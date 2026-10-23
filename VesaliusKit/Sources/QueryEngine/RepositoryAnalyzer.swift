import Foundation
import GraphEngine
import HealthEngine
import RepositoryIndex
import VesaliusCore

/// Derived, whole-repository analysis: graph metrics, cycles, clusters, health, architecture.
struct RepositoryAnalyzer {
    let store: IndexStore
    let repositoryName: String

    private var db: SQLiteDatabase { store.db }

    struct FileRow {
        let id: Int64
        let path: String
        let language: Language
        let lines: Int
        let codeLines: Int
        let complexity: Int
        let symbolCount: Int
        let isTest: Bool
        let isGenerated: Bool
        let isEntry: Bool
        let module: String?
    }

    func loadFiles() throws -> [FileRow] {
        try db.query("""
            SELECT f.id, f.path, f.language, f.line_count, f.code_lines, f.complexity, f.symbol_count, f.is_test, f.is_generated, f.is_entry, m.name
            FROM files f LEFT JOIN modules m ON m.id = f.module_id
            ORDER BY f.path
            """) { row in
            FileRow(id: row.int64(0), path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown, lines: row.int(3), codeLines: row.int(4), complexity: row.int(5), symbolCount: row.int(6), isTest: row.bool(7), isGenerated: row.bool(8), isEntry: row.bool(9), module: row.optionalString(10))
        }
    }

    func loadEdges() throws -> [RepositorySnapshot.Edge] {
        try db.query("SELECT src_file_id, dst_file_id, kind, weight FROM file_edges") { row in
            RepositorySnapshot.Edge(source: row.int64(0), target: row.int64(1), kind: EdgeKind(rawValue: row.string(2)) ?? .dependsOn, weight: row.int(3))
        }
    }

    // MARK: Graph

