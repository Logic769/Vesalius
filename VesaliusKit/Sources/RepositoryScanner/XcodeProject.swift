import Foundation
import VesaliusCore

/// A `project.pbxproj` read with `PropertyListSerialization` (the file is an OpenStep property list): native
/// targets with the build settings of their default configuration, the files each target compiles, what
/// each target links, embeds and depends on, and the project's Swift package references. Every fact keeps
/// the pbxproj line it was read from, so results can cite `Atlas.xcodeproj/project.pbxproj:135`.
///
/// Membership comes from three places:
/// - file-system synchronized root groups (Xcode 16+): every file under the folder, minus the group's
///   exception-set entries for that target;
/// - an exception set naming a target that does *not* sync the group *adds* those files to it (a watch
///   app compiles the phone app's `Atlas/App/ReaderSettings.swift` this way);
/// - classic `PBXSourcesBuildPhase`/`PBXResourcesBuildPhase`/`PBXHeadersBuildPhase` file references, with paths
///   resolved through the PBXGroup tree.
public struct XcodeProject: Sendable, Hashable, Codable {
    /// Repository-relative path of the `.xcodeproj` bundle.
    public var path: String
    /// The folder the project's relative paths start from (the bundle's folder plus `projectDirPath`).
    public var directory: String
    public var objectVersion: Int?
    public var targets: [Target]
    public var packageReferences: [PackageReference]
    /// True when the property list could not be read (a merge conflict, say) and targets were found by name only.
    public var isFallback: Bool
    public var warnings: [String]

    public var pbxprojPath: String { ProjectPaths.join(path, "project.pbxproj") }

    public struct Target: Sendable, Hashable, Codable {
        public var name: String
        public var productType: String?
        /// `PRODUCT_MODULE_NAME`, else the product or target name as a C99 identifier (`AtlasWatch_Watch_App`).
        public var moduleName: String
        /// The built product's file name (`Atlas.app`, `WidgetExtensionExtension.appex`).
        public var productFile: String?
        /// Definition line of the `PBXNativeTarget` in project.pbxproj.
        public var line: Int?
        public var bundleID: String?
        public var platform: String?
        public var deploymentTarget: String?
        /// The target a test bundle runs in: the app named by `TEST_HOST`, or `TEST_TARGET_NAME` for UI tests.
        public var testHost: String?
        public var infoPlistPath: String?
        public var entitlementsPath: String?
        public var compilationConditions: [String]
        public var synchronizedGroups: [SynchronizedGroup]
        /// Files an exception set adds although this target does not sync their folder.
        public var addedFiles: [MembershipEntry]
        /// Classic build-phase members (sources, resources, headers).
        public var buildPhaseFiles: [MembershipEntry]
        public var dependencies: [Dependency]
        /// `NSExtensionPointIdentifier` from the target's Info.plist.
        public var extensionPoint: String?
        /// `NSExtensionAttributes.IntentsSupported` from the target's Info.plist.
        public var intentsSupported: [String]

        /// `unit` or `ui` for test bundles, nil otherwise.
        public var testKind: String? {
            switch productType {
            case "com.apple.product-type.bundle.ui-testing": return "ui"
            case "com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ocunit-test": return "unit"
            case nil:
                // A project that names no product types (a hand-written fixture): go by the conventional names.
                if name.hasSuffix("UITests") { return "ui" }
                return name.hasSuffix("Tests") ? "unit" : nil
            default: return nil
            }
        }

        public var isTest: Bool { testKind != nil }

        /// False when the project lists no files for this target; the legacy same-name folder then stands in.
        public var hasMembershipData: Bool {
            !synchronizedGroups.isEmpty || !addedFiles.isEmpty || !buildPhaseFiles.isEmpty
        }
    }

    /// A folder synchronized into a target, with the entries the target's exception set removes.
    public struct SynchronizedGroup: Sendable, Hashable, Codable {
        /// Repository-relative folder.
        public var path: String
        /// Line of the group in the target's `fileSystemSynchronizedGroups` list.
        public var line: Int?
        public var excluded: [MembershipEntry]
    }

    /// A file or folder named by the project, with the pbxproj line that names it.
    public struct MembershipEntry: Sendable, Hashable, Codable {
        /// Repository-relative path; a folder covers every file under it.
        public var path: String
        public var line: Int?
    }

