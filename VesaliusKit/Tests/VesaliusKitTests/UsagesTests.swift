import Foundation
@testable import QueryEngine
import RepositoryIndex
import Testing
import VesaliusCore
import VesaliusMCP
@testable import VesaliusRender

/// `usages`: each view on a fixture repository indexed by the real pipeline, the change sections,
/// and the renderer's budget. Typed receivers, rejected lookalikes, UI literals, environment keys and runner
/// usage lines all come from the pipeline; only test classification is written into a fixture's index, because
/// the fixtures have no Xcode project to take it from. The end-to-end proof is the golden check on the
/// benchmark repositories; the CLI test here drives the built binary.
@Suite("Usages: views, change sections and rendering", .serialized)
struct UsagesTests {
    // MARK: Fixtures

    static let app: [String: String] = [
        "Sources/App/Planner.swift": """
            import Foundation

            /// Plans books from files.
            final class Planner {
                var lastImport = ""

                func importBook(from url: URL) -> String {
                    // importBook is the entry point
                    lastImport = url.path
                    return url.path
                }
            }
            """,
        "Sources/App/Wizard.swift": """
            import Foundation

            /// The step-by-step wizard.
            final class Wizard {
                let planner = Planner()

                func start(single: Bool) {
                    if single {
                        let result = planner.importBook(
                            from: URL(fileURLWithPath: "/tmp"))
                        print(result, planner.lastImport)
                    }
                }

                func restart() {
                    start(single: true)
                }
            }
            """,
        "Sources/App/DebugAutorun.swift": """
            #if DEBUG
            import Foundation

            enum DebugAutorun {
                static func run() {
                    _ = Planner().importBook(from: URL(fileURLWithPath: "/dev"))
                }
            }
            #endif
            """,
        "Sources/App/Settings.swift": """
            final class Settings {
                func save() {}
            }
            """,
        "Sources/Kit/Settings.swift": """
            struct Settings {}
            """,
        "docs/notes.md": "Call `importBook` to import a book.\n",
    ]

    static let web: [String: String] = [
        "tsconfig.json": """
            { "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["src/*"] } } }
            """,
        "package.json": """
            {
              "name": "web",
              "scripts": {
                "test": "vitest run"
              },
              "devDependencies": { "vitest": "^1.0.0" }
            }
            """,
        "vitest.config.ts": """
            import { defineConfig } from "vitest/config";
            export default defineConfig({ test: { include: ["tests/**/*.test.ts"] } });
            """,
        "src/lib/crypto.ts": """
            export function encrypt(text: string): string {
              return text.split("").reverse().join("");
            }

            export function decrypt(text: string): string {
              return encrypt(text);
            }
            """,
        "src/app/api/notes/route.ts": """
            import { encrypt } from "@/lib/crypto";

            export async function POST(req: Request) {
              const body = await req.text();
              const sealed = encrypt(body);
              return new Response(sealed);
            }
            """,
        "src/lib/client.ts": """
            import { decrypt } from "./crypto";

            function readKey(raw: string): string {
              return decrypt(raw);
            }

            export function token(raw: string): string {
              const key = readKey(raw);
              return key.toUpperCase();
            }
            """,
        "tests/crypto.test.ts": """
            import { describe, it, expect } from "vitest";
            import { encrypt, decrypt } from "../src/lib/crypto";

            describe("crypto", () => {
              it("round-trips", () => {
                expect(decrypt(encrypt("a"))).toBe("a");
              });
            });
            """,
        "tests/client.test.ts": """
            import { vi, it, expect } from "vitest";
            vi.mock("../src/lib/crypto", () => ({ decrypt: () => "k" }));
            import { token } from "../src/lib/client";

            it("uppercases", () => {
              expect(token("x")).toBe("K");
            });
            """,
    ]

    /// The result for `target`, computed afresh (memo cleared).
    private func usages(_ engine: RepositoryEngine, _ target: String, change: UsageChange? = nil) throws -> UsagesResult {
        engine.invalidateCaches()
        return try engine.usages(target, change: change)
    }

