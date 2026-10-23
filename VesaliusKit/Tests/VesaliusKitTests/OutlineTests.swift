import Foundation
@testable import QueryEngine
import Testing
import VesaliusCore
import VesaliusMCP
@testable import VesaliusRender

/// `outline`: a file's declarations with members, calls out and users; a type's members and
/// extensions; a function's flow; a folder's files; the choices for a name declared twice; the budget. The
/// fixture is a real repository on disk, indexed and queried through the engine and the tool.
@Suite("Outline", .serialized)
struct OutlineTests {
    /// A Swift package (one target, one test target) and a small TypeScript app.
    static let shop: [String: String] = [
        "Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "Shop",
                targets: [
                    .target(name: "Store"),
                    .testTarget(name: "StoreTests", dependencies: ["Store"]),
                ]
            )
            """,
        "Sources/Store/Ledger.swift": """
            import Foundation

            /// Flags stored with each entry.
            public struct EntryFlags: OptionSet, Sendable {
                public let rawValue: UInt32
                public init(rawValue: UInt32) { self.rawValue = rawValue }
                public static let voided = EntryFlags(rawValue: 1 << 0)
            }

            /// One line of the ledger. Entries never change once written.
            public struct Entry: Equatable, Sendable {
                public static let size: Int = 48
                public var amount: Int
                public var flags: EntryFlags
                private var memo = ""

                public init(amount: Int, flags: EntryFlags) {
                    self.amount = amount
                    self.flags = flags
                }

                /// The entry's bytes, checksummed.
                public func encode() throws -> Data {
                    guard amount >= 0 else { throw StoreError.negative(amount) }
                    return Checksum.digest(Data(count: Entry.size))
                }
            }

            public enum Record {
                case entry(amount: Int, flags: EntryFlags)
                case padding(bytes: Int)
                case sentinel

                public static let headerSize = Entry.size

                public var isSentinel: Bool {
                    if case .sentinel = self { return true }
                    return false
                }
            }
            """,
        "Sources/Store/Checksum.swift": """
            import Foundation

            public enum Checksum {
                public static func digest(_ data: Data) -> Data {
                    data
                }
            }

            public enum StoreError: Error {
                case negative(Int)
            }
            """,
        "Sources/Store/Ledger+Totals.swift": """
            extension Entry {
                /// The amount in cents.
                public var cents: Int { amount * 100 }
            }
            """,
        "Sources/Store/Book.swift": """
            public final class Book {
                public var entries: [Entry] = []

                public func add(_ amount: Int) throws {
                    let entry = Entry(amount: amount, flags: [])
                    _ = try entry.encode()
                    entries.append(entry)
                }
            }

            struct Config {
                var currency = "EUR"
            }
            """,
        "Sources/Store/Archive.swift": """
            import Foundation

            public struct Archive {
                public let url: URL

                /// Writes every entry, then syncs.
                public func write(_ book: Book) async throws {
                    for entry in book.entries {
                        let data = try entry.encode()
                        try data.write(to: url)
                    }
                    try await flush()
                }

                func flush() async throws {}
            }
            """,
        "Tests/StoreTests/EntryTests.swift": """
            import Testing
            @testable import Store

            @Test func encodes() throws {
                let entry = Entry(amount: 1, flags: .voided)
                #expect(try entry.encode().count == Entry.size)
            }
            """,
        "web/src/lib/crypto.ts": """
            import { randomBytes } from "node:crypto";

            const CIPHER_ID = "aes-256-gcm";

            function secretKey(): string {
              return process.env.SECRET_KEY ?? "";
            }

            export function seal(text: string): string {
              return CIPHER_ID + secretKey() + text + randomBytes(4).toString("hex");
            }

            export function open(sealed: string): string {
              return sealed.slice(CIPHER_ID.length);
            }

            export interface Config {
              currency: string;
            }
            """,
        "docs/GUIDE.md": """
            # Shop

            Keeps a ledger.

            ## Entries

            ```sh
            # not a heading
            ```

            ### Flags
            #notaheading
            """,
        "web/src/app/api/save/route.ts": """
            import { seal } from "../../../lib/crypto";

