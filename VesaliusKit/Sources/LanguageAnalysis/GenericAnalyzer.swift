import Foundation
import VesaliusCore

/// Lexical analyzer for languages without a dedicated syntax tree: Go, Rust, Java, Kotlin, C, C++,
/// Objective-C, C#, Ruby, PHP, Dart, shell, SQL and others. It strips comments and strings, then
/// recognises declarations, imports/includes and type-like references with per-language patterns, and
/// finds declaration extents by brace matching (or `end` keywords for Ruby).
public struct GenericAnalyzer: LanguageAnalyzer {
    public let identifier = "lexical"

    public init() {}

    public func canAnalyze(_ language: Language, path: String) -> Bool {
        language.isCode && !language.hasSyntaxAnalyzer
    }

    public func analyze(_ file: SourceFile) throws -> FileAnalysis {
        let lines = file.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let code = Self.stripCommentsAndStrings(lines, language: file.language)
        var analysis = FileAnalysis()
        analysis.imports = Self.imports(in: lines, code: code, language: file.language)
        analysis.symbols = Self.symbols(in: code, original: lines, language: file.language)
        analysis.references = Self.typeReferences(in: code, symbols: analysis.symbols, language: file.language)
        analysis.complexity = 1 + code.reduce(0) { $0 + Self.decisionPoints(in: $1) }
        for index in analysis.symbols.indices {
            let range = analysis.symbols[index].range
            if analysis.symbols[index].kind.isCallable {
                let body = code[(range.start - 1)..<min(range.end, code.count)]
                analysis.symbols[index].complexity = 1 + body.reduce(0) { $0 + Self.decisionPoints(in: $1) }
                if range.count >= 5 {
                    var hasher = FNV1a()
                    for line in body.dropFirst() { hasher.combine(Self.normalizeForHash(line)) }
                    analysis.symbols[index].bodyHash = hasher.value
                }
            }
        }
        analysis.isEntryPoint = Self.isEntryPoint(code: code, language: file.language, path: file.path)
        return analysis
    }

    // MARK: - Preprocessing

