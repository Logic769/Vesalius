import Foundation
import VesaliusCore

/// Runs the graph algorithms over a repository's file dependency graph and derives per-file metrics,
/// cycles and clusters.
public struct GraphAnalysis: Sendable {
    public struct FileInput: Sendable {
        public var id: Int64
        public var path: String
        public var codeLines: Int
        public var complexity: Int
        public var isCode: Bool
        public var isTest: Bool
        public var churn: Int?

        public init(id: Int64, path: String, codeLines: Int, complexity: Int, isCode: Bool, isTest: Bool, churn: Int?) {
            self.id = id
            self.path = path
            self.codeLines = codeLines
            self.complexity = complexity
            self.isCode = isCode
            self.isTest = isTest
            self.churn = churn
        }
    }

    public var metrics: [Int64: FileGraphMetrics]
    public var hotspotScores: [Int64: Double]
    /// Cycles as file ids, largest first.
    public var cycles: [[Int64]]
    /// A concrete closed path for each cycle (same order as `cycles`).
    public var cyclePaths: [[Int64]]
    public var clusters: [RepositorySnapshot.Cluster]
    /// The deepest dependency chain (file ids).
    public var longestChain: [Int64]

    public static func compute(files: [FileInput], edges: [RepositorySnapshot.Edge]) -> GraphAnalysis {
        var index: [Int64: Int] = [:]
        for (i, file) in files.enumerated() { index[file.id] = i }
        let graphEdges = edges.compactMap { edge -> (Int, Int, Double)? in
            guard edge.kind.isDependency, let s = index[edge.source], let t = index[edge.target] else { return nil }
            return (s, t, Double(max(1, edge.weight)))
        }
        let graph = DependencyGraph(nodeCount: files.count, edges: graphEdges.map { (source: $0.0, target: $0.1, weight: $0.2) })
        let rank = graph.pageRank()
        let maxRank = rank.max() ?? 1
        let minRank = rank.min() ?? 0
        let depth = graph.dependencyDepth()
        let reach = graph.transitiveCounts()
        let components = graph.cycles()
        let communities = graph.communities()

        var cycleOf: [Int: (id: Int, size: Int)] = [:]
        var cycles: [[Int64]] = []
        var cyclePaths: [[Int64]] = []
        for (cycleID, component) in components.enumerated() {
            for node in component { cycleOf[node] = (cycleID + 1, component.count) }
            cycles.append(component.map { files[$0].id })
            cyclePaths.append(graph.cyclePath(in: component).map { files[$0].id })
        }

        let codeFileCount = max(1, files.filter(\.isCode).count)
        var metrics: [Int64: FileGraphMetrics] = [:]
        var hotspots: [Int64: Double] = [:]
        let hasChurn = files.contains { ($0.churn ?? 0) > 0 }
        for (i, file) in files.enumerated() {
            var m = FileGraphMetrics()
            m.fanIn = graph.fanIn(i)
            m.fanOut = graph.fanOut(i)
            m.centrality = maxRank > minRank ? (rank[i] - minRank) / (maxRank - minRank) : 0
            m.transitiveDependents = reach.dependents[i]
            m.transitiveDependencies = reach.dependencies[i]
            m.depth = depth[i]
            m.cycleID = cycleOf[i]?.id
            m.cycleSize = cycleOf[i]?.size
            m.clusterID = communities.isEmpty ? nil : communities[i]
            m.churn = file.churn
            m.risk = Self.risk(metrics: m, file: file, codeFiles: codeFileCount)
            metrics[file.id] = m
            hotspots[file.id] = file.isCode && !file.isTest ? Self.hotspot(metrics: m, file: file, hasChurn: hasChurn) : 0
        }

        // Clusters with at least two files, labelled by their dominant directory.
        var members: [Int: [Int]] = [:]
        for (i, community) in communities.enumerated() where files[i].isCode {
            members[community, default: []].append(i)
        }
        let clusters = members
            .filter { $0.value.count >= 2 }
            .sorted { $0.value.count > $1.value.count }
            .map { community, nodes in
                RepositorySnapshot.Cluster(id: community, fileIDs: nodes.map { files[$0].id }, label: Self.label(for: nodes.map { files[$0].path }))
            }

        return GraphAnalysis(
            metrics: metrics,
            hotspotScores: hotspots,
            cycles: cycles,
            cyclePaths: cyclePaths,
            clusters: clusters,
            longestChain: graph.longestChain().map { files[$0].id }
        )
    }

    /// Change risk in 0…1: how far a change can ripple (transitive dependents, centrality, fan-in), how
    /// hard the file is to change safely (complexity, churn) and whether it sits in a cycle.
    public static func risk(metrics m: FileGraphMetrics, file: FileInput, codeFiles: Int) -> Double {
        // Logarithmic reach: being reachable from 200 of 700 files is serious, but not 30x worse than
        // from 7, and one large knot must not mark every member as high risk.
        let reach = log(1 + Double(m.transitiveDependents)) / log(1 + Double(max(2, codeFiles)))
        var score = 0.3 * reach
        score += 0.2 * m.centrality
        score += 0.15 * min(1, Double(m.fanIn) / 25)
        score += 0.15 * min(1, Double(file.complexity) / 250)
        score += 0.12 * min(1, Double(m.churn ?? 0) / 30)
        score += m.cycleID != nil ? 0.05 : 0
        return min(1, max(0, score))
    }

    /// Hotspot score in 0…1: big/complex code that changes often and is heavily coupled.
    public static func hotspot(metrics m: FileGraphMetrics, file: FileInput, hasChurn: Bool) -> Double {
        let size = min(1, Double(file.codeLines) / 800) * 0.5 + min(1, Double(file.complexity) / 200) * 0.5
        let coupling = min(1, Double(m.fanIn + m.fanOut) / 30)
        if hasChurn {
            let churn = min(1, Double(m.churn ?? 0) / 25)
            return 0.4 * size + 0.35 * churn + 0.25 * coupling
        }
        return 0.6 * size + 0.4 * coupling
    }

    /// Names a group of files after its most specific shared directory.
    public static func label(for paths: [String]) -> String {
        var counts: [String: Int] = [:]
        for path in paths {
            let directories = path.split(separator: "/").dropLast()
            var prefix = ""
            for component in directories {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                counts[prefix, default: 0] += 1
            }
        }
        // Deepest directory that holds at least 60% of the files.
        let threshold = Int((Double(paths.count) * 0.6).rounded(.up))
        let best = counts
            .filter { $0.value >= threshold }
            .max { a, b in
                let da = a.key.split(separator: "/").count, db = b.key.split(separator: "/").count
                return da == db ? a.value < b.value : da < db
            }
        if let best {
            let name = best.key.split(separator: "/").last.map(String.init) ?? best.key
            return name
        }
        // Fall back to the most common file-name word.
        var words: [String: Int] = [:]
        for path in paths {
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            for word in Tokenizer.splitIdentifier(stem) where word.count > 2 {
                words[word, default: 0] += 1
            }
        }
        return words.max { $0.value < $1.value }.map { $0.key.capitalized } ?? "Group"
    }
}
