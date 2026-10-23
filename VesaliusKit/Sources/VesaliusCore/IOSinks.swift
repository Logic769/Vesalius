import Foundation

/// Calls that move data out of the process: file writes and syncs, database writes (for the flow view).
///
/// A flow marks these `[sink]`. The catalog matches a reference's name and receiver text as indexed: `Darwin.pwrite`,
/// `fsync(fd)`, `data.write(to:)`, `FileManager.default.removeItem`, `sqlite3_step`, Node `fs.writeFileSync`, ORM
/// `db.insert(table)`, Python `os.fsync`. A bare name (`write`, `rename`) counts only when the reference did not
/// resolve to a function of the repository. Repository functions that call a sink (`FDFile.writeAll` around
/// `pwrite`) are found by the engine and count as sinks too.
public enum IOSinks {
    public enum Kind: String, Codable, Sendable {
        /// Bytes reach a file: `pwrite`, `Data.write(to:)`, `fs.writeFileSync`.
        case write
        /// Written bytes are made durable: `fsync`, `F_FULLFSYNC`, `FileHandle.synchronize`.
        case sync
        /// A file is truncated, renamed or removed.
        case file
        /// Memory mapped onto a file.
        case map
        /// A database write: `sqlite3_step`, `db.insert`, `context.save()`.
        case database
    }

    /// C library calls, matched bare or on `Darwin`/`Glibc`/`Foundation`/`os`.
    static let libc: [String: Kind] = [
        "pwrite": .write, "pwritev": .write, "write": .write, "writev": .write, "fwrite": .write, "fputs": .write,
        "fsync": .sync, "fdatasync": .sync, "fcntl": .sync, "fflush": .sync, "msync": .sync, "sync": .sync,
        "ftruncate": .file, "truncate": .file, "rename": .file, "renameat": .file, "renamex_np": .file, "unlink": .file,
        "unlinkat": .file, "remove": .file, "mmap": .map,
        "sqlite3_step": .database, "sqlite3_exec": .database,
    ]
    static let libcReceivers: Set<String> = ["Darwin", "Glibc", "Foundation", "os", "Musl", "WinSDK"]

    /// Swift Foundation members, on any receiver.
    static let foundationMembers: [String: Kind] = [
        "createFile": .write, "moveItem": .file, "removeItem": .file, "copyItem": .write, "replaceItemAt": .file,
        "replaceItem": .file, "synchronize": .sync, "synchronizeFile": .sync, "truncate": .file,
    ]

    /// Node `fs` functions.
    static let node: [String: Kind] = [
        "writeFile": .write, "writeFileSync": .write, "appendFile": .write, "appendFileSync": .write, "createWriteStream": .write,
        "copyFile": .write, "copyFileSync": .write, "cp": .write, "cpSync": .write, "rename": .file, "renameSync": .file,
        "unlink": .file, "unlinkSync": .file, "rm": .file, "rmSync": .file, "truncate": .file, "truncateSync": .file,
        "fsync": .sync, "fsyncSync": .sync, "fdatasync": .sync, "fdatasyncSync": .sync,
    ]
    static let nodeReceivers: Set<String> = ["fs", "fsp", "fsPromises", "promises", "fs.promises", "fse", "fsExtra"]

    /// ORM and database-driver writes, on a database-like receiver.
    static let database: Set<String> = [
        "insert", "update", "delete", "upsert", "create", "createMany", "updateMany", "deleteMany", "save", "exec",
        "execute", "executemany", "commit", "add", "merge", "bulkCreate", "insertMany", "insertOne", "updateOne",
        "deleteOne", "replaceOne", "findOneAndUpdate", "put", "set", "setItem",
    ]

    /// Python calls.
    static let python: [String: Kind] = [
        "fsync": .sync, "rename": .file, "replace": .file, "remove": .file, "unlink": .file, "move": .file,
        "copyfile": .write, "copy": .write, "dump": .write, "write_text": .write, "write_bytes": .write,
    ]
    static let pythonReceivers: Set<String> = ["os", "shutil", "json", "pickle", "path", "Path", "yaml", "toml"]

    /// The sink a call is, or nil. `receiver` is the indexed receiver text (`Darwin`, `fs`, `db`, `self.file`…);
    /// `resolvedInRepository` says the reference resolved to a declaration of the repository, which rules out
    /// the C library for a bare name.
    public static func kind(name: String, receiver: String?, language: Language, argumentLabels: [String]? = nil, resolvedInRepository: Bool = false) -> Kind? {
        let receiver = receiver?.trimmingCharacters(in: .whitespaces)
        let tail = receiver.map { String($0.split(separator: ".").last ?? Substring($0)) }
        switch language {
        case .swift, .objectiveC, .c, .cpp:
            if let kind = libc[name] {
                if let receiver, libcReceivers.contains(receiver) { return kind }
                if receiver == nil, !resolvedInRepository { return kind }
            }
            guard receiver != nil, let tail else { return nil }
            // `data.write(to:)`, `string.write(toFile:)`: Foundation's file writes are told apart by their label.
            if name == "write", let first = argumentLabels?.first, first == "to" || first == "toFile" { return .write }
            if let kind = foundationMembers[name], !resolvedInRepository,
               tail.localizedCaseInsensitiveContains("file") || tail.localizedCaseInsensitiveContains("handle") || tail == "default" || tail == "FileManager" {
                return kind
            }
            // SwiftData / Core Data contexts.
            if ["save", "insert", "delete"].contains(name), !resolvedInRepository, tail.lowercased().hasSuffix("context") { return .database }
            return nil
        case .typescript, .javascript:
            if let receiver, let kind = node[name], nodeReceivers.contains(receiver) || nodeReceivers.contains(tail ?? "") { return kind }
            if let receiver, database.contains(name), isDatabaseReceiver(receiver) { return .database }
            if name == "setItem", let tail, tail.hasSuffix("Storage") { return .write }
            return nil
        case .python:
            if let receiver, let kind = python[name], pythonReceivers.contains(receiver) || pythonReceivers.contains(tail ?? "") { return kind }
            if name == "write", let tail, ["f", "fh", "file", "handle", "out", "fp", "stream"].contains(tail) { return .write }
            if let receiver, ["commit", "add", "execute", "executemany", "merge", "delete"].contains(name), isDatabaseReceiver(receiver) { return .database }
            return nil
        default:
            return nil
        }
    }

    /// Every name the catalog knows, for prefiltering reference rows.
    public static let names: Set<String> = {
        var all = Set(libc.keys).union(foundationMembers.keys).union(node.keys).union(database).union(python.keys)
        all.formUnion(["write", "save", "insert", "delete", "setItem"])
        return all
    }()

    /// `db`, `tx`, `prisma.user`, `this.db`, `session`, `cursor`, `knex`: receivers that are a database handle.
    static func isDatabaseReceiver(_ receiver: String) -> Bool {
        let parts = receiver.split(separator: ".").map { $0.lowercased() }
        guard let first = parts.first(where: { $0 != "this" && $0 != "self" }) else { return false }
        if first == "prisma" || first == "knex" || first == "sequelize" || first == "mongoose" { return true }
        let last = parts.last ?? first
        return ["db", "tx", "trx", "database", "conn", "connection", "session", "cursor", "cur", "client", "pool"].contains(last)
            || last.hasSuffix("db") || last.hasSuffix("repository") || last.hasSuffix("repo")
    }

    /// `sinks` as one label per kind, in a fixed order (`write, sync`).
    public static func summary(_ kinds: Set<Kind>) -> [String] {
        [Kind.write, .sync, .file, .map, .database].filter(kinds.contains).map(\.rawValue)
    }
}
