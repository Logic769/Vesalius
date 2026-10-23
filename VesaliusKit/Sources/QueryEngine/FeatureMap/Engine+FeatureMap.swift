import Foundation
import RepositoryIndex
import SemanticSearch
import VesaliusCore

extension RepositoryEngine {
    /// Where and how a feature is implemented: the core type or file, its members by the question's
    /// roles with their decisive lines, environment links, tables, every call site, configuration, one doc
    /// section, lookalikes and role coverage. A "how does X write…" question gets the flow of its main method.
    ///
    /// `focus` (a file, folder or symbol, in the `usages` target grammar) anchors the core. Computed once per
    /// index version for a question.
    public func featureMap(question: String, focus: String? = nil) throws -> FeatureMapResult {
        try memoized("featureMap\u{1}\(question)\u{1}\(focus ?? "")") {
            let analysis = try search().analyze(question)
            let context = try FeatureContext(engine: self, analysis: analysis)
            return try FeatureMapBuilder(context: context, focus: focus).build()
        }
    }

    /// The files a feature map quotes that changed since they were indexed: their line numbers may
    /// no longer point at the code shown, so the caller re-indexes and asks again.
    public func staleEvidenceFiles(of result: FeatureMapResult) throws -> [String] {
        var paths = Set<String>()
        if let core = result.core { paths.insert(core.path) }
        for member in result.roles.flatMap(\.members) {
            paths.insert(member.path)
            if let delegate = member.delegate { paths.insert(delegate.path) }
        }
        for link in result.environment {
            if let producer = link.producer { paths.insert(producer.path) }
        }
        paths.formUnion(result.tables.map(\.path))
        paths.formUnion(result.callSites?.files.filter { !$0.isTest }.map(\.path) ?? [])
        if let flow = result.flow {
            paths.insert(flow.body.path)
            paths.formUnion(flow.otherWriters.map(\.path) + flow.readers.map(\.path))
        }
        if let docs = result.docs { paths.insert(docs.path) }
        return try staleFiles(paths.sorted())
    }

    /// Repository functions that call an IO sink (level 1, with the sink's name) and functions that call those
    /// (level 2), outside tests. Computed once per index version.
    func sinkWrappers() throws -> SinkWrappers {
        try memoized("sinkWrappers") {
            let db = try db
            var direct: [Int64: [String]] = [:]
            let names = IOSinks.names.map { "'\($0)'" }.joined(separator: ",")
            try db.forEach("""
                SELECT r.from_symbol_id, r.name, r.receiver, r.arg_labels, f.language, r.target_symbol_id, r.confidence
                FROM refs r JOIN files f ON f.id = r.file_id
                WHERE r.kind = 'call' AND r.name IN (\(names)) AND r.from_symbol_id IS NOT NULL AND f.is_test = 0
                """) { row in
                let resolved = row.optionalInt64(5) != nil && row.double(6) >= Self.useThreshold
                let labels = row.optionalString(3).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
                guard IOSinks.kind(name: row.string(1), receiver: row.optionalString(2), language: Language(rawValue: row.string(4)) ?? .unknown,
                                   argumentLabels: labels, resolvedInRepository: resolved) != nil else { return }
                if direct[row.int64(0), default: []].contains(row.string(1)) == false { direct[row.int64(0), default: []].append(row.string(1)) }
            }
            var indirect = Set<Int64>()
            if !direct.isEmpty {
                try db.forEach("""
                    SELECT DISTINCT r.from_symbol_id FROM refs r JOIN files f ON f.id = r.file_id
                    WHERE r.target_symbol_id IN (\(Array(direct.keys).sqlList)) AND r.kind = 'call' AND r.confidence >= ? AND r.from_symbol_id IS NOT NULL AND f.is_test = 0
                    """, [Self.useThreshold]) { indirect.insert($0.int64(0)) }
            }
            return SinkWrappers(direct: direct, indirect: indirect.subtracting(direct.keys))
        }
    }
}

/// Functions that write through an IO sink: `direct` call one (`FDFile.writeAll` → `pwrite`), `indirect` call such
/// a function (`Wax.writeHeaderPage`).
struct SinkWrappers: Sendable {
    let direct: [Int64: [String]]
    let indirect: Set<Int64>
}

/// Builds one feature map.
final class FeatureMapBuilder {
    let context: FeatureContext
    let focus: String?
    var analysis: QuestionAnalysis { context.analysis }
    var db: SQLiteDatabase { context.db }

    init(context: FeatureContext, focus: String?) {
        self.context = context
        self.focus = focus
    }

    // MARK: Seeds

    struct FrameworkSeed {
        /// As stored in `imports.external_name`.
        let module: String
        let name: String
        let importers: Set<Int64>
        /// Named by the question or one of its phrases, not only implied by a concept.
        let isNamed: Bool
    }

    /// Frameworks the question names or implies that the repository imports (mocks aside).
    func frameworkSeeds() throws -> [FrameworkSeed] {
        var wanted: [(module: String, named: Bool)] = []
        for framework in analysis.frameworks { wanted.append((framework.lowercased(), true)) }
        // A phrase's frameworks are as good as named ("at rest" → crypto); a concept a single word triggers ("store"
        // → persistence) only suggests its frameworks.
        for concept in analysis.concepts {
            let named = analysis.parsed.phrases.contains(concept)
            for module in ConceptFrameworks.modules(forConcept: concept) { wanted.append((module, named)) }
        }
        guard !wanted.isEmpty else { return [] }
        var importers: [String: (name: String, files: Set<Int64>)] = [:]
        try db.forEach("SELECT external_name, file_id FROM imports WHERE external_name IS NOT NULL AND is_mock = 0") { row in
            let module = row.string(0)
            importers[module.lowercased(), default: (module, [])].files.insert(row.int64(1))
        }
        var seeds: [FrameworkSeed] = []
        for (module, named) in wanted {
            let key = module.lowercased()
            let lookup = importers[key] ?? (key == "node:crypto" ? importers["crypto"] : nil)
            guard let found = lookup else { continue }
            if let index = seeds.firstIndex(where: { $0.module == found.name }) {
                if named && !seeds[index].isNamed { seeds[index] = FrameworkSeed(module: found.name, name: seeds[index].name, importers: found.files, isNamed: true) }
                continue
            }
            seeds.append(FrameworkSeed(module: found.name, name: ConceptFrameworks.displayName(found.name), importers: found.files, isNamed: named))
        }
        return seeds
    }

