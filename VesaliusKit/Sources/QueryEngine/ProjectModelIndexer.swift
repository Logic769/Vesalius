import CryptoKit
import Foundation
import RepositoryIndex
import RepositoryScanner
import VesaliusCore

/// Keeps the project model in the index: build targets and the files they compile, packages and their
/// products, and configuration links (schemes, test plans, StoreKit files, entitlements, test runners).
///
/// The pipeline calls `sync()` on every run, after modules and imports are resolved and before linking;
/// `true` means the project files changed (targets, membership rules, packages, schemes, test runners), so
/// every reference is linked again. It also records `projectFileStamps` in `meta.project_files_stamp`, which
/// lets `RepositoryEngine.staleFileCount` notice an edit to a project file the scanner never indexes (a
/// `.pbxproj`, a scheme).
///
/// Every run also reclassifies tests for all files, unchanged ones included, by build target first:
/// - a file only test bundles or SwiftPM test targets build is a test (`unit` or `ui`; non-code members are `support`);
/// - a file any other target builds is not a test, whatever its name;
/// - otherwise a JavaScript test runner's globs decide (`tests/**/*.test.ts`; other files in its test folder are `support`);
/// - otherwise `PathClassifier` guesses from the path.
///
/// `config_links` rows, by kind (`key` / `file_id`+`line` / `evidence`):
/// - `scheme-storekit`: StoreKit file path / that file / scheme name;
/// - `scheme-testplan`: test plan path / that file / `default` for the scheme's default plan;
/// - `scheme-testable`: test target the scheme tests without a plan / — / `skipped` or `skipped: A, B`;
/// - `scheme-env`: environment variable / — / `<launch|test>: <value>` (`(disabled)` appended when off);
/// - `testplan-target`: test target / the plan / `skipped: A, B` and `selected: C` joined by `; `, or `disabled`;
/// - `storekit-product`: product id / a code line with the quoted id (one row each; none: no file) / product type;
/// - `entitlement-appgroup`: app group / a code line using it / `literal`, `suiteName`, `containerURL`, or `unused`;
/// - `extension-intent`: intent class an extension's Info.plist supports / — / extension point;
/// - `runner-usage`: sub-command with its argument syntax / the script line / description (environment first);
/// - `npm-script`: script name / that `package.json` line / command;
/// - `test-config`: runner / that config line / its globs, comma-joined.
struct ProjectModelIndexer {
    let root: URL
    let store: IndexStore
    let detection: ModuleDetection
    let scan: ScanResult

    struct FileEntry {
        let id: Int64
        let path: String
        let language: Language
    }

    /// Rewrites the project-model tables where they differ and reclassifies tests. Returns true when the
    /// project files changed since the last run (`meta.project_model_hash`).
    func sync() throws -> Bool {
        let model = detection.projectModel
        let hash = Self.hash(model: model, submodules: scan.submodules)
        let changed = store.meta("project_model_hash") != hash

        var files: [FileEntry] = []
        try store.db.forEach("SELECT id, path, language FROM files") { row in
            files.append(FileEntry(id: row.int64(0), path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown))
        }
        files.sort { $0.path < $1.path }
        var moduleIDs: [String: Int64] = [:]
        try store.db.forEach("SELECT id, name, kind, root_path, manifest_path FROM modules") { row in
            moduleIDs["\(row.string(2))|\(row.string(3))"] = row.int64(0)
            if let manifest = row.optionalString(4) { moduleIDs["\(row.string(2))|\(manifest)|\(row.string(1))"] = row.int64(0) }
        }

        let plan = TargetPlan(model: model, submodules: scan.submodules, moduleIDs: moduleIDs)
        try store.db.transaction {
            let targetIDs = try store.replaceProjectStructure(targets: plan.targets.map(\.record), dependencies: plan.dependencies, packages: plan.packages)
            let memberships = plan.memberships(files: files, targetIDs: targetIDs)
            try store.replaceFileTargets(memberships)
            let links = ConfigLinker(root: root, store: store, model: model, plan: plan, targetIDs: targetIDs, files: files).links()
            try store.replaceConfigLinks(links)
            try store.applyTestClassification(classifyTests(files: files, memberships: memberships, plan: plan, targetIDs: targetIDs, runners: model.testRunners.configs))
            try store.setMeta("project_model_hash", hash)
            try store.setMeta("skipped_projects", VesaliusJSON.string(model.skippedProjects))
            try store.setMeta("project_model_warnings", VesaliusJSON.string(model.warnings))
        }
        return changed
    }

