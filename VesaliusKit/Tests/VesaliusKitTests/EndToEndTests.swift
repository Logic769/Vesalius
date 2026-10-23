import Foundation
import Testing
@testable import QueryEngine
import RepositoryIndex
import VesaliusCore

/// Drives the real `vesalius` executable: the same binary agents run.
@Suite("CLI and MCP end to end", .serialized)
struct EndToEndTests {
    @Test("index, ask, dependents, impact, symbols and health produce decodable JSON")
    func cliJSON() throws {
        let root = try RepoFixture.make(RepoFixture.app, name: "cli")
        let decoder = VesaliusJSON.decoder()

        let index = try CLI.run(["index", root.path, "--json", "--no-embeddings", "--no-history", "-q"])
        #expect(index.status == 0, "\(index.stderr)")
        let summary = try decoder.decode(IndexSummary.self, from: index.data)
        #expect(summary.filesScanned == RepoFixture.expectedAppFiles.count)

        let ask = try CLI.run(["ask", "where", "do", "users", "sign", "in?", "--json", "--repo", root.path, "--no-refresh"])
        #expect(ask.status == 0, "\(ask.stderr)")
        let answer = try decoder.decode(AskResult.self, from: ask.data)
        #expect(!answer.files.isEmpty && !answer.answer.isEmpty)
        #expect(answer.files.allSatisfy { (0...1).contains($0.relevance) })

        let dependents = try CLI.run(["dependents", "web/src/api/client.ts", "--depth", "2", "--json", "--repo", root.path, "--no-refresh"])
        let result = try decoder.decode(DependencyResult.self, from: dependents.data)
        #expect(Set(result.files.map(\.path)) == ["web/src/api/users.ts", "web/src/ui/UserCard.tsx"])

        let impact = try CLI.run(["impact", "SessionStore", "--json", "--repo", root.path, "--no-refresh"])
        let report = try decoder.decode(ImpactReport.self, from: impact.data)
        #expect(report.directDependents.contains { $0.path == "Sources/App/AuthService.swift" })

        let symbols = try CLI.run(["symbols", "Auth", "--json", "--repo", root.path, "--no-refresh"])
        let hits = try decoder.decode([SymbolHit].self, from: symbols.data)
        #expect(hits.first?.symbol.name == "AuthService")
        // Line ranges serialise compactly for agents.
        #expect(symbols.stdout.contains("\"lines\":\""))

        let health = try CLI.run(["health", "--json", "--repo", root.path, "--no-refresh"])
        struct Health: Decodable { let health: HealthReport; let diagnostics: [Diagnostic] }
        #expect(try decoder.decode(Health.self, from: health.data).health.categories.count == HealthCategory.allCases.count)

        let query = try CLI.run(["query", "SELECT COUNT(*) AS n FROM files", "--json", "--repo", root.path, "--no-refresh"])
        #expect(query.stdout.contains("\"n\""))
    }

    @Test("Errors are reported as JSON with a non-zero exit status")
    func cliErrors() throws {
        let root = try RepoFixture.make(RepoFixture.app, name: "cli-errors")
        _ = try CLI.run(["index", root.path, "-q", "--no-embeddings", "--no-history"])
        let missing = try CLI.run(["references", "NoSuchSymbolAnywhere", "--json", "--repo", root.path, "--no-refresh"])
        #expect(missing.status != 0)
        #expect(missing.stdout.contains("\"error\""))
        let writes = try CLI.run(["query", "DELETE FROM files", "--repo", root.path, "--no-refresh"])
        #expect(writes.status != 0)
    }

    @Test("The CLI picks up edits automatically before answering")
    func autoRefresh() throws {
        let root = try RepoFixture.make(RepoFixture.app, name: "refresh")
        _ = try CLI.run(["index", root.path, "-q", "--no-embeddings", "--no-history"])
        try RepoFixture.write("export function freshlyAddedHelper() { return 42; }\n", to: "web/src/fresh.ts", in: root)
        let result = try CLI.run(["symbols", "freshlyAddedHelper", "--json", "--repo", root.path, "-q"])
        let hits = try VesaliusJSON.decoder().decode([SymbolHit].self, from: result.data)
        #expect(hits.first?.symbol.path == "web/src/fresh.ts")
    }

