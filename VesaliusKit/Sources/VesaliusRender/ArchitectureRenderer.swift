import Foundation
import VesaliusCore

/// The `architecture` text, abridged:
///
///     Atlas.xcodeproj (AtlasSandbox.xcodeproj is git-excluded: skipped)
///     6 targets (1 test) · 2 local packages
///     TARGETS
///      Atlas [iOS 17.0 app, com.example.atlas] Atlas/ 212 swift · links AtlasUI, … · embeds AtlasWidgets, … · @main AtlasApp AtlasApp.swift:41
///      AtlasWatch Watch App [watchOS 26.0 app] AtlasWatch Watch App/ 25 swift + Atlas/App/ReaderSettings.swift, … (membership exception pbxproj:132-139) · …
///      not built: Legacy Watch App/ (14 files, own @main), Prototype Watch App/ (6, own @main), …
///     PACKAGES
///      Packages/AtlasKit (local): product AtlasKit · no dependencies · linked by app, watch · imported by app 18, watch 13
///     APP MODULE Atlas: Features 124 (Library 34, Home 29, …) · Services 48 · … · AtlasApp.swift
///      direction Features → Shared, App, Services, Models, Managers · Services → Models, … (convention only, one module)
///      upward Services/CloudSync.swift:146 → AccountSetupSheet (Features/AccountSetup) · …
///      cycles CloudSync.swift:146 ↔ AccountSetupSheet.swift:44 · ShelfLifecycle.swift:16 ↔ Features/Shelves (ShelvesSheet.swift:68, +2 files) · …
///      feature→feature Home → Library, Stats, +2 · …
///      root AtlasApp AtlasApp.swift:41 · launch … · stores library.store :63 (8 models; …) · ContentView: TabView HomeView, …; presents …
///     CROSS-TARGET
///      duplicate types Audio/Timer/SprintSessionAttributes (app SessionActivityAttributes.swift:17,48,68 = widget …) · …
///      bridges WatchConnectivity app PhoneSessionBridge ↔ watch WatchSessionBridge +1 · …
///      app group group.com.example.atlas declared by app (Atlas/Atlas.entitlements), unused
///     STYLE app: 196 SwiftUI views, 4 view models, 9 @Model types, 12 .shared singletons, 18 observable classes
///
/// Over budget, detail goes in steps (long lists shortened, then package internals and file lists dropped),
/// then the least telling lines; the first two lines are never cut, and a cut ends with the `more:`
/// call that shows one part in full.
public enum ArchitectureRenderer {
    public static func render(_ overview: ArchitectureOverview, budget: Budget) -> String {
        guard !budget.isUnlimited else { return lines(overview, detail: .full).joined(separator: "\n") }
        for detail in Detail.levels {
            let text = lines(overview, detail: detail).joined(separator: "\n")
            if TokenEstimate.of(text) <= budget.tokens { return text }
        }
        // Even the shortest form is too long: drop the least telling lines, then lines from the end, and say
        // how to see the rest.
        var all = lines(overview, detail: Detail.levels.last!)
        let more = moreLine(overview)
        func fits() -> Bool { TokenEstimate.of((all + [more]).joined(separator: "\n")) <= budget.tokens }
        for prefix in dropOrder {
            while !fits(), let index = all.indices.dropFirst(2).last(where: { all[$0].hasPrefix(prefix) }) {
                all.remove(at: index)
            }
            if fits() { return (all + [more]).joined(separator: "\n") }
        }
        while all.count > 2, !fits() { all.removeLast() }
        return (all + [more]).joined(separator: "\n")
    }

    /// Lines dropped first when the shortest form is still over budget.
    static let dropOrder = [" shared source", " used from:", " uses outside:", " feature→feature", " duplicate types", " bridges", " cycles", " upward"]

    /// How much of each list is shown.
    struct Detail {
        var upward: Int
        var cycles: Int
        var featureSources: Int
        var featureTargets: Int
        var directionTargets: Int
        var filesPerSide: Int
        var launch: Int
        var presents: Int
        var notBuilt: Int
        var duplicates: Int
        var packageInternals: Bool
        var packageDependencies: Bool
        var sharedSourceLine: Bool
        var registers: Bool

