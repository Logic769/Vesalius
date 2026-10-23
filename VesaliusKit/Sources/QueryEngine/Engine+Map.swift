import Foundation
import GraphEngine
import RepositoryIndex
import VesaliusCore

public struct MapOptions: Sendable, Hashable {
    public var includeTests: Bool
    public var includeExternal: Bool
    public var maxNodes: Int
    public var minEdgeWeight: Int
    public var languages: Set<Language>?

    public init(includeTests: Bool = false, includeExternal: Bool = true, maxNodes: Int = 220, minEdgeWeight: Int = 1, languages: Set<Language>? = nil) {
        self.includeTests = includeTests
        self.includeExternal = includeExternal
        self.maxNodes = maxNodes
        self.minEdgeWeight = minEdgeWeight
        self.languages = languages
    }
}

extension RepositoryEngine {
    /// A readable, hierarchical view of the repository graph.
    ///
    /// - `.modules` (no focus): one node per area (module/package or top-level folder).
    /// - `.directories` + `dir:`/`mod:` focus: the focus's sub-folders and direct files.
    /// - `.files` + `dir:`/`mod:` focus: every file in the focus.
    /// - `.files` + `file:` focus: focus mode — the file's neighbourhood two hops out.
    /// - `.symbols` + `file:` focus: the file's symbols and the symbols they connect to.
    /// Connections leaving the focus are folded into "external" area nodes.
    public func map(level: MapLevel = .modules, focus: String? = nil, options: MapOptions = MapOptions()) throws -> MapGraph {
        let cache = try graphCache()
        let eligible = cache.ordered.filter { node in
            node.isCode && (options.includeTests || !node.isTest) && (options.languages.map { $0.contains(node.language) } ?? true)
        }
        let areas = AreaPartition(files: eligible, modules: cache.modules)

        guard let focus, let parsed = NodeID.parse(focus) else {
            return try areaMap(cache: cache, eligible: eligible, areas: areas, options: options)
        }
        switch (level, parsed.kind) {
        case (.symbols, .file):
            return try symbolMap(path: parsed.value, cache: cache, areas: areas, options: options)
        case (_, .file):
            return try egoMap(path: parsed.value, cache: cache, eligible: eligible, areas: areas, options: options)
        case (.files, .dir), (.files, .mod):
            let members = areas.members(of: focus, in: eligible)
            return try groupMap(focus: focus, members: members, expandAll: true, cache: cache, eligible: eligible, areas: areas, options: options)
        case (_, .dir), (_, .mod):
            let members = areas.members(of: focus, in: eligible)
            return try groupMap(focus: focus, members: members, expandAll: false, cache: cache, eligible: eligible, areas: areas, options: options)
        default:
            return try areaMap(cache: cache, eligible: eligible, areas: areas, options: options)
        }
    }

    // MARK: Levels

