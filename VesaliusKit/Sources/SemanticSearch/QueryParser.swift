import Foundation
import NaturalLanguage
import VesaliusCore

/// What a natural-language question is asking for.
public enum QueryIntent: String, Sendable, Codable {
    case search
    case dependents
    case dependencies
    case references
    case callers
    case callees
    case impact
}

public struct ParsedQuery: Sendable {
    public var original: String
    public var intent: QueryIntent
    /// The entity a structural question is about (`User`, `SettingsView.swift`).
    public var subject: String?
    /// Content words of the question (lowercase, stop words removed).
    public var words: [String]
    /// Identifier-looking tokens exactly as typed (`BookFormatter`, `refresh_token`).
    public var identifiers: [String]
    /// Weighted search terms after expansion.
    public var terms: [String: Double]
    public var mentionsTests: Bool
    /// Frameworks the question names (`StoreKit`) or implies through a phrase ("in-app purchases"), kept whole.
    public var frameworks: [String] = []
    /// Acronyms of capitalised runs that the repository uses: `Cloud Sync Gateway` → `csg`.
    public var acronyms: [String: String] = [:]
    /// Labels of the phrases matched (`at rest`, `in-app purchases`).
    public var phrases: [String] = []
    /// The question's subjects in order: phrases, frameworks, acronyms and content words. Coverage counts these.
    public var units: [String] = []
    /// Which unit each term stands for (`entitlement` → `premium access`).
    public var origins: [String: String] = [:]
    /// A phrase asks for a flow ("the code path that writes").
    public var isFlow = false
    /// The question is about demo or sample code, so it is not ranked down.
    public var mentionsDemo = false
    /// The question is about analytics, so analytics-only files are not ranked down.
    public var mentionsAnalytics = false
}

public enum QueryParser {
    private static var structuralPatterns: [(QueryIntent, [Regex<(Substring, Substring)>])] { [
        (.impact, [
            /(?i)(?:impact|blast radius|consequences?|risk)\s+(?:of\s+)?(?:changing|modifying|editing|touching|removing|deleting)?\s*`?([\w.\/\-]+)`?/,
            /(?i)what (?:breaks|would break|is affected|gets affected)\s+(?:if|when)\s+(?:i|we)?\s*(?:change|modify|edit|remove|delete|touch)\s+`?([\w.\/\-]+)`?/,
            /(?i)(?:if|when)\s+(?:i|we)\s+(?:change|modify|edit)\s+`?([\w.\/\-]+)`?\s*,?\s*what/,
        ]),
        (.dependents, [
            /(?i)(?:what|which|who)\s+(?:files?\s+|code\s+|things?\s+|modules?\s+)?(?:depends?|relies|rely)\s+on\s+`?([\w.\/\-]+)`?/,
            /(?i)(?:things|files|code|everything|what)\s+(?:that\s+)?(?:depends?|relies|rely)\s+on\s+`?([\w.\/\-]+)`?/,
            /(?i)(?:dependents|importers|consumers)\s+of\s+`?([\w.\/\-]+)`?/,
            /(?i)(?:who|what|which files?)\s+(?:imports?|uses?)\s+`?([\w.\/\-]+)`?/,
        ]),
        (.dependencies, [
            /(?i)what\s+does\s+`?([\w.\/\-]+)`?\s+(?:depend on|import|use|need|require)/,
            /(?i)(?:dependencies|imports)\s+of\s+`?([\w.\/\-]+)`?/,
        ]),
        (.callers, [
            /(?i)(?:who|what|which\s+\w+)\s+calls?\s+`?([\w.]+)`?/,
            /(?i)callers?\s+of\s+`?([\w.]+)`?/,
            /(?i)where\s+is\s+`?([\w.]+)`?\s+called/,
        ]),
        (.callees, [
            /(?i)what\s+does\s+`?([\w.]+)`?\s+call/,
            /(?i)callees\s+of\s+`?([\w.]+)`?/,
        ]),
        (.references, [
            /(?i)where\s+is\s+`?([\w.\/\-]+)`?\s+(?:used|referenced|instantiated|accessed)/,
            /(?i)(?:usages?|references?|uses)\s+(?:of|to)\s+`?([\w.\/\-]+)`?/,
            /(?i)find\s+(?:all\s+)?(?:usages?|references?)\s+(?:of\s+)?`?([\w.\/\-]+)`?/,
        ]),
    ] }

