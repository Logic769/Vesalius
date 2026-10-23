import Foundation

/// Fits a `RenderDocument` into its token budget. The cuts are tried in order, each on top of
/// the ones before, until the whole result fits:
/// 1. repeated identical code in a file prints `·136 same`;
/// 2. secondary sites print only their lines (`also at 104,136 151-842 ×32`);
/// 3. at most 5 sites per file, then `+N more`;
/// 4. test files on one line.
/// If it still does not fit, blocks are paged: the page ends with `showing X of Y files · more: <call>`. Head,
/// completeness, unresolved sites and tail lines are never cut, and appear on every page.
public enum Budgeter {
    public enum Cut: Int, CaseIterable, Comparable, Sendable {
        case none, sameCode, lineLists, fiveSites, testsOneLine

        public static func < (a: Cut, b: Cut) -> Bool { a.rawValue < b.rawValue }
    }

    public static let sitesPerFile = 5
    /// Secondary code is shortened harder than a primary statement: it is a reminder, not the evidence.
    static let secondaryCodeLimit = 60

    public static func render(_ document: RenderDocument, budget: Budget) -> String {
        let top = topLines(document)
        if budget.isUnlimited {
            return join(top + document.blocks.flatMap { lines($0, cut: .none) } + document.tail)
        }
        var blocks: [[String]] = []
        for cut in Cut.allCases {
            blocks = document.blocks.map { lines($0, cut: cut) }
            if cost(top + blocks.flatMap { $0 } + document.tail) <= budget.tokens { break }
        }
        let fixed = cost(top + document.tail) + cost([footer(document, shown: 999...999, total: 999, page: 999, pages: 1_000)])
        let pages = paginate(blocks.map(blockCost), fixed: fixed, budget: budget.tokens)
        if pages.count <= 1 && budget.page == 1 {
            return join(top + blocks.flatMap { $0 } + document.tail)
        }
        guard budget.page <= pages.count else {
            let note = "page \(budget.page) is past the end: \(pages.count) page\(pages.count == 1 ? "" : "s") of \(document.blocks.count) \(document.unit)"
            return join(top + [note] + document.tail)
        }
        let range = pages[budget.page - 1]
        let shown = (range.lowerBound + 1)...range.upperBound
        return join(top + blocks[range].flatMap { $0 } + document.tail
            + [footer(document, shown: shown, total: blocks.count, page: budget.page, pages: pages.count)])
    }

    // MARK: Parts

    static func topLines(_ document: RenderDocument) -> [String] {
        var lines = document.head
        if let completeness = document.completeness {
            if lines.count >= 2 { lines[1] += " · " + completeness } else { lines.append(completeness) }
        }
        return lines + document.unresolved
    }

    static func footer(_ document: RenderDocument, shown: ClosedRange<Int>, total: Int, page: Int, pages: Int) -> String {
        let span = shown.lowerBound == 1 ? "\(shown.upperBound)" : "\(shown.lowerBound)-\(shown.upperBound)"
        var line = "showing \(span) of \(total) \(document.unit)"
        if page < pages {
            line += document.more.map { " · more: " + $0.call(page: page + 1) } ?? ""
        } else {
            line += " (last page)"
        }
        return line
    }

    /// Greedy pages of whole blocks; every page holds at least one block.
    static func paginate(_ costs: [Int], fixed: Int, budget: Int) -> [Range<Int>] {
        var pages: [Range<Int>] = []
        var start = 0
        var used = fixed
        for (index, size) in costs.enumerated() {
            if index > start && used + size > budget {
                pages.append(start..<index)
                start = index
                used = fixed
            }
            used += size
        }
        if start < costs.count { pages.append(start..<costs.count) }
        return pages
    }

    // MARK: One block

    static func lines(_ block: FileBlock, cut: Cut) -> [String] {
        var first = block.path + (block.header ?? "")
        if !block.labels.isEmpty { first += "  " + block.labels.joined(separator: " ") }
        if cut >= .testsOneLine && block.isTest {
            let all = block.members.flatMap { $0.sites.map(\.line) }
            return [all.isEmpty ? first : first + "  " + LineList.collapsed(all)]
        }
        var out = [first]
        var remaining = cut >= .fiveSites ? sitesPerFile : Int.max
        var dropped = 0
        var seen = Set<String>()
        for member in block.members {
            let kept = Array(member.sites.prefix(max(0, remaining)))
            dropped += member.sites.count - kept.count
            remaining -= kept.count
            if kept.isEmpty && !member.sites.isEmpty { continue }
            let indent = member.heading == nil ? "  " : "    "
            if let heading = member.heading { out.append("  " + heading) }
            var secondary: [(line: Int, code: String?)] = []
            for site in kept {
                let key = site.code.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let repeated = cut >= .sameCode && !key.isEmpty && !seen.insert(key).inserted
                if site.primary && !key.isEmpty && !repeated {
                    out += primaryLines(site, indent: indent)
                } else {
                    secondary.append((site.line, repeated ? "same" : (key.isEmpty ? nil : site.code)))
                }
            }
            if !secondary.isEmpty {
                if cut >= .lineLists {
                    out.append(indent + "also at " + LineList.collapsed(secondary.map(\.line)))
                } else {
                    out.append(indent + secondary.map { item in
                        "·\(item.line)" + (item.code.map { " " + Elide.middle(firstLine($0), limit: secondaryCodeLimit) } ?? "")
                    }.joined(separator: " "))
                }
            }
            out += member.trailer.map { indent + $0 }
        }
        if dropped > 0 { out.append("  +\(dropped) more") }
        return out
    }

    static func primaryLines(_ site: Site, indent: String) -> [String] {
        let rows = site.code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return rows.enumerated().map { offset, row in
            var text = "\(indent)\(site.line + offset) │ \(Elide.middle(row.trimmingCharacters(in: .whitespaces)))"
            if offset == rows.count - 1, let note = site.note { text += "  " + note }
            return text
        }
    }

    static func firstLine(_ code: String) -> String {
        code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    // MARK: Measuring

    static func cost(_ lines: [String]) -> Int {
        guard !lines.isEmpty else { return 0 }
        let bytes = lines.reduce(lines.count - 1) { $0 + $1.utf8.count }
        return (bytes + 2) / 3
    }

    static func blockCost(_ block: [String]) -> Int {
        // A block also costs the newline that joins it to the text before it.
        (block.reduce(block.count) { $0 + $1.utf8.count } + 2) / 3
    }

    static func join(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }
}
