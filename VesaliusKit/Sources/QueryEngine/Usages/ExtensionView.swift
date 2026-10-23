import Foundation
import RepositoryIndex
import VesaliusCore

/// The extension view: the type view limited to what one file's extensions of a type add.
///
/// - The target is the members the extensions declare, at any depth. The extended type and its other extensions
///   are other targets, named under `also named`.
/// - Every file that uses a member is listed, the declaring file too (a private extension is used nowhere else):
///   the members it uses with their lines and the declarations they are in, then each member's first statement.
///   Uses from inside the extensions are counted apart.
/// - Line 3 says what the extensions add. A conformance has no use sites of its own, and where the type is used
///   as that protocol needs the witness table, which is not built: that is said, not guessed.
/// - The completeness line reconciles the members' names as a file view does, leaving a common one unchecked as
///   a member's own view does. Initializers (a construction names the type) and subscripts are not named where
///   they are used, so they are not checked by name.
extension UsageBuilder {
    func extensionView(_ group: DeclarationGroup, symbol: UsageSymbolInfo, change: UsageChange?) throws -> UsagesResult {
        let ids = group.ids
        let typeIDs = Set(ids)
        let members = try engine.extensionMembers(of: ids)
        try loadSymbols(members)
        let inside = typeIDs.union(members)
        let all = try rows(targeting: members)
        let uses = all.filter { !inside.contains($0.fromSymbolID ?? -1) }
        try loadFiles(Set(uses.map(\.fileID)).union([symbol.fileID]))
        try loadSymbols(uses.compactMap(\.fromSymbolID))
        let added = members.compactMap { self.symbol($0) }.filter { typeIDs.contains($0.parentID ?? -1) }
            .sorted { ($0.lines.start, $0.id) < ($1.lines.start, $1.id) }

        // Per file: the members it uses, then each member's first statement.
        var byFile: [Int64: [UsageRow]] = [:]
        for row in uses { byFile[row.fileID, default: []].append(row) }
        let fileOrder = byFile.keys.sorted { (file($0)?.path ?? "") < (file($1)?.path ?? "") }
        var statementsLeft = Self.statementBudget
        var files: [UsageFile] = []
        for fileID in fileOrder {
            guard let info = file(fileID), let rows = byFile[fileID] else { continue }
            var entry = UsageFile(path: info.path, isTest: info.isTest, testKind: info.testKind, labels: fileLabels(info, sites: rows))
            entry.owners = try memberSummary(rows, typeIDs: typeIDs, viaLine: nil, ownerName: symbol.name)
            var shown = Set<String>()
            var sites: [UsageSite] = []
            for row in rows where statementsLeft > 0 {
                let member = try memberName(row, typeIDs: typeIDs)
                guard shown.insert(member).inserted else { continue }
                statementsLeft -= 1
                sites.append(site(row, path: info.path, primary: true, consumer: false, condition: false))
            }
            if !sites.isEmpty { entry.groups = [UsageGroup(sites: sites)] }
            files.append(entry)
        }
        files = orderFiles(files)

        let fileIDs = files.compactMap { entry in fileOrder.first { file($0)?.path == entry.path } }
        let (split, byTarget) = split(fileIDs, counts: byFile.mapValues(\.count))
        var extra: [String] = []
        if all.count > uses.count {
            let count = all.count - uses.count
            extra.append("\(count) more \(count == 1 ? "use" : "uses") inside the \(ids.count == 1 ? "extension" : "extensions")")
        }

        var header = try declarationHeader(symbol, group: group)
        header.title = symbol.signature.map(Self.oneLine).map { Statement.elide($0, to: 140, keeping: nil) } ?? "extension " + symbol.qualifiedName
        if group.rows.count > 1 { header.kind = "\(group.rows.count) extensions: " + group.rows.map { ":\($0.lines)" }.joined(separator: ", ") }

        // Initializers and subscripts are not named where they are used.
        let unnamed = added.filter { $0.kind == .initializer || $0.name == "subscript" }
        var names: [String] = []
        for member in added where !unnamed.contains(where: { $0.id == member.id }) && !names.contains(member.name) { names.append(member.name) }
        var completeness = names.isEmpty
            ? UsageCompleteness(isComplete: true, summary: "complete: the \(ids.count == 1 ? "extension adds" : "extensions add") no members to name")
            : try fileCompleteness(names: names, targets: inside, inferredFiles: 0, isMember: true)
        var notes = [try addedLine(group, symbol: symbol, added: added)]
        if !unnamed.isEmpty {
            let labels = unnamed.map(memberLabel).joined(separator: ", ")
            completeness.isComplete = false
            if names.isEmpty {
                completeness.summary = "INCOMPLETE: not checked by name: " + labels
            } else {
                if completeness.summary.hasPrefix("complete") { completeness.summary = "INCOMPLETE" + completeness.summary.dropFirst("complete".count) }
                completeness.summary += "; not checked by name: " + labels
            }
            let initializers = unnamed.filter { $0.kind == .initializer }.map(memberLabel)
            if !initializers.isEmpty {
                notes.append(initializers.joined(separator: ", ") + " not listed: constructions are recorded against \(symbol.name), not against \(initializers.count == 1 ? "the initializer" : "its initializers")")
            }
            let subscripts = unnamed.filter { $0.kind != .initializer }.map(memberLabel)
            if !subscripts.isEmpty { notes.append(subscripts.joined(separator: ", ") + " not listed: subscript uses are not recorded") }
        }

        var result = UsagesResult(
            view: .type, target: try engine.exactTarget(for: group), change: change, header: header,
            totals: UsageTotals(noun: "use", count: uses.count, files: fileIDs.count, split: split, splitByTarget: byTarget, extra: extra),
            completeness: completeness, notes: notes, files: files)
        result.footers = try extendedFooters(symbol, group: group) + lookalikeFooters(ids: members)
        if let change {
            result.sections = try fileChangeSections(change, declared: added, dependents: files, completeness: completeness)
        }
        return result
    }

