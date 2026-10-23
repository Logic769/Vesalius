import Foundation

/// A directed, weighted graph over dense integer node indices with algorithms sized for repositories
/// of tens of thousands of files. Edges point from a dependent to its dependency (A → B: A uses B).
public struct DependencyGraph: Sendable {
    public struct Edge: Sendable, Hashable {
        public let target: Int
        public let weight: Double
    }

    public let nodeCount: Int
    public private(set) var outgoing: [[Edge]]
    public private(set) var incoming: [[Edge]]

    /// Builds a graph; parallel edges are merged (weights summed) and self-loops dropped.
    public init(nodeCount: Int, edges: [(source: Int, target: Int, weight: Double)]) {
        self.nodeCount = nodeCount
        var merged: [Int: [Int: Double]] = [:]
        for edge in edges where edge.source != edge.target && edge.source >= 0 && edge.target >= 0 && edge.source < nodeCount && edge.target < nodeCount {
            merged[edge.source, default: [:]][edge.target, default: 0] += edge.weight
        }
        var outgoing = Array(repeating: [Edge](), count: nodeCount)
        var incoming = Array(repeating: [Edge](), count: nodeCount)
        for (source, targets) in merged {
            for (target, weight) in targets.sorted(by: { $0.key < $1.key }) {
                outgoing[source].append(Edge(target: target, weight: weight))
                incoming[target].append(Edge(target: source, weight: weight))
            }
        }
        for i in 0..<nodeCount {
            incoming[i].sort { $0.target < $1.target }
        }
        self.outgoing = outgoing
        self.incoming = incoming
    }

    public var edgeCount: Int { outgoing.reduce(0) { $0 + $1.count } }

    public func fanOut(_ node: Int) -> Int { outgoing[node].count }
    public func fanIn(_ node: Int) -> Int { incoming[node].count }

    // MARK: - Strongly connected components (iterative Tarjan)

    /// Returns components in reverse topological order (a component's dependencies come before it).
    public func stronglyConnectedComponents() -> [[Int]] {
        var index = 0
        var indices = Array(repeating: -1, count: nodeCount)
        var lowlink = Array(repeating: 0, count: nodeCount)
        var onStack = Array(repeating: false, count: nodeCount)
        var stack: [Int] = []
        var components: [[Int]] = []

        for root in 0..<nodeCount where indices[root] == -1 {
            var work: [(node: Int, edge: Int)] = [(root, 0)]
            indices[root] = index
            lowlink[root] = index
            index += 1
            stack.append(root)
            onStack[root] = true

            while !work.isEmpty {
                let (node, edgeIndex) = work[work.count - 1]
                if edgeIndex < outgoing[node].count {
                    work[work.count - 1].edge += 1
                    let next = outgoing[node][edgeIndex].target
                    if indices[next] == -1 {
                        indices[next] = index
                        lowlink[next] = index
                        index += 1
                        stack.append(next)
                        onStack[next] = true
                        work.append((next, 0))
                    } else if onStack[next] {
                        lowlink[node] = min(lowlink[node], indices[next])
                    }
                } else {
                    work.removeLast()
                    if let parent = work.last?.node {
                        lowlink[parent] = min(lowlink[parent], lowlink[node])
                    }
                    if lowlink[node] == indices[node] {
                        var component: [Int] = []
                        while let top = stack.popLast() {
                            onStack[top] = false
                            component.append(top)
                            if top == node { break }
                        }
                        components.append(component.sorted())
                    }
                }
            }
        }
        return components
    }

    /// Components with more than one node: dependency cycles.
    public func cycles() -> [[Int]] {
        stronglyConnectedComponents().filter { $0.count > 1 }.sorted { $0.count > $1.count }
    }

    /// A concrete closed walk through a cycle component (shortest cycle through its first node).
    public func cyclePath(in component: [Int]) -> [Int] {
        guard let start = component.first else { return [] }
        let members = Set(component)
        // BFS from start's successors back to start, staying inside the component.
        var previous: [Int: Int] = [:]
        var queue: [Int] = []
        var head = 0
        for edge in outgoing[start] where members.contains(edge.target) {
            if previous[edge.target] == nil {
                previous[edge.target] = start
                queue.append(edge.target)
            }
        }
        while head < queue.count {
            let node = queue[head]
            head += 1
            if node == start { break }
            for edge in outgoing[node] where members.contains(edge.target) && previous[edge.target] == nil {
                previous[edge.target] = node
                queue.append(edge.target)
                if edge.target == start { break }
            }
        }
        guard previous[start] != nil else { return component + [start] }
        var path = [start]
        var current = previous[start]!
        while current != start {
            path.append(current)
            current = previous[current]!
            if path.count > component.count + 1 { break }
        }
        path.append(start)
        return Array(path.reversed())
    }

