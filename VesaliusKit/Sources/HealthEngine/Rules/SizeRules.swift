import Foundation
import VesaliusCore

/// "large-file", "massive-ui-file", "large-type" and "long-function".
enum SizeRules {
    static func run(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        files(ctx, &findings)
        types(ctx, &findings)
        functions(ctx, &findings)
    }

    // MARK: Files

    static func isUIFile(_ file: RepositorySnapshot.File, ctx: HealthContext) -> Bool {
        let stem = file.stem.lowercased()
        let suffixes = ["view", "viewcontroller", "viewmodel", "component", "screen", "page", "vc"]
        if suffixes.contains(where: { stem.hasSuffix($0) }) { return true }
        if Language.isJSXExtension(file.path) {
            return (ctx.symbolsByFile[file.id] ?? []).contains { $0.kind == .component }
                || (ctx.symbolsByFile[file.id] ?? []).isEmpty == false && file.stem.first?.isUppercase == true
        }
        return false
    }

    private static func files(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        let config = ctx.config
        for file in ctx.participating {
            let multiplier = file.isTest ? config.testMultiplier : 1
            let isUI = !file.isTest && isUIFile(file, ctx: ctx)
            if isUI { findings.uiFileCount += 1 }
            let topTypes = (ctx.symbolsByFile[file.id] ?? []).filter { $0.parentID == nil && $0.kind.isType }
            let topLevel = (ctx.symbolsByFile[file.id] ?? []).filter { $0.parentID == nil && $0.kind != .extension }

            if isUI, file.codeLines > config.massiveUIFileLines {
                findings.massiveUIFileCount += 1
                let ratio = Double(file.codeLines) / Double(config.massiveUIFileLines)
                let severity: Severity = ratio >= 4 ? .critical : (ratio >= 2 ? .high : .medium)
                let role = uiRole(file)
                let biggest = topTypes.max { $0.lines.count < $1.lines.count }
                var recommendation = "Keep the \(role) focused on presentation: move state handling and business rules into a view model or service, and split large sub-views into their own types."
                if let biggest, biggest.lines.count > file.codeLines / 2 {
                    recommendation += " Most of the size is in \(biggest.name) (\(Format.count(biggest.lines.count)) lines)."
                }
                findings.drafts.append(DiagnosticDraft(
                    rule: "massive-ui-file",
                    category: .maintainability,
                    severity: severity,
                    title: "Massive \(role): \(file.fileName)",
                    summary: "\(file.fileName) is a \(role) file with \(Format.count(file.codeLines)) lines of code.",
                    reason: "UI files above \(config.massiveUIFileLines) code lines usually mix layout with state, data loading and business logic; this one has \(Format.count(file.codeLines)) (\(String(format: "%.1f", ratio))× the threshold).",
                    recommendation: recommendation,
                    targets: [.file(file.path)],
                    metrics: [
                        DiagnosticMetric(name: "code lines", value: Double(file.codeLines), threshold: Double(config.massiveUIFileLines), unit: "lines"),
                        DiagnosticMetric(name: "symbols", value: Double(file.symbolCount)),
                    ],
                    rank: ratio
                ))
                findings.largeFileIDs.insert(file.id)
                findings.largeFileLines += file.codeLines
                continue
            }

            let large = Int(Double(config.largeFileLines) * multiplier)
            let veryLarge = Int(Double(config.veryLargeFileLines) * multiplier)
            let huge = Int(Double(config.hugeFileLines) * multiplier)
            guard file.codeLines >= large else { continue }
            if !file.isTest {
                findings.largeFileIDs.insert(file.id)
                findings.largeFileLines += file.codeLines
            }
            let (severity, threshold, tier): (Severity, Int, String) =
                file.codeLines >= huge ? (.critical, huge, "huge")
                : file.codeLines >= veryLarge ? (.high, veryLarge, "very large")
                : (.medium, large, "large")
            var recommendation: String
            if topTypes.count >= 3 {
                recommendation = "This file declares \(topTypes.count) top-level types (\(Format.list(topTypes.map(\.name), limit: 4))); move each into its own file grouped by responsibility."
            } else if let biggest = topTypes.max(by: { $0.lines.count < $1.lines.count }), biggest.lines.count * 2 > file.codeLines {
                recommendation = "Most of the size comes from \(biggest.name) (\(Format.count(biggest.lines.count)) lines). Split it along its responsibilities into smaller collaborators or extensions in separate files."
            } else if topLevel.count >= 10 {
                recommendation = "The file holds \(topLevel.count) top-level declarations; group related ones into smaller, focused files."
            } else {
                recommendation = "Split the file along its responsibilities so each part can be read, reviewed and tested on its own."
            }
            if file.isTest {
                recommendation = "Split the test file by the behaviour under test and move shared setup into helpers or fixtures."
            }
            let testNote = file.isTest ? " (thresholds are doubled for tests)" : ""
            findings.drafts.append(DiagnosticDraft(
                rule: "large-file",
                category: .complexity,
                severity: file.isTest ? min(severity, .medium) : severity,
                title: "\(tier.prefix(1).uppercased() + tier.dropFirst()) file: \(file.fileName)",
                summary: "\(file.fileName) has \(Format.count(file.codeLines)) lines of code and \(Format.plural(file.symbolCount, "symbol")).",
                reason: "\(Format.count(file.codeLines)) code lines exceeds the \(Format.count(threshold))-line threshold for \(tier) files\(testNote). Large files tend to accumulate unrelated responsibilities and are harder to review and change safely.",
                recommendation: recommendation,
                targets: [.file(file.path)],
                metrics: [
                    DiagnosticMetric(name: "code lines", value: Double(file.codeLines), threshold: Double(threshold), unit: "lines"),
                    DiagnosticMetric(name: "top-level types", value: Double(topTypes.count)),
                    DiagnosticMetric(name: "complexity", value: Double(file.complexity)),
                ],
                rank: Double(file.codeLines) / Double(max(1, threshold))
            ))
        }
    }

