import ArgumentParser
import Foundation
import QueryEngine
import RepositoryIndex
import VesaliusCore
import VesaliusMCP
import VesaliusRender

/// The `vesalius` command line. Lives in a library so both the standalone executable and the macOS app
/// binary (invoked through a `vesalius` symlink) can run it.
public struct VesaliusCommand: AsyncParsableCommand {
    public init() {}

    public static let configuration = CommandConfiguration(
        commandName: "vesalius",
        abstract: "Understand the anatomy of your codebase.",
        discussion: """
            Vesalius keeps a persistent graph of your repository (files, symbols, imports, references, \
            calls, dependencies, health) so questions are answered from the index instead of re-scanning \
            the filesystem. Everything runs locally; Vesalius itself never uploads your code.

            Queries update the index incrementally first (only changed files are re-parsed). Use --json for \
            machine-readable output and --repo to target another repository.

            Examples:
              vesalius index .
              vesalius usages AuthService.signIn
              vesalius ask "where is authentication handled?" --json
              vesalius references UserSession
              vesalius impact Sources/Auth/AuthService.swift
              vesalius health
            """,
        version: MCPServer.version,
        subcommands: [
            Index.self, Status.self, Usages.self, FeatureMap.self, Outline.self, DependencyCycles.self,
            Ask.self, Files.self, Symbols.self, References.self, Callers.self, Callees.self,
            Dependencies.self, Dependents.self, Impact.self, Context.self, Related.self,
            Health.self, Diagnostics.self, Hotspots.self, Cycles.self, Unused.self, Architecture.self, Suggestions.self,
            MapCommand.self, Query.self, Repos.self, Watch.self, MCP.self, Debug.self,
        ]
    )
}

// MARK: - Shared options

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Repository path (default: the repository containing the current directory).")
    var repo: String?

    @Flag(name: .long, help: "Output JSON.")
    var json = false

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var pretty = false

    @Flag(name: .customLong("no-refresh"), help: "Query the existing index without checking for changed files.")
    var noRefresh = false

    @Flag(name: [.customShort("q"), .long], help: "Suppress progress output on stderr.")
    var quiet = false

    func repositoryURL() -> URL {
        if let repo {
            return URL(fileURLWithPath: (repo as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        }
        return RepositoryEngine.locateRepository(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    /// Opens the engine and brings the index up to date unless `--no-refresh`.
    func engine() async throws -> RepositoryEngine {
        let engine = try RepositoryEngine(repository: repositoryURL())
        if noRefresh {
            guard engine.isIndexed else { throw EngineError.notIndexed(engine.root.path) }
            return engine
        }
        let printer = ProgressPrinter(enabled: !quiet)
        if let summary = try await engine.ensureFresh(progress: { printer.update($0) }) {
            printer.finish("Indexed \(engine.root.lastPathComponent): \(summary.filesScanned) files (+\(summary.filesAdded) ~\(summary.filesChanged) -\(summary.filesRemoved)) in \(String(format: "%.1f", summary.durationSeconds))s")
        }
        return engine
    }

    func emit<T: Encodable>(_ value: T, text: () -> String) throws {
        if json {
            print(try VesaliusJSON.string(value, pretty: pretty))
        } else {
            print(text())
        }
    }

    /// Runs an MCP tool from the command line: the same handler, argument checks and text as `vesalius mcp`, so
    /// the CLI prints exactly what an agent gets. `--json` prints the tool's result value instead.
    func runTool(_ tool: any MCPTool, _ arguments: [String: JSONValue], full: Bool) async throws {
        if let problem = MCPToolCatalog.validate(arguments, for: tool) { throw ToolFailure(message: problem) }
        let engine = try await engine()
        let context = ToolContext(engine: engine, unbudgeted: full) {
            let summary = try await engine.index()
            return summary.filesAdded + summary.filesChanged + summary.filesRemoved
        }
        let output = await MCPToolCatalog.execute(tool, arguments: arguments, context: context)
        if output.isError { throw ToolFailure(message: output.text) }
        if !json {
            print(output.text)
        } else if let value = output.json {
            print(try VesaliusJSON.string(value, pretty: pretty))
        } else {
            struct TextOnly: Encodable { let text: String }
            print(try VesaliusJSON.string(TextOnly(text: output.text), pretty: pretty))
        }
    }

    /// Runs a command body with uniform error reporting (JSON errors when `--json`).
    func run(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let error as ExitCode {
            throw error
        } catch let error as CleanExit {
            throw error
        } catch {
            if json {
                struct ErrorOutput: Encodable {
                    let error: String
                    let suggestions: [String]?
                }
                var suggestions: [String]?
                if case EngineError.notFound(_, let list) = error, !list.isEmpty { suggestions = list }
                print((try? VesaliusJSON.string(ErrorOutput(error: error.localizedDescription, suggestions: suggestions), pretty: pretty)) ?? "{\"error\":\"unknown\"}")
            } else {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            }
            throw ExitCode(1)
        }
    }
}

/// A tool's error result, reported like any other command error.
struct ToolFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Progress on stderr, rewritten in place on terminals.
final class ProgressPrinter: @unchecked Sendable {
    private let enabled: Bool
    private let interactive = isatty(STDERR_FILENO) != 0
    private var lastPhase: IndexPhase?
    private var lastPrint = Date.distantPast
    private let lock = NSLock()

    init(enabled: Bool) { self.enabled = enabled }

    func update(_ progress: IndexProgress) {
        guard enabled, progress.phase != .finished else { return }
        lock.lock()
        defer { lock.unlock() }
        let phaseChanged = progress.phase != lastPhase
        guard phaseChanged || Date().timeIntervalSince(lastPrint) > 0.25 else { return }
        lastPhase = progress.phase
        lastPrint = Date()
        let counts = progress.total > 1 ? " \(progress.completed)/\(progress.total)" : ""
        let line = "\(progress.phase.displayName)…\(counts)"
        if interactive {
            FileHandle.standardError.write(Data("\r\u{1B}[2K\(line)".utf8))
        } else if phaseChanged {
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }
    }

    func finish(_ message: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        if interactive { FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8)) }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

// MARK: - Indexing

struct Index: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build or incrementally update the index for a repository.")

    @Argument(help: "Repository path (default: current repository).")
    var path: String?

    @Flag(help: "Discard the existing index and rebuild from scratch.")
    var rebuild = false

    @Flag(name: .customLong("no-embeddings"), help: "Skip on-device semantic vectors.")
    var noEmbeddings = false

    @Flag(name: .customLong("no-history"), help: "Skip git history (churn) analysis.")
    var noHistory = false

    @Option(help: "Extra exclusion pattern in .gitignore syntax (repeatable).")
    var exclude: [String] = []

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let url = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL } ?? global.repositoryURL()
            let engine = try RepositoryEngine(repository: url)
            var options = IndexOptions(computeEmbeddings: !noEmbeddings, gitChurn: !noHistory)
            options.scan.userExclusions = exclude
            let printer = ProgressPrinter(enabled: !global.quiet)
            let summary = try await engine.index(options: options, rebuild: rebuild) { printer.update($0) }
            printer.finish("")
            try global.emit(summary) { TextFormatter.indexSummary(summary) }
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show index status and repository statistics.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try RepositoryEngine(repository: global.repositoryURL())
            let status = try engine.status(checkStaleness: engine.isIndexed)
            try global.emit(status) { TextFormatter.status(status) }
        }
    }
}

