import Foundation
import RepositoryIndex
import VesaliusCore

extension RepositoryEngine {
    // MARK: - Reports

    public func health() throws -> HealthReport {
        try store().codableReport("health", as: HealthReport.self) ?? .empty
    }

    public func architecture() throws -> ArchitectureReport {
        try store().codableReport("architecture", as: ArchitectureReport.self) ?? .empty
    }

    public func suggestions() throws -> [ExtractionSuggestion] {
        try store().codableReport("suggestions", as: [ExtractionSuggestion].self) ?? []
    }

    public func cycles() throws -> [DependencyCycle] {
        try store().codableReport("cycles", as: [DependencyCycle].self) ?? []
    }

    public func unused() throws -> UnusedReport {
        try store().codableReport("unused", as: UnusedReport.self) ?? UnusedReport(files: [], symbols: [], note: "Not analysed yet.")
    }

    public func longestChain() throws -> [String] {
        try store().codableReport("longest-chain", as: [String].self) ?? []
    }

    // MARK: - Diagnostics

    func diagnosticRows(where clause: String = "1", _ values: [any SQLBindable] = [], limit: Int = 500) throws -> [Diagnostic] {
        try db.query("""
            SELECT d.id, d.rule, d.category, d.severity, d.title, d.summary, d.reason, d.recommendation, d.metrics, d.targets
            FROM diagnostics d WHERE \(clause) ORDER BY d.severity_rank DESC, d.title LIMIT \(limit)
            """, values, cache: false) { row in
            let decoder = VesaliusJSON.decoder()
            return Diagnostic(
                id: row.string(0),
                rule: row.string(1),
                category: HealthCategory(rawValue: row.string(2)) ?? .maintainability,
                severity: Severity(rawValue: row.string(3)) ?? .info,
                title: row.string(4),
                summary: row.string(5),
                reason: row.string(6),
                recommendation: row.string(7),
                targets: (try? decoder.decode([DiagnosticTarget].self, from: Data(row.string(9).utf8))) ?? [],
                metrics: (try? decoder.decode([DiagnosticMetric].self, from: Data(row.string(8).utf8))) ?? []
            )
        }
    }

    public func diagnostics(minimumSeverity: Severity? = nil, category: HealthCategory? = nil, rule: String? = nil, path: String? = nil, limit: Int = 500) throws -> [Diagnostic] {
        var clauses: [String] = []
        var values: [any SQLBindable] = []
        if let minimumSeverity {
            clauses.append("d.severity_rank >= ?")
            values.append(minimumSeverity.rank)
        }
        if let category {
            clauses.append("d.category = ?")
            values.append(category.rawValue)
        }
        if let rule {
            clauses.append("d.rule = ?")
            values.append(rule)
        }
        if let path {
            clauses.append("d.id IN (SELECT diagnostic_id FROM diagnostic_targets WHERE path = ? OR path LIKE ?)")
            values.append(path)
            values.append(path + "/%")
        }
        return try diagnosticRows(where: clauses.isEmpty ? "1" : clauses.joined(separator: " AND "), values, limit: limit)
    }

    // MARK: - Hotspots

    public func hotspots(limit: Int = 15) throws -> [Hotspot] {
        let cache = try graphCache()
        return cache.ordered
            .filter { $0.isCode && !$0.isTest && $0.hotspot > 0 }
            .sorted { $0.hotspot == $1.hotspot ? $0.path < $1.path : $0.hotspot > $1.hotspot }
            .prefix(limit)
            .map { node in
                var reasons: [String] = []
                if node.codeLines >= 300 { reasons.append("\(node.codeLines) lines of code") }
                if node.complexity >= 40 { reasons.append("complexity \(node.complexity)") }
                if let churn = node.churn, churn >= 5 { reasons.append("changed in \(churn) commits this year") }
                if node.fanIn >= 8 { reasons.append("used by \(node.fanIn) files") }
                if node.fanOut >= 12 { reasons.append("depends on \(node.fanOut) files") }
                if node.cycleID != nil { reasons.append("in a dependency cycle") }
                if node.diagnostics > 0 { reasons.append("\(node.diagnostics) diagnostic\(node.diagnostics == 1 ? "" : "s")") }
                if reasons.isEmpty { reasons.append("large and coupled relative to the rest of the repository") }
                return Hotspot(path: node.path, score: (node.hotspot * 100).rounded() / 100, lines: node.codeLines, complexity: node.complexity, fanIn: node.fanIn, fanOut: node.fanOut, churn: node.churn, diagnostics: node.diagnostics, reasons: reasons)
            }
    }

