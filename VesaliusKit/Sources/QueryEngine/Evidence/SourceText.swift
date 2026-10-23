import Foundation
import RepositoryScanner
import VesaliusCore

/// Source files read from disk for evidence: whole statements, enclosing conditions, consuming
/// statements and freshness checks.
///
/// One per engine. Files are kept in a least-recently-used cache with a byte budget (no file-count cap) and
/// re-read when their size or modification time changes. Lines are split on `\n` (a trailing `\r` is not part
/// of the line), as the analyzers count them; columns are 1-based UTF-8 byte offsets, as in `refs.col`.
final class SourceText: @unchecked Sendable {
    /// A file's size and modification time, read the way the scanner records them in `files.size`/`files.mtime`.
    struct Stamp: Hashable, Sendable {
        let size: Int
        let modified: Double
    }

    let root: URL
    let byteBudget: Int
    private let lock = NSLock()
    private var entries: [String: (file: File, lastUse: UInt64)] = [:]
    private var cachedBytes = 0
    private var clock: UInt64 = 0

    /// Files larger than this are never read (the scanner does not index them either).
    static let maxFileSize = 16 * 1024 * 1024

    init(root: URL, byteBudget: Int = 64 * 1024 * 1024) {
        self.root = root
        self.byteBudget = byteBudget
    }

    /// Drops every cached file (called with the engine's other caches).
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        cachedBytes = 0
    }

    static func stamp(of url: URL) -> Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return Stamp(size: values.fileSize ?? 0, modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    /// The file as it is on disk now (cached while its size and modification time stay the same), or nil when
    /// it is missing, binary or too large.
    func file(_ path: String) -> File? {
        let url = root.appendingPathComponent(path)
        guard let stamp = Self.stamp(of: url) else { return nil }
        lock.lock()
        if let entry = entries[path], entry.file.stamp == stamp {
            clock += 1
            entries[path] = (entry.file, clock)
            lock.unlock()
            return entry.file
        }
        lock.unlock()
        guard stamp.size <= Self.maxFileSize, let data = try? Data(contentsOf: url),
              case .text(let text, let encoding) = SourceDecoder.decode(data) else { return nil }
        let file = File(path: path, stamp: stamp, bytes: encoding == .utf8 ? [UInt8](data) : Array(text.utf8))
        insert(file)
        return file
    }

    private func insert(_ file: File) {
        lock.lock()
        defer { lock.unlock() }
        if let previous = entries[file.path] { cachedBytes -= previous.file.cost }
        clock += 1
        entries[file.path] = (file, clock)
        cachedBytes += file.cost
        while cachedBytes > byteBudget, entries.count > 1 {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }), oldest.key != file.path else { break }
            cachedBytes -= oldest.value.file.cost
            entries.removeValue(forKey: oldest.key)
        }
    }

    // MARK: Freshness

    /// True when the file on disk no longer has the size and modification time the index recorded (or is gone),
    /// so the index's line numbers may point at different code.
    func isStale(_ path: String, indexed: Stamp) -> Bool {
        Self.stamp(of: root.appendingPathComponent(path)) != indexed
    }

    /// True when line `line` of the file on disk still contains `name` as a whole identifier.
    func lineContains(_ path: String, line: Int, name: String) -> Bool {
        guard let file = file(path), let range = file.range(ofLine: line) else { return false }
        return file.occurrences(of: Array(name.utf8)).contains { range.contains($0) }
    }

    /// One trimmed source line for the legacy reference snippets (160 characters at most).
    func snippetLine(_ number: Int, in path: String) -> String? {
        guard let file = file(path), let text = file.text(ofLine: number) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
    }

    // MARK: Statements

    /// The statement around a site, for `NNN │ code` evidence.
    ///
    /// Bounds come from the index when the statement spans 3 lines or fewer (`stmt`…`end`), else from the call
    /// the site is the callee of (`line`…`callEnd`), else from bracket balancing on lexed code: walking back
    /// when the site line closes brackets opened above it (at most 2 lines, so the site stays in view) and
    /// forward until the brackets balance, stopping before a block or trailing closure opened at depth 0.
    /// At most 3 lines are shown; `name` and `column` locate the site token so elision keeps it visible.
    func statement(_ path: String, line: Int, stmt: Int? = nil, end: Int? = nil, callEnd: Int? = nil, name: String? = nil, column: Int? = nil) -> Statement? {
        guard let file = file(path), line >= 1, line <= file.lineCount else { return nil }
        return file.statement(line: line, stmt: stmt, end: end, callEnd: callEnd, name: name, column: column)
    }

    /// The `if`, `else if`, `guard`, `switch` or `case` line that governs a statement, within 2 code lines above it.
    func enclosingCondition(_ path: String, statementStart: Int, maxLength: Int = 110) -> Statement.Line? {
        file(path)?.enclosingCondition(above: statementStart, maxLength: maxLength)
    }

    /// The head line of the statement that consumes an assigned result (`refs.consumer_line`).
    func consumer(_ path: String, line: Int, maxLength: Int = 60) -> Statement.Line? {
        guard let statement = statement(path, line: line) else { return nil }
        return Statement.Line(number: statement.start, text: statement.text(maxLength: maxLength))
    }
}

