import Foundation
import RepositoryIndex
import VesaliusCore

/// `outline`: what a file, type, folder or function contains, read from the index.
///
/// - A file: its top-level declarations with their members, its imports, what it calls in other files,
///   frameworks and the environment, its build targets and how many files use it; a Markdown file its headings.
/// - A type: its members and extensions, and what they call outside the type.
/// - A file's extensions of a type (`path#Name`, or `path:line` for one of them): their members, and what they
///   call outside them.
/// - A function: its flow, plus its calls out.
/// - A property, case or alias: its declaration and the type that owns it.
/// - A folder or module: its files with their main declarations.
/// - A name declared in several places: the exact target of each ("where is X declared").
///
/// Targets use the `usages` grammar (`Type.member`, `Type.method(label:)`, `path#Name`, `path:line`, a path or
/// a unique path suffix, a folder, a module). The result is computed once per index version.
extension RepositoryEngine {
    public func outline(_ target: String) throws -> OutlineResult {
        var result: OutlineResult
        switch try resolveUsageTarget(target) {
        case .file(let id, let path):
            result = try memoized("outline|file|\(id)") { try OutlineBuilder(engine: self).file(id: id, path: path) }
        case .folder(let path, let fileIDs):
            result = try memoized("outline|folder|\(path)") { try OutlineBuilder(engine: self).folder(path: path, module: nil, fileIDs: fileIDs) }
        case .module(let name, let fileIDs):
            result = try memoized("outline|module|\(name)") { try OutlineBuilder(engine: self).folder(path: nil, module: name, fileIDs: fileIDs) }
        case .symbol(let rows):
            // Keyed by every row: `path:line` selects one of a file's extensions, `path#Name` all of them.
            result = try memoized("outline|symbol|\(rows.map { String($0.id) }.joined(separator: ","))") { try OutlineBuilder(engine: self).symbol(rows) }
        case .choices(let choices):
            result = try OutlineBuilder(engine: self).choices(choices)
        case .framework(let name, let importers):
            let files = Set(importers.map(\.path)).count
            throw EngineError.invalidQuery("\(name) is a framework (imported by \(files) \(files == 1 ? "file" : "files")), not a declaration of this repository: usages(target:\(OutlineBuilder.quoted(name))) lists its importers and the calls they make.")
        case .environment(let name):
            throw EngineError.invalidQuery("env:\(name) is an environment variable: usages(target:\(OutlineBuilder.quoted("env:" + name))) lists where it is read and written.")
        }
        // The memo is per declaration, whatever spelling found it; staleness is checked on every call.
        result.target = target
        result.staleFiles = try staleFiles(result.quotedFiles)
        return result
    }
}

/// Builds outlines from the index.
struct OutlineBuilder {
    let engine: RepositoryEngine
    let db: SQLiteDatabase

    init(engine: RepositoryEngine) throws {
        self.engine = engine
        self.db = try engine.db
    }

    /// A target as a tool call writes it: `"Foo.bar"`, quotes and backslashes escaped.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The most declarations a file, type or folder outline carries. Beyond it the renderer would cut anyway.
    static let maximumDeclarations = 400
    /// The characters a type's budget is computed from at least: 300 tokens.
    static let typeFloorCharacters = 4_500
    /// Primary declarations listed per file of a folder.
    static let primaryPerFile = 3
    /// A module imported by at least this share of the repository's code files says little about one file's
    /// purpose; its calls are counted, not listed by name.
    static let ambientShare = 0.2

    // MARK: Files

    struct FileInfo {
        let id: Int64
        let path: String
        let language: Language
        let lines: Int
        let size: Int
        let isTest: Bool
        let testKind: String?
        let analyzer: String?
        let parseStatus: String
        let parseMessage: String?
        let moduleID: Int64?

        /// Why the index may miss declarations or calls of this file.
        var note: String? {
            if parseStatus != "ok" {
                return "did not parse" + (parseMessage.map { " (\(OutlineSignature.shorten($0, to: 80)))" } ?? "") + ": declarations may be missing; Read the file"
            }
            if analyzer == "lexical" { return "scanned lexically: declarations and calls are approximate" }
            return nil
        }
    }

    func fileInfo(_ id: Int64) throws -> FileInfo? {
        try db.queryOne("""
            SELECT id, path, language, line_count, size, is_test, test_kind, analyzer, parse_status, parse_message, module_id
            FROM files WHERE id = ?
            """, [id]) { row in
            FileInfo(id: row.int64(0), path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown, lines: row.int(3), size: row.int(4),
                     isTest: row.bool(5), testKind: row.optionalString(6), analyzer: row.optionalString(7), parseStatus: row.string(8),
                     parseMessage: row.optionalString(9), moduleID: row.optionalInt64(10))
        }
    }

    func file(id: Int64, path: String) throws -> OutlineResult {
        guard let info = try fileInfo(id) else { throw EngineError.notFound(path, suggestions: []) }
        let tree = try OutlineTree(rows(inFile: id))
        let declarations = tree.roots.prefix(Self.maximumDeclarations).map { declaration($0, tree: tree, language: info.language, path: info.path) }
        let file = OutlineFile(
            path: info.path, language: info.language.displayName, lines: info.lines, targets: try targets(ofFiles: [id]).map(\.name),
            testKind: info.isTest ? (info.testKind ?? "test") : nil, usedBy: try usedBy(files: [id]), declarations: Array(declarations),
            imports: try imports(ofFile: id), calls: try calls(CallScope(files: [id: info.language], symbols: nil, inside: [], insideFiles: [id])),
            headings: info.language == .markdown ? headings(info.path) : [], note: info.note)
        return OutlineResult(kind: .file, target: path, sourceCharacters: info.size, file: file)
    }

