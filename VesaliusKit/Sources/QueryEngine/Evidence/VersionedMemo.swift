import Foundation

/// Results computed once per index version: type user sets, transitive closures, page slices.
///
/// A value is keyed by `(index_version, key)`. When the version moves (this or another process re-indexed),
/// every value from the older version is dropped on the next access, so a count shown twice is the same
/// number, and a stale one is never served. Thread-safe; `compute` runs outside the lock, so two callers may
/// both compute a missing value and the second result is the one kept.
final class VersionedMemo: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var version: Int?
    private var values: [String: any Sendable] = [:]
    /// Keys in insertion order, oldest first, for eviction past `capacity`.
    private var order: [String] = []

    init(capacity: Int = 256) {
        self.capacity = capacity
    }

    /// The value for `key` at index `version`, computing and keeping it on a miss.
    func value<T: Sendable>(for key: String, version: Int, _ compute: () throws -> T) rethrows -> T {
        lock.lock()
        if self.version != version {
            values.removeAll()
            order.removeAll()
            self.version = version
        }
        if let cached = values[key] as? T {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = try compute()

        lock.lock()
        defer { lock.unlock() }
        guard self.version == version else { return value }
        if values.updateValue(value, forKey: key) == nil {
            order.append(key)
            if order.count > capacity {
                values.removeValue(forKey: order.removeFirst())
            }
        }
        return value
    }

    /// The number of values kept for the current version.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
        order.removeAll()
        version = nil
    }
}
