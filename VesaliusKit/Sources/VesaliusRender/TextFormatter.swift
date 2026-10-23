import Foundation
import VesaliusCore

/// Compact, deterministic plain-text rendering for terminals and agents. Shared by the CLI and the MCP
/// server; `vesalius query`'s table lives in VesaliusCommands because its result type is QueryEngine's.
public enum TextFormatter {
    public static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    public static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    public static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    public static func score(_ value: Double) -> String { String(format: "%.2f", value) }

    // MARK: Index

    public static func indexSummary(_ s: IndexSummary) -> String {
        var lines = [
            "Indexed \(s.repository)",
            "  files: \(number(s.filesScanned)) scanned · +\(s.filesAdded) added · ~\(s.filesChanged) changed · -\(s.filesRemoved) removed · \(s.filesUnchanged) unchanged\(s.filesFailed > 0 ? " · \(s.filesFailed) failed" : "")",
            "  graph: \(number(s.symbols)) symbols · \(number(s.references)) references · \(number(s.edges)) dependency edges",
            "  time:  \(String(format: "%.2f", s.durationSeconds))s · index \(s.indexPath)",
        ]
        if !s.warnings.isEmpty {
            lines.append("  warnings:")
            lines += s.warnings.prefix(8).map { "    \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    public static func status(_ s: RepositoryStatus) -> String {
        var lines = ["\(s.repository.name)  \(s.repository.path)"]
        if s.repository.isGitRepository {
            lines.append("  git: \(s.repository.branch ?? "?") @ \(s.repository.headCommit ?? "?")")
        }
        guard s.isIndexed else {
            lines.append("  not indexed, run `vesalius index`")
            return lines.joined(separator: "\n")
        }
        let st = s.stats
        lines.append("  indexed \(s.lastIndexed.map(relative) ?? "?")\(s.indexDurationSeconds.map { String(format: " (took %.1fs)", $0) } ?? "")\(s.staleFiles.map { $0 > 0 ? " · \($0) file(s) changed since" : " · up to date" } ?? "")")
        lines.append("  \(number(st.files)) files (\(number(st.sourceFiles)) source, \(number(st.testFiles)) tests) · \(number(st.codeLines)) code lines · \(number(st.directories)) folders")
        lines.append("  \(number(st.symbols)) symbols (\(number(st.types)) types, \(number(st.functions)) functions) · \(st.modules) modules · \(number(st.dependencies)) file dependencies · \(st.externalModules) external modules")
        if let embeddings = s.embeddings { lines.append("  semantic vectors: \(number(embeddings))") }
        if st.parseFailures > 0 { lines.append("  \(st.parseFailures) file(s) failed to parse") }
        if let vendored = s.vendoredDirectories, !vendored.isEmpty {
            lines.append("  skipped \(vendored.count) vendored project(s): " + vendored.prefix(6).joined(separator: ", ") + (vendored.count > 6 ? " …" : ""))
        }
        lines.append("  index: \(s.indexPath)")
        return lines.joined(separator: "\n")
    }

    // MARK: Search

    /// `scores: false` is the agent form (MCP): no relevance numbers, related list or search terms.
    public static func ask(_ result: AskResult, scores: Bool = true) -> String {
        var lines = [result.answer, ""]
        for (index, file) in result.files.enumerated() {
            let range = file.lines.map { ":\($0)" } ?? ""
            lines.append("\(index + 1). \(file.path)\(range)\(scores ? "  [\(score(file.relevance))]" : "")  \(file.reason)")
            if !file.symbols.isEmpty {
                lines.append("     " + file.symbols.map { "\($0.name) (\($0.kind.displayName)) \($0.lines)" }.joined(separator: " · "))
            }
        }
        guard scores else { return lines.joined(separator: "\n") }
        if let related = result.related, !related.isEmpty {
            lines.append("related: " + related.map { "\($0.path) (\($0.reason))" }.joined(separator: ", "))
        }
        if !result.terms.isEmpty && result.intent == "search" {
            lines.append("terms: " + result.terms.prefix(10).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func symbols(_ symbols: [SymbolSummary]) -> String {
        guard !symbols.isEmpty else { return "No symbols match." }
        return symbols.map { symbol in
            var line = "\(symbol.qualifiedName)  \(symbol.kind.displayName)  \(symbol.path):\(symbol.lines)"
            if let refs = symbol.references, refs > 0 { line += "  (\(refs) refs)" }
            if let signature = symbol.signature { line += "\n    \(signature)" }
            return line
        }.joined(separator: "\n")
    }

    public static func references(_ result: ReferencesResult) -> String {
        var lines: [String] = []
        if result.symbols.isEmpty {
            lines.append("“\(result.query)” is not declared in this repository; unresolved uses (external API):")
            for site in result.textualMatches ?? [] { lines.append(siteLine(site)) }
            return lines.joined(separator: "\n")
        }
        for symbol in result.symbols {
            lines.append("\(symbol.qualifiedName) (\(symbol.kind.displayName)) \(symbol.path):\(symbol.lines)")
        }
        lines.append("\(result.total) reference\(result.total == 1 ? "" : "s")\(result.references.count < result.total ? " (showing \(result.references.count) sites)" : ""):")
        for site in result.references { lines.append(siteLine(site)) }
        return lines.joined(separator: "\n")
    }

    public static func siteLine(_ site: ReferenceSite) -> String {
        var line = "  \(site.path):\(site.line)  \(site.kind.rawValue)"
        if let from = site.from { line += "  in \(from)" }
        if let count = site.count { line += "  ×\(count)" }
        if let snippet = site.snippet, !snippet.isEmpty { line += "  │ \(snippet)" }
        return line
    }

    public static func callGraph(_ result: CallGraphResult) -> String {
        var lines = result.symbols.prefix(3).map { "\($0.qualifiedName) (\($0.kind.displayName)) \($0.path):\($0.lines)" }
        if result.relations.isEmpty {
            lines.append(result.direction == "callers" ? "No callers found." : "No repository callees found.")
        }
        for relation in result.relations {
            let sites = relation.sites.prefix(6).map(String.init).joined(separator: ",")
            lines.append("  \(relation.symbol.qualifiedName)  \(relation.symbol.path):\(sites)\(relation.count > 1 ? "  ×\(relation.count)" : "")")
        }
        return lines.joined(separator: "\n")
    }

    public static func dependencies(_ result: DependencyResult) -> String {
        var lines = ["\(result.target): \(result.total) \(result.direction)\(result.depth > 1 ? " (depth \(result.depth))" : "")"]
        for file in result.files {
            var line = "  \(file.distance.map { $0 > 1 ? "[\($0)] " : "" } ?? "")\(file.path)"
            if !file.kinds.isEmpty { line += "  \(file.kinds.map(\.rawValue).joined(separator: "/"))" }
            if let symbols = file.symbols, !symbols.isEmpty { line += ": " + symbols.joined(separator: ", ") }
            lines.append(line)
        }
        if let external = result.externalModules, !external.isEmpty {
            lines.append("  external: " + external.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func impact(_ report: ImpactReport) -> String {
        var lines = [report.summary, ""]
        lines.append("risk \(report.riskLevel.rawValue.uppercased()) \(Int(report.riskScore.rounded()))/100")
        for factor in report.factors { lines.append(String(format: "  %+.0f  %@: %@", factor.impact, factor.label, factor.detail)) }
        if !report.directDependents.isEmpty {
            lines.append("direct dependents (\(report.directDependents.count)):")
            for file in report.directDependents.prefix(25) {
                lines.append("  \(file.path)" + (file.symbols.map { ": " + $0.joined(separator: ", ") } ?? ""))
            }
        }
        if !report.transitiveDependents.isEmpty {
            lines.append("transitive dependents (\(report.transitiveDependents.count)):")
            for file in report.transitiveDependents.prefix(20) { lines.append("  [\(file.distance ?? 2)] \(file.path)") }
            if report.transitiveDependents.count > 20 { lines.append("  … \(report.transitiveDependents.count - 20) more") }
        }
        if !report.callers.isEmpty {
            lines.append("call/reference sites:")
            for site in report.callers.prefix(12) { lines.append(siteLine(site)) }
        }
        if !report.relatedTests.isEmpty { lines.append("related tests: " + report.relatedTests.joined(separator: ", ")) }
        if !report.affectedAreas.isEmpty { lines.append("areas: " + report.affectedAreas.map { "\($0.name) (\($0.files))" }.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    public static func fileContext(_ c: FileContext) -> String {
        let f = c.file
        var lines = ["\(f.path)  \(f.language.displayName) · \(f.lines) lines (\(f.codeLines) code) · \(f.symbols) symbols · complexity \(f.complexity)\(f.isTest ? " · test" : "")\(f.module.map { " · module \($0)" } ?? "")"]
        lines.append("  fan-in \(f.fanIn) · fan-out \(f.fanOut) · centrality \(score(f.centrality)) · risk \(c.impact.riskLevel.rawValue) (\(Int(c.impact.riskScore.rounded()))) · \(c.impact.transitiveDependents + c.impact.directDependents) affected by a change")
        if !c.symbols.isEmpty {
            lines.append("symbols:")
            for symbol in c.symbols.prefix(80) {
                let indent = String(repeating: "  ", count: (symbol.depth ?? 0) + 1)
                lines.append("\(indent)\(symbol.name) \(symbol.kind.displayName) \(symbol.lines)\(symbol.references.map { $0 > 0 ? " (\($0) refs)" : "" } ?? "")")
            }
            if c.symbols.count > 80 { lines.append("  … \(c.symbols.count - 80) more") }
        }
        if !c.imports.isEmpty {
            lines.append("imports: " + c.imports.map { $0.resolvedPath ?? $0.module }.joined(separator: ", "))
        }
        if !c.dependencies.isEmpty {
            lines.append("depends on: " + c.dependencies.prefix(20).map { $0.path + ($0.symbols.map { " (\($0.prefix(3).joined(separator: ", ")))" } ?? "") }.joined(separator: ", "))
        }
        if !c.dependents.isEmpty {
            lines.append("used by: " + c.dependents.prefix(20).map(\.path).joined(separator: ", ") + (c.dependents.count > 20 ? " … +\(c.dependents.count - 20)" : ""))
        }
        if !c.diagnostics.isEmpty {
            lines.append("diagnostics:")
            for diagnostic in c.diagnostics.prefix(8) { lines.append("  [\(diagnostic.severity.rawValue)] \(diagnostic.title)") }
        }
        if !c.related.isEmpty {
            lines.append("related: " + c.related.prefix(6).map { "\($0.path) (\($0.reason))" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func symbolContext(_ c: SymbolContext) -> String {
        let s = c.symbol
        var lines = ["\(s.qualifiedName)  \(s.kind.displayName)  \(s.path):\(s.lines)\(s.references.map { "  (\($0) refs)" } ?? "")"]
        if let signature = s.signature { lines.append("  \(signature)") }
        if let doc = s.doc { lines.append("  \(doc)") }
        if !c.members.isEmpty { lines.append("members: " + c.members.prefix(40).map { "\($0.name) (\($0.kind.displayName) \($0.lines))" }.joined(separator: ", ")) }
        if !c.callers.isEmpty { lines.append("callers: " + c.callers.prefix(15).map { "\($0.symbol.qualifiedName) [\($0.symbol.path)]" }.joined(separator: ", ")) }
        if !c.callees.isEmpty { lines.append("calls: " + c.callees.prefix(15).map(\.symbol.qualifiedName).joined(separator: ", ")) }
        if !c.references.isEmpty {
            lines.append("references:")
            for site in c.references.prefix(15) { lines.append(siteLine(site)) }
        }
        lines.append("impact: \(c.impact.directDependents) direct, \(c.impact.transitiveDependents) transitive dependents · risk \(c.impact.riskLevel.rawValue)")
        return lines.joined(separator: "\n")
    }

    // MARK: Health & architecture

    public static func health(_ report: HealthReport, diagnostics: [Diagnostic], verbose: Bool) -> String {
        var lines = ["Health \(report.score)/100 · \(report.grade)", report.summary, ""]
        for category in report.categories {
            let bar = String(repeating: "█", count: category.score / 10) + String(repeating: "░", count: 10 - category.score / 10)
            lines.append(String(format: "  %-22@ %3d  %@  %@", category.category.displayName as NSString, category.score, bar, category.summary))
            let factors = verbose ? category.factors : Array(category.factors.filter { $0.impact < 0 }.prefix(2))
            for factor in factors { lines.append(String(format: "      %+.1f  %@", factor.impact, factor.detail)) }
        }
        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("Top diagnostics:")
            for diagnostic in diagnostics { lines.append(diagnostic_(diagnostic)) }
        }
        return lines.joined(separator: "\n")
    }

    private static func diagnostic_(_ d: Diagnostic) -> String { diagnostic(d, detailed: false) }

    public static func diagnostic(_ d: Diagnostic, detailed: Bool) -> String {
        let location = d.targets.first.map { $0.path + ($0.line.map { ":\($0)" } ?? "") + ($0.symbol.map { " (\($0))" } ?? "") } ?? ""
        var lines = ["  [\(d.severity.rawValue)] \(d.title)  \(location)"]
        if detailed {
            lines.append("    \(d.summary)")
            lines.append("    why: \(d.reason)")
            if !d.metrics.isEmpty { lines.append("    metrics: " + d.metrics.map { "\($0.name) \($0.formattedValue)\($0.threshold.map { " (threshold \(DiagnosticMetric(name: "", value: $0).formattedValue))" } ?? "")" }.joined(separator: ", ")) }
            lines.append("    suggestion: \(d.recommendation)")
            if d.targets.count > 1 { lines.append("    affects: " + d.targets.prefix(8).map(\.path).joined(separator: ", ") + (d.targets.count > 8 ? " …" : "")) }
        }
        return lines.joined(separator: "\n")
    }

    public static func hotspots(_ hotspots: [Hotspot]) -> String {
        guard !hotspots.isEmpty else { return "No hotspots." }
        return hotspots.map { "\(score($0.score))  \($0.path)  · " + $0.reasons.joined(separator: ", ") }.joined(separator: "\n")
    }

    public static func unused(_ report: UnusedReport) -> String {
        var lines: [String] = []
        if !report.files.isEmpty {
            lines.append("Files with no detected references (\(report.files.count)):")
            lines += report.files.map { "  \($0.path)  [\(score($0.confidence))]  \($0.reason)" }
        }
        if !report.symbols.isEmpty {
            lines.append("Symbols with no detected references (\(report.symbols.count)):")
            lines += report.symbols.map { "  \($0.path):\($0.line ?? 0)  \($0.symbol ?? "")\($0.symbolKind.map { " (\($0.displayName))" } ?? "")  [\(score($0.confidence))]" }
        }
        if lines.isEmpty { lines.append("No unused code detected.") }
        if !report.note.isEmpty { lines.append("note: \(report.note)") }
        return lines.joined(separator: "\n")
    }

    /// `percentages: false` is the agent form (MCP): patterns are listed with their evidence but no confidence.
    public static func architecture(_ report: ArchitectureReport, percentages: Bool = true) -> String {
        var lines = [report.summary]
        if !report.frameworks.isEmpty { lines.append("frameworks: " + report.frameworks.joined(separator: ", ")) }
        for pattern in report.patterns {
            lines.append(percentages ? "\(pattern.label) (\(Int((pattern.confidence * 100).rounded()))%)" : "\(pattern.label):")
            for evidence in pattern.evidence.prefix(5) { lines.append("  - \(evidence)") }
        }
        if !report.layers.isEmpty {
            lines.append("layers:")
            for layer in report.layers { lines.append("  \(layer.name) (\(layer.files) files)\(layer.dependsOn.isEmpty ? "" : " → " + layer.dependsOn.joined(separator: ", "))") }
        }
        if !report.areas.isEmpty {
            lines.append("areas:")
            for area in report.areas.prefix(20) { lines.append("  \(area.name)  \(area.path)  \(area.files) files, \(number(area.lines)) lines\(area.dependsOn.isEmpty ? "" : " → " + area.dependsOn.prefix(5).joined(separator: ", "))") }
        }
        if !report.entryPoints.isEmpty { lines.append("entry points: " + report.entryPoints.prefix(10).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    public static func suggestions(_ suggestions: [ExtractionSuggestion]) -> String {
        guard !suggestions.isEmpty else { return "No strong extraction candidates: groups of files are either small or already well connected to the rest." }
        return suggestions.map { s in
            var lines = ["\(s.name)\(s.rootPath.map { "  (\($0))" } ?? "")  score \(score(s.score)) · \(s.files.count) files · \(number(s.lines)) lines · cohesion \(score(s.cohesion))"]
            lines += s.reasons.map { "  + \($0)" }
            lines += s.risks.map { "  ! \($0)" }
            if !s.entryPoints.isEmpty { lines.append("  entry points: " + s.entryPoints.prefix(5).joined(separator: ", ")) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    public static func map(_ graph: MapGraph) -> String {
        var lines = [graph.breadcrumbs.map(\.label).joined(separator: " › ") + "  (\(graph.level.rawValue), \(graph.nodes.count) nodes, \(graph.edges.count) edges\(graph.hiddenNodes > 0 ? ", \(graph.hiddenNodes) hidden" : ""))"]
        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        for node in graph.nodes.sorted(by: { $0.lines == $1.lines ? $0.label < $1.label : $0.lines > $1.lines }) {
            var line = "  \(node.kind == .external ? "↗ " : "")\(node.label)"
            if node.kind != .symbol { line += "  \(node.files) file\(node.files == 1 ? "" : "s"), \(number(node.lines)) lines" } else if let kind = node.symbolKind { line += "  \(kind.displayName)" }
            if node.diagnostics > 0 { line += "  ⚠︎\(node.diagnostics)" }
            line += "  [\(node.id)]"
            lines.append(line)
        }
        if !graph.edges.isEmpty {
            lines.append("edges:")
            for edge in graph.edges.sorted(by: { $0.weight > $1.weight }).prefix(80) {
                let source = byID[edge.source]?.label ?? edge.source
                let target = byID[edge.target]?.label ?? edge.target
                lines.append("  \(source) → \(target)  ×\(edge.weight)\(edge.isCycle ? "  (cycle)" : "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Lists moved from the CLI

    public static func files(_ hits: [FileHit]) -> String {
        hits.isEmpty ? "No files match." : hits.map { "\($0.path)\($0.reason.map { "  (\($0))" } ?? "")" }.joined(separator: "\n")
    }

    /// `filesPerCycle` cuts long cycle paths (`→ … +148 more`) so one huge cycle cannot fill an agent's result.
    public static func cycles(_ cycles: [DependencyCycle], filesPerCycle: Int = .max) -> String {
        guard !cycles.isEmpty else { return "No dependency cycles." }
        return cycles.map { cycle in
            let hidden = cycle.path.count - filesPerCycle
            return "cycle \(cycle.id) (\(cycle.files.count) files): " + cycle.path.prefix(filesPerCycle).joined(separator: " → ") + (hidden > 0 ? " → … +\(hidden) more" : "")
        }.joined(separator: "\n")
    }

    // MARK: Agent forms (MCP): facts with paths and lines, no scores, risk or centrality

    public static func overview(_ o: RepositoryOverview) -> String {
        let st = o.stats
        var lines = ["\(o.repository.name)  \(o.repository.path)"]
        lines.append("  \(number(st.files)) files (\(number(st.sourceFiles)) source, \(number(st.testFiles)) tests) · \(number(st.codeLines)) code lines · \(number(st.symbols)) symbols · \(st.modules) modules")
        if !o.languages.isEmpty {
            lines.append("  languages: " + o.languages.prefix(6).map { "\($0.language.displayName) \(Int(($0.share * 100).rounded()))%" }.joined(separator: ", "))
        }
        lines.append("  health \(o.health.score)/100 (\(o.health.grade)) · \(o.health.summary)")
        if !o.architecture.summary.isEmpty { lines.append("  architecture: \(o.architecture.summary)") }
        if !o.centralFiles.isEmpty { lines.append("central files: " + o.centralFiles.map { "\($0.path) (\($0.detail))" }.joined(separator: " · ")) }
        if !o.largeFiles.isEmpty { lines.append("largest files: " + o.largeFiles.map { "\($0.path) (\(Int($0.value)) lines)" }.joined(separator: " · ")) }
        if !o.hotspots.isEmpty { lines.append("hotspots: " + o.hotspots.map { "\($0.path) (\($0.reasons.prefix(2).joined(separator: ", ")))" }.joined(separator: " · ")) }
        if !o.cycles.isEmpty { lines.append("cycles: " + o.cycles.map { "\($0.files.count) files (\($0.path.prefix(3).joined(separator: " → "))\($0.path.count > 3 ? " → …" : ""))" }.joined(separator: " · ")) }
        if !o.externalModules.isEmpty { lines.append("external modules: " + o.externalModules.map { "\($0.path) (\(Int($0.value)))" }.joined(separator: ", ")) }
        if !o.topDiagnostics.isEmpty {
            lines.append("top diagnostics:")
            lines += o.topDiagnostics.map { diagnostic($0, detailed: false) }
        }
        return lines.joined(separator: "\n")
    }

    /// What a change to a file or symbol touches, from the legacy impact report: no risk score or factors.
    public static func changeImpact(_ report: ImpactReport, change: String) -> String {
        var lines = ["\(change.uppercased()) \(report.target) (\(report.targetKind))"]
        for symbol in report.symbols?.prefix(3) ?? [] {
            lines.append("  \(symbol.qualifiedName) (\(symbol.kind.displayName)) \(symbol.path):\(symbol.lines)")
        }
        var totals = (report.directDependents.count == 1 ? "1 file uses" : "\(report.directDependents.count) files use") + " it directly, \(report.transitiveDependents.count) more transitively"
        if !report.affectedAreas.isEmpty { totals += " · areas: " + report.affectedAreas.prefix(6).map { "\($0.name) (\($0.files))" }.joined(separator: ", ") }
        lines.append(totals)
        if !report.callers.isEmpty {
            lines.append("call/reference sites:")
            for site in report.callers.prefix(30) { lines.append(siteLine(site)) }
        }
        if !report.directDependents.isEmpty {
            lines.append("direct dependents:")
            for file in report.directDependents.prefix(30) {
                lines.append("  \(file.path)" + (file.symbols.map { ": " + $0.joined(separator: ", ") } ?? ""))
            }
            if report.directDependents.count > 30 { lines.append("  +\(report.directDependents.count - 30) more") }
        }
        if !report.transitiveDependents.isEmpty {
            lines.append("transitive dependents: " + report.transitiveDependents.prefix(12).map(\.path).joined(separator: ", ") + (report.transitiveDependents.count > 12 ? " +\(report.transitiveDependents.count - 12)" : ""))
        }
        if !report.relatedTests.isEmpty { lines.append("related tests: " + report.relatedTests.prefix(12).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// A file's declarations as an indented tree: line range, then signature (or kind and name).
    public static func fileOutline(_ c: FileContext) -> String {
        let f = c.file
        var header = "\(f.path)  \(f.language.displayName) · \(f.lines) lines · \(f.symbols) symbols"
        if let module = f.module { header += " · module \(module)" }
        header += " · used by \(c.dependents.count) file\(c.dependents.count == 1 ? "" : "s")"
        var lines = [header]
        for symbol in c.symbols {
            let indent = String(repeating: "  ", count: (symbol.depth ?? 0) + 1)
            var line = "\(indent)\(symbol.lines)  \(declaration(symbol))"
            if (symbol.depth ?? 0) == 0, let doc = symbol.doc.flatMap(firstSentence) { line += "  “\(doc)”" }
            lines.append(line)
        }
        if c.symbols.isEmpty { lines.append("  no declarations") }
        if !c.imports.isEmpty {
            lines.append("imports: " + c.imports.map { $0.resolvedPath ?? $0.module }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// A type's members or a function's declaration, with what it calls and who calls it.
    public static func symbolOutline(_ c: SymbolContext) -> String {
        let s = c.symbol
        var lines = ["\(s.qualifiedName)  \(s.kind.displayName)  \(s.path):\(s.lines)"]
        if let signature = s.signature { lines.append("  \(signature)") }
        if let doc = s.doc.flatMap(firstSentence) { lines.append("  “\(doc)”") }
        if let parent = c.parent { lines.append("  in \(parent.qualifiedName) (\(parent.kind.displayName)) :\(parent.lines)") }
        if !c.members.isEmpty {
            lines.append("members:")
            for member in c.members.prefix(80) { lines.append("  \(member.lines)  \(declaration(member))") }
            if c.members.count > 80 { lines.append("  +\(c.members.count - 80) more") }
        }
        if !c.callees.isEmpty {
            lines.append("calls: " + c.callees.prefix(20).map { "\($0.symbol.qualifiedName) \($0.symbol.path):\($0.symbol.lines)" }.joined(separator: " · ") + (c.callees.count > 20 ? " +\(c.callees.count - 20)" : ""))
        }
        if !c.callers.isEmpty {
            lines.append("called by: " + c.callers.prefix(15).map { "\($0.symbol.qualifiedName) \($0.symbol.path):\($0.sites.prefix(4).map(String.init).joined(separator: ","))" }.joined(separator: " · ") + (c.callers.count > 15 ? " +\(c.callers.count - 15)" : ""))
        }
        return lines.joined(separator: "\n")
    }

    /// The signature when the index has one, else `kind name`.
    static func declaration(_ symbol: SymbolSummary) -> String {
        if let signature = symbol.signature, !signature.isEmpty { return signature }
        return "\(symbol.kind.displayName) \(symbol.name)"
    }

    /// The first sentence of a doc comment, at most 100 characters.
    static func firstSentence(_ doc: String) -> String? {
        let flat = doc.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        var sentence = flat
        if let end = flat.range(of: ". ") { sentence = String(flat[..<end.lowerBound]) + "." }
        return sentence.count > 100 ? String(sentence.prefix(99)) + "…" : sentence
    }
}
