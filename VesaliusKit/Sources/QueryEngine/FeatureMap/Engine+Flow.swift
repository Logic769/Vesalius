import Foundation
import RepositoryIndex
import SemanticSearch
import VesaliusCore

extension RepositoryEngine {
    /// A function's call sites in order: it follows a body that only hands the work on (`commit` →
    /// `commitLocked`), lists each step with its resolved target, flags IO sinks, and adds the owner type's other
    /// writers, the readers of what the flow writes and the files of that format. `target` is any `usages`
    /// target naming a function or method.
    public func flow(of target: String) throws -> FlowView {
        guard case .symbol(let rows) = try resolveUsageTarget(target), let row = rows.first else {
            throw EngineError.invalidQuery("“\(target)” is not a function; flow(of:) needs a function or method, e.g. Type.method.")
        }
        guard row.kind.isCallable else {
            let kind = row.kind.displayName
            throw EngineError.invalidQuery("\(row.qualifiedName) is \("aeiou".contains(kind.prefix(1)) ? "an" : "a") \(kind); flow(of:) needs a function or method.")
        }
        let analysis = try search().analyze("")
        let context = try FeatureContext(engine: self, analysis: analysis)
        return try FlowBuilder(context: context, wrappers: try sinkWrappers()).flow(from: row)
    }
}

/// Builds flow views.
struct FlowBuilder {
    let context: FeatureContext
    let wrappers: SinkWrappers

    static let maximumSteps = 16
    static let delegationDepth = 2
    static let maximumCallers = 5

    // MARK: Entry

    /// The flow a question asks for: the method named by one of its flow verbs that reaches the most sinks
    /// within its delegation chain, preferring the implementation over wrappers that call it.
    func flow(forVerbs verbs: [String], focus: String?, outcome: SearchOutcome) throws -> FlowView? {
        if let focus, case .symbol(let rows)? = try? context.engine.resolveUsageTarget(focus), let row = rows.first, row.kind.isCallable {
            return try flow(from: row)
        }
        var candidates: [(row: RepositoryEngine.SymbolRow, chain: [RepositoryEngine.SymbolRow], sinks: Double, verb: Int)] = []
        let hitFiles = Set(outcome.hits.prefix(10).map(\.fileID))
        for (index, verb) in verbs.enumerated() {
            let rows = context.symbolRows(where: "s.name = ? COLLATE NOCASE AND s.kind IN ('method', 'function')", [verb], limit: 200)
            for row in rows {
                guard let info = context.file(row.fileID), !info.isTest, !HybridSearch.isDemoPath(info.path) else { continue }
                let chain = try delegationChain(from: row)
                var reach = 0.0
                for member in chain {
                    let refs = try context.refs(where: "r.from_symbol_id = ? AND r.kind IN ('call', 'instantiate')", [member.id])
                    reach += Double(refs.filter { isSink($0) }.count) + 0.5 * Double(refs.filter { $0.target.map(wrappers.indirect.contains) ?? false }.count)
                }
                if hitFiles.contains(row.fileID) { reach += 0.5 }
                guard reach > 0 else { continue }
                candidates.append((row, chain, reach, index))
            }
        }
        // A candidate whose chain runs through another candidate only wraps it.
        let ids = Set(candidates.map(\.row.id))
        let implementations = candidates.filter { candidate in !candidate.chain.dropFirst().contains { ids.contains($0.id) } }
        guard let best = (implementations.isEmpty ? candidates : implementations)
            .max(by: { $0.sinks == $1.sinks ? $0.verb > $1.verb : $0.sinks < $1.sinks }) else { return nil }
        return try flow(from: best.row)
    }

