import CoreGraphics
import Foundation

/// A node as the layout engine sees it: a footprint, a cluster key and optional continuity hints.
nonisolated struct GraphLayoutNode: Sendable {
    var id: String
    /// Nodes sharing a group are pulled together so clusters read as clusters.
    var group: String
    /// Footprint in world points (cards are rectangles, everything else is treated as a circle).
    var size: CGSize
    var isRect: Bool
    /// Desired empty space between this node's border and its neighbours' (room for labels/arrows).
    var gap: Double
    /// Relative visual mass in 0…1; heavier nodes settle closer to the centre.
    var mass: Double
    /// Previous position, for continuity across graph updates.
    var initial: CGPoint?
    /// Pinned nodes never move.
    var pinned: Bool
}

nonisolated struct GraphLayoutEdge: Sendable {
    var source: Int
    var target: Int
    var weight: Double
}

nonisolated struct GraphLayoutRequest: Sendable {
    var nodes: [GraphLayoutNode]
    var edges: [GraphLayoutEdge]
}

nonisolated struct GraphLayoutResult: Sendable {
    /// Node centres, in request order.
    var positions: [CGPoint]
    /// Union of all node footprints.
    var bounds: CGRect
    var milliseconds: Double
}

/// Deterministic, size-aware force-directed layout.
///
/// Fruchterman–Reingold forces measured between node *borders* (so wide cards and small circles get
/// the same visual gaps), short-range repulsion (the FR grid variant), group cohesion, mass-weighted
/// gravity, continuity anchors and a final overlap-removal pass. Exact pairwise repulsion up to
/// `exactRepulsionLimit` nodes, a uniform-grid neighbour search above that. Pure and thread-safe.
nonisolated enum GraphLayoutEngine {
    static let exactRepulsionLimit = 450

    /// Recommended gaps between the borders of neighbouring nodes.
    static let cardGap = 70.0
    static let symbolGap = 46.0
    static let pointGap = 30.0

    static func layout(_ request: GraphLayoutRequest) -> GraphLayoutResult {
        let started = DispatchTime.now().uptimeNanoseconds
        var state = LayoutState(request)
        if state.count > 0 {
            state.seedPositions()
            state.simulate()
            state.removeOverlaps()
            state.recenterIfFree()
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return GraphLayoutResult(positions: state.positions, bounds: state.bounds, milliseconds: elapsed)
    }
}

/// Mutable simulation state.
private nonisolated struct LayoutState {
    struct Body {
        var halfWidth: Double
        var halfHeight: Double
        var radius: Double
        var isRect: Bool
        var gap: Double
        var group: Int
        var mass: Double
        var pinned: Bool

        /// Distance from the centre to the border along unit direction (ux, uy).
        @inline(__always)
        func extent(_ ux: Double, _ uy: Double) -> Double {
            guard isRect else { return radius }
            let ax = abs(ux), ay = abs(uy)
            let tx = ax > 1e-9 ? halfWidth / ax : .greatestFiniteMagnitude
            let ty = ay > 1e-9 ? halfHeight / ay : .greatestFiniteMagnitude
            return min(tx, ty)
        }
    }

    let count: Int
    let ids: [String]
    let bodies: [Body]
    var x: [Double]
    var y: [Double]
    let groupCount: Int
    let groupSizes: [Int]
    let edges: [(Int, Int, Double)]
    let anchors: [CGPoint?]
    let hasAnchors: Bool
    let averageIdeal: Double

    init(_ request: GraphLayoutRequest) {
        let nodes = request.nodes
        count = nodes.count
        ids = nodes.map(\.id)
        let keys = Array(Set(nodes.map(\.group))).sorted()
        let groupIndex = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        bodies = nodes.map { node in
            let w = Double(max(4, node.size.width)), h = Double(max(4, node.size.height))
            return Body(
                halfWidth: w / 2,
                halfHeight: h / 2,
                radius: max(w, h) / 2,
                isRect: node.isRect,
                gap: max(4, node.gap.isFinite ? node.gap : GraphLayoutEngine.pointGap),
                group: groupIndex[node.group] ?? 0,
                mass: min(1, max(0, node.mass.isFinite ? node.mass : 0)),
                pinned: node.pinned
            )
        }
        x = Array(repeating: 0, count: count)
        y = Array(repeating: 0, count: count)
        groupCount = keys.count
        var sizes = Array(repeating: 0, count: keys.count)
        for body in bodies { sizes[body.group] += 1 }
        groupSizes = sizes
        edges = request.edges.compactMap { edge in
            guard edge.source != edge.target, edge.source >= 0, edge.target >= 0, edge.source < nodes.count, edge.target < nodes.count else { return nil }
            return (edge.source, edge.target, max(1, edge.weight))
        }
        anchors = nodes.map(\.initial)
        hasAnchors = anchors.contains { $0 != nil }
        let meanExtent = bodies.isEmpty ? 10 : bodies.reduce(0) { $0 + ($1.isRect ? ($1.halfWidth + $1.halfHeight) / 2 : $1.radius) } / Double(bodies.count)
        let meanGap = bodies.isEmpty ? GraphLayoutEngine.pointGap : bodies.reduce(0) { $0 + $1.gap } / Double(bodies.count)
        averageIdeal = 2 * meanExtent + meanGap
    }

    @inline(__always)
    static func gap(_ a: Body, _ b: Body) -> Double { max(a.gap, b.gap) }

    /// The smallest acceptable border gap (labels and arrowheads need room).
    @inline(__always)
    static func minimumGap(_ a: Body, _ b: Body) -> Double { max(8, gap(a, b) * 0.37) }

    /// Repulsion fades smoothly to zero at three ideal distances (the grid variant of
    /// Fruchterman–Reingold), so loose nodes pack into a compact disc held by gravity instead of
    /// drifting apart; overlapping footprints get an extra linear push.
    @inline(__always)
    static let cutoffFactor = 2.5

    static func repulsion(distance d: Double, ideal k: Double, contact: Double, sameGroup: Bool) -> Double {
        let cutoff = cutoffFactor * k
        guard d < cutoff else { return 0 }
        let taper = 1 - d / cutoff
        // Other groups push harder, so clusters separate into readable islands.
        var strength = k * k / d * taper * taper * (sameGroup ? 0.8 : 1.6)
        // Resist closing the gap below the ideal distance, and push hard near contact.
        if d < k { strength += (k - d) * 0.9 }
        if d < contact { strength += (contact - d) * 2 }
        return strength
    }

    // MARK: Seeding

    /// Deterministic start: groups evenly spaced on a ring (sorted by key); members on a golden-angle
    /// spiral around their group centre, heaviest first; anchored nodes start at their anchors.
    mutating func seedPositions() {
        var anchorSumX = 0.0, anchorSumY = 0.0, anchorCount = 0.0
        var groupAnchorX = Array(repeating: 0.0, count: groupCount)
        var groupAnchorY = Array(repeating: 0.0, count: groupCount)
        var groupAnchorCount = Array(repeating: 0.0, count: groupCount)
        for i in 0..<count {
            guard let anchor = anchors[i] else { continue }
            anchorSumX += anchor.x
            anchorSumY += anchor.y
            anchorCount += 1
            groupAnchorX[bodies[i].group] += anchor.x
            groupAnchorY[bodies[i].group] += anchor.y
            groupAnchorCount[bodies[i].group] += 1
        }
        let origin = anchorCount > 0 ? (anchorSumX / anchorCount, anchorSumY / anchorCount) : (0.0, 0.0)
        let ringRadius = groupCount > 1 ? averageIdeal * Double(count).squareRoot() * 0.5 : 0
        var memberIndex = Array(repeating: 0, count: groupCount)
        let order = (0..<count).sorted { a, b in
            if bodies[a].mass != bodies[b].mass { return bodies[a].mass > bodies[b].mass }
            return MapLayoutHash.value(ids[a]) < MapLayoutHash.value(ids[b])
        }
        for i in order {
            if let anchor = anchors[i] {
                x[i] = anchor.x
                y[i] = anchor.y
                continue
            }
            let g = bodies[i].group
            var centerX: Double, centerY: Double
            if groupAnchorCount[g] > 0 {
                centerX = groupAnchorX[g] / groupAnchorCount[g]
                centerY = groupAnchorY[g] / groupAnchorCount[g]
            } else {
                let angle = 2 * Double.pi * Double(g) / Double(max(1, groupCount)) - Double.pi / 2
                centerX = origin.0 + ringRadius * cos(angle)
                centerY = origin.1 + ringRadius * sin(angle)
            }
            let k = Double(memberIndex[g])
            memberIndex[g] += 1
            let spiralAngle = k * 2.399_963_229_7 // golden angle
            let spiralRadius = averageIdeal * 0.6 * (k + 0.5).squareRoot()
            let jitter = MapLayoutHash.unitPair(ids[i])
            x[i] = centerX + spiralRadius * cos(spiralAngle) + jitter.0 * 3
            y[i] = centerY + spiralRadius * sin(spiralAngle) + jitter.1 * 3
        }
    }

    // MARK: Simulation

    mutating func simulate() {
        guard count > 1 else { return }
        let anchoredShare = Double(anchors.filter { $0 != nil }.count) / Double(count)
        var iterations: Int
        switch count {
        case ..<60: iterations = 420
        case ..<200: iterations = 320
        case ..<450: iterations = 240
        default: iterations = 170
        }
        if anchoredShare > 0.6 { iterations = max(80, iterations / 3) }

        let span = averageIdeal * Double(count).squareRoot()
        let startTemperature = anchoredShare > 0.6 ? averageIdeal * 0.5 : max(averageIdeal * 1.5, span / 6)
        let endTemperature = averageIdeal * 0.015
        let useGroups = groupCount > 1 && groupSizes.contains { $0 > 1 }
        // Sparse graphs need a firmer pull than well-connected ones, whose springs already hold them.
        let density = Double(edges.count) / Double(count)
        let gravity = density < 0.5 ? 0.16 : (density < 2 ? 0.1 : 0.07)
        var center = (0.0, 0.0)
        if hasAnchors {
            var sx = 0.0, sy = 0.0, n = 0.0
            for case let anchor? in anchors {
                sx += anchor.x
                sy += anchor.y
                n += 1
            }
            center = (sx / n, sy / n)
        }

        var dx = Array(repeating: 0.0, count: count)
        var dy = Array(repeating: 0.0, count: count)
        var groupX = Array(repeating: 0.0, count: groupCount)
        var groupY = Array(repeating: 0.0, count: groupCount)

        for iteration in 0..<iterations {
            let progress = Double(iteration) / Double(max(1, iterations - 1))
            let temperature = startTemperature * pow(endTemperature / startTemperature, progress)
            for i in 0..<count {
                dx[i] = 0
                dy[i] = 0
            }

            if count <= GraphLayoutEngine.exactRepulsionLimit {
                applyExactRepulsion(&dx, &dy)
            } else {
                applyGridRepulsion(&dx, &dy)
            }

            // Springs along edges, stronger for heavier dependencies.
            for (s, t, w) in edges {
                let ex = x[s] - x[t], ey = y[s] - y[t]
                let distance = max(0.01, (ex * ex + ey * ey).squareRoot())
                let ux = ex / distance, uy = ey / distance
                let k = bodies[s].extent(ux, uy) + bodies[t].extent(ux, uy) + Self.gap(bodies[s], bodies[t])
                let sameGroup = bodies[s].group == bodies[t].group
                let strength = (distance * distance / k) * min(1.7, 1 + 0.25 * log(w)) * (sameGroup ? 1.0 : 0.35)
                dx[s] -= ux * strength
                dy[s] -= uy * strength
                dx[t] += ux * strength
                dy[t] += uy * strength
            }

            // Cluster cohesion.
            if useGroups {
                for g in 0..<groupCount {
                    groupX[g] = 0
                    groupY[g] = 0
                }
                for i in 0..<count {
                    groupX[bodies[i].group] += x[i]
                    groupY[bodies[i].group] += y[i]
                }
                for g in 0..<groupCount where groupSizes[g] > 0 {
                    groupX[g] /= Double(groupSizes[g])
                    groupY[g] /= Double(groupSizes[g])
                }
                for i in 0..<count where groupSizes[bodies[i].group] > 1 {
                    let gx = groupX[bodies[i].group] - x[i], gy = groupY[bodies[i].group] - y[i]
                    let distance = (gx * gx + gy * gy).squareRoot()
                    guard distance > 0.01 else { continue }
                    let strength = distance * distance / averageIdeal * 0.2
                    dx[i] += gx / distance * strength
                    dy[i] += gy / distance * strength
                }
            }

            // Gravity: a linear pull keeps components and loose nodes in one compact disc; heavier
            // nodes are pulled harder so they settle in the middle.
            for i in 0..<count {
                let pull = gravity * (1 + 1.2 * bodies[i].mass)
                dx[i] += (center.0 - x[i]) * pull
                dy[i] += (center.1 - y[i]) * pull
            }

            // Continuity: previously placed nodes stay near where the viewer last saw them.
            if hasAnchors {
                for i in 0..<count {
                    guard let anchor = anchors[i] else { continue }
                    dx[i] += (anchor.x - x[i]) * 0.6
                    dy[i] += (anchor.y - y[i]) * 0.6
                }
            }

            var largestStep = 0.0
            for i in 0..<count where !bodies[i].pinned {
                let length = (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
                guard length > 0.0001 else { continue }
                let step = min(length, temperature)
                x[i] += dx[i] / length * step
                y[i] += dy[i] / length * step
                largestStep = max(largestStep, step)
            }
            // Settled: nothing moves more than a fraction of a point.
            if progress > 0.35 && largestStep < averageIdeal * 0.004 { break }
        }
    }

    /// Repulsive force on `a` from `b`, given the offset from `b` to `a`.
    @inline(__always)
    static func pairForce(_ a: Body, _ b: Body, ex inEx: Double, ey inEy: Double, salt: Int) -> (Double, Double) {
        var ex = inEx, ey = inEy
        var d2 = ex * ex + ey * ey
        if d2 < 0.0001 {
            // Coincident points: separate deterministically.
            ex = Double(salt % 7) - 3 + 0.5
            ey = Double((salt / 7) % 5) - 2 + 0.5
            d2 = ex * ex + ey * ey
        }
        let d = d2.squareRoot()
        let ux = ex / d, uy = ey / d
        let contact = a.extent(ux, uy) + b.extent(ux, uy)
        let k = contact + gap(a, b)
        guard d < cutoffFactor * k else { return (0, 0) }
        let strength = repulsion(distance: d, ideal: k, contact: contact + minimumGap(a, b), sameGroup: a.group == b.group)
        return (ux * strength, uy * strength)
    }

    private func applyExactRepulsion(_ dx: inout [Double], _ dy: inout [Double]) {
        let n = count
        var fx = [Double](repeating: 0, count: n)
        var fy = [Double](repeating: 0, count: n)
        bodies.withUnsafeBufferPointer { body in
            x.withUnsafeBufferPointer { px in
                y.withUnsafeBufferPointer { py in
                    fx.withUnsafeMutableBufferPointer { fxp in
                        fy.withUnsafeMutableBufferPointer { fyp in
                            for i in 0..<n {
                                let a = body[i], xi = px[i], yi = py[i]
                                var accX = 0.0, accY = 0.0
                                for j in (i + 1)..<n {
                                    let ex = xi - px[j], ey = yi - py[j]
                                    // Cheap reject with circumscribed radii before the exact border test.
                                    let b = body[j]
                                    let reach = Self.cutoffFactor * (a.radius + b.radius + Self.gap(a, b))
                                    if ex * ex + ey * ey >= reach * reach { continue }
                                    let force = Self.pairForce(a, b, ex: ex, ey: ey, salt: i &* 31 &+ j)
                                    accX += force.0
                                    accY += force.1
                                    fxp[j] -= force.0
                                    fyp[j] -= force.1
                                }
                                fxp[i] += accX
                                fyp[i] += accY
                            }
                        }
                    }
                }
            }
        }
        for i in 0..<n {
            dx[i] += fx[i]
            dy[i] += fy[i]
        }
    }

    /// Same forces as the exact path; neighbours come from a uniform grid (counting-sorted into flat
    /// arrays) whose cells are as large as the longest possible repulsion reach. Each pair is visited
    /// once: O(n · neighbours) per iteration.
    private func applyGridRepulsion(_ dx: inout [Double], _ dy: inout [Double]) {
        let maxRadius = bodies.map(\.radius).max() ?? 10
        let maxGap = bodies.map(\.gap).max() ?? GraphLayoutEngine.pointGap
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for i in 0..<count {
            minX = min(minX, x[i]); maxX = max(maxX, x[i])
            minY = min(minY, y[i]); maxY = max(maxY, y[i])
        }
        var cellSize = max(8, Self.cutoffFactor * (2 * maxRadius + maxGap))
        cellSize = max(cellSize, (maxX - minX) / 400, (maxY - minY) / 400)
        let columns = Int((maxX - minX) / cellSize) + 1
        let rows = Int((maxY - minY) / cellSize) + 1

        var cellOf = [Int](repeating: 0, count: count)
        var start = [Int](repeating: 0, count: columns * rows + 1)
        for i in 0..<count {
            let cell = Int((x[i] - minX) / cellSize) + Int((y[i] - minY) / cellSize) * columns
            cellOf[i] = cell
            start[cell + 1] += 1
        }
        for c in 0..<(columns * rows) { start[c + 1] += start[c] }
        var cursor = start
        var order = [Int](repeating: 0, count: count)
        for i in 0..<count {
            order[cursor[cellOf[i]]] = i
            cursor[cellOf[i]] += 1
        }

        var fx = [Double](repeating: 0, count: count)
        var fy = [Double](repeating: 0, count: count)
        bodies.withUnsafeBufferPointer { body in
            x.withUnsafeBufferPointer { px in
                y.withUnsafeBufferPointer { py in
                    fx.withUnsafeMutableBufferPointer { fxp in
                        fy.withUnsafeMutableBufferPointer { fyp in
                            for i in 0..<count {
                                let a = body[i], xi = px[i], yi = py[i]
                                let column = cellOf[i] % columns, row = cellOf[i] / columns
                                var accX = 0.0, accY = 0.0
                                for r in max(0, row - 1)...min(rows - 1, row + 1) {
                                    for c in max(0, column - 1)...min(columns - 1, column + 1) {
                                        let cell = c + r * columns
                                        for slot in start[cell]..<start[cell + 1] {
                                            let j = order[slot]
                                            guard j > i else { continue }
                                            let b = body[j]
                                            let ex = xi - px[j], ey = yi - py[j]
                                            let reach = Self.cutoffFactor * (a.radius + b.radius + Self.gap(a, b))
                                            if ex * ex + ey * ey >= reach * reach { continue }
                                            let force = Self.pairForce(a, b, ex: ex, ey: ey, salt: i &* 31 &+ j)
                                            accX += force.0
                                            accY += force.1
                                            fxp[j] -= force.0
                                            fyp[j] -= force.1
                                        }
                                    }
                                }
                                fxp[i] += accX
                                fyp[i] += accY
                            }
                        }
                    }
                }
            }
        }
        for i in 0..<count {
            dx[i] += fx[i]
            dy[i] += fy[i]
        }
    }

    // MARK: Overlap removal

    /// Pushes apart overlapping footprints (circles against circles, boxes otherwise) using a spatial
    /// hash, so the final picture never stacks nodes on top of each other.
    mutating func removeOverlaps() {
        guard count > 1 else { return }
        let maxExtent = bodies.map { max($0.halfWidth, $0.halfHeight) }.max() ?? 10
        let cellSize = max(8, maxExtent * 2 + (bodies.map(\.gap).max() ?? 30))
        for _ in 0..<60 {
            var buckets: [Int64: [Int]] = [:]
            buckets.reserveCapacity(count)
            for i in 0..<count {
                buckets[Self.bucketKey(Int64(floor(x[i] / cellSize)), Int64(floor(y[i] / cellSize))), default: []].append(i)
            }
            var moved = false
            for i in 0..<count {
                let cx = Int64(floor(x[i] / cellSize)), cy = Int64(floor(y[i] / cellSize))
                for ox in -1...1 {
                    for oy in -1...1 {
                        guard let bucket = buckets[Self.bucketKey(cx + Int64(ox), cy + Int64(oy))] else { continue }
                        for j in bucket where j > i {
                            if separate(i, j, padding: Self.minimumGap(bodies[i], bodies[j])) { moved = true }
                        }
                    }
                }
            }
            if !moved { break }
        }
    }

    @inline(__always)
    static func bucketKey(_ a: Int64, _ b: Int64) -> Int64 { (a &* 73_856_093) ^ (b &* 19_349_663) }

    /// Separates one pair if overlapping. Returns true when it moved anything.
    private mutating func separate(_ i: Int, _ j: Int, padding: Double) -> Bool {
        let a = bodies[i], b = bodies[j]
        if a.pinned && b.pinned { return false }
        var ex = x[j] - x[i], ey = y[j] - y[i]
        if abs(ex) < 0.001 && abs(ey) < 0.001 {
            let jitter = MapLayoutHash.unitPair(ids[j])
            ex = jitter.0 + 0.1
            ey = jitter.1
        }
        var pushX = 0.0, pushY = 0.0
        if !a.isRect && !b.isRect {
            let distance = (ex * ex + ey * ey).squareRoot()
            let minimum = a.radius + b.radius + padding
            guard distance < minimum else { return false }
            let overlap = minimum - distance
            pushX = ex / max(distance, 0.001) * overlap
            pushY = ey / max(distance, 0.001) * overlap
        } else {
            let overlapX = a.halfWidth + b.halfWidth + padding - abs(ex)
            let overlapY = a.halfHeight + b.halfHeight + padding - abs(ey)
            guard overlapX > 0, overlapY > 0 else { return false }
            if overlapX < overlapY {
                pushX = ex >= 0 ? overlapX : -overlapX
            } else {
                pushY = ey >= 0 ? overlapY : -overlapY
            }
        }
        let shareI = a.pinned ? 0.0 : (b.pinned ? 1.0 : 0.5)
        let shareJ = b.pinned ? 0.0 : (a.pinned ? 1.0 : 0.5)
        x[i] -= pushX * shareI
        y[i] -= pushY * shareI
        x[j] += pushX * shareJ
        y[j] += pushY * shareJ
        return true
    }

    // MARK: Output

    /// Fresh layouts are centred on the origin; anchored layouts keep the viewer's coordinate space.
    mutating func recenterIfFree() {
        guard !hasAnchors, !bodies.contains(where: \.pinned) else { return }
        let box = bounds
        let cx = Double(box.midX), cy = Double(box.midY)
        for i in 0..<count {
            x[i] -= cx
            y[i] -= cy
        }
    }

    var positions: [CGPoint] {
        (0..<count).map { CGPoint(x: x[$0], y: y[$0]) }
    }

    var bounds: CGRect {
        guard count > 0 else { return .zero }
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for i in 0..<count {
            minX = min(minX, x[i] - bodies[i].halfWidth)
            maxX = max(maxX, x[i] + bodies[i].halfWidth)
            minY = min(minY, y[i] - bodies[i].halfHeight)
            maxY = max(maxY, y[i] + bodies[i].halfHeight)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Stable hashing for deterministic seeding (never `Hasher`, which is randomised per process).
nonisolated enum MapLayoutHash {
    static func value(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Two values in -1…1 derived from the string.
    static func unitPair(_ string: String) -> (Double, Double) {
        let hash = value(string)
        let a = Double(hash & 0xFFFF) / 65535 * 2 - 1
        let b = Double((hash >> 16) & 0xFFFF) / 65535 * 2 - 1
        return (a, b)
    }
}
