import Foundation

/// Approximate tokens of rendered text: one per 3 UTF-8 bytes, rounded up. The golden checks measure results
/// the same way, so a result that fits its budget here fits there.
public enum TokenEstimate {
    public static func of(_ text: String) -> Int {
        (text.utf8.count + 2) / 3
    }
}

/// How many tokens one tool result may use, and which page of it to show.
public struct Budget: Sendable, Hashable {
    public var tokens: Int
    /// 1-based.
    public var page: Int

    public init(tokens: Int, page: Int = 1) {
        self.tokens = max(1, tokens)
        self.page = max(1, page)
    }

    public static let usages = Budget(tokens: 1_500)
    public static let featureMap = Budget(tokens: 1_500)
    public static let cycles = Budget(tokens: 1_500)
    /// The target is about 1.3K; the limit leaves room for large Xcode projects.
    public static let architecture = Budget(tokens: 1_500)
    /// CLI `--full`: nothing is cut or paged.
    public static let unlimited = Budget(tokens: Int.max)

    /// An outline costs at most a fifth of reading the file, and never more than 2,000 tokens. Small files keep
    /// 150 tokens, enough for their declarations.
    public static func outline(fileCharacters: Int) -> Budget {
        Budget(tokens: min(2_000, max(150, fileCharacters / 15)))
    }

    public var isUnlimited: Bool { tokens == Int.max }

    public func page(_ page: Int) -> Budget {
        Budget(tokens: tokens, page: page)
    }
}

/// Line-number lists as results print them: `53,55,100`, consecutive runs as `148-153`, runs longer than six
/// lines with their count (`148-160 ×13`), so every listed line can be read back from the text. A counted run
/// stands on its own after the comma list (`53,55 148-160 ×13`): inside one it would read as two endpoints.
public enum LineList {
    public static func format(_ lines: [Int]) -> String {
        let sorted = Array(Set(lines)).sorted()
        var plain: [String] = []
        var counted: [String] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1] == sorted[end] + 1 { end += 1 }
            let run = end - index + 1
            switch run {
            case 1: plain.append("\(sorted[index])")
            case 2: plain.append("\(sorted[index]),\(sorted[end])")
            case 3...6: plain.append("\(sorted[index])-\(sorted[end])")
            default: counted.append("\(sorted[index])-\(sorted[end]) ×\(run)")
            }
            index = end + 1
        }
        return ((plain.isEmpty ? [] : [plain.joined(separator: ",")]) + counted).joined(separator: " ")
    }

    /// A long list as `first-last ×count` (for example "151-842 ×32"); short lists as `format`.
    public static func collapsed(_ lines: [Int], above limit: Int = 8) -> String {
        let unique = Array(Set(lines)).sorted()
        guard unique.count > limit, let first = unique.first, let last = unique.last else { return format(unique) }
        return "\(first)-\(last) ×\(unique.count)"
    }
}

/// Shortens one line of code by cutting its middle, so both ends (usually the receiver and the call) stay visible.
public enum Elide {
    public static let codeLimit = 110

    public static func middle(_ text: String, limit: Int = codeLimit) -> String {
        guard text.count > limit, limit >= 8 else { return text }
        let head = (limit - 1) * 3 / 5
        let tail = limit - 1 - head
        let start = text.prefix(head).trimmingCharacters(in: .whitespaces)
        let end = text.suffix(tail).trimmingCharacters(in: .whitespaces)
        return start + "…" + end
    }
}
