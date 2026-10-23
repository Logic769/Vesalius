import Foundation
import RepositoryIndex
import Testing
import VesaliusCore
@testable import LanguageAnalysis

private func analyze(_ source: String, path: String = "src/module.ts") throws -> FileAnalysis {
    let language: Language = path.hasSuffix(".ts") || path.hasSuffix(".tsx") || path.hasSuffix(".mts") ? .typescript : .javascript
    return try TypeScriptAnalyzer().analyze(SourceFile(path: path, language: language, text: source))
}

private extension FileAnalysis {
    func symbol(_ name: String, _ kind: SymbolKind? = nil) -> ExtractedSymbol? {
        symbols.first { $0.name == name && (kind == nil || $0.kind == kind) }
    }

    func references(named name: String) -> [ExtractedReference] {
        references.filter { $0.name == name }
    }

    func hasReference(_ name: String, _ kind: ReferenceKind, receiver: String? = nil) -> Bool {
        references.contains { $0.name == name && $0.kind == kind && $0.receiver == receiver }
    }

    func importFor(_ module: String) -> ExtractedImport? {
        imports.first { $0.module == module }
    }

    func reference(_ name: String, line: Int) -> ExtractedReference? {
        references.first { $0.name == name && $0.line == line }
    }

    func enclosingName(_ reference: ExtractedReference) -> String? {
        reference.enclosingSymbol.map { symbols[$0].name }
    }
}

private func describe(_ names: [ImportedName]) -> [String] {
    names.map { name in name.alias.map { "\(name.name) as \($0)" } ?? name.name }
}

@Suite("TypeScript / JavaScript analyzer")
struct TypeScriptAnalyzerTests {
    @Test func reactComponentWithHooksAndImports() throws {
        let source = """
        import React, { useState, useEffect as useMountEffect } from "react";
        import * as api from "../api/client";
        import type { User } from "../models/user";
        import { Button } from "@/components/Button";
        import "./profile.css";

        /** Shows a user's profile card. */
        export function ProfileCard({ userId }: { userId: string }) {
          const [user, setUser] = useState<User | null>(null);
          useMountEffect(() => {
            api.fetchUser(userId).then(setUser);
          }, [userId]);
          if (!user) {
            return <Spinner />;
          }
          return (
            <div className="card">
              <Avatar user={user} />
              <Button onClick={() => api.logout()}>Log out</Button>
            </div>
          );
        }

        export const Spinner = () => <div className="spinner" />;

        const Avatar = React.memo(({ user }: { user: User }) => <img src={user.avatarURL} />);

        export default ProfileCard;
        """
        let analysis = try analyze(source, path: "src/profile/ProfileCard.tsx")

        let card = try #require(analysis.symbol("ProfileCard"))
        #expect(card.kind == .component)
        #expect(card.isExported)
        #expect(card.doc == "Shows a user's profile card.")
        #expect(card.range == LineRange(8, 22))
        #expect(card.signature == "function ProfileCard({ userId }: { userId: string })")
        #expect(card.complexity == 2)
        #expect(analysis.symbol("Spinner")?.kind == .component)
        #expect(analysis.symbol("Spinner")?.isExported == true)
        #expect(analysis.symbol("Avatar")?.kind == .component, "React.memo-wrapped arrow functions are components")
        #expect(analysis.symbol("Avatar")?.isExported == false)

        #expect(describe(try #require(analysis.importFor("react")).names) == ["default as React", "useState", "useEffect as useMountEffect"])
        #expect(analysis.importFor("react")?.kind == .module)
        #expect(describe(try #require(analysis.importFor("../api/client")).names) == ["* as api"])
        #expect(analysis.importFor("../api/client")?.kind == .relative)
        #expect(analysis.importFor("../models/user")?.isTypeOnly == true)
        #expect(analysis.importFor("@/components/Button")?.kind == .module)
        #expect(analysis.importFor("./profile.css")?.names.isEmpty == true)
        #expect(analysis.exportedNames == ["default=ProfileCard"])

        #expect(analysis.hasReference("useState", .call))
        #expect(analysis.hasReference("useMountEffect", .call))
        #expect(analysis.hasReference("fetchUser", .call, receiver: "api"))
        #expect(analysis.hasReference("logout", .call, receiver: "api"))
        #expect(analysis.hasReference("User", .typeUse))
        #expect(analysis.hasReference("Spinner", .instantiate))
        #expect(analysis.hasReference("Avatar", .instantiate))
        #expect(analysis.hasReference("Button", .instantiate))
        #expect(analysis.hasReference("memo", .call, receiver: "React"))
        // Locals, parameters and intrinsic elements are not references.
        for local in ["user", "setUser", "userId", "div", "img", "then"] {
            #expect(analysis.references(named: local).isEmpty, "\(local) should not be a reference")
        }
        let fetch = try #require(analysis.references(named: "fetchUser").first)
        #expect(analysis.enclosingName(fetch) == "ProfileCard")
        #expect(fetch.line == 11)
    }