    /// Line 3: `adds remember(pdfAt:metadata:) :6`, `adds conformance to MaintenableMemory and 12 members: … · +6
    /// more`. For conformances alone, that where the type is used as that protocol is not indexed, and which
    /// target lists where the protocol is.
    func addedLine(_ group: DeclarationGroup, symbol: UsageSymbolInfo, added: [UsageSymbolInfo]) throws -> String {
        var protocols: [String] = []
        for id in group.ids {
            for name in (self.symbol(id)?.inherits ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty && !protocols.contains(name) {
                protocols.append(name)
            }
        }
        let labels = added.map { "\(memberLabel($0)) :\($0.lines.start)" }
        var parts: [String] = []
        if !protocols.isEmpty { parts.append("conformance to " + protocols.joined(separator: ", ")) }
        if labels.count == 1, protocols.isEmpty {
            parts.append(labels[0])
        } else if !labels.isEmpty {
            parts.append("\(labels.count) \(labels.count == 1 ? "member" : "members"): " + labels.prefix(6).joined(separator: " · ") + (labels.count > 6 ? " · +\(labels.count - 6) more" : ""))
        }
        guard labels.isEmpty else { return "adds " + parts.joined(separator: " and ") }
        guard !protocols.isEmpty else { return "adds nothing: no members and no conformances" }
        var line = "adds \(parts[0]) and no members: where \(symbol.name) is used as \(protocols.joined(separator: " or ")) is not indexed"
        // The protocols declared in the repository: their own uses are a target.
        let conformed = try rows(where: "r.from_symbol_id IN (\(group.ids.sqlList)) AND r.kind = 'conform' AND r.target_symbol_id IS NOT NULL AND r.confidence >= ?", [threshold])
        let declared = try engine.symbolRows(where: "s.id IN (\(conformed.compactMap(\.targetSymbolID).sqlList))", [], limit: 20)
        let targets = try engine.groupDeclarations(declared).map { try engine.exactTarget(for: $0) }
        if !targets.isEmpty {
            line += "; " + targets.map { "usages(target:\(OutlineBuilder.quoted($0)))" }.joined(separator: ", ") + " \(targets.count == 1 ? "lists the protocol's uses" : "list the protocols' uses")"
        }
        return line
    }

    /// A member as the member lines name it: `remember(pdfAt:metadata:)`, `messages`.
    func memberLabel(_ member: UsageSymbolInfo) -> String {
        member.kind.isCallable ? String(displayName(member).split(separator: ".").last ?? Substring(member.name)) : member.name
    }

    /// `also named`: the extended type's declarations, the declaring file's other extensions of it, then the other
    /// files' (one file's together when `path#Name` selects them all, else one by one), with their use counts and
    /// exact targets.
    func extendedFooters(_ symbol: UsageSymbolInfo, group: DeclarationGroup) throws -> [UsageFooter] {
        let others = try engine.symbolRows(where: "s.qualified_name = ? AND s.id NOT IN (\(group.ids.sqlList)) ORDER BY f.path, s.start_line", [symbol.qualifiedName], limit: 500)
        let here = others.filter { $0.kind == .extension && $0.fileID == symbol.fileID }
        var elsewhere: [DeclarationGroup] = []
        for other in try engine.groupDeclarations(others.filter { $0.kind == .extension && $0.fileID != symbol.fileID }) {
            let together = try engine.extensionTarget(other.rows) == "\(other.first.path)#\(other.first.qualifiedName)"
            elsewhere += together ? [other] : other.rows.map { DeclarationGroup(rows: [$0], selector: nil) }
        }
        let groups = try engine.groupDeclarations(others.filter { $0.kind != .extension })
            + here.map { DeclarationGroup(rows: [$0], selector: nil) }
            + elsewhere
        guard !groups.isEmpty else { return [] }
        var items: [String] = []
        for other in groups.prefix(4) {
            let counts = try engine.useCounts(other.ids)
            items.append("\(try engine.exactTarget(for: other)) (\(other.first.kind.displayName), \(counts.uses) \(counts.uses == 1 ? "use" : "uses") in \(counts.files) \(counts.files == 1 ? "file" : "files"), excluded)")
        }
        return [UsageFooter(kind: .alsoNamed, items: items, more: groups.count - items.count)]
    }
}
