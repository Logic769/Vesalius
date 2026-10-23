import ArgumentParser
import Foundation
import QueryEngine

/// Developer diagnostics for the index and the evidence it serves (`vesalius debug …`). Hidden from help:
/// the output is for checking the engine, not a stable interface.
struct Debug: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Developer diagnostics for the index.",
        shouldDisplay: false,
        subcommands: [DebugCompleteness.self, DebugStatement.self, DebugTarget.self]
    )
}

struct DebugCompleteness: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completeness",
        abstract: "Classify every occurrence of a name against a target and print the completeness line."
    )

    @Argument(help: "The identifier to look for, e.g. ensureFresh.")
    var name: String

    @Option(help: "The target the uses must resolve to, in usages syntax (Type.member, path#Name, a file, …).")
    var target: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            print(try engine.completenessReport(name: name, target: target))
        }
    }
}

struct DebugStatement: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statement",
        abstract: "Show the statement evidence for a site: bounds, joined text, rendered lines, condition, consumer."
    )

    @Argument(help: "The site as <path>:<line>, the path relative to the repository.")
    var site: String

    @Option(help: "The identifier at the site (default: the first call or reference recorded on that line).")
    var name: String?

    @OptionGroup var global: GlobalOptions

    /// `site` split into its path and line.
    private var location: (path: String, line: Int)? {
        guard let colon = site.lastIndex(of: ":"), let line = Int(site[site.index(after: colon)...]), line >= 1 else { return nil }
        return (String(site[..<colon]), line)
    }

    func validate() throws {
        guard location != nil else { throw ValidationError("Expected <path>:<line>, e.g. Sources/App/Login.swift:42.") }
    }

    func run() async throws {
        guard let location else { return }
        try await global.run {
            let engine = try await global.engine()
            print(try engine.statementReport(path: location.path, line: location.line, name: name))
        }
    }
}

struct DebugTarget: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "target",
        abstract: "Resolve a usages target: one declaration, a file's extensions of a type, a file, folder, module, framework, environment variable, or the choices."
    )

    @Argument(help: "The target text, e.g. \"RepositoryEngine.ensureFresh(options:progress:)\", path#Name, path:line, StoreKit.")
    var text: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            print(try engine.extensionTargetReport(text) ?? engine.usageTargetReport(text))
        }
    }
}
