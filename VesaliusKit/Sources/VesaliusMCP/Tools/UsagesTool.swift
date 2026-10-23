import Foundation
import QueryEngine
import VesaliusCore
import VesaliusRender

/// `usages`: who calls, uses, imports or depends on a symbol or file.
///
/// The view follows from the target: a function's callers, a property's writes and reads, a type's users with
/// how each obtains it, a file's (folder's, module's) dependents by owner type and member, a framework's
/// importers and their calls into it, an environment variable's reads and writes. Every site comes with its
/// code; line 2 carries the totals and the completeness reconciliation; same-name declarations become choices.
/// With `change`, the edit sections follow: owner users, text-only mentions, dynamic forms, tests and how to run
/// them, entry points, other overloads and coverage.
public struct UsagesTool: MCPTool {
    /// True once results carry a computed completeness line; the server instructions then say so.
    public static let claimsCompleteness = true

    public let name = "usages"
    public let title = "Usages"
    public let isV2 = true
    public let loading = ToolLoading.gated(true)
    public let searchHint = "who calls callers usages references which files use import depend dependents rename signature what breaks tests to run"
    public let descriptionShim = "Who calls, uses, imports or depends on a symbol or file: its reference sites (file:line) grouped by file and enclosing function, or the files that depend on a file, folder or module; with `change`, the dependents, call sites and related tests of the change."
    public let descriptionV2 = "Who calls, uses, imports or depends on a symbol or file: every site as file:line + code grouped by enclosing function, incl. type-inferred uses grep misses, minus same-name lookalikes, with a completeness check; with `change`, the edit list (owner users, text mentions, tests to run)."
    public let parameters = [
        ToolParameter("target", .string, description: "Type.member, Type.method(label:), file path, path#Name, path:line, folder, or module (e.g. StoreKit).", required: true),
        ToolParameter("change", .oneOf(["rename", "signature", "remove"])),
        ToolParameter("page", .integer(minimum: 1)),
    ]

    public init() {}

    public func run(arguments: ToolArguments, context: ToolContext) async throws -> ToolOutput {
        let target = arguments.string("target") ?? ""
        let change = arguments.string("change").flatMap(UsageChange.init(rawValue:))
        let page = arguments.int("page") ?? 1
        let result = try context.engine.usages(target, change: change, page: page)
        let text = UsagesRenderer.render(result, budget: context.budget(.usages, page: page))
        return ToolOutput(text: text, json: AnyEncodable(result), staleFiles: result.staleFiles, complete: result.completeness?.isComplete)
    }
}