    public struct Dependency: Sendable, Hashable, Codable {
        /// `target` (PBXTargetDependency), `product` (Swift package product), `embed` (an extension or watch
        /// app copied into this product) or `framework` (a linked framework or library).
        public var kind: String
        public var name: String
        /// For `product`: the package's name, when the project says which package provides it.
        public var package: String?
        public var line: Int?
    }

    public struct PackageReference: Sendable, Hashable, Codable {
        /// `local` or `remote`.
        public var kind: String
        /// Repository-relative folder (local) or repository URL (remote).
        public var location: String
        public var name: String
        public var line: Int?
    }

    // MARK: - Loading

    /// Reads `<bundle>/project.pbxproj` under `root`. Nil when the file is missing or unreadable.
    public static func load(bundle: String, root: URL) -> XcodeProject? {
        let url = root.appendingPathComponent(ProjectPaths.join(bundle, "project.pbxproj"))
        guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { return nil }
        return parse(data: data, bundle: bundle, root: root)
    }

    /// Parses pbxproj bytes. `root` is used to read targets' Info.plist files; pass nil to skip that.
    public static func parse(data: Data, bundle: String, root: URL?) -> XcodeProject {
        let text = String(decoding: data, as: UTF8.self)
        let index = PBXLineIndex(text: text)
        let bundleFolder = (bundle as NSString).deletingLastPathComponent
        var format = PropertyListSerialization.PropertyListFormat.openStep
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]] else {
            return fallback(text: text, bundle: bundle, directory: bundleFolder)
        }
        var reader = PBXReader(objects: objects, index: index, bundleFolder: bundleFolder, rootObject: plist["rootObject"] as? String, root: root)
        var project = reader.read(bundle: bundle)
        project.objectVersion = (plist["objectVersion"] as? String).flatMap(Int.init)
        return project
    }

    /// Today's regex, for a pbxproj the property-list reader rejects: target names only, no membership.
    static func fallback(text: String, bundle: String, directory: String) -> XcodeProject {
        var targets: [Target] = []
        var seen = Set<String>()
        let lineStarts = ProjectPaths.lineStarts(text)
        for match in text.matches(of: /isa = PBXNativeTarget;[\s\S]*?name = "?([^";\n]+)"?;/) {
            let name = String(match.1).trimmingCharacters(in: .whitespaces)
            guard seen.insert(name).inserted else { continue }
            let line = ProjectPaths.line(of: match.range.lowerBound, in: text, lineStarts: lineStarts)
            targets.append(Target(
                name: name, productType: nil, moduleName: ProjectPaths.c99Identifier(name), productFile: nil, line: line,
                bundleID: nil, platform: nil, deploymentTarget: nil, testHost: nil, infoPlistPath: nil, entitlementsPath: nil,
                compilationConditions: [], synchronizedGroups: [], addedFiles: [], buildPhaseFiles: [], dependencies: [],
                extensionPoint: nil, intentsSupported: []
            ))
        }
        return XcodeProject(
            path: bundle, directory: directory, objectVersion: nil, targets: targets, packageReferences: [], isFallback: true,
            warnings: ["\(ProjectPaths.join(bundle, "project.pbxproj")) is not a readable property list (a merge conflict?); targets were read by name only"]
        )
    }
}

// MARK: - Object graph reader

/// Walks the pbxproj object graph. Separate from `XcodeProject` so the memo tables stay private.
private struct PBXReader {
    let objects: [String: [String: Any]]
    let index: PBXLineIndex
    let bundleFolder: String
    let rootObject: String?
    let root: URL?
    var parents: [String: String] = [:]
    var groupPaths: [String: String?] = [:]
    var projectDirectory = ""
    var mainGroup: String?

    init(objects: [String: [String: Any]], index: PBXLineIndex, bundleFolder: String, rootObject: String?, root: URL?) {
        self.objects = objects
        self.index = index
        self.bundleFolder = bundleFolder
        self.rootObject = rootObject
        self.root = root
        for (id, object) in objects {
            for child in Self.strings(object["children"]) { parents[child] = id }
        }
    }

    static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    func isa(_ id: String) -> String? { objects[id]?["isa"] as? String }

