import Foundation
import RepositoryIndex
import VesaliusCore

/// What a `usages` target string names: one declaration, a file, a folder, a repository module,
/// a framework or an environment variable.
///
/// Accepted forms: `Type.member`, `Type.method(label:)`, a bare name, `path#Name`, `path:line` (the innermost
/// declaration enclosing that line), a file or folder path (a unique suffix is enough), a module, a framework
/// (`StoreKit`, from `imports.external_name`), and `env:NAME` or a bare `ENV_NAME`. Backticks and a trailing
/// `()` are stripped. Nothing is merged or picked silently: when several things match, the result is
/// `.choices`, each with the exact target string that selects it and its use counts.
///
/// An extension has no name of its own, so a bare name never selects one. `path#Name` selects the file's
/// extensions of `Name` when the file declares nothing else called `Name`, and `path:line` on a line of an
/// extension outside its members selects that extension: the target is what they add. Swift only: the lexical
/// analyzers' `extension` rows (an Objective-C `@implementation`, a Rust `impl`) are not targets of their own.
enum UsageTarget {
    /// One declaration. Several rows only for its `#if` variants (same file, qualified name and selector), or
    /// for one file's extensions of a type.
    case symbol([RepositoryEngine.SymbolRow])
    case file(id: Int64, path: String)
    case folder(path: String, fileIDs: [Int64])
    case module(name: String, fileIDs: [Int64])
    case framework(name: String, importers: [Importer])
    case environment(name: String)
    case choices([Choice])

    struct Importer: Hashable, Sendable {
        let path: String
        let line: Int
    }

    struct Choice: Hashable, Sendable {
        /// The string that selects exactly this choice, e.g. `Atlas/App/ReaderSettings.swift#ReaderSettings`.
        let target: String
        /// `class`, `method`, `file`, `folder`, `module`, `framework`, `environment variable`, …
        let kind: String
        /// `path:start-end` for a declaration.
        let location: String?
        /// References at the use threshold (importing files for a module or framework), and their files.
        let uses: Int
        let files: Int
    }
}

/// Declarations that are one target: the same file, qualified name and selector (`#if` variants).
struct DeclarationGroup {
    var rows: [RepositoryEngine.SymbolRow]
    let selector: String?

    var first: RepositoryEngine.SymbolRow { rows[0] }
    var ids: [Int64] { rows.map(\.id) }
}

extension RepositoryEngine {
    /// Resolves a `usages` target (see `UsageTarget`). Throws `notFound` with suggestions in the accepted syntax
    /// when nothing matches.
    func resolveUsageTarget(_ text: String) throws -> UsageTarget {
        let query = Self.normalizedTarget(text, root: root)
        guard !query.isEmpty else { throw EngineError.invalidQuery("The target is empty. Pass a symbol, file, folder, module or framework.") }
        // `Type.method()` is a zero-argument selector when it names one overload; otherwise its `()` is noise.
        let call = text.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0 != "`" }
        if call.hasSuffix("()"), let parsed = Self.parseSelector(call) {
            let groups = try groupDeclarations(try declarations(withSelector: parsed))
            if groups.count == 1 { return .symbol(groups[0].rows) }
        }