    /// Bump when `sync()` stores something new for unchanged project files: the stamp below then differs from
    /// the recorded one, so existing indexes look stale and their next refresh syncs again.
    static let version = 1
    static let versionStampKey = "#project-model-version"

    /// Repository-relative path → modification time of every file the project model reads that the scanner
    /// does not index: each Xcode project's `project.pbxproj` and shared schemes, and `.gitmodules`. (Package
    /// manifests, test plans, StoreKit files, plists and runner configs are indexed files, so the scan already
    /// notices their edits.) One extra entry, `versionStampKey`, carries the model version. Finds the projects
    /// with a folder-only walk; callers holding a scan can pass its `projectBundles` instead.
    static func projectFileStamps(root: URL) -> [String: Double] {
        projectFileStamps(root: root, bundles: (try? RepositoryScanner(root: root).projectBundles()) ?? [])
    }

    static func projectFileStamps(root: URL, bundles: [ProjectBundle]) -> [String: Double] {
        let fm = FileManager.default
        var stamps: [String: Double] = [versionStampKey: Double(version)]
        func stamp(_ relative: String) {
            let path = root.appendingPathComponent(relative).path
            if let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
                stamps[relative] = date.timeIntervalSince1970
            }
        }
        stamp(".gitmodules")
        for bundle in bundles where bundle.isProject && !bundle.ignored {
            stamp(bundle.path + "/project.pbxproj")
            let schemes = bundle.path + "/xcshareddata/xcschemes"
            for name in ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(schemes).path)) ?? []).sorted() where name.hasSuffix(".xcscheme") {
                stamp(schemes + "/" + name)
            }
        }
        return stamps
    }

    /// A digest of everything the project files say, line numbers included (they are evidence). Test plans,
    /// npm scripts and runner usage lines are left out: they live in indexed files, whose edits already count
    /// as changes, and they never change how references link.
    static func hash(model: ProjectModel, submodules: [GitSubmodule]) -> String {
        struct Digest: Encodable {
            let projects: [XcodeProject]
            let skippedProjects: [SkippedProject]
            let packages: [SwiftPackageManifest]
            let schemes: [XcodeScheme]
            let testRunners: [TestRunnerConfig]
            let submodules: [GitSubmodule]
        }
        let digest = Digest(projects: model.projects, skippedProjects: model.skippedProjects, packages: model.packages, schemes: model.schemes,
                            testRunners: model.testRunners.configs, submodules: submodules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(digest)) ?? Data()
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Tests

    private func classifyTests(files: [FileEntry], memberships: [FileTargetRecord], plan: TargetPlan, targetIDs: [Int64], runners: [TestRunnerConfig]) -> [TestClassification] {
        let index = Dictionary(uniqueKeysWithValues: targetIDs.enumerated().map { ($1, $0) })
        let byFile = Dictionary(grouping: memberships, by: \.fileID)
        let classifiers = runners.map { ($0, $0.makeClassifier()) }
        return files.map { file -> TestClassification in
            let rows = byFile[file.id] ?? []
            if !rows.isEmpty {
                let targets = rows.compactMap { row in index[row.targetID].map { (row, plan.targets[$0]) } }
                guard !targets.isEmpty, targets.allSatisfy({ $0.1.record.isTest }) else {
                    return TestClassification(fileID: file.id, isTest: false, kind: nil, evidence: nil)
                }
                let ui = targets.contains { $0.1.record.testKind == "ui" }
                // Cite the membership that decided the kind.
                let (row, target) = targets.first { !ui || $0.1.record.testKind == "ui" } ?? targets[0]
                let place = [row.evidencePath, row.evidenceLine.map(String.init)].compactMap { $0 }.joined(separator: ":")
                return TestClassification(fileID: file.id, isTest: true, kind: file.language.isCode ? (ui ? "ui" : "unit") : "support",
                                          evidence: place.isEmpty ? target.record.name : "\(place) \(target.record.name)")
            }
            for (config, classify) in classifiers {
                guard let verdict = classify(file.path) else { continue }
                let place = config.line.map { "\(config.path):\($0)" } ?? config.path
                return TestClassification(fileID: file.id, isTest: true, kind: verdict == "test" ? config.testKind : "support", evidence: place)
            }
            let isTest = PathClassifier.isTest(file.path)
            return TestClassification(fileID: file.id, isTest: isTest, kind: nil, evidence: isTest ? "path" : nil)
        }
    }
}