    /// A Markdown file's ATX headings (`#` to `######`), outside fenced code blocks.
    func headings(_ path: String) -> [OutlineHeading] {
        guard let text = engine.sourceText.file(path) else { return [] }
        var headings: [OutlineHeading] = []
        var fenced = false
        for number in 1...max(1, text.lineCount) {
            guard let line = text.text(ofLine: number)?.trimmingCharacters(in: .whitespaces) else { continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fenced.toggle()
                continue
            }
            guard !fenced, line.hasPrefix("#") else { continue }
            let level = line.prefix { $0 == "#" }.count
            let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
            guard level <= 6, line.dropFirst(level).first == " ", !title.isEmpty else { continue }
            headings.append(OutlineHeading(line: number, level: level, text: OutlineSignature.shorten(title, to: 80)))
            if headings.count >= Self.maximumDeclarations { break }
        }
        return headings
    }

    // MARK: Declarations

    /// A symbol row with the columns an outline line needs.
    struct Row {
        let id: Int64
        let fileID: Int64
        let parentID: Int64?
        let name: String
        let qualifiedName: String
        let kind: SymbolKind
        let lines: LineRange
        let signature: String?
        let doc: String?
        let visibility: Visibility?
        let isExported: Bool
        let depth: Int
        /// Attributes and modifiers as the collector stored them (`@MainActor`, `final`, `static`, `async`).
        let attributes: [String]
        let setterVisibility: Visibility?
        let conditions: String?
        let selector: String?
    }

    static let rowColumns = """
        s.id, s.file_id, s.parent_id, s.name, s.qualified_name, s.kind, s.start_line, s.end_line, s.signature, s.doc, s.visibility,
        s.is_exported, s.depth, s.attributes, s.setter_visibility, s.conditions, s.selector
        """

