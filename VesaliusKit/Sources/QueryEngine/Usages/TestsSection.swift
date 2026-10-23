import Foundation
import RepositoryIndex
import VesaliusCore

/// TESTS for `usages(target, change:)`: which tests a change touches, each with the fact
/// that links it to the target, and the commands that run them. Nothing beyond that link is claimed: a UI test
/// is "linked by literal", not "tests the target".
///
/// 1. direct: test files with uses of the target itself.
/// 2. compile-coupled: test files that use the target's owner type (they recompile), with their suites.
/// 3. UI: UI-test literals equal to an app literal (or, in a `contains` check, part of one) that sits in a
///    declaration using the target (tier 1), in one such a declaration references (tier 2), or elsewhere in a file
///    using it (tier 3); shown with the test function around the literal and both lines. Only distinctive
///    literals link (a blank, or 16 characters or more).
/// 4. hook: environment variables tests set that a function writing the target reads (`start` :109 →
///    `isSubscribed = true` :110).
/// 5. run: the repository's own runner script usage lines (quoted with their line), else `xcodebuild` with
///    `-only-testing:` ids checked against the test targets, `swift test --filter`, or the npm test script. A
///    class is called skipped only when the scheme's default test plan skips it.
extension UsageBuilder {
    func testsSection(symbol: UsageSymbolInfo, group: DeclarationGroup, rows: [UsageRow]) throws -> UsageTests {
        var tests = UsageTests()
        try loadFiles(rows.map(\.fileID))

        // 1. Tests that use the target.
        let directFiles = Dictionary(grouping: rows.filter { file($0.fileID)?.isTest == true }, by: \.fileID)
        for (fileID, fileRows) in directFiles.sorted(by: { (file($0.key)?.path ?? "") < (file($1.key)?.path ?? "") }) {
            guard let info = file(fileID) else { continue }
            tests.direct.append(UsageTestFile(path: info.path, kind: info.testKind ?? "unit", suites: try suites(inFile: info.path), lines: fileRows.map(\.line).sorted()))
        }

        // 2. Tests that use the owner type but not the target.
        if let owner = try ancestors(of: symbol.id).first(where: { $0.kind.isType || $0.kind == .extension }) {
            let typeGroup = try ownerTypeIDs(owner)
            let users = try ownerUsers(typeIDs: typeGroup.ids, memberIDs: try memberIDs(ofType: typeGroup.symbol, ids: typeGroup.ids), excludingFiles: Set(directFiles.keys))
            for user in users {
                guard let info = file(user.fileID), info.isTest else { continue }
                let used = try usedMemberNames(user.rows, ownerIDs: Set(typeGroup.ids), ownerName: typeGroup.symbol.name)
                tests.compileCoupled.append(UsageTestFile(path: info.path, kind: info.testKind ?? "unit", suites: try suites(inFile: info.path), uses: used.isEmpty ? [typeGroup.symbol.name] : used))
            }
        }

        // 3. UI tests linked by literals; 4. launch hooks.
        tests.ui = try uiLinks(rows: rows)
        tests.hooks = try hooks(symbol: symbol, rows: rows)
        tests.run = try runCommands(for: tests)
        return tests
    }

    // MARK: Suites

