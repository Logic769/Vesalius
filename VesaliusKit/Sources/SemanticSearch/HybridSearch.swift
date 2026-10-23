import Foundation
import RepositoryIndex
import VesaliusCore

public struct MatchedSymbol: Sendable, Hashable {
    public let id: Int64
    public let name: String
    public let qualifiedName: String
    public let kind: SymbolKind
    public let lines: LineRange
    public let score: Double
}

public struct SearchHit: Sendable {
    public let fileID: Int64
    public let path: String
    public let language: Language
    /// Calibrated relevance 0…1.
    public let relevance: Double
    public let reasons: [String]
    public let symbols: [MatchedSymbol]
    public let matchedTerms: [String]
    public let fanIn: Int
    public let fanOut: Int
    /// The question's units (phrases, frameworks, acronyms, words) this file matched.
    public var coveredUnits: [String] = []
}

public struct SearchOutcome: Sendable {
    public let query: ParsedQuery
    public let hits: [SearchHit]
    /// Graph neighbours of the top hits that did not match lexically but are structurally involved.
    public let related: [RelatedFile]
    /// Expanded terms ordered by weight (for display).
    public let terms: [String]
    /// Share of the question's content words matched by the best result (0…1).
    public let coverage: Double
    /// Markdown files that matched, best first. They are not ranked with code: a result shows at most one
    /// section of them, labelled as possibly stale.
    public var docs: [SearchHit] = []
}

/// Hybrid retrieval: term-weighted BM25 over files and symbols (FTS5), exact identifier matches,
/// path/directory signals, on-device semantic similarity, structural centrality and one hop of
/// graph propagation. Everything is computed from the persistent index — no file is re-read.
public final class HybridSearch {
    let db: SQLiteDatabase
    public let vocabulary: Vocabulary
    private let semantic: SemanticIndex?
    /// The repository's imported external modules (`StoreKit`, `crypto`, `electron`), which the parser keeps whole.
    public let externalModules: [String]

    /// Most search terms per question: each unit keeps its own word and its two best expansions first.
    static let termBudget = 24
    static let expansionsPerUnit = 2

    public init(db: SQLiteDatabase, useEmbeddings: Bool = true) throws {
        self.db = db
        self.vocabulary = try Vocabulary(db: db)
        self.semantic = useEmbeddings ? (try? SemanticIndex(db: db)).flatMap { $0.isEmpty ? nil : $0 } : nil
        self.externalModules = try db.query("SELECT DISTINCT external_name FROM imports WHERE external_name IS NOT NULL AND is_mock = 0 ORDER BY external_name") { $0.string(0) }
    }

    public func parse(_ question: String) -> ParsedQuery {
        QueryParser.parse(question, vocabulary: vocabulary, useEmbeddings: semantic != nil || true, externalModules: externalModules)
    }

    struct FileFacts {
        let path: String
        let language: Language
        let isTest: Bool
        let isGenerated: Bool
        let centrality: Double
        let fanIn: Int
        let fanOut: Int
        /// Demo, example, sample or playground code: ranked down like tests unless the question asks for it.
        let isDemo: Bool
    }

    public func search(_ question: String, limit: Int = 10) throws -> SearchOutcome {
        let query = parse(question)
        return try search(query, limit: limit)
    }

    /// The terms searched, at most `termBudget`: every unit's own term and its best expansions first, then the
    /// remaining expansions by weight.
    static func budgetedTerms(_ query: ParsedQuery, vocabulary: Vocabulary) -> [(key: String, value: Double)] {
        let ranked = query.terms.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard !query.origins.isEmpty else { return Array(ranked.prefix(18)) }
        var byUnit: [String: [(key: String, value: Double)]] = [:]
        for term in ranked { byUnit[query.origins[term.key] ?? term.key, default: []].append(term) }
        var chosen: [(key: String, value: Double)] = []
        var taken = Set<String>()
        func take(_ term: (key: String, value: Double)) {
            guard chosen.count < termBudget, taken.insert(term.key).inserted else { return }
            chosen.append(term)
        }
        let units = query.units + byUnit.keys.filter { !query.units.contains($0) }.sorted()
        for unit in units {
            guard let terms = byUnit[unit] else { continue }
            if let own = terms.first(where: { $0.key == unit || $0.key == unit.lowercased().replacingOccurrences(of: " ", with: "") }) { take(own) }
            let isPhrase = query.phrases.contains(unit) || query.frameworks.contains(unit)
            let others = terms.filter { !taken.contains($0.key) }
                .sorted { ($0.value * vocabulary.idf($0.key), $1.key) > ($1.value * vocabulary.idf($1.key), $0.key) }
            for term in others.prefix(isPhrase ? 4 : expansionsPerUnit) { take(term) }
        }
        for term in ranked { take(term) }
        return chosen
    }