    private func areaMap(cache: GraphCache, eligible: [GraphCache.FileNode], areas: AreaPartition, options: MapOptions) throws -> MapGraph {
        var groups: [String: [GraphCache.FileNode]] = [:]
        for node in eligible { groups[areas.area(of: node).id, default: []].append(node) }
        var nodes = groups.map { id, members in groupNode(id: id, label: areas.label(for: id), members: members, kind: id.hasPrefix("mod:") ? .module : .directory) }
        let assignment = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, areas.area(of: $0).id) })
        let edges = aggregateEdges(cache: cache, assignment: assignment, minWeight: options.minEdgeWeight)
        nodes = applyDegrees(nodes, edges: edges)
        return MapGraph(level: .modules, focus: nil, breadcrumbs: [MapBreadcrumb(id: "root", label: repositoryInfo().name)], nodes: nodes.sorted { $0.id < $1.id }, edges: markCycles(edges), hiddenNodes: 0)
    }

    private func groupMap(focus: String, members: [GraphCache.FileNode], expandAll: Bool, cache: GraphCache, eligible: [GraphCache.FileNode], areas: AreaPartition, options: MapOptions) throws -> MapGraph {
        let root = areas.rootPath(of: focus)
        var assignment: [Int64: String] = [:]
        var groups: [String: [GraphCache.FileNode]] = [:]
        var fileNodes: [GraphCache.FileNode] = []
        for node in members {
            let relative = root.isEmpty ? node.path : String(node.path.dropFirst(root.count + 1))
            let components = relative.split(separator: "/")
            if expandAll || components.count == 1 {
                fileNodes.append(node)
                assignment[node.id] = NodeID.file(node.path)
            } else {
                let child = root.isEmpty ? String(components[0]) : root + "/" + components[0]
                let id = NodeID.directory(child)
                groups[id, default: []].append(node)
                assignment[node.id] = id
            }
        }
        var hidden = 0
        if fileNodes.count > options.maxNodes {
            let keep = Set(fileNodes.sorted { $0.centrality == $1.centrality ? $0.codeLines > $1.codeLines : $0.centrality > $1.centrality }.prefix(options.maxNodes).map(\.id))
            hidden = fileNodes.count - keep.count
            for node in fileNodes where !keep.contains(node.id) { assignment[node.id] = nil }
            fileNodes = fileNodes.filter { keep.contains($0.id) }
        }
        var nodes = groups.map { id, list in groupNode(id: id, label: (String(id.dropFirst(4)) as NSString).lastPathComponent, members: list, kind: .directory) }
        nodes += fileNodes.map { fileNode($0, group: areas.label(for: areas.area(of: $0).id)) }

        if options.includeExternal {
            let memberIDs = Set(members.map(\.id))
            for node in eligible where !memberIDs.contains(node.id) {
                assignment[node.id] = "ext|" + areas.area(of: node).id
            }
        }
        var edges = aggregateEdges(cache: cache, assignment: assignment, minWeight: options.minEdgeWeight)
        if options.includeExternal {
            let externalIDs = Set(edges.flatMap { [$0.source, $0.target] }.filter { $0.hasPrefix("ext|") })
            for id in externalIDs {
                let areaID = String(id.dropFirst(4))
                let list = eligible.filter { areas.area(of: $0).id == areaID }
                var node = groupNode(id: id, label: areas.label(for: areaID), members: list, kind: .external)
                node.path = areaID
                nodes.append(node)
            }
            // Keep the external context light: only the strongest external connections.
            let externalEdges = edges.filter { $0.source.hasPrefix("ext|") || $0.target.hasPrefix("ext|") }
            if externalEdges.count > 40 {
                let keep = Set(externalEdges.sorted { $0.weight > $1.weight }.prefix(40).map(\.id))
                edges = edges.filter { !($0.source.hasPrefix("ext|") || $0.target.hasPrefix("ext|")) || keep.contains($0.id) }
                let connected = Set(edges.flatMap { [$0.source, $0.target] })
                nodes = nodes.filter { $0.kind != .external || connected.contains($0.id) }
            }
        }
        nodes = applyDegrees(nodes, edges: edges)
        return MapGraph(level: expandAll ? .files : .directories, focus: focus, breadcrumbs: breadcrumbs(for: focus, areas: areas), nodes: nodes.sorted { $0.id < $1.id }, edges: markCycles(edges), hiddenNodes: hidden)
    }

    private func egoMap(path: String, cache: GraphCache, eligible: [GraphCache.FileNode], areas: AreaPartition, options: MapOptions) throws -> MapGraph {
        guard let center = cache.byPath[path], let centerNode = cache.files[center] else {
            throw EngineError.notFound(path, suggestions: try suggestions(for: path))
        }
        var included: [Int64: Int] = [center: 0]
        for (id, distance) in cache.traverse(from: [center], dependents: false, maxDepth: 2, limit: 400) { included[id] = min(included[id] ?? .max, distance) }
        for (id, distance) in cache.traverse(from: [center], dependents: true, maxDepth: 2, limit: 400) { included[id] = min(included[id] ?? .max, distance) }
        var ids = included.keys.filter { id in
            guard let node = cache.files[id] else { return false }
            return id == center || (node.isCode && (options.includeTests || !node.isTest))
        }
        var hidden = 0
        if ids.count > options.maxNodes {
            let sorted = ids.sorted { (included[$0]!, -(cache.files[$0]?.centrality ?? 0)) < (included[$1]!, -(cache.files[$1]?.centrality ?? 0)) }
            hidden = ids.count - options.maxNodes
            ids = Array(sorted.prefix(options.maxNodes))
        }
        var assignment: [Int64: String] = [:]
        for id in ids { if let node = cache.files[id] { assignment[id] = NodeID.file(node.path) } }
        let nodes = ids.compactMap { cache.files[$0] }.map { fileNode($0, group: areas.label(for: areas.area(of: $0).id)) }
        let edges = aggregateEdges(cache: cache, assignment: assignment, minWeight: 1)
        var crumbs = breadcrumbs(for: areas.area(of: centerNode).id, areas: areas)
        crumbs.append(MapBreadcrumb(id: NodeID.file(path), label: centerNode.name))
        return MapGraph(level: .files, focus: NodeID.file(path), breadcrumbs: crumbs, nodes: applyDegrees(nodes, edges: edges).sorted { $0.id < $1.id }, edges: markCycles(edges), hiddenNodes: hidden)
    }

    private func symbolMap(path: String, cache: GraphCache, areas: AreaPartition, options: MapOptions) throws -> MapGraph {
        guard let fileID = cache.byPath[path], let fileNode = cache.files[fileID] else {
            throw EngineError.notFound(path, suggestions: try suggestions(for: path))
        }
        let own = try symbolRows(where: "s.file_id = ? AND s.depth <= 1 AND s.kind NOT IN ('variable', 'enumCase', 'case') ORDER BY s.start_line", [fileID], limit: 160)
        let ownIDs = Set(own.map(\.id))
        // Map nested symbols onto their top-level (depth ≤ 1) ancestor in this file.
        var anchor: [Int64: Int64] = [:]
        for row in own { anchor[row.id] = row.id }
        try db.forEach("SELECT id, parent_id FROM symbols WHERE file_id = ? ORDER BY depth", [fileID]) { row in
            let id = row.int64(0)
            if anchor[id] == nil, let parent = row.optionalInt64(1), let parentAnchor = anchor[parent] { anchor[id] = parentAnchor }
        }
        var weights: [String: (source: String, target: String, kind: EdgeKind, weight: Int)] = [:]
        var externalCounts: [Int64: Int] = [:]
        func key(_ s: String, _ t: String) -> String { s + "→" + t }
        // Outgoing: references from this file's symbols.
        try db.forEach("""
            SELECT r.from_symbol_id, r.target_symbol_id, r.kind, r.count, s.file_id FROM refs r JOIN symbols s ON s.id = r.target_symbol_id
            WHERE r.file_id = ? AND r.from_symbol_id IS NOT NULL AND r.confidence >= ?
            """, [fileID, ReferenceLinker.edgeThreshold]) { row in
            guard let from = anchor[row.int64(0)] else { return }
            let target = row.int64(1)
            let kind = (ReferenceKind(rawValue: row.string(2)) ?? .typeUse).edgeKind
            let sourceID = "symbol:\(from)"
            let targetID: String
            if row.int64(4) == fileID {
                guard let targetAnchor = anchor[target], targetAnchor != from else { return }
                targetID = "symbol:\(targetAnchor)"
            } else {
                externalCounts[target, default: 0] += row.int(3)
                targetID = "symbol:\(target)"
            }
            let k = key(sourceID, targetID)
            weights[k] = (sourceID, targetID, kind, (weights[k]?.weight ?? 0) + row.int(3))
        }
        // Incoming: other files' symbols referencing this file's symbols.
        try db.forEach("""
            SELECT r.from_symbol_id, r.target_symbol_id, r.kind, r.count FROM refs r
            WHERE r.target_file_id = ? AND r.file_id != ? AND r.from_symbol_id IS NOT NULL AND r.target_symbol_id IS NOT NULL AND r.confidence >= ?
            """, [fileID, fileID, ReferenceLinker.edgeThreshold]) { row in
            guard let targetAnchor = anchor[row.int64(1)] else { return }
            let from = row.int64(0)
            externalCounts[from, default: 0] += row.int(3)
            let sourceID = "symbol:\(from)", targetID = "symbol:\(targetAnchor)"
            let k = key(sourceID, targetID)
            weights[k] = (sourceID, targetID, (ReferenceKind(rawValue: row.string(2)) ?? .typeUse).edgeKind, (weights[k]?.weight ?? 0) + row.int(3))
        }
        let externalLimit = max(10, options.maxNodes / 4)
        let keptExternal = Set(externalCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(externalLimit).map(\.key))
        let externalRows = keptExternal.isEmpty ? [] : try symbolRows(where: "s.id IN (\(Array(keptExternal).sqlList))", [], limit: 500)
        let counts = try referenceCounts(own.map(\.id))

        var nodes: [MapNode] = own.map { row in
            MapNode(id: "symbol:\(row.id)", kind: .symbol, label: row.name, path: row.path, files: 1, lines: row.lines.count, symbols: 1, language: fileNode.language, fanIn: counts[row.id] ?? 0, fanOut: 0, centrality: 0, diagnostics: 0, maxSeverity: nil, group: row.parentID.flatMap { parent in own.first { $0.id == parent }?.name } ?? row.name, isExpandable: false, isTest: fileNode.isTest, risk: 0, symbolKind: row.kind)
        }
        nodes += externalRows.map { row in
            MapNode(id: "symbol:\(row.id)", kind: .external, label: row.qualifiedName, path: row.path, files: 1, lines: row.lines.count, symbols: 1, language: cache.files[row.fileID]?.language, fanIn: 0, fanOut: 0, centrality: 0, diagnostics: 0, maxSeverity: nil, group: (row.path as NSString).lastPathComponent, isExpandable: true, isTest: cache.files[row.fileID]?.isTest ?? false, risk: 0, symbolKind: row.kind)
        }
        let nodeIDs = Set(nodes.map(\.id))
        let edges = weights.values
            .filter { nodeIDs.contains($0.source) && nodeIDs.contains($0.target) }
            .map { MapEdge(source: $0.source, target: $0.target, kinds: [$0.kind], weight: $0.weight, isCycle: false) }
        _ = ownIDs
        var crumbs = breadcrumbs(for: areas.area(of: fileNode).id, areas: areas)
        crumbs.append(MapBreadcrumb(id: NodeID.file(path), label: fileNode.name))
        return MapGraph(level: .symbols, focus: NodeID.file(path), breadcrumbs: crumbs, nodes: applyDegrees(nodes, edges: edges).sorted { $0.id < $1.id }, edges: edges.sorted { $0.id < $1.id }, hiddenNodes: max(0, externalCounts.count - keptExternal.count))
    }

    // MARK: Helpers

    private func groupNode(id: String, label: String, members: [GraphCache.FileNode], kind: MapNodeKind) -> MapNode {
        var languageLines: [Language: Int] = [:]
        for member in members { languageLines[member.language, default: 0] += member.codeLines }
        let language = languageLines.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        let severity = members.compactMap(\.maxSeverity).max()
        let path: String? = {
            guard let parsed = NodeID.parse(id) else { return nil }
            return parsed.kind == .dir ? parsed.value : nil
        }()
        return MapNode(
            id: id, kind: kind, label: label, path: path,
            files: members.count, lines: members.reduce(0) { $0 + $1.codeLines }, symbols: members.reduce(0) { $0 + $1.symbols },
            language: language, fanIn: 0, fanOut: 0,
            centrality: (members.map(\.centrality).max() ?? 0).rounded(toPlaces: 3),
            diagnostics: members.reduce(0) { $0 + $1.diagnostics }, maxSeverity: severity,
            group: label, isExpandable: true, isTest: !members.isEmpty && members.allSatisfy(\.isTest),
            risk: (members.map(\.risk).max() ?? 0).rounded(toPlaces: 3)
        )
    }

    private func fileNode(_ node: GraphCache.FileNode, group: String) -> MapNode {
        MapNode(id: NodeID.file(node.path), kind: .file, label: node.name, path: node.path, files: 1, lines: node.codeLines, symbols: node.symbols, language: node.language, fanIn: node.fanIn, fanOut: node.fanOut, centrality: node.centrality.rounded(toPlaces: 3), diagnostics: node.diagnostics, maxSeverity: node.maxSeverity, group: group, isExpandable: node.symbols > 0, isTest: node.isTest, risk: node.risk.rounded(toPlaces: 3))
    }

    private func aggregateEdges(cache: GraphCache, assignment: [Int64: String], minWeight: Int) -> [MapEdge] {
        var aggregated: [String: (source: String, target: String, kinds: Set<EdgeKind>, weight: Int)] = [:]
        for (source, sourceGroup) in assignment {
            for edge in cache.outgoing[source] ?? [] {
                guard let targetGroup = assignment[edge.file], targetGroup != sourceGroup else { continue }
                if sourceGroup.hasPrefix("ext|") && targetGroup.hasPrefix("ext|") { continue }
                let key = sourceGroup + "→" + targetGroup
                var entry = aggregated[key] ?? (sourceGroup, targetGroup, [], 0)
                entry.kinds.insert(edge.kind)
                entry.weight += edge.weight
                aggregated[key] = entry
            }
        }
        return aggregated.values
            .filter { $0.weight >= minWeight }
            .map { MapEdge(source: $0.source, target: $0.target, kinds: $0.kinds.sorted { $0.rawValue < $1.rawValue }, weight: $0.weight, isCycle: false) }
            .sorted { $0.id < $1.id }
    }

    private func applyDegrees(_ nodes: [MapNode], edges: [MapEdge]) -> [MapNode] {
        var incoming: [String: Int] = [:]
        var outgoing: [String: Int] = [:]
        for edge in edges {
            outgoing[edge.source, default: 0] += 1
            incoming[edge.target, default: 0] += 1
        }
        return nodes.map { node in
            var copy = node
            if node.kind != .file {
                copy.fanIn = incoming[node.id] ?? 0
                copy.fanOut = outgoing[node.id] ?? 0
            }
            return copy
        }
    }

    private func markCycles(_ edges: [MapEdge]) -> [MapEdge] {
        let ids = Array(Set(edges.flatMap { [$0.source, $0.target] })).sorted()
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let graph = DependencyGraph(nodeCount: ids.count, edges: edges.map { (source: index[$0.source]!, target: index[$0.target]!, weight: Double($0.weight)) })
        var component: [Int: Int] = [:]
        for (number, members) in graph.cycles().enumerated() {
            for member in members { component[member] = number }
        }
        return edges.map { edge in
            var copy = edge
            if let a = component[index[edge.source]!], let b = component[index[edge.target]!], a == b { copy.isCycle = true }
            return copy
        }
    }

    private func breadcrumbs(for focus: String, areas: AreaPartition) -> [MapBreadcrumb] {
        var crumbs = [MapBreadcrumb(id: "root", label: repositoryInfo().name)]
        guard let parsed = NodeID.parse(focus) else { return crumbs }
        switch parsed.kind {
        case .mod:
            crumbs.append(MapBreadcrumb(id: focus, label: parsed.value))
        case .dir:
            let base = areas.areaBase
            var path = ""
            for component in parsed.value.split(separator: "/") {
                path = path.isEmpty ? String(component) : path + "/" + component
                if !base.isEmpty, base.hasPrefix(path) && base != path { continue }
                crumbs.append(MapBreadcrumb(id: NodeID.directory(path), label: String(component)))
            }
        default:
            break
        }
        return crumbs
    }
}