    /// Replaces comment and string contents with spaces, keeping line structure intact.
    static func stripCommentsAndStrings(_ lines: [String], language: Language) -> [String] {
        let lineComments = language.lineCommentPrefixes
        let blockComments = language.hasBlockComments
        var inBlock = false
        var result: [String] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            var output = ""
            output.reserveCapacity(line.count)
            let chars = Array(line)
            var i = 0
            var quote: Character?
            while i < chars.count {
                let c = chars[i]
                if inBlock {
                    if c == "*" && i + 1 < chars.count && chars[i + 1] == "/" {
                        inBlock = false
                        output.append("  ")
                        i += 2
                    } else {
                        output.append(" ")
                        i += 1
                    }
                    continue
                }
                if let q = quote {
                    if c == "\\" {
                        output.append("  ")
                        i += 2
                        continue
                    }
                    if c == q { quote = nil }
                    output.append(c == q ? c : " ")
                    i += 1
                    continue
                }
                if blockComments && c == "/" && i + 1 < chars.count && chars[i + 1] == "*" {
                    inBlock = true
                    output.append("  ")
                    i += 2
                    continue
                }
                if lineComments.contains(where: { prefix in
                    let p = Array(prefix)
                    return i + p.count <= chars.count && Array(chars[i..<(i + p.count)]) == p
                }) {
                    break
                }
                if c == "\"" || c == "'" || c == "`" {
                    // Rust lifetimes / Kotlin char literals: treat a lone ' followed by identifier as code.
                    if c == "'" && language == .rust && i + 2 < chars.count && chars[i + 2] != "'" {
                        output.append(c)
                        i += 1
                        continue
                    }
                    quote = c
                    output.append(c)
                    i += 1
                    continue
                }
                output.append(c)
                i += 1
            }
            result.append(output)
        }
        return result
    }

    static func normalizeForHash(_ line: String) -> String {
        var output = ""
        var inWord = false
        for c in line where !c.isWhitespace {
            if c.isLetter || c == "_" {
                if !inWord { output.append("a") }
                inWord = true
            } else if c.isNumber {
                if !inWord { output.append("0") }
            } else {
                inWord = false
                output.append(c)
            }
        }
        return output
    }

    private static let decisionKeywords: Set<String> = ["if", "for", "foreach", "while", "case", "catch", "except", "elif", "elsif", "when", "unless", "until"]

    /// Counts branch keywords and short-circuit operators with a single byte scan (no regex).
    static func decisionPoints(in line: String) -> Int {
        var count = 0
        var word: [UInt8] = []
        var previous: UInt8 = 0
        func flush() {
            if word.count >= 2 && word.count <= 7, let text = String(bytes: word, encoding: .ascii), decisionKeywords.contains(text) { count += 1 }
            word.removeAll(keepingCapacity: true)
        }
        for byte in line.utf8 {
            let isWord = (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95
            if isWord {
                word.append(byte)
            } else {
                if !word.isEmpty { flush() }
                if (byte == 38 && previous == 38) || (byte == 124 && previous == 124) { count += 1 }
            }
            previous = byte
        }
        if !word.isEmpty { flush() }
        return count
    }

    // MARK: - Imports

    static func imports(in lines: [String], code: [String], language: Language) -> [ExtractedImport] {
        var result: [ExtractedImport] = []
        var inGoBlock = false
        let leaders: Set<Character> = ["#", "@", "i", "u", "r", "p", "m", "e", "s", ".", ")", "\"", "f"]
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, leaders.contains(first) || inGoBlock else { continue }
            let lineNumber = index + 1
            switch language {
            case .c, .cpp, .objectiveC:
                if let m = line.firstMatch(of: /^#\s*(?:include|import)\s*"([^"]+)"/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .include, line: lineNumber))
                } else if let m = line.firstMatch(of: /^#\s*(?:include|import)\s*<([^>]+)>/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .module, line: lineNumber))
                } else if let m = line.firstMatch(of: /^@import\s+([\w.]+)\s*;/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .module, line: lineNumber))
                }
            case .go:
                if line.hasPrefix("import (") { inGoBlock = true; continue }
                if inGoBlock {
                    if line.hasPrefix(")") { inGoBlock = false; continue }
                    if let m = line.firstMatch(of: /^(?:[\w.]+\s+)?"([^"]+)"/) {
                        result.append(ExtractedImport(module: String(m.1), kind: .module, line: lineNumber))
                    }
                } else if let m = line.firstMatch(of: /^import\s+(?:[\w.]+\s+)?"([^"]+)"/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .module, line: lineNumber))
                }
            case .rust:
                if let m = line.firstMatch(of: /^(?:pub(?:\([^)]*\))?\s+)?use\s+([\w:]+)/) {
                    var module = String(m.1)
                    if module.hasSuffix("::") { module.removeLast(2) }
                    result.append(ExtractedImport(module: module, kind: .module, line: lineNumber))
                } else if let m = line.firstMatch(of: /^(?:pub\s+)?mod\s+(\w+)\s*;/) {
                    result.append(ExtractedImport(module: "self::" + String(m.1), kind: .relative, line: lineNumber))
                }
            case .java, .kotlin:
                if let m = line.firstMatch(of: /^import\s+(?:static\s+)?([\w.]+(?:\.\*)?)/) {
                    let module = String(m.1).replacingOccurrences(of: ".*", with: "")
                    result.append(ExtractedImport(module: module, kind: .module, line: lineNumber))
                }
            case .csharp:
                if let m = line.firstMatch(of: /^using\s+(?:static\s+)?([\w.]+)\s*;/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .module, line: lineNumber))
                }
            case .ruby:
                if let m = line.firstMatch(of: /^require_relative\s+['"]([^'"]+)['"]/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .relative, line: lineNumber))
                } else if let m = line.firstMatch(of: /^require\s+['"]([^'"]+)['"]/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .module, line: lineNumber))
                }
            case .php:
                if let m = line.firstMatch(of: /^use\s+([\w\\]+)/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .module, line: lineNumber))
                } else if let m = line.firstMatch(of: /^(?:require|include)(?:_once)?\s*\(?\s*['"]([^'"]+)['"]/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .relative, line: lineNumber))
                }
            case .dart:
                if let m = line.firstMatch(of: /^(?:import|export|part)\s+['"]([^'"]+)['"]/) {
                    let module = String(m.1)
                    result.append(ExtractedImport(module: module, kind: module.hasPrefix("package:") || module.hasPrefix("dart:") ? .module : .relative, line: lineNumber))
                }
            case .shell:
                if let m = line.firstMatch(of: /^(?:source|\.)\s+([\w.\/\-]+)/) {
                    result.append(ExtractedImport(module: String(m.1), kind: .relative, line: lineNumber))
                }
            default:
                break
            }
        }
        _ = code
        return result
    }

    // MARK: - Symbols

    private struct Pattern {
        let regex: Regex<(Substring, Substring)>
        let kind: SymbolKind
    }

    private static func patterns(for language: Language) -> [Pattern] {
        switch language {
        case .go:
            return [
                Pattern(regex: /^func\s+\([^)]*\)\s+(\w+)\s*[\[(]/, kind: .method),
                Pattern(regex: /^func\s+(\w+)\s*[\[(]/, kind: .function),
                Pattern(regex: /^type\s+(\w+)\s+struct\b/, kind: .struct),
                Pattern(regex: /^type\s+(\w+)\s+interface\b/, kind: .interface),
                Pattern(regex: /^type\s+(\w+)\s+/, kind: .typeAlias),
            ]
        case .rust:
            return [
                Pattern(regex: /^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:const\s+)?fn\s+(\w+)/, kind: .function),
                Pattern(regex: /^\s*(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)/, kind: .struct),
                Pattern(regex: /^\s*(?:pub(?:\([^)]*\))?\s+)?enum\s+(\w+)/, kind: .enum),
                Pattern(regex: /^\s*(?:pub(?:\([^)]*\))?\s+)?trait\s+(\w+)/, kind: .protocol),
                Pattern(regex: /^\s*impl(?:<[^>]*>)?\s+(?:[\w:<>, ]+\s+for\s+)?(\w+)/, kind: .extension),
                Pattern(regex: /^\s*(?:pub(?:\([^)]*\))?\s+)?type\s+(\w+)/, kind: .typeAlias),
                Pattern(regex: /^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*\{/, kind: .namespace),
            ]
        case .java, .csharp, .dart:
            return [
                Pattern(regex: /^\s*(?:(?:public|private|protected|internal|static|abstract|final|sealed|partial|data|open)\s+)*(?:class|record)\s+(\w+)/, kind: .class),
                Pattern(regex: /^\s*(?:(?:public|private|protected|internal|static|abstract|sealed|partial)\s+)*interface\s+(\w+)/, kind: .interface),
                Pattern(regex: /^\s*(?:(?:public|private|protected|internal|static)\s+)*enum\s+(\w+)/, kind: .enum),
                Pattern(regex: /^\s*(?:(?:public|private|protected|internal|static)\s+)*struct\s+(\w+)/, kind: .struct),
                Pattern(regex: /^\s*(?:(?:public|private|protected|internal|static|final|abstract|synchronized|override|virtual|async|sealed)\s+)+[\w<>\[\],?. ]+\s+(\w+)\s*\([^;]*$/, kind: .method),
            ]
        case .kotlin:
            return [
                Pattern(regex: /^\s*(?:(?:public|private|protected|internal|abstract|open|sealed|data|inner|enum|annotation)\s+)*class\s+(\w+)/, kind: .class),
                Pattern(regex: /^\s*(?:(?:public|private|protected|internal|fun|sealed)\s+)*interface\s+(\w+)/, kind: .interface),
                Pattern(regex: /^\s*(?:(?:public|private|protected|internal|data|companion)\s+)*object\s+(\w+)/, kind: .class),
                Pattern(regex: /^\s*(?:(?:public|private|protected|internal|override|open|abstract|suspend|inline|operator|infix|tailrec)\s+)*fun\s+(?:<[^>]*>\s*)?(?:[\w.]+\.)?(\w+)\s*\(/, kind: .function),
            ]
        case .c, .cpp, .objectiveC:
            return [
                Pattern(regex: /^@interface\s+(\w+)/, kind: .class),
                Pattern(regex: /^@implementation\s+(\w+)/, kind: .extension),
                Pattern(regex: /^@protocol\s+(\w+)/, kind: .protocol),
                Pattern(regex: /^\s*(?:template\s*<[^>]*>\s*)?class\s+(\w+)[^;]*$/, kind: .class),
                Pattern(regex: /^\s*(?:typedef\s+)?struct\s+(\w+)\s*\{?\s*$/, kind: .struct),
                Pattern(regex: /^\s*(?:typedef\s+)?enum\s+(?:class\s+)?(\w+)/, kind: .enum),
                Pattern(regex: /^namespace\s+(\w+)/, kind: .namespace),
                Pattern(regex: /^[-+]\s*\([^)]*\)\s*(\w+)/, kind: .method),
                Pattern(regex: /^(?!\s*(?:if|for|while|switch|return|else)\b)[\w:*&<> ]+[\s*&]+(?:\w+::)?(\w+)\s*\([^;]*\)\s*(?:const\s*)?\{?\s*$/, kind: .function),
            ]
        case .ruby:
            return [
                Pattern(regex: /^\s*class\s+(\w+)/, kind: .class),
                Pattern(regex: /^\s*module\s+(\w+)/, kind: .namespace),
                Pattern(regex: /^\s*def\s+(?:self\.)?(\w+[?!=]?)/, kind: .method),
            ]
        case .php:
            return [
                Pattern(regex: /^\s*(?:(?:abstract|final)\s+)?class\s+(\w+)/, kind: .class),
                Pattern(regex: /^\s*interface\s+(\w+)/, kind: .interface),
                Pattern(regex: /^\s*trait\s+(\w+)/, kind: .protocol),
                Pattern(regex: /^\s*(?:(?:public|private|protected|static|abstract|final)\s+)*function\s+(\w+)/, kind: .function),
            ]
        case .shell:
            return [
                Pattern(regex: /^\s*(?:function\s+)?([\w\-]+)\s*\(\)\s*\{?/, kind: .function),
                Pattern(regex: /^\s*function\s+([\w\-]+)/, kind: .function),
            ]
        case .sql:
            return [
                Pattern(regex: /(?i)^\s*create\s+(?:or\s+replace\s+)?(?:temporary\s+|temp\s+)?table\s+(?:if\s+not\s+exists\s+)?[\w."]*?(\w+)"?\s*\(/, kind: .struct),
                Pattern(regex: /(?i)^\s*create\s+(?:or\s+replace\s+)?(?:materialized\s+)?view\s+(?:if\s+not\s+exists\s+)?[\w."]*?(\w+)/, kind: .struct),
                Pattern(regex: /(?i)^\s*create\s+(?:or\s+replace\s+)?(?:function|procedure)\s+[\w."]*?(\w+)\s*\(/, kind: .function),
            ]
        default:
            return []
        }
    }

    static func symbols(in code: [String], original: [String], language: Language) -> [ExtractedSymbol] {
        let patterns = patterns(for: language)
        guard !patterns.isEmpty else { return [] }
        var found: [(line: Int, name: String, kind: SymbolKind, indent: Int)] = []
        let hints = declarationHints(for: language)
        for (index, line) in code.enumerated() {
            guard line.utf8.count < 600, mightDeclare(line, hints: hints, language: language) else { continue }
            for pattern in patterns {
                if let match = line.firstMatch(of: pattern.regex) {
                    let name = String(match.1)
                    guard !Tokenizer.languageKeywords.contains(name), name.count > 1 || language == .go else { break }
                    let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                    found.append((index + 1, name, pattern.kind, indent))
                    break
                }
            }
        }

        // Extents: brace matching for brace languages, `end` for Ruby, else until the next declaration.
        var symbols: [ExtractedSymbol] = []
        var stack: [(localID: Int, end: Int)] = []
        for (position, item) in found.enumerated() {
            let end: Int
            switch language {
            case .ruby:
                end = rubyEnd(from: item.line, indent: item.indent, code: code) ?? (position + 1 < found.count ? found[position + 1].line - 1 : code.count)
            case .shell, .sql:
                end = braceEnd(from: item.line, code: code) ?? (position + 1 < found.count ? found[position + 1].line - 1 : code.count)
            default:
                end = braceEnd(from: item.line, code: code) ?? item.line
            }
            while let top = stack.last, top.end < item.line { stack.removeLast() }
            let parent = stack.last?.localID
            var kind = item.kind
            if kind == .function, let parentID = parent, symbols[parentID].kind.isContainer { kind = .method }
            if kind == .method, parent == nil, language != .objectiveC, language != .go { kind = .function }
            let localID = symbols.count
            let signature = original[item.line - 1].trimmingCharacters(in: .whitespaces).compactSignature()
            symbols.append(ExtractedSymbol(
                localID: localID,
                parentLocalID: parent,
                name: item.name,
                kind: kind,
                range: LineRange(item.line, max(item.line, end)),
                signature: signature,
                doc: docComment(above: item.line, lines: original, language: language),
                visibility: visibility(in: original[item.line - 1], language: language, name: item.name),
                isExported: isExported(original[item.line - 1], language: language, name: item.name)
            ))
            if kind.isContainer || language == .ruby {
                stack.append((localID, end))
            }
        }
        return symbols
    }

    /// Keywords whose presence makes a line worth testing against the declaration regexes.
    static func declarationHints(for language: Language) -> [String] {
        switch language {
        case .go: ["func ", "type "]
        case .rust: ["fn ", "struct ", "enum ", "trait ", "impl", "type ", "mod "]
        case .java, .csharp, .dart: ["class ", "interface ", "enum ", "struct ", "record ", "("]
        case .kotlin: ["class ", "interface ", "object ", "fun "]
        case .ruby: ["class ", "module ", "def "]
        case .php: ["class ", "interface ", "trait ", "function "]
        case .shell: ["()", "function "]
        case .sql: ["create ", "CREATE "]
        case .c, .cpp, .objectiveC: ["@interface", "@implementation", "@protocol", "class ", "struct ", "enum ", "namespace ", "("]
        default: []
        }
    }

    static func mightDeclare(_ line: String, hints: [String], language: Language) -> Bool {
        guard !hints.isEmpty else { return false }
        if [.c, .cpp, .objectiveC].contains(language) {
            // Function definitions start at column 0 and do not end with `;`; types may be indented.
            let trimmedEnd = line.trimmingCharacters(in: .whitespaces)
            if trimmedEnd.isEmpty || trimmedEnd.hasSuffix(";") || trimmedEnd.hasPrefix("#") || trimmedEnd.hasPrefix("//") { return false }
            if let first = line.first, first == " " || first == "\t" {
                return hints.dropLast().contains { line.contains($0) }
            }
        }
        return hints.contains { line.contains($0) }
    }

    static func braceEnd(from line: Int, code: [String]) -> Int? {
        var depth = 0
        var opened = false
        for index in (line - 1)..<min(code.count, line - 1 + 4000) {
            for c in code[index] {
                if c == "{" {
                    depth += 1
                    opened = true
                } else if c == "}" {
                    depth -= 1
                    if opened && depth <= 0 { return index + 1 }
                } else if c == ";" && !opened && index == line - 1 {
                    // A declaration without a body (prototype).
                    return nil
                }
            }
            if !opened && index > line + 2 { return nil }
        }
        return nil
    }

    static func rubyEnd(from line: Int, indent: Int, code: [String]) -> Int? {
        for index in line..<min(code.count, line + 4000) {
            let text = code[index]
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let currentIndent = text.prefix { $0 == " " || $0 == "\t" }.count
            if trimmed == "end" && currentIndent <= indent { return index + 1 }
        }
        return nil
    }

    static func docComment(above line: Int, lines: [String], language: Language) -> String? {
        var collected: [String] = []
        var index = line - 2
        while index >= 0 {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("--") {
                if trimmed.hasPrefix("#") && [.c, .cpp, .objectiveC].contains(language) { break }
                collected.insert(trimmed, at: 0)
                index -= 1
            } else if trimmed.hasPrefix("@") && (language == .java || language == .kotlin) {
                index -= 1
            } else {
                break
            }
            if collected.count > 30 { break }
        }
        return collected.isEmpty ? nil : collected.joined(separator: "\n").cleanedDocComment()
    }

    static func visibility(in line: String, language: Language, name: String) -> Visibility? {
        let words = Set(line.split(whereSeparator: { !$0.isLetter }).map(String.init))
        if words.contains("private") { return .private }
        if words.contains("protected") || words.contains("fileprivate") { return .fileprivate }
        if words.contains("internal") { return .internal }
        if words.contains("public") || line.contains("pub ") || line.hasPrefix("pub(") { return .public }
        if language == .go, let first = name.first { return first.isUppercase ? .public : .internal }
        return nil
    }

    static func isExported(_ line: String, language: Language, name: String) -> Bool {
        switch language {
        case .go: return name.first?.isUppercase ?? false
        case .rust: return line.trimmingCharacters(in: .whitespaces).hasPrefix("pub")
        case .java, .csharp, .kotlin, .php, .dart: return !line.contains("private")
        default: return true
        }
    }

    // MARK: - References

    private static let commonTypeNames: Set<String> = [
        "String", "Int", "Integer", "Long", "Double", "Float", "Boolean", "Bool", "Object", "List", "Map", "Set", "Array",
        "HashMap", "ArrayList", "Optional", "Error", "Exception", "Void", "Self", "None", "True", "False", "TODO", "NULL", "BOOL", "YES", "NO",
        "Vec", "Box", "Option", "Result", "Some", "Ok", "Err", "Rc", "Arc", "Any", "Unit", "Nothing", "NSString", "NSObject", "NSArray", "NSDictionary",
    ]

    static func typeReferences(in code: [String], symbols: [ExtractedSymbol], language: Language) -> [ExtractedReference] {
        var declarationLines: [String: Set<Int>] = [:]
        for symbol in symbols { declarationLines[symbol.name, default: []].insert(symbol.range.start) }
        // Containers sorted by start so the innermost enclosing symbol is found with a forward scan.
        let containers = symbols.filter { $0.kind.isContainer || $0.kind.isCallable }
        var references: [ExtractedReference] = []
        var seen: Set<String> = []
        for (index, line) in code.enumerated() {
            let lineNumber = index + 1
            let bytes = Array(line.utf8)
            var i = 0
            var enclosing: Int?? = nil
            while i < bytes.count {
                let byte = bytes[i]
                guard byte >= 65 && byte <= 90, i == 0 || !isIdentifierByte(bytes[i - 1]) else {
                    i += 1
                    continue
                }
                var j = i + 1
                var allUpper = true
                while j < bytes.count && isIdentifierByte(bytes[j]) {
                    if bytes[j] >= 97 && bytes[j] <= 122 { allUpper = false }
                    j += 1
                }
                let length = j - i
                if length >= 3 && !allUpper, let name = String(bytes: bytes[i..<j], encoding: .utf8), !commonTypeNames.contains(name),
                   !(declarationLines[name]?.contains(lineNumber) ?? false) {
                    if enclosing == nil {
                        enclosing = .some(containers.last { $0.range.start <= lineNumber && $0.range.end >= lineNumber }?.localID)
                    }
                    let owner = enclosing ?? nil
                    let key = "\(name)|\(owner ?? -1)"
                    if seen.insert(key).inserted {
                        var k = j
                        while k < bytes.count && bytes[k] == 32 { k += 1 }
                        let kind: ReferenceKind = k < bytes.count && bytes[k] == 40 ? .instantiate : .typeUse
                        references.append(ExtractedReference(name: name, kind: kind, line: lineNumber, column: i, enclosingSymbol: owner))
                        if references.count > 4000 { return references }
                    }
                }
                i = j
            }
        }
        _ = language
        return references
    }

    @inline(__always)
    static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95
    }

    static func isEntryPoint(code: [String], language: Language, path: String) -> Bool {
        let joined = code.prefix(400)
        switch language {
        case .go: return joined.contains { $0.hasPrefix("package main") } && joined.contains { $0.contains("func main(") }
        case .rust: return path.hasSuffix("main.rs") || path.hasSuffix("lib.rs") || path.hasSuffix("build.rs")
        case .c, .cpp, .objectiveC: return code.contains { $0.contains(" main(") || $0.hasPrefix("int main") }
        case .java, .kotlin, .csharp: return code.contains { $0.contains("static void main") || $0.contains("fun main(") || $0.contains("static void Main") || $0.contains("static async Task Main") }
        case .shell: return true
        default: return false
        }
    }
}
