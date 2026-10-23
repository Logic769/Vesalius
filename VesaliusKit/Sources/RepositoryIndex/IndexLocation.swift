import CryptoKit
import Foundation

/// Metadata stored next to each index so the registry can list and re-associate indexes.
public struct IndexedRepositoryRecord: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    /// Git root commit, used to recognise a repository after it has been moved.
    public var identity: String?
    public var createdAt: Date
    public var lastIndexedAt: Date?
    public var indexDirectory: String

    public var id: String { indexDirectory }
    public var exists: Bool { FileManager.default.fileExists(atPath: path) }

    public init(path: String, name: String, identity: String?, createdAt: Date, lastIndexedAt: Date?, indexDirectory: String) {
        self.path = path
        self.name = name
        self.identity = identity
        self.createdAt = createdAt
        self.lastIndexedAt = lastIndexedAt
        self.indexDirectory = indexDirectory
    }
}

/// Where a repository's index lives: `~/Library/Application Support/Vesalius/Indexes/<name>-<hash>/`.
/// Set `VESALIUS_HOME` to relocate all indexes (used by tests and CI).
public struct IndexLocation: Sendable, Hashable {
    public let repositoryRoot: URL
    public let directory: URL

    /// The database is named after its schema version (`index.v4.sqlite`), so an older app or CLI and a newer
    /// one keep separate files instead of deleting each other's index on open.
    public var databaseURL: URL { directory.appendingPathComponent("index.v\(IndexSchema.version).sqlite") }
    public var manifestURL: URL { directory.appendingPathComponent("repository.json") }
    /// Held while a process writes the index (see `IndexLock`).
    public var lockURL: URL { directory.appendingPathComponent("index.lock") }

    public static var baseDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["VESALIUS_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Vesalius", isDirectory: true)
    }

    public static var indexesDirectory: URL { baseDirectory.appendingPathComponent("Indexes", isDirectory: true) }

    /// Canonical form of a repository path: absolute, standardised, symlinks resolved.
    public static func canonicalRoot(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public init(repositoryRoot: URL) {
        let root = Self.canonicalRoot(repositoryRoot)
        self.repositoryRoot = root
        self.directory = Self.indexesDirectory.appendingPathComponent(Self.key(for: root), isDirectory: true)
    }

    init(repositoryRoot: URL, directory: URL) {
        self.repositoryRoot = repositoryRoot
        self.directory = directory
    }

    static func key(for root: URL) -> String {
        let digest = SHA256.hash(data: Data(root.path.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let slug = root.lastPathComponent.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .prefix(40)
        return "\(slug.isEmpty ? "repo" : String(slug))-\(hex)"
    }

    public var hasIndex: Bool { FileManager.default.fileExists(atPath: databaseURL.path) }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func readManifest() -> IndexedRepositoryRecord? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(IndexedRepositoryRecord.self, from: data)
    }

    public func writeManifest(name: String, identity: String?, lastIndexedAt: Date?) throws {
        try ensureDirectory()
        let existing = readManifest()
        let record = IndexedRepositoryRecord(
            path: repositoryRoot.path,
            name: name,
            identity: identity ?? existing?.identity,
            createdAt: existing?.createdAt ?? Date(),
            lastIndexedAt: lastIndexedAt ?? existing?.lastIndexedAt,
            indexDirectory: directory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: manifestURL, options: .atomic)
    }

    /// Deletes the index (database, WAL and manifest). The repository itself is never touched.
    public func removeIndex() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Deletes only this version's database and its WAL, keeping the manifest and the lock file, so a
    /// rebuild can run while it holds the `IndexLock`.
    public func removeDatabase() throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// Every index on this machine.
    public static func allIndexed() -> [IndexedRepositoryRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: indexesDirectory, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { directory in
            IndexLocation(repositoryRoot: directory, directory: directory).readManifest()
        }
        .sorted { ($0.lastIndexedAt ?? .distantPast) > ($1.lastIndexedAt ?? .distantPast) }
    }

    /// If the repository has no index at its current path but an index exists for the same git identity
    /// at a path that no longer exists (the repository was moved or renamed), move that index here.
    @discardableResult
    public func adoptMovedIndex(identity: String?) -> Bool {
        guard !hasIndex, let identity, !identity.isEmpty else { return false }
        guard let orphan = Self.allIndexed().first(where: { $0.identity == identity && !$0.exists }) else { return false }
        do {
            try FileManager.default.createDirectory(at: Self.indexesDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.moveItem(at: URL(fileURLWithPath: orphan.indexDirectory), to: directory)
            try writeManifest(name: repositoryRoot.lastPathComponent, identity: identity, lastIndexedAt: orphan.lastIndexedAt)
            return true
        } catch {
            return false
        }
    }
}
