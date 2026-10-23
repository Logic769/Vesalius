import Foundation
import RepositoryIndex
import SemanticSearch
import VesaliusCore

extension RepositoryEngine {
    static let referenceConfidence = 0.35

    // MARK: - References

    /// Every resolved use of a symbol, with enclosing symbol and source snippet. When the name is not
    /// declared in the repository (e.g. a framework type), unresolved uses are returned as textual matches.
    public func references(_ symbol: String, limit: Int = 100) throws -> ReferencesResult {
        let symbols = try resolveSymbols(symbol)
        let reader = SnippetReader(root: root)
        if symbols.isEmpty {
            let name = String(symbol.split(separator: ".").last ?? Substring(symbol))
            let sites = try db.query("""
                SELECT f.path, r.line, r.kind, r.count, fs.qualified_name
                FROM refs r JOIN files f ON f.id = r.file_id LEFT JOIN symbols fs ON fs.id = r.from_symbol_id
                WHERE r.name = ? AND r.target_symbol_id IS NULL ORDER BY f.path, r.line LIMIT ?
                """, [name, limit]) { row in
                ReferenceSite(path: row.string(0), line: row.int(1), kind: ReferenceKind(rawValue: row.string(2)) ?? .read, from: row.optionalString(4), snippet: reader.line(row.int(1), in: row.string(0)), count: row.int(3) > 1 ? row.int(3) : nil)
            }
            if sites.isEmpty { throw EngineError.notFound(symbol, suggestions: try suggestions(for: symbol)) }
            return ReferencesResult(query: symbol, symbols: [], references: [], total: 0, textualMatches: sites)
        }
        let ids = symbols.prefix(12).map(\.id)
        let total = try db.scalarInt("SELECT COALESCE(SUM(count), 0) FROM refs WHERE target_symbol_id IN (\(ids.sqlList)) AND confidence >= ?", [Self.referenceConfidence])
        let sites = try db.query("""
            SELECT f.path, r.line, r.kind, r.count, fs.qualified_name
            FROM refs r JOIN files f ON f.id = r.file_id LEFT JOIN symbols fs ON fs.id = r.from_symbol_id
            WHERE r.target_symbol_id IN (\(ids.sqlList)) AND r.confidence >= ?
            ORDER BY f.path, r.line LIMIT ?
            """, [Self.referenceConfidence, limit], cache: false) { row in
            ReferenceSite(path: row.string(0), line: row.int(1), kind: ReferenceKind(rawValue: row.string(2)) ?? .read, from: row.optionalString(4), snippet: reader.line(row.int(1), in: row.string(0)), count: row.int(3) > 1 ? row.int(3) : nil)
        }
        let counts = try referenceCounts(ids)
        return ReferencesResult(query: symbol, symbols: symbols.prefix(12).map { $0.summary(references: counts[$0.id] ?? 0) }, references: sites, total: total)
    }

    // MARK: - Call graph

    public func callers(_ symbol: String, limit: Int = 50) throws -> CallGraphResult {
        let symbols = try resolveSymbols(symbol)
        guard !symbols.isEmpty else { throw EngineError.notFound(symbol, suggestions: try suggestions(for: symbol)) }
        let ids = symbols.prefix(12).map(\.id)
        var kinds = "'call','instantiate','decorator'"
        if try db.scalarInt("SELECT COUNT(*) FROM refs WHERE target_symbol_id IN (\(ids.sqlList)) AND kind IN (\(kinds))") == 0 {
            kinds = "'call','instantiate','decorator','read','write','type','member'"
        }
        var grouped: [String: (row: SymbolRow?, path: String, lines: [Int], count: Int)] = [:]
        try db.forEach("""
            SELECT r.from_symbol_id, f.path, r.line, r.count FROM refs r JOIN files f ON f.id = r.file_id
            WHERE r.target_symbol_id IN (\(ids.sqlList)) AND r.kind IN (\(kinds)) AND r.confidence >= ?
            ORDER BY f.path, r.line
            """, [Self.referenceConfidence]) { row in
            let key = row.optionalInt64(0).map(String.init) ?? "file:" + row.string(1)
            var entry = grouped[key] ?? (nil, row.string(1), [], 0)
            entry.lines.append(row.int(2))
            entry.count += row.int(3)
            grouped[key] = entry
        }
        let fromIDs = grouped.keys.compactMap(Int64.init)
        let fromRows = fromIDs.isEmpty ? [] : try symbolRows(where: "s.id IN (\(fromIDs.sqlList))", [], limit: 5000)
        let byID = Dictionary(uniqueKeysWithValues: fromRows.map { ($0.id, $0) })
        var relations: [CallRelation] = []
        for (key, entry) in grouped {
            let fromRow: SymbolRow? = Int64(key).flatMap { byID[$0] }
            let summary: SymbolSummary = fromRow?.summary() ?? Self.topLevelSummary(path: entry.path, line: entry.lines.first ?? 1)
            relations.append(CallRelation(symbol: summary, sites: entry.lines, count: entry.count))
        }
        relations.sort(by: Self.byCount)
        return CallGraphResult(query: symbol, direction: "callers", symbols: symbols.prefix(12).map { $0.summary() }, relations: Array(relations.prefix(limit)))
    }

