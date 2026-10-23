import Foundation
import RepositoryIndex
import VesaliusCore

/// The callers view: a function's call sites grouped by file, then by calling declaration.
///
/// - Each caller is headed by its signature, range, `#if` condition and the first sentence of its doc (or its
///   type's); its first site prints the whole statement with the condition that governs it, the others one line.
/// - With 10 callers or fewer, each caller also lists who calls it (one hop, at most 3).
/// - References that are not calls (the method passed as a value) are grouped apart.
/// - The header carries the signature with attributes, the declaration's range, kind and build targets.
extension UsageBuilder {
    /// One hop of callers is added when there are at most this many callers.
    static let calledByLimit = 10

    func callersView(_ group: DeclarationGroup, symbol: UsageSymbolInfo, change: UsageChange?) throws -> UsagesResult {
        let ids = group.ids
        let all = try rows(targeting: ids)
        try loadFiles(Set(all.map(\.fileID)).union([symbol.fileID]))
        try loadSymbols(all.compactMap(\.fromSymbolID))

        // Totals: callers are the calling declarations (top-level code counts once per file).
        var callersPerFile: [Int64: Int] = [:]
        var callerFiles: [Int64] = []
        var seen = Set<String>()
        for row in all where row.isCall {
            let key = "\(row.fileID)|\(row.fromSymbolID.map(String.init) ?? "-")"
            guard seen.insert(key).inserted else { continue }
            if callersPerFile[row.fileID] == nil { callerFiles.append(row.fileID) }
            callersPerFile[row.fileID, default: 0] += 1
        }
        let callers = callersPerFile.values.reduce(0, +)
        let calledBy = callers <= Self.calledByLimit ? try oneHop(callerIDs: Set(all.filter(\.isCall).compactMap(\.fromSymbolID))) : [:]
        let files = orderFiles(try siteFiles(all, primaryPerGroup: { $0.isScript ? 3 : 1 }, consumers: true, calledBy: calledBy))

        let calls = all.filter(\.isCall).count
        let (split, byTarget) = split(callerFiles, counts: callersPerFile)
        var extra: [String] = []
        if calls != callers { extra.append("\(calls) call sites") }
        let references = all.count - calls
        if references > 0 { extra.append("\(references) \(references == 1 ? "reference" : "references") that \(references == 1 ? "is" : "are") not a call") }

        let (completeness, check) = try completeness(of: symbol.name, targets: Set(ids), isMember: symbol.parentID != nil)
        var result = UsagesResult(
            view: .callers, target: try engine.exactTarget(for: group), change: change,
            header: try declarationHeader(symbol, group: group),
            totals: UsageTotals(noun: "caller", count: callers, files: callerFiles.count, split: split, splitByTarget: byTarget, extra: extra),
            completeness: completeness, notes: try ownerNote(symbol).map { [$0] } ?? [], files: files)
        result.footers = try lookalikeFooters(ids: ids)
        if let change {
            result.sections = try changeSections(change, symbol: symbol, group: group, rows: all, check: check, completeness: completeness)
        }
        return result
    }

    // MARK: Files and groups