    /// File extensions that make a question token a file name (`AuthService.swift`).
    static let fileExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "m", "mm", "h", "c", "cpp", "kt", "java", "go", "rs",
        "rb", "json", "md", "yml", "yaml", "plist", "storekit", "xcscheme", "xctestplan", "pbxproj",
    ]

    /// Most completions kept per out-of-vocabulary word.
    static let completionLimit = 3

    /// Parses a question: question scaffolding and phrases are matched before tokenising, framework names
    /// stay whole, capitalised runs become the repository's acronym for them, and only words the repository does
    /// not use are completed or expanded with embedding neighbours.
    ///
    /// `externalModules` are the repository's `imports.external_name` values: with the built-in framework names
    /// they decide which tokens are frameworks.
    public static func parse(_ question: String, vocabulary: Vocabulary? = nil, useEmbeddings: Bool = true, externalModules: [String] = []) -> ParsedQuery {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var intent = QueryIntent.search
        var subject: String?
        outer: for (candidateIntent, patterns) in structuralPatterns {
            for pattern in patterns {
                if let match = trimmed.firstMatch(of: pattern) {
                    let value = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "?.,`'\""))
                    if !value.isEmpty, !Tokenizer.questionStopWords.contains(value.lowercased()) {
                        intent = candidateIntent
                        subject = value
                        break outer
                    }
                }
            }
        }

        var scan = QuestionScan(trimmed)
        var identifiers = scan.backticked
        scan.maskMetaPhrases()
        let phrases = scan.matchPhrases()
        let frameworks = scan.matchFrameworks(externalModules: externalModules)
        let acronyms = vocabulary.map { scan.matchAcronyms(vocabulary: $0) } ?? []

        // Identifier-looking tokens as typed: inner capitals, `_`, dotted names and file names. Never a
        // sentence-initial capital or a short all-caps word (`Where`, `List`, `ID`, `API`).
        for token in scan.identifierTokens() where !identifiers.contains(token) {
            identifiers.append(token)
        }

        // Content words: what is left after scaffolding, phrases, frameworks and acronyms.
        var expandable: [String] = []
        var plain: [String] = []
        for token in scan.tokens where token.state == .content || token.state == .kept {
            let parts = Tokenizer.splitIdentifier(token.text).filter { $0.count >= 2 && !Tokenizer.questionStopWords.contains($0) }
            var found = parts
            if Tokenizer.splitIdentifier(token.text).count > 1 { found.append(token.text.lowercased()) }
            for word in found {
                if token.state == .kept || token.noExpansion {
                    if !plain.contains(word) { plain.append(word) }
                } else if !expandable.contains(word) {
                    expandable.append(word)
                }
            }
        }
        plain.removeAll { expandable.contains($0) }

        // A word in too many files narrows nothing (`wax` in Wax); keep at least one content word.
        if let vocabulary {
            let common = { (word: String) in Double(vocabulary.frequencies[word] ?? 0) / Double(vocabulary.documentCount) > Tokenizer.maximumWordShare }
            let narrowing = (expandable + plain).filter { !common($0) }
            if !narrowing.isEmpty || !phrases.isEmpty || !frameworks.isEmpty || !acronyms.isEmpty {
                expandable.removeAll(where: common)
                plain.removeAll(where: common)
            }
        }

        var terms: [String: Double] = [:]
        var origins: [String: String] = [:]
        var units: [String] = []
        func add(_ term: String, _ weight: Double, origin: String) {
            let key = term.lowercased()
            guard !key.isEmpty else { return }
            if weight > (terms[key] ?? 0) {
                terms[key] = weight
                origins[key] = origin
            } else if origins[key] == nil {
                origins[key] = origin
            }
        }
        for phrase in phrases {
            if !units.contains(phrase.label) { units.append(phrase.label) }
            for term in phrase.terms { add(term, 0.8, origin: phrase.label) }
        }
        var frameworkNames: [String] = []
        for framework in frameworks + phrases.flatMap(\.frameworks) where !frameworkNames.contains(framework) {
            frameworkNames.append(framework)
        }
        for framework in frameworks {
            if !units.contains(framework) { units.append(framework) }
            add(framework.lowercased().replacingOccurrences(of: " ", with: ""), 1.0, origin: framework)
        }
        var acronymMap: [String: String] = [:]
        for acronym in acronyms {
            acronymMap[acronym.phrase] = acronym.acronym
            if !units.contains(acronym.acronym) { units.append(acronym.acronym) }
            add(acronym.acronym, 1.0, origin: acronym.acronym)
        }
        for word in plain {
            if !units.contains(word) { units.append(word) }
            add(word, 1.0, origin: word)
            let stem = Tokenizer.stem(word)
            if stem != word { add(stem, 0.9, origin: word) }
        }
        for word in expandable {
            if !units.contains(word) { units.append(word) }
            for (term, weight) in ConceptLexicon.expand([word]) { add(term, weight, origin: word) }
        }

        let words = expandable + plain + frameworks.map { $0.lowercased().replacingOccurrences(of: " ", with: "") } + acronyms.map(\.acronym)
        let mentionsTests = words.contains { ["test", "tests", "spec", "specs", "testing"].contains($0) }
        if let vocabulary {
            for word in expandable + plain where !vocabulary.contains(word) {
                for completion in vocabulary.completions(of: word, limit: completionLimit) where terms[completion] == nil {
                    add(completion, 0.7, origin: word)
                }
            }
            if useEmbeddings, let embedding = NLEmbedding.wordEmbedding(for: .english) {
                for word in expandable where word.count >= 4 && !vocabulary.contains(word) {
                    for (neighbor, distance) in embedding.neighbors(for: word, maximumCount: 12) where distance < 1.05 {
                        let candidate = neighbor.lowercased()
                        guard terms[candidate] == nil, vocabulary.contains(candidate), !Tokenizer.questionStopWords.contains(candidate) else { continue }
                        add(candidate, max(0.2, 0.42 - (distance - 0.75) * 0.6), origin: word)
                    }
                }
            }
            // Expansion terms the repository never uses only add noise; the question's own words always stay.
            let own = Set(words)
            terms = terms.filter { own.contains($0.key) || vocabulary.contains($0.key) || vocabulary.contains(Tokenizer.stem($0.key)) }
            origins = origins.filter { terms[$0.key] != nil }
        }

        var parsed = ParsedQuery(original: trimmed, intent: intent, subject: subject, words: words, identifiers: identifiers, terms: terms, mentionsTests: mentionsTests)
        parsed.frameworks = frameworkNames
        parsed.acronyms = acronymMap
        parsed.phrases = phrases.map(\.label)
        parsed.units = units
        parsed.origins = origins
        parsed.isFlow = phrases.contains { $0.isFlow }
        parsed.mentionsDemo = words.contains { ["demo", "demos", "example", "examples", "sample", "samples", "playground"].contains($0) }
        let analytics = ConceptLexicon.concepts.first { $0.name == "analytics" }
        parsed.mentionsAnalytics = words.contains { $0 == "analytics" || (analytics?.terms.prefix(6).contains($0) ?? false) }
        return parsed
    }
}