    @Test func classHeritageDecoratorsAndParameterProperties() throws {
        let source = """
        import { Injectable } from "@angular/core";
        import { BaseService } from "./base";

        @Injectable({ providedIn: "root" })
        export class AccountService extends BaseService implements Repository<Account>, ns.Auditable {
          private cache = new Map<string, Account>();
          #token?: string;

          constructor(private readonly http: HttpClient, public logger: Logger, plain: number) {
            super();
          }

          /** Finds an account by id. */
          async find(id: string): Promise<Account> {
            if (this.cache.has(id)) {
              return this.cache.get(id)!;
            }
            const account = await this.http.get<Account>(`/accounts/${id}`);
            this.logger.info("loaded");
            return account;
          }

          static create(): AccountService {
            return new AccountService(new HttpClient(), defaultLogger);
          }

          protected get size(): number { return this.cache.size; }

          handleClick = () => { this.find("x"); };
        }

        export abstract class Shape { abstract area(): number; }
        """
        let analysis = try analyze(source, path: "src/account.service.ts")

        let service = try #require(analysis.symbol("AccountService", .class))
        #expect(service.isExported)
        #expect(service.attributes.contains("@Injectable"))
        #expect(service.inheritedTypes == ["BaseService", "Repository", "Auditable"])
        #expect(service.range.start == 4, "the range starts at the decorator")
        #expect(analysis.hasReference("BaseService", .inherit))
        #expect(analysis.hasReference("Repository", .conform))
        #expect(analysis.hasReference("Auditable", .conform, receiver: "ns"))
        #expect(analysis.hasReference("Injectable", .decorator))
        #expect(analysis.hasReference("Account", .typeUse))

        let members = analysis.symbols.filter { $0.parentLocalID == service.localID }
        #expect(members.map(\.name) == ["cache", "#token", "constructor", "http", "logger", "find", "create", "size", "handleClick"])
        #expect(analysis.symbol("cache")?.visibility == .private)
        #expect(analysis.symbol("#token")?.visibility == .private)
        #expect(analysis.symbol("constructor")?.kind == .initializer)
        #expect(analysis.symbol("http")?.kind == .property, "constructor parameter properties declare members")
        #expect(analysis.symbol("http")?.attributes == ["readonly"])
        #expect(analysis.symbol("logger")?.visibility == .public)
        #expect(analysis.symbol("plain") == nil)
        let find = try #require(analysis.symbol("find", .method))
        #expect(find.attributes == ["async"])
        #expect(find.doc == "Finds an account by id.")
        #expect(find.signature == "async find(id: string): Promise<Account>")
        #expect(find.complexity == 2)
        #expect(analysis.symbol("create")?.attributes == ["static"])
        #expect(analysis.symbol("size")?.attributes == ["get"])
        #expect(analysis.symbol("size")?.visibility == .internal)
        #expect(analysis.symbol("handleClick")?.kind == .method)
        #expect(analysis.symbol("Shape")?.attributes == ["abstract"])
        #expect(analysis.symbol("area")?.kind == .method)

        #expect(analysis.hasReference("get", .call, receiver: "this.http"), "await + generic member calls are calls")
        #expect(analysis.hasReference("info", .call, receiver: "this.logger"))
        #expect(analysis.hasReference("AccountService", .instantiate))
        #expect(analysis.hasReference("HttpClient", .instantiate))
        #expect(analysis.hasReference("defaultLogger", .read))
        #expect(analysis.hasReference("find", .call, receiver: "this"))
        #expect(analysis.hasReference("cache", .read, receiver: "this"))
        #expect(analysis.references(named: "Map").isEmpty, "built-ins are skipped")
        #expect(analysis.references(named: "id").isEmpty)
        #expect(analysis.references(named: "account").isEmpty)
    }

