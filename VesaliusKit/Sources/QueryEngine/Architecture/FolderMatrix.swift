import Foundation
import RepositoryIndex
import VesaliusCore

/// A module's folders and the dependencies between them.
///
/// Edges come from references whose target is a type, never from file proximity or names: type annotations,
/// instantiations, inheritance and conformance, and the type of a static member access, at confidence ≥ 0.85
/// and resolved by type, scope or a static receiver (a unique-name guess never counts; rows linked before
/// `refs.basis` existed count by confidence alone). The type must be top-level, so a bare name bound to a
/// nested type (`Link`, `Context`) cannot fake an edge. Both files must be built by the same target.
/// Scripting languages, whose files import files, use import edges instead.
///
/// Each edge is weighed in distinct (file, type) pairs. For every pair of top folders the heavier way is the
/// dominant direction; references the other way are upward edges, unless the two ways are close, which makes
/// the pair mutual. A folder cycle is a file whose upward use is answered by a use of that file from the other
/// folder, shown with one reference each way.
extension ArchitectureContext {
    /// Folders whose children are features (`Features/Home`), expanded one level.
    static let containerNames: Set<String> = ["features", "feature", "modules", "module", "screens", "scenes", "flows", "domains", "pages"]

    /// Kinds of `refs` that name a type.
    static let typeReferenceKinds = ["type", "instantiate", "inherit", "conform"]

    /// One use of a declaration in another file: a type (Swift) or an imported file (scripts).
    struct Use {
        let from: Int64
        let line: Int
        let name: String
        let to: Int64
    }

    /// Names a file's folder inside a module: the first folder under the root, `Container/Child` for a
    /// container folder, a secondary root by its own name, and "" for a file directly in the root.
    struct FolderKeyer {
        let base: String
        let secondary: [String]

        func key(_ path: String) -> String? {
            if ArchitectureContext.contains(folder: base, path: path) {
                let relative = base.isEmpty ? Substring(path) : path.dropFirst(base.count + 1)
                let components = relative.split(separator: "/")
                guard components.count > 1 else { return "" }
                let first = String(components[0])
                if components.count > 2, ArchitectureContext.containerNames.contains(first.lowercased()) {
                    return first + "/" + components[1]
                }
                return first
            }
            if let root = secondary.first(where: { ArchitectureContext.contains(folder: $0, path: path) }) {
                return (root as NSString).lastPathComponent
            }
            return nil
        }

        static func top(_ key: String) -> String {
            key.split(separator: "/").first.map(String.init) ?? key
        }
    }

    /// The folder section of a target: folder counts, direction, upward edges, cycles, feature edges. With
    /// `folder`, the folders under it, plus what it uses outside and who outside uses it.
    func module(of target: TargetRow, folder: String?) throws -> ArchitectureOverview.Module? {
        let code = codeFiles(of: target).filter { $0.language == .swift }
        guard !code.isEmpty else { return nil }
        let roots = self.roots(of: target).map(\.path)
        let primary = target.moduleID.flatMap { moduleRoots[$0] }.flatMap { root in roots.contains(root) || roots.isEmpty ? root : nil } ?? roots.first ?? ""
        let keyer = FolderKeyer(base: folder ?? primary, secondary: folder == nil ? roots.filter { $0 != primary } : [])
        let outsideKeyer = FolderKeyer(base: primary, secondary: roots.filter { $0 != primary })
        let ids = Set(code.map(\.id))
        let uses = try typeUses(target: target, files: ids)
        var module = buildModule(name: target.name, root: folder ?? primary, edgeSource: "type references", files: code, uses: uses, keyer: keyer,
                                 outsideKeyer: folder == nil ? nil : outsideKeyer)
        module.isSingleModule = true
        return module
    }