    public func callees(_ symbol: String, limit: Int = 50) throws -> CallGraphResult {
        let symbols = try resolveSymbols(symbol)
        guard !symbols.isEmpty else { throw EngineError.notFound(symbol, suggestions: try suggestions(for: symbol)) }
        // A type's callees are those of all its members.
        var sources = Set(symbols.prefix(12).map(\.id))
        var frontier = Array(sources)
        while !frontier.isEmpty && sources.count < 2000 {
            let children = try db.query("SELECT id FROM symbols WHERE parent_id IN (\(frontier.sqlList))") { $0.int64(0) }
            frontier = children.filter { sources.insert($0).inserted }
        }
        var grouped: [Int64: (lines: [Int], count: Int)] = [:]
        try db.forEach("""
            SELECT r.target_symbol_id, r.line, r.count FROM refs r
            WHERE r.from_symbol_id IN (\(Array(sources).sqlList)) AND r.target_symbol_id IS NOT NULL
              AND r.kind IN ('call','instantiate','decorator') AND r.confidence >= ?
            """, [ReferenceLinker.edgeThreshold]) { row in
            var entry = grouped[row.int64(0)] ?? ([], 0)
            entry.lines.append(row.int(1))
            entry.count += row.int(2)
            grouped[row.int64(0)] = entry
        }
        grouped = grouped.filter { !sources.contains($0.key) }
        let targets = grouped.isEmpty ? [] : try symbolRows(where: "s.id IN (\(Array(grouped.keys).sqlList))", [], limit: 5000)
        var relations: [CallRelation] = []
        for row in targets {
            let entry = grouped[row.id]
            let sites: [Int] = entry?.lines.sorted() ?? []
            relations.append(CallRelation(symbol: row.summary(), sites: sites, count: entry?.count ?? 0))
        }
        relations.sort(by: Self.byCount)
        return CallGraphResult(query: symbol, direction: "callees", symbols: symbols.prefix(12).map { $0.summary() }, relations: Array(relations.prefix(limit)))
    }

    static func byCount(_ a: CallRelation, _ b: CallRelation) -> Bool {
        a.count == b.count ? a.symbol.id < b.symbol.id : a.count > b.count
    }

    static func topLevelSummary(path: String, line: Int) -> SymbolSummary {
        SymbolSummary(id: NodeID.file(path), name: "(top level)", qualifiedName: (path as NSString).lastPathComponent, kind: .namespace, path: path, lines: LineRange(line, line))
    }

    // MARK: - Dependencies

