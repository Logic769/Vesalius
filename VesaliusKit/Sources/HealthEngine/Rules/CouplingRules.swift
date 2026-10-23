import Foundation
import VesaliusCore

/// "high-fan-out", "high-fan-in", "tight-coupling", "low-cohesion-directory" and modularity measures.
enum CouplingRules {
    static func run(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        fanOut(ctx, &findings)
        fanIn(ctx, &findings)
        bidirectional(ctx, &findings)
        cohesion(ctx, &findings)
        modularity(ctx, &findings)
    }

    // MARK: Fan-out

    private static func fanOut(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        let threshold = ctx.fanOutThreshold
        for file in ctx.sourceFiles {
            let metrics = ctx.metric(file.id)
            guard metrics.fanOut > threshold else { continue }
            findings.highFanOutFiles += 1
            let severity: Severity = metrics.fanOut >= max(ctx.config.veryHighFanOut, threshold * 2) ? .high : .medium
            var byArea: [String: Int] = [:]
            for target in ctx.outgoing[file.id] ?? [] {
                byArea[ctx.areaName(of: target), default: 0] += 1
            }
            let spread = byArea.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let spreadText = spread.prefix(4).map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            let percentile = Int(ctx.config.fanPercentile * 100)
            findings.drafts.append(DiagnosticDraft(
                rule: "high-fan-out",
                category: .coupling,
                severity: severity,
                title: "High fan-out: \(file.fileName)",
                summary: "\(file.fileName) depends on \(Format.plural(metrics.fanOut, "file"))\(spread.count > 1 ? " across \(spread.count) areas" : "").",
                reason: "Fan-out \(metrics.fanOut) exceeds the threshold of \(threshold) (the larger of \(ctx.config.highFanOut) and the repository's \(percentile)th percentile). A file that depends on this much breaks whenever any of its dependencies change\(spreadText.isEmpty ? "" : "; its dependencies are spread over \(spreadText)").",
                recommendation: spread.count >= 3
                    ? "It coordinates many parts of the system. Split it by area or introduce narrow facades so it depends on a few interfaces instead of \(metrics.fanOut) concrete files."
                    : "Group the dependencies it uses together and move each group behind a smaller interface, or split the file by the subsets of dependencies its parts need.",
                targets: [.file(file.path)],
                metrics: [
                    DiagnosticMetric(name: "fan-out", value: Double(metrics.fanOut), threshold: Double(threshold), unit: "files"),
                    DiagnosticMetric(name: "transitive dependencies", value: Double(metrics.transitiveDependencies), unit: "files"),
                    DiagnosticMetric(name: "areas", value: Double(spread.count)),
                ],
                rank: Double(metrics.fanOut) / Double(max(1, threshold))
            ))
        }
    }

    // MARK: Fan-in

    private static func fanIn(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        let threshold = ctx.fanInThreshold
        let total = max(1, ctx.sourceFiles.count)
        for file in ctx.sourceFiles {
            let metrics = ctx.metric(file.id)
            guard metrics.fanIn > threshold else { continue }
            findings.hubFiles += 1
            let share = Double(metrics.transitiveDependents) / Double(total)
            if share >= 0.5 { findings.heavyHubFiles += 1 }
            let severity: Severity = share >= 0.5 ? .medium : (share >= 0.25 ? .low : .info)
            let layer = ctx.layerOfFile[file.id]
            let expected = layer == "Models" || layer == "Utilities" || file.stem.lowercased().contains("constant") || file.stem.lowercased().hasSuffix("types")
            findings.drafts.append(DiagnosticDraft(
                rule: "high-fan-in",
                category: .coupling,
                severity: severity,
                title: "Hub file: \(file.fileName)",
                summary: "\(file.fileName) is used directly by \(Format.plural(metrics.fanIn, "file")) and transitively by \(Format.count(metrics.transitiveDependents)) (\(Format.percent(share)) of source files).",
                reason: "Fan-in \(metrics.fanIn) exceeds the threshold of \(threshold). Every change to this file can ripple to \(Format.percent(share)) of the codebase, which makes it a critical file to change carefully\(expected ? "; as a shared \(layer?.lowercased() ?? "definitions") file this is partly expected" : "").",
                recommendation: "Keep its public surface small and stable, cover it with tests, and split unrelated responsibilities into separate files so each change reaches fewer dependents.",
                targets: [.file(file.path)],
                metrics: [
                    DiagnosticMetric(name: "fan-in", value: Double(metrics.fanIn), threshold: Double(threshold), unit: "files"),
                    DiagnosticMetric(name: "transitive dependents", value: Double(metrics.transitiveDependents), unit: "files"),
                    DiagnosticMetric(name: "share of codebase", value: (share * 1000).rounded() / 1000, threshold: 0.5),
                    DiagnosticMetric(name: "centrality", value: (metrics.centrality * 1000).rounded() / 1000),
                ],
                rank: share
            ))
        }
    }

