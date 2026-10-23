import Foundation
import VesaliusCore

/// Finds groups of files that are strongly connected internally and weakly coupled externally —
/// candidates for extraction into their own package, module or target.
enum ExtractionAdvisor {
    struct Candidate {
        var name: String
        var rootPath: String?
        var members: Set<Int64>
        var internalPairs = 0
        var outPairs = 0
        var inPairs = 0
        var externalDependencies: Set<Int64> = []
        var externalDependents: Set<Int64> = []
        var entryCounts: [Int64: Int] = [:]
        var isDirectory: Bool

        var cohesion: Double {
            let total = internalPairs + outPairs + inPairs
            return total == 0 ? 0 : Double(internalPairs) / Double(total)
        }
    }

    static func suggest(_ ctx: HealthContext) -> [ExtractionSuggestion] {
        let config = ctx.config
        let total = ctx.sourceFiles.count
        guard total >= config.extractionMinFiles * 2 else { return [] }
        let maxSize = max(config.extractionMinFiles, Int(Double(total) * config.extractionMaxShare))

        // Directory candidates: every ancestor directory holding enough source files. Ancestors are
        // computed once per unique directory, then referenced by integer index in the edge loop.
        var sourcesPerDirectory: [Int: Int] = [:]
        for file in ctx.sourceFiles { sourcesPerDirectory[ctx.directoryIndex(of: file.id), default: 0] += 1 }
        var countPerDirectory: [String: Int] = [:]
        var prefixesOfDirectory: [Int: [String]] = [:]
        for (directoryIndex, count) in sourcesPerDirectory where directoryIndex >= 0 {
            var prefix = ""
            var list: [String] = []
            for part in ctx.directoryPaths[directoryIndex].split(separator: "/") {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                list.append(prefix)
                countPerDirectory[prefix, default: 0] += count
            }
            prefixesOfDirectory[directoryIndex] = list
        }
        let candidatePaths = countPerDirectory.filter { $0.value >= config.extractionMinFiles && $0.value <= maxSize }.keys.sorted()
        var candidateIndex: [String: Int] = [:]
        for (index, path) in candidatePaths.enumerated() { candidateIndex[path] = index }
        var candidatesOfDirectory: [Int: [Int]] = [:]
        for (directoryIndex, prefixes) in prefixesOfDirectory {
            candidatesOfDirectory[directoryIndex] = prefixes.compactMap { candidateIndex[$0] }
        }
        var directories: [Candidate] = candidatePaths.map { path in
            Candidate(name: path.split(separator: "/").last.map(String.init) ?? path, rootPath: path, members: [], isDirectory: true)
        }
        for file in ctx.sourceFiles {
            for index in candidatesOfDirectory[ctx.directoryIndex(of: file.id)] ?? [] {
                directories[index].members.insert(file.id)
            }
        }

        // Cluster candidates.
        var clusterOf: [Int64: Int] = [:]
        var clusters: [Int: Candidate] = [:]
        for cluster in ctx.graph.clusters {
            let members = cluster.fileIDs.filter { ctx.sourceIDs.contains($0) }
            guard members.count >= config.extractionMinFiles, members.count <= maxSize else { continue }
            for id in members { clusterOf[id] = cluster.id }
            clusters[cluster.id] = Candidate(name: clusterName(cluster.label, members: members, ctx: ctx, directorySizes: countPerDirectory), rootPath: commonDirectory(members.map { ctx.path($0) }), members: Set(members), isDirectory: false)
        }

        // One pass over the edges fills every candidate's counters.
        let none: [Int] = []
        for entry in ctx.pairs where ctx.sourceIDs.contains(entry.pair.source) && ctx.sourceIDs.contains(entry.pair.target) {
            let s = entry.pair.source, t = entry.pair.target
            let sDirs = candidatesOfDirectory[ctx.directoryIndex(of: s)] ?? none
            let tDirs = candidatesOfDirectory[ctx.directoryIndex(of: t)] ?? none
            for index in sDirs {
                if tDirs.contains(index) {
                    directories[index].internalPairs += 1
                } else {
                    directories[index].outPairs += 1
                    directories[index].externalDependencies.insert(t)
                }
            }
            for index in tDirs where !sDirs.contains(index) {
                directories[index].inPairs += 1
                directories[index].externalDependents.insert(s)
                directories[index].entryCounts[t, default: 0] += 1
            }
            let cs = clusterOf[s], ct = clusterOf[t]
            if let cs, cs == ct {
                clusters[cs]?.internalPairs += 1
            } else {
                if let cs {
                    clusters[cs]?.outPairs += 1
                    clusters[cs]?.externalDependencies.insert(t)
                }
                if let ct {
                    clusters[ct]?.inPairs += 1
                    clusters[ct]?.externalDependents.insert(s)
                    clusters[ct]?.entryCounts[t, default: 0] += 1
                }
            }
        }

        // Cycle membership for boundary-crossing checks.
        var cycleOf: [Int64: Int] = [:]
        var cycleMembers: [Int: [Int64]] = [:]
        for (index, cycle) in ctx.graph.cycles.enumerated() {
            let members = cycle.filter { ctx.sourceIDs.contains($0) }
            guard members.count >= 2 else { continue }
            cycleMembers[index] = members
            for id in members { cycleOf[id] = index }
        }

        var scored: [(score: Double, candidate: Candidate, ui: Int, crossing: Int)] = []
        let allCandidates = directories + clusters.keys.sorted().compactMap { clusters[$0] }
        for candidate in allCandidates {
            let size = candidate.members.count
            guard size >= config.extractionMinFiles,
                  candidate.internalPairs >= max(3, size / 2),
                  candidate.cohesion >= config.extractionMinCohesion else { continue }
            let ui = candidate.members.filter { id in
                guard let file = ctx.file(id) else { return false }
                return file.externalImports.contains { Catalog.uiModules.contains($0.lowercased()) } || ctx.layerOfFile[id] == "Presentation"
            }.count
            let cycles = Set(candidate.members.compactMap { cycleOf[$0] })
            let crossing = cycles.filter { index in !(cycleMembers[index] ?? []).allSatisfy(candidate.members.contains) }.count
            let uiShare = Double(ui) / Double(size)
            let entryShare = min(1, Double(candidate.entryCounts.count) / Double(size))
            let dependencyShare = min(1, Double(candidate.externalDependencies.count) / Double(size))
            var score = candidate.cohesion
            score *= 0.5 + 0.5 * min(1, Double(size) / 8)
            score *= 1 - 0.5 * entryShare
            score *= 1 - 0.3 * uiShare
            score *= 1 - 0.3 * dependencyShare
            if crossing > 0 { score *= 0.7 }
            guard score >= 0.3 else { continue }
            scored.append((score, candidate, ui, crossing))
        }
        // Folders are the natural unit to extract, so they win over an equivalent graph cluster.
        func priority(_ entry: (score: Double, candidate: Candidate, ui: Int, crossing: Int)) -> Double {
            entry.score * (entry.candidate.isDirectory ? 1.15 : 1)
        }
        scored.sort { lhs, rhs in
            if priority(lhs) != priority(rhs) { return priority(lhs) > priority(rhs) }
            if lhs.candidate.members.count != rhs.candidate.members.count { return lhs.candidate.members.count > rhs.candidate.members.count }
            if lhs.candidate.isDirectory != rhs.candidate.isDirectory { return lhs.candidate.isDirectory }
            return (lhs.candidate.rootPath ?? lhs.candidate.name) < (rhs.candidate.rootPath ?? rhs.candidate.name)
        }

        var picked: [(candidate: Candidate, ui: Int, crossing: Int, score: Double)] = []
        for entry in scored {
            let overlaps = picked.contains { other in
                let shared = entry.candidate.members.intersection(other.candidate.members).count
                return Double(shared) / Double(min(entry.candidate.members.count, other.candidate.members.count)) >= 0.3
            }
            guard !overlaps else { continue }
            picked.append((entry.candidate, entry.ui, entry.crossing, entry.score))
            if picked.count >= config.maxSuggestions { break }
        }

        var usedNames: [String: Int] = [:]
        return picked.map { entry in
            var name = entry.candidate.name
            usedNames[name, default: 0] += 1
            if usedNames[name]! > 1, let root = entry.candidate.rootPath {
                name = "\(name) (\((root as NSString).deletingLastPathComponent))"
            }
            return makeSuggestion(name: name, entry.candidate, ui: entry.ui, crossing: entry.crossing, score: entry.score, ctx: ctx)
        }
    }

