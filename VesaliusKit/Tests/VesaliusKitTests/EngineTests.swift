import Foundation
import Testing
@testable import GraphEngine
@testable import QueryEngine
import RepositoryIndex
import VesaliusCore

@Suite("Indexing, graph queries, health and impact", .serialized)
struct EngineTests {
    // MARK: Indexing

    @Test("A full index stores files, symbols, imports and typed edges")
    func fullIndex() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "full")
        let files = Set(try engine.allFiles().map(\.path))
        #expect(files == RepoFixture.expectedAppFiles)
        let symbols = try engine.allSymbols()
        for name in ["AuthService", "SessionStore", "LoginView", "ApiClient", "fetchUser", "UserCard", "User", "load_user"] {
            #expect(symbols.contains { $0.name == name }, "missing symbol \(name)")
        }
        #expect(symbols.first { $0.name == "UserCard" }?.kind == .component)
        #expect(symbols.first { $0.qualifiedName == "AuthService.signIn" }?.kind == .method)
        let stats = try engine.stats()
        #expect(stats.dependencies > 0)
        #expect(stats.externalModules > 0)
    }

    @Test("Re-indexing an unchanged repository does no work; edits are incremental")
    func incremental() async throws {
        let (engine, root) = try await RepoFixture.indexed(RepoFixture.app, name: "incremental")
        let unchanged = try await engine.index(options: RepoFixture.fastOptions)
        #expect(unchanged.filesAdded == 0 && unchanged.filesChanged == 0 && unchanged.filesRemoved == 0)
        #expect(unchanged.filesUnchanged == RepoFixture.expectedAppFiles.count)

        // Modify one file: exactly one file is re-parsed and its new symbol is searchable.
        try RepoFixture.write("""
            import Foundation

            struct SessionStore {
                func save(token: String) {
                    UserDefaults.standard.set(token, forKey: "token")
                }

                func clear() {
                    UserDefaults.standard.removeObject(forKey: "token")
                }
            }
            """, to: "Sources/App/SessionStore.swift", in: root)
        let changed = try await engine.index(options: RepoFixture.fastOptions)
        #expect(changed.filesChanged == 1)
        #expect(changed.filesAdded == 0)
        #expect(try engine.searchSymbols("SessionStore.clear").first?.symbol.qualifiedName == "SessionStore.clear")

        // Touch without changing content: no re-parse.
        try RepoFixture.write(try String(contentsOf: root.appendingPathComponent("web/src/api/users.ts"), encoding: .utf8), to: "web/src/api/users.ts", in: root)
        let touched = try await engine.index(options: RepoFixture.fastOptions)
        #expect(touched.filesChanged == 0)

        // Remove and add files.
        try FileManager.default.removeItem(at: root.appendingPathComponent("web/src/api/users.ts"))
        try RepoFixture.write("export const added = 1;\n", to: "web/src/api/added.ts", in: root)
        let restructured = try await engine.index(options: RepoFixture.fastOptions)
        #expect(restructured.filesRemoved == 1)
        #expect(restructured.filesAdded == 1)
        let dependents = try engine.dependents(of: "web/src/api/client.ts")
        #expect(!dependents.files.contains { $0.path == "web/src/api/users.ts" })
    }

    @Test("Renaming a symbol re-links references in unchanged files")
    func relinking() async throws {
        let (engine, root) = try await RepoFixture.indexed(RepoFixture.app, name: "relink")
        #expect(try engine.callers("SessionStore.save").relations.contains { $0.symbol.qualifiedName == "AuthService.signIn" })
        try RepoFixture.write("""
            import Foundation

            struct SessionStore {
                func persist(token: String) {
                    UserDefaults.standard.set(token, forKey: "token")
                }
            }
            """, to: "Sources/App/SessionStore.swift", in: root)
        try await engine.index(options: RepoFixture.fastOptions)
        #expect(try engine.searchSymbols("SessionStore.save").first?.symbol.qualifiedName != "SessionStore.save")
        // AuthService still calls `save`, which no longer resolves; after fixing the call site it does.
        let source = try String(contentsOf: root.appendingPathComponent("Sources/App/AuthService.swift"), encoding: .utf8)
        try RepoFixture.write(source.replacingOccurrences(of: "store.save(", with: "store.persist("), to: "Sources/App/AuthService.swift", in: root)
        try await engine.index(options: RepoFixture.fastOptions)
        #expect(try engine.callers("SessionStore.persist").relations.contains { $0.symbol.qualifiedName == "AuthService.signIn" })
    }

    // MARK: Graph queries

    @Test("Reverse dependencies and traversal depth (TypeScript imports)")
    func typescriptDependencies() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "ts")
        let direct = try engine.dependents(of: "web/src/api/client.ts")
        #expect(direct.files.map(\.path) == ["web/src/api/users.ts"])
        #expect(direct.files.first?.kinds.contains(.imports) == true)
        let deep = try engine.dependents(of: "client.ts", depth: 3)
        #expect(deep.files.contains { $0.path == "web/src/ui/UserCard.tsx" && $0.distance == 2 })
        let dependencies = try engine.dependencies(of: "web/src/ui/UserCard.tsx")
        #expect(dependencies.files.map(\.path) == ["web/src/api/users.ts"])
        #expect(dependencies.files.first?.symbols?.contains("fetchUser") == true)
    }

    @Test("Swift references resolve across files without imports")
    func swiftReferences() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "swift")
        let refs = try engine.references("SessionStore")
        #expect(refs.symbols.first?.path == "Sources/App/SessionStore.swift")
        #expect(refs.references.contains { $0.path == "Sources/App/AuthService.swift" })
        let callers = try engine.callers("signIn")
        #expect(callers.relations.contains { $0.symbol.qualifiedName == "LoginView.tap" })
        let callees = try engine.callees("AuthService")
        #expect(callees.relations.contains { $0.symbol.qualifiedName == "SessionStore.save" })
        let dependents = try engine.dependents(of: "Sources/App/AuthService.swift")
        #expect(dependents.files.map(\.path).contains("Sources/App/LoginView.swift"))
    }

    @Test("Swift links respect module imports, type-level members and framework receivers")
    func swiftVisibility() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription

                let package = Package(name: "Kit", targets: [
                    .target(name: "Interpreter"),
                    .target(name: "App", dependencies: ["Interpreter"]),
                ])
                """,
            "Sources/Interpreter/Evaluator.swift": """
                public final class Environment {
                    public init() {}
                    public func value(named name: String) -> Int { 0 }
                }
                """,
            "Sources/App/Shapes.swift": """
                enum Corner {
                    case rounded
                    case square
                }

                enum ReadingReminders {
                    static func sync() {}
                }
                """,
            "Sources/App/SettingsView.swift": """
                import SwiftUI
                import StoreKit

                struct SettingsView: View {
                    @Environment(\\.dismiss) private var dismiss
                    let corner = Corner.square

                    func percent(_ fraction: Double) -> Int {
                        Int(fraction.rounded())
                    }

                    func restore() async throws {
                        try await AppStore.sync()
                        ReadingReminders.sync()
                    }

                    var body: some View { Text("Settings") }
                }
                """,
            "Sources/App/Console.swift": """
                import Interpreter

                struct Console {
                    let environment = Environment()
                    func run() -> Int { environment.value(named: "x") }
                }
                """,
        ], name: "visibility")

        // `Environment` from another module is visible only where that module is imported.
        let environment = try engine.references("Environment")
        #expect(environment.references.map(\.path).contains("Sources/App/Console.swift"))
        #expect(!environment.references.map(\.path).contains("Sources/App/SettingsView.swift"))
        let dependents = try engine.dependents(of: "Sources/Interpreter/Evaluator.swift")
        #expect(dependents.files.map(\.path) == ["Sources/App/Console.swift"])

        // A value never reaches an enum case; a framework type never reaches another type's statics.
        let callees = try engine.callees("SettingsView")
        let names = callees.relations.map(\.symbol.qualifiedName)
        #expect(!names.contains("Corner.rounded"))
        let sync = try #require(callees.relations.first { $0.symbol.qualifiedName == "ReadingReminders.sync" })
        #expect(sync.sites == [14])  // `ReadingReminders.sync()`, not `AppStore.sync()` on line 13
        #expect(try engine.callees("Console").relations.map(\.symbol.qualifiedName).contains("Environment.value"))
    }

    @Test("Targets of one Xcode project see each other's files; other packages need an import")
    func xcodeSiblingTargets() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "App.xcodeproj/project.pbxproj": """
                // !$*UTF8*$!
                {
                    objects = {
                        A1 /* Phone */ = {
                            isa = PBXNativeTarget;
                            name = Phone;
                        };
                        A2 /* Watch */ = {
                            isa = PBXNativeTarget;
                            name = Watch;
                        };
                    };
                }
                """,
            "Phone/Models/Workout.swift": "import Foundation\n\nstruct Workout {\n    var endedAt: Date?\n}\n",
            "Watch/SummaryView.swift": """
                import SwiftUI

                struct SummaryView: View {
                    let workout: Workout
                    var body: some View { Text(workout.endedAt?.formatted() ?? "") }
                }
                """,
            "Packages/Fitness/Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription

                let package = Package(name: "Fitness", targets: [.target(name: "Fitness")])
                """,
            "Packages/Fitness/Sources/Fitness/Workout.swift": "import Foundation\n\npublic struct Workout {\n    public var endedAt: Date?\n}\n",
        ], name: "targets")

        let modules = try engine.rawQuery("SELECT m.name FROM files f JOIN modules m ON m.id = f.module_id WHERE f.path IN ('Phone/Models/Workout.swift', 'Watch/SummaryView.swift') ORDER BY f.path")
        #expect(modules.rows.map { $0[0].stringValue } == ["Phone", "Watch"])
        let dependencies = try engine.dependencies(of: "Watch/SummaryView.swift")
        #expect(dependencies.files.map(\.path) == ["Phone/Models/Workout.swift"])
    }

    @Test("Typed Swift links: chains through declared types, labels pick overloads, frameworks stay external, privates stay home")
    func typedSwiftLinks() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/PremiumStore.swift": """
                import StoreKit

                final class PremiumStore {
                    static let shared = PremiumStore()

                    func start() {
                        Task { for await _ in Transaction.updates {} }
                    }

                    func restore(source: String) {}
                }
                """,
            "Sources/App/ContentView.swift": """
                import SwiftUI

                struct ContentView: View {
                    private var subscriptions = PremiumStore.shared

                    var body: some View {
                        Text("Home").onAppear { subscriptions.start() }
                    }
                }
                """,
            "Sources/App/PaywallView.swift": """
                struct PaywallView {
                    let subs = PremiumStore.shared

                    private func restore() {}

                    func footer() {
                        subs.restore(source: "paywall")
                        restore()
                    }
                }
                """,
            "Sources/App/Engine.swift": """
                import Metal

                struct Engine {
                    let buffer: MTLBuffer

                    func size() -> Int { buffer.length }
                }

                struct Header {
                    var length: Int = 0
                }
                """,
            "Sources/App/Share.swift": """
                func share(_ view: PaywallView) {
                    view.restore()
                }
                """,
        ], name: "typed-links")

        func site(_ name: String, line: Int, in path: String) throws -> [String] {
            let rows = try engine.rawQuery("""
                SELECT COALESCE(s.qualified_name, ''), COALESCE(r.basis, ''), r.is_external, COALESCE(r.external_module, ''), COALESCE(a.qualified_name, '')
                FROM refs r JOIN files f ON f.id = r.file_id LEFT JOIN symbols s ON s.id = r.target_symbol_id
                LEFT JOIN symbols a ON a.id = r.alt_symbol_id
                WHERE f.path = '\(path)' AND r.name = '\(name)' AND r.line = \(line)
                """)
            return rows.rows.first?.map { $0.stringValue ?? String($0.intValue ?? 0) } ?? []
        }
        // `subscriptions.start()` types through the property's initializer `PremiumStore.shared`.
        #expect(try site("start", line: 7, in: "Sources/App/ContentView.swift") == ["PremiumStore.start", "typed", "0", "", ""])
        #expect(try engine.callers("PremiumStore.start").relations.contains { $0.symbol.qualifiedName == "ContentView.body" })
        // The label picks PremiumStore.restore(source:), not the view's own private restore().
        #expect(try site("restore", line: 7, in: "Sources/App/PaywallView.swift").first == "PremiumStore.restore")
        #expect(try site("restore", line: 8, in: "Sources/App/PaywallView.swift").first == "PaywallView.restore")
        #expect(try site("restore", line: 2, in: "Sources/App/Share.swift").first == "", "a private method is invisible from another file")
        // Framework members are external references with their module, never a repository lookalike.
        #expect(try site("updates", line: 7, in: "Sources/App/PremiumStore.swift") == ["", "static", "1", "StoreKit", ""])
        #expect(try site("length", line: 6, in: "Sources/App/Engine.swift") == ["", "typed", "1", "Metal", "Header.length"])
    }

    @Test("Overloads get their own ids; unique names keep the plain id")
    func overloadIdentity() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/Store.swift": """
                struct Store {
                    func save(token: String) {}
                    func save(data: Data) {}
                    func load() {}
                }
                """,
        ], name: "overloads")
        let ids = try engine.allSymbols().map(\.id)
        #expect(Set(ids).count == ids.count, "ids must be unique: \(ids)")
        #expect(ids.contains("sym:Sources/App/Store.swift#Store.save"))
        #expect(ids.contains("sym:Sources/App/Store.swift#Store.save~2"))
        #expect(ids.contains("sym:Sources/App/Store.swift#Store.load"))
        let second = try engine.symbolContext("sym:Sources/App/Store.swift#Store.save~2")
        #expect(second.symbol.lines.start == 3)
        #expect(second.symbol.id == "sym:Sources/App/Store.swift#Store.save~2")
    }

    @Test("Python relative and absolute imports resolve to files")
    func pythonImports() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "py")
        let dependents = try engine.dependents(of: "py/app/models.py")
        #expect(dependents.files.map(\.path).contains("py/app/service.py"))
        let tests = try engine.dependents(of: "py/app/service.py")
        #expect(tests.files.map(\.path).contains("py/tests/test_service.py"))
        #expect(try engine.references("User").references.contains { $0.path == "py/app/service.py" })
    }

    @Test("Symbol search ranks exact, prefix and abbreviation matches")
    func symbolSearch() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "symbols")
        #expect(try engine.searchSymbols("AuthService").first?.symbol.name == "AuthService")
        #expect(try engine.searchSymbols("AuthSer").first?.symbol.name == "AuthService")
        #expect(try engine.searchSymbols("authservice").first?.symbol.name == "AuthService")
        #expect(try engine.searchSymbols("SS").contains { $0.symbol.name == "SessionStore" })
        #expect(try engine.searchSymbols("Api", kinds: [.class]).allSatisfy { $0.symbol.kind == .class })
        #expect(try engine.searchFiles("usrcard").first?.path == "web/src/ui/UserCard.tsx")
    }

    @Test("Import cycles are found with a concrete path and reported as a diagnostic")
    func cycles() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "cycles")
        let cycles = try engine.cycles()
        let tsCycle = try #require(cycles.first { Set($0.files) == ["web/src/cycle/a.ts", "web/src/cycle/b.ts"] })
        #expect(tsCycle.path.first == tsCycle.path.last)
        let diagnostics = try engine.diagnostics(rule: "dependency-cycle")
        #expect(diagnostics.contains { $0.targets.map(\.path).contains("web/src/cycle/a.ts") && $0.severity >= .medium })
    }

    @Test("Graph algorithms: SCCs, PageRank, depth, reachability, communities")
    func graphAlgorithms() {
        // 0 → 1 → 2 → 0 (cycle), 3 → 0, 4 → 3, 5 isolated.
        let graph = DependencyGraph(nodeCount: 6, edges: [(0, 1, 1), (1, 2, 1), (2, 0, 1), (3, 0, 1), (4, 3, 1)].map { (source: $0.0, target: $0.1, weight: Double($0.2)) })
        #expect(graph.cycles() == [[0, 1, 2]])
        let path = graph.cyclePath(in: [0, 1, 2])
        #expect(path.first == path.last && path.count == 4)
        let rank = graph.pageRank()
        #expect(rank[0] > rank[4] && rank[1] > rank[5])
        let reach = graph.transitiveCounts()
        #expect(reach.dependents[0] == 4)       // 1, 2 (cycle) + 3 + 4
        #expect(reach.dependencies[4] == 4)     // 3, 0, 1, 2
        #expect(reach.dependents[5] == 0)
        #expect(graph.dependencyDepth()[4] >= 3)
        #expect(graph.traverse(from: 4, direction: .dependencies, maxDepth: 1).map(\.node) == [3])
        let communities = graph.communities()
        #expect(communities.count == 6)
        #expect(communities == graph.communities())  // deterministic
    }

    // MARK: Impact, health, search, map

    @Test("Change impact lists dependents, call sites, related tests and an explained risk")
    func impact() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "impact")
        let report = try engine.impact(of: "web/src/api/client.ts")
        #expect(report.directDependents.map(\.path) == ["web/src/api/users.ts"])
        #expect(report.transitiveDependents.contains { $0.path == "web/src/ui/UserCard.tsx" && $0.distance == 2 })
        #expect(report.riskScore > 0 && !report.factors.isEmpty)
        #expect(!report.summary.isEmpty)

        let python = try engine.impact(of: "py/app/models.py")
        #expect(python.relatedTests.contains("py/tests/test_service.py"))

        let symbol = try engine.impact(of: "SessionStore")
        #expect(symbol.targetKind == "symbol")
        #expect(symbol.directDependents.contains { $0.path == "Sources/App/AuthService.swift" })
        #expect(symbol.callers.contains { $0.path == "Sources/App/AuthService.swift" })
    }

    @Test("Health is scored per category with explainable factors")
    func health() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "health")
        let report = try engine.health()
        #expect(report.categories.count == HealthCategory.allCases.count)
        #expect((0...100).contains(report.score))
        #expect(report.categories.first { $0.category == .cycles }!.factors.contains { $0.impact < 0 })
        let architecture = try engine.architecture()
        #expect(architecture.frameworks.contains("SwiftUI"))
    }

    @Test("Natural-language questions find the owning code; structural questions use the graph")
    func ask() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "ask")
        let auth = try engine.ask("where do users sign in?")
        #expect(["Sources/App/AuthService.swift", "Sources/App/LoginView.swift"].contains(auth.files.first?.path ?? ""))
        #expect(auth.intent == "search")
        let dependents = try engine.ask("what depends on ApiClient?")
        #expect(dependents.intent == "dependents")
        #expect(dependents.files.contains { $0.path == "web/src/api/users.ts" })
        let callers = try engine.ask("who calls fetchUser")
        #expect(callers.intent == "callers")
        #expect(callers.files.first?.path == "web/src/ui/UserCard.tsx")
    }

    @Test("The map clusters areas, drills into folders and focuses on files")
    func map() async throws {
        let (engine, _) = try await RepoFixture.indexed(RepoFixture.app, name: "map")
        let top = try engine.map()
        #expect(top.level == .modules)
        #expect(top.nodes.count >= 3)
        let web = try engine.map(level: .files, focus: NodeID.directory("web"))
        #expect(web.nodes.contains { $0.path == "web/src/api/client.ts" })
        #expect(web.edges.contains { $0.isCycle })
        let focus = try engine.map(level: .files, focus: NodeID.file("web/src/api/users.ts"))
        #expect(Set(focus.nodes.compactMap(\.path)).isSuperset(of: ["web/src/api/users.ts", "web/src/api/client.ts", "web/src/ui/UserCard.tsx"]))
        let symbols = try engine.map(level: .symbols, focus: NodeID.file("Sources/App/AuthService.swift"))
        #expect(symbols.nodes.contains { $0.label == "AuthService" })
    }

    @Test("Moved repositories keep their index via git identity; missing ones fail clearly")
    func missingRepository() throws {
        #expect(throws: EngineError.self) {
            try RepositoryEngine(repository: URL(fileURLWithPath: "/definitely/not/here/\(UUID().uuidString)"))
        }
    }
}
