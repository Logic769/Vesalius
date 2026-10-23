import Foundation
import VesaliusCore

/// Separates code from comments and string literals, so evidence can tell a use of a name from a mention of
/// it and balance brackets on code only.
///
/// Every UTF-8 byte of a file gets a `Region`. Code interpolated into strings (`\( )`, `${ }`, f-string `{ }`)
/// is code. Swift, TypeScript/JavaScript and Python are lexed in full; C-family and `#`-comment languages
/// for their comments and strings only; every other language (Markdown, JSON, …) is non-source.
enum CodeLexer {
    enum Region: UInt8, Sendable {
        case code = 0
        case comment = 1
        /// `///`, `/** */` and Python docstrings.
        case doc = 2
        case string = 3
        case nonSource = 4
    }

    enum Dialect: Sendable {
        case swift
        case script
        /// TypeScript or JavaScript that may hold JSX (`.tsx`, `.jsx`, `.js`): element text is not code.
        case jsx
        case python
        case cFamily
        case hashComments
        case none

        init(_ language: Language) {
            switch language {
            case .swift: self = .swift
            case .typescript, .javascript: self = .script
            case .python: self = .python
            case .objectiveC, .c, .cpp, .go, .rust, .java, .kotlin, .csharp, .dart, .php: self = .cFamily
            case .shell, .ruby: self = .hashComments
            default: self = .none
            }
        }

        /// The dialect of a file: its language's, with JSX for `.tsx`, `.jsx` and `.js` (never `.ts`, where
        /// `<T>value` is a type assertion).
        init(path: String) {
            let name = (path as NSString).lastPathComponent
            let language = Language.detect(fileName: name)
            let ext = (name as NSString).pathExtension.lowercased()
            self = (language == .typescript || language == .javascript) && ["tsx", "jsx", "js", "mjs"].contains(ext) ? .jsx : Dialect(language)
        }

        /// TypeScript or JavaScript, with or without JSX.
        var isScript: Bool { self == .script || self == .jsx }

        /// Whether `$` is part of identifiers (`$scope` is one name in JavaScript; `$x` is a projection in Swift).
        var dollarIsIdentifier: Bool { isScript || self == .cFamily }
    }

    /// The region of every byte of `bytes`.
    static func regions(_ bytes: [UInt8], language: Language) -> [UInt8] {
        regions(bytes, dialect: Dialect(language))
    }

    static func regions(_ bytes: [UInt8], dialect: Dialect) -> [UInt8] {
        guard dialect != .none else { return [UInt8](repeating: Region.nonSource.rawValue, count: bytes.count) }
        return bytes.withUnsafeBufferPointer { buffer in
            var lexer = Lexer(text: buffer, dialect: dialect)
            _ = lexer.code(from: 0, closer: nil)
            return lexer.regions
        }
    }

    /// True for bytes that can continue an identifier (non-ASCII bytes included, so `café` stays one word).
    @inline(__always)
    static func isIdentifierByte(_ byte: UInt8, dollar: Bool = false) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95 || byte >= 0x80
            || (dollar && byte == 36)
    }
}

// MARK: - Lexer

private extension UInt8 {
    static let newline: UInt8 = 10
    static let space: UInt8 = 32
    static let tab: UInt8 = 9
    static let quote: UInt8 = 34      // "
    static let apostrophe: UInt8 = 39 // '
    static let backtick: UInt8 = 96   // `
    static let slash: UInt8 = 47      // /
    static let star: UInt8 = 42       // *
    static let hash: UInt8 = 35       // #
    static let backslash: UInt8 = 92  // \
    static let dollar: UInt8 = 36     // $
    static let openParen: UInt8 = 40
    static let closeParen: UInt8 = 41
    static let openBrace: UInt8 = 123
    static let closeBrace: UInt8 = 125
    static let openBracket: UInt8 = 91
    static let closeBracket: UInt8 = 93
}