    public func search(_ query: ParsedQuery, limit: Int = 10) throws -> SearchOutcome {
        let rankedTerms = query.terms.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let terms = Self.budgetedTerms(query, vocabulary: vocabulary)
        guard !terms.isEmpty || !query.identifiers.isEmpty else {
            return SearchOutcome(query: query, hits: [], related: [], terms: [], coverage: 0)
        }
        let maxIDF = terms.map { vocabulary.idf($0.key) }.max() ?? 1

        // Which question unit(s) each search term came from: every unit contributes the best of its direct match
        // or a discounted synonym match, never the sum, so files that merely match many synonyms cannot outrank
        // the file that owns the concept.
        var origins: [String: Set<String>] = [:]
        if query.origins.isEmpty {
            for word in query.words {
                for (term, _) in ConceptLexicon.expand([word]) where query.terms[term] != nil { origins[term, default: []].insert(word) }
                origins[word, default: []].insert(word)
            }
        } else {
            for (term, unit) in query.origins { origins[term, default: []].insert(unit) }
        }
        for (term, _) in terms where origins[term] == nil {
            // Vocabulary completions and embedding neighbours: attribute to the closest question word.
            let owner = query.words.first { term.hasPrefix($0) || $0.hasPrefix(term) } ?? query.words.first ?? term
            origins[term, default: []].insert(owner)
        }

        struct TermHit {
            var lexical = 0.0
            var symbol = 0.0
            var path = false
        }
        var termHits: [String: [Int64: TermHit]] = [:]
        var termWeights: [String: Double] = [:]
        var fileSymbols: [Int64: [MatchedSymbol]] = [:]
        var exactBoost: [Int64: Double] = [:]

        let ownWords = Set(query.words)
        for (term, weight) in terms {
            let idf = vocabulary.idf(term) / maxIDF
            termWeights[term] = weight * (0.35 + 0.65 * idf)
            // Prefix matching only completes a question word the repository does not use (`authn`), so `commit`
            // no longer matches `walCommittedSeq`.
            let isOriginal = ownWords.contains(term)
            let match = isOriginal && term.count >= 4 && !vocabulary.contains(term) ? "(\"\(term)\" OR \"\(term)\"*)" : "\"\(term)\""
            var perFile: [Int64: TermHit] = [:]

            let fileRows = try db.query("SELECT rowid, -bm25(fts_files, 6.0, 4.0, 1.5, 1.0) AS s FROM fts_files WHERE fts_files MATCH ? ORDER BY s DESC LIMIT 150", [match], cache: false) { ($0.int64(0), $0.double(1)) }
            if let top = fileRows.first?.1, top > 0 {
                for (id, score) in fileRows { perFile[id, default: TermHit()].lexical = score / top }
            }
            let pathRows = try db.query("SELECT rowid FROM fts_files WHERE fts_files MATCH ? LIMIT 300", ["path : \(match)"], cache: false) { $0.int64(0) }
            for id in pathRows { perFile[id, default: TermHit()].path = true }

            let symbolRows = try db.query("""
                SELECT s.id, s.file_id, s.name, s.qualified_name, s.kind, s.start_line, s.end_line, -bm25(fts_symbols, 6.0, 4.0, 2.0, 1.0, 0.5) AS score
                FROM fts_symbols JOIN symbols s ON s.id = fts_symbols.rowid
                WHERE fts_symbols MATCH ? ORDER BY score DESC LIMIT 200
                """, ["{name words qualified doc} : \(match)"], cache: false) { row in
                (row.int64(0), row.int64(1), row.string(2), row.string(3), SymbolKind(rawValue: row.string(4)) ?? .variable, row.int(5), row.int(6), row.double(7))
            }
            if let top = symbolRows.first?.7, top > 0 {
                for (id, fileID, name, qualified, kind, start, end, score) in symbolRows {
                    // A type named after the term (CatalogImporter for "catalog") is the strongest signal.
                    let nameWords = Tokenizer.splitIdentifier(name)
                    let leading = nameWords.first.map { $0 == term || Tokenizer.stem($0) == Tokenizer.stem(term) } ?? false
                    let value = (score / top) * Self.kindWeight(kind) * (leading && kind.isType ? 1.25 : 1)
                    perFile[fileID, default: TermHit()].symbol = max(perFile[fileID]?.symbol ?? 0, min(1.25, value))
                    fileSymbols[fileID, default: []].append(MatchedSymbol(id: id, name: name, qualifiedName: qualified, kind: kind, lines: LineRange(start, end), score: value * weight))
                }
            }
            termHits[term] = perFile
        }

        // Exact identifiers typed in the question (`BookFormatter`, `AuthService.swift`). Short ones keep their case,
        // so `ID` never matches every `id` property.
        for identifier in query.identifiers {
            let stem = (identifier as NSString).deletingPathExtension
            let exactCase = stem.count < 5
            let rows = try db.query(
                exactCase
                    ? "SELECT id, file_id, name, qualified_name, kind, start_line, end_line FROM symbols WHERE name = ? OR qualified_name = ? LIMIT 40"
                    : "SELECT id, file_id, name, qualified_name, kind, start_line, end_line FROM symbols WHERE name = ? COLLATE NOCASE OR qualified_name = ? COLLATE NOCASE LIMIT 40",
                [stem, stem]) { row in
                (row.int64(0), row.int64(1), row.string(2), row.string(3), SymbolKind(rawValue: row.string(4)) ?? .variable, row.int(5), row.int(6))
            }
            for (id, fileID, name, qualified, kind, start, end) in rows {
                exactBoost[fileID, default: 0] += 1.2 * Self.kindWeight(kind)
                fileSymbols[fileID, default: []].append(MatchedSymbol(id: id, name: name, qualifiedName: qualified, kind: kind, lines: LineRange(start, end), score: 2))
            }
            let files = try db.query("SELECT id FROM files WHERE name = ? COLLATE NOCASE OR name LIKE ? COLLATE NOCASE LIMIT 20", [identifier, stem + ".%"]) { $0.int64(0) }
            for id in files { exactBoost[id, default: 0] += 1.4 }
        }

        // Semantic similarity.
        var semanticScores: [Int64: Double] = [:]
        if let semantic {
            let text = ([query.original] + rankedTerms.prefix(8).map(\.key)).joined(separator: " ")
            semanticScores = semantic.similar(to: text)
        }

        var candidateIDs = Set(exactBoost.keys).union(semanticScores.keys)
        for perFile in termHits.values { candidateIDs.formUnion(perFile.keys) }
        guard !candidateIDs.isEmpty else {
            return SearchOutcome(query: query, hits: [], related: [], terms: terms.map(\.key), coverage: 0)
        }

        // Per unit: best direct-or-synonym evidence for each file.
        let units = query.units.isEmpty ? (query.words.isEmpty ? Array(Set(origins.values.flatMap { $0 })).sorted() : query.words) : query.units
        var conceptScores: [Int64: Double] = [:]
        var coverageByFile: [Int64: Double] = [:]
        var coveredByFile: [Int64: [String]] = [:]
        var matchedTerms: [Int64: Set<String>] = [:]
        var pathTerms: [Int64: Set<String>] = [:]
        for id in candidateIDs {
            var total = 0.0
            var covered = 0.0
            for unit in units {
                var best = 0.0
                var bestIsDirect = false
                for (term, termOrigins) in origins where termOrigins.contains(unit) {
                    guard let hit = termHits[term]?[id], let weight = termWeights[term] else { continue }
                    let evidence = 0.4 * hit.lexical + 0.4 * hit.symbol + (hit.path ? 0.35 : 0)
                    let value = weight * evidence
                    if value > 0 {
                        matchedTerms[id, default: []].insert(term)
                        if hit.path { pathTerms[id, default: []].insert(term) }
                    }
                    if value > best {
                        best = value
                        let key = unit.lowercased().replacingOccurrences(of: " ", with: "")
                        bestIsDirect = term == key || Tokenizer.stem(term) == Tokenizer.stem(key) || term.hasPrefix(key)
                            || query.phrases.contains(unit) || query.frameworks.contains(unit)
                    }
                }
                total += best
                if best > 0.05 {
                    covered += bestIsDirect ? 1 : 0.5
                    coveredByFile[id, default: []].append(unit)
                }
            }
            conceptScores[id] = total
            coverageByFile[id] = units.isEmpty ? 0 : covered / Double(units.count)
        }
        if candidateIDs.count > 2000 {
            let ranked = candidateIDs.sorted { (conceptScores[$0] ?? 0) > (conceptScores[$1] ?? 0) }
            candidateIDs = Set(ranked.prefix(2000))
        }
        let facts = try loadFacts(Array(candidateIDs))
        let topConcept = max(conceptScores.values.max() ?? 1, 1e-9)

        var scores: [Int64: Double] = [:]
        var docScores: [Int64: Double] = [:]
        for id in candidateIDs {
            guard let fact = facts[id] else { continue }
            var score = 0.85 * (conceptScores[id] ?? 0) / topConcept + 0.15 * (semanticScores[id] ?? 0)
            score += 0.4 * min(2, exactBoost[id] ?? 0)
            let covered = coverageByFile[id] ?? 0
            score *= 0.35 + 0.65 * covered
            score *= 1 + 0.15 * fact.centrality
            if fact.isGenerated { score *= 0.3 }
            if fact.isTest && !query.mentionsTests { score *= 0.55 }
            if fact.isDemo && !query.mentionsDemo { score *= 0.55 }
            if !query.mentionsAnalytics, Self.isAnalyticsOnly(fileSymbols[id] ?? []) { score *= 0.5 }
            // Markdown is not ranked with code: it is offered as a docs section instead.
            if fact.language == .markdown {
                docScores[id] = score
                continue
            }
            if !fact.language.isCode { score *= 0.4 }
            scores[id] = score
        }

        // One hop of graph propagation from the strongest results.
        let preliminary = scores.sorted { $0.value > $1.value }
        let seeds = preliminary.prefix(10)
        var related: [Int64: (score: Double, reason: String)] = [:]
        if let topScore = seeds.first?.value, topScore > 0 {
            for (seed, seedScore) in seeds {
                guard let seedPath = facts[seed]?.path else { continue }
                let neighbors = try db.query("""
                    SELECT dst_file_id, 'uses' FROM file_edges WHERE src_file_id = ?
                    UNION ALL SELECT src_file_id, 'used-by' FROM file_edges WHERE dst_file_id = ?
                    """, [seed, seed]) { ($0.int64(0), $0.string(1)) }
                for (neighbor, direction) in neighbors where neighbor != seed {
                    if let existing = scores[neighbor], existing > 0 {
                        scores[neighbor] = existing + 0.12 * seedScore
                    } else if seedScore > topScore * 0.35 {
                        let reason = direction == "uses"
                            ? "used by \((seedPath as NSString).lastPathComponent)"
                            : "depends on \((seedPath as NSString).lastPathComponent)"
                        let value = 0.5 * seedScore / topScore
                        if (related[neighbor]?.score ?? 0) < value { related[neighbor] = (value, reason) }
                    }
                }
            }
        }

        let ordered = scores.filter { $0.value > 0 }.sorted { $0.value == $1.value ? (facts[$0.key]?.path ?? "") < (facts[$1.key]?.path ?? "") : $0.value > $1.value }
        guard let best = ordered.first else {
            return SearchOutcome(query: query, hits: [], related: [], terms: terms.map(\.key), coverage: 0)
        }
        let topCoverage = coverageByFile[best.key] ?? 0
        let calibration = min(1, 0.3 + 0.7 * topCoverage + ((exactBoost[best.key] ?? 0) > 0 ? 0.25 : 0))

        func hit(_ id: Int64, score: Double, rank: Int) -> SearchHit? {
            guard let fact = facts[id] else { return nil }
            let symbols = Self.topSymbols(fileSymbols[id] ?? [], rank: rank)
            let relevance = ((score / best.value) * calibration * 100).rounded() / 100
            var hit = SearchHit(
                fileID: id,
                path: fact.path,
                language: fact.language,
                relevance: relevance,
                reasons: reasons(fact: fact, symbols: symbols, matched: matchedTerms[id] ?? [], pathTerms: pathTerms[id] ?? [], semantic: semanticScores[id] ?? 0, exact: exactBoost[id] ?? 0),
                symbols: symbols,
                // Heaviest first; equal weights by spelling, so the order never depends on the Set's.
                matchedTerms: (matchedTerms[id] ?? []).sorted { a, b in
                    let (weightA, weightB) = (query.terms[a] ?? 0, query.terms[b] ?? 0)
                    return weightA != weightB ? weightA > weightB : a < b
                },
                fanIn: fact.fanIn,
                fanOut: fact.fanOut
            )
            hit.coveredUnits = coveredByFile[id] ?? []
            return hit
        }
        var hits: [SearchHit] = []
        for (rank, (id, score)) in ordered.prefix(limit).enumerated() {
            if let found = hit(id, score: score, rank: rank) { hits.append(found) }
        }
        let docs = docScores.filter { $0.value > 0 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5).compactMap { hit($0.key, score: $0.value, rank: 2) }

        let hitIDs = Set(hits.map(\.fileID))
        let relatedFacts = try loadFacts(Array(related.keys.filter { !hitIDs.contains($0) }))
        let relatedFiles = related
            .filter { !hitIDs.contains($0.key) && relatedFacts[$0.key].map { $0.language.isCode && !$0.isGenerated } == true }
            .sorted { $0.value.score == $1.value.score ? $0.key < $1.key : $0.value.score > $1.value.score }
            .prefix(6)
            .compactMap { id, value in relatedFacts[id].map { RelatedFile(path: $0.path, score: (value.score * 100).rounded() / 100, reason: value.reason) } }

        var outcome = SearchOutcome(query: query, hits: hits, related: Array(relatedFiles), terms: terms.map(\.key), coverage: topCoverage)
        outcome.docs = docs
        return outcome
    }

