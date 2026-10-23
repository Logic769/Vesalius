import ArgumentParser
import Foundation
import QueryEngine
import RepositoryIndex
import VesaliusMCP
import VesaliusRender

/// `vesalius doctor`: is everything in place for Claude Code to use Vesalius here, and if not, the command that fixes it.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check that Claude Code can use Vesalius in this repository, with a fix for anything that's off.",
        discussion: """
            Checks the server Claude Code would start for this folder (or --repo), the way it starts it: the \
            registered command and arguments, with CLAUDE_PROJECT_DIR set. Exits 1 when something needs fixing.
            """
    )

    @OptionGroup var global: GlobalOptions

    struct Check: Encodable {
        enum Status: String, Encodable { case ok, warning, failure, skipped }
        var status: Status
        let summary: String
        var detail: [String] = []
        var fix: String?
    }

    func run() async throws {
        try await global.run {
            let checks = await Self.checks(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), repositoryFlag: global.repo)
            let failed = checks.contains { $0.status == .failure }
            try global.emit(checks) {
                let printer = CheckPrinter()
                var lines = ["Vesalius doctor", ""]
                for check in checks {
                    let mark: CheckPrinter.Mark = switch check.status {
                    case .ok: .ok
                    case .warning: .warning
                    case .failure: .failure
                    case .skipped: .skipped
                    }
                    lines.append(printer.line(mark, check.summary, detail: check.detail + (check.fix.map { ["fix: \($0)"] } ?? [])))
                }
                lines.append("")
                lines.append(failed ? "Something needs fixing; each ✗ above says how." : checks.contains { $0.status == .warning } ? "Working, with a note or two above." : "All good.")
                return lines.joined(separator: "\n")
            }
            if failed { throw ExitCode(1) }
        }
    }

    static func checks(directory: URL, repositoryFlag: String?) async -> [Check] {
        var checks: [Check] = []
        let me = SelfExecutable.path
        let tilde = UsageReport.tilde
        let resolved = { (path: String) in URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path }
        // The setup command a user can paste: plain `vesalius` only when PATH resolves to this copy.
        let onPath = ExternalTool.find("vesalius")
        let vesalius = onPath.map(resolved) == resolved(me) ? "vesalius" : Self.shellQuoted(me)
        let setupFix = "\(vesalius) setup"

        // This program, and whether `vesalius` on PATH is it.
        var program = Check(status: .ok, summary: "vesalius \(MCPServer.version) · \(tilde(me))")
        if let onPath, resolved(onPath) != resolved(me) {
            program.detail = ["`vesalius` on your PATH is another copy: \(tilde(onPath))"]
        } else if onPath == nil {
            program.detail = ["not on your PATH; setup registers this full path instead"]
        }
        checks.append(program)

        // The folder being checked.
        let folder = repositoryFlag.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, relativeTo: directory).standardizedFileURL } ?? directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            checks.append(Check(status: .failure, summary: "No such folder: \(tilde(folder.path))", fix: "pass --repo a folder inside a repository"))
            return checks
        }

        // Claude Code and its registration.
        var registration: ClaudeRegistration?
        if let claude = Agent.claude.executable {
            let version = ExternalTool.run(claude, ["--version"], timeout: 15)?.output.trimmingCharacters(in: .whitespacesAndNewlines)
            checks.append(Check(status: .ok, summary: "Claude Code \(version?.replacingOccurrences(of: " (Claude Code)", with: "") ?? "") · \(tilde(claude))"))
            registration = ClaudeRegistration.lookup(claude: claude, directory: folder)
            if let registration {
                let scope = registration.isUserScope ? "for every project" : "(\(registration.scope ?? "unknown scope"))"
                if registration.isPendingApproval {
                    checks.append(Check(status: .failure, summary: "Registered with Claude Code \(scope), waiting for approval", detail: [registration.commandLine],
                                        fix: "start `claude` in \(tilde(folder.path)) and approve vesalius"))
                } else if !registration.isConnected {
                    checks.append(Check(status: .failure, summary: "Registered with Claude Code \(scope), not connecting (\(registration.status ?? "no status"))",
                                        detail: [registration.commandLine], fix: setupFix))
                } else {
                    var check = Check(status: .ok, summary: "Registered with Claude Code \(scope), connected", detail: [registration.commandLine])
                    if let command = registration.command, let runs = command.contains("/") ? command : ExternalTool.find(command), resolved(runs) != resolved(me) {
                        check.status = .warning
                        check.detail.append("Claude Code runs \(tilde(runs)), a different copy from this one")
                        check.fix = "run setup from the copy you want Claude Code to use"
                    }
                    checks.append(check)
                }
            } else {
                checks.append(Check(status: .failure, summary: "Not registered with Claude Code", fix: setupFix))
            }
        } else {
            checks.append(Check(status: .warning, summary: "Claude Code not found", detail: ["Vesalius works with any MCP client; Claude Code is the one setup configures"], fix: "install Claude Code, then run \(setupFix)"))
        }

        // The server Claude Code would start here, started the same way.
        var command = me
        var arguments = ["mcp"]
        var environment = ["CLAUDE_PROJECT_DIR": folder.path]
        if let registration, let registered = registration.command,
           let path = registered.contains("/") ? (registered as NSString).expandingTildeInPath : ExternalTool.find(registered) {
            command = path
            arguments = registration.arguments.isEmpty ? ["mcp"] : registration.arguments
            environment.merge(registration.environment) { $1 }
        }
        let probe = MCPProbe.run(command: command, arguments: arguments, directory: folder, environment: environment)
        if let probe {
            let deferred = probe.tools.filter { !probe.upFront.contains($0) }
            let loading = probe.upFront.isEmpty ? "all on demand" : "\(probe.upFront.joined(separator: " and ")) up front, \(deferred.count) on demand"
            let time = probe.seconds < 1 ? "\(Int((probe.seconds * 1000).rounded())) ms" : String(format: "%.1f s", probe.seconds)
            checks.append(Check(status: .ok, summary: "MCP server answers in \(time) with \(probe.tools.count) tools (\(loading))"))
        } else {
            checks.append(Check(status: .failure, summary: "MCP server did not answer", detail: [([tilde(command)] + arguments).joined(separator: " ")],
                                fix: "run that command in \(tilde(folder.path)) and read its error"))
        }

        // The repository it serves, and its index.
        let home = IndexLocation.canonicalRoot(URL(fileURLWithPath: NSHomeDirectory())).path
        // The server's own word first; failing that, what its registration pins, then what it would pick here.
        let pinnedPath = registration?.pinnedRepository ?? registration?.environment["VESALIUS_REPO"]
        let served = probe?.repository.map { URL(fileURLWithPath: $0) }
            ?? MCP.repository(flag: pinnedPath, environment: environment, directory: folder)
        let servedPath = IndexLocation.canonicalRoot(served).path
        let folderPath = IndexLocation.canonicalRoot(folder).path
        let pinned = registration?.pinnedRepository != nil ? " · pinned by the registration's --repo"
            : registration?.environment["VESALIUS_REPO"] != nil ? " · pinned by the registration's VESALIUS_REPO" : ""
        var servedIsFolder: ObjCBool = false
        if !pinned.isEmpty, !(FileManager.default.fileExists(atPath: served.path, isDirectory: &servedIsFolder) && servedIsFolder.boolValue) {
            checks.append(Check(status: .failure, summary: "The registration pins a repository that doesn't exist: \(tilde(served.path))",
                                detail: ["every question Claude asks would fail"], fix: "claude mcp remove --scope user vesalius, then \(setupFix)"))
        } else if folderPath == home && repositoryFlag == nil && pinned.isEmpty {
            checks.append(Check(status: .skipped, summary: "Not in a project (this is your home folder)", detail: ["run doctor inside a project to check its index"]))
        } else if pinned.isEmpty, servedPath != folderPath, folderPath.hasPrefix(servedPath + "/"),
                  servedPath == home || Self.gitRoot(of: folder).map({ $0.path != servedPath }) == true {
            // An indexed parent folder wins over the project inside it (the server picks the nearest indexed folder).
            let index = IndexLocation(repositoryRoot: served).directory.path
            let project = Self.gitRoot(of: folder) ?? folder
            let parent = servedPath == home ? "your home folder's index" : "the index of a parent folder, \(tilde(servedPath))"
            checks.append(Check(status: servedPath == home ? .failure : .warning, summary: "From here, Claude Code would be served \(parent), not \(project.lastPathComponent)",
                                detail: ["an indexed folder wins for every un-indexed project inside it"],
                                fix: servedPath == home ? "rm -r \(Self.shellQuoted(index))" : "\(vesalius) index \(Self.shellQuoted(project.path)), or remove the parent's index: rm -r \(Self.shellQuoted(index))"))
        } else if let engine = Self.engine(for: served, failure: { checks.append(Check(status: .failure, summary: "Can't open the index for \(tilde(served.path))", detail: [$0])) }) {
            let name = "\(engine.root.lastPathComponent) (\(tilde(engine.root.path)))"
            if engine.isIndexed, let status = try? engine.status(checkStaleness: true) {
                let when = status.lastIndexed.map { "updated \(TextFormatter.relative($0))" } ?? "indexed"
                let changed = status.staleFiles ?? 0
                checks.append(Check(status: .ok, summary: "Repository: \(name)\(pinned)",
                                    detail: ["\(status.stats.files) file\(status.stats.files == 1 ? "" : "s"), \(when)" + (changed > 0 ? "; \(changed) changed since, refreshed on the next question" : ", up to date")]))
            } else {
                checks.append(Check(status: .ok, summary: "Repository: \(name)\(pinned)", detail: ["not indexed yet: the first question indexes it, or run `vesalius index` now"]))
            }
        }

        // Whether Claude (or another agent) has called it here.
        let calls = UsageLog.read().filter { IndexLocation.canonicalRoot(URL(fileURLWithPath: $0.repository)).path == servedPath }
        let overMCP = calls.filter { $0.via == "mcp" }
        if !UsageLog.isEnabled() {
            checks.append(Check(status: .skipped, summary: "Usage recording is off (\(UsageLog.environmentKey)=off)"))
        } else if let last = overMCP.last {
            let week = overMCP.filter { $0.time > Date().addingTimeInterval(-7 * 86_400) }.count
            checks.append(Check(status: .ok, summary: "Last call over MCP here \(TextFormatter.relative(last.time)) · \(week) in the last 7 days", detail: ["details: vesalius stats"]))
        } else if servedPath != home {
            checks.append(Check(status: .skipped, summary: "No calls over MCP here yet" + (calls.isEmpty ? "" : " (\(calls.count) from the command line)"),
                                detail: ["after you ask Claude Code about this code, `vesalius stats` shows its calls"]))
        }
        return checks
    }

    /// The engine for `repository`, or nil after reporting why it couldn't be opened.
    static func engine(for repository: URL, failure: (String) -> Void) -> RepositoryEngine? {
        do {
            return try RepositoryEngine(repository: repository)
        } catch {
            failure(error.localizedDescription)
            return nil
        }
    }

    /// The nearest folder at or above `folder` with a `.git` entry.
    static func gitRoot(of folder: URL) -> URL? {
        var cursor = IndexLocation.canonicalRoot(folder)
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) { return cursor }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return nil }
            cursor = parent
        }
        return nil
    }

    /// `path`, single-quoted when the shell would otherwise split or expand it.
    static func shellQuoted(_ path: String) -> String {
        guard path.contains(where: { " '\"$`\\!*?[]()&;<>|#~{}".contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
