import Foundation
@testable import QueryEngine
@testable import SemanticSearch
import Testing
import VesaliusCore
import VesaliusRender

/// Question parsing, question analysis, the IO sink catalog and the feature map renderer, then `featureMap`
/// and `flow(of:)` on indexed fixture repositories (real index, real source reads, nothing stubbed).
@Suite("Feature map: question parsing, roles, flow and rendering", .serialized)
struct FeatureMapTests {
    static let b1 = "Where does this app handle in-app purchases and subscriptions: loading products, buying, restoring purchases, and deciding whether the user has premium access? List the key files and the main types and functions involved."
    static let i3 = "Where does the app store and load the Partner Store Gateway API credentials (account ID, key ID, private key), and how are they protected at rest? List the key files and functions."
    static let w2 = "How does Wax persist its data to disk? Identify the files that define the on-disk file format and the code path that writes (commits) data to the file."

    // MARK: Question parsing

    @Test("Scaffolding goes, phrases and frameworks stay whole, capitals are not identifiers")
    func parsesPhrasesAndScaffolding() {
        let parsed = QueryParser.parse(Self.b1, vocabulary: nil, useEmbeddings: false)
        #expect(parsed.phrases.contains("in-app purchases"))
        #expect(parsed.phrases.contains("premium access"))
        #expect(parsed.frameworks.contains("StoreKit"))
        for meta in ["key", "main", "types", "functions", "whether", "has", "list", "where"] {
            #expect(!parsed.words.contains(meta), "\(meta) is scaffolding")
        }
        #expect(parsed.words.contains("premium") && parsed.words.contains("access"))
        #expect(parsed.identifiers.isEmpty, "sentence-initial capitals are not identifiers: \(parsed.identifiers)")
        // Phrase terms carry the concept; "in" and "app" do not become words.
        #expect(parsed.terms["entitlement"] != nil && parsed.terms["storekit"] != nil)
        #expect(!parsed.words.contains("app") && !parsed.words.contains("in"))
    }

    @Test("A framework name is one word; `ID`, `API` and `Where` are not identifiers; backticks are")
    func frameworksAndIdentifiers() {
        let parsed = QueryParser.parse("Where is StoreKit used with the `PurchaseFlow.start()` API and its ID?", vocabulary: nil, useEmbeddings: false)
        #expect(parsed.frameworks == ["StoreKit"])
        #expect(parsed.words.contains("storekit"))
        #expect(!parsed.words.contains("store") && !parsed.words.contains("kit"))
        #expect(parsed.identifiers.contains("PurchaseFlow.start"))
        #expect(!parsed.identifiers.contains("API") && !parsed.identifiers.contains("ID") && !parsed.identifiers.contains("Where"))
        // Everyday words that are also module names stay words unless written as a name.
        let plain = QueryParser.parse("how is testing done for the vision feature", vocabulary: nil, useEmbeddings: false, externalModules: ["testing", "Vision"])
        #expect(plain.frameworks.isEmpty, "\(plain.frameworks)")
    }

    @Test("Capitalised runs become the repository's acronym; the lower-case verb stays a word")
    func acronyms() {
        let vocabulary = Vocabulary(frequencies: ["psg": 70, "credentials": 4, "store": 30, "load": 25, "account": 3, "encrypt": 6], documentCount: 300)
        let parsed = QueryParser.parse(Self.i3, vocabulary: vocabulary, useEmbeddings: false)
        #expect(parsed.acronyms["Partner Store Gateway"] == "psg")
        #expect(parsed.terms["psg"] == 1.0)
        #expect(parsed.words.contains("store"), "the verb in 'the app store and load' is a word")
        #expect(parsed.phrases.contains("at rest"))
        #expect(!parsed.words.contains("rest"), "'rest' in 'at rest' is not REST")
        #expect(parsed.terms["encrypt"] != nil)
        #expect(parsed.terms["keychain"] == nil, "a phrase term the repository never uses is dropped")
    }

