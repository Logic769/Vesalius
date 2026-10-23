import Foundation
import RepositoryIndex
import VesaliusCore

/// The property view: a property's writes and reads.
///
/// - Files that use the owner type are listed with how they obtain it (`via`), then their reads and writes of
///   the property by enclosing declaration; `$x` and `\.x` forms are marked. With `change`, owner users that do not
///   touch the property are listed too, on one line each (OWNER USERS).
/// - The declaring file is summarised on one line: `reads ·86 showsUpgrade … | writes ·96 init …`.
/// - A head line counts the owner's users: `PremiumStore is used by 4 files; 3 read isSubscribed`.
extension UsageBuilder {
    func propertyView(_ group: DeclarationGroup, symbol: UsageSymbolInfo, change: UsageChange?) throws -> UsagesResult {
        let ids = group.ids
        let all = try rows(targeting: ids)
        let declaringFiles = Set(group.rows.map(\.fileID))
        try loadFiles(Set(all.map(\.fileID)).union(declaringFiles))
        try loadSymbols(all.compactMap(\.fromSymbolID))
        let owner = try ancestors(of: symbol.id).first { $0.kind.isType || $0.kind == .extension }

        // Uses outside the declaring file, each file with its owner-type `via` line.
        let elsewhere = all.filter { !declaringFiles.contains($0.fileID) }
        var files = try siteFiles(elsewhere, primaryPerGroup: { $0.isScript ? 3 : 1 }, consumers: true)
        for index in files.indices {
            let rows = elsewhere.filter { file($0.fileID)?.path == files[index].path }
            let reads = rows.contains { !$0.isWrite }, writes = rows.contains(where: \.isWrite)
            files[index].labels.append([reads ? "reads" : nil, writes ? "writes" : nil].compactMap { $0 }.joined(separator: ", "))
            // Declarations that write first, then those that only read; each in line order.
            files[index].groups.sort { a, b in
                let wa = a.sites.contains { $0.kind == ReferenceKind.write.rawValue } ? 0 : 1
                let wb = b.sites.contains { $0.kind == ReferenceKind.write.rawValue } ? 0 : 1
                return wa != wb ? wa < wb : (a.sites.first?.line ?? 0) < (b.sites.first?.line ?? 0)
            }
        }

        var notes: [String] = []
        var ownerLine: String?
        if let owner, owner.kind.isType || owner.kind == .extension {
            let typeGroup = try ownerTypeIDs(owner)
            let users = try ownerUsers(typeIDs: typeGroup.ids, memberIDs: try memberIDs(ofType: typeGroup.symbol, ids: typeGroup.ids), excludingFiles: declaringFiles)
            let touching = Set(elsewhere.map(\.fileID))
            for user in users {
                guard let info = file(user.fileID) else { continue }
                if let index = files.firstIndex(where: { $0.path == info.path }) {
                    files[index].via = user.via.flatMap { viaLine($0, path: info.path) }
                } else if change != nil, !touching.contains(user.fileID) {
                    var entry = UsageFile(path: info.path, isTest: info.isTest, testKind: info.testKind, labels: fileLabels(info, sites: []))
                    var used = try usedMemberNames(user.rows, ownerIDs: Set(typeGroup.ids), ownerName: typeGroup.symbol.name)
                    if used.isEmpty { used = [typeGroup.symbol.name] }
                    entry.note = "uses " + used.prefix(6).joined(separator: ", ") + (used.count > 6 ? ", +\(used.count - 6)" : "") + "; not " + symbol.name
                    files.append(entry)
                }
            }
            let verb = Set(elsewhere.filter(\.isWrite).map(\.fileID)).isEmpty ? "read" : "use"
            let line = "\(typeGroup.symbol.name) is used by \(users.count) \(users.count == 1 ? "file" : "files"); \(touching.count) \(verb) \(symbol.name)"
            ownerLine = line
            notes.append(line)
        }
        files = orderFiles(files)

        // The declaring file on one line.
        let here = all.filter { declaringFiles.contains($0.fileID) }
        var declaring: UsageDeclaringFile?
        if !here.isEmpty, let path = file(symbol.fileID)?.path {
            func entries(_ rows: [UsageRow]) -> [UsageCaller] {
                rows.sorted { $0.line < $1.line }.map { row in
                    UsageCaller(name: self.symbol(row.fromSymbolID).map { callerName($0, relativeTo: symbol) } ?? "(top level)", line: row.line, conditions: row.conditions)
                }
            }
            declaring = UsageDeclaringFile(path: path, reads: entries(here.filter { !$0.isWrite }), writes: entries(here.filter(\.isWrite)))
        }

        let writes = all.filter(\.isWrite).count
        let fileIDs = Array(Set(all.map(\.fileID))).sorted { (file($0)?.path ?? "") < (file($1)?.path ?? "") }
        let perFile = Dictionary(grouping: all, by: \.fileID).mapValues(\.count)
        let (split, byTarget) = split(fileIDs, counts: perFile)
        var extra = ["\(writes) \(writes == 1 ? "write" : "writes"), \(all.count - writes) \(all.count - writes == 1 ? "read" : "reads")"]
        let projected = all.filter { $0.form == ReferenceContext.projected.rawValue || $0.form == ReferenceContext.keypath.rawValue }.count
        if projected > 0 { extra.append("\(projected) as $\(symbol.name) or \\.\(symbol.name)") }

        let (completeness, check) = try completeness(of: symbol.name, targets: Set(ids), isMember: symbol.parentID != nil)
        var result = UsagesResult(
            view: .property, target: try engine.exactTarget(for: group), change: change,
            header: try declarationHeader(symbol, group: group),
            totals: UsageTotals(noun: "use", count: all.count, files: fileIDs.count, split: split, splitByTarget: byTarget, extra: extra),
            completeness: completeness, notes: notes, files: files, declaringFile: declaring)
        result.footers = try lookalikeFooters(ids: ids)
        if let change {
            result.sections = try changeSections(change, symbol: symbol, group: group, rows: all, check: check, completeness: completeness)
            result.sections?.ownerUsers = ownerLine
        }
        return result
    }

    /// The owner type of a member as a declaration group: an extension stands for the type it extends.
    func ownerTypeIDs(_ owner: UsageSymbolInfo) throws -> (symbol: UsageSymbolInfo, ids: [Int64]) {
        guard owner.kind == .extension else { return (owner, [owner.id]) }
        let types = try symbols(where: "s.qualified_name = ? AND s.kind != 'extension'", [owner.qualifiedName])
        guard let first = types.first else { return (owner, [owner.id]) }
        return (first, types.filter { $0.fileID == first.fileID }.map(\.id))
    }

    /// The owner's members a file uses (direct children: `Copy`, `monthlyID`, `Plan`), most used first.
    func usedMemberNames(_ rows: [UsageRow], ownerIDs: Set<Int64>, ownerName: String) throws -> [String] {
        var counts: [String: Int] = [:]
        var first: [String: Int] = [:]
        for row in rows where !ownerIDs.contains(row.targetSymbolID ?? -1) {
            let name = try memberName(row, typeIDs: ownerIDs)
            counts[name, default: 0] += 1
            if first[name] == nil { first[name] = row.line }
        }
        return counts.keys.sorted { (counts[$0] ?? 0, -(first[$0] ?? 0)) > (counts[$1] ?? 0, -(first[$1] ?? 0)) }
    }
}