    /// Sites grouped by file, then by enclosing declaration (calls before other references), in line order. The
    /// first `primaryPerGroup` sites of a group carry their statement; the rest one line each. `calledBy` holds
    /// the one-hop callers of each enclosing declaration.
    func siteFiles(_ rows: [UsageRow], primaryPerGroup: (UsageFileInfo) -> Int, consumers: Bool, calledBy: [Int64: [UsageCaller]] = [:],
                   showConditions: Bool = true) throws -> [UsageFile] {
        var byFile: [Int64: [UsageRow]] = [:]
        var fileOrder: [Int64] = []
        for row in rows {
            if byFile[row.fileID] == nil { fileOrder.append(row.fileID) }
            byFile[row.fileID, default: []].append(row)
        }
        var statementsLeft = Self.statementBudget
        var result: [UsageFile] = []
        for fileID in fileOrder {
            guard let info = file(fileID), let fileRows = byFile[fileID] else { continue }
            let fileCondition = Self.sharedCondition(fileRows.map(\.conditions))
            var groups: [UsageGroup] = []
            var typeDocs = Set<String>()
            for isCall in [true, false] {
                var order: [Int64?] = []
                var byOwner: [Int64?: [UsageRow]] = [:]
                for row in fileRows.filter({ $0.isCall == isCall }).sorted(by: { ($0.line, $0.column) < ($1.line, $1.column) }) {
                    if byOwner[row.fromSymbolID] == nil { order.append(row.fromSymbolID) }
                    byOwner[row.fromSymbolID, default: []].append(row)
                }
                for owner in order {
                    var group = try enclosingGroup(owner, path: info.path, fileCondition: fileCondition, showConditions: showConditions)
                    // A type's doc is said once per file.
                    if group.isTypeDoc, let doc = group.doc, !typeDocs.insert(doc).inserted { group.doc = nil }
                    group.isReferenceOnly = !isCall
                    let primaries = primaryPerGroup(info)
                    group.sites = (byOwner[owner] ?? []).enumerated().map { index, row in
                        let primary = index < primaries && statementsLeft > 0
                        if primary { statementsLeft -= 1 }
                        return site(row, path: info.path, primary: primary, consumer: consumers)
                    }
                    if isCall, let owner, let callers = calledBy[owner] {
                        group.calledBy = Array(callers.prefix(3))
                        group.calledByMore = max(0, callers.count - 3)
                    }
                    if info.isScript, let owner {
                        group.inFileCallers = try inFileCallers(of: owner)
                    }
                    groups.append(group)
                }
            }
            result.append(UsageFile(path: info.path, isTest: info.isTest, testKind: info.testKind, labels: fileLabels(info, sites: fileRows), groups: groups))
        }
        return result
    }

    /// The heading data of the declaration that encloses some sites; nil `owner` is the file's top level.
    func enclosingGroup(_ owner: Int64?, path: String, fileCondition: String?, showConditions: Bool = true) throws -> UsageGroup {
        guard let owner, let symbol = symbol(owner) else { return UsageGroup() }
        var group = UsageGroup(declaration: Statement.elide(heading(symbol, attributes: true), to: 120, keeping: nil), lines: symbol.lines)
        if showConditions, let conditions = symbol.conditions, !conditions.isEmpty, conditions != fileCondition {
            group.conditions = conditions
        }
        if let doc = try doc(for: symbol) {
            group.doc = doc.text
            group.isTypeDoc = doc.isTypeDoc
        }
        group.route = try route(for: symbol, path: path)
        return group
    }

    /// One site: a primary one with its statement, governing condition and (for assigned results) the statement
    /// that consumes it; a secondary one with its line.
    func site(_ row: UsageRow, path: String, primary: Bool, consumer withConsumer: Bool, condition withCondition: Bool = true) -> UsageSite {
        var site = UsageSite(line: row.line, column: row.column, kind: row.kind, form: row.form, basis: row.basis, conditions: row.conditions, isPrimary: primary)
        if primary {
            let (code, condition) = statement(row, path: path, withCondition: withCondition)
            site.code = code
            site.condition = condition
            if withConsumer { site.consumer = consumer(row, path: path) }
        }
        if site.code.isEmpty, let line = lineText(row, path: path) {
            site.code = [line]
        }
        return site
    }