/// Splits files into areas: manifest modules when they cover most code, otherwise folders below the
/// deepest directory that every code file shares.
struct AreaPartition {
    struct Area: Hashable {
        let id: String
        let label: String
    }

    let useModules: Bool
    let areaBase: String
    let modules: [Int64: ModuleInfo]

    init(files: [GraphCache.FileNode], modules: [Int64: ModuleInfo]) {
        self.modules = modules
        let realModules = modules.values.filter { $0.kind != .directory }
        let covered = files.filter { $0.moduleID.map { modules[$0]?.kind != .directory } ?? false }.count
        useModules = realModules.count >= 2 && covered * 2 >= max(1, files.count)

        // Deepest common directory with at least two children.
        var base = ""
        for _ in 0..<4 {
            let children = Set(files.compactMap { file -> String? in
                let relative = base.isEmpty ? file.path : (file.path.hasPrefix(base + "/") ? String(file.path.dropFirst(base.count + 1)) : nil) ?? ""
                let parts = relative.split(separator: "/")
                return parts.count > 1 ? String(parts[0]) : "·file"
            })
            guard children.count == 1, let only = children.first, only != "·file" else { break }
            base = base.isEmpty ? only : base + "/" + only
        }
        areaBase = base
    }

    func area(of file: GraphCache.FileNode) -> Area {
        if useModules, let moduleID = file.moduleID, let module = modules[moduleID], module.kind != .directory {
            return Area(id: NodeID.module(module.name), label: module.name)
        }
        let relative = areaBase.isEmpty ? file.path : String(file.path.dropFirst(min(file.path.count, areaBase.count + 1)))
        let parts = relative.split(separator: "/")
        if parts.count <= 1 {
            let id = NodeID.directory(areaBase)
            return Area(id: id, label: areaBase.isEmpty ? "(root)" : (areaBase as NSString).lastPathComponent)
        }
        let path = areaBase.isEmpty ? String(parts[0]) : areaBase + "/" + parts[0]
        return Area(id: NodeID.directory(path), label: String(parts[0]))
    }

    func label(for id: String) -> String {
        guard let parsed = NodeID.parse(id) else { return id }
        if parsed.kind == .mod { return parsed.value }
        if parsed.value == "." || parsed.value.isEmpty { return "(root)" }
        return (parsed.value as NSString).lastPathComponent
    }

    func rootPath(of focus: String) -> String {
        guard let parsed = NodeID.parse(focus) else { return "" }
        switch parsed.kind {
        case .dir: return parsed.value == "." ? "" : parsed.value
        case .mod: return modules.values.first { $0.name == parsed.value && $0.kind != .directory }?.rootPath ?? modules.values.first { $0.name == parsed.value }?.rootPath ?? ""
        default: return ""
        }
    }

    func members(of focus: String, in files: [GraphCache.FileNode]) -> [GraphCache.FileNode] {
        guard let parsed = NodeID.parse(focus) else { return [] }
        if parsed.kind == .mod, useModules {
            return files.filter { area(of: $0).id == focus }
        }
        let root = rootPath(of: focus)
        return files.filter { root.isEmpty || $0.path.hasPrefix(root + "/") }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
