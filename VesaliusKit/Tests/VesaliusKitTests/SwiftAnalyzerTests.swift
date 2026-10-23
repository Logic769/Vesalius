import Foundation
import Testing
@testable import LanguageAnalysis
import VesaliusCore

@Suite("Swift analyzer")
struct SwiftAnalyzerTests {
    let analyzer = SwiftAnalyzer()

    private func analyze(_ source: String, path: String = "Sources/App/Feature.swift") throws -> FileAnalysis {
        try analyzer.analyze(SourceFile(path: path, language: .swift, text: source))
    }

    // MARK: - Contract

    @Test func identifiesItselfAndClaimsOnlySwift() {
        #expect(analyzer.identifier == "swift-syntax")
        #expect(analyzer.canAnalyze(.swift, path: "a.swift"))
        #expect(!analyzer.canAnalyze(.typescript, path: "a.ts"))
        #expect(!analyzer.canAnalyze(.python, path: "a.py"))
    }

    // MARK: - Symbols

    static let authService = """
    import Foundation
    import Combine

    /// Coordinates sign-in and token refresh.
    ///
    /// Long discussion that should not be part of the summary.
    public final class AuthService: NSObject, ObservableObject, @unchecked Sendable {
        public static let shared = AuthService()
        @Published private(set) var session: Session?
        var isLoggedIn: Bool { session != nil }
        private let client: APIClient, store: TokenStore

        enum State {
            case idle, loading
            /// Sign-in failed.
            case failed(Error)
        }

        struct Token: Codable {
            let value: String
            let expires: Date
        }

        init(client: APIClient = APIClient(), store: TokenStore = .shared) {
            self.client = client
            self.store = store
            super.init()
        }

        public func signIn(email: String, password: String) async throws -> Session {
            let request = LoginRequest(email: email, password: password)
            let response = try await client.send(request)
            func remember(_ token: Token) { store.save(token) }
            struct Audit { let at: Date }
            remember(response.token)
            session = response.session
            return response.session
        }

        deinit {
            let pending = 0
            _ = pending
        }
    }

    extension AuthService {
        func signOut() {
            session = nil
            Analytics.track("sign_out")
        }
    }
    """

