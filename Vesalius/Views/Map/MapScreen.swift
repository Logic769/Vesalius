import QueryEngine
import SwiftUI
import VesaliusCore

struct MapScreen: View {
    @Bindable var workspace: Workspace
    private var map: MapState { workspace.map }

    var body: some View {
        @Bindable var map = workspace.map
        ZStack(alignment: .topLeading) {
            if let graph = map.graph {
                GraphCanvas(
                    graph: graph,
                    selection: map.selection,
                    highlighted: map.highlighted,
                    edgeFilter: map.edgeFilter,
                    colorMode: map.colorMode,
                    showLabels: map.showLabels,
                    fitToken: map.fitToken,
                    zoomToken: map.zoomToken,
                    onSelect: { node in
                        map.selection = node?.id
                        if let node { workspace.inspect(.node(node)) }
                    },
                    onActivate: { node in map.activate(node, in: workspace) },
                    onHover: { node in map.hovered = node }
                )
                if graph.nodes.isEmpty {
                    ContentUnavailableView("Nothing to Map Here", systemImage: "point.3.connected.trianglepath.dotted", description: Text("This level has no source files. Go back or include tests."))
                }
            } else if let error = map.error {
                ContentUnavailableView("Map Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                breadcrumbBar
                Spacer()
                HStack(alignment: .bottom) {
                    legend
                    Spacer()
                    VStack(alignment: .trailing, spacing: Theme.Space.s) {
                        if let hovered = map.hovered {
                            HoverCard(node: hovered)
                        }
                        zoomControls
                    }
                }
            }
            .padding(Theme.Space.m)
        }
        .toolbar { mapToolbar }
        .task(id: workspace.generation) { await map.load(workspace) }
        .onChange(of: map.includeTests) { Task { await map.load(workspace) } }
        .onKeyPress(.escape) {
            if map.selection != nil {
                map.selection = nil
                return .handled
            }
            if map.canGoBack {
                map.back(in: workspace)
                return .handled
            }
            return .ignored
        }
        .accessibilityIdentifier("map-screen")
    }

    private var breadcrumbBar: some View {
        HStack(spacing: Theme.Space.xs) {
            Button {
                map.back(in: workspace)
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!map.canGoBack)
            .help("Back (⌘[)")
            if let graph = map.graph {
                ForEach(Array(graph.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.Colors.text3)
                    }
                    Button(crumb.label) { map.jump(to: crumb, in: workspace) }
                        .buttonStyle(.plain)
                        .font(index == graph.breadcrumbs.count - 1 ? Theme.Font.rowTitle : Theme.Font.small)
                        .foregroundStyle(index == graph.breadcrumbs.count - 1 ? Theme.Colors.text1 : Theme.Colors.text2)
                }
                Text("·").foregroundStyle(Theme.Colors.text3)
                Text(levelDescription(graph)).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
            }
            if map.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
        .accessibilityIdentifier("map-breadcrumbs")
    }

    private func levelDescription(_ graph: MapGraph) -> String {
        let kind: String
        switch graph.level {
        case .modules: kind = "areas"
        case .directories: kind = "folders and files"
        case .files: kind = graph.focus?.hasPrefix("file:") == true ? "files in the neighbourhood" : "files"
        case .symbols: kind = "symbols"
        }
        var text = "\(graph.nodes.filter { $0.kind != .external }.count) \(kind), \(graph.edges.count) dependencies"
        if graph.hiddenNodes > 0 { text += ", \(graph.hiddenNodes) smaller hidden" }
        return text
    }

    /// Zoom lives in the canvas corner, like Maps: big targets near where the eye already is.
    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button { map.zoomToken = (map.zoomToken.0 + 1, 1 / 1.35) } label: {
                Image(systemName: "minus").frame(width: 30, height: 26)
            }
            .help("Zoom Out (⌘−)")
            Divider().frame(height: 16)
            Button { map.fitToken += 1 } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 30, height: 26)
            }
            .help("Zoom to Fit (⌘0)")
            Divider().frame(height: 16)
            Button { map.zoomToken = (map.zoomToken.0 + 1, 1.35) } label: {
                Image(systemName: "plus").frame(width: 30, height: 26)
            }
            .help("Zoom In (⌘+)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.Colors.text2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
        .accessibilityIdentifier("map-zoom")
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            LegendRow(color: Color(nsColor: .systemBlue), text: "Dependents of selection")
            LegendRow(color: Color(nsColor: .systemOrange), text: "Dependencies of selection")
            LegendRow(color: Theme.Colors.danger, text: "Cycle", dashed: true)
            Text("Double-click to drill in. Esc to go back.").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
        }
        .padding(Theme.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
    }

    @ToolbarContentBuilder
    private var mapToolbar: some ToolbarContent {
        @Bindable var map = workspace.map
        ToolbarItemGroup {
            TextField("Find in map", text: $map.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .accessibilityIdentifier("map-search")
            Picker("Show", selection: $map.edgeFilter) {
                Text("All").tag(MapEdgeFilter.all)
                Text("Dependents").tag(MapEdgeFilter.incoming)
                Text("Dependencies").tag(MapEdgeFilter.outgoing)
            }
            .pickerStyle(.segmented)
            .help("Which relationships of the selected node to emphasise")
            Menu {
                Picker("Colour by", selection: $map.colorMode) {
                    Text("Area").tag(MapColorMode.area)
                    Text("Language").tag(MapColorMode.language)
                    Text("Health").tag(MapColorMode.health)
                    Text("Change risk").tag(MapColorMode.risk)
                }
                Divider()
                Toggle("File Labels", isOn: $map.showLabels)
                Toggle("Include Tests", isOn: $map.includeTests)
            } label: {
                Label("Display", systemImage: "paintpalette")
            }
        }
    }
}

private struct LegendRow: View {
    let color: Color
    let text: String
    var dashed = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 18, y: 4))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 3] : []))
            .frame(width: 18, height: 8)
            Text(text).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text2)
        }
    }
}

private struct HoverCard: View {
    let node: MapNode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(node.label).font(Theme.Font.rowTitle)
            if let path = node.path, node.kind != .module {
                Text(path).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3).lineLimit(1)
            }
            Text(details).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text2)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
    }

    private var details: String {
        var parts: [String] = []
        switch node.kind {
        case .symbol:
            if let kind = node.symbolKind { parts.append(kind.displayName) }
            parts.append("\(node.lines) lines")
        default:
            if node.files > 1 { parts.append("\(node.files) files") }
            parts.append("\(node.lines.grouped) lines")
        }
        parts.append("in \(node.fanIn) · out \(node.fanOut)")
        if node.diagnostics > 0 { parts.append("\(node.diagnostics) issue\(node.diagnostics == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