    @Test func interfacesEnumsAliasesAndNamespaces() throws {
        let source = """
        export interface Repository<T> extends Disposable, Base.Readable {
          find(id: string): Promise<T>;
          readonly count: number;
          [key: string]: unknown;
        }

        export enum Status { Active = "active", Inactive, "Legacy-Mode" }

        export type UserMap<K> = Map<K, Account> | { [P in keyof Settings]: Toggle };

        export namespace Geometry {
          export function area(shape: Shape): number { return shape.w * shape.h; }
          export const unit = "px";
        }
        """
        let analysis = try analyze(source)

        let repository = try #require(analysis.symbol("Repository", .interface))
        #expect(repository.inheritedTypes == ["Disposable", "Readable"])
        #expect(analysis.hasReference("Disposable", .inherit))
        #expect(analysis.hasReference("Readable", .inherit, receiver: "Base"))
        #expect(analysis.symbol("find")?.parentLocalID == repository.localID)
        #expect(analysis.symbol("count")?.kind == .property)
        #expect(analysis.references(named: "T").isEmpty, "type parameters are not references")
        #expect(analysis.references(named: "key").isEmpty)

        let status = try #require(analysis.symbol("Status", .enum))
        #expect(analysis.symbols.filter { $0.parentLocalID == status.localID }.map(\.name) == ["Active", "Inactive", "Legacy-Mode"])
        #expect(analysis.symbols.filter { $0.parentLocalID == status.localID }.allSatisfy { $0.kind == .enumCase })

        #expect(analysis.symbol("UserMap")?.kind == .typeAlias)
        #expect(analysis.hasReference("Account", .typeUse))
        #expect(analysis.hasReference("Settings", .typeUse))
        #expect(analysis.hasReference("Toggle", .typeUse))
        #expect(analysis.references(named: "K").isEmpty)
        #expect(analysis.references(named: "P").isEmpty)

        let geometry = try #require(analysis.symbol("Geometry", .namespace))
        #expect(geometry.isExported)
        let area = try #require(analysis.symbol("area"))
        #expect(area.parentLocalID == geometry.localID)
        #expect(area.isExported)
        #expect(analysis.symbol("unit")?.kind == .constant)
        #expect(analysis.symbol("unit")?.parentLocalID == geometry.localID)
        #expect(analysis.hasReference("Shape", .typeUse))
    }

    @Test func reExportsAndBarrelFiles() throws {
        let source = """
        export * from "./auth";
        export * as payments from "./payments";
        export { login, logout as signOut } from "./session";
        export { default as Button } from "./Button";
        export type { Props } from "./types";
        import { helper } from "./helper";
        const local = 1;
        export { local, helper as assist };
        """
        let analysis = try analyze(source, path: "src/index.ts")
        let reExports = analysis.imports.filter(\.isReExport)
        #expect(reExports.map(\.module) == ["./auth", "./payments", "./session", "./Button", "./types"])
        #expect(describe(try #require(analysis.importFor("./auth")).names) == ["*"])
        #expect(describe(try #require(analysis.importFor("./payments")).names) == ["* as payments"])
        #expect(describe(try #require(analysis.importFor("./session")).names) == ["login", "logout as signOut"])
        #expect(describe(try #require(analysis.importFor("./Button")).names) == ["default as Button"])
        #expect(analysis.importFor("./types")?.isTypeOnly == true)
        #expect(analysis.importFor("./helper")?.isReExport == false)
        #expect(analysis.exportedNames == ["local=local", "assist=helper"])
        #expect(analysis.syntaxErrorCount == 0)
    }

    @Test func commonJSModules() throws {
        let source = """
        #!/usr/bin/env node
        const path = require("path");
        const { readFile, writeFile: write } = require("fs/promises");
        const helpers = require("./helpers");

        function main(argv) {
          const file = path.resolve(argv[2]);
          return readFile(file).then((data) => helpers.transform(data));
        }

        exports.run = function run() { return main(process.argv); };
        module.exports.version = VERSION;
        module.exports = { main, parse: helpers.parse };

        class Legacy extends EventEmitter { handle() { this.emit("x"); } }
        async function lazy() { const mod = await import("./lazy"); return mod; }
        """
        let analysis = try analyze(source, path: "bin/cli.js")
        #expect(analysis.isEntryPoint, "a shebang marks an entry point")
        #expect(describe(try #require(analysis.importFor("path")).names) == ["* as path"])
        #expect(describe(try #require(analysis.importFor("fs/promises")).names) == ["readFile", "writeFile as write"])
        #expect(analysis.importFor("./helpers")?.kind == .relative)
        // `const mod = await import("./lazy")` binds the module like `import * as mod`, loaded when `lazy` runs.
        #expect(describe(try #require(analysis.importFor("./lazy")).names) == ["* as mod"])
        #expect(analysis.importFor("./lazy")?.isDynamic == true)
        #expect(analysis.importFor("path")?.isDynamic == false)
        #expect(analysis.exportedNames == ["run=run", "version=VERSION", "main=main"])
        #expect(analysis.symbol("run")?.isExported == true)
        #expect(analysis.symbol("main")?.kind == .function)
        #expect(analysis.symbol("main")?.isExported == false)
        #expect(analysis.symbol("Legacy")?.inheritedTypes == ["EventEmitter"])
        #expect(analysis.hasReference("EventEmitter", .inherit))
        #expect(analysis.hasReference("resolve", .call, receiver: "path"))
        #expect(analysis.hasReference("transform", .call, receiver: "helpers"))
        #expect(analysis.hasReference("main", .call))
        #expect(analysis.hasReference("emit", .call, receiver: "this"))
        #expect(analysis.references(named: "require").isEmpty)
        #expect(analysis.references(named: "argv").isEmpty)
        #expect(analysis.references(named: "process").isEmpty)
        #expect(analysis.symbols.allSatisfy { $0.kind != .component }, "components are only inferred in JSX files")
        #expect(analysis.syntaxErrorCount == 0)
    }

