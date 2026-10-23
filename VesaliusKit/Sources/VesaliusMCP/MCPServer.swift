import Foundation
import QueryEngine
import VesaliusCore

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0) for one repository.
///
/// A reader thread splits stdin into messages. `initialize`, `ping`, `tools/list`, `resources/list` and
/// `prompts/list` are answered at once and never wait for indexing; each `tools/call` runs as its own task, and
/// `notifications/cancelled` drops that call's answer. At the end of input the server finishes the calls still
/// running. Results are plain text. Logs go to stderr; stdout carries only protocol messages.
public final class MCPServer: Sendable {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let version = "2.1.0"

    public let repository: URL
    public let catalog: MCPToolCatalog
    private let coordinator: IndexCoordinator
    private let output: LineWriter
    private let log: LineWriter
    private let toolsList: JSONValue
    private let instructions: String

    public init(repository: URL, catalog: MCPToolCatalog = MCPToolCatalog(), output: FileHandle = .standardOutput, log: FileHandle = .standardError) {
        self.repository = repository
        self.catalog = catalog
        self.output = LineWriter(output)
        let logWriter = LineWriter(log)
        self.log = logWriter
        self.coordinator = IndexCoordinator(repository: repository) { logWriter.write("[vesalius] " + $0) }
        self.toolsList = .object(["tools": catalog.listings])
        self.instructions = catalog.instructions
    }

    /// Serves requests until stdin closes, then waits for the tool calls still running.
    public func run(input: FileHandle = .standardInput) async {
        signal(SIGPIPE, SIG_IGN)
        logLine("vesalius MCP server \(Self.version), repository \(repository.path), profile \(catalog.profile.rawValue), deferred: \(catalog.deferredTools.joined(separator: ", "))")
        if let alwaysLoad = catalog.alwaysLoad {
            let unknown = alwaysLoad.subtracting(catalog.tools.map(\.name))
            if !unknown.isEmpty { logLine("\(AlwaysLoadOverride.environmentKey): no tool named \(unknown.sorted().joined(separator: ", "))") }
        }
        let calls = InFlightCalls()
        await withDiscardingTaskGroup { group in
            for await line in LineReader.lines(from: input.fileDescriptor) {
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
                    send(Self.error(id: .null, code: -32700, message: "Parse error"))
                    continue
                }
                if case .array(let batch) = message {
                    group.addTask {
                        if let response = await self.batch(batch) { self.send(response) }
                    }
                    continue
                }
                guard case .object(let object) = message, let method = object["method"]?.stringValue else {
                    send(Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request"))
                    continue
                }
                let params = object["params"] ?? .object([:])
                guard let id = object["id"] else {
                    // Notifications get no reply; a cancelled call finishes without one.
                    if method == "notifications/cancelled", let requestID = params["requestId"] { calls.cancel(requestID) }
                    continue
                }
                if method == "tools/call" {
                    let task = Task {
                        if let response = await self.call(id: id, params: params) { self.send(response) }
                    }
                    calls.insert(id, task)
                    group.addTask {
                        await task.value
                        calls.remove(id, task)
                    }
                } else {
                    send(answer(id: id, method: method, params: params))
                }
            }
        }
    }

    // MARK: - Requests

    /// Everything except tools/call: answered from memory.
    private func answer(id: JSONValue, method: String, params: JSONValue) -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.supportedProtocolVersions[0]
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            return Self.result(id: id, .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("vesalius"), "title": .string("Vesalius"), "version": .string(Self.version)]),
                "instructions": .string(instructions),
            ]))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, toolsList)
        case "resources/list":
            return Self.result(id: id, .object(["resources": .array([])]))
        case "resources/templates/list":
            return Self.result(id: id, .object(["resourceTemplates": .array([])]))
        case "prompts/list":
            return Self.result(id: id, .object(["prompts": .array([])]))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// One tools/call. Nil when the client cancelled it.
    private func call(id: JSONValue, params: JSONValue) async -> JSONValue? {
        guard let name = params["name"]?.stringValue else {
            return Self.error(id: id, code: -32602, message: "Missing tool name")
        }
        guard let tool = catalog.tool(named: name) else {
            return Self.result(id: id, Self.content(.error("Unknown tool “\(name)”. Tools: \(catalog.tools.map(\.name).joined(separator: ", ")).")))
        }
        var arguments: [String: JSONValue] = [:]
        if case .object(let values) = params["arguments"] ?? .null { arguments = values }
        let started = Date()
        var output: ToolOutput
        var engine: RepositoryEngine?
        if let problem = MCPToolCatalog.validate(arguments, for: tool) {
            output = .error(problem)
        } else {
            do {
                let prepared = try await coordinator.prepare()
                if Task.isCancelled {
                    logLine("\(name) cancelled")
                    return nil
                }
                engine = prepared.engine
                let coordinator = coordinator
                let context = ToolContext(engine: prepared.engine) { try await coordinator.reindexNow() }
                output = await MCPToolCatalog.execute(tool, arguments: arguments, context: context)
                if let note = prepared.note { output.text = note + "\n" + output.text }
            } catch {
                output = .error(error.localizedDescription)
            }
        }
        if Task.isCancelled {
            logLine("\(name) cancelled")
            return nil
        }
        let milliseconds = Int((Date().timeIntervalSince(started) * 1000).rounded())
        logLine("\(name) \(milliseconds)ms \(output.text.utf8.count)B\(output.isError ? " error" : "")")
        UsageLog.append(.measuring(output, tool: name, via: "mcp", repository: engine?.root ?? repository, milliseconds: milliseconds))
        return Self.result(id: id, Self.content(output))
    }

    /// A JSON-RPC batch (protocol versions before 2025-06-18), answered in order as one array.
    private func batch(_ items: [JSONValue]) async -> JSONValue? {
        var responses: [JSONValue] = []
        for item in items {
            guard case .object(let object) = item, let method = object["method"]?.stringValue else {
                responses.append(Self.error(id: item["id"] ?? .null, code: -32600, message: "Invalid Request"))
                continue
            }
            guard let id = object["id"] else { continue }
            let params = object["params"] ?? .object([:])
            if method == "tools/call" {
                if let response = await call(id: id, params: params) { responses.append(response) }
            } else {
                responses.append(answer(id: id, method: method, params: params))
            }
        }
        return responses.isEmpty ? nil : .array(responses)
    }

    // MARK: - Output

    private static func result(id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .int(Int64(code)), "message": .string(message)])])
    }

    /// A tool result: one text block, never JSON.
    private static func content(_ output: ToolOutput) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(output.text)])]), "isError": .bool(output.isError)])
    }

    private func send(_ value: JSONValue) {
        guard let data = try? VesaliusJSON.encoder().encode(value) else { return }
        output.write(data)
    }

    private func logLine(_ text: String) {
        log.write("[vesalius] " + text)
    }
}

/// The tool calls still running, by request id, so `notifications/cancelled` can reach them.
final class InFlightCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [JSONValue: Task<Void, Never>] = [:]

    func insert(_ id: JSONValue, _ task: Task<Void, Never>) {
        lock.withLock { tasks[id] = task }
    }

    func remove(_ id: JSONValue, _ task: Task<Void, Never>) {
        lock.withLock {
            if tasks[id] == task { tasks[id] = nil }
        }
    }

    func cancel(_ id: JSONValue) {
        lock.withLock { tasks[id] }?.cancel()
    }
}