    private static func makeSuggestion(name: String, _ candidate: Candidate, ui: Int, crossing: Int, score: Double, ctx: HealthContext) -> ExtractionSuggestion {
        let members = candidate.members.sorted { ctx.path($0) < ctx.path($1) }
        let lines = members.reduce(0) { $0 + (ctx.file($1)?.codeLines ?? 0) }
        let entries = candidate.entryCounts.sorted { $0.value == $1.value ? ctx.path($0.key) < ctx.path($1.key) : $0.value > $1.value }.map(\.key)
        let dependencies = candidate.externalDependencies.sorted { ctx.path($0) < ctx.path($1) }
        let directoriesSpanned = Set(members.compactMap { ctx.file($0)?.directory }).count

        var reasons = ["\(members.count) files with \(Format.plural(candidate.internalPairs, "internal dependency", "internal dependencies"))"]
        switch dependencies.count {
        case 0: reasons.append("No dependencies on the rest of the codebase")
        case 1...3: reasons.append("Only \(Format.plural(dependencies.count, "external dependency", "external dependencies")) (\(Format.list(dependencies.map { ctx.displayName($0) }, limit: 3)))")
        default: reasons.append("\(Format.plural(dependencies.count, "external dependency", "external dependencies"))")
        }
        if entries.isEmpty {
            reasons.append("Not used by the rest of the codebase yet")
        } else {
            reasons.append("\(Format.plural(entries.count, "entry point")) used by \(Format.plural(candidate.externalDependents.count, "file")) outside (\(Format.list(entries.map { ctx.displayName($0) }, limit: 2)))")
        }
        reasons.append("\(Format.percent(candidate.cohesion)) of its dependency edges stay inside")
        reasons.append(ui == 0 ? "No UI framework coupling" : "\(Format.plural(ui, "file")) \(Format.verb(ui, "touches", "touch")) UI frameworks")
        if !candidate.isDirectory && directoriesSpanned > 1 {
            reasons.append("Detected from the dependency graph: the files currently live in \(directoriesSpanned) folders")
        }

        let languages = Dictionary(grouping: members.compactMap { ctx.file($0)?.language }, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        var benefits = [
            entries.isEmpty ? "A self-contained unit with no inbound coupling" : "A clear API boundary around \(Format.plural(entries.count, "entry point"))",
            "Faster incremental builds: changes inside stay inside the module",
            "Can be tested in isolation",
        ]
        switch languages {
        case .swift: benefits.append("Could become its own Swift package or target")
        case .typescript, .javascript: benefits.append("Could become a workspace package")
        case .python: benefits.append("Could become an installable package")
        default: break
        }
        if !candidate.isDirectory && directoriesSpanned > 1 {
            benefits.append("Consolidates related code currently spread across \(directoriesSpanned) folders")
        }

        var risks: [String] = []
        if !candidate.externalDependents.isEmpty {
            risks.append("\(Format.plural(candidate.externalDependents.count, "file")) outside \(Format.verb(candidate.externalDependents.count, "depends", "depend")) on it and would need to import the new module")
        }
        if crossing > 0 { risks.append("\(Format.plural(crossing, "dependency cycle")) \(Format.verb(crossing, "crosses", "cross")) the boundary and must be broken first") }
        if ui > 0 { risks.append("\(Format.plural(ui, "file")) \(Format.verb(ui, "imports", "import")) UI frameworks, which limits reuse outside the app") }
        if dependencies.count > 3 { risks.append("Depends on \(dependencies.count) outside files; they must move too or become dependencies of the new module") }
        if languages == .swift && !entries.isEmpty { risks.append("Declarations used across the boundary will need public access") }
        if risks.isEmpty { risks.append("Low: the group is already isolated") }

        return ExtractionSuggestion(
            name: name,
            rootPath: candidate.rootPath,
            files: Array(members.prefix(200).map { ctx.path($0) }),
            lines: lines,
            internalDependencies: candidate.internalPairs,
            externalDependencies: dependencies.count,
            externalDependents: candidate.externalDependents.count,
            cohesion: (candidate.cohesion * 1000).rounded() / 1000,
            entryPoints: Array(entries.prefix(10).map { ctx.path($0) }),
            score: (score * 1000).rounded() / 1000,
            reasons: reasons,
            benefits: benefits,
            risks: risks
        )
    }

    /// Cluster labels come from their dominant folder; when that folder is much larger than the cluster
    /// (e.g. the whole app folder) name the cluster after its most common file-name word instead.
    static func clusterName(_ label: String, members: [Int64], ctx: HealthContext, directorySizes: [String: Int]) -> String {
        let folderSize = directorySizes.filter { ($0.key as NSString).lastPathComponent == label }.map(\.value).max() ?? 0
        guard folderSize > members.count * 3 / 2 else { return label }
        var counts: [String: Int] = [:]
        for id in members {
            for word in FastWords.split(ctx.file(id)?.stem ?? "") where word.count >= 3 && !Catalog.genericWords.contains(word) {
                counts[word, default: 0] += 1
            }
        }
        guard let best = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }), best.value >= 2 else {
            return "\(label) cluster"
        }
        return best.key.prefix(1).uppercased() + best.key.dropFirst()
    }

    static func commonDirectory(_ paths: [String]) -> String? {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent.split(separator: "/").map(String.init) }) else { return nil }
        for path in paths.dropFirst() {
            let parts = (path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
            var length = 0
            while length < min(common.count, parts.count) && common[length] == parts[length] { length += 1 }
            common = Array(common.prefix(length))
            if common.isEmpty { return nil }
        }
        return common.joined(separator: "/")
    }
}
