import Foundation
import Testing
@testable import VesaliusCommands
@testable import VesaliusMCP

/// The permission rule `vesalius setup` adds to Claude Code's settings: added and removed in place, the rest of the
/// file untouched, and never written when the result doesn't check out.
@Suite("Claude Code settings edits")
struct ClaudeSettingsTests {
    let rule = ClaudeSettings.vesaliusRule

    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func settings(_ text: String?) throws -> ClaudeSettings {
        let url = try folder().appendingPathComponent("settings.json")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return ClaudeSettings(url: url)
    }

    func contents(_ settings: ClaudeSettings) throws -> String {
        try String(contentsOf: settings.url, encoding: .utf8)
    }

    @Test func addsAPermissionsMemberAndUndoesItExactly() throws {
        let original = """
            {
              "model": "opus",
              "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "echo \\"{x}\\" [y], z"}]}]},
              "enabledPlugins": {}
            }

            """
        let file = try settings(original)
        #expect(file.addAllowRule(rule) == .changed)
        #expect(try contents(file) == original.replacingOccurrences(of: "{\n  \"model\"", with: "{\n  \"permissions\": {\"allow\": [\"mcp__vesalius__*\"]},\n  \"model\""))
        #expect(file.allows(rule))
        #expect(file.addAllowRule(rule) == .unchanged)
        #expect(file.removeAllowRule(rule) == .changed)
        #expect(try contents(file) == original)
        #expect(file.removeAllowRule(rule) == .unchanged)
    }

    @Test func joinsAnExistingAllowListInItsLayout() throws {
        let original = "{\r\n  \"permissions\": {\r\n    \"allow\": [\r\n      \"Bash(git status)\",\r\n      \"Read\"\r\n    ],\r\n    \"deny\": []\r\n  }\r\n}"
        let file = try settings(original)
        #expect(file.addAllowRule(rule) == .changed)
        #expect(try contents(file).contains("\"allow\": [\r\n      \"mcp__vesalius__*\",\r\n      \"Bash(git status)\","))
        #expect(file.removeAllowRule(rule) == .changed)
        #expect(try contents(file) == original)
    }

    @Test func addsAnAllowListBesideOtherPermissionsAndTakesItAwayAgain() throws {
        let original = #"{"permissions": {"deny": ["Bash(rm *)"]}}"#
        let file = try settings(original)
        #expect(file.addAllowRule(rule) == .changed)
        let added = try #require(ClaudeSettings.parse(try contents(file)))
        #expect(ClaudeSettings.allowList(added) == [rule])
        #expect((added["permissions"] as? [String: Any])?["deny"] as? [String] == ["Bash(rm *)"])
        #expect(file.removeAllowRule(rule) == .changed)
        #expect(try contents(file) == original)
    }

