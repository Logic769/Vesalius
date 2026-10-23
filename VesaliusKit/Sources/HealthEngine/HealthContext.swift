import Foundation
import GraphEngine
import VesaliusCore

/// Indexes precomputed once per analysis so every rule runs in O(files + edges + symbols).
struct HealthContext {
    typealias File = RepositorySnapshot.File
    typealias Symbol = RepositorySnapshot.Symbol
    typealias Concern = ConceptLexicon.Concern

    /// A unique dependency between two participating files (all edge kinds merged).
    struct Pair: Hashable, Sendable {
        let source: Int64
        let target: Int64
    }

    let snapshot: RepositorySnapshot
    let graph: GraphAnalysis
    let config: HealthConfiguration

    // MARK: Files

    let filesByID: [Int64: File]
    /// Code files that are not generated, sorted by path.
    let participating: [File]
    let participatingIDs: Set<Int64>
    /// Participating files that are not tests.
    let sourceFiles: [File]
    let sourceIDs: Set<Int64>
    let metrics: [Int64: FileGraphMetrics]
    let totalSourceLines: Int

    // MARK: Edges

    /// Weighted dependency pairs among participating files, sorted (source, target).
    let pairs: [(pair: Pair, weight: Int)]
    let pairWeight: [Pair: Int]
    /// Explicit file imports only (`import`, `#include`, `require`), without name references.
    let importTargets: [Int64: Set<Int64>]
    let outgoing: [Int64: [Int64]]
    let incoming: [Int64: [Int64]]

    // MARK: Symbols

    let symbolsByID: [Int64: Symbol]
    let symbolsByFile: [Int64: [Symbol]]
    let childrenOf: [Int64: [Symbol]]
    /// Extensions keyed by the extended type's simple name.
    let extensionsByName: [String: [Symbol]]
    /// Names of members declared inside protocols/interfaces in the repository.
    let protocolRequirementNames: Set<String>
    /// Simple names of every type declared in the repository.
    let repositoryTypeNames: Set<String>

    // MARK: Structure

    let areas: AreaMap
    /// Unique directories of participating files (sorted) and each file's directory index.
    let directoryPaths: [String]
    let directoryIndexOfFile: [Int64: Int]
    /// Area index of every participating file (index into `areas.areas`).
    let areaIndexOfFile: [Int64: Int]
    let layerOfFile: [Int64: String]
    let importConcerns: [Int64: Set<Concern>]
    let fanOutThreshold: Int
    let fanInThreshold: Int