        static let full = Detail(upward: 12, cycles: 8, featureSources: 12, featureTargets: 8, directionTargets: 8, filesPerSide: 4, launch: 8, presents: 6,
                                 notBuilt: 10, duplicates: 6, packageInternals: true, packageDependencies: true,
                                 sharedSourceLine: true, registers: true)
        static let levels: [Detail] = [
            full,
            Detail(upward: 8, cycles: 6, featureSources: 9, featureTargets: 6, directionTargets: 8, filesPerSide: 2, launch: 6, presents: 4,
                   notBuilt: 8, duplicates: 4, packageInternals: false, packageDependencies: true,
                   sharedSourceLine: true, registers: true),
            Detail(upward: 7, cycles: 5, featureSources: 7, featureTargets: 4, directionTargets: 8, filesPerSide: 2, launch: 5, presents: 3,
                   notBuilt: 6, duplicates: 3, packageInternals: false, packageDependencies: false,
                   sharedSourceLine: false, registers: true),
            Detail(upward: 6, cycles: 4, featureSources: 5, featureTargets: 3, directionTargets: 6, filesPerSide: 1, launch: 4, presents: 3,
                   notBuilt: 5, duplicates: 2, packageInternals: false, packageDependencies: false,
                   sharedSourceLine: false, registers: false),
            Detail(upward: 4, cycles: 3, featureSources: 6, featureTargets: 2, directionTargets: 5, filesPerSide: 1, launch: 4, presents: 2,
                   notBuilt: 4, duplicates: 2, packageInternals: false, packageDependencies: false,
                   sharedSourceLine: false, registers: false),
            Detail(upward: 3, cycles: 2, featureSources: 4, featureTargets: 1, directionTargets: 4, filesPerSide: 1, launch: 4, presents: 1,
                   notBuilt: 3, duplicates: 1, packageInternals: false, packageDependencies: false,
                   sharedSourceLine: false, registers: false),
        ]
    }

    static func lines(_ overview: ArchitectureOverview, detail: Detail) -> [String] {
        var out = head(overview)
        out += targets(overview, detail: detail)
        out += packages(overview, detail: detail)
        for module in overview.modules { out += self.module(module, overview: overview, detail: detail) }
        out += crossTarget(overview, detail: detail)
        out += style(overview)
        return out
    }

    // MARK: Head

    static func head(_ overview: ArchitectureOverview) -> [String] {
        var first: String
        if overview.projects.isEmpty {
            let languages = overview.languages.prefix(4).map { "\($0.language) \($0.files)" }.joined(separator: ", ")
            first = "no Xcode project or Swift package" + (languages.isEmpty ? "" : ": " + languages + " files")
        } else {
            first = overview.projects.joined(separator: ", ")
            if overview.projects.allSatisfy({ $0.hasSuffix("Package.swift") }) { first += " (SwiftPM)" }
        }
        if !overview.skippedProjects.isEmpty {
            first += " (" + overview.skippedProjects.map { "\($0.path) is \($0.reason): skipped" }.joined(separator: "; ") + ")"
        }
        var second: [String] = []
        let apps = overview.targets.filter { !$0.isTest }
        if !overview.targets.isEmpty {
            let tests = overview.targets.count - apps.count
            second.append(plural(overview.targets.count, "target") + (tests > 0 ? " (\(tests) test)" : ""))
        }
        let local = overview.packages.filter { $0.kind != "remote" }
        let remote = overview.packages.filter { $0.kind == "remote" }
        if !local.isEmpty { second.append(plural(local.count, "local package")) }
        if !remote.isEmpty { second.append(plural(remote.count, "remote package")) }
        if let focus = overview.focus { second.append("focus: \(focus.kind.rawValue) \(focus.name)") }
        if !overview.staleFiles.isEmpty {
            second.append("edited since indexing: " + overview.staleFiles.prefix(3).joined(separator: ", ") + (overview.staleFiles.count > 3 ? " +\(overview.staleFiles.count - 3)" : ""))
        }
        if second.isEmpty, !overview.sourceFolders.isEmpty {
            second.append("code in " + overview.sourceFolders.prefix(8).map { "\($0.name)/ \($0.files)" }.joined(separator: ", ")
                + (overview.sourceFolders.count > 8 ? ", +\(overview.sourceFolders.count - 8) folders" : ""))
        }
        if second.isEmpty { second.append(overview.modules.isEmpty ? "nothing to show" : "folders by \(overview.modules[0].edgeSource)") }
        return [first, second.joined(separator: " · ")]
    }

