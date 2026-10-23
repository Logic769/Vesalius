import CryptoKit
import Foundation
import GraphEngine
import HealthEngine
import LanguageAnalysis
import RepositoryIndex
import RepositoryScanner
import SemanticSearch
import VesaliusCore

public struct IndexOptions: Sendable {
    public var scan: ScanOptions
    public var computeEmbeddings: Bool
    public var gitChurn: Bool
    public var concurrency: Int
    public var batchSize: Int

    public init(scan: ScanOptions = ScanOptions(), computeEmbeddings: Bool = true, gitChurn: Bool = true, concurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount), batchSize: Int = 192) {
        self.scan = scan
        self.computeEmbeddings = computeEmbeddings
        self.gitChurn = gitChurn
        self.concurrency = concurrency
        self.batchSize = batchSize
    }
}

/// Incrementally (re)builds a repository index. Only files whose size/mtime changed are re-read; only
/// files whose content hash changed are re-parsed (all of them when an analyzer changed); only references
/// affected by changed names are re-linked. Every batch is committed, so a cancelled run keeps its progress.
final class IndexingPipeline: @unchecked Sendable {
    let root: URL
    let store: IndexStore
    let registry: AnalyzerRegistry
    let options: IndexOptions

    init(root: URL, store: IndexStore, registry: AnalyzerRegistry = .standard, options: IndexOptions) {
        self.root = root
        self.store = store
        self.registry = registry
        self.options = options
    }

    struct PreparedFile: Sendable {
        enum Outcome: Sendable {
            case unchangedContent(id: Int64, size: Int, modified: Double)
            case write(FileRecord, FileAnalysis?, LexicalDocument)
            case unreadable(path: String, reason: String)
        }
        let path: String
        let outcome: Outcome
    }

    private static let tracing = ProcessInfo.processInfo.environment["VESALIUS_TRACE"] != nil
    private var phaseStart = Date()

    /// Prints phase timings to stderr when VESALIUS_TRACE is set.
    private func trace(_ phase: String) {
        guard Self.tracing else { return }
        let now = Date()
        FileHandle.standardError.write(Data(String(format: "[trace] %-28@ %7.2fs\n", phase as NSString, now.timeIntervalSince(phaseStart)).utf8))
        phaseStart = now
    }