    init(snapshot: RepositorySnapshot, graph: GraphAnalysis, config: HealthConfiguration) {
        self.snapshot = snapshot
        self.graph = graph
        self.config = config

        var byID: [Int64: File] = [:]
        for file in snapshot.files { byID[file.id] = file }
        filesByID = byID
        participating = snapshot.files
            .filter { $0.language.isCode && !$0.isGenerated }
            .sorted { $0.path < $1.path }
        participatingIDs = Set(participating.map(\.id))
        sourceFiles = participating.filter { !$0.isTest }
        sourceIDs = Set(sourceFiles.map(\.id))
        let metricsMap = snapshot.metrics.isEmpty ? graph.metrics : snapshot.metrics
        metrics = metricsMap
        totalSourceLines = sourceFiles.reduce(0) { $0 + $1.codeLines }

        var weights: [Pair: Int] = [:]
        var imports: [Int64: Set<Int64>] = [:]
        for edge in snapshot.edges where edge.kind.isDependency && edge.source != edge.target {
            guard participatingIDs.contains(edge.source), participatingIDs.contains(edge.target) else { continue }
            weights[Pair(source: edge.source, target: edge.target), default: 0] += max(1, edge.weight)
            if edge.kind == .imports { imports[edge.source, default: []].insert(edge.target) }
        }
        pairWeight = weights
        importTargets = imports
        pairs = weights
            .map { (pair: $0.key, weight: $0.value) }
            .sorted { ($0.pair.source, $0.pair.target) < ($1.pair.source, $1.pair.target) }
        var out: [Int64: [Int64]] = [:]
        var inc: [Int64: [Int64]] = [:]
        for entry in pairs {
            out[entry.pair.source, default: []].append(entry.pair.target)
            inc[entry.pair.target, default: []].append(entry.pair.source)
        }
        outgoing = out
        incoming = inc

        var symbolMap: [Int64: Symbol] = [:]
        var perFile: [Int64: [Symbol]] = [:]
        var children: [Int64: [Symbol]] = [:]
        for symbol in snapshot.symbols {
            symbolMap[symbol.id] = symbol
            perFile[symbol.fileID, default: []].append(symbol)
            if let parent = symbol.parentID { children[parent, default: []].append(symbol) }
        }
        for key in perFile.keys { perFile[key]?.sort { ($0.lines.start, $0.id) < ($1.lines.start, $1.id) } }
        for key in children.keys { children[key]?.sort { ($0.lines.start, $0.id) < ($1.lines.start, $1.id) } }
        symbolsByID = symbolMap
        symbolsByFile = perFile
        childrenOf = children

        var extensions: [String: [Symbol]] = [:]
        var requirements: Set<String> = []
        var typeNames: Set<String> = []
        for symbol in snapshot.symbols {
            if symbol.kind == .extension {
                let simple = symbol.name.split(separator: ".").last.map(String.init) ?? symbol.name
                extensions[simple, default: []].append(symbol)
            } else if symbol.kind.isType {
                typeNames.insert(symbol.name)
            }
            if symbol.kind == .protocol || symbol.kind == .interface {
                for member in children[symbol.id] ?? [] { requirements.insert(member.name) }
            }
        }
        extensionsByName = extensions
        protocolRequirementNames = requirements
        repositoryTypeNames = typeNames

        var directoryCounts: [String: Int] = [:]
        for file in participating { directoryCounts[file.directory, default: 0] += 1 }
        let directoryList = directoryCounts.keys.sorted()
        var indexOfDirectory: [String: Int] = [:]
        for (index, directory) in directoryList.enumerated() { indexOfDirectory[directory] = index }
        var fileDirectories: [Int64: Int] = [:]
        for file in participating { fileDirectories[file.id] = indexOfDirectory[file.directory] }
        directoryPaths = directoryList
        directoryIndexOfFile = fileDirectories
        let areaMap = AreaMap(directories: directoryList, fileCounts: directoryList.map { directoryCounts[$0] ?? 0 }, repositoryName: snapshot.repositoryName)
        areas = areaMap
        var fileAreas: [Int64: Int] = [:]
        for (id, directory) in fileDirectories { fileAreas[id] = areaMap.areaIndexOfDirectory[directory] }
        areaIndexOfFile = fileAreas

        var layers: [Int64: String] = [:]
        var concerns: [Int64: Set<Concern>] = [:]
        // Directory components decide the layer before file names do, so classify each directory once
        // and fall back to the per-file (file-name) rule only where the directory says nothing.
        var directoryLayer: [Int: String?] = [:]
        for file in participating {
            let directory = fileDirectories[file.id] ?? -1
            let byDirectory: String?
            if let cached = directoryLayer[directory] {
                byDirectory = cached
            } else {
                let computed = file.directory.isEmpty ? nil : PathClassifier.layer(of: file.directory + "/_")
                directoryLayer[directory] = .some(computed)
                byDirectory = computed
            }
            if let layer = byDirectory ?? PathClassifier.layer(of: file.path) { layers[file.id] = layer }
            var set: Set<Concern> = []
            for module in file.externalImports {
                let key = module.lowercased()
                if let concern = Catalog.importConcerns[key] ?? Catalog.importConcerns[String(key.split(separator: ".").first ?? "")],
                   let normalized = Catalog.normalized(concern) {
                    set.insert(normalized)
                }
            }
            if !set.isEmpty { concerns[file.id] = set }
        }
        layerOfFile = layers
        importConcerns = concerns

        let fanOuts = sourceFiles.map { metricsMap[$0.id]?.fanOut ?? 0 }
        let fanIns = sourceFiles.map { metricsMap[$0.id]?.fanIn ?? 0 }
        fanOutThreshold = max(config.highFanOut, Self.percentile(fanOuts, config.fanPercentile))
        fanInThreshold = max(config.highFanIn, Self.percentile(fanIns, config.fanPercentile))
    }

    // MARK: Helpers

    func metric(_ id: Int64) -> FileGraphMetrics { metrics[id] ?? FileGraphMetrics() }

    /// Area index of a participating file (-1 for non-participating files).
    func areaIndex(of id: Int64) -> Int { areaIndexOfFile[id] ?? -1 }

    /// Area path of a participating file ("" for the root area).
    func area(of id: Int64) -> String {
        let index = areaIndex(of: id)
        return index >= 0 ? areas.areas[index] : ""
    }

    func areaName(of id: Int64) -> String { areas.name(at: areaIndex(of: id)) }

    func directoryIndex(of id: Int64) -> Int { directoryIndexOfFile[id] ?? -1 }

    func file(_ id: Int64) -> File? { filesByID[id] }

    func path(_ id: Int64) -> String { filesByID[id]?.path ?? "#\(id)" }

