import Foundation
import GraphEngine
import RepositoryIndex
import VesaliusCore

/// Circular imports: strongly connected components of the import graph in a scope, built from `imports`
/// rows alone (mock imports never count), with each cycle's import statements, the uses that make them runtime
/// dependencies, a load-time verdict, the same check on value-only and static-only edges, the barrels that
/// re-export the cycle, and a stamp of everything scanned.
///
/// Swift has no file imports: its files see their whole module. For Swift files the module import graph
/// (`imports.resolved_module_id` from the files' build targets) is checked instead.
extension RepositoryEngine {
    public func importCycles(path: String? = nil, includeTests: Bool = false) throws -> ImportCycleReport {
        let scope = try cycleScope(path)
        var report = try memoized("import-cycles|\(scope.key)|\(includeTests)") {
            try computeImportCycles(scope, includeTests: includeTests)
        }
        // Checked on every call: a file edited after the memo was filled must still be caught.
        report.staleFiles = try staleFiles(Array(Set(report.cycles.flatMap(\.files))).sorted())
        return report
    }

    /// The folder (or file) a cycle check covers.
    struct CycleScope: Sendable {
        /// Folder without a trailing slash; empty for the whole repository.
        let folder: String
        /// A file whose cycles are asked for: the repository is checked and only cycles through it are kept.
        let file: String?

        var key: String { file.map { "file:" + $0 } ?? "dir:" + folder }

        func contains(_ path: String) -> Bool {
            folder.isEmpty || path.hasPrefix(folder + "/")
        }
    }

    func cycleScope(_ text: String?) throws -> CycleScope {
        var query = Self.normalizedTarget(text ?? "", root: root)
        while query.hasSuffix("/") { query.removeLast() }
        if query.isEmpty || query == "." { return CycleScope(folder: "", file: nil) }
        let paths = try db.query("SELECT path FROM files", cache: true) { $0.string(0) }
        if paths.contains(query) { return CycleScope(folder: "", file: query) }
        if paths.contains(where: { $0.hasPrefix(query + "/") }) { return CycleScope(folder: query, file: nil) }
        // A folder or file named by a unique path suffix (`shop/` for `src/lib/shop/`).
        let fileMatches = paths.filter { $0.hasSuffix("/" + query) }
        if fileMatches.count == 1 { return CycleScope(folder: "", file: fileMatches[0]) }
        let folders = Set(paths.compactMap { path -> String? in
            guard let range = path.range(of: "/" + query + "/") else { return nil }
            return String(path[..<range.upperBound].dropLast())
        })
        if folders.count == 1, let folder = folders.first { return CycleScope(folder: folder, file: nil) }
        let choices = folders.sorted().map { $0 + "/" } + fileMatches.sorted()
        guard choices.isEmpty else {
            throw EngineError.invalidQuery("“\(text ?? query)” names \(choices.count) paths; pass one of: " + choices.prefix(8).joined(separator: ", ")
                + (choices.count > 8 ? " (+\(choices.count - 8) more)" : ""))
        }
        throw EngineError.notFound(text ?? query, suggestions: Self.topFolders(paths))
    }

    private static func topFolders(_ paths: [String]) -> [String] {
        var seen: [String] = []
        for path in paths {
            guard let slash = path.firstIndex(of: "/") else { continue }
            let folder = String(path[..<slash]) + "/"
            if !seen.contains(folder) { seen.append(folder) }
        }
        return Array(seen.sorted().prefix(8))
    }

    // MARK: - Computation

    /// One file of the repository as the cycle check sees it.
    private struct CycleFile {
        let path: String
        let language: Language
        let isTest: Bool
        let moduleID: Int64?
    }

    /// An import statement between two files: the rows of one statement (Python stores one per name) merged.
    private struct ImportStatement {
        let from: Int64
        let to: Int64
        let line: Int
        var endLine: Int
        let module: String
        var names: [ImportedName]
        var isTypeOnly: Bool
        var isReexport: Bool
        var isDynamic: Bool
        var isSideEffect: Bool
    }

