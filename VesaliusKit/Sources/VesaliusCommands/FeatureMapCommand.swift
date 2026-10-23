import ArgumentParser
import Foundation
import VesaliusCore
import VesaliusMCP

/// `vesalius feature-map`: the MCP `feature_map` tool on the command line, with the same text.
struct FeatureMap: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "feature-map", abstract: "Where and how a feature or behaviour is implemented (the MCP feature_map tool).")

    @Argument(help: "The question, e.g. \"where are purchases handled?\"")
    var question: [String]

    @Option(help: "A file, folder or symbol to anchor on.")
    var focus: String?

    @Flag(help: "Print the whole result, with no token budget.")
    var full = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            var arguments: [String: JSONValue] = ["question": .string(question.joined(separator: " "))]
            if let focus { arguments["focus"] = .string(focus) }
            try await global.runTool(FeatureMapTool(), arguments, full: full)
        }
    }
}