    // MARK: Bidirectional areas / modules

    private static func bidirectional(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        // Areas (integer-indexed hot loop).
        let areaCount = ctx.areas.areas.count
        let areaDrafts = bidirectionalDrafts(
            ctx,
            groupCount: areaCount,
            group: { ctx.areaIndex(of: $0) },
            name: { ctx.areas.name(at: $0) },
            target: { DiagnosticTarget.directory(ctx.areas.areas[$0]) },
            kind: "area",
            findings: &findings,
            countStats: true
        )
        findings.drafts += areaDrafts

        // Modules, when they differ from areas.
        let moduleRoots = Dictionary(ctx.snapshot.modules.map { ($0.name, $0.rootPath) }, uniquingKeysWith: { first, _ in first })
        let modulesInUse = Set(ctx.sourceFiles.compactMap(\.module)).sorted()
        let areaSet = Set(ctx.areas.areas)
        guard modulesInUse.count >= 2, !modulesInUse.allSatisfy({ areaSet.contains(moduleRoots[$0] ?? "\u{0}") }) else { return }
        var moduleIndex: [String: Int] = [:]
        for (index, module) in modulesInUse.enumerated() { moduleIndex[module] = index }
        var discard = HealthFindings()
        let moduleDrafts = bidirectionalDrafts(
            ctx,
            groupCount: modulesInUse.count,
            group: { ctx.file($0)?.module.flatMap { moduleIndex[$0] } ?? -1 },
            name: { modulesInUse[$0] },
            target: { DiagnosticTarget(kind: .module, path: moduleRoots[modulesInUse[$0]] ?? modulesInUse[$0]) },
            kind: "module",
            findings: &discard,
            countStats: false
        )
        let existing = Set(findings.drafts.map { $0.build().id })
        for draft in moduleDrafts where !existing.contains(draft.build().id) {
            // Skip module pairs whose roots are exactly an already-reported area pair.
            if draft.targets.allSatisfy({ areaSet.contains($0.path) }) { continue }
            findings.drafts.append(draft)
        }
    }