struct Repos: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List repositories indexed on this Mac.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let records = IndexLocation.allIndexed()
            try global.emit(records) {
                records.isEmpty ? "No repositories indexed yet. Run `vesalius index <path>`." : records.map { record in
                    let date = record.lastIndexedAt.map { TextFormatter.relative($0) } ?? "never"
                    return "\(record.name)  \(record.path)\(record.exists ? "" : "  (missing)")  indexed \(date)"
                }.joined(separator: "\n")
            }
        }
    }
}

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Keep the index up to date while files change (Ctrl-C to stop).")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            FileHandle.standardError.write(Data("Watching \(engine.root.path) …\n".utf8))
            let stream = AsyncStream<[String]> { continuation in
                let watcher = FileWatcher(root: engine.root) { paths in continuation.yield(paths) }
                watcher.start()
                continuation.onTermination = { _ in watcher.stop() }
            }
            for await paths in stream {
                let summary = try await engine.index()
                if summary.didChange {
                    let line = "\(TextFormatter.time(Date()))  \(paths.count) change(s): +\(summary.filesAdded) ~\(summary.filesChanged) -\(summary.filesRemoved) in \(String(format: "%.2f", summary.durationSeconds))s"
                    if global.json { print(try VesaliusJSON.string(summary)) } else { print(line) }
                }
            }
        }
    }
}

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the Vesalius MCP server on stdio (for Claude Code, Codex and other MCP clients).")

    @Option(name: .long, help: "Repository to serve (default: $VESALIUS_REPO, then $CLAUDE_PROJECT_DIR, then the repository containing the current directory).")
    var repo: String?

    @Option(name: .long, help: "Tools to offer: default (usages and feature_map load up front once their golden checks pass), lean (every tool deferred) or full (adds repo_report). Default: $VESALIUS_MCP_PROFILE, else default.")
    var profile: MCPProfile?

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let profile = profile ?? MCPProfile.from(environment: environment) { FileHandle.standardError.write(Data("[vesalius] \($0)\n".utf8)) }
        let catalog = MCPToolCatalog(profile: profile, alwaysLoad: AlwaysLoadOverride.from(environment: environment))
        await MCPServer(repository: Self.repository(flag: repo, environment: environment, directory: directory), catalog: catalog).run()
    }

    /// `--repo`, else `VESALIUS_REPO`, else `CLAUDE_PROJECT_DIR` (Claude Code sets it for stdio servers), else the
    /// working directory; the last two are directories inside a repository, resolved to its root.
    static func repository(flag: String?, environment: [String: String], directory: URL) -> URL {
        func absolute(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL
        }
        if let flag, !flag.isEmpty { return absolute(flag) }
        if let repository = environment["VESALIUS_REPO"], !repository.isEmpty { return absolute(repository) }
        if let project = environment["CLAUDE_PROJECT_DIR"], !project.isEmpty { return RepositoryEngine.locateRepository(from: absolute(project)) }
        return RepositoryEngine.locateRepository(from: directory)
    }
}

extension MCPProfile: ExpressibleByArgument {}

extension VesaliusCommand {
    /// Parses `arguments` (default: the process arguments) and runs the selected subcommand, awaiting
    /// async commands. Used by the standalone executable and by the app binary in command-line mode.
    public static func runCommandLine(_ arguments: [String]? = nil) async -> Never {
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            Foundation.exit(0)
        } catch {
            Self.exit(withError: error)
        }
    }
}
