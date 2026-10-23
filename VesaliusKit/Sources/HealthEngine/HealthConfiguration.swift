import Foundation

/// Every threshold the health engine uses. Defaults are tuned for typical application repositories;
/// test files get `testMultiplier`× the size thresholds and are never reported as unused.
public struct HealthConfiguration: Sendable, Hashable {
    // MARK: Size

    /// Code lines at which a file is "large" (medium severity).
    public var largeFileLines: Int = 400
    /// Code lines at which a file is "very large" (high severity).
    public var veryLargeFileLines: Int = 800
    /// Code lines at which a file is "huge" (critical severity).
    public var hugeFileLines: Int = 1_500
    /// Multiplier applied to size thresholds for test files.
    public var testMultiplier: Double = 2.0
    /// Lines at which a type is considered a possible god object.
    public var largeTypeLines: Int = 500
    /// Members (including same-name extensions) at which a type is considered a possible god object.
    public var largeTypeMembers: Int = 40
    /// Lines at which a function/method is "long".
    public var longFunctionLines: Int = 80
    /// Cyclomatic complexity at which a function/method is "complex".
    public var complexFunction: Int = 20
    /// Keep only the worst N long/complex functions.
    public var maxLongFunctionDiagnostics: Int = 60
    /// Code lines at which a View/ViewController/ViewModel/Component/Screen/Page file is "massive".
    public var massiveUIFileLines: Int = 300

    // MARK: Coupling

    /// Minimum fan-out threshold; the effective threshold is max(this, the repository's 95th percentile).
    public var highFanOut: Int = 15
    /// Fan-out at which severity becomes high.
    public var veryHighFanOut: Int = 30
    /// Minimum fan-in threshold for hub files; effective threshold is max(this, the 95th percentile).
    public var highFanIn: Int = 20
    /// Percentile used for adaptive fan-in/fan-out thresholds.
    public var fanPercentile: Double = 0.95
    /// Edges required in each direction before a bidirectional area pair is reported.
    public var tightCouplingMinEdges: Int = 1
    /// Code files a directory needs before cohesion is judged.
    public var lowCohesionMinFiles: Int = 4
    /// Share of a directory's dependency edges that must stay inside it.
    public var lowCohesionThreshold: Double = 0.2

    // MARK: Cycles and chains

    /// Dependency hops in the longest chain before it is reported (medium).
    public var deepChainLength: Int = 8
    /// Dependency hops at which a deep chain becomes high severity.
    public var veryDeepChainLength: Int = 12
    /// Maximum dependency-cycle diagnostics (largest cycles first).
    public var maxCycleDiagnostics: Int = 50

    // MARK: Structure and concerns

    /// Distinct concerns (UI, networking, persistence, …) before a file is "mixed".
    public var mixedConcernsMin: Int = 3
    /// Code lines a file needs before mixed concerns are reported.
    public var mixedConcernsMinLines: Int = 60
    /// Files in a utility directory before it is reported as a dumping ground.
    public var dumpingGroundMinFiles: Int = 12
    /// Top-level symbols in a utility file before it is reported as a dumping ground.
    public var dumpingGroundMinSymbols: Int = 25
    /// Fan-in of a utility file before it is reported as a dumping ground.
    public var dumpingGroundFanIn: Int = 15
    /// Unrelated areas a feature word must appear in before it is reported as scattered.
    public var scatteredFeatureMinAreas: Int = 4

    // MARK: Duplication

    /// Minimum lines for a function body to take part in duplicate detection.
    public var duplicateMinLines: Int = 6

    // MARK: Extraction suggestions

    /// Minimum code files in an extraction candidate.
    public var extractionMinFiles: Int = 4
    /// Minimum cohesion (internal edge share) of an extraction candidate.
    public var extractionMinCohesion: Double = 0.35
    /// Candidates larger than this share of the code are not "extractions" but the whole app.
    public var extractionMaxShare: Double = 0.6
    /// Maximum extraction suggestions.
    public var maxSuggestions: Int = 8

    // MARK: Output

    /// Maximum diagnostics returned (most severe kept).
    public var maxDiagnostics: Int = 400
    /// Maximum unused files diagnostics (all of them remain in the unused report).
    public var maxUnusedFileDiagnostics: Int = 60
    /// Maximum per-file unused-symbol diagnostics.
    public var maxUnusedSymbolDiagnostics: Int = 80

    public init() {}

    public static let `default` = HealthConfiguration()
}
