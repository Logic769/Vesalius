import Foundation
import RepositoryIndex
import VesaliusCore

/// The type view: the files that use a type, each with how it obtains the type (`via`) and the
/// members it uses, with lines.
///
/// - The member set is the type's declarations plus those of its extensions (same qualified name, same module).
/// - The `via` line is the first of: a property whose annotation names the type, a property initialised with an
///   instance or a static member of it, a parameter annotation, the line that typed a receiver, the first use.
/// - Totals count uses of the type's name (the rows the completeness line reconciles); files that reach it only
///   through members are counted apart (`by type flow`).
/// - Other declarations with the same name are excluded, with their counts and exact target strings.
extension UsageBuilder {
    func typeView(_ group: DeclarationGroup, symbol: UsageSymbolInfo, change: UsageChange?) throws -> UsagesResult {
        let ids = group.ids
        let members = try memberIDs(ofType: symbol, ids: ids)
        let declaringFiles = Set(group.rows.map(\.fileID))
        let users = try ownerUsers(typeIDs: ids, memberIDs: members, excludingFiles: declaringFiles)

        var files: [UsageFile] = []
        var nameUses: [Int64: Int] = [:]
        var typeFlowOnly = 0
        for user in users {
            guard let info = file(user.fileID) else { continue }
            var entry = UsageFile(path: info.path, isTest: info.isTest, testKind: info.testKind, labels: fileLabels(info, sites: user.rows))
            entry.via = user.via.flatMap { viaLine($0, path: info.path) }
            entry.owners = try memberSummary(user.rows, typeIDs: Set(ids), viaLine: user.via?.line, ownerName: symbol.name)
            let named = user.rows.filter { ids.contains($0.targetSymbolID ?? -1) }.count
            if named > 0 { nameUses[user.fileID] = named } else { typeFlowOnly += 1 }
            if named == 0, let label = try typeFlowLabel(user.rows) { entry.labels.append(label) }
            files.append(entry)
        }
        files = orderFiles(files)

        let usesOfName = nameUses.values.reduce(0, +)
        let namedFiles = users.map(\.fileID).filter { nameUses[$0] != nil }
        let (split, byTarget) = split(namedFiles, counts: Dictionary(uniqueKeysWithValues: namedFiles.map { ($0, 1) }))
        var extra: [String] = []
        if typeFlowOnly > 0 { extra.append("+\(typeFlowOnly) \(typeFlowOnly == 1 ? "file uses" : "files use") it by type flow, never naming it") }
        let memberUses = users.reduce(0) { $0 + $1.rows.filter { !ids.contains($0.targetSymbolID ?? -1) }.count }
        if memberUses > 0 { extra.append("\(memberUses) member \(memberUses == 1 ? "use" : "uses")") }

        let (completeness, check) = try completeness(of: symbol.name, targets: Set(ids), isMember: false)
        var header = try declarationHeader(symbol, group: group)
        header.title = symbol.signature.map(Self.oneLine).map { Statement.elide($0, to: 140, keeping: nil) } ?? symbol.qualifiedName
        var result = UsagesResult(
            view: .type, target: try engine.exactTarget(for: group), change: change, header: header,
            totals: UsageTotals(noun: "use", count: usesOfName, files: namedFiles.count, split: split, splitByTarget: byTarget, extra: extra),
            completeness: completeness, files: files)
        result.footers = try alsoNamedFooters(symbol, group: group) + lookalikeFooters(ids: ids)
        if let change {
            result.sections = try changeSections(change, symbol: symbol, group: group, rows: users.flatMap(\.rows), check: check, completeness: completeness)
        }
        return result
    }

    // MARK: Members and users

    /// The declarations inside a type and inside its extensions (same qualified name; same module when another
    /// type has that name too), at any depth.
    func memberIDs(ofType symbol: UsageSymbolInfo, ids: [Int64]) throws -> [Int64] {
        let sameName = try db.scalarInt("SELECT COUNT(*) FROM symbols WHERE qualified_name = ? AND kind != 'extension' AND depth = ?", [symbol.qualifiedName, symbol.depth])
        let module = try db.queryOne("SELECT module_id FROM files WHERE id = ?", [symbol.fileID]) { $0.optionalInt64(0) } ?? nil
        var roots = ids
        let extensions = try db.query("""
            SELECT s.id, f.module_id FROM symbols s JOIN files f ON f.id = s.file_id WHERE s.kind = 'extension' AND s.qualified_name = ?
            """, [symbol.qualifiedName]) { ($0.int64(0), $0.optionalInt64(1)) }
        roots += extensions.filter { sameName <= 1 || $0.1 == module }.map(\.0)
        return try db.query("""
            WITH RECURSIVE d(id) AS (SELECT id FROM symbols WHERE parent_id IN (\(roots.sqlList))
              UNION SELECT s.id FROM symbols s JOIN d ON s.parent_id = d.id)
            SELECT id FROM d
            """) { $0.int64(0) }
    }

