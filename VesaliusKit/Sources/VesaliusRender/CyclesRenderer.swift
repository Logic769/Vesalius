import Foundation
import VesaliusCore

/// The `dependency_cycles` text:
///
///     1 import cycle under src/: scanned 214 files, 802 import edges, 0 unresolved (47 type-only, …); tests excluded
///     cycle 1: src/lib/shop/orders.ts ↔ invoices.ts
///       orders.ts:5  import { listInvoices } from "./invoices"  value · used :188 in resolveOrderInvoiceMap() · defined invoices.ts:24
///       invoices.ts:3  import { fetchOrderTotals } from "./orders"  value · used :96 in getInvoiceDetail() · defined orders.ts:130
///       load-time safe (…) · same on value-only and static-only edges · shop/index.ts re-exports both, not in cycle
///     no other strongly connected component in scope
///
/// Inside a cycle, the first file is a full path and files in its folder are shown by name. Over budget, cycles
/// lose detail in order (fewer uses and imports, then only their first line, then only a count per folder);
/// the stamp and the closing lines are never cut.
public enum CyclesRenderer {
    /// Imports listed per cycle before the rest are counted.
    static let edgesPerCycle = 12
    /// Use groups (one name in one declaration) listed per import.
    static let usesPerEdge = 4
    /// Characters of an import statement before its middle is elided.
    static let statementLimit = 90

    public static func render(_ report: ImportCycleReport, budget: Budget) -> String {
        let head = headLines(report)
        let tail = tailLines(report)
        let cycles = report.cycles
        func text(_ blocks: [[String]], _ extra: [String] = []) -> String {
            (head + blocks.flatMap { $0 } + extra + tail).joined(separator: "\n")
        }
        let full = cycles.map { lines($0, scope: report.scope, detail: .full) }
        guard !budget.isUnlimited else { return text(full) }

        // Sizes in bytes, each line with its newline, so a candidate is measured without joining it.
        func bytes(_ lines: [String]) -> Int { lines.reduce(0) { $0 + $1.utf8.count + 1 } }
        let fixed = bytes(head) + bytes(tail) - 1
        func fits(_ blockBytes: Int, _ extra: [String] = []) -> Bool {
            (fixed + blockBytes + bytes(extra) + 2) / 3 <= budget.tokens
        }
        if fits(full.reduce(0) { $0 + bytes($1) }) { return text(full) }
        let compact = cycles.map { lines($0, scope: report.scope, detail: .compact) }
        let compactBytes = compact.map(bytes)
        if fits(compactBytes.reduce(0, +)) { return text(compact) }
        let headers = cycles.map { lines($0, scope: report.scope, detail: .header) }
        let headerBytes = headers.map(bytes)

        // The first cycles in detail, the rest on their first line.
        var detailed = compactBytes.reduce(0, +)
        var firstLines = 0
        for shown in stride(from: cycles.count - 1, through: 0, by: -1) {
            detailed -= compactBytes[shown]
            firstLines += headerBytes[shown]
            let note = ["showing \(shown) of \(cycles.count) cycles in detail; a narrower path shows the others"]
            if fits(detailed + firstLines, note) { return text(Array(compact.prefix(shown)) + Array(headers.dropFirst(shown)), note) }
        }
        // Only some first lines fit: the rest are counted by folder (that line is at most a few hundred bytes).
        var shown = 0
        var used = 0
        while shown < headers.count, fits(used + headerBytes[shown], [String(repeating: " ", count: 300)]) {
            used += headerBytes[shown]
            shown += 1
        }
        while shown > 0 {
            let note = [moreLine(Array(cycles.dropFirst(shown)), total: cycles.count, shown: shown, scope: report.scope)]
            if fits(used, note) { return text(Array(headers.prefix(shown)), note) }
            shown -= 1
            used -= headerBytes[shown]
        }
        return text([], [moreLine(cycles, total: cycles.count, shown: 0, scope: report.scope)])
    }

    // MARK: Head and tail