    mutating func read(bundle: String) -> XcodeProject {
        let project = rootObject.flatMap { objects[$0] }
        projectDirectory = ProjectPaths.join(bundleFolder, project?["projectDirPath"] as? String ?? "")
        mainGroup = project?["mainGroup"] as? String

        // Targets in the project's order; a project without a root object (a fixture) in file order.
        var targetIDs = Self.strings(project?["targets"]).filter { isa($0) == "PBXNativeTarget" }
        if targetIDs.isEmpty {
            targetIDs = objects.filter { $0.value["isa"] as? String == "PBXNativeTarget" }.map(\.key)
                .sorted { (index.line(of: $0) ?? .max, $0) < (index.line(of: $1) ?? .max, $1) }
        }
        let projectSettings = configuration(list: project?["buildConfigurationList"] as? String, name: nil)

        // Product file → target, for TEST_HOST and embed phases.
        var productOwners: [String: String] = [:]
        var productNames: [String: String] = [:]
        for id in targetIDs {
            guard let target = objects[id], let name = target["name"] as? String else { continue }
            if let reference = target["productReference"] as? String {
                productOwners[reference] = name
                if let file = objects[reference]?["path"] as? String { productNames[file] = name }
            }
        }

        // Exception sets, by the synchronized group that lists them.
        var groupExceptions: [String: [(target: String, entries: [XcodeProject.MembershipEntry])]] = [:]
        for (groupID, group) in objects where group["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" {
            guard let folder = groupPath(groupID) else { continue }
            for exceptionID in Self.strings(group["exceptions"]) {
                guard let exception = objects[exceptionID], exception["isa"] as? String == "PBXFileSystemSynchronizedBuildFileExceptionSet",
                      let target = exception["target"] as? String else { continue }
                let entries = Self.strings(exception["membershipExceptions"]).map { entry in
                    XcodeProject.MembershipEntry(path: ProjectPaths.join(folder, entry), line: index.line(ofEntry: entry, in: exceptionID))
                }
                groupExceptions[groupID, default: []].append((target, entries))
            }
        }

        var targets: [XcodeProject.Target] = []
        for id in targetIDs {
            guard let object = objects[id] else { continue }
            let name = object["name"] as? String ?? id
            let (_, raw) = configuration(list: object["buildConfigurationList"] as? String, name: projectSettings.name, base: projectSettings.settings)
            let settings = BuildSettings(raw: raw, targetName: name)

            var synchronized: [XcodeProject.SynchronizedGroup] = []
            let syncedIDs = Self.strings(object["fileSystemSynchronizedGroups"])
            for groupID in syncedIDs {
                guard let folder = groupPath(groupID) else { continue }
                let excluded = (groupExceptions[groupID] ?? []).filter { $0.target == id }.flatMap(\.entries)
                synchronized.append(XcodeProject.SynchronizedGroup(path: folder, line: index.line(ofEntry: groupID, in: id), excluded: excluded))
            }
            var added: [XcodeProject.MembershipEntry] = []
            for (groupID, sets) in groupExceptions.sorted(by: { $0.key < $1.key }) where !syncedIDs.contains(groupID) {
                for set in sets where set.target == id { added.append(contentsOf: set.entries) }
            }

            var phaseFiles: [XcodeProject.MembershipEntry] = []
            var dependencies: [XcodeProject.Dependency] = []
            for phaseID in Self.strings(object["buildPhases"]) {
                guard let phase = objects[phaseID] else { continue }
                let buildFiles = Self.strings(phase["files"])
                switch phase["isa"] as? String {
                case "PBXSourcesBuildPhase", "PBXResourcesBuildPhase", "PBXHeadersBuildPhase":
                    for buildFile in buildFiles {
                        guard let reference = objects[buildFile]?["fileRef"] as? String else { continue }
                        for path in memberPaths(of: reference) {
                            phaseFiles.append(XcodeProject.MembershipEntry(path: path, line: index.line(of: buildFile)))
                        }
                    }
                case "PBXFrameworksBuildPhase":
                    for buildFile in buildFiles {
                        // Package products are listed under packageProductDependencies; frameworks only here.
                        guard let reference = objects[buildFile]?["fileRef"] as? String, let file = objects[reference] else { continue }
                        let fileName = ((file["path"] as? String) ?? (file["name"] as? String) ?? "") as NSString
                        let name = productOwners[reference] ?? (fileName.lastPathComponent as NSString).deletingPathExtension
                        guard !name.isEmpty else { continue }
                        dependencies.append(XcodeProject.Dependency(kind: "framework", name: name, package: nil, line: index.line(of: buildFile)))
                    }
                case "PBXCopyFilesBuildPhase":
                    // 13 = PlugIns (app extensions), 16 = Products Directory (watch apps, App Clips).
                    guard ["13", "16"].contains(phase["dstSubfolderSpec"] as? String ?? "") else { continue }
                    for buildFile in buildFiles {
                        guard let reference = objects[buildFile]?["fileRef"] as? String, let owner = productOwners[reference] else { continue }
                        dependencies.append(XcodeProject.Dependency(kind: "embed", name: owner, package: nil, line: index.line(of: buildFile)))
                    }
                default:
                    break
                }
            }
            for dependencyID in Self.strings(object["dependencies"]) {
                guard let dependency = objects[dependencyID] else { continue }
                let targetName = (dependency["target"] as? String).flatMap { objects[$0]?["name"] as? String }
                    ?? (dependency["name"] as? String)
                    ?? (dependency["targetProxy"] as? String).flatMap { objects[$0]?["remoteInfo"] as? String }
                guard let targetName else { continue }
                dependencies.append(XcodeProject.Dependency(kind: "target", name: targetName, package: nil, line: index.line(ofEntry: dependencyID, in: id) ?? index.line(of: dependencyID)))
            }
            for productID in Self.strings(object["packageProductDependencies"]) {
                guard let product = objects[productID], var productName = product["productName"] as? String else { continue }
                if productName.hasPrefix("plugin:") { productName = String(productName.dropFirst("plugin:".count)) }
                let package = (product["package"] as? String).flatMap(packageReference)?.name
                dependencies.append(XcodeProject.Dependency(kind: "product", name: productName, package: package, line: index.line(ofEntry: productID, in: id) ?? index.line(of: productID)))
            }

            let productFile = (object["productReference"] as? String).flatMap { objects[$0]?["path"] as? String }
            var testHost: String?
            if let host = settings["TEST_HOST"], let app = host.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
                testHost = productNames[String(app)] ?? String(app.dropLast(4))
            }
            if testHost == nil, let name = settings["TEST_TARGET_NAME"], !name.isEmpty { testHost = name }
            let infoPlist = settings["INFOPLIST_FILE"].map { ProjectPaths.join(projectDirectory, $0) }
            let (extensionPoint, intents) = infoPlist.map(readExtension) ?? (nil, [])

            targets.append(XcodeProject.Target(
                name: name,
                productType: object["productType"] as? String,
                moduleName: settings.moduleName,
                productFile: productFile,
                line: index.line(of: id),
                bundleID: settings["PRODUCT_BUNDLE_IDENTIFIER"],
                platform: settings.platform,
                deploymentTarget: settings.deploymentTarget,
                testHost: testHost,
                infoPlistPath: infoPlist,
                entitlementsPath: settings["CODE_SIGN_ENTITLEMENTS"].map { ProjectPaths.join(projectDirectory, $0) },
                compilationConditions: settings.compilationConditions,
                synchronizedGroups: synchronized,
                addedFiles: added,
                buildPhaseFiles: phaseFiles,
                dependencies: dependencies,
                extensionPoint: extensionPoint,
                intentsSupported: intents
            ))
        }

        let references = Self.strings(project?["packageReferences"]).compactMap(packageReference)
        return XcodeProject(path: bundle, directory: projectDirectory, objectVersion: nil, targets: targets, packageReferences: references, isFallback: false, warnings: [])
    }