private struct Lexer {
    let text: UnsafeBufferPointer<UInt8>
    let dialect: CodeLexer.Dialect
    let count: Int
    var regions: [UInt8]

    init(text: UnsafeBufferPointer<UInt8>, dialect: CodeLexer.Dialect) {
        self.text = text
        self.dialect = dialect
        self.count = text.count
        self.regions = [UInt8](repeating: CodeLexer.Region.code.rawValue, count: text.count)
    }

    private func at(_ index: Int) -> UInt8 {
        index >= 0 && index < count ? text[index] : 0
    }

    private mutating func mark(_ start: Int, _ end: Int, _ region: CodeLexer.Region) {
        var index = max(0, start)
        let end = min(count, end)
        while index < end {
            regions[index] = region.rawValue
            index += 1
        }
    }

    private func endOfLine(from index: Int) -> Int {
        var index = index
        while index < count, text[index] != .newline { index += 1 }
        return index
    }

    /// The last non-blank byte before `index` on the same line, or nil at the line start.
    private func previousOnLine(_ index: Int) -> UInt8? {
        var index = index - 1
        while index >= 0 {
            let byte = text[index]
            if byte == .newline { return nil }
            if byte != .space && byte != .tab && byte != 13 { return byte }
            index -= 1
        }
        return nil
    }

