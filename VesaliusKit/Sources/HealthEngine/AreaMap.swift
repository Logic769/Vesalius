import Foundation
import VesaliusCore

/// Partitions code files into "areas": features/modules/packages when the repository is organised that
/// way (children of Features/, Modules/, packages/, Sources/…), otherwise top-level code directories.
/// Wrapper directories that hold most of the code (an app folder, a `src/` with one child) are expanded
/// so areas stay meaningful.
///
/// Works on unique directories (not files), so cost is O(directories × depth).
struct AreaMap: Sendable {
    /// Area paths, sorted ("" = repository root).
    let areas: [String]
    /// Area index for every directory index of the context.
    let areaIndexOfDirectory: [Int]
    private let names: [String]
    private let indexOfArea: [String: Int]

    /// - Parameters:
    ///   - directories: unique directories of participating files.
    ///   - fileCounts: number of participating files directly in each directory (same order).
    init(directories: [String], fileCounts: [Int], repositoryName: String) {
        let total = fileCounts.reduce(0, +)
        var counts: [String: Int] = [:]
        var direct: [String: Int] = [:]
        var children: [String: Set<String>] = [:]
        for (directory, count) in zip(directories, fileCounts) {
            direct[directory, default: 0] += count
            counts["", default: 0] += count
            var prefix = ""
            for component in directory.split(separator: "/") {
                let parent = prefix
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                counts[prefix, default: 0] += count
                children[parent, default: []].insert(prefix)
            }
        }

        func expand(_ directory: String, depth: Int) -> [String] {
            let kids = (children[directory] ?? []).sorted()
            let directCount = direct[directory] ?? 0
            if directory.isEmpty {
                var result = directCount > 0 ? [""] : []
                for kid in kids { result += expand(kid, depth: 1) }
                return result.isEmpty ? [""] : result
            }
            guard depth < 6, !kids.isEmpty else { return [directory] }
            let name = (directory.split(separator: "/").last.map(String.init) ?? directory).lowercased()
            let isContainer = Catalog.containerNames.contains(name) && kids.count >= 2
            let isDominant = total >= 8 && (counts[directory] ?? 0) * 2 >= total && kids.count >= 2
            let isWrapper = kids.count == 1 && directCount == 0
            guard isContainer || isDominant || isWrapper else { return [directory] }
            var result = directCount > 0 ? [directory] : []
            for kid in kids { result += expand(kid, depth: depth + 1) }
            return result
        }

        let roots = Set(expand("", depth: 0))
        var areaOfDirectory: [String] = []
        areaOfDirectory.reserveCapacity(directories.count)
        for directory in directories {
            var candidate = Substring(directory)
            while !roots.contains(String(candidate)) && !candidate.isEmpty {
                if let slash = candidate.lastIndex(of: "/") {
                    candidate = candidate[..<slash]
                } else {
                    candidate = ""
                }
            }
            areaOfDirectory.append(String(candidate))
        }
        let used = Set(areaOfDirectory).sorted()
        var indexOfArea: [String: Int] = [:]
        for (index, area) in used.enumerated() { indexOfArea[area] = index }
        areas = used
        self.indexOfArea = indexOfArea
        areaIndexOfDirectory = areaOfDirectory.map { indexOfArea[$0] ?? 0 }

        // Display names: last component, disambiguated with the parent when names collide.
        var byLast: [String: [Int]] = [:]
        for (index, area) in used.enumerated() {
            let last = area.isEmpty ? repositoryName : (area.split(separator: "/").last.map(String.init) ?? area)
            byLast[last, default: []].append(index)
        }
        var names = Array(repeating: "", count: used.count)
        for (last, group) in byLast {
            for index in group {
                if group.count == 1 {
                    names[index] = last.isEmpty ? "(root)" : last
                } else {
                    let suffix = used[index].split(separator: "/").suffix(2).joined(separator: "/")
                    names[index] = suffix.isEmpty ? "(root)" : suffix
                }
            }
        }
        self.names = names
    }

    func name(at index: Int) -> String {
        index >= 0 && index < names.count ? names[index] : "(root)"
    }

    func name(of area: String) -> String {
        guard let index = indexOfArea[area] else { return area.isEmpty ? "(root)" : area }
        return names[index]
    }
}