    /// References to the seed frameworks' APIs: the linker's external references where it records them (in Swift,
    /// those the SDK catalog backs); in TypeScript and Python, uses of the names imported from the framework; and in
    /// Swift the receiver types used only in files importing it (`Product`, `Transaction`, `AppStore`), values named
    /// after them (`product`, `transaction`) when the linker does not type values, and unresolved calls that occur
    /// only there and name the question's concept (`.manageSubscriptionsSheet`). Environment reads are not calls
    /// into a framework.
    func externalSites(_ seeds: [FrameworkSeed]) throws -> [FeatureContext.Ref] {
        guard !seeds.isEmpty else { return [] }
        var found: [Int64: FeatureContext.Ref] = [:]
        let modules = seeds.map { "'\($0.module.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        if context.hasExternalRows {
            let rows = try context.refs(where: "r.is_external = 1 AND r.external_module IN (\(modules)) COLLATE NOCASE")
            for ref in try catalogBacked(rows, seeds: seeds) { found[ref.id] = ref }
        }
        // With the linker's external rows, the fallbacks below only take what it could not place in a module.
        let unplaced = context.hasExternalRows ? "(r.is_external = 0 OR r.external_module IS NULL) AND " : ""
        let importerFiles = Set(seeds.flatMap(\.importers))
        let infos = context.files(Array(importerFiles))
        let scriptFiles = importerFiles.filter { [.typescript, .javascript, .python].contains(infos[$0]?.language ?? .unknown) }
        let swiftFiles = importerFiles.filter { infos[$0]?.language == .swift }

        // Script languages: what the file imports from the framework, by binding.
        for seed in seeds {
            var bindings: [Int64: Set<String>] = [:]
            try db.forEach("SELECT file_id, names FROM imports WHERE external_name = ? AND is_mock = 0", [seed.module]) { row in
                guard scriptFiles.contains(row.int64(0)) else { return }
                for name in ImportNamesCodec.decode(row.optionalString(1)) { bindings[row.int64(0), default: []].insert(name.alias ?? name.name) }
            }
            for (fileID, names) in bindings where !names.isEmpty {
                let list = names.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
                for ref in try context.refs(where: "r.file_id = ? AND (r.receiver IN (\(list)) OR (r.receiver IS NULL AND r.name IN (\(list)))) AND r.kind != 'import'", [fileID]) {
                    found[ref.id] = ref
                }
            }
        }

        // Swift: static member accesses (`Transaction.updates`) the framework's importers make and no other Swift
        // file leaves unresolved. Pairs, not type names: SwiftUI's `Transaction()` elsewhere does not hide StoreKit's.
        if !swiftFiles.isEmpty {
            let inside = Array(swiftFiles).sqlList
            var pairs = Set<String>()
            var receivers = Set<String>()
            try db.forEach("""
                SELECT DISTINCT r.receiver, r.name FROM refs r
                WHERE r.file_id IN (\(inside)) AND \(unplaced)r.target_symbol_id IS NULL AND r.receiver GLOB '[A-Z]*' AND r.kind != 'type'
                  AND r.name NOT LIKE 'env:%'
                """) { row in
                pairs.insert(row.string(0) + "\u{1}" + row.string(1))
                receivers.insert(row.string(0))
            }
            if !receivers.isEmpty {
                let list = receivers.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
                try db.forEach("""
                    SELECT DISTINCT r.receiver, r.name FROM refs r JOIN files f ON f.id = r.file_id
                    WHERE f.language = 'swift' AND r.file_id NOT IN (\(inside)) AND r.target_symbol_id IS NULL AND r.receiver IN (\(list))
                    """) { row in
                    pairs.remove(row.string(0) + "\u{1}" + row.string(1))
                }
                let repoTypes = Set(try db.query("SELECT DISTINCT name FROM symbols WHERE name IN (\(list)) AND kind IN ('class','struct','enum','protocol','actor','typealias')") { $0.string(0) })
                pairs = pairs.filter { !repoTypes.contains(String($0.split(separator: "\u{1}")[0])) }
            }
            let types = Set(pairs.map { String($0.split(separator: "\u{1}")[0]) })
            if !types.isEmpty {
                let list = types.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
                for ref in try context.refs(where: "r.file_id IN (\(inside)) AND \(unplaced)r.receiver IN (\(list)) AND r.target_symbol_id IS NULL AND r.name NOT LIKE 'env:%'") {
                    if pairs.contains((ref.receiver ?? "") + "\u{1}" + ref.name) { found[ref.id] = ref }
                }
            }
            // Values named after a framework type that nothing typed (`if case .verified(let transaction)`):
            // `transaction.finish()`. A one-word type names its values (`transaction`, `verifiedTransaction`); a
            // longer one only whole (`appStore`), so `store` and `error` stay unclaimed.
            let valueTypes = types.union(found.values.filter { swiftFiles.contains($0.fileID) }.compactMap { ref in
                ref.receiverType.flatMap { $0.split(separator: ".").first.map(String.init) } ?? (Self.typeLikeKinds.contains(ref.kind) ? ref.name : nil)
            }).filter { $0.first?.isUppercase == true }
            if !valueTypes.isEmpty {
                let wholeNames = Set(valueTypes.map { $0.lowercased() })
                let oneWord = Set(valueTypes.filter { Tokenizer.splitIdentifier($0).count == 1 }.map { $0.lowercased() })
                for ref in try context.refs(where: """
                    r.file_id IN (\(inside)) AND \(unplaced)r.receiver GLOB '[a-z]*' AND (r.target_symbol_id IS NULL OR r.confidence < ?) AND r.receiver NOT LIKE '%.%'
                    """, [context.threshold]) {
                    guard let receiver = ref.receiver else { continue }
                    let last = Tokenizer.splitIdentifier(receiver).last ?? ""
                    if wholeNames.contains(receiver.lowercased()) || oneWord.contains(last) { found[ref.id] = ref }
                }
            }
            // Calls that only the framework's importers make and that name the question's concept.
            let terms = analysis.allTerms
            let placedHere = context.hasExternalRows ? "(r.is_external = 0 OR r.external_module IS NULL OR r.external_module IN (\(modules))) AND " : ""
            for ref in try context.refs(where: "r.file_id IN (\(inside)) AND \(placedHere)r.kind = 'call' AND r.target_symbol_id IS NULL AND (r.receiver IS NULL OR r.receiver IN ('_', '.'))") {
                guard found[ref.id] == nil, FeatureContext.match(Tokenizer.splitIdentifier(ref.name), terms: terms) >= 0.5 else { continue }
                let elsewhere = try db.scalarInt("""
                    SELECT COUNT(*) FROM refs r JOIN files f ON f.id = r.file_id WHERE r.name = ? AND r.file_id NOT IN (\(inside)) AND f.language = 'swift'
                    """, [ref.name])
                let declared = try db.scalarInt("SELECT COUNT(*) FROM symbols WHERE name = ?", [ref.name])
                if elsewhere == 0 && declared == 0 { found[ref.id] = ref }
            }
        }
        return Array(found.values)
    }

