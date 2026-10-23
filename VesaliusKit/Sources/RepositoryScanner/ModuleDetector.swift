import Foundation
import VesaliusCore

/// TypeScript/JavaScript path-mapping configuration from a `tsconfig.json`/`jsconfig.json`.
public struct TSConfigInfo: Sendable, Hashable {
    /// Directory containing the config (repository-relative).
    public var directory: String
    /// `baseUrl` resolved to a repository-relative directory.
    public var baseURL: String?
    /// `paths` aliases, e.g. `@/*` → [`src/*`], with targets resolved relative to the repository.
    public var paths: [(pattern: String, targets: [String])]

    public static func == (lhs: TSConfigInfo, rhs: TSConfigInfo) -> Bool {
        lhs.directory == rhs.directory && lhs.baseURL == rhs.baseURL && lhs.paths.map(\.pattern) == rhs.paths.map(\.pattern)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(directory)
        hasher.combine(baseURL)
    }
}

public struct WorkspacePackage: Sendable, Hashable {
    public var name: String
    public var directory: String
    /// Entry files declared in package.json (`source`, `module`, `main`, `types`), repository-relative.
    public var entries: [String]
}

public struct ModuleDetection: Sendable {
    public var modules: [ModuleInfo]
    public var manifestDependencies: [String]
    public var tsconfigs: [TSConfigInfo]
    public var workspacePackages: [WorkspacePackage]
    public var pythonSourceRoots: [String]
    public var goModulePath: String?
    /// Swift files that declare `@main`-style entry points are detected by analyzers; manifest-declared
    /// entry files (package.json main/bin, setup.py console scripts) are listed here.
    public var entryFiles: Set<String>
    /// Build targets, packages, schemes, test plans and test runners read from the project files.
    public var projectModel: ProjectModel
}

/// What the project files say about the build: the Xcode projects in use (and the ones skipped), Swift
/// package manifests, shared schemes, test plans and test runners. `ProjectModelIndexer` stores it.
public struct ProjectModel: Sendable, Hashable, Codable {
    /// Xcode projects that are not ignored and, among projects defining the same targets, tracked by git.
    public var projects: [XcodeProject]
    public var skippedProjects: [SkippedProject]
    public var packages: [SwiftPackageManifest]
    public var schemes: [XcodeScheme]
    public var testPlans: [XcodeTestPlan]
    public var testRunners: TestRunnerDetection
    public var warnings: [String]

    public init(projects: [XcodeProject] = [], skippedProjects: [SkippedProject] = [], packages: [SwiftPackageManifest] = [], schemes: [XcodeScheme] = [],
                testPlans: [XcodeTestPlan] = [], testRunners: TestRunnerDetection = TestRunnerDetection(), warnings: [String] = []) {
        self.projects = projects
        self.skippedProjects = skippedProjects
        self.packages = packages
        self.schemes = schemes
        self.testPlans = testPlans
        self.testRunners = testRunners
        self.warnings = warnings
    }
}

/// An Xcode project the model does not read, and why.
public struct SkippedProject: Sendable, Hashable, Codable {
    public var path: String
    /// `git-excluded` (`.git/info/exclude`), `gitignored`, `ignored` (other ignore rules), `untracked` (git does
    /// not track it and a tracked project defines the same targets) or `unreadable`.
    public var reason: String
    /// The rule or project behind the reason (`.git/info/exclude:14`, `same targets as App.xcodeproj`).
    public var evidence: String?

    public init(path: String, reason: String, evidence: String?) {
        self.path = path
        self.reason = reason
        self.evidence = evidence
    }
}

