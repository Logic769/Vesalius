import Foundation
@testable import QueryEngine
import Testing
import VesaliusCore
import VesaliusMCP
@testable import VesaliusRender

/// Targets that name Swift extensions (`path#Name`, `path:line`): `usages` lists the uses of what they add,
/// `outline` their members, `vesalius debug target` what was resolved. The fixture is indexed by the real pipeline
/// and the CLI test drives the built binary; the end-to-end proof is the MCP run on the benchmark repositories.
@Suite("Extension targets", .serialized)
struct ExtensionTargetTests {
    static let app: [String: String] = [
        "Sources/App/Planner.swift": """
            import Foundation

            final class Planner {
                var name = "book"

                func plan() -> String { name }
            }

            extension Planner {
                func replan() -> String {
                    plan() + "!"
                }
            }
            """,
        "Sources/App/Planner+Export.swift": """
            import Foundation

            extension Planner: CustomStringConvertible {
                var description: String { name }
            }

            extension Planner {
                /// Writes the plan to `url`.
                func export(to url: URL) -> Bool {
                    !replan().isEmpty && !exportName.isEmpty
                }

                var exportName: String { name + ".json" }
            }

            extension String {
                func shouted() -> String {
                    uppercased() + "!"
                }
            }
            """,
        "Sources/App/Planner+Sendable.swift": """
            extension Planner: @unchecked Sendable {}
            """,
        "Sources/App/Wizard.swift": """
            import Foundation

            final class Wizard {
                let planner = Planner()

                func run() -> Bool {
                    let title = planner.exportName.shouted()
                    print(title)
                    return planner.export(to: URL(fileURLWithPath: "/tmp"))
                }
            }
            """,
        "Sources/App/Formatting.swift": """
            extension String {
                var titled: String { capitalized }
            }
            """,
        "Sources/Kit/Formatting.swift": """
            extension String {
                var trimmedLine: String { self }
            }
            """,
        "Tests/AppTests/PlannerTests.swift": """
            import Foundation
            import Testing
            @testable import App

            @Test func exports() {
                #expect(Planner().export(to: URL(fileURLWithPath: "/tmp")))
            }

            @Test func doubles() {
                #expect(2.doubled() == 4)
                #expect(3.doubled() == 6)
            }

            private extension Int {
                func doubled() -> Int { self * 2 }
            }
            """,
    ]

    /// The result for `target`, computed afresh (memo cleared).
    private func usages(_ engine: RepositoryEngine, _ target: String) throws -> UsagesResult {
        engine.invalidateCaches()
        return try engine.usages(target)
    }

    private func members(_ result: UsagesResult) -> [String: [Int]] {
        var lines: [String: [Int]] = [:]
        for member in result.files.flatMap(\.owners).flatMap(\.members) { lines[member.name, default: []] += member.lines }
        return lines
    }

    // MARK: usages

