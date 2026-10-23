import Foundation
import VesaliusCore

/// The tools one server offers: five, six under `--profile full`, each listed with `annotations` (title; read-only,
/// idempotent, closed-world) and `_meta` (search hint, up-front loading), and the server instructions that route
/// questions to them.
public struct MCPToolCatalog: Sendable {
    public let profile: MCPProfile
    /// `VESALIUS_MCP_ALWAYS_LOAD`: exactly these tools load up front. Nil leaves it to the gates.
    public let alwaysLoad: Set<String>?
    public let tools: [any MCPTool]

    public init(profile: MCPProfile = .default, alwaysLoad: Set<String>? = nil) {
        self.profile = profile
        self.alwaysLoad = alwaysLoad
        var tools: [any MCPTool] = [UsagesTool(), FeatureMapTool(), ArchitectureTool(), DependencyCyclesTool(), OutlineTool()]
        if profile == .full { tools.append(RepoReportTool()) }
        self.tools = tools
    }

    public func tool(named name: String) -> (any MCPTool)? {
        tools.first { $0.name == name }
    }

    /// `_meta["anthropic/alwaysLoad"]`: true loads the tool into the first prompt; false keeps it behind tool
    /// search even under a server-level `alwaysLoad`; nil leaves the key out (deferred while its gate is closed).
    public func alwaysLoadValue(_ tool: any MCPTool) -> Bool? {
        if let alwaysLoad, alwaysLoad.contains(tool.name) { return true }
        switch tool.loading {
        case .deferred:
            return false
        case .gated(let open):
            if profile == .lean { return false }
            return open && alwaysLoad == nil ? true : nil
        }
    }

    /// Tools that reach Claude only through ToolSearch, in catalog order.
    public var deferredTools: [String] {
        tools.filter { alwaysLoadValue($0) != true }.map(\.name)
    }

    /// One tools/list entry.
    public func listing(_ tool: any MCPTool) -> JSONValue {
        var meta: [String: JSONValue] = ["anthropic/searchHint": .string(tool.searchHint)]
        if let load = alwaysLoadValue(tool) { meta["anthropic/alwaysLoad"] = .bool(load) }
        return .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
            "annotations": .object([
                "title": .string(tool.title), "readOnlyHint": .bool(true), "destructiveHint": .bool(false),
                "idempotentHint": .bool(true), "openWorldHint": .bool(false),
            ]),
            "_meta": .object(meta),
        ])
    }

    public var listings: JSONValue {
        .array(tools.map(listing))
    }

    /// The server instructions: which tool answers which question, the exact ToolSearch call for the deferred
    /// ones, and when Grep is the better tool. Claims about completeness appear only once `usages` makes them.
    public var instructions: String {
        let claims = UsagesTool.claimsCompleteness
        var lines = ["Vesalius is a precomputed code graph of this repo (resolved references, build targets, tests)."
            + (claims ? " Results give file:line + code plus a completeness line, so you rarely need Grep or Read afterwards." : "")]
        lines += [
            "- who calls X / where is X used / which files use, import or depend on X -> usages(target)",
            "- rename, change or remove X; what must be updated; which tests to run -> usages(target, change)",
            "- where/how a feature or behaviour is implemented -> feature_map(question)",
            "- architecture, targets, packages, layers -> architecture",
            "- circular imports / dependency cycles -> dependency_cycles",
            "- what a long file, type or function contains -> outline (cheaper than Read)",
        ]
        if tool(named: "repo_report") != nil {
            lines.append("- health score, diagnostics, hotspots, unused code, overview, finding files by name -> repo_report(kind)")
        }
        let deferred = deferredTools
        if !deferred.isEmpty {
            lines.append("Load deferred ones in one call: ToolSearch \"select:" + deferred.map { "mcp__vesalius__" + $0 }.joined(separator: ",") + "\".")
        }
        lines.append("Use Grep for literal text or regex." + (claims ? " If a result says complete, don't re-grep it; if it lists unresolved sites, check only those." : ""))
        return lines.joined(separator: "\n")
    }

    // MARK: Running a tool (shared by the MCP server and the CLI)

    /// The first argument problem, naming the accepted values; nil when the arguments are usable.
    public static func validate(_ arguments: [String: JSONValue], for tool: any MCPTool) -> String? {
        for parameter in tool.parameters {
            if let problem = parameter.problem(with: arguments[parameter.name]) { return problem }
        }
        return nil
    }

    /// Validates, runs, and when the tool reports stale quoted lines, re-indexes once and runs it again, starting
    /// the result with `re-indexed N files`. Errors become error results.
    public static func execute(_ tool: any MCPTool, arguments: [String: JSONValue], context: ToolContext) async -> ToolOutput {
        if let problem = validate(arguments, for: tool) { return .error(problem) }
        let input = ToolArguments(arguments)
        do {
            let output = try await tool.run(arguments: input, context: context)
            guard !output.staleFiles.isEmpty, !output.isError else { return output }
            let changed = try await context.reindex()
            var retried = try await tool.run(arguments: input, context: context)
            retried.staleFiles = []
            if changed > 0 { retried.text = "re-indexed \(changed) file\(changed == 1 ? "" : "s")\n" + retried.text }
            return retried
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
