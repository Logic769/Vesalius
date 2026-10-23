import Foundation

/// The repository's structure, computed from the project model (`targets`, `target_deps`,
/// `file_targets`, `packages`, `config_links`) and type-level references, never from folder names alone:
/// - build targets with what they build, link, embed and start from, and the code no target builds;
/// - local packages with their products, internal dependencies, re-exports and importers per target;
/// - each app module's folders with the dependency direction its type references show, the edges against it,
///   folder cycles, feature-to-feature edges and the composition root;
/// - the links between targets: shared source, duplicated types, framework bridges, app groups;
/// - style as counts.
///
/// The legacy `ArchitectureReport` (the app's Architecture tab, pattern percentages) is a different notion.
public struct ArchitectureOverview: Codable, Sendable, Hashable {
    /// The project files the model was read from (`Atlas.xcodeproj`, `Package.swift`); empty when the
    /// repository has neither.
    public var projects: [String]
    public var skippedProjects: [SkippedProject]
    /// What `focus` resolved to; nil for the whole repository.
    public var focus: Focus?
    public var targets: [Target]
    /// Code in a build language that no target builds, by folder.
    public var notBuilt: [UnbuiltCode]
    public var packages: [Package]
    public var modules: [Module]
    public var crossTarget: CrossTarget
    public var style: [Style]
    /// Source files by language, and the top folders holding them, for a repository without an Xcode or
    /// SwiftPM project.
    public var languages: [LanguageCount]
    public var sourceFolders: [Folder]
    /// Files cited with line numbers that were edited since indexing: those lines may have moved.
    public var staleFiles: [String]

    public init(projects: [String] = [], skippedProjects: [SkippedProject] = [], focus: Focus? = nil, targets: [Target] = [], notBuilt: [UnbuiltCode] = [],
                packages: [Package] = [], modules: [Module] = [], crossTarget: CrossTarget = CrossTarget(), style: [Style] = [],
                languages: [LanguageCount] = [], sourceFolders: [Folder] = [], staleFiles: [String] = []) {
        self.projects = projects
        self.skippedProjects = skippedProjects
        self.focus = focus
        self.targets = targets
        self.notBuilt = notBuilt
        self.packages = packages
        self.modules = modules
        self.crossTarget = crossTarget
        self.style = style
        self.languages = languages
        self.sourceFolders = sourceFolders
        self.staleFiles = staleFiles
    }

    /// A project the model left out, and why (`AtlasSandbox.xcodeproj`, `git-excluded`).
    public struct SkippedProject: Codable, Sendable, Hashable {
        public var path: String
        public var reason: String
        /// Where the reason comes from (`.git/info/exclude:14`).
        public var evidence: String?

        public init(path: String, reason: String, evidence: String? = nil) {
            self.path = path
            self.reason = reason
            self.evidence = evidence
        }
    }

