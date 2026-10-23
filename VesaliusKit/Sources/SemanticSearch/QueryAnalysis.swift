import Foundation
import VesaliusCore

/// A feature question taken apart for `feature_map`: the parsed search query plus the roles the
/// question lists in its own order, the concepts and frameworks it names, and whether it asks for a flow.
public struct QuestionAnalysis: Sendable {
    /// One thing the question wants found ("loading products", "restoring purchases").
    public struct Role: Sendable, Hashable {
        /// How results name it: `load`, `buy`, `restore`, `premium access`, `at rest`.
        public let label: String
        /// The question's words for it.
        public let text: String
        /// Identifier words that mark a member as playing the role, weighted: its own words 1.0, their stems 0.9,
        /// phrase terms 0.8 and the head verb's synonyms 0.6.
        public let terms: [String: Double]

        public init(label: String, text: String, terms: [String: Double]) {
            self.label = label
            self.text = text
            self.terms = terms
        }
    }

    public let question: String
    public let parsed: ParsedQuery
    public let roles: [Role]
    /// `ConceptLexicon` concepts and phrase labels the question triggers (`payments`, `at rest`).
    public let concepts: [String]
    /// "How does X persist/write/commit…" or "the code path that…": the flow verbs in question order, as base
    /// forms (`persist`, `write`, `commit`). Empty when the question does not ask for a flow.
    public let flowVerbs: [String]

    public var isFlow: Bool { !flowVerbs.isEmpty }
    public var frameworks: [String] { parsed.frameworks }
    public var acronyms: [String: String] { parsed.acronyms }

    /// Search terms with their weights, the roles' terms included.
    public var allTerms: [String: Double] {
        var terms = parsed.terms
        for role in roles {
            for (term, weight) in role.terms where weight > (terms[term] ?? 0) { terms[term] = weight }
        }
        return terms
    }

    /// The feature in the question's words: its phrases, frameworks, acronyms and first content words.
    public var featureLabel: String {
        var parts: [String] = []
        for (phrase, acronym) in parsed.acronyms.sorted(by: { $0.key < $1.key }) { parts.append("\(phrase) (\(acronym))") }
        for phrase in parsed.phrases where !parts.contains(phrase) { parts.append(phrase) }
        let roleWords = Set(roles.flatMap { $0.terms.keys })
        let covered = Set(parts.flatMap { Tokenizer.splitIdentifier($0) })
        for word in parsed.words where !roleWords.contains(word) && !covered.contains(word) && !parsed.acronyms.values.contains(word) {
            if parsed.frameworks.contains(where: { $0.lowercased().replacingOccurrences(of: " ", with: "") == word }) { continue }
            parts.append(word)
            if parts.count >= 4 { break }
        }
        return parts.isEmpty ? parsed.original : parts.prefix(4).joined(separator: ", ")
    }
}

