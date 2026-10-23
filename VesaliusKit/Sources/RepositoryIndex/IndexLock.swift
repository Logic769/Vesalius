import Foundation

/// A cross-process lock around index writes.
///
/// The app, `vesalius watch`, the CLI and the MCP server may all index the same repository. Two writers on
/// one SQLite file make the second wait on the busy timeout and then fail with `database is locked`, so
/// writers take `flock` on `<index dir>/index.lock` first and queue there instead, polling every 50 ms. The
/// kernel releases the lock when its holder exits, even after a crash, so a stale lock file never blocks.
public struct IndexLock: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(location: IndexLocation) {
        self.init(url: location.lockURL)
    }

    /// Runs `body` while holding the lock, after waiting for any other holder. Waiting ends early with
    /// `CancellationError` when the task is cancelled.
    public func withLock<T>(_ body: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await body()
    }
}