    static func row(_ row: SQLRow) -> Row {
        Row(id: row.int64(0), fileID: row.int64(1), parentID: row.optionalInt64(2), name: row.string(3), qualifiedName: row.string(4),
            kind: SymbolKind(rawValue: row.string(5)) ?? .variable, lines: LineRange(row.int(6), row.int(7)), signature: row.optionalString(8),
            doc: row.optionalString(9), visibility: row.optionalString(10).flatMap(Visibility.init(rawValue:)), isExported: row.bool(11),
            depth: row.int(12), attributes: (row.optionalString(13) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            setterVisibility: row.optionalString(14).flatMap(Visibility.init(rawValue:)), conditions: row.optionalString(15), selector: row.optionalString(16))
    }

    /// A file's declarations, function-local ones left out.
    func rows(inFile fileID: Int64) throws -> [Row] {
        try db.query("SELECT \(Self.rowColumns) FROM symbols s WHERE s.file_id = ? AND s.is_local = 0 ORDER BY s.start_line, s.id", [fileID], Self.row)
    }

    /// One declaration with its members, as the outline shows it.
    func declaration(_ row: Row, tree: OutlineTree, language: Language, path: String) -> OutlineDeclaration {
        var signature = row.signature.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        // TypeScript and JavaScript signatures are stored without the `export` they are written with.
        if row.isExported, row.parentID == nil, language == .typescript || language == .javascript, let text = signature, !text.hasPrefix("export") {
            signature = "export " + text
        }
        // A Python line can keep its colon and a trailing comment (`def main(): # Base paths`).
        if language == .python, let text = signature { signature = OutlineSignature.withoutPythonTail(text) }
        let parts = signature.map { OutlineSignature.parts($0, name: row.name, kind: row.kind, language: language) } ?? OutlineSignature.Parts()
        let modifiers = Set(row.attributes.filter { !$0.hasPrefix("@") })
        let isMember = !row.kind.isContainer || row.kind == .typeAlias
        var selector = row.selector
        if selector == nil, language == .swift {
            selector = RepositoryEngine.selector(name: row.name, kind: row.kind, signature: signature)
        }
        var access: String?
        if let visibility = row.visibility, visibility == .private || visibility == .fileprivate { access = visibility.rawValue }
        var setterAccess: String?
        if let setter = row.setterVisibility, setter == .private || setter == .fileprivate, access == nil { setterAccess = setter.rawValue }
        // A Next.js handler says which route it serves.
        let route = row.parentID == nil && row.kind.isCallable && (language == .typescript || language == .javascript)
            ? RouteLabel.label(path: path, handler: row.name, isDefaultExport: row.name == "default") : nil
        return OutlineDeclaration(
            name: row.name, qualifiedName: row.qualifiedName, kind: row.kind, lines: row.lines, signature: signature, route: route,
            doc: OutlineSignature.firstSentence(row.doc), selector: selector,
            attributes: row.attributes.filter { $0.hasPrefix("@") }.map(OutlineSignature.attributeName),
            isStatic: isMember && (modifiers.contains("static") || modifiers.contains("class") || parts.isStatic),
            access: access, setterAccess: setterAccess, isExported: row.isExported,
            type: parts.type, value: parts.value, effects: parts.effects, parameters: parts.parameters, condition: row.conditions,
            members: (tree.children[row.id] ?? []).prefix(Self.maximumDeclarations).map { declaration($0, tree: tree, language: language, path: path) })
    }

    // MARK: Declarations by target

    func symbol(_ rows: [RepositoryEngine.SymbolRow]) throws -> OutlineResult {
        let first = rows[0]
        guard let info = try fileInfo(first.fileID) else { throw EngineError.notFound(first.qualifiedName, suggestions: []) }
        let tree = try OutlineTree(self.rows(inFile: first.fileID))
        // A function-local declaration is not in the tree; it is outlined on its own.
        let loaded = try tree.row(first.id) ?? db.queryOne("SELECT \(Self.rowColumns) FROM symbols s WHERE s.id = ?", [first.id], Self.row)
        guard let row = loaded else { throw EngineError.notFound(first.qualifiedName, suggestions: []) }
        var declaration = self.declaration(row, tree: tree, language: info.language, path: info.path)
        // `#if` variants of one declaration: their members together, in line order. A file's other extensions of
        // the same type keep their own lines.
        var others: [OutlineExtension] = []
        for variant in rows.dropFirst() {
            guard let other = tree.row(variant.id) else { continue }
            let outlined = self.declaration(other, tree: tree, language: info.language, path: info.path)
            if row.kind == .extension {
                others.append(OutlineExtension(path: info.path, declaration: outlined))
            } else {
                declaration.members += outlined.members
            }
        }
        declaration.members.sort { ($0.lines.start, $0.name) < ($1.lines.start, $1.name) }

        var symbol = OutlineSymbol(path: info.path, language: info.language.displayName, declaration: declaration, targets: try targets(ofFiles: [info.id]).map(\.name),
                                   extensions: others)
        if let parentID = row.parentID, let parent = tree.row(parentID) {
            symbol.owner = parent.kind == .extension ? "extension " + parent.name : parent.qualifiedName
            symbol.ownerLines = parent.lines
        }

        // What belongs to the declaration: its rows, their members, and for a type its extensions' members.
        var inside = Set(rows.map(\.id))
        for variant in rows { inside.formUnion(tree.descendants(of: variant.id).map(\.id)) }
        var fromSymbols = inside
        var extensionFiles: [Int64] = []
        // A type's outline stands in for reading the type: a fifth of its own characters, but room for a
        // screenful of members (300 tokens), and never more than a fifth of its file. So does an extension's.
        let isExtension = row.kind == .extension
        var sourceCharacters = row.kind.isType ? spanCharacters(info, lines: row.lines)
            : isExtension ? rows.reduce(0) { $0 + spanCharacters(info, lines: $1.lines) } : info.size
        if row.kind.isType {
            for (extensionRow, extensionInfo, extensionTree) in try extensions(of: row, file: info) {
                symbol.extensions.append(OutlineExtension(path: extensionInfo.path, declaration: self.declaration(extensionRow, tree: extensionTree, language: extensionInfo.language, path: extensionInfo.path)))
                let members = extensionTree.descendants(of: extensionRow.id).map(\.id)
                inside.formUnion(members)
                sourceCharacters += spanCharacters(extensionInfo, lines: extensionRow.lines)
                // Calls out are read from the declaring file only, so every line number in them is a line of
                // that file; an extension elsewhere has its own file outline.
                if extensionInfo.id == info.id {
                    fromSymbols.insert(extensionRow.id)
                    fromSymbols.formUnion(members)
                } else {
                    extensionFiles.append(extensionInfo.id)
                }
            }
        }
        if row.kind.isType || isExtension { sourceCharacters = min(max(sourceCharacters, Self.typeFloorCharacters), max(info.size, sourceCharacters)) }
        // `T(…)` is recorded against the type, so an initializer's users are the files that construct its type.
        let constructed = row.kind == .initializer ? row.parentID.flatMap { tree.row($0) }.flatMap { $0.kind.isType ? $0.id : nil } : nil
        symbol.usedBy = try usedBy(symbols: inside, constructing: constructed, excludingFiles: [info.id] + extensionFiles)
        symbol.calls = try calls(CallScope(files: [info.id: info.language], symbols: fromSymbols, inside: inside, insideFiles: []))

        var result = OutlineResult(kind: .symbol, target: first.qualifiedName, sourceCharacters: sourceCharacters, symbol: symbol)
        if row.kind.isCallable {
            // The flow view is the outline of a function. A function it cannot follow still gets its
            // declaration and calls.
            let target = (try? engine.groupDeclarations(rows)).flatMap { try? engine.exactTarget(for: $0[0]) } ?? first.qualifiedName
            result.flow = try? engine.flow(of: target)
            // A flow that follows the work into a body in another file (`remember(pdfAt:)` → `remember(_:metadata:)`)
            // stands in for reading that file too.
            if let body = result.flow?.body, body.path != info.path,
               let size = try db.queryOne("SELECT size FROM files WHERE path = ?", [body.path], { $0.int(0) }) {
                result.sourceCharacters += size
            }
        }
        return result
    }

    /// Extensions of `type` anywhere in the repository: by name, and, when another type has the same name, only
    /// those in the same module.
    func extensions(of type: Row, file: FileInfo) throws -> [(Row, FileInfo, OutlineTree)] {
        let names = Array(Set([type.name, type.qualifiedName]))
        let candidates = try db.query("""
            SELECT s.id, s.file_id FROM symbols s JOIN files f ON f.id = s.file_id
            WHERE s.kind = 'extension' AND s.is_local = 0 AND (s.name IN (\(names.map { _ in "?" }.joined(separator: ","))) OR s.qualified_name = ?)
            ORDER BY f.path, s.start_line LIMIT 50
            """, names + [type.qualifiedName], cache: false) { ($0.int64(0), $0.int64(1)) }
        guard !candidates.isEmpty else { return [] }
        let typeKinds = SymbolKind.allCases.filter(\.isType).map { "'\($0.rawValue)'" }.joined(separator: ",")
        let namesakes = try db.scalarInt("SELECT COUNT(*) FROM symbols WHERE qualified_name = ? AND kind IN (\(typeKinds)) AND is_local = 0", [type.qualifiedName])
        var result: [(Row, FileInfo, OutlineTree)] = []
        var trees: [Int64: (FileInfo, OutlineTree)] = [:]
        for (id, fileID) in candidates {
            if trees[fileID] == nil, let info = try fileInfo(fileID) {
                trees[fileID] = (info, OutlineTree(try rows(inFile: fileID)))
            }
            guard let (info, tree) = trees[fileID], let row = tree.row(id) else { continue }
            if namesakes > 1, info.moduleID != file.moduleID { continue }
            result.append((row, info, tree))
        }
        return result
    }

    /// Characters of `lines` in a file, read from disk; estimated from the file's size when it can't be read.
    func spanCharacters(_ info: FileInfo, lines: LineRange) -> Int {
        if let text = engine.sourceText.file(info.path), let start = text.range(ofLine: lines.start), let end = text.range(ofLine: lines.end) {
            return max(0, end.upperBound - start.lowerBound)
        }
        guard info.lines > 0 else { return info.size }
        return info.size * lines.count / info.lines
    }

    // MARK: Choices

    func choices(_ choices: [UsageTarget.Choice]) throws -> OutlineResult {
        var items: [OutlineChoice] = []
        for choice in choices {
            var signature: String?
            if choice.location != nil, case .symbol(let rows)? = try? engine.resolveUsageTarget(choice.target) {
                signature = rows[0].signature
            }
            items.append(OutlineChoice(target: choice.target, kind: choice.kind, location: choice.location, signature: signature, uses: choice.uses, files: choice.files))
        }
        // Declarations first, most used first; then files, folders and modules.
        items.sort { a, b in
            let da = a.location != nil, dbl = b.location != nil
            if da != dbl { return da }
            return a.uses == b.uses ? a.target < b.target : a.uses > b.uses
        }
        return OutlineResult(kind: .choices, target: "", sourceCharacters: 30_000, choices: items)
    }

    // MARK: Folders and modules

    func folder(path: String?, module: String?, fileIDs: [Int64]) throws -> OutlineResult {
        struct Entry {
            let id: Int64
            let path: String
            let language: Language
            let lines: Int
            let size: Int
            let isTest: Bool
        }
        var entries: [Entry] = []
        for chunk in Self.chunks(fileIDs) {
            entries += try db.query("SELECT id, path, language, line_count, size, is_test FROM files WHERE id IN (\(chunk.sqlList))", cache: false) { row in
                Entry(id: row.int64(0), path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown, lines: row.int(3), size: row.int(4), isTest: row.bool(5))
            }
        }
        entries.sort { $0.path < $1.path }
        let ids = entries.map(\.id)

        var topLevel: [Int64: [Row]] = [:]
        for chunk in Self.chunks(ids) {
            try db.forEach("SELECT \(Self.rowColumns) FROM symbols s WHERE s.file_id IN (\(chunk.sqlList)) AND s.depth = 0 AND s.is_local = 0 ORDER BY s.file_id, s.start_line, s.id") { sql in
                let row = Self.row(sql)
                topLevel[row.fileID, default: []].append(row)
            }
        }
        let users = try usersPerFile(ids)
        let emptyTree = OutlineTree([])
        let files = entries.map { entry -> OutlineFolderFile in
            let rows = topLevel[entry.id] ?? []
            let primary = Self.primary(rows, fileName: (entry.path as NSString).lastPathComponent).prefix(Self.primaryPerFile)
            return OutlineFolderFile(path: entry.path, lines: entry.lines, isTest: entry.isTest,
                                     primary: primary.map { declaration($0, tree: emptyTree, language: entry.language, path: entry.path) },
                                     declarations: rows.count, usedBy: users[entry.id] ?? 0)
        }
        let folderPath = path ?? Self.commonFolder(entries.map(\.path))
        let folder = OutlineFolder(path: folderPath, module: module, targets: try targets(ofFiles: ids), files: files)
        return OutlineResult(kind: .folder, target: module ?? folderPath, sourceCharacters: entries.reduce(0) { $0 + $1.size }, folder: folder)
    }

    /// A file's main declarations: types (the one named like the file first), then functions and the rest;
    /// extensions last, exported declarations before others.
    static func primary(_ rows: [Row], fileName: String) -> [Row] {
        let stem = (fileName as NSString).deletingPathExtension
        func rank(_ row: Row) -> Int {
            if row.kind.isType && row.kind != .typeAlias { return row.name == stem ? 0 : 1 }
            if row.kind == .extension { return 4 }
            if row.kind.isCallable || row.kind == .component { return row.isExported ? 2 : 3 }
            return row.isExported ? 3 : 5
        }
        // Private declarations only when the file has nothing else; an extension of a type listed beside it
        // adds nothing.
        let isPrivate = { (row: Row) in row.visibility == .private || row.visibility == .fileprivate }
        let visible = rows.contains { !isPrivate($0) } ? rows.filter { !isPrivate($0) } : rows
        let types = Set(visible.filter { $0.kind.isType }.map(\.name))
        let candidates = visible.filter { $0.kind != .extension || !types.contains($0.name) }
        return candidates.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    /// The deepest folder holding every path; empty for the repository root.
    static func commonFolder(_ paths: [String]) -> String {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent }) else { return "" }
        for path in paths.dropFirst() {
            while !common.isEmpty && !path.hasPrefix(common + "/") {
                common = (common as NSString).deletingLastPathComponent
            }
        }
        return common
    }

