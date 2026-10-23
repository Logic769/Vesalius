import Foundation
import RepositoryIndex
import VesaliusCore

/// An in-memory copy of the file graph and per-file metrics, loaded once per index generation.
/// Used for map rendering and traversal-heavy queries so they never scan SQLite repeatedly.
final class GraphCache: @unchecked Sendable {
    struct FileNode: Sendable {
        let id: Int64
        let path: String
        let directory: String
        let name: String
        let language: Language
        let lines: Int
        let codeLines: Int
        let symbols: Int
        let complexity: Int
        let isTest: Bool
        let isGenerated: Bool
        let isEntry: Bool
        let module: String?
        let moduleID: Int64?
        let fanIn: Int
        let fanOut: Int
        let centrality: Double
        let risk: Double
        let hotspot: Double
        let churn: Int?
        let transitiveIn: Int
        let transitiveOut: Int
        let depth: Int
        let cycleID: Int?
        let cycleSize: Int?
        let clusterID: Int?
        var diagnostics: Int
        var maxSeverity: Severity?

        var isCode: Bool { language.isCode && !isGenerated }

        var metrics: FileGraphMetrics {
            var m = FileGraphMetrics()
            m.fanIn = fanIn
            m.fanOut = fanOut
            m.centrality = centrality
            m.transitiveDependents = transitiveIn
            m.transitiveDependencies = transitiveOut
            m.depth = depth
            m.cycleID = cycleID
            m.cycleSize = cycleSize
            m.clusterID = clusterID
            m.churn = churn
            m.risk = risk
            return m
        }
    }

    struct EdgeRef: Sendable {
        let file: Int64
        let kind: EdgeKind
        let weight: Int
    }

    let files: [Int64: FileNode]
    let ordered: [FileNode]
    let byPath: [String: Int64]
    let outgoing: [Int64: [EdgeRef]]
    let incoming: [Int64: [EdgeRef]]
    let modules: [Int64: ModuleInfo]

    init(db: SQLiteDatabase) throws {
        var severities: [Int64: (count: Int, max: Severity)] = [:]
        try db.forEach("""
            SELECT t.file_id, COUNT(DISTINCT d.id), MAX(d.severity_rank)
            FROM diagnostic_targets t JOIN diagnostics d ON d.id = t.diagnostic_id
            WHERE t.file_id IS NOT NULL GROUP BY t.file_id
            """) { row in
            let rank = row.int(2)
            severities[row.int64(0)] = (row.int(1), Severity.allCases.first { $0.rank == rank } ?? .info)
        }
        var modules: [Int64: ModuleInfo] = [:]
        try db.forEach("SELECT id, name, kind, root_path, manifest_path, language FROM modules") { row in
            modules[row.int64(0)] = ModuleInfo(name: row.string(1), kind: ModuleKind(rawValue: row.string(2)) ?? .directory, rootPath: row.string(3), manifestPath: row.optionalString(4), language: row.optionalString(5).flatMap(Language.init(rawValue:)))
        }
        self.modules = modules

        var files: [Int64: FileNode] = [:]
        var ordered: [FileNode] = []
        try db.forEach("""
            SELECT f.id, f.path, f.name, f.language, f.line_count, f.code_lines, f.symbol_count, f.complexity, f.is_test, f.is_generated, f.is_entry, f.module_id,
                   COALESCE(m.fan_in, 0), COALESCE(m.fan_out, 0), COALESCE(m.centrality, 0), COALESCE(m.risk, 0), COALESCE(m.hotspot, 0), m.churn,
                   COALESCE(m.transitive_in, 0), COALESCE(m.transitive_out, 0), COALESCE(m.depth, 0), m.cycle_id, m.cycle_size, m.cluster_id
            FROM files f LEFT JOIN file_metrics m ON m.file_id = f.id ORDER BY f.path
            """) { row in
            let id = row.int64(0)
            let path = row.string(1)
            let moduleID = row.optionalInt64(11)
            let severity = severities[id]
            let node = FileNode(
                id: id, path: path, directory: (path as NSString).deletingLastPathComponent, name: row.string(2),
                language: Language(rawValue: row.string(3)) ?? .unknown, lines: row.int(4), codeLines: row.int(5), symbols: row.int(6),
                complexity: row.int(7), isTest: row.bool(8), isGenerated: row.bool(9), isEntry: row.bool(10),
                module: moduleID.flatMap { modules[$0]?.name }, moduleID: moduleID,
                fanIn: row.int(12), fanOut: row.int(13), centrality: row.double(14), risk: row.double(15), hotspot: row.double(16),
                churn: row.optionalInt(17), transitiveIn: row.int(18), transitiveOut: row.int(19), depth: row.int(20),
                cycleID: row.optionalInt(21), cycleSize: row.optionalInt(22), clusterID: row.optionalInt(23),
                diagnostics: severity?.count ?? 0, maxSeverity: severity?.max
            )
            files[id] = node
            ordered.append(node)
        }
        self.files = files
        self.ordered = ordered
        self.byPath = Dictionary(uniqueKeysWithValues: ordered.map { ($0.path, $0.id) })

        var outgoing: [Int64: [EdgeRef]] = [:]
        var incoming: [Int64: [EdgeRef]] = [:]
        try db.forEach("SELECT src_file_id, dst_file_id, kind, weight FROM file_edges") { row in
            let source = row.int64(0), target = row.int64(1)
            let kind = EdgeKind(rawValue: row.string(2)) ?? .dependsOn
            let weight = row.int(3)
            outgoing[source, default: []].append(EdgeRef(file: target, kind: kind, weight: weight))
            incoming[target, default: []].append(EdgeRef(file: source, kind: kind, weight: weight))
        }
        self.outgoing = outgoing
        self.incoming = incoming
    }