// MARK: - File

extension SourceText {
    /// One decoded file: its UTF-8 bytes, where each line starts, and (on first use) its lexed regions.
    final class File: @unchecked Sendable {
        let path: String
        let stamp: Stamp
        let language: Language
        let dialect: CodeLexer.Dialect
        let bytes: [UInt8]
        /// Byte offset of the first byte of each line; line 1 starts at 0.
        let lineStarts: [Int]
        private let lock = NSLock()
        private var lexed: [UInt8]?

        init(path: String, stamp: Stamp, bytes: [UInt8]) {
            self.path = path
            self.stamp = stamp
            self.language = Language.detect(fileName: (path as NSString).lastPathComponent)
            self.dialect = CodeLexer.Dialect(path: path)
            self.bytes = bytes
            var starts = [0]
            starts.reserveCapacity(bytes.count / 32 + 1)
            bytes.withUnsafeBufferPointer { buffer in
                for index in 0..<buffer.count where buffer[index] == 10 { starts.append(index + 1) }
            }
            // A final line break ends the last line; it does not start another.
            if starts.count > 1, starts.last == bytes.count { starts.removeLast() }
            self.lineStarts = starts
        }

        /// Bytes held in the cache: the text, its line table and its region map.
        var cost: Int { bytes.count * 2 + lineStarts.count * 8 + 256 }

        var lineCount: Int { bytes.isEmpty ? 0 : lineStarts.count }

        /// Code, comment, doc, string or non-source for every byte (`CodeLexer.Region` raw values).
        var regions: [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            if let lexed { return lexed }
            let regions = CodeLexer.regions(bytes, dialect: dialect)
            lexed = regions
            return regions
        }

        /// The bytes of line `number` without its line break.
        func range(ofLine number: Int) -> Range<Int>? {
            guard number >= 1, number <= lineCount else { return nil }
            let start = lineStarts[number - 1]
            var end = number < lineStarts.count ? lineStarts[number] : bytes.count
            if end > start, bytes[end - 1] == 10 { end -= 1 }
            if end > start, bytes[end - 1] == 13 { end -= 1 }
            return start..<end
        }

        func text(ofLine number: Int) -> String? {
            guard let range = range(ofLine: number) else { return nil }
            return String(decoding: bytes[range], as: UTF8.self)
        }

        /// The 1-based line holding byte `offset`.
        func line(atOffset offset: Int) -> Int {
            var low = 0, high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return low + 1
        }

        /// The 1-based UTF-8 column of byte `offset`.
        func column(atOffset offset: Int) -> Int {
            offset - lineStarts[line(atOffset: offset) - 1] + 1
        }

        /// Byte offsets of every whole-identifier occurrence of `name` (ASCII letters, digits, `_` and
        /// non-ASCII bytes continue an identifier; `$` too where the language says so).
        func occurrences(of name: [UInt8]) -> [Int] {
            guard let first = name.first, bytes.count >= name.count else { return [] }
            let dollar = dialect.dollarIsIdentifier
            var found: [Int] = []
            bytes.withUnsafeBufferPointer { text in
                name.withUnsafeBufferPointer { needle in
                    guard let base = text.baseAddress, let needleBase = needle.baseAddress else { return }
                    let count = text.count, length = needle.count
                    var index = 0
                    while index <= count - length {
                        guard let hit = memchr(base + index, Int32(first), count - length - index + 1) else { break }
                        let start = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                        if memcmp(base + start, needleBase, length) == 0,
                           start == 0 || !CodeLexer.isIdentifierByte(text[start - 1], dollar: dollar),
                           start + length == count || !CodeLexer.isIdentifierByte(text[start + length], dollar: dollar) {
                            found.append(start)
                            index = start + length
                        } else {
                            index = start + 1
                        }
                    }
                }
            }
            return found
        }

