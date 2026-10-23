import Foundation
import RepositoryIndex
import VesaliusCore

/// Every file that uses the feature's core, with its sites, from the reference table.
///
/// For a type: references resolved to the type or its members, keeping a unique-name guess only when its receiver
/// is the type, `self` or a property of the using file that holds the type (`subs = PremiumStore.shared`).
/// Through those properties, member calls the linker left unresolved or guessed below 0.85 are attributed to the
/// type's member of that name and argument labels. For a file: its importers, the uses of what they import, the
/// statement consuming each result, the route each handler serves, and one hop up from local helpers.
struct ClusterUsers {
    let context: FeatureContext
    /// Role order of each member that plays a role (call sites to these rank first).
    let roleOrder: [Int64: Int]
    /// The question's framework calls by file (`.manageSubscriptionsSheet` in ProfileView).
    let externalByFile: [Int64: [FeatureContext.Ref]]

    static let sitesPerFile = 6
    static let strongBases: Set<String> = ["typed", "static", "self", "lexical", "import"]

    // MARK: Type core

    func callSites(ofType core: RepositoryEngine.SymbolRow, members: [Int64: RepositoryEngine.SymbolRow]) throws -> FeatureCallSites {
        let ids = Set(members.keys).union([core.id])
        let memberIDsByName = Dictionary(grouping: members.values.filter { $0.kind != .extension }, by: \.name).mapValues { $0.map(\.id) }
        let aliases = try aliasesByFile(of: core.name, excluding: core.fileID)
        var sites: [Int64: [FeatureContext.Ref]] = [:]
        var resolvedMember: [Int64: Int64] = [:]

        for ref in try context.refs(where: "r.target_symbol_id IN (\(Array(ids).sqlList)) AND r.file_id != ? AND r.confidence >= ?", [core.fileID, context.threshold]) {
            let fileAliases = aliases[ref.fileID] ?? []
            let receiver = ref.receiver ?? ""
            let trusted = ref.confidence >= 0.85 || ref.basis.map(Self.strongBases.contains) == true
                || ref.receiver == nil || ["self", "Self", core.name].contains(receiver) || fileAliases.contains(receiver)
                || fileAliases.contains(receiver.replacingOccurrences(of: "self.", with: "")) || ref.kind == "type" || ref.kind == "instantiate"
            guard trusted else { continue }
            sites[ref.fileID, default: []].append(ref)
            if let target = ref.target { resolvedMember[ref.id] = target }
        }
        // Member uses through a property that holds the type, which the index left unresolved or guessed elsewhere.
        if !aliases.isEmpty, !memberIDsByName.isEmpty {
            let receivers = Set(aliases.values.flatMap { $0 }).flatMap { [$0, "self." + $0] }
            let rows = try context.refs(where: """
                r.file_id IN (\(Array(aliases.keys).sqlList)) AND r.receiver IN (\(receivers.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")))
                AND r.name IN (\(memberIDsByName.keys.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")))
                AND (r.target_symbol_id IS NULL OR r.confidence < 0.85)
                """)
            for ref in rows {
                let receiver = (ref.receiver ?? "").replacingOccurrences(of: "self.", with: "")
                guard aliases[ref.fileID]?.contains(receiver) == true, let candidates = memberIDsByName[ref.name] else { continue }
                guard let member = pickOverload(candidates, labels: ref.labels, members: members) else { continue }
                if sites[ref.fileID]?.contains(where: { $0.id == ref.id }) == true {
                    resolvedMember[ref.id] = member
                    continue
                }
                sites[ref.fileID, default: []].append(ref)
                resolvedMember[ref.id] = member
            }
        }
        var files: [FeatureCallSiteFile] = []
        let infos = context.files(Array(sites.keys) + Array(externalByFile.keys))
        for (fileID, refs) in sites {
            guard let info = infos[fileID] else { continue }
            let external = externalByFile[fileID] ?? []
            files.append(fileBlock(info, refs: refs, external: external, member: { resolvedMember[$0.id] }, members: members, core: core))
        }
        files.sort(by: Self.fileOrder)
        let completeness = try typeCompleteness(core, ids: ids, files: Set(files.map(\.path)))
        return FeatureCallSites(subject: core.name, files: files, completeness: completeness)
    }