    func packageReference(_ id: String) -> XcodeProject.PackageReference? {
        guard let object = objects[id] else { return nil }
        switch object["isa"] as? String {
        case "XCLocalSwiftPackageReference":
            guard let relative = object["relativePath"] as? String else { return nil }
            let location = ProjectPaths.join(projectDirectory, relative)
            return XcodeProject.PackageReference(kind: "local", location: location, name: (location as NSString).lastPathComponent, line: index.line(of: id))
        case "XCRemoteSwiftPackageReference":
            guard let url = object["repositoryURL"] as? String else { return nil }
            return XcodeProject.PackageReference(kind: "remote", location: url, name: ProjectPaths.packageIdentity(url), line: index.line(of: id))
        default:
            return nil
        }
    }

    /// The files a build-phase entry stands for: the file reference itself, or each localization of a
    /// variant group (which has no path of its own and would otherwise resolve to its whole folder).
    mutating func memberPaths(of reference: String) -> [String] {
        guard let object = objects[reference] else { return [] }
        let references = object["isa"] as? String == "PBXVariantGroup" ? Self.strings(object["children"]) : [reference]
        return references.compactMap { id in objects[id]?["path"] == nil ? nil : groupPath(id) }
    }

    /// Repository-relative path of a group or file reference, resolved through its parent groups. Nil for
    /// references outside the repository (SDK frameworks, build products).
    mutating func groupPath(_ id: String) -> String? {
        if let cached = groupPaths[id] { return cached }
        var visiting = Set<String>()
        let resolved = resolve(id, visiting: &visiting)
        groupPaths[id] = resolved
        return resolved
    }

