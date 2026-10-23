import AppKit
import Foundation
import Observation
import QueryEngine
import VesaliusCore

/// A request to hand a piece of work to a coding agent, opened from an inspector.
struct AgentRequest: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let prompt: String
    let suggestedMode: AgentSession.Mode
}

/// Builds agent prompts from Vesalius evidence so the agent starts with the analysis, not a grep.
enum AgentPrompt {
    static func forDiagnostic(_ diagnostic: Diagnostic, impact: ImpactReport?, repository: String) -> String {
        var lines: [String] = []
        lines.append("Improve the code health of the \(repository) repository by resolving one issue reported by Vesalius, a local code-analysis tool.")
        lines.append("")
        lines.append("Issue: \(diagnostic.title) (\(diagnostic.severity.displayName.lowercased()) severity, \(diagnostic.category.displayName.lowercased()))")
        lines.append("What: \(diagnostic.summary)")
        lines.append("Why it was flagged: \(diagnostic.reason)")
        if !diagnostic.metrics.isEmpty {
            lines.append("Evidence: " + diagnostic.metrics.map { metric in
                "\(metric.name) \(metric.formattedValue)" + (metric.threshold.map { " (threshold \(DiagnosticMetric(name: "", value: $0).formattedValue))" } ?? "")
            }.joined(separator: "; "))
        }
        let targets = diagnostic.targets.prefix(15).map { target in
            target.path + (target.symbol.map { " (\($0))" } ?? "") + (target.line.map { ":\($0)" } ?? "")
        }
        lines.append("Affected: " + targets.joined(separator: ", ") + (diagnostic.targets.count > 15 ? " and \(diagnostic.targets.count - 15) more" : ""))
        lines.append("Suggested improvement: \(diagnostic.recommendation)")
        if let impact {
            lines.append("")
            lines.append("Blast radius of \(impact.target): \(impact.directDependents.count) direct and \(impact.transitiveDependents.count) transitive dependents, risk \(impact.riskLevel.rawValue).")
            if !impact.relatedTests.isEmpty {
                lines.append("Related tests to run afterwards: " + impact.relatedTests.prefix(8).joined(separator: ", "))
            }
        }
        lines.append("")
        lines.append(guidance)
        return lines.joined(separator: "\n")
    }

    static func forImpact(_ impact: ImpactReport, repository: String) -> String {
        """
        Plan a safe change to \(impact.target) in the \(repository) repository.

        Vesalius measured its blast radius: \(impact.directDependents.count) files depend on it directly and \(impact.transitiveDependents.count) transitively, across \(impact.affectedAreas.map(\.name).prefix(5).joined(separator: ", ")). Risk: \(impact.riskLevel.rawValue) (\(Int(impact.riskScore.rounded()))/100).
        Direct dependents: \(impact.directDependents.prefix(12).map(\.path).joined(separator: ", "))
        Related tests: \(impact.relatedTests.isEmpty ? "none found" : impact.relatedTests.prefix(8).joined(separator: ", "))

        Describe how to reduce this file's coupling and risk (for example narrowing its public surface or introducing an interface), list the call sites that would change, and propose the order of steps. \(guidance)
        """
    }

    static func forExtraction(_ suggestion: ExtractionSuggestion, repository: String) -> String {
        """
        Plan extracting "\(suggestion.name)"\(suggestion.rootPath.map { " (\($0))" } ?? "") from the \(repository) repository into its own package or module.

        Vesalius found \(suggestion.files.count) files with \(suggestion.internalDependencies) internal dependencies, \(suggestion.externalDependencies) dependencies on the rest of the code and \(suggestion.externalDependents) uses from outside (cohesion \(Int((suggestion.cohesion * 100).rounded()))%).
        Reasons: \(suggestion.reasons.joined(separator: "; "))
        Risks: \(suggestion.risks.isEmpty ? "none noted" : suggestion.risks.joined(separator: "; "))
        Entry points used from outside: \(suggestion.entryPoints.prefix(8).joined(separator: ", "))
        Files: \(suggestion.files.prefix(30).joined(separator: ", "))\(suggestion.files.count > 30 ? " and more" : "")

        Propose the package boundary, its public API, what has to change at each entry point, and a step-by-step migration that keeps the build green. \(guidance)
        """
    }

    private static let guidance = """
        Use the vesalius MCP tools to navigate instead of searching the filesystem: usages (who calls, uses or depends on a symbol or file, and what a change touches), feature_map (where and how a feature is implemented) and outline (what a file, type or function contains). Keep the change focused and behaviour-preserving, keep public APIs stable unless the fix requires otherwise, follow the existing code style, and finish with a short summary of what changed and why.
        """
}

