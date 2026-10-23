import ArgumentParser
import Foundation
import VesaliusCore
import VesaliusMCP

/// `vesalius outline`: the MCP `outline` tool on the command line, with the same text.
struct Outline: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Compact outline of a file, type, folder or function (the MCP outline tool).")

    @Argument(help: "File, folder, type or function.")
    var target: String

    @Flag(help: "Print the whole result, with no token budget.")
    var full = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            try await global.runTool(OutlineTool(), ["target": .string(target)], full: full)
        }
    }
}