    private func resolve(_ id: String, visiting: inout Set<String>) -> String? {
        guard visiting.insert(id).inserted, let object = objects[id] else { return nil }
        let own = object["path"] as? String
        switch object["sourceTree"] as? String ?? "<group>" {
        case "<group>":
            let base: String?
            if id == mainGroup {
                base = projectDirectory
            } else if let parent = parents[id] {
                base = resolve(parent, visiting: &visiting)
            } else {
                // Synchronized groups referenced only by targets (a widget extension's `AtlasWidgets`) sit at the project root.
                base = projectDirectory
            }
            guard let base else { return nil }
            return own.map { ProjectPaths.join(base, $0) } ?? base
        case "SOURCE_ROOT":
            return own.map { ProjectPaths.join(projectDirectory, $0) } ?? projectDirectory
        case "<absolute>":
            guard let own, let root else { return nil }
            let rootPath = root.standardizedFileURL.path
            return own.hasPrefix(rootPath + "/") ? String(own.dropFirst(rootPath.count + 1)) : nil
        default:
            return nil
        }
    }

    /// Build settings of the configuration named `name` (else the list's default, else its first), laid over
    /// `base` with `$(inherited)` taking the base value.
    func configuration(list: String?, name: String?, base: [String: String] = [:]) -> (name: String?, settings: [String: String]) {
        guard let list, let object = objects[list] else { return (name, base) }
        let configurations = Self.strings(object["buildConfigurations"]).compactMap { id in objects[id].map { (id, $0) } }
        let wanted = name ?? (object["defaultConfigurationName"] as? String)
        guard let chosen = configurations.first(where: { $0.1["name"] as? String == wanted }) ?? configurations.first else { return (wanted, base) }
        var merged = base
        for (key, value) in chosen.1["buildSettings"] as? [String: Any] ?? [:] {
            let text: String
            if let string = value as? String {
                text = string
            } else if let array = value as? [Any] {
                text = array.compactMap { $0 as? String }.joined(separator: " ")
            } else {
                continue
            }
            merged[key] = text.replacingOccurrences(of: "$(inherited)", with: base[key] ?? "").trimmingCharacters(in: .whitespaces)
        }
        return (chosen.1["name"] as? String ?? wanted, merged)
    }

    /// `NSExtensionPointIdentifier` and `IntentsSupported` from an Info.plist in the repository.
    func readExtension(_ plistPath: String) -> (String?, [String]) {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent(plistPath)),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { return (nil, []) }
        let extensionInfo = (plist["NSExtension"] ?? plist["EXAppExtensionAttributes"]) as? [String: Any]
        let point = (extensionInfo?["NSExtensionPointIdentifier"] ?? extensionInfo?["EXExtensionPointIdentifier"]) as? String
        let attributes = extensionInfo?["NSExtensionAttributes"] as? [String: Any]
        return (point, Self.strings(attributes?["IntentsSupported"]))
    }
}

/// The merged build settings of one target, with the few substitutions the project model needs.
private struct BuildSettings {
    let raw: [String: String]
    let targetName: String

    subscript(key: String) -> String? {
        guard let value = raw[key] else { return nil }
        let expanded = expand(value)
        return expanded.isEmpty ? nil : expanded
    }

    var productName: String {
        guard let value = raw["PRODUCT_NAME"] else { return targetName }
        let name = Self.substitute("TARGET_NAME", with: targetName, in: value)
        return name.isEmpty || name.contains("$") ? targetName : name
    }

    var moduleName: String {
        if let explicit = self["PRODUCT_MODULE_NAME"] { return explicit }
        return ProjectPaths.c99Identifier(productName)
    }

