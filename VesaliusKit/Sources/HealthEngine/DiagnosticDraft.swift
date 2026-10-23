import Foundation
import VesaliusCore

/// A diagnostic under construction plus a ranking key used to keep the most important ones when
/// capping. Rules return drafts; the engine assigns stable ids and orders them.
struct DiagnosticDraft {
    var rule: String
    var category: HealthCategory
    var severity: Severity
    var title: String
    var summary: String
    var reason: String
    var recommendation: String
    var targets: [DiagnosticTarget]
    var metrics: [DiagnosticMetric]
    /// Higher = more important within the same severity.
    var rank: Double

    func build() -> Diagnostic {
        Diagnostic(
            id: Diagnostic.fingerprint(rule: rule, targets: targets),
            rule: rule,
            category: category,
            severity: severity,
            title: title,
            summary: summary,
            reason: reason,
            recommendation: recommendation,
            targets: targets,
            metrics: metrics
        )
    }

    /// Rule order used as a tie-breaker (structural problems first).
    static let rulePriority: [String: Int] = [
        "dependency-cycle": 0,
        "large-type": 1,
        "large-file": 2,
        "massive-ui-file": 3,
        "high-fan-out": 4,
        "tight-coupling": 5,
        "boundary-violation": 6,
        "duplicate-code": 7,
        "deep-chain": 8,
        "mixed-concerns": 9,
        "high-fan-in": 10,
        "long-function": 11,
        "utility-dumping-ground": 12,
        "low-cohesion-directory": 13,
        "unused-file": 14,
        "unused-symbols": 15,
        "scattered-feature": 16,
        "extraction-candidate": 17,
    ]

    static func ordered(_ lhs: DiagnosticDraft, _ rhs: DiagnosticDraft) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        let lp = rulePriority[lhs.rule] ?? 99, rp = rulePriority[rhs.rule] ?? 99
        if lp != rp { return lp < rp }
        if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return (lhs.targets.first?.path ?? "") < (rhs.targets.first?.path ?? "")
    }
}

extension DiagnosticTarget {
    static func file(_ path: String) -> DiagnosticTarget { DiagnosticTarget(kind: .file, path: path) }
    static func directory(_ path: String) -> DiagnosticTarget { DiagnosticTarget(kind: .directory, path: path.isEmpty ? "." : path) }
    static func symbol(_ path: String, _ name: String, line: Int?) -> DiagnosticTarget {
        DiagnosticTarget(kind: .symbol, path: path, symbol: name, line: line)
    }
}
