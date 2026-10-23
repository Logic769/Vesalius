import Foundation
import QueryEngine
import VesaliusCore
import VesaliusRender

/// `dependency_cycles`: circular import dependencies.
///
/// Cycles are strongly connected components of the import graph in scope (mock imports never count; test files
/// only with `include_tests`). Each comes with its import statements, what each import is used for and where,
/// a load-time verdict, whether it survives on value-only and static-only edges, and the barrels re-exporting
/// it; the first line stamps what was scanned. Swift files are checked on the module import graph.
public struct DependencyCyclesTool: MCPTool {
    public let name = "dependency_cycles"
    public let title = "Dependency cycles"
    public let isV2 = true
    public let loading = ToolLoading.deferred
    public let searchHint = "circular dependencies import cycles cyclic"
    public let descriptionShim = "Circular dependencies between files, in the whole repository or under a folder: each cycle as the files that depend on each other, in order."
    public let descriptionV2 = "Circular import dependencies: every cycle in a scope with each edge's import line, imported names and where they are used, plus what was scanned, so 'no other cycles' needs no re-scan."
    public let parameters = [
        ToolParameter("path", .string, description: "Optional folder scope, e.g. src/."),
        ToolParameter("include_tests", .boolean),
    ]

    public init() {}

    public func run(arguments: ToolArguments, context: ToolContext) async throws -> ToolOutput {
        let report = try context.engine.importCycles(path: arguments.string("path"), includeTests: arguments.bool("include_tests") ?? false)
        return ToolOutput(text: CyclesRenderer.render(report, budget: context.budget(.cycles)), json: AnyEncodable(report), staleFiles: report.staleFiles)
    }
}
