import AppKit
import Foundation

/// Runs commands through the user's login shell so tools installed with Homebrew, nvm, pnpm, volta or
/// npm prefixes are found exactly as they are in Terminal (GUI apps do not inherit the shell PATH).
enum LoginShell {
    nonisolated static var shell: String {
        let configured = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: configured) ? configured : "/bin/zsh"
    }

    /// Single-quotes a string for POSIX shells.
    nonisolated static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `command` (already shell-quoted) and returns stdout, stderr and the exit status.
    nonisolated static func run(_ command: String, directory: URL? = nil, timeout: TimeInterval = 20) -> (output: String, error: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ("", error.localizedDescription, -1) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate() }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (output, error, process.terminationStatus)
    }

    /// Resolves an executable name via the login shell's PATH.
    nonisolated static func which(_ name: String) -> String? {
        let result = run("command -v \(quote(name))", timeout: 10)
        let path = result.output.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return result.status == 0 && path.hasPrefix("/") ? path : nil
    }
}

/// Installs the `vesalius` command: a symlink to this app's executable, which switches to
/// command-line mode when started under that name.
enum CommandLineInstaller {
    nonisolated static var appExecutable: String { Bundle.main.executablePath ?? "" }
    nonisolated static var userBinDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin") }
    nonisolated static let systemPath = "/usr/local/bin/vesalius"

    /// The installed `vesalius` command, if any: a symlink into this app or a standalone build.
    nonisolated static func installedCommand() -> String? {
        let candidates = [userBinDirectory.appendingPathComponent("vesalius").path, systemPath, "/opt/homebrew/bin/vesalius"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The command agents should run for the MCP server: the installed `vesalius`, or this app binary.
    nonisolated static func mcpCommand() -> (command: String, arguments: [String]) {
        if let installed = installedCommand() { return (installed, ["mcp"]) }
        return (appExecutable, ["--cli", "mcp"])
    }

    @discardableResult
    nonisolated static func installForUser() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: userBinDirectory, withIntermediateDirectories: true)
        let link = userBinDirectory.appendingPathComponent("vesalius")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: appExecutable)
        return link
    }

    /// Installs into /usr/local/bin after an administrator password prompt from macOS.
    nonisolated static func installSystemWide() -> String? {
        let command = "mkdir -p /usr/local/bin && ln -sf \(LoginShell.quote(appExecutable)) \(systemPath)"
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error.map { ($0[NSAppleScript.errorMessage] as? String) ?? "Installation was cancelled." }
    }

    /// True when `directory` is on the user's login-shell PATH.
    nonisolated static func isOnPath(_ directory: URL) -> Bool {
        let path = LoginShell.run("printf %s \"$PATH\"").output
        return path.split(separator: ":").contains { $0 == directory.path || $0 == directory.path + "/" }
    }
}

/// Coding agents Vesalius can hand work to.
enum AgentKind: String, CaseIterable, Identifiable, Hashable {
    case claude, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    nonisolated var executableName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    var installHint: String {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        }
    }

    /// Registers the Vesalius MCP server with the agent (user scope, so it works in every repository:
    /// the server resolves the repository from the agent's working directory).
    nonisolated func connectCommand() -> String {
        let mcp = CommandLineInstaller.mcpCommand()
        let parts = ([mcp.command] + mcp.arguments).map(LoginShell.quote).joined(separator: " ")
        switch self {
        case .claude:
            return "claude mcp remove --scope user vesalius >/dev/null 2>&1; claude mcp add --scope user vesalius -- \(parts)"
        case .codex:
            return "codex mcp remove vesalius >/dev/null 2>&1; codex mcp add vesalius -- \(parts)"
        }
    }
}

/// Which agents are installed (resolved once per launch, off the main thread).
@Observable
final class AgentAvailability {
    static let shared = AgentAvailability()
    private(set) var paths: [AgentKind: String] = [:]
    private(set) var resolved = false

    func refresh() {
        Task.detached(priority: .utility) {
            var found: [AgentKind: String] = [:]
            for agent in AgentKind.allCases {
                if let path = LoginShell.which(agent.executableName) { found[agent] = path }
            }
            let resolvedPaths = found
            await MainActor.run {
                self.paths = resolvedPaths
                self.resolved = true
            }
        }
    }

    func isInstalled(_ agent: AgentKind) -> Bool { paths[agent] != nil }
}
