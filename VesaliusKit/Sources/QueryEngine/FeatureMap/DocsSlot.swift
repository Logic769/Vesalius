import Foundation
import RepositoryIndex
import VesaliusCore

/// One documentation section for a feature (its docs slot): the best `#` heading section of the Markdown files in
/// the folders of the feature's code (or among the search's Markdown matches), at most 12 lines, quoted and
/// labelled as possibly stale. Markdown is never ranked with code.
struct DocsSlot {
    let context: FeatureContext

    static let maximumLines = 12
    static let quotedLines = 5
    static let minimumScore = 3.0

    struct Section {
        let path: String
        let heading: String
        let lines: LineRange
        let score: Double
    }

    /// The best section near `anchors` (code paths) or in `candidates` (Markdown paths), nil when none is about the
    /// question.
    func best(near anchors: [String], candidates: [String], terms: [String: Double]) throws -> FeatureDocSection? {
        var paths = Set(candidates)
        var folders = Set<String>()
        for anchor in anchors {
            var folder = (anchor as NSString).deletingLastPathComponent
            for _ in 0..<2 {
                folders.insert(folder)
                guard !folder.isEmpty else { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        for folder in folders {
            let rows = try context.db.query(
                folder.isEmpty
                    ? "SELECT path FROM files WHERE language = 'markdown' AND path NOT LIKE '%/%'"
                    : "SELECT path FROM files WHERE language = 'markdown' AND path LIKE ? AND path NOT LIKE ?",
                folder.isEmpty ? [] : [folder + "/%", folder + "/%/%"]) { $0.string(0) }
            paths.formUnion(rows)
        }
        var best: Section?
        for path in paths.sorted() {
            for section in sections(path, terms: terms) where section.score > (best?.score ?? 0) {
                best = section
            }
        }
        guard let best, best.score >= Self.minimumScore else { return nil }
        return FeatureDocSection(path: best.path, heading: best.heading, lines: best.lines, quote: quote(best))
    }

    /// The heading sections of a Markdown file, scored by the question's terms: heading words count 3, body words
    /// 1, each term once. Long sections are cut to their first `maximumLines` lines.
    func sections(_ path: String, terms: [String: Double]) -> [Section] {
        guard let file = context.engine.sourceText.file(path) else { return [] }
        var headings: [(line: Int, level: Int, text: String)] = []
        var inFence = false
        for number in 1...max(1, file.lineCount) {
            guard let text = file.text(ofLine: number) else { continue }
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            guard !inFence, let match = text.wholeMatch(of: /(#{1,6})\s+(.+)/) else { continue }
            headings.append((number, match.1.count, String(match.2).trimmingCharacters(in: .whitespaces)))
        }
        var result: [Section] = []
        for (index, heading) in headings.enumerated() {
            let next = index + 1 < headings.count ? headings[index + 1].line - 1 : file.lineCount
            let end = min(next, heading.line + Self.maximumLines - 1)
            guard end > heading.line else { continue }
            let headingWords = QuestionWords.of(heading.text)
            var bodyWords: [String] = []
            for number in (heading.line + 1)...end {
                bodyWords += QuestionWords.of(file.text(ofLine: number) ?? "")
            }
            let headingScore = FeatureContext.match(headingWords, terms: terms) * 3
            let bodyScore = FeatureContext.match(Array(Set(bodyWords).subtracting(headingWords)), terms: terms)
            result.append(Section(path: path, heading: heading.text, lines: LineRange(heading.line, end), score: headingScore + bodyScore))
        }
        return result
    }

    /// The section's content lines (no heading, blank lines or fences), at most `quotedLines`.
    func quote(_ section: Section) -> [FeatureEvidence] {
        guard let file = context.engine.sourceText.file(section.path) else { return [] }
        var quoted: [FeatureEvidence] = []
        for number in (section.lines.start + 1)...section.lines.end where quoted.count < Self.quotedLines {
            guard let text = file.text(ofLine: number)?.trimmingCharacters(in: .whitespaces), !text.isEmpty, !text.hasPrefix("```") else { continue }
            quoted.append(FeatureEvidence(line: number, code: Statement.elide(Statement.collapse(text), to: 110, keeping: nil), kind: .step, primary: true))
        }
        return quoted
    }
}

/// Words of prose for matching question terms.
enum QuestionWords {
    static func of(_ text: String) -> [String] {
        var words: [String] = []
        for match in text.matches(of: /[A-Za-z][A-Za-z0-9]*/) {
            for part in Tokenizer.splitIdentifier(String(match.0)) where part.count >= 2 {
                words.append(part)
            }
            if Tokenizer.splitIdentifier(String(match.0)).count > 1 { words.append(String(match.0).lowercased()) }
        }
        return words
    }
}
