import Foundation
import RepositoryIndex
import SemanticSearch
import VesaliusCore

/// What a feature map reads, cached for one call: files, symbols, reference rows and source statements.
final class FeatureContext {
    let engine: RepositoryEngine
    let db: SQLiteDatabase
    let analysis: QuestionAnalysis
    /// v2 views count a site at the linker's edge threshold.
    let threshold = RepositoryEngine.useThreshold
    private var fileCache: [Int64: FileInfo] = [:]
    private var symbolCache: [Int64: RepositoryEngine.SymbolRow] = [:]
    private var extraCache: [Int64: SymbolExtra] = [:]

    init(engine: RepositoryEngine, analysis: QuestionAnalysis) throws {
        self.engine = engine
        self.db = try engine.db
        self.analysis = analysis
    }

    struct FileInfo: Hashable {
        let id: Int64
        let path: String
        let language: Language
        let isTest: Bool
        /// `unit`, `ui` or `support`, when known.
        let testKind: String?
        let analyzer: String?
    }

    /// Symbol columns the engine's `SymbolRow` leaves out.
    struct SymbolExtra: Hashable {
        let attributes: String?
        let selector: String?
        let declaredType: String?
        let conditions: String?
        let inherits: String?
    }

    /// A reference row as the feature map reads it.
    struct Ref: Hashable {
        let id: Int64
        let fileID: Int64
        let fromSymbol: Int64?
        let name: String
        let kind: String
        let context: String?
        let line: Int
        let column: Int
        let stmt: Int?
        let end: Int?
        let callEnd: Int?
        let receiver: String?
        let receiverRef: Int64?
        let argumentLabels: String?
        let target: Int64?
        let targetFile: Int64?
        let confidence: Double
        let isExternal: Bool
        let externalModule: String?
        let receiverType: String?
        let conditions: String?
        let consumerLine: Int?
        let assignedTo: String?
        let basis: String?