    // MARK: Targets

    static func targets(_ overview: ArchitectureOverview, detail: Detail) -> [String] {
        guard !overview.targets.isEmpty || !overview.notBuilt.isEmpty else { return [] }
        var out = ["TARGETS"]
        for target in overview.targets {
            out.append(" " + targetLine(target, detail: detail))
        }
        if !overview.notBuilt.isEmpty {
            let shown = overview.notBuilt.prefix(detail.notBuilt).enumerated().map { index, code -> String in
                if !code.path.hasSuffix("/") { return code.path }
                return "\(code.path) (\(index == 0 ? plural(code.files, "file") : "\(code.files)")\(code.hasMain ? ", own @main" : ""))"
            }
            let more = overview.notBuilt.count - shown.count
            out.append(" not built: " + shown.joined(separator: ", ") + (more > 0 ? ", +\(more) more" : ""))
        }
        return out
    }

    static func targetLine(_ target: ArchitectureOverview.Target, detail: Detail) -> String {
        var bracket = [target.kind]
        if target.isTest {
            if let host = target.testHost { bracket.append("host \(host)") }
        } else if let version = target.deploymentTarget, let platform = target.platform {
            // `iOS 17.0 app`; an extension names its platform after its kind.
            if target.kind.hasPrefix(platform + " ") {
                bracket[0] = platform + " " + version + target.kind.dropFirst(platform.count)
            } else {
                bracket.append("\(platform) \(version)")
            }
        }
        if !target.isTest, let bundle = target.bundleID { bracket.append(bundle) }
        var line = "\(target.name) [\(bracket.joined(separator: ", "))]"
        var parts: [String] = []
        if !target.roots.isEmpty {
            var roots = target.roots.prefix(3).map { root in
                "\(root.path.isEmpty ? "." : root.path + "/") \(root.codeFiles)" + (root.language.map { " " + $0 } ?? "")
            }.joined(separator: ", ")
            if target.roots.count > 3 { roots += ", +\(target.roots.count - 3) folders" }
            for added in target.addedFiles {
                let paths = added.paths.prefix(4).joined(separator: ", ") + (added.paths.count > 4 ? ", +\(added.paths.count - 4)" : "")
                var evidence = ""
                if let first = added.firstLine {
                    let name = added.evidencePath.map { ($0 as NSString).lastPathComponent } ?? ""
                    let file = name == "project.pbxproj" ? "pbxproj" : name
                    evidence = " \(file.isEmpty ? "" : file + ":")\(first)" + (added.lastLine.map { $0 != first ? "-\($0)" : "" } ?? "")
                }
                roots += " + \(paths) (\(added.via)\(evidence))"
            }
            parts.append(roots)
        }
        if let framework = target.testFramework { parts.append(framework) }
        if !target.links.isEmpty { parts.append("links " + target.links.joined(separator: ", ")) }
        if !target.embeds.isEmpty { parts.append("embeds " + target.embeds.joined(separator: ", ")) }
        if !target.dependsOn.isEmpty { parts.append("depends on " + target.dependsOn.joined(separator: ", ")) }
        if let entry = target.entry {
            var text = "\(entry.kind) \(entry.name)"
            if let path = entry.path, let number = entry.line {
                // Inside a folder the line names already: the path below it.
                let root = target.roots.first { !$0.path.isEmpty && path.hasPrefix($0.path + "/") }
                text += " \(root.map { String(path.dropFirst($0.path.count + 1)) } ?? path):\(number)"
            }
            if detail.registers, !target.registers.isEmpty { text += " registers " + compactNames(target.registers).joined(separator: ", ") }
            parts.append(text)
        }
        if !target.intents.isEmpty { parts.append("intents " + target.intents.joined(separator: ", ")) }
        if !parts.isEmpty { line += " " + parts.joined(separator: " · ") }
        return line
    }