// MARK: - Targets, dependencies, packages and membership

/// The rows the project model turns into, plus each target's membership rules.
struct TargetPlan {
    struct Planned {
        var record: TargetRecord
        /// `xcode|<pbxproj>|<name>` or `swiftpm|<manifest>|<name>`.
        var key: String
        var rules: [Rule]
    }

    /// Files a target builds: everything under `path` (or exactly `path`), minus `excluded`, limited to `only`.
    struct Rule {
        var path: String
        var via: String
        var evidencePath: String?
        var evidenceLine: Int?
        var excluded: [String] = []
        var only: [String]? = nil
    }

    private(set) var targets: [Planned] = []
    private(set) var dependencies: [TargetDependencyRecord] = []
    private(set) var packages: [PackageRecord] = []
    private var indexByKey: [String: Int] = [:]

    init(model: ProjectModel, submodules: [GitSubmodule], moduleIDs: [String: Int64]) {
        // Xcode targets.
        for project in model.projects {
            let projectFolder = (project.path as NSString).deletingLastPathComponent
            for target in project.targets {
                var rules: [Rule] = []
                for group in target.synchronizedGroups {
                    rules.append(Rule(path: group.path, via: "sync-root", evidencePath: project.pbxprojPath, evidenceLine: group.line ?? target.line, excluded: group.excluded.map(\.path)))
                }
                for entry in target.buildPhaseFiles {
                    rules.append(Rule(path: entry.path, via: "build-phase", evidencePath: project.pbxprojPath, evidenceLine: entry.line))
                }
                for entry in target.addedFiles {
                    rules.append(Rule(path: entry.path, via: "exception-add", evidencePath: project.pbxprojPath, evidenceLine: entry.line))
                }
                if !target.hasMembershipData {
                    rules.append(Rule(path: ProjectPaths.join(projectFolder, target.name), via: "legacy-folder", evidencePath: project.pbxprojPath, evidenceLine: target.line))
                }
                add(Planned(
                    record: TargetRecord(
                        name: target.name, moduleName: target.moduleName, system: "xcode", productType: target.productType, platform: target.platform,
                        deploymentTarget: target.deploymentTarget, bundleID: target.bundleID, isTest: target.isTest, testKind: target.testKind,
                        testHost: target.testHost, projectPath: project.pbxprojPath, projectLine: target.line, infoPlistPath: target.infoPlistPath,
                        entitlementsPath: target.entitlementsPath, extensionPoint: target.extensionPoint,
                        moduleID: moduleIDs["\(ModuleKind.xcodeTarget.rawValue)|\(project.path)|\(target.name)"]
                    ),
                    key: "xcode|\(project.pbxprojPath)|\(target.name)",
                    rules: rules
                ))
            }
        }
        // SwiftPM targets.
        for manifest in model.packages {
            for target in manifest.targets where target.kind != "binaryTarget" {
                let rule = Rule(path: target.path, via: "swiftpm-path", evidencePath: manifest.path, evidenceLine: target.line, excluded: target.exclude, only: target.sources)
                add(Planned(
                    record: TargetRecord(
                        name: target.name, moduleName: ProjectPaths.c99Identifier(target.name), system: "swiftpm", productType: target.kind, platform: nil,
                        deploymentTarget: nil, bundleID: nil, isTest: target.isTest, testKind: target.isTest ? "unit" : nil, testHost: nil,
                        projectPath: manifest.path, projectLine: target.line, infoPlistPath: nil, entitlementsPath: nil, extensionPoint: nil,
                        moduleID: moduleIDs["\(ModuleKind.swiftPackageTarget.rawValue)|\(target.path)"]
                    ),
                    key: "swiftpm|\(manifest.path)|\(target.name)",
                    rules: [rule]
                ))
            }
        }

        // Dependencies, now that every target has an index.
        for project in model.projects {
            for target in project.targets {
                guard let from = indexByKey["xcode|\(project.pbxprojPath)|\(target.name)"] else { continue }
                for dependency in target.dependencies {
                    var resolved: Int?
                    switch dependency.kind {
                    case "product":
                        resolved = productTarget(dependency.name, package: dependency.package, model: model)
                    default:
                        resolved = indexByKey["xcode|\(project.pbxprojPath)|\(dependency.name)"]
                    }
                    dependencies.append(TargetDependencyRecord(target: from, kind: dependency.kind, name: dependency.name, dependency: resolved, package: dependency.package,
                                                               evidencePath: project.pbxprojPath, evidenceLine: dependency.line))
                }
            }
        }
        for manifest in model.packages {
            let ownTargets = Set(manifest.targets.map(\.name))
            for target in manifest.targets {
                guard let from = indexByKey["swiftpm|\(manifest.path)|\(target.name)"] else { continue }
                for dependency in target.dependencies {
                    let sameTarget = dependency.kind != "product" && ownTargets.contains(dependency.name)
                    let kind = sameTarget ? "target" : "product"
                    let resolved = sameTarget
                        ? indexByKey["swiftpm|\(manifest.path)|\(dependency.name)"]
                        : productTarget(dependency.name, package: dependency.package, model: model, from: manifest)
                    dependencies.append(TargetDependencyRecord(target: from, kind: kind, name: dependency.name, dependency: resolved, package: dependency.package,
                                                               evidencePath: manifest.path, evidenceLine: dependency.line))
                }
            }
        }

        // Packages: local manifests (submodules marked), then remote and unindexed local references.
        var seen = Set<String>()
        for manifest in model.packages {
            let submodule = submodules.first { $0.path == manifest.directory }
            packages.append(PackageRecord(
                name: manifest.name ?? (manifest.directory as NSString).lastPathComponent, path: manifest.directory, url: submodule?.url,
                kind: submodule == nil ? "local" : "submodule", manifestPath: manifest.path,
                products: manifest.products.map { PackageProductRecord(name: $0.name, kind: $0.kind, targets: $0.targets.joined(separator: ","), manifestLine: $0.line) }
            ))
            seen.insert("local|\(manifest.directory)")
        }
        var references: [(kind: String, location: String, name: String)] = []
        for project in model.projects {
            references.append(contentsOf: project.packageReferences.map { ($0.kind, $0.location, $0.name) })
        }
        for manifest in model.packages {
            references.append(contentsOf: manifest.dependencies.filter { $0.kind != "registry" }.map { ($0.kind == "url" ? "remote" : "local", $0.location, $0.identity) })
        }
        for reference in references {
            let key = reference.kind == "remote" ? "remote|\(Self.normalizedURL(reference.location))" : "local|\(reference.location)"
            guard seen.insert(key).inserted else { continue }
            packages.append(PackageRecord(
                name: reference.name, path: reference.kind == "local" ? reference.location : nil, url: reference.kind == "remote" ? reference.location : nil,
                kind: reference.kind, manifestPath: nil, products: []
            ))
        }
    }

