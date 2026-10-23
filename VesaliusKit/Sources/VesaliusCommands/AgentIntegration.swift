import Foundation
import VesaliusCore
import VesaliusMCP

/// Other programs `setup` and `doctor` talk to: agent CLIs found on this Mac, and this binary run as an MCP server.
enum ExternalTool {
    struct Run: Sendable {
        let status: Int32
        let output: String
        let error: String
        let timedOut: Bool
        var succeeded: Bool { status == 0 && !timedOut }
    }

    /// `name` on PATH, else in the folders installers commonly use but shells don't always put on PATH.
    static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let home = NSHomeDirectory()
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fallbacks = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        for folder in path + fallbacks where !folder.isEmpty {
            let candidate = (folder as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs `executable` and collects its output. `environment` adds to (or replaces values in) this process's.
    /// Nil when it could not be started.
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil, environment: [String: String] = [:], input: Data? = nil, timeout: TimeInterval = 30) -> Run? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let outputPipe = Pipe(), errorPipe = Pipe(), inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        // Output is read as it arrives, so what the child wrote is kept even when something it left running holds
        // the pipe open and end-of-file never comes.
        let collected = Collected()
        let readers = DispatchGroup()
        for (pipe, isOutput) in [(outputPipe, true), (errorPipe, false)] {
            readers.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    readers.leave()
                } else {
                    collected.append(data, isOutput: isOutput)
                }
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            return nil
        }
        if let input {
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }
        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
        }
        // Output still open after the child exits belongs to something it left running; don't wait for that.
        if readers.wait(timeout: .now() + (timedOut ? 1 : 2)) == .timedOut {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
        }
        return Run(status: process.isRunning ? -1 : process.terminationStatus, output: collected.text(isOutput: true), error: collected.text(isOutput: false), timedOut: timedOut)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var output = Data()
        private var error = Data()

        func append(_ data: Data, isOutput: Bool) {
            lock.withLock { if isOutput { output.append(data) } else { error.append(data) } }
        }

        func text(isOutput: Bool) -> String {
            lock.withLock { String(decoding: isOutput ? output : error, as: UTF8.self) }
        }
    }
}

/// This program, as agents should launch it.
enum SelfExecutable {
    /// The path to register: the `vesalius` on PATH when that is this program (so a Homebrew upgrade, which moves the
    /// real file, keeps working), else this program's own path.
    static var path: String {
        let own = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        if let onPath = ExternalTool.find("vesalius"), URL(fileURLWithPath: onPath).resolvingSymlinksInPath().path == own {
            return onPath
        }
        return own
    }

    /// What PATH resolves `vesalius` to, when that is a different program from this one.
    static var shadowingCommand: String? {
        let own = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        guard let onPath = ExternalTool.find("vesalius"), URL(fileURLWithPath: onPath).resolvingSymlinksInPath().path != own else { return nil }
        return onPath
    }
}

/// Starts a Vesalius MCP server the way an agent does and asks for its tools, without touching the repository.
enum MCPProbe {
    struct Result: Sendable {
        let serverVersion: String?
        let tools: [String]
        /// Tools Claude Code loads into the first prompt (`_meta["anthropic/alwaysLoad"]`).
        let upFront: [String]
        let seconds: Double
        /// The repository the server said it serves (its first stderr line).
        let repository: String?
    }

    /// Runs `command arguments` in `directory` with `environment` added, as Claude Code starts a stdio server for a
    /// project (it also sets CLAUDE_PROJECT_DIR).
    static func run(command: String, arguments: [String], directory: URL, environment: [String: String] = [:], timeout: TimeInterval = 20) -> Result? {
        let requests: [JSONValue] = [
            .object(["jsonrpc": .string("2.0"), "id": .int(1), "method": .string("initialize"), "params": .object([
                "protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("vesalius-doctor"), "version": .string(MCPServer.version)]),
            ])]),
            .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]),
            .object(["jsonrpc": .string("2.0"), "id": .int(2), "method": .string("tools/list")]),
        ]
        var input = Data()
        for request in requests {
            guard let line = try? VesaliusJSON.string(request) else { return nil }
            input.append(Data(line.utf8))
            input.append(0x0A)
        }
        let started = Date()
        guard let run = ExternalTool.run(command, arguments, directory: directory, environment: environment, input: input, timeout: timeout), !run.timedOut else { return nil }
        let seconds = Date().timeIntervalSince(started)
        var version: String?
        var tools: [String] = []
        var upFront: [String] = []
        for line in run.output.split(separator: "\n") {
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
            if message["id"]?.intValue == 1 { version = message["result"]?["serverInfo"]?["version"]?.stringValue }
            if message["id"]?.intValue == 2, case .array(let listed) = message["result"]?["tools"] ?? .null {
                for tool in listed {
                    guard let name = tool["name"]?.stringValue else { continue }
                    tools.append(name)
                    if tool["_meta"]?["anthropic/alwaysLoad"]?.boolValue == true { upFront.append(name) }
                }
            }
        }
        guard !tools.isEmpty else { return nil }
        return Result(serverVersion: version, tools: tools, upFront: upFront, seconds: seconds, repository: servedRepository(in: run.error))
    }

    /// The path in the server's opening log line, `vesalius MCP server 2.1.0, repository /path, profile …`.
    static func servedRepository(in log: String) -> String? {
        for line in log.split(separator: "\n") {
            guard let start = line.range(of: ", repository ")?.upperBound, let end = line.range(of: ", profile ", range: start..<line.endIndex)?.lowerBound else { continue }
            return String(line[start..<end])
        }
        return nil
    }
}