    // MARK: Packages

    static func packages(_ overview: ArchitectureOverview, detail: Detail) -> [String] {
        guard !overview.packages.isEmpty else { return [] }
        var out = ["PACKAGES"]
        for package in overview.packages {
            var line = " "
            if package.kind == "remote" {
                line += package.name + (package.url.map { " (\(shortURL($0)))" } ?? " (remote)")
            } else {
                line += (package.path ?? package.name) + " (" + (package.kind == "submodule" ? "git submodule" + (package.url.map { " " + shortURL($0) } ?? "") : package.kind) + ")"
            }
            var parts: [String] = []
            let products = package.products.map(\.name)
            if !products.isEmpty { parts.append((products.count == 1 ? "product " : "products ") + products.joined(separator: ", ")) }
            if package.kind != "remote" {
                if package.dependencies.isEmpty && package.remote.isEmpty {
                    parts.append("no dependencies")
                } else if detail.packageDependencies {
                    // The targets behind linked products, unless everything is shown.
                    let shown = package.dependencies.filter { detail.packageInternals || package.usedTargets.isEmpty || package.usedTargets.contains($0.from) }
                    if !shown.isEmpty {
                        parts.append("deps " + shown.map { "\($0.from) → \($0.to.joined(separator: ", "))" }.joined(separator: "; "))
                    }
                }
                for reexport in package.reexports where detail.packageInternals || package.usedTargets.isEmpty || package.usedTargets.contains(reexport.from) {
                    parts.append("\(reexport.from) re-exports \(reexport.to.joined(separator: ", ")) (@_exported)")
                }
                if detail.packageInternals {
                    if !package.remote.isEmpty { parts.append("remote " + package.remote.joined(separator: ", ")) }
                    if !package.vendored.isEmpty { parts.append("vendored " + package.vendored.joined(separator: ", ")) }
                }
            }
            if !package.linkedBy.isEmpty { parts.append("linked by " + package.linkedBy.joined(separator: ", ")) }
            if !package.importers.isEmpty { parts.append(importersText(package.importers)) }
            if !parts.isEmpty { line += ": " + parts.joined(separator: " · ") }
            out.append(line)
        }
        return out
    }

    /// `imported by app 18, watch 13` for a one-module package; `imported by app (AtlasCore 15, AtlasUI 5)`.
    static func importersText(_ importers: [ArchitectureOverview.Importers]) -> String {
        if importers.count == 1 {
            return "imported by " + importers[0].counts.map { "\($0.role) \($0.count)" }.joined(separator: ", ")
        }
        var byRole: [(role: String, modules: [String])] = []
        for importer in importers {
            for count in importer.counts {
                if let index = byRole.firstIndex(where: { $0.role == count.role }) {
                    byRole[index].modules.append("\(importer.module) \(count.count)")
                } else {
                    byRole.append((count.role, ["\(importer.module) \(count.count)"]))
                }
            }
        }
        return "imported by " + byRole.map { "\($0.role) (\($0.modules.joined(separator: ", ")))" }.joined(separator: ", ")
    }

    static func shortURL(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://", "git@", "ssh://"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        return text.replacingOccurrences(of: "github.com:", with: "github.com/")
    }

    // MARK: Modules

    /// Folders (and a container's children) listed before the rest are counted.
    static let folderLimit = 16