    /// One file that uses a type.
    struct OwnerUser {
        let fileID: Int64
        /// Uses of the type and its members, in line order.
        let rows: [UsageRow]
        /// The line that gives the file the type.
        let via: Via?
    }

    /// The line that gives a file a type, and the use on it (nil when the line comes from type evidence).
    struct Via {
        let line: Int
        let row: UsageRow?
    }

    /// The files (outside `excludingFiles`) with uses of the type or its members, each with its `via` row.
    func ownerUsers(typeIDs: [Int64], memberIDs: [Int64], excludingFiles: Set<Int64>) throws -> [OwnerUser] {
        let all = try rows(targeting: typeIDs + memberIDs).filter { !excludingFiles.contains($0.fileID) }
        try loadFiles(all.map(\.fileID))
        try loadSymbols(all.compactMap(\.fromSymbolID) + all.compactMap(\.targetSymbolID))
        var byFile: [Int64: [UsageRow]] = [:]
        for row in all { byFile[row.fileID, default: []].append(row) }
        let typeSet = Set(typeIDs)
        return byFile.map { fileID, rows in
            OwnerUser(fileID: fileID, rows: rows.sorted { ($0.line, $0.column) < ($1.line, $1.column) }, via: viaRow(rows, typeIDs: typeSet))
        }.sorted { (file($0.fileID)?.path ?? "") < (file($1.fileID)?.path ?? "") }
    }

    /// How a file obtains the type: a property annotated with it or initialised from it (an instance or a static
    /// member), else a parameter annotation, else the line that typed a member's receiver, else the first use.
    func viaRow(_ rows: [UsageRow], typeIDs: Set<Int64>) -> Via? {
        let names = Set(typeIDs.compactMap { symbol($0)?.name })
        func inProperty(_ row: UsageRow) -> Bool { symbol(row.fromSymbolID)?.isProperty == true }
        let ofType = rows.filter { typeIDs.contains($0.targetSymbolID ?? -1) }
        let staticReads = rows.filter { row in row.receiver.map(names.contains) == true && !typeIDs.contains(row.targetSymbolID ?? -1) }
        if let row = (ofType + staticReads).filter(inProperty).min(by: { $0.line < $1.line }) { return Via(line: row.line, row: row) }
        // A parameter: a type use on the header line of a function.
        if let row = ofType.filter({ row in
            guard let owner = symbol(row.fromSymbolID), owner.kind.isCallable else { return false }
            return row.line <= owner.lines.start + 3
        }).min(by: { $0.line < $1.line }) {
            return Via(line: row.line, row: row)
        }
        if let evidence = rows.compactMap(\.typeEvidenceLine).min() {
            return Via(line: evidence, row: rows.first { $0.line == evidence })
        }
        return ((ofType + staticReads).min { $0.line < $1.line } ?? rows.first).map { Via(line: $0.line, row: $0) }
    }

    /// The `via` line's statement, on one line.
    func viaLine(_ via: Via, path: String) -> UsageCodeLine? {
        if let row = via.row {
            let (code, _) = statement(row, path: path, withCondition: false)
            if let first = code.first {
                return code.count == 1 ? first : UsageCodeLine(line: first.line, text: Statement.elide(code.map(\.text).joined(separator: " "), to: 110, keeping: nil))
            }
            return lineText(row, path: path)
        }
        guard let statement = engine.sourceText.statement(path, line: via.line) else { return nil }
        return UsageCodeLine(line: statement.start, text: statement.text())
    }