    @Test("A word in too many files is dropped unless it is the only one; completions only for unknown words")
    func commonWordsAndCompletions() {
        let vocabulary = Vocabulary(frequencies: ["wax": 270, "persist": 3, "disk": 4, "format": 9, "authentication": 6, "authorize": 4, "authority": 2, "authors": 1, "auth": 20], documentCount: 278)
        let parsed = QueryParser.parse("How does Wax persist data to disk?", vocabulary: vocabulary, useEmbeddings: false)
        #expect(!parsed.words.contains("wax"))
        #expect(parsed.words.contains("persist"))
        let only = QueryParser.parse("wax", vocabulary: vocabulary, useEmbeddings: false)
        #expect(only.words == ["wax"], "the only content word stays")
        #expect(vocabulary.completions(of: "auth").isEmpty, "a word the repository uses is not completed")
        #expect(vocabulary.completions(of: "aut").isEmpty, "three letters are too short")
        let completions = vocabulary.completions(of: "autho")
        #expect(completions.count == 3 && completions.allSatisfy { $0.hasPrefix("autho") })
    }

    @Test("The term budget keeps every unit's own word before anyone's expansions")
    func termBudget() {
        let vocabulary = Vocabulary(frequencies: [:], documentCount: 100)
        let parsed = QueryParser.parse(Self.b1, vocabulary: nil, useEmbeddings: false)
        let chosen = HybridSearch.budgetedTerms(parsed, vocabulary: vocabulary).map(\.key)
        #expect(chosen.count <= HybridSearch.termBudget)
        for word in ["buying", "restoring", "loading", "premium", "access", "storekit"] {
            #expect(chosen.contains(word), "\(word) kept: \(chosen)")
        }
        #expect(HybridSearch.isDemoPath("WaxDemo/Sources/WaxDemo/main.swift"))
        #expect(HybridSearch.isDemoPath("examples/basic/app.ts"))
        #expect(!HybridSearch.isDemoPath("Sources/WaxCore/Wax.swift"))
    }

    // MARK: Question analysis

    @Test("Roles follow the question's own list, in its order")
    func rolesFromList() {
        let analysis = QuestionAnalyzer.analyze(Self.b1, parsed: QueryParser.parse(Self.b1, vocabulary: nil, useEmbeddings: false))
        #expect(analysis.roles.map(\.label) == ["load", "buy", "restore", "premium access"])
        #expect(analysis.flowVerbs.isEmpty)
        let buy = analysis.roles[1]
        #expect((buy.terms["purchase"] ?? 0) > (analysis.roles[2].terms["purchase"] ?? 0), "a purchase is buying, not restoring")
    }

    @Test("Without a list, the question's verbs are its roles; proper names are not verbs")
    func rolesFromVerbs() {
        let vocabulary = Vocabulary(frequencies: ["psg": 70], documentCount: 300)
        let analysis = QuestionAnalyzer.analyze(Self.i3, parsed: QueryParser.parse(Self.i3, vocabulary: vocabulary, useEmbeddings: false))
        #expect(analysis.roles.map(\.label) == ["store", "load", "at rest"])
        #expect(analysis.flowVerbs.isEmpty, "'how are they protected' asks for no flow")
    }

    @Test("Flow questions name their verbs; other how-questions are feature maps")
    func flowVerbs() {
        let analysis = QuestionAnalyzer.analyze(Self.w2, parsed: QueryParser.parse(Self.w2, vocabulary: nil, useEmbeddings: false))
        #expect(analysis.flowVerbs == ["persist", "write", "commit"])
        let login = QuestionAnalyzer.analyze("How does login work?", parsed: QueryParser.parse("How does login work?", vocabulary: nil, useEmbeddings: false))
        #expect(login.flowVerbs.isEmpty)
        #expect(QuestionAnalyzer.lemma("estimating") == "estimate")
        #expect(QuestionAnalyzer.lemma("loading") == "load")
        #expect(QuestionAnalyzer.lemma("running") == "run")
        #expect(QuestionAnalyzer.lemma("restoring") == "restore")
    }

    // MARK: IO sinks

    @Test("The sink catalog: C library, Foundation, Node fs and ORM writes; never a repository function")
    func sinks() {
        #expect(IOSinks.kind(name: "pwrite", receiver: "Darwin", language: .swift) == .write)
        #expect(IOSinks.kind(name: "fsync", receiver: nil, language: .swift) == .sync)
        #expect(IOSinks.kind(name: "write", receiver: nil, language: .swift, resolvedInRepository: true) == nil)
        #expect(IOSinks.kind(name: "write", receiver: "data", language: .swift, argumentLabels: ["to"]) == .write)
        #expect(IOSinks.kind(name: "writeFileSync", receiver: "fs", language: .typescript) == .write)
        #expect(IOSinks.kind(name: "insert", receiver: "db", language: .typescript) == .database)
        #expect(IOSinks.kind(name: "set", receiver: "cache", language: .typescript) == nil)
        #expect(IOSinks.kind(name: "fsync", receiver: "os", language: .python) == .sync)
    }

