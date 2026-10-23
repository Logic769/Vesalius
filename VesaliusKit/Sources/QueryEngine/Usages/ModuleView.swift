import Foundation
import RepositoryIndex
import VesaliusCore

/// The framework and environment-variable views.
///
/// - A framework (`StoreKit`, from `imports.external_name`): the files that import it with their import lines,
///   and each file's calls into it (`refs.is_external`), grouped by `Type.member` with lines.
/// - An environment variable (`env:API_KEY`): its reads and writes, each with its statement.
extension UsageBuilder {
    func frameworkView(name: String, importers: [UsageTarget.Importer]) throws -> UsagesResult {
        let external = try rows(where: "r.is_external = 1 AND r.external_module = ? ORDER BY r.file_id, r.line", [name])
        try loadFiles(external.map(\.fileID))
        let paths = Dictionary(importers.map { ($0.path, $0.line) }, uniquingKeysWith: min)
        let importerPaths = Array(paths.keys)
        var ids: [(Int64, String)] = []
        for chunk in stride(from: 0, to: importerPaths.count, by: 400) {
            let slice = Array(importerPaths[chunk..<min(importerPaths.count, chunk + 400)])
            ids += try db.query("SELECT id, path FROM files WHERE path IN (\(slice.map { _ in "?" }.joined(separator: ",")))", slice) { ($0.int64(0), $0.string(1)) }
        }
        try loadFiles(ids.map(\.0))
        var byFile = Dictionary(grouping: external, by: \.fileID)
        for (id, _) in ids where byFile[id] == nil { byFile[id] = [] }
        try loadSymbols(external.compactMap(\.fromSymbolID))

        var files: [UsageFile] = []
        for (fileID, rows) in byFile {
            guard let info = file(fileID) else { continue }
            var entry = UsageFile(path: info.path, isTest: info.isTest, testKind: info.testKind, labels: fileLabels(info, sites: rows), importLine: paths[info.path])
            if paths[info.path] == nil { entry.labels.append("no import of \(name)") }
            // Calls grouped by the framework type they go through (`Product: products 154 · purchase 315`), the
            // types used most first; a type named on its own counts as `type`. An implicit member whose contextual
            // type was not inferred (`case .success`) is listed with its dot under `implicit members`.
            var ownerOrder: [String] = []
            var members: [String: [String]] = [:]
            var uses: [String: (lines: [Int], enclosing: [String])] = [:]
            for row in rows {
                let owner: String, member: String
                if row.receiverType == nil, row.receiver == "." {
                    (owner, member) = ("implicit members", "." + row.name)
                } else {
                    let api = (row.receiverType ?? row.receiver.flatMap { $0.first?.isUppercase == true ? $0 : nil }).map { $0 + "." + row.name } ?? row.name
                    let parts = api.split(separator: ".", maxSplits: 1).map(String.init)
                    (owner, member) = (parts[0], parts.count > 1 ? parts[1] : "type")
                }
                if members[owner] == nil {
                    ownerOrder.append(owner)
                    members[owner] = []
                }
                let key = owner + "." + member
                if uses[key] == nil { members[owner, default: []].append(member) }
                var entryUse = uses[key] ?? ([], [])
                entryUse.lines.append(row.line)
                if let from = symbol(row.fromSymbolID).map({ enclosingName($0) }), !entryUse.enclosing.contains(from) { entryUse.enclosing.append(from) }
                uses[key] = entryUse
            }
            let weight = { (owner: String) in (members[owner] ?? []).reduce(0) { $0 + (uses[owner + "." + $1]?.lines.count ?? 0) } }
            ownerOrder.sort { weight($0) == weight($1) ? $0 < $1 : weight($0) > weight($1) }
            if !ownerOrder.isEmpty {
                entry.owners = ownerOrder.map { owner in
                    UsageOwnerUses(owner: owner, members: (members[owner] ?? []).map { member in
                        let use = uses[owner + "." + member] ?? ([], [])
                        return UsageMemberUse(name: member, lines: Array(Set(use.lines)).sorted(), enclosing: use.enclosing)
                    })
                }
            } else {
                entry.note = "no call into \(name) recorded"
            }
            files.append(entry)
        }
        files = orderFiles(files)
        let fileIDs = files.compactMap { entry in ids.first { $0.1 == entry.path }?.0 ?? external.first { file($0.fileID)?.path == entry.path }?.fileID }
        let (split, byTarget) = split(fileIDs, counts: Dictionary(uniqueKeysWithValues: fileIDs.map { ($0, 1) }))
        let check = try engine.completeness(of: name, targets: [], options: RepositoryEngine.CompletenessOptions())
        var extra: [String] = []
        if !external.isEmpty { extra.append("\(external.count) external \(external.count == 1 ? "call" : "calls")") }
        return UsagesResult(
            view: .framework, target: NodeID.external(name),
            header: UsageHeader(title: name, kind: "framework"),
            totals: UsageTotals(noun: "importer", count: paths.count, files: paths.count, split: split, splitByTarget: byTarget, extra: extra),
            completeness: usageCompleteness(check), files: files)
    }

    func environmentView(name: String) throws -> UsagesResult {
        let all = try rows(where: "r.name = ? ORDER BY r.file_id, r.line", ["env:" + name])
        try loadFiles(all.map(\.fileID))
        try loadSymbols(all.compactMap(\.fromSymbolID))
        var files = orderFiles(try siteFiles(all, primaryPerGroup: { _ in 2 }, consumers: false))
        for index in files.indices {
            let rows = all.filter { file($0.fileID)?.path == files[index].path }
            let writes = rows.contains(where: \.isWrite), reads = rows.contains { !$0.isWrite }
            files[index].labels.append([reads ? "reads" : nil, writes ? "writes" : nil].compactMap { $0 }.joined(separator: ", "))
        }
        let writes = all.filter(\.isWrite).count
        let fileIDs = Array(Set(all.map(\.fileID)))
        let (split, byTarget) = split(fileIDs, counts: Dictionary(grouping: all, by: \.fileID).mapValues(\.count))

        // Text occurrences of the name on a line with an environment access are that access.
        var check = try engine.completeness(of: name, targets: [], options: RepositoryEngine.CompletenessOptions())
        let accessLines = Set(all.compactMap { row in file(row.fileID).map { "\($0.path):\(row.line)" } })
        for index in check.occurrences.indices where accessLines.contains("\(check.occurrences[index].path):\(check.occurrences[index].line)") {
            check.occurrences[index].category = .target
        }
        return UsagesResult(
            view: .environment, target: "env:" + name,
            header: UsageHeader(title: "env:" + name, kind: "environment variable"),
            totals: UsageTotals(noun: "access", count: all.count, files: fileIDs.count, split: split, splitByTarget: byTarget,
                                extra: ["\(all.count - writes) \(all.count - writes == 1 ? "read" : "reads"), \(writes) \(writes == 1 ? "write" : "writes")"]),
            completeness: usageCompleteness(check), files: files)
    }
}