    @Test("path#Name: every extension of the type in that file, the uses of their members, never the type's own")
    func fileExtensions() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "extension-file")
        let result = try usages(engine, "Sources/App/Planner+Export.swift#Planner")
        #expect(result.view == .type)
        #expect(result.target == "Sources/App/Planner+Export.swift#Planner")
        #expect(result.header.title == "extension Planner: CustomStringConvertible")
        #expect(result.header.kind == "2 extensions: :3-5, :7-14")
        #expect(result.notes.first == "adds conformance to CustomStringConvertible and 3 members: description :4 · export(to:) :9 · exportName :13")
        // The String extension in the same file is another target; `replan()` belongs to Planner.swift's extension.
        #expect(members(result) == ["exportName": [7], "export(to:)": [9, 6]])
        #expect(result.files.map(\.path) == ["Sources/App/Wizard.swift", "Tests/AppTests/PlannerTests.swift"])
        #expect(result.totals.count == 3 && result.totals.files == 2)
        // `exportName` read inside `export(to:)` is counted apart, and reconciled.
        #expect(result.totals.extra == ["1 more use inside the extensions"])
        #expect(result.completeness?.summary == "complete: description, export, exportName occur 7×: 4 resolved to the target, 3 declarations; 0 unresolved")
        let also = try #require(result.footers.first { $0.kind == .alsoNamed })
        #expect(also.items == [
            "Planner (class, 6 uses in 5 files, excluded)",
            "Sources/App/Planner+Sendable.swift#Planner (extension, 0 uses in 0 files, excluded)",
            "Sources/App/Planner.swift:9 (extension, 1 use in 1 file, excluded)",
        ])

        let lines = UsagesRenderer.render(result, budget: Budget(tokens: 1_500)).components(separatedBy: "\n")
        #expect(lines[0] == "extension Planner: CustomStringConvertible  Sources/App/Planner+Export.swift:3-5 · 2 extensions: :3-5, :7-14")
        #expect(lines[1].hasPrefix("3 uses in 2 files (app 2, test 1); 1 more use inside the extensions · complete:"))
        #expect(lines.contains("  exportName 7 (Wizard.run) · export(to:) 9 (Wizard.run)"))
        #expect(lines.contains("  9 │ return planner.export(to: URL(fileURLWithPath: \"/tmp\"))"))
        #expect(lines.contains("  6 │ #expect(Planner().export(to: URL(fileURLWithPath: \"/tmp\")))"))
    }

    @Test("Two extensions of different types in one file are separate targets, each scoped to its own members")
    func scoped() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "extension-scoped")
        let string = try usages(engine, "Sources/App/Planner+Export.swift#String")
        #expect(string.header.title == "extension String" && string.header.kind == "extension")
        #expect(string.notes == ["adds shouted() :17"])
        #expect(members(string) == ["shouted()": [7]])
        #expect(string.completeness?.isComplete == true)
        let planner = try usages(engine, "Sources/App/Planner+Export.swift#Planner")
        #expect(members(planner)["shouted()"] == nil)
    }

    @Test("A file that declares the type and extends it: path#Name is the type; a line of the extension is the extension")
    func typeAndLines() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "extension-lines")
        let type = try usages(engine, "Sources/App/Planner.swift#Planner")
        #expect(type.view == .type && type.header.title == "final class Planner")

        // `extension Planner {`, outside any member.
        let byLine = try usages(engine, "Sources/App/Planner.swift:9")
        #expect(byLine.header.title == "extension Planner" && byLine.header.lines == LineRange(9, 13))
        #expect(byLine.target == "Sources/App/Planner.swift:9")
        #expect(byLine.notes == ["adds replan() :10"])
        #expect(members(byLine) == ["replan()": [10]])
        #expect(byLine.files.map(\.path) == ["Sources/App/Planner+Export.swift"])

        // Inside a member: the member, as before.
        let member = try usages(engine, "Sources/App/Planner.swift:11")
        #expect(member.view == .callers && member.header.title.hasPrefix("func Planner.replan() -> String"))
    }

    @Test("A private extension is used in its own file: the declaring file is listed")
    func privateExtension() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "extension-private")
        let result = try usages(engine, "Tests/AppTests/PlannerTests.swift#Int")
        #expect(result.header.title == "private extension Int")
        #expect(result.files.map(\.path) == ["Tests/AppTests/PlannerTests.swift"])
        #expect(members(result) == ["doubled()": [10, 11]])
        #expect(result.files.first?.groups.first?.sites.map(\.line) == [10])
        #expect(result.completeness?.summary == "complete: \"doubled\" occurs 3×: 2 resolved to the target, 1 declaration; 0 unresolved")
    }

    @Test("A conformance alone: what it adds, no uses, and that uses as the protocol are not indexed")
    func conformanceOnly() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "extension-conformance")
        let result = try usages(engine, "Sources/App/Planner+Sendable.swift#Planner")
        #expect(result.header.title == "extension Planner: @unchecked Sendable")
        #expect(result.totals.count == 0 && result.files.isEmpty)
        #expect(result.notes == ["adds conformance to Sendable and no members: where Planner is used as Sendable is not indexed"])
        #expect(result.completeness?.summary == "complete: the extension adds no members to name")
        #expect(result.footers.first { $0.kind == .alsoNamed }?.items.first == "Planner (class, 6 uses in 5 files, excluded)")
    }

    @Test("Bare names never select an extension; a miss suggests extensions by path#Name, and a shared suffix gives choices")
    func namesAndSuggestions() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "extension-names")
        let type = try usages(engine, "Planner")
        #expect(type.view == .type && type.header.title == "final class Planner")

        for miss in ["String", "Sources/App/Planner+Export.swift#Strin"] {
            do {
                _ = try usages(engine, miss)
                Issue.record("\(miss) names no declaration")
            } catch EngineError.notFound(_, let suggestions) {
                #expect(suggestions.contains("Sources/App/Planner+Export.swift#String"), "\(suggestions)")
                #expect(!suggestions.contains("String"), "\(suggestions)")
            }
        }

        let choices = try usages(engine, "Formatting.swift#String")
        #expect(choices.view == .choices)
        #expect(choices.choices.map(\.target).sorted() == ["Sources/App/Formatting.swift#String", "Sources/Kit/Formatting.swift#String"])
        #expect(choices.choices.allSatisfy { $0.kind == "extension" })
    }

    // MARK: outline

    @Test("outline: the extensions' members; a file's other extensions of the type keep their own lines")
    func outline() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.app, name: "extension-outline")
        let result = try engine.outline("Sources/App/Planner+Export.swift#Planner")
        let symbol = try #require(result.symbol)
        #expect(result.kind == .symbol && symbol.declaration.kind == .extension)
        #expect(symbol.declaration.members.map(\.name) == ["description"])
        #expect(symbol.extensions.map { $0.declaration.members.map(\.name) } == [["export", "exportName"]])
        #expect(OutlineRenderer.render(result, budget: .unlimited).components(separatedBy: "\n") == [
            "extension Planner: CustomStringConvertible  Sources/App/Planner+Export.swift:3-5 · used by 2 files (1 app, 1 test)",
            "  4  var description: String",
            "extension Planner  :7-14",
            "    export(to:) -> Bool :9 · exportName: String :13",
            "calls out: Planner.replan :10",
        ])

        // The first extension by line is outlined alone, not taken from the memo of the file's two.
        let byLine = OutlineRenderer.render(try engine.outline("Sources/App/Planner+Export.swift:3"), budget: .unlimited)
        #expect(byLine == "extension Planner: CustomStringConvertible  Sources/App/Planner+Export.swift:3-5 · used by no other file\n  4  var description: String")

        let conformance = OutlineRenderer.render(try engine.outline("Sources/App/Planner+Sendable.swift#Planner"), budget: .unlimited)
        #expect(conformance == "extension Planner: @unchecked Sendable  Sources/App/Planner+Sendable.swift:1 · used by no other file")
    }

    static let mixed: [String: String] = [
        "Sources/App/Model.swift": """
            struct Model {
                var value = 1
            }

            extension Model { func one() -> Int { value } }

            extension Model {
                func two() -> Int { one() + 1 }
            }
            """,
        "Sources/App/Model+More.swift": """
            extension Model {
                func three() -> Int { two() + 1 }
            }
            """,
        "Sources/App/Use.swift": """
            func run() -> Int {
                let model = Model()
                return model.one() + model.two() + model.three()
            }
            """,
        "objc/Counter.h": """
            #import <Foundation/Foundation.h>

            @interface Counter : NSObject
            - (void)increment;
            @end
            """,
        "objc/Counter.m": """
            #import "Counter.h"

            @implementation Counter {
                int _count;
            }

            - (void)increment {
                _count += 1;
            }

            @end

            void bump(Counter *c) {
                [c increment];
            }
            """,
        "rust/src/lib.rs": """
            pub struct Gauge;

            impl Gauge {
                pub fn new() -> Gauge {
                    Gauge
                }
            }

            pub fn use_it() -> Gauge {
                Gauge::new()
            }
            """,
    ]

    @Test("Every printed target selects what it names: one-line extensions, other files' extensions one by one, Swift only")
    func exactTargetsSelect() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.mixed, name: "extension-exact")
        // A one-line extension is selected by its line; its member keeps its name.
        let oneLine = try usages(engine, "Sources/App/Model.swift:5")
        #expect(oneLine.target == "Sources/App/Model.swift:5")
        #expect(oneLine.notes.first == "adds one() :5")
        #expect(try usages(engine, "Model.one").view == .callers)

        // Model.swift declares the type, so path#Model is the struct: its two extensions are listed one by one, each
        // under a target that selects that extension alone.
        let more = try usages(engine, "Sources/App/Model+More.swift#Model")
        let also = try #require(more.footers.first { $0.kind == .alsoNamed })
        let targets = also.items.map { String($0[..<$0.range(of: " (")!.lowerBound]) }
        #expect(targets == ["Model", "Sources/App/Model.swift:5", "Sources/App/Model.swift:7"])
        for (target, line) in zip(targets.dropFirst(), [5, 7]) {
            guard case .symbol(let rows) = try engine.resolveUsageTarget(target) else { Issue.record("\(target)"); continue }
            #expect(rows.count == 1 && rows[0].kind == .extension && rows[0].lines.start == line, "\(target)")
        }

        // An Objective-C @implementation and a Rust impl are not extension targets.
        #expect(throws: EngineError.self) { try self.usages(engine, "objc/Counter.m#Counter") }
        let counter = try usages(engine, "Counter")
        #expect(counter.completeness?.summary.contains("1 other declaration (Counter)") == true, "\(counter.completeness?.summary ?? "")")
        let gauge = try usages(engine, "rust/src/lib.rs#Gauge")
        #expect(gauge.completeness?.summary.contains("1 other declaration (Gauge)") == true, "\(gauge.completeness?.summary ?? "")")
    }

    // MARK: End to end

    @Test("The real binary: usages, outline and debug target for an extension target")
    func cli() throws {
        let root = try RepoFixture.make(Self.app, name: "extension-cli")
        let index = try CLI.run(["index", root.path, "--no-embeddings", "--no-history", "-q"])
        #expect(index.status == 0, "\(index.stderr)")

        let usages = try CLI.run(["usages", "Sources/App/Planner+Export.swift#String", "--repo", root.path, "--no-refresh"])
        #expect(usages.status == 0, "\(usages.stderr)")
        #expect(usages.stdout.hasPrefix("extension String  Sources/App/Planner+Export.swift:16-20 · extension\n"))
        #expect(usages.stdout.contains("1 use in 1 file (app 1, test 0) · complete: \"shouted\" occurs 2×"))
        #expect(usages.stdout.contains("  7 │ let title = planner.exportName.shouted()"))

        let outline = try CLI.run(["outline", "Sources/App/Planner+Export.swift#String", "--repo", root.path, "--no-refresh"])
        #expect(outline.status == 0, "\(outline.stderr)")
        #expect(outline.stdout.contains("  17  func shouted() -> String"))

        let target = try CLI.run(["debug", "target", "Sources/App/Planner.swift:9", "--repo", root.path, "--no-refresh"])
        #expect(target.status == 0, "\(target.stderr)")
        #expect(target.stdout == """
            Sources/App/Planner.swift:9 → 1 extension of Planner in Sources/App/Planner.swift · its members have 1 use in 1 file
              extension Planner  :9-13
                replan() :10-12 · method
              exact target: Sources/App/Planner.swift:9

            """)
    }
}