        // MARK: Bracket balance

        @inline(__always)
        private static func bracketDelta(_ byte: UInt8) -> Int {
            switch byte {
            case 40, 91, 123: 1   // ( [ {
            case 41, 93, 125: -1  // ) ] }
            default: 0
            }
        }

        /// Net bracket change of line `number` over code bytes, and the lowest depth reached within it.
        func balance(ofLine number: Int) -> (net: Int, low: Int) {
            guard let range = range(ofLine: number) else { return (0, 0) }
            let regions = regions
            var depth = 0, low = 0
            for index in range where regions[index] == CodeLexer.Region.code.rawValue {
                depth += Self.bracketDelta(bytes[index])
                low = min(low, depth)
            }
            return (depth, low)
        }

        /// The last code byte of a line (blanks and trailing comments skipped), with its offset.
        func lastCode(ofLine number: Int) -> (byte: UInt8, offset: Int)? {
            guard let range = range(ofLine: number) else { return nil }
            let regions = regions
            var index = range.upperBound - 1
            while index >= range.lowerBound {
                let byte = bytes[index]
                if regions[index] == CodeLexer.Region.code.rawValue && byte != 32 && byte != 9 { return (byte, index) }
                index -= 1
            }
            return nil
        }

        /// The offset of the last byte of a line that is neither blank nor comment.
        func lastSignificant(ofLine number: Int) -> Int? {
            guard let range = range(ofLine: number) else { return nil }
            let regions = regions
            var index = range.upperBound - 1
            while index >= range.lowerBound {
                let region = regions[index], byte = bytes[index]
                if region != CodeLexer.Region.comment.rawValue && region != CodeLexer.Region.doc.rawValue && byte != 32 && byte != 9 {
                    return index
                }
                index -= 1
            }
            return nil
        }

        /// True when a string literal runs on past the end of line `number`: the line break is inside the literal, or
        /// (for literals whose blanks and line breaks are left unmarked) the next line starts inside it.
        func stringContinues(afterLine number: Int) -> Bool {
            guard let range = range(ofLine: number) else { return false }
            let regions = regions
            if range.upperBound < bytes.count, regions[range.upperBound] == CodeLexer.Region.string.rawValue { return true }
            guard let next = self.range(ofLine: number + 1) else { return false }
            for index in next where bytes[index] != 32 && bytes[index] != 9 {
                return regions[index] == CodeLexer.Region.string.rawValue
            }
            return false
        }

        /// True when line `number` holds part of a string literal.
        func hasString(_ number: Int) -> Bool {
            guard let range = range(ofLine: number) else { return false }
            let regions = regions
            return range.contains { regions[$0] == CodeLexer.Region.string.rawValue }
        }

        /// True when line `number` continues the statement of the code line above it. A multi-line literal between
        /// the two that has closed ended that statement: it was its last operand.
        func continuesInto(_ number: Int) -> Bool {
            guard number > 1, let previous = previousCodeLine(before: number), continuesAfter(previous) else { return false }
            if previous < number - 1, (previous + 1..<number).contains(where: hasString) {
                return stringContinues(afterLine: number - 1)
            }
            return true
        }

        /// The first code byte of a line, with its offset.
        func firstCode(ofLine number: Int) -> (byte: UInt8, offset: Int)? {
            guard let range = range(ofLine: number) else { return nil }
            let regions = regions
            for index in range where regions[index] == CodeLexer.Region.code.rawValue && bytes[index] != 32 && bytes[index] != 9 {
                return (bytes[index], index)
            }
            return nil
        }

        /// True when line `number` holds code (not only blanks or comments).
        func hasCode(_ number: Int) -> Bool { firstCode(ofLine: number) != nil }