    /// The linker's references into the seed frameworks that the SDK catalog backs. A script file's come from its
    /// import bindings and all count. A Swift file's module can be a guess (a file whose only framework import is
    /// StoreKit gets SwiftUI's `CircularProgressViewStyle` put in StoreKit), so a Swift reference counts when the
    /// type it uses (its receiver's type, or the type it names) or the function it calls is the catalog's for that
    /// module; a type two modules declare (`Transaction`: StoreKit and SwiftUI) counts only for uses that no Swift
    /// file without the module's import makes.
    func catalogBacked(_ rows: [FeatureContext.Ref], seeds: [FrameworkSeed]) throws -> [FeatureContext.Ref] {
        let infos = context.files(Array(Set(rows.map(\.fileID))))
        var kept: [FeatureContext.Ref] = []
        var shared: [String: [(ref: FeatureContext.Ref, key: String)]] = [:]
        for ref in rows {
            guard infos[ref.fileID]?.language == .swift else {
                kept.append(ref)
                continue
            }
            guard let module = ref.externalModule else { continue }
            let typeLike = Self.typeLikeKinds.contains(ref.kind)
            let type = ref.receiverType.flatMap { $0.first?.isLetter == true ? $0 : nil } ?? (typeLike ? ref.name : nil)
            guard let type else {
                // A free function (`pwrite`, `XCTAssertEqual`).
                if ref.receiver == nil, ref.isCall, FrameworkCatalog.module(forFunction: ref.name)?.caseInsensitiveCompare(module) == .orderedSame { kept.append(ref) }
                continue
            }
            let candidates = FrameworkCatalog.typeCandidates(type)
            guard candidates.contains(where: { $0.caseInsensitiveCompare(module) == .orderedSame }) else { continue }
            if candidates.count == 1 {
                kept.append(ref)
            } else {
                shared[module.lowercased(), default: []].append((ref, typeLike ? "t\u{1}\(ref.name)" : "m\u{1}\(type)\u{1}\(ref.name)"))
            }
        }
        for (module, entries) in shared {
            let importers = Array(seeds.filter { $0.module.lowercased() == module }.flatMap(\.importers))
            let types = Set(entries.compactMap { $0.ref.receiverType }).map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            let names = Set(entries.map(\.ref.name)).map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            var elsewhere = Set<String>()
            try db.forEach("""
                SELECT r.kind, r.receiver_type, r.name FROM refs r JOIN files f ON f.id = r.file_id
                WHERE f.language = 'swift' AND r.file_id NOT IN (\(importers.sqlList)) AND r.name IN (\(names))
                  AND (r.receiver_type IN (\(types.isEmpty ? "''" : types)) OR r.kind IN ('type', 'instantiate', 'conform', 'inherit'))
                """) { row in
                if Self.typeLikeKinds.contains(row.string(0)) { elsewhere.insert("t\u{1}\(row.string(2))") }
                if let type = row.optionalString(1) { elsewhere.insert("m\u{1}\(type)\u{1}\(row.string(2))") }
            }
            kept += entries.filter { !elsewhere.contains($0.key) }.map(\.ref)
        }
        return kept
    }

    static let typeLikeKinds: Set<String> = ["type", "instantiate", "conform", "inherit"]

    /// Environment variables whose name the question's terms cover (`DATA_ENCRYPTION_KEY` for "key … at rest"):
    /// two of its words, or one specific word, at full weight. Generic words (`id`, `path`, `url`) do not count.
    func environmentSeeds() throws -> Set<String> {
        let terms = analysis.allTerms
        let generic: Set<String> = ["id", "ids", "key", "path", "url", "name", "type", "data", "value", "mode", "level", "env", "app", "api", "dir", "file", "host", "port"]
        var seeds = Set<String>()
        try db.forEach("SELECT DISTINCT name FROM refs WHERE name LIKE 'env:%' AND name != 'env:*'") { row in
            let name = String(row.string(0).dropFirst(4))
            let words = name.split(whereSeparator: { $0 == "_" || $0 == ":" || $0 == "-" }).map { $0.lowercased() }
            let matched = words.filter { FeatureContext.match([$0], terms: terms) >= 0.6 }
            let specific = matched.filter { !generic.contains($0) }
            if matched.count >= 2 && !specific.isEmpty || specific.contains(where: { $0.count >= 5 && FeatureContext.match([$0], terms: terms) >= 0.8 }) {
                seeds.insert(name)
            }
        }
        return seeds
    }

    // MARK: Build

    func build() throws -> FeatureMapResult {
        let search = try context.engine.search()
        let outcome = try search.search(analysis.parsed, limit: 12)
        let seeds = try frameworkSeeds()
        let external = try externalSites(seeds)
        let environment = try environmentSeeds()
        let wrappers = try context.engine.sinkWrappers()
        debugTrace("parsed words=\(analysis.parsed.words) phrases=\(analysis.parsed.phrases) frameworks=\(analysis.frameworks) acronyms=\(analysis.acronyms) units=\(analysis.parsed.units)")
        debugTrace("roles=\(analysis.roles.map { "\($0.label): \($0.terms.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)=\($0.value)" })" })")
        debugTrace("concepts=\(analysis.concepts) flow=\(analysis.flowVerbs) seeds=\(seeds.map { "\($0.module)(\($0.importers.count))" }) env=\(environment)")
        debugTrace("external=\(external.count): \(Set(external.map { ($0.receiver ?? "-") + "." + $0.name }).sorted().prefix(40))")
        debugTrace("hits=\(outcome.hits.prefix(8).map { "\($0.path) \($0.relevance)" }) terms=\(outcome.terms)")

