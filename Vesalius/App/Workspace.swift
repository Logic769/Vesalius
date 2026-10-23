import AppKit
import Observation
import QueryEngine
import RepositoryScanner
import SwiftUI
import VesaliusCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview, map, health, files, symbols, architecture, search, diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .map: "System Map"
        case .health: "Health"
        case .files: "Files"
        case .symbols: "Symbols"
        case .architecture: "Architecture"
        case .search: "Ask"
        case .diagnostics: "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .map: "point.3.connected.trianglepath.dotted"
        case .health: "heart.fill"
        case .files: "doc.on.doc.fill"
        case .symbols: "curlybraces"
        case .architecture: "building.columns.fill"
        case .search: "text.magnifyingglass"
        case .diagnostics: "stethoscope"
        }
    }

    /// Navigation identity: cool hues for anatomy, warm for diagnosis, the rest for the index.
    var tint: Color {
        switch self {
        case .overview: Theme.Hue.blue
        case .map: Theme.Hue.purple
        case .architecture: Theme.Hue.indigo
        case .health: Theme.Hue.red
        case .diagnostics: Theme.Hue.orange
        case .files: Theme.Hue.gray
        case .symbols: Theme.Hue.green
        case .search: Theme.Hue.pink
        }
    }

    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((SidebarSection.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}

/// What the inspector is showing.
enum InspectorTarget: Hashable {
    case file(String)
    case symbol(String)
    case node(MapNode)
    case diagnostic(Diagnostic)
    case impact(String)
}

enum IndexState: Equatable {
    case idle
    case indexing(IndexProgress, initial: Bool)
    case failed(String)

    static func == (lhs: IndexState, rhs: IndexState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): true
        case (.failed(let a), .failed(let b)): a == b
        case (.indexing(let a, let ia), .indexing(let b, let ib)): a.phase == b.phase && a.completed == b.completed && ia == ib
        default: false
        }
    }
}

/// A weak reference that can cross concurrency boundaries (the referent is only used on the main actor).
final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

/// Runs work off the main actor (engine queries are synchronous and may touch SQLite).
nonisolated func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

/// One open repository: indexing lifecycle, cached query results and UI selection.
@Observable
final class Workspace {
    let engine: RepositoryEngine
    var section: SidebarSection = .overview
    var indexState: IndexState = .idle
    var lastSummary: IndexSummary?

    // Loaded data.
    var overview: RepositoryOverview?
    var files: [FileSummary] = []
    var symbols: [SymbolSummary] = []
    var symbolsLoaded = false
    var diagnostics: [Diagnostic] = []
    var loadError: String?
    var generation = 0

    // Inspector.
    var inspector: InspectorTarget?
    var showInspector = false
    private var history: [InspectorTarget] = []

    // Search.
    var askQuery = ""
    var askResult: AskResult?
    var isAsking = false

    let map = MapState()

    // Agents.
    var agentRequest: AgentRequest?

    private var indexTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var pendingReindex = false

    init(engine: RepositoryEngine) {
        self.engine = engine
    }

    var name: String { engine.root.lastPathComponent }
    var root: URL { engine.root }
    var hasData: Bool { overview != nil }

    var isIndexing: Bool {
        if case .indexing = indexState { return true }
        return false
    }

    // MARK: Lifecycle

    func start() {
        if engine.isIndexed {
            Task { await reload() }
            reindex(initial: false)
        } else {
            reindex(initial: true)
        }
        startWatching()
    }

    func close() {
        indexTask?.cancel()
        watcher?.stop()
        watcher = nil
    }

