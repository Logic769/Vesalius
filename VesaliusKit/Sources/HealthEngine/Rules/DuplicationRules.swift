import Foundation
import VesaliusCore

/// "duplicate-code": functions whose bodies are structurally identical (identifiers and literals
/// normalised by the analyzers' body hash).
enum DuplicationRules {
    static func run(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        var groups: [UInt64: [RepositorySnapshot.Symbol]] = [:]
        for file in ctx.sourceFiles {
            for symbol in ctx.symbolsByFile[file.id] ?? [] where symbol.kind.isCallable {
                guard let hash = symbol.bodyHash, symbol.lines.count >= ctx.config.duplicateMinLines else { continue }
                groups[hash, default: []].append(symbol)
            }
        }
        var drafts: [DiagnosticDraft] = []
        for (_, symbols) in groups where symbols.count >= 2 {
            let sorted = symbols.sorted { (ctx.path($0.fileID), $0.lines.start) < (ctx.path($1.fileID), $1.lines.start) }
            let copies = sorted.count
            let lines = sorted.map(\.lines.count).max() ?? 0
            let extra = sorted.dropFirst().reduce(0) { $0 + $1.lines.count }
            findings.duplicateGroups += 1
            findings.duplicateExtraLines += extra
            let severity: Severity = (copies >= 4 && lines >= 30) ? .high : ((copies >= 3 || lines >= 15) ? .medium : .low)
            let distinctNames = Array(Set(sorted.map(\.name))).sorted()
            let name = distinctNames.count == 1 ? distinctNames[0] : "\(distinctNames[0]) and \(distinctNames.count - 1) similar"
            let locations = sorted.map { "\(ctx.displayName($0.fileID)):\($0.lines.start) (\($0.qualifiedName))" }
            let files = Set(sorted.map(\.fileID)).count
            drafts.append(DiagnosticDraft(
                rule: "duplicate-code",
                category: .maintainability,
                severity: severity,
                title: "Duplicate-looking code: \(name) (\(copies) copies)",
                summary: "\(copies) functions of about \(lines) lines have structurally identical bodies across \(Format.plural(files, "file")): \(Format.list(locations, limit: 4)).",
                reason: "Their bodies match token-for-token once identifiers and literals are ignored. Duplicated logic has to be fixed in \(copies) places and tends to drift apart over time.",
                recommendation: distinctNames.count == 1
                    ? "Extract the shared logic into one function (or a protocol extension / base helper) and call it from each site, parameterising whatever differs."
                    : "Check whether \(Format.list(distinctNames, limit: 3)) implement the same algorithm; if so, extract it once and parameterise the differences.",
                targets: sorted.map { .symbol(ctx.path($0.fileID), $0.qualifiedName, line: $0.lines.start) },
                metrics: [
                    DiagnosticMetric(name: "copies", value: Double(copies), threshold: 2),
                    DiagnosticMetric(name: "lines per copy", value: Double(lines), threshold: Double(ctx.config.duplicateMinLines), unit: "lines"),
                    DiagnosticMetric(name: "duplicated lines", value: Double(extra), unit: "lines"),
                ],
                rank: Double(copies * lines)
            ))
        }
        drafts.sort { $0.rank != $1.rank ? $0.rank > $1.rank : DiagnosticDraft.ordered($0, $1) }
        findings.drafts += drafts.prefix(40)
    }
}
