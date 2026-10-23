import Foundation
import VesaliusCore

/// A file selected for indexing.
public struct ScannedFile: Sendable, Hashable {
    /// Repository-relative path with `/` separators.
    public let path: String
    public let size: Int
    public let modified: Double
    public let language: Language

    public init(path: String, size: Int, modified: Double, language: Language) {
        self.path = path
        self.size = size
        self.modified = modified
        self.language = language
    }
}

public struct SkippedEntry: Sendable, Hashable {
    public enum Reason: String, Sendable {
        case ignoredByRule = "ignored"
        case defaultExclusion = "excluded"
        case tooLarge = "too-large"
        case binary
        case symlink
        case unreadable
        case hidden
        case vendored
    }

    public let path: String
    public let reason: Reason
}

public struct ScanOptions: Sendable {
    /// Directory names never descended into (in addition to `.gitignore` rules).
    public var excludedDirectoryNames: Set<String>
    /// Extra user exclusions in gitignore syntax, applied at the repository root.
    public var userExclusions: [String]
    public var respectGitignore: Bool
    /// Files above this size are skipped entirely.
    public var maxFileSize: Int
    /// Include files in unknown/plain-text formats (still indexed lexically).
    public var includeNonCodeText: Bool
    public var maxFiles: Int
    /// Skip third-party projects copied into the repository (vendored libraries, embedded runtimes).
    public var skipVendoredProjects: Bool

    public init(
        excludedDirectoryNames: Set<String> = ScanOptions.defaultExcludedDirectories,
        userExclusions: [String] = [],
        respectGitignore: Bool = true,
        maxFileSize: Int = 1_500_000,
        includeNonCodeText: Bool = true,
        maxFiles: Int = 200_000,
        skipVendoredProjects: Bool = true
    ) {
        self.excludedDirectoryNames = excludedDirectoryNames
        self.userExclusions = userExclusions
        self.respectGitignore = respectGitignore
        self.maxFileSize = maxFileSize
        self.includeNonCodeText = includeNonCodeText
        self.maxFiles = maxFiles
        self.skipVendoredProjects = skipVendoredProjects
    }

    public static let defaultExcludedDirectories: Set<String> = [
        ".git", ".hg", ".svn", ".jj",
        "node_modules", "bower_components", "jspm_packages",
        "DerivedData", ".build", "build", "Build", "dist", "out-tsc",
        "Pods", "Carthage", "vendor", ".bundle",
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".vercel", ".netlify", ".expo", ".angular", ".docusaurus",
        ".cache", ".parcel-cache", "coverage", ".nyc_output", "storybook-static",
        "__pycache__", ".venv", "venv", ".tox", ".nox", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".eggs", "site-packages",
        ".gradle", ".idea", ".swiftpm", "xcuserdata", ".dart_tool", ".terraform", ".serverless",
        "generated", "__generated__", "Generated", "third_party", "third-party", "ThirdParty", "3rdparty",
        "dist-packages", "lib-dynload", "python-stdlib", "bower_components", "Carthage", "SourcePackages",
    ]

    /// Directory-name suffixes that are bundles or build products, not source folders.
    public static let excludedDirectorySuffixes: [String] = [
        ".xcodeproj", ".xcworkspace", ".xcassets", ".framework", ".xcframework", ".app", ".dSYM",
        ".lproj", ".bundle", ".egg-info", ".playground", ".xcdatamodeld", ".scnassets", ".mlpackage", ".mlmodelc",
        ".docc", ".icon",
    ]

    /// Bundles the project model reads although the walk never descends into them.
    public static let projectBundleSuffixes: [String] = [".xcodeproj", ".xcworkspace"]

    public static let excludedFileNames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Podfile.lock", "Package.resolved", "Cargo.lock",
        "poetry.lock", "Gemfile.lock", "composer.lock", "Pipfile.lock", "uv.lock", "bun.lockb", "go.sum",
        ".DS_Store", "Thumbs.db",
    ]

    public static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "ico", "icns", "bmp", "tif", "tiff", "psd", "sketch", "fig", "ai", "eps", "svg",
        "pdf", "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "dmg", "pkg", "ipa", "apk", "aab", "jar", "war", "class",
        "o", "a", "so", "dylib", "dll", "exe", "bin", "wasm", "obj", "lib", "pyc", "pyo",
        "mp3", "mp4", "mov", "m4a", "m4v", "wav", "aiff", "aif", "caf", "flac", "ogg", "avi", "mkv", "webm",
        "ttf", "otf", "woff", "woff2", "eot",
        "sqlite", "sqlite3", "db", "realm", "mlmodel", "car", "nib", "keystore", "p12", "cer", "mobileprovision", "der",
        "xcstrings", "strings", "stringsdict", "map", "lock", "snap", "usdz", "reality", "glb", "gltf", "fbx", "blend",
    ]
}

