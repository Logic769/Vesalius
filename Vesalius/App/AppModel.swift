import AppKit
import Observation
import QueryEngine
import RepositoryIndex
import SwiftUI
import VesaliusCore

/// A repository the user opened before.
struct RecentRepository: Codable, Hashable, Identifiable {
    var path: String
    var name: String
    var lastOpened: Date

    var id: String { path }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var url: URL { URL(fileURLWithPath: path) }
}

/// App-wide state: the open workspace and the recent-repositories list.
@Observable
final class AppModel {
    private(set) var workspace: Workspace?
    private(set) var recents: [RecentRepository] = []
    var openError: String?
    var showCommandPalette = false
    var paletteQuery = ""

    private static let recentsKey = "recentRepositories"
    /// Automated runs (`-VesaliusResetRecents YES`) keep their recents in a separate suite, so a UI test never
    /// clears the list of the person using the same build.
    private let recentsStore: UserDefaults

    init() {
        let arguments = UserDefaults.standard
        let automated = arguments.bool(forKey: "VesaliusResetRecents")
        recentsStore = automated ? UserDefaults(suiteName: "dev.vesalius.Vesalius.automation") ?? .standard : .standard
        loadRecents()
        if automated {
            recents = []
            saveRecents()
        }
        // Launch arguments let automated end-to-end runs open a repository without the folder picker:
        //   -VesaliusOpenRepository /path/to/repo  [-VesaliusSection map]
        if let path = arguments.string(forKey: "VesaliusOpenRepository"), !path.isEmpty {
            open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            if let section = arguments.string(forKey: "VesaliusSection").flatMap(SidebarSection.init(rawValue:)) {
                workspace?.section = section
            }
        }
        if let link = arguments.string(forKey: "VesaliusURL").flatMap(URL.init(string:)) {
            handle(link)
        }
    }

    // MARK: Deep links

    /// Handles `vesalius://open?repo=<path>&section=<map>&file=<path>&line=<n>&symbol=<name>&impact=<target>
    /// &ask=<question>&palette=<query>&improve=first` (used by the VS Code extension and automation),
    /// and plain folder URLs dropped on the app.
    func handle(_ url: URL) {
        guard url.scheme == "vesalius" else {
            if url.isFileURL { open(url) }
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }

        if let repo = value("repo") {
            let target = IndexLocation.canonicalRoot(URL(fileURLWithPath: (repo as NSString).expandingTildeInPath))
            if workspace?.root.path != target.path { open(target) }
        }
        guard let workspace else { return }
        if let section = value("section").flatMap(SidebarSection.init(rawValue:)) { workspace.section = section }
        if let file = value("file") {
            var relative = file
            if relative.hasPrefix(workspace.root.path + "/") { relative = String(relative.dropFirst(workspace.root.path.count + 1)) }
            workspace.inspect(.file(relative))
            if value("section") == "map" { workspace.revealInMap(relative) }
        }
        if let symbol = value("symbol") { workspace.inspect(.symbol(symbol)) }
        if let impact = value("impact") { workspace.inspect(.impact(impact)) }
        if let question = value("ask") { workspace.ask(question) }
        if let query = value("palette") {
            paletteQuery = query
            showCommandPalette = true
        }
        if value("improve") != nil {
            Task {
                while workspace.diagnostics.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                if let first = workspace.diagnostics.first {
                    workspace.inspect(.diagnostic(first))
                    workspace.improve(first)
                }
            }
        }
    }

    // MARK: Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Repository"
        panel.message = "Choose a repository or source folder. Vesalius reads it locally and never modifies it."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        do {
            let engine = try RepositoryEngine(repository: url)
            workspace?.close()
            let workspace = Workspace(engine: engine)
            self.workspace = workspace
            openError = nil
            remember(engine.root)
            workspace.start()
        } catch {
            openError = error.localizedDescription
            if let index = recents.firstIndex(where: { $0.path == url.path }), !recents[index].exists {
                recents.remove(at: index)
                saveRecents()
            }
        }
    }

    func closeWorkspace() {
        workspace?.close()
        workspace = nil
    }

    // MARK: Recents

    private func remember(_ url: URL) {
        recents.removeAll { $0.path == url.path }
        recents.insert(RecentRepository(path: url.path, name: url.lastPathComponent, lastOpened: Date()), at: 0)
        recents = Array(recents.prefix(12))
        saveRecents()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func removeRecent(_ recent: RecentRepository) {
        recents.removeAll { $0.id == recent.id }
        saveRecents()
    }

    func clearRecents() {
        recents = []
        saveRecents()
    }

    private func loadRecents() {
        guard let data = recentsStore.data(forKey: Self.recentsKey),
              let decoded = try? JSONDecoder().decode([RecentRepository].self, from: data) else { return }
        recents = decoded
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            recentsStore.set(data, forKey: Self.recentsKey)
        }
    }

    /// Indexed repositories on this Mac that are not in the recents list (e.g. indexed from the CLI).
    var otherIndexedRepositories: [IndexedRepositoryRecord] {
        let known = Set(recents.map(\.path))
        return IndexLocation.allIndexed().filter { $0.exists && !known.contains($0.path) }
    }
}