    static func chunks(_ ids: [Int64], size: Int = 500) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min(ids.count, $0 + size)]) }
    }

    // MARK: Build targets, imports, users

    /// Build targets compiling any of the files, with how many of them each compiles; app targets first.
    func targets(ofFiles ids: [Int64]) throws -> [OutlineTargetCount] {
        var counts: [String: (files: Int, isTest: Bool)] = [:]
        for chunk in Self.chunks(ids) {
            try db.forEach("""
                SELECT t.name, t.is_test, COUNT(DISTINCT ft.file_id) FROM file_targets ft JOIN targets t ON t.id = ft.target_id
                WHERE ft.file_id IN (\(chunk.sqlList)) GROUP BY t.name, t.is_test
                """) { row in
                let name = row.string(0)
                counts[name] = ((counts[name]?.files ?? 0) + row.int(2), row.bool(1))
            }
        }
        return counts.sorted { a, b in
            if a.value.isTest != b.value.isTest { return !a.value.isTest }
            return a.value.files == b.value.files ? a.key.lowercased() < b.key.lowercased() : a.value.files > b.value.files
        }.map { OutlineTargetCount(name: $0.key, files: $0.value.files) }
    }

    func imports(ofFile id: Int64) throws -> [OutlineImport] {
        try db.query("""
            SELECT i.line, i.module, i.names, i.is_type_only, rf.path FROM imports i LEFT JOIN files rf ON rf.id = i.resolved_file_id
            WHERE i.file_id = ? AND i.is_mock = 0 ORDER BY i.line, i.id
            """, [id]) { row in
            OutlineImport(line: row.int(0), module: row.string(1), path: row.optionalString(4),
                          names: ImportNamesCodec.decode(row.optionalString(2)).map { name in name.alias.map { "\(name.name) as \($0)" } ?? name.name },
                          isTypeOnly: row.bool(3))
        }
        .reduce(into: [OutlineImport]()) { merged, item in
            // Python stores one row per imported name: one statement, one entry.
            if let last = merged.last, last.line == item.line, last.module == item.module {
                merged[merged.count - 1].names += item.names.filter { !last.names.contains($0) }
            } else {
                merged.append(item)
            }
        }
    }

    /// Files outside `files` that use them: references at the use threshold, or a non-mock import.
    func usedBy(files ids: [Int64]) throws -> OutlineUsers {
        let list = ids.sqlList
        return try users("""
            SELECT file_id FROM refs WHERE target_file_id IN (\(list)) AND file_id NOT IN (\(list)) AND confidence >= ?
            UNION SELECT file_id FROM imports WHERE resolved_file_id IN (\(list)) AND file_id NOT IN (\(list)) AND is_mock = 0
            """, [RepositoryEngine.useThreshold])
    }

    /// Files other than `excludingFiles` with references at the use threshold to any of `symbols`, or that
    /// construct the type `constructing`.
    func usedBy(symbols: Set<Int64>, constructing: Int64? = nil, excludingFiles: [Int64]) throws -> OutlineUsers {
        guard !symbols.isEmpty else { return OutlineUsers() }
        let construction = constructing.map { " OR (target_symbol_id = \($0) AND kind = 'instantiate')" } ?? ""
        return try users("""
            SELECT DISTINCT file_id FROM refs WHERE (target_symbol_id IN (\(Array(symbols).sqlList))\(construction))
            AND file_id NOT IN (\(excludingFiles.sqlList)) AND confidence >= ?
            """, [RepositoryEngine.useThreshold])
    }

    private func users(_ sql: String, _ values: [any SQLBindable]) throws -> OutlineUsers {
        try db.queryOne("SELECT COUNT(*), COALESCE(SUM(f.is_test), 0) FROM (\(sql)) u JOIN files f ON f.id = u.file_id", values) { row in
            OutlineUsers(files: row.int(0), testFiles: row.int(1))
        } ?? OutlineUsers()
    }

    /// For each file, how many other files use it.
    func usersPerFile(_ ids: [Int64]) throws -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        for chunk in Self.chunks(ids) {
            let list = chunk.sqlList
            try db.forEach("""
                SELECT t, COUNT(DISTINCT u) FROM (
                    SELECT target_file_id AS t, file_id AS u FROM refs
                    WHERE target_file_id IN (\(list)) AND file_id != target_file_id AND confidence >= ?
                    UNION SELECT resolved_file_id, file_id FROM imports
                    WHERE resolved_file_id IN (\(list)) AND file_id != resolved_file_id AND is_mock = 0
                ) GROUP BY t
                """, [RepositoryEngine.useThreshold]) { result[$0.int64(0)] = $0.int(1) }
        }
        return result
    }

    // MARK: Calls out

    /// Which references count: those in `files` (from `symbols` when set), to anything outside `inside` and
    /// outside `insideFiles`.
    struct CallScope {
        let files: [Int64: Language]
        let symbols: Set<Int64>?
        let inside: Set<Int64>
        let insideFiles: Set<Int64>
    }

    /// Calls (and initializers and static member reads) leaving the scope: into the repository at the use
    /// threshold, into frameworks, and environment variables.
    func calls(_ scope: CallScope) throws -> OutlineCalls {
        struct Ref {
            let line: Int
            let name: String
            let kind: String
            let receiver: String?
            let target: Int64?
            let targetFile: Int64?
            let confidence: Double
            let isExternal: Bool
            let module: String?
            let receiverType: String?
            let language: Language
        }
        var refs: [Ref] = []
        for (fileID, language) in scope.files.sorted(by: { $0.key < $1.key }) {
            var sql = """
                SELECT line, name, kind, receiver, target_symbol_id, target_file_id, confidence, is_external, external_module, receiver_type
                FROM refs WHERE file_id = ?
                """
            if let symbols = scope.symbols { sql += " AND from_symbol_id IN (\(Array(symbols).sqlList))" }
            refs += try db.query(sql + " ORDER BY line, col", [fileID], cache: scope.symbols == nil) { row in
                Ref(line: row.int(0), name: row.string(1), kind: row.string(2), receiver: row.optionalString(3), target: row.optionalInt64(4),
                    targetFile: row.optionalInt64(5), confidence: row.double(6), isExternal: row.bool(7), module: row.optionalString(8),
                    receiverType: row.optionalString(9), language: language)
            }
        }
        // Several files (a type and its extensions) are merged in line order of first use per file.

        var environment: [String: OutlineEnvironmentUse] = [:]
        var environmentOrder: [String] = []
        // Keyed by target and the name called: a member call that resolved to its receiver's binding
        // (`db.insert` → `db`) keeps the member's name.
        struct CalleeKey: Hashable {
            let target: Int64
            let name: String
        }
        var repository: [CalleeKey: [Int]] = [:]
        var repositoryOrder: [CalleeKey] = []
        var instantiated: [CalleeKey: Language] = [:]
        var external: [String: [String: [Int]]] = [:]
        var externalOrder: [String: [String]] = [:]
        var moduleOrder: [String] = []
        for ref in refs {
            if ref.name.hasPrefix("env:") {
                let name = String(ref.name.dropFirst(4))
                if environment[name] == nil {
                    environment[name] = OutlineEnvironmentUse(name: name)
                    environmentOrder.append(name)
                }
                if ref.kind == ReferenceKind.write.rawValue { environment[name]?.writes.append(ref.line) } else { environment[name]?.reads.append(ref.line) }
                continue
            }
            guard ref.confidence >= RepositoryEngine.useThreshold else { continue }
            let isCall = ref.kind == ReferenceKind.call.rawValue || ref.kind == ReferenceKind.instantiate.rawValue
            let isStaticRead = ref.kind == ReferenceKind.read.rawValue && Self.isTypeName(ref.receiver)
            guard isCall || isStaticRead else { continue }
            if ref.isExternal {
                let module = ref.module ?? "other"
                let label = Self.externalLabel(name: ref.name, kind: ref.kind, receiverType: ref.receiverType, receiver: ref.receiver, language: ref.language)
                if external[module] == nil { moduleOrder.append(module) }
                if external[module]?[label] == nil { externalOrder[module, default: []].append(label) }
                external[module, default: [:]][label, default: []].append(ref.line)
            } else if let target = ref.target, let targetFile = ref.targetFile, !scope.inside.contains(target), !scope.insideFiles.contains(targetFile) {
                let key = CalleeKey(target: target, name: ref.name)
                if repository[key] == nil { repositoryOrder.append(key) }
                repository[key, default: []].append(ref.line)
                if ref.kind == ReferenceKind.instantiate.rawValue { instantiated[key] = ref.language }
            }
        }

        // Repository callees with their names and declaring files; error types after the rest.
        let callees = try calleeInfo(Array(Set(repositoryOrder.map(\.target))))
        var calls: [OutlineCall] = []
        var selectors: [String?] = []
        for key in repositoryOrder {
            guard let info = callees[key.target], let lines = repository[key] else { continue }
            var name = info.qualifiedName
            var selector: String?
            if let language = instantiated[key], info.kind.isType {
                name = language == .swift ? name + ".init" : (language == .python ? name + "()" : "new " + name)
            } else if key.name != info.name {
                name += "." + key.name
            } else if let full = info.selector, info.kind.isCallable, name.hasSuffix(info.name) {
                selector = String(name.dropLast(info.name.count)) + full
            }
            calls.append(OutlineCall(name: name, path: info.path, lines: Self.sortedUnique(lines), isError: info.isError))
            selectors.append(selector)
        }
        // Overloads called under one name are told apart by selector (`embed(_:)`, `embed(batch:)`).
        let shared = Dictionary(grouping: calls.map(\.name), by: { $0 }).filter { $0.value.count > 1 }
        for index in calls.indices where shared[calls[index].name] != nil {
            if let selector = selectors[index] { calls[index].name = selector }
        }
        calls = calls.filter { !$0.isError } + calls.filter(\.isError)

        let shares = try moduleShares()
        let modules = moduleOrder.map { module in
            OutlineModuleCalls(module: module,
                               calls: (externalOrder[module] ?? []).map { OutlineCall(name: $0, lines: Self.sortedUnique(external[module]?[$0] ?? [])) },
                               isAmbient: module == "Swift" || (shares[module] ?? 0) >= Self.ambientShare)
        }
        // Modules that say what the code is for first, in order of first use.
        let ordered = modules.filter { !$0.isAmbient } + modules.filter(\.isAmbient)
        let env = environmentOrder.compactMap { environment[$0] }.map {
            OutlineEnvironmentUse(name: $0.name, reads: Self.sortedUnique($0.reads), writes: Self.sortedUnique($0.writes))
        }
        return OutlineCalls(repository: calls, external: ordered, environment: env)
    }

    struct CalleeInfo {
        let name: String
        let qualifiedName: String
        let kind: SymbolKind
        let path: String
        let isError: Bool
        /// `embed(batch:)`, for telling overloads apart.
        let selector: String?
    }

    func calleeInfo(_ ids: [Int64]) throws -> [Int64: CalleeInfo] {
        var result: [Int64: CalleeInfo] = [:]
        for chunk in Self.chunks(ids) {
            try db.forEach("""
                SELECT s.id, s.qualified_name, s.kind, f.path, s.name, p.name, p.kind, s.selector FROM symbols s JOIN files f ON f.id = s.file_id
                LEFT JOIN symbols p ON p.id = s.parent_id WHERE s.id IN (\(chunk.sqlList))
                """) { row in
                let kind = SymbolKind(rawValue: row.string(2)) ?? .variable
                // The callee's type: itself, or the type it is a member of.
                let typeName = kind.isType ? row.string(4) : (row.optionalString(6).flatMap(SymbolKind.init(rawValue:))?.isContainer == true ? row.optionalString(5) : nil)
                let isError = typeName.map { $0.hasSuffix("Error") || $0.hasSuffix("Exception") } ?? false
                result[row.int64(0)] = CalleeInfo(name: row.string(4), qualifiedName: row.string(1), kind: kind, path: row.string(3), isError: isError,
                                                  selector: row.optionalString(7))
            }
        }
        return result
    }

    /// The share of the repository's code files importing each external module.
    func moduleShares() throws -> [String: Double] {
        try engine.memoized("outline|module-shares") {
            let codeLanguages = Language.allCases.filter(\.isCode).map { "'\($0.rawValue)'" }.joined(separator: ",")
            let total = max(1, try db.scalarInt("SELECT COUNT(*) FROM files WHERE language IN (\(codeLanguages))"))
            var shares: [String: Double] = [:]
            try db.forEach("SELECT external_name, COUNT(DISTINCT file_id) FROM imports WHERE external_name IS NOT NULL AND is_mock = 0 GROUP BY external_name") { row in
                shares[row.string(0)] = Double(row.int(1)) / Double(total)
            }
            return shares
        }
    }

    /// `Product.products`, `Data.init`, `MKLocalSearch.Request.init`, `randomBytes`, `[String].insert`,
    /// `os.path.dirname`.
    static func externalLabel(name: String, kind: String, receiverType: String?, receiver: String?, language: Language) -> String {
        if kind == ReferenceKind.instantiate.rawValue {
            // A nested type keeps the type it is in.
            let type = receiver.flatMap { isTypeName($0) ? $0 + "." + name : nil } ?? name
            return language == .swift ? type + ".init" : (language == .python ? type + "()" : "new " + type)
        }
        if let type = receiverType, !type.isEmpty, type != name {
            // A path into an imported module (`os.path`) is kept as written.
            if let receiver, receiver.hasPrefix(type + "."), isPath(receiver) { return receiver + "." + name }
            return type + "." + name
        }
        if let receiver, isTypeName(receiver) { return receiver + "." + name }
        return name
    }

    /// `os.path`, `np.linalg`: identifiers joined by dots.
    static func isPath(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "." || $0 == "$" }
    }

    /// `WaxError`, `Self`, `PremiumStore.Tier`: a receiver that names a type, so the reference is static.
    static func isTypeName(_ receiver: String?) -> Bool {
        guard let receiver, let first = receiver.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
        return receiver.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "." }
    }

    static func sortedUnique(_ lines: [Int]) -> [Int] { Array(Set(lines)).sorted() }
}