    private static func uiRole(_ file: RepositorySnapshot.File) -> String {
        let stem = file.stem.lowercased()
        if stem.hasSuffix("viewcontroller") || stem.hasSuffix("vc") { return "view controller" }
        if stem.hasSuffix("viewmodel") { return "view model" }
        if stem.hasSuffix("screen") { return "screen" }
        if stem.hasSuffix("page") { return "page" }
        if stem.hasSuffix("component") || Language.isJSXExtension(file.path) { return "component" }
        return "view"
    }

    // MARK: Types

    private static func types(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        let config = ctx.config
        for file in ctx.participating {
            let multiplier = file.isTest ? config.testMultiplier : 1
            for symbol in ctx.symbolsByFile[file.id] ?? [] where symbol.kind.isType && symbol.kind != .typeAlias {
                let members = ctx.members(ofType: symbol)
                var lines = symbol.lines.count
                var extensionCount = 0
                let module = file.module
                for ext in ctx.extensionsByName[symbol.name] ?? [] {
                    let extModule = ctx.file(ext.fileID)?.module
                    guard extModule == module || extModule == nil || module == nil else { continue }
                    lines += ext.lines.count
                    extensionCount += 1
                }
                let lineLimit = Double(config.largeTypeLines) * multiplier
                let memberLimit = Double(config.largeTypeMembers) * multiplier
                let ratio = max(Double(lines) / lineLimit, Double(members.count) / memberLimit)
                guard ratio > 1 else { continue }
                if !file.isTest {
                    findings.largeTypeCount += 1
                    findings.largeTypeLines += symbol.lines.count
                }
                let severity: Severity = ratio >= 3 ? .critical : (ratio >= 2 ? .high : .medium)
                let methods = members.filter { $0.kind.isCallable }.count
                let properties = members.filter { $0.kind == .property || $0.kind == .variable || $0.kind == .constant }.count
                var concernCounts: [ConceptLexicon.Concern: Int] = [:]
                for member in members {
                    for (concern, _) in ConceptLexicon.concerns(for: FastWords.split(member.name)) {
                        if let normalized = Catalog.normalized(concern) { concernCounts[normalized, default: 0] += 1 }
                    }
                }
                let concernList = concernCounts
                    .filter { $0.value >= 2 }
                    .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
                    .map { "\($0.key.displayName) (\($0.value))" }
                let referencing = symbol.referencingFiles
                var reason = "\(symbol.name) spans \(Format.count(lines)) lines and \(Format.plural(members.count, "member"))"
                reason += " against thresholds of \(Int(lineLimit)) lines / \(Int(memberLimit)) members."
                if concernList.count >= 2 {
                    reason += " Its members touch several concerns: \(concernList.joined(separator: ", "))."
                }
                if referencing > 0 {
                    reason += " It is referenced from \(Format.plural(referencing, "other file")), so its size affects many call sites."
                }
                let extensionNote = extensionCount > 0 ? " and \(Format.plural(extensionCount, "extension"))" : ""
                findings.drafts.append(DiagnosticDraft(
                    rule: "large-type",
                    category: .complexity,
                    severity: file.isTest ? min(severity, .medium) : severity,
                    title: "Large \(symbol.kind.displayName): \(symbol.name)",
                    summary: "\(symbol.name) (\(symbol.kind.displayName)) has \(Format.plural(members.count, "member")) (\(methods) methods, \(properties) properties) across its declaration\(extensionNote).",
                    reason: reason,
                    recommendation: concernList.count >= 2
                        ? "Extract the member groups by concern (\(concernList.prefix(3).map { $0.components(separatedBy: " (").first ?? $0 }.joined(separator: ", "))) into dedicated collaborators that \(symbol.name) delegates to."
                        : "Identify cohesive groups of members (state + the methods that use it) and extract them into smaller types that \(symbol.name) composes.",
                    targets: [.symbol(file.path, symbol.qualifiedName, line: symbol.lines.start)],
                    metrics: [
                        DiagnosticMetric(name: "lines", value: Double(lines), threshold: lineLimit, unit: "lines"),
                        DiagnosticMetric(name: "members", value: Double(members.count), threshold: memberLimit),
                        DiagnosticMetric(name: "methods", value: Double(methods)),
                        DiagnosticMetric(name: "referencing files", value: Double(referencing)),
                    ],
                    rank: ratio
                ))
            }
        }
    }

    // MARK: Functions

    private static func functions(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        let config = ctx.config
        var candidates: [(ratio: Double, draft: DiagnosticDraft)] = []
        for file in ctx.participating {
            let multiplier = file.isTest ? config.testMultiplier : 1
            for symbol in ctx.symbolsByFile[file.id] ?? [] where symbol.kind.isCallable {
                if !file.isTest {
                    findings.callableCount += 1
                    findings.callableComplexityTotal += symbol.complexity
                }
                let lineLimit = Double(config.longFunctionLines) * multiplier
                let complexityLimit = Double(config.complexFunction) * multiplier
                let lines = symbol.lines.count
                let ratio = max(Double(lines) / lineLimit, Double(symbol.complexity) / complexityLimit)
                guard ratio > 1 else { continue }
                if !file.isTest { findings.longFunctionCount += 1 }
                let severity: Severity = ratio >= 4 ? .high : (ratio >= 2 ? .medium : .low)
                let isLong = Double(lines) > lineLimit
                let isComplex = Double(symbol.complexity) > complexityLimit
                let what = isLong && isComplex ? "long and complex" : (isLong ? "long" : "complex")
                var reasonParts: [String] = []
                if isLong { reasonParts.append("\(lines) lines (threshold \(Int(lineLimit)))") }
                if isComplex { reasonParts.append("cyclomatic complexity \(symbol.complexity) (threshold \(Int(complexityLimit)))") }
                let draft = DiagnosticDraft(
                    rule: "long-function",
                    category: .complexity,
                    severity: severity,
                    title: "\(what.prefix(1).uppercased() + what.dropFirst()) \(symbol.kind.displayName): \(symbol.name)",
                    summary: "\(symbol.qualifiedName) in \(file.fileName) has \(lines) lines and complexity \(symbol.complexity).",
                    reason: "Measured \(reasonParts.joined(separator: " and ")). Functions this size are hard to test exhaustively because every branch multiplies the paths through them.",
                    recommendation: isComplex
                        ? "Extract the independent branches into well-named helpers, replace nested conditionals with early returns, and consider a lookup table or strategy for large switch statements."
                        : "Split the body into steps with descriptive helper functions so each step can be understood and tested on its own.",
                    targets: [.symbol(file.path, symbol.qualifiedName, line: symbol.lines.start)],
                    metrics: [
                        DiagnosticMetric(name: "lines", value: Double(lines), threshold: lineLimit, unit: "lines"),
                        DiagnosticMetric(name: "complexity", value: Double(symbol.complexity), threshold: complexityLimit),
                    ],
                    rank: ratio
                )
                candidates.append((ratio, draft))
            }
        }
        candidates.sort { lhs, rhs in
            lhs.ratio != rhs.ratio ? lhs.ratio > rhs.ratio : DiagnosticDraft.ordered(lhs.draft, rhs.draft)
        }
        findings.drafts += candidates.prefix(config.maxLongFunctionDiagnostics).map(\.draft)
    }
}
