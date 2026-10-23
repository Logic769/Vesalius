import AppKit
import SwiftUI
import VesaliusCore

/// How map nodes are coloured.
enum MapColorMode: String, CaseIterable, Identifiable {
    case area, language, health, risk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Area"
        case .language: "Language"
        case .health: "Health"
        case .risk: "Change Risk"
        }
    }
}

/// Which relationships of the selected node are emphasised.
enum MapEdgeFilter: String, CaseIterable, Identifiable {
    case all, incoming, outgoing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .incoming: "Dependents"
        case .outgoing: "Dependencies"
        }
    }
}

/// SwiftUI wrapper around `GraphCanvasView`.
struct GraphCanvas: NSViewRepresentable {
    var graph: MapGraph
    /// Selected node id.
    var selection: String?
    /// Search matches.
    var highlighted: Set<String>
    /// For the selected node: all, only incoming (dependents) or only outgoing (dependencies) edges.
    var edgeFilter: MapEdgeFilter
    var colorMode: MapColorMode
    var showLabels: Bool
    /// Increment to animate a fit-to-view.
    var fitToken: Int
    /// (counter, factor): increment the counter to animate a zoom by `factor` around the view centre.
    var zoomToken: (Int, Double)
    var onSelect: (MapNode?) -> Void
    /// Double-click: drill in.
    var onActivate: (MapNode) -> Void
    var onHover: (MapNode?) -> Void

    func makeNSView(context: Context) -> GraphCanvasView {
        let view = GraphCanvasView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: GraphCanvasView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GraphCanvasView) {
        view.onSelect = onSelect
        view.onActivate = onActivate
        view.onHover = onHover
        view.update(
            graph: graph,
            selection: selection,
            highlighted: highlighted,
            edgeFilter: edgeFilter,
            colorMode: colorMode,
            showLabels: showLabels,
            fitToken: fitToken,
            zoomToken: zoomToken
        )
    }
}
