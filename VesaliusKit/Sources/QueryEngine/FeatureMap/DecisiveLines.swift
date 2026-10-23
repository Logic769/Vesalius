import Foundation
import RepositoryIndex
import VesaliusCore

/// The lines that decide what a member does, read from its body: framework and IO calls,
/// environment reads and writes, the return of a short Boolean getter, writes to the feature's stored state,
/// guards, and calls into the feature's other members.
///
/// Each kind has a weight; the best line of each strong kind is taken first, so a member that writes its state
/// after a run of framework calls still shows the write. Lines under `#if` weigh a little less. The chosen lines
/// print in line order: the strongest one or two as full statements, the rest compactly.
struct DecisiveLines {
    let context: FeatureContext
    /// References attributed to the question's frameworks.
    let externalRefs: Set<Int64>
    /// Repository functions that write through a sink (`FDFile.writeAll`).
    let sinkWrappers: Set<Int64>
    /// The feature's stored properties, whose writes are decisive.
    let storedState: Set<Int64>
    /// Members of the feature that play a role: calls to them show how the work is split.
    let roleMembers: Set<Int64>

    struct Pick {
        let line: Int
        let score: Double
        let kind: FeatureEvidence.Kind
        let ref: FeatureContext.Ref?
        /// What a compact line says when the statement is not shown (`transaction.finish()`).
        let name: String?
    }

    static let strongKinds: [FeatureEvidence.Kind] = [.external, .sink, .env, .gate, .guard, .write]

    /// The decisive lines of `member`'s body, at most `limit`, in line order.
    func evidence(for member: RepositoryEngine.SymbolRow, refs: [FeatureContext.Ref], limit: Int = 3, primaries: Int = 2) -> [FeatureEvidence] {
        let picks = choose(candidates(for: member, refs: refs), limit: limit)
        return render(picks, path: member.path, primaries: primaries)
    }

    func candidates(for member: RepositoryEngine.SymbolRow, refs: [FeatureContext.Ref]) -> [Pick] {
        var best: [Int: Pick] = [:]
        func offer(_ pick: Pick) {
            if let existing = best[pick.line], existing.score >= pick.score { return }
            best[pick.line] = pick
        }
        var writtenState = Set<Int64>()
        // The declaration's own lines (attributes, parameters) are not part of what it does.
        let headerEnd = member.lines.count > 1 ? (context.engine.sourceText.file(member.path)?.headerEnd(from: member.lines.start) ?? member.lines.start) : member.lines.start - 1
        for ref in refs.sorted(by: { ($0.line, $0.column) < ($1.line, $1.column) }) where ref.line > headerEnd && ref.kind != "type" {
            let discount = ref.conditions == nil ? 0 : 0.5
            if ref.isEnvironment && ref.name != "env:*" {
                offer(Pick(line: ref.line, score: 5 - discount, kind: .env, ref: ref, name: String(ref.name.dropFirst(4))))
            } else if externalRefs.contains(ref.id) {
                offer(Pick(line: ref.line, score: 5 - discount, kind: .external, ref: ref, name: ref.name))
            } else if isSink(ref) {
                offer(Pick(line: ref.line, score: 5 - discount, kind: .sink, ref: ref, name: ref.name))
            } else if ref.isCall, ref.target == nil, context.externalBindings(ref.fileID).contains(ref.receiver ?? ref.name) {
                // A call into another library: decisive when the question names it (`safeStorage` for "at rest").
                let binding = ref.receiver ?? ref.name
                let named = FeatureContext.match(FeatureContext.words(binding) + FeatureContext.words(ref.name), terms: context.analysis.parsed.terms) >= 0.8
                offer(Pick(line: ref.line, score: (named ? 5 : 3.5) - discount, kind: .external, ref: ref, name: ref.name))
            } else if ref.kind == "write", let target = ref.target, storedState.contains(target), ref.confidence >= context.threshold {
                let first = writtenState.insert(target).inserted
                offer(Pick(line: ref.line, score: (first ? 3 : 1.5) - discount, kind: .write, ref: ref, name: ref.name))
            } else if ref.isCall, let target = ref.target, target != member.id, roleMembers.contains(target), ref.confidence >= context.threshold {
                offer(Pick(line: ref.line, score: 2 - discount, kind: .call, ref: ref, name: ref.name))
            } else if ref.isCall, ref.target != nil, ref.confidence >= context.threshold {
                // Any other call into the repository: shown only when the member has nothing stronger.
                offer(Pick(line: ref.line, score: 1.5 - discount, kind: .step, ref: ref, name: ref.name))
            }
        }
        let bodyStart = member.lines.start + (member.lines.count > 1 ? 1 : 0)
        let body = LineRange(bodyStart, max(bodyStart, member.lines.end - (member.lines.count > 2 ? 1 : 0)))
        // Guards and the gate return come from the text.
        var lastReturn: Int?
        for line in body.start...body.end {
            // Keywords are tested on code only (strings and comments blanked); content on the code with its strings.
            guard let code = context.codeOnly(member.path, line)?.trimmingCharacters(in: .whitespaces), !code.isEmpty,
                  let text = context.codeLine(member.path, line) else { continue }
            if code.hasPrefix("guard ") {
                // Unwrapping and pattern guards (`guard let x = …`, `guard case .verified(let t) = …`) only bind.
                let binding = text.hasPrefix("guard let ") || text.hasPrefix("guard var ") || text.hasPrefix("guard case ")
                let trivial = text.hasPrefix("guard let self") || (text.hasPrefix("guard !") && !text.contains("(") && !text.contains("\""))
                let weighty = !binding && (text.contains("\"") || text.contains("("))
                offer(Pick(line: line, score: trivial ? 0.5 : (weighty ? 3.5 : binding ? 1.5 : 2), kind: .guard, ref: nil, name: nil))
            }
            if code.hasPrefix("return ") {
                let value = text.dropFirst(7).trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
                if !["true", "false", "nil", "null", "undefined", "None", "True", "False"].contains(value), !value.isEmpty { lastReturn = line }
            }
        }
        if let lastReturn, isShortBooleanGetter(member) {
            offer(Pick(line: lastReturn, score: 5, kind: .gate, ref: nil, name: nil))
        }
        return Array(best.values)
    }