    /// `LibraryService (owner type) is used by 8 other files`: how widely a member's type is used.
    func ownerNote(_ symbol: UsageSymbolInfo) throws -> String? {
        guard let owner = try ancestors(of: symbol.id).first(where: { $0.kind.isType || $0.kind == .extension }) else { return nil }
        let typeGroup = try ownerTypeIDs(owner)
        let ids = typeGroup.ids + (try memberIDs(ofType: typeGroup.symbol, ids: typeGroup.ids))
        var files = Set<Int64>()
        for chunk in Self.chunks(ids) {
            try db.forEach("SELECT DISTINCT file_id FROM refs WHERE target_symbol_id IN (\(chunk.sqlList)) AND confidence >= ? AND file_id != ?",
                           [threshold, typeGroup.symbol.fileID]) { files.insert($0.int64(0)) }
        }
        let count = files.count
        return "\(typeGroup.symbol.name) (owner type) is used by \(count) other \(count == 1 ? "file" : "files")"
    }

    // MARK: One hop

    /// For each declaration in `callerIDs`: who calls it (a read, for a property), same file first, then by
    /// path and line; recursion left out.
    func oneHop(callerIDs: Set<Int64>) throws -> [Int64: [UsageCaller]] {
        guard !callerIDs.isEmpty else { return [:] }
        let list = Array(callerIDs).sqlList
        let hops = try rows(where: """
            r.target_symbol_id IN (\(list)) AND r.confidence >= ? AND (r.kind IN ('call','instantiate','decorator')
              OR (r.kind = 'read' AND r.target_symbol_id IN (SELECT id FROM symbols WHERE id IN (\(list)) AND kind IN ('property','variable'))))
            """, [threshold])
        try loadFiles(hops.map(\.fileID))
        try loadSymbols(hops.compactMap(\.fromSymbolID))
        var result: [Int64: [UsageCaller]] = [:]
        var byCallee: [Int64: [UsageRow]] = [:]
        for hop in hops where hop.fromSymbolID != hop.targetSymbolID {
            if let callee = hop.targetSymbolID { byCallee[callee, default: []].append(hop) }
        }
        for (calleeID, hopRows) in byCallee {
            guard let callee = symbol(calleeID) else { continue }
            let sorted = hopRows.sorted { a, b in
                let sa = a.fileID == callee.fileID ? 0 : 1, sb = b.fileID == callee.fileID ? 0 : 1
                return sa != sb ? sa < sb : (file(a.fileID)?.path ?? "", a.line) < (file(b.fileID)?.path ?? "", b.line)
            }
            var seen = Set<String>()
            var callers: [UsageCaller] = []
            for hop in sorted {
                let name = hop.fromSymbolID.flatMap { symbol($0) }.map { callerName($0, relativeTo: callee) } ?? "(top level)"
                let path = hop.fileID == callee.fileID ? nil : file(hop.fileID)?.path
                guard seen.insert(name + "|" + (path ?? "")).inserted else { continue }
                callers.append(UsageCaller(name: name, path: path, line: hop.line, conditions: hop.conditions))
            }
            result[calleeID] = callers
        }
        return result
    }

    /// A non-exported TypeScript or Python helper's callers in its own file (`← loadToken :41`), following
    /// further non-exported helpers up to 2 steps.
    func inFileCallers(of owner: Int64) throws -> [UsageCaller] {
        var chain: [UsageCaller] = []
        var current = owner
        for _ in 0..<2 {
            guard let symbol = symbol(current), symbol.depth == 0, !symbol.isExported, symbol.kind.isCallable else { break }
            let hops = try rows(where: "r.target_symbol_id = ? AND r.file_id = ? AND r.kind = 'call' AND r.from_symbol_id IS NOT NULL AND r.from_symbol_id != ? ORDER BY r.line LIMIT 3",
                                [current, symbol.fileID, current])
            try loadSymbols(hops.compactMap(\.fromSymbolID))
            guard let first = hops.first, let caller = self.symbol(first.fromSymbolID) else { break }
            chain.append(UsageCaller(name: displayName(caller), line: first.line))
            current = caller.id
        }
        return chain
    }

    // MARK: Header

