import Foundation
import LanguageAnalysis
import RepositoryIndex
import VesaliusCore

/// Every occurrence of a name in the indexed text, reconciled with the reference table.
///
/// A result may say `complete` only when each occurrence is explained: a use resolved to the target, a use
/// resolved to another declaration (named), a rejected lookalike, an external use, a declaration, an import, an
/// argument label or key, a comment, a string, a dynamic form, a local variable, other-language or non-source
/// text. Unresolved rows, occurrences with no row, names an analyzer never records, and code in lexically
/// analysed files that could name the target rule it out, as do a capped scan, a common member name left
/// unchecked, a target that is itself analysed lexically, and files edited since they were indexed.
struct Completeness: Sendable {
    enum Category: String, CaseIterable, Sendable {
        /// A reference resolved to the target at or above the use threshold.
        case target
        /// A reference resolved to another declaration (`detail` = its exact target string).
        case other
        /// A same-name lookalike the linker rejected for the target (`detail` = the receiver's type).
        case rejected
        /// A reference resolved outside the repository (`detail` = the module).
        case external
        case declaration
        case otherDeclaration = "other declaration"
        case importName = "import"
        /// An argument label, parameter name or object key.
        case label
        case comment
        case doc
        case string
        /// `$name`, `\.name`, `#selector(name)` or `"name"` (see `Form`).
        case dynamic
        /// A local variable or parameter with the same name.
        case local
        /// Documentation, configuration and other text that is not source code.
        case nonSource = "non-source"
        /// Code in a language that cannot name the target (a shell script for a Swift type).
        case otherLanguage = "other language"
        /// Code in a lexically analysed file that could name the target: not verifiable.
        case lexical
        /// A reference row with no target, or below the use threshold.
        case unresolved
        /// An occurrence in parsed code with no reference row.
        case unrecorded
        /// An occurrence of a name the analyzer never records (`AnalyzerStopLists`).
        case untracked

        /// Occurrences the index cannot account for; any of them rules out `complete`.
        var isUnexplained: Bool {
            switch self {
            case .unresolved, .unrecorded, .untracked, .lexical: true
            default: false
            }
        }
    }

    enum Form: String, Sendable {
        case plain
        /// `$name`: a property wrapper's projected value.
        case projected
        /// `\.name`, `\Type.name`, `#keyPath(name)`.
        case keyPath = "keypath"
        /// `#selector(name)`.
        case selector
        /// A string literal that is exactly the name (`"name"`), as used by KVC, `@AppStorage` or reflection.
        case stringKey = "string"

        /// How the form is written for `name`: `$isSubscribed`, `\.isSubscribed`, `#selector(isSubscribed)`.
        func written(_ name: String) -> String {
            switch self {
            case .plain: name
            case .projected: "$" + name
            case .keyPath: "\\." + name
            case .selector: "#selector(\(name))"
            case .stringKey: "\"\(name)\""
            }
        }
    }

    struct Occurrence: Sendable, Hashable {
        let path: String
        let line: Int
        /// 1-based UTF-8 byte column.
        let column: Int
        var category: Category
        var form: Form = .plain
        /// The other declaration's exact target string, the external module, a rejected lookalike's type, or
        /// why a site is unresolved or unrecorded.
        var detail: String?
        var symbolID: Int64?
        var referenceID: Int64?
    }

    let name: String
    var occurrences: [Occurrence] = []
    /// Files that may contain the name (full-text hits ∪ files with reference rows ∪ declaring files).
    var candidateFiles = 0
    var scannedFiles = 0
    /// Files edited (or deleted) since they were indexed: their rows may no longer line up with their text.
    var staleFiles: [String] = []
    /// Indexed files whose words include the name, and all indexed files (the "not checked by name" rule).
    var documentFrequency = 0
    var indexedFiles = 0
    var notCheckedByName = false
    /// The scan stopped at its file or time cap.
    var capped = false
    /// The target is declared in a lexically analysed file, whose uses the index cannot verify.
    var targetIsLexical = false
    /// Reference rows of the name whose line no longer shows it (a sign of a stale file).
    var unmatchedRows = 0
    var elapsed: TimeInterval = 0

    var isComplete: Bool {
        !notCheckedByName && !capped && !targetIsLexical && staleFiles.isEmpty && !occurrences.contains { $0.category.isUnexplained }
    }

    func count(_ categories: Category...) -> Int {
        occurrences.reduce(0) { $0 + (categories.contains($1.category) ? 1 : 0) }
    }

    func occurrences(_ categories: Category...) -> [Occurrence] {
        occurrences.filter { categories.contains($0.category) }
    }

    /// Sorted for reading: by path, then line and column.
    var sorted: [Occurrence] {
        occurrences.sorted { ($0.path, $0.line, $0.column) < ($1.path, $1.line, $1.column) }
    }

    // MARK: The completeness line