    // MARK: - Overview

    public func overview() throws -> RepositoryOverview {
        let cache = try graphCache()
        let store = try store()
        let lastIndexed = store.meta("last_indexed_at").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        let code = cache.ordered.filter { $0.isCode && !$0.isTest }
        let central = code.filter { $0.fanIn > 0 }.sorted { $0.centrality == $1.centrality ? $0.path < $1.path : $0.centrality > $1.centrality }.prefix(8).map {
            RankedFile(path: $0.path, value: ($0.centrality * 100).rounded() / 100, detail: "used by \($0.fanIn) file\($0.fanIn == 1 ? "" : "s"), reaches \($0.transitiveIn) transitively")
        }
        let large = code.sorted { $0.codeLines == $1.codeLines ? $0.path < $1.path : $0.codeLines > $1.codeLines }.prefix(8).map {
            RankedFile(path: $0.path, value: Double($0.codeLines), detail: "\($0.codeLines) lines · complexity \($0.complexity) · \($0.symbols) symbols")
        }
        let unusedReport = try unused()
        let external = try db.query("SELECT external_name, COUNT(DISTINCT file_id) AS n FROM imports WHERE external_name IS NOT NULL GROUP BY external_name ORDER BY n DESC, external_name LIMIT 12") {
            RankedFile(path: $0.string(0), value: Double($0.int(1)), detail: "imported by \($0.int(1)) file\($0.int(1) == 1 ? "" : "s")")
        }
        return RepositoryOverview(
            repository: repositoryInfo(),
            stats: try stats(),
            languages: try languages(),
            lastIndexed: lastIndexed,
            health: try health(),
            architecture: try architecture(),
            hotspots: try hotspots(limit: 8),
            centralFiles: Array(central),
            largeFiles: Array(large),
            cycles: Array(try cycles().prefix(6)),
            unused: Array((unusedReport.files + unusedReport.symbols).sorted { $0.confidence > $1.confidence }.prefix(10)),
            suggestions: Array(try suggestions().prefix(5)),
            topDiagnostics: try diagnosticRows(where: "d.severity_rank >= 2", limit: 8),
            externalModules: external
        )
    }

    // MARK: - Browsing

    func summary(_ node: GraphCache.FileNode, parseStatus: String? = nil) -> FileSummary {
        FileSummary(path: node.path, language: node.language, size: 0, lines: node.lines, codeLines: node.codeLines, symbols: node.symbols, complexity: node.complexity, fanIn: node.fanIn, fanOut: node.fanOut, centrality: (node.centrality * 1000).rounded() / 1000, risk: (node.risk * 1000).rounded() / 1000, churn: node.churn, diagnostics: node.diagnostics, isTest: node.isTest, isGenerated: node.isGenerated, module: node.module, parseStatus: parseStatus)
    }

    /// Every indexed file with metrics (for the Files browser).
    public func allFiles() throws -> [FileSummary] {
        let cache = try graphCache()
        var sizes: [Int64: (Int, String)] = [:]
        try db.forEach("SELECT id, size, parse_status FROM files") { sizes[$0.int64(0)] = ($0.int(1), $0.string(2)) }
        return cache.ordered.map { node in
            var file = summary(node, parseStatus: sizes[node.id]?.1)
            file.size = sizes[node.id]?.0 ?? 0
            return file
        }
    }

    /// Symbols for the Symbols browser, optionally filtered by kind, with reference counts.
    public func allSymbols(kinds: Set<SymbolKind>? = nil, limit: Int = 20_000) throws -> [SymbolSummary] {
        var clause = "s.kind != 'extension'"
        if let kinds, !kinds.isEmpty {
            clause = "s.kind IN (" + kinds.map { "'\($0.rawValue)'" }.joined(separator: ",") + ")"
        }
        var counts: [Int64: Int] = [:]
        try db.forEach("SELECT target_symbol_id, SUM(count) FROM refs WHERE target_symbol_id IS NOT NULL AND confidence >= ? GROUP BY target_symbol_id", [Self.referenceConfidence]) {
            counts[$0.int64(0)] = $0.int(1)
        }
        return try symbolRows(where: clause + " ORDER BY f.path, s.start_line", [], limit: limit).map { $0.summary(references: counts[$0.id] ?? 0) }
    }

    // MARK: - Context