public enum QuestionAnalyzer {
    /// Surface forms of the verbs a question uses to name what a feature does, by base form.
    static let verbs: [String: String] = {
        var map: [String: String] = [:]
        let table: [String: [String]] = [
            "store": ["store", "stores", "stored", "storing"], "save": ["save", "saves", "saved", "saving"],
            "persist": ["persist", "persists", "persisted", "persisting"], "write": ["write", "writes", "wrote", "written", "writing"],
            "read": ["read", "reads", "reading"], "load": ["load", "loads", "loaded", "loading"],
            "fetch": ["fetch", "fetches", "fetched", "fetching"], "buy": ["buy", "buys", "bought", "buying"],
            "restore": ["restore", "restores", "restored", "restoring"], "sync": ["sync", "syncs", "synced", "syncing", "synchronize"],
            "encrypt": ["encrypt", "encrypts", "encrypted", "encrypting"], "decrypt": ["decrypt", "decrypts", "decrypted", "decrypting"],
            "protect": ["protect", "protects", "protected", "protecting"], "validate": ["validate", "validates", "validated", "validating"],
            "authenticate": ["authenticate", "authenticates", "authenticated", "authenticating"],
            "send": ["send", "sends", "sent", "sending"], "upload": ["upload", "uploads", "uploaded", "uploading"],
            "download": ["download", "downloads", "downloaded", "downloading"], "render": ["render", "renders", "rendered", "rendering"],
            "parse": ["parse", "parses", "parsed", "parsing"], "schedule": ["schedule", "schedules", "scheduled", "scheduling"],
            "notify": ["notify", "notifies", "notified", "notifying"], "delete": ["delete", "deletes", "deleted", "deleting"],
            "remove": ["remove", "removes", "removed", "removing"], "create": ["create", "creates", "created", "creating"],
            "update": ["update", "updates", "updated", "updating"], "commit": ["commit", "commits", "committed", "committing"],
            "flush": ["flush", "flushes", "flushed", "flushing"], "decide": ["decide", "decides", "decided", "deciding"],
            "check": ["check", "checks", "checked", "checking"], "generate": ["generate", "generates", "generated", "generating"],
            "process": ["process", "processes", "processed", "processing"], "serialize": ["serialize", "serializes", "serialized", "serializing"],
            "encode": ["encode", "encodes", "encoded", "encoding"], "decode": ["decode", "decodes", "decoded", "decoding"],
            "verify": ["verify", "verifies", "verified", "verifying"], "import": ["import", "imports", "imported", "importing"],
            "export": ["export", "exports", "exported", "exporting"], "cancel": ["cancel", "cancels", "cancelled", "canceled", "cancelling"],
            "refresh": ["refresh", "refreshes", "refreshed", "refreshing"], "purchase": ["purchasing"],
            "track": ["track", "tracks", "tracked", "tracking"], "log": ["logging"], "cache": ["caching", "cached"],
        ]
        for (base, forms) in table {
            for form in forms { map[form] = base }
        }
        return map
    }()

    /// Verbs that only frame a role ("deciding whether the user has premium access" is about premium access).
    static let framingVerbs: Set<String> = ["decide", "check", "handle", "manage", "determine", "process"]

    /// Synonyms that start half of all function names (`getX`, `setX`): too weak to place a member in a role.
    static let weakVerbs: Set<String> = ["get", "set", "make", "do", "run", "new", "add"]

    /// Object words too general to tell members apart ("the user", "the data").
    static let genericWords: Set<String> = [
        "user", "users", "data", "value", "values", "item", "items", "info", "information", "state", "status", "type",
        "types", "thing", "object", "objects", "result", "results",
    ]

    /// Base forms whose `how … <verb>` asks for a flow.
    static let flowVerbSet: Set<String> = ["persist", "write", "commit", "save", "flush", "sync", "serialize", "encode", "store", "process"]

    public static func analyze(_ question: String, parsed: ParsedQuery) -> QuestionAnalysis {
        let roles = roles(in: parsed.original, parsed: parsed)
        return QuestionAnalysis(question: question, parsed: parsed, roles: roles, concepts: concepts(parsed), flowVerbs: flowVerbs(in: parsed.original, parsed: parsed))
    }

    /// The base form of a question word (`loading` → `load`), or the word.
    public static func lemma(_ word: String) -> String {
        let lower = word.lowercased()
        if let base = verbs[lower] { return base }
        if lower.hasSuffix("ing"), lower.count > 5 {
            let stem = String(lower.dropLast(3))
            if let base = verbs[stem] ?? verbs[stem + "e"] { return base }
            // Doubled final consonants drop one (`running` → `run`); `-ating`, `-izing`, `-uring`, `-ving`, `-cing`
            // and `-ging` restore their `e` (`estimating` → `estimate`).
            if let last = stem.last, stem.dropLast().last == last, !"aeiouls".contains(last) { return String(stem.dropLast()) }
            for ending in ["at", "iz", "ur", "v", "c", "g", "dat", "rat", "lat", "pos", "us", "ar"] where stem.hasSuffix(ending) {
                return stem + "e"
            }
            return stem
        }
        return lower
    }

    // MARK: Roles

