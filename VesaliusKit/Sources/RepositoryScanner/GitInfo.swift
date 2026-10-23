import Foundation
import VesaliusCore

/// Read-only git queries. Every call degrades gracefully when git is missing or the folder is not a
/// repository (unusual layouts, worktrees, submodules, bare checkouts).
public struct GitRepository: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Locates a git executable without relying on the login shell's PATH (GUI apps do not inherit it).
    public static let executable: URL? = {
        let candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if path == "/usr/bin/git" {
                // /usr/bin/git is a shim that needs Xcode or the Command Line Tools.
                let developerDir = "/Library/Developer/CommandLineTools/usr/bin/git"
                let xcodeGit = "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
                guard FileManager.default.fileExists(atPath: developerDir) || FileManager.default.fileExists(atPath: xcodeGit) else { continue }
            }
            return URL(fileURLWithPath: path)
        }
        return nil
    }()

    public var isAvailable: Bool { Self.executable != nil }

    /// True when the folder is inside a git work tree.
    public var isRepository: Bool {
        guard let output = run(["rev-parse", "--is-inside-work-tree"]) else {
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func info(name: String) -> RepositoryInfo {
        guard isRepository else {
            return RepositoryInfo(name: name, path: root.path, isGitRepository: false)
        }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = run(["rev-parse", "--short", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = run(["config", "--get", "remote.origin.url"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RepositoryInfo(
            name: name,
            path: root.path,
            isGitRepository: true,
            branch: branch?.isEmpty == false ? branch : nil,
            headCommit: head?.isEmpty == false ? head : nil,
            remoteURL: remote?.isEmpty == false ? Self.redactCredentials(remote!) : nil
        )
    }

    /// The first commit hash: a stable identity for the repository that survives moves and renames.
    public func rootCommit() -> String? {
        run(["rev-list", "--max-parents=0", "HEAD"])?
            .split(separator: "\n").last.map(String.init)
    }

    /// Absolute path of the work-tree top level.
    public func topLevel() -> URL? {
        guard let path = run(["rev-parse", "--show-toplevel"])?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Commit counts per root-relative path over a recent window (a "churn" signal for hotspots).
    public func churn(sinceDays: Int = 365, maxCommits: Int = 4000) -> [String: Int] {
        guard isRepository, let top = topLevel() else { return [:] }
        guard let output = run(["log", "--since=\(sinceDays).days", "-n", String(maxCommits), "--no-merges", "--name-only", "--pretty=format:", "--", "."], timeout: 30) else {
            return [:]
        }
        // git prints paths relative to the top level; convert to paths relative to our root.
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let topPath = top.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.count > topPath.count ? String(rootPath.dropFirst(topPath.count + 1)) + "/" : ""
        var counts: [String: Int] = [:]
        for line in output.split(separator: "\n") where !line.isEmpty {
            var path = String(line)
            if !prefix.isEmpty {
                guard path.hasPrefix(prefix) else { continue }
                path = String(path.dropFirst(prefix.count))
            }
            counts[path, default: 0] += 1
        }
        return counts
    }

    func run(_ arguments: [String], timeout: TimeInterval = 10) -> String? {
        guard let executable = Self.executable else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"      // never take index.lock: we are read-only
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting so large outputs cannot deadlock on a full pipe.
        let deadline = DispatchTime.now() + timeout
        let reader = stdout.fileHandleForReading
        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = reader.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }

    static func redactCredentials(_ url: String) -> String {
        guard let at = url.firstIndex(of: "@"), let scheme = url.range(of: "://"), scheme.upperBound < at else { return url }
        return String(url[..<scheme.upperBound]) + String(url[url.index(after: at)...])
    }
}

private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

/// Decodes file bytes into text, rejecting binaries and tolerating legacy encodings.
public enum SourceDecoder {
    public enum Result: Sendable {
        case text(String, encoding: String.Encoding)
        case binary
    }

    public static func decode(_ data: Data) -> Result {
        if data.isEmpty { return .text("", encoding: .utf8) }
        // UTF-16 with BOM.
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                if let text = String(data: data, encoding: .utf16) { return .text(text, encoding: .utf16) }
            }
        }
        // A NUL byte in the first 8 KB means binary content.
        if data.prefix(8192).contains(0) { return .binary }
        if let text = String(data: data, encoding: .utf8) { return .text(text, encoding: .utf8) }
        if let text = String(data: data, encoding: .windowsCP1252) { return .text(text, encoding: .windowsCP1252) }
        if let text = String(data: data, encoding: .isoLatin1) { return .text(text, encoding: .isoLatin1) }
        return .binary
    }

    /// Heuristics for generated or minified files. Generated files stay searchable but are excluded from
    /// health diagnostics; minified files are skipped by analyzers.
    public static func generatedMarker(path: String, text: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let generatedNames = [".generated.", ".g.dart", ".pb.swift", ".pb.go", "_pb2.py", "_pb2_grpc.py", ".designer.cs", "R.generated.swift", "Generated.swift", ".freezed.dart"]
        if generatedNames.contains(where: { name.contains($0) }) { return true }
        let head = text.prefix(1500).lowercased()
        let markers = ["@generated", "code generated", "do not edit", "auto-generated", "autogenerated", "automatically generated", "this file was generated", "generated by"]
        return markers.contains { head.contains($0) }
    }

    public static func isMinified(text: String) -> Bool {
        var lines = 0
        var longest = 0
        var current = 0
        for byte in text.utf8.prefix(200_000) {
            if byte == 10 {
                lines += 1
                longest = max(longest, current)
                current = 0
            } else {
                current += 1
            }
        }
        longest = max(longest, current)
        let length = min(text.utf8.count, 200_000)
        return longest > 5_000 || (lines > 0 && length / max(lines, 1) > 400)
    }
}
