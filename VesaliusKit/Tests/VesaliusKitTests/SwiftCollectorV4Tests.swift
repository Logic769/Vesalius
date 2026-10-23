import Foundation
@testable import LanguageAnalysis
@testable import QueryEngine
import RepositoryIndex
import Testing
import VesaliusCore

/// The Swift collector's v4 output: call shapes, statement spans, contexts, `#if` conditions, selectors,
/// signatures with attributes, local types, implicit members, the split stop list, receiver types, string literals
/// and environment variables.
@Suite("Swift collector v4")
struct SwiftCollectorV4Tests {
    private func analyze(_ source: String) throws -> FileAnalysis {
        try SwiftAnalyzer().analyze(SourceFile(path: "Sources/App/Feature.swift", language: .swift, text: source))
    }

    private func refs(_ name: String, in analysis: FileAnalysis) -> [ExtractedReference] {
        analysis.references.filter { $0.name == name }
    }

    private func symbol(_ name: String, kind: SymbolKind? = nil, in analysis: FileAnalysis) -> ExtractedSymbol? {
        analysis.symbols.first { $0.name == name && (kind == nil || $0.kind == kind) }
    }

    /// `receiver kind context (labels)`, e.g. `. call pattern (_)`.
    private func describe(_ reference: ExtractedReference?) -> String {
        guard let reference else { return "none" }
        let labels = reference.argumentLabels.map { " (" + $0.joined(separator: ",") + ")" } ?? ""
        return "\(reference.receiver ?? "-") \(reference.kind.rawValue) \(reference.context ?? "-")" + labels
    }

    @Test func versionFourChangesTheFingerprint() {
        #expect(SwiftAnalyzer().version == 4)
        #expect(IndexingPipeline.extractorFingerprint(.standard).hasPrefix("swift-syntax@4,"))
    }

    // MARK: - Calls

    @Test func callsRecordLabelsAndWhereTheirArgumentsEnd() throws {
        let analysis = try analyze("""
        func run() async {
            book = await libraryService.importBook(
                from: only, preferences: all.first, modelContext: modelContext)
            Button("Save") {
                save()
            }
            sheet(isPresented: $show) { Text("x") } onDismiss: { reset() }
            embed(" ")
            embed(batch: texts)
            start()
            index(for: key)
        }
        """)
        let importBook = try #require(refs("importBook", in: analysis).first)
        #expect(importBook.line == 2 && importBook.callEndLine == 3)
        #expect(importBook.statementLine == 2 && importBook.endLine == 3)
        #expect(importBook.argumentLabels == ["from", "preferences", "modelContext"])
        #expect(importBook.context == "call" && importBook.receiver == "libraryService")

        let button = try #require(refs("Button", in: analysis).first)
        #expect(button.kind == .instantiate && button.context == "call")
        #expect(button.argumentLabels == ["_", "{}"])
        #expect(button.callEndLine == 4, "a trailing closure is not part of the call's own text")
        #expect(button.statementLine == 4 && button.endLine == 6)
        let save = try #require(refs("save", in: analysis).first)
        #expect(save.argumentLabels == [] && save.statementLine == 5 && save.endLine == 5)

        #expect(refs("sheet", in: analysis).first?.argumentLabels == ["isPresented", "{}", "onDismiss{}"])
        #expect(refs("embed", in: analysis).map { $0.argumentLabels ?? ["nil"] } == [["_"], ["batch"]])
        #expect(refs("start", in: analysis).first?.argumentLabels == [])
        #expect(refs("index", in: analysis).first?.argumentLabels == ["for"], "keyword labels are labels")

        // Reads are not calls: no labels, no call end.
        let texts = try #require(refs("texts", in: analysis).first)
        #expect(texts.argumentLabels == nil && texts.callEndLine == nil && texts.context == "read")
        #expect(refs("book", in: analysis).first?.context == "write")
    }

    @Test func compoundStatementsCountOnlyTheirHeader() throws {
        let analysis = try analyze("""
        func check(input: Input) -> Output {
            if let value = load(),
               value.isReady {
                use(value)
            } else if fallback() {
                reset()
            }
            guard ready else { return .empty }
            switch mode {
            case .idle, .busy:
                wait()
            default:
                break
            }
            repeat {
                step()
            } while more()
            return .done
        }
        """)
        func span(_ name: String) -> [Int?] {
            refs(name, in: analysis).flatMap { [$0.statementLine, $0.endLine] }
        }
        #expect(span("Input") == [1, 1], "a declaration with a body: its header")
        #expect(span("load") == [2, 3])
        #expect(span("isReady") == [2, 3])
        #expect(span("use") == [4, 4])
        #expect(span("fallback") == [5, 5], "each `if` of an `else if` chain has its own header")
        #expect(span("reset") == [6, 6])
        #expect(span("ready") == [8, 8])
        #expect(span("mode") == [9, 9])
        #expect(span("idle") == [10, 10], "a `case` label is the statement of its patterns")
        #expect(span("wait") == [11, 11])
        #expect(span("step") == [16, 16])
        #expect(span("more") == [17, 17], "`} while condition` is the statement of a repeat condition")
    }

    // MARK: - Contexts

    @Test func contextsDescribeTheSyntacticRole() throws {
        let analysis = try analyze("""
        struct Screen: View {
            @ObservedObject var model: Model
            var body: some View {
                Toggle("On", isOn: $model)
            }
            func update() {
                counter = 1
                let path = \\Model.name
                let color: Color = .red
                switch state {
                case .loaded(let value): show(value)
                default: break
                }
                if case .failed = state { retry() }
                if state == .empty { wal.append(payload: path) }
            }
        }
        """)
        func context(_ name: String) -> [String?] { refs(name, in: analysis).map(\.context) }
        #expect(context("View") == ["type", "type"])
        #expect(context("model") == ["projected"], "`$model` is the projected value of `model`")
        #expect(context("counter") == ["write"])
        #expect(context("name") == ["keypath"])
        #expect(context("show") == ["call"])

        let red = try #require(refs("red", in: analysis).first)
        #expect(red.receiver == "." && red.kind == .read && red.context == "implicit")
        let loaded = try #require(refs("loaded", in: analysis).first)
        #expect(loaded.receiver == "." && loaded.kind == .call && loaded.context == "pattern" && loaded.argumentLabels == ["_"])
        #expect(describe(refs("failed", in: analysis).first) == ". read pattern")
        #expect(describe(refs("empty", in: analysis).first) == ". read implicit", "a comparison is not a pattern")
        #expect(describe(refs("append", in: analysis).first) == "wal call call (payload)")
    }