    func run(progress: @escaping @Sendable (IndexProgress) -> Void) async throws -> IndexSummary {
        let started = Date()
        phaseStart = started
        var warnings: [String] = []

        // 1. Scan.
        progress(IndexProgress(phase: .scanning, completed: 0, total: 0))
        let scanner = RepositoryScanner(root: root, options: options.scan)
        let scan = try scanner.scan(isCancelled: { Task.isCancelled })
        warnings.append(contentsOf: scan.errors.prefix(20))
        if scan.truncated { warnings.append("Repository has more than \(options.scan.maxFiles) files; indexing was truncated.") }

        // Git history is read concurrently with parsing.
        let git = GitRepository(root: root)
        let churnTask: Task<[String: Int], Never>? = options.gitChurn ? Task.detached(priority: .utility) { git.churn() } : nil

        trace("scan (\(scan.files.count) files)")
        let detection = ModuleDetector(root: root).detect(files: scan.files, directories: scan.directories)
        let directoryIDs = try store.syncDirectories(scan.directories)
        try store.setMeta("vendored_directories", VesaliusJSON.string(scan.vendoredDirectories))
        trace("modules + directories")

        // 2. Diff against the stored state. When an analyzer changed, every file is parsed again.
        let stored = try store.storedFileStates()
        let fingerprint = Self.extractorFingerprint(registry)
        let reparseAll = store.meta("extractor_fingerprint") != fingerprint
        let scannedPaths = Set(scan.files.map(\.path))
        var candidates: [ScannedFile] = []
        var unchanged = 0
        for file in scan.files {
            if !reparseAll, let previous = stored[file.path], previous.size == file.size, previous.modified == file.modified, previous.language == file.language {
                unchanged += 1
            } else {
                candidates.append(file)
            }
        }
        let removed = stored.values.filter { !scannedPaths.contains($0.path) }

        var affectedNames = Set<String>()
        var changedFileIDs = Set<Int64>()
        var added = 0, changed = 0, failed = 0, contentUnchanged = 0

        // 3. Analyze + write in batches.
        let total = candidates.count
        var completed = 0
        progress(IndexProgress(phase: .analyzing, completed: 0, total: total))
        for batchStart in stride(from: 0, to: candidates.count, by: options.batchSize) {
            try Task.checkCancellation()
            let batch = Array(candidates[batchStart..<min(candidates.count, batchStart + options.batchSize)])
            // Without the previous state, `prepareFile` cannot skip a file whose content hash is unchanged.
            let prepared = try await prepare(batch, stored: reparseAll ? [:] : stored, detection: detection)

            let existingIDs = prepared.compactMap { file -> Int64? in
                if case .write = file.outcome { return stored[file.path]?.id }
                return nil
            }
            affectedNames.formUnion(try namesDefined(in: existingIDs))

            try store.db.transaction {
                for file in prepared {
                    switch file.outcome {
                    case .unchangedContent(let id, let size, let modified):
                        try store.touchFile(id: id, modified: modified, size: size)
                        contentUnchanged += 1
                    case .write(let record, let analysis, let lexical):
                        let directory = (record.path as NSString).deletingLastPathComponent
                        let id = try store.writeFile(record, directoryID: directoryIDs[directory], analysis: analysis, lexical: lexical)
                        changedFileIDs.insert(id)
                        if stored[record.path] == nil { added += 1 } else { changed += 1 }
                        if record.parseStatus == "failed" { failed += 1 }
                        for symbol in analysis?.symbols ?? [] { affectedNames.insert(symbol.name) }
                        for entry in analysis?.exportedNames ?? [] {
                            affectedNames.insert(String(entry.split(separator: "=").first ?? Substring(entry)))
                        }
                    case .unreadable(let path, let reason):
                        failed += 1
                        if warnings.count < 50 { warnings.append("\(path): \(reason)") }
                    }
                }
            }
            completed += batch.count
            progress(IndexProgress(phase: .analyzing, completed: completed, total: total, currentPath: batch.last?.path))
        }

        trace("analyze + write (\(candidates.count))")
        // 4. Removed files.
        if !removed.isEmpty {
            affectedNames.formUnion(try namesDefined(in: removed.map(\.id)))
            try store.deleteFiles(removed.map(\.id))
        }

        let didChange = !changedFileIDs.isEmpty || !removed.isEmpty || stored.isEmpty

        // 5. Modules, imports, project model, linking.
        progress(IndexProgress(phase: .resolving, completed: 0, total: 1))
        let modules = try store.syncModules(detection.modules)
        try store.assignModules(modules)
        let importChanges = try resolveImports(modules: modules, detection: detection)
        trace("resolve imports")
        let projectStamps = ProjectModelIndexer.projectFileStamps(root: root)
        let projectChanged = try ProjectModelIndexer(root: root, store: store, detection: detection, scan: scan).sync()
        trace("project model")
        // New resolution rules, or new target membership: every reference is re-linked and every edge rebuilt.
        let relinkAll = store.meta("linker_version") != String(ReferenceLinker.version) || projectChanged
        let needsAnalysis = didChange || relinkAll || store.meta("analysis_version") != String(Self.analysisVersion)
        let linker = ReferenceLinker(db: store.db)
        if relinkAll {
            try linker.invalidateAll()
        } else {
            try linker.invalidate(names: affectedNames)
            try linker.invalidate(files: importChanges)
        }
        let linkResult = try linker.link()
        trace("link references (\(linkResult.processed))")
        var edgeSources = linkResult.filesWithChangedEdges.union(changedFileIDs).union(importChanges)
        if relinkAll { edgeSources.formUnion(try store.allFileIDs()) }
        try linker.rebuildEdges(for: edgeSources)
        try store.setMeta("linker_version", String(ReferenceLinker.version))
        trace("rebuild edges")
        progress(IndexProgress(phase: .resolving, completed: 1, total: 1))

        // 6. Graph metrics, health, vocabulary.
        let churn = await churnTask?.value ?? [:]
        trace("git churn")
        var analysisUpdated = false
        if needsAnalysis || !churn.isEmpty && store.meta("churn_hash") != String(churn.count) {
            try Task.checkCancellation()
            progress(IndexProgress(phase: .graph, completed: 0, total: 1))
            let analyzer = RepositoryAnalyzer(store: store, repositoryName: root.lastPathComponent)
            let graph = try analyzer.computeGraph(churn: churn)
            trace("graph metrics")
            progress(IndexProgress(phase: .health, completed: 0, total: 1))
            try analyzer.computeHealth(graph: graph, manifestDependencies: detection.manifestDependencies)
            trace("health")
            try VocabularyBuilder(db: store.db).rebuild()
            trace("vocabulary")
            try store.setMeta("churn_hash", String(churn.count))
            try store.setMeta("analysis_version", String(Self.analysisVersion))
            analysisUpdated = true
        }

        // 7. Semantic vectors.
        var embeddingsUpdated = false
        if options.computeEmbeddings {
            let embedder = EmbeddingIndexer(db: store.db)
            if embedder.isAvailable {
                let changesBefore = try store.db.scalarInt("SELECT total_changes()")
                try await embedder.update(root: root) { done, total in
                    progress(IndexProgress(phase: .embeddings, completed: done, total: total))
                }
                embeddingsUpdated = try store.db.scalarInt("SELECT total_changes()") != changesBefore
            }
        }

        trace("embeddings")
        // 8. Metadata.
        let duration = Date().timeIntervalSince(started)
        let info = git.info(name: root.lastPathComponent)
        try store.setMeta("repository_name", root.lastPathComponent)
        try store.setMeta("repository_path", root.path)
        try store.setMeta("repository_info", VesaliusJSON.string(info))
        try store.setMeta("last_indexed_at", String(Date().timeIntervalSince1970))
        try store.setMeta("last_index_duration", String(duration))
        try store.setMeta("skipped_count", String(scan.skippedCount))
        try store.setMeta("indexer_version", String(Self.analysisVersion))
        try store.setMeta("extractor_fingerprint", fingerprint)
        try store.setMeta("project_files_stamp", VesaliusJSON.string(projectStamps))
        // Readers key caches and memoized results on `index_version`, so it moves only when results can differ.
        if didChange || relinkAll || analysisUpdated || projectChanged || embeddingsUpdated {
            let previous = store.meta("index_version").flatMap(Int.init) ?? 0
            try store.setMeta("index_version", String(previous + 1))
        }
        store.db.checkpoint()
        if didChange { store.db.optimize() }

        let counts = try store.counts()
        progress(IndexProgress(phase: .finished, completed: 1, total: 1))
        return IndexSummary(
            repository: root.path,
            indexPath: store.path,
            filesScanned: scan.files.count,
            filesAdded: added,
            filesChanged: changed,
            filesRemoved: removed.count,
            filesUnchanged: unchanged + contentUnchanged,
            filesFailed: failed,
            symbols: counts.symbols,
            references: counts.refs,
            edges: counts.edges,
            durationSeconds: duration,
            warnings: warnings,
            analysisUpdated: analysisUpdated
        )
    }