    private static func bidirectionalDrafts(
        _ ctx: HealthContext,
        groupCount: Int,
        group: (Int64) -> Int,
        name: (Int) -> String,
        target: (Int) -> DiagnosticTarget,
        kind: String,
        findings: inout HealthFindings,
        countStats: Bool
    ) -> [DiagnosticDraft] {
        guard groupCount >= 2 else { return [] }
        var counts: [Int: Int] = [:]
        var examples: [Int: [String]] = [:]
        for entry in ctx.pairs where ctx.sourceIDs.contains(entry.pair.source) && ctx.sourceIDs.contains(entry.pair.target) {
            let a = group(entry.pair.source), b = group(entry.pair.target)
            guard a >= 0, b >= 0, a != b else { continue }
            let key = a * groupCount + b
            counts[key, default: 0] += 1
            if (examples[key]?.count ?? 0) < 3 {
                examples[key, default: []].append("\(ctx.path(entry.pair.source)) → \(ctx.path(entry.pair.target))")
            }
        }
        if countStats {
            var connected = Set<Int>()
            for key in counts.keys {
                let a = key / groupCount, b = key % groupCount
                connected.insert(min(a, b) * groupCount + max(a, b))
            }
            findings.connectedAreaPairs = connected.count
        }
        var drafts: [DiagnosticDraft] = []
        let minimum = ctx.config.tightCouplingMinEdges
        for key in counts.keys.sorted() {
            let a = key / groupCount, b = key % groupCount
            guard a < b else { continue }
            let forward = counts[key] ?? 0
            let backward = counts[b * groupCount + a] ?? 0
            guard forward >= minimum, backward >= minimum else { continue }
            // Orient so `from` is the side with more outgoing edges (the "natural" direction).
            let (from, to, fwd, bwd) = forward >= backward ? (a, b, forward, backward) : (b, a, backward, forward)
            let weaker = min(fwd, bwd)
            if countStats {
                findings.bidirectionalAreaPairs += 1
                if weaker >= 3 { findings.heavyTightPairs += 1 }
            }
            let severity: Severity = weaker >= 10 ? .high : (weaker >= 3 ? .medium : .low)
            let back = examples[to * groupCount + from] ?? []
            let fromName = name(from), toName = name(to)
            drafts.append(DiagnosticDraft(
                rule: "tight-coupling",
                category: .coupling,
                severity: severity,
                title: "Bidirectional dependency: \(fromName) ↔ \(toName)",
                summary: "\(fromName) depends on \(toName) through \(Format.plural(fwd, "file dependency", "file dependencies")), and \(toName) depends back on \(fromName) through \(Format.count(bwd)).",
                reason: "Dependencies run in both directions between these \(kind)s (\(fwd) one way, \(bwd) back), so neither can be understood, tested or extracted without the other\(back.isEmpty ? "" : ". Back-references include \(Format.list(back, limit: 2))").",
                recommendation: "Decide which direction is intended (usually feature → shared). Move the \(Format.plural(bwd, "back-reference")) behind an interface owned by \(toName), or move the code both sides need into a lower-level shared \(kind).",
                targets: [target(from), target(to)],
                metrics: [
                    DiagnosticMetric(name: "\(fromName) → \(toName)", value: Double(fwd), unit: "dependencies"),
                    DiagnosticMetric(name: "\(toName) → \(fromName)", value: Double(bwd), threshold: Double(minimum), unit: "dependencies"),
                ],
                rank: Double(weaker)
            ))
        }
        return drafts
    }

    // MARK: Directory cohesion