        /// A statement that does not end on this line: a trailing `,`, `&&`, `||`, `=` or `+`, or a Python `\`. A line
        /// that ends in a string literal ends its statement (`static let id = "yearly"`) unless the literal runs on
        /// past the line break (`let text = """` and the literal's own lines).
        func continuesAfter(_ number: Int) -> Bool {
            let lastCodeByte = lastCode(ofLine: number)
            if let tail = lastSignificant(ofLine: number), tail > (lastCodeByte?.offset ?? -1), regions[tail] == CodeLexer.Region.string.rawValue {
                return stringContinues(afterLine: number)
            }
            guard let last = lastCodeByte else { return false }
            let previous = last.offset > 0 ? bytes[last.offset - 1] : 0
            switch last.byte {
            case 44, 38, 124: return true                  // , && ||
            case 43: return previous != 43                 // + but not ++
            case 92: return dialect == .python             // \
            case 61:                                       // = but not == / >= / <= / !=
                return previous != 61 && previous != 33 && previous != 60 && previous != 62
            default: return false
            }
        }

        /// The offset of a block or trailing-closure `{` that ends line `number` at depth 0, given the depth at
        /// the start of the line: everything after it is blank, a comment or a closure signature (`a, b in`).
        func trailingOpener(onLine number: Int, depthAtStart: Int) -> Int? {
            guard let range = range(ofLine: number) else { return nil }
            let regions = regions
            var depth = depthAtStart
            var candidate: Int?
            for index in range where regions[index] == CodeLexer.Region.code.rawValue {
                let byte = bytes[index]
                if byte == 123 && depth == 0 { candidate = index }
                depth += Self.bracketDelta(byte)
            }
            guard let candidate, depth > 0 else { return nil }
            let rest = codeText(candidate + 1..<range.upperBound).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return candidate }
            // A closure signature: `_, value in`, `(a, b) in`, `[weak self] value in`.
            if rest == "in" || rest.hasSuffix(" in"), !rest.contains(where: { "{};=\"".contains($0) }) { return candidate }
            return nil
        }

        /// The code bytes of `range` as text: comments are dropped (a comment followed by more code becomes `…`).
        func codeText(_ range: Range<Int>) -> String {
            codeLine(range).text
        }

        /// `codeText`, and whether the range ended inside a dropped comment (so joining the next line onto it
        /// must mark the gap, or the quoted text would not appear contiguously in the file).
        func codeLine(_ range: Range<Int>) -> (text: String, droppedTrailingComment: Bool) {
            let regions = regions
            var output: [UInt8] = []
            output.reserveCapacity(range.count)
            var inComment = false
            for index in range {
                let region = regions[index]
                if region == CodeLexer.Region.comment.rawValue || region == CodeLexer.Region.doc.rawValue {
                    inComment = true
                    continue
                }
                if inComment {
                    if bytes[index] == 32 || bytes[index] == 9 { continue }
                    output.append(contentsOf: [32, 0xE2, 0x80, 0xA6, 32]) // " … "
                    inComment = false
                }
                output.append(bytes[index])
            }
            return (Statement.collapse(String(decoding: output, as: UTF8.self)), inComment)
        }

        // MARK: Statement extraction

        func statement(line: Int, stmt: Int?, end: Int?, callEnd: Int?, name: String?, column: Int?) -> Statement {
            var start = line, last = line
            var basis = Statement.Basis.brackets
            var partial = false
            var continues = false
            if let stmt, let end, stmt <= line, line <= end, end - stmt < 3 {
                start = stmt
                last = end
                basis = .index
            } else if let callEnd, callEnd >= line {
                last = callEnd
                basis = .call
            } else {
                (start, partial) = head(of: line)
                (last, continues) = tail(from: start, site: line)
            }
            let shownEnd = min(last, start + 2)
            if last > shownEnd { continues = true }

            // Depth at the start of each shown line, to find a block opener on the statement's last line.
            var depth = 0
            var lines: [Statement.Line] = []
            var gaps = Set<Int>()
            for number in start...shownEnd {
                guard var range = range(ofLine: number) else { continue }
                if number == last, let opener = trailingOpener(onLine: number, depthAtStart: depth) {
                    range = range.lowerBound..<opener
                }
                depth += balance(ofLine: number).net
                let (text, dropped) = codeLine(range)
                if dropped { gaps.insert(number) }
                lines.append(Statement.Line(number: number, text: text))
            }
            return Statement(siteLine: line, start: start, end: last, lines: lines, gaps: gaps, partialStart: partial, continues: continues, basis: basis, name: name, siteOrdinal: siteOrdinal(line: line, name: name, column: column))
        }