    // MARK: - Centrality

    /// Weighted PageRank over dependency edges: files that many (important) files depend on rank highest.
    public func pageRank(damping: Double = 0.85, iterations: Int = 60, tolerance: Double = 1e-9) -> [Double] {
        guard nodeCount > 0 else { return [] }
        let n = Double(nodeCount)
        var rank = Array(repeating: 1.0 / n, count: nodeCount)
        let outWeight = outgoing.map { $0.reduce(0) { $0 + $1.weight } }
        for _ in 0..<iterations {
            var next = Array(repeating: (1 - damping) / n, count: nodeCount)
            var danglingMass = 0.0
            for node in 0..<nodeCount {
                if outWeight[node] == 0 {
                    danglingMass += rank[node]
                } else {
                    let share = damping * rank[node] / outWeight[node]
                    for edge in outgoing[node] {
                        next[edge.target] += share * edge.weight
                    }
                }
            }
            let danglingShare = damping * danglingMass / n
            var delta = 0.0
            for node in 0..<nodeCount {
                next[node] += danglingShare
                delta += abs(next[node] - rank[node])
            }
            rank = next
            if delta < tolerance { break }
        }
        return rank
    }

    // MARK: - Depth

    /// Longest dependency chain (in nodes, minus one) starting at each node, computed on the
    /// condensation DAG so cycles cannot cause infinite chains.
    public func dependencyDepth() -> [Int] {
        let components = stronglyConnectedComponents()
        var componentOf = Array(repeating: 0, count: nodeCount)
        for (id, component) in components.enumerated() {
            for node in component { componentOf[node] = id }
        }
        // Tarjan returns components so that every dependency component precedes its dependents.
        var componentDepth = Array(repeating: 0, count: components.count)
        for (id, component) in components.enumerated() {
            var best = 0
            for node in component {
                for edge in outgoing[node] {
                    let target = componentOf[edge.target]
                    if target != id { best = max(best, componentDepth[target] + 1) }
                }
            }
            componentDepth[id] = best + (component.count > 1 ? component.count - 1 : 0)
        }
        return (0..<nodeCount).map { componentDepth[componentOf[$0]] }
    }

    /// The longest dependency chain in the graph (node indices from dependent to deepest dependency).
    public func longestChain() -> [Int] {
        let depth = dependencyDepth()
        guard let start = (0..<nodeCount).max(by: { depth[$0] < depth[$1] }), depth[start] > 0 else { return [] }
        var chain = [start]
        var visited: Set<Int> = [start]
        var current = start
        while depth[current] > 0, chain.count <= nodeCount {
            guard let next = outgoing[current]
                .map(\.target)
                .filter({ !visited.contains($0) })
                .max(by: { depth[$0] < depth[$1] }) else { break }
            chain.append(next)
            visited.insert(next)
            current = next
        }
        return chain
    }

    // MARK: - Reachability

    public enum Direction: Sendable { case dependencies, dependents }