    /// The roles a question lists, in its order: the items of a list after `:`, "including" or "such as"; else the
    /// verbs of its first sentence when it names two or more ("store and load … protected at rest").
    static func roles(in question: String, parsed: ParsedQuery) -> [QuestionAnalysis.Role] {
        let sentences = splitSentences(question)
        var items: [String] = []
        for sentence in sentences {
            if let list = listText(in: sentence) {
                items = splitList(list)
                break
            }
        }
        if items.count < 2 {
            items = verbItems(in: sentences.first ?? question, parsed: parsed)
        }
        guard items.count >= 2 else { return [] }
        let heads = items.map { headVerb(of: $0) }
        var roles: [QuestionAnalysis.Role] = []
        for (index, item) in items.enumerated() {
            let phrases = phrasesIn(item)
            // Phrase words a phrase does not keep are not role words ("rest" in "at rest").
            let dropped = Set(phrases.flatMap { phrase in phrase.words.filter { !phrase.keptWords.contains($0) } })
            let words = contentWords(item).filter { !dropped.contains($0) && !dropped.contains(Tokenizer.stem($0)) }
            guard !words.isEmpty || !phrases.isEmpty else { continue }
            var terms: [String: Double] = [:]
            func add(_ term: String, _ weight: Double) {
                let key = term.lowercased()
                if weight > (terms[key] ?? 0) { terms[key] = weight }
            }
            // The head verb says what the role does; its object weighs less, unless the verb only frames the
            // role ("deciding whether the user has premium access").
            let head = heads[index]
            let objectWeight = head == nil || framingVerbs.contains(head ?? "") ? 1.0 : 0.5
            for (position, word) in words.enumerated() {
                let isHead = position == 0 && head != nil && lemma(word) == head
                let weight = isHead ? 1.0 : genericWords.contains(word) ? 0.3 : objectWeight
                add(word, weight)
                let stem = Tokenizer.stem(word)
                if stem != word { add(stem, weight * 0.9) }
                let base = lemma(word)
                if base != word { add(base, weight) }
            }
            for phrase in phrases {
                for term in phrase.terms { add(term, 0.8) }
            }
            if let head, !framingVerbs.contains(head) {
                add(head, 1.0)
                let others = Set(heads.enumerated().compactMap { $0.offset == index ? nil : $0.element })
                for synonym in ConceptLexicon.synonyms[head] ?? [] where !others.contains(synonym) {
                    add(synonym, weakVerbs.contains(synonym) ? 0.3 : 0.6)
                }
            }
            let label: String
            if let phrase = phrases.first {
                label = phrase.label
            } else if let head = heads[index], !framingVerbs.contains(head) {
                label = head
            } else {
                label = words.last ?? item
            }
            if !roles.contains(where: { $0.label == label }) {
                roles.append(QuestionAnalysis.Role(label: label, text: item, terms: terms))
            }
        }
        return roles.count >= 2 ? roles : []
    }