    /// iOS, watchOS, macOS, tvOS or visionOS, from SDKROOT (or the first supported platform when it is `auto`).
    var platform: String? {
        let names = ["iphoneos": "iOS", "iphonesimulator": "iOS", "watchos": "watchOS", "watchsimulator": "watchOS", "macosx": "macOS",
                     "appletvos": "tvOS", "appletvsimulator": "tvOS", "xros": "visionOS", "xrsimulator": "visionOS", "driverkit": "DriverKit"]
        if let sdk = self["SDKROOT"]?.lowercased(), let name = names[sdk] { return name }
        if let supported = self["SUPPORTED_PLATFORMS"]?.split(separator: " ").first.map({ String($0).lowercased() }) { return names[supported] }
        return nil
    }

    var deploymentTarget: String? {
        let keys = ["iOS": "IPHONEOS_DEPLOYMENT_TARGET", "watchOS": "WATCHOS_DEPLOYMENT_TARGET", "macOS": "MACOSX_DEPLOYMENT_TARGET",
                    "tvOS": "TVOS_DEPLOYMENT_TARGET", "visionOS": "XROS_DEPLOYMENT_TARGET", "DriverKit": "DRIVERKIT_DEPLOYMENT_TARGET"]
        guard let platform, let key = keys[platform] else { return nil }
        return self[key]
    }