    @Test func localsAndParametersAreNotReferences() throws {
        let source = """
        import { format } from "./format";
        export function summarize(items: Item[], { limit = DEFAULT_LIMIT, sort }: Options, ...rest: string[]) {
          const seen = new Set<string>();
          let total = 0;
          for (const [key, value] of pairsOf(items)) {
            total += value;
          }
          try {
            render(total);
          } catch (error) {
            report(error);
          }
          function inner(depth) { return depth + total + limit; }
          const arrow = (x) => x * scale;
          return format(inner(1), arrow, sort, rest, seen, key);
        }
        """
        let analysis = try analyze(source)
        let names = Set(analysis.references.map(\.name))
        #expect(names.isSuperset(of: ["Item", "Options", "DEFAULT_LIMIT", "pairsOf", "render", "report", "scale", "format"]))
        for local in ["items", "limit", "sort", "rest", "seen", "total", "value", "error", "inner", "depth", "arrow", "x"] {
            #expect(!names.contains(local), "\(local) is a local binding")
        }
        // `key` is declared by the loop but used outside it: block scoping is approximated per function.
        #expect(analysis.symbol("inner")?.parentLocalID == analysis.symbol("summarize")?.localID)
        #expect(analysis.hasReference("total", .write) == false)
    }

    @Test func complexityCountsDecisionPoints() throws {
        let source = """
        export function route(input: Input): string {
          if (input.a && input.b) { return "ab"; }
          for (const x of input.list) { if (x) { continue; } }
          while (input.next) { input = input.next; }
          switch (input.kind) {
            case "a": return "a";
            case "b": return "b";
            default: break;
          }
          try { risky(); } catch { recover(); }
          return input.c ?? (input.d ? "d" : input.e || "e");
        }
        """
        let analysis = try analyze(source)
        // if, &&, for, if, while, case, case, catch, ??, ternary, || → 11 decision points.
        #expect(analysis.symbol("route")?.complexity == 12)
        #expect(analysis.complexity == 12)
    }

    @Test func duplicateBodiesShareAStructuralHash() throws {
        let source = """
        export function sumA(items: number[]): number {
          let total = 0;
          for (const item of items) {
            total += item;
          }
          return total;
        }

        export function sumB(values: number[]): number {
          // A comment does not change the structure.
          let acc = 100;
          for (const value of values) {
            acc += value;
          }
          return acc;
        }

        export function product(values: number[]): number {
          let acc = 1;
          for (const value of values) {
            acc *= value;
          }
          return acc;
        }

        export function tiny() { return 1; }
        """
        let analysis = try analyze(source)
        let a = try #require(analysis.symbol("sumA")?.bodyHash)
        let b = try #require(analysis.symbol("sumB")?.bodyHash)
        let product = try #require(analysis.symbol("product")?.bodyHash)
        #expect(a == b)
        #expect(a != product)
        #expect(analysis.symbol("tiny")?.bodyHash == nil, "bodies under five lines are not hashed")
    }

    @Test func malformedInputIsRecoveredNotThrown() throws {
        // Errors inside a balanced body: everything around them is still recovered.
        let recoverable = """
        export class Broken {
          method() {
            const x = ;
            callSomething(;
          }
        }
        function ok(): number { return 1 }
        export const fine = 2;
        """
        let analysis = try analyze(recoverable)
        #expect(analysis.syntaxErrorCount > 0)
        #expect(analysis.symbols.map(\.name) == ["Broken", "method", "ok", "fine"])

        // An unclosed class swallows the rest of the file; the analyzer still returns what it can.
        let unclosed = """
        export class Broken {
          method( {
            const x = ;
          }
        function ok(): number { return 1 }
        export const fine = 2;
        """
        let partial = try analyze(unclosed)
        #expect(partial.syntaxErrorCount > 0)
        #expect(partial.symbol("Broken") != nil)
        _ = try analyze("")
        _ = try analyze("}}}{{{ ))) <<< export default", path: "src/garbage.tsx")
        _ = try analyze(String(repeating: "(", count: 20_000), path: "src/deep.js")
    }