    @Test func implicitMembersAreEmittedAndInitInstantiatesAKnownContext() throws {
        let analysis = try analyze("""
        func scan(header: Header) {
            if header.flags.contains(.isBlank) { skip() }
            let tint: Color = .accentColor.opacity(0.5)
            view.font(.system(size: 12))
            let made: Box = .init(width: 1)
        }
        """)
        let padding = try #require(refs("isBlank", in: analysis).first)
        #expect(padding.receiver == "." && padding.kind == .read && padding.context == "implicit" && padding.line == 2)
        #expect(refs("contains", in: analysis).first?.receiver == "_", "a member of a chain")
        #expect(refs("accentColor", in: analysis).first?.receiver == ".")
        #expect(describe(refs("opacity", in: analysis).first) == "_ call call (_)")
        #expect(describe(refs("system", in: analysis).first) == ". call implicit (size)")
        #expect(refs("init", in: analysis).isEmpty && refs("width", in: analysis).isEmpty)
        // `.init(…)` with a written contextual type instantiates it.
        #expect(refs("Box", in: analysis).map(\.kind) == [.typeUse, .instantiate])
        let made = try #require(refs("Box", in: analysis).last)
        #expect(made.line == 5 && made.context == "call" && made.argumentLabels == ["width"])
    }

    // MARK: - Conditional compilation

    @Test func ifConfigConditionsAttachToSymbolsReferencesAndImports() throws {
        let analysis = try analyze("""
        #if DEBUG
        import Mocks
        enum MockAutorun {
            static func run() { seed() }
        }
        #elseif os(iOS)
        func iosOnly() { ping() }
        #else
        func other() {}
        #endif
        #if canImport(UIKit) || canImport(AppKit)
        #if !DEBUG
        func release() { ship() }
        #endif
        #endif
        @testable import MyApp
        func always() {}
        """)
        let mocks = try #require(analysis.imports.first { $0.module == "Mocks" })
        #expect(mocks.conditions == ["DEBUG"] && !mocks.isTestable)
        let app = try #require(analysis.imports.first { $0.module == "MyApp" })
        #expect(app.isTestable && app.conditions.isEmpty)

        #expect(symbol("MockAutorun", in: analysis)?.conditions == ["DEBUG"])
        #expect(symbol("run", in: analysis)?.conditions == ["DEBUG"])
        #expect(refs("seed", in: analysis).first?.conditions == ["DEBUG"])
        #expect(symbol("iosOnly", in: analysis)?.conditions == ["!DEBUG && os(iOS)"])
        #expect(refs("ping", in: analysis).first?.conditions == ["!DEBUG && os(iOS)"])
        #expect(symbol("other", in: analysis)?.conditions == ["!DEBUG && !os(iOS)"])
        #expect(symbol("release", in: analysis)?.conditions == ["(canImport(UIKit) || canImport(AppKit))", "!DEBUG"])
        #expect(refs("ship", in: analysis).first?.conditions.count == 2)
        #expect(symbol("always", in: analysis)?.conditions == [])
        #expect(!analysis.references.contains { ["DEBUG", "os", "iOS", "canImport", "UIKit"].contains($0.name) }, "conditions are not references")
    }

    @Test func aPostfixIfConfigMemberIsNotAnImplicitMember() throws {
        let analysis = try analyze("""
        struct Card: View {
            var body: some View {
                Text("x")
                #if os(iOS)
                    .padding()
                    .font(.headline)
                #endif
            }
        }
        """)
        let padding = try #require(refs("padding", in: analysis).first)
        #expect(padding.receiver == "_" && padding.kind == .call && padding.conditions == ["os(iOS)"])
        #expect(refs("font", in: analysis).first?.receiver == "_")
        #expect(refs("headline", in: analysis).first?.receiver == ".", "an argument is still an implicit member")
    }

    // MARK: - Declarations

