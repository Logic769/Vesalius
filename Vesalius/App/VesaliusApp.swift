import AppKit
import SwiftUI
import VesaliusCore

struct VesaliusApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Vesalius", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1060, minHeight: 680)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { VesaliusCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct VesaliusCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") { model.presentOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(model.recents) { recent in
                    Button(recent.name) { model.open(recent.url) }
                        .disabled(!recent.exists)
                }
                if !model.recents.isEmpty {
                    Divider()
                    Button("Clear Menu") { model.clearRecents() }
                }
            }
            Divider()
            Button("Close Repository") { model.closeWorkspace() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.workspace == nil)
        }

        CommandMenu("Repository") {
            Button("Update Index") { model.workspace?.reindex(initial: false) }
                .keyboardShortcut("r")
                .disabled(model.workspace == nil || model.workspace?.isIndexing == true)
            Button("Rebuild Index") { model.workspace?.reindex(rebuild: true) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.workspace == nil || model.workspace?.isIndexing == true)
            Button("Stop Indexing") { model.workspace?.cancelIndexing() }
                .keyboardShortcut(".")
                .disabled(model.workspace?.isIndexing != true)
            Divider()
            Button("Reveal in Finder") {
                if let root = model.workspace?.root { NSWorkspace.shared.activateFileViewerSelecting([root]) }
            }
            .disabled(model.workspace == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Command Palette…") { model.showCommandPalette = true }
                .keyboardShortcut("k")
                .disabled(model.workspace == nil)
            Button("Ask a Question…") { model.workspace?.section = .search }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.workspace == nil)
            Divider()
            ForEach(SidebarSection.allCases) { section in
                Button(section.title) { model.workspace?.section = section }
                    .keyboardShortcut(section.shortcut)
                    .disabled(model.workspace == nil)
            }
            Divider()
            Button("Toggle Inspector") { model.workspace?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.workspace == nil)
            Button("Back") {
                guard let workspace = model.workspace else { return }
                if workspace.section == .map, workspace.map.canGoBack {
                    workspace.map.back(in: workspace)
                } else {
                    workspace.inspectorBack()
                }
            }
            .keyboardShortcut("[")
            .disabled(model.workspace == nil)
        }

        CommandMenu("Map") {
            Button("Zoom to Fit") { model.workspace?.map.fitToken += 1 }
                .keyboardShortcut("0")
                .disabled(model.workspace?.section != .map)
            Button("Zoom In") {
                guard let map = model.workspace?.map else { return }
                map.zoomToken = (map.zoomToken.0 + 1, 1.35)
            }
            .keyboardShortcut("=")
            .disabled(model.workspace?.section != .map)
            Button("Zoom Out") {
                guard let map = model.workspace?.map else { return }
                map.zoomToken = (map.zoomToken.0 + 1, 1 / 1.35)
            }
            .keyboardShortcut("-")
            .disabled(model.workspace?.section != .map)
            Divider()
            Button("Show Top Level") {
                guard let workspace = model.workspace else { return }
                workspace.section = .map
                workspace.map.navigate(to: .init(level: .modules, focus: nil), in: workspace)
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])
            .disabled(model.workspace == nil)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let workspace = model.workspace {
                WorkspaceView(workspace: workspace)
                    .id(ObjectIdentifier(workspace))
            } else {
                WelcomeView()
            }
        }
        .onOpenURL { url in model.handle(url) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            model.open(url)
            return true
        }
    }
}