    /// Starting files for a target, and the files it reaches in one hop (for symbols, via its references).
    private func startFiles(_ target: Target, dependents: Bool) throws -> (starts: [Int64], firstHop: [Int64: Set<String>]?) {
        switch target {
        case .file(let id, _):
            return ([id], nil)
        case .group(_, _, let ids):
            return (ids, nil)
        case .symbols(let rows):
            let ids = rows.prefix(12).map(\.id)
            var hop: [Int64: Set<String>] = [:]
            if dependents {
                try db.forEach("SELECT r.file_id, s.name FROM refs r JOIN symbols s ON s.id = r.target_symbol_id WHERE r.target_symbol_id IN (\(ids.sqlList)) AND r.confidence >= ?", [ReferenceLinker.edgeThreshold]) { row in
                    hop[row.int64(0), default: []].insert(row.string(1))
                }
                for row in rows { hop[row.fileID] = nil }
            } else {
                var sources = Set(ids)
                let children = try db.query("SELECT id FROM symbols WHERE parent_id IN (\(ids.sqlList))") { $0.int64(0) }
                sources.formUnion(children)
                try db.forEach("SELECT r.target_file_id, COALESCE(s.name, r.name) FROM refs r LEFT JOIN symbols s ON s.id = r.target_symbol_id WHERE r.from_symbol_id IN (\(Array(sources).sqlList)) AND r.target_file_id IS NOT NULL AND r.confidence >= ?", [ReferenceLinker.edgeThreshold]) { row in
                    hop[row.int64(0), default: []].insert(row.string(1))
                }
                for row in rows { hop[row.fileID] = nil }
            }
            return (rows.map(\.fileID), hop)
        }
    }

    public func dependencies(of target: String, depth: Int = 1, limit: Int = 100) throws -> DependencyResult {
        try relatedFiles(target: target, dependents: false, depth: max(1, depth), limit: limit)
    }

    public func dependents(of target: String, depth: Int = 1, limit: Int = 100) throws -> DependencyResult {
        try relatedFiles(target: target, dependents: true, depth: max(1, depth), limit: limit)
    }

    private func relatedFiles(target text: String, dependents: Bool, depth: Int, limit: Int) throws -> DependencyResult {
        let target = try resolveTarget(text)
        let cache = try graphCache()
        let (starts, firstHop) = try startFiles(target, dependents: dependents)
        let startSet = Set(starts)

        var distances: [Int64: Int] = [:]
        if let firstHop {
            for id in firstHop.keys { distances[id] = 1 }
            if depth > 1 {
                for (id, distance) in cache.traverse(from: Array(firstHop.keys), dependents: dependents, maxDepth: depth - 1) where distances[id] == nil {
                    distances[id] = distance + 1
                }
            }
        } else {
            for (id, distance) in cache.traverse(from: starts, dependents: dependents, maxDepth: depth) where !startSet.contains(id) {
                distances[id] = distance
            }
        }
        distances = distances.filter { !startSet.contains($0.key) || firstHop != nil }

        let ordered = distances.sorted { a, b in
            if a.value != b.value { return a.value < b.value }
            return (cache.files[a.key]?.path ?? "") < (cache.files[b.key]?.path ?? "")
        }
        var files: [FileRelation] = []
        for (id, distance) in ordered.prefix(limit) {
            guard let node = cache.files[id] else { continue }
            var kinds = Set<EdgeKind>()
            var weight = 0
            if distance == 1 {
                for start in starts {
                    let relation = dependents ? cache.relation(from: id, to: start) : cache.relation(from: start, to: id)
                    kinds.formUnion(relation.kinds)
                    weight += relation.weight
                }
            }
            var symbols: [String]?
            if distance == 1 {
                if let names = firstHop?[id] {
                    symbols = names.sorted().prefix(6).map { $0 }
                } else {
                    let sourceList = dependents ? [id] : starts
                    let targetList = dependents ? starts : [id]
                    let names = try db.query("""
                        SELECT DISTINCT COALESCE(s.name, r.name) FROM refs r LEFT JOIN symbols s ON s.id = r.target_symbol_id
                        WHERE r.file_id IN (\(sourceList.sqlList)) AND r.target_file_id IN (\(targetList.sqlList)) AND r.confidence >= ? LIMIT 6
                        """, [ReferenceLinker.edgeThreshold], cache: false) { $0.string(0) }
                    symbols = names.isEmpty ? nil : names
                }
            }
            files.append(FileRelation(path: node.path, kinds: kinds.sorted { $0.rawValue < $1.rawValue }, weight: weight, symbols: symbols, distance: distance))
        }

        var external: [String]?
        if !dependents {
            let names = try db.query("SELECT DISTINCT external_name FROM imports WHERE file_id IN (\(starts.sqlList)) AND external_name IS NOT NULL ORDER BY external_name LIMIT 60") { $0.string(0) }
            external = names.isEmpty ? nil : names
        }
        return DependencyResult(target: target.description, direction: dependents ? "dependents" : "dependencies", depth: depth, files: files, externalModules: external, total: distances.count)
    }