    static func headLines(_ report: ImportCycleReport) -> [String] {
        let scope = report.scope
        let count = report.cycles.count
        var line = "\(count) import \(count == 1 ? "cycle" : "cycles") \(scopeText(scope)): scanned \(plural(scope.files, "file")), "
            + "\(plural(scope.edges, "import edge"))\(languageNote(scope)), \(scope.unresolved) unresolved"
        let flags = [(scope.typeOnly, "type-only"), (scope.reexports, "re-export"), (scope.dynamic, "dynamic"), (scope.sideEffect, "side-effect")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        if !flags.isEmpty { line += " (" + flags.joined(separator: ", ") + " counted)" }
        if scope.leavingScope > 0, let path = scope.path, !scope.isFile {
            line += ", \(scope.leavingScope) more leave \(path)/"
        }
        if scope.mocks > 0 { line += ", \(plural(scope.mocks, "mock import")) ignored" }
        line += "; " + (scope.includeTests ? "tests included" : scope.testFilesExcluded > 0 ? "\(plural(scope.testFilesExcluded, "test file")) excluded" : "tests excluded")
        var lines = [line]
        if !scope.unresolvedSites.isEmpty {
            let more = scope.unresolved - scope.unresolvedSites.count
            lines.append("unresolved: " + scope.unresolvedSites.map { "\($0.path):\($0.line) \"\($0.module)\"" }.joined(separator: " · ") + (more > 0 ? " · +\(more) more" : ""))
        }
        return lines
    }

    /// Which languages the edges come from, when that is not obvious: ` (C #include)` in a Swift repository,
    /// ` (TypeScript 812, Python 40)` in a mixed one. Nothing for a single scripting language.
    static func languageNote(_ scope: ImportCycleScope) -> String {
        let languages = scope.edgeLanguages.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        if languages.count > 1 { return " (" + languages.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")" }
        switch languages.first?.key {
        case "C", "C++": return " (\(languages[0].key) #include)"
        case "Objective-C": return " (Objective-C #import)"
        default: return ""
        }
    }

    static func scopeText(_ scope: ImportCycleScope) -> String {
        guard let path = scope.path else { return "in the repository" }
        return scope.isFile ? "through \(path)" : "under \(path)/"
    }

    static func tailLines(_ report: ImportCycleReport) -> [String] {
        var lines: [String] = []
        if report.crossingCycles > 0, let path = report.scope.path {
            let count = report.crossingCycles
            lines.append("\(count) more import \(count == 1 ? "cycle runs" : "cycles run") through \(path)/ and files outside it: dependency_cycles() checks the whole repository")
        }
        var swiftCycles = 0
        if let swift = report.swiftModules {
            swiftCycles = swift.cycles.count
            lines.append("Swift: \(plural(swift.cycles.count, "module import cycle")) among \(plural(swift.modules, "module")) "
                + "(\(plural(swift.dependencies, "module dependency", "module dependencies")) from \(plural(swift.importLines, "import line"))) · "
                + "Swift files in one module see each other without imports; reference loops are not import cycles")
            for (index, cycle) in swift.cycles.enumerated() {
                let sites = index < swift.cycleImports.count ? swift.cycleImports[index] : []
                let modules = cycle.count == 2 ? cycle.joined(separator: " ↔ ") : "\(cycle.count) modules \(cycle.joined(separator: ", "))"
                lines.append("  module cycle: \(modules)" + sites.prefix(6).map { " · \($0.path):\($0.line) import \($0.module)" }.joined()
                    + (sites.count > 6 ? " · +\(sites.count - 6) more" : ""))
            }
        }
        lines.append(report.cycles.isEmpty && swiftCycles == 0 ? "no strongly connected component in scope" : "no other strongly connected component in scope")
        return lines
    }

    /// `showing 8 of 13 cycles; the others by folder: src/lib/ 3, src/app/ 2 · more: dependency_cycles(path:"src/lib/")`.
    static func moreLine(_ rest: [ImportCycle], total: Int, shown: Int, scope: ImportCycleScope) -> String {
        var byFolder: [String: Int] = [:]
        for cycle in rest { byFolder[commonFolder(cycle.files), default: 0] += 1 }
        let folders = byFolder.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var line = "showing \(shown) of \(total) cycles; the others by folder: " + folders.prefix(6).map { "\($0.key.isEmpty ? "." : $0.key + "/") \($0.value)" }.joined(separator: ", ")
        if folders.count > 6 { line += ", +\(folders.count - 6) more folders" }
        if let first = folders.first, !first.key.isEmpty, first.key != scope.path {
            line += " · more: dependency_cycles(path:\(quoted(first.key + "/")))"
        }
        return line
    }

    // MARK: One cycle

    enum Detail {
        /// Every import (up to `edgesPerCycle`) with its uses and definitions.
        case full
        /// The walk's imports only, one use group each, no definitions.
        case compact
        /// The first line only.
        case header
    }

    static func lines(_ cycle: ImportCycle, scope: ImportCycleScope, detail: Detail) -> [String] {
        let names = Names(cycle)
        var first = header(cycle, names: names)
        if detail == .header {
            let folder = commonFolder(cycle.files)
            if !folder.isEmpty, folder != scope.path { first += " · detail: dependency_cycles(path:\(quoted(folder + "/")))" }
            return [first]
        }
        var out = [first]
        let walkPairs = Set(zip(cycle.path, cycle.path.dropFirst()).map { "\($0.0)>\($0.1)" })
        let listed = detail == .full
            ? Array(cycle.edges.prefix(edgesPerCycle))
            : Array(cycle.edges.filter { walkPairs.contains("\($0.from)>\($0.to)") }.prefix(edgesPerCycle / 2))
        for edge in listed {
            out.append("  " + edgeLine(edge, names: names, uses: detail == .full ? usesPerEdge : 1, definitions: detail == .full))
        }
        if cycle.edges.count > listed.count {
            let more = cycle.edges.count - listed.count
            out.append("  +\(more) more \(more == 1 ? "import" : "imports") among these files")
        }
        var summary = [loadText(cycle, names: names), modesText(cycle, names: names)]
        if let barrels = barrelText(cycle, names: names) { summary.append(barrels) }
        out.append("  " + summary.joined(separator: " · "))
        return out
    }

    /// `cycle 1: src/a/x.ts ↔ y.ts`, or `cycle 2 (3 files): src/a/x.ts → y.ts → z.ts → x.ts`.
    static func header(_ cycle: ImportCycle, names: Names) -> String {
        guard let start = cycle.files.first else { return "cycle \(cycle.id)" }
        if cycle.files.count == 2 {
            return "cycle \(cycle.id): \(start) ↔ \(names.short(cycle.files[1]))"
        }
        var walk = cycle.path.enumerated().map { $0.offset == 0 ? $0.element : names.short($0.element) }
        if walk.isEmpty { walk = [start] }
        var line = "cycle \(cycle.id) (\(cycle.files.count) files): " + walk.joined(separator: " → ")
        let onWalk = Set(cycle.path)
        let others = cycle.files.filter { !onWalk.contains($0) }
        if !others.isEmpty {
            line += "; also in it: " + others.prefix(6).map(names.short).joined(separator: ", ") + (others.count > 6 ? ", +\(others.count - 6) more" : "")
        }
        return line
    }

    /// `orders.ts:5  import { listInvoices } from "./invoices"  value · used :188 in resolveOrderInvoiceMap() · defined invoices.ts:24`.
    static func edgeLine(_ edge: ImportCycleEdge, names: Names, uses limit: Int, definitions: Bool) -> String {
        var line = "\(names.short(edge.from)):\(edge.line)  \(statement(edge))  \(classification(edge))"
        if let uses = usesText(edge, limit: limit) { line += " · " + uses }
        if definitions {
            let shown = edge.definitions.filter { definition in
                !edge.isValue || edge.uses.isEmpty || edge.uses.contains { $0.name == definition.name && !$0.isTypeUse }
            }
            let lines = Array(Set(shown.map(\.line))).sorted()
            if !lines.isEmpty {
                line += " · defined \(names.short(edge.to)):" + lines.prefix(6).map(String.init).joined(separator: ",") + (lines.count > 6 ? " +\(lines.count - 6)" : "")
            }
        }
        return line
    }

    static func statement(_ edge: ImportCycleEdge) -> String {
        guard var text = edge.statement else { return "imports \(quoted(edge.module))" }
        if text.hasSuffix(";") { text.removeLast() }
        return fit(text, limit: statementLimit)
    }

    /// An import statement shortened in the name list, so the module it names stays visible.
    static func fit(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        if let from = text.range(of: " from ", options: .backwards) {
            let tail = String(text[from.lowerBound...])
            var head = String(text[..<from.lowerBound])
            let closer = head.hasSuffix("}") ? " }" : ""
            let room = max(20, limit - tail.count - closer.count - 2)
            if head.count > room {
                // Cut after the last whole name that fits.
                var kept = head.prefix(room)
                if let comma = kept.lastIndex(of: ",") { kept = kept[...comma] }
                head = kept.trimmingCharacters(in: .whitespaces) + " …" + closer
                return head + tail
            }
        }
        return Elide.middle(text, limit: limit)
    }

    /// `value`, `type-only`, `value, dynamic`, `types only, elided`.
    static func classification(_ edge: ImportCycleEdge) -> String {
        var parts: [String] = []
        if edge.isTypeOnly {
            parts.append("type-only")
        } else if !edge.isValue {
            parts.append("types only, elided at runtime")
        } else {
            parts.append("value")
        }
        if edge.isReexport { parts.append("re-export") }
        if edge.isDynamic { parts.append("dynamic") }
        if edge.isSideEffect { parts.append("side-effect") }
        return parts.joined(separator: ", ")
    }

    /// `used :188 in resolveOrderInvoiceMap()`; with several imported names each group is named:
    /// `used listInvoices :188 in resolveOrderInvoiceMap(), createInvoice :12 at top level`.
    static func usesText(_ edge: ImportCycleEdge, limit: Int) -> String? {
        let relevant = edge.isValue ? edge.uses.filter { !$0.isTypeUse } : []
        guard !relevant.isEmpty else { return nil }
        struct Group {
            let name: String
            let place: String
            var lines: [Int]
        }
        var groups: [Group] = []
        for use in relevant {
            let place = Self.place(use)
            if let index = groups.firstIndex(where: { $0.name == use.name && $0.place == place }) {
                if !groups[index].lines.contains(use.line) { groups[index].lines.append(use.line) }
            } else {
                groups.append(Group(name: use.name, place: place, lines: [use.line]))
            }
        }
        let distinct = Set(groups.map(\.name))
        let imported = edge.names.filter { !$0.isTypeOnly }
        let named = distinct.count > 1 || imported.count != 1 || imported.first.map { $0.name != groups[0].name && $0.localName != groups[0].name } ?? true
        var pieces = groups.prefix(limit).map { group in
            (named ? group.name + " " : "") + ":" + LineList.format(group.lines) + " " + group.place
        }
        if groups.count > limit { pieces.append("+\(groups.count - limit) more") }
        return "used " + pieces.joined(separator: ", ")
    }

    /// `in resolveOrderInvoiceMap()`, `at top level`, `at load, in value` (a top-level initializer),
    /// `in setup(), called at load`, `in helper(), called at load via setup`.
    static func place(_ use: ImportUse) -> String {
        guard let enclosing = use.enclosing else { return use.atLoad ? "at top level" : "in a top-level callback" }
        let shown = enclosing + (use.enclosingIsCallable ? "()" : "")
        guard use.atLoad else { return "in \(shown)" }
        guard let via = use.via else { return "at load, in \(shown)" }
        return "in \(shown), called at load" + (sameDeclaration(via, enclosing) ? "" : " via \(via)")
    }

    /// `via` is a plain name; `enclosing` may be qualified (`Store.setup`).
    static func sameDeclaration(_ via: String, _ enclosing: String) -> Bool {
        via == enclosing || enclosing.hasSuffix("." + via)
    }

    static func loadText(_ cycle: ImportCycle, names: Names) -> String {
        guard !cycle.loadTimeUses.isEmpty else { return "load-time safe (no imported binding used at module top level)" }
        let shown = Array(cycle.loadTimeUses.prefix(4))
        var sites = shown.filter { !$0.isFromImport }.map { use -> String in
            let site = "\(names.short(use.path)):\(use.line) \(use.name)"
            guard let enclosing = use.enclosing else { return site + " at top level" }
            guard let via = use.via else { return site + " at load, in \(enclosing)" }
            return site + " in \(enclosing), called at load" + (sameDeclaration(via, enclosing) ? "" : " via \(via)")
        }
        let fromImports = shown.filter(\.isFromImport).map { "\(names.short($0.path)):\($0.line) \($0.name)" }
        if !fromImports.isEmpty { sites.append(fromImports.joined(separator: ", ") + " read by `from … import` at load") }
        let more = cycle.loadTimeUses.count - shown.count
        return "load-time unsafe, an imported binding is used while the modules load: " + sites.joined(separator: ", ") + (more > 0 ? ", +\(more) more" : "")
    }

    /// Whether the cycle survives when type-only imports are erased, and when dynamic imports are left out too.
    static func modesText(_ cycle: ImportCycle, names: Names) -> String {
        let all = [cycle.files]
        if cycle.valueOnly == all && cycle.staticOnly == all { return "same on value-only and static-only edges" }
        func describe(_ components: [[String]], mode: String, reason: String) -> String {
            if components.isEmpty { return "no cycle on \(mode) edges (\(reason))" }
            if components == all { return "same on \(mode) edges" }
            return "on \(mode) edges only " + components.prefix(3).map { component in
                component.count == 2 ? "\(names.short(component[0])) ↔ \(names.short(component[1]))" : "\(component.count) of these files"
            }.joined(separator: ", ")
        }
        var parts = [describe(cycle.valueOnly, mode: "value-only", reason: "type imports close it; they are erased at runtime")]
        if cycle.staticOnly != cycle.valueOnly {
            parts.append(describe(cycle.staticOnly, mode: "static-only", reason: "a dynamic import closes it"))
        } else if cycle.valueOnly != all {
            parts.append("likewise on static-only edges")
        }
        return parts.joined(separator: " · ")
    }

    /// `shop/index.ts re-exports both, not in cycle`.
    static func barrelText(_ cycle: ImportCycle, names: Names) -> String? {
        guard !cycle.barrels.isEmpty else { return nil }
        var groups: [(members: [String], paths: [String])] = []
        for barrel in cycle.barrels {
            if let index = groups.firstIndex(where: { $0.members == barrel.members }) {
                groups[index].paths.append(barrel.path)
            } else {
                groups.append((barrel.members, [barrel.path]))
            }
        }
        return groups.prefix(2).map { group in
            let what = group.members.count == cycle.files.count
                ? (cycle.files.count == 2 ? "both" : "all \(cycle.files.count)")
                : group.members.map(names.short).joined(separator: ", ")
            let paths = group.paths.prefix(3).map(names.barrel).joined(separator: ", ") + (group.paths.count > 3 ? " +\(group.paths.count - 3)" : "")
            return "\(paths) \(group.paths.count == 1 ? "re-exports" : "re-export") \(what), not in cycle"
        }.joined(separator: " · ")
    }

    // MARK: Helpers

    /// Short names inside one cycle: files in the folder of its first file by name, others by full path.
    struct Names {
        let folder: String

        init(_ cycle: ImportCycle) {
            folder = (cycle.files.first.map { ($0 as NSString).deletingLastPathComponent }) ?? ""
        }

        func short(_ path: String) -> String {
            let directory = (path as NSString).deletingLastPathComponent
            return directory == folder ? (path as NSString).lastPathComponent : path
        }

        /// A barrel's own name says little (`index.ts`), so its folder stays.
        func barrel(_ path: String) -> String {
            let directory = (path as NSString).deletingLastPathComponent
            guard directory == folder else { return path }
            let name = (path as NSString).lastPathComponent
            let parent = (directory as NSString).lastPathComponent
            return parent.isEmpty ? name : parent + "/" + name
        }
    }

    /// The deepest folder holding every file, without a trailing slash ("" for the repository root).
    static func commonFolder(_ paths: [String]) -> String {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent }) else { return "" }
        for path in paths.dropFirst() {
            while !common.isEmpty && !path.hasPrefix(common + "/") {
                common = (common as NSString).deletingLastPathComponent
            }
        }
        return common
    }

    static func plural(_ count: Int, _ noun: String, _ plural: String? = nil) -> String {
        "\(count) \(count == 1 ? noun : plural ?? noun + "s")"
    }

    static func quoted(_ text: String) -> String {
        MoreCall.quoted(text)
    }
}