    /// Nodes reachable from `start`, with hop distance, up to `maxDepth` hops.
    public func traverse(from start: Int, direction: Direction, maxDepth: Int = .max, limit: Int = .max) -> [(node: Int, distance: Int)] {
        var distance: [Int: Int] = [start: 0]
        var queue = [start]
        var head = 0
        var result: [(Int, Int)] = []
        while head < queue.count {
            let node = queue[head]
            head += 1
            let d = distance[node]!
            guard d < maxDepth else { continue }
            let edges = direction == .dependencies ? outgoing[node] : incoming[node]
            for edge in edges where distance[edge.target] == nil {
                distance[edge.target] = d + 1
                queue.append(edge.target)
                result.append((edge.target, d + 1))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// Counts of transitively reachable nodes per node in both directions. Exact (bitsets over the
    /// condensation DAG) up to `exactLimit` nodes; beyond that, bounded BFS counts capped at `cap`.
    public func transitiveCounts(exactLimit: Int = 12_000, cap: Int = 400) -> (dependents: [Int], dependencies: [Int]) {
        guard nodeCount > 0 else { return ([], []) }
        if nodeCount > exactLimit {
            var dependents = Array(repeating: 0, count: nodeCount)
            var dependencies = Array(repeating: 0, count: nodeCount)
            for node in 0..<nodeCount {
                if !incoming[node].isEmpty { dependents[node] = traverse(from: node, direction: .dependents, limit: cap).count }
                if !outgoing[node].isEmpty { dependencies[node] = traverse(from: node, direction: .dependencies, limit: cap).count }
            }
            return (dependents, dependencies)
        }

        let components = stronglyConnectedComponents()
        var componentOf = Array(repeating: 0, count: nodeCount)
        for (id, component) in components.enumerated() {
            for node in component { componentOf[node] = id }
        }
        let words = (nodeCount + 63) / 64

        // Forward reach: components come dependencies-first, so successors are complete before use.
        var forward = Array(repeating: [UInt64](repeating: 0, count: words), count: components.count)
        for (id, component) in components.enumerated() {
            var bits = [UInt64](repeating: 0, count: words)
            for node in component {
                for edge in outgoing[node] {
                    let target = componentOf[edge.target]
                    guard target != id else { continue }
                    let targetBits = forward[target]
                    for w in 0..<words { bits[w] |= targetBits[w] }
                    for member in components[target] { bits[member >> 6] |= 1 << UInt64(member & 63) }
                }
            }
            forward[id] = bits
        }
        // Backward reach: iterate in the opposite order.
        var backward = Array(repeating: [UInt64](repeating: 0, count: words), count: components.count)
        for id in stride(from: components.count - 1, through: 0, by: -1) {
            var bits = [UInt64](repeating: 0, count: words)
            for node in components[id] {
                for edge in incoming[node] {
                    let source = componentOf[edge.target]
                    guard source != id else { continue }
                    let sourceBits = backward[source]
                    for w in 0..<words { bits[w] |= sourceBits[w] }
                    for member in components[source] { bits[member >> 6] |= 1 << UInt64(member & 63) }
                }
            }
            backward[id] = bits
        }
        var dependents = Array(repeating: 0, count: nodeCount)
        var dependencies = Array(repeating: 0, count: nodeCount)
        for (id, component) in components.enumerated() {
            let inCycleExtra = component.count - 1
            let back = backward[id].reduce(0) { $0 + $1.nonzeroBitCount } + inCycleExtra
            let fwd = forward[id].reduce(0) { $0 + $1.nonzeroBitCount } + inCycleExtra
            for node in component {
                dependents[node] = back
                dependencies[node] = fwd
            }
        }
        return (dependents, dependencies)
    }

    // MARK: - Community detection (Louvain)

    /// Louvain modularity clustering on the undirected projection. Deterministic for a given graph.
    public func communities(resolution: Double = 1.0, maxLevels: Int = 6) -> [Int] {
        guard nodeCount > 0 else { return [] }
        // Undirected adjacency.
        var adjacency = Array(repeating: [Int: Double](), count: nodeCount)
        for source in 0..<nodeCount {
            for edge in outgoing[source] {
                adjacency[source][edge.target, default: 0] += edge.weight
                adjacency[edge.target][source, default: 0] += edge.weight
            }
        }
        var membership = Array(0..<nodeCount)   // original node → current super-node
        var graph = adjacency
        for _ in 0..<maxLevels {
            let (assignment, moved) = Self.louvainLocalMoving(graph, resolution: resolution)
            guard moved else { break }
            // Renumber communities densely.
            var remap: [Int: Int] = [:]
            for community in assignment where remap[community] == nil { remap[community] = remap.count }
            membership = membership.map { remap[assignment[$0]]! }
            var aggregated = Array(repeating: [Int: Double](), count: remap.count)
            for (node, neighbors) in graph.enumerated() {
                let a = remap[assignment[node]]!
                for (neighbor, weight) in neighbors {
                    let b = remap[assignment[neighbor]]!
                    aggregated[a][b, default: 0] += weight
                }
            }
            if aggregated.count == graph.count { break }
            graph = aggregated
        }
        return membership
    }

    private static func louvainLocalMoving(_ graph: [[Int: Double]], resolution: Double) -> ([Int], Bool) {
        let n = graph.count
        var community = Array(0..<n)
        let degree = graph.map { $0.values.reduce(0, +) }
        let totalWeight = degree.reduce(0, +)
        guard totalWeight > 0 else { return (community, false) }
        var communityTotal = degree
        var movedAny = false
        for _ in 0..<24 {
            var moved = false
            for node in 0..<n {
                let current = community[node]
                var weightsToCommunity: [Int: Double] = [:]
                for (neighbor, weight) in graph[node] where neighbor != node {
                    weightsToCommunity[community[neighbor], default: 0] += weight
                }
                communityTotal[current] -= degree[node]
                var best = current
                var bestGain = (weightsToCommunity[current] ?? 0) - resolution * communityTotal[current] * degree[node] / totalWeight
                for (candidate, weight) in weightsToCommunity.sorted(by: { $0.key < $1.key }) where candidate != current {
                    let gain = weight - resolution * communityTotal[candidate] * degree[node] / totalWeight
                    if gain > bestGain + 1e-12 {
                        bestGain = gain
                        best = candidate
                    }
                }
                community[node] = best
                communityTotal[best] += degree[node]
                if best != current {
                    moved = true
                    movedAny = true
                }
            }
            if !moved { break }
        }
        return (community, movedAny)
    }
}