/// An Xcode project or workspace found by the walk (which never descends into it).
public struct ProjectBundle: Sendable, Hashable, Codable {
    /// Repository-relative path of the `.xcodeproj` or `.xcworkspace` directory.
    public let path: String
    /// True when ignore rules exclude it (`.gitignore`, `.git/info/exclude`, `.vesaliusignore`, user exclusions).
    public let ignored: Bool

    public init(path: String, ignored: Bool) {
        self.path = path
        self.ignored = ignored
    }

    public var isProject: Bool { path.hasSuffix(".xcodeproj") }
}

/// A submodule declared in the repository's root `.gitmodules`.
public struct GitSubmodule: Sendable, Hashable, Codable {
    public let name: String
    /// Repository-relative path of the checkout.
    public let path: String
    public let url: String?
    /// Line of the `[submodule "…"]` header.
    public let line: Int

    public init(name: String, path: String, url: String?, line: Int) {
        self.name = name
        self.path = path
        self.url = url
        self.line = line
    }

    /// Parses `.gitmodules` text (git config syntax).
    public static func parse(_ text: String) -> [GitSubmodule] {
        var result: [GitSubmodule] = []
        var current: (name: String, line: Int, path: String?, url: String?)?
        func flush() {
            if let current, let path = current.path {
                result.append(GitSubmodule(name: current.name, path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), url: current.url, line: current.line))
            }
        }
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let match = line.firstMatch(of: /^\[\s*submodule\s+"([^"]*)"\s*\]/) {
                flush()
                current = (String(match.1), index + 1, nil, nil)
                continue
            }
            if line.hasPrefix("[") {
                flush()
                current = nil
                continue
            }
            guard current != nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if key == "path" { current?.path = value }
            if key == "url" { current?.url = value }
        }
        flush()
        return result
    }
}

public struct ScanResult: Sendable {
    public let root: URL
    public let files: [ScannedFile]
    public let directories: [String]
    /// A capped sample of skipped entries, for diagnostics and the UI.
    public let skipped: [SkippedEntry]
    public let skippedCount: Int
    public let errors: [String]
    public let truncated: Bool
    /// Third-party projects detected inside the repository and skipped (repository-relative paths).
    public let vendoredDirectories: [String]
    /// Xcode projects and workspaces in the scanned folders, including ignored ones (the project model picks).
    public let projectBundles: [ProjectBundle]
    /// Submodules declared in the root `.gitmodules` (a hidden file the walk otherwise skips).
    public let submodules: [GitSubmodule]
}

/// Walks a repository honouring `.gitignore` files (root, nested, `.git/info/exclude`, global excludes),
/// `.vesaliusignore`, user exclusions and default build/vendor exclusions. Never follows symlinks and never
/// writes to the repository.
public struct RepositoryScanner: Sendable {
    public let root: URL
    public let options: ScanOptions