/// One headless run of Claude Code or Codex in the repository, streamed into a transcript.
@Observable
final class AgentSession {
    enum Mode: String, CaseIterable, Identifiable {
        case plan, edit
        var id: String { rawValue }
        var title: String { self == .plan ? "Plan only" : "Allow edits" }
        var detail: String {
            self == .plan
                ? "The agent reads and proposes changes. Nothing in your working tree is modified."
                : "The agent edits files in your working tree and may run builds and tests. Review the changes with git afterwards."
        }
    }

    enum Status: Equatable {
        case idle, running, finished, failed(String), stopped
    }

    struct Event: Identifiable {
        enum Kind { case message, tool, result, error, info }
        let id = UUID()
        let kind: Kind
        let text: String
        var detail: String?
    }

    let agent: AgentKind
    let root: URL
    let mode: Mode
    let prompt: String
    private(set) var status: Status = .idle
    private(set) var events: [Event] = []
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var changedFiles: [String] = []
    var healthBefore: Int?
    var healthAfter: Int?
    private var process: Process?
    private var gitBefore: Set<String> = []

    init(agent: AgentKind, root: URL, mode: Mode, prompt: String) {
        self.agent = agent
        self.root = root
        self.mode = mode
        self.prompt = prompt
    }

    var isRunning: Bool { status == .running }

    // MARK: Launch

