import Foundation
import RepositoryIndex
import SemanticSearch
import VesaliusCore

extension RepositoryEngine {
    // MARK: - Natural-language questions

    /// Answers a natural-language question with the most relevant files, symbols and line ranges.
    /// Structural questions ("what depends on User", "who calls refreshToken") are routed to the graph.
    public func ask(_ question: String, limit: Int = 8) throws -> AskResult {
        let search = try search()
        let parsed = search.parse(question)
        if parsed.intent != .search, let subject = parsed.subject {
            if let structural = try? structuralAnswer(parsed: parsed, subject: subject, limit: limit) {
                return structural
            }
        }
        let outcome = try search.search(parsed, limit: limit)
        let files = outcome.hits.map { hit -> AskFile in
            let symbols = hit.symbols.map { AskSymbol(name: $0.qualifiedName, kind: $0.kind, lines: $0.lines) }
            let span: LineRange? = symbols.isEmpty ? nil : LineRange(symbols.map(\.lines.start).min()!, symbols.map(\.lines.end).max()!)
            return AskFile(
                path: hit.path,
                relevance: hit.relevance,
                reason: hit.reasons.isEmpty ? "matches " + hit.matchedTerms.prefix(3).joined(separator: ", ") : hit.reasons.joined(separator: "; "),
                symbols: symbols,
                lines: span,
                dependents: hit.fanIn,
                dependencies: hit.fanOut
            )
        }
        return AskResult(
            query: question,
            intent: QueryIntent.search.rawValue,
            answer: Self.synthesizeAnswer(question: question, hits: outcome.hits),
            terms: Array(outcome.terms.prefix(12)),
            files: files,
            related: outcome.related.isEmpty ? nil : outcome.related,
            confidence: files.first?.relevance ?? 0
        )
    }

