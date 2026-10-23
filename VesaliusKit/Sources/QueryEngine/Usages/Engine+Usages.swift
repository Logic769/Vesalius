import Foundation
import RepositoryIndex
import VesaliusCore

/// `usages`: who calls, uses, imports or depends on a target, with every site as file:line plus code.
///
/// 1. The target string is resolved by `UsageTarget`; several matches give choices, never a merge.
/// 2. The view follows from the kind of target: callers, property, type, extension (a type view limited to its
///    members), file, folder, module, framework or environment variable.
/// 3. Sites come from one row per occurrence at the use threshold; the totals are counted from the same rows.
/// 4. Every occurrence of the target's name is reconciled with those rows for the completeness line.
/// 5. Statements, enclosing conditions and consuming statements are read from the files.
/// 6. The result is memoized per index version; pages are slices of that one result, cut by the renderer.
extension RepositoryEngine {
    /// The uses of `target`. `page` is accepted for symmetry with the tool: every page is cut from the same
    /// memoized result by the renderer, so the engine computes it once. Quoted files edited since indexing are
    /// listed in `staleFiles` (checked on every call, never memoized).
    public func usages(_ target: String, change: UsageChange? = nil, page: Int = 1) throws -> UsagesResult {
        let resolved = try resolveUsageTarget(target)
        let key = "usages|\(Self.normalizedTarget(target, root: root))|\(change?.rawValue ?? "-")"
        var result = try memoized(key) {
            try UsageBuilder(engine: self).build(resolved, query: target, change: change)
        }
        result.staleFiles = try staleFiles(Self.quotedFiles(result))
        return result
    }

    /// Files whose lines the result quotes: the declaration's, every listed file's, the declaring file's.
    static func quotedFiles(_ result: UsagesResult) -> [String] {
        var paths = Set(result.files.map(\.path))
        if let path = result.header.path { paths.insert(path) }
        if let path = result.declaringFile?.path { paths.insert(path) }
        return paths.sorted()
    }
}

// MARK: - Rows

/// A reference row as the usages views read it.
struct UsageRow: Sendable, Hashable {
    let id: Int64
    let fileID: Int64
    let line: Int
    let column: Int
    let name: String
    let kind: String
    let context: String?
    let stmtLine: Int?
    let endLine: Int?
    let callEndLine: Int?
    let receiver: String?
    let receiverRef: Int64?
    let typeEvidenceLine: Int?
    let argLabels: String?
    let conditions: String?
    let assignedTo: String?
    let consumerLine: Int?
    let fromSymbolID: Int64?
    let targetSymbolID: Int64?
    let targetFileID: Int64?
    let confidence: Double
    let basis: String?
    let receiverType: String?
    let isExternal: Bool
    let externalModule: String?
    let altSymbolID: Int64?

    static let columns = """
        r.id, r.file_id, r.line, r.col, r.name, r.kind, r.context, r.stmt_line, r.end_line, r.call_end_line, r.receiver,
        r.receiver_ref, r.type_evidence_line, r.arg_labels, r.conditions, r.assigned_to, r.consumer_line, r.from_symbol_id,
        r.target_symbol_id, r.target_file_id, r.confidence, r.basis, r.receiver_type, r.is_external, r.external_module, r.alt_symbol_id
        """

    init(_ row: SQLRow) {
        id = row.int64(0)
        fileID = row.int64(1)
        line = row.int(2)
        column = row.int(3)
        name = row.string(4)
        kind = row.string(5)
        context = row.optionalString(6)
        stmtLine = row.optionalInt(7)
        endLine = row.optionalInt(8)
        callEndLine = row.optionalInt(9)
        receiver = row.optionalString(10)
        receiverRef = row.optionalInt64(11)
        typeEvidenceLine = row.optionalInt(12)
        argLabels = row.optionalString(13)
        conditions = row.optionalString(14)
        assignedTo = row.optionalString(15)
        consumerLine = row.optionalInt(16)
        fromSymbolID = row.optionalInt64(17)
        targetSymbolID = row.optionalInt64(18)
        targetFileID = row.optionalInt64(19)
        confidence = row.double(20)
        basis = row.optionalString(21)
        receiverType = row.optionalString(22)
        isExternal = row.bool(23)
        externalModule = row.optionalString(24)
        altSymbolID = row.optionalInt64(25)
    }