    /// Line 1 for a declaration: its signature with attributes (callables as `Owner.selector` plus effects and
    /// return type), its range, what it is, the build targets that compile it, and its `#if` condition.
    func declarationHeader(_ symbol: UsageSymbolInfo, group: DeclarationGroup) throws -> UsageHeader {
        try loadFiles([symbol.fileID])
        let info = file(symbol.fileID)
        var title: String
        var named = false
        if symbol.kind.isCallable, symbol.language == .swift {
            title = heading(symbol, attributes: true, tail: true)
            named = true
        } else if let signature = symbol.signature.map(Self.oneLine), !signature.isEmpty {
            title = Statement.elide(signature, to: 140, keeping: nil)
            // A member's signature names only itself: lead with the qualified name.
            if symbol.qualifiedName != symbol.name, !signature.contains(symbol.qualifiedName) {
                title = symbol.qualifiedName + "  " + title
                named = true
            }
        } else {
            title = symbol.qualifiedName
            named = true
        }
        var kind = symbol.kind.displayName
        if !named, let parent = try ancestors(of: symbol.id).first, parent.kind.isType || parent.kind == .extension {
            kind += " of " + parent.qualifiedName
        }
        if group.rows.count > 1 { kind += " (\(group.rows.count) #if variants)" }
        return UsageHeader(title: title, path: info?.path ?? group.first.path, lines: symbol.lines, kind: kind, buildTargets: info?.targets ?? [],
                           membership: try membershipNote(info), conditions: symbol.conditions)
    }

    /// How a file came into its targets, when that is worth saying: an exception that adds it to another target's
    /// synchronized folder, or a classic build phase.
    func membershipNote(_ info: UsageFileInfo?) throws -> String? {
        guard let info else { return nil }
        if let exception = try db.queryOne("SELECT evidence_path, evidence_line FROM file_targets WHERE file_id = ? AND via = 'exception-add' ORDER BY evidence_line LIMIT 1", [info.id], { row in
            row.optionalString(0).map { path in row.optionalInt(1).map { "\(path):\($0)" } ?? path }
        }), let evidence = exception {
            return "membership exception, " + evidence
        }
        return nil
    }

    // MARK: Footers

    /// `rejected lookalikes:` sites the linker resolved elsewhere (or outside the repository) that a unique-name
    /// guess would have bound to the target.
    func lookalikeFooters(ids: [Int64]) throws -> [UsageFooter] {
        guard !ids.isEmpty else { return [] }
        var items: [String] = []
        var total = 0
        for chunk in Self.chunks(ids) {
            let rows = try rows(where: "r.alt_symbol_id IN (\(chunk.sqlList)) AND (r.target_symbol_id IS NULL OR r.target_symbol_id NOT IN (\(chunk.sqlList)))")
            try loadFiles(rows.map(\.fileID))
            try loadSymbols(rows.compactMap(\.targetSymbolID))
            for row in rows.sorted(by: { (file($0.fileID)?.path ?? "", $0.line) < (file($1.fileID)?.path ?? "", $1.line) }) {
                total += 1
                guard items.count < 5, let path = file(row.fileID)?.path else { continue }
                let expression = (row.receiver.map { $0 + "." } ?? "") + row.name
                let why = Self.lookalikeReason(row, resolved: symbol(row.targetSymbolID))
                items.append("\((path as NSString).lastPathComponent):\(row.line) \(expression)" + (why.map { " (\($0))" } ?? ""))
            }
        }
        return items.isEmpty ? [] : [UsageFooter(kind: .rejectedLookalikes, items: items, more: total - items.count)]
    }

    /// Why a lookalike is not the target: its receiver's type, its module, or the declaration it resolved to.
    static func lookalikeReason(_ row: UsageRow, resolved: UsageSymbolInfo?) -> String? {
        if resolved?.isLocal == true { return "local type" + (row.receiverType.map { " " + $0 } ?? "") }
        if let type = row.receiverType, type != "(tuple)" { return type }
        if row.receiverType == "(tuple)" { return "tuple element" }
        if let module = row.externalModule { return module }
        if let resolved { return resolved.isLocal ? "local type" : resolved.qualifiedName }
        return nil
    }
}