    private func computeImportCycles(_ scope: CycleScope, includeTests: Bool) throws -> ImportCycleReport {
        let db = try db
        var files: [Int64: CycleFile] = [:]
        try db.forEach("SELECT id, path, language, is_test, module_id FROM files") { row in
            files[row.int64(0)] = CycleFile(path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown, isTest: row.bool(3), moduleID: row.optionalInt64(4))
        }
        func kept(_ id: Int64) -> Bool {
            guard let file = files[id] else { return false }
            return includeTests || !file.isTest
        }
        func inScope(_ id: Int64) -> Bool {
            guard let file = files[id] else { return false }
            return scope.contains(file.path) && kept(id)
        }

        // Statements and the stamp.
        var statements: [String: ImportStatement] = [:]
        var order: [String] = []
        var importers = Set<Int64>()
        var unresolved: [ImportSite] = []
        var leaving = 0
        var mocks = 0
        var swiftImports: [(file: Int64, line: Int, module: Int64)] = []
        try db.forEach("""
            SELECT file_id, module, names, line, end_line, is_type_only, is_reexport, is_dynamic, is_side_effect, is_mock,
                   resolved_file_id, resolved_module_id, external_name
            FROM imports ORDER BY file_id, line, id
            """) { row in
            let fileID = row.int64(0)
            guard inScope(fileID), let file = files[fileID] else { return }
            importers.insert(fileID)
            if row.bool(9) {
                mocks += 1
                return
            }
            let target = row.optionalInt64(10)
            if file.language == .swift, let module = row.optionalInt64(11) {
                swiftImports.append((fileID, row.int(3), module))
            }
            guard let target else {
                if row.isNull(11) && row.isNull(12) { unresolved.append(ImportSite(path: file.path, line: row.int(3), module: row.string(1))) }
                return
            }
            guard target != fileID else { return }
            guard inScope(target) else {
                if let other = files[target], !scope.contains(other.path) { leaving += 1 }
                return
            }
            let line = row.int(3)
            let key = "\(fileID):\(line):\(target)"
            let names = ImportNamesCodec.decode(row.optionalString(2))
            if var statement = statements[key] {
                statement.names += names
                statement.endLine = max(statement.endLine, row.optionalInt(4) ?? line)
                statement.isTypeOnly = statement.isTypeOnly && row.bool(5)
                statement.isReexport = statement.isReexport || row.bool(6)
                statement.isDynamic = statement.isDynamic || row.bool(7)
                statement.isSideEffect = statement.isSideEffect || row.bool(8)
                statements[key] = statement
            } else {
                order.append(key)
                statements[key] = ImportStatement(from: fileID, to: target, line: line, endLine: row.optionalInt(4) ?? line, module: row.string(1), names: names,
                                                  isTypeOnly: row.bool(5), isReexport: row.bool(6), isDynamic: row.bool(7), isSideEffect: row.bool(8))
            }
        }
        let edges = order.compactMap { statements[$0] }

        let folderFiles = files.filter { scope.contains($0.value.path) && ($0.value.language.isCode || importers.contains($0.key)) }
        let scanned = folderFiles.filter { kept($0.key) }.count
        var languages: [String: Int] = [:]
        for edge in edges { languages[files[edge.from]?.language.displayName ?? "Other", default: 0] += 1 }
        let stamp = ImportCycleScope(
            path: scope.file ?? (scope.folder.isEmpty ? nil : scope.folder), isFile: scope.file != nil, includeTests: includeTests,
            files: scanned, testFilesExcluded: folderFiles.count - scanned, edges: edges.count, edgeLanguages: languages,
            unresolved: unresolved.count, unresolvedSites: Array(unresolved.prefix(5)), leavingScope: leaving,
            typeOnly: edges.filter(\.isTypeOnly).count, reexports: edges.filter(\.isReexport).count,
            dynamic: edges.filter(\.isDynamic).count, sideEffect: edges.filter(\.isSideEffect).count, mocks: mocks)

        // The graph: nodes are the files with an edge, numbered in path order so results are stable.
        let nodeIDs = Array(Set(edges.flatMap { [$0.from, $0.to] })).sorted { files[$0]!.path < files[$1]!.path }
        let nodeIndex = Dictionary(uniqueKeysWithValues: nodeIDs.enumerated().map { ($1, $0) })
        let graph = DependencyGraph(nodeCount: nodeIDs.count, edges: edges.map { (nodeIndex[$0.from]!, nodeIndex[$0.to]!, 1.0) })
        var components = graph.stronglyConnectedComponents().filter { $0.count > 1 }
        if let file = scope.file {
            components = components.filter { $0.contains { files[nodeIDs[$0]]?.path == file } }
        }
        components.sort { $0.count != $1.count ? $0.count > $1.count : files[nodeIDs[$0[0]]]!.path < files[nodeIDs[$1[0]]]!.path }

        var loadRunners: [Int64: [Int64: String]] = [:]
        var cycles: [ImportCycle] = []
        for (offset, component) in components.enumerated() {
            let members = Set(component.map { nodeIDs[$0] })
            let inside = edges.filter { members.contains($0.from) && members.contains($0.to) }
            let walk = graph.cyclePath(in: component).map { nodeIDs[$0] }
            var hops: [(Int64, Int64)] = []
            for index in walk.indices.dropLast() where !hops.contains(where: { $0 == (walk[index], walk[index + 1]) }) {
                hops.append((walk[index], walk[index + 1]))
            }
            // The walk's hops in order, then every other import between members.
            let ordered = hops.flatMap { hop in inside.filter { $0.from == hop.0 && $0.to == hop.1 }.sorted { $0.line < $1.line } }
                + inside.filter { edge in !hops.contains { $0 == (edge.from, edge.to) } }.sorted { (files[$0.from]!.path, $0.line) < (files[$1.from]!.path, $1.line) }

            var cycleEdges: [ImportCycleEdge] = []
            var loadUses: [ImportLoadUse] = []
            var usesByPair: [String: [PairUse]] = [:]
            for statement in ordered {
                let pair = "\(statement.from)>\(statement.to)"
                if usesByPair[pair] == nil { usesByPair[pair] = try pairUses(from: statement.from, to: statement.to) }
                let pairUses = usesByPair[pair] ?? []
                let siblings = ordered.filter { $0.from == statement.from && $0.to == statement.to }
                let uses = Self.uses(of: statement, among: pairUses, siblings: siblings)
                let runners: [Int64: String]
                if let cached = loadRunners[statement.from] {
                    runners = cached
                } else {
                    runners = try loadTimeRunners(fileID: statement.from)
                    loadRunners[statement.from] = runners
                }
                guard let fromFile = files[statement.from], let toFile = files[statement.to] else { continue }
                let shown = uses.map { found -> ImportUse in
                    var use = found.use
                    if !use.isTypeUse, !use.atLoad, let symbol = found.fromSymbol, let via = runners[symbol] {
                        use.atLoad = true
                        use.via = via
                    }
                    return use
                }
                for use in shown where use.atLoad && !use.isTypeUse && !statement.isTypeOnly {
                    loadUses.append(ImportLoadUse(path: fromFile.path, line: use.line, name: use.name, enclosing: use.enclosing, via: use.via))
                }
                let isValue = try isValueImport(statement, language: fromFile.language, uses: shown)
                if fromFile.language == .python, isValue, !statement.isDynamic, !statement.isTypeOnly,
                   let name = statement.names.first(where: { $0.name != "*" || $0.alias == nil }) {
                    // `from m import x` reads x from the other module while this one loads.
                    loadUses.append(ImportLoadUse(path: fromFile.path, line: statement.line, name: name.name, isFromImport: true))
                }
                cycleEdges.append(ImportCycleEdge(
                    from: fromFile.path, to: toFile.path, line: statement.line, endLine: statement.endLine,
                    statement: importStatementText(fromFile.path, line: statement.line, endLine: statement.endLine), module: statement.module,
                    names: statement.names, isTypeOnly: statement.isTypeOnly, isReexport: statement.isReexport,
                    isDynamic: statement.isDynamic, isSideEffect: statement.isSideEffect, isValue: isValue,
                    uses: shown, definitions: try definitions(of: statement, uses: uses)))
            }

            // The same check on value-only edges, then without dynamic imports.
            func modeComponents(_ keep: (ImportCycleEdge) -> Bool) -> [[String]] {
                let paths = Array(members).compactMap { files[$0]?.path }.sorted()
                let index = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($1, $0) })
                let sub = DependencyGraph(nodeCount: paths.count, edges: cycleEdges.filter(keep).compactMap { edge in
                    guard let a = index[edge.from], let b = index[edge.to] else { return nil }
                    return (a, b, 1.0)
                })
                return sub.stronglyConnectedComponents().filter { $0.count > 1 }.map { $0.map { paths[$0] }.sorted() }
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
            }
            let valueOnly = modeComponents { $0.isValue }
            let staticOnly = modeComponents { $0.isValue && !$0.isDynamic }