        if let parsed = NodeID.parse(query) {
            let target: UsageTarget?
            switch parsed.kind {
            case .sym: target = try declarationTarget(try resolveSymbols(query), query: text)
            case .file: target = try pathTarget(parsed.value)
            case .dir: target = try folderTarget(parsed.value == "." ? "" : parsed.value)
            case .mod: target = try moduleTarget(named: parsed.value)
            case .ext: target = try frameworkTarget(named: parsed.value)
            }
            guard let target else { throw EngineError.notFound(text, suggestions: try usageSuggestions(for: parsed.value)) }
            return target
        }
        if query.hasPrefix("env:") {
            let name = String(query.dropFirst(4))
            if try environmentUses(name) > 0 { return .environment(name: name) }
            throw EngineError.notFound(text, suggestions: try environmentSuggestions(name))
        }
        // `path:line`: the innermost declaration enclosing that line.
        if let match = query.wholeMatch(of: /(.+):(\d+)/), let line = Int(match.2) {
            switch try matchFile(String(match.1)) {
            case .one(let id, let path): return try lineTarget(fileID: id, path: path, line: line, query: text)
            case .many(let paths): return .choices(try paths.map { try fileChoice($0, suffix: ":\(line)") })
            case .none: break
            }
        }
        // `path#Name`; with no declaration of that name, the file's extensions of `Name`.
        if let hash = query.firstIndex(of: "#"), hash != query.startIndex {
            let path = String(query[..<hash]), name = String(query[query.index(after: hash)...])
            switch try matchFile(path) {
            case .one(let id, _):
                let rows = try declarations(named: name, inFile: id)
                return try declarationTarget(rows.isEmpty ? try extensions(of: name, inFiles: [id]) : rows, query: text)
            case .many(let paths):
                // A suffix shared by several files: the declarations of that name in any of them.
                var rows: [SymbolRow] = []
                var ids: [Int64] = []
                for path in paths {
                    guard let id = try db.queryOne("SELECT id FROM files WHERE path = ?", [path], { $0.int64(0) }) else { continue }
                    ids.append(id)
                    rows += try declarations(named: name, inFile: id)
                }
                return try declarationTarget(rows.isEmpty ? try extensions(of: name, inFiles: ids) : rows, query: text)
            case .none: break
            }
        }
        if let target = try pathTarget(query) { return target }
        if let target = try namedTarget(query) { return target }
        throw EngineError.notFound(text, suggestions: try usageSuggestions(for: query))
    }

    /// Backticks, a trailing `()`, surrounding blanks, `./` and the repository root of an absolute path go.
    static func normalizedTarget(_ text: String, root: URL) -> String {
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query.removeAll { $0 == "`" }
        if query.hasSuffix("()") { query.removeLast(2) }
        let rootPath = root.path + "/"
        if query.hasPrefix(rootPath) { query = String(query.dropFirst(rootPath.count)) }
        if query.hasPrefix("./") { query = String(query.dropFirst(2)) }
        return query.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Files and folders

    private enum PathMatch {
        case none
        case one(id: Int64, path: String)
        case many([String])
    }

    /// A file by exact path, else by a unique path suffix (exact case first).
    private func matchFile(_ path: String) throws -> PathMatch {
        guard !path.isEmpty, !path.hasSuffix("/") else { return .none }
        if let row = try db.queryOne("SELECT id, path FROM files WHERE path = ?", [path], { ($0.int64(0), $0.string(1)) }) {
            return .one(id: row.0, path: row.1)
        }
        let rows = try db.query("SELECT id, path FROM files WHERE path LIKE ? ESCAPE '\\' ORDER BY path LIMIT 50", ["%/" + Self.escapedLike(path)]) { ($0.int64(0), $0.string(1)) }
        let exactCase = rows.filter { $0.1.hasSuffix("/" + path) }
        let matches = exactCase.isEmpty ? rows : exactCase
        switch matches.count {
        case 0: return .none
        case 1: return .one(id: matches[0].0, path: matches[0].1)
        default: return .many(matches.map(\.1))
        }
    }

    private static func escapedLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// A file or folder path: exact, or a unique suffix.
    private func pathTarget(_ query: String) throws -> UsageTarget? {
        switch try matchFile(query) {
        case .one(let id, let path): return .file(id: id, path: path)
        case .many(let paths): return .choices(try paths.map { try fileChoice($0, suffix: "") })
        case .none: break
        }
        let folder = query.hasSuffix("/") ? String(query.dropLast()) : query
        if let target = try folderTarget(folder) { return target }
        guard query.contains("/") else { return nil }
        let folders = try db.query("SELECT path FROM directories WHERE path LIKE ? ESCAPE '\\' ORDER BY path LIMIT 20", ["%/" + Self.escapedLike(folder)]) { $0.string(0) }
            .filter { $0.hasSuffix("/" + folder) }
        if folders.count == 1 { return try folderTarget(folders[0]) }
        if folders.count > 1 { return .choices(try folders.map { try folderChoice($0) }) }
        return nil
    }

    private func folderTarget(_ path: String) throws -> UsageTarget? {
        let exists = try path.isEmpty || db.scalarInt("SELECT COUNT(*) FROM directories WHERE path = ?", [path]) > 0
        guard exists else { return nil }
        let ids = try db.query("SELECT id FROM files WHERE path LIKE ? ESCAPE '\\' OR ? = ''", [Self.escapedLike(path) + "/%", path]) { $0.int64(0) }
        return .folder(path: path, fileIDs: ids)
    }

    private func fileChoice(_ path: String, suffix: String) throws -> UsageTarget.Choice {
        let dependents = try db.scalarInt("""
            SELECT COUNT(DISTINCT e.src_file_id) FROM file_edges e JOIN files f ON f.id = e.dst_file_id
            WHERE f.path = ? AND e.src_file_id != e.dst_file_id
            """, [path])
        return UsageTarget.Choice(target: path + suffix, kind: "file", location: nil, uses: dependents, files: dependents)
    }

    private func folderChoice(_ path: String) throws -> UsageTarget.Choice {
        let files = try db.scalarInt("SELECT COUNT(*) FROM files WHERE path LIKE ? ESCAPE '\\'", [Self.escapedLike(path) + "/%"])
        return UsageTarget.Choice(target: path + "/", kind: "folder", location: nil, uses: files, files: files)
    }

    /// `path:line`: the innermost declaration enclosing the line (function-local types and their members count,
    /// local variables are not indexed); on a line of an extension outside its members, that extension.
    private func lineTarget(fileID: Int64, path: String, line: Int, query: String) throws -> UsageTarget {
        let rows = try symbolRows(where: """
            s.file_id = ? AND s.start_line <= ? AND s.end_line >= ? AND (s.kind != 'extension' OR f.language = 'swift')
            ORDER BY s.depth DESC, s.start_line DESC
            """, [fileID, line, line], limit: 1)
        guard let row = rows.first else {
            var suggestions = [path]
            for top in try symbolRows(where: "s.file_id = ? AND s.depth = 0 AND (s.kind != 'extension' OR f.language = 'swift') ORDER BY s.start_line", [fileID], limit: 4) {
                var target = "\(path)#\(top.qualifiedName)"
                if top.kind == .extension {
                    let extended = try extensions(of: top.qualifiedName, inFiles: [fileID])
                    target = try extensionTarget(extended.isEmpty ? [top] : extended)
                }
                if !suggestions.contains(target) { suggestions.append(target) }
            }
            throw EngineError.notFound(query, suggestions: suggestions)
        }
        if row.kind == .extension { return .symbol([row]) }
        // An extension with no line outside its members (`extension Model { func one() … }`) is selected by its
        // first line; the member keeps its name as a target.
        if let first = try extensions(inFile: fileID, startingOn: line).first, try memberFreeLine(of: first) == nil {
            return .symbol([first])
        }
        let variants = try symbolRows(where: "s.file_id = ? AND s.qualified_name = ? AND s.kind != 'extension' ORDER BY s.id", [fileID, row.qualifiedName], limit: 50)
        let selectors = try selectors(for: variants)
        return .symbol(variants.filter { selectors[$0.id] == selectors[row.id] })
    }

    // MARK: Declarations

    /// Declarations in one file named `name`: a qualified name, a simple name, or either with a selector.
    private func declarations(named name: String, inFile fileID: Int64) throws -> [SymbolRow] {
        let parsed = Self.parseSelector(name)
        let base = parsed?.base ?? name
        var rows = try symbolRows(where: "s.file_id = ? AND (s.qualified_name = ? OR s.name = ?) AND s.kind != 'extension' ORDER BY s.id", [fileID, base, base], limit: 200)
        if let parsed {
            let selectors = try selectors(for: rows)
            rows = rows.filter { selectors[$0.id] == parsed.selector }
        }
        return rows
    }

    /// Extensions of the type `name` (`extension Notification.Name`), in `fileIDs` when given, by path and line.
    /// `Name` matches `Notification.Name` when nothing extends a type of exactly that name.
    private func extensions(of name: String, inFiles fileIDs: [Int64]? = nil) throws -> [SymbolRow] {
        guard Self.parseSelector(name) == nil, !name.isEmpty, fileIDs?.isEmpty != true else { return [] }
        let scope = "s.kind = 'extension' AND f.language = 'swift'" + (fileIDs.map { " AND s.file_id IN (\($0.sqlList))" } ?? "")
        let exact = try symbolRows(where: "\(scope) AND s.qualified_name = ? ORDER BY f.path, s.start_line", [name], limit: 200)
        guard exact.isEmpty, !name.contains(where: { "*?[".contains($0) }) else { return exact }
        return try symbolRows(where: "\(scope) AND s.qualified_name GLOB ? ORDER BY f.path, s.start_line", ["*." + name], limit: 200)
    }

    private func extensions(inFile fileID: Int64, startingOn line: Int) throws -> [SymbolRow] {
        try symbolRows(where: "s.file_id = ? AND s.start_line = ? AND s.kind = 'extension' AND f.language = 'swift'", [fileID, line], limit: 1)
    }

    /// The first line of an extension that none of its members covers; nil when every line is inside one.
    private func memberFreeLine(of row: SymbolRow) throws -> Int? {
        let members = try db.query("SELECT start_line, end_line FROM symbols WHERE parent_id = ?", [row.id]) { LineRange($0.int(0), $0.int(1)) }
        return (row.lines.start...row.lines.end).first { line in !members.contains { $0.start <= line && line <= $0.end } }
    }

    /// Whether `fileID` is a Swift file, where an `extension` row is a Swift extension.
    func isSwiftFile(_ fileID: Int64) throws -> Bool {
        try db.scalarInt("SELECT COUNT(*) FROM files WHERE id = ? AND language = 'swift'", [fileID]) > 0
    }

    /// The string that selects exactly `rows`, one file's extensions of one type: `path#Name` when they are all of
    /// them and the file declares nothing else called `Name`, else `path:line` on a line of the first that none of
    /// its members covers, or on its first line when its members cover every line.
    func extensionTarget(_ rows: [SymbolRow]) throws -> String {
        let row = rows[0]
        let all = try extensions(of: row.qualifiedName, inFiles: [row.fileID])
        if Set(all.map(\.id)) == Set(rows.map(\.id)), try declarations(named: row.qualifiedName, inFile: row.fileID).isEmpty {
            return "\(row.path)#\(row.qualifiedName)"
        }
        return "\(row.path):\(try memberFreeLine(of: row) ?? row.lines.start)"
    }

    /// One declaration group, or the choices between several.
    private func declarationTarget(_ rows: [SymbolRow], query: String) throws -> UsageTarget {
        let groups = try groupDeclarations(rows)
        switch groups.count {
        case 0: throw EngineError.notFound(query, suggestions: try usageSuggestions(for: Self.normalizedTarget(query, root: root)))
        case 1: return .symbol(groups[0].rows)
        default: return .choices(try groups.map { try declarationChoice($0) })
        }
    }

    /// Declarations by name (qualified, simple or with a selector), plus a module, framework or environment
    /// variable of that name; one match is the target, several are choices.
    private func namedTarget(_ query: String) throws -> UsageTarget? {
        var rows: [SymbolRow] = []
        if let parsed = Self.parseSelector(query) {
            rows = try declarations(withSelector: parsed)
            if rows.isEmpty {
                throw EngineError.notFound(query, suggestions: try usageSuggestions(for: query))
            }
        } else {
            rows = try symbolRows(where: "s.qualified_name = ? AND s.kind != 'extension'", [query], limit: 500)
            if rows.isEmpty, !query.contains(".") {
                rows = try symbolRows(where: "s.name = ? AND s.kind != 'extension'", [query], limit: 500)
            }
            // `Module.Type`.
            if rows.isEmpty, let dot = query.firstIndex(of: "."), try isModuleName(String(query[..<dot])) {
                rows = try symbolRows(where: "s.qualified_name = ? AND s.kind != 'extension'", [String(query[query.index(after: dot)...])], limit: 500)
            }
        }

        let groups = try groupDeclarations(rows)
        var choices = try groups.map { try declarationChoice($0) }
        var single: UsageTarget? = groups.count == 1 ? .symbol(groups[0].rows) : nil
        if !query.contains("/"), Self.parseSelector(query) == nil {
            if let module = try moduleTarget(named: query), case .module(let name, let ids) = module {
                let importers = try db.scalarInt("SELECT COUNT(DISTINCT i.file_id) FROM imports i JOIN modules m ON m.id = i.resolved_module_id WHERE m.name = ?", [name])
                choices.append(UsageTarget.Choice(target: NodeID.module(name), kind: "module", location: "\(ids.count) \(ids.count == 1 ? "file" : "files")", uses: importers, files: importers))
                single = module
            }
            if let framework = try frameworkTarget(named: query), case .framework(let name, let importers) = framework {
                let files = Set(importers.map(\.path)).count
                choices.append(UsageTarget.Choice(target: NodeID.external(name), kind: "framework", location: nil, uses: files, files: files))
                single = framework
            }
            if Self.looksLikeEnvironmentName(query), try environmentUses(query) > 0 {
                let files = try db.scalarInt("SELECT COUNT(DISTINCT file_id) FROM refs WHERE name = ?", ["env:" + query])
                choices.append(UsageTarget.Choice(target: "env:" + query, kind: "environment variable", location: nil, uses: try environmentUses(query), files: files))
                single = .environment(name: query)
            }
        }
        if choices.count == 1, let single { return single }
        if choices.count > 1 { return .choices(choices) }

        // A file name, a file stem or a folder name.
        let named = try db.query("SELECT id, path FROM files WHERE name = ? ORDER BY path LIMIT 20", [query]) { ($0.int64(0), $0.string(1)) }
        if named.count == 1 { return .file(id: named[0].0, path: named[0].1) }
        if named.count > 1 { return .choices(try named.map { try fileChoice($0.1, suffix: "") }) }
        let stems = try db.query("SELECT id, path, name FROM files WHERE name LIKE ? ESCAPE '\\' ORDER BY path LIMIT 50", [Self.escapedLike(query) + ".%"]) { ($0.int64(0), $0.string(1), $0.string(2)) }
            .filter { (($0.2 as NSString).deletingPathExtension) == query }
        if stems.count == 1 { return .file(id: stems[0].0, path: stems[0].1) }
        if stems.count > 1 { return .choices(try stems.map { try fileChoice($0.1, suffix: "") }) }
        let folders = try db.query("SELECT path FROM directories WHERE name = ? ORDER BY depth, path LIMIT 20", [query]) { $0.string(0) }
        if folders.count == 1 { return try folderTarget(folders[0]) }
        if folders.count > 1 { return .choices(try folders.map { try folderChoice($0) }) }
        // A declaration that differs only in case, last and only when it is the one match (`WAL` is a folder
        // before it is the property `wal`).
        if Self.parseSelector(query) == nil {
            let column = query.contains(".") ? "s.qualified_name" : "s.name"
            let loose = try groupDeclarations(try symbolRows(where: "\(column) = ? COLLATE NOCASE AND s.kind != 'extension'", [query], limit: 50))
            if loose.count == 1 { return .symbol(loose[0].rows) }
        }
        return nil
    }

    /// Declarations whose (qualified, else simple) name is `base` and whose selector is `selector`.
    private func declarations(withSelector parsed: (base: String, selector: String)) throws -> [SymbolRow] {
        let column = parsed.base.contains(".") ? "s.qualified_name" : "s.name"
        let candidates = try symbolRows(where: "\(column) = ? AND s.kind != 'extension'", [parsed.base], limit: 500)
        let selectors = try selectors(for: candidates)
        return candidates.filter { selectors[$0.id] == parsed.selector }
    }

    private func isModuleName(_ name: String) throws -> Bool {
        try db.scalarInt("SELECT COUNT(*) FROM modules WHERE name = ?", [name]) > 0
            || db.scalarInt("SELECT COUNT(*) FROM imports WHERE external_name = ?", [name]) > 0
    }

    private func moduleTarget(named name: String) throws -> UsageTarget? {
        let ids = try db.query("SELECT id FROM modules WHERE name = ?", [name]) { $0.int64(0) }
        guard !ids.isEmpty else { return nil }
        let files = try db.query("SELECT id FROM files WHERE module_id IN (\(ids.sqlList)) ORDER BY path") { $0.int64(0) }
        return .module(name: name, fileIDs: files)
    }

    private func frameworkTarget(named name: String) throws -> UsageTarget? {
        let importers = try db.query("""
            SELECT f.path, i.line FROM imports i JOIN files f ON f.id = i.file_id
            WHERE i.external_name = ? AND i.is_mock = 0 ORDER BY f.path, i.line
            """, [name]) { UsageTarget.Importer(path: $0.string(0), line: $0.int(1)) }
        return importers.isEmpty ? nil : .framework(name: name, importers: importers)
    }

    private func environmentUses(_ name: String) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM refs WHERE name = ?", ["env:" + name])
    }

    private func environmentSuggestions(_ name: String) throws -> [String] {
        try db.query("SELECT DISTINCT name FROM refs WHERE name LIKE 'env:%' AND name LIKE ? ORDER BY name LIMIT 8", ["%\(name.prefix(4))%"]) { $0.string(0) }
    }

    /// `API_KEY`, `ATLAS_SKIP_INTRO`: upper case, digits and underscores.
    static func looksLikeEnvironmentName(_ text: String) -> Bool {
        text.count >= 2 && text.first?.isUppercase == true
            && text.allSatisfy { ($0.isUppercase && $0.isASCII) || $0.isNumber || $0 == "_" }
            && (text.contains("_") || text.count >= 4)
    }

    // MARK: Grouping, selectors, exact target strings

    /// Groups declarations that are one target (`#if` variants: same file, qualified name and selector).
    func groupDeclarations(_ rows: [SymbolRow]) throws -> [DeclarationGroup] {
        let selectors = try selectors(for: rows)
        var groups: [DeclarationGroup] = []
        var index: [String: Int] = [:]
        for row in rows {
            let selector = selectors[row.id]
            let key = "\(row.fileID)\u{1}\(row.qualifiedName)\u{1}\(selector ?? "")"
            if let position = index[key] {
                groups[position].rows.append(row)
            } else {
                index[key] = groups.count
                groups.append(DeclarationGroup(rows: [row], selector: selector))
            }
        }
        return groups
    }

    /// Selectors (`embed(_:)`): `symbols.selector`, else derived from a Swift signature.
    func selectors(for rows: [SymbolRow]) throws -> [Int64: String] {
        guard !rows.isEmpty else { return [:] }
        var stored: [Int64: String] = [:]
        for chunk in stride(from: 0, to: rows.count, by: 500) {
            let ids = rows[chunk..<min(rows.count, chunk + 500)].map(\.id)
            try db.forEach("SELECT id, selector FROM symbols WHERE id IN (\(ids.sqlList)) AND selector IS NOT NULL") { stored[$0.int64(0)] = $0.string(1) }
        }
        var result: [Int64: String] = [:]
        for row in rows {
            if let selector = stored[row.id] {
                result[row.id] = selector
            } else if row.path.hasSuffix(".swift"), let selector = Self.selector(name: row.name, kind: row.kind, signature: row.signature) {
                result[row.id] = selector
            }
        }
        return result
    }

    /// `name(label:label:)` from a Swift declaration's signature (`public func embed(_ text: String) async`
    /// → `embed(_:)`; `case data(sequence: UInt64, Data)` → `data(sequence:_:)`); nil when it has no parameter
    /// clause or the stored signature was cut short. Subscript parameters have no argument label unless they
    /// name one.
    static func selector(name: String, kind: SymbolKind, signature: String?) -> String? {
        guard kind.isCallable || kind == .enumCase, let signature else { return nil }
        let characters = Array(signature)
        let keyword = Array(kind == .initializer ? "init" : name)
        guard !keyword.isEmpty else { return nil }
        // The declared name (not inside a longer word), then `?`/`!` (failable init) and a generic clause.
        var index = -1
        var search = 0
        while search + keyword.count <= characters.count {
            if Array(characters[search..<search + keyword.count]) == keyword,
               search == 0 || !(characters[search - 1].isLetter || characters[search - 1].isNumber || characters[search - 1] == "_" || characters[search - 1] == "."),
               search + keyword.count < characters.count, "(<?!".contains(characters[search + keyword.count]) {
                index = search + keyword.count
                break
            }
            search += 1
        }
        guard index >= 0 else { return nil }
        if characters[index] == "?" || characters[index] == "!" { index += 1 }
        if index < characters.count, characters[index] == "<" {
            var depth = 0
            while index < characters.count {
                if characters[index] == "<" { depth += 1 }
                if characters[index] == ">", characters[max(0, index - 1)] != "-" {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        break
                    }
                }
                index += 1
            }
        }
        guard index < characters.count, characters[index] == "(" else { return nil }
        // Split the balanced parameter clause on top-level commas.
        var parameters: [String] = []
        var current = ""
        var depth = 0
        var closed = false
        index += 1
        while index < characters.count {
            let character = characters[index]
            let isArrow = character == ">" && characters[index - 1] == "-"
            if "([{<".contains(character) { depth += 1 }
            if ")]}".contains(character) || (character == ">" && !isArrow) {
                if depth == 0 {
                    closed = character == ")"
                    break
                }
                depth -= 1
            }
            if character == "," && depth == 0 {
                parameters.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        guard closed else { return nil }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parameters.append(current) }
        let isSubscript = name == "subscript"
        let labels = parameters.map { parameter -> String in
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard let colon = Self.topLevelColon(in: trimmed) else { return "_" }
            let names = trimmed[..<colon].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).filter { !$0.hasPrefix("@") }
            guard let first = names.first else { return "_" }
            return isSubscript && names.count < 2 ? "_" : first
        }
        return String(keyword) + "(" + labels.map { $0 + ":" }.joined() + ")"
    }

    private static func topLevelColon(in text: String) -> String.Index? {
        var depth = 0
        var previous: Character = " "
        for index in text.indices {
            let character = text[index]
            if "([<{".contains(character) { depth += 1 }
            if ")]}".contains(character) || (character == ">" && previous != "-") { depth -= 1 }
            if character == ":" && depth == 0 { return index }
            previous = character
        }
        return nil
    }

    /// `Type.method(label:)` → base `Type.method`, selector `method(label:)`; nil for anything else.
    static func parseSelector(_ text: String) -> (base: String, selector: String)? {
        guard let match = text.wholeMatch(of: /([A-Za-z_][A-Za-z0-9_.]*)\(((?:[A-Za-z_][A-Za-z0-9_]*:)*)\)/) else { return nil }
        let base = String(match.1)
        let last = base.split(separator: ".").last.map(String.init) ?? base
        return (base, last + "(" + String(match.2) + ")")
    }

    /// The shortest string that selects exactly this declaration: `Type.member`, then with its selector, then
    /// `path#Type.member` (with its selector when the file overloads it), then `path:line`. Extensions: see
    /// `extensionTarget`.
    func exactTarget(for group: DeclarationGroup) throws -> String {
        let row = group.first
        if row.kind == .extension, try isSwiftFile(row.fileID) { return try extensionTarget(group.rows) }
        let all = try symbolRows(where: "s.qualified_name = ? AND s.kind != 'extension'", [row.qualifiedName], limit: 500)
        let groups = try groupDeclarations(all)
        if groups.count <= 1, try !namesSomethingElse(row.qualifiedName) { return row.qualifiedName }
        let prefix = row.qualifiedName.hasSuffix("." + row.name) ? String(row.qualifiedName.dropLast(row.name.count)) : ""
        if let selector = group.selector, groups.filter({ $0.selector == selector }).count == 1 {
            return prefix + selector
        }
        let inFile = groups.filter { $0.first.fileID == row.fileID }
        if inFile.count == 1 { return "\(row.path)#\(row.qualifiedName)" }
        if let selector = group.selector, inFile.filter({ $0.selector == selector }).count == 1 {
            return "\(row.path)#\(prefix)\(selector)"
        }
        return "\(row.path):\(row.lines.start)"
    }

    /// A bare name that is also a module, framework or environment variable name: as a target it would be
    /// ambiguous, so it cannot be a declaration's exact target string.
    private func namesSomethingElse(_ name: String) throws -> Bool {
        guard !name.contains(".") else { return false }
        if try db.scalarInt("SELECT COUNT(*) FROM modules WHERE name = ?", [name]) > 0 { return true }
        if try db.scalarInt("SELECT COUNT(*) FROM imports WHERE external_name = ? AND is_mock = 0", [name]) > 0 { return true }
        return try Self.looksLikeEnvironmentName(name) && environmentUses(name) > 0
    }

    /// Uses at the use threshold and the files they are in. An extension's uses are its members' from outside it.
    func useCounts(_ ids: [Int64]) throws -> (uses: Int, files: Int) {
        let members = try extensionMembers(of: ids)
        let scope = members.isEmpty ? "target_symbol_id IN (\(ids.sqlList))"
            : "target_symbol_id IN (\(members.sqlList)) AND (from_symbol_id IS NULL OR from_symbol_id NOT IN (\((ids + members).sqlList)))"
        return try db.queryOne("SELECT COUNT(*), COUNT(DISTINCT file_id) FROM refs WHERE \(scope) AND confidence >= ?", [Self.useThreshold]) { ($0.int(0), $0.int(1)) } ?? (0, 0)
    }

    /// The declarations inside the Swift extensions among `ids`, at any depth; empty when none of them is one.
    func extensionMembers(of ids: [Int64]) throws -> [Int64] {
        try db.query("""
            WITH RECURSIVE d(id) AS (SELECT id FROM symbols WHERE parent_id IN (SELECT s.id FROM symbols s JOIN files f ON f.id = s.file_id
                WHERE s.id IN (\(ids.sqlList)) AND s.kind = 'extension' AND f.language = 'swift')
              UNION SELECT s.id FROM symbols s JOIN d ON s.parent_id = d.id)
            SELECT id FROM d
            """, cache: false) { $0.int64(0) }
    }

    private func declarationChoice(_ group: DeclarationGroup) throws -> UsageTarget.Choice {
        let counts = try useCounts(group.ids)
        let row = group.first
        return UsageTarget.Choice(target: try exactTarget(for: group), kind: row.kind.displayName, location: "\(row.path):\(row.lines)", uses: counts.uses, files: counts.files)
    }

    /// Suggestions in the accepted syntax for a miss: declarations with the same simple name (members of the
    /// named type first, with their selectors), then the files that extend a type of that name (`path#Name`: a
    /// bare name never selects an extension), then fuzzy matches.
    func usageSuggestions(for query: String) throws -> [String] {
        var base = query
        if let paren = base.firstIndex(of: "(") { base = String(base[..<paren]) }
        if let hash = base.lastIndex(of: "#") { base = String(base[base.index(after: hash)...]) }
        let simple = String(base.split(separator: ".").last ?? Substring(base))
        guard !simple.isEmpty else { return [] }
        let owner = base.contains(".") ? String(base[..<base.lastIndex(of: ".")!]) : nil
        var rows = try symbolRows(where: "s.name = ? AND s.kind != 'extension'", [simple], limit: 40)
        if let owner {
            rows.sort { ($0.qualifiedName.hasPrefix(owner + ".") ? 0 : 1, $0.path) < ($1.qualifiedName.hasPrefix(owner + ".") ? 0 : 1, $1.path) }
        }
        var results: [String] = []
        for group in try groupDeclarations(rows).prefix(6) {
            results.append(try exactTarget(for: group))
        }
        results += try extensionTargets(of: base, limit: 6)
        // A fuzzy name that only extensions carry is given as their targets.
        for name in try suggestions(for: simple) {
            let declared = try db.scalarInt("SELECT COUNT(*) FROM symbols WHERE (name = ? OR qualified_name = ?) AND kind != 'extension'", [name, name]) > 0
            let targets = declared ? [] : try extensionTargets(of: name, limit: 3)
            results += targets.isEmpty ? [name] : targets
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0).inserted && $0 != query }.prefix(8).map { $0 }
    }

    /// The string that selects each file's extensions of the type `name`, for the first `limit` files by path.
    private func extensionTargets(of name: String, limit: Int) throws -> [String] {
        let rows = try extensions(of: name)
        var files: [Int64] = []
        for row in rows where !files.contains(row.fileID) { files.append(row.fileID) }
        return try files.prefix(limit).map { id in try extensionTarget(rows.filter { $0.fileID == id }) }
    }

    /// `vesalius debug target` for a target that selects extensions: each one with its members, the uses of the
    /// members from outside them, and the exact target string; nil for any other target.
    public func extensionTargetReport(_ text: String) throws -> String? {
        guard case .symbol(let rows) = try resolveUsageTarget(text), let row = rows.first, row.kind == .extension else { return nil }
        let group = try groupDeclarations(rows)[0]
        let counts = try useCounts(group.ids)
        var lines = ["\(text) → \(rows.count == 1 ? "1 extension" : "\(rows.count) extensions") of \(row.qualifiedName) in \(row.path) · "
            + "its members have \(counts.uses) \(counts.uses == 1 ? "use" : "uses") in \(counts.files) \(counts.files == 1 ? "file" : "files")"]
        for extensionRow in rows {
            lines.append("  \(extensionRow.signature ?? "extension " + extensionRow.qualifiedName)  :\(extensionRow.lines)")
            let members = try symbolRows(where: "s.parent_id = ? ORDER BY s.start_line", [extensionRow.id])
            let selectors = try selectors(for: members)
            lines += members.map { "    \(selectors[$0.id] ?? $0.name) :\($0.lines) · \($0.kind.displayName)" }
            if members.isEmpty { lines.append("    no members") }
        }
        lines.append("  exact target: \(try exactTarget(for: group))")
        return lines.joined(separator: "\n")
    }
}