    /// `complete: "importBook" occurs 9×: 3 resolved to the target, 1 declaration, 2 comments (…), 3 non-source
    /// (Documentation/*.md); 0 unresolved`, or `INCOMPLETE: …` with what is unexplained and why.
    var summary: String {
        if notCheckedByName {
            return "INCOMPLETE: \"\(name)\" not checked by name: it is in \(documentFrequency) of \(indexedFiles) indexed files"
        }
        var parts: [String] = []
        func add(_ count: Int, _ singular: String, _ plural: String, _ detail: String? = nil) {
            guard count > 0 else { return }
            parts.append("\(count) \(count == 1 ? singular : plural)" + (detail.map { " (\($0))" } ?? ""))
        }
        add(count(.target), "resolved to the target", "resolved to the target")
        let others = Dictionary(grouping: occurrences(.other), by: { $0.detail ?? "another declaration" })
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
        for (target, sites) in others.prefix(3) { add(sites.count, "resolved to \(target)", "resolved to \(target)") }
        if others.count > 3 {
            add(others.dropFirst(3).reduce(0) { $0 + $1.value.count }, "resolved to other declarations", "resolved to other declarations")
        }
        add(count(.rejected), "rejected lookalike", "rejected lookalikes", Self.locations(occurrences(.rejected), withDetail: true))
        add(count(.external), "external", "external", Set(occurrences(.external).compactMap(\.detail)).sorted().prefix(3).joined(separator: ", ").nonEmpty)
        add(count(.declaration), "declaration", "declarations")
        add(count(.otherDeclaration), "other declaration", "other declarations", Set(occurrences(.otherDeclaration).compactMap(\.detail)).sorted().prefix(3).joined(separator: ", ").nonEmpty)
        add(count(.importName), "import", "imports")
        add(count(.label), "argument label or key", "argument labels or keys")
        add(count(.comment, .doc), "comment", "comments", Self.locations(occurrences(.comment, .doc)))
        add(count(.string), "string", "strings", Self.locations(occurrences(.string)))
        add(count(.dynamic), "dynamic form", "dynamic forms", Self.forms(occurrences(.dynamic), name: name))
        add(count(.local), "local variable of the same name", "local variables of the same name")
        add(count(.nonSource), "non-source", "non-source", Self.glob(occurrences(.nonSource).map(\.path)))
        add(count(.otherLanguage), "in another language", "in other languages", Self.glob(occurrences(.otherLanguage).map(\.path)))
        add(count(.lexical), "in a lexically analysed file", "in lexically analysed files", Self.locations(occurrences(.lexical)))
        add(count(.untracked), "not tracked by name", "not tracked by name", Self.locations(occurrences(.untracked)))
        add(count(.unrecorded), "unrecorded", "unrecorded", Self.locations(occurrences(.unrecorded)))
        let unresolved = count(.unresolved)
        var reasons: [String] = ["\(unresolved) unresolved" + (unresolved > 0 ? " (\(Self.locations(occurrences(.unresolved)) ?? ""))" : "")]
        if capped { reasons.append("scanned \(scannedFiles) of \(candidateFiles) files") }
        if targetIsLexical { reasons.append("the target is analysed lexically") }
        if !staleFiles.isEmpty { reasons.append("\(staleFiles.count) \(staleFiles.count == 1 ? "file" : "files") changed since indexing (\(Self.glob(staleFiles) ?? ""))") }
        let head = "\(isComplete ? "complete" : "INCOMPLETE"): \"\(name)\" occurs \(occurrences.count)×"
        return head + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", ")) + "; " + reasons.joined(separator: "; ")
    }

    /// `File.swift:12,40, Other.swift:7` (first 4 files, then `+N files`). Files are named by their file name,
    /// or by as many trailing path components as it takes to tell two apart (`App/Settings.swift`).
    static func locations(_ occurrences: [Occurrence], withDetail: Bool = false, limit: Int = 4) -> String? {
        guard !occurrences.isEmpty else { return nil }
        var order: [String] = []
        var lines: [String: [String]] = [:]
        for occurrence in occurrences.sorted(by: { ($0.path, $0.line) < ($1.path, $1.line) }) {
            if lines[occurrence.path] == nil { order.append(occurrence.path) }
            let detail = withDetail ? occurrence.detail.map { " (\($0))" } ?? "" : ""
            lines[occurrence.path, default: []].append("\(occurrence.line)\(detail)")
        }
        let names = shortNames(order)
        let shown = order.prefix(limit).map { path in
            "\(names[path] ?? path):\(lines[path, default: []].joined(separator: ","))"
        }
        return (shown + (order.count > limit ? ["+\(order.count - limit) files"] : [])).joined(separator: ", ")
    }

    /// The shortest trailing part of each path that no other path in `paths` ends with.
    static func shortNames(_ paths: [String]) -> [String: String] {
        let split = paths.map { $0.split(separator: "/").map(String.init) }
        var names: [String: String] = [:]
        for (index, components) in split.enumerated() {
            var length = 1
            while length < components.count {
                let suffix = components.suffix(length)
                if !split.enumerated().contains(where: { $0.offset != index && $0.element.suffix(length) == suffix }) { break }
                length += 1
            }
            names[paths[index]] = components.suffix(length).joined(separator: "/")
        }
        return names
    }

    /// `$isSubscribed ×1, \.isSubscribed ×2` for dynamic forms.
    static func forms(_ occurrences: [Occurrence], name: String) -> String? {
        let counts = Dictionary(grouping: occurrences, by: \.form).mapValues(\.count)
        guard !counts.isEmpty else { return nil }
        return counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.written(name)) ×\($0.value)" }.joined(separator: ", ")
    }

    /// A short description of a set of paths: `Documentation/*.md`, `docs/**/*.md`, or the first file names.
    static func glob(_ paths: [String]) -> String? {
        let unique = Array(Set(paths)).sorted()
        guard let first = unique.first else { return nil }
        if unique.count == 1 { return first }
        let directories = unique.map { ($0 as NSString).deletingLastPathComponent.split(separator: "/").map(String.init) }
        var common = directories[0]
        for components in directories.dropFirst() {
            var shared = 0
            while shared < min(common.count, components.count), common[shared] == components[shared] { shared += 1 }
            common = Array(common.prefix(shared))
        }
        let extensions = Set(unique.map { ($0 as NSString).pathExtension })
        let name = extensions.count == 1 && !(extensions.first ?? "").isEmpty ? "*.\(extensions.first!)" : "*"
        if common.isEmpty {
            let names = unique.prefix(3).map { ($0 as NSString).lastPathComponent }
            return names.joined(separator: ", ") + (unique.count > 3 ? ", +\(unique.count - 3)" : "")
        }
        let nested = directories.contains { $0.count > common.count }
        return common.joined(separator: "/") + (nested ? "/**/" : "/") + name
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Engine

extension RepositoryEngine {
    struct CompletenessOptions: Sendable {
        var threshold = RepositoryEngine.useThreshold
        var maxFiles = 300
        var timeBudget: TimeInterval = 0.3
        /// Leave a member name unchecked when it is in more than max(10, 5% of) the indexed files' text (common
        /// names such as `length` and `sequence`): scanning it would only list unrelated uses.
        var skipCommonNames = false
    }

    /// Reconciles every whole-identifier occurrence of `name` in the indexed files with the reference rows and
    /// declarations of that name. `targets` are the symbol ids that count as the target.
    func completeness(of name: String, targets: Set<Int64>, options: CompletenessOptions = CompletenessOptions()) throws -> Completeness {
        let started = DispatchTime.now()
        var result = Completeness(name: name)
        let nameBytes = Array(name.utf8)
        guard !nameBytes.isEmpty, !name.contains(where: { $0.isWhitespace }) else { return result }
        let db = try db

        // The languages that can name the target decide which files may hold real uses. A Swift declaration is
        // visible to C and Objective-C only when exported to them (`@objc`, `@_cdecl`, an `NSObject` subclass).
        var namingLanguages = Set<Language>()
        if !targets.isEmpty {
            try db.forEach("""
                SELECT f.language, f.analyzer, COALESCE(s.attributes, '') || ' ' || COALESCE(s.inherits, '') || ' ' ||
                       COALESCE(p.attributes, '') || ' ' || COALESCE(p.inherits, '')
                FROM symbols s JOIN files f ON f.id = s.file_id LEFT JOIN symbols p ON p.id = s.parent_id
                WHERE s.id IN (\(Array(targets).sqlList))
                """) { row in
                let language = Language(rawValue: row.string(0)) ?? .unknown
                let traits = row.string(2)
                let exported = traits.contains("@objc") || traits.contains("@_cdecl") || traits.contains("NSObject")
                namingLanguages.formUnion(Self.languages(thatCanName: language, exportedToC: exported))
                if row.optionalString(1) == "lexical" { result.targetIsLexical = true }
            }
        }

        let phrase = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        if options.skipCommonNames {
            result.indexedFiles = try db.scalarInt("SELECT COUNT(*) FROM files")
            result.documentFrequency = (try? db.scalarInt("SELECT COUNT(*) FROM fts_files WHERE fts_files MATCH ?", ["body : " + phrase])) ?? 0
            if result.documentFrequency > max(10, result.indexedFiles / 20) {
                result.notCheckedByName = true
                result.elapsed = Self.seconds(since: started)
                return result
            }
        }

        // Candidates: full-text hits, files with reference rows of the name, and declaring files.
        var candidateIDs = Set((try? db.query("SELECT rowid FROM fts_files WHERE fts_files MATCH ?", ["{symbols docs body} : " + phrase], cache: false) { $0.int64(0) }) ?? [])
        var rowsByFile: [Int64: [NameRow]] = [:]
        try db.forEach("""
            SELECT id, file_id, line, col, target_symbol_id, confidence, basis, is_external, external_module, receiver_type, alt_symbol_id
            FROM refs WHERE name = ?
            """, [name]) { row in
            rowsByFile[row.int64(1), default: []].append(NameRow(
                id: row.int64(0), line: row.int(2), column: row.int(3), target: row.optionalInt64(4), confidence: row.double(5),
                basis: row.optionalString(6), isExternal: row.bool(7), externalModule: row.optionalString(8), receiverType: row.optionalString(9),
                alt: row.optionalInt64(10)))
        }
        var declarationsByFile: [Int64: [NameDeclaration]] = [:]
        try db.forEach("SELECT id, file_id, start_line, end_line FROM symbols WHERE name = ? ORDER BY start_line", [name]) { row in
            declarationsByFile[row.int64(1), default: []].append(NameDeclaration(id: row.int64(0), start: row.int(2), end: row.int(3)))
        }
        candidateIDs.formUnion(rowsByFile.keys)
        candidateIDs.formUnion(declarationsByFile.keys)
        var files: [CandidateFile] = []
        let ids = Array(candidateIDs)
        for chunk in stride(from: 0, to: ids.count, by: 500) {
            let slice = Array(ids[chunk..<min(ids.count, chunk + 500)])
            try db.forEach("SELECT id, path, language, analyzer, parse_status, size, mtime FROM files WHERE id IN (\(slice.sqlList))") { row in
                files.append(CandidateFile(
                    id: row.int64(0), path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown,
                    analyzer: row.optionalString(3), parseStatus: row.string(4), stamp: SourceText.Stamp(size: row.int(5), modified: row.double(6))))
            }
        }
        // Files the index connects to the name come first, so a capped scan still covers them.
        files.sort { a, b in
            let ra = rowsByFile[a.id] != nil || declarationsByFile[a.id] != nil, rb = rowsByFile[b.id] != nil || declarationsByFile[b.id] != nil
            return ra != rb ? ra : a.path < b.path
        }
        result.candidateFiles = files.count

        let scanStarted = DispatchTime.now()
        for file in files {
            if result.scannedFiles >= options.maxFiles || Self.seconds(since: scanStarted) > options.timeBudget {
                result.capped = true
                break
            }
            result.scannedFiles += 1
            guard let source = sourceText.file(file.path) else {
                result.staleFiles.append(file.path)
                continue
            }
            if source.stamp != file.stamp { result.staleFiles.append(file.path) }
            let offsets = source.occurrences(of: nameBytes)
            let rows = rowsByFile[file.id] ?? []
            guard !offsets.isEmpty else {
                result.unmatchedRows += rows.count
                continue
            }
            var scan = FileScan(engine: self, file: file, source: source, name: name, targets: targets, threshold: options.threshold, mode: Self.scanMode(file, namingLanguages: namingLanguages))
            let classified = try scan.classify(offsets: offsets, rows: rows, declarations: declarationsByFile[file.id] ?? [])
            result.occurrences += classified.occurrences
            result.unmatchedRows += classified.unmatchedRows
        }
        try describeOtherTargets(in: &result)
        result.elapsed = Self.seconds(since: started)
        return result
    }

    static func seconds(since start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Languages whose code can name a declaration written in `language`: Swift sees C and Objective-C, which see
    /// Swift only through what it exports to them.
    static func languages(thatCanName language: Language, exportedToC: Bool = false) -> Set<Language> {
        switch language {
        case .swift: exportedToC ? [.swift, .objectiveC, .c, .cpp] : [.swift]
        case .objectiveC, .c, .cpp: [.swift, .objectiveC, .c, .cpp]
        case .typescript, .javascript: [.typescript, .javascript]
        default: [language]
        }
    }

    fileprivate static func scanMode(_ file: CandidateFile, namingLanguages: Set<Language>) -> FileScan.Mode {
        guard file.language.isCode, file.analyzer != nil, file.parseStatus != "skipped", file.parseStatus != "binary" else { return .nonSource }
        if !namingLanguages.isEmpty, !namingLanguages.contains(file.language) { return .otherLanguage }
        if file.analyzer == "lexical" { return .lexical }
        return file.parseStatus == "failed" ? .unparsed : .full
    }

    /// Exact target strings for the other declarations occurrences resolved to.
    private func describeOtherTargets(in result: inout Completeness) throws {
        let ids = Set(result.occurrences.filter { $0.category == .other || $0.category == .otherDeclaration || ($0.category == .unresolved && $0.symbolID != nil) }.compactMap(\.symbolID))
        guard !ids.isEmpty else { return }
        let rows = try symbolRows(where: "s.id IN (\(Array(ids).sqlList))", [], limit: ids.count)
        var names: [Int64: String] = [:]
        for group in try groupDeclarations(rows) {
            let target = try exactTarget(for: group)
            for id in group.ids { names[id] = target }
        }
        for index in result.occurrences.indices {
            guard let id = result.occurrences[index].symbolID, let target = names[id] else { continue }
            switch result.occurrences[index].category {
            case .other, .otherDeclaration: result.occurrences[index].detail = target
            case .unresolved: result.occurrences[index].detail = "guessed \(target) below the use threshold"
            default: break
            }
        }
    }
}

// MARK: - Classification

fileprivate struct CandidateFile {
    let id: Int64
    let path: String
    let language: Language
    let analyzer: String?
    let parseStatus: String
    let stamp: SourceText.Stamp
}

fileprivate struct NameRow {
    let id: Int64
    let line: Int
    let column: Int
    let target: Int64?
    let confidence: Double
    let basis: String?
    let isExternal: Bool
    let externalModule: String?
    let receiverType: String?
    let alt: Int64?

    /// Resolved to something that is not a repository declaration: a framework or package member, an
    /// environment variable or a tuple element. (`refs.resolved` only says the linker has processed a row.)
    func isResolvedOutside(threshold: Double) -> Bool {
        isExternal || basis == ResolutionBasis.env.rawValue || receiverType == "(tuple)" || (target == nil && confidence >= threshold)
    }
}

fileprivate struct NameDeclaration {
    let id: Int64
    let start: Int
    let end: Int
}

/// Classifies the occurrences of a name in one file.
fileprivate struct FileScan {
    enum Mode {
        /// Parsed by a syntax analyzer: occurrences are matched with reference rows.
        case full
        /// A syntax analyzer failed on it: code occurrences are unrecorded.
        case unparsed
        /// Analysed lexically and able to name the target: code occurrences cannot be verified.
        case lexical
        case otherLanguage
        case nonSource
    }

    let engine: RepositoryEngine
    let file: CandidateFile
    let source: SourceText.File
    let name: String
    let targets: Set<Int64>
    let threshold: Double
    let mode: Mode
    private var importRanges: [ClosedRange<Int>]?
    private var callableRanges: [ClosedRange<Int>]?
    private var targetDeclarations = Set<Int>()

    init(engine: RepositoryEngine, file: CandidateFile, source: SourceText.File, name: String, targets: Set<Int64>, threshold: Double, mode: Mode) {
        self.engine = engine
        self.file = file
        self.source = source
        self.name = name
        self.targets = targets
        self.threshold = threshold
        self.mode = mode
    }

    private var bytes: [UInt8] { source.bytes }
    private var length: Int { name.utf8.count }

    private func byte(_ index: Int) -> UInt8 {
        index >= 0 && index < source.bytes.count ? source.bytes[index] : 0
    }

    private struct Pending {
        let offset: Int
        let line: Int
        let column: Int
        let region: UInt8
        var rows: [NameRow] = []
        var occurrence: Completeness.Occurrence
    }

    mutating func classify(offsets: [Int], rows: [NameRow], declarations: [NameDeclaration]) throws -> (occurrences: [Completeness.Occurrence], unmatchedRows: Int) {
        let simple: Completeness.Category? = switch mode {
        case .nonSource: .nonSource
        case .otherLanguage: .otherLanguage
        default: nil
        }
        if let simple {
            return (offsets.map { offset in
                let line = source.line(atOffset: offset)
                return Completeness.Occurrence(path: file.path, line: line, column: offset - source.lineStarts[line - 1] + 1, category: simple)
            }, 0)
        }

        let regions = source.regions
        let code = CodeLexer.Region.code.rawValue
        var pending = offsets.map { offset -> Pending in
            let line = source.line(atOffset: offset)
            let column = offset - source.lineStarts[line - 1] + 1
            var occurrence = Completeness.Occurrence(path: file.path, line: line, column: column, category: .unrecorded)
            if source.dialect == .swift, regions[offset] == code { occurrence.form = swiftForm(offset, line: line) }
            return Pending(offset: offset, line: line, column: column, region: regions[offset], occurrence: occurrence)
        }

        // 1. Reference rows, by line: the row at the occurrence's column (1-based; 0-based for tree-sitter;
        //    `$name` rows start at the `$`), then the remaining rows in order with code occurrences left over.
        var unmatched = 0
        if mode == .full {
            let indicesByLine = Dictionary(grouping: pending.indices, by: { pending[$0].line })
            for (line, lineRows) in Dictionary(grouping: rows, by: \.line) {
                guard let indices = indicesByLine[line] else {
                    unmatched += lineRows.count
                    continue
                }
                var leftover: [NameRow] = []
                for row in lineRows.sorted(by: { $0.column < $1.column }) {
                    if let index = indices.first(where: { pending[$0].column == row.column || pending[$0].column - 1 == row.column }) {
                        pending[index].rows.append(row)
                    } else {
                        leftover.append(row)
                    }
                }
                let free = indices.filter { pending[$0].rows.isEmpty && pending[$0].region == code }
                for (row, index) in zip(leftover, free) { pending[index].rows.append(row) }
                unmatched += max(0, leftover.count - free.count)
            }
            for index in pending.indices where !pending[index].rows.isEmpty {
                categorize(&pending[index].occurrence, rows: pending[index].rows)
            }
        }

        // 2. Declarations: in each declaration's head (attributes included), the code occurrence after a
        //    declaration keyword is its name (`var scenePhase`, not the attribute's `\.scenePhase` before it),
        //    else the first occurrence no row explains (`case a, isOpen`). A row can explain the name itself
        //    (`extension Book` is a use of `Book`); then the declaration adds nothing.
        var explained = Set(pending.indices.filter { !pending[$0].rows.isEmpty })
        var claimed = Set<Int>()
        for declaration in declarations {
            let headEnd = min(declaration.end, declaration.start + 12)
            let head = pending.indices.filter {
                !claimed.contains($0) && pending[$0].region == code && pending[$0].line >= declaration.start && pending[$0].line <= headEnd
            }
            guard let index = head.first(where: { Self.declarationKeywords.contains(previousWord(pending[$0].offset)) })
                ?? head.first(where: { !explained.contains($0) }) ?? head.first else { continue }
            claimed.insert(index)
            guard !explained.contains(index) else { continue }
            explained.insert(index)
            pending[index].occurrence.category = targets.contains(declaration.id) ? .declaration : .otherDeclaration
            pending[index].occurrence.symbolID = declaration.id
        }

        // 3. Everything else, from its text. A local binding that is the target's own declaration (a nested
        //    function the analyzer does not record calls to) explains nothing away. The Swift analyzer leaves
        //    out only unqualified uses of its stop-listed names; member uses (`x.count`, `.max`) are recorded.
        targetDeclarations = Set(pending.filter { $0.occurrence.category == .declaration }.map(\.offset))
        let stopListed = AnalyzerStopLists.untrackedNames(language: file.language).contains(name)
        func untracked(_ offset: Int) -> Bool {
            stopListed && !(source.dialect == .swift && previousCode(offset) == 46)
        }
        for index in pending.indices where !explained.contains(index) {
            let offset = pending[index].offset
            var occurrence = pending[index].occurrence
            switch CodeLexer.Region(rawValue: pending[index].region) ?? .code {
            case .comment: occurrence.category = .comment
            case .doc: occurrence.category = .doc
            case .nonSource: occurrence.category = .nonSource
            case .string:
                if isExactString(offset) {
                    occurrence.category = .dynamic
                    occurrence.form = .stringKey
                } else {
                    occurrence.category = .string
                }
            case .code:
                if mode == .lexical {
                    occurrence.category = .lexical
                    occurrence.detail = "\(file.language.displayName), analysed lexically"
                } else if mode == .unparsed {
                    occurrence.category = .unrecorded
                    occurrence.detail = "the file did not parse"
                } else if occurrence.form != .plain {
                    occurrence.category = .dynamic
                } else if try inImportStatement(line: pending[index].line) {
                    occurrence.category = .importName
                } else if isLabel(offset) {
                    occurrence.category = .label
                } else if try isLocal(offset, line: pending[index].line, earlier: offsets) {
                    occurrence.category = .local
                } else if untracked(offset) {
                    occurrence.category = .untracked
                    occurrence.detail = "the \(file.language.displayName) analyzer does not record \"\(name)\""
                } else {
                    occurrence.category = .unrecorded
                    occurrence.detail = unrecordedReason(offset)
                }
            }
            pending[index].occurrence = occurrence
        }
        return (pending.map(\.occurrence), unmatched)
    }

    /// The best explanation among the rows at one occurrence.
    private func categorize(_ occurrence: inout Completeness.Occurrence, rows: [NameRow]) {
        if let row = rows.first(where: { $0.target.map(targets.contains) == true && $0.confidence >= threshold }) {
            occurrence.category = .target
            occurrence.symbolID = row.target
            occurrence.referenceID = row.id
        } else if let row = rows.first(where: { $0.alt.map(targets.contains) == true && ($0.isResolvedOutside(threshold: threshold) || ($0.target != nil && $0.confidence >= threshold)) }) {
            occurrence.category = .rejected
            occurrence.detail = row.receiverType ?? row.externalModule
            occurrence.symbolID = row.target
            occurrence.referenceID = row.id
        } else if let row = rows.first(where: { $0.target != nil && $0.confidence >= threshold }) {
            occurrence.category = .other
            occurrence.symbolID = row.target
            occurrence.referenceID = row.id
        } else if let row = rows.first(where: { $0.isResolvedOutside(threshold: threshold) }) {
            occurrence.category = .external
            occurrence.detail = row.externalModule ?? row.receiverType
            occurrence.referenceID = row.id
        } else {
            let row = rows[0]
            occurrence.category = .unresolved
            occurrence.symbolID = row.target
            occurrence.referenceID = row.id
            occurrence.detail = row.target == nil ? "no declaration found" : "below the use threshold"
        }
    }

    // MARK: Text checks

    /// `$name`, a key path component, or a name inside `#selector(…)` / `#keyPath(…)`.
    private func swiftForm(_ offset: Int, line: Int) -> Completeness.Form {
        let previous = byte(offset - 1)
        if previous == 36 { return .projected } // $
        if previous == 46 { // .
            var cursor = offset - 2
            while cursor >= 0, CodeLexer.isIdentifierByte(bytes[cursor]) || bytes[cursor] == 46 || bytes[cursor] == 63 || bytes[cursor] == 33 { cursor -= 1 }
            if byte(cursor) == 92 { return .keyPath } // \
        }
        let lineStart = source.lineStarts[line - 1]
        let prefix = String(decoding: bytes[lineStart..<offset], as: UTF8.self)
        for (marker, form) in [("#selector(", Completeness.Form.selector), ("#keyPath(", .keyPath)] {
            guard let range = prefix.range(of: marker, options: .backwards) else { continue }
            var depth = 1
            for character in prefix[range.upperBound...] {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
            }
            if depth > 0 { return form }
        }
        return .plain
    }

    /// A string literal that is exactly the name: its quotes are the literal's own delimiters (`"name"`,
    /// `'name'`, `#"name"#`), not quotes inside a longer literal (`"{\"title\":\"name\"}"`).
    private func isExactString(_ offset: Int) -> Bool {
        let before = byte(offset - 1), after = byte(offset + length)
        guard (before == 34 || before == 39 || before == 96) && before == after else { return false }
        let regions = source.regions
        func delimits(_ index: Int, step: Int) -> Bool {
            var index = index
            while index >= 0, index < bytes.count, bytes[index] == 35 { index += step } // raw-string `#`
            return index < 0 || index >= bytes.count || regions[index] != CodeLexer.Region.string.rawValue
        }
        return delimits(offset - 2, step: -1) && delimits(offset + length + 1, step: 1)
    }

    /// An argument label, parameter name or object key: `(name:` / `, name:` (`(label name:` in Swift),
    /// `{ name:` and `name?:` in TypeScript, `name=` keyword arguments in Python.
    func isLabel(_ offset: Int) -> Bool {
        var after = offset + length
        while after < bytes.count, bytes[after] == 32 || bytes[after] == 9 { after += 1 }
        let next = byte(after), nextNext = byte(after + 1)
        let dialect = source.dialect
        var colon = (next == 58 && nextNext != 58) || (dialect.isScript && next == 63 && nextNext == 58)
        // A Swift external label in a declaration: `outcome o: Type`, `from url: URL`.
        if dialect == .swift, !colon, after > offset + length, CodeLexer.isIdentifierByte(next) {
            var cursor = after
            while cursor < bytes.count, CodeLexer.isIdentifierByte(bytes[cursor]) { cursor += 1 }
            while cursor < bytes.count, bytes[cursor] == 32 || bytes[cursor] == 9 { cursor += 1 }
            colon = byte(cursor) == 58 && byte(cursor + 1) != 58
        }
        let keyword = dialect == .python && next == 61 && nextNext != 61
        // A JSX attribute: `name={…}` or `name="…"` right after a blank, inside a tag.
        if dialect.isScript, after == offset + length, next == 61, nextNext == 123 || nextNext == 34 || nextNext == 39,
           byte(offset - 1) == 32 || byte(offset - 1) == 9 || byte(offset - 1) == 10 {
            return true
        }
        guard colon || keyword else { return false }
        let regions = source.regions
        var before = offset - 1
        func skipBlanks() {
            while before >= 0 {
                let byte = bytes[before]
                let region = regions[before]
                if byte == 32 || byte == 9 || byte == 10 || byte == 13 || region == CodeLexer.Region.comment.rawValue || region == CodeLexer.Region.doc.rawValue {
                    before -= 1
                } else {
                    break
                }
            }
        }
        skipBlanks()
        var previous = byte(before)
        if dialect == .swift, CodeLexer.isIdentifierByte(previous) {
            // `(label name:` and `(_ name:`: step over the argument label, but not over `let`/`var`.
            var start = before
            while start >= 0, CodeLexer.isIdentifierByte(bytes[start]) { start -= 1 }
            let word = String(decoding: bytes[(start + 1)...before], as: UTF8.self)
            guard !Self.swiftKeywords.contains(word) else { return false }
            before = start
            skipBlanks()
            previous = byte(before)
        }
        switch dialect {
        case .script, .jsx, .cFamily: return previous == 40 || previous == 44 || previous == 123 || previous == 59
        default: return previous == 40 || previous == 44
        }
    }

    private static let swiftKeywords: Set<String> = ["let", "var", "case", "if", "guard", "while", "for", "return", "in", "else", "try", "await", "inout", "throw", "is", "as"]

    /// Words that directly precede a declared name: Swift, TypeScript/JavaScript (with member modifiers) and Python.
    static let declarationKeywords: Set<String> = [
        "func", "var", "let", "class", "struct", "enum", "protocol", "actor", "extension", "typealias", "case",
        "associatedtype", "macro", "function", "const", "interface", "type", "namespace", "module", "def",
        "async", "static", "get", "set", "readonly", "abstract", "override", "declare", "public", "private", "protected",
    ]

    /// Inside an import (or a TypeScript `export { … }` list) of this file.
    private mutating func inImportStatement(line: Int) throws -> Bool {
        if importRanges == nil {
            var ranges: [ClosedRange<Int>] = []
            // `vi.mock(…)` rows are not import statements: keys in their factories are keys.
            try engine.db.forEach("SELECT line, end_line FROM imports WHERE file_id = ? AND is_mock = 0", [file.id]) { row in
                let start = row.int(0)
                let end = row.optionalInt(1) ?? source.balancedEnd(from: start)
                ranges.append(start...max(start, end))
            }
            if source.dialect.isScript {
                for number in 1...max(1, source.lineCount) {
                    guard let range = source.range(ofLine: number) else { continue }
                    let text = source.codeText(range)
                    if text.hasPrefix("export {") || text.hasPrefix("export type {") || text.hasPrefix("export *") {
                        ranges.append(number...max(number, source.balancedEnd(from: number)))
                    }
                }
            }
            importRanges = ranges
        }
        return importRanges?.contains { $0.contains(line) } ?? false
    }

    /// A local variable or parameter of the same name: the occurrence declares one (`let name`, `for name in`,
    /// a closure parameter, a Python assignment), or one is declared earlier in the enclosing function. Member
    /// accesses (`x.name`) are never locals.
    private mutating func isLocal(_ offset: Int, line: Int, earlier: [Int]) throws -> Bool {
        if previousCode(offset) == 46 { return false } // .
        if isBinding(offset) { return true }
        if callableRanges == nil {
            let kinds = SymbolKind.allCases.filter(\.isCallable).map { "'\($0.rawValue)'" }.joined(separator: ",")
            callableRanges = try engine.db.query("SELECT start_line, end_line FROM symbols WHERE file_id = ? AND kind IN (\(kinds))", [file.id]) {
                $0.int(0)...max($0.int(0), $0.int(1))
            }
        }
        // Closures and nested functions see the locals of every function around them: the scope is the
        // outermost enclosing function, and each enclosing function's header declares parameters.
        let enclosing = callableRanges?.filter { $0.contains(line) } ?? []
        let scopeStart = enclosing.map(\.lowerBound).min() ?? max(1, line - 200)
        let headers = enclosing.map { $0.lowerBound...source.headerEnd(from: $0.lowerBound) }
        // The occurrence declares a parameter itself, or a function or type inside a function (not indexed).
        if headers.contains(where: { $0.contains(line) }), isScriptParameter(offset) { return true }
        if enclosing.contains(where: { $0.lowerBound < line }), !targetDeclarations.contains(offset),
           ["func", "function", "def", "struct", "class", "enum", "actor"].contains(previousWord(offset)) {
            return true
        }
        for other in earlier where other < offset {
            let otherLine = source.line(atOffset: other)
            guard otherLine >= scopeStart, !targetDeclarations.contains(other) else { continue }
            if isBinding(other) { return true }
            if headers.contains(where: { $0.contains(otherLine) }), isLabel(other) || isScriptParameter(other) { return true }
            // A function declared inside another one is a local.
            if !enclosing.isEmpty, otherLine > scopeStart, ["func", "function", "def"].contains(previousWord(other)) {
                return true
            }
        }
        return false
    }

    private func isBinding(_ offset: Int) -> Bool {
        let word = previousWord(offset)
        let rest = restOfLine(after: offset + length)
        switch source.dialect {
        case .swift:
            if word == "let" || word == "var" || word == "for" { return true }
            // Tuple patterns: `let (a, name) = …`, `for (name, value) in …`, `case let .some((name, _))`.
            let head = lineText(before: offset)
            if head.wholeMatch(of: /.*\b(let|var|for)(\s+try)?(\s+await)?\s*(case\s+)?[(.][^=]*/) != nil { return true }
            if head.wholeMatch(of: /.*\bfor(\s+try)?(\s+await)?(\s+case)?(\s+let|\s+var)?\s+/) != nil { return true }
            // Closure parameters: `{ name in`, `{ a, name in`, `{ (name, b) in`, `{ name -> T in`, `{ (name: T) -> U in`.
            if head.contains("{"), rest.wholeMatch(of: /\s*(:[^{}=]*?)?(,[^{}=]*?)?\)?\s*(->[^{}=]*?)?\s*\bin\b.*/) != nil { return true }
            // Parameters of a function declared inside another one, which the index does not hold: `func f(_ name: T)`.
            return head.wholeMatch(of: /.*\b(func\s+[^\s(<]+|init|subscript)\s*(<[^>]*>)?\(.*/) != nil && isLabel(offset)
        case .script, .jsx:
            if word == "const" || word == "let" || word == "var" { return true }
            if rest.wholeMatch(of: /\s*\)?\s*=>.*/) != nil { return true }
            // Destructuring: `const { a, name } = …`, also across lines.
            let head = lineText(before: offset)
            if head.wholeMatch(of: /\s*(export\s+)?(const|let|var)\s*[{\[][^=]*/) != nil || inDestructuringPattern(offset) { return true }
            // Another declarator of the same statement: `let a = 0, name = 0;`.
            return head.wholeMatch(of: /\s*(export\s+)?(const|let|var)\s.*,\s*/) != nil && Self.isBalanced(head)
                && rest.wholeMatch(of: /\s*(:[^=]*)?(=[^=>].*|[,;].*|)/) != nil
        case .python:
            if word == "for" || word == "as" || word == "global" || word == "nonlocal" { return true }
            // `name = …` and `a, name = …` at the start of a statement.
            let head = lineText(before: offset)
            return head.wholeMatch(of: /\s*([A-Za-z_][A-Za-z0-9_]*\s*,\s*)*/) != nil && rest.wholeMatch(of: /\s*(,\s*[A-Za-z_][A-Za-z0-9_]*\s*)*(:[^=]*)?=[^=].*/) != nil
        default:
            return false
        }
    }

    /// Inside a `{ … }` or `[ … ]` binding pattern that a `const`, `let` or `var` opens, possibly lines above.
    private func inDestructuringPattern(_ offset: Int) -> Bool {
        let regions = source.regions
        var depth = 0
        var index = offset - 1
        let limit = max(0, offset - 4000)
        while index >= limit {
            defer { index -= 1 }
            guard regions[index] == CodeLexer.Region.code.rawValue else { continue }
            switch bytes[index] {
            case 41, 93, 125: depth += 1                                  // ) ] }
            case 40: if depth == 0 { return false } else { depth -= 1 }  // (
            case 91, 123:                                                 // [ {
                if depth > 0 {
                    depth -= 1
                    continue
                }
                let word = previousWord(index)
                if word == "const" || word == "let" || word == "var" { return true }
                // A nested pattern (`const { a: { name } } = …`) continues outward after `:` or `,`.
                let previous = previousCode(index)
                if previous == 58 || previous == 44 || previous == 91 || previous == 123 { continue }
                return false
            case 59, 61: if depth == 0 { return false }                   // ; =
            default: break
            }
        }
        return false
    }

    /// Brackets in `text` are balanced (it is at statement depth 0).
    static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        for byte in text.utf8 {
            if byte == 40 || byte == 91 || byte == 123 { depth += 1 }
            if byte == 41 || byte == 93 || byte == 125 { depth -= 1 }
        }
        return depth == 0
    }

    /// A TypeScript or Python parameter without a type annotation (`(name, …)`, `(…, name)`, `(name = 1)`), or
    /// a destructured one (`({ name, other }: Props)`).
    private func isScriptParameter(_ offset: Int) -> Bool {
        guard source.dialect.isScript || source.dialect == .python else { return false }
        var before = offset - 1
        while before >= 0, bytes[before] == 32 || bytes[before] == 9 || bytes[before] == 10 || bytes[before] == 13 { before -= 1 }
        let previous = byte(before)
        var after = offset + length
        while after < bytes.count, bytes[after] == 32 || bytes[after] == 9 || bytes[after] == 10 || bytes[after] == 13 { after += 1 }
        let next = byte(after)
        return (previous == 40 || previous == 44 || previous == 123) && (next == 44 || next == 41 || next == 61 || next == 125 || next == 58)
    }

    private func previousCode(_ offset: Int) -> UInt8 {
        var index = offset - 1
        while index >= 0, bytes[index] == 32 || bytes[index] == 9 { index -= 1 }
        return byte(index)
    }

    private func previousWord(_ offset: Int) -> String {
        var end = offset - 1
        while end >= 0, bytes[end] == 32 || bytes[end] == 9 { end -= 1 }
        var start = end
        while start >= 0, CodeLexer.isIdentifierByte(bytes[start]) { start -= 1 }
        guard end > start else { return "" }
        return String(decoding: bytes[(start + 1)...end], as: UTF8.self)
    }

    private func restOfLine(after offset: Int) -> String {
        var end = offset
        while end < bytes.count, bytes[end] != 10 { end += 1 }
        return String(decoding: bytes[min(offset, end)..<end], as: UTF8.self)
    }

    private func lineText(before offset: Int) -> String {
        var start = offset
        while start > 0, bytes[start - 1] != 10 { start -= 1 }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private func unrecordedReason(_ offset: Int) -> String {
        guard previousCode(offset) == 46 else { return "no reference row" }
        var index = offset - 1
        while index >= 0, bytes[index] == 32 || bytes[index] == 9 { index -= 1 }
        let receiver = byte(index - 1)
        let hasReceiver = CodeLexer.isIdentifierByte(receiver) || receiver == 41 || receiver == 93 || receiver == 63 || receiver == 33
        return hasReceiver ? "member access with no reference row" : "implicit member with no reference row"
    }
}