    public func fileContext(_ path: String) throws -> FileContext {
        guard case .file(let id, let resolvedPath) = try resolveTarget(path) else {
            throw EngineError.notFound(path, suggestions: try suggestions(for: path))
        }
        let cache = try graphCache()
        guard let node = cache.files[id] else { throw EngineError.notFound(path, suggestions: []) }
        var file = summary(node)
        try db.forEach("SELECT size, parse_status FROM files WHERE id = ?", [id]) { row in
            file.size = row.int(0)
            file.parseStatus = row.string(1)
        }
        var counts: [Int64: Int] = [:]
        let rows = try symbolRows(where: "s.file_id = ? ORDER BY s.start_line", [id], limit: 2000)
        counts = try referenceCounts(rows.map(\.id))
        let symbols = rows.map { $0.summary(references: counts[$0.id] ?? 0) }
        let imports = try db.query("""
            SELECT i.module, i.line, rf.path, i.external_name, i.names FROM imports i LEFT JOIN files rf ON rf.id = i.resolved_file_id
            WHERE i.file_id = ? ORDER BY i.line
            """, [id]) { row in
            ImportSummary(module: row.string(0), line: row.int(1), resolvedPath: row.optionalString(2), isExternal: row.optionalString(3) != nil, names: ImportNamesCodec.decode(row.optionalString(4)).map(\.localName).nilIfEmpty)
        }
        let dependencies = try dependencies(of: resolvedPath, depth: 1, limit: 200).files
        let dependents = try dependents(of: resolvedPath, depth: 1, limit: 200).files
        return FileContext(
            file: file,
            symbols: symbols,
            imports: imports,
            dependencies: dependencies,
            dependents: dependents,
            metrics: node.metrics,
            diagnostics: try diagnostics(path: resolvedPath, limit: 50),
            related: try relatedFiles(resolvedPath, limit: 10),
            impact: impactSummary(resolvedPath)
        )
    }

    public func symbolContext(_ query: String) throws -> SymbolContext {
        let rows = try resolveSymbols(query)
        guard let row = rows.first else { throw EngineError.notFound(query, suggestions: try suggestions(for: query)) }
        let counts = try referenceCounts([row.id])
        let parent = try row.parentID.flatMap { try symbolRows(where: "s.id = ?", [$0]).first }
        let members = try symbolRows(where: "s.parent_id = ? ORDER BY s.start_line", [row.id], limit: 500)
        let memberCounts = try referenceCounts(members.map(\.id))
        let id = NodeID.symbol(path: row.path, qualifiedName: row.qualifiedName)
        let references = (try? references(id, limit: 60).references) ?? []
        let callers = (try? callers(id, limit: 40).relations) ?? []
        let callees = (try? callees(id, limit: 40).relations) ?? []
        let diagnostics = try diagnosticRows(where: "d.id IN (SELECT diagnostic_id FROM diagnostic_targets WHERE path = ? AND (symbol IS NULL OR symbol = ? OR symbol = ?))", [row.path, row.name, row.qualifiedName], limit: 20)
        return SymbolContext(
            symbol: row.summary(references: counts[row.id] ?? 0),
            parent: parent?.summary(),
            members: members.map { $0.summary(references: memberCounts[$0.id] ?? 0) },
            references: references,
            callers: callers,
            callees: callees,
            diagnostics: diagnostics,
            impact: impactSummary(id)
        )
    }

    // MARK: - Raw SQL

    public struct RawQueryResult: Codable, Sendable {
        public var columns: [String]
        public var rows: [[JSONValue]]
    }

    /// Runs a read-only SQL statement against the index (for power users and agents).
    public func rawQuery(_ sql: String, limit: Int = 200) throws -> RawQueryResult {
        let reader = try SQLiteDatabase(path: location.databaseURL.path, readOnly: true)
        let (columns, rows) = try reader.rawQuery(sql, limit: limit)
        return RawQueryResult(columns: columns, rows: rows.map { row in
            row.map { value -> JSONValue in
                switch value {
                case .null: .null
                case .int(let v): .int(v)
                case .double(let v): .double(v)
                case .text(let v): .string(v)
                case .blob(let v): .string("<\(v.count) bytes>")
                }
            }
        })
    }

    /// The index schema (for `vesalius query`).
    public static var schemaDescription: String {
        IndexSchema.statements.filter { $0.contains("CREATE TABLE") || $0.contains("VIRTUAL TABLE") }.joined(separator: ";\n\n") + ";"
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