    // MARK: - Impact

    public func impact(of text: String, depth: Int = 8) throws -> ImpactReport {
        let target = try resolveTarget(text)
        let cache = try graphCache()
        let (starts, firstHop) = try startFiles(target, dependents: true)
        let startSet = Set(starts)

        var direct: [Int64: Set<String>] = [:]
        if let firstHop {
            direct = firstHop
        } else {
            for start in starts {
                for edge in cache.incoming[start] ?? [] where !startSet.contains(edge.file) {
                    direct[edge.file, default: []].insert(edge.kind.rawValue)
                }
            }
        }
        var distances: [Int64: Int] = [:]
        for id in direct.keys { distances[id] = 1 }
        for (id, distance) in cache.traverse(from: Array(direct.keys), dependents: true, maxDepth: max(1, depth - 1)) where distances[id] == nil && !startSet.contains(id) {
            distances[id] = distance + 1
        }

        func relation(_ id: Int64, _ distance: Int) -> FileRelation? {
            guard let node = cache.files[id] else { return nil }
            var kinds: [EdgeKind] = []
            var weight = 0
            if distance == 1 {
                for start in starts {
                    let r = cache.relation(from: id, to: start)
                    kinds.append(contentsOf: r.kinds)
                    weight += r.weight
                }
            }
            let symbols = distance == 1 && firstHop != nil ? direct[id].map { $0.sorted().prefix(5).map { $0 } } : nil
            return FileRelation(path: node.path, kinds: Array(Set(kinds)).sorted { $0.rawValue < $1.rawValue }, weight: weight, symbols: symbols, distance: distance)
        }
        var directRelations: [FileRelation] = direct.keys.compactMap { relation($0, 1) }
        directRelations.sort { (a: FileRelation, b: FileRelation) -> Bool in a.weight == b.weight ? a.path < b.path : a.weight > b.weight }
        var transitiveRelations: [FileRelation] = distances.filter { $0.value > 1 }.compactMap { relation($0.key, $0.value) }
        transitiveRelations.sort { (a: FileRelation, b: FileRelation) -> Bool in
            let da = a.distance ?? 0, db = b.distance ?? 0
            return da == db ? a.path < b.path : da < db
        }

        // Call/reference sites into the target.
        let reader = SnippetReader(root: root)
        var callers: [ReferenceSite] = []
        let siteQuery: String
        switch target {
        case .symbols(let rows):
            siteQuery = "r.target_symbol_id IN (\(rows.prefix(12).map(\.id).sqlList))"
        case .file(let id, _):
            siteQuery = "r.target_file_id = \(id) AND r.file_id != \(id)"
        case .group(_, _, let ids):
            siteQuery = "r.target_file_id IN (\(ids.sqlList)) AND r.file_id NOT IN (\(ids.sqlList))"
        }
        callers = try db.query("""
            SELECT f.path, r.line, r.kind, r.count, fs.qualified_name FROM refs r JOIN files f ON f.id = r.file_id
            LEFT JOIN symbols fs ON fs.id = r.from_symbol_id
            WHERE \(siteQuery) AND r.confidence >= ? ORDER BY r.count DESC, f.path, r.line LIMIT 30
            """, [ReferenceLinker.edgeThreshold], cache: false) { row in
            ReferenceSite(path: row.string(0), line: row.int(1), kind: ReferenceKind(rawValue: row.string(2)) ?? .read, from: row.optionalString(4), snippet: reader.line(row.int(1), in: row.string(0)), count: row.int(3) > 1 ? row.int(3) : nil)
        }

        // Related tests: affected test files plus tests named after the target.
        let affectedIDs = Set(distances.keys)
        var testDistance: [String: Int] = [:]
        for id in affectedIDs {
            guard let node = cache.files[id], node.isTest else { continue }
            testDistance[node.path] = distances[id] ?? 9
        }
        var tests = Set(testDistance.keys)
        let stems: [String] = {
            switch target {
            case .file(_, let path): return [((path as NSString).lastPathComponent as NSString).deletingPathExtension]
            case .symbols(let rows): return Array(Set(rows.prefix(3).map { $0.name } + rows.prefix(3).map { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension }))
            case .group(_, let label, _): return [(label as NSString).lastPathComponent]
            }
        }()
        var namedTests = Set<String>()
        for node in cache.ordered where node.isTest {
            let name = (node.name as NSString).deletingPathExtension.lowercased()
            if stems.contains(where: { $0.count >= 3 && name.contains($0.lowercased()) }) {
                tests.insert(node.path)
                namedTests.insert(node.path)
            }
        }
        // Tests named after the target first, then by distance: the ones most likely to catch a regression.
        let rankedTests = tests.sorted { a, b in
            let na = namedTests.contains(a), nb = namedTests.contains(b)
            if na != nb { return na }
            let da = testDistance[a] ?? 0, db = testDistance[b] ?? 0
            return da == db ? a < b : da < db
        }

        // Affected areas.
        var areas: [String: Int] = [:]
        for id in affectedIDs {
            guard let node = cache.files[id] else { continue }
            areas[Self.areaName(for: node), default: 0] += 1
        }
        var affectedAreas: [AffectedArea] = areas.map { AffectedArea(name: $0.key, files: $0.value) }
        affectedAreas.sort { (a: AffectedArea, b: AffectedArea) -> Bool in a.files == b.files ? a.name < b.name : a.files > b.files }

        // Risk.
        let codeFiles = max(1, cache.ordered.filter(\.isCode).count)
        let primary = starts.compactMap { cache.files[$0] }
        let centrality = primary.map(\.centrality).max() ?? 0
        let complexity = primary.map(\.complexity).reduce(0, +)
        let churn = primary.compactMap(\.churn).reduce(0, +)
        let inCycle = primary.contains { $0.cycleID != nil }
        var factors: [ScoreFactor] = []
        func add(_ label: String, _ detail: String, _ points: Double, _ value: Double? = nil) {
            if abs(points) >= 0.5 { factors.append(ScoreFactor(label: label, detail: detail, impact: (points * 10).rounded() / 10, value: value)) }
        }
        add("Direct dependents", "\(directRelations.count) \(directRelations.count == 1 ? "file uses" : "files use") it directly", min(30, Double(directRelations.count) * 3), Double(directRelations.count))
        let reachShare = Double(affectedIDs.count) / Double(codeFiles)
        add("Transitive reach", "\(affectedIDs.count) \(affectedIDs.count == 1 ? "file" : "files") affected transitively (\(Int((reachShare * 100).rounded()))% of code files)", min(25, 25 * Double(affectedIDs.count) / max(10, Double(codeFiles) * 0.3)), Double(affectedIDs.count))
        add("Centrality", String(format: "centrality %.2f in the dependency graph", centrality), 15 * centrality, centrality)
        add("Complexity", "combined complexity \(complexity)", min(10, Double(complexity) / 20), Double(complexity))
        if churn > 0 { add("Recent churn", "\(churn) \(churn == 1 ? "commit" : "commits") in the last year", min(10, Double(churn) / 3), Double(churn)) }
        if inCycle { add("Dependency cycle", "participates in a dependency cycle", 10) }
        if !tests.isEmpty {
            add("Test coverage signal", "\(tests.count) related test \(tests.count == 1 ? "file" : "files") found", -min(12, Double(tests.count) * 4), Double(tests.count))
        } else if directRelations.count > 3 {
            add("No related tests", "no test files reference it or are named after it", 6)
        }
        let score = min(100, max(0, factors.reduce(0) { $0 + $1.impact }))
        let level = RiskLevel.from(score: score)

        let name = target.description
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var summary = "Changing \(name) directly affects \(plural(directRelations.count, "file")) and \(transitiveRelations.count) more transitively"
        if !affectedAreas.isEmpty { summary += " across \(plural(affectedAreas.count, "area")) (\(affectedAreas.prefix(3).map(\.name).joined(separator: ", ")))" }
        summary += ". Risk: \(level.rawValue) (\(Int(score.rounded()))/100)."
        if !rankedTests.isEmpty { summary += " Start with " + rankedTests.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + (rankedTests.count > 3 ? " (\(rankedTests.count) related tests)" : "") + "." }

        let kind: String
        var symbols: [SymbolSummary]?
        switch target {
        case .file: kind = "file"
        case .group: kind = "group"
        case .symbols(let rows):
            kind = "symbol"
            symbols = rows.prefix(5).map { $0.summary() }
        }
        return ImpactReport(
            target: name,
            targetKind: kind,
            symbols: symbols,
            directDependents: directRelations,
            transitiveDependents: transitiveRelations,
            callers: callers,
            relatedTests: rankedTests,
            affectedAreas: affectedAreas,
            riskScore: (score * 10).rounded() / 10,
            riskLevel: level,
            factors: factors.sorted { abs($0.impact) > abs($1.impact) },
            summary: summary
        )
    }