/// One pass over a question's words: which are scaffolding, which belong to a phrase, a framework name or an
/// acronym, and which are left as content.
struct QuestionScan {
    enum State: Equatable {
        case content
        /// Scaffolding ("list the key files").
        case masked
        /// Covered by a phrase, a framework name or an acronym: not a word of its own.
        case consumed
        /// A phrase word that stays a search word, without concept expansion.
        case kept
    }

    struct Token {
        let text: String
        let lower: String
        let range: Range<String.Index>
        /// The first word of a sentence.
        let isSentenceStart: Bool
        var state = State.content
        /// Part of a proper name (a capitalised run): no concept expansion.
        var noExpansion = false
    }

    let text: String
    /// The text with backticked spans blanked out.
    let plainText: String
    var tokens: [Token] = []
    var backticked: [String] = []

    init(_ text: String) {
        self.text = text
        var plain = text
        var quoted: [String] = []
        for match in text.matches(of: /`([^`]+)`/).reversed() {
            var value = String(match.1).trimmingCharacters(in: .whitespaces)
            if value.hasSuffix("()") { value.removeLast(2) }
            if !value.isEmpty { quoted.insert(value, at: 0) }
            plain.replaceSubrange(match.range, with: String(repeating: " ", count: text[match.range].count))
        }
        plainText = plain
        backticked = quoted
        var sentenceStart = true
        var cursor = plain.startIndex
        for match in plain.matches(of: /[A-Za-z0-9_]+/) {
            let gap = plain[cursor..<match.range.lowerBound]
            if gap.contains(where: { ".?!:;\n".contains($0) }) { sentenceStart = true }
            let word = String(match.0)
            tokens.append(Token(text: word, lower: word.lowercased(), range: match.range, isSentenceStart: sentenceStart))
            sentenceStart = false
            cursor = match.range.upperBound
        }
    }

    /// Indices of `words` matched in order over content tokens from `start`; the last word may be plural.
    private func match(_ words: [String], at start: Int, states: Set<State>) -> [Int]? {
        var index = start
        var found: [Int] = []
        for (offset, word) in words.enumerated() {
            guard index < tokens.count, states.contains(tokens[index].state) else { return nil }
            let token = tokens[index].lower
            let isLast = offset == words.count - 1
            guard token == word || (isLast && (token == word + "s" || token == word + "es")) else { return nil }
            found.append(index)
            index += 1
        }
        return found
    }

    mutating func maskMetaPhrases() {
        for phrase in ConceptLexicon.metaPhrases {
            var start = 0
            while start < tokens.count {
                if let hit = match(phrase, at: start, states: [.content]) {
                    for index in hit { tokens[index].state = .masked }
                    start = (hit.last ?? start) + 1
                } else {
                    start += 1
                }
            }
        }
    }

    /// Matches the phrase lexicon, longest phrases first; covered words are consumed unless the phrase keeps them.
    mutating func matchPhrases() -> [ConceptLexicon.Phrase] {
        var matched: [ConceptLexicon.Phrase] = []
        for phrase in ConceptLexicon.phrases.sorted(by: { $0.words.count > $1.words.count }) {
            var start = 0
            while start < tokens.count {
                if let hit = match(phrase.words, at: start, states: [.content]) {
                    for index in hit {
                        let keep = phrase.keptWords.contains(tokens[index].lower) && !Tokenizer.questionStopWords.contains(tokens[index].lower)
                        tokens[index].state = keep ? .kept : .consumed
                    }
                    if !matched.contains(where: { $0.label == phrase.label }) { matched.append(phrase) }
                    start = (hit.last ?? start) + 1
                } else {
                    start += 1
                }
            }
        }
        return matched
    }

    /// Framework names kept whole (`StoreKit`, `SwiftData`, `node:crypto`): their parts are not words.
    mutating func matchFrameworks(externalModules: [String]) -> [String] {
        var modules = Set(ConceptFrameworks.names.keys)
        for module in externalModules { modules.insert(module) }
        var byLower: [String: String] = [:]
        for module in modules { byLower[module.lowercased()] = module }
        for module in externalModules { byLower[module.lowercased()] = module }
        var found: [String] = []
        for match in plainText.matches(of: /[A-Za-z@][A-Za-z0-9_.:\/@-]*[A-Za-z0-9]|[A-Za-z]/) {
            let raw = String(match.0)
            for candidate in [raw, raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))] {
                guard let module = byLower[candidate.lowercased()], ConceptFrameworks.token(candidate, names: module) else { continue }
                let name = ConceptFrameworks.displayName(module) == module && externalModules.contains(module) ? module : ConceptFrameworks.displayName(module)
                if !found.contains(name) { found.append(name) }
                for index in tokens.indices where tokens[index].range.overlaps(match.range) && tokens[index].state != .masked {
                    tokens[index].state = .consumed
                }
                break
            }
        }
        return found
    }

    /// Runs of capitalised words (`Cloud Sync Gateway`) whose initials the repository uses as a word (`csg`).
    /// The run's words become the acronym; leftover words of the run stay words without concept expansion.
    mutating func matchAcronyms(vocabulary: Vocabulary) -> [(phrase: String, acronym: String)] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for index in tokens.indices {
            let token = tokens[index]
            let capitalised = token.text.first?.isUppercase == true
            let eligible = capitalised && token.state == .content && !(token.isSentenceStart && Tokenizer.questionStopWords.contains(token.lower))
            let adjacent = current.last.map { previous in
                text[tokens[previous].range.upperBound..<token.range.lowerBound].allSatisfy { $0 == " " }
            } ?? true
            if eligible && adjacent {
                current.append(index)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = eligible ? [index] : []
            }
        }
        if current.count >= 2 { runs.append(current) }

        var found: [(phrase: String, acronym: String)] = []
        for run in runs {
            for index in run { tokens[index].noExpansion = true }
            var start = 0
            while start < run.count - 1 {
                var matchedEnd: Int?
                for end in stride(from: run.count - 1, through: start + 1, by: -1) {
                    let initials = run[start...end].compactMap { tokens[$0].lower.first }.map(String.init).joined()
                    if initials.count >= 3, (vocabulary.frequencies[initials] ?? 0) >= 2 {
                        let phrase = run[start...end].map { tokens[$0].text }.joined(separator: " ")
                        found.append((phrase, initials))
                        for index in run[start...end] { tokens[index].state = .consumed }
                        matchedEnd = end
                        break
                    }
                }
                start = (matchedEnd ?? start) + 1
            }
        }
        return found
    }

    /// Tokens that look like identifiers as typed: inner capitals with lower case (`BookFormatter`), `_`, a dotted
    /// name or a file name; never a framework, a sentence-initial capital or a short all-caps word.
    func identifierTokens() -> [String] {
        var result: [String] = []
        for match in plainText.matches(of: /[A-Za-z_][\w.]*[A-Za-z0-9_]/) {
            let token = String(match.0)
            let covered = tokens.filter { $0.range.overlaps(match.range) }
            if covered.contains(where: { $0.state == .consumed || $0.state == .masked }) { continue }
            let letters = token.filter(\.isLetter)
            let hasLower = letters.contains { $0.isLowercase }
            let innerCapital = hasLower && token.dropFirst().contains { $0.isUppercase }
            let underscore = token.contains("_") && token.count > 2
            let ext = (token as NSString).pathExtension.lowercased()
            let fileName = token.contains(".") && QueryParser.fileExtensions.contains(ext)
            let dotted = token.contains(".") && !fileName && token.split(separator: ".").count >= 2
                && token.split(separator: ".").allSatisfy { $0.first?.isLetter == true || $0.first == "_" }
                && token.contains { $0.isUppercase }
            if innerCapital || underscore || fileName || dotted {
                if !result.contains(token) { result.append(token) }
            }
        }
        return result
    }
}
