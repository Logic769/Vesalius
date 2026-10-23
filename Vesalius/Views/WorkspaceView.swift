import AppKit
import QueryEngine
import SwiftUI
import VesaliusCore

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Bindable var workspace: Workspace

    var body: some View {
        let split = NavigationSplitView {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(minWidth: 520, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        }
        Group {
            split.inspector(isPresented: $workspace.showInspector) {
                InspectorView(workspace: workspace)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            }
        }
        .navigationTitle(workspace.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .overlay {
            if model.showCommandPalette {
                CommandPalette(workspace: workspace, initialQuery: model.paletteQuery) {
                    model.showCommandPalette = false
                    model.paletteQuery = ""
                }
            }
        }
        .focusedSceneValue(\.workspaceSection, workspace.section)
        .sheet(item: $workspace.agentRequest) { request in
            AgentSheet(workspace: workspace, request: request)
        }
        .task { AgentAvailability.shared.refresh() }
    }

    private var subtitle: String {
        if let info = workspace.overview?.repository, let branch = info.branch { return branch }
        return (workspace.root.path as NSString).abbreviatingWithTildeInPath
    }

    @ViewBuilder
    private var detail: some View {
        if case .indexing(let progress, initial: true) = workspace.indexState, !workspace.hasData {
            IndexingView(workspace: workspace, progress: progress)
        } else if case .failed(let message) = workspace.indexState, !workspace.hasData {
            ContentUnavailableView {
                Label("Indexing Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { workspace.reindex(rebuild: true) }
            }
        } else if !workspace.hasData {
            Text("Loading index…").font(Theme.Font.small).foregroundStyle(Theme.Colors.text3)
        } else {
            switch workspace.section {
            case .overview: OverviewView(workspace: workspace)
            case .map: MapScreen(workspace: workspace)
            case .health: HealthView(workspace: workspace)
            case .files: FilesView(workspace: workspace)
            case .symbols: SymbolsView(workspace: workspace)
            case .architecture: ArchitectureView(workspace: workspace)
            case .search: AskView(workspace: workspace)
            case .diagnostics: DiagnosticsView(workspace: workspace)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.showCommandPalette = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search files, symbols and diagnostics (⌘K)")
            .accessibilityIdentifier("open-command-palette")

            Button {
                workspace.reindex(initial: false)
            } label: {
                Label("Update Index", systemImage: "arrow.clockwise")
            }
            .help("Update the index (⌘R)")
            .disabled(workspace.isIndexing)

            Button {
                workspace.showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

struct WorkspaceSectionKey: FocusedValueKey {
    typealias Value = SidebarSection
}

extension FocusedValues {
    var workspaceSection: SidebarSection? {
        get { self[WorkspaceSectionKey.self] }
        set { self[WorkspaceSectionKey.self] = newValue }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var workspace: Workspace

    var body: some View {
        List(selection: Binding(get: { workspace.section }, set: { if let value = $0 { workspace.section = value } })) {
            Section("Anatomy") {
                row(.overview)
                row(.map)
                row(.architecture)
            }
            Section("Diagnosis") {
                row(.health)
                row(.diagnostics, badge: workspace.diagnostics.filter { $0.severity >= .high }.count)
            }
            Section("Index") {
                row(.files, badge: nil)
                row(.symbols)
                row(.search)
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar")
    }

    private func row(_ section: SidebarSection, badge: Int? = nil) -> some View {
        Label {
            Text(section.title)
        } icon: {
            IconTile(systemImage: section.systemImage, color: section.tint)
        }
        .badge(badge ?? 0)
        .tag(section)
        .accessibilityIdentifier("sidebar-\(section.rawValue)")
    }
}

private struct SidebarFooter: View {
    let overview: RepositoryOverview

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Divider()
            HStack(spacing: Theme.Space.s) {
                ScoreGauge(score: overview.health.score, diameter: 26, lineWidth: 3, showsNumber: false)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Health \(overview.health.score)").font(Theme.Font.rowTitle)
                    Text("\(overview.stats.sourceFiles.grouped) source files").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
    }
}

// MARK: - Index status

struct IndexStatusView: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            switch workspace.indexState {
            case .indexing(let progress, _):
                ProgressView().controlSize(.small)
                Text(progress.phase.displayName + (progress.total > 1 ? " \(progress.completed)/\(progress.total)" : ""))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Colors.text2)
                    .monospacedDigit()
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Colors.warning)
                Text("Index update failed").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text2).help(message)
            case .idle:
                if let summary = workspace.lastSummary {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.Colors.text3)
                    Text("Indexed \(summary.filesScanned.grouped) files").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                }
            }
        }
        .frame(width: 230, height: 22, alignment: .leading)
        .accessibilityIdentifier("index-status")
    }
}

/// First-time indexing: the one moment where a full-screen progress view is appropriate.
struct IndexingView: View {
    let workspace: Workspace
    let progress: IndexProgress

    private let phases: [IndexPhase] = [.scanning, .analyzing, .resolving, .graph, .health, .embeddings]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Indexing \(workspace.name)").font(Theme.Font.title)
            Text("Vesalius is reading the repository once to build its graph. Later updates are incremental and only re-parse changed files.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Colors.text2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(phases, id: \.self) { phase in
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: icon(for: phase))
                            .foregroundStyle(phase == progress.phase ? Theme.Colors.accent : Theme.Colors.text3)
                            .frame(width: 16)
                        Text(phase.displayName)
                            .font(phase == progress.phase ? Theme.Font.rowTitle : Theme.Font.body)
                            .foregroundStyle(order(of: phase) <= order(of: progress.phase) ? Theme.Colors.text1 : Theme.Colors.text3)
                        if phase == progress.phase && progress.total > 1 {
                            Text("\(progress.completed.grouped) of \(progress.total.grouped)")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Colors.text3)
                                .monospacedDigit()
                        }
                    }
                }
            }
            if progress.total > 1 {
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if let path = progress.currentPath {
                Text(path).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3).lineLimit(1).truncationMode(.middle)
            }
            Button("Stop") { workspace.cancelIndexing() }
                .keyboardShortcut(".")
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(Theme.Space.xxl)
        .accessibilityIdentifier("indexing-view")
    }

    private func order(of phase: IndexPhase) -> Int { phases.firstIndex(of: phase) ?? phases.count }

    private func icon(for phase: IndexPhase) -> String {
        if order(of: phase) < order(of: progress.phase) { return "checkmark.circle.fill" }
        if phase == progress.phase { return "circle.dotted" }
        return "circle"
    }
}