    static func module(_ module: ArchitectureOverview.Module, overview: ArchitectureOverview, detail: Detail) -> [String] {
        let isApp = module.composition != nil || overview.targets.contains { $0.name == module.name && $0.kind.hasSuffix("app") }
        let title = module.edgeSource == "imports" ? "SOURCE" : isApp ? "APP MODULE" : "MODULE"
        var header = title + " " + module.name
        if !module.root.isEmpty, module.root != module.name { header += " (\(module.root)/)" }
        var folders = module.folders.prefix(Self.folderLimit).map { folder -> String in
            guard !folder.children.isEmpty else { return "\(folder.name) \(folder.files)" }
            let children = folder.children.prefix(Self.folderLimit).map { "\($0.name) \($0.files)" }
                + (folder.children.count > Self.folderLimit ? ["+\(folder.children.count - Self.folderLimit) more"] : [])
            return "\(folder.name) \(folder.files) (" + children.joined(separator: ", ") + ")"
        }
        if module.folders.count > Self.folderLimit { folders.append("+\(module.folders.count - Self.folderLimit) folders") }
        folders += module.rootFiles.count <= 3 ? module.rootFiles : ["\(module.rootFiles.count) files at the top"]
        header += ": " + (folders.isEmpty ? "no folders" : folders.joined(separator: " · "))
        var out = [header]
        let prefix = module.root.isEmpty ? "" : module.root + "/"
        func relative(_ path: String) -> String { path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path }

        if !module.direction.isEmpty {
            let note = module.edgeSource == "imports" ? " (convention only)" : module.isSingleModule ? " (convention only, one module)" : ""
            out.append(" direction " + module.direction.map { dependency in
                let targets = dependency.to.prefix(detail.directionTargets).joined(separator: ", ") + (dependency.to.count > detail.directionTargets ? ", +\(dependency.to.count - detail.directionTargets)" : "")
                return "\(dependency.from) → \(targets)"
            }.joined(separator: " · ") + note)
        } else if module.edgeCount == 0, !module.folders.isEmpty {
            out.append(" direction: no \(module.edgeSource) between these folders")
        }
        if !module.upward.isEmpty {
            let shown = module.upward.prefix(detail.upward).map { edge in
                "\(relative(edge.path)):\(lineList(edge.lines)) → \(edge.types.prefix(3).joined(separator: ", "))\(edge.types.count > 3 ? " +\(edge.types.count - 3)" : "") (\(edge.toFolder))"
            }
            let more = module.upward.count - shown.count
            out.append(" upward " + shown.joined(separator: " · ") + (more > 0 ? " · +\(more) more" : ""))
        }
        if !module.cycles.isEmpty {
            let repeated = Set(module.repeatedFileNames)
            // A file by its name, or by its path in the module when another file has the same name.
            func name(_ path: String) -> String {
                let file = fileName(path)
                return repeated.contains(file) ? relative(path) : file
            }
            let shown = module.cycles.prefix(detail.cycles).map { cycle -> String in
                let forward = "\(name(cycle.forward.path)):\(cycle.forward.line)"
                let back = cycle.back.map { "\(name($0.path)):\($0.line)" }.joined(separator: ", ")
                let others = cycle.others > 0 ? ", +\(plural(cycle.others, "file"))" : ""
                return cycle.isFilePair ? "\(forward) ↔ \(back)\(others.isEmpty ? "" : " (" + others.dropFirst(2) + ")")" : "\(forward) ↔ \(cycle.toFolder) (\(back)\(others))"
            }
            let more = module.cycles.count - shown.count
            out.append(" cycles " + shown.joined(separator: " · ") + (more > 0 ? " · +\(more) more" : ""))
        }
        if !module.featureEdges.isEmpty {
            let shown = module.featureEdges.prefix(detail.featureSources).map { edge in
                "\(edge.from) → " + edge.to.prefix(detail.featureTargets).joined(separator: ", ") + (edge.to.count > detail.featureTargets ? ", +\(edge.to.count - detail.featureTargets)" : "")
            }
            let more = module.featureEdges.count - shown.count
            out.append(" feature→feature " + shown.joined(separator: " · ") + (more > 0 ? " · +\(more) more" : ""))
        }
        if !module.usesOutside.isEmpty { out.append(" uses outside: " + module.usesOutside.prefix(8).joined(separator: ", ")) }
        if !module.usedFromOutside.isEmpty { out.append(" used from: " + module.usedFromOutside.prefix(8).joined(separator: ", ")) }
        if let root = module.composition {
            out.append(" " + rootLine(root, relative: relative, detail: detail))
        }
        return out
    }

