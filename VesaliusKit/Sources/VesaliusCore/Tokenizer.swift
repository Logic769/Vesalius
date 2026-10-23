import Foundation

/// Identifier-aware text processing shared by indexing and querying.
public enum Tokenizer {
    /// Splits an identifier into lowercase words:
    /// `URLSessionTaskDelegate` → `url session task delegate`, `refresh_token` → `refresh token`,
    /// `getHTTP2Client` → `get http2 client`.
    public static func splitIdentifier(_ identifier: some StringProtocol) -> [String] {
        var words: [String] = []
        var current: [Character] = []

        func flush() {
            if !current.isEmpty {
                words.append(String(current).lowercased())
                current.removeAll(keepingCapacity: true)
            }
        }

        let chars = Array(identifier)
        for (i, ch) in chars.enumerated() {
            if ch == "_" || ch == "-" || ch == "." || ch == "/" || ch == "$" || ch == " " || ch == ":" {
                flush()
                continue
            }
            guard ch.isLetter || ch.isNumber else {
                flush()
                continue
            }
            if let last = current.last {
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if ch.isUppercase && last.isLowercase {
                    flush()                                    // fooBar → foo | Bar
                } else if ch.isUppercase && last.isUppercase, let next, next.isLowercase {
                    flush()                                    // URLSession → URL | Session
                } else if ch.isLetter && last.isNumber && ch.isUppercase {
                    flush()                                    // HTTP2Client → HTTP2 | Client
                }
            }
            current.append(ch)
        }
        flush()
        return words
    }

    /// Lowercase words for a path: directories, file stem and split identifiers.
    public static func pathWords(_ path: String) -> [String] {
        var words: [String] = []
        for component in path.split(separator: "/") {
            var name = Substring(component)
            if let dot = name.lastIndex(of: "."), dot != name.startIndex { name = name[..<dot] }
            words.append(contentsOf: splitIdentifier(name))
        }
        return words
    }

    /// Extracts searchable words from source text: identifiers (plus their split words), words in
    /// comments and string literals. Numbers and one-letter tokens are dropped. Intended for FTS input.
    public static func lexicalWords(in text: String, limit: Int = 60_000) -> [String] {
        var output: [String] = []
        output.reserveCapacity(min(limit, text.utf8.count / 4))
        var token: [UInt8] = []
        token.reserveCapacity(64)

        func emit() {
            defer { token.removeAll(keepingCapacity: true) }
            guard token.count >= 2, token.count <= 64 else { return }
            guard let first = token.first, !(first >= 48 && first <= 57) else { return }
            let raw = String(decoding: token, as: UTF8.self)
            let parts = splitIdentifier(raw)
            if parts.count > 1 {
                output.append(raw.lowercased())
            }
            for part in parts where part.count >= 2 && !(part.first?.isNumber ?? false) {
                output.append(part)
            }
        }

        for byte in text.utf8 {
            if output.count >= limit { break }
            let isIdent = (byte >= 97 && byte <= 122) || (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95 || byte >= 0x80
            if isIdent {
                token.append(byte)
            } else if !token.isEmpty {
                emit()
            }
        }
        if !token.isEmpty { emit() }
        return output
    }

    /// Words that carry no search signal in natural-language questions about code.
    public static let questionStopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being", "am",
        "where", "what", "which", "who", "whom", "whose", "why", "how", "when",
        "do", "does", "did", "doing", "done", "can", "could", "should", "would", "will", "shall", "may", "might", "must",
        "i", "me", "my", "we", "our", "you", "your", "it", "its", "they", "them", "their", "this", "that", "these", "those",
        "of", "in", "on", "at", "to", "for", "from", "by", "with", "about", "into", "onto", "over", "under", "between",
        "and", "or", "but", "not", "no", "if", "then", "else", "so", "than", "too", "very", "just", "also",
        "any", "all", "some", "each", "every", "there", "here", "up", "down", "out",
        "code", "codebase", "repo", "repository", "project", "app", "application", "file", "files", "logic", "part", "parts",
        "find", "show", "tell", "list", "give", "get", "look", "see", "locate", "located", "implemented", "implement",
        "implementation", "handled", "handle", "handles", "happen", "happens", "responsible", "related", "involved",
        "place", "places", "thing", "things", "stuff", "use", "used", "uses", "using", "please", "defined", "define",
        "live", "lives", "work", "works", "working", "piece",
        // Question scaffolding: words that steer the answer's shape, never its subject.
        "whether", "has", "have", "had", "identify", "including", "include", "includes", "across", "overview",
        "describe", "explain", "other", "others", "via",
    ]

    /// The share of a repository's files a question word may appear in and still narrow the search. A word
    /// in more files than this (`wax` in the Wax repository) matches everything, so it is dropped, unless it is
    /// the question's only content word.
    public static let maximumWordShare = 0.4

    /// Keywords common to many languages; excluded from identifier vocabularies.
    public static let languageKeywords: Set<String> = [
        "func", "function", "def", "class", "struct", "enum", "protocol", "interface", "extension", "import", "export",
        "return", "let", "var", "const", "if", "else", "for", "while", "switch", "case", "default", "break", "continue",
        "true", "false", "nil", "null", "none", "self", "this", "super", "init", "new", "public", "private", "internal",
        "fileprivate", "open", "static", "final", "override", "async", "await", "throws", "throw", "try", "catch",
        "guard", "where", "in", "is", "as", "from", "type", "typealias", "lambda", "yield", "pass", "elif", "with",
        "not", "and", "or", "void", "undefined", "typeof", "instanceof", "string", "int", "bool", "double", "float",
    ]

    /// A light English stemmer used for matching query terms against identifier words
    /// (FTS5's porter tokenizer does the heavy lifting inside the index).
    public static func stem(_ word: String) -> String {
        var w = word.lowercased()
        guard w.count > 4 else { return w }
        let suffixes = ["ations", "ation", "ments", "ment", "ings", "ing", "ers", "er", "ies", "ied", "es", "ed", "ly", "s"]
        for suffix in suffixes where w.hasSuffix(suffix) && w.count - suffix.count >= 3 {
            w.removeLast(suffix.count)
            if suffix == "ies" || suffix == "ied" { w += "y" }
            break
        }
        return w
    }
}