    static func kindWeight(_ kind: SymbolKind) -> Double {
        switch kind {
        case .class, .struct, .actor, .protocol, .interface, .enum, .component: 1.0
        case .function, .method, .initializer, .macro: 0.85
        case .typeAlias, .namespace, .extension: 0.6
        case .property, .constant: 0.45
        case .variable: 0.35
        case .enumCase: 0.3
        }
    }

    /// A file's matched symbols, best first: 12 for the best file, 6 for the second, 3 after that, plus any
    /// symbol scoring at least 30% of the file's best.
    static func topSymbols(_ symbols: [MatchedSymbol], rank: Int = 0) -> [MatchedSymbol] {
        var best: [Int64: MatchedSymbol] = [:]
        for symbol in symbols {
            if let existing = best[symbol.id] {
                best[symbol.id] = MatchedSymbol(id: symbol.id, name: symbol.name, qualifiedName: symbol.qualifiedName, kind: symbol.kind, lines: symbol.lines, score: existing.score + symbol.score)
            } else {
                best[symbol.id] = symbol
            }
        }
        let sorted = best.values.sorted { $0.score == $1.score ? $0.lines.start < $1.lines.start : $0.score > $1.score }
        let cap = rank == 0 ? 12 : rank == 1 ? 6 : 3
        guard let top = sorted.first?.score, top > 0 else { return Array(sorted.prefix(cap)) }
        let strong = sorted.prefix { $0.score >= top * 0.3 }
        return Array(sorted.prefix(max(cap, min(strong.count, 12))))
    }