    /// The identifier that ends right before `index` (skipping blanks), e.g. a keyword before a `/`.
    private func previousWord(_ index: Int) -> String {
        var end = index - 1
        while end >= 0, text[end] == .space || text[end] == .tab { end -= 1 }
        var start = end
        while start >= 0, CodeLexer.isIdentifierByte(text[start]) { start -= 1 }
        guard end > start else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: text[(start + 1)...end]), as: UTF8.self)
    }

    /// Lexes code from `start`. Inside an interpolation (`closer` set), stops at the byte that closes it and
    /// returns its index; otherwise returns the end of the text.
    mutating func code(from start: Int, closer: UInt8?) -> Int {
        let opener: UInt8? = closer == .closeParen ? .openParen : (closer == .closeBrace ? .openBrace : nil)
        var depth = 0
        var index = start
        while index < count {
            let byte = text[index]
            if let closer {
                if byte == opener {
                    depth += 1
                } else if byte == closer {
                    if depth == 0 { return index }
                    depth -= 1
                }
            }
            switch dialect {
            case .swift: index = swiftToken(at: index)
            case .script, .jsx: index = scriptToken(at: index)
            case .python: index = pythonToken(at: index)
            case .cFamily: index = cFamilyToken(at: index)
            case .hashComments: index = hashToken(at: index)
            case .none: index += 1
            }
        }
        return count
    }

    // MARK: Comments shared by C-like dialects

    /// `//` and `/* */` comments starting at `index`; returns the index after the comment, or nil.
    private mutating func slashComment(at index: Int, nested: Bool) -> Int? {
        guard text[index] == .slash else { return nil }
        let next = at(index + 1)
        if next == .slash {
            let end = endOfLine(from: index)
            // `///` documents the next declaration; `////` is a divider.
            let isDoc = at(index + 2) == .slash && at(index + 3) != .slash
            mark(index, end, isDoc ? .doc : .comment)
            return end
        }
        if next == .star {
            let isDoc = at(index + 2) == .star && at(index + 3) != .slash
            var level = 1
            var cursor = index + 2
            while cursor < count && level > 0 {
                if nested && text[cursor] == .slash && at(cursor + 1) == .star {
                    level += 1
                    cursor += 2
                } else if text[cursor] == .star && at(cursor + 1) == .slash {
                    level -= 1
                    cursor += 2
                } else {
                    cursor += 1
                }
            }
            mark(index, cursor, isDoc ? .doc : .comment)
            return cursor
        }
        return nil
    }

    // MARK: Swift

    private mutating func swiftToken(at index: Int) -> Int {
        let byte = text[index]
        if let end = slashComment(at: index, nested: true) { return end }
        if byte == .quote { return swiftString(from: index) }
        if byte == .hash {
            var cursor = index
            while at(cursor) == .hash { cursor += 1 }
            if at(cursor) == .quote { return swiftString(from: index) }
            if at(cursor) == .slash { return swiftRegex(from: index, hashes: cursor - index) }
            return index + 1
        }
        if byte == .slash, let end = bareRegex(at: index, after: [.openParen, 44, 61, .openBracket, 58, .openBrace, 38, 124, 59]) {
            return end
        }
        return index + 1
    }

    /// A Swift string literal starting at its first `#` or quote, with `\( )` interpolations lexed as code.
    private mutating func swiftString(from start: Int) -> Int {
        var index = start
        var hashes = 0
        while at(index) == .hash {
            hashes += 1
            index += 1
        }
        let multiline = at(index + 1) == .quote && at(index + 2) == .quote
        let quotes = multiline ? 3 : 1
        mark(start, index + quotes, .string)
        index += quotes
        while index < count {
            let byte = text[index]
            if byte == .backslash && hashesFollow(index + 1, hashes) {
                let escaped = index + 1 + hashes
                if at(escaped) == .openParen {
                    mark(index, escaped + 1, .string)
                    let close = code(from: escaped + 1, closer: .closeParen)
                    mark(close, close + 1, .string)
                    index = close + 1
                    continue
                }
                mark(index, escaped + 1, .string)
                index = escaped + 1
                continue
            }
            if byte == .quote {
                if multiline {
                    if at(index + 1) == .quote && at(index + 2) == .quote && hashesFollow(index + 3, hashes) {
                        mark(index, index + 3 + hashes, .string)
                        return index + 3 + hashes
                    }
                } else if hashesFollow(index + 1, hashes) {
                    mark(index, index + 1 + hashes, .string)
                    return index + 1 + hashes
                }
            }
            if byte == .newline && !multiline { return index }
            regions[index] = CodeLexer.Region.string.rawValue
            index += 1
        }
        return count
    }

    private func hashesFollow(_ index: Int, _ hashes: Int) -> Bool {
        var cursor = index
        for _ in 0..<hashes {
            guard at(cursor) == .hash else { return false }
            cursor += 1
        }
        return true
    }

    /// `#/…/#` (extended regex literal); a `#/` without its closer is code.
    private mutating func swiftRegex(from start: Int, hashes: Int) -> Int {
        var index = start + hashes + 1
        while index < count {
            if text[index] == .slash && hashesFollow(index + 1, hashes) {
                mark(start, index + 1 + hashes, .string)
                return index + 1 + hashes
            }
            if text[index] == .backslash { index += 1 }
            index += 1
        }
        return start + 1
    }

    /// A one-line `/regex/` where an expression can start (after one of `after`, or a keyword in JavaScript);
    /// division otherwise. Returns the index after the literal and its flags, or nil when it is not one.
    private mutating func bareRegex(at index: Int, after openers: Set<UInt8>, keywords: Set<String> = []) -> Int? {
        let next = at(index + 1)
        guard next != .slash, next != .star, next != .space, next != .tab, next != .newline, next != 61 else { return nil }
        if let previous = previousOnLine(index) {
            if !openers.contains(previous) {
                guard !keywords.isEmpty, CodeLexer.isIdentifierByte(previous), keywords.contains(previousWord(index)) else { return nil }
            }
        } else if dialect == .swift {
            return nil
        }
        var cursor = index + 1
        var inClass = false
        while cursor < count {
            let byte = text[cursor]
            if byte == .newline { return nil }
            if byte == .backslash {
                cursor += 2
                continue
            }
            if byte == .openBracket { inClass = true }
            if byte == .closeBracket { inClass = false }
            if byte == .slash && !inClass {
                if dialect == .swift && (text[cursor - 1] == .space || text[cursor - 1] == .tab) { return nil }
                var end = cursor + 1
                while end < count, (text[end] >= 97 && text[end] <= 122) { end += 1 }
                mark(index, end, .string)
                return end
            }
            cursor += 1
        }
        return nil
    }

    // MARK: TypeScript / JavaScript

    private static let regexKeywords: Set<String> = ["return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "instanceof", "yield", "await"]

    private mutating func scriptToken(at index: Int) -> Int {
        let byte = text[index]
        if let end = slashComment(at: index, nested: false) { return end }
        if byte == .quote || byte == .apostrophe { return quoted(from: index, quote: byte, escapes: true) }
        if byte == .backtick { return template(from: index) }
        if byte == .slash {
            let openers: Set<UInt8> = [.openParen, 44, 61, .openBracket, 58, .openBrace, 59, 33, 38, 124, 63, 43, 45, 42, 37, 60, 62, 126, 94]
            if let end = bareRegex(at: index, after: openers, keywords: Self.regexKeywords) { return end }
        }
        if byte == 60, dialect == .jsx, startsElement(at: index), let end = element(from: index) { return end } // <
        return index + 1
    }

    // MARK: JSX

    private static let elementKeywords: Set<String> = ["return", "case", "default", "yield", "await", "else", "do"]

    /// A `<` where an expression starts (after `(`, `,`, `=`, `:`, `?`, `{`, `}`, `[`, `;`, `&&`, `||`, `=>`,
    /// `return`, or at a line start) followed by a tag name or `>`: a JSX element, not a comparison.
    private func startsElement(at index: Int) -> Bool {
        let next = at(index + 1)
        guard (next >= 97 && next <= 122) || (next >= 65 && next <= 90) || next == 62 else { return false }
        guard let previous = previousOnLine(index) else { return true }
        switch previous {
        case .openParen, 44, 61, 58, 63, .openBrace, .closeBrace, .openBracket, 59, 38, 124: return true
        case 62: return at(index - 1) == 61 || previousOnLineBefore(index, skipping: 62) == 61 // `=>`
        default: return CodeLexer.isIdentifierByte(previous) && Self.elementKeywords.contains(previousWord(index))
        }
    }

    private func previousOnLineBefore(_ index: Int, skipping byte: UInt8) -> UInt8? {
        var cursor = index - 1
        while cursor >= 0, text[cursor] == .space || text[cursor] == .tab { cursor -= 1 }
        guard cursor >= 0, text[cursor] == byte else { return nil }
        return at(cursor - 1)
    }

    /// A JSX element from its `<`: attribute strings are strings, `{ }` containers are code, and the text
    /// between tags is a string. Returns the index after the element, or nil when the tag is not one: a type
    /// parameter list (`<T,>(x: T) =>`, `<T extends Props>(…) =>`, `<T = unknown>`), a comparison, or a tag that
    /// never closes. Bytes marked while trying are code again, so nothing after a false start reads as text.
    private mutating func element(from start: Int) -> Int? {
        var index = start + 1
        // Tag name: letters, digits, `_`, `.`, `-`, `:`; a fragment `<>` has none.
        while index < count, CodeLexer.isIdentifierByte(text[index]) || text[index] == 46 || text[index] == 45 || text[index] == 58 { index += 1 }
        let after = at(index)
        guard after == 62 || after == .slash || after == .space || after == .tab || after == .newline || after == 13 || after == .openBrace else { return nil }
        var next = index
        while next < count, text[next] == .space || text[next] == .tab || text[next] == .newline || text[next] == 13 { next += 1 }
        var wordEnd = next
        while wordEnd < count, CodeLexer.isIdentifierByte(text[wordEnd]) { wordEnd += 1 }
        if at(next) == 61 || String(decoding: UnsafeBufferPointer(rebasing: text[next..<wordEnd]), as: UTF8.self) == "extends" { return nil }
        // Attributes, up to `>` or `/>`.
        while index < count {
            let byte = text[index]
            if byte == .quote || byte == .apostrophe {
                index = quoted(from: index, quote: byte, escapes: false)
                continue
            }
            if byte == .openBrace {
                let close = code(from: index + 1, closer: .closeBrace)
                index = close + 1
                continue
            }
            if byte == .slash && at(index + 1) == 62 { return index + 2 }
            if byte == 62 {
                index += 1
                break
            }
            // Not attribute syntax (`<T, U>(…)`, `a < b;`): not an element after all.
            if byte == 60 || byte == 44 || byte == 59 || byte == .openParen || byte == .closeParen {
                mark(start, index, .code)
                return nil
            }
            index += 1
        }
        // Children: text, `{expressions}` and nested elements, up to the closing tag.
        while index < count {
            let byte = text[index]
            if byte == .openBrace {
                let close = code(from: index + 1, closer: .closeBrace)
                index = close + 1
                continue
            }
            if byte == 60 {
                if at(index + 1) == .slash {
                    while index < count, text[index] != 62 { index += 1 }
                    return min(count, index + 1)
                }
                let next = at(index + 1)
                if (next >= 97 && next <= 122) || (next >= 65 && next <= 90) || next == 62, let end = element(from: index) {
                    index = end
                    continue
                }
            }
            if byte != .newline && byte != .space && byte != .tab { regions[index] = CodeLexer.Region.string.rawValue }
            index += 1
        }
        // No closing tag before the end of the file.
        mark(start, count, .code)
        return nil
    }

    /// A one-line quoted string; an unterminated one ends at the line break.
    private mutating func quoted(from start: Int, quote: UInt8, escapes: Bool) -> Int {
        var index = start + 1
        while index < count {
            let byte = text[index]
            if byte == .backslash && escapes {
                index += 2
                continue
            }
            if byte == quote {
                mark(start, index + 1, .string)
                return index + 1
            }
            if byte == .newline { break }
            index += 1
        }
        mark(start, index, .string)
        return index
    }

    /// A template literal with `${ }` substitutions lexed as code.
    private mutating func template(from start: Int) -> Int {
        regions[start] = CodeLexer.Region.string.rawValue
        var index = start + 1
        while index < count {
            let byte = text[index]
            if byte == .backslash {
                mark(index, index + 2, .string)
                index += 2
                continue
            }
            if byte == .backtick {
                regions[index] = CodeLexer.Region.string.rawValue
                return index + 1
            }
            if byte == .dollar && at(index + 1) == .openBrace {
                mark(index, index + 2, .string)
                let close = code(from: index + 2, closer: .closeBrace)
                mark(close, close + 1, .string)
                index = close + 1
                continue
            }
            regions[index] = CodeLexer.Region.string.rawValue
            index += 1
        }
        return count
    }

    // MARK: Python

    private mutating func pythonToken(at index: Int) -> Int {
        let byte = text[index]
        if byte == .hash {
            let end = endOfLine(from: index)
            mark(index, end, .comment)
            return end
        }
        if byte == .quote || byte == .apostrophe { return pythonString(from: index, quoteAt: index, formatted: false) }
        // String prefixes: r, b, u, f and their pairs (rb, br, fr, rf), directly before the quote.
        if CodeLexer.isIdentifierByte(byte), !CodeLexer.isIdentifierByte(at(index - 1)) {
            var cursor = index
            var formatted = false
            while cursor < index + 2, cursor < count, "rRbBuUfF".utf8.contains(text[cursor]) {
                if text[cursor] == 102 || text[cursor] == 70 { formatted = true }
                cursor += 1
            }
            if cursor > index, at(cursor) == .quote || at(cursor) == .apostrophe {
                return pythonString(from: index, quoteAt: cursor, formatted: formatted)
            }
            // Skip the rest of the identifier so a prefix letter inside a word never starts a string.
            var end = index + 1
            while end < count, CodeLexer.isIdentifierByte(text[end]) { end += 1 }
            return end
        }
        return index + 1
    }

    private mutating func pythonString(from start: Int, quoteAt quoteIndex: Int, formatted: Bool) -> Int {
        let quote = text[quoteIndex]
        let triple = at(quoteIndex + 1) == quote && at(quoteIndex + 2) == quote
        let region: CodeLexer.Region = triple && isDocstringStart(start) ? .doc : .string
        let opening = quoteIndex + (triple ? 3 : 1)
        mark(start, opening, region)
        var index = opening
        while index < count {
            let byte = text[index]
            if byte == .backslash {
                mark(index, index + 2, region)
                index += 2
                continue
            }
            if byte == quote && (!triple || (at(index + 1) == quote && at(index + 2) == quote)) {
                let end = index + (triple ? 3 : 1)
                mark(index, end, region)
                return end
            }
            if byte == .newline && !triple { return index }
            if formatted && byte == .openBrace {
                if at(index + 1) == .openBrace {
                    mark(index, index + 2, region)
                    index += 2
                    continue
                }
                regions[index] = region.rawValue
                let close = code(from: index + 1, closer: .closeBrace)
                mark(close, close + 1, region)
                index = close + 1
                continue
            }
            regions[index] = region.rawValue
            index += 1
        }
        return count
    }

    /// A triple-quoted string that opens a module, class or function body documents it.
    private func isDocstringStart(_ start: Int) -> Bool {
        guard previousOnLine(start) == nil else { return false }
        var index = start - 1
        // Skip back over blank lines and comments to the previous code byte.
        while index >= 0 {
            let byte = text[index]
            if byte == .space || byte == .tab || byte == .newline || byte == 13 {
                index -= 1
                continue
            }
            if regions[index] == CodeLexer.Region.comment.rawValue {
                index -= 1
                continue
            }
            return byte == 58 // ':'
        }
        return true
    }

    // MARK: C family and #-comment languages (comments and strings only)

    private mutating func cFamilyToken(at index: Int) -> Int {
        let byte = text[index]
        if let end = slashComment(at: index, nested: false) { return end }
        if byte == .quote {
            if at(index + 1) == .quote && at(index + 2) == .quote {
                var cursor = index + 3
                while cursor < count, !(text[cursor] == .quote && at(cursor + 1) == .quote && at(cursor + 2) == .quote) { cursor += 1 }
                let end = min(count, cursor + 3)
                mark(index, end, .string)
                return end
            }
            return quoted(from: index, quote: .quote, escapes: true)
        }
        if byte == .backtick {
            var cursor = index + 1
            while cursor < count, text[cursor] != .backtick { cursor += 1 }
            let end = min(count, cursor + 1)
            mark(index, end, .string)
            return end
        }
        if byte == .apostrophe {
            // A character literal closes within a few bytes; a lone `'` (a Rust lifetime) is code.
            var cursor = index + 1
            while cursor < count, cursor <= index + 8, text[cursor] != .newline {
                if text[cursor] == .backslash {
                    cursor += 2
                    continue
                }
                if text[cursor] == .apostrophe {
                    mark(index, cursor + 1, .string)
                    return cursor + 1
                }
                cursor += 1
            }
        }
        return index + 1
    }

    private mutating func hashToken(at index: Int) -> Int {
        let byte = text[index]
        if byte == .hash {
            // `$#` and `${#var}` are not comments.
            let previous = at(index - 1)
            if index == 0 || previous == .space || previous == .tab || previous == .newline || previous == 59 {
                let end = endOfLine(from: index)
                mark(index, end, .comment)
                return end
            }
            return index + 1
        }
        if byte == .quote { return quoted(from: index, quote: .quote, escapes: true) }
        if byte == .apostrophe { return quoted(from: index, quote: .apostrophe, escapes: false) }
        return index + 1
    }
}