            export async function POST(request: Request) {
              const body = await request.text();
              return new Response(seal(body));
            }
            """,
    ]

    /// Overloads, cases declared together, a file compiled under one condition, framework calls through a nested
    /// type and a Python module path.
    static let labels: [String: String] = [
        "Sources/Kit/Hasher.swift": """
            import Foundation

            public enum Hasher {
                public static func digest(_ data: Data) -> Data { data }
                public static func digest(parts: [Data]) -> Data { parts.first ?? Data() }
            }

            public enum Outcome {
                case cancelled, pending, success
                case failed(String)
            }
            """,
        "Sources/Kit/Seal.swift": """
            import Foundation

            public func seal(_ data: Data) -> Data {
                let one = Hasher.digest(data)
                return Hasher.digest(parts: [one, data])
            }
            """,
        "Sources/Kit/Debug.swift": """
            #if DEBUG
            import MapKit

            public func debugSearch() -> MKLocalSearch.Request {
                MKLocalSearch.Request()
            }

            public struct DebugFlags {
                public var verbose = false
            }
            #endif
            """,
        "scripts/pack.py": """
            import os

            HERE = os.path.dirname(os.path.abspath(__file__))

            def main(): # Packs the build
                os.makedirs(HERE, exist_ok=True)
            """,
    ]

    static func context(_ engine: RepositoryEngine) -> ToolContext {
        ToolContext(engine: engine) {
            let summary = try await engine.index(options: RepoFixture.fastOptions)
            return summary.filesAdded + summary.filesChanged + summary.filesRemoved
        }
    }

    @Test("A file: top-level declarations with ranges, docs and members, its target, users and calls out")
    func file() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.shop, name: "outline-file")
        let result = try engine.outline("Sources/Store/Ledger.swift")
        #expect(result.kind == .file)
        let file = try #require(result.file)
        #expect(file.declarations.map(\.name) == ["EntryFlags", "Entry", "Record"])
        #expect(file.targets == ["Store"])
        #expect(file.usedBy == OutlineUsers(files: 4, testFiles: 1))
        let entry = file.declarations[1]
        #expect(entry.lines == LineRange(11, 27) && entry.doc == "One line of the ledger.")
        let size = try #require(entry.members.first { $0.name == "size" })
        #expect(size.isStatic && size.value == "48" && size.type == "Int")
        let encode = try #require(entry.members.first { $0.name == "encode" })
        #expect(encode.selector == "encode()" && encode.effects == "throws" && encode.type == "Data")
        #expect(file.calls.repository.map(\.name) == ["Checksum.digest", "StoreError.negative"])
        #expect(file.calls.repository.last?.isError == true)

        let lines = OutlineRenderer.render(result, budget: .unlimited).components(separatedBy: "\n")
        #expect(lines == [
            "Sources/Store/Ledger.swift  40 lines · target Store · used by 4 files (3 app, 1 test)",
            "imports: Foundation",
            "4-8    public struct EntryFlags: OptionSet, Sendable  \"Flags stored with each entry.\"",
            "         rawValue: UInt32 :5 · init(rawValue:) :6 · static voided = EntryFlags(rawValue: 1 << 0) :7",
            "11-27  public struct Entry: Equatable, Sendable  \"One line of the ledger.\"",
            "         static size = 48 :12 · amount: Int :13 · flags: EntryFlags :14 · private memo = \"\" :15",
            "         init(amount:flags:) :17 · encode() throws -> Data :23",
            "29-40  public enum Record — cases entry(amount:flags:) :30 · padding(bytes:) :31 · sentinel :32",
            "         static headerSize = Entry.size :34 · isSentinel: Bool :36",
            "calls out: Checksum.digest :25 · StoreError.negative :24",
            "external: Foundation ×1 (Data.init)",
        ])
    }

    @Test("The tool's text fits a fifth of the file; a small budget keeps every declaration with its member count")
    func budget() async throws {
        let (engine, root) = try await RepoFixture.indexed(Self.shop, name: "outline-budget")
        let output = await MCPToolCatalog.execute(OutlineTool(), arguments: ["target": .string("Sources/Store/Ledger.swift")], context: Self.context(engine))
        #expect(!output.isError)
        let size = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Sources/Store/Ledger.swift").path)[.size] as? Int ?? 0
        #expect(TokenEstimate.of(output.text) <= Budget.outline(fileCharacters: size).tokens)
        let lines = output.text.components(separatedBy: "\n")
        #expect(lines.first == "Sources/Store/Ledger.swift  40 lines · target Store · used by 4 files (3 app, 1 test)")
        #expect(lines.contains { $0.hasPrefix("4-8    public struct EntryFlags") })
        #expect(lines.contains { $0.hasPrefix("11-27  public struct Entry") })
        #expect(lines.contains { $0.hasPrefix("29-40  public enum Record") })

        // Past the last level, declarations are cut from the end with a line that says how many and from where.
        let result = try engine.outline("Sources/Store/Ledger.swift")
        let tiny = OutlineRenderer.render(result, budget: Budget(tokens: 40)).components(separatedBy: "\n")
        #expect(tiny.first == lines.first)
        #expect(tiny.contains("+3 more not shown, from line 4"))
        // The last level keeps each declaration's kind, name and member count, and the types it calls.
        let tight = OutlineRenderer.render(result, budget: Budget(tokens: 90)).components(separatedBy: "\n")
        #expect(tight == [
            "Sources/Store/Ledger.swift  40 lines · target Store · used by 4 files (3 app, 1 test)",
            "4-8    struct EntryFlags — 3 members",
            "11-27  struct Entry — 6 members",
            "29-40  enum Record — 5 members",
            "calls out: Checksum · StoreError",
            "external: Foundation ×1",
        ])
    }

    @Test("A type: one member per line with signatures and docs, extensions in other files, users outside them")
    func type() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.shop, name: "outline-type")
        let result = try engine.outline("Entry")
        let symbol = try #require(result.symbol)
        #expect(result.kind == .symbol && symbol.declaration.kind == .struct)
        #expect(symbol.extensions.map(\.path) == ["Sources/Store/Ledger+Totals.swift"])
        // Book, Archive and the test use it; the extension's file is part of the type.
        #expect(symbol.usedBy == OutlineUsers(files: 3, testFiles: 1))
        let text = OutlineRenderer.render(result, budget: .unlimited)
        #expect(text.components(separatedBy: "\n") == [
            "public struct Entry: Equatable, Sendable  Sources/Store/Ledger.swift:11-27 · target Store · used by 3 files (2 app, 1 test)",
            "  \"One line of the ledger.\"",
            "  12  public static let size: Int = 48",
            "  13  public var amount: Int",
            "  14  public var flags: EntryFlags",
            "  15  private var memo = \"\"",
            "  17  public init(amount: Int, flags: EntryFlags)",
            "  23  public func encode() throws -> Data  \"The entry's bytes, checksummed.\"",
            "extension Entry  Sources/Store/Ledger+Totals.swift:1-4",
            "    cents: Int :3",
            "calls out: Checksum.digest :25 · StoreError.negative :24",
            "external: Foundation ×1 (Data.init)",
        ])

        // A property names the type it is in.
        let property = OutlineRenderer.render(try engine.outline("Entry.size"), budget: .unlimited)
        #expect(property.hasPrefix("public static let size: Int = 48  Sources/Store/Ledger.swift:12 · in Entry :11-27 · target Store · used by "))
    }

    @Test("A function: its flow when it has steps; otherwise its callers and its calls in order")
    func function() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.shop, name: "outline-function")
        let write = try engine.outline("Archive.write(_:)")
        let flow = try #require(write.flow)
        #expect(!flow.steps.isEmpty)
        let full = OutlineRenderer.render(write, budget: .unlimited).components(separatedBy: "\n")
        #expect(full.first == "public func write(_ book: Book) async throws  Sources/Store/Archive.swift:7-13 · in Archive :3-16 · target Store · used by no other file")
        #expect(full.dropFirst().first == "  \"Writes every entry, then syncs.\"")
        // The flow is printed as feature_map prints it.
        let flowLines = FeatureMapRenderer.render(flow: flow, budget: .unlimited).components(separatedBy: "\n")
        #expect(Array(full.dropFirst(2).prefix(flowLines.count)) == flowLines)
        // In a fifth of this small file the header gives up the owner's lines, and the flow's first line, which
        // repeats the header, its place to the sinks.
        let lines = OutlineRenderer.render(write, budget: Budget.outline(fileCharacters: write.sourceCharacters)).components(separatedBy: "\n")
        #expect(Array(lines.prefix(3)) == [
            "public func write(_ book: Book) async throws  Sources/Store/Archive.swift:7-13 · in Archive · target Store · used by no other file",
            "  \"Writes every entry, then syncs.\"",
            "sinks: data.write",
        ])
        for step in flow.steps {
            #expect(lines.contains { $0.hasPrefix("  \(step.line) │ ") })
        }

        let add = try engine.outline("Book.add")
        #expect(add.symbol?.calls.repository.map(\.name) == ["Entry.init", "Entry.encode"])
        let addText = OutlineRenderer.render(add, budget: .unlimited)
        #expect(addText.hasPrefix("public func add(_ amount: Int) throws  Sources/Store/Book.swift:4-8 · in Book :1-9 · target Store"))
        #expect(addText.contains("Entry.encode :6"))
    }

    @Test("A folder lists its files with their main declarations; a name declared twice lists exact targets; a document its headings")
    func folderAndChoices() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.shop, name: "outline-folder")
        let folder = OutlineRenderer.render(try engine.outline("Sources/Store/"), budget: .unlimited)
        #expect(folder.components(separatedBy: "\n") == [
            "Sources/Store/  5 files · 84 lines · target Store",
            "  Archive.swift  16 lines  public struct Archive",
            "  Book.swift  13 lines  public final class Book · struct Config · used by 1",
            "  Checksum.swift  11 lines  public enum Checksum · public enum StoreError: Error · used by 1",
            "  Ledger+Totals.swift  4 lines  extension Entry",
            "  Ledger.swift  40 lines  public struct EntryFlags: OptionSet · public struct Entry · public enum Record  \"Flags stored with each entry.\" · used by 4",
        ])

        let choices = try engine.outline("Config")
        #expect(choices.kind == .choices)
        #expect(choices.choices.map(\.target) == ["Sources/Store/Book.swift#Config", "web/src/lib/crypto.ts#Config"])
        let text = OutlineRenderer.render(choices, budget: .unlimited)
        #expect(text.hasPrefix("“Config” names 2 declarations; outline one by its exact target:"))
        #expect(text.contains("  Sources/Store/Book.swift:11-13  struct Config · 0 uses in 0 files → outline(target:\"Sources/Store/Book.swift#Config\")"))
        // Each exact target selects one declaration.
        for choice in choices.choices {
            #expect(try engine.outline(choice.target).kind == .symbol)
        }

        // A document lists its headings; a fenced block holds none.
        let guide = OutlineRenderer.render(try engine.outline("docs/GUIDE.md"), budget: .unlimited).components(separatedBy: "\n")
        #expect(Array(guide.dropFirst()) == ["1   # Shop", "5   ## Entries", "11  ### Flags"])
    }

    @Test("TypeScript: exports, routes, environment reads; private declarations are named on one line when tight")
    func typescript() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.shop, name: "outline-ts")
        let result = try engine.outline("web/src/lib/crypto.ts")
        let text = OutlineRenderer.render(result, budget: .unlimited)
        #expect(text.components(separatedBy: "\n") == [
            "web/src/lib/crypto.ts  19 lines · used by 1 file",
            "imports: node:crypto {randomBytes}",
            "3      const CIPHER_ID = \"aes-256-gcm\"",
            "5-7    function secretKey(): string",
            "9-11   export function seal(text: string): string",
            "13-15  export function open(sealed: string): string",
            "17-19  export interface Config — currency: string :18",
            "external: crypto  randomBytes :10",
            "env: SECRET_KEY read :6",
        ])
        let tight = OutlineRenderer.render(result, budget: Budget(tokens: 105)).components(separatedBy: "\n")
        #expect(tight.contains("9-11   export function seal(text: string): string"))
        #expect(tight.contains("not exported: CIPHER_ID :3 · secretKey :5"))
        #expect(!tight.contains { $0.hasPrefix("5-7") })

        let route = OutlineRenderer.render(try engine.outline("web/src/app/api/save/route.ts"), budget: .unlimited)
        #expect(route.contains("3-6  export async function POST(request: Request)  [POST /api/save]"))
        #expect(route.contains("calls out: seal :5"))
    }

    @Test("Frameworks and unknown names point to the right call; an edited file is re-indexed before answering")
    func errorsAndFreshness() async throws {
        let (engine, root) = try await RepoFixture.indexed(Self.shop, name: "outline-errors")
        let context = Self.context(engine)
        let framework = await MCPToolCatalog.execute(OutlineTool(), arguments: ["target": .string("Foundation")], context: context)
        #expect(framework.isError && framework.text.contains("usages(target:\"Foundation\")"))
        let missing = await MCPToolCatalog.execute(OutlineTool(), arguments: ["target": .string("NoSuchThing")], context: context)
        #expect(missing.isError && missing.text.hasPrefix("Nothing in the index matches “NoSuchThing”"))

        try RepoFixture.write("""
            public enum Checksum {
                /// Returns the data unchanged.
                public static func digest(_ data: Data) -> Data {
                    data
                }
            }
            """, to: "Sources/Store/Checksum.swift", in: root)
        let fresh = await MCPToolCatalog.execute(OutlineTool(), arguments: ["target": .string("Sources/Store/Checksum.swift")], context: context)
        #expect(fresh.text.hasPrefix("re-indexed 1 file\n"))
        #expect(fresh.text.contains("public enum Checksum — static digest(_:) -> Data :3"))
        #expect(!fresh.text.contains("StoreError"))
    }

    @Test("A tight budget keeps a function's steps: the header shortens and the flow's first line, which repeats it, goes")
    func tightFunction() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.shop, name: "outline-tight")
        let write = try engine.outline("Archive.write(_:)")
        let flow = try #require(write.flow)
        let full = OutlineRenderer.render(write, budget: .unlimited)
        #expect(full.components(separatedBy: "\n").contains { $0.hasPrefix("flow Archive.write(_:)  Sources/Store/Archive.swift:7-13") })
        let tight = OutlineRenderer.render(write, budget: Budget(tokens: TokenEstimate.of(full) - 30)).components(separatedBy: "\n")
        #expect(tight[0].hasPrefix("public func write(_ book: Book) async throws  Sources/Store/Archive.swift:7-13 · "))
        #expect(!tight.contains { $0.hasPrefix("flow ") })
        for step in flow.steps {
            #expect(tight.contains { $0.hasPrefix("  \(step.line) │ ") })
        }
    }

    @Test("Overloads are told apart by selector, cases written together share a line, a shared #if is said once, framework calls keep their full names")
    func labelsAndConditions() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.labels, name: "outline-labels")
        let seal = OutlineRenderer.render(try engine.outline("Sources/Kit/Seal.swift"), budget: .unlimited)
        #expect(seal.contains("calls out: Hasher.digest(_:) :4 · Hasher.digest(parts:) :5"))

        let outcome = OutlineRenderer.render(try engine.outline("Outcome"), budget: .unlimited).components(separatedBy: "\n")
        #expect(outcome.contains("  9   case cancelled, pending, success"))
        #expect(outcome.contains("  10  case failed(String)"))

        let debug = OutlineRenderer.render(try engine.outline("Sources/Kit/Debug.swift"), budget: .unlimited).components(separatedBy: "\n")
        #expect(debug[0].hasSuffix(" · #if DEBUG"))
        #expect(!debug.dropFirst().contains { $0.contains("#if") })
        #expect(debug.contains { $0.contains("MKLocalSearch.Request.init") })

        let pack = OutlineRenderer.render(try engine.outline("scripts/pack.py"), budget: .unlimited).components(separatedBy: "\n")
        #expect(pack.contains("5-6  def main()"))
        #expect(pack.contains { $0.contains("os.path.dirname") } && !pack.contains { $0.contains("os.dirname") })
        #expect(OutlineSignature.withoutPythonTail("X = {'a': '#'}  # map") == "X = {'a': '#'}")
        #expect(OutlineRenderer.parameterNames("({ className, ...props }: React.ComponentProps<\"ol\">, ref?: Ref)") == ["{…}", "ref"])
    }

    @Test("A collapsed subfolder names the main declarations of its most used files first")
    func collapsedFolder() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.shop, name: "outline-collapse")
        let root = try engine.outline(".")
        let text = OutlineRenderer.compose(OutlineRenderer.sections(root, level: 5, budget: .unlimited))
        #expect(text.contains("  Sources/  5 files · 84 lines: EntryFlags, Book, Checksum, Archive, Entry"))
    }

    @Test("Signatures split into type, value, effects and parameters", arguments: [
        ("public static let size: Int = 48", "size", SymbolKind.property, Language.swift, OutlineSignature.Parts(type: "Int", value: "48", isStatic: true)),
        ("@Published private(set) var isSubscribed = false", "isSubscribed", .property, .swift, OutlineSignature.Parts(value: "false")),
        ("public var sequence: UInt64?", "sequence", .property, .swift, OutlineSignature.Parts(type: "UInt64?")),
        ("let handler: (Int) -> Void = { _ in }", "handler", .property, .swift, OutlineSignature.Parts(type: "(Int) -> Void", value: "{ _ in }")),
        ("public static func decode(from data: Data, offset: UInt64) throws -> WALRecordHeader", "decode", .method, .swift,
         OutlineSignature.Parts(type: "WALRecordHeader", effects: "throws", isStatic: true)),
        ("func items<T>(of kind: T.Type) async rethrows -> [T] where T: Decodable", "items", .method, .swift, OutlineSignature.Parts(type: "[T]", effects: "async rethrows")),
        ("public init?(rawValue: String)", "init", .initializer, .swift, OutlineSignature.Parts()),
        ("case yearly = \"yearly_atlas\"", "yearly", .enumCase, .swift, OutlineSignature.Parts(value: "\"yearly_atlas\"")),
        ("case data(sequence: UInt64, payload: Data)", "data", .enumCase, .swift, OutlineSignature.Parts(parameters: "(sequence: UInt64, payload: Data)")),
        ("typealias Unit = Product.SubscriptionPeriod.Unit", "Unit", .typeAlias, .swift, OutlineSignature.Parts(value: "Product.SubscriptionPeriod.Unit")),
        ("async function POST(request: Request)", "POST", .function, .typescript, OutlineSignature.Parts(effects: "async", parameters: "(request: Request)")),
        ("function sealSecret(plain: string): SealedBox", "sealSecret", .function, .typescript,
         OutlineSignature.Parts(type: "SealedBox", parameters: "(plain: string)")),
        ("const NONCE_LENGTH = 12", "NONCE_LENGTH", .constant, .typescript, OutlineSignature.Parts(value: "12")),
        ("def load(self, path: str) -> dict", "load", .method, .python, OutlineSignature.Parts(type: "dict", parameters: "(self, path: str)")),
        ("def tier(ox, oy, w):  # One slab, then its faces.", "tier", .function, .python, OutlineSignature.Parts(parameters: "(ox, oy, w)")),
        ("async def fetch(url) -> bytes:", "fetch", .function, .python, OutlineSignature.Parts(type: "bytes", effects: "async", parameters: "(url)")),
    ])
    func signatures(_ signature: String, _ name: String, _ kind: SymbolKind, _ language: Language, _ expected: OutlineSignature.Parts) {
        #expect(OutlineSignature.parts(signature, name: name, kind: kind, language: language) == expected)
    }

    @Test("A doc comment's first sentence stops at the first full stop, never inside an abbreviation or a parameter list")
    func firstSentence() {
        #expect(OutlineSignature.firstSentence("One line of the ledger. Entries never change.") == "One line of the ledger.")
        #expect(OutlineSignature.firstSentence("Reads a file, e.g. a WAL. Then stops.") == "Reads a file, e.g. a WAL.")
        #expect(OutlineSignature.firstSentence("Opens the store\n- Parameter url: where") == "Opens the store")
        #expect(OutlineSignature.firstSentence("\n\nFirst paragraph\ncontinues here.\n\nSecond.") == "First paragraph continues here.")
        #expect(OutlineSignature.firstSentence(nil) == nil)
        #expect(OutlineSignature.firstSentence(String(repeating: "word ", count: 60))?.count == 160)
    }
}
