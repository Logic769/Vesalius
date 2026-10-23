import Foundation
import GraphEngine
import LanguageAnalysis
import RepositoryIndex
import RepositoryScanner
import SemanticSearch
import VesaliusCore

public enum EngineError: Error, LocalizedError, Sendable {
    case repositoryMissing(String)
    case notIndexed(String)
    case notFound(String, suggestions: [String])
    case invalidQuery(String)

    public var errorDescription: String? {
        switch self {
        case .repositoryMissing(let path):
            "No repository at \(path). It may have been moved or deleted."
        case .notIndexed(let path):
            "\(path) has not been indexed yet. Run `vesalius index` first."
        case .notFound(let query, let suggestions):
            suggestions.isEmpty
                ? "Nothing in the index matches “\(query)”."
                : "Nothing in the index matches “\(query)”. Did you mean: \(suggestions.prefix(5).joined(separator: ", "))?"
        case .invalidQuery(let message):
            message
        }
    }
}

/// The single entry point to a repository's index, shared by the macOS app, the CLI and the MCP
/// server. Query methods are synchronous, thread-safe and read only from the index; `index` runs the
/// incremental pipeline on its own connection so queries keep working while it runs.
public final class RepositoryEngine: @unchecked Sendable {
    public let root: URL
    public let location: IndexLocation
    /// Source text for evidence (statements, conditions, completeness scans), cached across calls.
    let sourceText: SourceText
    /// Values computed once per index version.
    let memo = VersionedMemo()

    private let lock = NSRecursiveLock()
    private var cachedStore: IndexStore?
    private var cachedSearch: HybridSearch?
    private var cachedGraph: GraphCache?
    private var generation = 0
    /// The `index_version` the caches were last checked against (nil before the first check).
    private var observedIndexVersion: Int?