    public struct Focus: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            case target, package, folder
        }

        public var kind: Kind
        /// The target name, package path (or name, for a remote package) or folder (no trailing slash).
        public var name: String

        public init(kind: Kind, name: String) {
            self.kind = kind
            self.name = name
        }
    }

    // MARK: Targets

    /// One build target: an Xcode native target, or a SwiftPM target when the repository is a package.
    public struct Target: Codable, Sendable, Hashable {
        public var name: String
        /// A short name for cross-target lines: `app`, `watch`, `widget`, `intents`, `tests`; the target's own
        /// name when that would be ambiguous.
        public var role: String
        /// The product as people say it: `iOS app`, `WidgetKit extension`, `unit tests`, `library`.
        public var kind: String
        /// `xcode` or `swiftpm`.
        public var system: String
        public var platform: String?
        public var deploymentTarget: String?
        public var bundleID: String?
        public var isTest: Bool
        /// The app a test bundle runs in.
        public var testHost: String?
        /// `Swift Testing`, `XCTest` or `Swift Testing + XCTest`, from what the target's files import.
        public var testFramework: String?
        /// The file that declares the target and the line (`Atlas.xcodeproj/project.pbxproj:316`).
        public var project: String?
        public var projectLine: Int?
        /// Folders the target builds whole, with their code files.
        public var roots: [Root]
        /// Files the target builds outside its folders (a membership exception, a build-phase entry).
        public var addedFiles: [AddedFiles]
        /// Package products and frameworks it links, in project order.
        public var links: [String]
        /// Products copied into it (extensions, a watch app).
        public var embeds: [String]
        /// Target dependencies it does not embed.
        public var dependsOn: [String]
        /// Where it starts: the `@main` type, or an extension's principal class or storyboard.
        public var entry: Entry?
        /// What its entry registers: the widgets a `WidgetBundle` lists.
        public var registers: [String]
        /// Intents its Info.plist says it handles.
        public var intents: [String]
        /// `NSExtensionPointIdentifier`.
        public var extensionPoint: String?
        /// Code files it builds (roots and added files).
        public var codeFiles: Int

        public init(name: String, role: String, kind: String, system: String, platform: String? = nil, deploymentTarget: String? = nil, bundleID: String? = nil,
                    isTest: Bool = false, testHost: String? = nil, testFramework: String? = nil, project: String? = nil, projectLine: Int? = nil,
                    roots: [Root] = [], addedFiles: [AddedFiles] = [], links: [String] = [], embeds: [String] = [], dependsOn: [String] = [],
                    entry: Entry? = nil, registers: [String] = [], intents: [String] = [], extensionPoint: String? = nil, codeFiles: Int = 0) {
            self.name = name
            self.role = role
            self.kind = kind
            self.system = system
            self.platform = platform
            self.deploymentTarget = deploymentTarget
            self.bundleID = bundleID
            self.isTest = isTest
            self.testHost = testHost
            self.testFramework = testFramework
            self.project = project
            self.projectLine = projectLine
            self.roots = roots
            self.addedFiles = addedFiles
            self.links = links
            self.embeds = embeds
            self.dependsOn = dependsOn
            self.entry = entry
            self.registers = registers
            self.intents = intents
            self.extensionPoint = extensionPoint
            self.codeFiles = codeFiles
        }
    }

    /// A folder a target builds, with its code files by language (`swift 240`).
    public struct Root: Codable, Sendable, Hashable {
        /// Repository-relative, no trailing slash; empty for the repository root.
        public var path: String
        public var codeFiles: Int
        /// The language most of its code is in (`swift`, `objc`, `c`).
        public var language: String?

        public init(path: String, codeFiles: Int, language: String? = nil) {
            self.path = path
            self.codeFiles = codeFiles
            self.language = language
        }
    }

    /// Files a target builds one by one, with the project lines that say so.
    public struct AddedFiles: Codable, Sendable, Hashable {
        public var paths: [String]
        /// `membership exception` (an exception set of another target's folder) or `build phase`.
        public var via: String
        /// The project file and the lines of the entry that adds them (`132-139` for an exception set).
        public var evidencePath: String?
        public var firstLine: Int?
        public var lastLine: Int?

        public init(paths: [String], via: String, evidencePath: String? = nil, firstLine: Int? = nil, lastLine: Int? = nil) {
            self.paths = paths
            self.via = via
            self.evidencePath = evidencePath
            self.firstLine = firstLine
            self.lastLine = lastLine
        }
    }

    public struct Entry: Codable, Sendable, Hashable {
        /// `@main`, `principal class` or `storyboard`.
        public var kind: String
        public var name: String
        public var path: String?
        public var line: Int?

        public init(kind: String, name: String, path: String? = nil, line: Int? = nil) {
            self.kind = kind
            self.name = name
            self.path = path
            self.line = line
        }
    }

    /// Code no target builds: a folder holding only such files (path ends in `/`), or a single file.
    public struct UnbuiltCode: Codable, Sendable, Hashable {
        public var path: String
        public var files: Int
        /// One of its files declares a `@main` type: an app of its own that no project builds.
        public var hasMain: Bool

        public init(path: String, files: Int, hasMain: Bool = false) {
            self.path = path
            self.files = files
            self.hasMain = hasMain
        }
    }

    // MARK: Packages

    public struct Package: Codable, Sendable, Hashable {
        public var name: String
        /// Repository-relative folder; nil for a remote package.
        public var path: String?
        /// `local`, `submodule` or `remote`.
        public var kind: String
        public var url: String?
        public var manifest: String?
        public var products: [Product]
        /// What its non-test targets depend on, inside and outside the package.
        public var dependencies: [Dependency]
        /// `@_exported import`s: the target that re-exports, and what.
        public var reexports: [Dependency]
        /// Its modules as imported by targets outside it: module → files per importing target.
        public var importers: [Importers]
        /// Remote packages its targets depend on.
        public var remote: [String]
        /// Local packages inside it that it uses by path (`Dependencies/Wax`).
        public var vendored: [String]
        /// Targets outside the package that link one of its products.
        public var linkedBy: [String]
        /// Its targets that the linked products are built from, with their dependencies inside the package.
        public var usedTargets: [String]
        public var targetCount: Int
        public var codeFiles: Int

        public init(name: String, path: String? = nil, kind: String, url: String? = nil, manifest: String? = nil, products: [Product] = [], dependencies: [Dependency] = [],
                    reexports: [Dependency] = [], importers: [Importers] = [], remote: [String] = [], vendored: [String] = [], linkedBy: [String] = [],
                    usedTargets: [String] = [], targetCount: Int = 0, codeFiles: Int = 0) {
            self.name = name
            self.path = path
            self.kind = kind
            self.url = url
            self.manifest = manifest
            self.products = products
            self.dependencies = dependencies
            self.reexports = reexports
            self.importers = importers
            self.remote = remote
            self.vendored = vendored
            self.linkedBy = linkedBy
            self.usedTargets = usedTargets
            self.targetCount = targetCount
            self.codeFiles = codeFiles
        }
    }

    public struct Product: Codable, Sendable, Hashable {
        public var name: String
        /// `library`, `executable` or `plugin`.
        public var kind: String
        public var targets: [String]

        public init(name: String, kind: String, targets: [String]) {
            self.name = name
            self.kind = kind
            self.targets = targets
        }
    }

    /// `from` depends on (or re-exports) each of `to`, in manifest order.
    public struct Dependency: Codable, Sendable, Hashable {
        public var from: String
        public var to: [String]

        public init(from: String, to: [String]) {
            self.from = from
            self.to = to
        }
    }

    public struct Importers: Codable, Sendable, Hashable {
        public var module: String
        /// Importing files per target role, most first.
        public var counts: [RoleCount]

        public init(module: String, counts: [RoleCount]) {
            self.module = module
            self.counts = counts
        }
    }

    public struct RoleCount: Codable, Sendable, Hashable {
        public var role: String
        public var count: Int

        public init(role: String, count: Int) {
            self.role = role
            self.count = count
        }
    }

    // MARK: Modules

    /// The folders of one compiled module (an app target), or of a source root in a repository without targets.
    public struct Module: Codable, Sendable, Hashable {
        /// The target, or the folder for a repository without targets.
        public var name: String
        /// The folder the folder names are relative to (no trailing slash; empty for the repository root).
        public var root: String
        /// What the folder edges are built from: `type references` (Swift) or `imports`.
        public var edgeSource: String
        /// Folders by code files, most first; container folders (`Features/`) list their children.
        public var folders: [Folder]
        /// Code files directly in the root, by name.
        public var rootFiles: [String]
        /// For each folder, the folders it mostly depends on, by weight.
        public var direction: [Dependency]
        /// References against a folder pair's dominant direction, grouped by file.
        public var upward: [UpwardEdge]
        /// Two folders that depend on each other, closed through a file: one reference each way.
        public var cycles: [FolderCycle]
        /// Dependencies between children of a container folder (`Home → Workouts`).
        public var featureEdges: [Dependency]
        public var composition: CompositionRoot?
        /// The folders compile into one module, so nothing but convention keeps the direction.
        public var isSingleModule: Bool
        /// Distinct (file, type) pairs between different folders that the edges are built from.
        public var edgeCount: Int
        /// Uses that leave the focus folder, and folders outside it that use it (folder focus only).
        public var usesOutside: [String]
        public var usedFromOutside: [String]
        /// File names that more than one file of the module has (`page.tsx`): such files are named by path.
        public var repeatedFileNames: [String]

        public init(name: String, root: String, edgeSource: String, folders: [Folder] = [], rootFiles: [String] = [], direction: [Dependency] = [],
                    upward: [UpwardEdge] = [], cycles: [FolderCycle] = [], featureEdges: [Dependency] = [], composition: CompositionRoot? = nil,
                    isSingleModule: Bool = true, edgeCount: Int = 0, usesOutside: [String] = [], usedFromOutside: [String] = [], repeatedFileNames: [String] = []) {
            self.name = name
            self.root = root
            self.edgeSource = edgeSource
            self.folders = folders
            self.rootFiles = rootFiles
            self.direction = direction
            self.upward = upward
            self.cycles = cycles
            self.featureEdges = featureEdges
            self.composition = composition
            self.isSingleModule = isSingleModule
            self.edgeCount = edgeCount
            self.usesOutside = usesOutside
            self.usedFromOutside = usedFromOutside
            self.repeatedFileNames = repeatedFileNames
        }
    }

    public struct Folder: Codable, Sendable, Hashable {
        public var name: String
        public var files: Int
        public var children: [Folder]

        public init(name: String, files: Int, children: [Folder] = []) {
            self.name = name
            self.files = files
            self.children = children
        }
    }

    /// `Services/CloudSync.swift:146 → AccountSetupSheet (Features/AccountSetup)`: the uses in one file of types
    /// in a folder that mostly depends on the file's own folder.
    public struct UpwardEdge: Codable, Sendable, Hashable {
        /// Repository-relative.
        public var path: String
        public var lines: [Int]
        public var types: [String]
        public var fromFolder: String
        public var toFolder: String
        /// Distinct (file, type) pairs each way between the two top folders: the minority (this) and the majority.
        public var weight: Int
        public var reverseWeight: Int

        public init(path: String, lines: [Int], types: [String], fromFolder: String, toFolder: String, weight: Int, reverseWeight: Int) {
            self.path = path
            self.lines = lines
            self.types = types
            self.fromFolder = fromFolder
            self.toFolder = toFolder
            self.weight = weight
            self.reverseWeight = reverseWeight
        }
    }

    /// A file that uses a type of another folder which uses it back: one reference each way.
    public struct FolderCycle: Codable, Sendable, Hashable {
        public var forward: SiteRef
        /// The way back: one use per file that closes the loop (at most two), or one use from the folder.
        public var back: [SiteRef]
        /// True when the `back` files are files that `forward`'s file uses: a cycle between files.
        public var isFilePair: Bool
        /// Further files of `toFolder` that use `forward`'s file.
        public var others: Int
        public var fromFolder: String
        public var toFolder: String

        public init(forward: SiteRef, back: [SiteRef], isFilePair: Bool, others: Int = 0, fromFolder: String, toFolder: String) {
            self.forward = forward
            self.back = back
            self.isFilePair = isFilePair
            self.others = others
            self.fromFolder = fromFolder
            self.toFolder = toFolder
        }
    }

    /// One reference: the file and line, and the type it names.
    public struct SiteRef: Codable, Sendable, Hashable {
        public var path: String
        public var line: Int
        public var type: String

        public init(path: String, line: Int, type: String) {
            self.path = path
            self.line = line
            self.type = type
        }
    }

    /// Where an app starts: the `@main` type, its stores, what it wires at launch, and its root view.
    public struct CompositionRoot: Codable, Sendable, Hashable {
        public var type: String
        public var path: String
        public var line: Int
        /// Persistent stores named in the module's files that set up a `ModelContainer` (or Core Data).
        public var stores: [Store]
        /// Calls on repository singletons and static calls the `@main` type makes (`LibraryCache.warmUpOnLaunch`).
        public var launch: [String]
        /// The view `WindowGroup` shows first.
        public var rootView: String?
        public var tabs: [Tab]
        /// Other views the root view presents (onboarding, a paywall cover, sheets).
        public var presents: [String]

        public init(type: String, path: String, line: Int, stores: [Store] = [], launch: [String] = [], rootView: String? = nil, tabs: [Tab] = [], presents: [String] = []) {
            self.type = type
            self.path = path
            self.line = line
            self.stores = stores
            self.launch = launch
            self.rootView = rootView
            self.tabs = tabs
            self.presents = presents
        }
    }

    /// A store file name (`library.store`) where the code names it, and the models the schema next to it lists.
    public struct Store: Codable, Sendable, Hashable {
        public var name: String
        public var path: String
        public var line: Int
        public var models: Int?
        /// Further files naming the same store.
        public var otherSites: [String]

        public init(name: String, path: String, line: Int, models: Int? = nil, otherSites: [String] = []) {
            self.name = name
            self.path = path
            self.line = line
            self.models = models
            self.otherSites = otherSites
        }
    }

    public struct Tab: Codable, Sendable, Hashable {
        public var view: String
        /// The tab's title when it differs from the view's name (`CalendarView` titled `Plans`).
        public var title: String?

        public init(view: String, title: String? = nil) {
            self.view = view
            self.title = title
        }
    }

    // MARK: Between targets

    public struct CrossTarget: Codable, Sendable, Hashable {
        /// Source files several targets compile.
        public var sharedSources: [SharedSource]
        /// Top-level types declared under one name in several targets.
        public var duplicates: [DuplicateTypes]
        /// Frameworks that connect targets at runtime (WatchConnectivity, ActivityKit, Intents…), per target.
        public var bridges: [Bridge]
        public var appGroups: [AppGroup]

        public init(sharedSources: [SharedSource] = [], duplicates: [DuplicateTypes] = [], bridges: [Bridge] = [], appGroups: [AppGroup] = []) {
            self.sharedSources = sharedSources
            self.duplicates = duplicates
            self.bridges = bridges
            self.appGroups = appGroups
        }

        public var isEmpty: Bool { sharedSources.isEmpty && duplicates.isEmpty && bridges.isEmpty && appGroups.isEmpty }
    }

    public struct SharedSource: Codable, Sendable, Hashable {
        /// Files, or a folder (trailing `/`) whose code files are all shared the same way.
        public var paths: [String]
        public var files: Int
        /// Target roles, the folder's owner first.
        public var targets: [String]
        /// `membership exception`, `synchronized folder`, `build phase`.
        public var via: String

        public init(paths: [String], files: Int, targets: [String], via: String) {
            self.paths = paths
            self.files = files
            self.targets = targets
            self.via = via
        }
    }

    public struct DuplicateTypes: Codable, Sendable, Hashable {
        public var names: [String]
        /// One declaration site per target: role, file and the names' lines in `names` order.
        public var sites: [DuplicateSite]

        public init(names: [String], sites: [DuplicateSite]) {
            self.names = names
            self.sites = sites
        }
    }

    public struct DuplicateSite: Codable, Sendable, Hashable {
        public var role: String
        public var path: String
        public var lines: [Int]

        public init(role: String, path: String, lines: [Int]) {
            self.role = role
            self.path = path
            self.lines = lines
        }
    }

    public struct Bridge: Codable, Sendable, Hashable {
        public var framework: String
        /// The importing files of each target, by target role.
        public var sides: [BridgeSide]

        public init(framework: String, sides: [BridgeSide]) {
            self.framework = framework
            self.sides = sides
        }
    }

    public struct BridgeSide: Codable, Sendable, Hashable {
        public var role: String
        /// Repository-relative paths.
        public var files: [String]

        public init(role: String, files: [String]) {
            self.role = role
            self.files = files
        }
    }

    public struct AppGroup: Codable, Sendable, Hashable {
        public var group: String
        /// Roles of the targets whose entitlements declare it, and the entitlements files.
        public var declaredBy: [String]
        public var entitlements: [String]
        /// Files using it (the literal, `suiteName:`, `containerURL`), per target role; empty: unused.
        public var uses: [BridgeSide]

        public init(group: String, declaredBy: [String], entitlements: [String], uses: [BridgeSide]) {
            self.group = group
            self.declaredBy = declaredBy
            self.entitlements = entitlements
            self.uses = uses
        }
    }

    /// How an app target's code is written, as counts (no pattern guesses).
    public struct Style: Codable, Sendable, Hashable {
        public var target: String
        public var views: Int
        public var viewModels: Int
        /// `@Model` (SwiftData) types.
        public var models: Int
        /// Types with a `static let shared`.
        public var singletons: Int
        /// `ObservableObject` and `@Observable` classes.
        public var observables: Int
        /// UIKit view controllers.
        public var viewControllers: Int

        public init(target: String, views: Int = 0, viewModels: Int = 0, models: Int = 0, singletons: Int = 0, observables: Int = 0, viewControllers: Int = 0) {
            self.target = target
            self.views = views
            self.viewModels = viewModels
            self.models = models
            self.singletons = singletons
            self.observables = observables
            self.viewControllers = viewControllers
        }
    }

    public struct LanguageCount: Codable, Sendable, Hashable {
        public var language: String
        public var files: Int

        public init(language: String, files: Int) {
            self.language = language
            self.files = files
        }
    }
}