    /// Bump when analyzers or derived analysis change so existing indexes recompute derived data.
    static let analysisVersion = 10

    /// Identifies the analyzers that produced the stored facts (`swift-syntax@1,…`). When it changes, every
    /// file is parsed again even though its content did not change.
    static func extractorFingerprint(_ registry: AnalyzerRegistry) -> String {
        registry.analyzers.map { "\($0.identifier)@\($0.version)" }.joined(separator: ",")
    }

    private func namesDefined(in fileIDs: [Int64]) throws -> Set<String> {
        guard !fileIDs.isEmpty else { return [] }
        var names = Set<String>()
        try store.db.forEach("SELECT DISTINCT name FROM symbols WHERE file_id IN (\(fileIDs.sqlList))") { names.insert($0.string(0)) }
        try store.db.forEach("SELECT DISTINCT exported_name FROM exports WHERE file_id IN (\(fileIDs.sqlList))") { names.insert($0.string(0)) }
        return names
    }

    // MARK: - Preparation (parallel)

    private func prepare(_ batch: [ScannedFile], stored: [String: StoredFileState], detection: ModuleDetection) async throws -> [PreparedFile] {
        let registry = self.registry
        let root = self.root
        let entryFiles = detection.entryFiles
        return try await withThrowingTaskGroup(of: PreparedFile.self) { group in
            var results: [PreparedFile] = []
            results.reserveCapacity(batch.count)
            var iterator = batch.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                let previous = stored[file.path]
                group.addTask(priority: .userInitiated) {
                    Self.prepareFile(file, previous: previous, root: root, registry: registry, entryFiles: entryFiles)
                }
                return true
            }
            while running < options.concurrency, addNext() { running += 1 }
            while let result = try await group.next() {
                results.append(result)
                if Task.isCancelled { group.cancelAll() }
                _ = addNext()
            }
            return results.sorted { $0.path < $1.path }
        }
    }

    static func prepareFile(_ file: ScannedFile, previous: StoredFileState?, root: URL, registry: AnalyzerRegistry, entryFiles: Set<String>) -> PreparedFile {
        let url = root.appendingPathComponent(file.path)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return PreparedFile(path: file.path, outcome: .unreadable(path: file.path, reason: error.localizedDescription))
        }
        let hash = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        if let previous, previous.contentHash == hash, previous.language == file.language {
            return PreparedFile(path: file.path, outcome: .unchangedContent(id: previous.id, size: file.size, modified: file.modified))
        }

        let text: String
        switch SourceDecoder.decode(data) {
        case .binary:
            let record = FileRecord(path: file.path, language: file.language, size: file.size, modified: file.modified, contentHash: hash, lines: .init(), complexity: 0, isTest: false, isGenerated: false, isEntryPoint: false, analyzer: nil, parseStatus: "binary", parseMessage: "Binary content")
            return PreparedFile(path: file.path, outcome: .write(record, nil, LexicalDocument(pathText: pathText(file.path), symbolText: "", docText: "", bodyText: "")))
        case .text(let decoded, _):
            text = decoded
        }

        let lines = LineCounter.count(text, language: file.language)
        let longLines = SourceDecoder.isMinified(text: text)
        // Minified bundles are skipped entirely; other files with very long lines (embedded data) are
        // still parsed for their symbols but treated as generated in health metrics.
        let isMinified = longLines && [.javascript, .css, .html, .json].contains(file.language)
        let isGenerated = SourceDecoder.generatedMarker(path: file.path, text: text) || longLines
        let isTest = PathClassifier.isTest(file.path)

        var analysis: FileAnalysis?
        var status = "ok"
        var message: String?
        var analyzerID: String?
        if isMinified {
            status = "skipped"
            message = "Minified or machine-generated content"
        } else if let analyzer = registry.analyzer(for: file.language, path: file.path) {
            analyzerID = analyzer.identifier
            do {
                let analysisStart = tracing ? Date() : nil
                let result = try analyzer.analyze(SourceFile(path: file.path, language: file.language, text: text))
                if let analysisStart {
                    let elapsed = Date().timeIntervalSince(analysisStart)
                    if elapsed > 0.25 {
                        FileHandle.standardError.write(Data(String(format: "[trace] slow parse %.2fs %@ (%@)\n", elapsed, file.path as NSString, analyzer.identifier as NSString).utf8))
                    }
                }
                analysis = result
                if result.syntaxErrorCount > 0 {
                    status = "partial"
                    message = "\(result.syntaxErrorCount) syntax error\(result.syntaxErrorCount == 1 ? "" : "s") recovered"
                }
            } catch {
                status = "failed"
                message = error.localizedDescription
            }
        }

        let symbols = analysis?.symbols ?? []
        let isEntry = (analysis?.isEntryPoint ?? false)
            || entryFiles.contains(file.path)
            || PathClassifier.isConventionalEntryPoint(file.path, language: file.language)
            || symbols.contains { $0.attributes.contains("@main") }

        var symbolWords = symbols.prefix(4000).map { symbol -> String in
            let words = Tokenizer.splitIdentifier(symbol.name)
            return words.count > 1 ? symbol.name + " " + words.joined(separator: " ") : symbol.name
        }
        // Environment variables the file reads or writes (`env:API_KEY`) are found like the names it declares.
        var environmentNames = Set<String>()
        for reference in analysis?.references ?? [] where reference.name.hasPrefix("env:") && environmentNames.count < 200 {
            let name = String(reference.name.dropFirst(4))
            guard name != "*", !name.isEmpty, environmentNames.insert(name).inserted else { continue }
            let words = Tokenizer.splitIdentifier(name)
            symbolWords.append(words.count > 1 ? name + " " + words.joined(separator: " ") : name)
        }
        let docs = symbols.compactMap(\.doc).prefix(400).joined(separator: " ")
        let body = isMinified ? "" : Tokenizer.lexicalWords(in: text).joined(separator: " ")
        let lexical = LexicalDocument(pathText: pathText(file.path), symbolText: symbolWords.joined(separator: " "), docText: docs, bodyText: body)

        let record = FileRecord(
            path: file.path,
            language: file.language,
            size: file.size,
            modified: file.modified,
            contentHash: hash,
            lines: lines,
            complexity: analysis?.complexity ?? 0,
            isTest: isTest,
            isGenerated: isGenerated || isMinified,
            isEntryPoint: isEntry,
            analyzer: analyzerID,
            parseStatus: status,
            parseMessage: message
        )
        return PreparedFile(path: file.path, outcome: .write(record, analysis, lexical))
    }

    static func pathText(_ path: String) -> String {
        let words = Tokenizer.pathWords(path)
        let stem = (((path as NSString).lastPathComponent) as NSString).deletingPathExtension
        return ([stem] + words).joined(separator: " ")
    }

    // MARK: - Imports

    /// Resolves every import and returns the files whose resolution changed (their bindings must be relinked).
    private func resolveImports(modules: [(id: Int64, module: ModuleInfo)], detection: ModuleDetection) throws -> Set<Int64> {
        var files: [ImportResolver.FileEntry] = []
        try store.db.forEach("SELECT id, path, language FROM files") { row in
            files.append(ImportResolver.FileEntry(id: row.int64(0), path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown))
        }
        let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let resolver = ImportResolver(files: files, modules: modules, detection: detection)

        struct Row {
            let id: Int64, fileID: Int64, module: String, kind: ImportKind, names: [ImportedName]
            let resolvedFile: Int64?, resolvedModule: Int64?, external: String?
        }
        var rows: [Row] = []
        try store.db.forEach("SELECT id, file_id, module, kind, names, resolved_file_id, resolved_module_id, external_name FROM imports") { row in
            rows.append(Row(id: row.int64(0), fileID: row.int64(1), module: row.string(2), kind: ImportKind(rawValue: row.string(3)) ?? .module, names: ImportNamesCodec.decode(row.optionalString(4)), resolvedFile: row.optionalInt64(5), resolvedModule: row.optionalInt64(6), external: row.optionalString(7)))
        }
        var changedFiles = Set<Int64>()
        try store.db.transaction {
            for row in rows {
                guard let file = byID[row.fileID] else { continue }
                var resolvedFile: Int64?
                var resolvedModule: Int64?
                var external: String?
                switch resolver.resolve(module: row.module, kind: row.kind, names: row.names, from: file) {
                case .file(let id): resolvedFile = id
                case .module(let id): resolvedModule = id
                case .external(let name): external = name
                case .unresolved: break
                }
                if resolvedFile != row.resolvedFile || resolvedModule != row.resolvedModule || external != row.external {
                    try store.db.run("UPDATE imports SET resolved_file_id = ?, resolved_module_id = ?, external_name = ? WHERE id = ?", [resolvedFile, resolvedModule, external, row.id])
                    changedFiles.insert(row.fileID)
                }
            }
        }
        return changedFiles
    }
}
