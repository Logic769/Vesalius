import Foundation
import GraphEngine
import VesaliusCore

/// Deterministic code-health analysis: diagnostics, a transparent score, architecture inference,
/// extraction suggestions and unused-code signals for one repository snapshot.
///
/// The engine is pure: it reads a `RepositorySnapshot` plus the `GraphAnalysis` computed for it and
/// returns a `HealthAnalysis`. Identical inputs always produce identical output (all collections are
/// explicitly ordered), and every rule runs in O(files + edges + symbols).
public struct HealthEngine: Sendable {
    public let configuration: HealthConfiguration

    public init(configuration: HealthConfiguration = .default) {
        self.configuration = configuration
    }

    public func analyze(snapshot: RepositorySnapshot, graph: GraphAnalysis) -> HealthAnalysis {
        let ctx = HealthContext(snapshot: snapshot, graph: graph, config: configuration)
        var findings = HealthFindings()

        SizeRules.run(ctx, &findings)
        CouplingRules.run(ctx, &findings)
        CycleRules.run(ctx, &findings)
        StructureRules.run(ctx, &findings)
        DuplicationRules.run(ctx, &findings)
        let unused = UnusedRules.run(ctx, &findings)

        let suggestions = ExtractionAdvisor.suggest(ctx)
        findings.drafts += extractionDrafts(suggestions)

        let architecture = ArchitectureInferrer.infer(ctx, violations: findings.layerViolationPairs)
        let diagnostics = finalize(findings.drafts)
        let report: HealthReport
        if ctx.sourceFiles.isEmpty {
            var counts: [String: Int] = [:]
            for severity in Severity.allCases { counts[severity.rawValue] = 0 }
            report = HealthReport(score: 0, grade: "Unknown", summary: "No source files to analyse yet.", categories: [], diagnosticCounts: counts)
        } else {
            report = HealthScorer.score(ctx, findings, diagnostics: diagnostics)
        }
        return HealthAnalysis(report: report, diagnostics: diagnostics, architecture: architecture, suggestions: suggestions, unused: unused)
    }

    /// Orders by severity/rule/rank, drops identical findings and keeps the most important
    /// `maxDiagnostics`. Distinct findings that share a fingerprint (two long overloads of one method)
    /// are kept, the later ones with a `-2`, `-3` suffix, so every diagnostic has its own id.
    private func finalize(_ drafts: [DiagnosticDraft]) -> [Diagnostic] {
        var identical = Set<String>()
        var occurrences: [String: Int] = [:]
        var result: [Diagnostic] = []
        for draft in drafts.sorted(by: DiagnosticDraft.ordered) {
            var diagnostic = draft.build()
            guard identical.insert(diagnostic.id + "\u{1F}" + diagnostic.summary).inserted else { continue }
            let occurrence = (occurrences[diagnostic.id] ?? 0) + 1
            occurrences[diagnostic.id] = occurrence
            if occurrence > 1 { diagnostic.id += "-\(occurrence)" }
            result.append(diagnostic)
            if result.count >= configuration.maxDiagnostics { break }
        }
        return result
    }

    private func extractionDrafts(_ suggestions: [ExtractionSuggestion]) -> [DiagnosticDraft] {
        suggestions.prefix(3).filter { $0.score >= 0.45 }.map { suggestion in
            let target: DiagnosticTarget = suggestion.rootPath.map { .directory($0) } ?? .file(suggestion.files.first ?? "")
            return DiagnosticDraft(
                rule: "extraction-candidate",
                category: .modularity,
                severity: .info,
                title: "Extraction candidate: \(suggestion.name)",
                summary: "\(suggestion.name) could likely become an independent module: \(suggestion.files.count) files, \(Format.percent(suggestion.cohesion)) of dependencies internal.",
                reason: suggestion.reasons.joined(separator: "; ") + ".",
                recommendation: "Consider extracting it into its own package/target. Benefits: \(suggestion.benefits.prefix(2).joined(separator: "; ").lowercased()). Watch for: \(suggestion.risks.first?.lowercased() ?? "nothing significant").",
                targets: [target],
                metrics: [
                    DiagnosticMetric(name: "files", value: Double(suggestion.files.count), unit: "files"),
                    DiagnosticMetric(name: "cohesion", value: suggestion.cohesion, threshold: configuration.extractionMinCohesion),
                    DiagnosticMetric(name: "external dependencies", value: Double(suggestion.externalDependencies)),
                    DiagnosticMetric(name: "external dependents", value: Double(suggestion.externalDependents)),
                ],
                rank: suggestion.score
            )
        }
    }
}
