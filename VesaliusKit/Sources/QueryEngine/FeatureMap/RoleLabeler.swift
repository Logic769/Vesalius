import Foundation
import SemanticSearch
import VesaliusCore

/// Puts a feature's members under the roles the question names, in the question's order.
///
/// A member plays the role whose terms best match its name words (3 points each, 1.5× for the first word), its
/// documentation (1 each) and the framework calls it makes (1.5 each). Documentation and calls count a role's
/// object words ("products" in "loading products") only next to its verb, so a member that merely handles
/// products is not "loading". Analytics and logging helpers count half unless the question is about analytics.
/// Below `minimumScore` a member plays no role.
struct RoleLabeler {
    let roles: [QuestionAnalysis.Role]
    let mentionsAnalytics: Bool

    static let minimumScore = 2.0
    /// Role terms at this weight or more are verbs, their synonyms or phrase terms; below are object words.
    static let strongWeight = 0.6
    static let membersPerRole = 4
    static let analyticsWords: Set<String> = ["log", "logs", "track", "tracking", "analytics", "report", "metric", "metrics", "telemetry"]

    struct Candidate {
        let id: Int64
        let name: String
        let doc: String?
        /// Words of the external calls the member makes (`products`, `purchase`, `sync`).
        let externalWords: [String]
        /// Kinds of sinks the member reaches (`database`), which mark a store/save/write role.
        let sinkKinds: Set<IOSinks.Kind>
        /// Names of the feature's stored properties the member writes outside `#if` (`isSubscribed`).
        var writtenState: [String] = []
        /// The member calls the question's frameworks.
        var callsFramework = false
    }

    /// The best role for a candidate and its score, or nil.
    func role(for candidate: Candidate) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        let nameWords = Tokenizer.splitIdentifier(candidate.name)
        // The doc's first sentence says what the member is for; later sentences weigh half.
        let sentences = QuestionAnalyzer.splitSentences(candidate.doc ?? "")
        let firstWords = sentences.first.map { QuestionAnalyzer.contentWords($0) } ?? []
        let restWords = sentences.dropFirst().prefix(2).flatMap { QuestionAnalyzer.contentWords($0) }.filter { !firstWords.contains($0) }
        let isAnalytics = !mentionsAnalytics && nameWords.contains { Self.analyticsWords.contains($0) }
        for (index, role) in roles.enumerated() {
            var nameScore = 0.0
            for (position, word) in nameWords.enumerated() {
                let value = FeatureContext.match([word], terms: role.terms)
                nameScore += value * 3 * (position == 0 ? 1.5 : 1)
            }
            nameScore += FeatureContext.match(nameWords.count > 1 ? [nameWords.joined()] : [], terms: role.terms) * 3
            let strong = role.terms.filter { $0.value >= Self.strongWeight }
            var score = nameScore
            // Object words count in documentation only next to a verb of the role ("loads products").
            if FeatureContext.match(firstWords, terms: strong) > 0 { score += FeatureContext.match(firstWords, terms: role.terms) }
            score += FeatureContext.match(restWords, terms: strong) * 0.5
            if Self.saysVerbAndObject(sentences.first ?? "", role: role) { score += 1.5 }
            score += FeatureContext.match(candidate.externalWords, terms: strong) * 1.5
            let state = candidate.writtenState.reduce(0.0) { $0 + FeatureContext.match(Tokenizer.splitIdentifier($1), terms: strong) }
            score += min(3, state * 1.5)
            if !candidate.sinkKinds.isEmpty, Self.isStorageRole(role) { score += 3 }
            if candidate.callsFramework { score += 0.5 }
            // Without its name, a member plays a role only through what it does: framework calls or the state it sets.
            if nameScore == 0 && !candidate.callsFramework && state == 0 && candidate.sinkKinds.isEmpty { score *= 0.5 }
            if isAnalytics { score *= 0.5 }
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        guard let best, best.score >= Self.minimumScore else { return nil }
        return best
    }

    /// The sentence says the role in its own words: one of the role's verbs followed within two words by one of
    /// its object words ("begins the listener, loads products" for "loading products").
    static func saysVerbAndObject(_ sentence: String, role: QuestionAnalysis.Role) -> Bool {
        let words = sentence.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let verbs = Set(role.terms.filter { $0.value >= 1 }.keys)
        let objects = Set(role.terms.filter { $0.value < strongWeight && $0.value >= 0.45 }.keys)
        guard !objects.isEmpty else { return false }
        for (index, word) in words.enumerated() where verbs.contains(QuestionAnalyzer.lemma(word)) || verbs.contains(word) {
            for next in words.dropFirst(index + 1).prefix(2) where objects.contains(next) || objects.contains(Tokenizer.stem(next)) {
                return true
            }
        }
        return false
    }

    /// A role about storing data (`store`, `save`, `persist`, `write`), which database and file writes play.
    static func isStorageRole(_ role: QuestionAnalysis.Role) -> Bool {
        ["store", "save", "persist", "write", "insert"].contains { (role.terms[$0] ?? 0) >= 1 }
    }

    /// A role about reading data back (`load`, `read`, `fetch`).
    static func isLoadRole(_ role: QuestionAnalysis.Role) -> Bool {
        ["load", "read", "fetch"].contains { (role.terms[$0] ?? 0) >= 1 }
    }

    /// Candidates grouped by role in the question's order, best `membersPerRole` per role, each group in line order.
    func assign(_ candidates: [Candidate], order: (Int64) -> Int) -> [(role: QuestionAnalysis.Role, members: [Int64])] {
        var byRole: [Int: [(id: Int64, score: Double)]] = [:]
        for candidate in candidates {
            guard let best = role(for: candidate) else { continue }
            byRole[best.index, default: []].append((candidate.id, best.score))
        }
        var result: [(role: QuestionAnalysis.Role, members: [Int64])] = []
        for (index, role) in roles.enumerated() {
            let ranked = (byRole[index] ?? []).sorted { $0.score == $1.score ? order($0.id) < order($1.id) : $0.score > $1.score }
            let kept = ranked.prefix(Self.membersPerRole).map(\.id).sorted { order($0) < order($1) }
            result.append((role, kept))
        }
        return result
    }
}