/// Detects modules/packages from manifests and repository layout.
public struct ModuleDetector: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// - Parameter projectBundles: the scan's Xcode projects and workspaces; when nil they are looked up in
    ///   `directories` under the same ignore rules.
    public func detect(files: [ScannedFile], directories: [String], projectBundles: [ProjectBundle]? = nil) -> ModuleDetection {
        let paths = Set(files.map(\.path))
        let directorySet = Set(directories)
        var modules: [ModuleInfo] = []
        var dependencies: Set<String> = []
        var tsconfigs: [TSConfigInfo] = []
        var workspaces: [WorkspacePackage] = []
        var entryFiles: Set<String> = []
        var goModule: String?
        var manifests: [SwiftPackageManifest] = []

        for file in files {
            let name = (file.path as NSString).lastPathComponent
            let directory = (file.path as NSString).deletingLastPathComponent
            switch name {
            case "Package.swift":
                guard let text = read(file.path) else { continue }
                let manifest = SwiftPackageManifest.parse(text: text, path: file.path, directories: directorySet)
                manifests.append(manifest)
                let declared = manifest.targets.isEmpty && manifest.isPartial
                    ? legacySwiftPackageTargets(text: text, path: file.path, directory: directory, directories: directorySet)
                    : manifest.targets.filter { $0.kind != "binaryTarget" }.map { ModuleInfo(name: $0.name, kind: .swiftPackageTarget, rootPath: $0.path, manifestPath: file.path, language: .swift) }
                modules.append(contentsOf: declared.filter { directorySet.contains($0.rootPath) || $0.rootPath.isEmpty })
                dependencies.formUnion(manifest.dependencies.filter { $0.kind != "registry" }.map(\.identity))
            case "package.json":
                if let (package, deps, entries) = parsePackageJSON(at: file.path, directory: directory, paths: paths) {
                    modules.append(ModuleInfo(name: package.name, kind: .npmPackage, rootPath: directory, manifestPath: file.path, language: .typescript))
                    workspaces.append(package)
                    dependencies.formUnion(deps)
                    entryFiles.formUnion(entries)
                }
            case "tsconfig.json", "jsconfig.json":
                if let config = parseTSConfig(at: file.path, directory: directory) { tsconfigs.append(config) }
            case "pyproject.toml", "setup.py", "setup.cfg":
                let (name, deps) = parsePythonManifest(at: file.path)
                if let name, !modules.contains(where: { $0.rootPath == directory && $0.kind == .pythonPackage }) {
                    modules.append(ModuleInfo(name: name, kind: .pythonPackage, rootPath: directory, manifestPath: file.path, language: .python))
                }
                dependencies.formUnion(deps)
            case "requirements.txt", "requirements-dev.txt", "Pipfile":
                dependencies.formUnion(parseRequirements(at: file.path))
            case "go.mod":
                if let text = read(file.path), let line = text.split(separator: "\n").first(where: { $0.hasPrefix("module ") }) {
                    let path = line.dropFirst("module ".count).trimmingCharacters(in: .whitespaces)
                    goModule = path
                    modules.append(ModuleInfo(name: (path as NSString).lastPathComponent, kind: .goModule, rootPath: directory, manifestPath: file.path, language: .go))
                }
            case "Cargo.toml":
                if let text = read(file.path), let name = firstTOMLValue("name", in: text) {
                    modules.append(ModuleInfo(name: name, kind: .cargoCrate, rootPath: directory, manifestPath: file.path, language: .rust))
                }
            case "Podfile":
                if let text = read(file.path) {
                    for match in text.matches(of: /pod\s+['"]([^'"]+)['"]/) { dependencies.insert(String(match.1)) }
                }
            default:
                break
            }
        }

        let bundles = projectBundles ?? RepositoryScanner(root: root).projectBundles(in: directories)
        var model = detectProjects(bundles: bundles, manifests: manifests)
        modules.append(contentsOf: xcodeModules(projects: model.projects, directories: directorySet, existing: modules))
        model.schemes = sharedSchemes(of: model.projects)
        model.testPlans = testPlans(files: files, schemes: model.schemes)
        model.testRunners = TestRunnerDetector(root: root).detect(files: files)

        // Python packages: top-level directories with __init__.py whose parent is not a package.
        var pythonRoots: Set<String> = [""]
        for path in paths where path.hasSuffix("/__init__.py") || path == "__init__.py" {
            let package = (path as NSString).deletingLastPathComponent
            let parent = (package as NSString).deletingLastPathComponent
            let parentInit = parent.isEmpty ? "__init__.py" : parent + "/__init__.py"
            if !paths.contains(parentInit) {
                pythonRoots.insert(parent)
                if !modules.contains(where: { $0.rootPath == package }) {
                    modules.append(ModuleInfo(name: (package as NSString).lastPathComponent, kind: .pythonPackage, rootPath: package, manifestPath: nil, language: .python))
                }
            }
        }
        if directorySet.contains("src") { pythonRoots.insert("src") }

        // De-duplicate by (kind, root) keeping the first.
        var seen = Set<String>()
        modules = modules.filter { seen.insert("\($0.kind.rawValue)|\($0.rootPath)").inserted }

        return ModuleDetection(
            modules: modules,
            manifestDependencies: dependencies.sorted(),
            tsconfigs: tsconfigs,
            workspacePackages: workspaces,
            pythonSourceRoots: pythonRoots.sorted(),
            goModulePath: goModule,
            entryFiles: entryFiles,
            projectModel: model
        )
    }

    // MARK: - Swift Package Manager

    /// The pre-manifest-parser regex, kept for manifests the static reader cannot follow at all.
    private func legacySwiftPackageTargets(text: String, path: String, directory: String, directories: Set<String>) -> [ModuleInfo] {
        var modules: [ModuleInfo] = []
        let pattern = /\.(target|executableTarget|testTarget|macro|plugin|systemLibrary|binaryTarget)\s*\(\s*name:\s*"([^"]+)"/
        let ranges = text.matches(of: pattern)
        for (index, match) in ranges.enumerated() {
            let kind = String(match.1)
            let name = String(match.2)
            guard kind != "binaryTarget" else { continue }
            // Look for an explicit path: within this target's declaration (until the next target).
            let end = index + 1 < ranges.count ? ranges[index + 1].range.lowerBound : text.endIndex
            let declaration = text[match.range.lowerBound..<end]
            let root = declaration.firstMatch(of: /path:\s*"([^"]+)"/).map { join(directory, String($0.1)) }
                ?? SwiftPackageManifest.defaultPath(kind: kind, name: name, directory: directory, directories: directories)
            modules.append(ModuleInfo(name: name, kind: .swiftPackageTarget, rootPath: root, manifestPath: path, language: .swift))
        }
        return modules
    }

    // MARK: - Xcode

    /// Parses the Xcode projects the model should read. An ignored project (a git-excluded
    /// AtlasSandbox.xcodeproj) is skipped; so is an untracked project when a tracked one defines the same
    /// targets.
    private func detectProjects(bundles: [ProjectBundle], manifests: [SwiftPackageManifest]) -> ProjectModel {
        var model = ProjectModel(packages: manifests)
        let git = GitRepository(root: root)
        let scanner = RepositoryScanner(root: root)
        var parsed: [XcodeProject] = []
        for bundle in bundles where bundle.isProject {
            if bundle.ignored {
                let source = scanner.ignoreSource(of: bundle.path, isDirectory: true)
                let reason = source.map { $0.contains("info/exclude") ? "git-excluded" : $0.contains(".gitignore") ? "gitignored" : "ignored" } ?? "ignored"
                model.skippedProjects.append(SkippedProject(path: bundle.path, reason: reason, evidence: source))
                continue
            }
            guard var project = XcodeProject.load(bundle: bundle.path, root: root) else {
                model.skippedProjects.append(SkippedProject(path: bundle.path, reason: "unreadable", evidence: nil))
                continue
            }
            // Some product dependencies do not say which package provides them; local manifests do.
            let localPackages = Set(project.packageReferences.filter { $0.kind == "local" }.map(\.location))
            for (targetIndex, target) in project.targets.enumerated() {
                for (dependencyIndex, dependency) in target.dependencies.enumerated() where dependency.kind == "product" && dependency.package == nil {
                    let providers = manifests.filter { manifest in manifest.products.contains { $0.name == dependency.name } }
                    let provider = providers.first { localPackages.contains($0.directory) } ?? providers.first
                    project.targets[targetIndex].dependencies[dependencyIndex].package = provider.map { $0.name ?? ($0.directory as NSString).lastPathComponent }
                }
            }
            model.warnings.append(contentsOf: project.warnings)
            parsed.append(project)
        }

        // Two readable projects with the same targets (a scratch copy of the real one): keep what git tracks.
        let signatures = parsed.map { Set($0.targets.map(\.name)) }
        let duplicated = parsed.indices.filter { index in
            !signatures[index].isEmpty && parsed.indices.contains { $0 != index && signatures[$0] == signatures[index] }
        }
        if !duplicated.isEmpty, let tracked = git.trackedPaths(duplicated.map { parsed[$0].pbxprojPath }) {
            var dropped = Set<Int>()
            for index in duplicated where !tracked.contains(parsed[index].pbxprojPath) {
                guard let twin = duplicated.first(where: { $0 != index && signatures[$0] == signatures[index] && tracked.contains(parsed[$0].pbxprojPath) }) else { continue }
                dropped.insert(index)
                model.skippedProjects.append(SkippedProject(path: parsed[index].path, reason: "untracked", evidence: "same targets as \(parsed[twin].path)"))
            }
            parsed = parsed.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        }
        model.projects = parsed.sorted { $0.path < $1.path }
        model.skippedProjects.sort { $0.path < $1.path }
        return model
    }

    /// One module per native target. Its root is the target's first synchronized folder, else the folder
    /// shared by its build-phase files, else (no membership data, as in a hand-written project) a folder
    /// named like the target next to the project.
    private func xcodeModules(projects: [XcodeProject], directories: Set<String>, existing: [ModuleInfo]) -> [ModuleInfo] {
        var results: [ModuleInfo] = []
        for project in projects {
            let projectFolder = (project.path as NSString).deletingLastPathComponent
            for target in project.targets {
                var folder: String?
                if let synchronized = target.synchronizedGroups.first {
                    folder = synchronized.path
                } else if !target.buildPhaseFiles.isEmpty {
                    let shared = Self.commonFolder(target.buildPhaseFiles.map { ($0.path as NSString).deletingLastPathComponent })
                    folder = shared.isEmpty ? nil : shared
                }
                if folder == nil, !target.hasMembershipData { folder = join(projectFolder, target.name) }
                guard let folder, !folder.isEmpty, directories.contains(folder),
                      !existing.contains(where: { $0.rootPath == folder }), !results.contains(where: { $0.rootPath == folder }) else { continue }
                results.append(ModuleInfo(name: target.name, kind: .xcodeTarget, rootPath: folder, manifestPath: project.path, language: .swift))
            }
        }
        return results
    }

    static func commonFolder(_ folders: [String]) -> String {
        guard var common = folders.first?.split(separator: "/").map(String.init) else { return "" }
        for folder in folders.dropFirst() {
            let parts = folder.split(separator: "/").map(String.init)
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
            if common.isEmpty { break }
        }
        return common.joined(separator: "/")
    }

    /// Shared schemes of the projects in use (`xcshareddata` only: user schemes are personal).
    private func sharedSchemes(of projects: [XcodeProject]) -> [XcodeScheme] {
        var schemes: [XcodeScheme] = []
        for project in projects {
            let folder = join(project.path, "xcshareddata/xcschemes")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? []
            for name in names.sorted() where name.hasSuffix(".xcscheme") {
                if let scheme = XcodeScheme.load(path: join(folder, name), projectPath: project.path, root: root) { schemes.append(scheme) }
            }
        }
        return schemes
    }

    /// Every indexed test plan plus the ones schemes reference.
    private func testPlans(files: [ScannedFile], schemes: [XcodeScheme]) -> [XcodeTestPlan] {
        var paths = Set(files.map(\.path).filter { $0.hasSuffix(".xctestplan") })
        for scheme in schemes { paths.formUnion(scheme.testPlans.map(\.path)) }
        return paths.sorted().compactMap { XcodeTestPlan.load(path: $0, root: root) }
    }

    // MARK: - npm

    private func parsePackageJSON(at path: String, directory: String, paths: Set<String>) -> (WorkspacePackage, [String], [String])? {
        guard let data = read(path).map({ Data($0.utf8) }),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let name = (object["name"] as? String) ?? (directory.isEmpty ? root.lastPathComponent : (directory as NSString).lastPathComponent)
        var dependencies: [String] = []
        for key in ["dependencies", "devDependencies", "peerDependencies"] {
            if let deps = object[key] as? [String: Any] { dependencies.append(contentsOf: deps.keys) }
        }
        var entries: [String] = []
        for key in ["source", "module", "main", "types", "typings", "browser"] {
            if let value = object[key] as? String { entries.append(value) }
        }
        if let bin = object["bin"] as? String { entries.append(bin) }
        if let bin = object["bin"] as? [String: String] { entries.append(contentsOf: bin.values) }
        if let exports = object["exports"] as? String { entries.append(exports) }
        if let exports = object["exports"] as? [String: Any] {
            for value in exports.values {
                if let string = value as? String { entries.append(string) }
                if let nested = value as? [String: Any] { entries.append(contentsOf: nested.values.compactMap { $0 as? String }) }
            }
        }
        let resolvedEntries = entries.compactMap { entry -> String? in
            let candidate = join(directory, entry.hasPrefix("./") ? String(entry.dropFirst(2)) : entry)
            if paths.contains(candidate) { return candidate }
            // dist/index.js → src/index.ts is the usual source mapping.
            let sourceGuess = candidate.replacingOccurrences(of: "dist/", with: "src/").replacingOccurrences(of: "lib/", with: "src/")
            for ext in ["", ".ts", ".tsx", ".js"] {
                let base = ext.isEmpty ? sourceGuess : (sourceGuess as NSString).deletingPathExtension + ext
                if paths.contains(base) { return base }
            }
            return nil
        }
        let package = WorkspacePackage(name: name, directory: directory, entries: resolvedEntries)
        return (package, dependencies, resolvedEntries)
    }

    private func parseTSConfig(at path: String, directory: String) -> TSConfigInfo? {
        guard let text = read(path) else { return nil }
        let cleaned = Self.stripJSONComments(text)
        guard let object = try? JSONSerialization.jsonObject(with: Data(cleaned.utf8)) as? [String: Any] else { return nil }
        let options = object["compilerOptions"] as? [String: Any] ?? [:]
        let baseURL = (options["baseUrl"] as? String).map { join(directory, $0) }
        var mapped: [(String, [String])] = []
        if let paths = options["paths"] as? [String: [String]] {
            let base = baseURL ?? directory
            for (pattern, targets) in paths {
                mapped.append((pattern, targets.map { join(base, $0) }))
            }
        }
        guard baseURL != nil || !mapped.isEmpty else { return nil }
        return TSConfigInfo(directory: directory, baseURL: baseURL, paths: mapped.sorted { $0.0.count > $1.0.count })
    }

    /// Removes `//` and `/* */` comments and trailing commas so JSONC parses with JSONSerialization.
    static func stripJSONComments(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        var iterator = Array(text)
        var i = 0
        while i < iterator.count {
            let c = iterator[i]
            if inString {
                output.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                output.append(c)
                i += 1
            } else if c == "/" && i + 1 < iterator.count && iterator[i + 1] == "/" {
                while i < iterator.count && iterator[i] != "\n" { i += 1 }
            } else if c == "/" && i + 1 < iterator.count && iterator[i + 1] == "*" {
                i += 2
                while i + 1 < iterator.count && !(iterator[i] == "*" && iterator[i + 1] == "/") { i += 1 }
                i += 2
            } else {
                output.append(c)
                i += 1
            }
        }
        iterator = []
        return output.replacing(/,(\s*[}\]])/) { match in String(match.1) }
    }

    // MARK: - Python

    private func parsePythonManifest(at path: String) -> (String?, [String]) {
        guard let text = read(path) else { return (nil, []) }
        var name: String?
        if path.hasSuffix(".toml") {
            name = firstTOMLValue("name", in: text)
        } else if let match = text.firstMatch(of: /name\s*=\s*['"]([^'"]+)['"]/) {
            name = String(match.1)
        }
        var dependencies: [String] = []
        if let block = text.firstMatch(of: /dependencies\s*=\s*\[([\s\S]*?)\]/) {
            for match in String(block.1).matches(of: /['"]([A-Za-z0-9_.\-]+)/) { dependencies.append(String(match.1).lowercased()) }
        }
        if let block = text.firstMatch(of: /install_requires\s*=\s*\[([\s\S]*?)\]/) {
            for match in String(block.1).matches(of: /['"]([A-Za-z0-9_.\-]+)/) { dependencies.append(String(match.1).lowercased()) }
        }
        return (name, dependencies)
    }

    private func parseRequirements(at path: String) -> [String] {
        guard let text = read(path) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("-") else { return nil }
            let name = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
            return name.isEmpty ? nil : name.lowercased()
        }
    }

    // MARK: - Helpers

    private func firstTOMLValue(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) else { continue }
            let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("=") else { continue }
            let value = rest.dropFirst().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func read(_ relativePath: String) -> String? {
        let url = root.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url), data.count < 2_000_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func join(_ directory: String, _ path: String) -> String {
        var components = directory.isEmpty ? [] : directory.split(separator: "/").map(String.init)
        for part in path.split(separator: "/") {
            switch part {
            case ".", "": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }
}