    private mutating func add(_ planned: Planned) {
        guard indexByKey[planned.key] == nil else { return }
        indexByKey[planned.key] = targets.count
        targets.append(planned)
    }

    /// The SwiftPM target behind a product: the product's first target in the package that declares it.
    private func productTarget(_ product: String, package: String?, model: ProjectModel, from: SwiftPackageManifest? = nil) -> Int? {
        let candidates = model.packages.filter { manifest in
            guard manifest.products.contains(where: { $0.name == product }) else { return false }
            guard let package else { return true }
            let identities = [manifest.name, (manifest.directory as NSString).lastPathComponent].compactMap { $0 }
            return identities.contains { $0.caseInsensitiveCompare(package) == .orderedSame }
                || from?.dependencies.contains { $0.identity.caseInsensitiveCompare(package) == .orderedSame && $0.location == manifest.directory } == true
        }
        guard let manifest = candidates.first, let name = manifest.products.first(where: { $0.name == product })?.targets.first else { return nil }
        return indexByKey["swiftpm|\(manifest.path)|\(name)"]
    }

    static func normalizedURL(_ url: String) -> String {
        var text = url.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        return text
    }

    /// `file_targets` rows. A file gets one row per target; rules are applied in the order sync-root,
    /// swiftpm-path, build-phase, exception-add, legacy-folder, and within one package only the target with
    /// the deepest folder claims a file.
    func memberships(files: [ProjectModelIndexer.FileEntry], targetIDs: [Int64]) -> [FileTargetRecord] {
        var filesUnder: [String: [Int]] = [:]
        var fileIndex: [String: Int] = [:]
        for (index, file) in files.enumerated() {
            fileIndex[file.path] = index
            var folder = Substring("")
            filesUnder["", default: []].append(index)
            for component in file.path.split(separator: "/").dropLast() {
                folder = folder.isEmpty ? component : Substring(String(folder) + "/" + component)
                filesUnder[String(folder), default: []].append(index)
            }
        }
        func matching(_ rule: Rule) -> [Int] {
            var candidates = filesUnder[rule.path] ?? []
            if let exact = fileIndex[rule.path] { candidates.append(exact) }
            return candidates.filter { index in
                let path = files[index].path
                if rule.excluded.contains(where: { ProjectPaths.contains($0, path) }) { return false }
                if let only = rule.only, !only.contains(where: { ProjectPaths.contains($0, path) }) { return false }
                return true
            }
        }

        var rows: [FileTargetRecord] = []
        var claimed = Set<[Int64]>()
        var claimedInPackage = Set<String>()
        let order = ["sync-root", "swiftpm-path", "build-phase", "exception-add", "legacy-folder"]
        for via in order {
            var entries: [(target: Int, rule: Rule)] = []
            for (index, planned) in targets.enumerated() {
                for rule in planned.rules where rule.via == via { entries.append((index, rule)) }
            }
            if via == "swiftpm-path" { entries.sort { $0.rule.path.count > $1.rule.path.count } }
            for (target, rule) in entries where targetIDs.indices.contains(target) {
                let targetID = targetIDs[target]
                for index in matching(rule) {
                    let file = files[index]
                    if via == "swiftpm-path" {
                        guard claimedInPackage.insert("\(rule.evidencePath ?? "")|\(file.path)").inserted else { continue }
                    }
                    guard claimed.insert([file.id, targetID]).inserted else { continue }
                    rows.append(FileTargetRecord(fileID: file.id, targetID: targetID, via: via, evidencePath: rule.evidencePath, evidenceLine: rule.evidenceLine))
                }
            }
        }
        return rows
    }