    /// The entry and the members it hands its work to, at most `delegationDepth` hops: a short body whose one
    /// call into the repository (closure-taking wrappers like `withWriteLock { }` aside) is another function, or
    /// whose callee repeats its name (`commit` → `commitLocked`).
    func delegationChain(from entry: RepositoryEngine.SymbolRow) throws -> [RepositoryEngine.SymbolRow] {
        var chain = [entry]
        var current = entry
        for _ in 0..<Self.delegationDepth {
            let refs = try context.refs(where: "r.from_symbol_id = ? AND r.kind = 'call' AND r.target_symbol_id IS NOT NULL AND r.confidence >= ?", [current.id, context.threshold])
            let callees = context.symbols(Array(Set(refs.compactMap(\.target)).subtracting(chain.map(\.id)))).values.filter { $0.kind.isCallable }
            let wrapperCalls = Set(refs.filter { ($0.labels ?? []).last?.hasSuffix("{}") == true }.compactMap(\.target))
            let named = callees.filter { $0.name.lowercased().hasPrefix(current.name.lowercased()) || $0.name.lowercased().hasSuffix(current.name.lowercased()) }
            let plain = callees.filter { !wrapperCalls.contains($0.id) }
            let next: RepositoryEngine.SymbolRow?
            if named.count == 1 {
                next = named.first
            } else if current.lines.count <= 8, plain.count == 1 {
                next = plain.first
            } else {
                next = nil
            }
            guard let next else { break }
            chain.append(next)
            current = next
        }
        return chain
    }

    // MARK: Flow

    func flow(from entry: RepositoryEngine.SymbolRow) throws -> FlowView {
        let chain = try delegationChain(from: entry)
        let body = chain.last ?? entry
        let refs = try context.refs(where: "r.from_symbol_id = ? ORDER BY r.line, r.col", [body.id])
        let steps = steps(body, refs: refs)
        let owner = body.parentID.flatMap { context.symbol($0) }

        var sinkNames: [String] = []
        for ref in refs where isSink(ref) {
            let label: String
            if let target = ref.target, let sinks = wrappers.direct[target], let row = context.symbol(target) {
                // The sink the wrapper is named after (`fsync` in `FDFile.fsync`), else its first.
                let sink = sinks.first { row.name.localizedCaseInsensitiveContains($0) } ?? sinks[0]
                label = "\(row.qualifiedName) → \(sink)"
            } else {
                label = ref.receiver.map { "\($0).\(ref.name)" } ?? ref.name
            }
            if !sinkNames.contains(label) { sinkNames.append(label) }
        }
        let calledBy = try callers(of: entry)
        var flow = FlowView(entry: reference(entry), body: reference(body), sinks: Array(sinkNames.prefix(4)), calledBy: calledBy.callers, steps: steps)
        flow.moreCallers = calledBy.more
        if let owner {
            let excluded = Set(chain.map(\.id)).union(steps.compactMap { step in step.target.flatMap { name in context.symbolRows(where: "s.qualified_name = ? AND s.parent_id = ?", [name, owner.id], limit: 1).first?.id } })
            flow.otherWriters = try otherWriters(owner: owner, excluding: excluded)
            let format = try formatTypes(body: body, refs: refs, writers: flow.otherWriters)
            flow.readers = try readers(owner: owner, formatTypes: format.types, excluding: Set(chain.map(\.id)))
            flow.format = format.groups
        } else {
            let format = try formatTypes(body: body, refs: refs, writers: [])
            flow.format = format.groups
        }
        return flow
    }

    func reference(_ row: RepositoryEngine.SymbolRow) -> FeatureRef {
        FeatureRef(name: context.displayName(row, qualified: true), path: row.path, lines: row.lines)
    }

    func isSink(_ ref: FeatureContext.Ref) -> Bool {
        guard ref.isCall else { return false }
        if let target = ref.target, ref.confidence >= context.threshold { return wrappers.direct[target] != nil }
        guard let file = context.file(ref.fileID) else { return false }
        return IOSinks.kind(name: ref.name, receiver: ref.receiver, language: file.language, argumentLabels: ref.labels, resolvedInRepository: false) != nil
    }