    @Test func acceptsAnEmptyPermissionsObject() throws {
        let file = try settings(#"{"permissions": {}, "model": "opus"}"#)
        #expect(file.addAllowRule(rule) == .changed)
        #expect(try contents(file) == #"{"permissions": {"allow": ["mcp__vesalius__*"]}, "model": "opus"}"#)
    }

    @Test func createsTheFileWhenThereIsNone() throws {
        let file = try settings(nil)
        #expect(file.addAllowRule(rule, dryRun: true) == .changed)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(file.addAllowRule(rule) == .changed)
        #expect(file.allows(rule))
    }

    @Test func handlesAnEmptyObject() throws {
        let file = try settings("{}")
        #expect(file.addAllowRule(rule) == .changed)
        #expect(try contents(file) == #"{"permissions": {"allow": ["mcp__vesalius__*"]}}"#)
        #expect(file.removeAllowRule(rule) == .changed)
        #expect(try contents(file) == "{}")
    }

    @Test(arguments: [
        ("comments", Data("{\n  // a comment\n  \"model\": \"opus\"\n}\n".utf8)),
        ("duplicate keys", Data(#"{"permissions": {"allow": []}, "permissions": {"deny": []}}"#.utf8)),
        ("invalid UTF-8", Data([0x7B, 0x22, 0x6D, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D])),
    ])
    func leavesFilesItCannotEditSafelyAlone(_ kind: String, _ original: Data) throws {
        let url = try folder().appendingPathComponent("settings.json")
        try original.write(to: url)
        let file = ClaudeSettings(url: url)
        guard case .skipped = file.addAllowRule(rule) else {
            Issue.record("expected \(kind) to be skipped")
            return
        }
        #expect(try Data(contentsOf: url) == original, "\(kind)")
    }

    @Test func undoTakesAwayExactlyWhatTheAdditionCreated() throws {
        for original in [#"{"permissions": {"allow": []}}"#, #"{"permissions": {}}"#, #"{"model": "opus"}"#, #"{"permissions": {"allow": ["Read"]}}"#] {
            let file = try settings(original)
            let created = try #require(file.creation())
            #expect(file.addAllowRule(rule) == .changed)
            #expect(file.removeAllowRule(rule, created: created) == .changed)
            #expect(try contents(file) == original, "\(original) after add and undo, created \(created)")
        }
        let fresh = try settings(nil)
        #expect(fresh.creation() == .file)
        #expect(fresh.addAllowRule(rule) == .changed)
        #expect(fresh.removeAllowRule(rule, created: .file) == .changed)
        #expect(!FileManager.default.fileExists(atPath: fresh.url.path), "a file setup created goes when it ends up empty")
    }

    @Test func undoIgnoresRepeatedKeysWhenThereIsNoRuleToRemove() throws {
        let file = try settings(#"{"permissions": {"allow": ["Bash(ls)"]}, "permissions": {"allow": ["Read"]}}"#)
        #expect(file.removeAllowRule(rule) == .unchanged)
    }

    @Test func neverReplacesAFileItCannotRead() throws {
        let original = #"{"model": "precious", "permissions": {"deny": ["Bash(rm:*)"]}}"#
        let file = try settings(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path) }
        guard case .skipped = file.addAllowRule(rule) else {
            Issue.record("an unreadable settings file must be left alone")
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
        #expect(try contents(file) == original)

        let dangling = try folder().appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/nonexistent/settings.json")
        guard case .skipped = ClaudeSettings(url: dangling).addAllowRule(rule) else {
            Issue.record("a dangling symlink must be left alone")
            return
        }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: dangling.path)) == "/nonexistent/settings.json")
    }

    @Test func editsThroughASymlinkAndKeepsPermissions() throws {
        let dotfiles = try folder().appendingPathComponent("settings.json")
        try #"{"model": "opus"}"#.write(to: dotfiles, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotfiles.path)
        let link = try folder().appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotfiles)
        let file = ClaudeSettings(url: link)
        #expect(file.addAllowRule(rule) == .changed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == dotfiles.path)
        #expect(try String(contentsOf: dotfiles, encoding: .utf8).contains("mcp__vesalius__*"))
        #expect((try FileManager.default.attributesOfItem(atPath: dotfiles.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(file.removeAllowRule(rule) == .changed)
        #expect(try String(contentsOf: dotfiles, encoding: .utf8) == #"{"model": "opus"}"#)
    }
}

@Suite("Agent registrations and probes")
struct AgentRegistrationTests {
    @Test func readsTheRegistrationClaudeCodeReports() {
        let registration = ClaudeRegistration.parse("""
            vesalius:
              Scope: User config (available in all your projects)
              Status: ✔ Connected
              Type: stdio
              Command: /opt/homebrew/bin/vesalius
              Args: mcp --repo /Users/me/code/app
              Environment:
                VESALIUS_MCP_PROFILE=lean

            To remove this server, run: claude mcp remove vesalius -s user
            """)
        #expect(registration.isUserScope && registration.isConnected && !registration.isPendingApproval)
        #expect(registration.arguments == ["mcp", "--repo", "/Users/me/code/app"])
        #expect(registration.environment == ["VESALIUS_MCP_PROFILE": "lean"])
        #expect(registration.pinnedRepository == "/Users/me/code/app")
        #expect(registration.commandLine == "/opt/homebrew/bin/vesalius mcp --repo /Users/me/code/app")
        #expect(Agent.claude.addition(command: "/x/vesalius", arguments: registration.arguments, environment: registration.environment)
            == ["mcp", "add", "--scope", "user", "vesalius", "-e", "VESALIUS_MCP_PROFILE=lean", "--", "/x/vesalius", "mcp", "--repo", "/Users/me/code/app"])