        /// Which occurrence of `name` on its line the site is (0 = the first), counting the occurrences that
        /// stay in the shown text (code and strings), from the site's column (1-based, or 0-based tree-sitter).
        private func siteOrdinal(line: Int, name: String?, column: Int?) -> Int {
            guard let name, let column, let range = range(ofLine: line) else { return 0 }
            let offset = range.lowerBound + column - 1
            let regions = regions
            return occurrences(of: Array(name.utf8)).filter {
                range.contains($0) && $0 < offset - 1
                    && regions[$0] != CodeLexer.Region.comment.rawValue && regions[$0] != CodeLexer.Region.doc.rawValue
            }.count
        }

        /// The statement head for a site line: up to 2 lines back while the line closes brackets opened above
        /// it or continues the previous line.
        private func head(of line: Int) -> (start: Int, partial: Bool) {
            let need = -balance(ofLine: line).low
            let continuation = continuesInto(line)
            guard need > 0 || continuation else { return (line, false) }
            for back in 1...2 {
                let start = line - back
                guard start >= 1 else { break }
                var running = 0, low = 0
                for number in start..<line {
                    let (net, lineLow) = balance(ofLine: number)
                    low = min(low, running + lineLow)
                    running += net
                }
                let continued = continuesInto(start)
                if low >= 0, running >= need, !continued, hasCode(start) { return (start, false) }
            }
            return (max(1, line - 2), true)
        }

        private func previousCodeLine(before line: Int) -> Int? {
            var number = line - 1
            while number >= 1, number >= line - 3 {
                if hasCode(number) { return number }
                number -= 1
            }
            return nil
        }

        /// The statement's last line: where the brackets opened since `start` close (at or after the site), or
        /// a block opener at depth 0; `continues` when that is more than 40 lines away.
        private func tail(from start: Int, site: Int) -> (end: Int, continues: Bool) {
            var depth = 0
            var number = start
            let limit = min(lineCount, start + 40)
            while number <= limit {
                if number >= site, trailingOpener(onLine: number, depthAtStart: depth) != nil { return (number, false) }
                depth += balance(ofLine: number).net
                if number >= site, depth <= 0, !continuesAfter(number) { return (number, false) }
                number += 1
            }
            return (limit, true)
        }

        /// The line where the brackets opened from `line` on close again (an import list, an argument list),
        /// at most `limit` lines on; `line` itself when it opens none.
        func balancedEnd(from line: Int, limit: Int = 80) -> Int {
            var depth = 0
            var number = line
            while number <= min(lineCount, line + limit) {
                depth += balance(ofLine: number).net
                if depth <= 0 { return number }
                number += 1
            }
            return min(lineCount, line + limit)
        }

        /// The last line of a declaration's header: where its body's `{` opens at depth 0 (a function's
        /// parameters may span many lines), at most `limit` lines on.
        func headerEnd(from line: Int, limit: Int = 40) -> Int {
            var depth = 0
            var number = line
            while number <= min(lineCount, line + limit) {
                if trailingOpener(onLine: number, depthAtStart: depth) != nil { return number }
                guard let range = range(ofLine: number) else { break }
                let regions = regions
                for index in range where regions[index] == CodeLexer.Region.code.rawValue {
                    if bytes[index] == 123 && depth == 0 { return number }
                    depth += Self.bracketDelta(bytes[index])
                }
                number += 1
            }
            return line
        }

        // MARK: Enclosing condition

        func enclosingCondition(above start: Int, maxLength: Int) -> Statement.Line? {
            var candidates: [Int] = []
            var number = start - 1
            while number >= 1, number >= start - 6, candidates.count < 2 {
                if hasCode(number) { candidates.append(number) }
                number -= 1
            }
            for candidate in candidates {
                guard let range = range(ofLine: candidate) else { continue }
                let text = codeText(range)
                guard let keyword = conditionKeyword(text) else { continue }
                if governs(condition: candidate, keyword: keyword, statementStart: start) {
                    return Statement.Line(number: candidate, text: Statement.elide(text, to: maxLength, keeping: nil))
                }
            }
            return nil
        }

