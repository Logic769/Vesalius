import AppKit
import VesaliusCore

/// How a node is drawn.
enum MapNodeShape {
    /// Module or folder: rounded card with a title and size line.
    case card
    /// An area outside the current focus: dashed card.
    case ghostCard
    /// A file: circle sized by lines of code.
    case circle
    /// A symbol: rounded square with a kind glyph.
    case square
    /// A symbol in another file: dashed square.
    case ghostSquare

    var isRect: Bool { self == .card || self == .ghostCard }
    var isGhost: Bool { self == .ghostCard || self == .ghostSquare }
}

/// One node's drawable state: geometry in world points plus transition bookkeeping.
struct MapNodeVisual {
    var node: MapNode
    var shape: MapNodeShape
    /// Footprint in world points.
    var size: CGSize
    var groupKey: String
    /// 0…1: decides which labels win when space is tight.
    var importance: Double
    /// Relative size within the graph (0…1).
    var sizeShare: Double

    var position: CGPoint = .zero
    var from: CGPoint = .zero
    var to: CGPoint = .zero
    /// 0 → 1 while a node grows in; 1 when settled.
    var appear: CGFloat = 1
    var appearFrom: CGFloat = 1
    /// 1 → 0 while a node leaves.
    var fade: CGFloat = 1

    var id: String { node.id }

    func frame(at point: CGPoint, scale: CGFloat = 1) -> CGRect {
        CGRect(x: point.x - size.width * scale / 2, y: point.y - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
    }
}

/// The renderable form of a `MapGraph`: visuals, resolved edges and adjacency.
struct MapScene {
    var graph: MapGraph?
    var visuals: [MapNodeVisual] = []
    var index: [String: Int] = [:]
    var edges: [MapEdge] = []
    /// Resolved (source, target) visual indices per edge.
    var endpoints: [(source: Int, target: Int)] = []
    var incoming: [[Int]] = []
    var outgoing: [[Int]] = []

    static func build(_ graph: MapGraph, text: MapTextCache) -> MapScene {
        var scene = MapScene()
        scene.graph = graph
        let maxCardLines = max(1, graph.nodes.filter { $0.kind == .module || $0.kind == .directory }.map(\.lines).max() ?? 1)
        let maxLines = max(1, graph.nodes.map(\.lines).max() ?? 1)
        for node in graph.nodes {
            scene.index[node.id] = scene.visuals.count
            scene.visuals.append(makeVisual(node, maxLines: maxLines, maxCardLines: maxCardLines, text: text))
        }
        scene.incoming = Array(repeating: [], count: scene.visuals.count)
        scene.outgoing = Array(repeating: [], count: scene.visuals.count)
        for edge in graph.edges {
            guard let source = scene.index[edge.source], let target = scene.index[edge.target], source != target else { continue }
            let edgeIndex = scene.edges.count
            scene.edges.append(edge)
            scene.endpoints.append((source, target))
            scene.outgoing[source].append(edgeIndex)
            scene.incoming[target].append(edgeIndex)
        }
        return scene
    }

    /// Updates node attributes (metrics, diagnostics) without touching geometry or positions.
    mutating func refresh(with graph: MapGraph, text: MapTextCache) {
        self.graph = graph
        let maxCardLines = max(1, graph.nodes.filter { $0.kind == .module || $0.kind == .directory }.map(\.lines).max() ?? 1)
        let maxLines = max(1, graph.nodes.map(\.lines).max() ?? 1)
        for node in graph.nodes {
            guard let i = index[node.id] else { continue }
            let fresh = Self.makeVisual(node, maxLines: maxLines, maxCardLines: maxCardLines, text: text)
            visuals[i].node = node
            visuals[i].importance = fresh.importance
            visuals[i].sizeShare = fresh.sizeShare
            visuals[i].groupKey = fresh.groupKey
        }
        var byID: [String: MapEdge] = [:]
        for edge in graph.edges { byID[edge.id] = edge }
        for i in edges.indices {
            if let updated = byID[edges[i].id] { edges[i] = updated }
        }
    }

