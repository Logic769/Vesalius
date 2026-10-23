import Foundation
import QueryEngine
import VesaliusCore

/// Owns the server's engine and keeps its index fresh.
///
/// - The engine is created on the first tool call, so `initialize` and `tools/list` never touch the repository.
/// - Refreshes are single-flight: calls that arrive while one runs wait for it instead of starting another, and
///   the staleness scan runs at most every 10 seconds.
/// - Before every call the engine drops its caches if another process (the app, the CLI) re-indexed since.
/// - The result of a call that waited for a build says so: `index: built just now (865 files, 5.1 s)`.
actor IndexCoordinator {
    struct Prepared: Sendable {
        let engine: RepositoryEngine
        /// The first line of this call's result, when it waited for indexing.
        let note: String?
    }

    private struct Refresh: Sendable {
        let summary: IndexSummary?
        /// The repository had no index before this run.
        let built: Bool
    }

    let repository: URL
    private let options: IndexOptions
    private let throttle: TimeInterval
    private let log: @Sendable (String) -> Void
    private var engine: RepositoryEngine?
    private var running: (id: Int, task: Task<Refresh, Error>)?
    private var runs = 0
    private var lastCheck: Date?

    init(repository: URL, options: IndexOptions = IndexOptions(), throttle: TimeInterval = 10, log: @escaping @Sendable (String) -> Void) {
        self.repository = repository
        self.options = options
        self.throttle = throttle
        self.log = log
    }

    /// The engine, its index brought up to date (or joined to the refresh already running), its caches current.
    func prepare() async throws -> Prepared {
        let engine = try currentEngine()
        var refresh: Refresh?
        do {
            if let running {
                refresh = try await finish(running)
            } else if needsCheck(engine) {
                refresh = try await start(engine: engine, force: false)
            }
        } catch {
            // An index that exists still answers; only a repository that was never indexed fails the call.
            guard engine.isIndexed else { throw error }
            log("index refresh failed: \(error.localizedDescription); answering from the existing index")
        }
        engine.refreshCachesIfIndexChanged()
        return Prepared(engine: engine, note: refresh.flatMap(Self.note))
    }

    /// Re-indexes now, after any refresh already running, and returns how many files changed. Used when a result
    /// quoted lines that no longer match the files.
    func reindexNow() async throws -> Int {
        let engine = try currentEngine()
        while let running { _ = try? await finish(running) }
        let refresh = try await start(engine: engine, force: true)
        return refresh.summary.map(Self.changedFiles) ?? 0
    }

    // MARK: -

    private func currentEngine() throws -> RepositoryEngine {
        if let engine { return engine }
        do {
            let created = try RepositoryEngine(repository: repository)
            engine = created
            return created
        } catch {
            throw EngineError.invalidQuery("\(error.localizedDescription) Start `vesalius mcp` with --repo <path> (or set VESALIUS_REPO), or run it inside a repository.")
        }
    }

    private func needsCheck(_ engine: RepositoryEngine) -> Bool {
        guard let lastCheck, Date().timeIntervalSince(lastCheck) < throttle else { return true }
        return !engine.isIndexed
    }

    /// Starts a refresh off the actor (indexing must not hold up other calls' cache checks) and waits for it.
    private func start(engine: RepositoryEngine, force: Bool) async throws -> Refresh {
        runs += 1
        lastCheck = Date()
        let options = options
        let log = log
        let task = Task.detached { () throws -> Refresh in
            let built = !engine.isIndexed
            if built { log("indexing \(engine.root.path) …") }
            let summary = force ? try await engine.index(options: options) : try await engine.ensureFresh(options: options)
            if let summary {
                log("index updated: +\(summary.filesAdded) ~\(summary.filesChanged) -\(summary.filesRemoved) in \(String(format: "%.1f", summary.durationSeconds))s")
            }
            return Refresh(summary: summary, built: built)
        }
        let flight = (id: runs, task: task)
        running = flight
        return try await finish(flight)
    }

    private func finish(_ flight: (id: Int, task: Task<Refresh, Error>)) async throws -> Refresh {
        defer {
            if running?.id == flight.id { running = nil }
        }
        return try await flight.task.value
    }

    private static func note(_ refresh: Refresh) -> String? {
        guard let summary = refresh.summary else { return nil }
        if refresh.built {
            return "index: built just now (\(summary.filesScanned) files, \(String(format: "%.1f", summary.durationSeconds)) s)"
        }
        let changed = changedFiles(summary)
        return changed > 0 ? "re-indexed \(changed) file\(changed == 1 ? "" : "s")" : nil
    }

    private static func changedFiles(_ summary: IndexSummary) -> Int {
        summary.filesAdded + summary.filesChanged + summary.filesRemoved
    }
}