        private func conditionKeyword(_ text: String) -> String? {
            var line = Substring(text)
            if line.hasPrefix("}") { line = line.dropFirst().drop(while: { $0 == " " }) }
            let words = ["else if", "elif", "if", "guard", "switch", "match", "case"]
            for word in words where line.hasPrefix(word) {
                let next = line.dropFirst(word.count).first
                if next == nil || next == " " || next == "(" || next == ":" { return word == "elif" ? "if" : (word == "else if" ? "if" : (word == "match" ? "switch" : word)) }
            }
            return nil
        }

        private func governs(condition: Int, keyword: String, statementStart: Int) -> Bool {
            switch keyword {
            case "case":
                return lastCode(ofLine: condition)?.byte == 58 // ':'
            case "guard":
                // A guard that has ended guards everything after it.
                return balance(ofLine: condition).net == 0
            default:
                if dialect == .python {
                    return lastCode(ofLine: condition)?.byte == 58 && indentation(statementStart) > indentation(condition)
                }
                var depth = 0
                for number in condition..<statementStart { depth += balance(ofLine: number).net }
                if depth > 0 { return true }
                // `if (x)` with its single statement on the next line, no braces.
                return lastCode(ofLine: condition)?.byte == 41 && (condition + 1...statementStart).allSatisfy { $0 == statementStart || !hasCode($0) }
            }
        }

        private func indentation(_ number: Int) -> Int {
            guard let range = range(ofLine: number) else { return 0 }
            var count = 0
            for index in range {
                if bytes[index] == 32 { count += 1 } else if bytes[index] == 9 { count += 4 } else { break }
            }
            return count
        }
    }
}

// MARK: - Statement

/// A statement shown as evidence: at most 3 source lines, comments dropped, whitespace collapsed.
struct Statement: Sendable, Hashable {
    struct Line: Sendable, Hashable {
        let number: Int
        let text: String
    }

    enum Basis: String, Sendable {
        /// `refs.stmt_line`…`refs.end_line`.
        case index
        /// The call the site is the callee of (`refs.call_end_line`).
        case call
        /// Bracket balancing on lexed code.
        case brackets
    }

    /// The line of the site the statement was taken for.
    let siteLine: Int
    /// The statement's first line and its last line (the last may lie beyond the lines shown).
    let start: Int
    let end: Int
    /// The lines shown: at most 3, from `start`.
    let lines: [Line]
    /// Shown lines that ended in a dropped comment (or were only a comment): joining past them marks a gap.
    let gaps: Set<Int>
    /// The statement began above the lines shown.
    let partialStart: Bool
    /// The statement goes on after the lines shown.
    let continues: Bool
    let basis: Basis
    let name: String?
    /// Which occurrence of `name` on the site line is the site.
    let siteOrdinal: Int

    /// The lines shown joined on one line: no space after an opening or before a closing bracket, `…` for text
    /// left out. Not length-capped.
    var joined: String { assembled().text }

    /// `joined`, and the character offset where the site line's text starts in it.
    private func assembled() -> (text: String, siteOffset: Int) {
        var text = partialStart ? "… " : ""
        var siteOffset = text.count
        var gapPending = false
        for line in lines {
            if line.text.isEmpty {
                gapPending = gapPending || gaps.contains(line.number)
                if line.number == siteLine { siteOffset = text.count }
                continue
            }
            if text.isEmpty || text == "… " {
                // First text.
            } else if gapPending {
                text += " … "
            } else {
                let tight = text.hasSuffix("(") || text.hasSuffix("[") || line.text.hasPrefix(")") || line.text.hasPrefix("]")
                    || line.text.hasPrefix(".") || line.text.hasPrefix(",") || line.text.hasPrefix("?.")
                if !tight { text += " " }
            }
            if line.number == siteLine { siteOffset = text.count }
            text += line.text
            gapPending = gaps.contains(line.number)
        }
        if continues, !text.hasSuffix("…") { text += " …" }
        return (text, siteOffset)
    }

    /// `joined` cut to `maxLength` characters, eliding the middle and keeping the site token.
    func text(maxLength: Int = 110) -> String {
        let (text, siteOffset) = assembled()
        return Self.elide(text, to: maxLength, keeping: focus(in: text, from: siteOffset))
    }