    /// The source folder of a repository without build targets (`src/`), with import edges.
    func sourceModule(folder: String?) throws -> ArchitectureOverview.Module? {
        let scripts: Set<Language> = [.typescript, .javascript, .python]
        let code = files.values.filter { scripts.contains($0.language) && !$0.isTest && !$0.isGenerated }
        guard code.count >= 5 else { return nil }
        let base: String
        if let folder {
            base = folder
        } else {
            var counts: [String: Int] = [:]
            for file in code where file.path.contains("/") {
                counts[String(file.path.split(separator: "/")[0]), default: 0] += 1
            }
            guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), best.value * 2 >= code.count || best.value >= 20 else { return nil }
            base = best.key
        }
        let keyer = FolderKeyer(base: base, secondary: [])
        let inside = code.filter { Self.contains(folder: base, path: $0.path) }
        guard !inside.isEmpty else { return nil }
        let ids = Set(code.map(\.id))
        var uses: [Use] = []
        try db.forEach("""
            SELECT file_id, line, resolved_file_id FROM imports
            WHERE resolved_file_id IS NOT NULL AND resolved_file_id != file_id AND is_mock = 0
            ORDER BY file_id, line
            """) { row in
            let from = row.int64(0), to = row.int64(2)
            guard ids.contains(from), ids.contains(to), let path = files[to]?.path else { return }
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            uses.append(Use(from: from, line: row.int(1), name: stem, to: to))
        }
        return buildModule(name: base, root: base, edgeSource: "imports", files: folder == nil ? inside : code, uses: uses, keyer: keyer,
                           outsideKeyer: folder == nil ? nil : FolderKeyer(base: "", secondary: []))
    }

    /// Type-level uses between two files of the target.
    func typeUses(target: TargetRow, files ids: Set<Int64>) throws -> [Use] {
        var uses: [Use] = []
        let kinds = Self.typeReferenceKinds.map { "'\($0)'" }.joined(separator: ",")
        try db.forEach("""
            SELECT r.file_id, r.line, s.name, s.file_id
            FROM refs r JOIN symbols s ON s.id = r.target_symbol_id
            WHERE r.kind IN (\(kinds)) AND r.confidence >= ? AND (r.basis IS NULL OR r.basis IN ('typed', 'static', 'lexical', 'self'))
              AND s.depth = 0 AND s.is_local = 0 AND s.kind IN ('class', 'struct', 'enum', 'protocol', 'actor', 'typealias', 'interface')
              AND r.file_id != s.file_id
            ORDER BY r.file_id, r.line, r.col
            """, [Self.typeEdgeThreshold]) { row in
            let from = row.int64(0), to = row.int64(3)
            guard ids.contains(from), ids.contains(to) else { return }
            uses.append(Use(from: from, line: row.int(1), name: row.string(2), to: to))
        }
        return uses
    }

    /// References weaker than this (a guess by name, a legacy membership fallback) never make a folder edge.
    static let typeEdgeThreshold = 0.85

    // MARK: The matrix

    func buildModule(name: String, root: String, edgeSource: String, files moduleFiles: [FileRow], uses: [Use], keyer: FolderKeyer,
                     outsideKeyer: FolderKeyer?) -> ArchitectureOverview.Module {
        var module = ArchitectureOverview.Module(name: name, root: root, edgeSource: edgeSource)
        let names = Dictionary(moduleFiles.map { (($0.path as NSString).lastPathComponent, 1) }, uniquingKeysWith: +)
        module.repeatedFileNames = names.filter { $0.value > 1 }.map(\.key).sorted()
        var keys: [Int64: String] = [:]
        for file in moduleFiles {
            if let key = keyer.key(file.path) { keys[file.id] = key }
        }

        // Folder counts, containers with their children.
        var counts: [String: Int] = [:]
        var childCounts: [String: [String: Int]] = [:]
        for (id, key) in keys {
            if key.isEmpty {
                if let path = files[id]?.path { module.rootFiles.append((path as NSString).lastPathComponent) }
                continue
            }
            let top = FolderKeyer.top(key)
            counts[top, default: 0] += 1
            if key.contains("/") { childCounts[top, default: [:]][String(key.dropFirst(top.count + 1)), default: 0] += 1 }
        }
        module.rootFiles.sort()
        module.folders = counts.map { top, count in
            let children = (childCounts[top] ?? [:]).map { ArchitectureOverview.Folder(name: $0.key, files: $0.value) }
                .sorted { ($0.files, $1.name) > ($1.files, $0.name) }
            return ArchitectureOverview.Folder(name: top, files: count, children: children)
        }.sorted { ($0.files, $1.name) > ($1.files, $0.name) }

        // Edges between folders, weighed in distinct (file, type) pairs.
        struct Pair: Hashable {
            let from: String
            let to: String
        }
        var top: [Pair: Set<String>] = [:]
        var fine: [Pair: Set<String>] = [:]
        var topUses: [Pair: [Use]] = [:]
        var outsideUses: [String: Set<String>] = [:]
        var outsideUsers: [String: Set<String>] = [:]
        for use in uses {
            let from = keys[use.from], to = keys[use.to]
            if let outsideKeyer, (from == nil) != (to == nil) {
                // Folder focus: a use crossing the folder's boundary, named by the folder outside.
                guard let path = files[from == nil ? use.from : use.to]?.path else { continue }
                let label = outsideKeyer.key(path).map { $0.isEmpty ? (path as NSString).lastPathComponent : FolderKeyer.top($0) } ?? (path as NSString).deletingLastPathComponent
                if from == nil {
                    outsideUsers[label, default: []].insert("\(use.from)|\(use.name)")
                } else {
                    outsideUses[label, default: []].insert("\(use.from)|\(use.name)")
                }
                continue
            }
            guard let from, let to, !from.isEmpty, !to.isEmpty, from != to else { continue }
            let pairKey = "\(use.from)|\(use.name)"
            fine[Pair(from: from, to: to), default: []].insert(pairKey)
            let topPair = Pair(from: FolderKeyer.top(from), to: FolderKeyer.top(to))
            guard topPair.from != topPair.to else { continue }
            top[topPair, default: []].insert(pairKey)
            topUses[topPair, default: []].append(use)
        }
        module.edgeCount = top.values.reduce(0) { $0 + $1.count }
        module.usesOutside = Self.byWeight(outsideUses).filter { !$0.isEmpty }
        module.usedFromOutside = Self.byWeight(outsideUsers).filter { !$0.isEmpty }

        // Direction per top-folder pair.
        func weight(_ from: String, _ to: String) -> Int { top[Pair(from: from, to: to)]?.count ?? 0 }
        var dominant: [String: [(String, Int)]] = [:]
        var minority: [(pair: Pair, ratio: Double)] = []
        var mutual: [Pair] = []
        for pair in top.keys where pair.from < pair.to || weight(pair.to, pair.from) == 0 {
            let forward = weight(pair.from, pair.to), backward = weight(pair.to, pair.from)
            if backward == 0 {
                dominant[pair.from, default: []].append((pair.to, forward))
            } else if backward * 2 <= forward {
                dominant[pair.from, default: []].append((pair.to, forward))
                minority.append((Pair(from: pair.to, to: pair.from), Double(backward) / Double(forward)))
            } else if forward * 2 <= backward {
                dominant[pair.to, default: []].append((pair.from, backward))
                minority.append((pair, Double(forward) / Double(backward)))
            } else {
                mutual.append(pair)
            }
        }
        module.direction = dominant.map { from, targets in
            (from, targets.sorted { ($0.1, $1.0) > ($1.1, $0.0) })
        }.sorted { lhs, rhs in
            let left = (lhs.1.count, lhs.1.reduce(0) { $0 + $1.1 }), right = (rhs.1.count, rhs.1.reduce(0) { $0 + $1.1 })
            return left != right ? left > right : lhs.0 < rhs.0
        }.map { ArchitectureOverview.Dependency(from: $0.0, to: $0.1.map(\.0)) }

        // Upward edges: the minority way of each pair, grouped by file.
        minority.sort { ($0.ratio, $0.pair.from, $0.pair.to) < ($1.ratio, $1.pair.from, $1.pair.to) }
        for (pair, _) in minority {
            var byFile: [Int64: [Use]] = [:]
            for use in topUses[pair] ?? [] { byFile[use.from, default: []].append(use) }
            let entries = byFile.compactMap { fileID, fileUses -> ArchitectureOverview.UpwardEdge? in
                guard let path = files[fileID]?.path else { return nil }
                let sorted = fileUses.sorted { $0.line < $1.line }
                return ArchitectureOverview.UpwardEdge(
                    path: path, lines: Self.uniqueInts(sorted.map(\.line)), types: Self.unique(sorted.map(\.name)),
                    fromFolder: keys[fileID] ?? pair.from, toFolder: sorted.first.flatMap { keys[$0.to] } ?? pair.to,
                    weight: weight(pair.from, pair.to), reverseWeight: weight(pair.to, pair.from))
            }
            module.upward.append(contentsOf: entries.sorted { $0.path < $1.path })
        }

        // Cycles: an upward use answered from the folders it reaches by a use of the same file, then mutual pairs.
        var cycles: [ArchitectureOverview.FolderCycle] = []
        func site(_ use: Use) -> ArchitectureOverview.SiteRef? {
            files[use.from].map { ArchitectureOverview.SiteRef(path: $0.path, line: use.line, type: use.name) }
        }
        func byPath(_ lhs: Use, _ rhs: Use) -> Bool { (files[lhs.from]?.path ?? "", lhs.line) < (files[rhs.from]?.path ?? "", rhs.line) }
        for (pair, _) in minority {
            var byFile: [Int64: [Use]] = [:]
            for use in topUses[pair] ?? [] { byFile[use.from, default: []].append(use) }
            for (fileID, fileUses) in byFile.sorted(by: { (files[$0.key]?.path ?? "") < (files[$1.key]?.path ?? "") }) {
                let reachedFiles = Set(fileUses.map(\.to))
                let reachedFolders = Set(fileUses.compactMap { keys[$0.to] })
                // Uses of this file from the folders its upward uses reach.
                let back = (topUses[Pair(from: pair.to, to: pair.from)] ?? []).filter { $0.to == fileID && keys[$0.from].map(reachedFolders.contains) == true }
                guard !back.isEmpty else { continue }
                var firstBack: [Int64: Use] = [:]
                for use in back.sorted(by: byPath) where firstBack[use.from] == nil { firstBack[use.from] = use }
                let closing = firstBack.values.filter { reachedFiles.contains($0.from) }.sorted(by: byPath)
                if !closing.isEmpty {
                    // A cycle between files: the first use of the first closing file, and its answers.
                    let target = closing[0].from
                    guard let forward = fileUses.filter({ $0.to == target }).min(by: { $0.line < $1.line }).flatMap(site) else { continue }
                    cycles.append(ArchitectureOverview.FolderCycle(
                        forward: forward, back: closing.prefix(2).compactMap(site), isFilePair: true, others: max(0, firstBack.count - min(2, closing.count)),
                        fromFolder: keys[fileID] ?? pair.from, toFolder: keys[target] ?? pair.to))
                } else {
                    let answers = firstBack.values.sorted(by: byPath)
                    guard let answer = answers.first, let back = site(answer),
                          let forward = fileUses.min(by: { $0.line < $1.line }).flatMap(site) else { continue }
                    let folder = keys[answer.from] ?? pair.to
                    cycles.append(ArchitectureOverview.FolderCycle(
                        forward: forward, back: [back], isFilePair: false, others: answers.filter { keys[$0.from] == folder }.count - 1,
                        fromFolder: keys[fileID] ?? pair.from, toFolder: folder))
                }
            }
        }
        for pair in mutual.sorted(by: { ($0.from, $0.to) < ($1.from, $1.to) }) {
            let forward = (topUses[pair] ?? []).sorted(by: byPath), backward = (topUses[Pair(from: pair.to, to: pair.from)] ?? []).sorted(by: byPath)
            // Two files using each other, else the first use each way.
            var chosen: (Use, Use, Bool)?
            for use in forward {
                if let answer = backward.first(where: { $0.from == use.to && $0.to == use.from }) {
                    chosen = (use, answer, true)
                    break
                }
            }
            if chosen == nil, let first = forward.first, let second = backward.first { chosen = (first, second, false) }
            guard let (there, answer, isFilePair) = chosen, let forwardSite = site(there), let backSite = site(answer) else { continue }
            cycles.append(ArchitectureOverview.FolderCycle(forward: forwardSite, back: [backSite], isFilePair: isFilePair, others: 0,
                                                           fromFolder: pair.from, toFolder: pair.to))
        }
        module.cycles = cycles.enumerated().sorted { ($0.element.isFilePair ? 0 : 1, $0.offset) < ($1.element.isFilePair ? 0 : 1, $1.offset) }.map(\.element)

        // Feature to feature: edges between children of one container folder.
        var featureTargets: [String: [(String, Int)]] = [:]
        for (pair, users) in fine where pair.from.contains("/") && pair.to.contains("/") && FolderKeyer.top(pair.from) == FolderKeyer.top(pair.to) {
            let from = String(pair.from.dropFirst(FolderKeyer.top(pair.from).count + 1))
            let to = String(pair.to.dropFirst(FolderKeyer.top(pair.to).count + 1))
            featureTargets[from, default: []].append((to, users.count))
        }
        module.featureEdges = featureTargets.map { from, targets in
            (from, targets.sorted { ($0.1, $1.0) > ($1.1, $0.0) })
        }.sorted { lhs, rhs in
            let left = lhs.1.reduce(0) { $0 + $1.1 }, right = rhs.1.reduce(0) { $0 + $1.1 }
            return left != right ? left > right : lhs.0 < rhs.0
        }.map { ArchitectureOverview.Dependency(from: $0.0, to: $0.1.map(\.0)) }
        return module
    }

    static func byWeight(_ groups: [String: Set<String>]) -> [String] {
        groups.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.map(\.key)
    }

    static func uniqueInts(_ values: [Int]) -> [Int] {
        var seen = Set<Int>()
        return values.filter { seen.insert($0).inserted }
    }
}
