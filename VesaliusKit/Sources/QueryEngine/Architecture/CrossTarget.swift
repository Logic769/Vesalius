import Foundation
import RepositoryIndex
import VesaliusCore

/// How the targets of a project connect besides package products, and the style counts.
///
/// - Shared source: files more than one app-side target compiles (`file_targets`), with how.
/// - Duplicates: top-level types declared under one name in several targets' own files.
/// - Bridges: the frameworks through which targets talk at runtime, imported per target.
/// - App groups: declared in entitlements (`config_links`), and where the code uses them, or "unused".
extension ArchitectureContext {
    /// Frameworks that connect an app with its extensions, watch app or the system at runtime.
    static let bridgeFrameworks = ["WatchConnectivity", "ActivityKit", "Intents", "IntentsUI", "AppIntents", "WidgetKit"]

    /// App-side targets: Xcode targets that are not tests.
    var productTargets: [TargetRow] { xcodeTargets.filter { !$0.isTest } }

    func crossTarget(focus: String?) throws -> ArchitectureOverview.CrossTarget {
        let products = productTargets
        guard products.count > 1 else { return ArchitectureOverview.CrossTarget() }
        let focused = focus.flatMap { name in targets.first { $0.name == name } }
        func involves(_ roles: [String]) -> Bool { focused.map { roles.contains($0.role) } ?? true }
        var cross = ArchitectureOverview.CrossTarget()
        cross.sharedSources = sharedSources(products).filter { involves($0.targets) }
        cross.duplicates = try duplicates(products).filter { involves($0.sites.map(\.role)) }
        cross.bridges = try bridges(products).filter { involves($0.sides.map(\.role)) }
        cross.appGroups = try appGroups().filter { involves($0.declaredBy + $0.uses.map(\.role)) }
        return cross
    }

    // MARK: Shared source

    func sharedSources(_ products: [TargetRow]) -> [ArchitectureOverview.SharedSource] {
        let productIDs = Set(products.map(\.id))
        var groups: [String: (targets: [String], via: String, files: [String])] = [:]
        var order: [String] = []
        for (fileID, rows) in memberships {
            let built = rows.filter { productIDs.contains($0.target) }
            guard built.count > 1, let file = files[fileID], Self.buildLanguages.contains(file.language) else { continue }
            // The folder's owner first: a synchronized root before an exception or build-phase entry.
            let ordered = built.sorted { (Self.viaRank($0.via), $0.target) < (Self.viaRank($1.via), $1.target) }
            let roles = ordered.compactMap { targetsByID[$0.target]?.role }
            let via = ordered.dropFirst().contains { $0.via == "exception-add" } ? "membership exception"
                : ordered.allSatisfy { $0.via == "sync-root" } ? "synchronized folder" : ordered.dropFirst().first?.via.replacingOccurrences(of: "-", with: " ") ?? ""
            let key = roles.joined(separator: "|") + "|" + via
            if groups[key] == nil {
                order.append(key)
                groups[key] = (roles, via, [])
            }
            groups[key]?.files.append(file.path)
        }
        return order.compactMap { key -> ArchitectureOverview.SharedSource? in
            guard let group = groups[key] else { return nil }
            let paths = group.files.sorted()
            // A folder all of whose code is shared the same way is named once.
            let folder = Self.commonFolder(paths)
            let folderCode = files.values.filter { Self.buildLanguages.contains($0.language) && Self.contains(folder: folder, path: $0.path) }.count
            let shown = paths.count > 2 && !folder.isEmpty && folderCode == paths.count ? [folder + "/"] : paths
            return ArchitectureOverview.SharedSource(paths: shown, files: paths.count, targets: group.targets, via: group.via)
        }.sorted { ($0.files, $0.paths.first ?? "") > ($1.files, $1.paths.first ?? "") }
    }

    static func viaRank(_ via: String) -> Int {
        switch via {
        case "sync-root": 0
        case "swiftpm-path": 1
        case "build-phase": 2
        case "legacy-folder": 3
        default: 4
        }
    }

    // MARK: Duplicate types