    /// Names of properties (any depth) in each file that hold the type: their signature names it as a whole word
    /// (`= PremiumStore.shared`, `: PremiumStore`) or their declared type is it.
    func aliasesByFile(of typeName: String, excluding coreFile: Int64) throws -> [Int64: Set<String>] {
        var result: [Int64: Set<String>] = [:]
        let pattern = "%" + typeName + "%"
        try context.db.forEach("""
            SELECT file_id, name, signature, declared_type FROM symbols
            WHERE kind IN ('property', 'variable', 'constant') AND file_id != ? AND (signature LIKE ? OR declared_type = ?)
            """, [coreFile, pattern, typeName]) { row in
            let signature = row.optionalString(2) ?? ""
            let declared = row.optionalString(3)
            if declared == typeName || Self.holdsType(signature, typeName) {
                result[row.int64(0), default: []].insert(row.string(1))
            }
        }
        return result
    }

    /// Whether a declaration's text names the type itself as a whole word, not one of its nested types
    /// (`PremiumStore.shared` and `: PremiumStore` hold it; `PremiumStore.Tier` does not).
    static func holdsType(_ text: String, _ word: String) -> Bool {
        var search = text.startIndex
        while let range = text.range(of: word, range: search..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let boundaryBefore = before.map { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") } ?? true
            let boundaryAfter = after.map { !($0.isLetter || $0.isNumber || $0 == "_") } ?? true
            var nested = false
            if after == ".", text.index(after: range.upperBound) < text.endIndex {
                nested = text[text.index(after: range.upperBound)].isUppercase
            }
            if boundaryBefore && boundaryAfter && !nested { return true }
            search = range.upperBound
        }
        return false
    }

    /// The overload a call's argument labels select (`purchase(planID:)` for `planID:`), else the only one.
    func pickOverload(_ candidates: [Int64], labels: [String]?, members: [Int64: RepositoryEngine.SymbolRow]) -> Int64? {
        guard candidates.count > 1, let labels else { return candidates.count == 1 ? candidates[0] : candidates.first }
        let wanted = labels.filter { !$0.hasSuffix("{}") }.map { $0 == "_" ? "_:" : $0 + ":" }.joined()
        for id in candidates {
            guard let row = members[id] else { continue }
            let selector = context.extra(id)?.selector ?? RepositoryEngine.selector(name: row.name, kind: row.kind, signature: row.signature)
            guard let selector, let open = selector.firstIndex(of: "(") else { continue }
            let inside = selector[selector.index(after: open)...].dropLast()
            if inside == wanted { return id }
        }
        // Defaulted parameters may be left out: the first overload whose labels start with the call's.
        for id in candidates {
            guard let row = members[id], let selector = context.extra(id)?.selector ?? RepositoryEngine.selector(name: row.name, kind: row.kind, signature: row.signature),
                  let open = selector.firstIndex(of: "(") else { continue }
            if selector[selector.index(after: open)...].hasPrefix(wanted) { return id }
        }
        return candidates.first
    }

    /// One file's block: sites ranked by what they use (role members' calls first, ties in line order), the same
    /// member's repeats on one compact line, each line quoted once, the file's framework calls, and how many more
    /// there are.
    func fileBlock(_ info: FeatureContext.FileInfo, refs: [FeatureContext.Ref], external: [FeatureContext.Ref], member: (FeatureContext.Ref) -> Int64?,
                   members: [Int64: RepositoryEngine.SymbolRow], core: RepositoryEngine.SymbolRow) -> FeatureCallSiteFile {
        struct Use {
            let key: String
            let refs: [FeatureContext.Ref]
            let score: Double
            let isExternal: Bool
        }
        var byKey: [String: [FeatureContext.Ref]] = [:]
        var keyScore: [String: Double] = [:]
        for ref in refs {
            let target = member(ref)
            let row = target.flatMap { members[$0] }
            let key = row.map { "\($0.id)" } ?? "type:\(ref.name)"
            var score: Double
            if let row, let order = roleOrder[row.id] {
                score = (ref.isCall ? 5 : 4) - Double(order) * 0.01
            } else if let row, row.kind.isCallable {
                score = ref.isCall ? 3 : 2
            } else if ref.kind == "write" {
                score = 2.5
            } else if let row, row.kind == .property, (row.signature ?? "").contains("static "), (row.signature ?? "").contains("\(core.name)(") {
                // Getting the shared instance (`= PremiumStore.shared`) is how the file reaches the type, not a use.
                score = 1
            } else if row != nil {
                score = 2
            } else {
                score = 1
            }
            if ref.conditions != nil { score -= 0.3 }
            byKey[key, default: []].append(ref)
            keyScore[key] = max(keyScore[key] ?? 0, score)
        }
        for ref in external {
            let key = "ext:\(ref.name)"
            byKey[key, default: []].append(ref)
            keyScore[key] = 4.5
        }
        var uses: [Use] = []
        for (key, refs) in byKey {
            let ordered = refs.sorted { (a: FeatureContext.Ref, b: FeatureContext.Ref) in a.line == b.line ? a.column < b.column : a.line < b.line }
            uses.append(Use(key: key, refs: ordered, score: keyScore[key] ?? 0, isExternal: key.hasPrefix("ext:")))
        }
        uses.sort { (a: Use, b: Use) in
            if a.score != b.score { return a.score > b.score }
            return (a.refs[0].line, a.refs[0].column, a.key) < (b.refs[0].line, b.refs[0].column, b.key)
        }
        // Bare mentions of the type (annotations, casts) only when the file does nothing else with it.
        if uses.contains(where: { $0.score > 1 }) { uses.removeAll { $0.score <= 1 } }

        let labels = info.isTest ? ["[test]"] : []
        let callers = Set(refs.compactMap(\.fromSymbol))
        let caller: String? = callers.count == 1 ? callers.first.flatMap { context.symbol($0) }.map { context.displayName($0) } : nil
        if info.isTest {
            let lines = refs.map(\.line) + external.map(\.line)
            return FeatureCallSiteFile(path: info.path, labels: labels, isTest: true, groups: [FeatureCallSiteGroup(caller: nil, sites: lines.sorted().prefix(1).map {
                FeatureEvidence(line: $0, code: "", kind: .read, moreLines: Array(Set(lines)).sorted().dropFirst().map { $0 })
            })])
        }
        var sites: [FeatureEvidence] = []
        var shown = Set<Int>()
        var hidden = 0
        for use in uses {
            // A line another site already quotes is not quoted again (`activeProductID == …lifetimeID`).
            let refs = use.refs.filter { !shown.contains($0.line) }
            guard let first = refs.first else { continue }
            guard sites.count < Self.sitesPerFile else {
                hidden += refs.count
                continue
            }
            let index = sites.count
            let more = Array(Set(refs.dropFirst().map { $0.line })).sorted().filter { $0 != first.line }
            let kind: FeatureEvidence.Kind = use.isExternal ? .external : (first.isCall ? .call : .read)
            if index < 2, use.score >= 3.5 || index == 0, let statement = context.statement(info.path, ref: first) {
                sites.append(FeatureEvidence(line: statement.start, code: statement.text(maxLength: 110), kind: kind, primary: true, moreLines: more))
                shown.formUnion(statement.start...max(statement.start, min(statement.end, statement.start + 2)))
            } else {
                let gist = context.gist(info.path, line: first.line, name: first.name, limit: 50) ?? first.name
                sites.append(FeatureEvidence(line: first.line, code: gist, kind: kind, moreLines: more))
                shown.insert(first.line)
            }
        }
        var group = FeatureCallSiteGroup(caller: caller, sites: sites)
        if hidden > 0 { group.sites.append(FeatureEvidence(line: 0, code: "+\(hidden) more", kind: .read)) }
        return FeatureCallSiteFile(path: info.path, labels: labels, isTest: false, groups: [group])
    }

    static func fileOrder(_ a: FeatureCallSiteFile, _ b: FeatureCallSiteFile) -> Bool {
        if a.isTest != b.isTest { return !a.isTest }
        let aCalls = a.groups.flatMap(\.sites).filter { $0.kind == .call || $0.kind == .external }.count
        let bCalls = b.groups.flatMap(\.sites).filter { $0.kind == .call || $0.kind == .external }.count
        if aCalls != bCalls { return aCalls > bCalls }
        return a.path < b.path
    }

    /// `complete: every file that names PremiumStore is listed`, from the completeness check of the
    /// type's name, or `INCOMPLETE: …` with the unexplained sites.
    func typeCompleteness(_ core: RepositoryEngine.SymbolRow, ids: Set<Int64>, files: Set<String>) throws -> String? {
        let result = try context.engine.completeness(of: core.name, targets: ids)
        let users = Set(result.occurrences(.target).map(\.path)).subtracting([core.path])
        let missing = users.subtracting(files)
        if result.isComplete && missing.isEmpty {
            return "complete: every file that names \(core.name) is listed"
        }
        let unexplained = result.occurrences.filter { $0.category.isUnexplained }
        if unexplained.isEmpty && missing.isEmpty { return nil }
        var parts: [String] = []
        if !unexplained.isEmpty { parts.append("\(unexplained.count) unresolved (\(Completeness.locations(unexplained) ?? ""))") }
        if result.capped { parts.append("scanned \(result.scannedFiles) of \(result.candidateFiles) files") }
        return "INCOMPLETE: " + parts.joined(separator: "; ")
    }

    // MARK: File core

    func callSites(ofFile core: FeatureContext.FileInfo, exports: [Int64: RepositoryEngine.SymbolRow]) throws -> FeatureCallSites {
        struct Import {
            let fileID: Int64
            let line: Int
            let names: [String]
            let isMock: Bool
        }
        var imports: [Import] = []
        try context.db.forEach("SELECT file_id, line, names, is_mock FROM imports WHERE resolved_file_id = ? AND file_id != ?", [core.id, core.id]) { row in
            let names = ImportNamesCodec.decode(row.optionalString(2)).map { $0.alias ?? $0.name }
            imports.append(Import(fileID: row.int64(0), line: row.int(1), names: names, isMock: row.bool(3)))
        }
        let realImporters = Set(imports.filter { !$0.isMock }.map(\.fileID))
        let mockOnly = Set(imports.filter(\.isMock).map(\.fileID)).subtracting(realImporters)
        let ids = Array(exports.keys)
        var refsByFile: [Int64: [FeatureContext.Ref]] = [:]
        if !realImporters.isEmpty {
            let clause = ids.isEmpty ? "r.target_file_id = ?" : "(r.target_file_id = ? OR r.target_symbol_id IN (\(ids.sqlList)))"
            for ref in try context.refs(where: "r.file_id IN (\(Array(realImporters).sqlList)) AND \(clause) AND r.confidence >= ? AND r.kind != 'import'", [core.id, context.threshold]) {
                refsByFile[ref.fileID, default: []].append(ref)
            }
        }
        let infos = context.files(Array(realImporters) + Array(mockOnly))
        var files: [FeatureCallSiteFile] = []
        for fileID in realImporters {
            guard let info = infos[fileID] else { continue }
            let fileImports = imports.filter { $0.fileID == fileID && !$0.isMock }
            let names = Array(Set(fileImports.flatMap(\.names))).sorted()
            let header = fileImports.first.map { ":\($0.line) imports " + (names.isEmpty ? "it" : "{\(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? ", …" : "")}") }
            let refs = (refsByFile[fileID] ?? []).sorted { ($0.line, $0.column) < ($1.line, $1.column) }
            if info.isTest {
                files.append(FeatureCallSiteFile(path: info.path, labels: ["[test]"], isTest: true, header: header))
                continue
            }
            files.append(FeatureCallSiteFile(path: info.path, header: header, groups: try groups(info, refs: refs)))
        }
        files.sort(by: Self.fileOrder)
        let source = files.filter { !$0.isTest }.count
        var line = "imported by \(files.count) \(files.count == 1 ? "file" : "files") (\(source) source, \(files.count - source) test)"
        if !mockOnly.isEmpty { line += "; \(mockOnly.count) more only mock it" }
        return FeatureCallSites(subject: core.path, files: files, completeness: line, mockOnly: mockOnly.compactMap { infos[$0]?.path }.sorted())
    }

    /// Sites grouped by the function they are in: each call's statement and the statement consuming its result;
    /// a route handler's route; one hop up from a local helper, with what consumes that call.
    func groups(_ info: FeatureContext.FileInfo, refs: [FeatureContext.Ref]) throws -> [FeatureCallSiteGroup] {
        var order: [Int64?] = []
        var byCaller: [Int64?: [FeatureContext.Ref]] = [:]
        for ref in refs where ref.isCall || ref.kind == "read" || ref.kind == "write" {
            if byCaller[ref.fromSymbol] == nil { order.append(ref.fromSymbol) }
            byCaller[ref.fromSymbol, default: []].append(ref)
        }
        var result: [FeatureCallSiteGroup] = []
        for caller in order {
            let refs = (byCaller[caller] ?? []).sorted { ($0.isCall ? 0 : 1, $0.line) < ($1.isCall ? 0 : 1, $1.line) }
            let row = caller.flatMap { context.symbol($0) }
            var name = row.map { context.displayName($0) }
            if let row, let route = RouteLabel.label(path: info.path, handler: row.name, isDefaultExport: row.name == "default") { name = route }
            var sites: [FeatureEvidence] = []
            for (index, ref) in refs.sorted(by: { $0.line < $1.line }).prefix(4).enumerated() {
                let consumer = ref.consumerLine.flatMap { consumerGist(info.path, line: $0) }.map { "→ :\($0.line) \($0.text)" }
                if index == 0, let statement = context.statement(info.path, ref: ref) {
                    sites.append(FeatureEvidence(line: statement.start, code: statement.text(maxLength: 110), kind: ref.isCall ? .call : .read, primary: true, note: consumer))
                } else {
                    let gist = context.gist(info.path, line: ref.line, name: ref.name, limit: 50) ?? ref.name
                    sites.append(FeatureEvidence(line: ref.line, code: gist, kind: ref.isCall ? .call : .read, note: consumer))
                }
            }
            var group = FeatureCallSiteGroup(caller: name, callerLines: row?.lines, sites: sites)
            // One hop up from a helper the file keeps to itself (`openSecret` ← `loadToken :41`).
            if let row, !row.isExported, row.parentID == nil {
                group.calledBy = try localCallers(of: row, in: info)
            }
            result.append(group)
        }
        return result
    }

    /// In-file callers of a local helper with the line of each call, at most 3.
    func localCallers(of helper: RepositoryEngine.SymbolRow, in info: FeatureContext.FileInfo) throws -> [FeatureCaller] {
        let rows = try context.refs(where: "r.file_id = ? AND r.target_symbol_id = ? AND r.confidence >= ? ORDER BY r.line", [info.id, helper.id, context.threshold])
        var callers: [FeatureCaller] = []
        for ref in rows.prefix(3) {
            let name = ref.fromSymbol.flatMap { context.symbol($0) }.map { context.displayName($0) }
            let consumer = ref.consumerLine.flatMap { consumerGist(info.path, line: $0) }.map { "→ :\($0.line) \($0.text)" }
            callers.append(FeatureCaller(name: name, path: info.path, line: ref.line, note: consumer))
        }
        return callers
    }

    /// The consuming statement's head line, short (`db.insert(apiTokens)`).
    func consumerGist(_ path: String, line: Int) -> (line: Int, text: String)? {
        guard let consumer = context.engine.sourceText.consumer(path, line: line, maxLength: 60) else { return nil }
        return (consumer.number, consumer.text)
    }
}