    var isCall: Bool { kind == ReferenceKind.call.rawValue || kind == ReferenceKind.instantiate.rawValue || kind == ReferenceKind.decorator.rawValue }
    var isWrite: Bool { kind == ReferenceKind.write.rawValue }
    var isTypeUse: Bool { kind == ReferenceKind.typeUse.rawValue }

    /// `$x`, `\.x`, `.x`, `case .x`: forms worth naming next to the site.
    var form: String? {
        switch context {
        case ReferenceContext.projected.rawValue, ReferenceContext.keypath.rawValue, ReferenceContext.implicit.rawValue, ReferenceContext.pattern.rawValue: context
        default: nil
        }
    }
}

/// An indexed file as the usages views describe it.
struct UsageFileInfo: Sendable {
    let id: Int64
    let path: String
    let language: Language
    let isTest: Bool
    let testKind: String?
    let analyzer: String?
    let moduleID: Int64?
    let size: Int
    let modified: Double
    /// Build targets that compile it, application targets first.
    var targets: [String] = []
    /// How the first target's membership was decided (`sync-root`, `exception-add`…) and where.
    var membership: (via: String, evidence: String?)?

    /// TypeScript, JavaScript and Python: uses are named imports, shown with their import line.
    var isScript: Bool { language == .typescript || language == .javascript || language == .python }
}

/// A declaration as the usages views describe it.
struct UsageSymbolInfo: Sendable {
    let id: Int64
    let fileID: Int64
    let parentID: Int64?
    let name: String
    let qualifiedName: String
    let kind: SymbolKind
    let lines: LineRange
    let signature: String?
    let doc: String?
    let visibility: String?
    let isExported: Bool
    let attributes: String?
    let inherits: String?
    let selector: String?
    let conditions: String?
    let depth: Int
    let isLocal: Bool
    let declaredType: String?
    /// The language of its file: only Swift declarations are named by selector.
    let language: Language

    static let columns = """
        s.id, s.file_id, s.parent_id, s.name, s.qualified_name, s.kind, s.start_line, s.end_line, s.signature, s.doc, s.visibility,
        s.is_exported, s.attributes, s.inherits, s.selector, s.conditions, s.depth, s.is_local, s.declared_type,
        (SELECT language FROM files WHERE id = s.file_id)
        """

    init(_ row: SQLRow) {
        id = row.int64(0)
        fileID = row.int64(1)
        parentID = row.optionalInt64(2)
        name = row.string(3)
        qualifiedName = row.string(4)
        kind = SymbolKind(rawValue: row.string(5)) ?? .variable
        lines = LineRange(row.int(6), row.int(7))
        signature = row.optionalString(8)
        doc = row.optionalString(9)
        visibility = row.optionalString(10)
        isExported = row.bool(11)
        attributes = row.optionalString(12)
        inherits = row.optionalString(13)
        selector = row.optionalString(14)
        conditions = row.optionalString(15)
        depth = row.int(16)
        isLocal = row.bool(17)
        declaredType = row.optionalString(18)
        language = Language(rawValue: row.optionalString(19) ?? "") ?? .unknown
    }

    var isProperty: Bool { kind == .property || kind == .variable || kind == .constant }
    var isPrivate: Bool { visibility == Visibility.private.rawValue || visibility == Visibility.fileprivate.rawValue }
}

// MARK: - Builder

/// Builds one `usages` result. Loads files and declarations once per result and reads code through the
/// engine's `SourceText`.
final class UsageBuilder {
    let engine: RepositoryEngine
    let db: SQLiteDatabase
    let threshold = RepositoryEngine.useThreshold
    private(set) var files: [Int64: UsageFileInfo] = [:]
    private(set) var symbols: [Int64: UsageSymbolInfo] = [:]
    /// Whether the repository has a project model (build targets): then a file no target builds is `not built`.
    private(set) lazy var hasProjectModel: Bool = ((try? db.scalarInt("SELECT COUNT(*) FROM file_targets")) ?? 0) > 0

    /// Primary statements read from the files; beyond this, sites keep their line only.
    static let statementBudget = 400

    init(engine: RepositoryEngine) throws {
        self.engine = engine
        self.db = try engine.db
    }