    /// The body's steps in line order: statements that call a sink, that `try` or `await` a call (closure-taking
    /// wrappers such as `io.run {` and `throw` statements aside), or that call into the repository to write,
    /// commit, encode or apply.
    func steps(_ body: RepositoryEngine.SymbolRow, refs: [FeatureContext.Ref]) -> [FlowStep] {
        let calls = refs.filter(\.isCall)
        let byLine = Dictionary(grouping: calls, by: \.line)
        var steps: [FlowStep] = []
        var covered = Set<Int>()
        for line in byLine.keys.sorted() {
            guard !covered.contains(line), let lineRefs = byLine[line], let code = context.codeOnly(body.path, line)?.trimmingCharacters(in: .whitespaces) else { continue }
            let sink = lineRefs.contains { isSink($0) }
            let awaited = Self.hasWord(code, "try") || Self.hasWord(code, "await")
            let wrapperOnly = lineRefs.allSatisfy { ($0.labels ?? []).last?.hasSuffix("{}") == true } && code.hasSuffix("{")
            let throwing = code.hasPrefix("throw ")
            let main = lineRefs.first { isSink($0) }
                ?? lineRefs.first { $0.target != nil && $0.confidence >= context.threshold && ($0.labels ?? []).last?.hasSuffix("{}") != true && !isErrorType($0) }
                ?? lineRefs.first
            // A call into the repository named for writing (`writeHeaderPage`), not a collection's `append`.
            let writes = main.map { ref in Self.isWriteName(ref.name) && ref.target != nil && ref.confidence >= context.threshold } ?? false
            guard sink || (awaited && !wrapperOnly && !throwing) || (writes && !throwing) else { continue }
            guard let ref = main, let statement = context.statement(body.path, ref: ref) else { continue }
            for number in statement.start...max(statement.start, min(statement.end, statement.start + 2)) { covered.insert(number) }
            var step = FlowStep(line: statement.start, code: statement.text(maxLength: 90), isSink: sink)
            if !sink, let target = ref.target, ref.confidence >= context.threshold, let row = context.symbol(target), row.kind.isCallable {
                step.target = context.displayName(row, qualified: true)
                step.targetLines = row.lines
            }
            steps.append(step)
            if steps.count >= Self.maximumSteps { break }
        }
        return steps
    }

    func isErrorType(_ ref: FeatureContext.Ref) -> Bool {
        guard let target = ref.target, let row = context.symbol(target) else { return false }
        let owner = row.parentID.flatMap { context.symbol($0) }?.name ?? row.name
        return owner.hasSuffix("Error") || owner.hasSuffix("Exception")
    }

    /// Whether `word` occurs in `code` as a whole word (`try`, not the end of `entry`).
    static func hasWord(_ code: String, _ word: String) -> Bool {
        var search = code.startIndex
        while let range = code.range(of: word, range: search..<code.endIndex) {
            let before = range.lowerBound == code.startIndex ? nil : code[code.index(before: range.lowerBound)]
            let after = range.upperBound == code.endIndex ? nil : code[range.upperBound]
            let isWord: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
            if !isWord(before) && !isWord(after) { return true }
            search = range.upperBound
        }
        return false
    }

    static func isWriteName(_ name: String) -> Bool {
        let words = Tokenizer.splitIdentifier(name)
        guard let first = words.first else { return false }
        return ["write", "commit", "persist", "save", "flush", "sync", "encode", "serialize", "apply", "store", "append", "insert", "put"].contains(first)
    }

