import Foundation
import VesaliusCore

/// Per-file facts written alongside the analysis.
public struct FileRecord: Sendable {
    public var path: String
    public var language: Language
    public var size: Int
    public var modified: Double
    public var contentHash: String
    public var lines: LineCounter.Counts
    public var complexity: Int
    public var isTest: Bool
    public var isGenerated: Bool
    public var isEntryPoint: Bool
    public var analyzer: String?
    public var parseStatus: String
    public var parseMessage: String?

    public init(path: String, language: Language, size: Int, modified: Double, contentHash: String, lines: LineCounter.Counts, complexity: Int, isTest: Bool, isGenerated: Bool, isEntryPoint: Bool, analyzer: String?, parseStatus: String, parseMessage: String?) {
        self.path = path
        self.language = language
        self.size = size
        self.modified = modified
        self.contentHash = contentHash
        self.lines = lines
        self.complexity = complexity
        self.isTest = isTest
        self.isGenerated = isGenerated
        self.isEntryPoint = isEntryPoint
        self.analyzer = analyzer
        self.parseStatus = parseStatus
        self.parseMessage = parseMessage
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Text written to the full-text index for one file.
public struct LexicalDocument: Sendable {
    public var pathText: String
    public var symbolText: String
    public var docText: String
    public var bodyText: String

    public init(pathText: String, symbolText: String, docText: String, bodyText: String) {
        self.pathText = pathText
        self.symbolText = symbolText
        self.docText = docText
        self.bodyText = bodyText
    }
}

public struct StoredFileState: Sendable, Hashable {
    public let id: Int64
    public let path: String
    public let size: Int
    public let modified: Double
    public let contentHash: String?
    public let language: Language
}

/// Typed access to an index database. Writers hold one `IndexStore`; readers may open their own
/// read-only store concurrently (WAL mode).
public final class IndexStore: @unchecked Sendable {
    public let db: SQLiteDatabase
    public let path: String

    /// Opens (creating if needed) an index database. A database with an incompatible schema version is
    /// deleted and recreated.
    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        if readOnly {
            db = try SQLiteDatabase(path: path, readOnly: true)
            return
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        var database = try SQLiteDatabase(path: path)
        if let version = IndexSchema.existingVersion(database), version != IndexSchema.version {
            database = try Self.recreate(path: path)
        }
        do {
            try IndexSchema.create(database)
        } catch {
            // A corrupt or foreign file: start over.
            database = try Self.recreate(path: path)
            try IndexSchema.create(database)
        }
        db = database
    }

    private static func recreate(path: String) throws -> SQLiteDatabase {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        return try SQLiteDatabase(path: path)
    }

    // MARK: Meta

    public func meta(_ key: String) -> String? {
        try? db.queryOne("SELECT value FROM meta WHERE key = ?", [key]) { $0.string(0) }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [key, value])
    }

    public func setReport(_ name: String, json: String) throws {
        try db.run("INSERT OR REPLACE INTO reports(name, json, updated_at) VALUES(?, ?, ?)", [name, json, Date().timeIntervalSince1970])
    }

    public func report(_ name: String) -> String? {
        try? db.queryOne("SELECT json FROM reports WHERE name = ?", [name]) { $0.string(0) }
    }

    public func setCodableReport(_ name: String, _ value: some Encodable) throws {
        try setReport(name, json: VesaliusJSON.string(value))
    }

    public func codableReport<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let json = report(name) else { return nil }
        return try? VesaliusJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Files

    public func storedFileStates() throws -> [String: StoredFileState] {
        var states: [String: StoredFileState] = [:]
        try db.forEach("SELECT id, path, size, mtime, content_hash, language FROM files") { row in
            let state = StoredFileState(id: row.int64(0), path: row.string(1), size: row.int(2), modified: row.double(3), contentHash: row.optionalString(4), language: Language(rawValue: row.string(5)) ?? .unknown)
            states[state.path] = state
        }
        return states
    }

    public func fileID(path: String) -> Int64? {
        try? db.queryOne("SELECT id FROM files WHERE path = ?", [path]) { $0.int64(0) }
    }

    public func touchFile(id: Int64, modified: Double, size: Int) throws {
        try db.run("UPDATE files SET mtime = ?, size = ? WHERE id = ?", [modified, size, id])
    }

    public func allFileIDs() throws -> Set<Int64> {
        var ids = Set<Int64>()
        try db.forEach("SELECT id FROM files") { ids.insert($0.int64(0)) }
        return ids
    }

    /// Synchronises the directories table with the scanned tree and returns path → id.
    @discardableResult
    public func syncDirectories(_ paths: [String]) throws -> [String: Int64] {
        var existing: [String: Int64] = [:]
        try db.forEach("SELECT id, path FROM directories") { existing[$0.string(1)] = $0.int64(0) }
        let wanted = Set(paths)
        try db.transaction {
            for (path, id) in existing where !wanted.contains(path) {
                try db.run("DELETE FROM directories WHERE id = ?", [id])
                existing[path] = nil
            }
            for path in paths.sorted(by: { $0.count < $1.count }) where existing[path] == nil {
                let parentPath = path.isEmpty ? nil : (path as NSString).deletingLastPathComponent
                let parentID = parentPath.flatMap { existing[$0] }
                let name = path.isEmpty ? "." : (path as NSString).lastPathComponent
                let depth = path.isEmpty ? 0 : path.split(separator: "/").count
                try db.run("INSERT INTO directories(path, parent_id, name, depth) VALUES(?, ?, ?, ?)", [path, parentID, name, depth])
                existing[path] = db.lastInsertRowID
            }
        }
        return existing
    }

    /// Replaces the module table, keeping ids stable for unchanged modules. Returns modules with ids.
    @discardableResult
    public func syncModules(_ modules: [ModuleInfo]) throws -> [(id: Int64, module: ModuleInfo)] {
        var existing: [String: Int64] = [:]
        try db.forEach("SELECT id, kind, root_path FROM modules") { existing["\($0.string(1))|\($0.string(2))"] = $0.int64(0) }
        var result: [(Int64, ModuleInfo)] = []
        try db.transaction {
            var keep = Set<Int64>()
            for module in modules {
                let key = "\(module.kind.rawValue)|\(module.rootPath)"
                if let id = existing[key] {
                    try db.run("UPDATE modules SET name = ?, manifest_path = ?, language = ? WHERE id = ?", [module.name, module.manifestPath, module.language?.rawValue, id])
                    keep.insert(id)
                    result.append((id, module))
                } else {
                    try db.run("INSERT INTO modules(name, kind, root_path, manifest_path, language) VALUES(?, ?, ?, ?, ?)", [module.name, module.kind.rawValue, module.rootPath, module.manifestPath, module.language?.rawValue])
                    let id = db.lastInsertRowID
                    keep.insert(id)
                    result.append((id, module))
                }
            }
            for id in existing.values where !keep.contains(id) {
                try db.run("DELETE FROM modules WHERE id = ?", [id])
            }
        }
        return result
    }

    /// Writes one file and its analysis, replacing previous data for the path. Must be called inside a
    /// transaction for throughput when writing batches.
    @discardableResult
    public func writeFile(_ record: FileRecord, directoryID: Int64?, analysis: FileAnalysis?, lexical: LexicalDocument) throws -> Int64 {
        let now = Date().timeIntervalSince1970
        let fileID: Int64
        let values: [any SQLBindable] = [
            record.name, directoryID, record.language.rawValue, record.size, record.modified, record.contentHash,
            record.lines.total, record.lines.code, record.lines.comment, record.complexity, analysis?.symbols.count ?? 0,
            record.isTest, record.isGenerated, record.isEntryPoint, record.analyzer, record.parseStatus, record.parseMessage, now,
        ]
        if let existing = self.fileID(path: record.path) {
            fileID = existing
            try clearFileContents(fileID)
            try db.run("""
                UPDATE files SET name = ?, directory_id = ?, language = ?, size = ?, mtime = ?, content_hash = ?,
                    line_count = ?, code_lines = ?, comment_lines = ?, complexity = ?, symbol_count = ?,
                    is_test = ?, is_generated = ?, is_entry = ?, analyzer = ?, parse_status = ?, parse_message = ?, indexed_at = ?
                WHERE id = ?
                """, values + [existing])
        } else {
            try db.run("""
                INSERT INTO files(name, directory_id, language, size, mtime, content_hash, line_count, code_lines, comment_lines,
                    complexity, symbol_count, is_test, is_generated, is_entry, analyzer, parse_status, parse_message, indexed_at, path)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [record.path])
            fileID = db.lastInsertRowID
        }

        try db.run("INSERT INTO fts_files(rowid, path, symbols, docs, body) VALUES(?, ?, ?, ?, ?)", [fileID, lexical.pathText, lexical.symbolText, lexical.docText, lexical.bodyText])

        guard let analysis else { return fileID }

        // Symbols, in order, so parents precede children.
        var rowIDs: [Int: Int64] = [:]
        var qualifiedNames: [Int: String] = [:]
        var depths: [Int: Int] = [:]
        for symbol in analysis.symbols {
            let parentRow = symbol.parentLocalID.flatMap { rowIDs[$0] }
            let parentName = symbol.parentLocalID.flatMap { qualifiedNames[$0] }
            let qualified = parentName.map { "\($0).\(symbol.name)" } ?? symbol.name
            let depth = symbol.parentLocalID.flatMap { depths[$0] }.map { $0 + 1 } ?? 0
            try db.run("""
                INSERT INTO symbols(file_id, parent_id, name, qualified_name, kind, start_line, end_line, signature, doc,
                    visibility, is_exported, attributes, inherits, complexity, body_hash, depth,
                    selector, param_flags, param_types, declared_type, setter_visibility, conditions, is_local)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    fileID, parentRow, symbol.name, qualified, symbol.kind.rawValue, symbol.range.start, symbol.range.end,
                    symbol.signature, symbol.doc, symbol.visibility?.rawValue, symbol.isExported,
                    symbol.attributes.isEmpty ? nil : symbol.attributes.joined(separator: ","),
                    symbol.inheritedTypes.isEmpty ? nil : symbol.inheritedTypes.joined(separator: ","),
                    symbol.complexity, symbol.bodyHash.map { Int64(bitPattern: $0) }, depth,
                    symbol.selector, symbol.parameterFlags, symbol.parameterTypes?.joined(separator: "|"), symbol.declaredType,
                    symbol.setterVisibility?.rawValue, Self.joined(conditions: symbol.conditions), symbol.isLocal,
                ])
            let rowID = db.lastInsertRowID
            rowIDs[symbol.localID] = rowID
            qualifiedNames[symbol.localID] = qualified
            depths[symbol.localID] = depth
            let words = Tokenizer.splitIdentifier(symbol.name).joined(separator: " ")
            try db.run("INSERT INTO fts_symbols(rowid, name, words, qualified, doc, path) VALUES(?, ?, ?, ?, ?, ?)", [
                rowID, symbol.name, words, Tokenizer.splitIdentifier(qualified).joined(separator: " "), symbol.doc ?? "", lexical.pathText,
            ])
        }

        for item in analysis.imports {
            let names = item.names.isEmpty ? nil : ImportNamesCodec.encode(item.names)
            try db.run("""
                INSERT INTO imports(file_id, module, kind, names, line, is_type_only, is_reexport, end_line, is_dynamic,
                    is_side_effect, is_mock, is_testable, conditions)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    fileID, item.module, item.kind.rawValue, names, item.line, item.isTypeOnly, item.isReExport, item.endLine, item.isDynamic,
                    item.isSideEffect, item.isMock, item.isTestable, Self.joined(conditions: item.conditions),
                ])
        }

        for entry in analysis.exportedNames {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            let exported = parts.first ?? entry
            let local = parts.count > 1 ? parts[1] : exported
            try db.run("INSERT INTO exports(file_id, exported_name, local_name) VALUES(?, ?, ?)", [fileID, exported, local])
        }

        // References: one row per occurrence, in analyzer order. An exact repeat of a site (same line, column,
        // name, kind and receiver) is the same occurrence emitted twice and maps to the first row.
        struct Site: Hashable {
            let line: Int
            let column: Int
            let name: String
            let kind: ReferenceKind
            let receiver: String?
        }
        var refRowIDs: [Int64?] = Array(repeating: nil, count: analysis.references.count)
        var siteRows: [Site: Int64] = [:]
        var forwardReceivers: [(row: Int64, receiver: Int)] = []
        for (index, reference) in analysis.references.enumerated() {
            let site = Site(line: reference.line, column: reference.column, name: reference.name, kind: reference.kind, receiver: reference.receiver)
            if let kept = siteRows[site] {
                refRowIDs[index] = kept
                continue
            }
            // A receiver emitted before its member already has a row; later ones are filled in below.
            let receiverRow = reference.receiverRef.flatMap { $0 >= 0 && $0 < index ? refRowIDs[$0] : nil }
            try db.run("""
                INSERT INTO refs(file_id, from_symbol_id, name, kind, context, line, col, stmt_line, end_line, call_end_line,
                    receiver, receiver_hint, receiver_ref, type_evidence_line, arg_labels, conditions, at_load, assigned_to, consumer_line)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    fileID, reference.enclosingSymbol.flatMap { rowIDs[$0] }, reference.name, reference.kind.rawValue, reference.context,
                    reference.line, reference.column, reference.statementLine, reference.endLine, reference.callEndLine,
                    reference.receiver, reference.receiverHint, receiverRow, reference.typeEvidenceLine,
                    reference.argumentLabels?.joined(separator: ","), Self.joined(conditions: reference.conditions), reference.atLoad,
                    reference.assignedTo, reference.consumerLine,
                ])
            let rowID = db.lastInsertRowID
            refRowIDs[index] = rowID
            siteRows[site] = rowID
            if let receiver = reference.receiverRef, receiver > index { forwardReceivers.append((rowID, receiver)) }
        }

