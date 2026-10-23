import ArgumentParser
import Foundation
import VesaliusCore
import VesaliusMCP

/// `vesalius usages`: the MCP `usages` tool on the command line, with the same text.
struct Usages: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Who calls, uses, imports or depends on a symbol or file (the MCP usages tool).")

    @Argument(help: "Type.member, Type.method(label:), file path, path#Name, path:line, folder, or module (e.g. StoreKit).")
    var target: String

    @Option(help: "Plan a change: rename, signature or remove.")
    var change: String?

    @Option(help: "Page of a long result.")
    var page: Int?

    @Flag(help: "Print the whole result, with no token budget or pages.")
    var full = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            var arguments: [String: JSONValue] = ["target": .string(target)]
            if let change { arguments["change"] = .string(change) }
            if let page { arguments["page"] = .int(Int64(page)) }
            try await global.runTool(UsagesTool(), arguments, full: full)
        }
    }
}