/// A file's declarations as a tree by `parent_id`. Rows whose parent is not loaded (members of a function-local
/// type) are left out.
struct OutlineTree {
    let roots: [OutlineBuilder.Row]
    let children: [Int64: [OutlineBuilder.Row]]
    private let byID: [Int64: OutlineBuilder.Row]

    init(_ rows: [OutlineBuilder.Row]) {
        var byID: [Int64: OutlineBuilder.Row] = [:]
        for row in rows { byID[row.id] = row }
        var children: [Int64: [OutlineBuilder.Row]] = [:]
        var roots: [OutlineBuilder.Row] = []
        for row in rows {
            if let parent = row.parentID {
                if byID[parent] != nil { children[parent, default: []].append(row) }
            } else {
                roots.append(row)
            }
        }
        self.roots = roots
        self.children = children
        self.byID = byID
    }

    func row(_ id: Int64) -> OutlineBuilder.Row? { byID[id] }

    func descendants(of id: Int64) -> [OutlineBuilder.Row] {
        var result: [OutlineBuilder.Row] = []
        var stack = children[id] ?? []
        while let row = stack.popLast() {
            result.append(row)
            stack += children[row.id] ?? []
        }
        return result
    }
}

/// Reads the parts of a declaration's signature that a compact outline line keeps: a property's type and
/// initial value, a function's effects, result type and (for languages without selectors) parameter clause.
enum OutlineSignature {
    struct Parts: Equatable {
        var type: String?
        var value: String?
        var effects: String?
        var parameters: String?
        var isStatic = false
    }

