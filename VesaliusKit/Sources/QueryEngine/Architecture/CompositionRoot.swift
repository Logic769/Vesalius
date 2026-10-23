import Foundation
import RepositoryIndex
import VesaliusCore

/// Where an app starts (the architecture view's `root`): the `@main` type, what it wires at launch, the view its `WindowGroup`
/// shows, that view's tabs and what it presents, and the persistent stores the app opens.
///
/// Launch calls, the root view and what it presents come from `refs` of the `@main` and root view types.
/// Tabs and store names are read from the files by a line scan over code and string regions: the `TabView`
/// in the `@main` file or the root view's file, and store file names (`"library.store"`) in the files that set
/// up a `ModelContainer` or a Core Data container.
extension ArchitectureContext {
    func compositionRoot(of target: TargetRow) throws -> ArchitectureOverview.CompositionRoot? {
        guard let entry = try entry(of: target), entry.kind == "@main", let path = entry.path, let line = entry.line,
              let fileID = fileIDs[path] else { return nil }
        var root = ArchitectureOverview.CompositionRoot(type: entry.name, path: path, line: line)
        let ids = Set(targetFiles[target.id] ?? [])

        // The target's own top-level types, and which are SwiftUI views.
        var typeFiles: [String: Int64] = [:]
        var views = Set<String>()
        try db.forEach("""
            SELECT name, file_id, inherits FROM symbols
            WHERE depth = 0 AND is_local = 0 AND kind IN ('class', 'struct', 'enum', 'actor', 'protocol')
            """) { row in
            let file = row.int64(1)
            guard ids.contains(file) else { return }
            let name = row.string(0)
            if typeFiles[name] == nil { typeFiles[name] = file }
            if (row.optionalString(2) ?? "").split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "View" }) { views.insert(name) }
        }

        let main = try typeReferences(type: entry.name, in: fileID)
        root.launch = Self.unique(main.refs.compactMap { ref -> String? in
            guard ref.kind == "call", !Self.isDebugOnly(ref.conditions) else { return nil }
            if let receiver = ref.receiver, typeFiles[receiver] != nil { return "\(receiver).\(ref.name)" }
            if let id = ref.receiverRef, let producer = main.byID[id], producer.name == "shared",
               let owner = producer.receiver, typeFiles[owner] != nil {
                return "\(owner).shared.\(ref.name)"
            }
            return nil
        })

        // The root view: what `body` shows first, preferring the conventional root names.
        let shown = main.refs.filter { $0.kind == "instantiate" && $0.member == "body" && views.contains($0.name) && !Self.isDebugOnly($0.conditions) }.map(\.name)
        let preferred = ["ContentView", "RootView", "AppView", "MainView"]
        root.rootView = shown.first { preferred.contains($0) } ?? shown.first { $0.hasSuffix("RootView") } ?? shown.first

        var scanned = [path]
        var presented: [String] = []
        if let rootView = root.rootView, let rootFile = typeFiles[rootView], let rootPath = files[rootFile]?.path {
            if !scanned.contains(rootPath) { scanned.append(rootPath) }
            let rootRefs = try typeReferences(type: rootView, in: rootFile)
            presented = Self.unique(rootRefs.refs.filter { $0.kind == "instantiate" && views.contains($0.name) && $0.name != rootView && !Self.isDebugOnly($0.conditions) }.map(\.name))
        }
        for scannedPath in scanned where root.tabs.isEmpty {
            root.tabs = tabs(in: scannedPath, views: views)
        }
        let tabViews = Set(root.tabs.map(\.view))
        root.presents = presented.filter { !tabViews.contains($0) }
        root.stores = try stores(of: target, mainPath: path)
        return root
    }

    /// Code under positive `#if DEBUG`: test and demo wiring, not how the app starts.
    static func isDebugOnly(_ conditions: String?) -> Bool {
        guard let conditions else { return false }
        return conditions.split(separator: "&").contains { $0.trimmingCharacters(in: .whitespaces) == "DEBUG" }
    }

    struct MemberRef {
        let id: Int64
        let line: Int
        let name: String
        let kind: String
        let receiver: String?
        let receiverRef: Int64?
        let conditions: String?
        /// The member of the type the reference sits in (`body`, `init`); nil in the type itself.
        let member: String?
    }

    /// The references inside a type's declaration (its members, nested at any depth), in line order, and every
    /// reference of the file by id (for `receiver_ref` chains).
    func typeReferences(type: String, in fileID: Int64) throws -> (refs: [MemberRef], byID: [Int64: MemberRef]) {
        guard let typeID = try db.queryOne("SELECT id FROM symbols WHERE file_id = ? AND name = ? AND depth = 0 ORDER BY start_line LIMIT 1", [fileID, type], { $0.int64(0) }) else {
            return ([], [:])
        }
        // The type and its members, with the top member each belongs to.
        var memberOf: [Int64: String?] = [typeID: nil]
        var frontier: [(Int64, String?)] = [(typeID, nil)]
        while let (parent, member) = frontier.popLast() {
            try db.forEach("SELECT id, name FROM symbols WHERE parent_id = ?", [parent]) { row in
                let name: String? = member ?? row.string(1)
                memberOf[row.int64(0)] = name
                frontier.append((row.int64(0), name))
            }
        }
        var all: [Int64: MemberRef] = [:]
        var inside: [MemberRef] = []
        try db.forEach("""
            SELECT id, line, name, kind, receiver, receiver_ref, conditions, from_symbol_id FROM refs WHERE file_id = ? ORDER BY line, col
            """, [fileID]) { row in
            let from = row.optionalInt64(7)
            let member: String? = from.flatMap { memberOf[$0] ?? nil }
            let ref = MemberRef(id: row.int64(0), line: row.int(1), name: row.string(2), kind: row.string(3), receiver: row.optionalString(4),
                                receiverRef: row.optionalInt64(5), conditions: row.optionalString(6), member: member)
            all[ref.id] = ref
            if let from, memberOf[from] != nil { inside.append(ref) }
        }
        return (inside, all)
    }

    // MARK: Tabs

    /// The children of the first `TabView` in a file: each tab's view (looking inside `Tab { }`,
    /// `NavigationStack { }` and the like) and its title when that is not the view's own name.
    func tabs(in path: String, views: Set<String>) -> [ArchitectureOverview.Tab] {
        guard let file = engine.sourceText.file(path) else { return [] }
        let bytes = file.bytes
        let regions = file.regions
        let code = CodeLexer.Region.code.rawValue
        let name = Array("TabView".utf8)
        guard let start = file.occurrences(of: name).first(where: { regions[$0] == code }) else { return [] }
        // The content closure: the first `{` after the name, past any argument list.
        var index = start + name.count
        var parens = 0
        while index < bytes.count {
            if regions[index] == code {
                let byte = bytes[index]
                if byte == 40 { parens += 1 } else if byte == 41 { parens -= 1 } else if byte == 123 && parens == 0 { break }
                if parens < 0 { return [] }
            }
            index += 1
        }
        guard index < bytes.count else { return [] }
        let firstLine = file.line(atOffset: index) + 1

        // Statements at depth 1 inside the closure, each with its lines.
        var tabs: [ArchitectureOverview.Tab] = []
        var depth = 1
        var statement: [(line: Int, depth: Int, text: String)] = []
        func finish() {
            defer { statement.removeAll() }
            guard let head = statement.first else { return }
            let viewLine = statement.first { Self.leadingIdentifier($0.text).map(views.contains) ?? false }
            guard let viewLine, let view = Self.leadingIdentifier(viewLine.text) else { return }
            // `Tab("Plans", …)` or `.tabItem { Label("Plans", …) }`.
            var title: String?
            if Self.leadingIdentifier(head.text) == "Tab" { title = Self.firstStringLiteral(head.text) }
            if title == nil, let label = statement.first(where: { $0.text.contains("Label(") || $0.text.contains("Text(") }) {
                title = Self.firstStringLiteral(label.text)
            }
            let stem = view.hasSuffix("View") ? String(view.dropLast(4)) : view
            if let current = title, current.caseInsensitiveCompare(stem) == .orderedSame || current.caseInsensitiveCompare(view) == .orderedSame { title = nil }
            if !tabs.contains(where: { $0.view == view }) { tabs.append(ArchitectureOverview.Tab(view: view, title: title)) }
        }
        var number = firstLine
        while number <= file.lineCount, depth > 0 {
            guard let range = file.range(ofLine: number) else { break }
            let startDepth = depth
            var text: [UInt8] = []
            for offset in range where regions[offset] == code || regions[offset] == CodeLexer.Region.string.rawValue {
                let byte = bytes[offset]
                if regions[offset] == code {
                    if byte == 123 { depth += 1 } else if byte == 125 { depth -= 1 }
                }
                text.append(byte)
            }
            let line = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                // A new statement starts at depth 1 with an identifier (a modifier line starts with `.`).
                if startDepth == 1, let first = line.first, first.isLetter || first == "_" {
                    finish()
                }
                if startDepth >= 1 { statement.append((number, startDepth, line)) }
            }
            number += 1
        }
        finish()
        return tabs
    }

    /// The identifier a line starts with, when a call follows it: `HomeView()` → `HomeView`.
    static func leadingIdentifier(_ line: String) -> String? {
        var name = ""
        for character in line {
            if character.isLetter || character.isNumber || character == "_" { name.append(character) } else { break }
        }
        guard !name.isEmpty, name.first?.isUppercase == true else { return nil }
        let rest = line.dropFirst(name.count).drop { $0 == " " }
        return rest.first == "(" || rest.first == "{" ? name : nil
    }

    static func firstStringLiteral(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\"") else { return nil }
        let rest = line[line.index(after: open)...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<close])
        return value.isEmpty || value.count > 40 ? nil : value
    }

    // MARK: Stores

    /// Store file names (`"library.store"`, `"plans.sqlite"`) in string literals of the target's files that set
    /// up a SwiftData `ModelContainer` or a Core Data container, with the models of the schema in that file.
    func stores(of target: TargetRow, mainPath: String) throws -> [ArchitectureOverview.Store] {
        let ids = Set(targetFiles[target.id] ?? [])
        var candidates = Set<Int64>()
        try db.forEach("""
            SELECT DISTINCT file_id FROM refs
            WHERE name IN ('ModelContainer', 'ModelConfiguration', 'NSPersistentContainer', 'NSPersistentCloudKitContainer', 'NSPersistentStoreDescription')
            """) { row in
            if ids.contains(row.int64(0)), files[row.int64(0)]?.isTest == false { candidates.insert(row.int64(0)) }
        }
        let paths = candidates.compactMap { files[$0]?.path }.sorted { ($0 == mainPath ? 0 : 1, $0) < ($1 == mainPath ? 0 : 1, $1) }
        let pattern = /"([A-Za-z0-9_][A-Za-z0-9_.-]*\.(?:store|sqlite3?|sqlite|db))"/
        var stores: [ArchitectureOverview.Store] = []
        for path in paths {
            guard let file = engine.sourceText.file(path) else { continue }
            let regions = file.regions
            var models: Int?
            for number in 1...max(1, file.lineCount) {
                guard let text = file.text(ofLine: number), let range = file.range(ofLine: number) else { continue }
                for match in text.matches(of: pattern) {
                    // The literal must be a string in code, not a quote inside a comment.
                    let offset = range.lowerBound + text.utf8.distance(from: text.startIndex, to: match.range.lowerBound) + 1
                    guard offset < regions.count, regions[offset] == CodeLexer.Region.string.rawValue else { continue }
                    let name = String(match.1)
                    if models == nil { models = schemaModels(in: file) }
                    if let index = stores.firstIndex(where: { $0.name == name }) {
                        if stores[index].path != path, !stores[index].otherSites.contains(path) { stores[index].otherSites.append(path) }
                    } else {
                        stores.append(ArchitectureOverview.Store(name: name, path: path, line: number, models: models))
                    }
                }
            }
        }
        return stores
    }

    /// The `X.self` entries of the first `Schema([…])` in a file.
    func schemaModels(in file: SourceText.File) -> Int? {
        let bytes = file.bytes
        let regions = file.regions
        let code = CodeLexer.Region.code.rawValue
        guard let start = file.occurrences(of: Array("Schema".utf8)).first(where: { offset in
            regions[offset] == code && offset + 8 <= bytes.count && bytes[offset + 6] == 40 && bytes[offset + 7] == 91
        }) else { return nil }
        var index = start + 8
        var depth = 1
        var text: [UInt8] = []
        while index < bytes.count, depth > 0 {
            if regions[index] == code {
                if bytes[index] == 91 { depth += 1 } else if bytes[index] == 93 { depth -= 1 }
                if depth > 0 { text.append(bytes[index]) }
            }
            index += 1
        }
        let count = String(decoding: text, as: UTF8.self).components(separatedBy: ".self").count - 1
        return count > 0 ? count : nil
    }
}
