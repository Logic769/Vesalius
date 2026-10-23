import Foundation

/// One compiled line of a `.gitignore`-syntax file.
public struct IgnorePattern: Sendable, Hashable {
    public let raw: String
    let pattern: [UInt8]
    public let isNegated: Bool
    public let directoryOnly: Bool
    /// Anchored patterns contain a slash (other than a trailing one) and match against the path relative
    /// to the ignore file's directory; unanchored patterns match any path component.
    public let isAnchored: Bool

    /// Parses a gitignore line. Returns nil for blank lines and comments.
    public init?(line: String) {
        var text = line
        if text.hasSuffix("\r") { text.removeLast() }
        // Trailing unescaped spaces are ignored.
        while text.hasSuffix(" ") && !text.hasSuffix("\\ ") { text.removeLast() }
        if text.hasSuffix("\\ ") { text = String(text.dropLast(2)) + " " }
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }

        var negated = false
        if text.hasPrefix("!") {
            negated = true
            text.removeFirst()
        } else if text.hasPrefix("\\!") || text.hasPrefix("\\#") {
            text.removeFirst()
        }
        var directoryOnly = false
        if text.hasSuffix("/") {
            directoryOnly = true
            while text.hasSuffix("/") { text.removeLast() }
        }
        guard !text.isEmpty else { return nil }

        var anchored = text.contains("/")
        if text.hasPrefix("/") {
            text.removeFirst()
            anchored = true
        }
        // A leading "**/" means "in any directory", which is the unanchored behaviour.
        if text.hasPrefix("**/") && !text.dropFirst(3).contains("/") {
            text.removeFirst(3)
            anchored = false
        }
        guard !text.isEmpty else { return nil }

        self.raw = line
        self.pattern = Array(text.utf8)
        self.isNegated = negated
        self.directoryOnly = directoryOnly
        self.isAnchored = anchored
    }

    /// Tests a path relative to the ignore file's directory.
    public func matches(relativePath: String, isDirectory: Bool) -> Bool {
        if directoryOnly && !isDirectory { return false }
        if isAnchored {
            return GlobMatcher.match(pattern, Array(relativePath.utf8))
        }
        let name: Substring
        if let slash = relativePath.lastIndex(of: "/") {
            name = relativePath[relativePath.index(after: slash)...]
        } else {
            name = Substring(relativePath)
        }
        return GlobMatcher.match(pattern, Array(name.utf8))
    }
}

/// Patterns loaded from one ignore file, scoped to the directory containing it.
public struct IgnoreRuleSet: Sendable {
    /// Repository-relative directory the rules apply to ("" for the root).
    public let baseDirectory: String
    public let patterns: [IgnorePattern]

    public init(baseDirectory: String, patterns: [IgnorePattern]) {
        self.baseDirectory = baseDirectory
        self.patterns = patterns
    }

    public init(baseDirectory: String, contents: String) {
        self.baseDirectory = baseDirectory
        self.patterns = contents.split(separator: "\n", omittingEmptySubsequences: false).compactMap { IgnorePattern(line: String($0)) }
    }

    /// Returns `true` (ignore), `false` (explicitly re-included) or `nil` (no opinion).
    public func decision(forRepositoryPath path: String, isDirectory: Bool) -> Bool? {
        let relative: String
        if baseDirectory.isEmpty {
            relative = path
        } else if path.hasPrefix(baseDirectory + "/") {
            relative = String(path.dropFirst(baseDirectory.count + 1))
        } else {
            return nil
        }
        var result: Bool?
        for pattern in patterns where pattern.matches(relativePath: relative, isDirectory: isDirectory) {
            result = !pattern.isNegated
        }
        return result
    }
}

/// Evaluates a stack of rule sets with git precedence: deeper ignore files override shallower ones and
/// later lines override earlier ones.
public struct IgnoreStack: Sendable {
    public private(set) var ruleSets: [IgnoreRuleSet]

    public init(_ ruleSets: [IgnoreRuleSet] = []) {
        self.ruleSets = ruleSets
    }

    public mutating func push(_ ruleSet: IgnoreRuleSet) {
        ruleSets.append(ruleSet)
    }

    public func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for ruleSet in ruleSets {
            if let decision = ruleSet.decision(forRepositoryPath: path, isDirectory: isDirectory) {
                ignored = decision
            }
        }
        return ignored
    }
}

/// gitignore-style glob matching: `*` and `?` never match `/`, `**` matches across directories,
/// `[a-z]`/`[!abc]` character classes and backslash escapes are supported.
enum GlobMatcher {
    private static let slash = UInt8(ascii: "/")
    private static let star = UInt8(ascii: "*")
    private static let question = UInt8(ascii: "?")
    private static let open = UInt8(ascii: "[")
    private static let close = UInt8(ascii: "]")
    private static let backslash = UInt8(ascii: "\\")

    static func match(_ pattern: [UInt8], _ text: [UInt8]) -> Bool {
        match(pattern, 0, text, 0)
    }

    private static func match(_ p: [UInt8], _ pStart: Int, _ s: [UInt8], _ sStart: Int) -> Bool {
        var pi = pStart
        var si = sStart
        while pi < p.count {
            let c = p[pi]
            if c == star {
                if pi + 1 < p.count && p[pi + 1] == star {
                    pi += 2
                    if pi < p.count && p[pi] == slash {
                        // "**/" matches zero or more whole directories.
                        pi += 1
                        if match(p, pi, s, si) { return true }
                        var k = si
                        while k < s.count {
                            if s[k] == slash && match(p, pi, s, k + 1) { return true }
                            k += 1
                        }
                        return false
                    }
                    if pi == p.count { return true }
                    var k = si
                    while k <= s.count {
                        if match(p, pi, s, k) { return true }
                        k += 1
                    }
                    return false
                }
                pi += 1
                var k = si
                while k <= s.count {
                    if match(p, pi, s, k) { return true }
                    if k < s.count && s[k] == slash { break }
                    k += 1
                }
                return false
            } else if c == question {
                guard si < s.count, s[si] != slash else { return false }
                pi += 1
                si += 1
            } else if c == open, let (matched, next) = matchClass(p, pi, si < s.count ? s[si] : nil) {
                guard matched else { return false }
                pi = next
                si += 1
            } else {
                var literal = c
                if c == backslash && pi + 1 < p.count {
                    pi += 1
                    literal = p[pi]
                }
                guard si < s.count, s[si] == literal else { return false }
                pi += 1
                si += 1
            }
        }
        return si == s.count
    }

    /// Matches a `[...]` class starting at `start`. Returns nil when the bracket is not a valid class
    /// (then it is treated literally).
    private static func matchClass(_ p: [UInt8], _ start: Int, _ ch: UInt8?) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count && (p[i] == UInt8(ascii: "!") || p[i] == UInt8(ascii: "^")) {
            negate = true
            i += 1
        }
        var matched = false
        var first = true
        while i < p.count && (p[i] != close || first) {
            first = false
            var low = p[i]
            if low == backslash && i + 1 < p.count {
                i += 1
                low = p[i]
            }
            if i + 2 < p.count && p[i + 1] == UInt8(ascii: "-") && p[i + 2] != close {
                let high = p[i + 2]
                if let ch, ch >= low && ch <= high { matched = true }
                i += 3
            } else {
                if let ch, ch == low { matched = true }
                i += 1
            }
        }
        guard i < p.count else { return nil }
        guard let ch, ch != slash else { return (false, i + 1) }
        _ = ch
        return (negate ? !matched : matched, i + 1)
    }
}