    /// The index of a target by name, preferring the given project.
    func target(named name: String, in pbxprojPath: String?) -> Int? {
        if let pbxprojPath, let index = indexByKey["xcode|\(pbxprojPath)|\(name)"] { return index }
        return targets.firstIndex { $0.record.system == "xcode" && $0.record.name == name } ?? targets.firstIndex { $0.record.name == name }
    }
}

// MARK: - Configuration links

/// Builds `config_links` rows from schemes, test plans, StoreKit files, entitlements, extension Info.plists
/// and test runners. Code lines come from full-text candidates confirmed by reading the files.
private struct ConfigLinker {
    let root: URL
    let store: IndexStore
    let model: ProjectModel
    let plan: TargetPlan
    let targetIDs: [Int64]
    let files: [ProjectModelIndexer.FileEntry]

    private var filesByPath: [String: ProjectModelIndexer.FileEntry] {
        Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func links() -> [ConfigLinkRecord] {
        let byPath = filesByPath
        var rows: [ConfigLinkRecord] = []
        func targetID(_ name: String?, project: String?) -> Int64? {
            guard let name, let index = plan.target(named: name, in: project.map { $0 + "/project.pbxproj" }), targetIDs.indices.contains(index) else { return nil }
            return targetIDs[index]
        }

        for scheme in model.schemes {
            if let storeKit = scheme.storeKitConfiguration {
                rows.append(ConfigLinkRecord(configPath: scheme.path, configLine: storeKit.line, kind: "scheme-storekit", key: storeKit.path, fileID: byPath[storeKit.path]?.id,
                                             line: nil, targetID: targetID(scheme.launchTarget, project: scheme.projectPath), evidence: scheme.name))
            }
            for testPlan in scheme.testPlans {
                rows.append(ConfigLinkRecord(configPath: scheme.path, configLine: testPlan.line, kind: "scheme-testplan", key: testPlan.path, fileID: byPath[testPlan.path]?.id,
                                             line: nil, targetID: nil, evidence: testPlan.isDefault ? "default" : nil))
            }
            for testable in scheme.testables {
                let evidence = testable.isSkipped ? "skipped" : testable.skippedTests.isEmpty ? nil : "skipped: " + testable.skippedTests.joined(separator: ", ")
                rows.append(ConfigLinkRecord(configPath: scheme.path, configLine: testable.line, kind: "scheme-testable", key: testable.target, fileID: nil, line: nil,
                                             targetID: targetID(testable.target, project: scheme.projectPath), evidence: evidence))
            }
            for variable in scheme.environment {
                rows.append(ConfigLinkRecord(configPath: scheme.path, configLine: variable.line, kind: "scheme-env", key: variable.key, fileID: nil, line: nil,
                                             targetID: nil, evidence: "\(variable.action): \(variable.value)" + (variable.isEnabled ? "" : " (disabled)")))
            }
        }

        for testPlan in model.testPlans {
            for target in testPlan.targets {
                var parts: [String] = []
                if !target.isEnabled { parts.append("disabled") }
                if !target.skippedTests.isEmpty { parts.append("skipped: " + target.skippedTests.joined(separator: ", ")) }
                if !target.selectedTests.isEmpty { parts.append("selected: " + target.selectedTests.joined(separator: ", ")) }
                rows.append(ConfigLinkRecord(configPath: testPlan.path, configLine: target.line, kind: "testplan-target", key: target.name, fileID: byPath[testPlan.path]?.id,
                                             line: nil, targetID: targetID(target.name, project: nil), evidence: parts.isEmpty ? nil : parts.joined(separator: "; ")))
            }
        }

        rows.append(contentsOf: storeKitProducts())
        rows.append(contentsOf: appGroups(targetID: targetID))

        for project in model.projects {
            for target in project.targets where !target.intentsSupported.isEmpty {
                guard let plist = target.infoPlistPath else { continue }
                let text = read(plist) ?? ""
                for intent in target.intentsSupported {
                    rows.append(ConfigLinkRecord(configPath: plist, configLine: ProjectPaths.firstLine(containing: "<string>\(intent)</string>", in: text), kind: "extension-intent",
                                                 key: intent, fileID: nil, line: nil, targetID: targetID(target.name, project: project.path), evidence: target.extensionPoint))
                }
            }
        }

        for usage in model.testRunners.usageLines {
            let evidence = usage.environment.map { "\($0) · \(usage.description)" } ?? usage.description
            rows.append(ConfigLinkRecord(configPath: usage.path, configLine: usage.line, kind: "runner-usage", key: usage.command, fileID: byPath[usage.path]?.id,
                                         line: usage.line, targetID: nil, evidence: evidence))
        }
        for script in model.testRunners.npmScripts {
            rows.append(ConfigLinkRecord(configPath: script.path, configLine: script.line, kind: "npm-script", key: script.name, fileID: byPath[script.path]?.id,
                                         line: script.line, targetID: nil, evidence: script.command))
        }
        for config in model.testRunners.configs {
            rows.append(ConfigLinkRecord(configPath: config.path, configLine: config.line, kind: "test-config", key: config.runner, fileID: byPath[config.path]?.id,
                                         line: config.line, targetID: nil, evidence: config.patterns.joined(separator: ", ")))
        }
        return rows
    }

    // MARK: StoreKit

    private func storeKitProducts() -> [ConfigLinkRecord] {
        var rows: [ConfigLinkRecord] = []
        for file in files where file.path.hasSuffix(".storekit") {
            guard let text = read(file.path), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { continue }
            var products: [(id: String, type: String?)] = []
            collectProducts(object, into: &products)
            for product in products {
                let line = ProjectPaths.firstLine(containing: "\"\(product.id)\"", in: text)
                let uses = literalUses(of: product.id, limit: 10)
                if uses.isEmpty {
                    rows.append(ConfigLinkRecord(configPath: file.path, configLine: line, kind: "storekit-product", key: product.id, fileID: nil, line: nil, targetID: nil, evidence: product.type))
                }
                for use in uses {
                    rows.append(ConfigLinkRecord(configPath: file.path, configLine: line, kind: "storekit-product", key: product.id, fileID: use.file.id, line: use.line, targetID: nil, evidence: product.type))
                }
            }
        }
        return rows
    }

    private func collectProducts(_ value: Any, into products: inout [(id: String, type: String?)]) {
        if let object = value as? [String: Any] {
            if let id = object["productID"] as? String, !products.contains(where: { $0.id == id }) {
                products.append((id, object["type"] as? String))
            }
            for key in object.keys.sorted() { collectProducts(object[key]!, into: &products) }
        } else if let array = value as? [Any] {
            for element in array { collectProducts(element, into: &products) }
        }
    }

    // MARK: App groups

    private func appGroups(targetID: (String?, String?) -> Int64?) -> [ConfigLinkRecord] {
        var rows: [ConfigLinkRecord] = []
        var usesByGroup: [String: [ConfigUse]] = [:]
        for project in model.projects {
            for target in project.targets {
                guard let entitlements = target.entitlementsPath, let text = read(entitlements),
                      let plist = (try? PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)) as? [String: Any],
                      let groups = plist["com.apple.security.application-groups"] as? [String] else { continue }
                for group in groups {
                    if usesByGroup[group] == nil { usesByGroup[group] = appGroupUses(group) }
                    let line = ProjectPaths.firstLine(containing: "<string>\(group)</string>", in: text)
                    let owner = targetID(target.name, project.path)
                    let uses = usesByGroup[group] ?? []
                    if uses.isEmpty {
                        rows.append(ConfigLinkRecord(configPath: entitlements, configLine: line, kind: "entitlement-appgroup", key: group, fileID: nil, line: nil, targetID: owner, evidence: "unused"))
                    }
                    for use in uses {
                        rows.append(ConfigLinkRecord(configPath: entitlements, configLine: line, kind: "entitlement-appgroup", key: group, fileID: use.file.id, line: use.line, targetID: owner, evidence: use.how))
                    }
                }
            }
        }
        return rows
    }