    /// The best line of each strong kind, then the best of the rest, at most `limit`. A line under `#if` (a debug
    /// escape hatch) does not take its kind's reserved place; it competes with the rest by score.
    func choose(_ picks: [Pick], limit: Int) -> [Pick] {
        var chosen: [Pick] = []
        var used = Set<Int>()
        for kind in Self.strongKinds {
            guard chosen.count < limit else { break }
            if let pick = picks.filter({ $0.kind == kind && $0.score >= 3 && $0.ref?.conditions == nil && !used.contains($0.line) })
                .max(by: { $0.score == $1.score ? $0.line > $1.line : $0.score < $1.score }) {
                chosen.append(pick)
                used.insert(pick.line)
            }
        }
        for pick in picks.sorted(by: { $0.score == $1.score ? $0.line < $1.line : $0.score > $1.score }) where chosen.count < limit {
            guard pick.score >= 1.5, used.insert(pick.line).inserted else { continue }
            chosen.append(pick)
        }
        return chosen.sorted { $0.line < $1.line }
    }

    /// Picks as evidence: the strongest as a statement, then the others as gists in line order, and a second
    /// statement (up to `primaries`) only for a strong line of another kind (a write after a framework call).
    func render(_ picks: [Pick], path: String, primaries: Int) -> [FeatureEvidence] {
        let ranked = picks.sorted { $0.score == $1.score ? $0.line < $1.line : $0.score > $1.score }
        var primaryPicks: [Pick] = []
        for pick in ranked where primaryPicks.count < primaries && pick.score >= 3 {
            if primaryPicks.isEmpty || !primaryPicks.contains(where: { $0.kind == pick.kind }) { primaryPicks.append(pick) }
        }
        let primaryLines = Set(primaryPicks.map(\.line))
        let ordered = primaryPicks + picks.filter { !primaryLines.contains($0.line) }.sorted { $0.line < $1.line }
        var result: [FeatureEvidence] = []
        var covered = Set<Int>()
        for pick in ordered {
            guard !covered.contains(pick.line) else { continue }
            if primaryLines.contains(pick.line) {
                let statement = pick.ref.flatMap { context.statement(path, ref: $0) } ?? context.statement(path, line: pick.line, name: pick.name)
                guard let statement else { continue }
                for number in statement.start...max(statement.start, min(statement.end, statement.start + 2)) { covered.insert(number) }
                result.append(FeatureEvidence(line: statement.start, code: statement.text(maxLength: 110), kind: pick.kind, primary: true))
            } else if let gist = context.gist(path, line: pick.line, name: pick.name) {
                covered.insert(pick.line)
                result.append(FeatureEvidence(line: pick.line, code: gist, kind: pick.kind))
            }
        }
        return result
    }