    /// Every matched symbol of the file is about analytics (`TelemetryEvent.purchaseCompleted`).
    static func isAnalyticsOnly(_ symbols: [MatchedSymbol]) -> Bool {
        guard !symbols.isEmpty else { return false }
        return symbols.allSatisfy { symbol in
            let concerns = ConceptLexicon.concerns(for: Tokenizer.splitIdentifier(symbol.qualifiedName) + ["\(symbol.qualifiedName.lowercased())"])
            guard let dominant = concerns.max(by: { $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value }) else { return false }
            return dominant.key == .analytics
        }
    }

    /// Demo, example, sample and playground code, by folder name.
    public static func isDemoPath(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { component in
            let lower = component.lowercased()
            return ["demo", "demos", "example", "examples", "sample", "samples", "playground", "playgrounds"].contains(lower)
                || (lower.hasSuffix("demo") && lower.count > 4) || lower.hasSuffix("example") || lower.hasSuffix("examples")
        }
    }

    private func reasons(fact: FileFacts, symbols: [MatchedSymbol], matched: Set<String>, pathTerms: Set<String>, semantic: Double, exact: Double) -> [String] {
        var reasons: [String] = []
        if !symbols.isEmpty {
            let names = symbols.prefix(3).map { "\($0.qualifiedName) (\($0.kind.displayName))" }
            reasons.append("defines " + names.joined(separator: ", "))
        }
        if !pathTerms.isEmpty {
            reasons.append("path matches " + pathTerms.sorted().prefix(3).map { "\"\($0)\"" }.joined(separator: ", "))
        }
        let bodyTerms = matched.subtracting(pathTerms).subtracting(Set(symbols.flatMap { Tokenizer.splitIdentifier($0.name) }))
        if !bodyTerms.isEmpty && symbols.isEmpty {
            reasons.append("mentions " + bodyTerms.sorted().prefix(4).joined(separator: ", "))
        }
        if semantic > 0.3 { reasons.append("semantically similar") }
        if fact.fanIn >= 5 { reasons.append("used by \(fact.fanIn) files") }
        if exact > 0 && reasons.isEmpty { reasons.append("exact name match") }
        return reasons
    }