    /// The statement as `NNN │` evidence lines: one line when it fits in `maxLength`, else one per source line
    /// (each cut to `maxLength`), so every quoted fragment stays on or within two lines after its number.
    func rendered(maxLength: Int = 110) -> [Line] {
        let (joined, siteOffset) = assembled()
        if joined.count <= maxLength || lines.count <= 1 {
            return [Line(number: start, text: Self.elide(joined, to: maxLength, keeping: focus(in: joined, from: siteOffset)))]
        }
        return lines.enumerated().compactMap { index, line in
            var text = line.text
            var siteOffset = 0
            if index == 0, partialStart {
                text = "… " + text
                siteOffset = 2
            }
            if index == lines.count - 1, continues { text += " …" }
            guard !line.text.isEmpty else { return nil }
            let focus = line.number == siteLine ? self.focus(in: text, from: siteOffset) : nil
            return Line(number: line.number, text: Self.elide(text, to: maxLength, keeping: focus))
        }
    }

    /// Where the site token is in `text` (character offsets): the site's occurrence of `name` at or after
    /// `siteOffset` (where the site line's text starts), else the first occurrence.
    func focus(in text: String, from siteOffset: Int) -> Range<Int>? {
        guard let name, !name.isEmpty else { return nil }
        let characters = Array(text)
        let needle = Array(name)
        var hits: [Int] = []
        var index = 0
        while index + needle.count <= characters.count {
            if characters[index] == needle[0], Array(characters[index..<index + needle.count]) == needle,
               index == 0 || !Self.continuesIdentifier(characters[index - 1]),
               index + needle.count == characters.count || !Self.continuesIdentifier(characters[index + needle.count]) {
                hits.append(index)
                index += needle.count
            } else {
                index += 1
            }
        }
        guard let first = hits.first else { return nil }
        let onSiteLine = hits.filter { $0 >= siteOffset }
        let pick = onSiteLine.indices.contains(siteOrdinal) ? onSiteLine[siteOrdinal] : (onSiteLine.first ?? first)
        return pick..<pick + needle.count
    }

    private static func continuesIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Whitespace runs become one space; leading and trailing blanks go.
    static func collapse(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in text {
            if character == " " || character == "\t" || character == "\r" || character == "\n" {
                pendingSpace = !output.isEmpty
                continue
            }
            if pendingSpace { output.append(" ") }
            pendingSpace = false
            output.append(character)
        }
        return output
    }

    /// `text` cut to `maxLength` characters with `…` for what is left out: the end goes first, then the middle,
    /// and the characters in `keeping` (the site token) always stay.
    static func elide(_ text: String, to maxLength: Int, keeping focus: Range<Int>?) -> String {
        let characters = Array(text)
        let count = characters.count
        guard count > maxLength else { return text }
        let limit = max(maxLength, 24)
        func slice(_ range: Range<Int>) -> String {
            range.isEmpty ? "" : String(characters[range]).trimmingCharacters(in: .whitespaces)
        }
        let tail = min(16, limit / 5)
        // The site sits in the head (or is unknown): head … tail.
        let head = limit - 1 - tail
        guard let focus, focus.upperBound > head else {
            return slice(0..<head) + "…" + slice(count - tail..<count)
        }
        // The site sits near the end: a shorter head … a longer tail that starts just before the site.
        let minimumHead = min(24, limit / 4)
        let from = max(0, focus.lowerBound - 6)
        if minimumHead + 1 + (count - from) <= limit {
            return slice(0..<(limit - 1 - (count - from))) + "…" + slice(from..<count)
        }
        // The site sits in the middle: head … site with some context … tail.
        let siteLength = min(focus.count, limit - 2 - minimumHead - tail)
        var spare = limit - 2 - minimumHead - tail - siteLength
        var lower = focus.lowerBound
        var upper = min(count, focus.lowerBound + siteLength)
        let tailStart = max(count - tail, upper)
        let before = min(spare / 2, max(0, lower - minimumHead))
        lower -= before
        spare -= before
        let after = min(spare, max(0, tailStart - upper))
        upper += after
        spare -= after
        let headLength = min(lower, minimumHead + spare)
        return slice(0..<headLength) + "…" + slice(lower..<upper) + "…" + slice(tailStart..<count)
    }
}
