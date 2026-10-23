import Foundation
import RepositoryIndex
import VesaliusCore

/// The `architecture` tool's engine: the repository's structure from the project model and type-level
/// references. Every fact comes from a table or a line of a file: targets, membership and dependencies from
/// `targets`/`target_deps`/`file_targets` (read from project.pbxproj and Package.swift), packages from
/// `packages`/`package_products`, folder edges from references whose target is a type, app groups from
/// `config_links`. Nothing is inferred from folder or type names except the container folders that are
/// expanded (`Features/`), and style is reported as counts.
extension RepositoryEngine {
    public func architectureOverview(focus: String? = nil) throws -> ArchitectureOverview {
        let text = focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Once per index version and focus text; a focus that names nothing throws and is not kept.
        var overview = try memoized("architecture|" + text) {
            let context = try ArchitectureContext(engine: self)
            return try computeArchitecture(context, focus: context.resolveFocus(text))
        }
        // Checked on every call: a file edited after the memo was filled must still be caught.
        overview.staleFiles = try staleFiles(Self.citedFiles(overview))
        return overview
    }

    /// Files the overview quotes line numbers from.
    static func citedFiles(_ overview: ArchitectureOverview) -> [String] {
        var paths = Set<String>()
        for target in overview.targets {
            if let path = target.entry?.path, target.entry?.line != nil { paths.insert(path) }
        }
        for module in overview.modules {
            for edge in module.upward { paths.insert(edge.path) }
            for cycle in module.cycles {
                paths.insert(cycle.forward.path)
                for back in cycle.back { paths.insert(back.path) }
            }
            if let root = module.composition {
                paths.insert(root.path)
                for store in root.stores { paths.insert(store.path) }
            }
        }
        for duplicate in overview.crossTarget.duplicates {
            for site in duplicate.sites { paths.insert(site.path) }
        }
        return paths.sorted()
    }

    private func computeArchitecture(_ context: ArchitectureContext, focus: ArchitectureOverview.Focus?) throws -> ArchitectureOverview {
        var overview = ArchitectureOverview(projects: context.projectNames, skippedProjects: context.skippedProjects, focus: focus)
        if context.targets.isEmpty {
            overview.languages = context.languageCounts()
            overview.sourceFolders = context.sourceFolders()
        }
        let shown = context.shownTargets(focus: focus)
        overview.targets = try shown.map { try context.summary(of: $0) }
        if focus == nil || focus?.kind == .folder {
            overview.notBuilt = context.unbuiltCode(under: focus?.kind == .folder ? focus?.name : nil)
        }
        overview.packages = try context.packageSummaries(focus: focus)

        let moduleTargets = context.moduleTargets(focus: focus)
        var modules: [ArchitectureOverview.Module] = []
        for target in moduleTargets {
            let folder = focus?.kind == .folder ? focus?.name : nil
            if var module = try context.module(of: target, folder: folder) {
                if folder == nil, target.isApp {
                    module.composition = try context.compositionRoot(of: target)
                }
                modules.append(module)
            }
        }
        if context.targets.isEmpty, let module = try context.sourceModule(folder: focus?.kind == .folder ? focus?.name : nil) {
            modules.append(module)
        }
        overview.modules = modules

        if focus == nil || focus?.kind == .target {
            overview.crossTarget = try context.crossTarget(focus: focus?.kind == .target ? focus?.name : nil)
            overview.style = try context.styles(of: moduleTargets.filter(\.isApp))
        }
        return overview
    }
}

// MARK: - The project model, loaded once per computation

/// The rows the overview is built from, read once: files, targets, memberships, dependencies, packages.
struct ArchitectureContext {
    struct FileRow {
        let id: Int64
        let path: String
        let language: Language
        let isTest: Bool
        let isGenerated: Bool
    }

    struct TargetRow {
        let id: Int64
        let name: String
        let moduleName: String?
        let system: String
        let productType: String?
        let platform: String?
        let deploymentTarget: String?
        let bundleID: String?
        let isTest: Bool
        let testKind: String?
        let testHost: String?
        let projectPath: String?
        let projectLine: Int?
        let infoPlistPath: String?
        let entitlementsPath: String?
        let extensionPoint: String?
        let moduleID: Int64?
        /// `app`, `watch`, `widget`…, or the name when two targets would share a role.
        var role: String = ""

        var isApp: Bool {
            system == "xcode" && !isTest && (productType?.hasPrefix("com.apple.product-type.application") ?? false)
                && productType != "com.apple.product-type.application.watchapp2-container"
        }
    }

    struct Membership {
        let target: Int64
        let via: String
        let evidencePath: String?
        let evidenceLine: Int?
    }

    struct DependencyRow {
        let target: Int64
        let kind: String
        let name: String
        let dependency: Int64?
        let package: String?
    }

    struct PackageRow {
        let id: Int64
        let name: String
        let path: String?
        let url: String?
        let kind: String
        let manifest: String?
    }

    let engine: RepositoryEngine
    let db: SQLiteDatabase
    let files: [Int64: FileRow]
    let fileIDs: [String: Int64]
    let targets: [TargetRow]
    let targetsByID: [Int64: TargetRow]
    /// File → the targets building it, in target order.
    let memberships: [Int64: [Membership]]
    /// Target → its files.
    let targetFiles: [Int64: [Int64]]
    let dependencies: [DependencyRow]
    let packages: [PackageRow]
    let products: [Int64: [ArchitectureOverview.Product]]
    let moduleRoots: [Int64: String]
    let skippedProjects: [ArchitectureOverview.SkippedProject]
    let vendored: [String]

