import ArgumentParser
import Foundation
import VesaliusCore
import VesaliusMCP

/// `vesalius dependency-cycles`: the MCP `dependency_cycles` tool on the command line, with the same text.
struct DependencyCycles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dependency-cycles", abstract: "Circular dependencies, in the repository or under a folder (the MCP dependency_cycles tool).")

    @Option(help: "Only cycles under this folder, e.g. src/.")
    var path: String?

    @Flag(name: .customLong("include-tests"), help: "Include test files in the import graph (left out by default).")
    var includeTests = false

    @Flag(help: "Print the whole result, with no token budget.")
    var full = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            var arguments: [String: JSONValue] = [:]
            if let path { arguments["path"] = .string(path) }
            if includeTests { arguments["include_tests"] = .bool(true) }
            try await global.runTool(DependencyCyclesTool(), arguments, full: full)
        }
    }
}
