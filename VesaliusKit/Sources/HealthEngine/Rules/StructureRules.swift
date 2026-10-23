import Foundation
import VesaliusCore

/// "mixed-concerns", "utility-dumping-ground", "scattered-feature", "boundary-violation" and
/// organisation measures.
enum StructureRules {
    /// Concern detection is identifier-heavy; compute it once per file.
    private final class ConcernCache {
        private var storage: [Int64: [ConceptLexicon.Concern: String]] = [:]
        let ctx: HealthContext

        init(_ ctx: HealthContext) { self.ctx = ctx }

        func concerns(of file: RepositorySnapshot.File) -> [ConceptLexicon.Concern: String] {
            if let cached = storage[file.id] { return cached }
            let value = ctx.concerns(of: file)
            storage[file.id] = value
            return value
        }
    }

    static func run(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        let cache = ConcernCache(ctx)
        mixedConcerns(ctx, cache, &findings)
        dumpingGrounds(ctx, cache, &findings)
        scatteredFeatures(ctx, &findings)
        boundaries(ctx, &findings)
        organization(ctx, &findings)
    }

    // MARK: Mixed concerns

    private static func mixedConcerns(_ ctx: HealthContext, _ cache: ConcernCache, _ findings: inout HealthFindings) {
        for file in ctx.sourceFiles where file.codeLines >= ctx.config.mixedConcernsMinLines {
            let concerns = cache.concerns(of: file)
            guard concerns.count >= ctx.config.mixedConcernsMin else { continue }
            findings.mixedConcernFiles += 1
            let ordered = concerns.sorted { $0.key.rawValue < $1.key.rawValue }
            let names = ordered.map { $0.key.displayName }
            let evidence = ordered.map { "\($0.key.displayName) (\($0.value))" }.joined(separator: "; ")
            let hasUI = concerns[.ui] != nil
            let others = ordered.filter { $0.key != .ui }.map { $0.key.displayName }
            findings.drafts.append(DiagnosticDraft(
                rule: "mixed-concerns",
                category: .maintainability,
                severity: concerns.count >= 4 ? .medium : .low,
                title: "Mixed responsibilities: \(file.fileName)",
                summary: "\(file.fileName) combines \(Format.naturalList(names)).",
                reason: "Detected \(concerns.count) separate concerns (threshold \(ctx.config.mixedConcernsMin)): \(evidence). A file that owns several concerns changes for several unrelated reasons and is hard to test without all of them.",
                recommendation: hasUI
                    ? "Keep this file about presentation: move the \(Format.naturalList(others)) work into a view model, service or repository and pass the results in."
                    : "Give each concern its own type (e.g. a client for networking, a store for persistence) and let this file coordinate them through narrow interfaces.",
                targets: [.file(file.path)],
                metrics: [
                    DiagnosticMetric(name: "concerns", value: Double(concerns.count), threshold: Double(ctx.config.mixedConcernsMin)),
                    DiagnosticMetric(name: "code lines", value: Double(file.codeLines), unit: "lines"),
                ],
                rank: Double(concerns.count)
            ))
        }
    }

    // MARK: Utility dumping grounds

