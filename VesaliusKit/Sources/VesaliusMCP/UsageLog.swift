import Foundation
import RepositoryIndex

/// One answered tool call: where, which tool, how big and how long. Never the question, the symbol or any code.
public struct UsageRecord: Codable, Sendable, Equatable {
    public var time: Date
    /// The repository root the call was answered for.
    public var repository: String
    public var tool: String
    /// `mcp` (an agent, through `vesalius mcp`) or `cli` (a terminal, or an agent through its shell).
    public var via: String
    public var milliseconds: Int
    /// Characters of answer text the caller received.
    public var answerCharacters: Int
    /// For answers that run a completeness check: whether it said complete.
    public var complete: Bool?
    public var isError: Bool

    public init(time: Date = Date(), repository: String, tool: String, via: String, milliseconds: Int, answerCharacters: Int, complete: Bool? = nil, isError: Bool = false) {
        self.time = time
        self.repository = repository
        self.tool = tool
        self.via = via
        self.milliseconds = milliseconds
        self.answerCharacters = answerCharacters
        self.complete = complete
        self.isError = isError
    }

    enum CodingKeys: String, CodingKey {
        case time = "t", repository = "repo", tool, via, milliseconds = "ms", answerCharacters = "out", complete, isError = "err"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        time = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .time))
        repository = try values.decode(String.self, forKey: .repository)
        tool = try values.decode(String.self, forKey: .tool)
        via = try values.decodeIfPresent(String.self, forKey: .via) ?? "mcp"
        milliseconds = try values.decodeIfPresent(Int.self, forKey: .milliseconds) ?? 0
        answerCharacters = try values.decodeIfPresent(Int.self, forKey: .answerCharacters) ?? 0
        complete = try values.decodeIfPresent(Bool.self, forKey: .complete)
        isError = try values.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode((time.timeIntervalSince1970 * 1000).rounded() / 1000, forKey: .time)
        try values.encode(repository, forKey: .repository)
        try values.encode(tool, forKey: .tool)
        try values.encode(via, forKey: .via)
        try values.encode(milliseconds, forKey: .milliseconds)
        try values.encode(answerCharacters, forKey: .answerCharacters)
        try values.encodeIfPresent(complete, forKey: .complete)
        if isError { try values.encode(true, forKey: .isError) }
    }

    /// The record for one answer.
    public static func measuring(_ output: ToolOutput, tool: String, via: String, repository: URL, milliseconds: Int) -> UsageRecord {
        UsageRecord(repository: repository.path, tool: tool, via: via, milliseconds: milliseconds, answerCharacters: output.text.count,
                    complete: output.isError ? nil : output.complete, isError: output.isError)
    }
}

/// The local usage log behind `vesalius stats`: one JSON line per answered call in `usage.jsonl` next to the
/// indexes (`VESALIUS_HOME`). Writing never fails a call. `VESALIUS_STATS=off` stops recording.
public enum UsageLog {
    public static let environmentKey = "VESALIUS_STATS"
    /// Past this size the log is rotated to `usage.1.jsonl`, replacing the one before.
    public static let maximumBytes: off_t = 8 << 20

    public static var url: URL { IndexLocation.baseDirectory.appendingPathComponent("usage.jsonl") }

    static func rotated(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("1.jsonl")
    }

    public static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let value = environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return !["off", "0", "false", "no"].contains(value)
    }

    /// Appends one record with a single `write` on an append-only descriptor, so lines from concurrent servers
    /// never interleave. A full log is rotated by rename under a lock: writers still holding the old file keep
    /// appending to the rotated one, so nothing is lost.
    public static func append(_ record: UsageRecord, to url: URL = url, rotatingAt limit: off_t = maximumBytes) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard isEnabled(), var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_size > limit, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(descriptor, LOCK_UN) }
        // Rotate only if this descriptor's file is still the current log; another writer may have rotated it.
        var current = stat()
        guard stat(url.path, &current) == 0, current.st_ino == opened.st_ino, current.st_dev == opened.st_dev else { return }
        _ = rename(url.path, rotated(url).path)
    }

    /// Every readable record, oldest first: the rotated log, then the current one. Lines that don't parse are skipped.
    public static func read(from url: URL = url) -> [UsageRecord] {
        let decoder = JSONDecoder()
        return [rotated(url), url].flatMap { file -> [UsageRecord] in
            guard let data = try? Data(contentsOf: file) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(UsageRecord.self, from: Data($0)) }
        }
    }

    /// Deletes the log. False when there was nothing to delete.
    @discardableResult
    public static func reset(at url: URL = url) throws -> Bool {
        var deleted = false
        for file in [url, rotated(url)] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
            deleted = true
        }
        return deleted
    }
}
