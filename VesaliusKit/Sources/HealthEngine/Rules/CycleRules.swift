import Foundation
import GraphEngine
import VesaliusCore

/// "dependency-cycle" and "deep-chain".
enum CycleRules {
    static func run(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        cycles(ctx, &findings)
        deepChain(ctx, &findings)
    }

    /// File names, falling back to the last two path components where names collide.
    static func uniqueNames(_ ids: [Int64], ctx: HealthContext) -> [Int64: String] {
        var byName: [String: Set<Int64>] = [:]
        for id in ids { byName[ctx.displayName(id), default: []].insert(id) }
        var result: [Int64: String] = [:]
        for id in ids {
            let name = ctx.displayName(id)
            if (byName[name]?.count ?? 0) > 1 {
                result[id] = ctx.path(id).split(separator: "/").suffix(2).joined(separator: "/")
            } else {
                result[id] = name
            }
        }
        return result
    }

    /// The part of a dependency loop that explicit imports close on their own, with a concrete path.
    /// Swift files (which never import each other) and C headers that use the declarations of the header
    /// that includes them form loops no import closes: those compile fine and are reported gently.
    static func importCycle(_ members: [Int64], ctx: HealthContext) -> (members: [Int64], path: [Int64])? {
        let index = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1, $0) })
        var edges: [(source: Int, target: Int, weight: Double)] = []
        for id in members {
            guard let source = index[id] else { continue }
            for target in ctx.importTargets[id] ?? [] {
                if let target = index[target] { edges.append((source, target, 1)) }
            }
        }
        guard !edges.isEmpty else { return nil }
        let graph = DependencyGraph(nodeCount: members.count, edges: edges)
        let components = graph.stronglyConnectedComponents().filter { $0.count > 1 }
        guard let largest = components.max(by: { $0.count < $1.count }) else { return nil }
        let cycleMembers = components.flatMap { $0 }.map { members[$0] }.sorted { ctx.path($0) < ctx.path($1) }
        return (cycleMembers, graph.cyclePath(in: largest).map { members[$0] })
    }

    private static func cycles(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        var drafts: [DiagnosticDraft] = []
        for (index, cycle) in ctx.graph.cycles.enumerated() {
            let loop = cycle.filter { ctx.participatingIDs.contains($0) }.sorted { ctx.path($0) < ctx.path($1) }
            guard loop.count >= 2 else { continue }
            // A loop is an import cycle only when explicit imports close it. Swift files in one module see
            // each other without imports (and Swift forbids cyclic module dependencies), and C headers use
            // declarations from the headers that include them: such loops compile fine and only matter when
            // the group needs to be split.
            let imported = importCycle(loop, ctx: ctx)
            let implicitVisibility = imported == nil
            let members = imported?.members ?? loop
            let memberSet = Set(members)
            let languages = Set(members.compactMap { ctx.file($0)?.language })
            let modules = Set(members.compactMap { ctx.file($0)?.module })
            let swiftOnly = languages.isSubset(of: [.swift, .objectiveC])
            findings.cycleCount += 1
            let sourceMembers = members.filter { ctx.sourceIDs.contains($0) }.count
            if implicitVisibility {
                findings.softCycleFiles += sourceMembers
            } else {
                findings.filesInCycles += sourceMembers
                findings.largestCycle = max(findings.largestCycle, members.count)
            }

            var path = imported?.path ?? (index < ctx.graph.cyclePaths.count ? ctx.graph.cyclePaths[index].filter { memberSet.contains($0) } : [])
            if path.count < 3 { path = members + [members[0]] }
            let names = uniqueNames(members, ctx: ctx)
            var labels = path.map { names[$0] ?? ctx.displayName($0) }
            if labels.count > 10 { labels = Array(labels.prefix(8)) + ["…", labels[labels.count - 1]] }
            let pathText = labels.joined(separator: " → ")

            // Internal edges and the weakest link along the concrete path.
            var internalEdges = 0
            for id in members {
                for target in ctx.outgoing[id] ?? [] where memberSet.contains(target) { internalEdges += 1 }
            }
            var weakest: (from: Int64, to: Int64, weight: Int)?
            for (a, b) in zip(path, path.dropFirst()) {
                let weight = ctx.pairWeight[HealthContext.Pair(source: a, target: b)] ?? 0
                if weight > 0, weakest == nil || weight < weakest!.weight { weakest = (a, b, weight) }
            }
            let severity: Severity
            if implicitVisibility {
                severity = members.count >= 12 ? .medium : .low
            } else {
                severity = members.count >= 6 ? .critical : (members.count >= 3 ? .high : .medium)
            }
            var recommendation = implicitVisibility
                ? "If this group should become separate modules later, cut the loop first: move the shared types into their own file or module, and have higher-level files depend on protocols."
                : "Break the cycle by inverting one dependency: introduce a protocol or interface owned by the lower-level file, or move the shared types into a separate file both sides can depend on."
            if let weakest {
                recommendation += " The weakest link is \(names[weakest.from] ?? ctx.displayName(weakest.from)) → \(names[weakest.to] ?? ctx.displayName(weakest.to)) (\(Format.plural(weakest.weight, "reference"))), which is the cheapest place to cut."
            }
            drafts.append(DiagnosticDraft(
                rule: "dependency-cycle",
                category: .cycles,
                severity: severity,
                title: implicitVisibility
                    ? "Interconnected \(swiftOnly ? "Swift " : "")files (\(members.count))\(modules.count == 1 ? " in \(modules.first!)" : "")"
                    : "Dependency cycle across \(members.count) files",
                summary: members.count == 2
                    ? "\(names[members[0]] ?? "") and \(names[members[1]] ?? "") depend on each other: \(pathText)."
                    : "\(members.count) files are tangled in one dependency cycle (\(Format.list(members.map { names[$0] ?? ctx.displayName($0) }, limit: 5))). One concrete loop: \(pathText).",
                reason: implicitVisibility
                    ? "Each file reaches every other one through references (\(Format.plural(internalEdges, "dependency edge", "dependency edges")) inside the group), but no chain of imports closes the loop. "
                        + (swiftOnly
                            ? "Swift compiles this without imports, so it is not an error, but the group can only move into separate modules once the loop is cut."
                            : "The files use each other's declarations by name (for example a header that relies on the header that includes it), which compiles, but the group can only be split once the loop is cut.")
                    : "Each file in this group depends, directly or transitively, on every other one (\(Format.plural(internalEdges, "dependency edge", "dependency edges")) inside the loop), so none of them can be changed, tested or extracted in isolation.",
                recommendation: recommendation,
                targets: members.map { .file(ctx.path($0)) },
                metrics: [
                    DiagnosticMetric(name: "files in cycle", value: Double(members.count), threshold: 1, unit: "files"),
                    DiagnosticMetric(name: "internal edges", value: Double(internalEdges)),
                ],
                rank: Double(members.count)
            ))
        }
        drafts.sort { $0.rank != $1.rank ? $0.rank > $1.rank : DiagnosticDraft.ordered($0, $1) }
        findings.drafts += drafts.prefix(ctx.config.maxCycleDiagnostics)
    }

    private static func deepChain(_ ctx: HealthContext, _ findings: inout HealthFindings) {
        let chain = ctx.graph.longestChain.filter { ctx.participatingIDs.contains($0) }
        let depth = max(0, chain.count - 1)
        findings.longestChain = depth
        guard depth > ctx.config.deepChainLength else { return }
        let severity: Severity = depth > ctx.config.veryDeepChainLength ? .high : .medium
        let names = uniqueNames(chain, ctx: ctx)
        var labels = chain.map { names[$0] ?? ctx.displayName($0) }
        if labels.count > 12 { labels = Array(labels.prefix(6)) + ["…"] + Array(labels.suffix(5)) }
        let text = labels.joined(separator: " → ")
        findings.drafts.append(DiagnosticDraft(
            rule: "deep-chain",
            category: .coupling,
            severity: severity,
            title: "Deep dependency chain (\(depth) levels)",
            summary: "The longest dependency chain runs through \(chain.count) files: \(text).",
            reason: "A change at the bottom of a \(depth)-level chain can ripple up through every level above it (threshold \(ctx.config.deepChainLength) levels). Deep chains also make the top-level code slow to build and hard to test in isolation.",
            recommendation: "Flatten the chain: let high-level code depend on stable interfaces instead of concrete implementations several levels down, and check whether intermediate files only forward calls.",
            targets: chain.prefix(20).map { .file(ctx.path($0)) },
            metrics: [
                DiagnosticMetric(name: "chain depth", value: Double(depth), threshold: Double(ctx.config.deepChainLength), unit: "levels"),
            ],
            rank: Double(depth)
        ))
    }
}