    private func loadFacts(_ ids: [Int64]) throws -> [Int64: FileFacts] {
        guard !ids.isEmpty else { return [:] }
        var facts: [Int64: FileFacts] = [:]
        var demoTargets = Set<Int64>()
        // Files built only into demo, example or sample targets.
        try db.forEach("""
            SELECT ft.file_id FROM file_targets ft JOIN targets t ON t.id = ft.target_id
            WHERE lower(t.name) LIKE '%demo%' OR lower(t.name) LIKE '%example%' OR lower(t.name) LIKE '%sample%'
            EXCEPT
            SELECT ft.file_id FROM file_targets ft JOIN targets t ON t.id = ft.target_id
            WHERE NOT (lower(t.name) LIKE '%demo%' OR lower(t.name) LIKE '%example%' OR lower(t.name) LIKE '%sample%')
            """) { row in
            demoTargets.insert(row.int64(0))
        }
        for chunk in stride(from: 0, to: ids.count, by: 500) {
            let slice = Array(ids[chunk..<min(ids.count, chunk + 500)])
            try db.forEach("""
                SELECT f.id, f.path, f.language, f.is_test, f.is_generated, COALESCE(m.centrality, 0), COALESCE(m.fan_in, 0), COALESCE(m.fan_out, 0)
                FROM files f LEFT JOIN file_metrics m ON m.file_id = f.id WHERE f.id IN (\(slice.sqlList))
                """) { row in
                let path = row.string(1)
                facts[row.int64(0)] = FileFacts(path: path, language: Language(rawValue: row.string(2)) ?? .unknown, isTest: row.bool(3), isGenerated: row.bool(4),
                                                centrality: row.double(5), fanIn: row.int(6), fanOut: row.int(7),
                                                isDemo: demoTargets.contains(row.int64(0)) || Self.isDemoPath(path))
            }
        }
        return facts
    }
}
