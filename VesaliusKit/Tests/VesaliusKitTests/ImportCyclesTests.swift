import Foundation
@testable import QueryEngine
import Testing
import VesaliusCore
import VesaliusMCP
@testable import VesaliusRender

/// `dependency_cycles`: cycles on the import graph, per-edge evidence, the load-time verdict, value-only
/// and static-only modes, barrels, the scope stamp, test exclusion and the Swift module graph. The fixtures are
/// real repositories on disk, indexed and queried through the engine and the tool.
@Suite("Import cycles", .serialized)
struct ImportCyclesTests {
    /// Five two-file cycles under web/src, one per behaviour, plus a cycle among test files.
    static let web: [String: String] = [
        // Plain value cycle, used only inside functions; a barrel re-exports both files.
        "web/src/cyc/a.ts": """
            import { b } from "./b";

            export function a(n: number): number {
              return n > 0 ? b(n - 1) : 0;
            }
            """,
        "web/src/cyc/b.ts": """
            import { a } from "./a";

            export function b(n: number): number {
              return n > 0 ? a(n - 1) : 1;
            }
            """,
        "web/src/cyc/index.ts": """
            export { a } from "./a";
            export { b } from "./b";
            """,
        // Closed only by a type import: no cycle once types are erased.
        "web/src/types/c.ts": """
            import type { Shape } from "./d";

            export const unit = 1;
            export function area(shape: Shape): number {
              return shape.size * unit;
            }
            """,
        "web/src/types/d.ts": """
            import { unit } from "./c";

            export interface Shape {
              size: number;
            }
            export function double(): number {
              return unit * 2;
            }
            """,
        // Closed only by a dynamic import: no cycle on static edges.
        "web/src/lazy/e.ts": """
            export async function load(): Promise<number> {
              const { f } = await import("./f");
              return f();
            }
            export const base = 3;
            """,
        "web/src/lazy/f.ts": """
            import { base } from "./e";

            export function f(): number {
              return base + 1;
            }
            """,
        // An imported function called at module top level.
        "web/src/eager/g.ts": """
            import { h } from "./h";
            export const value = h();
            """,
        "web/src/eager/h.ts": """
            import { value } from "./g";

            export function h(): number {
              return 1;
            }
            export function show(): number {
              return value;
            }
            """,
        // An imported function called by a local function that runs at top level.
        "web/src/boot/p.ts": """
            import { q } from "./q";

            function setup(): number {
              return q();
            }
            export const ready = setup();
            """,
        "web/src/boot/q.ts": """
            import { ready } from "./p";

            export function q(): number {
              return 2;
            }
            export function check(): boolean {
              return ready > 0;
            }
            """,
        // Tests: a cycle of their own, an import into src and a mock that is never an edge.
        "web/tests/helper.ts": """
            import { fixture } from "./cycle.test";

            export function helper(): number {
              return fixture;
            }
            """,
        "web/tests/cycle.test.ts": """
            import { helper } from "./helper";
            import { a } from "../src/cyc/a";

            vi.mock("../src/cyc/b");
            export const fixture = 1;
            test("cycle", () => {
              helper();
              a(1);
            });
            """,
    ]

    private func cycle(_ report: ImportCycleReport, containing path: String) throws -> ImportCycle {
        try #require(report.cycles.first { $0.files.contains(path) }, "no cycle through \(path)")
    }

