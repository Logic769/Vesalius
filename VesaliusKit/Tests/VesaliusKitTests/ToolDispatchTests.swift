import Foundation
import Testing
import QueryEngine
import VesaliusCore
import VesaliusMCP

/// The dispatcher's freshness rule, which the v2 tools rely on: a tool that quotes lines the files
/// no longer have asks for one re-index and runs again, and the result says so. Real engine, index and file edit.
@Suite("Tool dispatch")
struct ToolDispatchTests {
    /// Lists a file's declarations, and reports the file stale while the index is older than the disk.
    struct DeclarationsTool: MCPTool {
        let name = "declarations"
        let title = "Declarations"
        let descriptionShim = "Declarations of a file."
        let descriptionV2 = "Declarations of a file."
        let isV2 = false
        let searchHint = "declarations"
        let loading = ToolLoading.deferred
        let parameters = [ToolParameter("path", .string, description: "A file path.", required: true)]

        func run(arguments: ToolArguments, context: ToolContext) async throws -> ToolOutput {
            let path = arguments.string("path") ?? ""
            let names = try context.engine.fileContext(path).symbols.map(\.name)
            return ToolOutput(text: names.joined(separator: ","), staleFiles: try context.engine.staleFileCount() > 0 ? [path] : [])
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    @Test("A stale result triggers one re-index and a second run that says so")
    func staleRetry() async throws {
        let (engine, root) = try await RepoFixture.indexed(["Sources/A.swift": "struct A {}\n"], name: "dispatch")
        try RepoFixture.write("struct A {}\nstruct B {}\n", to: "Sources/A.swift", in: root)
        let reindexes = Counter()
        let context = ToolContext(engine: engine) {
            reindexes.increment()
            let summary = try await engine.index(options: RepoFixture.fastOptions)
            return summary.filesAdded + summary.filesChanged + summary.filesRemoved
        }
        let tool = DeclarationsTool()
        let arguments: [String: JSONValue] = ["path": .string("Sources/A.swift")]

        let stale = await MCPToolCatalog.execute(tool, arguments: arguments, context: context)
        #expect(stale.text == "re-indexed 1 file\nA,B")
        #expect(reindexes.value == 1)

        let fresh = await MCPToolCatalog.execute(tool, arguments: arguments, context: context)
        #expect(fresh.text == "A,B" && !fresh.isError)
        #expect(reindexes.value == 1)

        let missing = await MCPToolCatalog.execute(tool, arguments: ["repo": .string("/elsewhere")], context: context)
        #expect(missing.isError && missing.text == "Missing required argument `path`: A file path.")
    }
}