    /// Identity of the graph's structure: when it changes the map is laid out again.
    static func structureKey(_ graph: MapGraph) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0x1F
            hash = hash &* 0x0000_0100_0000_01B3
        }
        mix(graph.level.rawValue)
        mix(graph.focus ?? "∅")
        for id in graph.nodes.map(\.id).sorted() { mix(id) }
        for id in graph.edges.map(\.id).sorted() { mix(id) }
        return hash
    }

    var contentCenter: CGPoint {
        guard !visuals.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for visual in visuals {
            x += visual.position.x
            y += visual.position.y
        }
        return CGPoint(x: x / CGFloat(visuals.count), y: y / CGFloat(visuals.count))
    }

    /// Union of node frames at their resting positions.
    var restingBounds: CGRect {
        visuals.reduce(CGRect.null) { $0.union($1.frame(at: $1.to)) }
    }

    // MARK: Sizing

    static let cardTitleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let cardDetailFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    static let ghostTitleFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    private static func makeVisual(_ node: MapNode, maxLines: Int, maxCardLines: Int, text: MapTextCache) -> MapNodeVisual {
        let shape: MapNodeShape
        switch node.kind {
        case .module, .directory: shape = .card
        case .file: shape = .circle
        case .symbol: shape = .square
        case .external: shape = node.symbolKind == nil ? .ghostCard : .ghostSquare
        }
        let share = (Double(max(0, node.lines)) / Double(max(1, shape == .card ? maxCardLines : maxLines))).squareRoot()
        var size: CGSize
        switch shape {
        case .card:
            let title = text.width(node.label, font: cardTitleFont)
            let detail = text.width(cardDetail(node), font: cardDetailFont)
            let width = min(250, max(132, max(title, detail) + 52)) + 34 * share
            size = CGSize(width: width.rounded(), height: (50 + 10 * share).rounded())
        case .ghostCard:
            let title = text.width(node.label, font: ghostTitleFont)
            size = CGSize(width: min(210, max(92, title + 30)).rounded(), height: 32)
        case .circle:
            let radius = min(17, max(4.5, 4 + Double(max(0, node.lines)).squareRoot() * 0.34))
            size = CGSize(width: radius * 2, height: radius * 2)
        case .square:
            let side = min(30, max(18, 15 + Double(max(0, node.lines)).squareRoot() * 0.6))
            size = CGSize(width: side, height: side)
        case .ghostSquare:
            size = CGSize(width: 16, height: 16)
        }
        let importance: Double
        switch shape {
        case .card, .ghostCard:
            importance = 1
        case .circle, .square, .ghostSquare:
            importance = min(1, 0.5 * node.centrality + 0.35 * share + 0.15 * min(1, Double(node.fanIn) / 12))
        }
        let groupKey = node.group ?? node.label
        return MapNodeVisual(node: node, shape: shape, size: size, groupKey: groupKey, importance: importance, sizeShare: share)
    }

    /// "43 files · 15.1k lines"
    static func cardDetail(_ node: MapNode) -> String {
        var parts: [String] = []
        if node.kind != .file && node.kind != .symbol {
            parts.append("\(compact(node.files)) file\(node.files == 1 ? "" : "s")")
        }
        parts.append("\(compact(node.lines)) lines")
        return parts.joined(separator: " · ")
    }

    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        case ..<10_000: return String(format: "%.1fk", Double(value) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        case ..<1_000_000: return "\(Int((Double(value) / 1_000).rounded()))k"
        default: return String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    /// One-letter glyph for symbol nodes.
    static func glyph(for kind: SymbolKind?) -> String {
        guard let kind else { return "•" }
        switch kind {
        case .class: return "C"
        case .struct: return "S"
        case .enum: return "E"
        case .protocol: return "P"
        case .interface: return "I"
        case .actor: return "A"
        case .extension: return "X"
        case .typeAlias: return "T"
        case .function: return "f"
        case .method: return "m"
        case .initializer: return "i"
        case .property: return "v"
        case .variable: return "v"
        case .constant: return "k"
        case .enumCase: return "c"
        case .namespace: return "N"
        case .macro: return "#"
        case .component: return "R"
        }
    }
}

/// Caches text measurements and fonts so drawing does not allocate per frame.
final class MapTextCache {
    private var widths: [String: CGFloat] = [:]
    private var fonts: [Int: NSFont] = [:]

    func width(_ string: String, font: NSFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(string)"
        if let width = widths[key] { return width }
        let width = ceil((string as NSString).size(withAttributes: [.font: font]).width)
        if widths.count > 4_000 { widths.removeAll(keepingCapacity: true) }
        widths[key] = width
        return width
    }

    /// System font quantised to quarter points.
    func font(size: CGFloat, weight: NSFont.Weight, monospacedDigits: Bool = false) -> NSFont {
        let quantised = (size * 4).rounded() / 4
        let key = Int(quantised * 4) * 100 + Int((weight.rawValue + 1) * 40) + (monospacedDigits ? 1 : 0)
        if let font = fonts[key] { return font }
        let font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: quantised, weight: weight)
            : NSFont.systemFont(ofSize: quantised, weight: weight)
        fonts[key] = font
        return font
    }
}