/// An agent Vesalius can register with.
enum Agent: String, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var executable: String? { ExternalTool.find(rawValue) }

    /// The arguments that register `command arguments` (by default `command mcp`) with `environment`.
    func addition(command: String, arguments: [String] = ["mcp"], environment: [String: String] = [:]) -> [String] {
        let variables = environment.keys.sorted().flatMap { ["-e", "\($0)=\(environment[$0]!)"] }
        switch self {
        case .claude: return ["mcp", "add", "--scope", "user", "vesalius"] + variables + ["--", command] + arguments
        case .codex: return ["mcp", "add", "vesalius"] + variables.map { $0 == "-e" ? "--env" : $0 } + ["--", command] + arguments
        }
    }

    func removal() -> [String] {
        switch self {
        case .claude: ["mcp", "remove", "--scope", "user", "vesalius"]
        case .codex: ["mcp", "remove", "vesalius"]
        }
    }
}

/// What `claude mcp get vesalius` reports.
struct ClaudeRegistration: Sendable {
    let scope: String?
    let status: String?
    let command: String?
    let arguments: [String]
    let environment: [String: String]

    var isConnected: Bool { status?.contains("Connected") == true && status?.contains("Failed") != true }
    var isPendingApproval: Bool { status?.localizedCaseInsensitiveContains("pending") == true }
    var isUserScope: Bool { scope?.lowercased().contains("user") == true }
    /// The registered command line, `command args`.
    var commandLine: String { ([command].compactMap { $0 } + arguments).joined(separator: " ") }
    /// The repository a `--repo` argument pins, if any.
    var pinnedRepository: String? {
        guard let index = arguments.firstIndex(of: "--repo"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Nil when Claude Code has no server named vesalius. Scope and status come from `claude mcp get`; for a
    /// user-scope registration the command, arguments and environment are read from Claude Code's config file
    /// instead of that printout, which joins arguments with spaces.
    static func lookup(claude: String, directory: URL?, environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeRegistration? {
        guard let run = ExternalTool.run(claude, ["mcp", "get", "vesalius"], directory: directory, timeout: 45), run.succeeded, !run.output.isEmpty else { return nil }
        let printed = parse(run.output)
        guard printed.isUserScope, let entry = userEntry(environment: environment) else { return printed }
        return ClaudeRegistration(scope: printed.scope, status: printed.status, command: entry.command ?? printed.command,
                                  arguments: entry.arguments, environment: entry.environment)
    }

    /// The `vesalius` entry of the user-scope `mcpServers` in `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`.
    static func userEntry(environment: [String: String]) -> (command: String?, arguments: [String], environment: [String: String])? {
        let file = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).appendingPathComponent(".claude.json") }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?["vesalius"] as? [String: Any] else { return nil }
        return (entry["command"] as? String, entry["args"] as? [String] ?? [], entry["env"] as? [String: String] ?? [:])
    }

    static func parse(_ text: String) -> ClaudeRegistration {
        var fields: [String: String] = [:]
        var environment: [String: String] = [:]
        var inEnvironment = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inEnvironment, indent > 2, let equals = trimmed.firstIndex(of: "=") {
                environment[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
                continue
            }
            inEnvironment = false
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = String(trimmed[..<colon])
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "Environment" { inEnvironment = true } else if fields[name] == nil { fields[name] = value }
        }
        let arguments = (fields["Args"] ?? "").split(separator: " ").map(String.init)
        return ClaudeRegistration(scope: fields["Scope"], status: fields["Status"], command: fields["Command"], arguments: arguments, environment: environment)
    }
}

/// `✓`, `!` and `✗` lines, coloured on a terminal unless NO_COLOR is set.
struct CheckPrinter {
    enum Mark { case ok, warning, failure, skipped }

    let colored = isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    func line(_ mark: Mark, _ text: String, detail: [String] = []) -> String {
        let (symbol, color): (String, String) = switch mark {
        case .ok: ("✓", "32")
        case .warning: ("!", "33")
        case .failure: ("✗", "31")
        case .skipped: ("–", "2")
        }
        let shown = colored ? "\u{1B}[\(color)m\(symbol)\u{1B}[0m" : symbol
        return (["  \(shown) \(text)"] + detail.map { "      \($0)" }).joined(separator: "\n")
    }
}