    @Test func deeplyNestedExpressionsDoNotOverflowTheStack() throws {
        let chain = (0..<20_000).map { "v\($0)" }.joined(separator: " + ")
        let analysis = try analyze("export const total = \(chain);")
        #expect(analysis.symbol("total") != nil)
        #expect(analysis.references.count == 20_000)
    }

    @Test func grammarSelectionFollowsTheFileExtension() throws {
        #expect(TypeScriptAnalyzer.grammar(for: "a/b.tsx", language: .typescript) == .tsx)
        #expect(TypeScriptAnalyzer.grammar(for: "a/b.ts", language: .typescript) == .typescript)
        #expect(TypeScriptAnalyzer.grammar(for: "a/b.mts", language: .typescript) == .typescript)
        #expect(TypeScriptAnalyzer.grammar(for: "a/b.jsx", language: .javascript) == .javascript)
        #expect(TypeScriptAnalyzer.grammar(for: "a/b.cjs", language: .javascript) == .javascript)
        let jsx = try analyze("export function App() { return <Layout><Header title=\"x\" /></Layout>; }", path: "src/App.jsx")
        #expect(jsx.symbol("App")?.kind == .component)
        #expect(jsx.hasReference("Layout", .instantiate))
        #expect(jsx.hasReference("Header", .instantiate))
        #expect(TypeScriptAnalyzer().canAnalyze(.javascript, path: "x.js"))
        #expect(!TypeScriptAnalyzer().canAnalyze(.python, path: "x.py"))
    }

    @Test func anonymousClassExpressionsProduceReferencesButNoSymbols() throws {
        let analysis = try analyze("""
        customElements.define("x-card", class extends HTMLElement {
          connectedCallback() { renderCard(this); }
          label = formatLabel("card");
        });
        """)
        #expect(analysis.symbols.isEmpty)
        #expect(analysis.hasReference("HTMLElement", .inherit))
        #expect(analysis.hasReference("renderCard", .call))
        #expect(analysis.hasReference("formatLabel", .call))
    }

