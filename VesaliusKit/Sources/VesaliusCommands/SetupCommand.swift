import ArgumentParser
import Foundation
import QueryEngine
import RepositoryIndex
import VesaliusCore
import VesaliusMCP

/// `vesalius setup`: one command from installed to answering Claude Code's questions, and `--undo` to reverse it.
struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect Claude Code (and Codex, when installed) to Vesalius and index this repository.",
        discussion: """
            Registers `vesalius mcp` with Claude Code for every project (claude mcp add --scope user), lets Claude \
            Code run Vesalius's read-only tools without asking (mcp__vesalius__* in permissions.allow of \
            ~/.claude/settings.json), registers it with Codex when the codex command is installed, checks that the \
            server answers, and indexes the repository you are in.

            It never touches your repository, CLAUDE.md or hooks. Running it again is safe: an existing \
            registration's arguments (a pinned --repo) and environment are kept. --undo removes the registrations, \
            and the permission rule if setup added it.
            """
    )

    @Flag(name: .customLong("dry-run"), help: "Show what would change, and change nothing.")
    var dryRun = false

    @Flag(help: "Remove the registrations, and the permission rule if setup added it. Indexes stay.")
    var undo = false

    @Flag(name: .customLong("no-index"), help: "Don't index the current repository now (the first question will).")
    var noIndex = false

    @Flag(name: .customLong("no-permissions"), help: "Leave Claude Code's permissions alone, so it asks before each tool's first use.")
    var noPermissions = false

    @Option(name: .long, help: "Repository to index (default: the one containing the current directory).")
    var repo: String?

    func run() async throws {
        let printer = CheckPrinter()
        let command = SelfExecutable.path
        let settings = ClaudeSettings.userSettings()
        let tilde = UsageReport.tilde
        if undo {
            print("Removing Vesalius from your agents\(dryRun ? " (dry run: nothing changes)" : "")\n")
            for agent in Agent.allCases {
                if let executable = agent.executable {
                    if dryRun {
                        print(printer.line(.ok, "\(agent.displayName): would run", detail: [([agent.rawValue] + agent.removal()).joined(separator: " ")]))
                    } else {
                        let run = ExternalTool.run(executable, agent.removal(), timeout: 45)
                        print(printer.line(run?.succeeded == true ? .ok : .skipped, "\(agent.displayName): " + (run?.succeeded == true ? "unregistered" : "wasn't registered")))
                    }
                } else {
                    print(printer.line(.skipped, "\(agent.displayName): not installed"))
                }
                guard agent == .claude else { continue }
                // Only a rule setup added goes, along with what adding it created.
                let record = SetupRecord.load().flatMap { $0.settingsPath == settings.url.path ? $0 : nil }
                if let created = record?.created {
                    switch settings.removeAllowRule(ClaudeSettings.vesaliusRule, created: created, dryRun: dryRun) {
                    case .changed: print(printer.line(.ok, "Claude Code: \(dryRun ? "would remove" : "removed") \(ClaudeSettings.vesaliusRule) from permissions.allow", detail: [tilde(settings.url.path)]))
                    case .unchanged: break
                    case .skipped(let reason): print(printer.line(.warning, "Claude Code: permission rule left in place", detail: [reason]))
                    }
                } else if settings.allows(ClaudeSettings.vesaliusRule) {
                    print(printer.line(.skipped, "Claude Code: left \(ClaudeSettings.vesaliusRule) in permissions.allow, because setup didn't add it"))
                }
                if !dryRun { SetupRecord.clear() }
            }
            print("""

                Indexes and the usage log stay in \(tilde(IndexLocation.baseDirectory.path)); delete that folder to remove them.
                To remove the program too: brew uninstall vesalius
                """)
            return
        }

        print("Setting up Vesalius \(MCPServer.version) (\(tilde(command)))\(dryRun ? ", dry run: nothing changes" : "")\n")
        var connected = false
        var failed = false

        // Claude Code.
        if let claude = Agent.claude.executable {
            let existing = ClaudeRegistration.lookup(claude: claude, directory: nil)
            let mine = existing?.isUserScope == true ? existing : nil
            // What the user chose stays: a registration's arguments (a pinned --repo) and environment carry over.
            let arguments = mine.map { $0.arguments.isEmpty ? ["mcp"] : $0.arguments } ?? ["mcp"]
            let environment = mine?.environment ?? [:]
            let addition = Agent.claude.addition(command: command, arguments: arguments, environment: environment)
            let shown = "claude " + addition.map(Doctor.shellQuoted).joined(separator: " ")
            if let existing, !existing.isUserScope {
                print(printer.line(.warning, "Claude Code: a registration in \(existing.scope ?? "another scope") takes precedence where it applies", detail: [existing.commandLine]))
            }
            if let mine, let registered = mine.command, Self.sameProgram(registered, command) {
                print(printer.line(.ok, "Claude Code: already registered for every project", detail: [mine.commandLine]))
            } else if dryRun {
                print(printer.line(.ok, "Claude Code: would \(mine == nil ? "register" : "re-register") for every project",
                                   detail: (mine.map { ["replacing \($0.commandLine)"] } ?? []) + [shown]))
            } else {
                if mine != nil { _ = ExternalTool.run(claude, Agent.claude.removal(), timeout: 45) }
                let added = ExternalTool.run(claude, addition, timeout: 45)
                if added?.succeeded == true {
                    print(printer.line(.ok, "Claude Code: registered for every project", detail: [shown]))
                } else {
                    failed = true
                    var detail = [added.map { $0.timedOut ? "claude didn't answer" : $0.error.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "claude couldn't be started"].filter { !$0.isEmpty }
                    if let mine, let registered = mine.command {
                        let restored = ExternalTool.run(claude, Agent.claude.addition(command: registered, arguments: arguments, environment: environment), timeout: 45)?.succeeded == true
                        detail.append(restored ? "the previous registration is back in place" : "the previous registration couldn't be put back: \(mine.commandLine)")
                    }
                    detail.append("to try by hand: \(shown)")
                    print(printer.line(.failure, "Claude Code: registration failed", detail: detail))
                }
            }
            if !noPermissions {
                let creation = settings.creation()
                let outcome = settings.addAllowRule(ClaudeSettings.vesaliusRule, dryRun: dryRun)
                if !dryRun, outcome == .changed, let creation {
                    SetupRecord(settingsPath: settings.url.path, created: creation).save()
                } else if !dryRun, outcome == .unchanged, SetupRecord.load()?.settingsPath != settings.url.path {
                    SetupRecord(settingsPath: settings.url.path, created: nil).save()
                }
                switch outcome {
                case .changed:
                    print(printer.line(.ok, "Claude Code: \(dryRun ? "would run" : "now runs") Vesalius's read-only tools without asking", detail: ["\(ClaudeSettings.vesaliusRule) in permissions.allow, \(tilde(settings.url.path))"]))
                case .unchanged:
                    print(printer.line(.ok, "Claude Code: already runs Vesalius's tools without asking"))
                case .skipped(let reason):
                    print(printer.line(.warning, "Claude Code: will ask before using each tool", detail: [reason]))
                }
            }
            if !dryRun && !failed {
                if let registration = ClaudeRegistration.lookup(claude: claude, directory: nil), registration.isConnected {
                    connected = true
                    print(printer.line(.ok, "Claude Code: connected"))
                } else {
                    failed = true
                    print(printer.line(.failure, "Claude Code: registered but not connecting", detail: ["see why with: \(Doctor.shellQuoted(command)) doctor"]))
                }
            }
        } else {
            print(printer.line(.warning, "Claude Code: not found", detail: ["install it (https://claude.com/claude-code), then run setup again"]))
        }

        // Codex, when its command line is installed.
        if let codex = Agent.codex.executable {
            let addition = Agent.codex.addition(command: command)
            let shown = "codex " + addition.map(Doctor.shellQuoted).joined(separator: " ")
            if dryRun {
                print(printer.line(.ok, "Codex: would register", detail: [shown]))
            } else {
                _ = ExternalTool.run(codex, Agent.codex.removal(), timeout: 45)
                if let added = ExternalTool.run(codex, addition, timeout: 45), added.succeeded {
                    connected = true
                    print(printer.line(.ok, "Codex: registered", detail: [shown]))
                } else {
                    failed = true
                    print(printer.line(.failure, "Codex: registration failed", detail: ["to try by hand: \(shown)"]))
                }
            }
        } else {
            print(printer.line(.skipped, "Codex: not installed"))
        }

        // This repository.
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repository = repo.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL }
            ?? RepositoryEngine.locateRepository(from: directory)
        var example: String?
        let home = IndexLocation.canonicalRoot(URL(fileURLWithPath: NSHomeDirectory())).path
        if IndexLocation.canonicalRoot(repository).path == home || repository.path == "/" {
            print(printer.line(.skipped, "Not in a project, so nothing was indexed", detail: ["Claude Code indexes each project the first time it asks about it"]))
        } else if noIndex || dryRun {
            let engine = try? RepositoryEngine(repository: repository)
            if let engine, engine.isIndexed {
                print(printer.line(.ok, "\(engine.root.lastPathComponent): already indexed"))
                example = Self.exampleQuestion(engine)
            } else {
                print(printer.line(.skipped, "\(repository.lastPathComponent): \(dryRun ? "would be indexed" : "not indexed now; the first question will")"))
            }
        } else {
            do {
                let engine = try RepositoryEngine(repository: repository)
                let progress = ProgressPrinter(enabled: isatty(STDERR_FILENO) != 0)
                let summary = try await engine.ensureFresh { progress.update($0) }
                progress.clear()
                let files = (try? engine.status().stats.files) ?? summary?.filesScanned ?? 0
                let note = summary.map { "\(files) files in \(String(format: "%.1f", $0.durationSeconds)) s" } ?? "\(files) files, already up to date"
                print(printer.line(.ok, "Indexed \(engine.root.lastPathComponent): \(note)"))
                example = Self.exampleQuestion(engine)
            } catch {
                print(printer.line(.warning, "Couldn't index \(repository.lastPathComponent) now: \(error.localizedDescription)", detail: ["the first question will try again"]))
            }
        }

        guard !dryRun else {
            print("\nNothing changed (dry run).")
            return
        }
        if connected {
            print("""

                Next: start Claude Code in a project (in a session that's already open, run /mcp), then ask, for example:
                  \(example ?? "Who calls PaymentService.charge, and what would I have to change to rename it?")

                  vesalius doctor          checks the connection any time
                  vesalius stats           shows what Claude asked Vesalius
                  vesalius setup --undo    reverses all of this
                """)
        } else if !failed {
            print("\nNo agent was set up. Any MCP client can run: \(command) mcp")
        }
        if failed { throw ExitCode(1) }
    }

    /// What setup changed in Claude Code's settings, kept next to the indexes so `--undo` takes away exactly that
    /// and nothing the user had before.
    struct SetupRecord: Codable {
        let settingsPath: String
        /// What adding the permission rule created; nil when the rule was already there.
        let created: ClaudeSettings.Created?

        static var url: URL { IndexLocation.baseDirectory.appendingPathComponent("setup.json") }

        static func load() -> SetupRecord? {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SetupRecord.self, from: $0) }
        }

        func save() {
            try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        }

        static func clear() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Whether two commands run the same program: paths compared after resolving symlinks, bare names found on PATH.
    static func sameProgram(_ first: String, _ second: String) -> Bool {
        func resolved(_ command: String) -> String? {
            let path = command.contains("/") ? (command as NSString).expandingTildeInPath : ExternalTool.find(command)
            return path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
        guard let first = resolved(first), let second = resolved(second) else { return false }
        return first == second
    }

    /// A question about this repository's most used type, so the first try is about real code.
    static func exampleQuestion(_ engine: RepositoryEngine) -> String? {
        let kinds: Set<SymbolKind> = [.class, .struct, .enum, .protocol, .interface, .actor]
        guard let symbols = try? engine.allSymbols(kinds: kinds, limit: 50_000) else { return nil }
        let candidate = symbols
            .filter { !$0.path.localizedCaseInsensitiveContains("test") && $0.name.count > 3 && ($0.references ?? 0) > 2 }
            .max { ($0.references ?? 0, $1.name) < ($1.references ?? 0, $0.name) }
        return candidate.map { "Who uses \($0.name), and what would I have to change to rename it?" }
    }
}
