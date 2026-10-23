import Foundation
import QueryEngine
import VesaliusCore
import VesaliusRender

/// `outline`: what a file, type, folder or function contains.
///
/// A file gets its top-level declarations with signatures, ranges, first doc sentences and members, its calls
/// out (repository, frameworks, environment), its build targets and how many files use it; a type its members
/// and extensions; a function its flow; a folder its files with their main declarations; a name declared
/// in several places the exact target of each. The result is capped at a fifth of the outlined source and
/// 2,000 tokens.
public struct OutlineTool: MCPTool {
    public let name = "outline"
    public let title = "Outline"
    public let isV2 = true
    public let loading = ToolLoading.deferred
    public let searchHint = "outline summary declarations members signatures where declared what does it call"
    public let descriptionShim = "Compact outline of a file, type, folder or function - declarations with signatures and line ranges, a type's members, what a function calls and who calls it - for fewer tokens than reading it; also finds where a name is declared."
    public let descriptionV2 = "Compact outline of a file, type, folder or function - declarations with signatures, line ranges, first doc sentence and calls in order - at about a fifth of the tokens of reading it; also finds where a name is declared."
    public let parameters = [
        ToolParameter("target", .string, description: "File, folder, type or function.", required: true),
    ]

    public init() {}

    public func run(arguments: ToolArguments, context: ToolContext) async throws -> ToolOutput {
        let result = try context.engine.outline(arguments.string("target") ?? "")
        let text = OutlineRenderer.render(result, budget: context.budget(.outline(fileCharacters: result.sourceCharacters)))
        return ToolOutput(text: text, json: AnyEncodable(result), staleFiles: result.staleFiles)
    }
}