    func isSink(_ ref: FeatureContext.Ref) -> Bool {
        guard ref.isCall else { return false }
        if let target = ref.target, sinkWrappers.contains(target), ref.confidence >= context.threshold { return true }
        guard let file = context.file(ref.fileID) else { return false }
        let resolved = ref.target != nil && ref.confidence >= context.threshold
        return IOSinks.kind(name: ref.name, receiver: ref.receiver, language: file.language, argumentLabels: ref.labels, resolvedInRepository: resolved) != nil
    }

    /// A computed Boolean property or a function returning `Bool` with a body of 8 lines or fewer.
    func isShortBooleanGetter(_ member: RepositoryEngine.SymbolRow) -> Bool {
        guard member.lines.count <= 10, let signature = member.signature else { return false }
        let compact = signature.replacingOccurrences(of: " ", with: "")
        return compact.hasSuffix(":Bool") || compact.contains("->Bool") || compact.hasSuffix(":boolean") || compact.contains("):boolean")
            || compact.hasSuffix("->bool")
    }

    // MARK: Constants and delegation

    /// String constants of the feature (`static let annualID = "yearly_atlas"`, `const CIPHER_ID = "aes-256-gcm"`),
    /// best first: those configuration links point at, then those whose name or value the question uses, then
    /// those the feature's members read. Nil-free; at most `limit`.
    func keyLiterals(_ constants: [RepositoryEngine.SymbolRow], linkedLines: Set<Int>, readBy members: Set<Int64>, terms: [String: Double], limit: Int = 3) throws -> [FeatureEvidence] {
        var scored: [(row: RepositoryEngine.SymbolRow, value: String, score: Double)] = []
        for row in constants {
            guard let signature = row.signature, let value = Self.stringValue(of: signature) else { continue }
            var score = 0.0
            if linkedLines.contains(row.lines.start) { score += 10 }
            score += FeatureContext.match(Tokenizer.splitIdentifier(row.name) + Tokenizer.splitIdentifier(value), terms: terms) * 2
            if row.visibility != .private && row.visibility != .fileprivate { score += 0.5 }
            if !members.isEmpty, try context.db.scalarInt("SELECT COUNT(*) FROM refs WHERE target_symbol_id = ? AND from_symbol_id IN (\(Array(members).sqlList))", [row.id]) > 0 {
                score += 1
            }
            guard score >= 1.5 else { continue }
            scored.append((row, value, score))
        }
        let best = scored.sorted { $0.score == $1.score ? $0.row.lines.start < $1.row.lines.start : $0.score > $1.score }.prefix(limit)
        return best.sorted { $0.row.lines.start < $1.row.lines.start }.enumerated().compactMap { index, item in
            if index == 0, let statement = context.statement(item.row.path, line: item.row.lines.start, name: item.row.name) {
                return FeatureEvidence(line: statement.start, code: statement.text(maxLength: 110), kind: .literal, primary: true)
            }
            return FeatureEvidence(line: item.row.lines.start, code: "\(item.row.name) \"\(item.value)\"", kind: .literal)
        }
    }

    /// The string a constant's signature assigns (`static let annualID = "yearly_atlas"` → `yearly_atlas`).
    static func stringValue(of signature: String) -> String? {
        guard let match = signature.firstMatch(of: /=\s*["'`]([^"'`\\]{2,120})["'`]\s*;?$/) else { return nil }
        return String(match.1)
    }

    /// The member a short member hands its work to: the one other member of the feature it calls, when it is 10
    /// lines or shorter or the callee's name repeats its own (`restore(source:)` → `restoreTransactions()`).
    static func delegate(of member: RepositoryEngine.SymbolRow, refs: [FeatureContext.Ref], members: [Int64: RepositoryEngine.SymbolRow], threshold: Double) -> RepositoryEngine.SymbolRow? {
        let callees = Set(refs.filter { $0.isCall && $0.confidence >= threshold }.compactMap(\.target)).subtracting([member.id])
        let candidates = callees.compactMap { members[$0] }.filter { $0.kind.isCallable }
        guard candidates.count == 1, let callee = candidates.first else {
            // Overloads of one name count as one callee (`purchase(planID:)` → `purchase(_:)`).
            let named = candidates.filter { $0.name == member.name }
            return named.count == 1 && candidates.count <= 2 ? named.first : nil
        }
        let sharesName = callee.name.localizedCaseInsensitiveContains(member.name) || callee.name == member.name
        return member.lines.count <= 10 || sharesName ? callee : nil
    }
}