    /// Non-test callers of the entry: resolved at 0.85 or more, or through a property holding the entry's type.
    /// Wrappers that repeat the entry's name (`WaxSession.commit` for `Wax.commit`) come first: they are the ways
    /// in. At most `maximumCallers`, and how many more there are.
    func callers(of entry: RepositoryEngine.SymbolRow) throws -> (callers: [FeatureCaller], more: Int) {
        var result: [(caller: FeatureCaller, wraps: Bool)] = []
        var seen = Set<String>()
        func add(_ ref: FeatureContext.Ref) {
            guard let info = context.file(ref.fileID), !info.isTest, !HybridSearch.isDemoPath(info.path), ref.fromSymbol != entry.id else { return }
            let row = ref.fromSymbol.flatMap { context.symbol($0) }
            let name = row.map { context.displayName($0, qualified: true) }
            let key = "\(info.path):\(name ?? "")"
            guard seen.insert(key).inserted else { return }
            result.append((FeatureCaller(name: name, path: info.path, line: ref.line), row?.name == entry.name))
        }
        for ref in try context.refs(where: "r.target_symbol_id = ? AND r.confidence >= 0.85 AND r.kind = 'call' ORDER BY r.file_id, r.line", [entry.id]) { add(ref) }
        if let owner = entry.parentID.flatMap({ context.symbol($0) }), owner.kind.isType {
            let aliases = try ClusterUsers(context: context, roleOrder: [:], externalByFile: [:]).aliasesByFile(of: owner.name, excluding: entry.fileID)
            if !aliases.isEmpty {
                let receivers = Set(aliases.values.flatMap { $0 }).flatMap { [$0, "self." + $0] }.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
                for ref in try context.refs(where: "r.file_id IN (\(Array(aliases.keys).sqlList)) AND r.name = ? AND r.kind = 'call' AND r.receiver IN (\(receivers)) ORDER BY r.file_id, r.line", [entry.name]) {
                    let receiver = (ref.receiver ?? "").replacingOccurrences(of: "self.", with: "")
                    if aliases[ref.fileID]?.contains(receiver) == true { add(ref) }
                }
            }
        }
        let ordered = result.filter(\.wraps) + result.filter { !$0.wraps }
        return (ordered.prefix(Self.maximumCallers).map(\.caller), max(0, ordered.count - Self.maximumCallers))
    }

    // MARK: Writers, readers, format

    /// The owner type's other members that write through a sink, with their sink lines and the calls right after.
    func otherWriters(owner: RepositoryEngine.SymbolRow, excluding: Set<Int64>) throws -> [FeatureMember] {
        let members = context.symbolRows(where: "s.parent_id = ? AND s.kind IN ('method', 'function', 'initializer')", [owner.id])
        var writers: [(row: RepositoryEngine.SymbolRow, lines: [FeatureEvidence], count: Int)] = []
        for member in members where !excluding.contains(member.id) {
            let refs = try context.refs(where: "r.from_symbol_id = ? AND r.kind = 'call' ORDER BY r.line, r.col", [member.id])
            let sinkLines = Set(refs.filter { isSink($0) }.map(\.line))
            guard !sinkLines.isEmpty else { continue }
            var evidence: [FeatureEvidence] = []
            var shown = Set<Int>()
            // Each sink line, and a `try` call right after it in the same block (`wal.append` after the payload write).
            func triesCall(_ line: Int) -> Bool {
                guard let code = context.codeOnly(member.path, line) else { return false }
                return Self.hasWord(code, "try") && !code.trimmingCharacters(in: .whitespaces).hasSuffix("{")
            }
            for line in sinkLines.sorted() {
                for ref in refs where (ref.line == line || (ref.line > line && ref.line <= line + 2 && triesCall(ref.line))) && !shown.contains(ref.line) {
                    guard evidence.count < 3, let gist = context.gist(member.path, line: ref.line, name: ref.name, limit: 60) else { continue }
                    shown.insert(ref.line)
                    evidence.append(FeatureEvidence(line: ref.line, code: gist, kind: sinkLines.contains(ref.line) ? .sink : .step))
                }
            }
            writers.append((member, evidence, sinkLines.count))
        }
        return writers.sorted { $0.row.lines.start < $1.row.lines.start }.prefix(4).map { writer in
            FeatureMember(name: context.displayName(writer.row), path: writer.row.path, lines: writer.row.lines, evidence: writer.lines)
        }
    }

