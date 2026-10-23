import Foundation
import LanguageAnalysis
@testable import QueryEngine
import RepositoryIndex
import Testing
import VesaliusCore

@Suite("Schema v4 storage: per-occurrence references, versioning and the index lock", .serialized)
struct StorageV4Tests {
    // MARK: Per-occurrence rows

    @Test("Two calls in one function are two rows, each with its own line")
    func oneRowPerOccurrence() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Sources/App/Greeter.swift": """
                struct Greeter {
                    func hello() {}

                    func twice() {
                        hello()
                        hello()
                    }
                }
                """,
        ], name: "occurrences")
        let rows = try engine.rawQuery("SELECT line, count FROM refs WHERE name = 'hello' ORDER BY line")
        #expect(rows.rows.map { $0[0].intValue } == [5, 6])
        #expect(rows.rows.map { $0[1].intValue } == [1, 1])
        let callers = try engine.callers("Greeter.hello")
        let twice = try #require(callers.relations.first { $0.symbol.qualifiedName == "Greeter.twice" })
        #expect(twice.sites == [5, 6])
        #expect(try engine.references("Greeter.hello").references.allSatisfy { $0.count == nil })
    }

    @Test("receiver_ref and declared_type_ref point at the right rows after the second pass")
    func secondPassPointers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vesalius-store-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(path: directory.appendingPathComponent("index.v\(IndexSchema.version).sqlite").path)

        var analysis = FileAnalysis()
        analysis.symbols = [
            ExtractedSymbol(localID: 0, name: "Session", kind: .class, range: LineRange(1, 10)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "store", kind: .property, range: LineRange(2, 2),
                            declaredType: "^", declaredTypeRef: 3, setterVisibility: .private, conditions: ["DEBUG"]),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "save", kind: .method, range: LineRange(4, 8),
                            selector: "save(_:retries:)", parameterFlags: "-d", parameterTypes: ["Data", "Int"]),
            ExtractedSymbol(localID: 3, parentLocalID: 2, name: "Draft", kind: .struct, range: LineRange(5, 5), isLocal: true),
        ]
        analysis.references = [
            // 0: `store.save(data)`: its receiver is emitted after it (a forward pointer).
            ExtractedReference(name: "save", kind: .call, line: 6, column: 15, enclosingSymbol: 2, receiver: "store",
                               statementLine: 6, endLine: 7, callEndLine: 7, context: "call", argumentLabels: ["_"], receiverHint: "^",
                               receiverRef: 1, conditions: ["DEBUG", "os(iOS)"]),
            // 1: the receiver read.
            ExtractedReference(name: "store", kind: .read, line: 6, column: 9, enclosingSymbol: 2, context: "read"),
            // 2: `store.flush()`: its receiver was emitted before it (a backward pointer).
            ExtractedReference(name: "flush", kind: .call, line: 8, column: 15, enclosingSymbol: 2, receiver: "store",
                               argumentLabels: [], receiverRef: 1, typeEvidenceLine: 2),
            // 3: the initializer that types `store`.
            ExtractedReference(name: "SessionStore", kind: .instantiate, line: 2, column: 17, enclosingSymbol: 1, atLoad: true,
                               assignedTo: "store", consumerLine: 6),
            // 4: the same occurrence as 1, emitted twice.
            ExtractedReference(name: "store", kind: .read, line: 6, column: 9, enclosingSymbol: 2),
            // 5: points at the duplicate, which maps to row 1.
            ExtractedReference(name: "close", kind: .call, line: 9, column: 15, enclosingSymbol: 2, receiver: "store", receiverRef: 4),
            // 6: an environment variable.
            ExtractedReference(name: "env:API_KEY", kind: .read, line: 3, column: 5, context: "env"),
        ]
        analysis.imports = [
            ExtractedImport(module: "Kit", kind: .module, line: 1, isTestable: true, conditions: ["DEBUG"]),
            ExtractedImport(module: "./mocked", kind: .relative, line: 2, isMock: true, endLine: 3),
        ]
        analysis.literals = [
            ExtractedLiteral(value: "Save", line: 7, column: 22, enclosingSymbol: 2, context: "ui", callee: "Button", label: "_"),
        ]
        let record = FileRecord(path: "Sources/Session.swift", language: .swift, size: 1, modified: 1, contentHash: "h", lines: .init(), complexity: 1, isTest: false, isGenerated: false, isEntryPoint: false, analyzer: "swift-syntax", parseStatus: "ok", parseMessage: nil)
        let lexical = LexicalDocument(pathText: "session", symbolText: "", docText: "", bodyText: "")
        // Written twice: rewriting a file replaces its rows (and literals) instead of adding to them.
        try store.writeFile(record, directoryID: nil, analysis: analysis, lexical: lexical)
        try store.writeFile(record, directoryID: nil, analysis: analysis, lexical: lexical)

        func ref(_ name: String) throws -> Int64 {
            let id = try store.db.queryOne("SELECT id FROM refs WHERE name = ?", [name]) { $0.int64(0) }
            guard let id else { throw MissingRow(query: name) }
            return id
        }
        /// A nullable column of the first matching row.
        func text(_ sql: String) throws -> String? {
            try store.db.queryOne(sql) { $0.optionalString(0) } ?? nil
        }
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM refs") == 6, "the duplicate occurrence is dropped")
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM refs WHERE count != 1") == 0)
        let storeRow = try ref("store")
        let sessionStoreRow = try ref("SessionStore")
        for member in ["save", "flush", "close"] {
            let receiver = try store.db.queryOne("SELECT receiver_ref FROM refs WHERE name = ?", [member]) { $0.optionalInt64(0) } ?? nil
            #expect(receiver == storeRow, "\(member) → store")
        }
        let declared = try store.db.queryOne("SELECT declared_type_ref, declared_type, setter_visibility, conditions FROM symbols WHERE name = 'store'") {
            ($0.optionalInt64(0), $0.optionalString(1), $0.optionalString(2), $0.optionalString(3))
        }
        #expect(declared?.0 == sessionStoreRow)
        #expect(declared?.1 == "^" && declared?.2 == "private" && declared?.3 == "DEBUG")

        let save = try store.db.queryOne("SELECT selector, param_flags, param_types, is_local FROM symbols WHERE name = 'save'") {
            ($0.optionalString(0), $0.optionalString(1), $0.optionalString(2), $0.bool(3))
        }
        #expect(save?.0 == "save(_:retries:)" && save?.1 == "-d" && save?.2 == "Data|Int" && save?.3 == false)
        #expect(try store.db.scalarInt("SELECT is_local FROM symbols WHERE name = 'Draft'") == 1)

        let call = try store.db.queryOne("SELECT stmt_line, end_line, call_end_line, context, arg_labels, receiver_hint, conditions FROM refs WHERE name = 'save'") {
            ($0.optionalInt(0), $0.optionalInt(1), $0.optionalInt(2), $0.optionalString(3), $0.optionalString(4), $0.optionalString(5), $0.optionalString(6))
        }
        #expect(call?.0 == 6 && call?.1 == 7 && call?.2 == 7 && call?.3 == "call" && call?.4 == "_" && call?.5 == "^")
        #expect(call?.6 == "DEBUG && os(iOS)")
        #expect(try text("SELECT arg_labels FROM refs WHERE name = 'flush'") == "", "f() stores an empty label list")
        #expect(try text("SELECT arg_labels FROM refs WHERE name = 'store'") == nil, "not a call")
        #expect(try store.db.scalarInt("SELECT type_evidence_line FROM refs WHERE name = 'flush'") == 2)
        let instantiation = try store.db.queryOne("SELECT at_load, assigned_to, consumer_line FROM refs WHERE name = 'SessionStore'") {
            ($0.bool(0), $0.optionalString(1), $0.optionalInt(2))
        }
        #expect(instantiation?.0 == true && instantiation?.1 == "store" && instantiation?.2 == 6)

        let imports = try store.db.query("SELECT module, is_testable, is_mock, end_line, conditions FROM imports ORDER BY line") {
            ($0.string(0), $0.bool(1), $0.bool(2), $0.optionalInt(3), $0.optionalString(4))
        }
        #expect(imports.count == 2)
        #expect(imports.first?.0 == "Kit" && imports.first?.1 == true && imports.first?.4 == "DEBUG")
        #expect(imports.last?.2 == true && imports.last?.3 == 3)
        let literal = try store.db.queryOne("SELECT value, context, callee, label, symbol_id = (SELECT id FROM symbols WHERE name = 'save') FROM literals") {
            ($0.string(0), $0.string(1), $0.optionalString(2), $0.optionalString(3), $0.bool(4))
        }
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM literals") == 1)
        #expect(literal?.0 == "Save" && literal?.1 == "ui" && literal?.2 == "Button" && literal?.3 == "_" && literal?.4 == true)
    }

    @Test("The linker leaves env names resolved without a target and implicit members unresolved")
    func linkerGuards() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vesalius-guards-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexStore(path: directory.appendingPathComponent("index.v\(IndexSchema.version).sqlite").path)
        func write(_ path: String, _ analysis: FileAnalysis) throws {
            let record = FileRecord(path: path, language: .swift, size: 1, modified: 1, contentHash: path, lines: .init(), complexity: 1, isTest: false, isGenerated: false, isEntryPoint: false, analyzer: "swift-syntax", parseStatus: "ok", parseMessage: nil)
            try store.writeFile(record, directoryID: nil, analysis: analysis, lexical: LexicalDocument(pathText: path, symbolText: "", docText: "", bodyText: ""))
        }
        // Flags.swift declares `isPadding` and a `count`; Worker.swift has a local type with a `length`.
        try write("Sources/Flags.swift", FileAnalysis(symbols: [
            ExtractedSymbol(localID: 0, name: "Flags", kind: .struct, range: LineRange(1, 4)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "isPadding", kind: .property, range: LineRange(2, 2)),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "count", kind: .property, range: LineRange(3, 3)),
        ]))
        try write("Sources/Worker.swift", FileAnalysis(symbols: [
            ExtractedSymbol(localID: 0, name: "work", kind: .function, range: LineRange(1, 9)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "Plan", kind: .struct, range: LineRange(2, 4), isLocal: true),
            ExtractedSymbol(localID: 2, parentLocalID: 1, name: "length", kind: .property, range: LineRange(3, 3)),
        ], references: [
            ExtractedReference(name: "length", kind: .read, line: 6, column: 10, enclosingSymbol: 0, receiver: "plan"),
        ]))
        try write("Sources/Reader.swift", FileAnalysis(symbols: [
            ExtractedSymbol(localID: 0, name: "read", kind: .function, range: LineRange(1, 9)),
        ], references: [
            ExtractedReference(name: "isPadding", kind: .read, line: 2, column: 20, enclosingSymbol: 0, receiver: ".", context: "implicit"),
            ExtractedReference(name: "env:HOME", kind: .read, line: 3, column: 5, enclosingSymbol: 0, context: "env"),
            ExtractedReference(name: "count", kind: .read, line: 4, column: 12, enclosingSymbol: 0, receiver: "items"),
            ExtractedReference(name: "length", kind: .read, line: 5, column: 12, enclosingSymbol: 0, receiver: "buffer"),
            ExtractedReference(name: "Plan", kind: .typeUse, line: 6, column: 12, enclosingSymbol: 0),
        ]))
        let linker = ReferenceLinker(db: store.db)
        _ = try linker.link()

        func resolution(_ name: String, in path: String) throws -> (resolved: Bool, target: Int64?, confidence: Double) {
            let row = try store.db.queryOne("SELECT r.resolved, r.target_symbol_id, r.confidence FROM refs r JOIN files f ON f.id = r.file_id WHERE r.name = ? AND f.path = ?", [name, path]) {
                ($0.bool(0), $0.optionalInt64(1), $0.double(2))
            }
            guard let row else { throw MissingRow(query: "\(path) \(name)") }
            return row
        }
        let implicit = try resolution("isPadding", in: "Sources/Reader.swift")
        #expect(implicit.resolved && implicit.target == nil && implicit.confidence == 0, "`.isPadding` needs its contextual type")
        let env = try resolution("env:HOME", in: "Sources/Reader.swift")
        #expect(env.resolved && env.target == nil && env.confidence == 1)
        #expect(try resolution("count", in: "Sources/Reader.swift").target == nil, "stoplisted member names are never guessed")
        #expect(try resolution("length", in: "Sources/Reader.swift").target == nil, "another file's local type is invisible")
        #expect(try resolution("Plan", in: "Sources/Reader.swift").target == nil)
        let sameFile = try resolution("length", in: "Sources/Worker.swift")
        #expect(sameFile.target != nil, "the local type's own file still sees it")
    }

    @Test("Mock imports never become import edges")
    func mockImportsHaveNoEdges() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "src/client.ts": "export function load() { return 1; }\n",
            "src/app.ts": "import { load } from './client';\nexport const value = load();\n",
        ], name: "mocks")
        let store = try engine.store()
        // What `vi.mock('./client')` records: an import row that names the module without loading it.
        let appID = try #require(store.fileID(path: "src/app.ts"))
        let clientID = try #require(store.fileID(path: "src/client.ts"))
        try store.db.run("UPDATE imports SET is_mock = 1 WHERE file_id = ?", [appID])
        let linker = ReferenceLinker(db: store.db)
        try linker.rebuildEdges(for: [appID])
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM file_edges WHERE src_file_id = ? AND dst_file_id = ? AND kind = 'imports'", [appID, clientID]) == 0)
        try store.db.run("UPDATE imports SET is_mock = 0 WHERE file_id = ?", [appID])
        try linker.rebuildEdges(for: [appID])
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM file_edges WHERE src_file_id = ? AND dst_file_id = ? AND kind = 'imports'", [appID, clientID]) == 1)
    }

    @Test("Environment variables a file uses are searchable like the names it declares")
    func environmentNamesAreSearchable() async throws {
        let root = try RepoFixture.make(["src/config.ts": "export const base = 1;\n"], name: "environment")
        let location = IndexLocation(repositoryRoot: root)
        try location.ensureDirectory()
        let store = try IndexStore(path: location.databaseURL.path)
        let registry = AnalyzerRegistry(analyzers: [EnvironmentAnalyzer()])
        _ = try await IndexingPipeline(root: root, store: store, registry: registry, options: RepoFixture.fastOptions).run { _ in }
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM fts_files WHERE fts_files MATCH 'symbols : \"api base url\"'") == 1)
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM fts_files WHERE fts_files MATCH 'symbols : env'") == 0, "only the variable's name is added")
        #expect(try store.db.scalarInt("SELECT COUNT(*) FROM refs WHERE name LIKE 'env:%' AND resolved = 1 AND confidence = 1 AND target_symbol_id IS NULL") == 3)
    }

    // MARK: Versioning

    @Test("The database file is named after the schema version and leaves an older index alone")
    func versionedFilename() async throws {
        let root = try RepoFixture.make(["Sources/A.swift": "struct A {}\n"], name: "filename")
        let location = IndexLocation(repositoryRoot: root)
        #expect(location.databaseURL.lastPathComponent == "index.v\(IndexSchema.version).sqlite")
        #expect(IndexSchema.version == 4)
        // An index written by an older release, under the old name.
        try location.ensureDirectory()
        let legacy = location.directory.appendingPathComponent("index.sqlite")
        try Data("v3 index".utf8).write(to: legacy)

        let engine = try RepositoryEngine(repository: root)
        try await engine.index(options: RepoFixture.fastOptions)
        #expect(FileManager.default.fileExists(atPath: location.databaseURL.path))
        #expect(try Data(contentsOf: legacy) == Data("v3 index".utf8))
        let status = try engine.status()
        #expect(status.indexPath.hasSuffix("/index.v4.sqlite") && status.schemaVersion == 4)
    }

    @Test("A changed analyzer fingerprint re-parses every file")
    func fingerprintForcesReparse() async throws {
        let (engine, root) = try await RepoFixture.indexed(RepoFixture.app, name: "fingerprint")
        let store = try engine.store()
        #expect(store.meta("extractor_fingerprint") == IndexingPipeline.extractorFingerprint(.standard))
        let versions = (SwiftAnalyzer().version, TypeScriptAnalyzer().version, PythonAnalyzer().version, GenericAnalyzer().version)
        #expect(IndexingPipeline.extractorFingerprint(.standard) == "swift-syntax@\(versions.0),tree-sitter-typescript@\(versions.1),tree-sitter-python@\(versions.2),lexical@\(versions.3)")
        #expect(!engine.isOutdated)

        // Same files, but the Swift analyzer now reports a new version.
        let registry = AnalyzerRegistry(analyzers: [VersionedAnalyzer(base: SwiftAnalyzer(), version: SwiftAnalyzer().version + 1), TypeScriptAnalyzer(), PythonAnalyzer(), GenericAnalyzer()])
        #expect(IndexingPipeline.extractorFingerprint(registry) != IndexingPipeline.extractorFingerprint(.standard))
        let writer = try IndexStore(path: engine.location.databaseURL.path)
        let summary = try await IndexingPipeline(root: root, store: writer, registry: registry, options: RepoFixture.fastOptions).run { _ in }
        #expect(summary.filesChanged == RepoFixture.expectedAppFiles.count)
        #expect(summary.filesAdded == 0 && summary.filesUnchanged == 0)
        #expect(writer.meta("extractor_fingerprint") == IndexingPipeline.extractorFingerprint(registry))

        // The standard registry differs from what built the index: the engine is outdated and a normal run
        // parses everything again.
        #expect(engine.isOutdated)
        let again = try await engine.index(options: RepoFixture.fastOptions)
        #expect(again.filesChanged == RepoFixture.expectedAppFiles.count)
        #expect(!engine.isOutdated)
        let quiet = try await engine.index(options: RepoFixture.fastOptions)
        #expect(quiet.filesChanged == 0 && quiet.filesUnchanged == RepoFixture.expectedAppFiles.count)
    }

    @Test("index_version moves only when something changed, and readers see another engine's update")
    func indexVersion() async throws {
        let (engine, root) = try await RepoFixture.indexed(RepoFixture.app, name: "version")
        #expect(engine.indexVersion() == 1)
        try await engine.index(options: RepoFixture.fastOptions)
        #expect(engine.indexVersion() == 1, "a no-op run keeps the version")
        #expect(!engine.refreshCachesIfIndexChanged())

        // Another writer (here a second engine; the app or the CLI in practice) changes a file.
        _ = try engine.graphCache()
        let generation = engine.indexGeneration
        try RepoFixture.write("struct SessionStore {\n    func save(token: String) {}\n    func clear() {}\n}\n", to: "Sources/App/SessionStore.swift", in: root)
        let other = try RepositoryEngine(repository: root)
        try await other.index(options: RepoFixture.fastOptions)
        #expect(other.indexVersion() == 2)
        #expect(engine.indexVersion() == 2)
        #expect(engine.refreshCachesIfIndexChanged())
        #expect(engine.indexGeneration == generation + 1)
        #expect(!engine.refreshCachesIfIndexChanged())
    }

    // MARK: Concurrency

    @Test("The index lock admits one holder at a time")
    func indexLockSerializes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vesalius-lock-\(UUID().uuidString.prefix(8))/index.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = EventLog()
        async let first: Void = IndexLock(url: url).withLock {
            log.append("first start")
            try await Task.sleep(for: .milliseconds(300))
            log.append("first end")
        }
        while !log.events.contains("first start") { try await Task.sleep(for: .milliseconds(5)) }
        async let second: Void = IndexLock(url: url).withLock {
            log.append("second start")
            log.append("second end")
        }
        _ = try await (first, second)
        #expect(log.events == ["first start", "first end", "second start", "second end"])
    }

    @Test("Two concurrent index() calls finish without `database is locked`, one after the other")
    func concurrentIndexing() async throws {
        var files: [String: String] = [:]
        for index in 0..<300 {
            files["Sources/Module\(index % 10)/Type\(index).swift"] = """
                struct Type\(index) {
                    let next = Type\((index + 1) % 300)()
                    func run() { next.run(); print("\(index)") }
                }
                """
        }
        let root = try RepoFixture.make(files, name: "concurrent")
        let a = try RepositoryEngine(repository: root)
        let b = try RepositoryEngine(repository: root)
        let log = EventLog()
        async let first = a.index(options: RepoFixture.fastOptions) { log.append("a \($0.phase.rawValue)") }
        async let second = b.index(options: RepoFixture.fastOptions) { log.append("b \($0.phase.rawValue)") }
        let summaries = try await [first, second]
        #expect(summaries.map(\.filesScanned) == [300, 300])
        #expect(summaries.map(\.filesAdded).sorted() == [0, 300], "the second run finds the first one's work done")
        // Each run's progress events are contiguous: the runs did not overlap.
        let order = log.events.map { $0.prefix(1) }
        #expect(order.indices.dropFirst().filter { order[$0] != order[$0 - 1] }.count == 1, "\(log.events)")
        #expect(try a.rawQuery("SELECT COUNT(*) FROM files").rows.first?.first?.intValue == 300)
    }
}

private struct MissingRow: Error {
    let query: String
}

/// Forwards to another analyzer under a different version, as a new release of that analyzer would.
private struct VersionedAnalyzer: LanguageAnalyzer {
    let base: any LanguageAnalyzer
    let version: Int

    var identifier: String { base.identifier }
    func canAnalyze(_ language: Language, path: String) -> Bool { base.canAnalyze(language, path: path) }
    func analyze(_ file: SourceFile) throws -> FileAnalysis { try base.analyze(file) }
}

/// Reports the environment variables a file reads and writes, as the script analyzers do for `process.env.X`.
private struct EnvironmentAnalyzer: LanguageAnalyzer {
    var identifier: String { "environment-test" }
    func canAnalyze(_ language: Language, path: String) -> Bool { true }
    func analyze(_ file: SourceFile) throws -> FileAnalysis {
        FileAnalysis(references: [
            ExtractedReference(name: "env:API_BASE_URL", kind: .read, line: 1, column: 21, context: "env"),
            ExtractedReference(name: "env:API_BASE_URL", kind: .write, line: 2, column: 1, context: "env"),
            ExtractedReference(name: "env:*", kind: .read, line: 3, column: 1, context: "env-all"),
        ])
    }
}

/// A thread-safe ordered event list for observing concurrent work.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