        let pending = ClaudeRegistration.parse("vesalius:\n  Scope: Project config (shared via .mcp.json)\n  Status: ⏸ Pending approval\n  Command: vesalius\n  Args: mcp\n")
        #expect(pending.isPendingApproval && !pending.isUserScope && !pending.isConnected)
    }

    @Test func readsExactArgumentsFromClaudeCodesConfig() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("claude-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let json = #"{"mcpServers": {"vesalius": {"type": "stdio", "command": "/opt/homebrew/bin/vesalius", "args": ["mcp", "--repo", "/Users/me/My Project"], "env": {"VESALIUS_MCP_PROFILE": "lean"}}}}"#
        try json.write(to: config.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let entry = try #require(ClaudeRegistration.userEntry(environment: ["CLAUDE_CONFIG_DIR": config.path]))
        #expect(entry.command == "/opt/homebrew/bin/vesalius")
        #expect(entry.arguments == ["mcp", "--repo", "/Users/me/My Project"])
        #expect(entry.environment == ["VESALIUS_MCP_PROFILE": "lean"])
    }

    @Test func keepsOutputWhenAChildLeavesSomethingRunning() throws {
        let started = Date()
        let run = try #require(ExternalTool.run("/bin/sh", ["-c", "echo hello; sleep 30 &"], timeout: 20))
        #expect(run.succeeded)
        #expect(run.output == "hello\n")
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func readsTheRepositoryAServerSaysItServes() {
        let log = "[vesalius] vesalius MCP server 2.1.0, repository /Users/me/code/my app, profile default, deferred: outline\n"
        #expect(MCPProbe.servedRepository(in: log) == "/Users/me/code/my app")
        #expect(MCPProbe.servedRepository(in: "something else\n") == nil)
        #expect(Doctor.shellQuoted("/Users/me/Library/Application Support/x") == "'/Users/me/Library/Application Support/x'")
        #expect(Doctor.shellQuoted("/opt/homebrew/bin/vesalius") == "/opt/homebrew/bin/vesalius")
    }
}

@Suite("Usage log")
struct UsageLogTests {
    func record(_ index: Int, repository: String = "/repo", tool: String = "usages", via: String = "mcp", complete: Bool? = nil) -> UsageRecord {
        UsageRecord(time: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), repository: repository, tool: tool, via: via, milliseconds: index, answerCharacters: 400, complete: complete)
    }

    func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)").appendingPathComponent("usage.jsonl")
    }

    @Test func appendsAndReadsRecordsInOrder() {
        let url = temporaryLog()
        for index in 0..<10 { UsageLog.append(record(index, complete: index.isMultiple(of: 2)), to: url) }
        let records = UsageLog.read(from: url)
        #expect(records.map(\.milliseconds) == Array(0..<10))
        #expect(records.first == record(0, complete: true))
    }

    @Test func rotatesAFullLogAndKeepsTheNewestRecords() throws {
        let url = temporaryLog()
        for index in 0..<20 { UsageLog.append(record(index), to: url, rotatingAt: 600) }
        let kept = UsageLog.read(from: url).map(\.milliseconds)
        #expect(kept.last == 19)
        #expect(kept == kept.sorted() && kept.count >= 4 && kept.count < 20)
        #expect(FileManager.default.fileExists(atPath: UsageLog.rotated(url).path))
        #expect(try UsageLog.reset(at: url))
        #expect(UsageLog.read(from: url).isEmpty)
        #expect(try UsageLog.reset(at: url) == false)
    }

    @Test func concurrentWritersNeverInterleaveLines() throws {
        let url = temporaryLog()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            UsageLog.append(record(index, tool: String(repeating: "x", count: index % 50 + 1)), to: url)
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 200)
        #expect(UsageLog.read(from: url).count == 200)
    }

    @Test func reportTotalsByToolForOneRepository() {
        let records = [
            UsageRecord(repository: "/a", tool: "usages", via: "mcp", milliseconds: 30, answerCharacters: 4_000, complete: true),
            UsageRecord(repository: "/a", tool: "usages", via: "mcp", milliseconds: 50, answerCharacters: 2_000, complete: false),
            UsageRecord(repository: "/a", tool: "outline", via: "cli", milliseconds: 4, answerCharacters: 400),
            UsageRecord(repository: "/b", tool: "usages", via: "mcp", milliseconds: 1, answerCharacters: 9_999),
        ]
        let report = UsageReport(records: records, repository: "/a", days: 30)
        #expect(report.rows.map(\.name) == ["usages", "outline"])
        #expect(report.total.calls == 3 && report.total.answerCharacters == 6_400 && report.total.medianMilliseconds == 30)
        #expect(report.rows.first?.medianMilliseconds == 40)
        #expect(report.overMCP == 2 && report.fromCommandLine == 1)
        let text = report.text()
        #expect(text.contains("Completeness checks passed: 1 of 2."))
        #expect(text.contains("Last call") && text.contains("2 over MCP, 1 from the command line"))
        let usagesRow = text.split(separator: "\n").first { $0.hasPrefix("  usages ") }
        #expect(usagesRow?.hasSuffix("2     1.5k          750          40 ms") == true, "\(text)")
    }

    @Test func roundsTokensBeforeChoosingTheUnit() {
        #expect(UsageReport.tokens(1_000) == "250")
        #expect(UsageReport.tokens(3_998) == "1.0k")
        #expect(UsageReport.tokens(399_990) == "100k")
        #expect(UsageReport.tokens(3_900_000) == "975k")
        #expect(UsageReport.tokens(3_999_000) == "1.0M")
    }

    @Test func recordsFromAClockThatRanAheadWaitForTheirTime() {
        let past = UsageRecord(time: Date().addingTimeInterval(-3_600), repository: "/a", tool: "usages", via: "mcp", milliseconds: 1, answerCharacters: 1)
        let future = UsageRecord(time: Date().addingTimeInterval(400 * 86_400), repository: "/a", tool: "usages", via: "mcp", milliseconds: 1, answerCharacters: 1)
        let report = UsageReport(records: [past, future], repository: "/a", days: 1)
        #expect(report.total.calls == 1)
        #expect(report.lastCall == past.time)
    }

    @Test func reportsOnALargeLogQuickly() {
        let records = (0..<60_000).map { UsageRecord(time: Date().addingTimeInterval(-Double($0)), repository: "/a", tool: ["usages", "outline", "feature_map"][$0 % 3], via: "mcp", milliseconds: $0 % 500, answerCharacters: 800) }
        let started = Date()
        let report = UsageReport(records: records, repository: nil, days: 0)
        #expect(report.total.calls == 60_000)
        #expect(Date().timeIntervalSince(started) < 5, "a report over 60,000 records should take moments")
    }
}