    private static func cohesion(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        let directoryCount = ctx.directoryPaths.count
        guard directoryCount > 0 else { return }
        var filesPerDirectory = Array(repeating: 0, count: directoryCount)
        for file in ctx.sourceFiles {
            let index = ctx.directoryIndex(of: file.id)
            if index >= 0 { filesPerDirectory[index] += 1 }
        }
        var internalCount = Array(repeating: 0, count: directoryCount)
        var externalCount = Array(repeating: 0, count: directoryCount)
        var externalByDirectory: [Int: [Int: Int]] = [:]
        for entry in ctx.pairs where ctx.sourceIDs.contains(entry.pair.source) && ctx.sourceIDs.contains(entry.pair.target) {
            let s = ctx.directoryIndex(of: entry.pair.source), t = ctx.directoryIndex(of: entry.pair.target)
            guard s >= 0, t >= 0 else { continue }
            if s == t {
                internalCount[s] += 1
            } else {
                externalCount[s] += 1
                externalCount[t] += 1
                if filesPerDirectory[s] >= ctx.config.lowCohesionMinFiles { externalByDirectory[s, default: [:]][t, default: 0] += 1 }
                if filesPerDirectory[t] >= ctx.config.lowCohesionMinFiles { externalByDirectory[t, default: [:]][s, default: 0] += 1 }
            }
        }
        for index in 0..<directoryCount where filesPerDirectory[index] >= ctx.config.lowCohesionMinFiles {
            let directory = ctx.directoryPaths[index]
            let count = filesPerDirectory[index]
            let last = (directory.split(separator: "/").last.map(String.init) ?? "").lowercased()
            guard !directory.isEmpty,
                  !Catalog.layerDirectoryNames.contains(last),
                  !Catalog.utilityNames.contains(last),
                  !Catalog.containerNames.contains(last) else { continue }
            let inside = internalCount[index]
            let outside = externalCount[index]
            let total = inside + outside
            guard total >= 6 else { continue }
            let cohesion = Double(inside) / Double(total)
            guard cohesion < ctx.config.lowCohesionThreshold else { continue }
            let partnerCounts: [Int: Int] = externalByDirectory[index] ?? [:]
            var partners: [(path: String, count: Int)] = []
            for (partner, edgeCount) in partnerCounts {
                partners.append((path: ctx.directoryPaths[partner], count: edgeCount))
            }
            partners.sort { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.path < rhs.path
            }
            guard let strongest = partners.first, strongest.count >= 3, strongest.count >= 2 * inside else { continue }
            findings.lowCohesionDirectories += 1
            let partnerText = partners.prefix(2).map { "\($0.path.isEmpty ? "(root)" : $0.path) (\($0.count))" }.joined(separator: " and ")
            findings.drafts.append(DiagnosticDraft(
                rule: "low-cohesion-directory",
                category: .modularity,
                severity: .low,
                title: "Loosely related folder: \(directory.split(separator: "/").last.map(String.init) ?? directory)",
                summary: "Only \(inside) of the \(total) dependencies touching \(directory)/ stay inside it.",
                reason: "\(Format.percent(cohesion)) of the dependency edges of this \(count)-file folder are internal (threshold \(Format.percent(ctx.config.lowCohesionThreshold))); its files mostly connect to \(partnerText), so the folder groups files that do not work together.",
                recommendation: "Check whether the folder groups files by a shared name rather than a shared purpose. Files that mainly work with \(strongest.path.isEmpty ? "the root" : strongest.path) may belong there, or the folder can be split into cohesive sub-folders.",
                targets: [.directory(directory)],
                metrics: [
                    DiagnosticMetric(name: "cohesion", value: (cohesion * 1000).rounded() / 1000, threshold: ctx.config.lowCohesionThreshold),
                    DiagnosticMetric(name: "internal dependencies", value: Double(inside)),
                    DiagnosticMetric(name: "external dependencies", value: Double(outside)),
                    DiagnosticMetric(name: "files", value: Double(count)),
                ],
                rank: 1 - cohesion
            ))
        }
    }

    // MARK: Modularity measures

    private static func modularity(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        var clusterOf: [Int64: Int] = [:]
        var clusterSize: [Int: Int] = [:]
        for cluster in ctx.graph.clusters {
            for id in cluster.fileIDs where ctx.sourceIDs.contains(id) {
                clusterOf[id] = cluster.id
                clusterSize[cluster.id, default: 0] += 1
            }
        }
        var inside: [Int: Int] = [:]
        var boundary: [Int: Int] = [:]
        var orderedAreaPairs = Set<Int>()
        let areaCount = max(1, ctx.areas.areas.count)
        findings.sourceAreaCount = Set(ctx.sourceFiles.map { ctx.areaIndex(of: $0.id) }).count
        for entry in ctx.pairs where ctx.sourceIDs.contains(entry.pair.source) && ctx.sourceIDs.contains(entry.pair.target) {
            findings.totalSourcePairs += 1
            let sourceArea = ctx.areaIndex(of: entry.pair.source), targetArea = ctx.areaIndex(of: entry.pair.target)
            if sourceArea != targetArea {
                findings.crossAreaPairs += 1
                orderedAreaPairs.insert(sourceArea * areaCount + targetArea)
            }
            let a = clusterOf[entry.pair.source], b = clusterOf[entry.pair.target]
            if let a, a == b {
                inside[a, default: 0] += 1
            } else {
                if let a { boundary[a, default: 0] += 1 }
                if let b { boundary[b, default: 0] += 1 }
            }
        }
        var weighted = 0.0
        var weight = 0
        for (cluster, size) in clusterSize.sorted(by: { $0.key < $1.key }) where size >= 3 {
            let total = (inside[cluster] ?? 0) + (boundary[cluster] ?? 0)
            guard total > 0 else { continue }
            weighted += Double(size) * Double(inside[cluster] ?? 0) / Double(total)
            weight += size
            findings.clusterCount += 1
        }
        findings.clusterCohesion = weight > 0 ? weighted / Double(weight) : nil
        findings.connectedOrderedAreaPairs = orderedAreaPairs.count
    }
}