    /// The suites a test file declares: top-level types with `@Suite`, with `@Test` members, that subclass
    /// `XCTestCase`, or that hold `test…` methods; then its top-level `@Test` functions (`name()`), which run on
    /// their own.
    func suites(inFile path: String) throws -> [String] {
        let rows = try db.query("""
            SELECT s.name, COALESCE(s.attributes, ''), COALESCE(s.inherits, ''),
                   (SELECT COUNT(*) FROM symbols c WHERE c.parent_id = s.id AND (c.attributes LIKE '%@Test%' OR (c.name LIKE 'test%' AND c.kind = 'method')))
            FROM symbols s JOIN files f ON f.id = s.file_id
            WHERE f.path = ? AND s.depth = 0 AND s.kind IN ('class','struct','enum','actor','extension') ORDER BY s.start_line
            """, [path]) { ($0.string(0), $0.string(1), $0.string(2), $0.int(3)) }
        var names: [String] = []
        for (name, attributes, inherits, tests) in rows where attributes.contains("@Suite") || inherits.contains("XCTestCase") || tests > 0 {
            if !names.contains(name) { names.append(name) }
        }
        try db.forEach("""
            SELECT s.name FROM symbols s JOIN files f ON f.id = s.file_id
            WHERE f.path = ? AND s.depth = 0 AND s.kind = 'function' AND s.attributes LIKE '%@Test%' ORDER BY s.start_line
            """, [path]) { row in
            let name = row.string(0) + "()"
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    // MARK: UI literals

    /// A literal distinctive enough to link a test to a screen: it has a blank (`Unlock Atlas Premium`) or is 16
    /// characters or longer (`paywall.unlockButton`). One short word (`Done`, `Profile`, `true`) occurs in too many
    /// places to say anything, and an environment key (`ATLAS_SKIP_INTRO`) is a launch hook, not screen text.
    static func isDistinctive(_ literal: String, callee: String? = nil) -> Bool {
        if let callee, environmentCallees.contains(callee) { return false }
        if literal.allSatisfy({ ($0.isUppercase && $0.isASCII) || $0.isNumber || $0 == "_" }) { return false }
        return literal.count >= 16 || (literal.contains(" ") && literal.count >= 6)
    }

    private static let environmentCallees: Set<String> = ["environment", "launchEnvironment", "launchArguments", "env", "getenv", "setenv"]

    /// A test function: XCTest's `test…` methods and Swift Testing's `@Test` functions. Helpers that build
    /// launches or queries are not tests.
    static func isTestFunction(_ symbol: UsageSymbolInfo) -> Bool {
        symbol.kind.isCallable && (symbol.name.hasPrefix("test") || symbol.attributes?.contains("@Test") == true)
    }

    /// UI-test literals that equal (or, in a `contains` check, are part of) an app literal near a use of the
    /// target: tier 1 in a declaration with a use, tier 2 in a declaration such a declaration references (one
    /// hop, same file), tier 3 elsewhere in a file with a use. Needs the literal index; with no literals
    /// indexed there are no links.
    func uiLinks(rows: [UsageRow]) throws -> [UsageUILink] {
        let appRows = rows.filter { file($0.fileID)?.isTest == false }
        guard !appRows.isEmpty, try db.scalarInt("SELECT COUNT(*) FROM literals LIMIT 1") > 0 else { return [] }
        let enclosing = Set(appRows.compactMap(\.fromSymbolID))
        let fileIDs = Set(appRows.map(\.fileID))
        var oneHop = Set<Int64>()
        if !enclosing.isEmpty {
            try db.forEach("""
                SELECT DISTINCT target_symbol_id FROM refs WHERE from_symbol_id IN (\(Array(enclosing).sqlList)) AND confidence >= ?
                  AND target_file_id IN (\(Array(fileIDs).sqlList)) AND target_symbol_id IS NOT NULL
                """, [threshold]) { oneHop.insert($0.int64(0)) }
        }
        struct AppLiteral { let value: String; let fileID: Int64; let line: Int; let tier: Int }
        var appLiterals: [AppLiteral] = []
        try db.forEach("SELECT l.value, l.file_id, l.line, l.symbol_id, l.callee FROM literals l WHERE l.file_id IN (\(Array(fileIDs).sqlList)) ORDER BY l.file_id, l.line") { row in
            let value = row.string(0)
            guard Self.isDistinctive(value, callee: row.optionalString(4)) else { return }
            let symbol = row.optionalInt64(3)
            let tier = symbol.map(enclosing.contains) == true ? 1 : symbol.map(oneHop.contains) == true ? 2 : 3
            appLiterals.append(AppLiteral(value: value, fileID: row.int64(1), line: row.int(2), tier: tier))
        }
        guard !appLiterals.isEmpty else { return [] }
        let values = Array(Set(appLiterals.map(\.value)))

        struct TestLiteral { let value: String; let fileID: Int64; let line: Int; let symbolID: Int64?; let callee: String? }
        var testLiterals: [TestLiteral] = []
        // Equal values.
        for chunk in stride(from: 0, to: values.count, by: 400) {
            let slice = Array(values[chunk..<min(values.count, chunk + 400)])
            try db.forEach("""
                SELECT l.value, l.file_id, l.line, l.symbol_id, l.callee FROM literals l JOIN files f ON f.id = l.file_id
                WHERE f.test_kind = 'ui' AND l.value IN (\(slice.map { _ in "?" }.joined(separator: ",")))
                """, slice) { row in
                testLiterals.append(TestLiteral(value: row.string(0), fileID: row.int64(1), line: row.int(2), symbolID: row.optionalInt64(3), callee: row.optionalString(4)))
            }
        }
        // Parts of app literals, checked with `contains`.
        var contained: [(TestLiteral, String)] = []
        try db.forEach("""
            SELECT l.value, l.file_id, l.line, l.symbol_id, l.callee FROM literals l JOIN files f ON f.id = l.file_id
            WHERE f.test_kind = 'ui' AND l.callee IS NOT NULL AND lower(l.callee) LIKE '%contain%'
            """) { row in
            let literal = TestLiteral(value: row.string(0), fileID: row.int64(1), line: row.int(2), symbolID: row.optionalInt64(3), callee: row.optionalString(4))
            guard Self.isDistinctive(literal.value, callee: literal.callee) else { return }
            if let app = values.first(where: { $0 != literal.value && $0.contains(literal.value) }) { contained.append((literal, app)) }
        }
        try loadFiles(testLiterals.map(\.fileID) + contained.map(\.0.fileID) + appLiterals.map(\.fileID))
        try loadSymbols(testLiterals.compactMap(\.symbolID) + contained.compactMap(\.0.symbolID))

        var links: [UsageUILink] = []
        func add(_ literal: TestLiteral, appValue: String, match: String) {
            guard Self.isDistinctive(literal.value, callee: literal.callee),
                  let app = appLiterals.filter({ $0.value == appValue }).min(by: { ($0.tier, $0.line) < ($1.tier, $1.line) }),
                  let testFile = file(literal.fileID), let appFile = file(app.fileID),
                  let test = symbol(literal.symbolID), Self.isTestFunction(test) else { return }
            links.append(UsageUILink(testPath: testFile.path, test: displayName(test), testLine: test.lines.start,
                                     literal: literal.value, literalLine: literal.line, match: match, appPath: appFile.path, appLine: app.line, tier: app.tier))
        }
        for literal in testLiterals { add(literal, appValue: literal.value, match: "equal") }
        for (literal, app) in contained { add(literal, appValue: app, match: "contains") }
        // One link per test function and literal; the strongest first: tier, then longer (more specific) literals.
        var seen = Set<String>()
        return links.filter { seen.insert("\($0.testPath)|\($0.test)|\($0.literal)").inserted }
            .sorted { ($0.tier, -$0.literal.count, $0.testPath, $0.literalLine) < ($1.tier, -$1.literal.count, $1.testPath, $1.literalLine) }
    }

    // MARK: Hooks

    /// Environment variables that a declaration writing (or being) the target reads, and the tests that set them.
    func hooks(symbol: UsageSymbolInfo, rows: [UsageRow]) throws -> [UsageHook] {
        var writers: [Int64: UsageRow] = [:]
        for row in rows where row.isWrite {
            if let from = row.fromSymbolID, writers[from] == nil { writers[from] = row }
        }
        if symbol.kind.isCallable { writers[symbol.id] = writers[symbol.id] ?? rows.first }
        guard !writers.isEmpty else { return [] }
        let reads = try self.rows(where: "r.name LIKE 'env:%' AND r.kind = 'read' AND r.from_symbol_id IN (\(Array(writers.keys).sqlList)) ORDER BY r.line")
        var hooks: [UsageHook] = []
        var seenVariables = Set<String>()
        for read in reads {
            let variable = String(read.name.dropFirst(4))
            // One hook per variable: the first function that reads it (in line order) stands for the others.
            guard seenVariables.insert(variable).inserted else { continue }
            let sets = try self.rows(where: "r.name = ? AND r.kind = 'write' AND r.file_id IN (SELECT id FROM files WHERE is_test = 1) ORDER BY r.file_id, r.line", [read.name])
            guard !sets.isEmpty, let from = read.fromSymbolID else { continue }
            try loadFiles(sets.map(\.fileID) + [read.fileID])
            try loadSymbols(sets.compactMap(\.fromSymbolID) + [from])
            let setters = try rankedSetters(sets)
            let write = writers[from].flatMap { row -> UsageCodeLine? in
                guard let path = file(row.fileID)?.path, row.isWrite else { return nil }
                return lineText(row, path: path, maxLength: 60)
            }
            hooks.append(UsageHook(variable: variable, setters: Array(setters.prefix(2)), settersMore: max(0, setters.count - 2),
                                   reader: self.symbol(from).map { displayName($0) } ?? "(top level)", readerPath: file(read.fileID)?.path ?? "", readLine: read.line, write: write))
        }
        return hooks
    }

    /// The test files that set a variable, the one most tests go through first: a test function that sets it counts
    /// once, a helper as often as declarations call it. A base class's `launch`, called from 156 places, comes before
    /// a file whose 5 tests each pass the key themselves. A file whose lines all sit in one such helper names it.
    func rankedSetters(_ rows: [UsageRow]) throws -> [UsageLocationList] {
        let helpers = Array(Set(rows.compactMap(\.fromSymbolID).filter { id in symbol(id).map { !Self.isTestFunction($0) } == true }))
        var callers: [Int64: Int] = [:]
        if !helpers.isEmpty {
            try db.forEach("""
                SELECT target_symbol_id, COUNT(DISTINCT from_symbol_id) FROM refs
                WHERE target_symbol_id IN (\(helpers.sqlList)) AND confidence >= ? AND kind IN ('call','instantiate') AND from_symbol_id != target_symbol_id
                GROUP BY target_symbol_id
                """, [threshold]) { callers[$0.int64(0)] = $0.int(1) }
        }
        var ranked: [(setter: UsageLocationList, reach: Int)] = []
        for (fileID, fileRows) in Dictionary(grouping: rows, by: \.fileID) {
            let owners = Set(fileRows.map(\.fromSymbolID))
            let reach = owners.reduce(0) { $0 + max(1, $1.flatMap { callers[$0] } ?? 0) }
            var note: String?
            if owners.count == 1, let owner = owners.first ?? nil, let count = callers[owner], count > 1, let helper = symbol(owner) {
                note = "in \(helper.name), \(count) callers"
            }
            let setter = UsageLocationList(path: file(fileID)?.path ?? "", lines: Array(Set(fileRows.map(\.line))).sorted(), note: note)
            ranked.append((setter, reach))
        }
        return ranked.sorted { ($1.reach, $1.setter.lines.count, $0.setter.path) < ($0.reach, $0.setter.lines.count, $1.setter.path) }.map(\.setter)
    }

    // MARK: Run commands

    /// How to run the tests found: the runner script's usage lines when the repository has one, else the
    /// build system's own command with test ids that exist.
    func runCommands(for tests: UsageTests) throws -> [UsageRunCommand] {
        let testFiles = Set(tests.direct.map(\.path) + tests.compileCoupled.map(\.path) + tests.ui.map(\.testPath))
        guard !testFiles.isEmpty else { return [] }
        let uiClasses = orderedUnique(tests.ui.filter { $0.test.contains(".") }.compactMap { $0.test.split(separator: ".").first.map(String.init) }
            + (tests.direct + tests.compileCoupled).filter { $0.kind == "ui" }.flatMap(\.suites).filter { !$0.hasSuffix("()") })
        let unitSuites = orderedUnique((tests.direct + tests.compileCoupled).filter { $0.kind != "ui" }.flatMap(\.suites))
        let hasUI = !uiClasses.isEmpty
        let hasUnit = !unitSuites.isEmpty || (tests.direct + tests.compileCoupled).contains { $0.kind != "ui" }

        // A runner script's usage lines.
        let usages = try db.query("SELECT config_path, config_line, key, evidence FROM config_links WHERE kind = 'runner-usage' ORDER BY config_path, config_line") {
            (path: $0.string(0), line: $0.optionalInt(1), key: $0.optionalString(2) ?? "", description: $0.optionalString(3))
        }
        if !usages.isEmpty {
            var commands: [UsageRunCommand] = []
            func add(_ usage: (path: String, line: Int?, key: String, description: String?), command: String) {
                commands.append(UsageRunCommand(command: usage.path + (command.isEmpty ? "" : " " + command), path: usage.path, line: usage.line, description: usage.description))
            }
            let words = { (usage: (path: String, line: Int?, key: String, description: String?)) in usage.key.split(separator: " ").first.map(String.init) ?? "" }
            if let build = usages.first(where: { words($0) == "build" }) { add(build, command: "build") }
            if hasUnit, let unit = usages.first(where: { words($0) == "unit" || ($0.description ?? "").lowercased().contains("unit") }) { add(unit, command: words(unit)) }
            if hasUI, let test = usages.first(where: { $0.key.contains("--only") }) {
                let classes = Array(uiClasses.prefix(6))
                add(test, command: words(test) + classes.map { " --only " + $0 }.joined())
                // Only what the scheme's default test plan says is called skipped.
                let skipped = try skippedTests()
                let skippedHere = classes.filter { skipped.classes.contains($0) }
                if !skippedHere.isEmpty, let plan = skipped.plan {
                    commands[commands.count - 1].description = skippedHere.joined(separator: ", ") + " skipped by " + (plan as NSString).lastPathComponent
                }
            }
            if !commands.isEmpty { return commands }
        }

        // npm / vitest.
        if let script = try db.queryOne("SELECT config_path, config_line, key, evidence FROM config_links WHERE kind = 'npm-script' AND key IN ('test','test:unit') ORDER BY key LIMIT 1", [], {
            (path: $0.string(0), line: $0.optionalInt(1), key: $0.optionalString(2) ?? "test", command: $0.optionalString(3) ?? "")
        }) {
            let files = testFiles.sorted().filter { !$0.hasSuffix(".swift") }
            guard !files.isEmpty else { return [] }
            let run = script.key == "test" ? "npm test" : "npm run \(script.key)"
            return [UsageRunCommand(command: run + " -- " + files.prefix(6).joined(separator: " ") + (files.count > 6 ? " …" : ""), path: script.path, line: script.line, description: script.command)]
        }

        // SwiftPM or Xcode test targets: ids checked against the classes declared in each target's files.
        var commands: [UsageRunCommand] = []
        let targetsByFile = try testTargets(for: Array(testFiles))
        var byTarget: [String: (system: String, project: String?, suites: [String])] = [:]
        for test in tests.direct + tests.compileCoupled {
            guard let target = targetsByFile[test.path] else { continue }
            var entry = byTarget[target.name] ?? (target.system, target.project, [])
            entry.suites = orderedUnique(entry.suites + test.suites)
            byTarget[target.name] = entry
        }
        for link in tests.ui {
            guard let target = targetsByFile[link.testPath], let suite = link.test.split(separator: ".").first.map(String.init) else { continue }
            var entry = byTarget[target.name] ?? (target.system, target.project, [])
            entry.suites = orderedUnique(entry.suites + [suite])
            byTarget[target.name] = entry
        }
        let skipped = try skippedTests().classes
        for (target, entry) in byTarget.sorted(by: { $0.key < $1.key }) where !entry.suites.isEmpty {
            if entry.system == "swiftpm" {
                // `--filter` is a pattern over `Target.Suite/test` ids: a top-level test function matches by its name.
                let ids = entry.suites.prefix(6).map { "\(target).\($0.hasSuffix("()") ? String($0.dropLast(2)) : $0)" }
                commands.append(UsageRunCommand(command: "swift test --filter '" + ids.joined(separator: "|") + "'"))
            } else {
                // `-only-testing:` names classes and suites; top-level test functions run with their whole target.
                let suites = entry.suites.filter { !$0.hasSuffix("()") }
                guard !suites.isEmpty else { continue }
                let scheme = try defaultScheme() ?? target
                var command = "xcodebuild test -scheme \(scheme)" + suites.prefix(6).map { " -only-testing:\(target)/\($0)" }.joined()
                let skippedHere = suites.filter { skipped.contains($0) }
                if !skippedHere.isEmpty { command += "  (skipped by the default test plan: " + skippedHere.joined(separator: ", ") + ")" }
                commands.append(UsageRunCommand(command: command))
            }
        }
        return commands
    }

    private func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// The test target each test file belongs to.
    private func testTargets(for paths: [String]) throws -> [String: (name: String, system: String, project: String?)] {
        var result: [String: (name: String, system: String, project: String?)] = [:]
        for path in paths {
            if let target = try db.queryOne("""
                SELECT t.name, t.system, t.project_path FROM file_targets ft JOIN targets t ON t.id = ft.target_id JOIN files f ON f.id = ft.file_id
                WHERE f.path = ? AND t.is_test = 1 ORDER BY t.id LIMIT 1
                """, [path], { ($0.string(0), $0.string(1), $0.optionalString(2)) }) {
                result[path] = target
            }
        }
        return result
    }

    /// The scheme whose default test plan is recorded (`Atlas` for `…/xcschemes/Atlas.xcscheme`).
    private func defaultScheme() throws -> String? {
        try db.queryOne("SELECT config_path FROM config_links WHERE kind = 'scheme-testplan' AND evidence = 'default' ORDER BY config_path LIMIT 1") { row in
            ((row.string(0) as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }

    /// Classes the default test plan of the default scheme skips, and that plan.
    private func skippedTests() throws -> (classes: Set<String>, plan: String?) {
        guard let plan = try db.queryOne("SELECT key FROM config_links WHERE kind = 'scheme-testplan' AND evidence = 'default' ORDER BY config_path LIMIT 1", [], { $0.optionalString(0) }) ?? nil else { return ([], nil) }
        var skipped = Set<String>()
        try db.forEach("SELECT evidence FROM config_links WHERE kind = 'testplan-target' AND config_path = ?", [plan]) { row in
            for part in (row.optionalString(0) ?? "").components(separatedBy: "; ") where part.hasPrefix("skipped: ") {
                for name in part.dropFirst("skipped: ".count).split(separator: ",") {
                    skipped.insert(name.trimmingCharacters(in: .whitespaces).split(separator: "/").first.map(String.init) ?? "")
                }
            }
        }
        return (skipped, plan)
    }
}
