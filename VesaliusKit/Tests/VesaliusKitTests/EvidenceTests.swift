import Foundation
@testable import QueryEngine
import RepositoryIndex
import Testing
import VesaliusCore

/// The evidence layer: lexing, statements, completeness, the usages target grammar, route labels and
/// the per-version memo. The fixture tests index a real repository on disk; the CLI test drives the binary.
@Suite("Evidence: statements, completeness and usages targets", .serialized)
struct EvidenceTests {
    // MARK: Lexer

    /// The region of the `occurrence`-th appearance of `needle` in `source`.
    private func region(of needle: String, in source: String, path: String, occurrence: Int = 0) throws -> CodeLexer.Region {
        let bytes = Array(source.utf8), target = Array(needle.utf8)
        var found = -1, seen = 0
        for index in 0...(bytes.count - target.count) where Array(bytes[index..<index + target.count]) == target {
            if seen == occurrence {
                found = index
                break
            }
            seen += 1
        }
        try #require(found >= 0, "\(needle) not in source")
        let regions = CodeLexer.regions(bytes, dialect: CodeLexer.Dialect(path: path))
        return try #require(CodeLexer.Region(rawValue: regions[found]))
    }

    @Test("Swift: doc and nested comments, interpolation is code, raw and multi-line strings, regex literals")
    func swiftLexing() throws {
        let source = #"""
            /// Docs mention alfa.
            // A comment mentions bravo.
            /* outer /* nested charlie */ still comment delta */
            let s = "text echo \(foxtrot + 1) more"
            let raw = #"raw "golf" \(hotel)"#
            let multi = """
                india
                """
            let pattern = #/juliett+/#
            let value = kilo / lima / mike
            """#
        let path = "a.swift"
        #expect(try region(of: "alfa", in: source, path: path) == .doc)
        #expect(try region(of: "bravo", in: source, path: path) == .comment)
        #expect(try region(of: "charlie", in: source, path: path) == .comment)
        #expect(try region(of: "delta", in: source, path: path) == .comment)
        #expect(try region(of: "echo", in: source, path: path) == .string)
        #expect(try region(of: "foxtrot", in: source, path: path) == .code)
        #expect(try region(of: "golf", in: source, path: path) == .string)
        // A raw string interpolates only with `\#(`.
        #expect(try region(of: "hotel", in: source, path: path) == .string)
        #expect(try region(of: "india", in: source, path: path) == .string)
        #expect(try region(of: "juliett", in: source, path: path) == .string)
        // Division is not a regex literal.
        #expect(try region(of: "lima", in: source, path: path) == .code)
        #expect(try region(of: "mike", in: source, path: path) == .code)
    }

    @Test("TypeScript and JSX: templates, regex literals, element text; Python: f-strings and docstrings")
    func scriptAndPythonLexing() throws {
        let script = """
            const a = `template ${alfa} bravo`;
            const r = /charlie+/.test(delta);
            const ratio = echo / foxtrot / 2;
            // golf
            function View() {
              return <div className="hotel">India text {juliett} more</div>;
            }
            """
        #expect(try region(of: "alfa", in: script, path: "a.tsx") == .code)
        #expect(try region(of: "bravo", in: script, path: "a.tsx") == .string)
        #expect(try region(of: "charlie", in: script, path: "a.tsx") == .string)
        #expect(try region(of: "delta", in: script, path: "a.tsx") == .code)
        #expect(try region(of: "foxtrot", in: script, path: "a.tsx") == .code)
        #expect(try region(of: "golf", in: script, path: "a.tsx") == .comment)
        #expect(try region(of: "hotel", in: script, path: "a.tsx") == .string)
        #expect(try region(of: "India", in: script, path: "a.tsx") == .string)
        #expect(try region(of: "juliett", in: script, path: "a.tsx") == .code)
        // In a .ts file `<` never starts an element.
        #expect(try region(of: "India", in: script, path: "a.ts") == .code)

        // Type parameter lists in .tsx are not elements, and nothing after them reads as element text.
        let generics = """
            const pick = <T extends object>(kilo: T) => kilo;
            const keep = <T,>(lima: T) => lima;
            const fallback = <T = unknown>(mike: T) => mike;
            const list = <ul>{items.map((november) => <li key={november}>Oscar</li>)}</ul>;
            """
        #expect(try region(of: "kilo", in: generics, path: "a.tsx", occurrence: 1) == .code)
        #expect(try region(of: "lima", in: generics, path: "a.tsx", occurrence: 1) == .code)
        #expect(try region(of: "mike", in: generics, path: "a.tsx", occurrence: 1) == .code)
        #expect(try region(of: "november", in: generics, path: "a.tsx", occurrence: 1) == .code)
        #expect(try region(of: "Oscar", in: generics, path: "a.tsx") == .string)
        // A tag that never closes is not an element either.
        #expect(try region(of: "papa", in: "const flag = ok && <b>papa(1);\n", path: "a.jsx") == .code)

        let python = #"""
            def load(alfa):
                """Loads bravo."""
                name = f"charlie {delta} echo"  # foxtrot
                return golf
            """#
        #expect(try region(of: "alfa", in: python, path: "a.py") == .code)
        #expect(try region(of: "bravo", in: python, path: "a.py") == .doc)
        #expect(try region(of: "charlie", in: python, path: "a.py") == .string)
        #expect(try region(of: "delta", in: python, path: "a.py") == .code)
        #expect(try region(of: "foxtrot", in: python, path: "a.py") == .comment)
        #expect(try region(of: "golf", in: python, path: "a.py") == .code)
        #expect(try region(of: "Call", in: "Call x", path: "README.md") == .nonSource)
    }

    // MARK: Statements

    private func file(_ text: String, path: String = "Sources/A.swift") -> SourceText.File {
        SourceText.File(path: path, stamp: SourceText.Stamp(size: text.utf8.count, modified: 0), bytes: Array(text.utf8))
    }

    @Test("A call split over two lines joins into one statement; the governing `if` is found")
    func joinedStatement() {
        let source = file("""
            func start() {
                if single, let only = singleURL {
                    book = await libraryService.importBook(
                        from: only, preferences: nil, modelContext: modelContext)
                }
            }
            """)
        let statement = source.statement(line: 3, stmt: nil, end: nil, callEnd: nil, name: "importBook", column: nil)
        #expect(statement.start == 3 && statement.end == 4)
        #expect(statement.joined == "book = await libraryService.importBook(from: only, preferences: nil, modelContext: modelContext)")
        #expect(statement.rendered().map(\.number) == [3])
        let condition = source.enclosingCondition(above: statement.start, maxLength: 110)
        #expect(condition == Statement.Line(number: 2, text: "if single, let only = singleURL {"))
    }

    @Test("A site line that closes brackets opened above starts at the statement head")
    func walksBack() {
        let source = file("""
            Telemetry.track(.launch(mode: "cold",
                                    premium: subscriptions.isSubscribed))
            """)
        let statement = source.statement(line: 2, stmt: nil, end: nil, callEnd: nil, name: "isSubscribed", column: nil)
        #expect(statement.start == 1)
        #expect(statement.joined == #"Telemetry.track(.launch(mode: "cold", premium: subscriptions.isSubscribed))"#)
    }

    @Test("A trailing closure stops the statement; a long statement shows 3 lines and `…`")
    func trailingClosureAndLongStatements() {
        let closure = file("""
            .onChange(of: subs.isSubscribed) { _, now in
                dismiss()
            }
            """)
        #expect(closure.statement(line: 1, stmt: nil, end: nil, callEnd: nil, name: "isSubscribed", column: nil).joined == ".onChange(of: subs.isSubscribed)")

        let long = file("""
            const passphrase = openSecret({
              sealed: entry.sealedPassphrase,
              nonce: entry.nonce,
              keyVersion: entry.keyVersion,
              scope: entry.scope,
            });
            """, path: "src/route.ts")
        let statement = long.statement(line: 1, stmt: nil, end: nil, callEnd: nil, name: "openSecret", column: nil)
        #expect(statement.end == 6 && statement.continues)
        #expect(statement.joined == "const passphrase = openSecret({ sealed: entry.sealedPassphrase, nonce: entry.nonce, …")
        #expect(statement.text().count <= 110)
    }

    @Test("A dropped comment inside a statement leaves `…`, so the quoted text stays contiguous in the file")
    func commentGap() {
        let source = file("""
            let total = compute(a, // why
                b)
            """)
        #expect(source.statement(line: 1, stmt: nil, end: nil, callEnd: nil, name: "compute", column: nil).joined == "let total = compute(a, … b)")
    }

    @Test("A line ending in a string literal ends its statement; a multi-line literal carries it to its closing line")
    func stringLiteralEndsStatement() {
        let source = file("""
            enum IDs {
                static let annualID = "yearly_atlas"
                static let lifetimeID = "lifetime_atlas"
                static let banner = \"\"\"
                    Go premium
                    \"\"\"
                static let joined = "a" +
                    "b"
            }
            """)
        let lifetime = source.statement(line: 3, stmt: nil, end: nil, callEnd: nil, name: "lifetimeID", column: nil)
        #expect(lifetime.start == 3 && lifetime.end == 3)
        #expect(lifetime.joined == #"static let lifetimeID = "lifetime_atlas""#)
        #expect(source.statement(line: 2, stmt: nil, end: nil, callEnd: nil, name: "annualID", column: nil).end == 2)
        let banner = source.statement(line: 4, stmt: nil, end: nil, callEnd: nil, name: "banner", column: nil)
        #expect(banner.start == 4 && banner.end == 6)
        let joined = source.statement(line: 7, stmt: nil, end: nil, callEnd: nil, name: "joined", column: nil)
        #expect(joined.start == 7 && joined.end == 8)
    }

    @Test("Index bounds win when they span 3 lines or fewer")
    func indexBounds() {
        let source = file("""
            let a = 1
            let b = first(
                second(a))
            """)
        let statement = source.statement(line: 3, stmt: 2, end: 3, callEnd: nil, name: "second", column: nil)
        #expect(statement.basis == .index && statement.start == 2)
        #expect(statement.joined == "let b = first(second(a))")
    }

    @Test("Elision cuts the middle and keeps the site token")
    func elision() {
        let text = String(repeating: "alpha ", count: 15) + "target(x)" + String(repeating: " omega", count: 15)
        let focus = Array(text).firstIndex(of: "t").map { $0..<$0 + 6 }
        let cut = Statement.elide(text, to: 60, keeping: focus)
        #expect(cut.count <= 60)
        #expect(cut.contains("target"))
        #expect(cut.contains("…"))
        #expect(Statement.elide("short", to: 60, keeping: nil) == "short")
    }

    // MARK: Target grammar helpers

    @Test("Selectors come from Swift signatures; truncated signatures give none")
    func selectors() {
        #expect(RepositoryEngine.selector(name: "embed", kind: .method, signature: "public func embed(_ text: String) async throws -> [Float]") == "embed(_:)")
        #expect(RepositoryEngine.selector(name: "importBook", kind: .method, signature: "func importBook(from url: URL, preferences: ReaderPreferences?, modelContext: ModelContext) async -> Book?") == "importBook(from:preferences:modelContext:)")
        #expect(RepositoryEngine.selector(name: "init", kind: .initializer, signature: "public init(from decoder: Decoder) throws") == "init(from:)")
        #expect(RepositoryEngine.selector(name: "decode", kind: .method, signature: "static func decode<T: Decodable>(_ type: T.Type, map: [String: Int], done: (Int) -> Void)") == "decode(_:map:done:)")
        #expect(RepositoryEngine.selector(name: "data", kind: .enumCase, signature: "case data(sequence: UInt64, Data)") == "data(sequence:_:)")
        #expect(RepositoryEngine.selector(name: "subscript", kind: .method, signature: "subscript(index: Int) -> Element") == "subscript(_:)")
        #expect(RepositoryEngine.selector(name: "init", kind: .initializer, signature: "public init( sourceURL: URL, frameCount: Int, superseded…") == nil)
        #expect(RepositoryEngine.parseSelector("TextEncoder.encode(_:)")?.base == "TextEncoder.encode")
        #expect(RepositoryEngine.parseSelector("TextEncoder.encode(_:)")?.selector == "encode(_:)")
        #expect(RepositoryEngine.parseSelector("Wax.swift") == nil)
        #expect(RepositoryEngine.normalizedTarget("  `Foo.bar()` ", root: URL(fileURLWithPath: "/repo")) == "Foo.bar")
        #expect(RepositoryEngine.normalizedTarget("/repo/Sources/A.swift", root: URL(fileURLWithPath: "/repo")) == "Sources/A.swift")
    }

    @Test("Next.js route files label their handlers")
    func routeLabels() {
        #expect(RouteLabel.label(path: "src/app/api/vault/route.ts", handler: "POST") == "POST /api/vault")
        #expect(RouteLabel.label(path: "app/(marketing)/@modal/api/users/[id]/route.js", handler: "GET") == "GET /api/users/[id]")
        #expect(RouteLabel.label(path: "app/route.ts", handler: "GET") == "GET /")
        #expect(RouteLabel.label(path: "apps/web/src/app/api/(.)photo/route.ts", handler: "DELETE") == "DELETE /api/photo")
        #expect(RouteLabel.label(path: "src/app/api/vault/route.ts", handler: "helper") == nil)
        #expect(RouteLabel.label(path: "src/server/vault.ts", handler: "POST") == nil)
        #expect(RouteLabel.label(path: "pages/api/hello.ts", handler: "handler", isDefaultExport: true) == "ANY /api/hello")
        #expect(RouteLabel.label(path: "src/pages/api/users/index.ts", handler: "default") == "ANY /api/users")
        #expect(RouteLabel.label(path: "pages/api/hello.ts", handler: "helper") == nil)
    }

    @Test("Memoized values live until the index version moves")
    func memo() {
        let memo = VersionedMemo(capacity: 2)
        var computed = 0
        func value(_ key: String, _ version: Int) -> Int {
            memo.value(for: key, version: version) {
                computed += 1
                return computed
            }
        }
        #expect(value("a", 1) == 1)
        #expect(value("a", 1) == 1)
        #expect(value("b", 1) == 2)
        #expect(value("a", 2) == 3)
        #expect(memo.count == 1)
        _ = value("c", 2)
        _ = value("d", 2)
        #expect(memo.count == 2)
        memo.clear()
        #expect(memo.count == 0)
    }

    // MARK: Fixture repositories

    static let planner: [String: String] = [
        "Sources/App/Planner.swift": """
            import Foundation

            /// Plans books. `importBook` builds one from a file.
            final class Planner {
                func importBook(from url: URL) -> String {
                    // importBook is the entry point
                    return "importBook"
                }

                func run() {
                    _ = importBook(from: URL(fileURLWithPath: "/"))
                }
            }
            """,
        "Sources/App/Wizard.swift": """
            final class Wizard {
                let planner = Planner()

                func start(single: Bool) {
                    if single {
                        let result = planner.importBook(
                            from: URL(fileURLWithPath: "/tmp"))
                        print(result)
                    }
                }
            }
            """,
        "Sources/App/Settings.swift": """
            final class Settings {
                func save(_ value: Int) {}
                func save(batch values: [Int]) {}
            }
            """,
        "Sources/Kit/Settings.swift": """
            final class Settings {}
            """,
        "Sources/App/Store.swift": """
            final class Store {
                func reload() {}
                func reload(force: Bool) {}
            }
            """,
        "docs/notes.md": "Call `importBook` to import a book.\n",
    ]

    @Test("Completeness accounts for every occurrence: uses, declaration, comments, a string key and docs")
    func completeness() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.planner, name: "evidence-complete")
        guard case .symbol(let rows) = try engine.resolveUsageTarget("Planner.importBook") else {
            Issue.record("Planner.importBook is one declaration")
            return
        }
        let result = try engine.completeness(of: "importBook", targets: Set(rows.map(\.id)))
        #expect(result.occurrences.count == 7)
        #expect(result.count(.target) == 2)
        #expect(result.count(.declaration) == 1)
        #expect(result.count(.comment, .doc) == 2)
        #expect(result.count(.dynamic) == 1)
        #expect(result.occurrences(.dynamic).first?.form == .stringKey)
        #expect(result.count(.nonSource) == 1)
        #expect(result.isComplete)
        #expect(result.summary.hasPrefix("complete: \"importBook\" occurs 7×"))
        #expect(result.summary.contains("0 unresolved"))

        // Against another declaration, the same uses are someone else's: nothing is claimed for it.
        guard case .symbol(let other) = try engine.resolveUsageTarget("Wizard.start") else {
            Issue.record("Wizard.start is one declaration")
            return
        }
        let elsewhere = try engine.completeness(of: "importBook", targets: Set(other.map(\.id)))
        #expect(elsewhere.count(.target) == 0)
        #expect(elsewhere.count(.other) == 2)
        #expect(elsewhere.count(.otherDeclaration) == 1)
        #expect(elsewhere.occurrences(.other).allSatisfy { $0.detail == "Planner.importBook" })
    }

    @Test("A declaration's name is the occurrence after its keyword, not a key path in its attribute")
    func declarationAfterAttribute() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/Home.swift": """
                import SwiftUI

                struct Home: View {
                    @Environment(\\.scenePhase) private var scenePhase

                    var body: some View {
                        Text("Home").onChange(of: scenePhase) { _, _ in }
                    }
                }
                """,
        ], name: "evidence-declaration")
        guard case .symbol(let rows) = try engine.resolveUsageTarget("Home.scenePhase") else {
            Issue.record("Home.scenePhase is one declaration")
            return
        }
        let result = try engine.completeness(of: "scenePhase", targets: Set(rows.map(\.id)))
        let declarations = result.occurrences(.declaration)
        #expect(declarations.count == 1)
        #expect(declarations.first?.line == 4)
        #expect(declarations.first?.column == Array("    @Environment(\\.scenePhase) private var ".utf8).count + 1)
        #expect(result.occurrences.first { $0.line == 4 && $0.column < 30 }?.form == .keyPath)
        #expect(result.count(.local) == 0)
    }

    @Test("Members of function-local types are targets, by name and by path:line")
    func localTypeMembers() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/Plan.swift": """
                func plan() -> Int {
                    struct Step {
                        let length: Int
                    }
                    return Step(length: 3).length
                }
                """,
        ], name: "evidence-local")
        guard case .symbol(let byLine) = try engine.resolveUsageTarget("Sources/App/Plan.swift:3") else {
            Issue.record("path:line inside a local type is its member")
            return
        }
        let member = try #require(byLine.first)
        #expect(member.name == "length" && member.qualifiedName.hasSuffix("Step.length"))
        guard case .symbol(let byName) = try engine.resolveUsageTarget(member.qualifiedName) else {
            Issue.record("a local type's member is reachable by its qualified name")
            return
        }
        #expect(byName.map(\.id) == [member.id])
    }

    @Test("A reference row the linker left without a target is unresolved and rules out `complete`")
    func unresolvedRow() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/Pingers.swift": """
                final class Alpha { func ping() {} }
                final class Bravo { func ping() {} }
                final class Charlie { func ping() {} }
                final class Delta { func ping() {} }

                struct Prober {
                    func probe() {
                        // `makeTarget` is declared nowhere, so nothing can type `target`.
                        let target = makeTarget()
                        target.ping()
                    }
                }
                """,
        ], name: "evidence-unresolved")
        guard case .symbol(let rows) = try engine.resolveUsageTarget("Alpha.ping") else {
            Issue.record("Alpha.ping is one declaration")
            return
        }
        let result = try engine.completeness(of: "ping", targets: Set(rows.map(\.id)))
        #expect(result.count(.declaration) == 1)
        #expect(result.count(.otherDeclaration) == 3)
        // Four same-name members: the linker gives up (no target), so the call is unresolved, not external.
        #expect(result.count(.unresolved) == 1)
        #expect(result.count(.external) == 0)
        #expect(result.occurrences(.unresolved).first?.line == 10)
        #expect(!result.isComplete)
        #expect(result.summary.hasPrefix("INCOMPLETE"))
        #expect(result.summary.contains("1 unresolved (Pingers.swift:10)"))
    }

    @Test("Target grammar: choices for same-name declarations, path#Name, selectors, path:line, frameworks, misses")
    func usageTargets() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.planner, name: "evidence-targets")
        guard case .choices(let choices) = try engine.resolveUsageTarget("Settings") else {
            Issue.record("two Settings classes are choices")
            return
        }
        #expect(Set(choices.map(\.target)) == ["Sources/App/Settings.swift#Settings", "Sources/Kit/Settings.swift#Settings"])
        guard case .symbol(let settings) = try engine.resolveUsageTarget("Sources/Kit/Settings.swift#Settings") else {
            Issue.record("path#Name is one declaration")
            return
        }
        #expect(settings.map(\.path) == ["Sources/Kit/Settings.swift"])

        guard case .choices(let overloads) = try engine.resolveUsageTarget("Settings.save") else {
            Issue.record("overloads are choices")
            return
        }
        #expect(Set(overloads.map(\.target)) == ["Settings.save(_:)", "Settings.save(batch:)"])
        guard case .symbol(let batch) = try engine.resolveUsageTarget("`Settings.save(batch:)`") else {
            Issue.record("a selector picks one overload")
            return
        }
        #expect(batch.first?.lines.start == 3)

        guard case .symbol(let enclosing) = try engine.resolveUsageTarget("Sources/App/Wizard.swift:6") else {
            Issue.record("path:line is the innermost declaration")
            return
        }
        #expect(enclosing.first?.qualifiedName == "Wizard.start")

        guard case .framework(let name, let importers) = try engine.resolveUsageTarget("Foundation") else {
            Issue.record("Foundation is a framework")
            return
        }
        #expect(name == "Foundation" && importers.map(\.path) == ["Sources/App/Planner.swift"])
        guard case .file(_, let path) = try engine.resolveUsageTarget("App/Wizard.swift") else {
            Issue.record("a unique path suffix is a file")
            return
        }
        #expect(path == "Sources/App/Wizard.swift")
        guard case .folder(let folder, let files) = try engine.resolveUsageTarget("Sources/App/") else {
            Issue.record("a folder path is a folder")
            return
        }
        #expect(folder == "Sources/App" && files.count == 4)

        // A zero-argument overload keeps its `()`; anywhere else a trailing `()` is noise.
        guard case .choices(let reloads) = try engine.resolveUsageTarget("Store.reload") else {
            Issue.record("overloads are choices")
            return
        }
        #expect(Set(reloads.map(\.target)) == ["Store.reload()", "Store.reload(force:)"])
        for choice in reloads {
            guard case .symbol(let rows) = try engine.resolveUsageTarget(choice.target) else {
                Issue.record("\(choice.target) selects one declaration")
                continue
            }
            #expect(rows.count == 1)
        }
        guard case .symbol = try engine.resolveUsageTarget("Planner.importBook()") else {
            Issue.record("a trailing () on a unique name is stripped")
            return
        }

        do {
            _ = try engine.resolveUsageTarget("Settings.save(other:)")
            Issue.record("an unknown selector is a miss")
        } catch EngineError.notFound(_, let suggestions) {
            #expect(suggestions.contains("Settings.save(_:)"))
            #expect(suggestions.contains("Settings.save(batch:)"))
        }
    }

    @Test("A type named like its module: both are choices, and each choice string selects exactly one")
    func moduleCollision() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription

                let package = Package(name: "Kit", targets: [.target(name: "Kit")])
                """,
            "Sources/Kit/Kit.swift": """
                public struct Kit {
                    public init() {}
                }
                """,
        ], name: "evidence-module")
        guard case .choices(let choices) = try engine.resolveUsageTarget("Kit") else {
            Issue.record("a module and a type of one name are choices")
            return
        }
        #expect(Set(choices.map(\.target)) == ["Sources/Kit/Kit.swift#Kit", "mod:Kit"])
        guard case .symbol = try engine.resolveUsageTarget("Sources/Kit/Kit.swift#Kit"), case .module(let name, _) = try engine.resolveUsageTarget("mod:Kit") else {
            Issue.record("each choice string selects one target")
            return
        }
        #expect(name == "Kit")
    }

    @Test("An edited file is stale: its line no longer holds the name, and completeness says so")
    func staleness() async throws {
        let (engine, root) = try await RepoFixture.indexed(Self.planner, name: "evidence-stale")
        #expect(try engine.staleFiles(["Sources/App/Wizard.swift"]).isEmpty)
        #expect(engine.sourceText.lineContains("Sources/App/Wizard.swift", line: 6, name: "importBook"))

        try RepoFixture.write("// moved down a line\n" + (Self.planner["Sources/App/Wizard.swift"] ?? ""), to: "Sources/App/Wizard.swift", in: root)
        #expect(try engine.staleFiles(["Sources/App/Wizard.swift", "Sources/App/Planner.swift"]) == ["Sources/App/Wizard.swift"])
        #expect(!engine.sourceText.lineContains("Sources/App/Wizard.swift", line: 6, name: "importBook"))
        #expect(engine.sourceText.lineContains("Sources/App/Wizard.swift", line: 7, name: "importBook"))

        guard case .symbol(let rows) = try engine.resolveUsageTarget("Planner.importBook") else {
            Issue.record("Planner.importBook is one declaration")
            return
        }
        let result = try engine.completeness(of: "importBook", targets: Set(rows.map(\.id)))
        #expect(result.staleFiles == ["Sources/App/Wizard.swift"])
        #expect(!result.isComplete)
        #expect(result.summary.hasPrefix("INCOMPLETE"))
    }

    @Test("A memoized value is kept until another engine re-indexes, then computed again")
    func memoAcrossEngines() async throws {
        let (reader, root) = try await RepoFixture.indexed(Self.planner, name: "evidence-memo")
        var computed = 0
        #expect(reader.memoized("count") { computed += 1; return computed } == 1)
        #expect(reader.memoized("count") { computed += 1; return computed } == 1)

        // Another engine (in practice another process: the app, `vesalius watch`) indexes an edit.
        try RepoFixture.write("final class Extra {}\n", to: "Sources/App/Extra.swift", in: root)
        let before = reader.indexVersion()
        let writer = try RepositoryEngine(repository: root)
        try await writer.index(options: RepoFixture.fastOptions)
        #expect(reader.indexVersion() > before)
        #expect(reader.memoized("count") { computed += 1; return computed } == 2)
    }

    @Test("`vesalius debug` prints completeness, statements and targets from the real binary")
    func debugCommands() throws {
        let root = try RepoFixture.make(Self.planner, name: "evidence-cli")
        let index = try CLI.run(["index", root.path, "--no-embeddings", "--no-history", "-q"])
        #expect(index.status == 0, "\(index.stderr)")

        let completeness = try CLI.run(["debug", "completeness", "importBook", "--target", "Planner.importBook", "--repo", root.path, "--no-refresh"])
        #expect(completeness.status == 0, "\(completeness.stderr)")
        #expect(completeness.stdout.contains("complete: \"importBook\" occurs 7×"))

        let statement = try CLI.run(["debug", "statement", "Sources/App/Wizard.swift:6", "--repo", root.path, "--no-refresh"])
        #expect(statement.stdout.contains("let result = planner.importBook(from: URL(fileURLWithPath: \"/tmp\"))"))
        #expect(statement.stdout.contains("condition  5 │ if single {"))

        let target = try CLI.run(["debug", "target", "Settings", "--repo", root.path, "--no-refresh"])
        #expect(target.stdout.contains("2 choices"))
        #expect(target.stdout.contains("Sources/Kit/Settings.swift#Settings"))

        let ambiguous = try CLI.run(["debug", "completeness", "Settings", "--target", "Settings", "--repo", root.path, "--no-refresh"])
        #expect(ambiguous.status != 0)
        #expect(ambiguous.stderr.contains("matches 2 targets"))
    }
}
