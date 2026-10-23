import Foundation
import RepositoryIndex
import VesaliusCore

/// The file view: a file's declared API, then each dependent file broken down by owner
/// type, member and line.
///
/// - Swift and other languages: per dependent file, the owners (top-level declarations of the target file) and
///   the members used, with lines and the declarations the uses are in; the first use's statement as evidence.
///   A file that never names one of the target's types but reaches them through inferred receivers is
///   labelled `[type-inferred via …]`.
/// - TypeScript and Python: the import line with its names, then each use with its statement, the route or
///   function it is in, the statement that consumes its result, and a helper's callers in its own file.
/// - Footers: rejected lookalikes, files that reach the target only transitively, files that only mock it.
/// - Completeness reconciles every name another file could use: Swift declarations that are not private,
///   TypeScript exports, Python names without a leading `_`.
extension UsageBuilder {
    /// Names reconciled per file target before the rest are reported unchecked.
    static let fileNamesChecked = 12

    func fileView(fileID: Int64, path: String, change: UsageChange?) throws -> UsagesResult {
        try loadFiles([fileID])
        guard let info = file(fileID) else { throw EngineError.notFound(path, suggestions: []) }
        let declared = try symbols(where: "s.file_id = ? ORDER BY s.start_line, s.id", [fileID])
        let topLevel = declared.filter { $0.depth == 0 }
        // What other files can use comes first; the rest is counted.
        let visible = Set(checkableNames(topLevel, language: info.language))
        let shown = topLevel.filter { visible.contains($0.name) || $0.kind == .extension }
        let header = UsageHeader(
            title: path, path: path, kind: "file", buildTargets: info.targets, membership: try membershipNote(info),
            declares: shown.prefix(8).map { UsageDeclared(name: $0.kind == .extension ? "extension " + $0.name : $0.name, kind: $0.kind.displayName, lines: $0.lines) },
            declaresMore: max(0, topLevel.count - min(8, shown.count)))
        let dependents = try dependentFiles(targetFileIDs: [fileID], topLevel: topLevel)

        // Totals: dependent files; for script languages, importers.
        let users = dependents.files
        let fileIDs = dependents.order
        let (split, byTarget) = split(fileIDs, counts: Dictionary(uniqueKeysWithValues: fileIDs.map { ($0, 1) }))
        var extra: [String] = []
        if dependents.mockOnly.count > 0 {
            extra.append("\(dependents.mockOnly.count) more only mock it")
        }
        let inferred = users.filter { $0.labels.contains { $0.hasPrefix("type-inferred") } }.count
        if inferred > 0 { extra.append("\(inferred) by type flow") }
        let isScript = info.isScript
        let totals = UsageTotals(noun: isScript ? "importer" : "file", count: users.count, files: users.count, split: split, splitByTarget: byTarget, extra: extra)

        let names = checkableNames(topLevel, language: info.language)
        let completeness = try fileCompleteness(names: names, targets: Set(declared.map(\.id)), inferredFiles: inferred)
        var result = UsagesResult(view: .file, target: path, change: change, header: header, totals: totals, completeness: completeness, files: users)
        result.footers = try lookalikeFooters(ids: declared.map(\.id)) + transitiveFooter(from: [fileID], direct: Set(fileIDs)) + mockFooter(dependents.mockOnly)
        if let change {
            result.sections = try fileChangeSections(change, declared: declared, dependents: users, completeness: completeness)
        }
        return result
    }

    /// The names of a file's declarations that other files can use.
    func checkableNames(_ topLevel: [UsageSymbolInfo], language: Language) -> [String] {
        var names: [String] = []
        for symbol in topLevel where symbol.kind != .extension && !names.contains(symbol.name) {
            switch language {
            case .typescript, .javascript: if symbol.isExported { names.append(symbol.name) }
            case .python: if !symbol.name.hasPrefix("_") { names.append(symbol.name) }
            default: if !symbol.isPrivate { names.append(symbol.name) }
            }
        }
        return names
    }

    // MARK: Dependents