    // MARK: Dispatch

    func build(_ target: UsageTarget, query: String, change: UsageChange?) throws -> UsagesResult {
        switch target {
        case .symbol(let rows):
            let group = try engine.groupDeclarations(rows)[0]
            try loadSymbols(group.ids)
            guard let symbol = symbols[group.first.id] else { throw EngineError.notFound(query, suggestions: []) }
            if symbol.kind == .extension, try engine.isSwiftFile(symbol.fileID) {
                return try extensionView(group, symbol: symbol, change: change)
            }
            // An Objective-C `@implementation` or a Rust `impl` reads as the type it implements.
            if symbol.kind.isType || symbol.kind == .extension {
                return try typeView(group, symbol: symbol, change: change)
            }
            if symbol.kind.isCallable {
                return try callersView(group, symbol: symbol, change: change)
            }
            if symbol.isProperty {
                return try propertyView(group, symbol: symbol, change: change)
            }
            return try callersView(group, symbol: symbol, change: change)
        case .file(let id, let path):
            return try fileView(fileID: id, path: path, change: change)
        case .folder(let path, let fileIDs):
            return try groupView(.folder, name: path.isEmpty ? "." : path + "/", fileIDs: fileIDs, change: change)
        case .module(let name, let fileIDs):
            return try groupView(.module, name: name, fileIDs: fileIDs, change: change)
        case .framework(let name, let importers):
            return try frameworkView(name: name, importers: importers)
        case .environment(let name):
            return try environmentView(name: name)
        case .choices(let choices):
            return choicesResult(query: query, choices: choices, change: change)
        }
    }

    private func choicesResult(query: String, choices: [UsageTarget.Choice], change: UsageChange?) -> UsagesResult {
        let sorted = choices.sorted { $0.uses == $1.uses ? $0.target < $1.target : $0.uses > $1.uses }
        return UsagesResult(
            view: .choices, target: query, change: change,
            header: UsageHeader(title: RepositoryEngine.normalizedTarget(query, root: engine.root), kind: "\(choices.count) targets"),
            totals: UsageTotals(noun: "choice", count: choices.count, files: 0),
            choices: sorted.map { UsageChoice(target: $0.target, kind: $0.kind, location: $0.location, uses: $0.uses, files: $0.files) })
    }

    // MARK: Loading

    /// Reference rows matching `clause` (on alias `r`).
    func rows(where clause: String, _ values: [any SQLBindable] = []) throws -> [UsageRow] {
        try db.query("SELECT \(UsageRow.columns) FROM refs r WHERE \(clause)", values, cache: false) { UsageRow($0) }
    }

    /// Rows that resolved to any of `ids` at the use threshold, in file and line order.
    func rows(targeting ids: [Int64]) throws -> [UsageRow] {
        var result: [UsageRow] = []
        for chunk in Self.chunks(ids) {
            result += try rows(where: "r.target_symbol_id IN (\(chunk.sqlList)) AND r.confidence >= ?", [threshold])
        }
        return result.sorted { ($0.fileID, $0.line, $0.column) < ($1.fileID, $1.line, $1.column) }
    }

