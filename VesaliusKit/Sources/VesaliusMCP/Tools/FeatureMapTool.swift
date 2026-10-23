import Foundation
import QueryEngine
import VesaliusCore
import VesaliusRender

/// `feature_map`: where and how a feature or behaviour is implemented.
///
/// The question is parsed for its phrases, frameworks, acronyms and roles; the result is the feature's core
/// type or file with its members by role and their decisive lines, environment links and tables, every call site
/// of the core, configuration, one doc section and lookalikes. "How does X write/commit…" questions get the
/// flow of the main method instead.
public struct FeatureMapTool: MCPTool {
    public let name = "feature_map"
    public let title = "Feature map"
    public let isV2 = true
    public let loading = ToolLoading.gated(true)
    public let searchHint = "where how feature implemented handled code path flow persist store load auth"
    public let descriptionShim = "Where/how a feature or behaviour is implemented ('where are purchases handled', 'how is data persisted'): the most relevant files, ranked by a search over names, docs and the code graph, with their matching types and functions and their line ranges."
    public let descriptionV2 = "Where/how a feature or behaviour is implemented ('where are purchases handled', 'how is data persisted'): core types and functions grouped by role, with their decisive code lines, framework/IO calls, config/env links and call sites as file:line evidence - usually enough to answer without opening files."
    public let parameters = [
        ToolParameter("question", .string, description: "The user's question, verbatim.", required: true),
        ToolParameter("focus", .string, description: "Optional file, folder or symbol to anchor on."),
    ]

    public init() {}

    public func run(arguments: ToolArguments, context: ToolContext) async throws -> ToolOutput {
        let question = arguments.string("question") ?? ""
        let result = try context.engine.featureMap(question: question, focus: arguments.string("focus"))
        let text = FeatureMapRenderer.render(result, budget: context.budget(.featureMap))
        return ToolOutput(text: text, json: AnyEncodable(result), staleFiles: try context.engine.staleEvidenceFiles(of: result))
    }
}
