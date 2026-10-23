import Foundation
import RepositoryIndex
import VesaliusCore

/// The sections `change: rename | signature | remove` adds, in a fixed order. WITNESS OF,
/// OVERRIDES and VIA PROTOCOL need the witness table, which is not built yet, so they are not printed.
///
/// - OWNER USERS: the result's files (the property and type views list the owner type's users).
/// - TEXT ONLY: comments, docs, strings and non-source text naming the target (a rename leaves them stale).
/// - DYNAMIC: the dynamic forms checked (`$x`, `\.x`, `"x"`) and where they occur.
/// - TESTS: see `testsSection`.
/// - ENTRY POINTS: the roots that reach the target through callers in at most 3 hops.
/// - NOT AFFECTED: other declarations of the same base name in the same type (other overloads).
/// - COVERAGE: how the occurrences of the name were resolved.
extension UsageBuilder {
    /// Hops followed up from the target's sites to find entry points.
    static let entryPointHops = 3

    func changeSections(_ change: UsageChange, symbol: UsageSymbolInfo, group: DeclarationGroup, rows: [UsageRow], check: Completeness,
                        completeness: UsageCompleteness) throws -> UsageChangeSections {
        var sections = UsageChangeSections()
        (sections.textOnly, sections.textOnlyMore) = textOnly(check)
        sections.dynamicChecked = completeness.formsChecked
        sections.dynamicHits = Self.locationItems(check.occurrences(.dynamic), detail: { $0.form.written(check.name) })
        let targetRows = rows.filter { group.ids.contains($0.targetSymbolID ?? -1) }
        sections.tests = try testsSection(symbol: symbol, group: group, rows: targetRows)
        // A rename keeps behaviour; a new signature or a removal reaches every path into the target.
        if symbol.kind.isCallable, change != .rename {
            (sections.entryPoints, sections.entryPointsMore) = try entryPoints(from: targetRows)
        }
        sections.notAffected = try notAffected(symbol, group: group)
        sections.coverage = coverage(check, indexed: targetRows.count)
        return sections
    }

    /// TEXT ONLY and COVERAGE for a file target: its declarations' names across the dependents.
    func fileChangeSections(_ change: UsageChange, declared: [UsageSymbolInfo], dependents: [UsageFile], completeness: UsageCompleteness) throws -> UsageChangeSections {
        var sections = UsageChangeSections()
        let text = completeness.textOnly.map { Completeness.Occurrence(path: $0.path, line: $0.line, column: 0, category: .comment) }
        let items = Self.locationItems(text, detail: nil)
        sections.textOnly = Array(items.prefix(8))
        sections.textOnlyMore = max(0, items.count - 8)
        sections.dynamicChecked = []
        let tests = dependents.filter(\.isTest)
        sections.tests.direct = try tests.map { file in
            UsageTestFile(path: file.path, kind: file.testKind ?? "unit", suites: try suites(inFile: file.path),
                          lines: file.owners.flatMap { $0.members.flatMap(\.lines) } + file.groups.flatMap { $0.sites.map(\.line) })
        }
        sections.tests.run = try runCommands(for: sections.tests)
        return sections
    }

    // MARK: TEXT ONLY, DYNAMIC, COVERAGE

    /// Comments, docs, strings and non-source mentions, one item per file (`PremiumStore.swift:75,219`).
    func textOnly(_ check: Completeness) -> ([String], Int) {
        let occurrences = check.occurrences(.comment, .doc, .string, .nonSource)
        let items = Self.locationItems(occurrences, detail: nil)
        return (Array(items.prefix(8)), max(0, items.count - 8))
    }

    /// `File.swift:12,40` per file, files named as briefly as they can be told apart; `detail` is appended to
    /// each line number.
    static func locationItems(_ occurrences: [Completeness.Occurrence], detail: ((Completeness.Occurrence) -> String)?) -> [String] {
        var order: [String] = []
        var lines: [String: [String]] = [:]
        for occurrence in occurrences.sorted(by: { ($0.path, $0.line) < ($1.path, $1.line) }) {
            if lines[occurrence.path] == nil { order.append(occurrence.path) }
            let item = "\(occurrence.line)" + (detail.map { " " + $0(occurrence) } ?? "")
            if lines[occurrence.path]?.contains(item) != true { lines[occurrence.path, default: []].append(item) }
        }
        let names = Completeness.shortNames(order)
        return order.map { "\(names[$0] ?? $0):\(lines[$0, default: []].joined(separator: ","))" }
    }

    /// `17 sites resolved to the target, 2 to other declarations, 0 unresolved`. A name the scan skipped (too
    /// common) or cut short has no reconciled counts: then the sites the index resolved are counted instead.
    func coverage(_ check: Completeness, indexed: Int) -> String {
        if check.notCheckedByName || check.capped {
            let why = check.notCheckedByName
                ? "not checked by name (in \(check.documentFrequency) of \(check.indexedFiles) files)"
                : "scanned in \(check.scannedFiles) of \(check.candidateFiles) files"
            return "\"\(check.name)\" \(why); \(indexed) indexed \(indexed == 1 ? "site" : "sites") resolved to the target"
        }
        let target = check.count(.target), other = check.count(.other), external = check.count(.external), unexplained = check.occurrences.filter { $0.category.isUnexplained }.count
        var parts = ["\(target) \(target == 1 ? "site" : "sites") of \"\(check.name)\" resolved to the target"]
        if other > 0 { parts.append("\(other) to other declarations") }
        if external > 0 { parts.append("\(external) outside the repository") }
        parts.append("\(unexplained) unresolved")
        return parts.joined(separator: ", ")
    }