    /// Members of a type including those declared in same-name extensions of the same module.
    func members(ofType type: Symbol) -> [Symbol] {
        var result = childrenOf[type.id] ?? []
        let module = filesByID[type.fileID]?.module
        for ext in extensionsByName[type.name] ?? [] {
            let extModule = filesByID[ext.fileID]?.module
            guard extModule == module || extModule == nil || module == nil else { continue }
            result += childrenOf[ext.id] ?? []
        }
        return result
    }

    /// Concerns of a file: external imports plus strong concern words (≥2 hits) in its symbol names.
    func concerns(of file: File) -> [Concern: String] {
        var result: [Concern: String] = [:]
        for concern in importConcerns[file.id] ?? [] {
            let modules = file.externalImports.filter { module in
                let key = module.lowercased()
                return (Catalog.importConcerns[key] ?? Catalog.importConcerns[String(key.split(separator: ".").first ?? "")]).flatMap(Catalog.normalized) == concern
            }
            result[concern] = "imports " + modules.sorted().prefix(3).joined(separator: ", ")
        }
        var words: [String] = FastWords.split(file.stem)
        for symbol in symbolsByFile[file.id] ?? [] where symbol.kind != .extension {
            words += FastWords.split(symbol.name)
        }
        for (concern, count) in ConceptLexicon.concerns(for: words) where count >= 2 {
            guard let normalized = Catalog.normalized(concern), result[normalized] == nil else { continue }
            result[normalized] = "\(count) \(normalized.displayName) identifiers"
        }
        return result
    }

    static func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded(.down))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    /// Display name of a file: its file name, or the path when names would be ambiguous.
    func displayName(_ id: Int64) -> String {
        guard let file = filesByID[id] else { return "#\(id)" }
        return file.fileName
    }
}

// MARK: - Formatting

enum Format {
    /// Locale-independent thousands grouping (deterministic output).
    static func count(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var grouped: [Character] = []
        for (index, character) in digits.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return (value < 0 ? "-" : "") + String(grouped.reversed())
    }

    static func percent(_ value: Double) -> String {
        let pct = value * 100
        if pct > 0 && pct < 1 { return String(format: "%.1f%%", pct) }
        return "\(Int(pct.rounded()))%"
    }

    static func points(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static func plural(_ count: Int, _ singular: String, _ pluralForm: String? = nil) -> String {
        "\(Format.count(count)) \(count == 1 ? singular : (pluralForm ?? singular + "s"))"
    }

    /// Picks the verb form agreeing with a count: `verb(1, "exceeds", "exceed")`.
    static func verb(_ count: Int, _ singular: String, _ pluralForm: String) -> String {
        count == 1 ? singular : pluralForm
    }

    /// "a", "a and b", "a, b and c".
    static func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    static func list(_ items: [String], limit: Int = 4) -> String {
        guard !items.isEmpty else { return "" }
        let shown = items.prefix(limit)
        let rest = items.count - shown.count
        let joined = shown.joined(separator: ", ")
        return rest > 0 ? "\(joined) and \(rest) more" : joined
    }
}

/// Identifier splitting with an ASCII fast path; same rules as `Tokenizer.splitIdentifier`
/// (`URLSessionTask` → url, session, task; `refresh_token` → refresh, token; `HTTP2Client` → http2, client).
enum FastWords {
    static func split(_ identifier: String) -> [String] {
        var words: [String] = []
        var current: [UInt8] = []
        current.reserveCapacity(24)
        var bytes = identifier.utf8.makeIterator()
        var previous: UInt8?
        var pending = bytes.next()
        func flush() {
            if !current.isEmpty {
                words.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            }
        }
        while let byte = pending {
            let next = bytes.next()
            if byte >= 0x80 { return Tokenizer.splitIdentifier(identifier) }
            let isUpper = byte >= 65 && byte <= 90
            let isLower = byte >= 97 && byte <= 122
            let isDigit = byte >= 48 && byte <= 57
            if !(isUpper || isLower || isDigit) {
                flush()
                previous = nil
                pending = next
                continue
            }
            if let last = previous, !current.isEmpty {
                let lastLower = last >= 97 && last <= 122
                let lastUpper = last >= 65 && last <= 90
                let lastDigit = last >= 48 && last <= 57
                let nextLower = next.map { $0 >= 97 && $0 <= 122 } ?? false
                if isUpper && (lastLower || lastDigit || (lastUpper && nextLower)) { flush() }
            }
            current.append(isUpper ? byte | 0x20 : byte)
            previous = byte
            pending = next
        }
        flush()
        return words
    }
}