    var compilationConditions: [String] {
        (self["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("$(") }
    }

    /// Expands `$(TARGET_NAME)`, `$(PRODUCT_NAME)` (with `:rfc1034identifier`/`:c99extidentifier`) and drops
    /// `$(SRCROOT)/`-style prefixes; other variables stay as written.
    func expand(_ value: String) -> String {
        guard value.contains("$") else { return value }
        var result = Self.substitute("TARGET_NAME", with: targetName, in: value)
        if result.contains("PRODUCT_NAME") { result = Self.substitute("PRODUCT_NAME", with: productName, in: result) }
        for variable in ["SRCROOT", "PROJECT_DIR", "SOURCE_ROOT"] {
            for (open, close) in [("$(", ")"), ("${", "}")] {
                result = result.replacingOccurrences(of: "\(open)\(variable)\(close)/", with: "")
                result = result.replacingOccurrences(of: "\(open)\(variable)\(close)", with: "")
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Replaces `$(NAME)`, `${NAME}` and their `:rfc1034identifier`/`:c99extidentifier` forms.
    static func substitute(_ variable: String, with replacement: String, in value: String) -> String {
        var result = value
        for (open, close) in [("$(", ")"), ("${", "}")] {
            result = result.replacingOccurrences(of: "\(open)\(variable):rfc1034identifier\(close)", with: ProjectPaths.rfc1034Identifier(replacement))
            result = result.replacingOccurrences(of: "\(open)\(variable):c99extidentifier\(close)", with: ProjectPaths.c99Identifier(replacement))
            result = result.replacingOccurrences(of: "\(open)\(variable)\(close)", with: replacement)
        }
        return result
    }
}

// MARK: - Line index

/// Definition lines of the objects in a pbxproj (`ID = { … };` entries of `objects`) and lookups of list
/// entries inside one object, for file:line evidence. A small lexer over the text: it skips comments and
/// quoted strings and records the line span of every dictionary opened at the objects level.
struct PBXLineIndex {
    private(set) var spans: [String: ClosedRange<Int>] = [:]
    private let lines: [Substring]

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let bytes = Array(text.utf8)
        var depth = 0
        var line = 1
        var lastToken: (text: String, line: Int)?
        var sawEquals = false
        var open: [(id: String, line: Int, depth: Int)] = []
        var i = 0
        func isBare(_ c: UInt8) -> Bool {
            !(c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == UInt8(ascii: "{") || c == UInt8(ascii: "}") || c == UInt8(ascii: "(")
              || c == UInt8(ascii: ")") || c == UInt8(ascii: "=") || c == UInt8(ascii: ";") || c == UInt8(ascii: ",") || c == UInt8(ascii: "\""))
        }
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x0A {
                line += 1
                i += 1
            } else if c == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < bytes.count, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) {
                    if bytes[i] == 0x0A { line += 1 }
                    i += 1
                }
                i += 2
            } else if c == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") {
                while i < bytes.count, bytes[i] != 0x0A { i += 1 }
            } else if c == UInt8(ascii: "\"") {
                let startLine = line
                var value: [UInt8] = []
                i += 1
                while i < bytes.count, bytes[i] != UInt8(ascii: "\"") {
                    if bytes[i] == UInt8(ascii: "\\"), i + 1 < bytes.count {
                        value.append(bytes[i + 1])
                        i += 2
                        continue
                    }
                    if bytes[i] == 0x0A { line += 1 }
                    value.append(bytes[i])
                    i += 1
                }
                i += 1
                lastToken = (String(decoding: value, as: UTF8.self), startLine)
                sawEquals = false
            } else if c == UInt8(ascii: "=") {
                sawEquals = true
                i += 1
            } else if c == UInt8(ascii: "{") {
                if depth == 2, sawEquals, let token = lastToken { open.append((token.text, token.line, depth + 1)) }
                depth += 1
                sawEquals = false
                lastToken = nil
                i += 1
            } else if c == UInt8(ascii: "}") {
                if let last = open.last, last.depth == depth {
                    spans[last.id] = last.line...max(last.line, line)
                    open.removeLast()
                }
                depth -= 1
                i += 1
            } else if isBare(c) {
                let start = i
                while i < bytes.count, isBare(bytes[i]) {
                    if bytes[i] == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") || bytes[i + 1] == UInt8(ascii: "/") { break }
                    i += 1
                }
                if i == start { i += 1 } else {
                    lastToken = (String(decoding: bytes[start..<i], as: UTF8.self), line)
                    sawEquals = false
                }
            } else {
                i += 1
            }
        }
    }

    /// Definition line of an object.
    func line(of id: String) -> Int? { spans[id]?.lowerBound }

    /// The line inside object `id` that lists `entry` (`ID /* name */,`, `App/ReaderSettings.swift,`, `"a b.swift",`).
    func line(ofEntry entry: String, in id: String) -> Int? {
        guard let span = spans[id] else { return nil }
        for number in span where number - 1 < lines.count {
            var text = lines[number - 1].trimmingCharacters(in: .whitespaces)
            if let comment = text.range(of: "/*") { text = text[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
            if text.hasSuffix(",") { text.removeLast() }
            text = text.trimmingCharacters(in: .whitespaces)
            if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
                text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            if text == entry { return number }
        }
        return nil
    }
}

// MARK: - Paths

/// Repository-relative path helpers shared by the project-file readers and the project-model indexer.
public enum ProjectPaths {
    /// Joins a repository-relative folder and a relative path, resolving `.` and `..`.
    public static func join(_ directory: String, _ path: String) -> String {
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

    /// True when `path` is `folder` or inside it; the empty folder is the repository root.
    public static func contains(_ folder: String, _ path: String) -> Bool {
        folder.isEmpty || path == folder || path.hasPrefix(folder + "/")
    }

    /// Xcode's `c99extidentifier`: anything but letters, digits and `_` becomes `_`, and a leading digit gets a `_`.
    public static func c99Identifier(_ name: String) -> String {
        var result = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if let first = result.first, first.isNumber { result = "_" + result }
        return result
    }

    /// Xcode's `rfc1034identifier`: anything but letters, digits, `-` and `.` becomes `-`.
    public static func rfc1034Identifier(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" })
    }

    /// A package's identity from its URL: `https://github.com/groue/GRDB.swift.git` → `GRDB.swift`.
    public static func packageIdentity(_ url: String) -> String {
        var name = (url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) as NSString).lastPathComponent
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        return name
    }

    /// Byte offsets where each line starts, for `line(of:in:lineStarts:)`.
    static func lineStarts(_ text: String) -> [String.Index] {
        var starts = [text.startIndex]
        var index = text.startIndex
        while let newline = text[index...].firstIndex(of: "\n") {
            index = text.index(after: newline)
            starts.append(index)
        }
        return starts
    }

    /// 1-based line of a string index.
    static func line(of position: String.Index, in text: String, lineStarts: [String.Index]) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= position { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// 1-based line of the first line containing `needle`, searching from line `from`.
    public static func firstLine(containing needle: String, in text: String, from: Int = 1) -> Int? {
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where offset + 1 >= from {
            if line.contains(needle) { return offset + 1 }
        }
        return nil
    }
}

extension GitRepository {
    /// Which of `paths` git tracks (nil when git or the repository is unavailable).
    func trackedPaths(_ paths: [String]) -> Set<String>? {
        guard !paths.isEmpty, let output = run(["ls-files", "--"] + paths) else { return nil }
        return Set(output.split(separator: "\n").map(String.init))
    }
}