    @Test func concurrentAnalysisIsDeterministic() async throws {
        let typescript = "import { a } from './a';\nexport class K extends a.Base { run(x: number) { return helper(x) && this.go(); } }\n"
        let python = "from .a import Base\nclass K(Base):\n    def run(self, x):\n        return helper(x) and self.go()\n"
        let results = await withTaskGroup(of: String.self) { group in
            for index in 0..<64 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        let result = try? TypeScriptAnalyzer().analyze(SourceFile(path: "k.ts", language: .typescript, text: typescript))
                        return "ts:\(result?.symbols.count ?? -1):\(result?.references.count ?? -1):\(result?.complexity ?? -1)"
                    }
                    let result = try? PythonAnalyzer().analyze(SourceFile(path: "k.py", language: .python, text: python))
                    return "py:\(result?.symbols.count ?? -1):\(result?.references.count ?? -1):\(result?.complexity ?? -1)"
                }
            }
            var all: [String] = []
            for await value in group { all.append(value) }
            return all
        }
        #expect(results.count == 64)
        #expect(Set(results).count == 2, "every concurrent run of the same input yields the same analysis: \(Set(results))")
        #expect(!results.contains { $0.contains("-1") })
    }

    @Test func largeGeneratedFileIsFast() throws {
        var lines: [String] = ["import { Base, helper } from \"./base\";"]
        for index in 0..<500 {
            lines.append("""
            /** Service \(index). */
            export class Service\(index) extends Base {
              private value\(index) = \(index);
              compute(input: number): number {
                if (input > \(index) && this.value\(index) > 0) {
                  return helper(input) + this.value\(index);
                }
                return new Service\(max(0, index - 1))().compute(input - 1);
              }
            }
            """)
        }
        let source = lines.joined(separator: "\n")
        let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
        let start = Date()
        let analysis = try analyze(source, path: "src/generated.ts")
        let elapsed = Date().timeIntervalSince(start)
        print("TypeScript: \(lineCount) lines in \(String(format: "%.3f", elapsed))s (\(Int(Double(lineCount) / max(elapsed, 0.0001))) lines/sec)")
        #expect(lineCount >= 5_000)
        #expect(analysis.symbols.filter { $0.kind == .class }.count == 500)
        #expect(analysis.symbols.filter { $0.kind == .method }.count == 500)
        #expect(elapsed < 5)
    }

    // MARK: v2 reference data (statements, consumers, load time, environment, import flags)

    @Test func environmentVariablesBecomeEnvReferences() throws {
        let source = """
        export function primeVault(secret: string) {
          if (!process.env.VAULT_KEY) {
            process.env.VAULT_KEY = secret;
          }
          delete process.env.OLD_KEY;
          process.env["MODE"] = "test";
          const value = process.env[pickName()];
          const { PORT, HOST: host = "localhost", ...rest } = process.env;
          return runtimeSchema.safeParse(process.env) && import.meta.env.VITE_API_URL && process.argv && import.meta.url;
        }
        """
        let analysis = try analyze(source, path: "src/server/vault.ts")
        func env(_ name: String, _ line: Int) -> (ReferenceKind, String?)? {
            analysis.references.first { $0.name == name && $0.line == line }.map { ($0.kind, $0.context) }
        }
        #expect(env("env:VAULT_KEY", 2)?.0 == .read)
        #expect(env("env:VAULT_KEY", 2)?.1 == "env")
        #expect(env("env:VAULT_KEY", 3)?.0 == .write)
        #expect(env("env:OLD_KEY", 5)?.0 == .write)
        #expect(env("env:OLD_KEY", 5)?.1 == "delete")
        #expect(env("env:MODE", 6)?.0 == .write, "a subscript assignment is a write")
        #expect(env("env:*", 7)?.1 == "env-dynamic")
        #expect(analysis.hasReference("pickName", .call), "a computed key is still visited")
        #expect(env("env:PORT", 8)?.1 == "env")
        #expect(env("env:HOST", 8)?.1 == "env")
        #expect(env("env:*", 8)?.1 == "env-all", "a rest element takes the remaining variables")
        #expect(env("env:*", 9)?.1 == "env-all", "the whole environment passed on")
        #expect(analysis.hasReference("env:VITE_API_URL", .read, receiver: "import.meta.env"))
        #expect(analysis.hasReference("safeParse", .call, receiver: "runtimeSchema"))
        for name in ["process", "env", "argv", "url", "VAULT_KEY", "OLD_KEY"] {
            #expect(analysis.references(named: name).isEmpty, "\(name) is not a reference of its own")
        }
        #expect(analysis.references.filter { $0.name.hasPrefix("env:") }.allSatisfy { $0.atLoad == false })
    }

    @Test func importFlagsTellStaticDynamicSideEffectAndMockImportsApart() throws {
        let source = """
        import { sealSecret, type SealedBox, openSecret as unseal } from "@/server/vault";
        import "./styles/base.css";
        import {
          a,
          b,
        } from "./multi";
        export { type Props, Button } from "./button";
        vi.mock("@/server/vault", () => ({ sealSecret: vi.fn(() => helper()) }));
        vi.mock(import("./db"));
        const actual = await vi.importActual("./real");
        require("./polyfill");
        export async function load() {
          const { startQueue } = await import("@/jobs/queue");
          startQueue();
          const legacy = require("./legacy");
          await import("./env");
          return legacy.run(sealSecret, unseal, a, b, actual);
        }
        """
        let analysis = try analyze(source, path: "src/app/start.ts")
        let vault = analysis.imports.filter { $0.module == "@/server/vault" }
        #expect(vault.count == 2)
        let real = try #require(vault.first { !$0.isMock })
        #expect(describe(real.names) == ["sealSecret", "SealedBox", "openSecret as unseal"])
        #expect(real.names.map(\.isTypeOnly) == [false, true, false], "inline `type` marks one name")
        #expect(!real.isTypeOnly && !real.isDynamic && !real.isSideEffect)
        let mock = try #require(vault.first { $0.isMock })
        #expect(mock.line == 8)
        #expect(mock.names.isEmpty && !mock.isDynamic)

        #expect(analysis.importFor("./styles/base.css")?.isSideEffect == true)
        #expect(analysis.importFor("./multi")?.line == 3)
        #expect(analysis.importFor("./multi")?.endLine == 6)
        let button = try #require(analysis.importFor("./button"))
        #expect(button.isReExport)
        #expect(button.names.map(\.isTypeOnly) == [true, false])
        #expect(analysis.importFor("./db")?.isMock == true, "vi.mock(import(\"./db\"))")
        #expect(analysis.importFor("./real")?.isMock == true)
        #expect(analysis.importFor("./real")?.isDynamic == true, "importActual loads the real module")
        #expect(analysis.importFor("./polyfill")?.isSideEffect == true)
        #expect(analysis.importFor("./polyfill")?.isDynamic == false)

        let queue = try #require(analysis.importFor("@/jobs/queue"))
        #expect(queue.isDynamic && !queue.isSideEffect)
        #expect(describe(queue.names) == ["startQueue"])
        #expect(analysis.importFor("./legacy")?.isDynamic == true, "require inside a function loads when it runs")
        #expect(describe(try #require(analysis.importFor("./legacy")).names) == ["* as legacy"])
        #expect(analysis.importFor("./env")?.isDynamic == true)
        #expect(analysis.importFor("./env")?.isSideEffect == false)

        // Names bound by a function-scoped dynamic import are references, not locals.
        let start = try #require(analysis.reference("startQueue", line: 14))
        #expect(start.kind == .call)
        #expect(analysis.enclosingName(start) == "load")
        #expect(analysis.hasReference("run", .call, receiver: "legacy"))
        // A mock is no call reference, but its factory and `vi` still are.
        #expect(analysis.references(named: "mock").isEmpty)
        #expect(analysis.references(named: "importActual").isEmpty)
        #expect(analysis.hasReference("helper", .call))
        #expect(analysis.hasReference("fn", .call, receiver: "vi"))
        #expect(analysis.references(named: "vi").count == 4)
    }

    @Test func dynamicImportCallbacksBindTheModuleParameter() throws {
        let source = """
        const Chart = dynamic(
          () => import("./chart").then(m => ({ default: m.TrendChart })),
          { ssr: false },
        );
        const Calendar = dynamic(() => import("./calendar").then((m) => m.MonthGrid));
        const Both = lazy(() => import("./both").then(({ First, Second: S }) => First ?? S));
        export function use(m: Model) { return m.value; }
        """
        let analysis = try analyze(source, path: "src/app/reports/page.tsx")
        // Each callback's `m` gets an alias unique in the file, so the four modules never share one binding.
        #expect(describe(try #require(analysis.importFor("./chart")).names) == ["* as m@2"])
        #expect(analysis.importFor("./chart")?.isDynamic == true)
        #expect(describe(try #require(analysis.importFor("./calendar")).names) == ["* as m@5"])
        #expect(describe(try #require(analysis.importFor("./both")).names) == ["First", "Second as S"])
        #expect(analysis.hasReference("TrendChart", .read, receiver: "m@2"))
        #expect(analysis.hasReference("MonthGrid", .read, receiver: "m@5"))
        #expect(analysis.hasReference("First", .read))
        #expect(analysis.hasReference("S", .read))
        #expect(analysis.references(named: "m").isEmpty, "the module parameter itself is not a reference")
        #expect(analysis.references(named: "value").isEmpty, "an ordinary parameter named m is still a local")
        #expect(!analysis.references.contains { $0.receiver?.hasPrefix("m@") == true && $0.line == 7 })
    }

    @Test func typeofInATypeIsATypeUse() throws {
        let source = """
        import { currentAccount, api } from "./session";
        function accountLabel(entry: NonNullable<ReturnType<typeof currentAccount>>): string {
          return typeof entry === "string" ? entry : render(entry);
        }
        type Client = typeof api.client;
        """
        let analysis = try analyze(source, path: "src/server/accounts.ts")
        let account = try #require(analysis.reference("currentAccount", line: 2))
        #expect(account.kind == .typeUse)
        #expect(account.context == "typeof")
        #expect(analysis.reference("client", line: 5)?.kind == .typeUse)
        #expect(analysis.reference("client", line: 5)?.context == "typeof")
        #expect(analysis.reference("client", line: 5)?.receiver == "api")
        #expect(analysis.reference("render", line: 3)?.context == "call")
        #expect(!analysis.references.contains { $0.name == "currentAccount" && $0.kind == .read })
    }

    @Test func statementSpansCallEndsAndConsumingStatements() throws {
        let source = """
        export async function POST(req: Request) {
          const form = await req.json();
          // Seal the vault entry
          const sealedKey = sealSecret(form.passphrase);
          db.insert(vaultEntries)
            .fields({
              sealedPassphrase: sealedKey.bytes,
            })
            .run();
          if (shouldStore(form)) {
            const sealedHint = sealSecret(form.hint);
            save(sealedHint);
          }
          try {
            const passphrase = openSecret({
              sealed: form.sealed,
              nonce: form.nonce,
            });

            const token = signSession(passphrase);
            return finish(token);
          } catch (error) {
            return fail(error);
          }
        }
        """
        let analysis = try analyze(source, path: "src/app/api/vault/route.ts")
        let seal = try #require(analysis.reference("sealSecret", line: 4))
        #expect(seal.column == 21, "columns are 1-based")
        #expect(seal.statementLine == 4 && seal.endLine == 4 && seal.callEndLine == 4)
        #expect(seal.context == "call")
        #expect(seal.atLoad == false)
        #expect(seal.assignedTo == "sealedKey")
        #expect(seal.consumerLine == 5, "the statement that reads `sealedKey` starts on line 5")
        #expect(analysis.reference("json", line: 2)?.assignedTo == "form")
        #expect(analysis.reference("json", line: 2)?.consumerLine == 4)

        // A chained call is one statement, lines 5-9; each call ends where its arguments close.
        let insert = try #require(analysis.reference("insert", line: 5))
        #expect(insert.statementLine == 5 && insert.endLine == 9 && insert.callEndLine == 5)
        let fields = try #require(analysis.reference("fields", line: 6))
        #expect(fields.statementLine == 5 && fields.endLine == 9 && fields.callEndLine == 8)
        #expect(analysis.reference("run", line: 9)?.callEndLine == 9)

        // A compound statement contributes only its header.
        let condition = try #require(analysis.reference("shouldStore", line: 10))
        #expect(condition.statementLine == 10 && condition.endLine == 10)
        let second = try #require(analysis.reference("sealSecret", line: 11))
        #expect(second.assignedTo == "sealedHint" && second.consumerLine == 12)

        let unseal = try #require(analysis.reference("openSecret", line: 15))
        #expect(unseal.statementLine == 15 && unseal.endLine == 18 && unseal.callEndLine == 18)
        #expect(unseal.assignedTo == "passphrase")
        #expect(unseal.consumerLine == 20, "the blank line between is skipped")
        #expect(analysis.reference("signSession", line: 20)?.consumerLine == 21)
        #expect(analysis.reference("finish", line: 21)?.assignedTo == "return")
        #expect(analysis.reference("finish", line: 21)?.consumerLine == nil)
        #expect(analysis.reference("fail", line: 23)?.assignedTo == "return")
        #expect(analysis.references.allSatisfy { $0.statementLine != nil }, "every reference here is inside a statement")
    }

    @Test func consumersStayWithTheirOwnBinding() throws {
        // Many functions in a file reuse local names; a read of another function's `x` never consumes this one.
        var source = ""
        for index in 0..<40 {
            source += "function first\(index)() {\n  const x = make\(index)();\n}\n"
            source += "function second\(index)() {\n  const x = 1;\n  use\(index)(x);\n}\n"
        }
        let analysis = try analyze(source, path: "src/many.ts")
        let made = analysis.references.filter { $0.name.hasPrefix("make") }
        #expect(made.count == 40)
        #expect(made.allSatisfy { $0.assignedTo == "x" && $0.consumerLine == nil })
    }

    @Test func referencesKnowWhetherTheyRunWhileTheModuleLoads() throws {
        let source = """
        import { register } from "./registry";
        register(Plugin);
        export class Service extends Base {
          static shared = create();
          instance = build();
          @Inject() dependency: Dep;
          run() { return execute(); }
        }
        const handler = () => respond();
        export default configure();
        """
        let analysis = try analyze(source, path: "src/service.ts")
        let atLoad = ["register": true, "Plugin": true, "Base": true, "create": true, "build": false, "Inject": true,
                      "execute": false, "respond": false, "configure": true]
        for (name, expected) in atLoad {
            let reference = try #require(analysis.references(named: name).first, "\(name)")
            #expect(reference.atLoad == expected, "\(name) atLoad")
        }
        let base = try #require(analysis.references(named: "Base").first)
        #expect(base.context == "heritage")
        #expect(base.statementLine == 3 && base.endLine == 3, "a class declaration's statement is its header")
        let inject = try #require(analysis.references(named: "Inject").first)
        #expect(inject.context == "decorator")
        #expect(inject.statementLine == 6 && inject.callEndLine == 6)
        #expect(analysis.references(named: "create").first?.statementLine == 4)
    }

    @Test func inlineTypeNamesSurviveStorage() {
        let names = [ImportedName(name: "sealSecret"), ImportedName(name: "SealedBox", isTypeOnly: true),
                     ImportedName(name: "Props", alias: "P", isTypeOnly: true)]
        let stored = ImportNamesCodec.encode(names)
        #expect(stored == "sealSecret,type SealedBox,type Props as P")
        #expect(ImportNamesCodec.decode(stored) == names)
        #expect(ImportNamesCodec.decode("openSecret as unseal,default as App").map(\.isTypeOnly) == [false, false])
    }

    @Test func versionAndStopListsForTheIndex() {
        // A new version re-parses every TypeScript and JavaScript file of an existing index.
        #expect(TypeScriptAnalyzer().version == 2)
        #expect(TypeScriptAnalyzer.stopNames.contains("console"))
        #expect(AnalyzerStopLists.untrackedNames(language: .typescript) == TypeScriptAnalyzer.stopNames)
        #expect(AnalyzerStopLists.untrackedNames(language: .javascript) == TypeScriptAnalyzer.stopNames)
    }
}