    @Test("MCP server: five read-only tools, text results, argument errors that name the fix, ping never waits")
    func mcp() throws {
        let root = try RepoFixture.make(RepoFixture.app, name: "mcp")
        let messages = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            // The first call builds the index; the ping right behind it must not wait for that.
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"usages","arguments":{"target":"ApiClient"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"usages","arguments":{"target":"web/src/api/client.ts","repo":"/somewhere/else"}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"feature_map","arguments":{"question":"user card component"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"outline","arguments":{"target":"Sources/App/AuthService.swift"}}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"usages","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"usages","arguments":{"target":"ApiClient","change":"rewrite"}}}"#,
            #"{"jsonrpc":"2.0","id":10,"method":"no/such/method"}"#,
        ].joined(separator: "\n") + "\n"
        let output = try MCPProcess.run(["mcp", "--repo", root.path], input: messages)
        let lines = output.stdout.split(separator: "\n").map(String.init)
        let responses = lines.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        func response(_ id: Int) -> JSONValue? { responses.first { $0["id"]?.intValue == id } }
        func position(_ id: Int) -> Int? { responses.firstIndex { $0["id"]?.intValue == id } }

        #expect(responses.count == 10, "\(output.stderr)")                     // the notification gets no reply
        #expect(response(1)?["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(response(1)?["result"]?["serverInfo"]?["version"]?.stringValue == "2.0.0")
        let instructions = response(1)?["result"]?["instructions"]?.stringValue ?? ""
        #expect(instructions.contains("select:mcp__vesalius__architecture,mcp__vesalius__dependency_cycles,mcp__vesalius__outline\""))
        #expect(instructions.count <= 1_100)

        guard case .array(let tools) = response(2)?["result"]?["tools"] ?? .null else {
            Issue.record("tools/list returned no tools")
            return
        }
        #expect(tools.map { $0["name"]?.stringValue ?? "" } == ["usages", "feature_map", "architecture", "dependency_cycles", "outline"])
        for tool in tools {
            let name = tool["name"]?.stringValue ?? ""
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(true), "\(name)")
            #expect(tool["annotations"]?["title"]?.stringValue?.isEmpty == false, "\(name)")
            #expect(tool["_meta"]?["anthropic/searchHint"]?.stringValue?.isEmpty == false, "\(name)")
            #expect((tool["description"]?.stringValue?.count ?? 999) <= 320, "\(name)")
            guard case .object(let properties) = tool["inputSchema"]?["properties"] ?? .null else {
                Issue.record("\(name) has no properties")
                continue
            }
            #expect(properties.count <= 3 && properties["repo"] == nil, "\(name)")
            // usages and feature_map passed their golden gates and load up front; deferred tools say so explicitly.
            let alwaysLoad = tool["_meta"]?["anthropic/alwaysLoad"]
            #expect(alwaysLoad == .bool(["usages", "feature_map"].contains(name)), "\(name)")
        }

        func text(_ id: Int) -> String {
            guard case .array(let content) = response(id)?["result"]?["content"] ?? .null else { return "" }
            return content.first?["text"]?.stringValue ?? ""
        }
        func isError(_ id: Int) -> Bool? { response(id)?["result"]?["isError"]?.boolValue }

        if let ping = position(4), let call = position(3) { #expect(ping < call, "ping waited for the first tool call") }
        #expect(response(4)?["result"] == .object([:]))
        // Every call that waited for the first index says so; results are plain text, never JSON.
        #expect(text(3).hasPrefix("index: built just now ("), "\(text(3))")
        for id in [3, 5, 6, 7] {
            #expect(isError(id) == false, "\(id): \(text(id))")
            #expect(!text(id).contains("{\""), "\(id) looks like JSON: \(text(id))")
        }
        #expect(text(3).contains("web/src/api/users.ts") && text(3).contains("ApiClient"))
        #expect(text(5).contains("web/src/api/users.ts"))                     // the old `repo` argument is ignored
        #expect(text(6).contains("UserCard"))
        #expect(text(7).contains("Sources/App/AuthService.swift") && text(7).contains("signIn"))
        #expect(isError(8) == true && text(8).contains("`target`") && text(8).contains("path#Name"))
        #expect(isError(9) == true && text(9).contains("rename, signature, remove"))
        #expect(response(10)?["error"]?["code"]?.intValue == -32601)
    }

    @Test("MCP profiles, the always-load override and where the repository comes from")
    func mcpProfiles() throws {
        let root = try RepoFixture.make(["Sources/A.swift": "struct A {}\n"], name: "profiles")
        let other = try RepoFixture.make(["Sources/B.swift": "struct B {}\n"], name: "profiles-other")
        let handshake = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ].joined(separator: "\n") + "\n"
        struct Listing {
            var loading: [String: JSONValue?] = [:]
            var instructions = ""
            var log = ""
        }
        func listing(_ arguments: [String], environment: [String: String] = [:]) throws -> Listing {
            let output = try MCPProcess.run(["mcp"] + arguments, environment: environment, input: handshake)
            var result = Listing(log: output.stderr)
            for line in output.stdout.split(separator: "\n") {
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                if let instructions = message["result"]?["instructions"]?.stringValue { result.instructions = instructions }
                if case .array(let tools) = message["result"]?["tools"] ?? .null {
                    for tool in tools { result.loading[tool["name"]?.stringValue ?? ""] = .some(tool["_meta"]?["anthropic/alwaysLoad"]) }
                }
            }
            return result
        }
        let five = ["usages", "feature_map", "architecture", "dependency_cycles", "outline"]

