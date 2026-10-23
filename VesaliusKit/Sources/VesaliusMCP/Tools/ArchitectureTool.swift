import Foundation
import QueryEngine
import VesaliusCore
import VesaliusRender

/// `architecture`: the repository's structure.
///
/// Built from the project files and the code graph: the targets with their product type, folders, links,
/// embedded products and entry points, and the code no target builds; packages with products, internal
/// dependencies, re-exports and importers per target; each app module's folders with the dependency
/// direction its type references show, the edges against it, folder cycles, feature-to-feature edges and
/// the composition root; and what connects the targets (shared source, duplicated types, framework bridges,
/// app groups). Style is counted, never scored. `focus` narrows it to one target, package or folder.
public struct ArchitectureTool: MCPTool {
    public let name = "architecture"
    public let title = "Architecture"
    public let isV2 = true
    public let loading = ToolLoading.deferred
    public let searchHint = "architecture overview structure targets packages modules layers dependencies"
    public let descriptionShim = "Architecture overview inferred from the code graph: frameworks, layers and feature areas with their sizes and the areas they depend on, plus entry points."
    public let descriptionV2 = "Architecture overview from project files plus the code graph: targets with product type, folders, linked packages and embedded extensions; packages and products; each app module's folders with dependency direction, upward edges and cycles; cross-target links - replaces reading project.pbxproj/Package.swift."
    public let parameters = [
        ToolParameter("focus", .string, description: "Optional target, package or folder."),
    ]

    public init() {}

    public func run(arguments: ToolArguments, context: ToolContext) async throws -> ToolOutput {
        let overview = try context.engine.architectureOverview(focus: arguments.string("focus"))
        return ToolOutput(text: ArchitectureRenderer.render(overview, budget: context.budget(.architecture)), json: AnyEncodable(overview),
                          staleFiles: overview.staleFiles)
    }
}