    public init(repository: URL) throws {
        let root = IndexLocation.canonicalRoot(repository)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw EngineError.repositoryMissing(root.path)
        }
        self.root = root
        self.location = IndexLocation(repositoryRoot: root)
        self.sourceText = SourceText(root: root)
        if !location.hasIndex {
            let identity = GitRepository(root: root).rootCommit()
            location.adoptMovedIndex(identity: identity)
        }
    }

    /// Finds the repository root for a working directory: the nearest ancestor that already has an
    /// index, else the git top level, else the directory itself.
    public static func locateRepository(from directory: URL) -> URL {
        var cursor = IndexLocation.canonicalRoot(directory)
        var gitRoot: URL?
        for _ in 0..<40 {
            if IndexLocation(repositoryRoot: cursor).hasIndex { return cursor }
            if gitRoot == nil, FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
                gitRoot = cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return gitRoot ?? IndexLocation.canonicalRoot(directory)
    }

    public var isIndexed: Bool {
        location.hasIndex && ((try? store().meta("last_indexed_at")) ?? nil) != nil
    }

    // MARK: - Connections & caches

    func store() throws -> IndexStore {
        lock.lock()
        defer { lock.unlock() }
        if let cachedStore { return cachedStore }
        guard location.hasIndex else { throw EngineError.notIndexed(root.path) }
        let store = try IndexStore(path: location.databaseURL.path)
        cachedStore = store
        return store
    }

    var db: SQLiteDatabase {
        get throws { try store().db }
    }

    func search() throws -> HybridSearch {
        lock.lock()
        defer { lock.unlock() }
        if let cachedSearch { return cachedSearch }
        let search = try HybridSearch(db: try db)
        cachedSearch = search
        return search
    }

    func graphCache() throws -> GraphCache {
        lock.lock()
        defer { lock.unlock() }
        if let cachedGraph { return cachedGraph }
        let cache = try GraphCache(db: try db)
        cachedGraph = cache
        return cache
    }

    private func dropConnections() {
        lock.lock()
        defer { lock.unlock() }
        cachedStore = nil
        cachedSearch = nil
        cachedGraph = nil
    }

    /// Drops in-memory caches (called after indexing and when another process updated the index).
    public func invalidateCaches() {
        lock.lock()
        defer { lock.unlock() }
        cachedSearch = nil
        cachedGraph = nil
        generation += 1
        sourceText.clear()
        memo.clear()
    }

    /// Increments whenever the index changes; UIs can use it to refresh.
    public var indexGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// The index's `index_version`: it increases whenever indexing changed anything, in any process.
    /// 0 when there is no index yet.
    public func indexVersion() -> Int {
        guard location.hasIndex, let store = try? store() else { return 0 }
        return store.meta("index_version").flatMap(Int.init) ?? 0
    }

    /// Drops the in-memory caches when another process (or another engine) re-indexed since the last check.
    /// Returns true when it did. Long-lived readers (the MCP server) call it before each request.
    @discardableResult
    public func refreshCachesIfIndexChanged() -> Bool {
        let current = indexVersion()
        lock.lock()
        defer { lock.unlock() }
        let previous = observedIndexVersion
        observedIndexVersion = current
        guard previous != current else { return false }
        // On the first check there is nothing to compare with; caches built before it may be from any version.
        guard previous != nil || cachedSearch != nil || cachedGraph != nil else { return false }
        invalidateCaches()
        return true
    }

    // MARK: - Indexing

    /// Builds or incrementally updates the index. Safe to call while queries run. Writers in this and other
    /// processes (the app, `vesalius watch`, the MCP server) take turns through the index lock.
    @discardableResult
    public func index(options: IndexOptions = IndexOptions(), rebuild: Bool = false, progress: @escaping @Sendable (IndexProgress) -> Void = { _ in }) async throws -> IndexSummary {
        guard FileManager.default.fileExists(atPath: root.path) else { throw EngineError.repositoryMissing(root.path) }
        try location.ensureDirectory()
        return try await IndexLock(location: location).withLock {
            if rebuild {
                dropConnections()
                // The database only: removing the directory would also delete the lock file this run holds.
                try location.removeDatabase()
            }
            let writer = try IndexStore(path: location.databaseURL.path)
            let pipeline = IndexingPipeline(root: root, store: writer, options: options)
            let summary = try await pipeline.run(progress: progress)
            try location.writeManifest(name: root.lastPathComponent, identity: GitRepository(root: root).rootCommit(), lastIndexedAt: Date())
            invalidateCaches()
            // This engine's caches are now current; a later version comes from another writer.
            observe(indexVersion: writer.meta("index_version").flatMap(Int.init) ?? 0)
            return summary
        }
    }

    private func observe(indexVersion: Int) {
        lock.lock()
        defer { lock.unlock() }
        observedIndexVersion = indexVersion
    }

    /// Indexes if there is no index yet, or refreshes when files changed since the last run.
    @discardableResult
    public func ensureFresh(options: IndexOptions = IndexOptions(), progress: @escaping @Sendable (IndexProgress) -> Void = { _ in }) async throws -> IndexSummary? {
        if !isIndexed {
            return try await index(options: options, progress: progress)
        }
        if try isOutdated || staleFileCount(options: options.scan) > 0 {
            return try await index(options: options, progress: progress)
        }
        return nil
    }

    /// True when the index was built with older analyzers, analysis or linking rules, so results must be
    /// recomputed even though no file changed.
    public var isOutdated: Bool {
        guard let store = try? store() else { return false }
        return store.meta("analysis_version") != String(IndexingPipeline.analysisVersion)
            || store.meta("linker_version") != String(ReferenceLinker.version)
            || store.meta("extractor_fingerprint") != IndexingPipeline.extractorFingerprint(.standard)
    }

    /// Number of files added, removed or modified since the last index (stat-only, no reads), including
    /// the project files the project model is read from.
    public func staleFileCount(options: ScanOptions = ScanOptions()) throws -> Int {
        let scan = try RepositoryScanner(root: root, options: options).scan()
        let store = try store()
        let stored = try store.storedFileStates()
        var stale = 0
        var seen = 0
        for file in scan.files {
            if let previous = stored[file.path] {
                seen += 1
                if previous.size != file.size || previous.modified != file.modified { stale += 1 }
            } else {
                stale += 1
            }
        }
        stale += max(0, stored.count - seen)
        let recorded = store.meta("project_files_stamp").flatMap { try? VesaliusJSON.decoder().decode([String: Double].self, from: Data($0.utf8)) } ?? [:]
        let current = ProjectModelIndexer.projectFileStamps(root: root)
        stale += Set(recorded.keys).union(current.keys).filter { recorded[$0] != current[$0] }.count
        return stale
    }

    /// The files among `paths` whose size or modification time no longer matches the index (edited, deleted or
    /// never indexed): their line numbers may point at different code.
    func staleFiles(_ paths: [String]) throws -> [String] {
        try paths.filter { path in
            guard let indexed = try db.queryOne("SELECT size, mtime FROM files WHERE path = ?", [path], { SourceText.Stamp(size: $0.int(0), modified: $0.double(1)) }) else { return true }
            return sourceText.isStale(path, indexed: indexed)
        }
    }

    // MARK: - Evidence

    /// The confidence at which a reference counts as a use in v2 results. Sites below it are listed as
    /// unresolved by `completeness`, never silently dropped. The legacy app and CLI APIs keep 0.35.
    static let useThreshold = ReferenceLinker.edgeThreshold

    /// `compute`'s value for `key`, computed once per index version.
    func memoized<T: Sendable>(_ key: String, _ compute: () throws -> T) rethrows -> T {
        try memo.value(for: key, version: indexVersion(), compute)
    }

    // MARK: - Status

    public func status(checkStaleness: Bool = false) throws -> RepositoryStatus {
        let info = repositoryInfo()
        guard isIndexed else {
            return RepositoryStatus(repository: info, indexPath: location.databaseURL.path, isIndexed: false, lastIndexed: nil, indexDurationSeconds: nil, schemaVersion: IndexSchema.version, stats: RepositoryStats())
        }
        let store = try store()
        let last = store.meta("last_indexed_at").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        let duration = store.meta("last_index_duration").flatMap(Double.init)
        let embeddings = try store.db.scalarInt("SELECT COUNT(*) FROM embeddings")
        return RepositoryStatus(
            repository: info,
            indexPath: location.databaseURL.path,
            isIndexed: true,
            lastIndexed: last,
            indexDurationSeconds: duration,
            schemaVersion: IndexSchema.version,
            stats: try stats(),
            staleFiles: checkStaleness ? try staleFileCount() : nil,
            embeddings: embeddings,
            vendoredDirectories: store.meta("vendored_directories").flatMap { try? VesaliusJSON.decoder().decode([String].self, from: Data($0.utf8)) }.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    public func repositoryInfo() -> RepositoryInfo {
        if let json = (try? store())?.meta("repository_info"),
           let info = try? VesaliusJSON.decoder().decode(RepositoryInfo.self, from: Data(json.utf8)) {
            return info
        }
        return GitRepository(root: root).info(name: root.lastPathComponent)
    }

    public func stats() throws -> RepositoryStats {
        let db = try db
        var stats = RepositoryStats()
        let codeLanguages = Language.allCases.filter(\.isCode).map { "'\($0.rawValue)'" }.joined(separator: ",")
        try db.forEach("""
            SELECT COUNT(*), SUM(CASE WHEN language IN (\(codeLanguages)) AND is_generated = 0 THEN 1 ELSE 0 END),
                   SUM(is_test), COALESCE(SUM(line_count), 0), COALESCE(SUM(code_lines), 0),
                   SUM(CASE WHEN parse_status = 'failed' THEN 1 ELSE 0 END)
            FROM files
            """) { row in
            stats.files = row.int(0)
            stats.sourceFiles = row.int(1)
            stats.testFiles = row.int(2)
            stats.lines = row.int(3)
            stats.codeLines = row.int(4)
            stats.parseFailures = row.int(5)
        }
        stats.directories = max(0, try db.scalarInt("SELECT COUNT(*) FROM directories") - 1)
        let typeKinds = SymbolKind.allCases.filter(\.isType).map { "'\($0.rawValue)'" }.joined(separator: ",")
        let callableKinds = SymbolKind.allCases.filter(\.isCallable).map { "'\($0.rawValue)'" }.joined(separator: ",")
        try db.forEach("SELECT COUNT(*), SUM(CASE WHEN kind IN (\(typeKinds)) THEN 1 ELSE 0 END), SUM(CASE WHEN kind IN (\(callableKinds)) THEN 1 ELSE 0 END) FROM symbols") { row in
            stats.symbols = row.int(0)
            stats.types = row.int(1)
            stats.functions = row.int(2)
        }
        stats.modules = try db.scalarInt("SELECT COUNT(*) FROM modules")
        stats.dependencies = try db.scalarInt("SELECT COUNT(*) FROM (SELECT DISTINCT src_file_id, dst_file_id FROM file_edges)")
        stats.references = try db.scalarInt("SELECT COALESCE(SUM(count), 0) FROM refs")
        stats.externalModules = try db.scalarInt("SELECT COUNT(DISTINCT external_name) FROM imports WHERE external_name IS NOT NULL")
        return stats
    }

    public func languages() throws -> [LanguageStat] {
        let rows = try db.query("SELECT language, COUNT(*), COALESCE(SUM(code_lines), 0) FROM files WHERE is_generated = 0 GROUP BY language") { row in
            (Language(rawValue: row.string(0)) ?? .unknown, row.int(1), row.int(2))
        }
        let code = rows.filter { $0.0.isCode }
        let total = max(1, code.reduce(0) { $0 + $1.2 })
        return code
            .map { LanguageStat(language: $0.0, files: $0.1, lines: $0.2, share: Double($0.2) / Double(total)) }
            .sorted { $0.lines > $1.lines }
    }

    // MARK: - Target resolution

    enum Target {
        case file(id: Int64, path: String)
        case symbols([SymbolRow])
        case group(id: String, label: String, fileIDs: [Int64])

        var description: String {
            switch self {
            case .file(_, let path): path
            case .symbols(let rows): rows.first.map { $0.qualifiedName } ?? "symbol"
            case .group(_, let label, _): label
            }
        }
    }

    struct SymbolRow: Hashable {
        let id: Int64
        let fileID: Int64
        let parentID: Int64?
        let name: String
        let qualifiedName: String
        let kind: SymbolKind
        let path: String
        let lines: LineRange
        let signature: String?
        let doc: String?
        let visibility: Visibility?
        let isExported: Bool
        let depth: Int
        /// Earlier declarations with the same qualified name in the same file (overloads, `#if`
        /// branches, a C struct and its typedef).
        let ordinal: Int

        /// `sym:path#Name`, or `sym:path#Name~2` for the second declaration of that name in the file,
        /// so every declaration has its own identity and unique names keep their plain id.
        var stableID: String {
            NodeID.symbol(path: path, qualifiedName: qualifiedName) + (ordinal > 0 ? "~\(ordinal + 1)" : "")
        }

        func summary(references: Int? = nil) -> SymbolSummary {
            SymbolSummary(id: stableID, name: name, qualifiedName: qualifiedName, kind: kind, path: path, lines: lines, signature: signature, doc: doc, visibility: visibility, isExported: isExported, references: references, depth: depth)
        }
    }

    static let symbolColumns = "s.id, s.file_id, s.parent_id, s.name, s.qualified_name, s.kind, f.path, s.start_line, s.end_line, s.signature, s.doc, s.visibility, s.is_exported, s.depth, (SELECT COUNT(*) FROM symbols d WHERE d.file_id = s.file_id AND d.qualified_name = s.qualified_name AND d.id < s.id)"

    static func symbolRow(_ row: SQLRow) -> SymbolRow {
        SymbolRow(
            id: row.int64(0), fileID: row.int64(1), parentID: row.optionalInt64(2), name: row.string(3), qualifiedName: row.string(4),
            kind: SymbolKind(rawValue: row.string(5)) ?? .variable, path: row.string(6), lines: LineRange(row.int(7), row.int(8)),
            signature: row.optionalString(9), doc: row.optionalString(10), visibility: row.optionalString(11).flatMap(Visibility.init(rawValue:)),
            isExported: row.bool(12), depth: row.int(13), ordinal: row.int(14)
        )
    }

    func symbolRows(where clause: String, _ values: [any SQLBindable], limit: Int = 200) throws -> [SymbolRow] {
        try db.query("SELECT \(Self.symbolColumns) FROM symbols s JOIN files f ON f.id = s.file_id WHERE \(clause) LIMIT \(limit)", values, cache: false, Self.symbolRow)
    }

    /// Resolves a user-supplied symbol reference: a stable id (`sym:path#Name`), a qualified name
    /// (`AuthService.signIn`), or a bare name. Types rank before members; exact case before
    /// case-insensitive.
    func resolveSymbols(_ text: String) throws -> [SymbolRow] {
        var query = text.trimmingCharacters(in: .whitespaces)
        if query.hasSuffix("()") { query.removeLast(2) }
        if let parsed = NodeID.parse(query), parsed.kind == .sym {
            let parts = parsed.value.split(separator: "#", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                // `Name~2`: the second declaration of that name in the file.
                if let match = parts[1].wholeMatch(of: /(.+)~(\d+)/), let ordinal = Int(match.2), ordinal >= 1 {
                    let rows = try symbolRows(where: "f.path = ? AND s.qualified_name = ? ORDER BY s.id", [parts[0], String(match.1)])
                    if rows.indices.contains(ordinal - 1) { return [rows[ordinal - 1]] }
                }
                return try symbolRows(where: "f.path = ? AND s.qualified_name = ? ORDER BY s.id", [parts[0], parts[1]])
            }
        }
        if query.contains("#") {
            let parts = query.split(separator: "#", maxSplits: 1).map(String.init)
            let rows = try symbolRows(where: "(f.path = ? OR f.path LIKE ?) AND (s.qualified_name = ? OR s.name = ?)", [parts[0], "%/" + parts[0], parts[1], parts[1]])
            if !rows.isEmpty { return rows }
        }
        var rows = try symbolRows(where: "s.qualified_name = ? AND s.kind != 'extension'", [query])
        if rows.isEmpty { rows = try symbolRows(where: "s.name = ? AND s.kind != 'extension'", [query]) }
        if rows.isEmpty { rows = try symbolRows(where: "s.qualified_name = ? COLLATE NOCASE AND s.kind != 'extension'", [query]) }
        if rows.isEmpty { rows = try symbolRows(where: "s.name = ? COLLATE NOCASE AND s.kind != 'extension'", [query]) }
        if rows.isEmpty, query.contains(".") {
            let last = String(query.split(separator: ".").last ?? "")
            rows = try symbolRows(where: "s.name = ? AND s.kind != 'extension'", [last])
        }
        return rows.sorted { a, b in
            let ta = a.kind.isType ? 0 : 1, tb = b.kind.isType ? 0 : 1
            if ta != tb { return ta < tb }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path < b.path
        }
    }

    /// Resolves a file path, file name, directory, module or symbol.
    func resolveTarget(_ text: String) throws -> Target {
        var query = text.trimmingCharacters(in: .whitespaces)
        if let parsed = NodeID.parse(query) {
            switch parsed.kind {
            case .file: query = parsed.value
            case .dir: return try groupTarget(directory: parsed.value == "." ? "" : parsed.value)
            case .mod: if let target = try moduleTarget(parsed.value) { return target }
            case .sym: return .symbols(try resolveSymbols(query))
            case .ext: throw EngineError.notFound(query, suggestions: [])
            }
        }
        // Absolute paths inside the repository.
        if query.hasPrefix("/") {
            let rootPath = root.path + "/"
            if query.hasPrefix(rootPath) { query = String(query.dropFirst(rootPath.count)) }
        }
        if query.hasPrefix("./") { query = String(query.dropFirst(2)) }
        if query.hasSuffix("/") { query.removeLast() }

        let db = try db
        if let row = try db.queryOne("SELECT id, path FROM files WHERE path = ?", [query], { ($0.int64(0), $0.string(1)) }) {
            return .file(id: row.0, path: row.1)
        }
        let suffixMatches = try db.query("SELECT f.id, f.path FROM files f LEFT JOIN file_metrics m ON m.file_id = f.id WHERE f.path LIKE ? ORDER BY COALESCE(m.centrality, 0) DESC, length(f.path) LIMIT 5", ["%/" + query]) { ($0.int64(0), $0.string(1)) }
        if let first = suffixMatches.first { return .file(id: first.0, path: first.1) }
        if try db.scalarInt("SELECT COUNT(*) FROM directories WHERE path = ?", [query]) > 0 {
            return try groupTarget(directory: query)
        }
        let nameMatches = try db.query("SELECT f.id, f.path FROM files f LEFT JOIN file_metrics m ON m.file_id = f.id WHERE f.name = ? COLLATE NOCASE ORDER BY COALESCE(m.centrality, 0) DESC, length(f.path) LIMIT 5", [query]) { ($0.int64(0), $0.string(1)) }
        if let first = nameMatches.first { return .file(id: first.0, path: first.1) }
        if let module = try moduleTarget(query) { return module }
        let symbols = try resolveSymbols(query)
        if !symbols.isEmpty { return .symbols(symbols) }
        // A file stem ("SettingsView" → SettingsView.swift).
        let stemMatches = try db.query("SELECT f.id, f.path FROM files f LEFT JOIN file_metrics m ON m.file_id = f.id WHERE f.name LIKE ? COLLATE NOCASE ORDER BY COALESCE(m.centrality, 0) DESC, length(f.path) LIMIT 5", [query + ".%"]) { ($0.int64(0), $0.string(1)) }
        if let first = stemMatches.first { return .file(id: first.0, path: first.1) }
        let directoryMatches = try db.query("SELECT path FROM directories WHERE name = ? COLLATE NOCASE ORDER BY depth LIMIT 1", [query]) { $0.string(0) }
        if let directory = directoryMatches.first { return try groupTarget(directory: directory) }
        throw EngineError.notFound(text, suggestions: try suggestions(for: query))
    }

    private func groupTarget(directory: String) throws -> Target {
        let ids = try db.query("SELECT id FROM files WHERE path LIKE ? OR ? = ''", [directory + "/%", directory]) { $0.int64(0) }
        return .group(id: NodeID.directory(directory), label: directory.isEmpty ? "." : directory, fileIDs: ids)
    }

    private func moduleTarget(_ name: String) throws -> Target? {
        guard let moduleID = try db.queryOne("SELECT id FROM modules WHERE name = ? COLLATE NOCASE ORDER BY kind LIMIT 1", [name], { $0.int64(0) }) else { return nil }
        let ids = try db.query("SELECT id FROM files WHERE module_id = ?", [moduleID]) { $0.int64(0) }
        return .group(id: NodeID.module(name), label: name, fileIDs: ids)
    }

    /// Fuzzy suggestions for a failed lookup (files and symbols).
    func suggestions(for query: String) throws -> [String] {
        let lower = query.lowercased()
        let words = Tokenizer.splitIdentifier(query)
        var results: [String] = []
        let pattern = "%" + (words.first ?? lower) + "%"
        results += try db.query("SELECT name FROM symbols WHERE name LIKE ? AND depth = 0 GROUP BY name ORDER BY length(name) LIMIT 5", [pattern]) { $0.string(0) }
        results += try db.query("SELECT path FROM files WHERE name LIKE ? ORDER BY length(path) LIMIT 5", [pattern]) { $0.string(0) }
        return Array(NSOrderedSet(array: results).array.compactMap { $0 as? String }.prefix(8))
    }

    func filePath(_ id: Int64) throws -> String? {
        try db.queryOne("SELECT path FROM files WHERE id = ?", [id]) { $0.string(0) }
    }

    /// Reads single source lines for the legacy reference snippets through `SourceText`: no per-call file budget
    ///, and the same decoding and line splitting as statement evidence.
    final class SnippetReader {
        private let source: SourceText

        init(root: URL) {
            source = SourceText(root: root)
        }

        init(source: SourceText) {
            self.source = source
        }

        func line(_ number: Int, in path: String) -> String? {
            source.snippetLine(number, in: path)
        }
    }
}

// MARK: - Evidence diagnostics (`vesalius debug`)

/// Plain-text views of the evidence layer for checking it by hand. Not a stable interface.
extension RepositoryEngine {
    /// Every occurrence of `name`, classified against `target` (any `usages` target string), with the
    /// completeness line it supports.
    public func completenessReport(name: String, target: String) throws -> String {
        let (ids, description, isMember) = try completenessTarget(target)
        let result = try completeness(of: name, targets: ids, options: CompletenessOptions(skipCommonNames: isMember))
        var lines = ["\"\(name)\" against \(description)", result.summary]
        var scope = "scanned \(result.scannedFiles) of \(result.candidateFiles) candidate files in \(String(format: "%.1f", result.elapsed * 1000)) ms"
        if result.unmatchedRows > 0 { scope += " · \(Self.plural(result.unmatchedRows, "reference row")) no longer \(result.unmatchedRows == 1 ? "matches its" : "match their") line" }
        lines.append(scope)
        let width = result.occurrences.map(\.category.rawValue.count).max() ?? 0
        for occurrence in result.sorted {
            let label = occurrence.category.rawValue.padding(toLength: width, withPad: " ", startingAt: 0)
            let code = sourceText.file(occurrence.path)?.text(ofLine: occurrence.line).map { Statement.elide(Statement.collapse($0), to: 100, keeping: nil) } ?? ""
            var line = "  \(label)  \(occurrence.path):\(occurrence.line)  \(code)"
            if occurrence.form != .plain { line += "  [\(occurrence.form.written(name))]" }
            if let detail = occurrence.detail { line += "  (\(detail))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func uses(_ uses: Int, files: Int) -> String {
        "\(plural(uses, "use")) in \(plural(files, "file"))"
    }

    /// The symbol ids a completeness check counts as the target, a description, and whether it is a member.
    private func completenessTarget(_ text: String) throws -> (ids: Set<Int64>, description: String, isMember: Bool) {
        switch try resolveUsageTarget(text) {
        case .symbol(let rows):
            let groups = try groupDeclarations(rows)
            let row = rows[0]
            let description = "\(try exactTarget(for: groups[0])) (\(row.kind.displayName), \(row.path):\(row.lines))"
            // An extension's target is what it adds: its members.
            let ids = rows.map(\.id)
            return (Set(ids + (try extensionMembers(of: ids))), description, row.parentID != nil && !row.kind.isType)
        case .file(let id, let path):
            let ids = try db.query("SELECT id FROM symbols WHERE file_id = ?", [id]) { $0.int64(0) }
            return (Set(ids), "the declarations of \(path)", false)
        case .folder(let path, let fileIDs):
            return (Set(try symbolIDs(inFiles: fileIDs)), "the declarations in \(path.isEmpty ? "." : path)/", false)
        case .module(let name, let fileIDs):
            return (Set(try symbolIDs(inFiles: fileIDs)), "the declarations of module \(name)", false)
        case .framework(let name, _):
            throw EngineError.invalidQuery("\(name) is a framework; completeness needs a declaration, file, folder or module target.")
        case .environment(let name):
            throw EngineError.invalidQuery("\(name) is an environment variable; completeness needs a declaration, file, folder or module target.")
        case .choices(let choices):
            throw EngineError.invalidQuery("“\(text)” matches \(choices.count) targets; pass one of: " + choices.prefix(8).map(\.target).joined(separator: ", "))
        }
    }

    private func symbolIDs(inFiles fileIDs: [Int64]) throws -> [Int64] {
        var ids: [Int64] = []
        for chunk in stride(from: 0, to: fileIDs.count, by: 500) {
            let slice = Array(fileIDs[chunk..<min(fileIDs.count, chunk + 500)])
            ids += try db.query("SELECT id FROM symbols WHERE file_id IN (\(slice.sqlList))") { $0.int64(0) }
        }
        return ids
    }

    /// The statement evidence for `path:line`: its bounds, the joined text, the `NNN │` lines a result would
    /// show, the enclosing condition, the consuming statement and freshness. The site is the reference named
    /// `name` on that line (else the first call, else the first reference).
    public func statementReport(path: String, line: Int, name: String? = nil) throws -> String {
        let path = Self.normalizedTarget(path, root: root)
        struct Site { let name: String; let column: Int; let stmt: Int?; let end: Int?; let callEnd: Int?; let consumer: Int? }
        var site: Site?
        if let fileID = try db.queryOne("SELECT id FROM files WHERE path = ?", [path], { $0.int64(0) }) {
            site = try db.queryOne("""
                SELECT name, col, stmt_line, end_line, call_end_line, consumer_line FROM refs
                WHERE file_id = ? AND line = ? AND (? IS NULL OR name = ?)
                ORDER BY CASE kind WHEN 'call' THEN 0 WHEN 'instantiate' THEN 1 ELSE 2 END, col LIMIT 1
                """, [fileID, line, name, name]) {
                Site(name: $0.string(0), column: $0.int(1), stmt: $0.optionalInt(2), end: $0.optionalInt(3), callEnd: $0.optionalInt(4), consumer: $0.optionalInt(5))
            }
        }
        // A file edited since indexing no longer matches the index's statement bounds or consumer line: balance
        // brackets instead.
        let stale = try staleFiles([path]).isEmpty == false
        guard let statement = stale
            ? sourceText.statement(path, line: line, name: site?.name ?? name)
            : sourceText.statement(path, line: line, stmt: site?.stmt, end: site?.end, callEnd: site?.callEnd, name: site?.name ?? name, column: site?.column) else {
            throw EngineError.notFound("\(path):\(line)", suggestions: [])
        }
        var lines = ["\(path):\(line)  statement \(statement.start)-\(statement.end) (\(statement.basis.rawValue))" + (statement.name.map { " · site \($0)" } ?? "")]
        lines.append("joined     \(statement.joined)")
        for (index, shown) in statement.rendered().enumerated() {
            lines.append((index == 0 ? "rendered   " : "           ") + "\(shown.number) │ \(shown.text)")
        }
        if let condition = sourceText.enclosingCondition(path, statementStart: statement.start) {
            lines.append("condition  \(condition.number) │ \(condition.text)")
        } else {
            lines.append("condition  none")
        }
        if !stale, let consumerLine = site?.consumer, let consumer = sourceText.consumer(path, line: consumerLine) {
            lines.append("consumer   → :\(consumer.number) \(consumer.text)")
        } else {
            lines.append("consumer   none")
        }
        var freshness = stale ? "stale: the file changed since it was indexed" : "fresh: size and modification time match the index"
        if let token = statement.name {
            freshness += " · line \(line) \(sourceText.lineContains(path, line: line, name: token) ? "contains" : "no longer contains") \(token)"
        }
        lines.append(freshness)
        return lines.joined(separator: "\n")
    }

    /// What a `usages` target string resolves to: one declaration (with its exact target string), a file, a
    /// folder, a module, a framework with its importers, an environment variable, or the choices.
    public func usageTargetReport(_ text: String) throws -> String {
        switch try resolveUsageTarget(text) {
        case .symbol(let rows):
            let groups = try groupDeclarations(rows)
            let row = rows[0]
            let counts = try useCounts(rows.map(\.id))
            var lines = ["\(text) → 1 declaration" + (rows.count > 1 ? " (\(rows.count) #if variants)" : "")]
            lines.append("  \(row.signature ?? row.qualifiedName)  \(row.path):\(row.lines) · \(row.kind.displayName) · \(Self.uses(counts.uses, files: counts.files))")
            lines.append("  exact target: \(try exactTarget(for: groups[0]))" + (groups[0].selector.map { " · selector \($0)" } ?? ""))
            return lines.joined(separator: "\n")
        case .file(let id, let path):
            let declarations = try db.scalarInt("SELECT COUNT(*) FROM symbols WHERE file_id = ? AND depth = 0", [id])
            let dependents = try db.scalarInt("SELECT COUNT(DISTINCT src_file_id) FROM file_edges WHERE dst_file_id = ? AND src_file_id != ?", [id, id])
            return "\(text) → file \(path)\n  \(declarations) top-level declarations · \(dependents) dependent files"
        case .folder(let path, let fileIDs):
            return "\(text) → folder \(path.isEmpty ? "." : path)/ (\(fileIDs.count) files)"
        case .module(let name, let fileIDs):
            let importers = try db.scalarInt("SELECT COUNT(DISTINCT i.file_id) FROM imports i JOIN modules m ON m.id = i.resolved_module_id WHERE m.name = ?", [name])
            return "\(text) → module \(name) (\(fileIDs.count) files, imported by \(importers) files)"
        case .framework(let name, let importers):
            let files = Set(importers.map(\.path)).count
            return (["\(text) → framework \(name), imported by \(files) \(files == 1 ? "file" : "files")"] + importers.map { "  \($0.path):\($0.line)" }).joined(separator: "\n")
        case .environment(let name):
            let uses = try db.queryOne("SELECT COUNT(*), COUNT(DISTINCT file_id) FROM refs WHERE name = ?", ["env:" + name]) { ($0.int(0), $0.int(1)) } ?? (0, 0)
            return "\(text) → environment variable \(name): \(uses.0) reads and writes in \(uses.1) files"
        case .choices(let choices):
            var lines = ["\(text) → \(choices.count) choices, nothing merged; pass one of these targets:"]
            let width = choices.map(\.target.count).max() ?? 0
            for choice in choices.sorted(by: { $0.uses == $1.uses ? $0.target < $1.target : $0.uses > $1.uses }) {
                let counted = switch choice.kind {
                case "module", "framework": "imported by \(Self.plural(choice.files, "file"))"
                case "file": Self.plural(choice.files, "dependent file")
                case "folder": Self.plural(choice.files, "file")
                default: Self.uses(choice.uses, files: choice.files)
                }
                lines.append("  \(choice.target.padding(toLength: width, withPad: " ", startingAt: 0))  \(choice.kind)" + (choice.location.map { " · \($0)" } ?? "") + " · \(counted)")
            }
            return lines.joined(separator: "\n")
        }
    }
}