    /// Languages Xcode and SwiftPM targets compile: code in them that no target builds is reported.
    static let buildLanguages: Set<Language> = [.swift, .objectiveC, .c, .cpp]

    init(engine: RepositoryEngine) throws {
        self.engine = engine
        let db = try engine.db
        self.db = db
        var files: [Int64: FileRow] = [:]
        var fileIDs: [String: Int64] = [:]
        try db.forEach("SELECT id, path, language, is_test, is_generated FROM files") { row in
            let file = FileRow(id: row.int64(0), path: row.string(1), language: Language(rawValue: row.string(2)) ?? .unknown, isTest: row.bool(3), isGenerated: row.bool(4))
            files[file.id] = file
            fileIDs[file.path] = file.id
        }
        self.files = files
        self.fileIDs = fileIDs

        var targets = try db.query("""
            SELECT id, name, module_name, system, product_type, platform, deployment_target, bundle_id, is_test, test_kind, test_host,
                   project_path, project_line, info_plist_path, entitlements_path, extension_point, module_id
            FROM targets ORDER BY id
            """) { row in
            TargetRow(id: row.int64(0), name: row.string(1), moduleName: row.optionalString(2), system: row.string(3), productType: row.optionalString(4),
                      platform: row.optionalString(5), deploymentTarget: row.optionalString(6), bundleID: row.optionalString(7), isTest: row.bool(8),
                      testKind: row.optionalString(9), testHost: row.optionalString(10), projectPath: row.optionalString(11), projectLine: row.optionalInt(12),
                      infoPlistPath: row.optionalString(13), entitlementsPath: row.optionalString(14), extensionPoint: row.optionalString(15), moduleID: row.optionalInt64(16))
        }
        Self.assignRoles(&targets)
        self.targets = targets
        self.targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })

        var memberships: [Int64: [Membership]] = [:]
        var targetFiles: [Int64: [Int64]] = [:]
        try db.forEach("SELECT file_id, target_id, via, evidence_path, evidence_line FROM file_targets ORDER BY target_id, file_id") { row in
            let membership = Membership(target: row.int64(1), via: row.string(2), evidencePath: row.optionalString(3), evidenceLine: row.optionalInt(4))
            memberships[row.int64(0), default: []].append(membership)
            targetFiles[membership.target, default: []].append(row.int64(0))
        }
        self.memberships = memberships
        self.targetFiles = targetFiles

        self.dependencies = try db.query("SELECT target_id, kind, name, dep_target_id, package FROM target_deps ORDER BY rowid") { row in
            DependencyRow(target: row.int64(0), kind: row.string(1), name: row.string(2), dependency: row.optionalInt64(3), package: row.optionalString(4))
        }
        self.packages = try db.query("SELECT id, name, path, url, kind, manifest_path FROM packages ORDER BY id") { row in
            PackageRow(id: row.int64(0), name: row.optionalString(1) ?? "", path: row.optionalString(2), url: row.optionalString(3), kind: row.optionalString(4) ?? "local", manifest: row.optionalString(5))
        }
        var products: [Int64: [ArchitectureOverview.Product]] = [:]
        try db.forEach("SELECT package_id, name, kind, targets FROM package_products ORDER BY rowid") { row in
            guard let package = row.optionalInt64(0) else { return }
            let targets = (row.optionalString(3) ?? "").split(separator: ",").map { String($0) }
            products[package, default: []].append(ArchitectureOverview.Product(name: row.optionalString(1) ?? "", kind: row.optionalString(2) ?? "library", targets: targets))
        }
        self.products = products
        var moduleRoots: [Int64: String] = [:]
        try db.forEach("SELECT id, root_path FROM modules") { moduleRoots[$0.int64(0)] = $0.string(1) }
        self.moduleRoots = moduleRoots

        let store = try engine.store()
        struct Skipped: Decodable {
            let path: String
            let reason: String
            let evidence: String?
        }
        let skipped = store.meta("skipped_projects").flatMap { try? VesaliusJSON.decoder().decode([Skipped].self, from: Data($0.utf8)) } ?? []
        self.skippedProjects = skipped.map { ArchitectureOverview.SkippedProject(path: $0.path, reason: $0.reason, evidence: $0.evidence) }
        self.vendored = store.meta("vendored_directories").flatMap { try? VesaliusJSON.decoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    // MARK: Roles

    /// Short, unique names for targets in cross-target lines.
    static func assignRoles(_ targets: inout [TargetRow]) {
        var proposed = targets.map(Self.role(of:))
        let counts = Dictionary(proposed.map { ($0, 1) }, uniquingKeysWith: +)
        for index in proposed.indices where counts[proposed[index], default: 0] > 1 { proposed[index] = targets[index].name }
        for index in targets.indices { targets[index].role = proposed[index] }
    }

    static func role(of target: TargetRow) -> String {
        guard target.system == "xcode" else { return target.name }
        switch target.productType ?? "" {
        case "com.apple.product-type.application", "com.apple.product-type.application.on-demand-install-capable":
            return target.platform == "watchOS" ? "watch" : "app"
        case "com.apple.product-type.application.watchapp2":
            return "watch"
        case "com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ocunit-test":
            return "tests"
        case "com.apple.product-type.bundle.ui-testing":
            return "UI tests"
        case "com.apple.product-type.app-extension", "com.apple.product-type.extensionkit-extension":
            switch target.extensionPoint ?? "" {
            case "com.apple.widgetkit-extension", "com.apple.widget-extension": return "widget"
            case "com.apple.intents-service": return "intents"
            case "com.apple.intents-ui-service": return "intents UI"
            case "com.apple.share-services": return "share"
            case "com.apple.usernotifications.content-extension": return "notification content"
            case "com.apple.usernotifications.service": return "notification service"
            default: return target.name
            }
        default:
            return target.name
        }
    }

    /// The product as people say it: `iOS app`, `WidgetKit extension`, `unit tests`, `library`.
    static func kind(of target: TargetRow) -> String {
        guard target.system == "xcode" else {
            switch target.productType ?? "" {
            case "executableTarget": return "executable"
            case "testTarget": return "tests"
            case "macro": return "macro"
            case "plugin": return "plugin"
            case "systemLibrary": return "system library"
            case "binaryTarget": return "binary"
            default: return "library"
            }
        }
        let platform = target.platform.map { $0 + " " } ?? ""
        switch target.productType ?? "" {
        case "com.apple.product-type.application": return platform + "app"
        case "com.apple.product-type.application.on-demand-install-capable": return "App Clip"
        case "com.apple.product-type.application.watchapp2": return "watchOS app"
        case "com.apple.product-type.application.watchapp2-container": return "watch app container"
        case "com.apple.product-type.app-extension", "com.apple.product-type.extensionkit-extension":
            return extensionKind(target.extensionPoint)
        case "com.apple.product-type.app-extension.messages": return "iMessage extension"
        case "com.apple.product-type.watchkit2-extension": return "watch extension"
        case "com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ocunit-test": return "unit tests"
        case "com.apple.product-type.bundle.ui-testing": return "UI tests"
        case "com.apple.product-type.framework": return platform + "framework"
        case "com.apple.product-type.library.static": return "static library"
        case "com.apple.product-type.library.dynamic": return "dynamic library"
        case "com.apple.product-type.tool": return "command-line tool"
        case "com.apple.product-type.xpc-service": return "XPC service"
        case "com.apple.product-type.bundle": return "bundle"
        case "": return "target"
        default:
            return (target.productType ?? "").replacingOccurrences(of: "com.apple.product-type.", with: "")
        }
    }

    static func extensionKind(_ point: String?) -> String {
        switch point ?? "" {
        case "com.apple.widgetkit-extension": return "WidgetKit extension"
        case "com.apple.widget-extension": return "Today widget extension"
        case "com.apple.intents-service": return "SiriKit Intents extension"
        case "com.apple.intents-ui-service": return "SiriKit Intents UI extension"
        case "com.apple.share-services": return "share extension"
        case "com.apple.usernotifications.content-extension": return "notification content extension"
        case "com.apple.usernotifications.service": return "notification service extension"
        case "com.apple.appintents-extension": return "App Intents extension"
        case "com.apple.fileprovider-nonui", "com.apple.fileprovider-actionsui": return "File Provider extension"
        case "com.apple.message-payload-provider": return "iMessage extension"
        case "com.apple.Safari.web-extension": return "Safari web extension"
        case "com.apple.keyboard-service": return "keyboard extension"
        case "com.apple.photo-editing": return "photo editing extension"
        case "com.apple.broadcast-services-upload": return "broadcast upload extension"
        case "com.apple.ui-services": return "action extension"
        case "": return "app extension"
        case let other where other.hasPrefix("com.apple.networkextension"): return "network extension"
        case let other: return "extension (" + other.replacingOccurrences(of: "com.apple.", with: "") + ")"
        }
    }

    // MARK: Projects

    /// `Atlas.xcodeproj`, then root and other package manifests that are not inside another package.
    var projectNames: [String] {
        var names: [String] = []
        for target in targets where target.system == "xcode" {
            guard let project = target.projectPath else { continue }
            let bundle = project.hasSuffix("/project.pbxproj") ? String(project.dropLast("/project.pbxproj".count)) : project
            if !names.contains(bundle) { names.append(bundle) }
        }
        if names.isEmpty {
            for package in packages where package.manifest != nil && !isNested(package) {
                if let manifest = package.manifest, !names.contains(manifest) { names.append(manifest) }
            }
        }
        return names
    }

    var xcodeTargets: [TargetRow] { targets.filter { $0.system == "xcode" } }

    /// The targets the TARGETS section lists: the Xcode targets, or for a package repository the root
    /// package's targets.
    var listedTargets: [TargetRow] {
        let xcode = xcodeTargets
        if !xcode.isEmpty { return xcode }
        guard let root = rootPackage?.manifest else { return [] }
        return targets.filter { $0.projectPath == root }
    }

    /// The package whose manifest is the repository's `Package.swift` (or, failing that, the shallowest one).
    var rootPackage: PackageRow? {
        let manifests = packages.filter { $0.manifest != nil }
        return manifests.first { $0.manifest == "Package.swift" } ?? manifests.min { ($0.manifest ?? "").count < ($1.manifest ?? "").count }
    }

    func isNested(_ package: PackageRow) -> Bool {
        guard let path = package.path, !path.isEmpty else { return false }
        return packages.contains { other in
            guard other.id != package.id, other.manifest != nil, let otherPath = other.path else { return false }
            return otherPath.isEmpty ? false : path.hasPrefix(otherPath + "/")
        }
    }

    func shownTargets(focus: ArchitectureOverview.Focus?) -> [TargetRow] {
        let listed = listedTargets
        guard let focus else { return Self.ordered(listed, dependencies: dependencies) }
        switch focus.kind {
        case .target:
            return targets.filter { $0.name == focus.name }
        case .package:
            guard let package = packages.first(where: { Self.focusName($0) == focus.name }), let manifest = package.manifest else { return [] }
            return targets.filter { $0.projectPath == manifest }
        case .folder:
            var ids = Set<Int64>()
            for (fileID, rows) in memberships where Self.contains(folder: focus.name, path: files[fileID]?.path ?? "") {
                ids.formUnion(rows.map(\.target))
            }
            return Self.ordered(targets.filter { ids.contains($0.id) }, dependencies: dependencies)
        }
    }

    /// Apps first, then what they embed, then other targets, tests last (each group in project order).
    static func ordered(_ targets: [TargetRow], dependencies: [DependencyRow]) -> [TargetRow] {
        let embedded = Set(dependencies.filter { $0.kind == "embed" }.compactMap(\.dependency))
        func rank(_ target: TargetRow) -> Int {
            if target.isTest { return 3 }
            if target.isApp && !embedded.contains(target.id) { return 0 }
            return target.system == "xcode" ? 1 : 2
        }
        return targets.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// How a package is named in `focus`: its folder, or its name when it has none (remote, or the root).
    static func focusName(_ package: PackageRow) -> String {
        package.path.flatMap { $0.isEmpty ? nil : $0 } ?? package.name
    }

    static func contains(folder: String, path: String) -> Bool {
        folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
    }

    // MARK: Focus

    /// Resolves `focus` to a target, a package or a folder. Ambiguity and misses name what is accepted.
    func resolveFocus(_ text: String?) throws -> ArchitectureOverview.Focus? {
        guard var query = text?.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return nil }
        let rootPath = engine.root.path + "/"
        if query.hasPrefix(rootPath) { query = String(query.dropFirst(rootPath.count)) }
        if query.hasPrefix("./") { query = String(query.dropFirst(2)) }
        while query.hasSuffix("/") { query.removeLast() }
        if query.isEmpty || query == "." { return nil }
        // A package named like one of its own targets (`AtlasKit`) means the package.
        let packageNamed = packages.first { $0.manifest != nil && !($0.path ?? "").isEmpty && $0.name.caseInsensitiveCompare(query) == .orderedSame }
        if let target = targets.first(where: { $0.name == query }) ?? targets.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame || $0.moduleName == query }),
           !(target.system == "swiftpm" && packageNamed.map { target.projectPath == $0.manifest } == true) {
            return ArchitectureOverview.Focus(kind: .target, name: target.name)
        }
        // A role (`watch`, `widget`); a target without one goes by its name, matched above.
        let roleMatches = targets.filter { $0.role != $0.name && $0.role.caseInsensitiveCompare(query) == .orderedSame }
        if roleMatches.count == 1 { return ArchitectureOverview.Focus(kind: .target, name: roleMatches[0].name) }
        if let package = packages.first(where: { $0.path == query && $0.path?.isEmpty == false }) ?? packages.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return ArchitectureOverview.Focus(kind: .package, name: Self.focusName(package))
        }
        if fileIDs.keys.contains(where: { $0.hasPrefix(query + "/") }) {
            return ArchitectureOverview.Focus(kind: .folder, name: query)
        }
        // A folder named by a unique path suffix (`Features` for `Atlas/Features`).
        let folders = Set(fileIDs.keys.compactMap { path -> String? in
            guard let range = path.range(of: "/" + query + "/") else { return nil }
            return String(path[..<range.upperBound].dropLast())
        })
        if folders.count == 1, let folder = folders.first { return ArchitectureOverview.Focus(kind: .folder, name: folder) }
        if folders.count > 1 {
            let choices = folders.sorted().map { $0 + "/" }
            throw EngineError.invalidQuery("“\(text ?? query)” names \(choices.count) folders; pass one of: " + choices.prefix(8).joined(separator: ", ")
                + (choices.count > 8 ? " (+\(choices.count - 8) more)" : ""))
        }
        var suggestions = targets.filter { !$0.isTest }.map(\.name)
        suggestions += packages.filter { $0.manifest != nil }.compactMap { $0.path.flatMap { $0.isEmpty ? nil : $0 } }
        throw EngineError.notFound(text ?? query, suggestions: Array(suggestions.prefix(8)))
    }

    // MARK: Targets

    func summary(of target: TargetRow) throws -> ArchitectureOverview.Target {
        let fileList = targetFiles[target.id] ?? []
        var summary = ArchitectureOverview.Target(
            name: target.name, role: target.role, kind: Self.kind(of: target), system: target.system, platform: target.platform,
            deploymentTarget: target.deploymentTarget, bundleID: target.bundleID, isTest: target.isTest, testHost: target.testHost,
            project: target.projectPath, projectLine: target.projectLine, extensionPoint: target.extensionPoint
        )
        summary.codeFiles = fileList.filter { files[$0].map { Self.buildLanguages.contains($0.language) } ?? false }.count
        summary.roots = roots(of: target)
        summary.addedFiles = addedFiles(of: target)

        let own = dependencies.filter { $0.target == target.id }
        summary.links = Self.unique(own.filter { $0.kind == "product" || $0.kind == "framework" }.map(\.name))
        summary.embeds = Self.unique(own.filter { $0.kind == "embed" }.map(\.name))
        summary.dependsOn = Self.unique(own.filter { $0.kind == "target" }.map(\.name)).filter { !summary.embeds.contains($0) && $0 != target.testHost }
        if target.system == "swiftpm" {
            // A package target's dependencies are what it links.
            summary.links = Self.unique(own.filter { $0.kind == "product" || $0.kind == "target" }.map(\.name))
            summary.dependsOn = []
        }
        if target.isTest { summary.testFramework = try testFramework(of: target) }
        summary.intents = try db.query("SELECT key FROM config_links WHERE kind = 'extension-intent' AND target_id = ? ORDER BY rowid", [target.id]) { $0.string(0) }
        summary.entry = try entry(of: target)
        if let entry = summary.entry, entry.kind == "@main" {
            summary.registers = try registeredWidgets(of: target, entry: entry)
        }
        return summary
    }

    /// The folders a target builds, from its synchronized groups or package path (one per rule), with the
    /// code files under each. Build-phase members are grouped by their top folder.
    func roots(of target: TargetRow) -> [ArchitectureOverview.Root] {
        var groups: [String: [Int64]] = [:]
        var order: [String] = []
        for fileID in targetFiles[target.id] ?? [] {
            guard let membership = memberships[fileID]?.first(where: { $0.target == target.id }), membership.via != "exception-add",
                  let file = files[fileID] else { continue }
            let key: String
            if membership.via == "build-phase" {
                key = "phase|" + (file.path.split(separator: "/").first.map(String.init).flatMap { file.path.contains("/") ? $0 : nil } ?? "")
            } else {
                key = "\(membership.via)|\(membership.evidencePath ?? "")|\(membership.evidenceLine ?? 0)"
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(fileID)
        }
        var roots: [ArchitectureOverview.Root] = []
        for key in order {
            let ids = groups[key] ?? []
            let paths = ids.compactMap { files[$0]?.path }
            var folder = key.hasPrefix("phase|") ? String(key.dropFirst("phase|".count)) : Self.commonFolder(paths)
            if let moduleID = target.moduleID, let root = moduleRoots[moduleID], paths.allSatisfy({ Self.contains(folder: root, path: $0) }), root.count > folder.count {
                folder = root
            }
            let code = ids.compactMap { files[$0] }.filter { Self.buildLanguages.contains($0.language) }
            let language = Dictionary(grouping: code, by: \.language).max { ($0.value.count, $1.key.rawValue) < ($1.value.count, $0.key.rawValue) }?.key
            if let index = roots.firstIndex(where: { $0.path == folder }) {
                roots[index].codeFiles += code.count
            } else {
                roots.append(ArchitectureOverview.Root(path: folder, codeFiles: code.count, language: language?.rawValue))
            }
        }
        let withCode = roots.filter { $0.codeFiles > 0 }
        return (withCode.isEmpty ? roots : withCode).sorted { $0.codeFiles > $1.codeFiles }
    }

    /// Files an exception set of another target's folder adds, grouped by set, with the set's lines in the
    /// project file.
    func addedFiles(of target: TargetRow) -> [ArchitectureOverview.AddedFiles] {
        var groups: [String: (paths: [String], evidence: String?, line: Int?)] = [:]
        var order: [String] = []
        for fileID in targetFiles[target.id] ?? [] {
            guard let membership = memberships[fileID]?.first(where: { $0.target == target.id }), membership.via == "exception-add",
                  let file = files[fileID] else { continue }
            let block = membership.evidencePath.flatMap { path in membership.evidenceLine.flatMap { definitionBlock(in: path, around: $0) } }
            let key = "\(membership.evidencePath ?? "")|\(block?.lowerBound ?? membership.evidenceLine ?? 0)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = ([], membership.evidencePath, membership.evidenceLine)
            }
            groups[key]?.paths.append(file.path)
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            let block = group.evidence.flatMap { path in group.line.flatMap { definitionBlock(in: path, around: $0) } }
            return ArchitectureOverview.AddedFiles(paths: group.paths.sorted(), via: "membership exception", evidencePath: group.evidence,
                                                   firstLine: block?.lowerBound ?? group.line, lastLine: block?.upperBound ?? group.line)
        }
    }

    /// The lines of the pbxproj object definition (`ID /* … */ = { … };`) holding `line`.
    func definitionBlock(in path: String, around line: Int) -> ClosedRange<Int>? {
        guard let file = engine.sourceText.file(path), line >= 1, line <= file.lineCount else { return nil }
        // An object definition line: `D0B149422EBC468800D35E6A /* Exceptions for … */ = {` (a nested dictionary's
        // key, like `buildSettings = {`, starts lowercase).
        var start = line
        while start >= 1 {
            if let text = file.text(ofLine: start), text.firstMatch(of: /^\s*[0-9A-Z][0-9A-Za-z]*\s+(\/\*.*\*\/\s*)?=\s*\{/) != nil { break }
            start -= 1
        }
        guard start >= 1 else { return nil }
        var depth = 0
        var number = start
        while number <= min(file.lineCount, start + 2_000) {
            for character in file.text(ofLine: number) ?? "" {
                if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
            }
            if depth <= 0 {
                // The object's lines, without the line that only closes it.
                let closing = (file.text(ofLine: number) ?? "").trimmingCharacters(in: .whitespaces) == "};"
                return start...(closing && number > start ? number - 1 : number)
            }
            number += 1
        }
        return nil
    }

    /// `Swift Testing`, `XCTest` or both, from the imports of the target's files.
    func testFramework(of target: TargetRow) throws -> String? {
        let ids = Set(targetFiles[target.id] ?? [])
        guard !ids.isEmpty else { return nil }
        var testing = 0, xctest = 0
        try db.forEach("SELECT file_id, module FROM imports WHERE module IN ('Testing', 'XCTest')") { row in
            guard ids.contains(row.int64(0)) else { return }
            if row.string(1) == "Testing" { testing += 1 } else { xctest += 1 }
        }
        switch (testing > 0, xctest > 0) {
        case (true, true): return "Swift Testing + XCTest"
        case (true, false): return "Swift Testing"
        case (false, true): return "XCTest"
        default: return nil
        }
    }

    /// The `@main` type among the target's files; for an extension without one, its Info.plist principal
    /// class or storyboard.
    func entry(of target: TargetRow) throws -> ArchitectureOverview.Entry? {
        let ids = Set(targetFiles[target.id] ?? [])
        guard !ids.isEmpty else { return nil }
        let mains = try db.query("""
            SELECT s.file_id, s.name, s.start_line FROM symbols s
            WHERE s.depth = 0 AND (',' || s.attributes || ',') LIKE '%,@main,%' ORDER BY s.file_id
            """) { row in (row.int64(0), row.string(1), row.int(2)) }
        if let main = mains.first(where: { ids.contains($0.0) }), let path = files[main.0]?.path {
            return ArchitectureOverview.Entry(kind: "@main", name: main.1, path: path, line: main.2)
        }
        guard let plistPath = target.infoPlistPath, let file = engine.sourceText.file(plistPath),
              let plist = (try? PropertyListSerialization.propertyList(from: Data(file.bytes), options: [], format: nil)) as? [String: Any],
              let info = (plist["NSExtension"] ?? plist["EXAppExtensionAttributes"]) as? [String: Any] else { return nil }
        if var principal = info["NSExtensionPrincipalClass"] as? String {
            if let dot = principal.lastIndex(of: ".") { principal = String(principal[principal.index(after: dot)...]) }
            let declaration = try db.query("SELECT file_id, start_line FROM symbols WHERE name = ? AND depth = 0 ORDER BY file_id", [principal]) { ($0.int64(0), $0.int(1)) }
                .first { ids.contains($0.0) }
            return ArchitectureOverview.Entry(kind: "principal class", name: principal, path: declaration.flatMap { files[$0.0]?.path }, line: declaration?.1)
        }
        if let storyboard = info["NSExtensionMainStoryboard"] as? String {
            return ArchitectureOverview.Entry(kind: "storyboard", name: storyboard)
        }
        return nil
    }

    /// The widgets a `WidgetBundle` entry lists in its body, in order.
    func registeredWidgets(of target: TargetRow, entry: ArchitectureOverview.Entry) throws -> [String] {
        guard let path = entry.path, let fileID = fileIDs[path] else { return [] }
        let inherits = try db.queryOne("SELECT inherits FROM symbols WHERE file_id = ? AND name = ? AND depth = 0", [fileID, entry.name]) { $0.optionalString(0) } ?? nil
        guard let inherits, inherits.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "WidgetBundle" }) else { return [] }
        return Self.unique(try db.query("""
            SELECT r.name FROM refs r JOIN symbols f ON f.id = r.from_symbol_id JOIN symbols p ON p.id = f.parent_id
            WHERE r.file_id = ? AND p.name = ? AND p.depth = 0 AND r.kind = 'instantiate' AND substr(r.name, 1, 1) BETWEEN 'A' AND 'Z'
            ORDER BY r.line, r.col
            """, [fileID, entry.name]) { $0.string(0) })
    }

    // MARK: Code no target builds

    /// Build-language files outside every target (manifests, vendored and generated code left out), grouped
    /// into the largest folders that hold nothing built; a lone file in a built folder is listed by itself.
    func unbuiltCode(under folder: String?) -> [ArchitectureOverview.UnbuiltCode] {
        guard !targets.isEmpty else { return [] }
        let vendoredPrefixes = vendored.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func counts(_ file: FileRow) -> Bool {
            Self.buildLanguages.contains(file.language) && !file.isGenerated && !Self.isManifest(file.path)
                && !vendoredPrefixes.contains { file.path.hasPrefix($0) }
        }
        var builtFolders = Set<String>()
        var unbuilt: [FileRow] = []
        for file in files.values where counts(file) {
            if memberships[file.id]?.isEmpty == false {
                var parent = (file.path as NSString).deletingLastPathComponent
                while !parent.isEmpty, builtFolders.insert(parent).inserted {
                    parent = (parent as NSString).deletingLastPathComponent
                }
                builtFolders.insert("")
            } else if folder.map({ Self.contains(folder: $0, path: file.path) }) ?? true {
                unbuilt.append(file)
            }
        }
        guard !unbuilt.isEmpty else { return [] }
        // The largest ancestor holding no built file.
        var groups: [String: [FileRow]] = [:]
        for file in unbuilt {
            var top = file.path
            var parent = (file.path as NSString).deletingLastPathComponent
            while !parent.isEmpty, !builtFolders.contains(parent) {
                top = parent
                parent = (parent as NSString).deletingLastPathComponent
            }
            groups[top, default: []].append(file)
        }
        let mains = Set((try? db.query("SELECT file_id FROM symbols WHERE depth = 0 AND (',' || attributes || ',') LIKE '%,@main,%'") { $0.int64(0) }) ?? [])
        var result: [ArchitectureOverview.UnbuiltCode] = []
        for (top, members) in groups {
            let hasMain = members.contains { mains.contains($0.id) }
            if members.count == 1, members[0].path == top {
                result.append(ArchitectureOverview.UnbuiltCode(path: top, files: 1, hasMain: hasMain))
            } else {
                // The deepest folder holding all of them (`Features/Workouts/` rather than `Features/`).
                let common = Self.commonFolder(members.map(\.path))
                result.append(ArchitectureOverview.UnbuiltCode(path: (common.isEmpty ? top : common) + "/", files: members.count, hasMain: hasMain))
            }
        }
        return result.sorted { ($0.hasMain ? 0 : 1, -$0.files, $0.path) < ($1.hasMain ? 0 : 1, -$1.files, $1.path) }
    }

    static func isManifest(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "Package.swift" || (name.hasPrefix("Package@swift-") && name.hasSuffix(".swift"))
    }

    // MARK: Packages

    func packageSummaries(focus: ArchitectureOverview.Focus?) throws -> [ArchitectureOverview.Package] {
        var rows = packages.filter { !isNested($0) && !($0.kind == "local" && $0.manifest == nil) }
        // A package repository's own manifest is the TARGETS section.
        if xcodeTargets.isEmpty, let root = rootPackage { rows.removeAll { $0.id == root.id } }
        // Remote packages a local package pulls in are listed with it; the others stand alone.
        let attributed = Set(rows.filter { $0.manifest != nil }.flatMap { remoteDependencies(of: $0).map(\.id) })
        rows.removeAll { $0.kind == "remote" && attributed.contains($0.id) }
        switch focus?.kind {
        case .package:
            rows = packages.filter { Self.focusName($0) == focus?.name }
        case .target:
            let target = targets.first { $0.name == focus?.name }
            rows = rows.filter { package in
                guard let target else { return false }
                return linkers(of: package).contains(target.role) || importerTargets(of: package).contains(target.id)
            }
        case .folder:
            rows = rows.filter { package in package.path.map { Self.contains(folder: focus?.name ?? "", path: $0) } ?? false }
        case nil:
            break
        }
        return try rows.map(summary(of:))
    }

    func packageTargets(_ package: PackageRow) -> [TargetRow] {
        guard let manifest = package.manifest else { return [] }
        return targets.filter { $0.system == "swiftpm" && $0.projectPath == manifest }
    }

    func remoteDependencies(of package: PackageRow) -> [PackageRow] {
        let ids = Set(packageTargets(package).map(\.id))
        let names = dependencies.filter { ids.contains($0.target) && $0.kind == "product" }
        return packages.filter { remote in
            remote.kind == "remote" && names.contains { dependency in
                dependency.package?.caseInsensitiveCompare(remote.name) == .orderedSame || dependency.name.caseInsensitiveCompare(remote.name) == .orderedSame
            }
        }
    }

    /// Roles of the targets outside `package` that link one of its products.
    func linkers(of package: PackageRow) -> [String] {
        let own = Set(packageTargets(package).map(\.id))
        let productNames = Set((products[package.id] ?? []).map(\.name))
        var roles: [String] = []
        for dependency in dependencies where dependency.kind == "product" && !own.contains(dependency.target) {
            let matches = dependency.dependency.map { own.contains($0) } ?? false
                || dependency.package?.caseInsensitiveCompare(package.name) == .orderedSame
                || (package.kind == "remote" && productNames.isEmpty && dependency.package == nil && dependency.name.caseInsensitiveCompare(package.name) == .orderedSame)
            guard matches, let target = targetsByID[dependency.target], !roles.contains(target.role) else { continue }
            roles.append(target.role)
        }
        return roles
    }

    /// The package's targets behind the products other targets link, with their dependencies inside the
    /// package, in manifest order.
    func usedTargets(of package: PackageRow) -> [String] {
        let own = packageTargets(package)
        let ownIDs = Set(own.map(\.id))
        var used = Set<Int64>()
        for dependency in dependencies where dependency.kind == "product" && !ownIDs.contains(dependency.target) {
            if let target = dependency.dependency, ownIDs.contains(target) { used.insert(target) }
        }
        var frontier = Array(used)
        while let next = frontier.popLast() {
            for dependency in dependencies where dependency.target == next {
                if let target = dependency.dependency, ownIDs.contains(target), used.insert(target).inserted { frontier.append(target) }
            }
        }
        return own.filter { used.contains($0.id) }.map(\.name)
    }

    func importerTargets(of package: PackageRow) -> Set<Int64> {
        let modules = Set(packageTargets(package).compactMap(\.moduleID))
        guard !modules.isEmpty else { return [] }
        var result = Set<Int64>()
        try? db.forEach("SELECT file_id, resolved_module_id FROM imports WHERE resolved_module_id IS NOT NULL") { row in
            guard modules.contains(row.int64(1)) else { return }
            for membership in memberships[row.int64(0)] ?? [] { result.insert(membership.target) }
        }
        return result
    }

    func summary(of package: PackageRow) throws -> ArchitectureOverview.Package {
        var summary = ArchitectureOverview.Package(name: package.name, path: package.path.flatMap { $0.isEmpty ? nil : $0 }, kind: package.kind,
                                                   url: package.url, manifest: package.manifest, products: products[package.id] ?? [])
        let own = packageTargets(package)
        let ownIDs = Set(own.map(\.id))
        summary.targetCount = own.count
        summary.codeFiles = own.reduce(0) { total, target in
            total + (targetFiles[target.id] ?? []).filter { files[$0].map { Self.buildLanguages.contains($0.language) } ?? false }.count
        }
        for target in own where !target.isTest {
            let names = Self.unique(dependencies.filter { $0.target == target.id && ($0.kind == "target" || $0.kind == "product") }.map(\.name))
            if !names.isEmpty { summary.dependencies.append(ArchitectureOverview.Dependency(from: target.name, to: names)) }
        }
        summary.remote = remoteDependencies(of: package).map(\.name)
        if let path = package.path, !path.isEmpty {
            summary.vendored = packages.filter { $0.kind == "local" && $0.manifest == nil && ($0.path ?? "").hasPrefix(path + "/") }
                .compactMap { $0.path.map { String($0.dropFirst(path.count + 1)) } }
        }
        summary.linkedBy = linkers(of: package)
        summary.usedTargets = usedTargets(of: package)

        // Re-exports: `@_exported import` lines in the package's files.
        var reexports: [String: [String]] = [:]
        var reexportOrder: [String] = []
        try db.forEach("SELECT file_id, module FROM imports WHERE is_reexport = 1 ORDER BY file_id, line") { row in
            guard let membership = memberships[row.int64(0)]?.first(where: { ownIDs.contains($0.target) }), let target = targetsByID[membership.target] else { return }
            if reexports[target.name] == nil { reexportOrder.append(target.name) }
            if !(reexports[target.name] ?? []).contains(row.string(1)) { reexports[target.name, default: []].append(row.string(1)) }
        }
        summary.reexports = reexportOrder.map { ArchitectureOverview.Dependency(from: $0, to: reexports[$0] ?? []) }

        // Importers outside the package, per module and target.
        let moduleOwners = Dictionary(own.compactMap { target in target.moduleID.map { ($0, target) } }, uniquingKeysWith: { first, _ in first })
        var importers: [Int64: [Int64: Set<Int64>]] = [:]
        try db.forEach("SELECT file_id, resolved_module_id FROM imports WHERE resolved_module_id IS NOT NULL AND is_reexport = 0") { row in
            let module = row.int64(1)
            guard moduleOwners[module] != nil else { return }
            for membership in memberships[row.int64(0)] ?? [] where !ownIDs.contains(membership.target) {
                importers[module, default: [:]][membership.target, default: []].insert(row.int64(0))
            }
        }
        summary.importers = importers.compactMap { module, byTarget -> ArchitectureOverview.Importers? in
            guard let owner = moduleOwners[module] else { return nil }
            let counts = byTarget.compactMap { target, files -> ArchitectureOverview.RoleCount? in
                guard let row = targetsByID[target] else { return nil }
                return ArchitectureOverview.RoleCount(role: row.role, count: files.count)
            }.sorted { ($0.count, $1.role) > ($1.count, $0.role) }
            return ArchitectureOverview.Importers(module: owner.name, counts: counts)
        }.sorted { lhs, rhs in
            let left = lhs.counts.reduce(0) { $0 + $1.count }, right = rhs.counts.reduce(0) { $0 + $1.count }
            return left != right ? left > right : lhs.module < rhs.module
        }
        return summary
    }

    // MARK: Modules

    /// Targets that get a folder section: the apps nothing embeds (or, with a target focus, that target);
    /// a package repository's largest target when it has no app.
    func moduleTargets(focus: ArchitectureOverview.Focus?) -> [TargetRow] {
        func codeCount(_ target: TargetRow) -> Int {
            (targetFiles[target.id] ?? []).filter { files[$0].map { Self.buildLanguages.contains($0.language) } ?? false }.count
        }
        switch focus?.kind {
        case .target:
            return targets.filter { $0.name == focus?.name && codeCount($0) > 0 }
        case .package:
            return []
        case .folder:
            // The target building most of the folder's code.
            var counts: [Int64: Int] = [:]
            for (fileID, rows) in memberships where Self.contains(folder: focus?.name ?? "", path: files[fileID]?.path ?? "") {
                for row in rows { counts[row.target, default: 0] += 1 }
            }
            guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), let target = targetsByID[best.key] else { return [] }
            return [target]
        case nil:
            let embedded = Set(dependencies.filter { $0.kind == "embed" }.compactMap(\.dependency))
            let apps = targets.filter { $0.isApp && !embedded.contains($0.id) && codeCount($0) > 0 }
            if !apps.isEmpty { return apps.sorted { codeCount($0) > codeCount($1) }.prefix(2).map { $0 } }
            let candidates = listedTargets.filter { !$0.isTest && $0.system == "swiftpm" && codeCount($0) >= 10 }
            return Array(candidates.sorted { (codeCount($0), $1.name) > (codeCount($1), $0.name) }.prefix(2))
        }
    }

    /// Top folders by source files (tests included), most first.
    func sourceFolders() -> [ArchitectureOverview.Folder] {
        var counts: [String: Int] = [:]
        for file in files.values where file.language.isCode && !file.isGenerated {
            let top = file.path.contains("/") ? String(file.path.split(separator: "/")[0]) : "."
            counts[top, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ArchitectureOverview.Folder(name: $0.key, files: $0.value) }
    }

    /// Source files by language, most first.
    func languageCounts() -> [ArchitectureOverview.LanguageCount] {
        var counts: [Language: Int] = [:]
        for file in files.values where file.language.isCode && !file.isGenerated { counts[file.language, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
            .map { ArchitectureOverview.LanguageCount(language: $0.key.displayName, files: $0.value) }
    }

    // MARK: Helpers

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// The deepest folder holding every path, without a trailing slash ("" for the repository root).
    static func commonFolder(_ paths: [String]) -> String {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent }) else { return "" }
        for path in paths.dropFirst() {
            while !common.isEmpty && !path.hasPrefix(common + "/") {
                common = (common as NSString).deletingLastPathComponent
            }
        }
        return common
    }

    func codeFiles(of target: TargetRow) -> [FileRow] {
        (targetFiles[target.id] ?? []).compactMap { files[$0] }.filter { Self.buildLanguages.contains($0.language) }
    }
}