    func start(onFinish: @escaping () -> Void) {
        guard status == .idle else { return }
        status = .running
        startedAt = Date()
        gitBefore = Set(Self.gitChangedFiles(root))
        append(.info, "Starting \(agent.displayName) in \(root.lastPathComponent) (\(mode.title.lowercased()))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: LoginShell.shell)
        process.arguments = ["-l", "-c", "exec " + commandLine()]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let reference = WeakReference(self)
        let lineBuffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in lineBuffer.append(data) {
                Task { @MainActor in reference.value?.handle(line: line) }
            }
        }
        let errorBuffer = LineBuffer()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in errorBuffer.append(data) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                Task { @MainActor in reference.value?.append(.info, line) }
            }
        }
        process.terminationHandler = { process in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let status = process.terminationStatus
            let reason = process.terminationReason
            Task { @MainActor in
                guard let session = reference.value else { return }
                session.finish(status: status, uncaughtSignal: reason == .uncaughtSignal)
                onFinish()
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            status = .failed(error.localizedDescription)
            append(.error, "Could not start \(agent.executableName): \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        status = .stopped
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if process.isRunning { process.terminate() } }
    }

    private func finish(status code: Int32, uncaughtSignal: Bool) {
        finishedAt = Date()
        changedFiles = Self.gitChangedFiles(root).filter { !gitBefore.contains($0) }.sorted()
        if status == .stopped {
            append(.info, "Stopped. Work done so far is kept in your working tree.")
        } else if code == 0 {
            status = .finished
        } else {
            status = .failed("\(agent.executableName) exited with status \(code)\(uncaughtSignal ? " (signal)" : "")")
        }
    }

    /// The shell command line for a headless run, with Vesalius attached as an MCP server.
    private func commandLine() -> String {
        let q = LoginShell.quote
        let mcp = CommandLineInstaller.mcpCommand()
        let mcpArguments = mcp.arguments + ["--repo", root.path]
        switch agent {
        case .claude:
            let config: [String: Any] = ["mcpServers": ["vesalius": ["command": mcp.command, "args": mcpArguments]]]
            let json = (try? JSONSerialization.data(withJSONObject: config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            var allowed = ["mcp__vesalius", "Read", "Grep", "Glob", "LS"]
            if mode == .edit {
                allowed += ["Edit", "MultiEdit", "Write", "Bash(git status:*)", "Bash(git diff:*)", "Bash(swift build:*)", "Bash(swift test:*)", "Bash(xcodebuild:*)", "Bash(npm test:*)", "Bash(npm run test:*)", "Bash(npx tsc:*)", "Bash(pytest:*)", "Bash(python -m pytest:*)"]
            }
            return [
                "claude", "-p", q(prompt), "--output-format", "stream-json", "--verbose",
                "--permission-mode", mode == .plan ? "plan" : "acceptEdits",
                "--mcp-config", q(json),
                "--allowedTools", allowed.map(q).joined(separator: " "),
            ].joined(separator: " ")
        case .codex:
            let args = "[" + mcpArguments.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",") + "]"
            return [
                "codex", "exec", "--json", "--skip-git-repo-check",
                "--sandbox", mode == .plan ? "read-only" : "workspace-write",
                "-C", q(root.path),
                "-c", q("mcp_servers.vesalius.command=\"\(mcp.command)\""),
                "-c", q("mcp_servers.vesalius.args=\(args)"),
                q(prompt),
            ].joined(separator: " ")
        }
    }

    // MARK: Output parsing

    private func append(_ kind: Event.Kind, _ text: String, detail: String? = nil) {
        events.append(Event(kind: kind, text: text, detail: detail))
        if events.count > 2000 { events.removeFirst(events.count - 2000) }
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { append(.info, trimmed) }
            return
        }
        switch agent {
        case .claude: handleClaude(object)
        case .codex: handleCodex(object)
        }
    }

    private func handleClaude(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "system":
            if let servers = event["mcp_servers"] as? [[String: Any]],
               let vesalius = servers.first(where: { $0["name"] as? String == "vesalius" }) {
                append(.info, "Vesalius index \((vesalius["status"] as? String) == "connected" ? "connected" : "unavailable") for the agent")
            }
        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { append(.message, text) }
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    append(.tool, Self.toolTitle(name), detail: Self.toolDetail(name, block["input"] as? [String: Any] ?? [:], root: root))
                default:
                    break
                }
            }
        case "user":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content where block["type"] as? String == "tool_result" && (block["is_error"] as? Bool) == true {
                let text = (block["content"] as? String) ?? ((block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ")) ?? "Tool error"
                append(.error, String(text.prefix(400)))
            }
        case "result":
            if let result = event["result"] as? String, !result.isEmpty { append(.result, result) }
            if (event["is_error"] as? Bool) == true { append(.error, (event["subtype"] as? String) ?? "The agent reported an error.") }
        default:
            break
        }
    }

    private func handleCodex(_ event: [String: Any]) {
        let type = event["type"] as? String ?? ""
        let item = event["item"] as? [String: Any] ?? [:]
        let itemType = item["type"] as? String ?? ""
        switch (type, itemType) {
        case ("item.completed", "agent_message"):
            if let text = item["text"] as? String { append(.message, text) }
        case ("item.started", "command_execution"):
            append(.tool, "Run", detail: item["command"] as? String)
        case ("item.completed", "file_change"):
            let paths = (item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
            append(.tool, "Edit", detail: paths.map { Self.relative($0, root: root) }.joined(separator: ", "))
        case ("item.started", "mcp_tool_call"):
            append(.tool, "Vesalius · \((item["tool"] as? String) ?? "tool")", detail: nil)
        case ("turn.completed", _):
            append(.info, "Turn completed")
        case ("error", _), ("turn.failed", _):
            append(.error, (event["message"] as? String) ?? ((event["error"] as? [String: Any])?["message"] as? String) ?? "Codex reported an error.")
        default:
            break
        }
    }

    static func toolTitle(_ name: String) -> String {
        if name.hasPrefix("mcp__vesalius__") {
            return "Vesalius · " + name.dropFirst("mcp__vesalius__".count).replacingOccurrences(of: "_", with: " ")
        }
        return name
    }

    static func toolDetail(_ name: String, _ input: [String: Any], root: URL) -> String? {
        for key in ["file_path", "path", "notebook_path"] {
            if let value = input[key] as? String { return relative(value, root: root) }
        }
        for key in ["command", "pattern", "query", "question", "symbol", "target", "focus", "description"] {
            if let value = input[key] as? String { return String(value.prefix(160)) }
        }
        return nil
    }

    static func relative(_ path: String, root: URL) -> String {
        path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
    }

    /// Paths with uncommitted changes (read-only git query).
    nonisolated static func gitChangedFiles(_ root: URL) -> [String] {
        let result = LoginShell.run("git status --porcelain --untracked-files=all", directory: root, timeout: 10)
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            return String(line.dropFirst(3)).components(separatedBy: " -> ").last
        }
    }

    // MARK: Terminal

    /// Opens an interactive agent session in Terminal with the same prompt.
    static func openInTerminal(agent: AgentKind, root: URL, prompt: String) {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Vesalius", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("\(agent.executableName)-\(Int(Date().timeIntervalSince1970)).command")
        let q = LoginShell.quote
        let body = """
            #!\(LoginShell.shell) -l
            cd \(q(root.path)) || exit 1
            clear
            exec \(agent.executableName) \(q(prompt))

            """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSSound.beep()
        }
    }
}

/// Splits a byte stream into lines (thread-safe; used from pipe readability handlers).
final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
