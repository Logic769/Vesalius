import Foundation
import QueryEngine
import VesaliusCore
import VesaliusRender

/// `repo_report`, offered only under `--profile full`: the v1 repository reports the default catalog dropped
/// (health, diagnostics, hotspots, unused code, overview, file search), as the CLI prints them.
public struct RepoReportTool: MCPTool {
    public let name = "repo_report"
    public let title = "Repository report"
    public let isV2 = false
    public let loading = ToolLoading.deferred
    public let searchHint = "health score diagnostics hotspots unused dead code overview dashboard find files"
    public let descriptionShim = "Repository reports: health score by category, diagnostics with evidence and recommendations, hotspots, unused code, an overview dashboard, or a fuzzy file search (kind files, with query)."
    public var descriptionV2: String { descriptionShim }
    public let parameters = [
        ToolParameter("kind", .oneOf(Kind.allCases.map(\.rawValue)), required: true),
        ToolParameter("query", .string, description: "For files: the name or path to find. For diagnostics: only those touching this file or folder."),
        ToolParameter("limit", .integer(minimum: 1)),
    ]

    enum Kind: String, CaseIterable {
        case health, diagnostics, hotspots, unused, overview, files
    }

    public init() {}

    static let budget = Budget(tokens: 2_000)

    public func run(arguments: ToolArguments, context: ToolContext) async throws -> ToolOutput {
        let engine = context.engine
        let kind = Kind(rawValue: arguments.string("kind") ?? "") ?? .overview
        let query = arguments.string("query")
        let limit = arguments.int("limit")
        let text: String
        let json: AnyEncodable
        switch kind {
        case .health:
            let health = try engine.health()
            let diagnostics = try engine.diagnostics(minimumSeverity: .medium, limit: limit ?? 12)
            text = TextFormatter.health(health, diagnostics: diagnostics, verbose: false)
            json = AnyEncodable(health)
        case .diagnostics:
            let list = try engine.diagnostics(minimumSeverity: .medium, path: query, limit: limit ?? 25)
            text = list.isEmpty ? "No diagnostics." : list.map { TextFormatter.diagnostic($0, detailed: true) }.joined(separator: "\n")
            json = AnyEncodable(list)
        case .hotspots:
            let hotspots = try engine.hotspots(limit: limit ?? 10)
            text = TextFormatter.hotspots(hotspots)
            json = AnyEncodable(hotspots)
        case .unused:
            let report = try engine.unused()
            let count = limit ?? 30
            let trimmed = UnusedReport(files: Array(report.files.prefix(count)), symbols: Array(report.symbols.prefix(count)), note: report.note)
            text = TextFormatter.unused(trimmed)
            json = AnyEncodable(trimmed)
        case .overview:
            let overview = try engine.overview()
            text = TextFormatter.overview(overview)
            json = AnyEncodable(overview)
        case .files:
            guard let query else { return .error("`query` is required for kind files: the file name or path to find.") }
            let hits = try engine.searchFiles(query, limit: limit ?? 15)
            text = TextFormatter.files(hits)
            json = AnyEncodable(hits)
        }
        return ToolOutput(text: LegacyShim.paged(text, head: 1, budget: context.budget(Self.budget)), json: json)
    }
}