    static func chunks(_ ids: [Int64], size: Int = 500) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min(ids.count, $0 + size)]) }
    }

    func loadFiles<S: Sequence>(_ ids: S) throws where S.Element == Int64 {
        let missing = Array(Set(ids).filter { files[$0] == nil })
        guard !missing.isEmpty else { return }
        for chunk in Self.chunks(missing) {
            try db.forEach("SELECT id, path, language, is_test, test_kind, analyzer, module_id, size, mtime FROM files WHERE id IN (\(chunk.sqlList))") { row in
                files[row.int64(0)] = UsageFileInfo(
                    id: row.int64(0), path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown, isTest: row.bool(3),
                    testKind: row.optionalString(4), analyzer: row.optionalString(5), moduleID: row.optionalInt64(6), size: row.int(7), modified: row.double(8))
            }
            var memberships: [Int64: [(name: String, isTest: Bool, via: String, evidence: String?)]] = [:]
            try db.forEach("""
                SELECT ft.file_id, t.name, t.is_test, ft.via, ft.evidence_path, ft.evidence_line FROM file_targets ft JOIN targets t ON t.id = ft.target_id
                WHERE ft.file_id IN (\(chunk.sqlList)) ORDER BY t.is_test, t.id
                """) { row in
                let evidence = row.optionalString(4).map { path in row.optionalInt(5).map { "\(path):\($0)" } ?? path }
                memberships[row.int64(0), default: []].append((row.string(1), row.bool(2), row.string(3), evidence))
            }
            for (id, targets) in memberships {
                files[id]?.targets = targets.map(\.name)
                if let first = targets.first { files[id]?.membership = (first.via, first.evidence) }
            }
        }
    }

    func loadSymbols<S: Sequence>(_ ids: S) throws where S.Element == Int64 {
        let missing = Array(Set(ids).filter { symbols[$0] == nil })
        guard !missing.isEmpty else { return }
        for chunk in Self.chunks(missing) {
            try db.forEach("SELECT \(UsageSymbolInfo.columns) FROM symbols s WHERE s.id IN (\(chunk.sqlList))") { row in
                let symbol = UsageSymbolInfo(row)
                symbols[symbol.id] = symbol
            }
        }
    }

    func symbols(where clause: String, _ values: [any SQLBindable] = []) throws -> [UsageSymbolInfo] {
        let found = try db.query("SELECT \(UsageSymbolInfo.columns) FROM symbols s WHERE \(clause)", values, cache: false) { UsageSymbolInfo($0) }
        for symbol in found { symbols[symbol.id] = symbol }
        return found
    }

    func file(_ id: Int64) -> UsageFileInfo? { files[id] }
    func symbol(_ id: Int64?) -> UsageSymbolInfo? { id.flatMap { symbols[$0] } }

    /// The symbol's parents, innermost first.
    func ancestors(of id: Int64) throws -> [UsageSymbolInfo] {
        var chain: [UsageSymbolInfo] = []
        var cursor = symbols[id]?.parentID
        while let parent = cursor, chain.count < 12 {
            try loadSymbols([parent])
            guard let symbol = symbols[parent] else { break }
            chain.append(symbol)
            cursor = symbol.parentID
        }
        return chain
    }

    // MARK: Ordering and labels

    /// Ordering: production before tests, direct before type-inferred, unconditional before `#if`, then path.
    func orderFiles(_ list: [UsageFile]) -> [UsageFile] {
        list.sorted { a, b in
            let ka = (a.isTest ? 1 : 0, a.labels.contains { $0.hasPrefix("type-inferred") } ? 1 : 0, a.labels.contains { $0.hasPrefix("#if") } ? 1 : 0)
            let kb = (b.isTest ? 1 : 0, b.labels.contains { $0.hasPrefix("type-inferred") } ? 1 : 0, b.labels.contains { $0.hasPrefix("#if") } ? 1 : 0)
            return ka != kb ? ka < kb : a.path < b.path
        }
    }

    /// `[#if DEBUG]` when every site of the file shares a condition; `[test]` from the build target; `[not built]`
    /// when the repository has build targets and none compiles the file.
    func fileLabels(_ info: UsageFileInfo, sites: [UsageRow]) -> [String] {
        var labels: [String] = []
        if info.isTest { labels.append(info.testKind == "ui" ? "UI test" : "test") }
        if let shared = Self.sharedCondition(sites.map(\.conditions)) { labels.append("#if " + shared) }
        if hasProjectModel, info.targets.isEmpty, info.language == .swift { labels.append("not built") }
        return labels
    }

    /// The condition every element shares (the whole stack), or nil.
    static func sharedCondition(_ conditions: [String?]) -> String? {
        guard let first = conditions.first, let shared = first, !shared.isEmpty else { return nil }
        return conditions.allSatisfy { $0 == shared } ? shared : nil
    }

    // MARK: Code

    /// The statement around a site as evidence lines (at most 3, each at most 110 characters), with the
    /// governing condition when one sits within 2 lines above. A file edited since indexing is read by bracket
    /// balancing, never through the index's (possibly moved) statement bounds.
    func statement(_ row: UsageRow, path: String, withCondition: Bool = true) -> (code: [UsageCodeLine], condition: UsageCodeLine?) {
        let fresh = isFresh(row.fileID)
        guard var statement = fresh
            ? engine.sourceText.statement(path, line: row.line, stmt: row.stmtLine, end: row.endLine, callEnd: row.callEndLine, name: Self.token(row.name), column: row.column)
            : engine.sourceText.statement(path, line: row.line, name: Self.token(row.name)) else { return ([], nil) }
        // A site two or more lines into a statement whose earlier lines it does not close (a SwiftUI modifier
        // chain, a builder) is shown from its own line: the head is another expression's code.
        if row.line - statement.start >= 2, let file = engine.sourceText.file(path), file.balance(ofLine: row.line).low >= 0,
           let trimmed = engine.sourceText.statement(path, line: row.line, stmt: row.line, end: min(statement.end, row.line + 2), name: Self.token(row.name), column: row.column) {
            statement = trimmed
        }
        var code = statement.rendered().map { UsageCodeLine(line: $0.number, text: $0.text) }
        // Rows of a statement print as consecutive numbers; a skipped blank or comment line would shift them.
        if code.count > 1, zip(code, code.dropFirst()).contains(where: { $1.line != $0.line + 1 }) {
            code = [UsageCodeLine(line: statement.start, text: statement.text())]
        }
        code = code.filter { !$0.text.isEmpty }
        // Lines after the site that only close brackets (`},`, `});`) end an enclosing literal, not this statement.
        while code.count > 1, let last = code.last, last.line > row.line, last.text.allSatisfy({ ")]},;".contains($0) || $0 == " " }) {
            code.removeLast()
        }
        var condition: UsageCodeLine?
        if withCondition, let line = engine.sourceText.enclosingCondition(path, statementStart: statement.start), line.number < statement.start {
            condition = UsageCodeLine(line: line.number, text: line.text)
        }
        return (code, condition)
    }

    /// One line of code for a secondary site: the line as written (comments dropped), elided around the name.
    func lineText(_ row: UsageRow, path: String, line: Int? = nil, maxLength: Int = 110) -> UsageCodeLine? {
        let number = line ?? row.line
        guard let file = engine.sourceText.file(path), let range = file.range(ofLine: number) else { return nil }
        let text = file.codeText(range)
        guard !text.isEmpty else { return nil }
        let characters = Array(text)
        let token = Array(Self.token(row.name))
        var focus: Range<Int>?
        if !token.isEmpty, characters.count >= token.count {
            for index in 0...(characters.count - token.count) where Array(characters[index..<index + token.count]) == token {
                focus = index..<index + token.count
                break
            }
        }
        return UsageCodeLine(line: number, text: Statement.elide(text, to: maxLength, keeping: focus))
    }

    /// The consuming statement's head (`→ :42 db.insert(apiTokens)`), for fresh files only.
    func consumer(_ row: UsageRow, path: String) -> UsageCodeLine? {
        guard let line = row.consumerLine, line > row.line, isFresh(row.fileID),
              let consumer = engine.sourceText.consumer(path, line: line, maxLength: 70) else { return nil }
        // A statement cut at its block (`return {`) says little: its own line says more.
        if consumer.number == line, consumer.text.count < 12, let own = lineText(row, path: path, line: line, maxLength: 70), own.text.count > consumer.text.count {
            return own
        }
        return UsageCodeLine(line: consumer.number, text: consumer.text)
    }

    private var freshness: [Int64: Bool] = [:]

    /// True when the file on disk still has the size and modification time the index recorded.
    func isFresh(_ fileID: Int64) -> Bool {
        if let known = freshness[fileID] { return known }
        guard let info = files[fileID] else { return false }
        let fresh = !engine.sourceText.isStale(info.path, indexed: SourceText.Stamp(size: info.size, modified: info.modified))
        freshness[fileID] = fresh
        return fresh
    }

    /// The identifier as it appears in source: `env:NAME` rows name `NAME`.
    static func token(_ name: String) -> String {
        name.hasPrefix("env:") ? String(name.dropFirst(4)) : name
    }

    // MARK: Names

    /// How a declaration is named in a heading: modifiers, its keyword and its qualified selector
    /// (`private func ImportSheet.beginImport(urls:)`, `static func DemoLibrary.seedIfRequested(_:)`,
    /// `var ContentView.body`, `function loadToken`). Attributes are left out unless `attributes` is set.
    func heading(_ symbol: UsageSymbolInfo, attributes: Bool = false, tail: Bool = false) -> String {
        let qualified = displayName(symbol)
        guard let signature = symbol.signature.map(Self.oneLine), !signature.isEmpty else {
            return qualified
        }
        let keyword = symbol.kind == .initializer ? "init" : symbol.name
        guard let range = Self.declaredName(keyword, in: signature) else {
            return qualified
        }
        var prefix = String(signature[..<range.lowerBound])
        if !attributes {
            prefix = prefix.split(separator: " ").filter { !$0.hasPrefix("@") }.joined(separator: " ")
            if !prefix.isEmpty { prefix += " " }
        }
        var text = prefix + qualified
        if tail, symbol.kind.isCallable, let close = Self.parameterClauseEnd(signature, from: range.upperBound) {
            let rest = signature[close...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, !rest.hasPrefix("{") { text += " " + rest }
        } else if tail, !symbol.kind.isCallable {
            // A property's type and short initializer.
            let rest = String(signature[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { text += (rest.hasPrefix(":") ? "" : " ") + rest }
        }
        return text
    }

    /// `LibraryService.importBook(from:preferences:modelContext:)`: the qualified name with its selector.
    func displayName(_ symbol: UsageSymbolInfo) -> String {
        guard symbol.kind.isCallable || symbol.kind == .enumCase, symbol.language == .swift,
              let selector = symbol.selector ?? RepositoryEngine.selector(name: symbol.name, kind: symbol.kind, signature: symbol.signature) else {
            return symbol.qualifiedName
        }
        let owner = symbol.qualifiedName.hasSuffix("." + symbol.name) ? String(symbol.qualifiedName.dropLast(symbol.name.count)) : ""
        return owner + selector
    }

    /// `ReadingPlan.schedule`: a declaration named by its type and base name, for member summaries.
    func enclosingName(_ symbol: UsageSymbolInfo) -> String {
        let parts = symbol.qualifiedName.split(separator: ".")
        return parts.suffix(2).joined(separator: ".")
    }

    /// The short name of a caller relative to `context`: its selector inside the same type, else qualified.
    func callerName(_ symbol: UsageSymbolInfo, relativeTo context: UsageSymbolInfo?) -> String {
        let full = displayName(symbol)
        guard let context, let parent = symbol.parentID, parent == context.parentID || parent == context.id else { return full }
        let owner = symbol.qualifiedName.hasSuffix("." + symbol.name) ? String(symbol.qualifiedName.dropLast(symbol.name.count)) : ""
        return owner.isEmpty ? full : String(full.dropFirst(owner.count))
    }

    static func oneLine(_ text: String) -> String {
        Statement.collapse(text.replacingOccurrences(of: "\n", with: " "))
    }

    /// The declared name in a signature: not inside a longer word, followed by `(`, `<`, `:`, ` `, `=` or the end.
    static func declaredName(_ name: String, in signature: String) -> Range<String.Index>? {
        var search = signature.startIndex
        while let range = signature.range(of: name, range: search..<signature.endIndex) {
            let before = range.lowerBound == signature.startIndex ? " " : signature[signature.index(before: range.lowerBound)]
            let after = range.upperBound == signature.endIndex ? " " : signature[range.upperBound]
            let boundaryBefore = !(before.isLetter || before.isNumber || before == "_" || before == "." || before == "@" || before == "\"")
            let boundaryAfter = "(<:= ?!".contains(after) || range.upperBound == signature.endIndex
            if boundaryBefore && boundaryAfter { return range }
            search = range.upperBound
        }
        return nil
    }

    /// The index just past the balanced parameter clause that starts at or after `from` (generic clause skipped).
    static func parameterClauseEnd(_ signature: String, from: String.Index) -> String.Index? {
        var index = from
        while index < signature.endIndex, signature[index] != "(" {
            if signature[index] == "{" || signature[index] == "=" { return nil }
            index = signature.index(after: index)
        }
        guard index < signature.endIndex else { return nil }
        var depth = 0
        while index < signature.endIndex {
            let character = signature[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return signature.index(after: index) }
            }
            index = signature.index(after: index)
        }
        return nil
    }

    /// The first sentence of a doc comment: backticks dropped, at most 100 characters.
    static func firstSentence(_ doc: String?) -> String? {
        guard var text = doc.map(oneLine), !text.isEmpty else { return nil }
        text.removeAll { $0 == "`" }
        if let end = text.range(of: ". ") ?? text.range(of: ".\n") {
            text = String(text[..<end.lowerBound]) + "."
        }
        if text.count > 100 {
            text = String(text.prefix(99)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }

    /// The doc for a caller heading: its own first sentence, else its type's.
    func doc(for symbol: UsageSymbolInfo) throws -> (text: String, isTypeDoc: Bool)? {
        if let own = Self.firstSentence(symbol.doc) { return (own, false) }
        for parent in try ancestors(of: symbol.id) where parent.kind.isType {
            if let text = Self.firstSentence(parent.doc) { return (text, true) }
            break
        }
        return nil
    }

    /// `POST /api/tokens` for a Next.js route handler (or a declaration inside one).
    func route(for symbol: UsageSymbolInfo, path: String) throws -> String? {
        guard RouteLabel.route(forFile: path) != nil else { return nil }
        var candidates = [symbol]
        candidates += try ancestors(of: symbol.id)
        for candidate in candidates where candidate.depth == 0 {
            if let label = RouteLabel.label(path: path, handler: candidate.name, isDefaultExport: candidate.attributes?.contains("default") == true) {
                return label
            }
        }
        return nil
    }

    // MARK: Totals

    /// Counts per build target when the files span more than one application target, else production
    /// against tests (`app 3, test 0`).
    func split(_ fileIDs: [Int64], counts: [Int64: Int]) -> (split: [UsageCount], byTarget: Bool) {
        var byTarget: [String: Int] = [:]
        var order: [String] = []
        var app = 0, tests = 0
        for id in fileIDs {
            guard let info = files[id] else { continue }
            let count = counts[id] ?? 1
            if info.isTest {
                tests += count
                continue
            }
            app += count
            let label = info.targets.first ?? ""
            if byTarget[label] == nil { order.append(label) }
            byTarget[label, default: 0] += count
        }
        let named = order.filter { !$0.isEmpty }
        if named.count > 1 {
            var split = named.map { UsageCount($0, byTarget[$0] ?? 0) }
            if let other = byTarget[""] { split.append(UsageCount("no target", other)) }
            if tests > 0 { split.append(UsageCount("test", tests)) }
            return (split, true)
        }
        return ([UsageCount("app", app), UsageCount("test", tests)], false)
    }

    // MARK: Completeness

    /// The reconciliation of `name` against `targets`, as the result carries it.
    func completeness(of name: String, targets: Set<Int64>, isMember: Bool) throws -> (UsageCompleteness, Completeness) {
        let check = try engine.completeness(of: name, targets: targets, options: RepositoryEngine.CompletenessOptions(skipCommonNames: isMember))
        return (usageCompleteness(check), check)
    }

    func usageCompleteness(_ check: Completeness) -> UsageCompleteness {
        let unresolved = check.sorted.filter { $0.category.isUnexplained }.map { occurrence in
            UsageOccurrence(path: occurrence.path, line: occurrence.line, category: occurrence.category.rawValue,
                            code: codeLine(occurrence.path, occurrence.line), detail: occurrence.detail)
        }
        let text = check.sorted.filter { [.comment, .doc, .string, .nonSource].contains($0.category) }.map {
            UsageOccurrence(path: $0.path, line: $0.line, category: $0.category.rawValue)
        }
        let dynamic = check.sorted.filter { $0.category == .dynamic }.map {
            UsageOccurrence(path: $0.path, line: $0.line, category: $0.form.rawValue)
        }
        return UsageCompleteness(isComplete: check.isComplete, summary: check.summary, unresolved: unresolved, textOnly: text, dynamic: dynamic,
                                 formsChecked: [Completeness.Form.projected, .keyPath, .stringKey].map { $0.written(check.name) })
    }

    /// One trimmed line of a file (for unresolved sites).
    func codeLine(_ path: String, _ line: Int) -> String? {
        guard let file = engine.sourceText.file(path), let range = file.range(ofLine: line) else { return nil }
        let text = file.codeText(range)
        return text.isEmpty ? nil : Statement.elide(text, to: 100, keeping: nil)
    }
}