    public static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "?" || character == "!" || character == "." {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    /// The list part of a sentence: after `:`, "including", "such as" or "like".
    static func listText(in sentence: String) -> String? {
        let lower = sentence.lowercased()
        for marker in [":", " including ", " such as "] {
            if let range = lower.range(of: marker) {
                let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
                let start = sentence.index(sentence.startIndex, offsetBy: offset)
                let list = sentence[start...].trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
                if !list.isEmpty { return list }
            }
        }
        return nil
    }

    /// `a, b, and c` → [a, b, c]; parenthesised asides stay with their item.
    static func splitList(_ list: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        for character in list {
            if character == "(" { depth += 1 }
            if character == ")" { depth = max(0, depth - 1) }
            if (character == "," || character == ";") && depth == 0 {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        var result: [String] = []
        for item in items {
            for part in item.components(separatedBy: " and ") + [] {
                var text = part.trimmingCharacters(in: .whitespaces)
                for lead in ["and ", "or "] where text.lowercased().hasPrefix(lead) { text = String(text.dropFirst(lead.count)) }
                text = text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { result.append(text) }
            }
        }
        return result
    }

    /// One item per role verb of the sentence ("store", "load", "protected at rest"): each verb with the words
    /// after it up to the next verb or comma. Verbs inside a proper name ("Cloud Sync Gateway") do not count.
    static func verbItems(in sentence: String, parsed: ParsedQuery) -> [String] {
        let tokens = sentence.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let properNames = Set(parsed.acronyms.keys.flatMap { $0.split(separator: " ").map(String.init) })
        var items: [String] = []
        var current: [String] = []
        var seen = Set<String>()
        for raw in tokens {
            let word = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            let closes = raw.hasSuffix(",") || raw.hasSuffix("?") || raw.hasSuffix(".")
            let isVerb = verbs[word.lowercased()] != nil && !properNames.contains(word) && !(word.first?.isUppercase ?? false && !current.isEmpty)
            if isVerb, let base = verbs[word.lowercased()], !seen.contains(base) {
                if !current.isEmpty { items.append(current.joined(separator: " ")) }
                current = [word]
                seen.insert(base)
            } else if !current.isEmpty {
                // A verb's object runs to the next verb; a comma ends it unless the object is still empty.
                if raw.hasPrefix("(") || (current.count > 1 && raw.first == "(") { continue }
                current.append(word)
            }
            if closes, !current.isEmpty {
                items.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { items.append(current.joined(separator: " ")) }
        // Each item keeps only its verb and the words that are not another subject of the sentence.
        return items.map { item in
            let words = item.split(separator: " ").map(String.init)
            guard let first = words.first else { return item }
            let rest = words.dropFirst().filter { word in
                let lower = word.lowercased()
                return !Tokenizer.questionStopWords.contains(lower) && !properNames.contains(word)
            }
            let phrase = phrasesIn(item).first.map { $0.words.joined(separator: " ") }
            return ([first] + (phrase.map { [$0] } ?? Array(rest.prefix(2)))).joined(separator: " ")
        }
    }

    static func headVerb(of item: String) -> String? {
        guard let first = item.split(separator: " ").first else { return nil }
        let word = String(first).trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
        if let base = verbs[word] { return base }
        if word.hasSuffix("ing") { return lemma(word) }
        return nil
    }

    /// Lowercase content words of prose, stop words out, in order.
    public static func contentWords(_ text: String) -> [String] {
        var words: [String] = []
        for match in text.matches(of: /[A-Za-z][A-Za-z0-9]*/) {
            let word = String(match.0).lowercased()
            guard word.count >= 2, !Tokenizer.questionStopWords.contains(word), !words.contains(word) else { continue }
            words.append(word)
        }
        return words
    }

    /// The lexicon phrases that occur in `text`.
    static func phrasesIn(_ text: String) -> [ConceptLexicon.Phrase] {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return ConceptLexicon.phrases.filter { phrase in
            guard phrase.words.count <= words.count, !phrase.words.isEmpty else { return false }
            for start in 0...(words.count - phrase.words.count) {
                var matched = true
                for (offset, word) in phrase.words.enumerated() {
                    let token = words[start + offset]
                    let isLast = offset == phrase.words.count - 1
                    if !(token == word || (isLast && (token == word + "s" || token == word + "es"))) {
                        matched = false
                        break
                    }
                }
                if matched { return true }
            }
            return false
        }
    }

    // MARK: Flow and concepts

    /// The flow verbs of a "how does X <verb>…" or "the code path that…" question, in question order.
    static func flowVerbs(in question: String, parsed: ParsedQuery) -> [String] {
        let lower = question.lowercased()
        var asksHow = false
        if let how = lower.range(of: #"\bhow\b"#, options: .regularExpression) {
            let clause = lower[how.upperBound...].prefix { $0 != "?" && $0 != "." }
            for word in clause.split(whereSeparator: { !$0.isLetter }) {
                if let base = verbs[String(word)], flowVerbSet.contains(base) {
                    asksHow = true
                    break
                }
            }
        }
        guard asksHow || parsed.isFlow else { return [] }
        let properNames = Set(parsed.acronyms.keys.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        var found: [String] = []
        for word in lower.split(whereSeparator: { !$0.isLetter }).map(String.init) where !properNames.contains(word) {
            if let base = verbs[word], flowVerbSet.contains(base), !found.contains(base) { found.append(base) }
        }
        return found
    }

    /// Concepts a question triggers: `ConceptLexicon` concepts whose name or leading terms are among its words,
    /// and its phrase labels.
    static func concepts(_ parsed: ParsedQuery) -> [String] {
        var names: [String] = parsed.phrases
        for word in parsed.words {
            let stem = Tokenizer.stem(word)
            for concept in ConceptLexicon.concepts where concept.name == word || concept.terms.prefix(6).contains(word) || concept.terms.prefix(6).contains(stem) {
                if !names.contains(concept.name) { names.append(concept.name) }
            }
        }
        return names
    }
}

extension HybridSearch {
    /// Parses and analyses a feature question against this repository's vocabulary and imports.
    public func analyze(_ question: String) -> QuestionAnalysis {
        QuestionAnalyzer.analyze(question, parsed: parse(question))
    }
}
