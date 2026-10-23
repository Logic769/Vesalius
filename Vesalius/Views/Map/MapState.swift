import Observation
import QueryEngine
import SwiftUI
import VesaliusCore

/// Navigation and display state of the System Map.
@Observable
final class MapState {
    struct Location: Hashable {
        var level: MapLevel
        var focus: String?
    }

    var location = Location(level: .modules, focus: nil)
    private(set) var backStack: [Location] = []
    var graph: MapGraph?
    var isLoading = false
    var error: String?

    var selection: String?
    var hovered: MapNode?
    var searchText = ""
    var colorMode: MapColorMode = .area
    var edgeFilter: MapEdgeFilter = .all
    var showLabels = true
    var includeTests = false
    var fitToken = 0
    var zoomToken: (Int, Double) = (0, 1)
    private var loadedKey: String?

    var highlighted: Set<String> {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty, let graph else { return [] }
        return Set(graph.nodes.filter { $0.label.lowercased().contains(query) || ($0.path?.lowercased().contains(query) ?? false) }.map(\.id))
    }

    var selectedNode: MapNode? {
        guard let selection else { return nil }
        return graph?.nodes.first { $0.id == selection }
    }

    func invalidate() {
        loadedKey = nil
    }

    private var key: String { "\(location.level.rawValue)|\(location.focus ?? "")|\(includeTests)" }

    func load(_ workspace: Workspace, force: Bool = false) async {
        let key = self.key
        guard force || key != loadedKey || graph == nil else { return }
        isLoading = true
        let engine = workspace.engine
        let location = self.location
        let options = MapOptions(includeTests: includeTests, maxNodes: 260)
        do {
            let graph = try await offMain { try engine.map(level: location.level, focus: location.focus, options: options) }
            guard self.key == key else { return }
            self.graph = graph
            self.error = nil
            loadedKey = key
            if let selection, !graph.nodes.contains(where: { $0.id == selection }) { self.selection = nil }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func navigate(to location: Location, in workspace: Workspace) {
        guard location != self.location else { return }
        backStack.append(self.location)
        self.location = location
        selection = nil
        Task { await load(workspace) }
    }

    func back(in workspace: Workspace) {
        guard let previous = backStack.popLast() else { return }
        location = previous
        selection = nil
        Task { await load(workspace) }
    }

    var canGoBack: Bool { !backStack.isEmpty }

    /// Drill into a node: areas/folders show their contents, files show their symbols.
    func activate(_ node: MapNode, in workspace: Workspace) {
        switch node.kind {
        case .module, .directory:
            let level: MapLevel = node.files <= 40 ? .files : .directories
            navigate(to: Location(level: level, focus: node.id), in: workspace)
        case .external:
            if node.id.hasPrefix("ext|") {
                navigate(to: Location(level: .directories, focus: String(node.id.dropFirst(4))), in: workspace)
            } else if let path = node.path {
                navigate(to: Location(level: .symbols, focus: NodeID.file(path)), in: workspace)
            }
        case .file:
            if let path = node.path { navigate(to: Location(level: .symbols, focus: NodeID.file(path)), in: workspace) }
        case .symbol:
            break
        }
    }

    func focusFile(_ path: String, in workspace: Workspace) {
        navigate(to: Location(level: .files, focus: NodeID.file(path)), in: workspace)
        selection = NodeID.file(path)
    }

    func jump(to crumb: MapBreadcrumb, in workspace: Workspace) {
        if crumb.id == "root" {
            navigate(to: Location(level: .modules, focus: nil), in: workspace)
        } else if crumb.id.hasPrefix("file:") {
            navigate(to: Location(level: .symbols, focus: crumb.id), in: workspace)
        } else {
            navigate(to: Location(level: .directories, focus: crumb.id), in: workspace)
        }
    }
}