    /// Lines with the group id as a string literal, and `suiteName:`/`containerURL(` lines that use the
    /// constant such a literal is assigned to (`static let appGroupID = "group.…"`).
    private func appGroupUses(_ group: String) -> [ConfigUse] {
        let literals = literalUses(of: group, limit: 6)
        var uses = literals.map { ConfigUse(file: $0.file, line: $0.line, how: Self.apiUse($0.text) ?? "literal") }
        var constants = Set<String>()
        for literal in literals {
            if let match = literal.text.firstMatch(of: /(?:let|var|const)\s+([A-Za-z_][A-Za-z0-9_]*)/) { constants.insert(String(match.1)) }
        }
        for constant in constants.sorted() {
            for file in candidates(matching: constant) {
                guard let text = read(file.path) else { continue }
                for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.contains(constant) {
                    guard let how = Self.apiUse(line), !uses.contains(where: { $0.file.id == file.id && $0.line == offset + 1 }) else { continue }
                    uses.append(ConfigUse(file: file, line: offset + 1, how: how))
                    if uses.count >= 12 { return uses }
                }
            }
        }
        return uses
    }

    private static func apiUse(_ line: Substring) -> String? {
        if line.contains("suiteName") { return "suiteName" }
        if line.contains("containerURL") || line.contains("forSecurityApplicationGroupIdentifier") { return "containerURL" }
        return nil
    }