    @Test func extractsTypesMembersAndNesting() throws {
        let analysis = try analyze(Self.authService)
        let names = analysis.symbols.map { "\(qualifiedName($0, in: analysis)):\($0.kind.rawValue)" }
        #expect(names == [
            "AuthService:class",
            "AuthService.shared:property",
            "AuthService.session:property",
            "AuthService.isLoggedIn:property",
            "AuthService.client:property",
            "AuthService.store:property",
            "AuthService.State:enum",
            "AuthService.State.idle:case",
            "AuthService.State.loading:case",
            "AuthService.State.failed:case",
            "AuthService.Token:struct",
            "AuthService.Token.value:property",
            "AuthService.Token.expires:property",
            "AuthService.init:initializer",
            "AuthService.signIn:method",
            "AuthService.signIn.Audit:struct",
            "AuthService.signIn.Audit.at:property",
            "AuthService:extension",
            "AuthService.signOut:method",
        ])

        // Parents always precede children and local ids are array indices.
        for (index, symbol) in analysis.symbols.enumerated() {
            #expect(symbol.localID == index)
            if let parent = symbol.parentLocalID { #expect(parent < index) }
        }
    }

    @Test func neverEmitsLocalsAsSymbols() throws {
        let analysis = try analyze(Self.authService)
        let names = Set(analysis.symbols.map(\.name))
        for local in ["request", "response", "remember", "pending", "email", "password"] {
            #expect(!names.contains(local), "\(local) is local and must not be a symbol")
        }
        // A function-local type is a symbol, but a local one: visible only inside `signIn`.
        let audit = try #require(symbol("Audit", in: analysis))
        #expect(audit.isLocal && !audit.isExported)
        #expect(qualifiedName(audit, in: analysis) == "AuthService.signIn.Audit")
        #expect(symbol("at", in: analysis)?.isLocal == true)
        #expect(analysis.symbols.filter(\.isLocal).map(\.name) == ["Audit", "at"])
    }

    @Test func recordsSignaturesDocsVisibilityAndAttributes() throws {
        let analysis = try analyze(Self.authService)
        let service = try #require(symbol("AuthService", kind: .class, in: analysis))
        #expect(service.signature == "public final class AuthService: NSObject, ObservableObject, @unchecked Sendable")
        #expect(service.doc == "Coordinates sign-in and token refresh.")
        #expect(service.visibility == .public)
        #expect(service.isExported)
        #expect(service.attributes.contains("final"))
        #expect(service.inheritedTypes == ["NSObject", "ObservableObject", "Sendable"])
        #expect(service.range == LineRange(7, 44))

        let signIn = try #require(symbol("signIn", in: analysis))
        #expect(signIn.signature == "public func signIn(email: String, password: String) async throws -> Session")
        #expect(signIn.attributes.contains("async"))
        #expect(signIn.attributes.contains("throws"))
        #expect(signIn.isExported)

        let shared = try #require(symbol("shared", in: analysis))
        #expect(shared.signature == "public static let shared = AuthService()")
        #expect(shared.attributes.contains("static"))

        let session = try #require(symbol("session", in: analysis))
        #expect(session.attributes.contains("@Published"))
        #expect(session.visibility == nil, "private(set) restricts the setter, not the declaration")
        #expect(session.signature == "@Published private(set) var session: Session?")
        #expect(session.setterVisibility == .private)

        let isLoggedIn = try #require(symbol("isLoggedIn", in: analysis))
        #expect(isLoggedIn.signature == "var isLoggedIn: Bool")

        let client = try #require(symbol("client", in: analysis))
        #expect(client.visibility == .private)
        #expect(client.signature == "private let client: APIClient")

        let failed = try #require(symbol("failed", in: analysis))
        #expect(failed.signature == "case failed(Error)")
        #expect(failed.doc == "Sign-in failed.")
        let idle = try #require(symbol("idle", in: analysis))
        #expect(idle.signature == "case idle")

        let initializer = try #require(symbol("init", in: analysis))
        #expect(initializer.signature == "init(client: APIClient = APIClient(), store: TokenStore = .shared)")
    }

    @Test func extensionMembersHangOffTheExtension() throws {
        let analysis = try analyze(Self.authService)
        let extensionSymbol = try #require(symbol("AuthService", kind: .extension, in: analysis))
        let signOut = try #require(symbol("signOut", in: analysis))
        #expect(signOut.parentLocalID == extensionSymbol.localID)
        #expect(qualifiedName(signOut, in: analysis) == "AuthService.signOut")
    }

    @Test func memberVisibilityFollowsExtensionsProtocolsAndEnums() throws {
        let analysis = try analyze("""
        public extension Store {
            func reset() {}
            private func purge() {}
        }
        public protocol Repository {
            associatedtype Item: Identifiable
            func load() async throws -> [Item]
        }
        public enum Mode { case light, dark
            func next() -> Mode { self }
        }
        """)
        #expect(symbol("reset", in: analysis)?.visibility == .public)
        #expect(symbol("reset", in: analysis)?.isExported == true)
        #expect(symbol("purge", in: analysis)?.visibility == .private)
        #expect(symbol("load", in: analysis)?.visibility == .public)
        #expect(symbol("Item", in: analysis)?.kind == .typeAlias)
        #expect(symbol("Item", in: analysis)?.inheritedTypes == ["Identifiable"])
        #expect(symbol("light", in: analysis)?.visibility == .public)
        #expect(symbol("next", in: analysis)?.visibility == nil, "enum methods default to internal")
    }

    @Test func coversRemainingDeclarationKinds() throws {
        let analysis = try analyze("""
        typealias Completion<T> = (Result<T, Error>) -> Void
        let apiVersion = 3
        var retryCount = 0
        actor Cache {
            subscript(key: String) -> Data? { storage[key] }
            private var storage: [String: Data] = [:]
        }
        @freestanding(expression)
        public macro stringify<T>(_ value: T) -> (T, String) = #externalMacro(module: "Macros", type: "StringifyMacro")
        func helper() {}
        struct Vector {
            static func + (lhs: Vector, rhs: Vector) -> Vector { lhs }
        }
        """)
        #expect(symbol("Completion", in: analysis)?.kind == .typeAlias)
        #expect(symbol("Completion", in: analysis)?.signature == "typealias Completion<T> = (Result<T, Error>) -> Void")
        #expect(symbol("apiVersion", in: analysis)?.kind == .constant)
        #expect(symbol("retryCount", in: analysis)?.kind == .variable)
        #expect(symbol("Cache", in: analysis)?.kind == .actor)
        #expect(symbol("subscript", in: analysis)?.kind == .method)
        #expect(symbol("subscript", in: analysis)?.signature == "subscript(key: String) -> Data?")
        #expect(symbol("stringify", in: analysis)?.kind == .macro)
        #expect(symbol("stringify", in: analysis)?.attributes.contains("@freestanding") == true)
        #expect(symbol("helper", in: analysis)?.kind == .function)
        let plus = try #require(symbol("+", in: analysis))
        #expect(plus.kind == .method)
        #expect(plus.attributes.contains("operator"))
        #expect(plus.attributes.contains("static"))
    }

    // MARK: - Imports

    @Test func extractsImports() throws {
        let analysis = try analyze("""
        import Foundation
        @testable import MyApp
        import struct Foundation.Date
        @_exported import CoreKit
        #if canImport(UIKit)
        import UIKit
        #endif
        """)
        #expect(analysis.imports.map(\.module) == ["Foundation", "MyApp", "Foundation", "CoreKit", "UIKit"])
        #expect(analysis.imports.map(\.line) == [1, 2, 3, 4, 6])
        #expect(analysis.imports.allSatisfy { $0.kind == .module })
        #expect(analysis.imports.filter(\.isReExport).map(\.module) == ["CoreKit"])
        #expect(analysis.references.isEmpty, "#if conditions are not references: \(analysis.references)")
    }

    // MARK: - References

    @Test func emitsCallsInstantiationsAndTypeUses() throws {
        let analysis = try analyze(Self.authService)
        let signIn = try #require(symbol("signIn", in: analysis))
        let fromSignIn = analysis.references.filter { $0.enclosingSymbol == signIn.localID }

        #expect(fromSignIn.contains { $0.name == "LoginRequest" && $0.kind == .instantiate && $0.receiver == nil })
        #expect(fromSignIn.contains { $0.name == "send" && $0.kind == .call && $0.receiver == "client" })
        #expect(fromSignIn.contains { $0.name == "client" && $0.kind == .read && $0.receiver == nil })
        #expect(fromSignIn.contains { $0.name == "session" && $0.kind == .write && $0.receiver == nil })
        #expect(fromSignIn.contains { $0.name == "session" && $0.kind == .read && $0.receiver == "response" })
        #expect(fromSignIn.contains { $0.name == "Session" && $0.kind == .typeUse })
        #expect(fromSignIn.contains { $0.name == "save" && $0.kind == .call && $0.receiver == "store" })

        let shared = try #require(symbol("shared", in: analysis))
        #expect(analysis.references.contains { $0.name == "AuthService" && $0.kind == .instantiate && $0.enclosingSymbol == shared.localID })

        let signOut = try #require(symbol("signOut", in: analysis))
        let fromSignOut = analysis.references.filter { $0.enclosingSymbol == signOut.localID }
        #expect(fromSignOut.contains { $0.name == "track" && $0.kind == .call && $0.receiver == "Analytics" })
        #expect(fromSignOut.contains { $0.name == "Analytics" && $0.kind == .typeUse && $0.receiver == nil })

        let initializer = try #require(symbol("init", in: analysis))
        let fromInit = analysis.references.filter { $0.enclosingSymbol == initializer.localID }
        #expect(fromInit.contains { $0.name == "client" && $0.kind == .write && $0.receiver == "self" })
        #expect(fromInit.contains { $0.name == "APIClient" && $0.kind == .instantiate })
        #expect(!fromInit.contains { $0.name == "init" }, "super.init delegates; it is not a reference")
    }

    @Test func emitsInheritanceAndConformances() throws {
        let analysis = try analyze(Self.authService + """

        struct Feed: View, Equatable {}
        class Repo: BaseRepository<User>, Loading {}
        protocol Store: AnyObject, Persisting {}
        extension Feed: Hashable {}
        """)
        func kinds(_ name: String) -> [ReferenceKind] { analysis.references.filter { $0.name == name }.map(\.kind) }
        #expect(kinds("NSObject") == [.inherit])
        #expect(kinds("ObservableObject") == [.conform])
        #expect(kinds("Sendable") == [.conform])
        #expect(kinds("View") == [.conform])
        #expect(kinds("Equatable") == [.conform])
        #expect(kinds("BaseRepository") == [.inherit])
        #expect(kinds("User") == [.typeUse], "generic arguments of an inherited type are type uses")
        #expect(kinds("Loading") == [.conform])
        #expect(kinds("Persisting") == [.conform])
        #expect(kinds("Hashable") == [.conform])
        #expect(kinds("Feed") == [.typeUse], "the extended type is a type use")
        #expect(kinds("Codable") == [.conform])
    }

    @Test func receiversDescribeTheBaseExpression() throws {
        let analysis = try analyze("""
        final class Screen: UIViewController {
            override func viewDidLoad() {
                super.viewDidLoad()
                self.refresh()
                Theme.Colors.apply()
                makeClient().fetch()
                delegate?.didFinish()
                let a = Foo.init()
                let b = Foo.Bar()
                let c = Box<Int>()
                let path = \\User.name
                let inferred: KeyPath<User, String> = \\.email
                let color: UIColor = .red
                cache[key] = nil
                register(&counter)
                (left, right) = (1, 2)
                _ = (a, b, c, path, inferred, color)
            }
        }
        """)
        func refs(_ name: String) -> [(ReferenceKind, String?)] {
            analysis.references.filter { $0.name == name }.map { ($0.kind, $0.receiver) }
        }
        #expect(refs("viewDidLoad").map(\.1) == ["super"])
        #expect(refs("refresh").map(\.1) == ["self"])
        #expect(refs("apply").map(\.1) == ["Theme.Colors"])
        #expect(refs("Colors").map(\.0) == [.typeUse])
        #expect(refs("Colors").map(\.1) == ["Theme"])
        #expect(refs("Theme").map(\.0) == [.typeUse])
        #expect(refs("fetch").map(\.1) == ["_"])
        #expect(refs("makeClient").map(\.0) == [.call])
        #expect(refs("didFinish").map(\.1) == ["delegate"])
        #expect(refs("Foo").map(\.0).contains(.instantiate))
        #expect(refs("Bar").map(\.0) == [.instantiate])
        #expect(refs("Bar").map(\.1) == ["Foo"])
        #expect(refs("Box").map(\.0) == [.instantiate])
        #expect(refs("name").map(\.0) == [.read])
        #expect(refs("name").map(\.1) == ["User"])
        #expect(refs("email").map(\.1) == ["_"])
        #expect(refs("red").map(\.0) == [.read], "implicit member expressions are emitted")
        #expect(refs("red").map(\.1) == ["."])
        #expect(refs("cache").map(\.0) == [.write])
        #expect(refs("counter").map(\.0) == [.write])
        #expect(refs("left").map(\.0) == [.write])
        #expect(refs("right").map(\.0) == [.write])
    }

    @Test func propertyWrappersAndMacrosAreReferences() throws {
        let analysis = try analyze("""
        import SwiftUI

        @Observable @MainActor
        final class Model {
            @ObservationIgnored @Injected var api: APIClient
            @objc dynamic var flag = false
        }

        struct ContentView: View {
            @State private var model = Model()
            @AppStorage("theme") var theme = "light"
            var body: some View { Text(#localize("title")) }
        }

        #Preview {
            ContentView()
        }

        @Test func checks() { #expect(true) }
        """)
        let typeUses = Set(analysis.references.filter { $0.kind == .typeUse }.map(\.name))
        for wrapper in ["Observable", "ObservationIgnored", "Injected", "State", "AppStorage", "APIClient", "View", "Test"] {
            #expect(typeUses.contains(wrapper), "\(wrapper) should be a type use")
        }
        #expect(!typeUses.contains("MainActor"))
        #expect(!typeUses.contains("objc"))
        #expect(analysis.references.contains { $0.name == "localize" && $0.kind == .call })
        #expect(!analysis.references.contains { $0.name == "Preview" || $0.name == "expect" })
        #expect(analysis.references.contains { $0.name == "ContentView" && $0.kind == .instantiate && $0.enclosingSymbol == nil })
        #expect(analysis.references.contains { $0.name == "Model" && $0.kind == .instantiate })
        #expect(symbol("model", in: analysis)?.attributes == ["@State"])
        #expect(symbol("flag", in: analysis)?.attributes == ["@objc", "dynamic"])
    }

    @Test func localsParametersAndGenericsAreNotReferences() throws {
        let analysis = try analyze("""
        struct Loader<Element: Decodable> {
            var items: [Element] = []
            mutating func load<T>(from url: URL, as type: T.Type, retry attempts: Int) throws -> [T] {
                let data = try Data(contentsOf: url)
                var decoded: [T] = []
                for (index, raw) in rows.enumerated() where index < attempts { consume(raw) }
                if let cached = cache[url] { return cached }
                guard let first = items.first else { return decoded }
                do { try validate(first) } catch { report(error) }
                do { try validate(data) } catch let failure as LoadError { report(failure) }
                rows.forEach { row in handle(row, $0) }
                let transform = { [weak self] (value: Int) -> Int in value * (self?.factor ?? 1) }
                switch state {
                case .ready(let payload): use(payload)
                case let .failed(reason): use(reason)
                default: break
                }
                decoded.append(contentsOf: [])
                return decoded + transform(attempts).description.isEmpty.description.map { _ in fatalError() }
            }
        }
        """)
        let names = Set(analysis.references.map(\.name))
        let unqualified = Set(analysis.references.filter { $0.receiver == nil }.map(\.name))
        for local in ["data", "decoded", "index", "raw", "cached", "first", "error", "failure", "row", "transform", "value", "payload", "reason", "url", "attempts", "type", "T", "Element"] {
            #expect(!unqualified.contains(local), "\(local) is local/parameter/generic and must not be referenced")
        }
        #expect(analysis.references.contains { $0.name == "first" && $0.receiver == "items" }, "a member named like a local is still a member")
        for member in ["rows", "cache", "items", "consume", "validate", "report", "handle", "state", "use", "factor", "LoadError", "URL", "Data", "Decodable"] {
            #expect(names.contains(member), "\(member) should be referenced")
        }
        #expect(analysis.references.contains { $0.name == "factor" && $0.receiver == "self" })
    }

    @Test func shorthandOptionalBindingReadsTheShadowedValue() throws {
        let analysis = try analyze("""
        final class Profile {
            var user: User?
            func render() {
                if let user { show(user) }
                notify(user)
            }
        }
        """)
        let userRefs = analysis.references.filter { $0.name == "user" }
        #expect(userRefs.count == 2, "the binding reads `user`, and `user` outside the if is the property again")
        #expect(userRefs.allSatisfy { $0.kind == .read && $0.receiver == nil })
    }

    @Test func stopListedNamesAreSkipped() throws {
        let analysis = try analyze("""
        func summarize(values: [Int]) -> String {
            print(values.count, values.isEmpty, values.map { $0 * 2 }.filter { $0 > 1 }.reduce(0, +))
            let text = String(describing: values.sorted().first)
            return text + Array(repeating: "x", count: 2).joined()
        }
        """)
        let names = Set(analysis.references.map(\.name))
        for ignored in ["print", "String", "Array", "Int"] {
            #expect(!names.contains(ignored), "\(ignored) is stop-listed")
        }
        // Members are always emitted: a repository type may declare one (`wal.append`).
        for member in ["count", "isEmpty", "map", "filter", "reduce", "sorted", "first", "joined"] {
            #expect(analysis.references.contains { $0.name == member && $0.receiver != nil }, "\(member) is a member use")
        }
    }

    @Test func referenceLocationsAreAccurate() throws {
        let analysis = try analyze("""
        func a() {
            b()
              Cache.store(1)
        }
        """)
        let call = try #require(analysis.references.first { $0.name == "b" })
        #expect(call.line == 2)
        #expect(call.column == 5)
        let store = try #require(analysis.references.first { $0.name == "store" })
        #expect(store.line == 3)
        #expect(store.column == 13)
        #expect(call.enclosingSymbol == 0)
    }

    // MARK: - Metrics

    @Test func countsComplexityPerCallableAndFile() throws {
        let analysis = try analyze("""
        func classify(_ value: Int?, flag: Bool) -> String {
            guard let value else { return "none" }
            if value > 10 && flag { return "big" }
            for index in 0..<value where index % 2 == 0 { consume(index) }
            switch value {
            case 0: return "zero"
            case 1, 2: return "small"
            default: return value > 5 ? "mid" : "low"
            }
        }

        func plain() -> Int { 1 }

        struct Box {
            var label: String { title ?? "untitled" }
            func check() { if open || locked { toggle() } }
        }
        """)
        // guard, if, &&, for, case 0, case 1/2, ternary = 7 decision points.
        #expect(symbol("classify", in: analysis)?.complexity == 8)
        #expect(symbol("plain", in: analysis)?.complexity == 1)
        #expect(symbol("label", in: analysis)?.complexity == 2)
        #expect(symbol("check", in: analysis)?.complexity == 3)
        #expect(symbol("Box", in: analysis)?.complexity == 4, "types accumulate the decisions of their members")
        #expect(analysis.complexity == 1 + 7 + 1 + 2)
    }

    @Test func renamedDuplicatesShareABodyHash() throws {
        let analysis = try analyze("""
        func totalPrice(items: [Item]) -> Double {
            var sum = 0.0
            for item in items {
                sum += item.price * 1.2
            }
            return sum
        }

        func totalWeight(parcels: [Parcel]) -> Double {
            var total = 0.0
            for parcel in parcels {
                total += parcel.weight * 3.5
            }
            return total
        }

        func average(items: [Item]) -> Double {
            var sum = 0.0
            for item in items {
                sum -= item.price / 1.2
            }
            return sum
        }

        func short() -> Int {
            return 1
        }
        """)
        let price = try #require(symbol("totalPrice", in: analysis)?.bodyHash)
        let weight = try #require(symbol("totalWeight", in: analysis)?.bodyHash)
        let average = try #require(symbol("average", in: analysis)?.bodyHash)
        #expect(price == weight)
        #expect(price != average)
        #expect(symbol("short", in: analysis)?.bodyHash == nil, "bodies under five lines are not fingerprinted")
    }

    // MARK: - Entry points and robustness

    @Test func detectsEntryPoints() throws {
        let app = try analyze("""
        import SwiftUI
        @main
        struct VesaliusApp: App {
            var body: some Scene { WindowGroup { ContentView() } }
        }
        """, path: "App/VesaliusApp.swift")
        #expect(app.isEntryPoint)

        let script = try analyze("""
        import Foundation
        let arguments = CommandLine.arguments
        run(arguments)
        """, path: "Sources/tool/main.swift")
        #expect(script.isEntryPoint)
        #expect(script.symbols.first?.kind == .constant)

        let library = try analyze("struct Model {}\n", path: "Sources/Lib/main.swift")
        #expect(!library.isEntryPoint, "main.swift without top-level code is not an entry point")

        let plain = try analyze("struct Model { func main() {} }")
        #expect(!plain.isEntryPoint)
    }

    @Test func malformedSourceStillProducesUsefulOutput() throws {
        let analysis = try analyze("""
        import Foundation

        struct Valid {
            func ok() -> Int { 1 }
        }

        class Broken: {
            func missingBrace( {
                let x = [1, 2,
            }
        """)
        #expect(analysis.syntaxErrorCount > 0)
        #expect(symbol("Valid", in: analysis) != nil)
        #expect(symbol("ok", in: analysis) != nil)
        #expect(analysis.imports.count == 1)
    }

    @Test func emptyAndGarbageInputDoNotThrow() throws {
        let empty = try analyze("")
        #expect(empty.symbols.isEmpty)
        #expect(empty.syntaxErrorCount == 0)
        let garbage = try analyze(String(repeating: "}{)(@#$%^&*", count: 200))
        #expect(garbage.syntaxErrorCount > 0)
    }

    @Test func handlesDeepButLegalNestingAndLongChains() throws {
        let nested = "let total = " + String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200)
        let chain = "let value = start" + String(repeating: ".next()", count: 4_000)
        let closures = "func deep() {\n" + String(repeating: "run {\n", count: 120) + "finish()\n" + String(repeating: "}\n", count: 120) + "}\n"
        let analysis = try analyze([nested, chain, closures].joined(separator: "\n"))
        #expect(analysis.syntaxErrorCount == 0)
        #expect(analysis.symbols.map(\.name) == ["total", "value", "deep"])
        #expect(analysis.references.contains { $0.name == "finish" && $0.kind == .call })
        #expect(analysis.references.contains { $0.name == "next" && $0.receiver == "_" })
    }

    @Test func nestingBeyondTheLimitDegradesWithoutCrashing() throws {
        let source = "struct Before {}\n" + "let x = " + String(repeating: "(", count: 1_000) + String(repeating: ")", count: 1_000) + "\nstruct After {}\n"
        let analysis = try analyze(source)
        #expect(analysis.syntaxErrorCount > 0)
        #expect(analysis.symbols.contains { $0.name == "Before" })
    }

    @Test func longBracketRunsAreDefusedInsteadOfHanging() throws {
        let deep = "let grid = " + String(repeating: "[", count: 2_000) + "seed" + String(repeating: "]", count: 2_000)
        let type = "let cube: " + String(repeating: "[", count: 40) + "Int" + String(repeating: "]", count: 40) + " = []"
        let source = "struct Before {}\n\(deep)\n\(type)\nstruct After { let label = \"[[[[[[[[[[[[[[[[\" }\n"
        let clock = ContinuousClock()
        var analysis = FileAnalysis()
        let elapsed = try clock.measure { analysis = try analyze(source) }
        #expect(elapsed < .seconds(5))
        #expect(analysis.symbols.map(\.name) == ["Before", "grid", "cube", "After", "label"])
        #expect(analysis.references.contains { $0.name == "seed" && $0.line == 2 }, "content inside the brackets is still analysed")
        #expect(analysis.syntaxErrorCount == 0)
    }

    @Test func sourceGuardPreservesOffsetsStringsAndComments() {
        let run = String(repeating: "[", count: 14) + "1" + String(repeating: "]", count: 14)
        let source = "let a = \(run)\n// [[[[[[[[[[[[[[[[\nlet s = \"[[[[[[[[[[[[[[[[\\(f([1]))\"\nlet r = #\"[[[[[[[[[[[[\"#\n"
        let bytes = Array(source.utf8)
        let defused = SwiftSourceGuard.defuse(bytes)
        let output = try! #require(defused)
        #expect(output.count == bytes.count)
        let text = String(decoding: output, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 5)
        #expect(lines[0] == "let a = " + String(repeating: "[", count: 10) + "    1    " + String(repeating: "]", count: 10))
        #expect(lines[1] == "// [[[[[[[[[[[[[[[[")
        #expect(lines[2] == "let s = \"[[[[[[[[[[[[[[[[\\(f([1]))\"")
        #expect(lines[3] == "let r = #\"[[[[[[[[[[[[\"#")
        #expect(SwiftSourceGuard.defuse(Array("let m = [[[1, 2], [3]]]".utf8)) == nil)
    }

    @Test func isSafeToCallConcurrently() async throws {
        let source = Self.authService
        let expected = try analyze(source)
        try await withThrowingTaskGroup(of: FileAnalysis.self) { group in
            for _ in 0..<16 {
                group.addTask { try SwiftAnalyzer().analyze(SourceFile(path: "A.swift", language: .swift, text: source)) }
            }
            for try await analysis in group {
                #expect(analysis.symbols == expected.symbols)
                #expect(analysis.references == expected.references)
            }
        }
    }

    @Test func benchmarkFiveThousandLines() throws {
        var source = "import Foundation\nimport SwiftUI\n\n"
        var index = 0
        while source.split(separator: "\n", omittingEmptySubsequences: false).count < 5_000 {
            source += """
            /// Generated service \(index).
            final class Service\(index): BaseService, Loading {
                @Published private(set) var items: [Item] = []
                private let client: APIClient

                init(client: APIClient = APIClient()) {
                    self.client = client
                }

                func load(page: Int) async throws -> [Item] {
                    guard page >= 0 else { return [] }
                    let response = try await client.fetch(Endpoint.items(page: page))
                    for item in response.items where item.isVisible {
                        items.append(item)
                    }
                    return response.items.isEmpty ? [] : items
                }
            }

            struct Service\(index)View: View {
                @StateObject var service = Service\(index)()
                var body: some View {
                    List(service.items) { item in
                        Text(item.title).padding()
                    }
                    .task { _ = try? await service.load(page: 0) }
                }
            }


            """
            index += 1
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).count
        let clock = ContinuousClock()
        var analysis = FileAnalysis()
        let elapsed = try clock.measure {
            analysis = try analyze(source, path: "Generated.swift")
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("SwiftAnalyzer benchmark: \(lines) lines in \(String(format: "%.3f", seconds))s → \(Int(Double(lines) / max(seconds, 1e-9))) lines/sec, \(analysis.symbols.count) symbols, \(analysis.references.count) references")
        #expect(analysis.symbols.count >= index * 6)
        #expect(analysis.syntaxErrorCount == 0)
    }

    // MARK: - Helpers

    private func symbol(_ name: String, kind: SymbolKind? = nil, in analysis: FileAnalysis) -> ExtractedSymbol? {
        analysis.symbols.first { $0.name == name && (kind == nil || $0.kind == kind) }
    }

    private func qualifiedName(_ symbol: ExtractedSymbol, in analysis: FileAnalysis) -> String {
        var components = [symbol.name]
        var parent = symbol.parentLocalID
        while let id = parent {
            components.insert(analysis.symbols[id].name, at: 0)
            parent = analysis.symbols[id].parentLocalID
        }
        return components.joined(separator: ".")
    }
}