    public init(root: URL, options: ScanOptions = ScanOptions()) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.options = options
    }

    public func scan(isCancelled: @Sendable () -> Bool = { false }) throws -> ScanResult {
        try walk(collectFiles: true, isCancelled: isCancelled)
    }

    /// The Xcode projects and workspaces `scan()` would report, found by walking folders only (no file
    /// stats), so callers without a scan at hand can stamp project files cheaply.
    public func projectBundles() throws -> [ProjectBundle] {
        try walk(collectFiles: false, isCancelled: { false }).projectBundles
    }

    private func walk(collectFiles: Bool, isCancelled: @Sendable () -> Bool) throws -> ScanResult {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw ScannerError.missingRepository(root.path)
        }
        guard isDirectory.boolValue else { throw ScannerError.notADirectory(root.path) }
        guard fm.isReadableFile(atPath: root.path) else { throw ScannerError.permissionDenied(root.path) }

        var files: [ScannedFile] = []
        var directories: [String] = [""]
        var skipped: [SkippedEntry] = []
        var skippedCount = 0
        var errors: [String] = []
        var truncated = false
        var vendored: [String] = []
        var bundles: [ProjectBundle] = []

        func skip(_ path: String, _ reason: SkippedEntry.Reason) {
            skippedCount += 1
            if skipped.count < 500 { skipped.append(SkippedEntry(path: path, reason: reason)) }
        }

        let baseStack = initialIgnoreStack()
        let keys: [URLResourceKey] = collectFiles
            ? [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            : [.isDirectoryKey, .isSymbolicLinkKey]

        // Iterative DFS carrying the ignore stack that applies to each directory.
        var pending: [(url: URL, relative: String, ignores: IgnoreStack)] = [(root, "", baseStack)]
        while let (directoryURL, relativeDirectory, inheritedIgnores) = pending.popLast() {
            if isCancelled() { throw CancellationError() }
            var ignores = inheritedIgnores
            if options.respectGitignore, relativeDirectory.isEmpty == false {
                if let ruleSet = loadIgnoreFile(directoryURL.appendingPathComponent(".gitignore"), base: relativeDirectory) {
                    ignores.push(ruleSet)
                }
                if let ruleSet = loadIgnoreFile(directoryURL.appendingPathComponent(".vesaliusignore"), base: relativeDirectory) {
                    ignores.push(ruleSet)
                }
            }

            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: keys, options: [])
            } catch {
                errors.append("Cannot read \(relativeDirectory.isEmpty ? "." : relativeDirectory): \(error.localizedDescription)")
                skip(relativeDirectory, .unreadable)
                continue
            }

            let siblingNames = Set(entries.map(\.lastPathComponent))
            if options.skipVendoredProjects, !relativeDirectory.isEmpty,
               VendorHeuristics.isVendoredProject(path: relativeDirectory, entries: siblingNames) {
                vendored.append(relativeDirectory)
                skip(relativeDirectory, .vendored)
                directories.removeAll { $0 == relativeDirectory }
                continue
            }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
                let values = try? entry.resourceValues(forKeys: Set(keys))

                if values?.isSymbolicLink == true {
                    skip(relative, .symlink)
                    continue
                }
                let isDir = values?.isDirectory ?? false

                if isDir {
                    if name.hasPrefix(".") && name != ".github" {
                        skip(relative, .hidden)
                        continue
                    }
                    if ScanOptions.projectBundleSuffixes.contains(where: { name.hasSuffix($0) }) {
                        bundles.append(ProjectBundle(path: relative, ignored: ignores.isIgnored(relative, isDirectory: true)))
                    }
                    if isExcludedDirectory(name: name, siblings: siblingNames) {
                        skip(relative, .defaultExclusion)
                        continue
                    }
                    if ignores.isIgnored(relative, isDirectory: true) {
                        skip(relative, .ignoredByRule)
                        continue
                    }
                    directories.append(relative)
                    pending.append((entry, relative, ignores))
                    continue
                }

                guard collectFiles else { continue }
                guard values?.isRegularFile ?? true else { continue }
                if name.hasPrefix(".") {
                    skip(relative, .hidden)
                    continue
                }
                if ScanOptions.excludedFileNames.contains(name) || isExcludedFileName(name) {
                    skip(relative, .defaultExclusion)
                    continue
                }
                let ext = (name as NSString).pathExtension.lowercased()
                if ScanOptions.binaryExtensions.contains(ext) {
                    skip(relative, .binary)
                    continue
                }
                if ignores.isIgnored(relative, isDirectory: false) {
                    skip(relative, .ignoredByRule)
                    continue
                }
                let size = values?.fileSize ?? 0
                if size > options.maxFileSize {
                    skip(relative, .tooLarge)
                    continue
                }
                let language = Language.detect(fileName: name)
                if language == .unknown && !options.includeNonCodeText {
                    continue
                }
                if language == .unknown && !ext.isEmpty && !Self.knownTextExtensions.contains(ext) {
                    // Unknown extensions are usually assets or tool output; keep only extension-less files
                    // (scripts, Makefile-likes) and recognised text formats.
                    skip(relative, .binary)
                    continue
                }
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                files.append(ScannedFile(path: relative, size: size, modified: modified, language: language))
                if files.count >= options.maxFiles {
                    truncated = true
                    break
                }
            }
            if truncated { break }
        }

        files.sort { $0.path < $1.path }
        directories.sort()
        // `.gitmodules` is hidden, so the walk skips it; the project model needs it to label submodule packages.
        let submodules = (try? String(contentsOf: root.appendingPathComponent(".gitmodules"), encoding: .utf8)).map(GitSubmodule.parse) ?? []
        return ScanResult(
            root: root, files: files, directories: directories, skipped: skipped, skippedCount: skippedCount, errors: errors,
            truncated: truncated, vendoredDirectories: vendored.sorted(), projectBundles: bundles.sorted { $0.path < $1.path }, submodules: submodules
        )
    }

    /// Whether the walk's ignore rules exclude `path`: the same stack `scan()` builds on its way down.
    public func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        var stack = initialIgnoreStack()
        if options.respectGitignore {
            var folder = ""
            for component in path.split(separator: "/").dropLast() {
                folder = folder.isEmpty ? String(component) : folder + "/" + component
                let url = root.appendingPathComponent(folder)
                if let ruleSet = loadIgnoreFile(url.appendingPathComponent(".gitignore"), base: folder) { stack.push(ruleSet) }
                if let ruleSet = loadIgnoreFile(url.appendingPathComponent(".vesaliusignore"), base: folder) { stack.push(ruleSet) }
            }
        }
        return stack.isIgnored(path, isDirectory: isDirectory)
    }

    /// The Xcode projects and workspaces directly inside already-scanned folders (the `directories` of a
    /// scan): what `scan()` records, without walking the tree again.
    public func projectBundles(in directories: [String]) -> [ProjectBundle] {
        var bundles: [ProjectBundle] = []
        for directory in directories {
            let url = directory.isEmpty ? root : root.appendingPathComponent(directory)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { continue }
            for name in names where !name.hasPrefix(".") && ScanOptions.projectBundleSuffixes.contains(where: { name.hasSuffix($0) }) {
                let path = directory.isEmpty ? name : directory + "/" + name
                bundles.append(ProjectBundle(path: path, ignored: isIgnored(path, isDirectory: true)))
            }
        }
        return bundles.sorted { $0.path < $1.path }
    }

    /// The ignore file and line that exclude `path` (`.git/info/exclude:14`, `Sub/.gitignore:3`), checking
    /// sources in git's precedence order: `.vesaliusignore`/`.gitignore` from the path's folder up to the root,
    /// then `.git/info/exclude`, the global excludes file and the user's exclusions. Reads the files directly,
    /// so it costs no git process. Nil when nothing ignores the path.
    public func ignoreSource(of path: String, isDirectory: Bool) -> String? {
        var sources: [(label: String, url: URL, base: String)] = []
        var folder = (path as NSString).deletingLastPathComponent
        while true {
            for name in [".vesaliusignore", ".gitignore"] {
                let label = folder.isEmpty ? name : folder + "/" + name
                sources.append((label, root.appendingPathComponent(label), folder))
            }
            if folder.isEmpty { break }
            folder = (folder as NSString).deletingLastPathComponent
        }
        sources.append((".git/info/exclude", root.appendingPathComponent(".git/info/exclude"), ""))
        if let global = Self.globalExcludesFile() { sources.append(((global.path as NSString).abbreviatingWithTildeInPath, global, "")) }
        for source in sources {
            guard let text = try? String(contentsOf: source.url, encoding: .utf8) else { continue }
            // Within one file the last matching line decides.
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().reversed() {
                guard let pattern = IgnorePattern(line: String(line)),
                      let ignored = IgnoreRuleSet(baseDirectory: source.base, patterns: [pattern]).decision(forRepositoryPath: path, isDirectory: isDirectory) else { continue }
                if ignored { return "\(source.label):\(offset + 1)" }
                break
            }
        }
        if !options.userExclusions.isEmpty,
           IgnoreStack([IgnoreRuleSet(baseDirectory: "", contents: options.userExclusions.joined(separator: "\n"))]).isIgnored(path, isDirectory: isDirectory) {
            return "user exclusions"
        }
        return nil
    }

    static let knownTextExtensions: Set<String> = ["txt", "cfg", "ini", "conf", "env", "properties", "gradle", "proto", "graphql", "gql", "prisma", "tf", "hcl", "cmake", "mk", "pbxproj", "xcconfig", "modulemap", "def", "rst", "adoc", "tex", "lua", "r", "scala", "clj", "ex", "exs", "erl", "hs", "ml", "fs", "vb", "pl", "pm", "groovy", "zig", "nim", "jl", "elm", "astro"]

    private func isExcludedDirectory(name: String, siblings: Set<String>) -> Bool {
        if options.excludedDirectoryNames.contains(name) { return true }
        for suffix in ScanOptions.excludedDirectorySuffixes where name.hasSuffix(suffix) { return true }
        // Rust/Maven/Gradle build output.
        if name == "target" && (siblings.contains("Cargo.toml") || siblings.contains("pom.xml") || siblings.contains("build.gradle")) {
            return true
        }
        if name == "out" && siblings.contains("package.json") { return true }
        return false
    }

    private func isExcludedFileName(_ name: String) -> Bool {
        name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".bundle.js") || name.hasSuffix(".chunk.js")
            || name.hasSuffix(".pbxproj") || name.hasSuffix(".xcscheme") || name.hasSuffix(".xcworkspacedata")
    }

    /// Ignore rules that apply before walking: global excludes, `.git/info/exclude`, parent `.gitignore`
    /// files between the git top-level and the selected root, the root `.gitignore`/`.vesaliusignore`
    /// and user exclusions.
    private func initialIgnoreStack() -> IgnoreStack {
        var stack = IgnoreStack()
        guard options.respectGitignore else {
            if !options.userExclusions.isEmpty {
                stack.push(IgnoreRuleSet(baseDirectory: "", contents: options.userExclusions.joined(separator: "\n")))
            }
            return stack
        }

        if let global = Self.globalExcludesFile(), let contents = try? String(contentsOf: global, encoding: .utf8) {
            stack.push(IgnoreRuleSet(baseDirectory: "", contents: contents))
        }

        // Walk up to the git top-level so .gitignore files above a selected sub-folder still apply.
        var gitTop: URL?
        var cursor = root
        var chain: [URL] = []
        for _ in 0..<40 {
            chain.append(cursor)
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
                gitTop = cursor
                break
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        if let gitTop {
            let infoExclude = gitTop.appendingPathComponent(".git/info/exclude")
            if let contents = try? String(contentsOf: infoExclude, encoding: .utf8) {
                stack.push(rebased(IgnoreRuleSet(baseDirectory: "", contents: contents), from: gitTop))
            }
            // Parent .gitignore files, outermost first (excluding the root itself, handled below).
            for directory in chain.reversed() where directory.path != root.path {
                if let contents = try? String(contentsOf: directory.appendingPathComponent(".gitignore"), encoding: .utf8) {
                    stack.push(rebased(IgnoreRuleSet(baseDirectory: "", contents: contents), from: directory))
                }
            }
        }
        if let ruleSet = loadIgnoreFile(root.appendingPathComponent(".gitignore"), base: "") { stack.push(ruleSet) }
        if let ruleSet = loadIgnoreFile(root.appendingPathComponent(".vesaliusignore"), base: "") { stack.push(ruleSet) }
        if !options.userExclusions.isEmpty {
            stack.push(IgnoreRuleSet(baseDirectory: "", contents: options.userExclusions.joined(separator: "\n")))
        }
        return stack
    }

    /// Re-expresses rules defined in an ancestor directory relative to the scan root.
    private func rebased(_ ruleSet: IgnoreRuleSet, from directory: URL) -> IgnoreRuleSet {
        let prefix = String(root.path.dropFirst(directory.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !prefix.isEmpty else { return ruleSet }
        var patterns: [IgnorePattern] = []
        for pattern in ruleSet.patterns {
            if !pattern.isAnchored {
                patterns.append(pattern)
                continue
            }
            // Anchored patterns from an ancestor only matter if they point inside the root.
            var text = String(decoding: pattern.pattern, as: UTF8.self)
            if text.hasPrefix(prefix + "/") {
                text = String(text.dropFirst(prefix.count + 1))
                var line = (pattern.isNegated ? "!" : "") + "/" + text
                if pattern.directoryOnly { line += "/" }
                if let rebasedPattern = IgnorePattern(line: line) { patterns.append(rebasedPattern) }
            } else if text.hasPrefix("**/") {
                patterns.append(pattern)
            }
        }
        return IgnoreRuleSet(baseDirectory: "", patterns: patterns)
    }

    private func loadIgnoreFile(_ url: URL, base: String) -> IgnoreRuleSet? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let ruleSet = IgnoreRuleSet(baseDirectory: base, contents: contents)
        return ruleSet.patterns.isEmpty ? nil : ruleSet
    }

    static func globalExcludesFile() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            let url = URL(fileURLWithPath: xdg).appendingPathComponent("git/ignore")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let url = home.appendingPathComponent(".config/git/ignore")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

public enum ScannerError: Error, LocalizedError, Sendable {
    case missingRepository(String)
    case notADirectory(String)
    case permissionDenied(String)

    public var errorDescription: String? {
        switch self {
        case .missingRepository(let path): "The repository at \(path) no longer exists. It may have been moved or deleted."
        case .notADirectory(let path): "\(path) is not a folder."
        case .permissionDenied(let path): "Vesalius does not have permission to read \(path)."
        }
    }
}