    /// Types the flow writes (instantiated, referenced or encoded in its body and its other writers), grouped by
    /// folder: a folder with 3 or more of them lists all its files when most of its files declare one (the format's
    /// own folder, `WAL/`), else only the files that do and how many others it has (`Services/`); other folders list
    /// the files that declare them.
    func formatTypes(body: RepositoryEngine.SymbolRow, refs: [FeatureContext.Ref], writers: [FeatureMember]) throws -> (types: Set<Int64>, groups: [FlowFormatGroup]) {
        var typeIDs = Set<Int64>()
        let owner = body.parentID
        func addType(of target: Int64) {
            guard var row = context.symbol(target) else { return }
            while !row.kind.isType, let parent = row.parentID.flatMap({ context.symbol($0) }) { row = parent }
            // A nested type counts as its top-level type.
            while let parent = row.parentID.flatMap({ context.symbol($0) }), parent.kind.isType { row = parent }
            guard row.kind.isType, row.id != owner, !row.name.hasSuffix("Error"), let info = context.file(row.fileID), !info.isTest else { return }
            typeIDs.insert(row.id)
        }
        var bodies = [body.id]
        for writer in writers {
            if let row = context.symbolRows(where: "s.file_id = (SELECT id FROM files WHERE path = ?) AND s.start_line = ?", [writer.path, writer.lines.start], limit: 1).first { bodies.append(row.id) }
        }
        let flowRefs = refs + (bodies.count > 1 ? try context.refs(where: "r.from_symbol_id IN (\(Array(bodies.dropFirst()).sqlList))") : [])
        for ref in flowRefs where ref.confidence >= context.threshold {
            if let target = ref.target { addType(of: target) }
        }
        // One hop into the codec: what the format types' encoders and decoders use (`BinaryEncoder`).
        let direct = typeIDs
        if !direct.isEmpty {
            let codecMembers = context.symbolRows(where: """
                s.parent_id IN (\(Array(direct).sqlList)) AND (s.name LIKE 'encode%' OR s.name LIKE 'decode%' OR s.name LIKE 'serialize%')
                """, [], limit: 200)
            if !codecMembers.isEmpty {
                for ref in try context.refs(where: "r.from_symbol_id IN (\(codecMembers.map(\.id).sqlList)) AND r.confidence >= ? AND r.target_symbol_id IS NOT NULL", [context.threshold]) {
                    if let target = ref.target { addType(of: target) }
                }
            }
        }
        // The owner's file is the flow itself, not part of the format.
        let rows = context.symbols(Array(typeIDs)).values.filter { $0.fileID != body.fileID }
        var byFolder: [String: Set<String>] = [:]
        for row in rows { byFolder[(row.path as NSString).deletingLastPathComponent, default: []].insert(row.path) }
        var groups: [FlowFormatGroup] = []
        var singles: [FlowFormatFile] = []
        for (folder, files) in byFolder.sorted(by: { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }) {
            if files.count >= 3 {
                let all = try context.db.query("SELECT id, path FROM files WHERE path LIKE ? AND path NOT LIKE ? AND is_test = 0 ORDER BY path", [folder + "/%", folder + "/%/%"]) { ($0.int64(0), $0.string(1)) }
                    .filter { Language.detect(fileName: ($0.1 as NSString).lastPathComponent).isCode }
                // Most of its files declare one: the format's own folder, listed whole.
                let listed = files.count * 2 > all.count ? all : all.filter { files.contains($0.1) }
                groups.append(FlowFormatGroup(folder: folder, files: listed.map { id, path in FlowFormatFile(path: path, types: primaryTypes(fileID: id)) },
                                              more: all.count - listed.count))
            } else {
                for path in files.sorted() {
                    let id = context.fileID(path: path)
                    singles.append(FlowFormatFile(path: path, types: id.map { primaryTypes(fileID: $0) } ?? []))
                }
            }
        }
        if !singles.isEmpty { groups.append(FlowFormatGroup(folder: "", files: Array(singles.prefix(6)))) }
        return (direct, Array(groups.prefix(4)))
    }