    private func startWatching() {
        guard Preferences.watchForChanges else { return }
        let reference = WeakReference(self)
        let watcher = FileWatcher(root: engine.root) { _ in
            Task { @MainActor in reference.value?.fileSystemChanged() }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func fileSystemChanged() {
        if isIndexing {
            pendingReindex = true
        } else {
            reindex(initial: false)
        }
    }

    /// Builds or incrementally updates the index without blocking the UI.
    func reindex(initial: Bool? = nil, rebuild: Bool = false) {
        guard !isIndexing else { return }
        let isInitial = initial ?? !engine.isIndexed
        indexState = .indexing(IndexProgress(phase: .scanning, completed: 0, total: 0), initial: isInitial || rebuild)
        let engine = self.engine
        var options = IndexOptions(computeEmbeddings: Preferences.semanticVectors, gitChurn: Preferences.gitHistory)
        options.scan.userExclusions = Preferences.exclusions(for: engine.root.path)
        let initialFlag = isInitial || rebuild
        let reference = WeakReference(self)
        indexTask = Task { [weak self] in
            do {
                let summary = try await engine.index(options: options, rebuild: rebuild) { progress in
                    Task { @MainActor in
                        guard let workspace = reference.value, case .indexing = workspace.indexState else { return }
                        workspace.indexState = .indexing(progress, initial: initialFlag)
                    }
                }
                guard let self else { return }
                self.lastSummary = summary
                self.indexState = .idle
                if summary.didChange || self.overview == nil || initialFlag {
                    await self.reload()
                }
            } catch is CancellationError {
                self?.indexState = .idle
            } catch {
                self?.indexState = .failed(error.localizedDescription)
            }
            if let self, self.pendingReindex {
                self.pendingReindex = false
                self.reindex(initial: false)
            }
        }
    }

    func cancelIndexing() {
        indexTask?.cancel()
    }

    /// Reloads every cached result after the index changed.
    func reload() async {
        let engine = self.engine
        do {
            async let overview = offMain { try engine.overview() }
            async let files = offMain { try engine.allFiles() }
            async let diagnostics = offMain { try engine.diagnostics(limit: 2000) }
            self.overview = try await overview
            self.files = try await files
            self.diagnostics = try await diagnostics
            if symbolsLoaded {
                symbols = try await offMain { try engine.allSymbols() }
            }
            loadError = nil
            generation += 1
            map.invalidate()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadSymbolsIfNeeded() async {
        guard !symbolsLoaded else { return }
        let engine = self.engine
        if let loaded = try? await offMain({ try engine.allSymbols() }) {
            symbols = loaded
            symbolsLoaded = true
        }
    }

    // MARK: Questions

    func ask(_ question: String? = nil) {
        if let question { askQuery = question }
        let query = askQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        section = .search
        isAsking = true
        let engine = self.engine
        Task {
            let result = try? await offMain { try engine.ask(query, limit: 12) }
            if self.askQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query {
                self.askResult = result
                self.isAsking = false
            }
        }
    }

    // MARK: Inspector navigation

    func inspect(_ target: InspectorTarget) {
        if let current = inspector, current != target { history.append(current) }
        inspector = target
        showInspector = true
    }

    var canGoBack: Bool { !history.isEmpty }

    func inspectorBack() {
        guard let previous = history.popLast() else { return }
        inspector = previous
    }

    func revealInMap(_ path: String) {
        section = .map
        map.focusFile(path, in: self)
    }

    // MARK: Agents

    /// Opens the agent sheet with a prompt built from a diagnostic and the blast radius of its main file.
    func improve(_ diagnostic: Diagnostic) {
        let engine = self.engine
        let name = self.name
        let primary = diagnostic.targets.first { $0.kind == .file || $0.kind == .symbol }?.path
        Task {
            let impact = try? await offMain { try primary.map { try engine.impact(of: $0, depth: 4) } }
            agentRequest = AgentRequest(
                title: diagnostic.title,
                subtitle: diagnostic.category.displayName,
                prompt: AgentPrompt.forDiagnostic(diagnostic, impact: impact ?? nil, repository: name),
                suggestedMode: diagnostic.rule == "dependency-cycle" || diagnostic.rule == "extraction-candidate" ? .plan : .edit
            )
        }
    }

    func planChange(_ impact: ImpactReport) {
        agentRequest = AgentRequest(title: "Plan a safe change to \(impact.target)", subtitle: "Change impact", prompt: AgentPrompt.forImpact(impact, repository: name), suggestedMode: .plan)
    }

    func planExtraction(_ suggestion: ExtractionSuggestion) {
        agentRequest = AgentRequest(title: "Extract \(suggestion.name) into a package", subtitle: "Architecture", prompt: AgentPrompt.forExtraction(suggestion, repository: name), suggestedMode: .plan)
    }

    // MARK: Editors

    func open(path: String, line: Int? = nil) {
        EditorLauncher.open(root.appendingPathComponent(path), line: line)
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path)])
    }
}