        // Second pass: pointers to references emitted later, and the references that type symbols.
        for (row, receiver) in forwardReceivers {
            guard receiver < refRowIDs.count, let receiverRow = refRowIDs[receiver] else { continue }
            try db.run("UPDATE refs SET receiver_ref = ? WHERE id = ?", [receiverRow, row])
        }
        for symbol in analysis.symbols {
            guard let reference = symbol.declaredTypeRef, refRowIDs.indices.contains(reference),
                  let referenceRow = refRowIDs[reference], let symbolRow = rowIDs[symbol.localID] else { continue }
            try db.run("UPDATE symbols SET declared_type_ref = ? WHERE id = ?", [referenceRow, symbolRow])
        }

        for literal in analysis.literals {
            try db.run("INSERT INTO literals(file_id, symbol_id, value, line, col, context, callee, label, conditions) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)", [
                fileID, literal.enclosingSymbol.flatMap { rowIDs[$0] }, literal.value, literal.line, literal.column, literal.context,
                literal.callee, literal.label, Self.joined(conditions: literal.conditions),
            ])
        }
        return fileID
    }

    /// The stored form of an `#if` stack: conditions joined with ` && `, outermost first; nil when unconditional.
    static func joined(conditions: [String]) -> String? {
        conditions.isEmpty ? nil : conditions.joined(separator: " && ")
    }

    /// Removes everything derived from a file's contents (but keeps the file row and its id).
    private func clearFileContents(_ fileID: Int64) throws {
        try db.run("DELETE FROM fts_symbols WHERE rowid IN (SELECT id FROM symbols WHERE file_id = ?)", [fileID])
        try db.run("DELETE FROM fts_files WHERE rowid = ?", [fileID])
        try db.run("DELETE FROM refs WHERE file_id = ?", [fileID])
        try db.run("DELETE FROM literals WHERE file_id = ?", [fileID])
        try db.run("DELETE FROM imports WHERE file_id = ?", [fileID])
        try db.run("DELETE FROM exports WHERE file_id = ?", [fileID])
        try db.run("DELETE FROM symbols WHERE file_id = ?", [fileID])
        try db.run("DELETE FROM file_edges WHERE src_file_id = ?", [fileID])
        try db.run("DELETE FROM embeddings WHERE file_id = ?", [fileID])
    }

    public func deleteFiles(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids {
                try clearFileContents(id)
                try db.run("DELETE FROM files WHERE id = ?", [id])
            }
        }
    }

    /// Assigns module ids to files by longest matching module root.
    public func assignModules(_ modules: [(id: Int64, module: ModuleInfo)]) throws {
        let sorted = modules.sorted { $0.module.rootPath.count > $1.module.rootPath.count }
        var assignments: [(Int64, Int64?)] = []
        try db.forEach("SELECT id, path, module_id FROM files") { row in
            let path = row.string(1)
            let current = row.optionalInt64(2)
            let match = sorted.first { entry in
                let root = entry.module.rootPath
                return root.isEmpty || path == root || path.hasPrefix(root + "/")
            }?.id
            if match != current { assignments.append((row.int64(0), match)) }
        }
        guard !assignments.isEmpty else { return }
        try db.transaction {
            for (fileID, moduleID) in assignments {
                try db.run("UPDATE files SET module_id = ? WHERE id = ?", [moduleID, fileID])
            }
        }
    }

    public func counts() throws -> (files: Int, symbols: Int, refs: Int, edges: Int) {
        (try db.scalarInt("SELECT COUNT(*) FROM files"),
         try db.scalarInt("SELECT COUNT(*) FROM symbols"),
         try db.scalarInt("SELECT COUNT(*) FROM refs"),
         try db.scalarInt("SELECT COUNT(*) FROM file_edges"))
    }
}