    /// The members a file uses, by owner type: for each, its lines, kinds and the declarations they are in.
    /// Uses of the type's own name on the `via` line are left out (the via line shows them).
    func memberSummary(_ rows: [UsageRow], typeIDs: Set<Int64>, viaLine: Int?, ownerName: String) throws -> [UsageOwnerUses] {
        var order: [String] = []
        var byMember: [String: (lines: [Int], kinds: Set<String>, enclosing: [String])] = [:]
        // A type name used as the receiver of a member on the same line says nothing the member does not.
        let memberLines = Set(rows.filter { !typeIDs.contains($0.targetSymbolID ?? -1) }.map(\.line))
        for row in rows {
            let isTypeName = typeIDs.contains(row.targetSymbolID ?? -1)
            if isTypeName, row.line == viaLine || (row.isTypeUse && memberLines.contains(row.line)) { continue }
            if !isTypeName, row.line == viaLine, row.receiver.map({ $0 == ownerName }) == true { continue }
            let name = isTypeName ? ownerName : try memberName(row, typeIDs: typeIDs)
            if byMember[name] == nil { order.append(name) }
            var entry = byMember[name] ?? ([], [], [])
            entry.lines.append(row.line)
            entry.kinds.insert(row.kind)
            if let from = symbol(row.fromSymbolID) {
                let enclosing = enclosingName(from)
                if !entry.enclosing.contains(enclosing) { entry.enclosing.append(enclosing) }
            }
            byMember[name] = entry
        }
        guard !order.isEmpty else { return [] }
        return [UsageOwnerUses(owner: ownerName, members: order.map { name in
            let entry = byMember[name] ?? ([], [], [])
            return UsageMemberUse(name: name, lines: Array(Set(entry.lines)).sorted(), kinds: entry.kinds.sorted(), enclosing: entry.enclosing)
        })]
    }

    /// The member of the owner a use reaches: the owner's direct child on the used declaration's parent chain
    /// (`Tier` for `PremiumStore.Tier.Trial.lengthText`), with its selector when it is callable.
    func memberName(_ row: UsageRow, typeIDs: Set<Int64>) throws -> String {
        guard let target = symbol(row.targetSymbolID) else { return row.name }
        var child = target
        for ancestor in try ancestors(of: target.id) {
            if typeIDs.contains(ancestor.id) || ancestor.kind == .extension { break }
            child = ancestor
        }
        let name = child.kind.isCallable ? String(displayName(child).split(separator: ".").last ?? Substring(child.name)) : child.name
        return row.form == ReferenceContext.implicit.rawValue && child.id == target.id ? "." + name : name
    }

    /// `type-inferred via scanRecords → WALRecordLocation.record` for a file that never names the type: the chain
    /// of receivers that produced the first member use's receiver.
    func typeFlowLabel(_ rows: [UsageRow]) throws -> String? {
        guard let first = rows.first(where: { $0.receiverRef != nil }) else {
            return rows.contains { $0.basis == ResolutionBasis.typed.rawValue } ? "type-inferred" : nil
        }
        var chain: [String] = []
        var cursor = first.receiverRef
        var depth = 0
        while let id = cursor, depth < 6 {
            depth += 1
            guard let producer = try self.rows(where: "r.id = ?", [id]).first else { break }
            if let target = producer.targetSymbolID {
                try loadSymbols([target])
                // An instance made on the spot (`JournalReader(…)`, the call an implicit member is an argument
                // of) is where the chain starts, not a step of it.
                if let symbol = symbol(target), !symbol.kind.isType {
                    chain.insert(symbol.kind.isCallable ? symbol.name : symbol.qualifiedName, at: 0)
                }
            } else {
                chain.insert(producer.name, at: 0)
            }
            cursor = producer.receiverRef
        }
        let type = first.receiverType.map { ": " + $0 } ?? ""
        guard !chain.isEmpty else { return "type-inferred" + type }
        return "type-inferred via " + chain.joined(separator: " → ") + type
    }

    // MARK: Same-name declarations

    /// `also named` other declarations of the type's name, with their use counts and exact target strings.
    func alsoNamedFooters(_ symbol: UsageSymbolInfo, group: DeclarationGroup) throws -> [UsageFooter] {
        let others = try engine.symbolRows(where: "s.name = ? AND s.kind != 'extension' AND s.id NOT IN (\(group.ids.sqlList))", [symbol.name], limit: 50)
            .filter { symbol.kind.isType ? $0.kind.isType : true }
        guard !others.isEmpty else { return [] }
        var items: [String] = []
        for other in try engine.groupDeclarations(others).prefix(4) {
            let counts = try engine.useCounts(other.ids)
            items.append("\(try engine.exactTarget(for: other)) (\(other.first.kind.displayName), \(counts.uses) \(counts.uses == 1 ? "use" : "uses") in \(counts.files) \(counts.files == 1 ? "file" : "files"), excluded)")
        }
        return [UsageFooter(kind: .alsoNamed, items: items, more: max(0, try engine.groupDeclarations(others).count - items.count))]
    }
}