        var isCall: Bool { kind == "call" || kind == "instantiate" }
        var labels: [String]? { argumentLabels.map { $0.isEmpty ? [] : $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) } }
        var isEnvironment: Bool { name.hasPrefix("env:") }
    }

    static let refColumns = """
        r.id, r.file_id, r.from_symbol_id, r.name, r.kind, r.context, r.line, r.col, r.stmt_line, r.end_line, r.call_end_line, \
        r.receiver, r.receiver_ref, r.arg_labels, r.target_symbol_id, r.target_file_id, r.confidence, r.is_external, r.external_module, \
        r.receiver_type, r.conditions, r.consumer_line, r.assigned_to, r.basis
        """

    static func ref(_ row: SQLRow) -> Ref {
        Ref(id: row.int64(0), fileID: row.int64(1), fromSymbol: row.optionalInt64(2), name: row.string(3), kind: row.string(4), context: row.optionalString(5),
            line: row.int(6), column: row.int(7), stmt: row.optionalInt(8), end: row.optionalInt(9), callEnd: row.optionalInt(10),
            receiver: row.optionalString(11), receiverRef: row.optionalInt64(12), argumentLabels: row.optionalString(13),
            target: row.optionalInt64(14), targetFile: row.optionalInt64(15), confidence: row.double(16), isExternal: row.bool(17),
            externalModule: row.optionalString(18), receiverType: row.optionalString(19), conditions: row.optionalString(20),
            consumerLine: row.optionalInt(21), assignedTo: row.optionalString(22), basis: row.optionalString(23))
    }

    func refs(where clause: String, _ values: [any SQLBindable] = []) throws -> [Ref] {
        try db.query("SELECT \(Self.refColumns) FROM refs r WHERE \(clause)", values, cache: false, Self.ref)
    }

    /// Whether the linker records external references (v4 linker); older data needs the fallbacks.
    lazy var hasExternalRows: Bool = ((try? db.scalarInt("SELECT EXISTS(SELECT 1 FROM refs WHERE is_external = 1)")) ?? 0) > 0

    // MARK: Files and symbols

    func file(_ id: Int64) -> FileInfo? {
        if let cached = fileCache[id] { return cached }
        _ = files([id])
        return fileCache[id]
    }

    @discardableResult
    func files(_ ids: [Int64]) -> [Int64: FileInfo] {
        let missing = Array(Set(ids.filter { fileCache[$0] == nil }))
        for chunk in stride(from: 0, to: missing.count, by: 500) {
            let slice = Array(missing[chunk..<min(missing.count, chunk + 500)])
            try? db.forEach("SELECT id, path, language, is_test, test_kind, analyzer FROM files WHERE id IN (\(slice.sqlList))") { row in
                fileCache[row.int64(0)] = FileInfo(id: row.int64(0), path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown,
                                                   isTest: row.bool(3), testKind: row.optionalString(4), analyzer: row.optionalString(5))
            }
        }
        var result: [Int64: FileInfo] = [:]
        for id in ids { if let info = fileCache[id] { result[id] = info } }
        return result
    }

    func fileID(path: String) -> Int64? {
        try? db.queryOne("SELECT id FROM files WHERE path = ?", [path]) { $0.int64(0) }
    }

    func symbol(_ id: Int64) -> RepositoryEngine.SymbolRow? {
        if let cached = symbolCache[id] { return cached }
        _ = symbols([id])
        return symbolCache[id]
    }

    @discardableResult
    func symbols(_ ids: [Int64]) -> [Int64: RepositoryEngine.SymbolRow] {
        let missing = Array(Set(ids.filter { symbolCache[$0] == nil }))
        for chunk in stride(from: 0, to: missing.count, by: 500) {
            let slice = Array(missing[chunk..<min(missing.count, chunk + 500)])
            for row in (try? engine.symbolRows(where: "s.id IN (\(slice.sqlList))", [], limit: 5_000)) ?? [] { symbolCache[row.id] = row }
        }
        var result: [Int64: RepositoryEngine.SymbolRow] = [:]
        for id in ids { if let row = symbolCache[id] { result[id] = row } }
        return result
    }

    func symbolRows(where clause: String, _ values: [any SQLBindable] = [], limit: Int = 5_000) -> [RepositoryEngine.SymbolRow] {
        let rows = (try? engine.symbolRows(where: clause, values, limit: limit)) ?? []
        for row in rows { symbolCache[row.id] = row }
        return rows
    }

    func extra(_ id: Int64) -> SymbolExtra? {
        if let cached = extraCache[id] { return cached }
        _ = extras([id])
        return extraCache[id]
    }

    @discardableResult
    func extras(_ ids: [Int64]) -> [Int64: SymbolExtra] {
        let missing = Array(Set(ids.filter { extraCache[$0] == nil }))
        for chunk in stride(from: 0, to: missing.count, by: 500) {
            let slice = Array(missing[chunk..<min(missing.count, chunk + 500)])
            try? db.forEach("SELECT id, attributes, selector, declared_type, conditions, inherits FROM symbols WHERE id IN (\(slice.sqlList))") { row in
                extraCache[row.int64(0)] = SymbolExtra(attributes: row.optionalString(1), selector: row.optionalString(2), declaredType: row.optionalString(3),
                                                       conditions: row.optionalString(4), inherits: row.optionalString(5))
            }
        }
        var result: [Int64: SymbolExtra] = [:]
        for id in ids { if let value = extraCache[id] { result[id] = value } }
        return result
    }

    /// The declaration's selector (`purchase(planID:)`), or its name with `()` for a function without a stored one.
    func displayName(_ row: RepositoryEngine.SymbolRow, qualified: Bool = false) -> String {
        let base = qualified ? row.qualifiedName : row.name
        guard row.kind.isCallable else { return base }
        if let selector = extra(row.id)?.selector ?? RepositoryEngine.selector(name: row.name, kind: row.kind, signature: row.signature) {
            guard qualified, let dot = row.qualifiedName.lastIndex(of: ".") else { return selector }
            return String(row.qualifiedName[...dot]) + selector
        }
        return base + "()"
    }

    /// The first sentence of a declaration's documentation, at most `limit` characters.
    static func firstSentence(_ doc: String?, limit: Int = 90) -> String? {
        guard let doc = doc?.trimmingCharacters(in: .whitespacesAndNewlines), !doc.isEmpty else { return nil }
        let flat = Statement.collapse(doc.replacingOccurrences(of: "\n", with: " "))
        var sentence = flat
        if let end = flat.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            sentence = String(flat[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return sentence.count > limit ? String(sentence.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : sentence
    }

    // MARK: Source text

    /// The statement at a reference, for `NNN │ code`: at most 3 lines, 110 characters.
    func statement(_ path: String, ref: Ref) -> Statement? {
        engine.sourceText.statement(path, line: ref.line, stmt: ref.stmt, end: ref.end, callEnd: ref.callEnd, name: ref.isEnvironment ? nil : ref.name, column: ref.column)
    }

    func statement(_ path: String, line: Int, name: String? = nil) -> Statement? {
        guard let file = engine.sourceText.file(path), let range = file.range(ofLine: line) else { return nil }
        // A balanced line that ends in a string literal (`static let annualID = "yearly_atlas"`) is a whole
        // statement: bracket balancing alone would read on, taking the `=` before the string for a continuation.
        let raw = file.text(ofLine: line)?.trimmingCharacters(in: .whitespaces) ?? ""
        let balance = file.balance(ofLine: line)
        if balance.net == 0, balance.low >= 0, let last = raw.last, "\"'`".contains(last) {
            return Statement(siteLine: line, start: line, end: line, lines: [Statement.Line(number: line, text: file.codeText(range))], gaps: [],
                             partialStart: false, continues: false, basis: .brackets, name: name, siteOrdinal: 0)
        }
        return engine.sourceText.statement(path, line: line, name: name)
    }

    /// One source line, whitespace collapsed (comments kept out), or nil.
    func codeLine(_ path: String, _ line: Int) -> String? {
        guard let file = engine.sourceText.file(path), let range = file.range(ofLine: line) else { return nil }
        let text = file.codeText(range)
        return text.isEmpty ? nil : text
    }

    /// A compact gist of the code at a site for `·NNN gist`: the line around `name`, at most `limit` characters.
    func gist(_ path: String, line: Int, name: String?, limit: Int = 60) -> String? {
        guard let text = codeLine(path, line) else { return nil }
        var trimmed = text
        // A trailing block opener or closure brace adds nothing to a one-line gist.
        while trimmed.hasSuffix("{") || trimmed.hasSuffix(" in") {
            if trimmed.hasSuffix("{") { trimmed.removeLast() } else { trimmed.removeLast(3) }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        if trimmed.isEmpty { trimmed = text }
        var focus: Range<Int>?
        if let name, let range = trimmed.range(of: name) {
            let lower = trimmed.distance(from: trimmed.startIndex, to: range.lowerBound)
            focus = lower..<(lower + name.count)
        }
        return Statement.elide(trimmed, to: limit, keeping: focus)
    }

    /// The whole text of lines `range` in a file (comments kept), for scanning bodies.
    func lines(_ path: String, _ range: LineRange) -> [(number: Int, text: String)] {
        guard let file = engine.sourceText.file(path) else { return [] }
        var result: [(Int, String)] = []
        for number in range.start...min(range.end, file.lineCount) {
            if let text = file.text(ofLine: number) { result.append((number, text)) }
        }
        return result
    }

    /// The code (comments and strings blanked) of a line, for keyword tests.
    func codeOnly(_ path: String, _ line: Int) -> String? {
        guard let file = engine.sourceText.file(path), let range = file.range(ofLine: line) else { return nil }
        let regions = file.regions
        var bytes: [UInt8] = []
        for index in range {
            bytes.append(regions[index] == CodeLexer.Region.code.rawValue ? file.bytes[index] : 32)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private var bindingCache: [Int64: Set<String>] = [:]

    /// Names a script file imports from external packages (`safeStorage`, `fs`, `randomBytes`): calls through them
    /// are library calls.
    func externalBindings(_ fileID: Int64) -> Set<String> {
        if let cached = bindingCache[fileID] { return cached }
        var names = Set<String>()
        guard let info = file(fileID), [.typescript, .javascript, .python].contains(info.language) else {
            bindingCache[fileID] = names
            return names
        }
        try? db.forEach("SELECT names FROM imports WHERE file_id = ? AND external_name IS NOT NULL AND is_mock = 0", [fileID]) { row in
            for name in ImportNamesCodec.decode(row.optionalString(0)) { names.insert(name.alias ?? name.name) }
        }
        bindingCache[fileID] = names
        return names
    }

    // MARK: Matching question terms

    /// How well identifier words match weighted terms: each word counts its best term (exact, stem or lemma).
    static func match(_ words: [String], terms: [String: Double]) -> Double {
        var total = 0.0
        var seen = Set<String>()
        for word in words {
            let lower = word.lowercased()
            guard lower.count >= 2, seen.insert(lower).inserted else { continue }
            let stem = Tokenizer.stem(lower)
            let lemma = QuestionAnalyzer.lemma(lower)
            total += max(terms[lower] ?? 0, terms[stem] ?? 0, terms[lemma] ?? 0)
        }
        return total
    }

    /// Words of a declaration or call name: split, plus the whole name lowercased.
    static func words(_ name: String) -> [String] {
        let parts = Tokenizer.splitIdentifier(name)
        return parts.count > 1 ? parts + [parts.joined()] : parts
    }
}
