import Foundation
import RepositoryIndex
import VesaliusCore

/// Builds the repository vocabulary: words that appear in identifiers and paths, with document
/// frequencies. Query expansion only keeps candidate terms that exist in this vocabulary, so
/// expansions never drift into words the codebase does not use.
///
/// Imported module names and the names imported from them count too (`storekit`, `safestorage`), as do the
/// receivers and members of references resolved outside the repository, so framework words survive the filter.
public struct VocabularyBuilder {
    let db: SQLiteDatabase

    public init(db: SQLiteDatabase) {
        self.db = db
    }

    public func rebuild() throws {
        var documentFrequency: [String: Int] = [:]
        var fileTerms: [Int64: Set<String>] = [:]
        func add(_ name: String, to fileID: Int64, whole: Bool = false) {
            let parts = Tokenizer.splitIdentifier(name)
            for word in parts where word.count >= 2 {
                fileTerms[fileID, default: []].insert(word)
            }
            let joined = parts.joined()
            if whole, parts.count > 1, joined.count >= 3, joined.count <= 40 {
                fileTerms[fileID, default: []].insert(joined)
            }
        }
        try db.forEach("SELECT file_id, name FROM symbols") { row in
            add(row.string(1), to: row.int64(0))
        }
        try db.forEach("SELECT id, path FROM files") { row in
            for word in Tokenizer.pathWords(row.string(1)) where word.count >= 2 {
                fileTerms[row.int64(0), default: []].insert(word)
            }
        }
        try db.forEach("SELECT file_id, module, external_name, names FROM imports WHERE external_name IS NOT NULL AND is_mock = 0") { row in
            let fileID = row.int64(0)
            add(row.string(2), to: fileID, whole: true)
            for name in ImportNamesCodec.decode(row.optionalString(3)) {
                add(name.alias ?? name.name, to: fileID, whole: true)
            }
        }
        try db.forEach("SELECT DISTINCT file_id, receiver_type, name FROM refs WHERE is_external = 1") { row in
            if let receiverType = row.optionalString(1) { add(receiverType, to: row.int64(0), whole: true) }
            add(row.string(2), to: row.int64(0), whole: true)
        }
        for terms in fileTerms.values {
            for term in terms where !Tokenizer.languageKeywords.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }
        try db.transaction {
            try db.run("DELETE FROM vocabulary")
            for (term, df) in documentFrequency {
                try db.run("INSERT INTO vocabulary(term, df) VALUES(?, ?)", [term, df])
            }
        }
    }
}

/// In-memory view of the vocabulary used during a query.
public struct Vocabulary: Sendable {
    public let frequencies: [String: Int]
    public let documentCount: Int

    public init(db: SQLiteDatabase) throws {
        var map: [String: Int] = [:]
        try db.forEach("SELECT term, df FROM vocabulary") { map[$0.string(0)] = $0.int(1) }
        frequencies = map
        documentCount = max(1, try db.scalarInt("SELECT COUNT(*) FROM files"))
    }

    /// A vocabulary from known frequencies (tests).
    public init(frequencies: [String: Int], documentCount: Int) {
        self.frequencies = frequencies
        self.documentCount = max(1, documentCount)
    }

    public func contains(_ term: String) -> Bool { frequencies[term] != nil }

    /// Inverse document frequency (rarer terms are more discriminative).
    public func idf(_ term: String) -> Double {
        let df = Double(frequencies[term] ?? 0)
        return log((Double(documentCount) + 1) / (df + 1)) + 1
    }

    /// The share of files a term appears in (0…1).
    public func share(_ term: String) -> Double {
        Double(frequencies[term] ?? 0) / Double(documentCount)
    }

    /// Vocabulary terms that extend a question word the repository does not use (`authn` → `authentication`).
    /// Only words of 4 or more letters are completed, so `class` or `key` never pull in `classify` or `keyword`.
    public func completions(of prefix: String, limit: Int = 3) -> [String] {
        guard prefix.count >= 4, frequencies[prefix] == nil else { return [] }
        return frequencies
            .filter { $0.key.hasPrefix(prefix) && $0.key != prefix && $0.key.count <= prefix.count + 10 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}