    @Test func callablesRecordSelectorsFlagsAndParameterTypes() throws {
        let analysis = try analyze("""
        struct TextEncoder {
            func encode(_ text: String) -> [Float] { [] }
            func encode(batch texts: [String]) -> [[Float]] { [] }
            func importBook(from url: URL, preferences: Preferences? = nil, modelContext: ModelContext) {}
            func load(id: Int, completion: (() -> Void)? = nil) {}
            func each(_ body: @escaping (Item) -> Void, values: Int...) {}
            func check(_ value: @autoclosure () -> Bool) {}
            func find<T: Store>(in stores: [T], where key: [String: Any], pair: (name: String, Int), any: some Sequence) {}
            init(from decoder: Decoder) throws {}
            subscript(key: String) -> Int { 0 }
            subscript(row r: Int, column c: Int) -> Int { 0 }
            static func + (lhs: TextEncoder, rhs: TextEncoder) -> TextEncoder { lhs }
        }
        enum Record {
            case entry(id: UInt64, flags: EntryFlags, body: Data), padding(Int), idle
        }
        """)
        let selectors = analysis.symbols.compactMap(\.selector)
        #expect(selectors == [
            "encode(_:)", "encode(batch:)", "importBook(from:preferences:modelContext:)", "load(id:completion:)",
            "each(_:values:)", "check(_:)", "find(in:where:pair:any:)", "init(from:)", "subscript(_:)",
            "subscript(row:column:)", "+(_:_:)", "entry(id:flags:body:)", "padding(_:)",
        ])
        func shape(_ selector: String) -> (String?, [String]?) {
            let found = analysis.symbols.first { $0.selector == selector }
            return (found?.parameterFlags, found?.parameterTypes)
        }
        #expect(shape("importBook(from:preferences:modelContext:)") == ("-d-", ["URL", "Preferences", "ModelContext"]))
        #expect(shape("load(id:completion:)") == ("-D", ["Int", "?"]), "a defaulted closure is skippable and fillable by a trailing closure")
        #expect(shape("each(_:values:)") == ("cv", ["?", "Int"]))
        #expect(shape("check(_:)").0 == "-", "an autoclosure takes an expression, not a trailing closure")
        #expect(shape("find(in:where:pair:any:)").1 == ["[Store]", "[String: Any]", "(name: String, _: Int)", "Sequence"])
        #expect(shape("entry(id:flags:body:)") == ("---", ["UInt64", "EntryFlags", "Data"]))
        #expect(symbol("idle", in: analysis)?.selector == nil, "a case without associated values is not called")
        // Overloads keep one qualified name; the selector tells them apart.
        #expect(analysis.symbols.filter { $0.name == "encode" }.count == 2)
    }

    @Test func signaturesKeepAttributesSetterAccessAndShortInitializers() throws {
        let analysis = try analyze("""
        @MainActor
        final class PremiumStore: ObservableObject {
            @Published private(set) var isSubscribed = false
            public static let pageSize: UInt64 = 4096
            @Environment(\\.modelContext) private var modelContext
            @Query(sort: \\Book.startDate, order: .reverse, animation: .default) private var books: [Book]
            public private(set) var count: Int = 0
            private let formatter: DateFormatter = DateFormatter.makeAVeryLongFormatterNameThatGoesOnAndOn(locale: .current)
            @available(iOS 17, *) @discardableResult func refresh() async -> Bool { true }
            @_spi(Internal) public func hidden() {}
            @inlinable init() {}
        }
        """)
        #expect(symbol("PremiumStore", in: analysis)?.signature == "@MainActor final class PremiumStore: ObservableObject")
        let subscribed = try #require(symbol("isSubscribed", in: analysis))
        #expect(subscribed.signature == "@Published private(set) var isSubscribed = false")
        #expect(subscribed.setterVisibility == .private && subscribed.visibility == nil)
        #expect(symbol("pageSize", in: analysis)?.signature == "public static let pageSize: UInt64 = 4096")
        #expect(symbol("modelContext", in: analysis)?.signature == "@Environment(\\.modelContext) private var modelContext")
        #expect(symbol("books", in: analysis)?.signature == "@Query(sort: \\Book.startDate, order: .reverse,…) private var books: [Book]")
        let count = try #require(symbol("count", in: analysis))
        #expect(count.visibility == .public && count.setterVisibility == .private)
        #expect(symbol("formatter", in: analysis)?.signature == "private let formatter: DateFormatter", "initializers over 60 characters are left out")
        #expect(symbol("refresh", in: analysis)?.signature == "@discardableResult func refresh() async -> Bool")
        #expect(symbol("hidden", in: analysis)?.signature == "public func hidden()")
        #expect(symbol("init", in: analysis)?.signature == "@inlinable init()")
        // The attributes column keeps bare names: the linker splits it on commas.
        #expect(symbol("books", in: analysis)?.attributes == ["@Query"])
    }

    @Test func functionLocalTypesAreLocalSymbolsWithMembers() throws {
        let analysis = try analyze("""
        public extension Library {
            func previews() -> [Int] {
                struct PreviewPlan: Sendable {
                    let itemId: UInt64
                    let length: Int
                    func size() -> Int { length }
                }
                let plans = [PreviewPlan(itemId: 1, length: 2)]
                func helper() {}
                helper()
                return plans.map { plan in plan.length }
            }
            func after() {}
        }
        """)
        let plan = try #require(symbol("PreviewPlan", in: analysis))
        let previews = try #require(symbol("previews", in: analysis))
        #expect(plan.kind == .struct && plan.isLocal && !plan.isExported && plan.visibility == nil)
        #expect(plan.parentLocalID == previews.localID)
        for member in ["itemId", "length", "size"] {
            let found = try #require(symbol(member, in: analysis))
            #expect(found.isLocal && found.parentLocalID == plan.localID && !found.isExported, "\(member)")
        }
        #expect(symbol("helper", in: analysis) == nil, "local functions stay locals")
        #expect(symbol("plans", in: analysis) == nil, "the function's own locals stay locals after the type")
        let after = try #require(symbol("after", in: analysis))
        #expect(!after.isLocal && after.parentLocalID == previews.parentLocalID && after.visibility == .public)

        // References inside the local type belong to it; the type's name still shadows outer declarations.
        #expect(refs("Sendable", in: analysis).first?.enclosingSymbol == plan.localID)
        #expect(refs("length", in: analysis).contains { $0.receiver == nil && $0.enclosingSymbol == symbol("size", in: analysis)?.localID })
        #expect(refs("length", in: analysis).contains { $0.receiver == "plan" && $0.enclosingSymbol == previews.localID })
        #expect(refs("PreviewPlan", in: analysis).isEmpty)
    }

    // MARK: - Stop list

    @Test func onlyUnqualifiedFreeFunctionCallsAndStdlibTypesAreSkipped() throws {
        let analysis = try analyze("""
        final class JournalWriter {
            var count = 0
            func append(payload: Data) {}
            func flush(values: [Int], item: Item) {
                append(payload: Data())
                print(type(of: item), min(1, 2), values.min() ?? 0, item.type, count)
                let bound = max
                _ = (bound, String(describing: item), Task { })
            }
        }
        """)
        #expect(refs("append", in: analysis).map(\.receiver) == [nil], "an unqualified member call is emitted")
        #expect(refs("print", in: analysis).isEmpty)
        #expect(refs("type", in: analysis).map(\.receiver) == ["item"], "`type(of:)` is skipped, `item.type` is not")
        #expect(refs("min", in: analysis).map(\.receiver) == ["values"])
        #expect(refs("max", in: analysis).map(\.kind) == [.read], "only calls of free functions are skipped")
        #expect(refs("count", in: analysis).map(\.receiver) == [nil])
        #expect(refs("String", in: analysis).isEmpty && refs("Task", in: analysis).isEmpty && refs("Int", in: analysis).isEmpty)
        #expect(refs("Data", in: analysis).count == 2)
    }

    @Test func everyAlwaysEmittedMemberNameStaysOnTheLinkerFallbackStoplist() {
        // Emitting `count`/`append` is safe only while the linker refuses to bind them by name alone.
        #expect(SwiftSyntaxSupport.memberNoise.isSubset(of: FallbackStoplist.names))
        let untracked = AnalyzerStopLists.untrackedNames(language: .swift)
        #expect(untracked.isSuperset(of: ["print", "String", "fatalError", "Task", "type"]))
        #expect(untracked.isDisjoint(with: ["count", "append", "map", "isEmpty", "description"]))
        #expect(!AnalyzerStopLists.untrackedNames(language: .typescript).isEmpty)
    }

    @Test func everySiteIsEmittedOnce() throws {
        // The index keeps one row per site and folds exact repeats, so a repeat would hide a bug.
        let analysis = try analyze(SwiftAnalyzerTests.authService + """

        struct Card: View {
            @Environment(\\.dismiss) private var dismiss
            var body: some View {
                Text("x")
                #if os(iOS)
                    .padding(.horizontal)
                #endif
                Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
            }
            func pick(_ mode: Mode) -> Mode {
                switch mode { case .a(let v) where v > 0: return .b(v) default: return Mode.init(raw: 0) }
            }
            func launchApp() {
                var env: [String: String] = ["A": "1"]
                env["B"] = ProcessInfo.processInfo.environment["B"]
                env.merge(["C": "3"]) { $1 }
                let app = XCUIApplication()
                app.launchEnvironment = env
                app.launchEnvironment["D"] = "4"
                app.launchArguments += ["-x"]
                launch(environment: ["E": "5"], launchArguments: ["-y"])
            }
        }
        """)
        struct Site: Hashable { let line: Int, column: Int, name: String, kind: ReferenceKind, receiver: String? }
        let sites = analysis.references.map { Site(line: $0.line, column: $0.column, name: $0.name, kind: $0.kind, receiver: $0.receiver) }
        #expect(Set(sites).count == sites.count)
        #expect(analysis.references.filter { $0.name.hasPrefix("env:") }.map(\.name).sorted() == [
            "env:A", "env:B", "env:B", "env:C", "env:D", "env:E", "env:arg:-x", "env:arg:-y",
        ], "a write of B and a read of B")
        #expect(analysis.references.allSatisfy { ($0.statementLine ?? 0) <= $0.line && $0.line <= ($0.endLine ?? .max) })
    }

    // MARK: - Receiver types

    /// `hint → name@line` for a reference's receiver: the hint (or `-`), and the reference `^` points at.
    private func receiver(_ reference: ExtractedReference?, in analysis: FileAnalysis) -> String {
        guard let reference else { return "none" }
        let target = reference.receiverRef.map { " → \(analysis.references[$0].name)@\(analysis.references[$0].line)" } ?? ""
        return (reference.receiverHint ?? "-") + target
    }

    private func declared(_ symbol: ExtractedSymbol?, in analysis: FileAnalysis) -> String {
        guard let symbol else { return "none" }
        let target = symbol.declaredTypeRef.map { " → \(analysis.references[$0].name)@\(analysis.references[$0].line)" } ?? ""
        return (symbol.declaredType ?? "-") + target
    }

    @Test func localsAndParametersCarryTheirTypes() throws {
        let analysis = try analyze("""
        enum Pipeline {
            static func encodeOne(_ text: String, encoder: some TextEncoding, cache: Memo?, items: Item...) async throws {
                let key = CacheKey.make(text: text)
                var vector = try await encoder.encode(text)
                let store = SessionStore()
                store.save(key)
                let plans: [PreviewPlan] = []
                for plan in plans { use(plan.length) }
                if let cached = await cache?.get(key) { cached.drop() }
                let (ids, pages): ([UInt64], [PageMeta]) = load()
                pages.first?.offset
                let unknown = makeIt()
                unknown.go()
                items.first?.title
                func helper() -> Report { Report() }
                helper().publish()
                let label = "x"
                label.uppercased()
                vector.append(ids.count)
                let parsed = { () -> Int in 1 }()
                parsed.signum()
            }
        }
        """)
        func first(_ name: String) -> ExtractedReference? { refs(name, in: analysis).first }
        #expect(receiver(first("encode"), in: analysis) == "TextEncoding", "`some P` is P")
        #expect(first("encode")?.typeEvidenceLine == 2, "the parameter's line")
        #expect(receiver(first("save"), in: analysis) == "^ → SessionStore@5", "an instantiation is typed by its reference")
        #expect(first("save")?.typeEvidenceLine == 5)
        #expect(receiver(first("length"), in: analysis) == "PreviewPlan", "an element of an annotated array")
        #expect(receiver(first("drop"), in: analysis) == "^ → get@9", "`if let` binds what the call returns")
        #expect(receiver(first("get"), in: analysis) == "Memo", "an optional parameter")
        #expect(receiver(first("offset"), in: analysis) == "PageMeta", "`first` of a typed array, through a tuple pattern")
        #expect(receiver(first("go"), in: analysis) == "^ → makeIt@12")
        #expect(receiver(first("title"), in: analysis) == "Item", "a variadic parameter is an array")
        #expect(receiver(first("publish"), in: analysis) == "Report", "a local function's return type")
        #expect(receiver(first("uppercased"), in: analysis) == "String")
        #expect(receiver(first("append"), in: analysis) == "^ → encode@4", "a local bound to a call")
        #expect(first("signum")?.receiverHint == "?" && first("signum")?.receiverRef == nil,
                "a local whose type is unknown is `?`, never a property")
        #expect(receiver(first("make"), in: analysis) == "-", "a type's member: the receiver text names the type")
    }

    @Test func membersOfPropertiesAndChainsPointAtTheirProducers() throws {
        let analysis = try analyze("""
        struct TodaysReadingCard: View {
            @ObservedObject private var subscriptions = PremiumStore.shared
            @Query(sort: \\ReadingPlan.createdAt) private var plans: [ReadingPlan]
            var body: some View {
                Text("x").task { await subscriptions.start() }
            }
            private var hasFreeDay: Bool {
                return plans.contains { plan in
                    plan.schedule(now: today)?.day(weekday)?.isOpen == true
                }
            }
            func names() -> [String] { plans.map { $0.template.name } + self.plans.sorted().map(\\.title) }
        }
        final class PremiumStore: ObservableObject {
            static let shared = PremiumStore()
        }
        """)
        func first(_ name: String) -> ExtractedReference? { refs(name, in: analysis).first }
        #expect(receiver(first("start"), in: analysis) == "- → subscriptions@5", "a property's member points at the read")
        #expect(receiver(first("schedule"), in: analysis) == "elem(^) → plans@8", "a closure parameter over a property")
        #expect(receiver(first("day"), in: analysis) == "- → schedule@9", "each segment points at the one before")
        #expect(receiver(first("isOpen"), in: analysis) == "- → day@9")
        #expect(receiver(first("template"), in: analysis) == "elem(^) → plans@12", "`$0` of `map`")
        #expect(receiver(first("name"), in: analysis) == "- → template@12")
        #expect(receiver(first("sorted"), in: analysis) == "- → plans@12")
        #expect(receiver(refs("map", in: analysis).last, in: analysis) == "- → plans@12", "`sorted()` keeps the sequence")

        #expect(declared(symbol("subscriptions", in: analysis), in: analysis) == "^ → shared@2")
        #expect(declared(symbol("shared", in: analysis), in: analysis) == "^ → PremiumStore@15")
        #expect(declared(symbol("plans", in: analysis), in: analysis) == "[ReadingPlan]", "a wrapper's annotation is the wrapped value")
        #expect(declared(symbol("hasFreeDay", in: analysis), in: analysis) == "Bool")
        #expect(declared(symbol("names", in: analysis), in: analysis) == "[String]")
    }

    @Test func declaredTypesCoverEveryKindOfDeclaration() throws {
        let analysis = try analyze("""
        struct Builder {
            @Environment(\\.modelContext) private var context
            @Environment(LibraryStore.self) private var store
            @AppStorage("units") var units = "metric"
            var a, b: Int
            static func classifyBook(_ book: Book) -> (label: String, reason: String)? { nil }
            func make<T: Store>(_ kind: T.Type) -> T { fatalError() }
            func copy() -> Self { self }
            init(seed: Int) {}
            subscript(index: Int) -> Page { pages[index] }
            enum Phase { case warmUp, main(Int) }
            func run() {
                struct Local { func size() -> Int { 0 } }
            }
        }
        """)
        func type(_ name: String) -> String { declared(symbol(name, in: analysis), in: analysis) }
        #expect(type("context") == "ModelContext")
        #expect(type("store") == "LibraryStore")
        #expect(type("units") == "String")
        #expect(type("a") == "Int" && type("b") == "Int", "`var a, b: Int` shares the annotation")
        #expect(type("classifyBook") == "(label: String, reason: String)", "tuple labels are kept")
        #expect(type("make") == "Store", "a generic return type is its constraint")
        #expect(type("copy") == "Builder", "`Self` is the enclosing type")
        #expect(type("init") == "Builder" && type("subscript") == "Page")
        #expect(type("warmUp") == "Builder.Phase" && type("main") == "Builder.Phase", "a case produces its enum")
        #expect(type("size") == "Int" && type("run") == "-")
    }

    @Test func closureParametersAreTypedByTheCallTheyArePassedTo() throws {
        let analysis = try analyze("""
        func check(writer: JournalWriter, items: [Book], table: [String: Page]) throws {
            let reader = JournalReader(file: file)
            let entries = try reader.scanEntries(from: 0)
            let decoded = entries.compactMap { entry -> Data? in
                if case .entry(_, _, let body) = entry.content { return body }
                return nil
            }
            _ = entries.compactMap { $0.content.seq }
            items.sorted { $0.date < $1.end }
            items.enumerated().forEach { index, book in book.close(index) }
            for (key, page) in table { page.open(key) }
            ForEach(items, id: \\.id) { row in row.render() }
            let total = items.reduce(0) { partial, book in partial + book.cost }
            items.forEach { [weak delegate] in delegate?.flush($0.id) }
            others.map { $0.bad() }
        }
        """)
        func first(_ name: String) -> ExtractedReference? { refs(name, in: analysis).first }
        #expect(receiver(refs("content", in: analysis).first, in: analysis) == "elem(^) → scanEntries@3")
        #expect(receiver(first("seq"), in: analysis) == "- → content@8")
        #expect(receiver(first("date"), in: analysis) == "Book" && receiver(first("end"), in: analysis) == "Book")
        #expect(receiver(first("close"), in: analysis) == "Book", "the element half of `enumerated()`")
        #expect(receiver(first("open"), in: analysis) == "Page", "a dictionary's value")
        #expect(receiver(first("render"), in: analysis) == "Book", "SwiftUI `ForEach` rows")
        #expect(receiver(first("cost"), in: analysis) == "Book")
        #expect(receiver(first("flush"), in: analysis) == "- → delegate@14", "`[weak delegate]` keeps the outer meaning")
        #expect(refs("delegate", in: analysis).count == 1, "the captured property is read in the closure")
        #expect(receiver(refs("id", in: analysis).last, in: analysis) == "Book", "`$0` after a capture list")
        #expect(receiver(first("bad"), in: analysis) == "elem(^) → others@15")
        _ = analysis
    }

    @Test func implicitMembersCarryTheirContext() throws {
        let analysis = try analyze("""
        struct Reader {
            var mode: Mode = .idle
            func scan(header: Header, state: State, style: Style = .plain) -> Output {
                if header.flags.contains(.isBlank) { skip() }
                let tint: Color = .red
                switch state {
                case .loaded(let value): show(value)
                default: break
                }
                if state == .empty || .failed != state { retry() }
                mode = .edit
                view.font(.system(size: 12, weight: .bold))
                let palette: [Color] = [.green, .blue]
                let pick: Mode = ready ? .busy : .idle
                Text("x").foregroundStyle(.secondary.opacity(0.5))
                return .done
            }
            var fallback: Output { .none }
        }
        """)
        func first(_ name: String) -> String { receiver(refs(name, in: analysis).first, in: analysis) }
        #expect(first("isBlank") == "ctx(^) → flags@4", "an option-set operation on a typed base")
        #expect(first("red") == "ctx(Color)")
        #expect(first("loaded") == "ctx(State)", "a `case` of the switch subject")
        #expect(first("empty") == "ctx(State)" && first("failed") == "ctx(State)", "the other side of `==`/`!=`")
        #expect(first("edit") == "ctx(^) → mode@11", "the assigned property")
        #expect(first("system") == "param(^,0) → font@12", "an argument: the callee's parameter")
        #expect(first("bold") == "param(^,1) → system@12")
        #expect(first("green") == "ctx(Color)" && first("blue") == "ctx(Color)", "array elements of an annotated array")
        #expect(first("busy") == "ctx(Mode)" && receiver(refs("idle", in: analysis).last, in: analysis) == "ctx(Mode)", "both branches")
        #expect(first("secondary") == "param(^,0) → foregroundStyle@15", "the root of an implicit member chain")
        #expect(first("done") == "ctx(Output)" && first("none") == "ctx(Output)", "`return` and a single-expression body")
        #expect(first("plain") == "ctx(Style)", "a default argument")
        #expect(receiver(refs("idle", in: analysis).first, in: analysis) == "ctx(Mode)", "a property's annotation")
    }

    @Test func casePatternsAndCastsBindTypes() throws {
        let analysis = try analyze("""
        func handle(result: Outcome, value: Any, items: [Book]) {
            switch value {
            case let book as Book: book.close()
            default: break
            }
            if case let found? = items.first { found.open() }
            do { try work() } catch let failure as LoadError { failure.report() } catch { error.log() }
            let cast = value as? Page ?? Page()
            cast.walk()
            for case let book? in maybeBooks { book.archive() }
            if let x = items.last, x.isDone { x.finish() }
            let isPage = value is Page
            isPage.negate()
        }
        """)
        func first(_ name: String) -> String { receiver(refs(name, in: analysis).first, in: analysis) }
        #expect(first("close") == "Book")
        #expect(first("open") == "Book", "`case let x?` binds the unwrapped value")
        #expect(first("report") == "LoadError" && first("log") == "Error")
        #expect(first("walk") == "Page")
        #expect(first("archive") == "elem(^) → maybeBooks@10")
        #expect(first("finish") == "Book" && first("isDone") == "Book")
        #expect(first("negate") == "Bool", "`x is T` is a check, not an `x`")
    }

    @Test func wellKnownAPIsKeyPathsAndOperatorsAreTyped() throws {
        let analysis = try analyze("""
        struct MapScreen: View {
            @Environment(\\.horizontalSizeClass) private var sizeClass
            var body: some View {
                GeometryReader { proxy in Text("x").frame(width: proxy.size.width) }
                    .onGeometryChange(for: CGFloat.self) { geometry in geometry.size.height } action: { height in height.rounded() }
            }
            func load(days: [Day], app: XCUIApplication) async {
                let names = days.map(\\.title.text)
                for index in 0..<days.count { days[index].close() }
                for index in days.indices { days[index - 1].open() }
                let value = await withCheckedContinuation { continuation in continuation.resume(returning: 1) }
                app.buttons["Save"].firstMatch.tap()
                let isLate = days.count > 3 && names.isEmpty
                isLate.toggle()
            }
        }
        """)
        func first(_ name: String) -> String { receiver(refs(name, in: analysis).first, in: analysis) }
        #expect(first("horizontalSizeClass") == "EnvironmentValues", "`@Environment(\\.key)` starts at EnvironmentValues")
        #expect(first("size") == "GeometryProxy" && receiver(refs("size", in: analysis).last, in: analysis) == "GeometryProxy")
        #expect(first("rounded") == "CGFloat", "`action:` receives the `for:` value")
        #expect(first("title") == "Day" && first("text") == "- → title@8", "`map(\\.title.text)` starts at an element")
        #expect(first("close") == "Day", "an Int range subscripts an array")
        #expect(first("open") == "Day", "`index - 1` is still an Int")
        #expect(first("resume") == "CheckedContinuation")
        #expect(first("firstMatch") == "XCUIElement" && first("tap") == "XCUIElement")
        #expect(first("toggle") == "Bool")
    }

    @Test func eachInferenceRuleCanBeSwitchedOff() throws {
        let source = """
        func run(items: [Book]) {
            items.forEach { book in book.close() }
            let tint: Color = .red
        }
        """
        let file = SourceFile(path: "Sources/App/Feature.swift", language: .swift, text: source)
        let all = SwiftAnalyzer.extract(file)
        #expect(all.references.first { $0.name == "close" }?.receiverHint == "Book")
        let off = SwiftAnalyzer.extract(file, disabledRules: [.closureElement, .contextAnnotation])
        #expect(off.references.first { $0.name == "close" }?.receiverHint == "?", "the closure parameter is a local of unknown type")
        #expect(off.references.first { $0.name == "red" }?.receiverHint == nil)
        #expect(SwiftTypeInference.rules(named: "closureElement, nope,parameter") == [.closureElement, .parameter])
        #expect(SwiftTypeInference.rules(named: "all").count == SwiftTypeInference.Rule.allCases.count)
    }

    // MARK: - String literals

    private func literal(_ value: String, in analysis: FileAnalysis) -> ExtractedLiteral? {
        analysis.literals.first { $0.value == value }
    }

    /// `context callee label`, e.g. `ui Text -`.
    private func describe(_ literal: ExtractedLiteral?) -> String {
        guard let literal else { return "none" }
        return "\(literal.context) \(literal.callee ?? "-") \(literal.label ?? "-")"
    }

    @Test func literalsRecordWhereTheirValueGoes() throws {
        let analysis = try analyze("""
        struct ProfileView: View {
            @AppStorage("hasSeenIntro") private var completed = false
            @State private var restoreMessage = ""
            let title = "Profile settings"
            var body: some View {
                VStack {
                    Text("Unlock Atlas Premium")
                    Label("Restore purchases", systemImage: "arrow.clockwise")
                    Text(name ?? "Guest user")
                    Text(verbatim: isOn ? "Switched on" : "Switched off")
                    #if DEBUG
                    Button("Skip (dev only)") { skip() }
                    #endif
                }
                .navigationTitle("Your profile")
                .accessibilityIdentifier("profile-root")
            }
            func restore() {
                restoreMessage = "Your premium plan is active."
                greet("Hello there", to: ("World"))
                let rows = ["Books", "Settings"]
                let message = "Restored \\(restoreMessage) at \\(format("long date"))"
                if restoreMessage == "Nothing found" {}
            }
            var footer: String { "Made with care" }
            func code() -> String { return "promo code" }
        }
        enum Plan: String { case premium = "premium-yearly" }
        """)
        #expect(describe(literal("hasSeenIntro", in: analysis)) == "call-arg AppStorage -")
        #expect(describe(literal("Profile settings", in: analysis)) == "initializer title -")
        #expect(describe(literal("Unlock Atlas Premium", in: analysis)) == "ui Text -")
        #expect(describe(literal("Restore purchases", in: analysis)) == "ui Label -")
        #expect(describe(literal("arrow.clockwise", in: analysis)) == "call-arg Label systemImage", "a symbol name is not text")
        #expect(describe(literal("Guest user", in: analysis)) == "ui Text -", "a `??` fallback goes where the expression goes")
        #expect(describe(literal("Switched on", in: analysis)) == "ui Text verbatim")
        #expect(describe(literal("Switched off", in: analysis)) == "ui Text verbatim")
        #expect(describe(literal("Your profile", in: analysis)) == "ui navigationTitle -")
        #expect(describe(literal("profile-root", in: analysis)) == "ui accessibilityIdentifier -")
        #expect(describe(literal("Your premium plan is active.", in: analysis)) == "assign restoreMessage -")
        #expect(describe(literal("Hello there", in: analysis)) == "call-arg greet -")
        #expect(describe(literal("World", in: analysis)) == "call-arg greet to", "parentheses are looked through")
        #expect(describe(literal("Books", in: analysis)) == "array - -")
        #expect(describe(literal("long date", in: analysis)) == "call-arg format -", "a literal inside an interpolation is its own")
        #expect(describe(literal("Nothing found", in: analysis)) == "other - -")
        #expect(describe(literal("Made with care", in: analysis)) == "return - -")
        #expect(describe(literal("promo code", in: analysis)) == "return - -")
        #expect(describe(literal("premium-yearly", in: analysis)) == "initializer premium -")
        #expect(!analysis.literals.contains { $0.value.hasPrefix("Restored") }, "an interpolated literal is not a value")
        #expect(refs("restoreMessage", in: analysis).contains { $0.line == 22 }, "what it interpolates is still a reference")
        #expect(refs("format", in: analysis).count == 1)

        let skip = try #require(literal("Skip (dev only)", in: analysis))
        #expect(skip.conditions == ["DEBUG"] && skip.line == 12)
        let active = try #require(literal("Your premium plan is active.", in: analysis))
        #expect(active.enclosingSymbol.map { analysis.symbols[$0].name } == "restore")
        #expect(active.line == 19 && active.column == 26)
    }

    @Test func uiTestQueriesAndHelpersKeepTheirLookups() throws {
        let analysis = try analyze("""
        final class PaywallTests: XCTestCase {
            func testRestore() {
                let app = XCUIApplication()
                app.buttons["Restore purchases"].tap()
                XCTAssertTrue(app.staticTexts["Unlock Atlas Premium"].waitForExistence(timeout: 5))
                XCTAssertTrue(message.contains("Your premium plan is active."))
                expect(text("Welcome back"), "the greeting shows")
                let cell = app.descendants(matching: .any)["book-row"]
            }
        }
        """)
        #expect(describe(literal("Restore purchases", in: analysis)) == "ui buttons -")
        #expect(describe(literal("Unlock Atlas Premium", in: analysis)) == "ui staticTexts -")
        #expect(describe(literal("Your premium plan is active.", in: analysis)) == "call-arg contains -")
        #expect(describe(literal("Welcome back", in: analysis)) == "call-arg text -")
        #expect(describe(literal("the greeting shows", in: analysis)) == "call-arg expect -")
        #expect(describe(literal("book-row", in: analysis)) == "ui descendants -")
        #expect(analysis.literals.count == 6)
        #expect(analysis.literals.allSatisfy { $0.enclosingSymbol.map { analysis.symbols[$0].name } == "testRestore" })
    }

    @Test func shortLetterlessAndLongLiteralsAreNotRecorded() throws {
        let long = String(repeating: "a", count: 201)
        let analysis = try analyze(#"""
        func values() {
            let a = "1"
            let b = "%@"
            let c = "x"
            let d = "\#(long)"
            let e = "ok"
            let f = #"raw "quoted" text"#
            let g = """
                first line
                second line
                """
        }
        """#)
        #expect(analysis.literals.map(\.value) == ["ok", #"raw "quoted" text"#, "first line\nsecond line"])
    }

    // MARK: - Environment variables and launch arguments

    /// `name kind context line` of every `env:` reference, in source order.
    private func environment(_ analysis: FileAnalysis) -> [String] {
        analysis.references.filter { $0.name.hasPrefix("env:") }
            .sorted { ($0.line, $0.column) < ($1.line, $1.column) }
            .map { "\($0.name) \($0.kind.rawValue) \($0.context ?? "-") \($0.line)" }
    }

    @Test func environmentReadsAreEnvReferences() throws {
        let analysis = try analyze("""
        final class PremiumStore {
            func start() async {
                #if DEBUG
                if ProcessInfo.processInfo.environment["ATLAS_SKIP_INTRO"] == "1" {
                    isSubscribed = true
                }
                #endif
                let env = ProcessInfo.processInfo.environment
                if let demo = env["DEMO_LIBRARY"], !demo.isEmpty {}
                let info = ProcessInfo.processInfo
                if !info.arguments.contains("-FIRDebugEnabled") {}
                let role = ProcessInfo.processInfo.environment[roleKey]
                let home = getenv("HOME")
            }
            static func isRequested(environment: [String: String]) -> Bool {
                environment["SHELF_DEMO"] == "1"
            }
            func headers() {
                let headers: [String: String] = ["Accept": "json"]
                _ = headers["Authorization"]
                var cache = ["key": "value"]
                cache["other"] = "x"
                _ = items[index]
            }
        }
        """)
        #expect(environment(analysis) == [
            "env:ATLAS_SKIP_INTRO read env 4",
            "env:DEMO_LIBRARY read env 9",
            "env:arg:-FIRDebugEnabled read env 11",
            "env:* read env-dynamic 12",
            "env:HOME read env 13",
            "env:SHELF_DEMO read env 16",
        ])
        let skip = try #require(refs("env:ATLAS_SKIP_INTRO", in: analysis).first)
        #expect(skip.enclosingSymbol.map { analysis.symbols[$0].name } == "start")
        #expect(skip.conditions == ["DEBUG"] && skip.statementLine == 4)
        #expect(skip.receiver == "ProcessInfo.processInfo.environment")
        #expect(refs("isSubscribed", in: analysis).first?.kind == .write)
        // The key is a literal too.
        #expect(describe(literal("ATLAS_SKIP_INTRO", in: analysis)) == "subscript environment -")
    }

    @Test func launchConfigurationWritesAreEnvReferences() throws {
        let analysis = try analyze("""
        class UITestBase: XCTestCase {
            private var lastEnvironment: [String: String] = [:]
            func launch(_ start: Start, environment: [String: String] = [:], arguments: [String] = []) -> XCUIApplication {
                var env: [String: String] = ["QUIET_MODE": "1"]
                var args: [String] = []
                switch start {
                case .signedIn:
                    env["ATLAS_SKIP_INTRO"] = "1"
                    args += ["-hasSeenIntro", "YES"]
                default:
                    break
                }
                env.merge(environment) { _, new in new }
                args += arguments
                let app = XCUIApplication()
                app.launchEnvironment = env
                app.launchArguments = args
                app.launchEnvironment["DEMO_LIBRARY"] = "1"
                app.launchArguments.append("-UITests")
                lastEnvironment = env
                return app
            }
            func relaunch() {
                var env = lastEnvironment
                env.removeValue(forKey: "RESET_LIBRARY")
                app.launchEnvironment = env
            }
            func testIntro() {
                launch(.firstRun, environment: ["ATLAS_SKIP_INTRO": "1"])
                var headers = ["Accept": "json"]
                headers["X-Token"] = "t"
                send(headers)
            }
        }
        """)
        #expect(environment(analysis) == [
            "env:QUIET_MODE write env 4",
            "env:ATLAS_SKIP_INTRO write env 8",
            "env:arg:-hasSeenIntro write env 9",
            "env:DEMO_LIBRARY write env 18",
            "env:arg:-UITests write env 19",
            "env:RESET_LIBRARY write delete 25",
            "env:ATLAS_SKIP_INTRO write env 29",
        ])
        let write = try #require(refs("env:ATLAS_SKIP_INTRO", in: analysis).first { $0.line == 8 })
        #expect(write.enclosingSymbol.map { analysis.symbols[$0].name } == "launch" && write.receiver == "env")
        #expect(write.statementLine == 8 && write.endLine == 8)
        let launch = try #require(refs("env:ATLAS_SKIP_INTRO", in: analysis).first { $0.line == 29 })
        #expect(launch.enclosingSymbol.map { analysis.symbols[$0].name } == "testIntro")
    }

    // MARK: - Through the index

    @Test func theIndexStoresReceiverPointersAsRowIDs() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/ContentView.swift": """
                struct ContentView {
                    private var subscriptions = PremiumStore.shared
                    func appear() { subscriptions.start() }
                    func scan(header: Header) { if header.flags.contains(.isBlank) {} }
                }
                final class PremiumStore {
                    static let shared = PremiumStore()
                    func start() {}
                }
                """,
        ], name: "collector-e2")
        let start = try engine.rawQuery("""
            SELECT r.receiver_hint, p.name, p.line FROM refs r JOIN refs p ON p.id = r.receiver_ref WHERE r.name = 'start'
            """)
        #expect(start.rows.first.map { $0.map(\.stringValue) } == [nil, "subscriptions", "3"])
        let padding = try engine.rawQuery("""
            SELECT r.receiver_hint, p.name FROM refs r JOIN refs p ON p.id = r.receiver_ref WHERE r.name = 'isBlank'
            """)
        #expect(padding.rows.first.map { $0.map(\.stringValue) } == ["ctx(^)", "flags"])
        let declared = try engine.rawQuery("""
            SELECT s.name, s.declared_type, p.name, p.line FROM symbols s JOIN refs p ON p.id = s.declared_type_ref ORDER BY s.name
            """)
        #expect(declared.rows.map { $0.map(\.stringValue) } == [
            ["shared", "^", "PremiumStore", "7"], ["subscriptions", "^", "shared", "2"],
        ])
    }

    @Test func theIndexStoresTheNewColumns() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/Planner.swift": """
                struct Planner {
                    func importBook(from url: URL, preferences: Int = 0) {}

                    func run() {
                        #if DEBUG
                        importBook(
                            from: url, preferences: 1)
                        #endif
                        let tint: Color = .red
                    }
                }
                """,
        ], name: "collector-v4")
        let call = try engine.rawQuery("""
            SELECT line, call_end_line, stmt_line, end_line, arg_labels, conditions, context, target_symbol_id IS NOT NULL
            FROM refs WHERE name = 'importBook'
            """)
        #expect(call.rows.count == 1)
        let row = try #require(call.rows.first)
        #expect(row[0].intValue == 6 && row[1].intValue == 7 && row[2].intValue == 6 && row[3].intValue == 7)
        #expect(row[4].stringValue == "from,preferences" && row[5].stringValue == "DEBUG" && row[6].stringValue == "call")
        #expect(row[7].intValue == 1, "a self call still resolves")

        let declaration = try engine.rawQuery("SELECT selector, param_flags, param_types FROM symbols WHERE name = 'importBook'")
        #expect(declaration.rows.first?.map(\.stringValue) == ["importBook(from:preferences:)", "-d", "URL|Int"])

        let implicit = try engine.rawQuery("SELECT receiver, context, target_symbol_id FROM refs WHERE name = 'red'")
        #expect(implicit.rows.first?[0].stringValue == "." && implicit.rows.first?[1].stringValue == "implicit")
        #expect(implicit.rows.first?[2] == .null, "an implicit member is never bound by name")
    }

    @Test func theIndexStoresLiteralsAndEnvironmentReferences() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/ProfileView.swift": """
                struct ProfileView {
                    func restore() {
                        #if DEBUG
                        restoreMessage = "Your premium plan is active."
                        #endif
                        if ProcessInfo.processInfo.environment["SKIP_PAYWALL"] == "1" { unlock() }
                    }
                    func unlock() {}
                }
                """,
        ], name: "collector-literals")
        let literals = try engine.rawQuery("""
            SELECT l.value, l.line, l.col, l.context, l.callee, l.conditions, s.name
            FROM literals l JOIN symbols s ON s.id = l.symbol_id ORDER BY l.line
            """)
        #expect(literals.rows.map { $0.map(\.stringValue) } == [
            ["Your premium plan is active.", "4", "26", "assign", "restoreMessage", "DEBUG", "restore"],
            ["SKIP_PAYWALL", "6", "48", "subscript", "environment", nil, "restore"],
        ])
        let environment = try engine.rawQuery("""
            SELECT r.name, r.kind, r.context, r.line, s.name, r.resolved, r.target_symbol_id IS NULL
            FROM refs r JOIN symbols s ON s.id = r.from_symbol_id WHERE r.name LIKE 'env:%'
            """)
        #expect(environment.rows.map { $0.map(\.stringValue) } == [["env:SKIP_PAYWALL", "read", "env", "6", "restore", "1", "1"]])
    }
}
