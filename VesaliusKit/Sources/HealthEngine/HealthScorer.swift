import Foundation
import VesaliusCore

/// Turns findings into eight category scores. Every category starts at 100 and loses points through
/// explicit, size-normalised factors; each factor records the measurement behind it so the score can be
/// explained. The overall score is the weighted mean of the category scores.
///
/// Weights: coupling 1.2, complexity 1.2, cycles 1.0, modularity 1.0, boundaries 1.0,
/// maintainability 1.0, organization 0.8, dead code 0.6.
enum HealthScorer {
    static let weights: [HealthCategory: Double] = [
        .modularity: 1.0, .coupling: 1.2, .complexity: 1.2, .cycles: 1.0,
        .organization: 0.8, .boundaries: 1.0, .maintainability: 1.0, .deadCode: 0.6,
    ]

    private struct Builder {
        let category: HealthCategory
        var factors: [ScoreFactor] = []
        var notes: [String] = []

        /// Records a deduction (positive `points` are subtracted), clamped to `cap`.
        mutating func deduct(_ label: String, _ detail: String, points: Double, cap: Double, value: Double? = nil) {
            let applied = min(cap, max(0, points))
            let impact = Format.points(applied)
            factors.append(ScoreFactor(label: label, detail: detail, impact: impact == 0 ? 0 : -impact, value: value.map { ($0 * 1000).rounded() / 1000 }))
        }

        /// Records a neutral observation (no deduction).
        mutating func observe(_ label: String, _ detail: String, value: Double? = nil) {
            factors.append(ScoreFactor(label: label, detail: detail, impact: 0, value: value.map { ($0 * 1000).rounded() / 1000 }))
        }

        func score() -> Int {
            let total = factors.reduce(0.0) { $0 + $1.impact }
            return Int(max(0, min(100, (100 + total).rounded())))
        }
    }