    /// Top-level types declared under one name in several targets, each declaration in a file only its own
    /// target builds. Names declared in the same files are grouped.
    func duplicates(_ products: [TargetRow]) throws -> [ArchitectureOverview.DuplicateTypes] {
        let productIDs = Set(products.map(\.id))
        // A file's single owning product target (shared files declare one type for several targets).
        var owner: [Int64: Int64] = [:]
        for (fileID, rows) in memberships {
            let built = rows.filter { productIDs.contains($0.target) }
            if built.count == 1 { owner[fileID] = built[0].target }
        }
        var declarations: [String: [(target: Int64, file: Int64, line: Int)]] = [:]
        try db.forEach("""
            SELECT name, file_id, start_line FROM symbols
            WHERE depth = 0 AND is_local = 0 AND kind IN ('class', 'struct', 'enum', 'protocol', 'actor')
            ORDER BY name, file_id, start_line
            """) { row in
            let file = row.int64(1)
            guard let target = owner[file], files[file]?.isTest == false else { return }
            declarations[row.string(0), default: []].append((target, file, row.int(2)))
        }
        // Names declared in more than one target, keyed by the files that declare them.
        var groups: [String: (names: [String], sites: [(target: Int64, file: Int64, lines: [Int])])] = [:]
        for (name, sites) in declarations {
            let byTarget = Dictionary(grouping: sites, by: \.target)
            guard byTarget.count > 1 else { continue }
            let chosen = byTarget.keys.sorted().compactMap { byTarget[$0]?.first }
            let key = chosen.map { "\($0.file)" }.joined(separator: "|")
            if groups[key] == nil {
                groups[key] = ([], chosen.map { ($0.target, $0.file, []) })
            }
            groups[key]?.names.append(name)
            for (index, site) in chosen.enumerated() { groups[key]?.sites[index].lines.append(site.line) }
        }
        return groups.values.compactMap { group -> ArchitectureOverview.DuplicateTypes? in
            // Names in declaration order within the first file.
            let order = group.sites.first.map { first in
                zip(group.names, first.lines).sorted { $0.1 < $1.1 }.map(\.0)
            } ?? group.names
            let sites = group.sites.compactMap { site -> ArchitectureOverview.DuplicateSite? in
                guard let path = files[site.file]?.path, let role = targetsByID[site.target]?.role else { return nil }
                let lines = order.compactMap { name in group.names.firstIndex(of: name).map { site.lines[$0] } }
                return ArchitectureOverview.DuplicateSite(role: role, path: path, lines: lines)
            }
            return ArchitectureOverview.DuplicateTypes(names: order, sites: sites)
        }.sorted { ($0.names.count, $0.names.first ?? "") > ($1.names.count, $1.names.first ?? "") }
    }

    // MARK: Framework bridges

    func bridges(_ products: [TargetRow]) throws -> [ArchitectureOverview.Bridge] {
        let productIDs = Set(products.map(\.id))
        var byFramework: [String: [Int64: [String]]] = [:]
        let frameworks = Self.bridgeFrameworks.map { "'\($0)'" }.joined(separator: ",")
        try db.forEach("SELECT DISTINCT file_id, module FROM imports WHERE module IN (\(frameworks)) ORDER BY file_id") { row in
            guard let path = files[row.int64(0)]?.path, files[row.int64(0)]?.isTest == false else { return }
            for membership in memberships[row.int64(0)] ?? [] where productIDs.contains(membership.target) {
                byFramework[row.string(1), default: [:]][membership.target, default: []].append(path)
            }
        }
        return Self.bridgeFrameworks.compactMap { framework -> ArchitectureOverview.Bridge? in
            guard let byTarget = byFramework[framework], byTarget.count > 1 else { return nil }
            let sides = products.compactMap { target -> ArchitectureOverview.BridgeSide? in
                guard let paths = byTarget[target.id] else { return nil }
                return ArchitectureOverview.BridgeSide(role: target.role, files: paths.sorted())
            }
            return ArchitectureOverview.Bridge(framework: framework, sides: sides)
        }
    }

    // MARK: App groups