    static func rootLine(_ root: ArchitectureOverview.CompositionRoot, relative: (String) -> String, detail: Detail) -> String {
        var parts = ["root \(root.type) \(relative(root.path)):\(root.line)"]
        if !root.launch.isEmpty {
            parts.append("launch " + root.launch.prefix(detail.launch).joined(separator: ", ") + (root.launch.count > detail.launch ? " +\(root.launch.count - detail.launch)" : ""))
        }
        if !root.stores.isEmpty {
            parts.append("stores " + root.stores.map { store in
                // A store in the root's own file cites the line only (the path is the line's first).
                var text = store.name + (store.path == root.path ? " :\(store.line)" : " \(relative(store.path)):\(store.line)")
                var notes: [String] = []
                if let models = store.models { notes.append(plural(models, "model")) }
                if !store.otherSites.isEmpty { notes.append("also " + store.otherSites.prefix(2).map(fileName).joined(separator: ", ")) }
                if !notes.isEmpty { text += " (" + notes.joined(separator: "; ") + ")" }
                return text
            }.joined(separator: ", "))
        }
        if let view = root.rootView {
            var text = view
            if !root.tabs.isEmpty {
                text += ": TabView " + root.tabs.map { tab in tab.title.map { "\(tab.view) \"\($0)\"" } ?? tab.view }.joined(separator: ", ")
            }
            if !root.presents.isEmpty {
                text += (root.tabs.isEmpty ? ": " : "; ") + "presents " + root.presents.prefix(detail.presents).joined(separator: ", ")
                    + (root.presents.count > detail.presents ? " +\(root.presents.count - detail.presents)" : "")
            }
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Between targets

    static func crossTarget(_ overview: ArchitectureOverview, detail: Detail) -> [String] {
        let cross = overview.crossTarget
        guard !cross.isEmpty else { return [] }
        var out = ["CROSS-TARGET"]
        // Exception-added files are on their target's line already.
        let sources = cross.sharedSources.filter { detail.sharedSourceLine || $0.via != "membership exception" }
        if !sources.isEmpty {
            out.append(" shared source " + sources.prefix(4).map { source in
                source.paths.prefix(3).joined(separator: ", ") + (source.paths.count > 3 ? " +\(source.paths.count - 3)" : "")
                    + (source.paths.count == 1 && source.paths[0].hasSuffix("/") ? " (\(plural(source.files, "file")))" : "")
                    + ": " + source.targets.joined(separator: " + ") + " (\(source.via))"
            }.joined(separator: " · "))
        }
        if !cross.duplicates.isEmpty {
            // Groups of several names with their lines; single names by the targets declaring them.
            let grouped = cross.duplicates.filter { $0.names.count > 1 }
            let single = cross.duplicates.filter { $0.names.count == 1 }
            var pieces = grouped.prefix(detail.duplicates).map { group in
                compactNames(group.names).joined(separator: ", ") + " (" + group.sites.map { "\($0.role) \(fileName($0.path)):\(lineList($0.lines))" }.joined(separator: " = ") + ")"
            }
            var byRoles: [(roles: String, names: [String])] = []
            for duplicate in single {
                let roles = duplicate.sites.map(\.role).joined(separator: ", ")
                if let index = byRoles.firstIndex(where: { $0.roles == roles }) {
                    byRoles[index].names.append(duplicate.names[0])
                } else {
                    byRoles.append((roles, duplicate.names))
                }
            }
            pieces += byRoles.prefix(3).map { group in
                group.names.prefix(detail.duplicates + 2).joined(separator: ", ") + (group.names.count > detail.duplicates + 2 ? " +\(group.names.count - detail.duplicates - 2)" : "") + " (\(group.roles))"
            }
            out.append(" duplicate types " + pieces.joined(separator: " · "))
        }
        if !cross.bridges.isEmpty {
            out.append(" bridges " + cross.bridges.map { bridge in
                bridge.framework + " " + bridge.sides.map { side in
                    side.role + " " + side.files.prefix(detail.filesPerSide).map(fileStem).joined(separator: ", ")
                        + (side.files.count > detail.filesPerSide ? " +\(side.files.count - detail.filesPerSide)" : "")
                }.joined(separator: " ↔ ")
            }.joined(separator: " · "))
        }
        for group in cross.appGroups {
            var line = " app group \(group.group) declared by " + group.declaredBy.joined(separator: ", ")
            if !group.entitlements.isEmpty, group.entitlements.count <= 2 { line += " (" + group.entitlements.joined(separator: ", ") + ")" }
            if group.uses.isEmpty {
                line += ", unused"
            } else {
                line += ", used by " + group.uses.map { "\($0.role) " + $0.files.prefix(detail.filesPerSide).map(fileName).joined(separator: ", ") + ($0.files.count > detail.filesPerSide ? " +\($0.files.count - detail.filesPerSide)" : "") }.joined(separator: "; ")
            }
            out.append(line)
        }
        return out.count > 1 ? out : []
    }

    static func style(_ overview: ArchitectureOverview) -> [String] {
        let styles = overview.style.compactMap { style -> String? in
            var counts: [String] = []
            if style.views > 0 { counts.append(plural(style.views, "SwiftUI view")) }
            if style.viewControllers > 0 { counts.append(plural(style.viewControllers, "view controller")) }
            counts.append(plural(style.viewModels, "view model"))
            if style.models > 0 { counts.append("\(style.models) @Model types") }
            if style.singletons > 0 { counts.append(plural(style.singletons, ".shared singleton")) }
            if style.observables > 0 { counts.append(plural(style.observables, "observable class", "observable classes")) }
            let role = overview.targets.first { $0.name == style.target }?.role ?? style.target
            return "\(role): " + counts.joined(separator: ", ")
        }
        return styles.isEmpty ? [] : ["STYLE " + styles.joined(separator: " · ")]
    }

    /// `more: architecture(focus:"Atlas")`: the first module, else the first target.
    static func moreLine(_ overview: ArchitectureOverview) -> String {
        let name = overview.modules.first?.name ?? overview.targets.first?.name ?? overview.packages.first.map { $0.path ?? $0.name }
        guard let name, overview.focus == nil else { return "more: shorter with a narrower focus" }
        return "more: architecture(focus:\(MoreCall.quoted(name)))"
    }

    // MARK: Helpers

    /// `Audio/Timer/SprintSessionAttributes` for names that share a word suffix; others unchanged.
    static func compactNames(_ names: [String]) -> [String] {
        var remaining = names
        var result: [String] = []
        while let first = remaining.first {
            var best: (suffix: String, members: [String])?
            for suffix in wordSuffixes(first) where suffix.count >= 6 {
                let members = remaining.filter { $0 != suffix && $0.hasSuffix(suffix) && wordSuffixes($0).contains(suffix) }
                // The longest shared suffix: `Audio/Timer/SprintSessionLiveActivity` keeps `WidgetExtensionLiveActivity` apart.
                if members.count >= 2, members.contains(first), suffix.count > (best?.suffix.count ?? 0) {
                    best = (suffix, members)
                }
            }
            if let best {
                result.append(best.members.map { String($0.dropLast(best.suffix.count)) }.joined(separator: "/") + best.suffix)
                remaining.removeAll { best.members.contains($0) }
            } else {
                result.append(first)
                remaining.removeFirst()
            }
        }
        return result
    }

    /// The suffixes of a camel-case name that start at a capital letter after the first: `SessionAttributes`,
    /// `Attributes` for `AudioSessionAttributes`.
    static func wordSuffixes(_ name: String) -> [String] {
        let characters = Array(name)
        return characters.indices.dropFirst().filter { characters[$0].isUppercase && characters[$0 - 1].isLowercase }.map { String(characters[$0...]) }
    }

    static func lineList(_ lines: [Int]) -> String {
        lines.count > 5 ? LineList.collapsed(lines, above: 5) : LineList.format(lines)
    }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// A file's name without its extension: usually the type it declares.
    static func fileStem(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func plural(_ count: Int, _ noun: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? noun : plural ?? noun + "s")"
    }

}