            // Barrels: files outside the cycle re-exporting from its members.
            var barrels: [Int64: (members: Set<String>, lines: Set<Int>)] = [:]
            for edge in edges where edge.isReexport && members.contains(edge.to) && !members.contains(edge.from) {
                barrels[edge.from, default: ([], [])].members.insert(files[edge.to]!.path)
                barrels[edge.from, default: ([], [])].lines.insert(edge.line)
            }
            let barrelList = barrels.map { ImportBarrel(path: files[$0.key]!.path, members: $0.value.members.sorted(), lines: $0.value.lines.sorted()) }
                .sorted { $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.path < $1.path }

            cycles.append(ImportCycle(
                id: offset + 1, files: members.compactMap { files[$0]?.path }.sorted(), path: walk.compactMap { files[$0]?.path },
                edges: cycleEdges, loadTimeUses: loadUses, valueOnly: valueOnly, staticOnly: staticOnly, barrels: barrelList))
        }

        return ImportCycleReport(
            scope: stamp, cycles: cycles,
            crossingCycles: try crossingComponents(scope, includeTests: includeTests, files: files),
            swiftModules: try swiftModuleImports(scope, includeTests: includeTests, files: files, imports: swiftImports))
    }

    /// Components of the repository-wide import graph with files both in the folder and outside it.
    private func crossingComponents(_ scope: CycleScope, includeTests: Bool, files: [Int64: CycleFile]) throws -> Int {
        guard !scope.folder.isEmpty else { return 0 }
        var pairs = Set<[Int64]>()
        try db.forEach("SELECT DISTINCT file_id, resolved_file_id FROM imports WHERE resolved_file_id IS NOT NULL AND resolved_file_id != file_id AND is_mock = 0") { row in
            let a = row.int64(0), b = row.int64(1)
            guard let fa = files[a], let fb = files[b], includeTests || (!fa.isTest && !fb.isTest) else { return }
            pairs.insert([a, b])
        }
        let ids = Array(Set(pairs.flatMap { $0 })).sorted()
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let graph = DependencyGraph(nodeCount: ids.count, edges: pairs.map { (index[$0[0]]!, index[$0[1]]!, 1.0) })
        return graph.stronglyConnectedComponents().filter { component in
            guard component.count > 1 else { return false }
            let paths = component.compactMap { files[ids[$0]]?.path }
            return paths.contains(where: scope.contains) && !paths.allSatisfy(scope.contains)
        }.count
    }

    // MARK: - Uses

    /// A reference in one file to a declaration of another, with what the cycle check needs to place it.
    private struct PairUse {
        let use: ImportUse
        let fromSymbol: Int64?
        let targetName: String
        let targetLine: Int
    }

    /// References from `from` to top-level declarations of `to` (the bindings an import makes available) at the
    /// use threshold, in line order. A member reached through one of them (`Foo.bar`, `client.get()`) is not a
    /// separate use: the binding it goes through is.
    private func pairUses(from: Int64, to: Int64) throws -> [PairUse] {
        try db.query("""
            SELECT r.line, r.kind, r.at_load, r.from_symbol_id, s.qualified_name, s.kind, t.name, t.start_line
            FROM refs r JOIN symbols t ON t.id = r.target_symbol_id LEFT JOIN symbols s ON s.id = r.from_symbol_id
            WHERE r.file_id = ? AND r.target_file_id = ? AND r.confidence >= ? AND t.parent_id IS NULL
            ORDER BY r.line, r.col
            """, [from, to, Self.useThreshold]) { row in
            let kind = ReferenceKind(rawValue: row.string(1)) ?? .read
            let enclosingKind = row.optionalString(5).flatMap(SymbolKind.init(rawValue:))
            return PairUse(
                use: ImportUse(name: row.string(6), line: row.int(0), kind: kind, enclosing: row.optionalString(4), enclosingIsCallable: enclosingKind?.isCallable ?? false,
                               atLoad: row.bool(2) && kind != .typeUse && kind != .conform),
                fromSymbol: row.optionalInt64(3), targetName: row.string(6), targetLine: row.int(7))
        }
    }

    /// The uses that belong to one statement: those of the names it imports; uses no sibling statement claims
    /// (a default or namespace import, or one the linker reached another way) go to the first value import.
    private static func uses(of statement: ImportStatement, among uses: [PairUse], siblings: [ImportStatement]) -> [PairUse] {
        guard siblings.count > 1 else { return uses }
        func claims(_ candidate: ImportStatement, _ use: PairUse) -> Bool {
            candidate.names.contains { $0.name == use.use.name || $0.localName == use.use.name }
        }
        let fallback = siblings.first { !$0.isTypeOnly } ?? siblings[0]
        return uses.filter { use in
            if claims(statement, use) { return true }
            return !siblings.contains { claims($0, use) } && fallback.line == statement.line
        }
    }

    /// Whether an import loads its target at runtime. TypeScript drops `import type`, and imports whose names
    /// are only used as types; other languages load every import that is not type-only.
    private func isValueImport(_ statement: ImportStatement, language: Language, uses: [ImportUse]) throws -> Bool {
        if statement.isTypeOnly { return false }
        guard language == .typescript else { return true }
        if !statement.names.isEmpty && statement.names.allSatisfy(\.isTypeOnly) { return false }
        if statement.isSideEffect || statement.isDynamic || statement.isReexport { return true }
        if uses.contains(where: { !$0.isTypeUse }) { return true }
        // A value use the linker left unresolved still keeps the import.
        let locals = statement.names.filter { !$0.isTypeOnly }.map(\.localName)
        guard !locals.isEmpty else { return false }
        let marks = locals.map { _ in "?" }.joined(separator: ",")
        return try db.scalarInt("""
            SELECT COUNT(*) FROM refs WHERE file_id = ? AND kind NOT IN ('type', 'conform') AND (name IN (\(marks)) OR receiver IN (\(marks)))
            """, [statement.from] + locals + locals) > 0
    }

    /// Where the imported names are declared in the imported file. A default or namespace import names no
    /// declaration, so the declarations it is used for stand in.
    private func definitions(of statement: ImportStatement, uses: [PairUse]) throws -> [ImportDefinition] {
        var found: [String: Int] = [:]
        let named = statement.names.filter { $0.name != "*" && $0.name != "default" }
        for name in named {
            if let use = uses.first(where: { $0.targetName == name.name }) {
                found[name.name] = use.targetLine
            } else if let line = try db.queryOne("SELECT start_line FROM symbols WHERE file_id = ? AND name = ? AND parent_id IS NULL ORDER BY start_line LIMIT 1",
                                                 [statement.to, name.name], { $0.int(0) }) {
                found[name.name] = line
            }
        }
        if named.count < statement.names.count {
            for use in uses where found[use.targetName] == nil { found[use.targetName] = use.targetLine }
        }
        return found.map { ImportDefinition(name: $0.key, line: $0.value) }.sorted { ($0.line, $0.name) < ($1.line, $1.name) }
    }

    /// The symbols of a file that run while it loads, each with the top-level function or class that leads to it:
    /// what top-level code calls or instantiates in the same file, and transitively what those call. Instantiating
    /// a class (in Python, calling it) runs its constructor and instance field initializers.
    private func loadTimeRunners(fileID: Int64) throws -> [Int64: String] {
        struct Call { let from: Int64?; let target: Int64; let atLoad: Bool }
        let calls = try db.query("""
            SELECT from_symbol_id, target_symbol_id, at_load FROM refs
            WHERE file_id = ? AND target_file_id = ? AND target_symbol_id IS NOT NULL AND kind IN ('call', 'instantiate') AND confidence >= ?
            """, [fileID, fileID, Self.useThreshold]) { Call(from: $0.optionalInt64(0), target: $0.int64(1), atLoad: $0.bool(2)) }
        guard calls.contains(where: \.atLoad) else { return [:] }
        struct Member { let id: Int64; let name: String; let kind: SymbolKind }
        var symbols: [Int64: Member] = [:]
        var children: [Int64: [Member]] = [:]
        try db.forEach("SELECT id, parent_id, name, kind FROM symbols WHERE file_id = ?", [fileID]) { row in
            let member = Member(id: row.int64(0), name: row.string(2), kind: SymbolKind(rawValue: row.string(3)) ?? .variable)
            symbols[member.id] = member
            if let parent = row.optionalInt64(1) { children[parent, default: []].append(member) }
        }
        var runners: [Int64: String] = [:]
        var queue: [Int64] = []
        func add(_ id: Int64, via: String) {
            guard runners[id] == nil else { return }
            runners[id] = via
            queue.append(id)
            guard symbols[id]?.kind.isType == true else { return }
            for member in children[id] ?? [] where member.kind == .initializer || member.kind == .property || member.name == "constructor" || member.name == "__init__" {
                add(member.id, via: via)
            }
        }
        for call in calls where call.atLoad {
            add(call.target, via: symbols[call.target]?.name ?? "")
        }
        while let id = queue.popLast() {
            guard let via = runners[id] else { continue }
            for call in calls where call.from == id { add(call.target, via: via) }
        }
        return runners
    }

    /// The import statement's text: its lines with comments dropped and whitespace collapsed (at most 40 lines).
    private func importStatementText(_ path: String, line: Int, endLine: Int) -> String? {
        guard let file = sourceText.file(path), line >= 1, line <= file.lineCount else { return nil }
        let last = min(file.lineCount, max(line, endLine), line + 40)
        let parts = (line...last).compactMap { file.range(ofLine: $0).map(file.codeText) }.filter { !$0.isEmpty }
        let text = Statement.collapse(parts.joined(separator: " "))
        return text.isEmpty ? nil : text
    }

    // MARK: - Swift modules

    /// The module import graph of the Swift files in scope: each file's modules come from its build targets
    /// (else its detected module); an `import` of a repository module is a dependency of each of them.
    private func swiftModuleImports(_ scope: CycleScope, includeTests: Bool, files: [Int64: CycleFile],
                                    imports: [(file: Int64, line: Int, module: Int64)]) throws -> SwiftModuleImports? {
        let swiftFiles = files.filter { $0.value.language == .swift && scope.contains($0.value.path) && (includeTests || !$0.value.isTest) }
        guard !swiftFiles.isEmpty else { return nil }
        var targetModules: [Int64: Set<Int64>] = [:]
        try db.forEach("SELECT ft.file_id, t.module_id FROM file_targets ft JOIN targets t ON t.id = ft.target_id WHERE t.module_id IS NOT NULL") { row in
            targetModules[row.int64(0), default: []].insert(row.int64(1))
        }
        var moduleNames: [Int64: String] = [:]
        try db.forEach("SELECT id, name FROM modules") { moduleNames[$0.int64(0)] = $0.string(1) }
        func modules(of file: Int64) -> Set<Int64> {
            targetModules[file] ?? (files[file]?.moduleID).map { [$0] } ?? []
        }

        var involved = Set<Int64>()
        for id in swiftFiles.keys { involved.formUnion(modules(of: id)) }
        var dependencies: [[Int64]: ImportSite] = [:]
        var lines = 0
        for entry in imports where swiftFiles[entry.file] != nil {
            lines += 1
            involved.insert(entry.module)
            for source in modules(of: entry.file) where source != entry.module {
                let key = [source, entry.module]
                if dependencies[key] == nil, let path = files[entry.file]?.path {
                    dependencies[key] = ImportSite(path: path, line: entry.line, module: moduleNames[entry.module] ?? "")
                }
            }
        }
        let ids = involved.sorted { (moduleNames[$0] ?? "", $0) < (moduleNames[$1] ?? "", $1) }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let graph = DependencyGraph(nodeCount: ids.count, edges: dependencies.keys.compactMap { key in
            guard let a = index[key[0]], let b = index[key[1]] else { return nil }
            return (a, b, 1.0)
        })
        // Component arrays are sorted node indices, and nodes are numbered in name order.
        let components = graph.stronglyConnectedComponents().filter { $0.count > 1 }.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
        let cycles = components.map { $0.map { moduleNames[ids[$0]] ?? "?" }.sorted() }
        let cycleImports = components.map { component -> [ImportSite] in
            let members = Set(component.map { ids[$0] })
            return dependencies.filter { members.contains($0.key[0]) && members.contains($0.key[1]) }.map(\.value)
                .sorted { ($0.path, $0.line) < ($1.path, $1.line) }
        }
        return SwiftModuleImports(modules: involved.count, dependencies: dependencies.count, importLines: lines, cycles: cycles, cycleImports: cycleImports)
    }
}