    // MARK: Rendering

    @Test("Rendering: evidence lines, no scores, and cuts that keep the result within its budget")
    func rendering() {
        let site = FeatureEvidence(line: 41, code: "const sealedKey = sealSecret(form.passphrase);", kind: .call, primary: true, note: "→ :42 db.insert(vaultEntries)")
        let files = (1...40).map { index in
            FeatureCallSiteFile(path: "src/app/api/route\(index).ts", header: ":3 imports {sealSecret}",
                                groups: [FeatureCallSiteGroup(caller: "POST /api/route\(index)", sites: [site] + (1...6).map { FeatureEvidence(line: 60 + $0, code: "sealSecret(other\($0))", kind: .call) })])
        }
        var result = FeatureMapResult(question: "q", headline: FeatureHeadline(feature: "encryption", frameworks: [FeatureFramework(name: "node:crypto", importers: 4)]),
                                      core: FeatureCore(path: "src/server/vault.ts", lines: LineRange(1, 58)))
        result.callSites = FeatureCallSites(subject: "src/server/vault.ts", files: files, completeness: "imported by 40 files (40 source, 0 test)")
        result.coverage = FeatureCoverage(found: ["at rest"], missing: ["load"])
        let full = FeatureMapRenderer.render(result, budget: .unlimited)
        #expect(full.contains("41 │ const sealedKey = sealSecret(form.passphrase);  → :42 db.insert(vaultEntries)"))
        #expect(full.hasPrefix("feature: encryption · node:crypto (imported by 4 files) · found: at rest · missing: load"))
        let small = FeatureMapRenderer.render(result, budget: Budget(tokens: 1_500))
        #expect(TokenEstimate.of(small) <= 1_500)
        #expect(small.contains("more files:"), "a cut says what it left out")
        for word in ["confidence", "relevance", "score", "weight"] { #expect(!small.lowercased().contains(word)) }

        let flow = FlowView(entry: FeatureRef(name: "Journal.commit()", path: "Journal.swift", lines: LineRange(10, 12)),
                            body: FeatureRef(name: "Journal.commitLocked()", path: "Journal.swift", lines: LineRange(14, 20)),
                            sinks: ["FileHandleBox.writeAll → pwrite"],
                            steps: [FlowStep(line: 16, code: "file.writeAll(bytes, at: 0)", isSink: true),
                                    FlowStep(line: 15, code: "let bytes = try encodeAll()", target: "Journal.encodeAll()", targetLines: LineRange(22, 24))])
        let text = FeatureMapRenderer.render(flow: flow)
        #expect(text.hasPrefix("flow Journal.commit() → commitLocked()  Journal.swift:14-20 · sinks: FileHandleBox.writeAll → pwrite"))
        #expect(text.contains("16 │ file.writeAll(bytes, at: 0)  [sink]"))
        #expect(text.contains("15 │ let bytes = try encodeAll()  → Journal.encodeAll() :22-24"))
    }

    // MARK: Engine on fixture repositories

    static let store: [String: String] = [
        "App/Store/PurchaseManager.swift": """
            import Foundation
            import StoreKit

            /// Handles in-app purchases.
            final class PurchaseManager {
                static let shared = PurchaseManager()
                static let yearlyID = "yearly_plan"
                private(set) var products: [Product] = []
                private(set) var isPremium = false

                /// Loads the products from the App Store.
                func loadProducts() async {
                    let loaded = try? await Product.products(for: [Self.yearlyID])
                    products = loaded ?? []
                }

                func purchase(_ product: Product) async {
                    let result = try? await product.purchase()
                    if result != nil { isPremium = true }
                }

                func restorePurchases() async {
                    try? await AppStore.sync()
                    await refreshEntitlements()
                }

                func refreshEntitlements() async {
                    for await result in Transaction.currentEntitlements {
                        _ = result
                        isPremium = true
                    }
                }
            }
            """,
        "App/Views/StoreScreen.swift": """
            import SwiftUI
            import StoreKit

            struct StoreScreen: View {
                private var manager = PurchaseManager.shared

                var body: some View {
                    Button("Buy") { Task { await manager.loadProducts() } }
                }

                func restoreTapped() async {
                    await manager.restorePurchases()
                }

                var spinner: some View {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                }

                var skipsPaywall: Bool {
                    ProcessInfo.processInfo.environment["STORE_SKIP_PAYWALL"] == "1"
                }

                var status: String {
                    manager.isPremium && manager.products.isEmpty ? "premium" : "free"
                }
            }
            """,
        "App/Other/WeatherService.swift": """
            import Foundation

            struct WeatherService {
                func forecast() -> String { "sunny" }
            }
            """,
    ]

    @Test("featureMap: the framework's caller is the core, its members by role, the views as call sites")
    func featureMapOnSwiftFixture() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.store, name: "feature-store")
        let result = try engine.featureMap(question: "Where are in-app purchases handled: loading products, buying, and restoring purchases?")
        #expect(result.core?.name == "PurchaseManager")
        #expect(result.core?.access == "static let shared :6")
        #expect(result.headline.frameworks.map(\.name) == ["StoreKit"])
        let roles = Dictionary(uniqueKeysWithValues: result.roles.map { ($0.label, $0.members.map(\.name)) })
        #expect(roles["load"]?.contains("loadProducts()") == true, "\(roles)")
        #expect(roles["buy"]?.contains("purchase(_:)") == true, "\(roles)")
        #expect(roles["restore"]?.contains("restorePurchases()") == true, "\(roles)")
        let load = result.roles.first { $0.label == "load" }?.members.first { $0.name == "loadProducts()" }
        #expect(load?.evidence.contains { $0.line == 13 && $0.code.contains("Product.products") } == true, "\(load?.evidence ?? [])")
        #expect(result.keyLiterals.contains { $0.code.contains("yearly_plan") })
        let sites = result.callSites?.files.map(\.path) ?? []
        #expect(sites == ["App/Views/StoreScreen.swift"], "\(sites)")
        // The view's member calls go through `manager = PurchaseManager.shared`, which the index left unresolved.
        let lines = result.callSites?.files.first?.groups.flatMap { $0.sites.flatMap { [$0.line] + $0.moreLines } } ?? []
        #expect(lines.contains(8) && lines.contains(12), "\(lines)")
        #expect(result.coverage.missing.isEmpty, "\(result.coverage)")
        #expect(!result.notThisFeature.contains { $0.path == "App/Store/PurchaseManager.swift" })