    static func parts(_ signature: String, name: String, kind: SymbolKind, language: Language) -> Parts {
        var parts = Parts()
        let characters = Array(signature)
        let word = kind == .initializer && language == .swift ? "init" : name
        guard let range = declaredName(word, in: characters) else { return parts }
        let prefix = String(characters[..<range.lowerBound])
        let prefixWords = Set(prefix.split(whereSeparator: { !$0.isLetter && $0 != "@" }).map(String.init))
        parts.isStatic = prefixWords.contains("static") || (prefixWords.contains("class") && !kind.isType)
        var index = range.upperBound
        func skipSpaces() { while index < characters.count, characters[index] == " " { index += 1 } }

        switch kind {
        case .function, .method, .initializer, .macro, .component, .enumCase:
            // `init?`, `init!`, then a generic clause.
            if index < characters.count, characters[index] == "?" || characters[index] == "!" { index += 1 }
            if index < characters.count, characters[index] == "<", let close = matching(characters, from: index) { index = close + 1 }
            skipSpaces()
            guard index < characters.count, characters[index] == "(", let close = matching(characters, from: index) else {
                if kind == .enumCase { parts.value = initialValue(characters, from: index) }
                if kind != .enumCase, prefixWords.contains("async") { parts.effects = "async" }
                return parts
            }
            if language != .swift || kind == .enumCase { parts.parameters = String(characters[index...close]) }
            let tail = String(characters[(close + 1)...]).trimmingCharacters(in: .whitespaces)
            if kind == .enumCase {
                parts.value = initialValue(Array(tail), from: 0)
                return parts
            }
            switch language {
            case .swift:
                // `async throws -> Data where T: P`.
                if let arrow = topLevel("->", in: tail) {
                    parts.effects = nonEmpty(String(tail[..<arrow.lowerBound]))
                    parts.type = nonEmpty(cutWhere(String(tail[arrow.upperBound...])))
                } else {
                    parts.effects = nonEmpty(cutWhere(tail))
                }
            case .python:
                // `-> dict:  # comment`; `async def`.
                var rest = tail
                if let comment = rest.firstIndex(of: "#") { rest = String(rest[..<comment]) }
                rest = rest.trimmingCharacters(in: .whitespaces).trimmingSuffix(":")
                if let arrow = topLevel("->", in: rest) { parts.type = nonEmpty(String(rest[arrow.upperBound...])) }
                if prefixWords.contains("async") { parts.effects = "async" }
            default:
                // TypeScript and JavaScript: `(…): Type`, `async` before the name.
                if tail.hasPrefix(":") { parts.type = nonEmpty(String(tail.dropFirst()).trimmingCharacters(in: .whitespaces)) }
                if prefixWords.contains("async") { parts.effects = "async" }
            }
        case .property, .variable, .constant, .typeAlias:
            if index < characters.count, characters[index] == "?" || characters[index] == "!" { index += 1 }
            skipSpaces()
            if index < characters.count, characters[index] == ":" {
                let start = index + 1
                let end = topLevelIndex(of: "=", in: characters, from: start) ?? characters.count
                parts.type = nonEmpty(String(characters[start..<end]).trimmingCharacters(in: .whitespaces).trimmingSuffix("{"))
                index = end
            }
            parts.value = initialValue(characters, from: index)
        default:
            break
        }
        return parts
    }