/// `setup`, `doctor` and `stats` through the real binary.
@Suite("Setup, doctor and stats end to end", .serialized)
struct SetupEndToEndTests {
    @Test func statsCountsAnsweredCallsAndTheirCompleteness() throws {
        let root = try RepoFixture.make([
            "Sources/Store.swift": "struct Store {\n    func save() {}\n}\n",
            "Sources/Checkout.swift": "func checkout() {\n    Store().save()\n}\n",
        ], name: "stats")
        let usages = try MCPProcess.run(["usages", "Store", "--repo", root.path, "-q"])
        #expect(usages.status == 0, "\(usages.stderr)")
        let stats = try MCPProcess.run(["stats", "--repo", root.path, "--json"])
        #expect(stats.status == 0, "\(stats.stderr)")
        let report = try JSONSerialization.jsonObject(with: Data(stats.stdout.utf8)) as? [String: Any]
        let total = report?["total"] as? [String: Any]
        #expect(total?["calls"] as? Int == 1)
        #expect(total?["complete"] as? Int == 1, "the usages answer's completeness check passed")
        #expect(report?["fromCommandLine"] as? Int == 1)
        let text = try MCPProcess.run(["stats", "--repo", root.path])
        #expect(text.stdout.contains("usages"))
        let negative = try MCPProcess.run(["stats", "--days", "-1"])
        #expect(negative.status != 0)
    }

    @Test func setupDryRunWritesNothing() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("claude-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let run = try MCPProcess.run(["setup", "--dry-run", "--no-index"], environment: ["CLAUDE_CONFIG_DIR": config.path], timeout: 180)
        #expect(run.status == 0, "\(run.stdout)\n\(run.stderr)")
        #expect(run.stdout.contains("Nothing changed (dry run)."))
        let written = (FileManager.default.enumerator(atPath: config.path)?.allObjects as? [String] ?? [])
            .compactMap { try? String(contentsOf: config.appendingPathComponent($0), encoding: .utf8) }
        #expect(!written.contains { $0.contains("vesalius") })
    }

    @Test func doctorChecksTheServerItWouldLaunch() throws {
        let root = try RepoFixture.make(["main.swift": "print(1)\n"], name: "doctor")
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("claude-config-\(UUID().uuidString)")
        let run = try MCPProcess.run(["doctor", "--repo", root.path, "--json"], environment: ["CLAUDE_CONFIG_DIR": config.path], timeout: 180)
        let checks = try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [[String: Any]] ?? []
        let server = checks.first { ($0["summary"] as? String)?.hasPrefix("MCP server answers") == true }
        #expect(server?["status"] as? String == "ok", "\(run.stdout)")
        #expect(checks.contains { ($0["summary"] as? String) == "Repository: \(root.lastPathComponent) (\(UsageReport.tilde(root.path)))" }, "\(run.stdout)")

        let missing = try MCPProcess.run(["doctor", "--repo", root.appendingPathComponent("nope").path, "--json"], environment: ["CLAUDE_CONFIG_DIR": config.path], timeout: 60)
        #expect(missing.status == 1)
        #expect(missing.stdout.contains("No such folder"))
    }
}