        if analysis.isFlow, let flow = try FlowBuilder(context: context, wrappers: wrappers).flow(forVerbs: analysis.flowVerbs, focus: focus, outcome: outcome) {
            return try flowResult(flow, outcome: outcome)
        }
        let strongExternal = try Set(externalSites(seeds.filter(\.isNamed)).map(\.id))
        guard let core = try chooseCore(outcome: outcome, external: external, strongExternal: strongExternal, environment: environment, wrappers: wrappers) else {
            return emptyResult(outcome: outcome, seeds: seeds)
        }
        return try assemble(core: core, outcome: outcome, seeds: seeds, external: external, strongExternal: strongExternal, environment: environment, wrappers: wrappers)
    }

    // MARK: Core

    /// The unit the feature is built around: a top-level type (Swift, Objective-C, …) or a file (TypeScript,
    /// JavaScript, Python), with its members.
    struct Core {
        let file: FeatureContext.FileInfo
        let type: RepositoryEngine.SymbolRow?
        /// Members by id: a type's members and its extensions' members; a file's top-level declarations.
        let members: [Int64: RepositoryEngine.SymbolRow]

        var ids: Set<Int64> { Set(members.keys).union(type.map { [$0.id] } ?? []) }
        var name: String { type?.name ?? (file.path as NSString).lastPathComponent }
    }

    func chooseCore(outcome: SearchOutcome, external: [FeatureContext.Ref], strongExternal: Set<Int64>, environment: Set<String>, wrappers: SinkWrappers) throws -> Core? {
        if let focus, let core = try focusCore(focus) { return core }
        var restrictTo: String?
        if let focus, case .folder(let path, _) = try? context.engine.resolveUsageTarget(focus) { restrictTo = path }

        // Candidate units and their evidence.
        var score: [String: Double] = [:]
        var units: [String: (file: Int64, type: RepositoryEngine.SymbolRow?)] = [:]
        var typesByFile: [Int64: [RepositoryEngine.SymbolRow]] = [:]
        func unitTypes(_ fileID: Int64) -> [RepositoryEngine.SymbolRow] {
            if let cached = typesByFile[fileID] { return cached }
            let rows = context.symbolRows(where: "s.file_id = ? AND s.depth = 0 AND s.kind IN ('class','struct','enum','actor','protocol','interface','component')", [fileID])
            typesByFile[fileID] = rows
            return rows
        }
        func unit(fileID: Int64, line: Int) -> String? {
            guard let info = context.file(fileID), !info.isTest, !HybridSearch.isDemoPath(info.path) else { return nil }
            if let restrictTo, !info.path.hasPrefix(restrictTo + "/") { return nil }
            if [.typescript, .javascript, .python].contains(info.language) {
                let key = "file:\(fileID)"
                units[key] = (fileID, nil)
                return key
            }
            guard let type = unitTypes(fileID).first(where: { $0.lines.start <= line && line <= $0.lines.end }) else { return nil }
            let key = "type:\(type.id)"
            units[key] = (fileID, type)
            return key
        }
        // Calls into the question's named frameworks count 3 each; into frameworks a concept only suggests, at most
        // 1 per unit (a schema file calls its ORM on every line without being the feature).
        var suggested: [String: Double] = [:]
        for ref in external where ref.kind != "type" {
            guard let key = unit(fileID: ref.fileID, line: ref.line) else { continue }
            if strongExternal.contains(ref.id) {
                score[key, default: 0] += 3
            } else {
                suggested[key, default: 0] += 0.25
            }
        }
        for (key, value) in suggested { score[key, default: 0] += min(1, value) }
        if !environment.isEmpty {
            let names = environment.map { "'env:\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            for ref in try context.refs(where: "r.name IN (\(names))") {
                if let key = unit(fileID: ref.fileID, line: ref.line) { score[key, default: 0] += 2 }
            }
        }
        // Search matches: a unit's three best symbols, weighted by the file's relevance.
        var covered: [String: Set<String>] = [:]
        for (rank, hit) in outcome.hits.prefix(10).enumerated() {
            guard let top = hit.symbols.map(\.score).max(), top > 0 else { continue }
            let weight = hit.relevance * (rank < 3 ? 1 : 0.6)
            var perUnit: [String: [Double]] = [:]
            for symbol in hit.symbols {
                if let key = unit(fileID: hit.fileID, line: symbol.lines.start) {
                    perUnit[key, default: []].append(symbol.score / top)
                    covered[key, default: []].formUnion(hit.coveredUnits)
                }
            }
            for (key, values) in perUnit { score[key, default: 0] += 4 * weight * values.sorted(by: >).prefix(3).reduce(0, +) }
        }
        // What the other matches build on: each other matching file that uses the unit adds 2, at most 3 of them.
        // A file's dependents count for a file; a type's are the files that use the type or its members.
        let hitFiles = Array(outcome.hits.prefix(10).map(\.fileID))
        if !hitFiles.isEmpty {
            var fileDependents: [Int64: Int] = [:]
            try db.forEach("SELECT dst_file_id, COUNT(DISTINCT src_file_id) FROM file_edges WHERE src_file_id IN (\(hitFiles.sqlList)) AND dst_file_id != src_file_id GROUP BY dst_file_id") { row in
                fileDependents[row.int64(0)] = row.int(1)
            }
            for (key, unit) in units {
                var count = fileDependents[unit.file] ?? 0
                if let type = unit.type {
                    count = try db.scalarInt("""
                        SELECT COUNT(DISTINCT r.file_id) FROM refs r
                        WHERE r.file_id IN (\(hitFiles.sqlList)) AND r.file_id != ? AND r.confidence >= ?
                          AND (r.target_symbol_id = ? OR r.target_symbol_id IN (SELECT id FROM symbols WHERE parent_id = ?))
                        """, [type.fileID, context.threshold, type.id, type.id])
                }
                score[key, default: 0] += 2 * Double(min(3, count))
            }
        }
        // A unit named after what the question asks about (`BookSyncQueue` for "sync books") adds 3 per subject.
        let subjects = Set(analysis.parsed.units.flatMap { $0.lowercased().split(separator: " ").map(String.init) }.filter { $0.count >= 3 })
        for (key, unit) in units {
            let name = unit.type?.name ?? ((context.file(unit.file)?.path ?? "") as NSString).lastPathComponent.components(separatedBy: ".").first ?? ""
            let words = Set(Tokenizer.splitIdentifier(name).flatMap { [$0, Tokenizer.stem($0)] })
            let hits = subjects.filter { words.contains($0) || words.contains(Tokenizer.stem($0)) }
            score[key, default: 0] += 3 * Double(hits.count)
        }
        let persistence = analysis.concepts.contains("persistence") || analysis.concepts.contains("on disk")
        if persistence, !wrappers.direct.isEmpty {
            for id in wrappers.direct.keys {
                guard let row = context.symbol(id), let key = unit(fileID: row.fileID, line: row.lines.start) else { continue }
                score[key, default: 0] += 1
            }
        }
        for (key, value) in score.sorted(by: { $0.value > $1.value }).prefix(8) {
            let label = units[key].map { unit in unit.type?.qualifiedName ?? context.file(unit.file)?.path ?? key } ?? key
            debugTrace("core candidate \(label) \(value)")
        }
        guard let best = score.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }), best.value > 0, let chosen = units[best.key],
              let file = context.file(chosen.file) else { return nil }
        // Too little to go on: no framework call or environment link of the question's, and the unit's files match
        // under half of what the question names (`quantum flux capacitor`).
        let unitsAsked = max(1, analysis.parsed.units.count)
        let hasDirectEvidence = external.contains { strongExternal.contains($0.id) && $0.fileID == chosen.file } || !environment.isEmpty
        if !hasDirectEvidence && Double(covered[best.key]?.count ?? 0) < 0.5 * Double(unitsAsked) {
            debugTrace("core rejected: covers \(covered[best.key] ?? []) of \(analysis.parsed.units)")
            return nil
        }
        return core(file: file, type: chosen.type)
    }

    /// The core for a `focus` target: the type itself, a member's top-level type, or a file (its main type in Swift).
    func focusCore(_ focus: String) throws -> Core? {
        switch try context.engine.resolveUsageTarget(focus) {
        case .symbol(let rows):
            guard var row = rows.first else { return nil }
            while !row.kind.isType || row.parentID != nil, let parent = row.parentID.flatMap({ context.symbol($0) }) { row = parent }
            guard let file = context.file(row.fileID) else { return nil }
            return core(file: file, type: row.kind.isType ? row : nil)
        case .file(let id, _):
            guard let file = context.file(id) else { return nil }
            if [.typescript, .javascript, .python].contains(file.language) { return core(file: file, type: nil) }
            let types = context.symbolRows(where: "s.file_id = ? AND s.depth = 0 AND s.kind IN ('class','struct','enum','actor','protocol')", [id])
            return core(file: file, type: types.max { $0.lines.count < $1.lines.count })
        default:
            return nil
        }
    }

    func core(file: FeatureContext.FileInfo, type: RepositoryEngine.SymbolRow?) -> Core {
        var members: [Int64: RepositoryEngine.SymbolRow] = [:]
        if let type {
            for row in context.symbolRows(where: "s.parent_id = ?", [type.id]) { members[row.id] = row }
            // Members added in extensions of the type, in files that are not tests.
            for row in context.symbolRows(where: """
                s.parent_id IN (SELECT e.id FROM symbols e JOIN files ef ON ef.id = e.file_id WHERE e.kind = 'extension' AND e.name = ? AND ef.is_test = 0)
                """, [type.name]) {
                members[row.id] = row
            }
        } else {
            for row in context.symbolRows(where: "s.file_id = ? AND s.depth = 0", [file.id]) { members[row.id] = row }
        }
        return Core(file: file, type: type, members: members)
    }

    // MARK: Assembly

    func assemble(core: Core, outcome: SearchOutcome, seeds: [FrameworkSeed], external: [FeatureContext.Ref], strongExternal: Set<Int64>,
                  environment: Set<String>, wrappers: SinkWrappers) throws -> FeatureMapResult {
        let externalIDs = Set(external.map(\.id))
        // Call-site rows show a file's calls into the frameworks the question names, not ones a concept suggests.
        let externalByFile = Dictionary(grouping: external.filter { $0.fileID != core.file.id && strongExternal.contains($0.id) && $0.kind != "type" }, by: \.fileID)
        let memberIDs = Array(core.members.keys)
        var refsByMember: [Int64: [FeatureContext.Ref]] = [:]
        if !memberIDs.isEmpty {
            for ref in try context.refs(where: "r.from_symbol_id IN (\(memberIDs.sqlList))") {
                if let from = ref.fromSymbol { refsByMember[from, default: []].append(ref) }
            }
        }
        context.extras(memberIDs)

        let storedState = Set(core.members.values.filter { ($0.kind == .property || $0.kind == .variable) && $0.lines.count <= 3 }.map(\.id))
        // Members that can play a role: behaviour, not stored state or nested types.
        let behaviour = core.members.values.filter { row in
            if row.kind.isType || row.kind == .extension || row.kind == .enumCase { return false }
            // A computed property has a body and no initial value; stored state shows through its writes.
            if row.kind == .property || row.kind == .variable || row.kind == .constant {
                return row.lines.count > 1 && !(row.signature ?? "").contains("=")
            }
            return true
        }
        let labeler = RoleLabeler(roles: analysis.roles.isEmpty ? [defaultRole()] : analysis.roles, mentionsAnalytics: analysis.parsed.mentionsAnalytics)
        let candidates = behaviour.map { row -> RoleLabeler.Candidate in
            let refs = refsByMember[row.id] ?? []
            let externalWords = refs.filter { externalIDs.contains($0.id) }.flatMap { FeatureContext.words($0.name) }
            let sinks = Set(refs.compactMap { ref -> IOSinks.Kind? in
                guard ref.isCall else { return nil }
                return IOSinks.kind(name: ref.name, receiver: ref.receiver, language: core.file.language, argumentLabels: ref.labels, resolvedInRepository: ref.target != nil)
            })
            let doc = row.doc.map { String($0.prefix(400)) }
            var candidate = RoleLabeler.Candidate(id: row.id, name: row.name, doc: doc, externalWords: externalWords, sinkKinds: sinks)
            candidate.callsFramework = refs.contains { externalIDs.contains($0.id) && $0.kind != "type" }
            candidate.writtenState = refs.filter { $0.kind == "write" && $0.conditions == nil && $0.target.map(storedState.contains) == true }
                .compactMap { $0.target.flatMap { core.members[$0]?.name } }
            return candidate
        }
        let order: (Int64) -> Int = { core.members[$0]?.lines.start ?? 0 }
        var assigned = labeler.assign(candidates, order: order)
        for candidate in candidates {
            if let best = labeler.role(for: candidate) { debugTrace("role \(candidate.name) → \(labeler.roles[best.index].label) \(best.score)") }
        }

        // Delegation: a short member that hands its work to another shows the other's lines.
        var absorbed = Set<Int64>()
        var delegates: [Int64: RepositoryEngine.SymbolRow] = [:]
        for group in assigned {
            for id in group.members {
                guard let row = core.members[id], let callee = DecisiveLines.delegate(of: row, refs: refsByMember[id] ?? [], members: core.members, threshold: context.threshold) else { continue }
                delegates[id] = callee
                absorbed.insert(callee.id)
            }
        }
        assigned = assigned.map { group in (role: group.role, members: group.members.filter { !absorbed.contains($0) || delegates[$0] != nil }) }
        let roleMembers = Set(assigned.flatMap(\.members)).union(delegates.values.map(\.id))
        var roleOrder: [Int64: Int] = [:]
        for (index, group) in assigned.enumerated() {
            for id in group.members { roleOrder[id] = index }
            for id in group.members { if let callee = delegates[id] { roleOrder[callee.id] = index } }
        }

        let decisive = DecisiveLines(context: context, externalRefs: externalIDs, sinkWrappers: Set(wrappers.direct.keys), storedState: storedState, roleMembers: roleMembers)
        var roles: [FeatureRole] = []
        for group in assigned where !group.members.isEmpty {
            var members: [FeatureMember] = []
            for id in group.members {
                guard let row = core.members[id] else { continue }
                var evidence: [FeatureEvidence]
                var delegate: FeatureRef?
                if let callee = delegates[id] {
                    delegate = FeatureRef(name: context.displayName(callee), path: callee.path, lines: callee.lines)
                    let picks = decisive.candidates(for: callee, refs: refsByMember[callee.id] ?? []) + decisive.candidates(for: row, refs: refsByMember[id] ?? [])
                    evidence = decisive.render(decisive.choose(picks, limit: 3), path: callee.path, primaries: 1)
                } else {
                    evidence = decisive.evidence(for: row, refs: refsByMember[id] ?? [], limit: 3, primaries: 2)
                }
                if evidence.isEmpty, row.lines.count <= 3, let statement = context.statement(row.path, line: row.lines.start, name: row.name) {
                    evidence = [FeatureEvidence(line: statement.start, code: statement.text(maxLength: 110), kind: .step, primary: true)]
                }
                members.append(FeatureMember(name: context.displayName(row), path: row.path, lines: row.lines, doc: FeatureContext.firstSentence(row.doc),
                                             delegate: delegate, evidence: evidence))
            }
            roles.append(FeatureRole(label: group.role.label, members: members))
        }

        // Constants: configuration-linked first.
        var linkedLines = Set<Int>()
        var configRows: [(path: String, line: Int?, kind: String, key: String?, codeLine: Int?)] = []
        try db.forEach("SELECT config_path, config_line, kind, key, line FROM config_links WHERE file_id = ? ORDER BY kind, config_line", [core.file.id]) { row in
            if let line = row.optionalInt(4) { linkedLines.insert(line) }
            configRows.append((row.string(0), row.optionalInt(1), row.string(2), row.optionalString(3), row.optionalInt(4)))
        }
        let constants = core.members.values.filter { ($0.kind == .property || $0.kind == .constant || $0.kind == .variable) && $0.lines.count == 1 }
        let keyLiterals = try decisive.keyLiterals(Array(constants), linkedLines: linkedLines, readBy: roleMembers, terms: analysis.allTerms)

        let callSites: FeatureCallSites
        let users = ClusterUsers(context: context, roleOrder: roleOrder, externalByFile: externalByFile)
        if let type = core.type {
            callSites = try users.callSites(ofType: type, members: core.members)
        } else {
            let exported = core.members.filter { $0.value.isExported }
            callSites = try users.callSites(ofFile: core.file, exports: exported.isEmpty ? core.members : exported)
        }
        // The feature's own files: the core's, its users' and the best matches'.
        let featureFiles = Set([core.file.id] + callSites.files.filter { !$0.isTest }.compactMap { context.fileID(path: $0.path) } + outcome.hits.prefix(5).map(\.fileID))
        let environmentLinks = try environmentLinks(core: core, seeds: environment, featureFiles: featureFiles, decisive: decisive)
        let tables = try tablesTouched(core: core, callSites: callSites)
        let config = try configEvidence(configRows, core: core)
        let docs = try DocsSlot(context: context).best(near: [core.file.path] + outcome.hits.prefix(3).map(\.path), candidates: [], terms: analysis.allTerms)
        let cluster = Set([core.file.path] + callSites.files.map(\.path) + environmentLinks.flatMap { $0.writers.map(\.path) + $0.readers.map(\.path) } + tables.map(\.path))
        let lookalikes = try lookalikes(outcome: outcome, cluster: cluster, core: core)
        let coverage = coverage(roles: roles, callSites: callSites, environment: environmentLinks, tables: tables)

        var featureCore = FeatureCore(path: core.file.path, name: core.type?.qualifiedName, signature: core.type?.signature, lines: core.type?.lines ?? LineRange(1, max(1, linesInFile(core.file.path))))
        if let type = core.type { featureCore.access = access(to: type, members: core.members) }
        return FeatureMapResult(question: analysis.question, headline: headline(seeds: seeds), core: featureCore, keyLiterals: keyLiterals, roles: roles,
                                environment: environmentLinks, tables: tables, callSites: callSites, config: config, docs: docs, notThisFeature: lookalikes, coverage: coverage)
    }

    /// When the question lists no roles: one role named after it, which every member with matching words plays.
    func defaultRole() -> QuestionAnalysis.Role {
        QuestionAnalysis.Role(label: "members", text: analysis.question, terms: analysis.allTerms)
    }

    func linesInFile(_ path: String) -> Int {
        context.engine.sourceText.file(path)?.lineCount ?? 1
    }

    /// How code reaches a type: a static property holding an instance (`static let shared :24`).
    func access(to type: RepositoryEngine.SymbolRow, members: [Int64: RepositoryEngine.SymbolRow]) -> String? {
        let shared = members.values.filter { row in
            guard row.kind == .property, let signature = row.signature, signature.contains("static ") else { return false }
            return signature.contains("= \(type.name)(") || signature.hasSuffix(": \(type.name)") || signature.contains(": \(type.name) =")
        }.min { $0.lines.start < $1.lines.start }
        guard let shared else { return nil }
        let keyword = (shared.signature ?? "").contains("static var") ? "static var" : "static let"
        return "\(keyword) \(shared.name) :\(shared.lines.start)"
    }

    // MARK: Environment

    /// Environment variables the core reads or writes, plus seeded ones that the feature's files use, with both
    /// sides; for a variable the core reads, the function that sets it and its decisive lines; and the setting
    /// file's other variables.
    func environmentLinks(core: Core, seeds: Set<String>, featureFiles: Set<Int64>, decisive: DecisiveLines) throws -> [FeatureEnvLink] {
        var names: [String] = []
        let coreRange = core.type?.lines
        for ref in try context.refs(where: "r.file_id = ? AND r.name LIKE 'env:%' AND r.name != 'env:*' ORDER BY r.line", [core.file.id]) {
            if let range = coreRange, !(range.start...range.end).contains(ref.line) { continue }
            let name = String(ref.name.dropFirst(4))
            if !names.contains(name) { names.append(name) }
        }
        // A seed that only other code uses (`__XCODE_BUILT_PRODUCTS_DIR_PATHS` for "loading products") matched a
        // word, not the feature.
        for seed in seeds.sorted() where !names.contains(seed) {
            let files = try db.query("SELECT DISTINCT file_id FROM refs WHERE name = ?", ["env:" + seed]) { $0.int64(0) }
            if files.contains(where: featureFiles.contains) { names.append(seed) }
        }
        guard !names.isEmpty else { return [] }

        var links: [FeatureEnvLink] = []
        var producerFiles: [Int64] = []
        for name in names.prefix(4) {
            let sites = try context.refs(where: "r.name = ? ORDER BY r.file_id, r.line", ["env:" + name])
            let (writers, readers) = environmentSites(sites, first: core.file.path)
            guard !writers.isEmpty || !readers.isEmpty else { continue }
            var link = FeatureEnvLink(name: name, writers: writers, readers: readers)
            // The function that sets it for the core, when the core reads it and production code sets it.
            if readers.contains(where: { $0.path == core.file.path }), let write = sites.first(where: { $0.kind == "write" && context.file($0.fileID)?.isTest == false && $0.fileID != core.file.id }),
               let function = write.fromSymbol.flatMap({ context.symbol($0) }) {
                let refs = try context.refs(where: "r.from_symbol_id = ?", [function.id])
                let evidence = decisive.render(decisive.choose(decisive.candidates(for: function, refs: refs), limit: 4), path: function.path, primaries: 2)
                let callers = try context.refs(where: "r.target_symbol_id = ? AND r.confidence >= ? ORDER BY r.line LIMIT 3", [function.id, context.threshold])
                    .map { FeatureCaller(name: $0.fromSymbol.flatMap { context.symbol($0) }.map { context.displayName($0) }, path: context.file($0.fileID)?.path ?? "", line: $0.line) }
                link.producer = FeatureMember(name: context.displayName(function), path: function.path, lines: function.lines, doc: FeatureContext.firstSentence(function.doc),
                                              evidence: evidence, calledBy: callers)
                if !producerFiles.contains(write.fileID) { producerFiles.append(write.fileID) }
            }
            links.append(link)
        }
        // The setting file's other variables, which the same start-up code sets.
        for fileID in producerFiles {
            for ref in try context.refs(where: "r.file_id = ? AND r.kind = 'write' AND r.name LIKE 'env:%' AND r.name != 'env:*' ORDER BY r.line", [fileID]) {
                let name = String(ref.name.dropFirst(4))
                guard !links.contains(where: { $0.name == name }), links.count < 6 else { continue }
                let sites = try context.refs(where: "r.name = ? ORDER BY r.file_id, r.line", [ref.name])
                let (writers, readers) = environmentSites(sites)
                guard readers.contains(where: { !$0.isTest }) else { continue }
                var link = FeatureEnvLink(name: name, writers: writers, readers: readers)
                if let function = ref.fromSymbol.flatMap({ context.symbol($0) }), let statement = context.statement(function.path, ref: ref) {
                    let callers = try context.refs(where: "r.target_symbol_id = ? AND r.confidence >= ? ORDER BY r.line LIMIT 3", [function.id, context.threshold])
                        .map { FeatureCaller(name: $0.fromSymbol.flatMap { context.symbol($0) }.map { context.displayName($0) }, path: context.file($0.fileID)?.path ?? "", line: $0.line) }
                    link.producer = FeatureMember(name: context.displayName(function), path: function.path, lines: function.lines,
                                                  evidence: [FeatureEvidence(line: statement.start, code: statement.text(maxLength: 110), kind: .env, primary: true)], calledBy: callers)
                }
                links.append(link)
            }
        }
        return links
    }

    func environmentSites(_ refs: [FeatureContext.Ref], first: String? = nil) -> (writers: [FeatureEnvSite], readers: [FeatureEnvSite]) {
        var writers: [FeatureEnvSite] = []
        var readers: [FeatureEnvSite] = []
        for ref in refs {
            guard let info = context.file(ref.fileID) else { continue }
            let function = ref.fromSymbol.flatMap { context.symbol($0) }.map { context.displayName($0) }
            let site = FeatureEnvSite(path: info.path, line: ref.line, function: function, isTest: info.isTest)
            if ref.kind == "write" { writers.append(site) } else { readers.append(site) }
        }
        // The core's file first, other production code after it, then configuration files (`drizzle.config.ts`),
        // tests last.
        func rank(_ site: FeatureEnvSite) -> Int {
            if site.path == first { return -1 }
            return site.isTest ? 2 : ((site.path as NSString).lastPathComponent.contains(".config.") ? 1 : 0)
        }
        let order: (FeatureEnvSite, FeatureEnvSite) -> Bool = { (rank($0), $0.path, $0.line) < (rank($1), $1.path, $1.line) }
        return (writers.sorted(by: order), readers.sorted(by: order))
    }

    // MARK: Tables

    /// Tables the feature's users write or read (`db.insert(apiTokens)`), with the columns the question names.
    func tablesTouched(core: Core, callSites: FeatureCallSites) throws -> [FeatureTable] {
        var fileIDs = [core.file.id]
        for file in callSites.files where !file.isTest {
            if let id = context.fileID(path: file.path) { fileIDs.append(id) }
        }
        var tableIDs: [Int64: Int] = [:]
        for ref in try context.refs(where: "r.file_id IN (\(fileIDs.sqlList)) AND r.target_symbol_id IS NOT NULL AND r.confidence >= ?", [context.threshold]) {
            if let target = ref.target { tableIDs[target, default: 0] += 1 }
        }
        guard !tableIDs.isEmpty else { return [] }
        let rows = context.symbols(Array(tableIDs.keys)).values.filter { Self.tableName($0.signature) != nil }
        let terms = analysis.allTerms
        var tables: [FeatureTable] = []
        for row in rows.sorted(by: { (tableIDs[$0.id] ?? 0, $1.qualifiedName) > (tableIDs[$1.id] ?? 0, $0.qualifiedName) }) {
            guard let name = Self.tableName(row.signature) else { continue }
            let relevance = FeatureContext.match(Tokenizer.splitIdentifier(row.name) + Tokenizer.splitIdentifier(name), terms: terms)
            guard relevance >= 0.8 else { continue }
            var columns: [(line: Int, text: String, field: String, column: String, score: Double)] = []
            for (number, text) in context.lines(row.path, LineRange(row.lines.start + 1, row.lines.end)) {
                guard let match = text.firstMatch(of: /(\w+)\s*:\s*\w+\(\s*["']([^"']+)["']/) else { continue }
                let words = Tokenizer.splitIdentifier(String(match.1)) + Tokenizer.splitIdentifier(String(match.2))
                columns.append((number, Statement.collapse(text), String(match.1), String(match.2), FeatureContext.match(words, terms: terms)))
            }
            let chosen = columns.filter { $0.score > 0 }.sorted { $0.score == $1.score ? $0.line < $1.line : $0.score > $1.score }.prefix(4).sorted { $0.line < $1.line }
            // The first column as its line; the others as `field "column"`, so the stored names stay whole.
            let evidence = chosen.enumerated().map { index, column in
                index == 0
                    ? FeatureEvidence(line: column.line, code: Statement.elide(column.text, to: 110, keeping: nil), kind: .column, primary: true)
                    : FeatureEvidence(line: column.line, code: "\(column.field) \"\(column.column)\"", kind: .column)
            }
            let (writers, readers) = try tableUsers(row)
            tables.append(FeatureTable(name: name, symbol: row.name, path: row.path, lines: row.lines, columns: evidence, writers: writers, readers: readers))
            if tables.count >= 2 { break }
        }
        return tables
    }

    /// The functions outside tests that write a table (`db.insert(apiTokens)`) and those that read it, at most
    /// 3 of each: the ones whose names the question's terms match first.
    func tableUsers(_ table: RepositoryEngine.SymbolRow) throws -> (writers: [FeatureCaller], readers: [FeatureCaller]) {
        var writers: [(caller: FeatureCaller, score: Double)] = []
        var readers: [(caller: FeatureCaller, score: Double)] = []
        var seen = Set<String>()
        for ref in try context.refs(where: "r.target_symbol_id = ? AND r.confidence >= ? AND r.file_id != ? ORDER BY r.file_id, r.line", [table.id, context.threshold, table.fileID]) {
            guard let info = context.file(ref.fileID), !info.isTest, let function = ref.fromSymbol.flatMap({ context.symbol($0) }) else { continue }
            let text = context.codeLine(info.path, ref.line) ?? ""
            let writes = text.contains("insert(") || text.contains("update(") || text.contains("delete(") || text.contains(".values(")
            let key = "\(writes)\u{1}\(function.id)"
            guard seen.insert(key).inserted else { continue }
            var name = context.displayName(function)
            if let route = RouteLabel.label(path: info.path, handler: function.name, isDefaultExport: function.name == "default") { name = route }
            let caller = FeatureCaller(name: name, path: info.path, line: ref.line)
            let score = FeatureContext.match(Tokenizer.splitIdentifier(function.name), terms: analysis.parsed.terms)
            if writes { writers.append((caller, score)) } else { readers.append((caller, score)) }
        }
        let order: ((caller: FeatureCaller, score: Double), (caller: FeatureCaller, score: Double)) -> Bool = {
            $0.score == $1.score ? ($0.caller.path, $0.caller.line) < ($1.caller.path, $1.caller.line) : $0.score > $1.score
        }
        return (writers.sorted(by: order).prefix(3).map(\.caller), readers.sorted(by: order).prefix(3).map(\.caller))
    }

    /// The stored name a table definition declares (`sqliteTable("asc_credentials", …)` → `asc_credentials`).
    static func tableName(_ signature: String?) -> String? {
        guard let signature, let match = signature.firstMatch(of: /(?:sqliteTable|pgTable|mysqlTable|Table|table|createTable)\(\s*["'`]([^"'`]+)["'`]/) else { return nil }
        return String(match.1)
    }

    // MARK: Config, lookalikes, coverage, headline

    func configEvidence(_ rows: [(path: String, line: Int?, kind: String, key: String?, codeLine: Int?)], core: Core) throws -> [FeatureConfig] {
        var byConfig: [String: [(line: Int?, kind: String, key: String?, codeLine: Int?)]] = [:]
        var order: [String] = []
        for row in rows {
            if byConfig[row.path] == nil { order.append(row.path) }
            byConfig[row.path, default: []].append((row.line, row.kind, row.key, row.codeLine))
        }
        var result: [FeatureConfig] = []
        for path in order {
            let entries = byConfig[path] ?? []
            let keys = entries.compactMap { entry in entry.key.map { key in entry.line.map { "\(key) :\($0)" } ?? key } }
            let codeLines = entries.compactMap(\.codeLine)
            var summary = keys.prefix(4).joined(separator: ", ")
            if let low = codeLines.min(), let high = codeLines.max() {
                summary += " = \((core.file.path as NSString).lastPathComponent):\(low == high ? "\(low)" : "\(low)-\(high)")"
            }
            // The schemes that use this configuration file.
            let schemes = try db.query("SELECT config_path, config_line FROM config_links WHERE kind = 'scheme-storekit' AND key = ? ORDER BY length(config_path), config_path LIMIT 1", [(path as NSString).lastPathComponent]) {
                "\(($0.string(0) as NSString).lastPathComponent):\($0.optionalInt(1).map(String.init) ?? "")"
            }
            if !schemes.isEmpty { summary += " · scheme " + schemes.joined(separator: ", ") }
            result.append(FeatureConfig(path: path, line: entries.compactMap(\.line).min(), summary: summary))
        }
        return result
    }

    /// Strong search matches outside the feature's files, each with the concern that explains it.
    func lookalikes(outcome: SearchOutcome, cluster: Set<String>, core: Core) throws -> [FeatureLookalike] {
        var result: [FeatureLookalike] = []
        for hit in outcome.hits.prefix(8) where !cluster.contains(hit.path) && hit.relevance >= 0.3 {
            guard let symbol = hit.symbols.first else { continue }
            let words = hit.symbols.prefix(4).flatMap { Tokenizer.splitIdentifier($0.qualifiedName) }
            var reason: String
            if let concern = ConceptLexicon.concerns(for: words).max(by: { $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value })?.key,
               !analysis.concepts.contains(where: { name in ConceptLexicon.concepts.first(where: { $0.name == name })?.concern == concern }) {
                reason = concern.displayName
            } else if let doc = FeatureContext.firstSentence(context.symbol(symbol.id)?.doc, limit: 50) {
                reason = doc.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            } else {
                reason = "matches \(hit.matchedTerms.prefix(2).joined(separator: ", "))"
            }
            if reason.isEmpty { continue }
            result.append(FeatureLookalike(name: symbol.qualifiedName, path: hit.path, reason: reason))
            if result.count >= 3 { break }
        }
        return result
    }

    /// Roles with code found for them: a member, or a call site, environment link or table that plays them.
    func coverage(roles: [FeatureRole], callSites: FeatureCallSites, environment: [FeatureEnvLink], tables: [FeatureTable]) -> FeatureCoverage {
        guard !analysis.roles.isEmpty else { return FeatureCoverage(found: roles.flatMap(\.members).isEmpty ? [] : [analysis.featureLabel]) }
        let labeler = RoleLabeler(roles: analysis.roles, mentionsAnalytics: analysis.parsed.mentionsAnalytics)
        var found = Set(roles.filter { !$0.members.isEmpty }.map(\.label))
        for file in callSites.files where !file.isTest {
            for group in file.groups {
                guard let caller = group.caller else { continue }
                let sinks: Set<IOSinks.Kind> = group.sites.contains { $0.note?.contains("insert") == true || $0.note?.contains("update") == true || $0.note?.contains("write") == true } ? [.database] : []
                let candidate = RoleLabeler.Candidate(id: 0, name: caller, doc: nil, externalWords: [], sinkKinds: sinks)
                if let role = labeler.role(for: candidate) { found.insert(analysis.roles[role.index].label) }
            }
        }
        if !tables.isEmpty, let store = analysis.roles.first(where: RoleLabeler.isStorageRole) { found.insert(store.label) }
        return FeatureCoverage(found: analysis.roles.map(\.label).filter(found.contains), missing: analysis.roles.map(\.label).filter { !found.contains($0) })
    }

    func headline(seeds: [FrameworkSeed]) -> FeatureHeadline {
        let frameworks = seeds.filter(\.isNamed).prefix(3).map { FeatureFramework(name: $0.name, importers: $0.importers.count) }
        var note: String?
        // A concept with known SDKs (payments, analytics…) of which the repository imports only these.
        for concept in ["payments", "analytics"] where analysis.concepts.contains(concept) && !seeds.isEmpty {
            note = "no other \(concept) SDK imported"
            break
        }
        return FeatureHeadline(feature: analysis.featureLabel, frameworks: Array(frameworks), note: note)
    }

    func emptyResult(outcome: SearchOutcome, seeds: [FrameworkSeed]) -> FeatureMapResult {
        let lookalikes = outcome.hits.prefix(5).compactMap { hit in hit.symbols.first.map { FeatureLookalike(name: $0.qualifiedName, path: hit.path, reason: "closest match") } }
        return FeatureMapResult(question: analysis.question, headline: headline(seeds: seeds), notThisFeature: lookalikes,
                                coverage: FeatureCoverage(found: [], missing: analysis.roles.isEmpty ? [analysis.featureLabel] : analysis.roles.map(\.label)))
    }

    func flowResult(_ flow: FlowView, outcome: SearchOutcome) throws -> FeatureMapResult {
        var anchors = [flow.body.path]
        anchors += flow.format.flatMap { $0.files.map(\.path) }.prefix(6)
        let docs = try DocsSlot(context: context).best(near: anchors, candidates: [], terms: analysis.allTerms)
        let headline = FeatureHeadline(feature: analysis.featureLabel)
        return FeatureMapResult(question: analysis.question, headline: headline, flow: flow, docs: docs,
                                coverage: FeatureCoverage(found: analysis.flowVerbs.filter { verb in flow.steps.contains { $0.isSink } || verb == analysis.flowVerbs.first }))
    }
}


private let featureMapTracing = ProcessInfo.processInfo.environment["VESALIUS_TRACE"] != nil

/// Prints how a feature map was built (parse, seeds, core candidates, roles) to stderr when VESALIUS_TRACE is set.
func debugTrace(_ message: @autoclosure () -> String) {
    guard featureMapTracing else { return }
    FileHandle.standardError.write(Data(("[trace] feature map: " + message() + "\n").utf8))
}