    /// The text after a top-level `=` at `index` (spaces skipped), or nil.
    private static func initialValue(_ characters: [Character], from start: Int) -> String? {
        var index = start
        while index < characters.count, characters[index] == " " { index += 1 }
        guard index < characters.count, characters[index] == "=", index + 1 >= characters.count || characters[index + 1] != "=" else { return nil }
        return nonEmpty(String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces))
    }

    /// Where `name` is declared in a signature: the first whole-word occurrence outside brackets and outside
    /// attributes' arguments.
    static func declaredName(_ name: String, in characters: [Character]) -> Range<Int>? {
        let word = Array(name)
        guard !word.isEmpty, word.count <= characters.count else { return nil }
        var depth = 0
        var index = 0
        while index + word.count <= characters.count {
            let character = characters[index]
            if "([{<".contains(character) && depth >= 0 {
                if depth == 0, Array(characters[index..<min(characters.count, index + word.count)]) == word { break }
                depth += 1
            } else if ")]}>".contains(character) {
                if !(character == ">" && index > 0 && characters[index - 1] == "-") { depth = max(0, depth - 1) }
            }
            if depth == 0, Array(characters[index..<index + word.count]) == word,
               index == 0 || !isIdentifier(characters[index - 1]) && characters[index - 1] != "@" && characters[index - 1] != ".",
               index + word.count == characters.count || !isIdentifier(characters[index + word.count]) {
                return index..<(index + word.count)
            }
            index += 1
        }
        return nil
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    /// The index of the bracket closing the one at `open`, or nil.
    static func matching(_ characters: [Character], from open: Int) -> Int? {
        var depth = 0
        var index = open
        var quote: Character?
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == "\\" { index += 2; continue }
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else if "([{<".contains(character) {
                depth += 1
            } else if ")]}>".contains(character) {
                if character == ">" && index > 0 && characters[index - 1] == "-" { index += 1; continue }
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The first top-level occurrence of `token` in `text`.
    static func topLevel(_ token: String, in text: String) -> Range<String.Index>? {
        let characters = Array(text)
        let tokenCharacters = Array(token)
        var depth = 0
        var index = 0
        while index + tokenCharacters.count <= characters.count {
            let character = characters[index]
            if depth == 0, Array(characters[index..<index + tokenCharacters.count]) == tokenCharacters {
                let start = text.index(text.startIndex, offsetBy: index)
                return start..<text.index(start, offsetBy: tokenCharacters.count)
            }
            if "([{<".contains(character) { depth += 1 }
            if ")]}".contains(character) || (character == ">" && !(index > 0 && characters[index - 1] == "-")) { depth = max(0, depth - 1) }
            index += 1
        }
        return nil
    }

    private static func topLevelIndex(of token: Character, in characters: [Character], from start: Int) -> Int? {
        var depth = 0
        var index = start
        var quote: Character?
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == "\\" { index += 2; continue }
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if "([{<".contains(character) {
                depth += 1
            } else if ")]}".contains(character) || (character == ">" && !(index > 0 && characters[index - 1] == "-")) {
                depth = max(0, depth - 1)
            } else if depth == 0, character == token, index + 1 >= characters.count || characters[index + 1] != "=",
                      index == 0 || !"=!<>".contains(characters[index - 1]) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// `def main(): # Base paths` → `def main()`: a Python declaration line without its comment and colon.
    static func withoutPythonTail(_ text: String) -> String {
        let characters = Array(text)
        var depth = 0
        var quote: Character?
        var end = characters.count
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == "\\" { index += 2; continue }
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if "([{".contains(character) {
                depth += 1
            } else if ")]}".contains(character) {
                depth = max(0, depth - 1)
            } else if character == "#", depth == 0 {
                end = index
                break
            }
            index += 1
        }
        let head = String(characters[..<end]).trimmingCharacters(in: .whitespaces)
        return head.hasSuffix(":") ? String(head.dropLast()).trimmingCharacters(in: .whitespaces) : head
    }

    /// Drops a trailing generic `where` clause.
    private static func cutWhere(_ text: String) -> String {
        guard let range = topLevel(" where ", in: text) else { return text.trimmingCharacters(in: .whitespaces) }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `@Environment(\.modelContext)` → `@Environment`.
    static func attributeName(_ attribute: String) -> String {
        guard let paren = attribute.firstIndex(of: "(") else { return attribute }
        return String(attribute[..<paren])
    }

    /// Text the index stores whole (a doc sentence, a parse message) cut to `limit` characters with `…`.
    static func shorten(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The first sentence of a doc comment's first paragraph, at most 160 characters; the parameter and
    /// return sections are never part of it.
    static func firstSentence(_ doc: String?, limit: Int = 160) -> String? {
        guard let doc else { return nil }
        var paragraph: [String] = []
        for raw in doc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if paragraph.isEmpty { continue } else { break } }
            let lower = line.lowercased()
            if lower.hasPrefix("- parameter") || lower.hasPrefix("- returns") || lower.hasPrefix("- throws") || lower.hasPrefix("@param") || lower.hasPrefix("@returns") || lower.hasPrefix(":param") {
                break
            }
            paragraph.append(line)
        }
        let flat = paragraph.joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        var sentence = flat
        var search = flat.startIndex
        while let end = flat.range(of: ". ", range: search..<flat.endIndex) ?? flat.range(of: "! ", range: search..<flat.endIndex) ?? flat.range(of: "? ", range: search..<flat.endIndex) {
            let before = flat[..<end.lowerBound]
            let lastWord = before.split(separator: " ").last.map { $0.lowercased() } ?? ""
            if ["e.g", "i.e", "etc", "vs", "cf", "approx", "no"].contains(lastWord) || lastWord.count == 1 {
                search = end.upperBound
                continue
            }
            sentence = String(flat[...end.lowerBound])
            break
        }
        return shorten(sentence, to: limit)
    }
}


private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) : self
    }
}