    // MARK: NOT AFFECTED

    /// Other declarations with the target's base name in the same type or file: other overloads, which a change
    /// to this one leaves alone.
    func notAffected(_ symbol: UsageSymbolInfo, group: DeclarationGroup) throws -> [String] {
        let siblings = try symbols(where: "s.name = ? AND s.id NOT IN (\(group.ids.sqlList)) AND s.file_id = ? AND " + (symbol.parentID.map { "s.parent_id = \($0)" } ?? "s.parent_id IS NULL"),
                                   [symbol.name, symbol.fileID])
        return siblings.sorted { $0.lines.start < $1.lines.start }.map { sibling in
            "\(displayName(sibling).split(separator: ".").last.map(String.init) ?? sibling.name) :\(sibling.lines.start)"
        }
    }

    // MARK: ENTRY POINTS

    /// Roots reached from the target's sites through callers, in at most 3 hops: SwiftUI `body`, `@main`, test
    /// functions, route handlers, and declarations nothing calls.
    func entryPoints(from rows: [UsageRow]) throws -> ([UsageEntryPoint], Int) {
        var frontier = Set(rows.compactMap(\.fromSymbolID))
        try loadSymbols(frontier)
        var chains: [Int64: [String]] = [:]
        for id in frontier { chains[id] = [] }
        var visited = frontier
        var roots: [(Int64, [String])] = []
        for _ in 0..<Self.entryPointHops {
            guard !frontier.isEmpty else { break }
            let callers = try oneHopRows(frontier)
            var next = Set<Int64>()
            for id in frontier.sorted() {
                guard let symbol = symbol(id) else { continue }
                let up = callers[id] ?? []
                if try isRoot(symbol) || up.isEmpty {
                    roots.append((id, chains[id] ?? []))
                    continue
                }
                for caller in up where !visited.contains(caller) {
                    visited.insert(caller)
                    next.insert(caller)
                    chains[caller] = [displayName(symbol)] + (chains[id] ?? [])
                }
            }
            frontier = next
        }
        // What is left after the last hop is reported as reached, not as a root.
        try loadFiles(Set((roots.map(\.0) + frontier).compactMap { symbol($0)?.fileID }))
        var points: [UsageEntryPoint] = []
        var inTests = Set<String>()
        for (id, chain) in roots {
            guard let symbol = symbol(id), let info = file(symbol.fileID) else { continue }
            if info.isTest { inTests.insert(info.path) }
            points.append(UsageEntryPoint(root: try entryName(symbol, path: info.path), path: info.path, line: symbol.lines.start, via: chain))
        }
        // Production roots first (tests are listed under TESTS too), then the nearest.
        points.sort { a, b in
            let ta = inTests.contains(a.path) ? 1 : 0, tb = inTests.contains(b.path) ? 1 : 0
            return (ta, a.via.count, a.path, a.line) < (tb, b.via.count, b.path, b.line)
        }
        var seen = Set<String>()
        points = points.filter { seen.insert($0.root + "|" + $0.path).inserted }
        return (Array(points.prefix(6)), max(0, points.count - 6) + frontier.count)
    }

    /// Callers of each declaration in `ids` (calls, and reads of properties), as declaration ids.
    private func oneHopRows(_ ids: Set<Int64>) throws -> [Int64: [Int64]] {
        guard !ids.isEmpty else { return [:] }
        let list = Array(ids).sqlList
        var result: [Int64: [Int64]] = [:]
        try db.forEach("""
            SELECT DISTINCT r.target_symbol_id, r.from_symbol_id FROM refs r
            WHERE r.target_symbol_id IN (\(list)) AND r.from_symbol_id IS NOT NULL AND r.confidence >= ? AND r.from_symbol_id != r.target_symbol_id
              AND (r.kind IN ('call','instantiate','decorator') OR (r.kind = 'read' AND r.target_symbol_id IN (SELECT id FROM symbols WHERE id IN (\(list)) AND kind IN ('property','variable'))))
            """, [threshold]) { row in
            result[row.int64(0), default: []].append(row.int64(1))
        }
        try loadSymbols(result.values.flatMap { $0 })
        return result
    }

    /// SwiftUI `body`, an `@main` type's members, a test function, a route handler.
    private func isRoot(_ symbol: UsageSymbolInfo) throws -> Bool {
        if symbol.name == "body", symbol.isProperty { return true }
        if symbol.attributes?.contains("@Test") == true || (symbol.name.hasPrefix("test") && symbol.kind.isCallable) { return true }
        if RouteLabel.httpMethods.contains(symbol.name), symbol.depth == 0 { return true }
        if try ancestors(of: symbol.id).contains(where: { $0.attributes?.contains("@main") == true }) { return true }
        return symbol.attributes?.contains("@main") == true
    }

    private func entryName(_ symbol: UsageSymbolInfo, path: String) throws -> String {
        if let route = try route(for: symbol, path: path) { return route }
        return displayName(symbol)
    }
}
