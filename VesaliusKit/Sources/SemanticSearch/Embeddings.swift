import Foundation
import NaturalLanguage
import RepositoryIndex
import VesaliusCore

/// On-device semantic vectors using Apple's NaturalLanguage sentence embeddings (no download, no
/// network). Each file is embedded from a compact natural-language descriptor: path words, symbol
/// names split into words, and documentation. Vectors are recomputed only when content changes.
public final class EmbeddingIndexer: @unchecked Sendable {
    public static let modelName = "nl-sentence-en-v2"
    let db: SQLiteDatabase

    public init(db: SQLiteDatabase) {
        self.db = db
    }

    public var isAvailable: Bool { NLEmbedding.sentenceEmbedding(for: .english) != nil }

    public func update(root: URL, maxFiles: Int = 25_000, progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        guard isAvailable else { return }
        struct Pending: Sendable { let id: Int64; let hash: String; let descriptor: String }
        var candidates: [(id: Int64, hash: String, path: String)] = []
        try db.forEach("""
            SELECT f.id, f.content_hash, f.path FROM files f
            LEFT JOIN embeddings e ON e.file_id = f.id
            WHERE f.content_hash IS NOT NULL AND f.is_generated = 0
              AND f.language NOT IN ('json', 'yaml', 'toml', 'xml', 'text', 'unknown', 'css', 'html')
              AND (e.file_id IS NULL OR e.content_hash != f.content_hash OR e.model != ?)
            ORDER BY f.id LIMIT ?
            """, [Self.modelName, maxFiles]) { row in
            candidates.append((row.int64(0), row.string(1), row.string(2)))
        }
        guard !candidates.isEmpty else { return }
        // Descriptors are built up front (SQLite on this thread), then embedded in parallel.
        let pending = try candidates.map { Pending(id: $0.id, hash: $0.hash, descriptor: try descriptorText(fileID: $0.id, path: $0.path)) }
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let chunkSize = max(16, (pending.count + workers - 1) / workers)
        let counter = ProgressCounter()
        let total = pending.count
        let results = try await withThrowingTaskGroup(of: [(Int64, String, Data)].self) { group in
            for start in stride(from: 0, to: pending.count, by: chunkSize) {
                let slice = Array(pending[start..<min(pending.count, start + chunkSize)])
                group.addTask(priority: .utility) {
                    // One embedding instance per worker: instances are not shared across threads.
                    guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return [] }
                    var output: [(Int64, String, Data)] = []
                    for item in slice {
                        try Task.checkCancellation()
                        if !item.descriptor.isEmpty, let vector = embedding.vector(for: item.descriptor) {
                            output.append((item.id, item.hash, Self.pack(vector)))
                        }
                        let done = counter.increment()
                        if done % 32 == 0 || done == total { progress(done, total) }
                    }
                    return output
                }
            }
            var all: [(Int64, String, Data)] = []
            for try await part in group { all.append(contentsOf: part) }
            return all
        }
        try db.transaction {
            for (id, hash, data) in results {
                try db.run("INSERT OR REPLACE INTO embeddings(file_id, content_hash, model, vector) VALUES(?, ?, ?, ?)", [id, hash, Self.modelName, data])
            }
        }
    }

    /// A short natural-language description of a file: path words, its main symbols, first doc line.
    /// Kept under ~200 characters because sentence-embedding cost grows with length.
    func descriptorText(fileID: Int64, path: String) throws -> String {
        var words = Tokenizer.pathWords(path).filter { $0.count > 1 }
        var doc: String?
        try db.forEach("SELECT name, doc FROM symbols WHERE file_id = ? AND depth = 0 ORDER BY (kind IN ('class','struct','enum','protocol','interface','actor','component')) DESC, start_line LIMIT 12", [fileID]) { row in
            words.append(contentsOf: Tokenizer.splitIdentifier(row.string(0)))
            if doc == nil, let text = row.optionalString(1) { doc = text }
        }
        var seen = Set<String>()
        var text = words.filter { seen.insert($0).inserted && !Tokenizer.languageKeywords.contains($0) }.prefix(24).joined(separator: " ")
        if let doc {
            let sentence = doc.split(separator: ".").first.map(String.init) ?? doc
            text += ". " + sentence.prefix(80)
        }
        return String(text.prefix(220))
    }

    static func pack(_ vector: [Double]) -> Data {
        var floats = vector.map { Float($0) }
        // Normalise so similarity is a plain dot product.
        let norm = sqrt(floats.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { floats = floats.map { $0 / norm } }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }
}

final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Query-time semantic similarity over stored file vectors.
public struct SemanticIndex {
    let vectors: [(fileID: Int64, vector: [Float])]
    let embedding: NLEmbedding?

    public init(db: SQLiteDatabase) throws {
        var loaded: [(Int64, [Float])] = []
        try db.forEach("SELECT file_id, vector FROM embeddings WHERE model = ?", [EmbeddingIndexer.modelName]) { row in
            if let data = row.blob(1) { loaded.append((row.int64(0), EmbeddingIndexer.unpack(data))) }
        }
        vectors = loaded
        embedding = loaded.isEmpty ? nil : NLEmbedding.sentenceEmbedding(for: .english)
    }

    public var isEmpty: Bool { vectors.isEmpty }

    /// Files ranked by similarity, scored relative to the corpus (z-score mapped into 0…1) because raw
    /// sentence-embedding cosines are compressed into a narrow band.
    public func similar(to text: String, limit: Int = 80) -> [Int64: Double] {
        guard let embedding, let raw = embedding.vector(for: text) else { return [:] }
        var query = raw.map { Float($0) }
        let norm = sqrt(query.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return [:] }
        query = query.map { $0 / norm }
        var sims: [(Int64, Float)] = []
        sims.reserveCapacity(vectors.count)
        for (id, vector) in vectors where vector.count == query.count {
            var dot: Float = 0
            for i in 0..<query.count { dot += query[i] * vector[i] }
            sims.append((id, dot))
        }
        guard sims.count > 3 else { return [:] }
        let mean = sims.reduce(0) { $0 + $1.1 } / Float(sims.count)
        let variance = sims.reduce(0) { $0 + ($1.1 - mean) * ($1.1 - mean) } / Float(sims.count)
        let std = max(sqrt(variance), 1e-4)
        var result: [Int64: Double] = [:]
        for (id, sim) in sims.sorted(by: { $0.1 > $1.1 }).prefix(limit) {
            let z = Double((sim - mean) / std)
            if z > 1.0 { result[id] = min(1, (z - 1.0) / 2.5) }
        }
        return result
    }
}