    func impactSummary(_ text: String) -> ImpactSummary {
        guard let report = try? impact(of: text, depth: 6) else {
            return ImpactSummary(directDependents: 0, transitiveDependents: 0, relatedTests: 0, riskScore: 0, riskLevel: .low)
        }
        return ImpactSummary(directDependents: report.directDependents.count, transitiveDependents: report.transitiveDependents.count, relatedTests: report.relatedTests.count, riskScore: report.riskScore, riskLevel: report.riskLevel)
    }

    /// The area (module or top-level folder) a file belongs to.
    static func areaName(for node: GraphCache.FileNode) -> String {
        if let module = node.module { return module }
        let parts = node.path.split(separator: "/")
        if parts.count <= 1 { return "(root)" }
        let first = String(parts[0])
        let containers: Set<String> = ["src", "Sources", "lib", "app", "apps", "packages", "Features", "Modules", "Packages", "pkg", "internal"]
        if containers.contains(first), parts.count > 2 { return first + "/" + parts[1] }
        return first
    }

    // MARK: - Related files

    public func relatedFiles(_ path: String, limit: Int = 12) throws -> [RelatedFile] {
        guard case .file(let id, _) = try resolveTarget(path) else { return [] }
        let cache = try graphCache()
        guard let node = cache.files[id] else { return [] }
        var scores: [Int64: (Double, String)] = [:]
        func offer(_ other: Int64, _ score: Double, _ reason: String) {
            guard other != id else { return }
            if (scores[other]?.0 ?? 0) < score { scores[other] = (score, reason) }
        }
        let outgoing = cache.outgoing[id] ?? []
        let incoming = cache.incoming[id] ?? []
        let maxWeight = Double(max(1, (outgoing + incoming).map(\.weight).max() ?? 1))
        for edge in outgoing { offer(edge.file, 0.6 + 0.4 * Double(edge.weight) / maxWeight, "\(edge.kind.rawValue) (uses)") }
        for edge in incoming { offer(edge.file, 0.55 + 0.4 * Double(edge.weight) / maxWeight, "\(edge.kind.rawValue) (used by)") }

        // Files sharing dependencies or dependents (co-dependence).
        var shared: [Int64: Int] = [:]
        for edge in outgoing.prefix(40) {
            for other in (cache.incoming[edge.file] ?? []).prefix(80) where other.file != id { shared[other.file, default: 0] += 1 }
        }
        for (other, count) in shared where count >= 2 {
            offer(other, min(0.6, 0.25 + 0.07 * Double(count)), "shares \(count) dependencies")
        }

        // Same feature name (FooView, FooViewModel, FooTests).
        let stemWords = Tokenizer.splitIdentifier((node.name as NSString).deletingPathExtension)
        if let lead = stemWords.first, lead.count >= 3 {
            for other in cache.ordered where other.id != id {
                let words = Tokenizer.splitIdentifier((other.name as NSString).deletingPathExtension)
                if words.first == lead && stemWords.count >= 1 {
                    offer(other.id, other.isTest ? 0.5 : 0.45, "same feature name (\(lead))")
                }
            }
        }
        var related: [RelatedFile] = []
        for (other, value) in scores {
            guard let file = cache.files[other] else { continue }
            let score: Double = (value.0 * 100).rounded() / 100
            related.append(RelatedFile(path: file.path, score: score, reason: value.1))
        }
        related.sort { (a: RelatedFile, b: RelatedFile) -> Bool in a.score == b.score ? a.path < b.path : a.score > b.score }
        return Array(related.prefix(limit))
    }
}