    func computeGraph(churn: [String: Int]) throws -> GraphAnalysis {
        let files = try loadFiles()
        let edges = try loadEdges()
        let inputs = files.map { file in
            GraphAnalysis.FileInput(id: file.id, path: file.path, codeLines: file.codeLines, complexity: file.complexity, isCode: file.language.isCode && !file.isGenerated, isTest: file.isTest, churn: churn.isEmpty ? nil : churn[file.path] ?? 0)
        }
        let graph = GraphAnalysis.compute(files: inputs, edges: edges)
        let pathByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.path) })

        try db.transaction {
            try db.run("DELETE FROM file_metrics")
            for file in files {
                guard let m = graph.metrics[file.id] else { continue }
                try db.run("""
                    INSERT INTO file_metrics(file_id, fan_in, fan_out, centrality, transitive_in, transitive_out, depth, cycle_id, cycle_size, cluster_id, churn, risk, hotspot)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [file.id, m.fanIn, m.fanOut, m.centrality, m.transitiveDependents, m.transitiveDependencies, m.depth, m.cycleID, m.cycleSize, m.clusterID, m.churn, m.risk, graph.hotspotScores[file.id] ?? 0])
            }
            try db.run("DELETE FROM clusters")
            for cluster in graph.clusters {
                try db.run("INSERT OR REPLACE INTO clusters(id, label, size) VALUES(?, ?, ?)", [cluster.id, cluster.label, cluster.fileIDs.count])
            }
        }

        let cycles = zip(graph.cycles, graph.cyclePaths).enumerated().map { index, pair in
            DependencyCycle(
                id: index + 1,
                files: pair.0.compactMap { pathByID[$0] }.sorted(),
                path: pair.1.compactMap { pathByID[$0] },
                edges: edges.filter { Set(pair.0).contains($0.source) && Set(pair.0).contains($0.target) }.count
            )
        }
        try store.setCodableReport("cycles", cycles)
        try store.setCodableReport("longest-chain", graph.longestChain.compactMap { pathByID[$0] })
        return graph
    }

    // MARK: Health

    func snapshot(graph: GraphAnalysis, manifestDependencies: [String]) throws -> RepositorySnapshot {
        let files = try loadFiles()
        var externalImports: [Int64: [String]] = [:]
        try db.forEach("SELECT file_id, external_name FROM imports WHERE external_name IS NOT NULL") { row in
            externalImports[row.int64(0), default: []].append(row.string(1))
        }
        var incoming: [Int64: (refs: Int, files: Int)] = [:]
        try db.forEach("""
            SELECT r.target_symbol_id, SUM(r.count),
                   COUNT(DISTINCT CASE WHEN r.file_id != s.file_id THEN r.file_id END)
            FROM refs r JOIN symbols s ON s.id = r.target_symbol_id
            WHERE r.target_symbol_id IS NOT NULL AND r.confidence >= ? AND (r.from_symbol_id IS NULL OR r.from_symbol_id != r.target_symbol_id)
            GROUP BY r.target_symbol_id
            """, [ReferenceLinker.edgeThreshold]) { row in
            incoming[row.int64(0)] = (row.int(1), row.int(2))
        }
        var symbols: [RepositorySnapshot.Symbol] = []
        try db.forEach("SELECT id, file_id, parent_id, name, qualified_name, kind, start_line, end_line, visibility, is_exported, attributes, inherits, complexity, body_hash FROM symbols") { row in
            let id = row.int64(0)
            let counts = incoming[id] ?? (0, 0)
            symbols.append(RepositorySnapshot.Symbol(
                id: id,
                fileID: row.int64(1),
                parentID: row.optionalInt64(2),
                name: row.string(3),
                qualifiedName: row.string(4),
                kind: SymbolKind(rawValue: row.string(5)) ?? .variable,
                lines: LineRange(row.int(6), row.int(7)),
                visibility: row.optionalString(8).flatMap(Visibility.init(rawValue:)),
                isExported: row.bool(9),
                attributes: row.optionalString(10)?.split(separator: ",").map(String.init) ?? [],
                inheritedTypes: row.optionalString(11)?.split(separator: ",").map(String.init) ?? [],
                complexity: row.int(12),
                bodyHash: row.optionalInt64(13).map { UInt64(bitPattern: $0) },
                incomingReferences: counts.refs,
                referencingFiles: counts.files
            ))
        }
        let modules = try db.query("SELECT name, kind, root_path, manifest_path, language FROM modules") { row in
            ModuleInfo(name: row.string(0), kind: ModuleKind(rawValue: row.string(1)) ?? .directory, rootPath: row.string(2), manifestPath: row.optionalString(3), language: row.optionalString(4).flatMap(Language.init(rawValue:)))
        }
        return RepositorySnapshot(
            repositoryName: repositoryName,
            files: files.map { file in
                RepositorySnapshot.File(
                    id: file.id,
                    path: file.path,
                    directory: (file.path as NSString).deletingLastPathComponent,
                    module: file.module,
                    language: file.language,
                    lines: file.lines,
                    codeLines: file.codeLines,
                    complexity: file.complexity,
                    symbolCount: file.symbolCount,
                    isTest: file.isTest,
                    isGenerated: file.isGenerated,
                    isEntryPoint: file.isEntry,
                    externalImports: Array(Set(externalImports[file.id] ?? [])).sorted(),
                    churn: graph.metrics[file.id]?.churn
                )
            },
            symbols: symbols,
            edges: try loadEdges(),
            modules: modules,
            metrics: graph.metrics,
            cycles: graph.cycles,
            clusters: graph.clusters,
            manifestDependencies: manifestDependencies
        )
    }

    func computeHealth(graph: GraphAnalysis, manifestDependencies: [String]) throws {
        let snapshot = try snapshot(graph: graph, manifestDependencies: manifestDependencies)
        let analysis = HealthEngine().analyze(snapshot: snapshot, graph: graph)
        let fileIDs = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0.id) })

        try db.transaction {
            try db.run("DELETE FROM diagnostic_targets")
            try db.run("DELETE FROM diagnostics")
            for diagnostic in analysis.diagnostics {
                try db.run("""
                    INSERT OR REPLACE INTO diagnostics(id, rule, category, severity, severity_rank, title, summary, reason, recommendation, metrics, targets)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                        diagnostic.id, diagnostic.rule, diagnostic.category.rawValue, diagnostic.severity.rawValue, diagnostic.severity.rank,
                        diagnostic.title, diagnostic.summary, diagnostic.reason, diagnostic.recommendation,
                        try VesaliusJSON.string(diagnostic.metrics), try VesaliusJSON.string(diagnostic.targets),
                    ])
                for target in diagnostic.targets {
                    try db.run("INSERT INTO diagnostic_targets(diagnostic_id, kind, path, symbol, file_id) VALUES(?, ?, ?, ?, ?)", [
                        diagnostic.id, target.kind.rawValue, target.path, target.symbol, fileIDs[target.path],
                    ])
                }
            }
        }
        try store.setCodableReport("health", analysis.report)
        try store.setCodableReport("architecture", analysis.architecture)
        try store.setCodableReport("suggestions", analysis.suggestions)
        try store.setCodableReport("unused", analysis.unused)
    }
}