    private func text(_ result: UsagesResult, tokens: Int = 1_500) -> String {
        UsagesRenderer.render(result, budget: Budget(tokens: tokens))
    }

    // MARK: Callers

    @Test("Callers: grouped by file and caller, the statement with its condition, one hop up, #if labels, complete")
    func callers() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "usages-callers")
        let result = try usages(engine, "Planner.importBook")
        #expect(result.view == .callers)
        #expect(result.totals.count == 2 && result.totals.files == 2)
        #expect(result.completeness?.isComplete == true)

        let wizard = try #require(result.files.first { $0.path == "Sources/App/Wizard.swift" })
        let start = try #require(wizard.groups.first)
        #expect(start.declaration == "func Wizard.start(single:)")
        #expect(start.lines == LineRange(7, 13))
        #expect(start.doc == "The step-by-step wizard." && start.isTypeDoc)
        let site = try #require(start.sites.first)
        #expect(site.isPrimary && site.line == 9)
        #expect(site.condition == UsageCodeLine(line: 8, text: "if single {"))
        #expect(site.code.map(\.text).joined(separator: " ") == "let result = planner.importBook(from: URL(fileURLWithPath: \"/tmp\"))")
        #expect(start.calledBy.map(\.name) == ["restart()"] && start.calledBy.first?.line == 16)

        let autorun = try #require(result.files.first { $0.path == "Sources/App/DebugAutorun.swift" })
        #expect(autorun.labels == ["#if DEBUG"])
        // Production files without a condition come first.
        #expect(result.files.map(\.path) == ["Sources/App/Wizard.swift", "Sources/App/DebugAutorun.swift"])

        let lines = text(result).components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("func Planner.importBook(from:) -> String  Sources/App/Planner.swift:7-11 · method"))
        #expect(lines[1].hasPrefix("2 callers in 2 files (app 2, test 0) · complete: \"importBook\" occurs"))
        #expect(lines.contains("    8 │ if single {"))
        #expect(lines.contains("Sources/App/DebugAutorun.swift  [#if DEBUG]"))
        #expect(lines.contains { $0.contains("called by: restart() :16") })
    }

    @Test("Same-name declarations are choices with exact targets; nothing is merged; one of them excludes the other")
    func choices() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "usages-choices")
        let result = try usages(engine, "Settings")
        #expect(result.view == .choices)
        #expect(Set(result.choices.map(\.target)) == ["Sources/App/Settings.swift#Settings", "Sources/Kit/Settings.swift#Settings"])
        let rendered = text(result)
        #expect(rendered.contains("usages(target:\"Sources/App/Settings.swift#Settings\")"))
        #expect(rendered.contains("usages(target:\"Sources/Kit/Settings.swift#Settings\")"))
        #expect(rendered.contains("nothing merged"))

        let one = try usages(engine, "Sources/App/Settings.swift#Settings")
        #expect(one.view == .type)
        let also = try #require(one.footers.first { $0.kind == .alsoNamed })
        #expect(also.items.first?.hasPrefix("Sources/Kit/Settings.swift#Settings (struct") == true)
        #expect(text(one).contains("also named: Sources/Kit/Settings.swift#Settings"))
    }

    @Test("A miss suggests targets in the accepted syntax")
    func miss() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "usages-miss")
        do {
            _ = try usages(engine, "Planer.importBook")
            Issue.record("an unknown type is a miss")
        } catch EngineError.notFound(_, let suggestions) {
            #expect(suggestions.contains("Planner.importBook"))
        }
    }

    // MARK: Property and type

    @Test("Property: owner users with their via line, writes and reads, the declaring file on one line")
    func property() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "usages-property")
        let result = try usages(engine, "Planner.lastImport")
        #expect(result.view == .property)
        #expect(result.header.title.hasPrefix("Planner.lastImport  var lastImport = \"\""))
        let declaring = try #require(result.declaringFile)
        #expect(declaring.writes.map(\.line) == [9])
        #expect(declaring.writes.first?.name == "importBook(from:)")
        let wizard = try #require(result.files.first { $0.path == "Sources/App/Wizard.swift" })
        #expect(wizard.via == UsageCodeLine(line: 5, text: "let planner = Planner()"))
        #expect(wizard.labels.contains("reads"))
        #expect(wizard.groups.flatMap(\.sites).map(\.line) == [11])
        #expect(result.notes.first?.hasPrefix("Planner is used by") == true)
        #expect(result.totals.extra.first == "1 write, 1 read")

        let rendered = text(result)
        #expect(rendered.contains("Sources/App/Wizard.swift  via 5 │ let planner = Planner()  [reads]"))
        #expect(rendered.contains("declaring file  writes ·9 importBook(from:)"))
    }

    @Test("Type: users per file with the line that gives them the type, members used, same-name types excluded")
    func type() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "usages-type")
        let result = try usages(engine, "Planner")
        #expect(result.view == .type)
        let wizard = try #require(result.files.first { $0.path == "Sources/App/Wizard.swift" })
        #expect(wizard.via == UsageCodeLine(line: 5, text: "let planner = Planner()"))
        let members = wizard.owners.flatMap(\.members)
        #expect(members.contains { $0.name == "importBook(from:)" && $0.lines == [9] })
        #expect(members.contains { $0.name == "lastImport" && $0.lines == [11] })
        let autorun = try #require(result.files.first { $0.path == "Sources/App/DebugAutorun.swift" })
        #expect(autorun.via?.line == 6)
        #expect(result.footers.first { $0.kind == .alsoNamed } == nil)
    }

    // MARK: File views

    @Test("Swift file: dependents by owner and member; rejected lookalikes and type flow from the linker's rows")
    func swiftFile() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/Core/Record.swift": """
                struct Record {
                    var length = 0
                    static let headerSize = 48
                }

                func makeRecord() -> Record { Record() }
                """,
            "Sources/Core/Loader.swift": """
                func loadRecord() -> Record { makeRecord() }
                """,
            "Sources/Core/Reader.swift": """
                struct Reader {
                    func size() -> Int {
                        Record.headerSize + loadRecord().length
                    }
                }
                """,
            "Sources/Core/Stream.swift": """
                struct Stream {
                    func total() -> Int {
                        let record = loadRecord()
                        return record.length
                    }
                }
                """,
            "Sources/GPU/Buffer.swift": """
                import Metal

                struct Buffer {
                    func check(buffer: MTLBuffer) -> Bool {
                        buffer.length > 0
                    }
                }
                """,
        ], name: "usages-swift-file")
        let result = try usages(engine, "Sources/Core/Record.swift")
        #expect(result.view == .file)
        #expect(result.header.declares.map(\.name) == ["Record", "makeRecord"])
        let reader = try #require(result.files.first { $0.path == "Sources/Core/Reader.swift" })
        #expect(reader.owners.map(\.owner).contains("Record"))
        #expect(reader.owners.flatMap(\.members).contains { $0.name == "headerSize" && $0.lines == [3] })
        // A top-level function of the file is called, not used as a type.
        let loader = try #require(result.files.first { $0.path == "Sources/Core/Loader.swift" })
        #expect(loader.owners.first { $0.owner == "makeRecord" }?.members.map(\.name) == ["call"])

        // The linker types `buffer` as Metal's MTLBuffer: an external use that a unique-name guess would have
        // bound to `Record.length`, so it is a rejected lookalike, not a dependent.
        #expect(!result.files.contains { $0.path == "Sources/GPU/Buffer.swift" })
        let lookalikes = try #require(result.footers.first { $0.kind == .rejectedLookalikes })
        #expect(lookalikes.items == ["Buffer.swift:5 buffer.length (MTLBuffer)"])
        // `record.length` in Stream is typed through the producer `loadRecord()`; Stream never names Record.
        let stream = try #require(result.files.first { $0.path == "Sources/Core/Stream.swift" })
        #expect(stream.labels.contains("type-inferred via loadRecord: Record"))
        let rendered = text(result)
        #expect(rendered.contains("rejected lookalikes: Buffer.swift:5 buffer.length (MTLBuffer)"))
        #expect(rendered.contains("Sources/Core/Stream.swift  [type-inferred via loadRecord: Record]"))
    }

    @Test("TypeScript file: import lines and names, routes, consumers, a helper's in-file callers, mocks apart")
    func typeScriptFile() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.web, name: "usages-ts-file")
        let result = try usages(engine, "src/lib/crypto.ts")
        #expect(result.view == .file)
        #expect(result.totals.noun == "importer")
        #expect(result.completeness?.isComplete == true, "\(result.completeness?.summary ?? "")")

        let route = try #require(result.files.first { $0.path == "src/app/api/notes/route.ts" })
        #expect(route.importLine == 1 && route.importedNames == ["encrypt"])
        let handler = try #require(route.groups.first)
        #expect(handler.route == "POST /api/notes")
        let sealed = try #require(handler.sites.first)
        #expect(sealed.code.first == UsageCodeLine(line: 5, text: "const sealed = encrypt(body);"))
        #expect(sealed.consumer == UsageCodeLine(line: 6, text: "return new Response(sealed);"))

        let client = try #require(result.files.first { $0.path == "src/lib/client.ts" })
        #expect(client.groups.first?.inFileCallers.map(\.name) == ["token"])
        #expect(client.groups.first?.inFileCallers.first?.line == 8)

        let mock = try #require(result.footers.first { $0.kind == .mockOnly })
        #expect(mock.items == ["tests/client.test.ts:2"])
        #expect(result.files.first { $0.path == "tests/crypto.test.ts" }?.isTest == true)

        let rendered = text(result)
        #expect(rendered.contains("src/app/api/notes/route.ts:1 imports {encrypt}"))
        #expect(rendered.contains("    5 │ const sealed = encrypt(body);  → :6 return new Response(sealed);"))
        #expect(rendered.contains("mock only (vi.mock): tests/client.test.ts:2"))
        #expect(rendered.split(separator: "\n")[1].hasPrefix("imported by 3 files (2 source, 1 test); 1 more only mock it · complete:"))
    }

    // MARK: Change sections

    @Test("Rename: text mentions, dynamic forms, compile-coupled tests with suites, UI links, hooks and run lines")
    func rename() async throws {
        var files = Self.app
        files["Sources/App/Planner.swift"] = """
            import Foundation

            /// Plans books from files.
            final class Planner {
                var lastImport = ""
                var status = ""

                func importBook(from url: URL) -> String {
                    if ProcessInfo.processInfo.environment["SKIP_SETUP"] == "1" {
                        lastImport = url.path
                        status = "Imported book"
                    }
                    return url.path
                }
            }
            """
        files["Tests/AppTests/PlannerTests.swift"] = """
            import Testing
            @testable import App

            @Suite struct PlannerSuite {
                @Test func makesAPlanner() {
                    _ = Planner()
                }
            }
            """
        files["UITests/WizardUITests.swift"] = """
            import XCTest

            final class WizardUITests: XCTestCase {
                func testImportShowsThePath() {
                    let app = XCUIApplication()
                    app.launchEnvironment["SKIP_SETUP"] = "1"
                    XCTAssertTrue(app.staticTexts["Imported book"].exists)
                }
            }
            """
        // A base class whose launch helper sets the variable for the tests that call it.
        files["UITests/AppTestCase.swift"] = """
            import XCTest

            class AppTestCase: XCTestCase {
                func launch(skipSetup: Bool) -> XCUIApplication {
                    let app = XCUIApplication()
                    if skipSetup { app.launchEnvironment["SKIP_SETUP"] = "1" }
                    app.launch()
                    return app
                }
            }
            """
        files["UITests/SetupUITests.swift"] = """
            import XCTest

            final class SetupUITests: AppTestCase {
                func testOne() { _ = launch(skipSetup: true) }
                func testTwo() { _ = launch(skipSetup: true) }
                func testThree() { _ = launch(skipSetup: false) }
            }
            """
        files["scripts/run.sh"] = """
            #!/bin/bash
            # Runs the app's tests.
            #
            #   scripts/run.sh build                build for testing
            #   scripts/run.sh test [--only Class]  run UI tests
            #   scripts/run.sh unit                 the unit suite
            echo "$@"
            """
        let (engine, _) = try await RepoFixture.indexed(files, name: "usages-rename")
        // Test classification comes from the build targets, which the fixture has none of; written here directly.
        // Literals and environment keys and the runner's usage lines come from the pipeline.
        let db = try engine.db
        try db.run("UPDATE files SET is_test = 1, test_kind = 'unit' WHERE path LIKE 'Tests/%'")
        try db.run("UPDATE files SET is_test = 1, test_kind = 'ui' WHERE path LIKE 'UITests/%'")

        let result = try usages(engine, "Planner.lastImport", change: .rename)
        let sections = try #require(result.sections)
        #expect(sections.dynamicChecked == ["$lastImport", "\\.lastImport", "\"lastImport\""])
        let coupled = try #require(sections.tests.compileCoupled.first)
        #expect(coupled.path == "Tests/AppTests/PlannerTests.swift" && coupled.suites == ["PlannerSuite"])
        let link = try #require(sections.tests.ui.first)
        #expect(link.testPath == "UITests/WizardUITests.swift" && link.literal == "Imported book" && link.literalLine == 7)
        #expect(link.appPath == "Sources/App/Planner.swift" && link.appLine == 11 && link.tier == 1)
        #expect(link.test == "WizardUITests.testImportShowsThePath()")
        let hook = try #require(sections.tests.hooks.first)
        #expect(hook.variable == "SKIP_SETUP" && hook.readLine == 9)
        #expect(hook.write?.text == "lastImport = url.path")
        // The helper three tests call comes before the one test that sets the variable itself.
        #expect(hook.setters.map(\.path) == ["UITests/AppTestCase.swift", "UITests/WizardUITests.swift"])
        #expect(hook.setters.first?.lines == [6] && hook.setters.first?.note == "in launch, 3 callers")
        #expect(hook.setters.last?.note == nil)
        #expect(sections.tests.run.map(\.command) == ["scripts/run.sh build", "scripts/run.sh unit", "scripts/run.sh test --only WizardUITests"])
        // A rename keeps behaviour: no entry points.
        #expect(sections.entryPoints.isEmpty)

        let rendered = text(result)
        #expect(rendered.hasPrefix("RENAME Planner.lastImport"))
        #expect(rendered.contains("Tests/AppTests/PlannerTests.swift  [test] uses Planner; not lastImport"))
        #expect(rendered.contains("  unit  Tests/AppTests/PlannerTests.swift: PlannerSuite (compile-coupled"))
        #expect(rendered.contains("  UI    UITests/WizardUITests.swift:4 testImportShowsThePath() ← \"Imported book\" :7 = Sources/App/Planner.swift:11"))
        #expect(rendered.contains("  hook  SKIP_SETUP set in UITests/AppTestCase.swift:6 (in launch, 3 callers), UITests/WizardUITests.swift:6 → read in Sources/App/Planner.swift:9 importBook(from:), which sets lastImport = url.path :10"))
        #expect(rendered.contains("  run   scripts/run.sh:4 build · scripts/run.sh:6 unit · scripts/run.sh:5 test --only WizardUITests"))
        #expect(!rendered.contains("skipped"))
    }

    @Test("Signature change of a method: entry points through callers; other overloads are not affected")
    func signature() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "usages-signature")
        let result = try usages(engine, "Planner.importBook", change: .signature)
        let sections = try #require(result.sections)
        // restart() calls start(single:), which calls the target; nothing calls restart() or DebugAutorun.run().
        #expect(sections.entryPoints.contains { $0.root == "Wizard.restart()" && $0.via == ["Wizard.start(single:)"] })
        #expect(sections.entryPoints.contains { $0.root == "DebugAutorun.run()" })
        #expect(text(result).contains("ENTRY POINTS  "))

        var files = Self.app
        files["Sources/App/Planner.swift"] = """
            import Foundation

            /// Plans books from files.
            final class Planner {
                var lastImport = ""

                func importBook(from url: URL) -> String {
                    lastImport = url.path
                    return url.path
                }

                func importBook(folder: URL) -> String {
                    folder.path
                }
            }
            """
        let (overloaded, _) = try await RepoFixture.indexed(files, name: "usages-overloads")
        let one = try usages(overloaded, "Planner.importBook(from:)", change: .signature)
        #expect(one.sections?.notAffected == ["importBook(folder:) :12"])
        #expect(text(one).contains("NOT AFFECTED  importBook(folder:) :12"))
    }

    @Test("A SwiftPM package's tests: top-level @Test functions run by name, beside the suites")
    func swiftPMTests() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Package.swift": """
                // swift-tools-version: 6.0
                import PackageDescription

                let package = Package(
                    name: "App",
                    targets: [
                        .target(name: "App"),
                        .testTarget(name: "AppTests", dependencies: ["App"]),
                    ]
                )
                """,
            "Sources/App/Planner.swift": """
                public final class Planner {
                    public init() {}

                    public func importBook(from path: String) -> String {
                        path.uppercased()
                    }
                }
                """,
            "Tests/AppTests/PlannerTests.swift": """
                import Testing
                @testable import App

                @Test func plannerImportsAPath() {
                    #expect(Planner().importBook(from: "a") == "A")
                }

                @Suite struct PlannerSuite {
                    @Test func makesOne() {
                        _ = Planner()
                    }
                }
                """,
        ], name: "usages-swiftpm-tests")
        // Test classification and the test target come from the package manifest.
        let result = try usages(engine, "Planner.importBook", change: .signature)
        let tests = try #require(result.sections?.tests)
        let direct = try #require(tests.direct.first)
        #expect(direct.path == "Tests/AppTests/PlannerTests.swift" && direct.suites == ["PlannerSuite", "plannerImportsAPath()"])
        #expect(tests.run.map(\.command) == ["swift test --filter 'AppTests.PlannerSuite|AppTests.plannerImportsAPath'"])
        #expect(text(result).contains("  unit  Tests/AppTests/PlannerTests.swift: PlannerSuite, plannerImportsAPath() (uses it: 5)"))
    }

    @Test("UI links need a distinctive literal: a phrase or 16+ characters, never an environment key")
    func distinctiveLiterals() {
        #expect(UsageBuilder.isDistinctive("Unlock Atlas Premium"))
        #expect(UsageBuilder.isDistinctive("Your premium plan is active."))
        #expect(UsageBuilder.isDistinctive("paywall.unlockButton"))
        #expect(!UsageBuilder.isDistinctive("Profile"))
        #expect(!UsageBuilder.isDistinctive("true"))
        #expect(!UsageBuilder.isDistinctive("ATLAS_SKIP_INTRO"))
        #expect(!UsageBuilder.isDistinctive("verbose logging", callee: "launchEnvironment"))
    }

    @Test("A use deep in a modifier chain is quoted from its own line, not from the chain's head")
    func modifierChain() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/Membership.swift": """
                final class Membership {
                    var isActive = false
                }
                """,
            "Sources/App/Badge.swift": """
                import SwiftUI

                struct Badge {
                    let membership = Membership()

                    func label() -> some View {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(membership.isActive ? Color.green : Color.gray)
                    }

                    var title: String { "Member" }
                }
                """,
        ], name: "usages-chain")
        let result = try usages(engine, "Membership.isActive")
        let site = try #require(result.files.flatMap(\.groups).flatMap(\.sites).first { $0.line == 9 })
        #expect(site.code == [UsageCodeLine(line: 9, text: ".foregroundStyle(membership.isActive ? Color.green : Color.gray)")])
        #expect(!text(result).contains("7 │"))
    }

    // MARK: Rendering

    @Test("UI links print one line per test file with its strongest link; a skipped class gets its own line")
    func uiLines() {
        var tests = UsageTests()
        tests.ui = [
            UsageUILink(testPath: "UITests/ProfileTests.swift", test: "ProfileTests.testRestore()", testLine: 20, literal: "Your premium plan is active.", literalLine: 31,
                        match: "equal", appPath: "App/Profile.swift", appLine: 515, tier: 1),
            UsageUILink(testPath: "UITests/ProfileTests.swift", test: "ProfileTests.testRows()", testLine: 40, literal: "Manage plan", literalLine: 44,
                        match: "equal", appPath: "App/Profile.swift", appLine: 488, tier: 3),
            UsageUILink(testPath: "UITests/DraftTests.swift", test: "DraftTests.testRetry()", testLine: 8, literal: "Try Again Later", literalLine: 9,
                        match: "contains", appPath: "App/Paywall.swift", appLine: 276, tier: 3),
        ]
        tests.run = [UsageRunCommand(command: "scripts/e2e.sh test --only ProfileTests --only DraftTests", path: "scripts/e2e.sh", line: 5, description: "DraftTests skipped by App.xctestplan")]
        let lines = UsagesRenderer.testLines(tests, targetName: "isActive")
        #expect(lines.contains("  UI    UITests/ProfileTests.swift:20 testRestore() ← \"Your premium plan is active.\" :31 = App/Profile.swift:515 (+1 more test)"))
        #expect(lines.contains("  UI    UITests/DraftTests.swift:8 testRetry() ← \"Try Again Later\" :9 ⊂ App/Paywall.swift:276"))
        #expect(lines.contains("  run   scripts/e2e.sh:5 test --only ProfileTests --only DraftTests"))
        #expect(lines.last == "  note  DraftTests skipped by App.xctestplan")
    }

    @Test("Tight member lines print overloads that share a base name once, with all their lines")
    func tightOverloads() {
        let owner = UsageOwnerUses(owner: "Scheduler", members: [
            UsageMemberUse(name: "suggestedDays(for:first:)", lines: [72], kinds: ["call"], enclosing: ["Sheet.init"]),
            UsageMemberUse(name: "orderedDays(first:)", lines: [190], kinds: ["call"], enclosing: ["Sheet.row"]),
            UsageMemberUse(name: "suggestedDays(count:)", lines: [247], kinds: ["call"], enclosing: ["Sheet.reset"]),
        ])
        #expect(UsagesRenderer.ownerLines(owner, showOwner: true, detail: .tight)
            == ["Scheduler  suggestedDays 72,247 · orderedDays 190  in Sheet.init, Sheet.reset, Sheet.row"])
        // With room to spare each overload keeps its selector and lines.
        let full = UsagesRenderer.ownerLines(owner, showOwner: true, detail: .full).joined(separator: "\n")
        #expect(full.contains("suggestedDays(for:first:) 72 (Sheet.init)") && full.contains("suggestedDays(count:) 247 (Sheet.reset)"))
    }

    @Test("Over budget: test files go to one line first, the head and completeness stay, pages say what is next")
    func budget() {
        func file(_ index: Int, test: Bool) -> UsageFile {
            UsageFile(path: "Sources/Feature\(index)/File\(index).swift", isTest: test, testKind: test ? "unit" : nil, labels: test ? ["test"] : [],
                      groups: [UsageGroup(declaration: "func Feature\(index).run()", lines: LineRange(10, 40), sites: (0..<6).map { site in
                          UsageSite(line: 12 + site, kind: "call", isPrimary: site == 0, code: [UsageCodeLine(line: 12 + site, text: "let value\(site) = service.importBook(from: url\(site), preferences: nil, modelContext: context)")])
                      })])
        }
        let result = UsagesResult(
            view: .callers, target: "Service.importBook",
            header: UsageHeader(title: "func Service.importBook(from:)", path: "Sources/Service.swift", lines: LineRange(1, 9), kind: "method of Service"),
            totals: UsageTotals(noun: "caller", count: 40, files: 40, split: [UsageCount("app", 20), UsageCount("test", 20)]),
            completeness: UsageCompleteness(isComplete: true, summary: "complete: \"importBook\" occurs 241×; 0 unresolved"),
            files: (0..<20).map { file($0, test: false) } + (20..<40).map { file($0, test: true) })

        let generous = UsagesRenderer.render(result, budget: Budget(tokens: 4_000))
        #expect(TokenEstimate.of(generous) <= 4_000)
        // Test files are one line each; production files keep their statements.
        #expect(generous.contains("Sources/Feature25/File25.swift  [test] 12-17"))
        #expect(generous.contains("    12 │ let value0 = service.importBook"))

        let page1 = UsagesRenderer.render(result, budget: Budget(tokens: 1_000))
        #expect(TokenEstimate.of(page1) <= 1_000)
        let lines = page1.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("func Service.importBook(from:)  Sources/Service.swift:1-9"))
        #expect(lines[1] == "40 callers in 40 files (app 20, test 20) · complete: \"importBook\" occurs 241×; 0 unresolved")
        #expect(lines.last?.hasPrefix("showing 1-") == true || lines.last?.hasPrefix("showing ") == true)
        #expect(page1.contains("more: usages(target:\"Service.importBook\", page:2)"))
        let page2 = UsagesRenderer.render(result, budget: Budget(tokens: 1_000, page: 2))
        #expect(page2.components(separatedBy: "\n")[1] == lines[1])
    }

    // MARK: End to end

    @Test("A quoted file edited since indexing is re-indexed once, and the result says so")
    func staleReindex() async throws {
        let (engine, root) = try await RepoFixture.indexed(Self.app, name: "usages-stale")
        let context = ToolContext(engine: engine) {
            let summary = try await engine.index(options: RepoFixture.fastOptions)
            return summary.filesAdded + summary.filesChanged + summary.filesRemoved
        }
        let before = await MCPToolCatalog.execute(UsagesTool(), arguments: ["target": .string("Planner.importBook")], context: context)
        #expect(before.text.contains("9 │ let result = planner.importBook"))
        #expect(!before.text.hasPrefix("re-indexed"))

        try RepoFixture.write("// moved down a line\n" + (Self.app["Sources/App/Wizard.swift"] ?? ""), to: "Sources/App/Wizard.swift", in: root)
        let after = await MCPToolCatalog.execute(UsagesTool(), arguments: ["target": .string("Planner.importBook")], context: context)
        #expect(after.text.hasPrefix("re-indexed 1 file\n"), "\(after.text)")
        #expect(after.text.contains("10 │ let result = planner.importBook"))
        #expect(after.staleFiles.isEmpty)
    }

    @Test("`vesalius usages` prints the callers view from the real binary, and a change plan")
    func cli() throws {
        let root = try RepoFixture.make(Self.app, name: "usages-cli")
        let index = try CLI.run(["index", root.path, "--no-embeddings", "--no-history", "-q"])
        #expect(index.status == 0, "\(index.stderr)")
        let callers = try CLI.run(["usages", "Planner.importBook", "--repo", root.path, "--no-refresh"])
        #expect(callers.status == 0, "\(callers.stderr)")
        #expect(callers.stdout.contains("2 callers in 2 files"))
        #expect(callers.stdout.contains("9 │ let result = planner.importBook(from: URL(fileURLWithPath: \"/tmp\"))"))
        #expect(callers.stdout.contains("complete: \"importBook\""))

        let json = try CLI.run(["usages", "Planner.importBook", "--repo", root.path, "--no-refresh", "--json"])
        let decoded = try VesaliusJSON.decoder().decode(UsagesResult.self, from: json.data)
        #expect(decoded.view == .callers && decoded.totals.count == 2)

        let rename = try CLI.run(["usages", "Planner.lastImport", "--change", "rename", "--repo", root.path, "--no-refresh"])
        #expect(rename.stdout.hasPrefix("RENAME Planner.lastImport"))
        #expect(rename.stdout.contains("TEXT ONLY"))

        let choices = try CLI.run(["usages", "Settings", "--repo", root.path, "--no-refresh"])
        #expect(choices.status == 0)
        #expect(choices.stdout.contains("Sources/Kit/Settings.swift#Settings"))
    }
}