    func primaryTypes(fileID: Int64) -> [String] {
        context.symbolRows(where: "s.file_id = ? AND s.depth = 0 AND s.kind IN ('class','struct','enum','actor','protocol') ORDER BY s.start_line", [fileID], limit: 4).map(\.name)
    }

    /// Members of the owner type that read back what the flow writes: they call a decoder of a format type, directly
    /// or through one function (`Wax.open` → `FooterScanner.findFooter` → `MV2SFooter.decode`).
    func readers(owner: RepositoryEngine.SymbolRow, formatTypes: Set<Int64>, excluding: Set<Int64>) throws -> [FeatureMember] {
        guard !formatTypes.isEmpty else { return [] }
        // Decoders, not reads: reading bytes back (`readExactly`) is IO, decoding them is the format.
        let decoders = context.symbolRows(where: """
            s.parent_id IN (\(Array(formatTypes).sqlList)) AND (s.name LIKE 'decode%' OR s.name LIKE 'deserialize%' OR s.name LIKE 'parse%')
            """, [], limit: 200)
        guard !decoders.isEmpty else { return [] }
        let decoderIDs = Set(decoders.map(\.id))
        // Functions that call a decoder (one hop from the owner's members).
        var intermediates = Set<Int64>()
        try context.db.forEach("""
            SELECT DISTINCT r.from_symbol_id FROM refs r JOIN files f ON f.id = r.file_id
            WHERE r.target_symbol_id IN (\(Array(decoderIDs).sqlList)) AND r.confidence >= ? AND f.is_test = 0 AND r.from_symbol_id IS NOT NULL
            """, [context.threshold]) { intermediates.insert($0.int64(0)) }
        // Overloads of an intermediate count as it (`findLastValidFooter(in:)` and its other form), so a call the
        // linker bound to either overload is a read.
        if !intermediates.isEmpty {
            try context.db.forEach("""
                SELECT o.id FROM symbols o JOIN symbols i ON i.qualified_name = o.qualified_name AND i.file_id = o.file_id
                WHERE i.id IN (\(Array(intermediates).sqlList))
                """) { intermediates.insert($0.int64(0)) }
        }
        let targets = decoderIDs.union(intermediates)
        let members = context.symbolRows(where: "s.parent_id = ? AND s.kind IN ('method', 'function', 'initializer')", [owner.id])
        var readers: [(row: RepositoryEngine.SymbolRow, refs: [FeatureContext.Ref])] = []
        for member in members where !excluding.contains(member.id) {
            let refs = try context.refs(where: "r.from_symbol_id = ? AND r.target_symbol_id IN (\(Array(targets).sqlList)) AND r.confidence >= ? ORDER BY r.line", [member.id, context.threshold])
            if !refs.isEmpty { readers.append((member, refs)) }
        }
        return readers.sorted { $0.refs.count == $1.refs.count ? $0.row.lines.start < $1.row.lines.start : $0.refs.count > $1.refs.count }.prefix(2).map { reader in
            var evidence: [FeatureEvidence] = []
            var targets = Set<Int64>()
            let distinct = reader.refs.filter { ref in ref.target.map { targets.insert($0).inserted } ?? false }
            for (index, ref) in distinct.prefix(4).enumerated() {
                if index == 0, let statement = context.statement(reader.row.path, ref: ref) {
                    evidence.append(FeatureEvidence(line: statement.start, code: statement.text(maxLength: 100), kind: .call, primary: true))
                } else if let gist = context.gist(reader.row.path, line: ref.line, name: ref.name, limit: 60) {
                    evidence.append(FeatureEvidence(line: ref.line, code: gist, kind: .call))
                }
            }
            return FeatureMember(name: context.displayName(reader.row, qualified: true), path: reader.row.path, lines: reader.row.lines, evidence: evidence)
        }
    }
}