    static func score(_ ctx: HealthContext, _ f: HealthFindings, diagnostics: [Diagnostic]) -> HealthReport {
        let files = max(1, ctx.sourceFiles.count)
        let lines = max(1, ctx.totalSourceLines)
        let kloc = Double(lines) / 1000
        var categories: [CategoryScore] = []

        // Modularity
        var modularity = Builder(category: .modularity)
        if f.sourceAreaCount >= 2, f.totalSourcePairs > 0 {
            let share = Double(f.crossAreaPairs) / Double(f.totalSourcePairs)
            let points = max(0, share - 0.6) * 50
            if points > 0 {
                modularity.deduct("Cross-area dependencies", "\(Format.percent(share)) of \(Format.count(f.totalSourcePairs)) file dependencies cross between \(f.sourceAreaCount) areas (features depending on shared code is normal; above 60% little stays local).", points: points, cap: 20, value: share)
            } else {
                modularity.observe("Cross-area dependencies", "\(Format.percent(share)) of file dependencies cross area boundaries, within the expected range.", value: share)
            }
            if f.sourceAreaCount >= 4 {
                let possible = f.sourceAreaCount * (f.sourceAreaCount - 1)
                let density = Double(f.connectedOrderedAreaPairs) / Double(possible)
                let densityPoints = max(0, density - 0.35) * 60
                if densityPoints > 0 {
                    modularity.deduct("Area coupling density", "\(f.connectedOrderedAreaPairs) of \(possible) possible area-to-area dependencies exist (\(Format.percent(density)); 35% or less keeps areas independent).", points: densityPoints, cap: 25, value: density)
                } else {
                    modularity.observe("Area coupling density", "Areas depend on \(Format.percent(density)) of the other areas they could reach.", value: density)
                }
            }
        } else {
            modularity.observe("Areas", "The code forms a single area, so cross-area coupling does not apply.")
        }
        if let cohesion = f.clusterCohesion {
            let points = max(0, 0.5 - cohesion) * 40
            if points > 0 {
                modularity.deduct("Cluster cohesion", "Dependency clusters keep \(Format.percent(cohesion)) of their edges internal on average (50%+ indicates well-separated modules).", points: points, cap: 20, value: cohesion)
            } else {
                modularity.observe("Cluster cohesion", "Dependency clusters keep \(Format.percent(cohesion)) of their edges internal.", value: cohesion)
            }
        }
        if f.lowCohesionDirectories > 0 {
            let share = Double(f.lowCohesionDirectories) / Double(max(1, f.sourceAreaCount))
            modularity.deduct("Loosely related folders", "\(Format.plural(f.lowCohesionDirectories, "folder")) \(Format.verb(f.lowCohesionDirectories, "groups", "group")) files that mostly depend on other folders.", points: 3 * Double(f.lowCohesionDirectories), cap: 15, value: share)
        }
        categories.append(finish(modularity, summary: modularitySummary(modularity, f)))

        // Coupling
        var coupling = Builder(category: .coupling)
        let avgFanOut = Double(ctx.sourceFiles.reduce(0) { $0 + ctx.metric($1.id).fanOut }) / Double(files)
        if avgFanOut > 5 {
            coupling.deduct("Average fan-out", String(format: "Files depend on %.1f other files on average (5 or fewer is comfortable).", avgFanOut), points: (avgFanOut - 5) * 3, cap: 25, value: avgFanOut)
        } else {
            coupling.observe("Average fan-out", String(format: "Files depend on %.1f other files on average.", avgFanOut), value: avgFanOut)
        }
        if f.highFanOutFiles > 0 {
            let share = Double(f.highFanOutFiles) / Double(files)
            coupling.deduct("High fan-out files", "\(Format.plural(f.highFanOutFiles, "file")) (\(Format.percent(share))) \(Format.verb(f.highFanOutFiles, "depends", "depend")) on more than \(ctx.fanOutThreshold) files.", points: max(2, share * 150), cap: 25, value: share)
        }
        if f.heavyHubFiles > 0 {
            let share = Double(f.heavyHubFiles) / Double(files)
            coupling.deduct("Critical hubs", "\(Format.plural(f.heavyHubFiles, "hub file")) \(Format.verb(f.heavyHubFiles, "reaches", "reach")) half or more of the codebase through their dependents.", points: max(3, share * 100), cap: 15, value: share)
        } else if f.hubFiles > 0 {
            coupling.observe("Hub files", "\(Format.plural(f.hubFiles, "file")) \(Format.verb(f.hubFiles, "has", "have")) high fan-in but a contained blast radius.")
        }
        if f.heavyTightPairs > 0 {
            let share = Double(f.heavyTightPairs) / Double(max(1, f.sourceAreaCount))
            coupling.deduct("Tightly coupled areas", "\(Format.plural(f.heavyTightPairs, "pair")) of areas \(Format.verb(f.heavyTightPairs, "depends", "depend")) on each other with 3+ dependencies in each direction.", points: max(4, share * 25), cap: 20, value: share)
        }
        if f.longestChain > ctx.config.deepChainLength {
            coupling.deduct("Dependency depth", "The longest dependency chain is \(f.longestChain) levels deep (threshold \(ctx.config.deepChainLength)).", points: Double(f.longestChain - ctx.config.deepChainLength) * 1.5, cap: 10, value: Double(f.longestChain))
        }
        categories.append(finish(coupling, summary: couplingSummary(coupling, avgFanOut: avgFanOut, f)))

        // Complexity
        var complexity = Builder(category: .complexity)
        let largeShare = Double(f.largeFileLines) / Double(lines)
        if f.largeFileLines > 0 {
            complexity.deduct("Code in large files", "\(Format.percent(largeShare)) of code lines live in \(Format.plural(f.largeFileIDs.count, "large file")).", points: largeShare * 50, cap: 40, value: largeShare)
        } else {
            complexity.observe("Code in large files", "No source file exceeds \(ctx.config.largeFileLines) code lines.")
        }
        if f.largeTypeCount > 0 {
            let share = Double(f.largeTypeLines) / Double(lines)
            complexity.deduct("Large types", "\(Format.plural(f.largeTypeCount, "type")) \(Format.verb(f.largeTypeCount, "exceeds", "exceed")) \(ctx.config.largeTypeLines) lines or \(ctx.config.largeTypeMembers) members (\(Format.percent(share)) of code).", points: max(3, share * 30), cap: 20, value: share)
        }
        if f.longFunctionCount > 0 {
            let density = Double(f.longFunctionCount) / max(1, kloc)
            complexity.deduct("Long or complex functions", String(format: "%@ (%.1f per 1,000 lines).", Format.plural(f.longFunctionCount, "function"), density), points: density * 6, cap: 25, value: density)
        }
        if f.callableCount > 0 {
            let average = Double(f.callableComplexityTotal) / Double(f.callableCount)
            if average > 4 {
                complexity.deduct("Average function complexity", String(format: "Functions average a cyclomatic complexity of %.1f (4 or less is typical).", average), points: (average - 4) * 3, cap: 15, value: average)
            } else {
                complexity.observe("Average function complexity", String(format: "Functions average a cyclomatic complexity of %.1f.", average), value: average)
            }
        }
        categories.append(finish(complexity, summary: complexity.factors.contains { $0.impact < 0 } ? "Size and branching are concentrated in a few places." : "Files, types and functions are comfortably sized."))

        // Cycles
        var cycles = Builder(category: .cycles)
        if f.cycleCount == 0 {
            cycles.observe("Dependency cycles", "No circular dependencies between files.")
        } else {
            if f.filesInCycles > 0 {
                let share = Double(f.filesInCycles) / Double(files)
                cycles.deduct("Files in import cycles", "\(Format.plural(f.filesInCycles, "file")) (\(Format.percent(share))) \(Format.verb(f.filesInCycles, "takes", "take")) part in dependency cycles.", points: share * 120, cap: 60, value: share)
            }
            if f.softCycleFiles > 0 {
                let share = Double(f.softCycleFiles) / Double(files)
                cycles.deduct("Interconnected files", "\(Format.plural(f.softCycleFiles, "file")) (\(Format.percent(share))) reference each other in loops that no import closes.", points: share * 45, cap: 25, value: share)
            }
            cycles.deduct("Cycle count", "\(Format.plural(f.cycleCount, "separate cycle")).", points: Double(f.cycleCount) * 1.5, cap: 12, value: Double(f.cycleCount))
            if f.largestCycle > 2 {
                cycles.deduct("Largest import cycle", "The largest import cycle spans \(f.largestCycle) files.", points: Double(f.largestCycle - 2) * 2, cap: 20, value: Double(f.largestCycle))
            }
        }
        categories.append(finish(cycles, summary: f.cycleCount == 0 ? "No circular dependencies detected." : "\(Format.plural(f.cycleCount, "loop")) involving \(Format.plural(f.filesInCycles + f.softCycleFiles, "file"))\(f.filesInCycles == 0 ? ", none of them closed by imports" : "")."))

        // Organization
        var organization = Builder(category: .organization)
        if f.dumpingGrounds > 0 {
            organization.deduct("Utility dumping grounds", "\(Format.plural(f.dumpingGrounds, "catch-all helper file or folder", "catch-all helper files or folders")) without a clear theme.", points: Double(f.dumpingGrounds) * 5, cap: 20, value: Double(f.dumpingGrounds))
        }
        if f.scatteredFeatures > 0 {
            organization.deduct("Scattered features", "\(Format.plural(f.scatteredFeatures, "feature name")) \(Format.verb(f.scatteredFeatures, "appears", "appear")) across \(ctx.config.scatteredFeatureMinAreas)+ unrelated areas.", points: Double(f.scatteredFeatures) * 3, cap: 15, value: Double(f.scatteredFeatures))
        }
        if files >= 20 {
            let rootShare = Double(f.rootSourceFiles) / Double(files)
            if rootShare > 0.1 {
                organization.deduct("Root clutter", "\(Format.plural(f.rootSourceFiles, "source file")) (\(Format.percent(rootShare))) \(Format.verb(f.rootSourceFiles, "sits", "sit")) directly in the repository root.", points: (rootShare - 0.1) * 50, cap: 15, value: rootShare)
            }
        }
        if f.oversizedDirectories > 0 {
            organization.deduct("Oversized folders", "\(Format.plural(f.oversizedDirectories, "folder")) \(Format.verb(f.oversizedDirectories, "holds", "hold")) more than 60 source files directly.", points: Double(f.oversizedDirectories) * 3, cap: 10, value: Double(f.oversizedDirectories))
        }
        if organization.factors.isEmpty {
            organization.observe("Structure", "No dumping grounds, scattered features or root clutter detected.")
        }
        categories.append(finish(organization, summary: organization.factors.contains { $0.impact < 0 } ? "Some code lacks a clear home in the directory structure." : "Directory structure is tidy."))

        // Boundaries
        var boundaries = Builder(category: .boundaries)
        if f.layeredPairs > 0 {
            let share = Double(f.layerViolationPairs) / Double(f.layeredPairs)
            if f.layerViolationPairs > 0 {
                boundaries.deduct("Layer violations", "\(Format.plural(f.layerViolationPairs, "dependency", "dependencies")) from lower layers \(Format.verb(f.layerViolationPairs, "points", "point")) up into presentation (\(Format.percent(share)) of layer-to-layer dependencies, \(Format.plural(f.violatingFiles, "file"))).", points: share * 150 + Double(min(10, f.violatingFiles)), cap: 40, value: share)
            } else {
                boundaries.observe("Layer direction", "All \(Format.count(f.layeredPairs)) dependencies between recognised layers point in the expected direction.")
            }
        }
        if f.connectedAreaPairs > 0 {
            let share = Double(f.bidirectionalAreaPairs) / Double(f.connectedAreaPairs)
            if f.bidirectionalAreaPairs > 0 {
                boundaries.deduct("Bidirectional areas", "\(Format.plural(f.bidirectionalAreaPairs, "of \(f.connectedAreaPairs) connected area pairs", "of \(f.connectedAreaPairs) connected area pairs")) \(Format.verb(f.bidirectionalAreaPairs, "depends", "depend")) on each other in both directions.", points: share * 50, cap: 30, value: share)
            } else {
                boundaries.observe("Area direction", "Dependencies between areas flow in one direction.")
            }
        }
        if boundaries.factors.isEmpty {
            boundaries.observe("Boundaries", "No recognisable layers or cross-area dependencies to check.")
        }
        categories.append(finish(boundaries, summary: boundaries.factors.contains { $0.impact < 0 } ? "Some dependencies cross boundaries in the wrong direction." : "Dependencies respect layer and area boundaries."))

        // Maintainability
        var maintainability = Builder(category: .maintainability)
        if f.duplicateGroups > 0 {
            let share = Double(f.duplicateExtraLines) / Double(lines)
            maintainability.deduct("Duplicated code", "\(Format.plural(f.duplicateGroups, "group")) of structurally identical functions (\(Format.count(f.duplicateExtraLines)) duplicated lines, \(Format.percent(share)) of code).", points: max(2, share * 200), cap: 30, value: share)
        }
        if f.massiveUIFileCount > 0 {
            let share = Double(f.massiveUIFileCount) / Double(max(1, f.uiFileCount))
            maintainability.deduct("Massive UI files", "\(Format.plural(f.massiveUIFileCount, "of \(f.uiFileCount) UI files", "of \(f.uiFileCount) UI files")) \(Format.verb(f.massiveUIFileCount, "exceeds", "exceed")) \(ctx.config.massiveUIFileLines) code lines.", points: max(3, share * 40), cap: 20, value: share)
        }
        if f.mixedConcernFiles > 0 {
            let share = Double(f.mixedConcernFiles) / Double(files)
            maintainability.deduct("Mixed responsibilities", "\(Format.plural(f.mixedConcernFiles, "file")) \(Format.verb(f.mixedConcernFiles, "combines", "combine")) \(ctx.config.mixedConcernsMin)+ concerns such as UI, networking and persistence.", points: max(2, share * 100), cap: 20, value: share)
        }
        if maintainability.factors.isEmpty {
            maintainability.observe("Maintainability", "No duplication, oversized UI files or mixed responsibilities detected.")
        }
        categories.append(finish(maintainability, summary: maintainability.factors.contains { $0.impact < 0 } ? "Duplication and overloaded files add maintenance cost." : "Code is free of duplication and overloaded files."))

        // Dead code
        var dead = Builder(category: .deadCode)
        if f.unusedFiles > 0 {
            let share = Double(f.unusedFiles) / Double(files)
            dead.deduct("Unreferenced files", "\(Format.plural(f.unusedFiles, "source file")) (\(Format.percent(share))) \(Format.verb(f.unusedFiles, "has", "have")) no detected references.", points: share * 150, cap: 50, value: share)
        }
        if f.unusedSymbols > 0, f.unusedCandidateSymbols > 0 {
            let share = Double(f.unusedSymbols) / Double(f.unusedCandidateSymbols)
            dead.deduct("Unreferenced declarations", "\(Format.plural(f.unusedSymbols, "of \(f.unusedCandidateSymbols) non-public declarations", "of \(f.unusedCandidateSymbols) non-public declarations")) (\(Format.percent(share))) \(Format.verb(f.unusedSymbols, "is", "are")) never referenced.", points: share * 100, cap: 40, value: share)
        }
        if dead.factors.isEmpty {
            dead.observe("Dead code", "No unreferenced files or declarations detected.")
        }
        categories.append(finish(dead, summary: dead.factors.contains { $0.impact < 0 } ? "Some code has no detected references." : "No dead-code signals."))

        // Overall.
        let totalWeight = categories.reduce(0) { $0 + $1.weight }
        let weighted = categories.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        let overall = ctx.sourceFiles.isEmpty ? 100 : Int((weighted / max(totalWeight, 0.001)).rounded())
        var counts: [String: Int] = [:]
        for severity in Severity.allCases { counts[severity.rawValue] = 0 }
        for diagnostic in diagnostics { counts[diagnostic.severity.rawValue, default: 0] += 1 }

        let ranked = categories.sorted { $0.score == $1.score ? $0.category.rawValue < $1.category.rawValue : $0.score > $1.score }
        let grade = HealthReport.grade(for: overall)
        var summary: String
        if ctx.sourceFiles.isEmpty {
            summary = "No source files to analyse yet."
        } else if let best = ranked.first, let worst = ranked.last, best.score != worst.score {
            summary = "Overall health \(overall)/100 (\(grade)). Strongest: \(best.category.displayName) (\(best.score)); weakest: \(worst.category.displayName) (\(worst.score))."
        } else {
            summary = "Overall health \(overall)/100 (\(grade)); all categories score \(ranked.first?.score ?? 100)."
        }
        let serious = (counts["critical"] ?? 0) + (counts["high"] ?? 0)
        if serious > 0 {
            summary += " \(Format.plural(serious, "high-severity finding")) \(Format.verb(serious, "deserves", "deserve")) attention first."
        }
        return HealthReport(score: overall, grade: grade, summary: summary, categories: categories, diagnosticCounts: counts)
    }

    private static func finish(_ builder: Builder, summary: String) -> CategoryScore {
        CategoryScore(
            category: builder.category,
            score: builder.score(),
            weight: weights[builder.category] ?? 1,
            summary: summary,
            factors: builder.factors
        )
    }

    private static func modularitySummary(_ builder: Builder, _ f: HealthFindings) -> String {
        if builder.factors.contains(where: { $0.impact < 0 }) {
            return "Dependencies cross area boundaries more than they stay within them."
        }
        return "Code separates into cohesive groups with contained cross-group dependencies."
    }

    private static func couplingSummary(_ builder: Builder, avgFanOut: Double, _ f: HealthFindings) -> String {
        if builder.factors.contains(where: { $0.impact < 0 }) {
            return String(format: "Average fan-out %.1f; %@ and %@ concentrate dependencies.", avgFanOut, Format.plural(f.highFanOutFiles, "high fan-out file"), Format.plural(f.hubFiles, "hub"))
        }
        return String(format: "Dependencies are evenly spread (average fan-out %.1f).", avgFanOut)
    }
}