    @Test("Cycles come from imports only, with statements, uses, definitions, modes, barrels and a scope stamp")
    func typeScriptCycles() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.web, name: "cycles-ts")
        let report = try engine.importCycles(path: "web/src/")

        let scope = report.scope
        #expect(scope.path == "web/src" && !scope.isFile && !scope.includeTests)
        #expect(scope.files == 11 && scope.testFilesExcluded == 0)
        #expect(scope.edges == 12 && scope.unresolved == 0 && scope.leavingScope == 0)
        #expect(scope.typeOnly == 1 && scope.reexports == 2 && scope.dynamic == 1 && scope.sideEffect == 0 && scope.mocks == 0)
        #expect(report.cycles.map(\.files) == [
            ["web/src/boot/p.ts", "web/src/boot/q.ts"], ["web/src/cyc/a.ts", "web/src/cyc/b.ts"], ["web/src/eager/g.ts", "web/src/eager/h.ts"],
            ["web/src/lazy/e.ts", "web/src/lazy/f.ts"], ["web/src/types/c.ts", "web/src/types/d.ts"],
        ])
        #expect(report.crossingCycles == 0 && report.swiftModules == nil && report.staleFiles.isEmpty)

        // The plain cycle: both statements, where each import is used and declared; safe; a barrel outside it.
        let plain = try cycle(report, containing: "web/src/cyc/a.ts")
        #expect(plain.path == ["web/src/cyc/a.ts", "web/src/cyc/b.ts", "web/src/cyc/a.ts"])
        #expect(plain.edges.map { "\($0.from):\($0.line) \($0.statement ?? "-")" } == [
            "web/src/cyc/a.ts:1 import { b } from \"./b\";", "web/src/cyc/b.ts:1 import { a } from \"./a\";",
        ])
        let first = plain.edges[0]
        #expect(first.isValue && !first.isTypeOnly && !first.isDynamic)
        #expect(first.uses.map { "\($0.name):\($0.line) \($0.enclosing ?? "top") \($0.atLoad)" } == ["b:4 a false"])
        #expect(first.definitions == [ImportDefinition(name: "b", line: 3)])
        #expect(plain.isLoadTimeSafe)
        #expect(plain.valueOnly == [plain.files] && plain.staticOnly == [plain.files])
        #expect(plain.barrels == [ImportBarrel(path: "web/src/cyc/index.ts", members: plain.files, lines: [1, 2])])

        // Closed by `import type`: the cycle is gone on value-only edges.
        let typed = try cycle(report, containing: "web/src/types/c.ts")
        #expect(typed.edges.first { $0.from.hasSuffix("c.ts") }?.isTypeOnly == true)
        #expect(typed.valueOnly.isEmpty && typed.staticOnly.isEmpty)

        // Closed by `await import()`: the same on value edges, gone on static ones.
        let lazy = try cycle(report, containing: "web/src/lazy/e.ts")
        let dynamic = try #require(lazy.edges.first { $0.from.hasSuffix("e.ts") })
        #expect(dynamic.isDynamic && dynamic.isValue && dynamic.line == 2)
        #expect(dynamic.uses.map(\.line) == [3])
        #expect(lazy.valueOnly == [lazy.files] && lazy.staticOnly.isEmpty)

        // Load time: a call at top level, and a call inside a local function that top-level code runs.
        let eager = try cycle(report, containing: "web/src/eager/g.ts")
        #expect(eager.loadTimeUses == [ImportLoadUse(path: "web/src/eager/g.ts", line: 2, name: "h", enclosing: "value")])
        let boot = try cycle(report, containing: "web/src/boot/p.ts")
        #expect(boot.loadTimeUses.map { "\($0.path):\($0.line) \($0.name) in \($0.enclosing ?? "-") via \($0.via ?? "-")" } == ["web/src/boot/p.ts:4 q in setup via setup"])
    }

    @Test("Test files and mocks: left out by default, test cycles listed with include_tests, mocks never edges")
    func testsAndMocks() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.web, name: "cycles-tests")
        let without = try engine.importCycles()
        #expect(without.scope.path == nil && without.scope.testFilesExcluded == 2)
        #expect(!without.cycles.contains { $0.files.contains { $0.hasPrefix("web/tests/") } })

        let with = try engine.importCycles(includeTests: true)
        #expect(with.scope.includeTests && with.scope.testFilesExcluded == 0 && with.scope.mocks == 1)
        #expect(with.scope.edges == without.scope.edges + 3)
        #expect(with.cycles.contains { $0.files == ["web/tests/cycle.test.ts", "web/tests/helper.ts"] })
        // The mocked b.ts gains no importer: its cycle is unchanged.
        #expect(try cycle(with, containing: "web/src/cyc/b.ts").edges.count == 2)
    }

    @Test("A file path keeps the cycles through it; a folder suffix names the folder; unknown paths fail")
    func scopes() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.web, name: "cycles-scope")
        let file = try engine.importCycles(path: "web/src/eager/h.ts")
        #expect(file.scope.isFile && file.scope.path == "web/src/eager/h.ts")
        #expect(file.cycles.map(\.files) == [["web/src/eager/g.ts", "web/src/eager/h.ts"]])

        let folder = try engine.importCycles(path: "./lazy")
        #expect(folder.scope.path == "web/src/lazy" && folder.cycles.count == 1)

        let cyc = try engine.importCycles(path: "web/src/cyc/")
        #expect(cyc.cycles.count == 1 && cyc.scope.files == 3 && cyc.scope.edges == 4 && cyc.scope.leavingScope == 0)

        #expect(throws: EngineError.self) { try engine.importCycles(path: "nowhere/") }
    }

    @Test("A class instantiated at load runs its field initializers; imports used only as types are elided")
    func instantiationAndElision() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "src/klass/k.ts": """
                import { m } from "./m";

                class Holder {
                  value = m();
                }
                export const holder = new Holder();
                """,
            "src/klass/m.ts": """
                import { holder } from "./k";

                export function m(): number {
                  return 1;
                }
                export function read(): unknown {
                  return holder;
                }
                """,
            // `Options` is an interface: TypeScript drops the import without `type`, so no runtime cycle.
            "src/elide/x.ts": """
                import { Options } from "./y";

                export function make(options: Options): number {
                  return options.size;
                }
                """,
            "src/elide/y.ts": """
                import { make } from "./x";

                export interface Options {
                  size: number;
                }
                export const made = (): number => make({ size: 1 });
                """,
        ], name: "cycles-class")
        let report = try engine.importCycles(path: "src")
        let klass = try cycle(report, containing: "src/klass/k.ts")
        #expect(klass.loadTimeUses.map { "\($0.path):\($0.line) \($0.name) in \($0.enclosing ?? "-") via \($0.via ?? "-")" } == ["src/klass/k.ts:4 m in Holder.value via Holder"])

        let elided = try cycle(report, containing: "src/elide/x.ts")
        let typesOnly = try #require(elided.edges.first { $0.from == "src/elide/x.ts" })
        #expect(!typesOnly.isTypeOnly && !typesOnly.isValue)
        #expect(elided.valueOnly.isEmpty && elided.isLoadTimeSafe)
        let text = CyclesRenderer.render(report, budget: .cycles)
        #expect(text.contains("  x.ts:1  import { Options } from \"./y\"  types only, elided at runtime · defined y.ts:3"))
        #expect(text.contains("k.ts:4 m in Holder.value, called at load via Holder"))
    }

    @Test("Python: module-level `from … import` in a cycle is a load-time hazard")
    func pythonFromImports() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "py/pkg/__init__.py": "",
            "py/pkg/a.py": """
                from .b import g


                def f():
                    return g()
                """,
            "py/pkg/b.py": """
                from .a import f


                def g():
                    return 1


                def h():
                    return f()
                """,
        ], name: "cycles-py")
        let report = try engine.importCycles()
        let cycle = try #require(report.cycles.first)
        #expect(cycle.files == ["py/pkg/a.py", "py/pkg/b.py"])
        #expect(cycle.edges.map(\.isValue) == [true, true])
        #expect(cycle.loadTimeUses.filter(\.isFromImport).map { "\($0.path):\($0.line) \($0.name)" } == ["py/pkg/a.py:1 g", "py/pkg/b.py:1 f"])
    }

    @Test("Swift: the module import graph from build targets, with module cycles and their import lines")
    func swiftModules() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription

                let package = Package(
                    name: "Kit",
                    targets: [
                        .target(name: "Core"),
                        .target(name: "UI", dependencies: ["Core"]),
                        .target(name: "Tools", dependencies: ["Core"]),
                    ]
                )
                """,
            "Sources/Core/Core.swift": "import Foundation\nimport UI\n\npublic struct Core {}\n",
            "Sources/UI/Screen.swift": "import Core\n\nstruct Screen {\n    let core = Core()\n}\n",
            "Sources/Tools/Tool.swift": "import Core\n\nstruct Tool {}\n",
        ], name: "cycles-swift")
        let report = try engine.importCycles()
        #expect(report.cycles.isEmpty && report.scope.edges == 0)
        let swift = try #require(report.swiftModules)
        #expect(swift.modules == 3 && swift.dependencies == 3 && swift.importLines == 3)
        #expect(swift.cycles == [["Core", "UI"]])
        #expect(swift.cycleImports.first?.map { "\($0.path):\($0.line) \($0.module)" } == ["Sources/Core/Core.swift:2 UI", "Sources/UI/Screen.swift:1 Core"])

        let text = CyclesRenderer.render(report, budget: .cycles)
        #expect(text.contains("Swift: 1 module import cycle among 3 modules (3 module dependencies from 3 import lines)"))
        #expect(text.contains("  module cycle: Core ↔ UI · Sources/Core/Core.swift:2 import UI · Sources/UI/Screen.swift:1 import Core"))
        #expect(text.hasSuffix("no other strongly connected component in scope"))
    }

    @Test("The tool's text: the stamp, each import with its use and definition, verdicts, and the closing line")
    func toolText() async throws {
        let (engine, root) = try await RepoFixture.indexed(Self.web, name: "cycles-tool")
        let context = ToolContext(engine: engine) {
            let summary = try await engine.index(options: RepoFixture.fastOptions)
            return summary.filesAdded + summary.filesChanged + summary.filesRemoved
        }
        let output = await MCPToolCatalog.execute(DependencyCyclesTool(), arguments: ["path": .string("web/src/")], context: context)
        #expect(!output.isError)
        let lines = output.text.components(separatedBy: "\n")
        #expect(lines.first == "5 import cycles under web/src/: scanned 11 files, 12 import edges, 0 unresolved (1 type-only, 2 re-export, 1 dynamic counted); tests excluded")
        #expect(lines.contains("cycle 2: web/src/cyc/a.ts ↔ b.ts"))
        #expect(lines.contains("  a.ts:1  import { b } from \"./b\"  value · used :4 in a() · defined b.ts:3"))
        #expect(lines.contains("  load-time safe (no imported binding used at module top level) · same on value-only and static-only edges · cyc/index.ts re-exports both, not in cycle"))
        #expect(lines.contains { $0.hasPrefix("  load-time unsafe, an imported binding is used while the modules load: g.ts:2 h at load, in value ·") })
        #expect(lines.contains { $0.hasPrefix("  load-time unsafe, an imported binding is used while the modules load: p.ts:4 q in setup, called at load ·") })
        #expect(lines.contains("  p.ts:1  import { q } from \"./q\"  value · used :4 in setup(), called at load · defined q.ts:3"))
        #expect(lines.contains { $0.contains("same on value-only edges · no cycle on static-only edges (a dynamic import closes it)") })
        #expect(lines.contains { $0.contains("no cycle on value-only edges (type imports close it; they are erased at runtime)") })
        #expect(lines.last == "no other strongly connected component in scope")
        #expect(TokenEstimate.of(output.text) <= Budget.cycles.tokens)

        // Editing a cycle file after indexing: the dispatcher re-indexes once and says so.
        try RepoFixture.write("import { b } from \"./b\";\n\n// moved\nexport function a(n: number): number {\n  return n > 0 ? b(n - 1) : 0;\n}\n", to: "web/src/cyc/a.ts", in: root)
        let fresh = await MCPToolCatalog.execute(DependencyCyclesTool(), arguments: ["path": .string("web/src/")], context: context)
        #expect(fresh.text.hasPrefix("re-indexed 1 file\n"))
        #expect(fresh.text.contains("  a.ts:1  import { b } from \"./b\"  value · used :5 in a() · defined b.ts:3"))

        let missing = await MCPToolCatalog.execute(DependencyCyclesTool(), arguments: ["path": .string("nowhere/")], context: context)
        #expect(missing.isError && missing.text.hasPrefix("Nothing in the index matches “nowhere/”"))
    }

    // MARK: Rendering

    /// A synthetic cycle `<folder>/a<n>.ts ↔ b<n>.ts` with two value imports.
    private static func syntheticCycle(_ id: Int, folder: String) -> ImportCycle {
        let a = "\(folder)/a\(id).ts", b = "\(folder)/b\(id).ts"
        func edge(_ from: String, _ to: String, _ name: String) -> ImportCycleEdge {
            ImportCycleEdge(from: from, to: to, line: 1, endLine: 1, statement: "import { \(name) } from \"./\((to as NSString).deletingPathExtension.split(separator: "/").last ?? "")\";",
                            module: "./x", names: [ImportedName(name: name)], isTypeOnly: false, isReexport: false, isDynamic: false, isSideEffect: false, isValue: true,
                            uses: [ImportUse(name: name, line: 12, kind: .call, enclosing: "run", enclosingIsCallable: true, atLoad: false)],
                            definitions: [ImportDefinition(name: name, line: 3)])
        }
        return ImportCycle(id: id, files: [a, b], path: [a, b, a], edges: [edge(a, b, "beta\(id)"), edge(b, a, "alpha\(id)")],
                           valueOnly: [[a, b]], staticOnly: [[a, b]])
    }

    @Test("Over budget, cycles lose detail in order; the stamp and closing line always stay")
    func budget() throws {
        func report(_ count: Int) -> ImportCycleReport {
            let cycles = (1...count).map { Self.syntheticCycle($0, folder: $0 <= count * 3 / 4 ? "src/one" : "src/two") }
            return ImportCycleReport(scope: ImportCycleScope(path: "src", includeTests: false, files: 2 * count, testFilesExcluded: 0, edges: 2 * count, unresolved: 0), cycles: cycles)
        }
        let full = CyclesRenderer.render(report(40), budget: .unlimited)
        #expect(full.components(separatedBy: "\n").count == 1 + 40 * 4 + 1)

        // The first cycles keep their imports; the others keep their first line and the call that details them.
        let small = CyclesRenderer.render(report(12), budget: Budget(tokens: 600))
        let lines = small.components(separatedBy: "\n")
        #expect(TokenEstimate.of(small) <= 600)
        #expect(lines.first?.hasPrefix("12 import cycles under src/: scanned 24 files, 24 import edges, 0 unresolved") == true)
        #expect(lines.last == "no other strongly connected component in scope")
        #expect(lines.contains("cycle 12: src/two/a12.ts ↔ b12.ts · detail: dependency_cycles(path:\"src/two/\")"))
        #expect(lines.contains { $0.hasPrefix("showing ") && $0.hasSuffix(" of 12 cycles in detail; a narrower path shows the others") })
        #expect(lines.contains("  a1.ts:1  import { beta1 } from \"./b1\"  value · used :12 in run()"))

        // Then only some first lines fit: the rest are counted by folder, with the call for the biggest group.
        let tiny = CyclesRenderer.render(report(40), budget: Budget(tokens: 150))
        #expect(TokenEstimate.of(tiny) <= 150)
        #expect(tiny.hasPrefix("40 import cycles under src/"))
        #expect(tiny.contains("the others by folder: src/one/ "))
        #expect(tiny.contains("more: dependency_cycles(path:\"src/one/\")"))
        #expect(tiny.hasSuffix("no other strongly connected component in scope"))
    }

    @Test("Long import statements keep the module they name; generic file names keep their folder")
    func shortening() {
        let long = "import { ORDERS_TTL, ORDER_DETAIL_TTL, deriveOrderStatus, type Invoice, type Payment, type Supplier, type InvoiceDetail } from \"./types\""
        let fitted = CyclesRenderer.fit(long, limit: 90)
        #expect(fitted.count <= 90)
        #expect(fitted == "import { ORDERS_TTL, ORDER_DETAIL_TTL, deriveOrderStatus, type Invoice, … } from \"./types\"")
        let names = CyclesRenderer.Names(Self.syntheticCycle(1, folder: "src/lib/billing/orders"))
        #expect(names.short("src/lib/billing/orders/refunds.ts") == "refunds.ts")
        #expect(names.short("src/lib/money.ts") == "src/lib/money.ts")
        #expect(names.barrel("src/lib/billing/orders/index.ts") == "orders/index.ts")
        #expect(CyclesRenderer.commonFolder(["src/a/x.ts", "src/a/b/y.ts", "src/c.ts"]) == "src")
    }
}