    func appGroups() throws -> [ArchitectureOverview.AppGroup] {
        var groups: [String: ArchitectureOverview.AppGroup] = [:]
        var order: [String] = []
        var usesByGroup: [String: [String: Set<String>]] = [:]
        try db.forEach("SELECT key, config_path, target_id, file_id, evidence FROM config_links WHERE kind = 'entitlement-appgroup' ORDER BY rowid") { row in
            let group = row.optionalString(0) ?? ""
            if groups[group] == nil {
                order.append(group)
                groups[group] = ArchitectureOverview.AppGroup(group: group, declaredBy: [], entitlements: [], uses: [])
            }
            if let target = row.optionalInt64(2).flatMap({ targetsByID[$0] }), !(groups[group]?.declaredBy.contains(target.role) ?? true) {
                groups[group]?.declaredBy.append(target.role)
            }
            let entitlements = row.string(1)
            if !(groups[group]?.entitlements.contains(entitlements) ?? true) { groups[group]?.entitlements.append(entitlements) }
            guard let fileID = row.optionalInt64(3), let file = files[fileID] else { return }
            let roles = (memberships[fileID] ?? []).compactMap { targetsByID[$0.target]?.role }
            for role in roles.isEmpty ? ["not built"] : roles {
                usesByGroup[group, default: [:]][role, default: []].insert(file.path)
            }
        }
        return order.compactMap { name -> ArchitectureOverview.AppGroup? in
            guard var group = groups[name] else { return nil }
            let uses = usesByGroup[name] ?? [:]
            let roleOrder = targets.map(\.role)
            group.uses = uses.keys.sorted { (roleOrder.firstIndex(of: $0) ?? .max, $0) < (roleOrder.firstIndex(of: $1) ?? .max, $1) }
                .map { ArchitectureOverview.BridgeSide(role: $0, files: (uses[$0] ?? []).sorted()) }
            return group
        }
    }

    // MARK: Style

    /// Counts per app target: SwiftUI views, view models, SwiftData models, `.shared` singletons, observable
    /// classes, UIKit view controllers.
    func styles(of apps: [TargetRow]) throws -> [ArchitectureOverview.Style] {
        guard !apps.isEmpty else { return [] }
        var styles: [ArchitectureOverview.Style] = []
        var symbols: [(file: Int64, id: Int64, name: String, kind: String, inherits: [String], attributes: [String])] = []
        var sharedOwners = Set<Int64>()
        try db.forEach("""
            SELECT file_id, id, name, kind, inherits, attributes FROM symbols
            WHERE depth = 0 AND is_local = 0 AND kind IN ('class', 'struct', 'enum', 'actor')
            """) { row in
            let split: (String?) -> [String] = { ($0 ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            symbols.append((row.int64(0), row.int64(1), row.string(2), row.string(3), split(row.optionalString(4)), split(row.optionalString(5))))
        }
        try db.forEach("SELECT parent_id FROM symbols WHERE name = 'shared' AND depth = 1 AND kind IN ('property', 'constant', 'variable') AND signature LIKE '%static%'") { row in
            if let parent = row.optionalInt64(0) { sharedOwners.insert(parent) }
        }
        for app in apps {
            let ids = Set(targetFiles[app.id] ?? [])
            var style = ArchitectureOverview.Style(target: app.name)
            for symbol in symbols where ids.contains(symbol.file) && files[symbol.file]?.isTest == false {
                if symbol.kind == "struct" && symbol.inherits.contains("View") { style.views += 1 }
                if symbol.name.hasSuffix("ViewModel") && symbol.kind != "enum" { style.viewModels += 1 }
                if symbol.attributes.contains("@Model") { style.models += 1 }
                if sharedOwners.contains(symbol.id) { style.singletons += 1 }
                if symbol.kind == "class" || symbol.kind == "actor",
                   symbol.inherits.contains("ObservableObject") || symbol.attributes.contains("@Observable") { style.observables += 1 }
                if symbol.kind == "class", symbol.inherits.contains(where: { $0.hasSuffix("ViewController") }) { style.viewControllers += 1 }
            }
            styles.append(style)
        }
        return styles
    }
}