    private static func isUtilityName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if Catalog.utilityNames.contains(lower) { return true }
        return ["utils", "utilities", "helpers", "extensions", "misc", "common"].contains { lower.hasSuffix($0) }
            || lower.hasPrefix("util") || lower.hasPrefix("helper")
    }

    private static func dumpingGrounds(_ ctx: HealthContext, _ cache: ConcernCache, _ findings: inout HealthFindings) {
        let config = ctx.config
        // Directories.
        var filesByDirectory: [String: [RepositorySnapshot.File]] = [:]
        for file in ctx.sourceFiles { filesByDirectory[file.directory, default: []].append(file) }
        for (directory, files) in filesByDirectory.sorted(by: { $0.key < $1.key }) {
            let name = (directory as NSString).lastPathComponent
            guard !directory.isEmpty, Catalog.utilityNames.contains(name.lowercased()), files.count >= config.dumpingGroundMinFiles else { continue }
            var concernSet = Set<ConceptLexicon.Concern>()
            for file in files { concernSet.formUnion(cache.concerns(of: file).keys) }
            var severity: Severity = files.count >= config.dumpingGroundMinFiles * 2 ? .medium : .low
            if concernSet.count >= 4 && severity == .low { severity = .medium }
            findings.dumpingGrounds += 1
            let lines = files.reduce(0) { $0 + $1.codeLines }
            findings.drafts.append(DiagnosticDraft(
                rule: "utility-dumping-ground",
                category: .organization,
                severity: severity,
                title: "Utility dumping ground: \(name)/",
                summary: "\(directory)/ holds \(Format.plural(files.count, "file")) (\(Format.count(lines)) code lines)\(concernSet.count >= 2 ? " touching \(Format.list(concernSet.map(\.displayName).sorted(), limit: 5))" : "").",
                reason: "Generic folders like \(name)/ attract code that has no clear home; with \(files.count) files (threshold \(config.dumpingGroundMinFiles)) it has become a catch-all whose contents are unrelated to each other\(concernSet.count >= 4 ? " (\(concernSet.count) different concerns)" : "").",
                recommendation: "Move each helper next to the feature that uses it, or regroup the folder into named, purpose-specific modules (Formatting, Networking, Persistence…).",
                targets: [.directory(directory)],
                metrics: [
                    DiagnosticMetric(name: "files", value: Double(files.count), threshold: Double(config.dumpingGroundMinFiles), unit: "files"),
                    DiagnosticMetric(name: "concerns", value: Double(concernSet.count)),
                    DiagnosticMetric(name: "code lines", value: Double(lines), unit: "lines"),
                ],
                rank: Double(files.count) / Double(config.dumpingGroundMinFiles)
            ))
        }
        // Files.
        for file in ctx.sourceFiles where isUtilityName(file.stem) {
            let topLevel = (ctx.symbolsByFile[file.id] ?? []).filter { symbol in
                guard symbol.kind != .extension else { return false }
                guard let parent = symbol.parentID else { return true }
                return ctx.symbolsByID[parent]?.kind == .extension
            }
            let concerns = cache.concerns(of: file)
            let fanIn = ctx.metric(file.id).fanIn
            var reasons: [String] = []
            if topLevel.count >= config.dumpingGroundMinSymbols { reasons.append("\(topLevel.count) top-level declarations (threshold \(config.dumpingGroundMinSymbols))") }
            if concerns.count >= 3 { reasons.append("\(concerns.count) unrelated concerns (\(concerns.keys.map(\.displayName).sorted().joined(separator: ", ")))") }
            if fanIn >= config.dumpingGroundFanIn { reasons.append("used by \(fanIn) files (threshold \(config.dumpingGroundFanIn))") }
            guard !reasons.isEmpty else { continue }
            findings.dumpingGrounds += 1
            findings.drafts.append(DiagnosticDraft(
                rule: "utility-dumping-ground",
                category: .organization,
                severity: reasons.count >= 2 ? .medium : .low,
                title: "Utility dumping ground: \(file.fileName)",
                summary: "\(file.fileName) is a general-purpose helper file with \(Format.plural(topLevel.count, "declaration")) used by \(Format.plural(fanIn, "file")).",
                reason: "Flagged for \(reasons.joined(separator: "; ")). Catch-all helper files grow without a theme and couple unrelated parts of the codebase through one file.",
                recommendation: "Split the helpers by purpose into focused files (e.g. DateFormatting, StringValidation) or move each one next to its only caller.",
                targets: [.file(file.path)],
                metrics: [
                    DiagnosticMetric(name: "declarations", value: Double(topLevel.count), threshold: Double(config.dumpingGroundMinSymbols)),
                    DiagnosticMetric(name: "concerns", value: Double(concerns.count), threshold: 3),
                    DiagnosticMetric(name: "fan-in", value: Double(fanIn), threshold: Double(config.dumpingGroundFanIn), unit: "files"),
                ],
                rank: Double(reasons.count)
            ))
        }
    }

    // MARK: Scattered features

    private static func scatteredFeatures(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        let repoWords = Set(FastWords.split(ctx.snapshot.repositoryName))
        var filesByWord: [String: [Int64]] = [:]
        for file in ctx.sourceFiles {
            let words = FastWords.split(file.stem).filter {
                $0.count >= 3 && !Catalog.genericWords.contains($0) && !Tokenizer.languageKeywords.contains($0)
                    && !repoWords.contains($0) && !($0.first?.isNumber ?? false)
            }
            guard let word = words.first else { continue }
            filesByWord[word, default: []].append(file.id)
        }
        let prefixLimit = Double(ctx.sourceFiles.count) * 0.4
        var candidates: [(word: String, areas: [String], files: [Int64])] = []
        for (word, files) in filesByWord where files.count >= 4 && Double(files.count) <= max(4, prefixLimit) {
            var areas = Set<String>()
            for id in files {
                let area = ctx.area(of: id)
                let last = (area as NSString).lastPathComponent.lowercased()
                guard !area.isEmpty, !Catalog.layerDirectoryNames.contains(last) else { continue }
                areas.insert(area)
            }
            guard areas.count >= ctx.config.scatteredFeatureMinAreas else { continue }
            candidates.append((word, areas.sorted(), files.sorted { ctx.path($0) < ctx.path($1) }))
        }
        candidates.sort { $0.areas.count == $1.areas.count ? $0.word < $1.word : $0.areas.count > $1.areas.count }
        for candidate in candidates.prefix(15) {
            findings.scatteredFeatures += 1
            let label = candidate.word.prefix(1).uppercased() + candidate.word.dropFirst()
            let areaNames = candidate.areas.map { ctx.areas.name(of: $0) }
            findings.drafts.append(DiagnosticDraft(
                rule: "scattered-feature",
                category: .organization,
                severity: .info,
                title: "Feature spread: \(label)",
                summary: "\(Format.plural(candidate.files.count, "file")) named after “\(label)” \(Format.verb(candidate.files.count, "lives", "live")) in \(candidate.areas.count) different areas: \(Format.list(areaNames, limit: 5)).",
                reason: "The \(label) concept appears in \(candidate.areas.count) areas (threshold \(ctx.config.scatteredFeatureMinAreas), layer folders excluded), so understanding or changing it means visiting all of them.",
                recommendation: "If \(label) is a feature, gather its files into one feature folder or module with a small public surface; if it is a shared domain concept, keep its model in one place and name feature-specific files after their feature.",
                targets: candidate.areas.map { .directory($0) } + candidate.files.prefix(10).map { .file(ctx.path($0)) },
                metrics: [
                    DiagnosticMetric(name: "areas", value: Double(candidate.areas.count), threshold: Double(ctx.config.scatteredFeatureMinAreas)),
                    DiagnosticMetric(name: "files", value: Double(candidate.files.count), unit: "files"),
                ],
                rank: Double(candidate.areas.count)
            ))
        }
    }

    // MARK: Layer boundaries

    private static let lowerLayers: Set<String> = ["Models", "Domain", "Data", "Services", "Utilities"]

    private static func violation(from source: String, to target: String) -> Severity? {
        if (source == "Models" || source == "Domain") && (target == "Presentation" || target == "ViewModels") { return .medium }
        if lowerLayers.contains(source) && (target == "Presentation" || target == "ViewModels") { return .low }
        if source == "Domain" && target == "Data" { return .low }
        if source == "ViewModels" && target == "Presentation" { return .low }
        return nil
    }

    private static func boundaries(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        var bySource: [Int64: [(target: Int64, severity: Severity, from: String, to: String)]] = [:]
        for entry in ctx.pairs where ctx.sourceIDs.contains(entry.pair.source) && ctx.sourceIDs.contains(entry.pair.target) {
            guard let from = ctx.layerOfFile[entry.pair.source], let to = ctx.layerOfFile[entry.pair.target] else { continue }
            findings.layeredPairs += 1
            guard from != to, let severity = violation(from: from, to: to) else { continue }
            findings.layerViolationPairs += 1
            bySource[entry.pair.source, default: []].append((entry.pair.target, severity, from, to))
        }
        findings.violatingFiles = bySource.count
        var drafts: [DiagnosticDraft] = []
        for (source, violations) in bySource {
            guard let file = ctx.file(source) else { continue }
            let severity = violations.map(\.severity).max() ?? .low
            let layers = Set(violations.map { "\($0.from) → \($0.to)" }).sorted()
            let targets = violations.map(\.target).sorted { ctx.path($0) < ctx.path($1) }
            let fromLayer = violations[0].from
            let isDomainData = violations.allSatisfy { $0.from == "Domain" && $0.to == "Data" }
            drafts.append(DiagnosticDraft(
                rule: "boundary-violation",
                category: .boundaries,
                severity: severity,
                title: "Layer violation (\(layers.joined(separator: ", "))): \(file.fileName)",
                summary: "\(file.fileName) in the \(fromLayer) layer depends on \(Format.plural(targets.count, "file")) in a higher layer: \(Format.list(targets.map { ctx.displayName($0) }, limit: 3)).",
                reason: isDomainData
                    ? "In a layered design the Domain layer owns the interfaces and Data implements them; here Domain depends on Data directly, so business rules are tied to a storage or networking implementation."
                    : "Lower layers (\(fromLayer)) should not know about the UI. This dependency couples data and business logic to how it is displayed, so UI changes can break them.",
                recommendation: isDomainData
                    ? "Declare the repository/service protocol in Domain and let the Data layer implement it; inject the implementation from the composition root."
                    : "Invert the dependency: move the shared type down into \(fromLayer), or let the UI layer adapt the model (a view model or a view-specific extension) instead.",
                targets: [.file(file.path)] + targets.prefix(10).map { .file(ctx.path($0)) },
                metrics: [
                    DiagnosticMetric(name: "upward dependencies", value: Double(targets.count), threshold: 0, unit: "files"),
                ],
                rank: Double(targets.count)
            ))
        }
        drafts.sort { $0.rank != $1.rank ? $0.rank > $1.rank : DiagnosticDraft.ordered($0, $1) }
        findings.drafts += drafts.prefix(40)
    }

    // MARK: Organization measures

    private static func organization(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        var perDirectory: [String: Int] = [:]
        for file in ctx.sourceFiles { perDirectory[file.directory, default: 0] += 1 }
        findings.rootSourceFiles = perDirectory[""] ?? 0
        findings.oversizedDirectories = perDirectory.filter { !$0.key.isEmpty && $0.value > 60 }.count
    }
}
