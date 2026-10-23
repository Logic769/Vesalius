import Foundation
import VesaliusCore

/// Diagnostics plus the aggregate measurements the scorer needs. Filled by the rules.
struct HealthFindings {
    var drafts: [DiagnosticDraft] = []

    // Complexity
    var largeFileIDs: Set<Int64> = []
    var largeFileLines = 0
    var largeTypeCount = 0
    var largeTypeLines = 0
    var longFunctionCount = 0
    var callableCount = 0
    var callableComplexityTotal = 0

    // Maintainability
    var uiFileCount = 0
    var massiveUIFileCount = 0
    var duplicateGroups = 0
    var duplicateExtraLines = 0
    var mixedConcernFiles = 0

    // Coupling
    var highFanOutFiles = 0
    var hubFiles = 0
    var heavyHubFiles = 0
    var heavyTightPairs = 0

    // Boundaries
    var bidirectionalAreaPairs = 0
    var connectedAreaPairs = 0
    var layerViolationPairs = 0
    var layeredPairs = 0
    var violatingFiles = 0

    // Modularity
    var crossAreaPairs = 0
    var totalSourcePairs = 0
    var sourceAreaCount = 0
    var connectedOrderedAreaPairs = 0
    var lowCohesionDirectories = 0
    var clusterCohesion: Double?
    var clusterCount = 0

    // Cycles
    var cycleCount = 0
    var filesInCycles = 0
    /// Files in loops that only exist through Swift's import-free visibility inside one module.
    var softCycleFiles = 0
    var largestCycle = 0
    var longestChain = 0

    // Organization
    var dumpingGrounds = 0
    var scatteredFeatures = 0
    var rootSourceFiles = 0
    var oversizedDirectories = 0

    // Dead code
    var unusedFiles = 0
    var unusedSymbols = 0
    var unusedCandidateSymbols = 0
}