    static func synthesizeAnswer(question: String, hits: [SearchHit]) -> String {
        guard let top = hits.first else {
            return "No indexed code clearly matches this question. Try naming a type, file or feature word used in the code."
        }
        var sentence = "Most likely in \(top.path)"
        if !top.symbols.isEmpty {
            sentence += " (" + top.symbols.prefix(2).map { $0.qualifiedName }.joined(separator: ", ") + ")"
        }
        sentence += "."
        // Where do the strong results cluster?
        let strong = hits.prefix(6).filter { $0.relevance >= 0.35 }
        var directories: [String: Int] = [:]
        for hit in strong {
            let directory = (hit.path as NSString).deletingLastPathComponent
            if !directory.isEmpty { directories[directory, default: 0] += 1 }
        }
        if let (directory, count) = directories.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }), count >= 2 {
            sentence += " Related code is concentrated in \(directory)/ (\(count) of the top results)."
        }
        let others = hits.dropFirst().prefix(2).filter { $0.relevance >= 0.3 }.map(\.path)
        if !others.isEmpty {
            sentence += " Also relevant: " + others.joined(separator: ", ") + "."
        }
        if top.relevance < 0.7 {
            sentence += " No file matches the question directly; these are the closest related matches."
        }
        return sentence
    }

    private func structuralAnswer(parsed: ParsedQuery, subject: String, limit: Int) throws -> AskResult {
        func file(_ relation: FileRelation, relevance: Double, reason: String) -> AskFile {
            AskFile(path: relation.path, relevance: (relevance * 100).rounded() / 100, reason: reason, symbols: [], lines: nil)
        }
        switch parsed.intent {
        case .dependents, .impact:
            let impact = try impact(of: subject, depth: 4)
            let direct = impact.directDependents.prefix(limit).map { relation in
                file(relation, relevance: 1, reason: Self.relationReason(relation, verb: "uses"))
            }
            let transitive = impact.transitiveDependents.filter { ($0.distance ?? 2) > 1 }.prefix(max(0, limit - direct.count)).map { relation in
                file(relation, relevance: max(0.3, 1 - 0.2 * Double((relation.distance ?? 2) - 1)), reason: "depends on it indirectly (\(relation.distance ?? 2) hops)")
            }
            let answer = parsed.intent == .impact
                ? impact.summary
                : "\(impact.directDependents.count) file\(impact.directDependents.count == 1 ? "" : "s") depend directly on \(impact.target) and \(impact.transitiveDependents.count) transitively."
            return AskResult(query: parsed.original, intent: parsed.intent.rawValue, answer: answer, terms: [subject], files: Array(direct) + transitive, related: nil, confidence: 1)
        case .dependencies:
            let result = try dependencies(of: subject, depth: 2, limit: limit * 2)
            let files = result.files.prefix(limit).map { relation in
                file(relation, relevance: relation.distance == 1 ? 1 : 0.6, reason: Self.relationReason(relation, verb: "provides"))
            }
            let directCount = result.files.filter { $0.distance == 1 }.count
            var answer = "\(result.target) depends on \(directCount) repository \(directCount == 1 ? "file" : "files")"
            if let external = result.externalModules, !external.isEmpty { answer += " and \(external.count) external \(external.count == 1 ? "module" : "modules"): \(external.prefix(6).joined(separator: ", "))" }
            return AskResult(query: parsed.original, intent: parsed.intent.rawValue, answer: answer + ".", terms: [subject], files: Array(files), related: nil, confidence: 1)
        case .references, .callers:
            let references = try references(subject, limit: 200)
            var byFile: [String: (count: Int, lines: [Int], from: Set<String>)] = [:]
            for site in references.references where parsed.intent == .references || [.call, .instantiate, .decorator].contains(site.kind) {
                var entry = byFile[site.path] ?? (0, [], [])
                entry.count += site.count ?? 1
                entry.lines.append(site.line)
                if let from = site.from { entry.from.insert(from) }
                byFile[site.path] = entry
            }
            let maxCount = Double(byFile.values.map(\.count).max() ?? 1)
            let files = byFile.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.prefix(limit).map { path, entry in
                AskFile(
                    path: path,
                    relevance: ((0.5 + 0.5 * Double(entry.count) / maxCount) * 100).rounded() / 100,
                    reason: "\(entry.count) use\(entry.count == 1 ? "" : "s")" + (entry.from.isEmpty ? "" : " in " + entry.from.sorted().prefix(3).joined(separator: ", ")),
                    symbols: [],
                    lines: LineRange(entry.lines.min()!, entry.lines.max()!)
                )
            }
            let name = references.symbols.first?.qualifiedName ?? subject
            let answer = "\(name) is \(parsed.intent == .callers ? "called" : "used") in \(byFile.count) file\(byFile.count == 1 ? "" : "s") (\(references.total) reference site\(references.total == 1 ? "" : "s"))."
            return AskResult(query: parsed.original, intent: parsed.intent.rawValue, answer: answer, terms: [subject], files: Array(files), related: nil, confidence: references.symbols.isEmpty ? 0.5 : 1)
        case .callees:
            let result = try callees(subject, limit: limit * 3)
            var byFile: [String: [CallRelation]] = [:]
            for relation in result.relations { byFile[relation.symbol.path, default: []].append(relation) }
            let files = byFile.sorted { $0.value.count > $1.value.count }.prefix(limit).map { path, relations in
                AskFile(path: path, relevance: 1, reason: "called: " + relations.prefix(4).map(\.symbol.qualifiedName).joined(separator: ", "), symbols: relations.prefix(4).map { AskSymbol(name: $0.symbol.qualifiedName, kind: $0.symbol.kind, lines: $0.symbol.lines) })
            }
            return AskResult(query: parsed.original, intent: parsed.intent.rawValue, answer: "\(subject) calls \(result.relations.count) repository \(result.relations.count == 1 ? "symbol" : "symbols") across \(byFile.count) \(byFile.count == 1 ? "file" : "files").", terms: [subject], files: Array(files), related: nil, confidence: 1)
        case .search:
            throw EngineError.invalidQuery("not structural")
        }
    }

    static func relationReason(_ relation: FileRelation, verb: String) -> String {
        let kinds = relation.kinds.map(\.rawValue).joined(separator: "/")
        if let symbols = relation.symbols, !symbols.isEmpty {
            return "\(kinds): \(symbols.prefix(4).joined(separator: ", "))"
        }
        return kinds.isEmpty ? verb : kinds
    }

    // MARK: - Files & symbols

    /// Fuzzy file search (command-palette quality): `authsvc` finds `AuthService.swift`.
    public func searchFiles(_ query: String, limit: Int = 20) throws -> [FileHit] {
        let cache = try graphCache()
        let parts = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return cache.ordered.sorted { $0.centrality > $1.centrality }.prefix(limit).map { FileHit(path: $0.path, language: $0.language, score: $0.centrality) }
        }
        var scored: [(GraphCache.FileNode, Double)] = []
        for node in cache.ordered {
            var total = 0.0
            var ok = true
            for part in parts {
                guard let score = FuzzyMatcher.score(part, node.path) else { ok = false; break }
                total += score
            }
            guard ok else { continue }
            total += node.centrality * 3
            if node.isTest { total -= 2 }
            if node.isGenerated { total -= 6 }
            scored.append((node, total))
        }
        let top = scored.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(limit)
        let best = max(top.first?.1 ?? 1, 1)
        return top.map { node, score in
            FileHit(path: node.path, language: node.language, score: (max(0, score / best) * 100).rounded() / 100, reason: node.module.map { "module \($0)" })
        }
    }

    /// Symbol search: exact, prefix, word and fuzzy (CamelCase abbreviation) matches, types first.
    public func searchSymbols(_ query: String, kinds: Set<SymbolKind>? = nil, limit: Int = 30) throws -> [SymbolHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let db = try db
        var scores: [Int64: Double] = [:]
        var rows: [Int64: SymbolRow] = [:]
        func add(_ found: [SymbolRow], _ score: Double) {
            for row in found {
                if let kinds, !kinds.contains(row.kind) { continue }
                if row.kind == .extension && kinds == nil { continue }
                rows[row.id] = row
                scores[row.id] = max(scores[row.id] ?? 0, score)
            }
        }
        add(try symbolRows(where: "s.name = ?", [trimmed]), 1.0)
        add(try symbolRows(where: "s.qualified_name = ? COLLATE NOCASE", [trimmed]), 0.98)
        // A different-case exact match ("auth" for "Auth") is weaker than a type prefix match when the
        // query's capitalisation signals a type name.
        let queryLooksLikeType = trimmed.first?.isUppercase ?? false
        for row in try symbolRows(where: "s.name = ? COLLATE NOCASE", [trimmed]) {
            let sameInitialCase = row.name.first?.isUppercase == trimmed.first?.isUppercase
            add([row], sameInitialCase || !queryLooksLikeType ? 0.95 : 0.7)
        }
        add(try symbolRows(where: "s.name LIKE ? ESCAPE '\\'", [Self.likeEscape(trimmed) + "%"], limit: 300), 0.8)
        add(try symbolRows(where: "s.qualified_name LIKE ? ESCAPE '\\'", ["%" + Self.likeEscape(trimmed)], limit: 200), 0.75)
        if scores.count < limit {
            add(try symbolRows(where: "s.name LIKE ? ESCAPE '\\'", ["%" + Self.likeEscape(trimmed) + "%"], limit: 400), 0.6)
        }
        if scores.count < limit {
            let words = Tokenizer.splitIdentifier(trimmed).filter { $0.count >= 2 }
            if !words.isEmpty {
                let match = words.map { "\"\($0)\"*" }.joined(separator: " AND ")
                let ids = try db.query("SELECT rowid FROM fts_symbols WHERE fts_symbols MATCH ? LIMIT 200", ["{name words} : (\(match))"], cache: false) { $0.int64(0) }
                if !ids.isEmpty { add(try symbolRows(where: "s.id IN (\(ids.sqlList))", [], limit: 200), 0.5) }
            }
        }
        if scores.count < limit && trimmed.count >= 2 && trimmed.count <= 8 && !trimmed.contains(" ") {
            // CamelCase abbreviation: "BF" → BookFormatter.
            let first = String(trimmed.prefix(1))
            let candidates = try symbolRows(where: "s.name LIKE ? AND s.depth <= 1", [first + "%"], limit: 3000)
            let pattern = trimmed.lowercased()
            for row in candidates {
                let initials = Tokenizer.splitIdentifier(row.name).compactMap(\.first).map(String.init).joined()
                if initials.hasPrefix(pattern) { add([row], 0.55) } else if let fuzzy = FuzzyMatcher.score(trimmed, row.name), fuzzy > Double(trimmed.count) * 4 { add([row], 0.35) }
            }
        }
        let referenceCounts = try referenceCounts(Array(scores.keys.sorted { scores[$0]! > scores[$1]! }.prefix(150)))
        return scores.keys
            .compactMap { id -> SymbolHit? in
                guard let row = rows[id] else { return nil }
                let refs = referenceCounts[id] ?? 0
                let typeBonus = row.kind.isType ? 0.04 : 0
                let score = min(1, scores[id]! + typeBonus + min(0.05, Double(refs) * 0.002) - Double(row.depth) * 0.01)
                return SymbolHit(symbol: row.summary(references: refs), score: (score * 100).rounded() / 100)
            }
            .sorted { $0.score == $1.score ? $0.symbol.qualifiedName < $1.symbol.qualifiedName : $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func referenceCounts(_ ids: [Int64]) throws -> [Int64: Int] {
        guard !ids.isEmpty else { return [:] }
        var counts: [Int64: Int] = [:]
        try db.forEach("SELECT target_symbol_id, SUM(count) FROM refs WHERE target_symbol_id IN (\(ids.sqlList)) AND confidence >= 0.35 GROUP BY target_symbol_id") { row in
            counts[row.int64(0)] = row.int(1)
        }
        return counts
    }

    static func likeEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// Mixed results for the command palette: files, symbols, diagnostics and architecture concepts.
    public func search(_ query: String, limit: Int = 8) throws -> UnifiedSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let files = try searchFiles(trimmed, limit: limit)
        let symbols = try searchSymbols(trimmed, limit: limit + 4)
        let pattern = "%" + Self.likeEscape(trimmed) + "%"
        let diagnostics = trimmed.count >= 3 ? try diagnosticRows(where: "(d.title LIKE ? ESCAPE '\\' OR d.summary LIKE ? ESCAPE '\\' OR d.rule LIKE ? ESCAPE '\\')", [pattern, pattern, pattern], limit: 5) : []
        let concepts = trimmed.count >= 3 ? (try architecture()).patterns.filter { $0.name.localizedCaseInsensitiveContains(trimmed) || $0.evidence.contains { $0.localizedCaseInsensitiveContains(trimmed) } } : []
        return UnifiedSearchResults(query: trimmed, files: files, symbols: symbols, diagnostics: diagnostics, concepts: concepts)
    }
}