    /// Breadth-first traversal over file edges from several start files.
    func traverse(from starts: [Int64], dependents: Bool, maxDepth: Int, limit: Int = 5000) -> [(id: Int64, distance: Int)] {
        var distance: [Int64: Int] = [:]
        for start in starts { distance[start] = 0 }
        var queue = starts
        var head = 0
        var result: [(Int64, Int)] = []
        while head < queue.count {
            let node = queue[head]
            head += 1
            let d = distance[node]!
            guard d < maxDepth else { continue }
            let edges = dependents ? incoming[node] ?? [] : outgoing[node] ?? []
            for edge in edges where distance[edge.file] == nil {
                distance[edge.file] = d + 1
                queue.append(edge.file)
                result.append((edge.file, d + 1))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// Aggregated edge kinds/weights between two files in one direction.
    func relation(from source: Int64, to target: Int64) -> (kinds: [EdgeKind], weight: Int) {
        let edges = (outgoing[source] ?? []).filter { $0.file == target }
        let kinds = Array(Set(edges.map(\.kind))).sorted { $0.rawValue < $1.rawValue }
        return (kinds, edges.reduce(0) { $0 + $1.weight })
    }
}

/// Command-palette style fuzzy matching ("authsvc" → `AuthService.swift`).
enum FuzzyMatcher {
    /// Higher is better; nil when the pattern is not a subsequence of the candidate.
    static func score(_ pattern: String, _ candidate: String) -> Double? {
        let p = Array(pattern.lowercased().filter { !$0.isWhitespace })
        guard !p.isEmpty else { return 0 }
        let original = Array(candidate)
        let c = Array(candidate.lowercased())
        guard p.count <= c.count else { return nil }
        let nameStart = (candidate.lastIndex(of: "/").map { candidate.distance(from: candidate.startIndex, to: $0) + 1 }) ?? 0

        var score = 0.0
        var pi = 0
        var lastMatch = -2
        var firstMatch = -1
        for ci in 0..<c.count where pi < p.count {
            guard c[ci] == p[pi] else { continue }
            var bonus = 1.0
            let previous: Character? = ci > 0 ? original[ci - 1] : nil
            if ci == 0 || previous == "/" || previous == "_" || previous == "-" || previous == "." || previous == " " {
                bonus += 6
            } else if original[ci].isUppercase && (previous?.isLowercase ?? false) {
                bonus += 5
            }
            if lastMatch == ci - 1 { bonus += 4 }
            if ci >= nameStart { bonus += 2 }
            if firstMatch < 0 { firstMatch = ci }
            score += bonus
            lastMatch = ci
            pi += 1
        }
        guard pi == p.count else { return nil }
        // Prefer shorter candidates and matches inside the file name.
        score -= Double(c.count) * 0.05
        if firstMatch >= nameStart { score += 4 }
        if candidate.lowercased().hasSuffix(pattern.lowercased()) || (candidate as NSString).lastPathComponent.lowercased().hasPrefix(pattern.lowercased()) { score += 8 }
        return score
    }
}