    // MARK: Code search

    struct ConfigUse {
        let file: ProjectModelIndexer.FileEntry
        let line: Int
        let how: String
    }

    /// Code lines that contain `literal` in quotes, in files the full-text index says mention it.
    private func literalUses(of literal: String, limit: Int) -> [(file: ProjectModelIndexer.FileEntry, line: Int, text: Substring)] {
        var uses: [(file: ProjectModelIndexer.FileEntry, line: Int, text: Substring)] = []
        for file in candidates(matching: literal) {
            guard let text = read(file.path) else { continue }
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("\"\(literal)\"") || line.contains("'\(literal)'") || line.contains("`\(literal)`") {
                uses.append((file, offset + 1, line))
                if uses.count >= limit { return uses }
            }
        }
        return uses
    }

    /// Code files whose indexed text contains the words of `term`, in path order. Best effort: a query the
    /// full-text index rejects finds nothing rather than failing the index run.
    private func candidates(matching term: String) -> [ProjectModelIndexer.FileEntry] {
        let phrase = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        var ids = Set<Int64>()
        try? store.db.forEach("SELECT rowid FROM fts_files WHERE fts_files MATCH ? LIMIT 400", ["body : " + phrase]) { ids.insert($0.int64(0)) }
        return files.filter { ids.contains($0.id) && $0.language.isCode }
    }

    private func read(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path)), data.count < 4_000_000 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