        let text = FeatureMapRenderer.render(result)
        #expect(text.contains("core  App/Store/PurchaseManager.swift"))
        #expect(text.contains("13 │ let loaded = try? await Product.products(for: [Self.yearlyID])"))
    }

    @Test("featureMap: guessed framework modules and environment reads are not framework calls; a line is quoted once")
    func featureMapKeepsFrameworkCallsHonest() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.store, name: "feature-store-calls")
        let result = try engine.featureMap(question: "Where are in-app purchases handled: loading products, buying, and restoring purchases?")
        let screen = result.callSites?.files.first { $0.path == "App/Views/StoreScreen.swift" }
        let sites = screen?.groups.flatMap(\.sites) ?? []
        // The view's only non-SwiftUI import is StoreKit, so the index files `CircularProgressViewStyle` and `.white`
        // under it; the SDK catalog says otherwise. `ProcessInfo…environment[…]` is an environment read.
        #expect(!sites.contains { $0.kind == .external }, "\(sites)")
        #expect(!sites.contains { $0.line == 16 || $0.line == 20 }, "\(sites)")
        // `isPremium` and `products` on line 24 are two uses on one line, quoted once.
        let quoted = sites.map(\.line).filter { $0 > 0 }
        #expect(quoted.contains(24) && Set(quoted).count == quoted.count, "\(quoted)")
        // The real StoreKit calls still are: `Product.products(for:)` decides `loadProducts()`.
        let load = result.roles.first { $0.label == "load" }?.members.first { $0.name == "loadProducts()" }
        #expect(load?.evidence.contains { $0.line == 13 && $0.kind == .external } == true, "\(load?.evidence ?? [])")
    }

    @Test("featureMap: a question about nothing in the repository says so instead of picking a core")
    func featureMapWithoutMatch() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.store, name: "feature-none")
        let result = try engine.featureMap(question: "Where is the quantum flux capacitor calibrated?")
        #expect(result.core == nil)
        #expect(result.roles.isEmpty)
        #expect(!result.coverage.missing.isEmpty)
    }

    static let journal: [String: String] = [
        "Store/Journal.swift": """
            import Foundation
            import Darwin

            final class FileHandleBox {
                let fd: Int32 = 3

                func writeAll(_ data: [UInt8], at offset: Int) {
                    _ = data.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
                }
            }

            final class Journal {
                let file = FileHandleBox()
                var pending: [[UInt8]] = []

                func commit() throws {
                    try commitLocked()
                }

                private func commitLocked() throws {
                    let bytes = try encodeAll()
                    file.writeAll(bytes, at: 0)
                }

                private func encodeAll() throws -> [UInt8] {
                    pending.flatMap { $0 }
                }
            }
            """,
    ]

    @Test("flow(of:) follows a delegating body and flags the sink wrapper")
    func flowOnFixture() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.journal, name: "feature-flow")
        let flow = try engine.flow(of: "Journal.commit")
        #expect(flow.entry.name == "Journal.commit()")
        #expect(flow.body.name == "Journal.commitLocked()")
        #expect(flow.steps.map(\.line) == [21, 22], "\(flow.steps)")
        #expect(flow.steps.first { $0.line == 22 }?.isSink == true)
        #expect(flow.steps.first { $0.line == 21 }?.target == "Journal.encodeAll()")
        #expect(flow.sinks == ["FileHandleBox.writeAll → pwrite"])

        let result = try engine.featureMap(question: "How does the journal persist data? Show the code path that commits it.")
        #expect(result.flow?.entry.name == "Journal.commit()")
        #expect(FeatureMapRenderer.render(result).contains("22 │ file.writeAll(bytes, at: 0)  [sink]"))
        #expect(throws: EngineError.self) { try engine.flow(of: "Journal.pending") }
    }

    static let secrets: [String: String] = [
        "desktop/boot.ts": """
            import { safeStorage } from "electron";

            function loadVaultKey(): void {
              process.env.VAULT_KEY = safeStorage.decryptString(Buffer.from("x"));
            }

            loadVaultKey();
            """,
        "src/lib/crypto.ts": """
            import { randomBytes, createCipheriv } from "node:crypto";

            function vaultKey(): Buffer {
              const raw = process.env.VAULT_KEY;
              return Buffer.from(raw ?? "", "base64");
            }

            export function sealSecret(text: string): string {
              const key = vaultKey();
              const nonce = randomBytes(12);
              const cipher = createCipheriv("aes-256-gcm", key, nonce);
              return cipher.update(text, "utf8", "base64");
            }
            """,
        "src/app/api/save/route.ts": """
            import { sealSecret } from "../../../lib/crypto";

            export async function POST(req: Request) {
              const sealed = sealSecret(await req.text());
              return new Response(sealed);
            }
            """,
    ]

    @Test("featureMap in TypeScript: the file core, its importers with their routes, the env var's producer")
    func featureMapOnScriptFixture() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.secrets, name: "feature-secrets")
        let result = try engine.featureMap(question: "How are secrets protected at rest, and where is the vault key set?")
        #expect(result.core?.path == "src/lib/crypto.ts", "\(String(describing: result.core))")
        let link = result.environment.first { $0.name == "VAULT_KEY" }
        #expect(link?.producer?.name == "loadVaultKey()", "\(result.environment)")
        #expect(link?.producer?.evidence.contains { $0.line == 4 && $0.code.contains("VAULT_KEY = safeStorage.decryptString") } == true)
        #expect(link?.readers.contains { $0.path == "src/lib/crypto.ts" && $0.line == 4 } == true)
        let route = result.callSites?.files.first { $0.path == "src/app/api/save/route.ts" }
        #expect(route?.groups.first?.caller == "POST /api/save", "\(String(describing: route))")
        #expect(route?.groups.first?.sites.first?.line == 4)
    }
}