        let lean = try listing(["--repo", root.path, "--profile", "lean"])
        #expect(Set(lean.loading.keys) == Set(five))
        #expect(lean.loading.values.allSatisfy { $0 == .bool(false) })
        let full = try listing(["--repo", root.path, "--profile", "full"])
        #expect(Set(full.loading.keys) == Set(five + ["repo_report"]))
        #expect(full.loading["repo_report"] == .some(.bool(false)))
        #expect(full.instructions.contains("mcp__vesalius__repo_report"))
        #expect(Set(try listing(["--repo", root.path], environment: ["VESALIUS_MCP_PROFILE": "full"]).loading.keys).count == 6)
        #expect(Set(try listing(["--repo", root.path, "--profile", "lean"], environment: ["VESALIUS_MCP_PROFILE": "full"]).loading.keys).count == 5)

        let override = try listing(["--repo", root.path], environment: ["VESALIUS_MCP_ALWAYS_LOAD": "usages,feature_map"])
        #expect(override.loading["usages"] == .some(.bool(true)) && override.loading["feature_map"] == .some(.bool(true)))
        #expect(override.loading["outline"] == .some(.bool(false)))
        #expect(override.instructions.contains("select:mcp__vesalius__architecture,mcp__vesalius__dependency_cycles,mcp__vesalius__outline\""))

        // --repo, then VESALIUS_REPO, then CLAUDE_PROJECT_DIR (a folder inside an indexed repository), then the working directory.
        _ = try CLI.run(["index", other.path, "-q", "--no-embeddings", "--no-history"])
        func served(_ log: String) -> String? {
            guard let first = log.split(separator: "\n").first, let range = first.range(of: "repository ") else { return nil }
            return String(first[range.upperBound...].prefix { $0 != "," })
        }
        #expect(served(try listing(["--repo", root.path], environment: ["VESALIUS_REPO": other.path]).log) == root.path)
        #expect(served(try listing([], environment: ["VESALIUS_REPO": root.path, "CLAUDE_PROJECT_DIR": other.path]).log) == root.path)
        #expect(served(try listing([], environment: ["CLAUDE_PROJECT_DIR": other.path.appending("/Sources")]).log) == other.path)

        let version = try MCPProcess.run(["--version"])
        #expect(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "2.0.0")
    }

    @Test("The CLI prints exactly the MCP text of a tool")
    func toolParity() throws {
        let root = try RepoFixture.make(RepoFixture.app, name: "parity")
        _ = try CLI.run(["index", root.path, "-q", "--no-embeddings", "--no-history"])
        let cli = try CLI.run(["usages", "ApiClient", "--repo", root.path, "--no-refresh"])
        #expect(cli.status == 0, "\(cli.stderr)")
        let call = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"usages","arguments":{"target":"ApiClient"}}}"#,
        ].joined(separator: "\n") + "\n"
        let server = try MCPProcess.run(["mcp", "--repo", root.path], input: call)
        let message = server.stdout.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }.first { $0["id"]?.intValue == 2 }
        guard case .array(let content) = message?["result"]?["content"] ?? .null, let text = content.first?["text"]?.stringValue else {
            Issue.record("no usages result: \(server.stderr)")
            return
        }
        #expect(cli.stdout == text + "\n")

        let bad = try CLI.run(["usages", "ApiClient", "--change", "rewrite", "--repo", root.path, "--no-refresh"])
        #expect(bad.status != 0 && bad.stderr.contains("rename, signature, remove"))
    }
}

/// Runs the built `vesalius` with a controlled environment: the MCP profile and repository variables come only
/// from the test, never from the shell that runs it.
enum MCPProcess {
    static func run(_ arguments: [String], environment: [String: String] = [:], input: String? = nil, timeout: TimeInterval = 120) throws -> CLI.Output {
        _ = RepoFixture.home
        var base = ProcessInfo.processInfo.environment
        for key in ["VESALIUS_MCP_PROFILE", "VESALIUS_MCP_ALWAYS_LOAD", "VESALIUS_REPO", "CLAUDE_PROJECT_DIR"] { base[key] = nil }
        base["VESALIUS_HOME"] = RepoFixture.home.path
        let process = Process()
        process.executableURL = CLI.executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.environment = base.merging(environment) { $1 }
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return CLI.Output(stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self), status: process.terminationStatus)
    }
}