    struct Dependents {
        var files: [UsageFile]
        /// File ids in `files` order.
        var order: [Int64]
        /// Files that only mock the target (`vi.mock`): path and line.
        var mockOnly: [(path: String, line: Int)]
    }

    /// The files outside `targetFileIDs` that use them (references at the use threshold, or a non-mock import),
    /// each described per owner and member, in a fixed order.
    func dependentFiles(targetFileIDs: [Int64], topLevel: [UsageSymbolInfo]) throws -> Dependents {
        let targets = Set(targetFileIDs)
        var all: [UsageRow] = []
        for chunk in Self.chunks(targetFileIDs) {
            all += try rows(where: "r.target_file_id IN (\(chunk.sqlList)) AND r.confidence >= ? AND r.file_id NOT IN (\(chunk.sqlList))", [threshold])
        }
        all = all.filter { !targets.contains($0.fileID) }
        struct ImportRow { let fileID: Int64; let line: Int; let names: [String]; let isMock: Bool; let isTypeOnly: Bool }
        var imports: [ImportRow] = []
        for chunk in Self.chunks(targetFileIDs) {
            imports += try db.query("""
                SELECT file_id, line, names, is_mock, is_type_only FROM imports
                WHERE resolved_file_id IN (\(chunk.sqlList)) AND file_id NOT IN (\(chunk.sqlList)) ORDER BY line
                """) { row in
                ImportRow(fileID: row.int64(0), line: row.int(1), names: (row.optionalString(2) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                          isMock: row.bool(3), isTypeOnly: row.bool(4))
            }
        }
        try loadFiles(all.map(\.fileID) + imports.map(\.fileID))
        try loadSymbols(all.compactMap(\.fromSymbolID) + all.compactMap(\.targetSymbolID))

        var byFile: [Int64: [UsageRow]] = [:]
        for row in all { byFile[row.fileID, default: []].append(row) }
        let realImports = Dictionary(grouping: imports.filter { !$0.isMock }, by: \.fileID)
        let mockImports = Dictionary(grouping: imports.filter(\.isMock), by: \.fileID)
        let users = Set(byFile.keys).union(realImports.keys)
        let mockOnly = mockImports.keys.filter { !users.contains($0) }.compactMap { id in
            file(id).map { ($0.path, mockImports[id]?.first?.line ?? 0) }
        }.sorted { $0.0 < $1.0 }

        let topNames = Set(topLevel.filter { $0.kind != .extension }.map(\.id))
        var statementsLeft = Self.statementBudget
        var files: [UsageFile] = []
        for fileID in users {
            guard let info = file(fileID) else { continue }
            let rows = (byFile[fileID] ?? []).sorted { ($0.line, $0.column) < ($1.line, $1.column) }
            var entry = UsageFile(path: info.path, isTest: info.isTest, testKind: info.testKind, labels: fileLabels(info, sites: rows))
            if let first = realImports[fileID]?.first {
                entry.importLine = first.line
                entry.importedNames = realImports[fileID]?.flatMap(\.names) ?? []
            }
            if info.isScript {
                // Each use with its statement: the first 3 of each declaration in full.
                var order: [Int64?] = []
                var byOwner: [Int64?: [UsageRow]] = [:]
                for row in rows {
                    if byOwner[row.fromSymbolID] == nil { order.append(row.fromSymbolID) }
                    byOwner[row.fromSymbolID, default: []].append(row)
                }
                for owner in order {
                    var group = try enclosingGroup(owner, path: info.path, fileCondition: nil)
                    group.sites = (byOwner[owner] ?? []).enumerated().map { index, row in
                        let primary = index < 3 && statementsLeft > 0
                        if primary { statementsLeft -= 1 }
                        var site = site(row, path: info.path, primary: primary, consumer: true, condition: false)
                        site.member = row.name
                        return site
                    }
                    if let owner { group.inFileCallers = try inFileCallers(of: owner) }
                    entry.groups.append(group)
                }
            } else {
                entry.owners = try ownerSummary(rows, targetFiles: targets)
                // The first use's statement, as evidence.
                if let first = rows.first, statementsLeft > 0 {
                    statementsLeft -= 1
                    entry.groups = [UsageGroup(sites: [site(first, path: info.path, primary: true, consumer: false, condition: false)])]
                }
                if !rows.isEmpty, !rows.contains(where: { topNames.contains($0.targetSymbolID ?? -1) }), let label = try typeFlowLabel(rows) {
                    entry.labels.append(label)
                }
            }
            files.append(entry)
        }
        files = orderFiles(files)
        let order = files.compactMap { entry in users.first { file($0)?.path == entry.path } }
        return Dependents(files: files, order: order, mockOnly: mockOnly)
    }

    /// Uses by owner (the top-level declaration of the target file that holds the used declaration), then by
    /// member, each with its lines and the declarations they are in. An owner's name used as the receiver of one
    /// of its members on the same line is not listed apart.
    func ownerSummary(_ rows: [UsageRow], targetFiles: Set<Int64>) throws -> [UsageOwnerUses] {
        var ownerOrder: [String] = []
        var members: [String: [String]] = [:]
        var entries: [String: (lines: [Int], kinds: Set<String>, enclosing: [String])] = [:]
        var lineHasMember: [Int: Set<String>] = [:]
        var resolved: [(row: UsageRow, owner: String, member: String, isOwnerName: Bool)] = []
        // Owners that are not types (a top-level function or variable): their own uses are calls or uses, not `type`.
        var plainOwners = Set<String>()
        for row in rows {
            guard let target = symbol(row.targetSymbolID) else { continue }
            let chain = try ancestors(of: target.id)
            let top = chain.last ?? target
            let owner = top.name
            let isOwnerName = top.id == target.id
            if !top.kind.isType, top.kind != .extension { plainOwners.insert(owner) }
            var member = owner
            if !isOwnerName {
                // The owner's direct child on the chain (a nested type's members show under the nested type).
                let child = chain.count >= 2 ? chain[chain.count - 2] : target
                member = child.kind.isCallable ? String(displayName(child).split(separator: ".").last ?? Substring(child.name)) : child.name
                if row.form == ReferenceContext.implicit.rawValue, child.id == target.id { member = "." + member }
                lineHasMember[row.line, default: []].insert(owner)
            }
            resolved.append((row, owner, member, isOwnerName))
        }
        for (row, owner, member, isOwnerName) in resolved {
            if isOwnerName, row.isTypeUse || row.kind == ReferenceKind.read.rawValue, lineHasMember[row.line]?.contains(owner) == true { continue }
            if members[owner] == nil {
                ownerOrder.append(owner)
                members[owner] = []
            }
            let key = owner + "\u{1}" + member
            if entries[key] == nil { members[owner, default: []].append(member) }
            var entry = entries[key] ?? ([], [], [])
            entry.lines.append(row.line)
            entry.kinds.insert(row.kind)
            if let from = symbol(row.fromSymbolID) {
                let name = enclosingName(from)
                if !entry.enclosing.contains(name) { entry.enclosing.append(name) }
            }
            entries[key] = entry
        }
        return ownerOrder.map { owner in
            UsageOwnerUses(owner: owner, members: (members[owner] ?? []).map { member in
                let entry = entries[owner + "\u{1}" + member] ?? ([], [], [])
                var name = member
                if member == owner {
                    let calls: Set<String> = [ReferenceKind.call.rawValue, ReferenceKind.instantiate.rawValue]
                    name = !plainOwners.contains(owner) ? "type" : entry.kinds.isSubset(of: calls) ? "call" : "use"
                }
                return UsageMemberUse(name: name, lines: Array(Set(entry.lines)).sorted(), kinds: entry.kinds.sorted(), enclosing: entry.enclosing)
            })
        }
    }

    // MARK: Completeness of a file

    /// Every occurrence of each name in `names`, reconciled against all the file's declarations, as one line.
    /// Members' names (`isMember`, an extension's) that are common words are left unchecked, as one member's are.
    func fileCompleteness(names: [String], targets: Set<Int64>, inferredFiles: Int, isMember: Bool = false) throws -> UsageCompleteness {
        guard !names.isEmpty else {
            return UsageCompleteness(isComplete: true, summary: "complete: the file declares nothing other files can name")
        }
        let checked = Array(names.prefix(Self.fileNamesChecked))
        var merged: Completeness?
        var reconciled: [String] = []
        var unchecked: Completeness?
        let started = DispatchTime.now()
        var skipped: [String] = Array(names.dropFirst(checked.count))
        for name in checked {
            // One shared time budget for all names.
            let left = max(0.05, 0.6 - RepositoryEngine.seconds(since: started))
            let check = try engine.completeness(of: name, targets: targets, options: RepositoryEngine.CompletenessOptions(timeBudget: left, skipCommonNames: isMember))
            if check.notCheckedByName {
                skipped.append(name)
                unchecked = unchecked ?? check
                continue
            }
            reconciled.append(name)
            guard var total = merged else {
                merged = check
                continue
            }
            total.occurrences += check.occurrences
            total.candidateFiles += check.candidateFiles
            total.scannedFiles += check.scannedFiles
            total.staleFiles = Array(Set(total.staleFiles + check.staleFiles)).sorted()
            total.capped = total.capped || check.capped
            total.targetIsLexical = total.targetIsLexical || check.targetIsLexical
            total.unmatchedRows += check.unmatchedRows
            merged = total
        }
        guard let merged else {
            // No name was reconciled: the first one left unchecked says why, the others are listed.
            guard let unchecked else { return UsageCompleteness(isComplete: false, summary: "INCOMPLETE: nothing could be checked") }
            var usage = usageCompleteness(unchecked)
            let others = skipped.filter { $0 != unchecked.name }
            if !others.isEmpty { usage.summary += "; not checked by name: " + others.prefix(6).joined(separator: ", ") + (others.count > 6 ? " +\(others.count - 6)" : "") }
            return usage
        }
        var usage = usageCompleteness(merged)
        // The summary names one identifier; say which names were reconciled instead.
        let list = reconciled.count > 4 ? reconciled.prefix(4).joined(separator: ", ") + " +\(reconciled.count - 4) more" : reconciled.joined(separator: ", ")
        let quoted = "\"\(merged.name)\" occurs"
        let verb = reconciled.count == 1 ? "occurs" : "occur"
        usage.summary = usage.summary.replacingOccurrences(of: quoted, with: "\(reconciled.count == 1 ? "\"\(reconciled[0])\"" : list) \(verb)")
        if !skipped.isEmpty {
            usage.isComplete = false
            if usage.summary.hasPrefix("complete") { usage.summary = "INCOMPLETE" + usage.summary.dropFirst("complete".count) }
            usage.summary += "; not checked by name: " + skipped.prefix(6).joined(separator: ", ") + (skipped.count > 6 ? " +\(skipped.count - 6)" : "")
        }
        if inferredFiles > 0 {
            usage.summary += "; +\(inferredFiles) \(inferredFiles == 1 ? "file" : "files") by type flow (listed)"
        }
        return usage
    }

    // MARK: Footers

    /// `transitive only (not listed)`: files that reach the target only through other files.
    func transitiveFooter(from targets: [Int64], direct: Set<Int64>) throws -> [UsageFooter] {
        let graph = try engine.graphCache()
        let reached = graph.traverse(from: targets, dependents: true, maxDepth: 64)
        let excluded = Set(targets).union(direct)
        let transitive = reached.filter { !excluded.contains($0.id) && $0.distance >= 2 }
            .compactMap { node in graph.files[node.id].map { (node: $0, distance: node.distance) } }
            .sorted { ($0.node.isTest ? 1 : 0, $0.distance, $0.node.path) < ($1.node.isTest ? 1 : 0, $1.distance, $1.node.path) }
        guard !transitive.isEmpty else { return [] }
        // Nearest production files first, named by their stem or as much of their path as tells them apart.
        let paths = transitive.map(\.node.path)
        let names = Completeness.shortNames(paths)
        let shown = paths.prefix(3).map { (names[$0] ?? $0) as NSString }.map { ($0.deletingPathExtension as String) }
        return [UsageFooter(kind: .transitiveOnly, qualifier: "(not listed)", items: shown, more: transitive.count - shown.count)]
    }

    /// `mock only (vi.mock)`: files whose only link to the target is a mock.
    func mockFooter(_ files: [(path: String, line: Int)]) -> [UsageFooter] {
        guard !files.isEmpty else { return [] }
        return [UsageFooter(kind: .mockOnly, qualifier: "(vi.mock)", items: files.map { "\($0.path):\($0.line)" })]
    }

    // MARK: Folder and module targets

    /// A folder or repository module: the files outside it that use its declarations or import it, broken down
    /// by owner and member as for a file. Completeness is not reconciled name by name for a whole folder.
    func groupView(_ view: UsagesResult.View, name: String, fileIDs: [Int64], change: UsageChange?) throws -> UsagesResult {
        try loadFiles(fileIDs)
        var topLevel: [UsageSymbolInfo] = []
        for chunk in Self.chunks(fileIDs) {
            topLevel += try symbols(where: "s.file_id IN (\(chunk.sqlList)) AND s.depth = 0 AND s.kind != 'extension' ORDER BY s.file_id, s.start_line")
        }
        var dependents = try dependentFiles(targetFileIDs: fileIDs, topLevel: topLevel)
        if view == .module {
            // Swift importers of the module (`import WaxCore`) that use nothing by name still depend on it.
            let importers = try db.query("""
                SELECT i.file_id, i.line FROM imports i JOIN modules m ON m.id = i.resolved_module_id
                WHERE m.name = ? AND i.file_id NOT IN (\(fileIDs.sqlList)) ORDER BY i.file_id, i.line
                """, [name]) { ($0.int64(0), $0.int(1)) }
            try loadFiles(importers.map(\.0))
            for (fileID, line) in importers {
                guard let info = file(fileID) else { continue }
                if let index = dependents.files.firstIndex(where: { $0.path == info.path }) {
                    if dependents.files[index].importLine == nil { dependents.files[index].importLine = line }
                } else {
                    dependents.files.append(UsageFile(path: info.path, isTest: info.isTest, testKind: info.testKind, labels: fileLabels(info, sites: []), importLine: line, note: "imports it; uses nothing by name"))
                    dependents.order.append(fileID)
                }
            }
            dependents.files = orderFiles(dependents.files)
        }
        let users = dependents.files
        let ids = users.compactMap { entry in dependents.order.first { file($0)?.path == entry.path } }
        let (split, byTarget) = split(ids, counts: Dictionary(uniqueKeysWithValues: ids.map { ($0, 1) }))
        let header = UsageHeader(
            title: name, kind: view == .module ? "module, \(fileIDs.count) files" : "folder, \(fileIDs.count) files",
            declares: topLevel.prefix(8).map { UsageDeclared(name: $0.name, kind: $0.kind.displayName, lines: $0.lines) }, declaresMore: max(0, topLevel.count - 8))
        let completeness = UsageCompleteness(
            isComplete: false,
            summary: "INCOMPLETE: \(topLevel.count) declarations in \(fileIDs.count) files are not reconciled name by name; usages of one file or type checks them")
        var result = UsagesResult(view: view, target: view == .module ? NodeID.module(name) : name, change: change, header: header,
                                  totals: UsageTotals(noun: "file", count: users.count, files: users.count, split: split, splitByTarget: byTarget,
                                                      extra: dependents.mockOnly.isEmpty ? [] : ["\(dependents.mockOnly.count) more only mock it"]),
                                  completeness: completeness, files: users)
        result.footers = try transitiveFooter(from: fileIDs, direct: Set(ids)) + mockFooter(dependents.mockOnly)
        return result
    }
}
