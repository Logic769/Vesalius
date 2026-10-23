import Foundation
import VesaliusCore

/// The `usages` text:
///
///     <signature incl. attributes>  <path>:<start>-<end> · <kind> · target <T> [· #if <cond>]
///     <N> <callers|uses> in <F> files (<app/test or per-target split>) · complete: … | INCOMPLETE: …
///     <path>  [labels]
///       <enclosing> :<start>-<end> [#if …]  "doc first sentence"
///         <line> │ <statement>
///         ·<line> <short call>
///         called by: <caller> :<line> · …
///     rejected lookalikes: … · transitive only (not listed): … · mock only (vi.mock): …
///
/// Detail is lowered step by step until the result fits its budget: test files shrink to one line, then file and
/// type views drop evidence statements their member lines already locate, then member lines tighten, then docs and
/// enclosing names go. What still does not fit is paged by the `Budgeter`, which never cuts the head, the
/// completeness line, the unresolved sites or the tail.
public enum UsagesRenderer {
    /// Unresolved sites listed under line 2 before the rest are counted.
    static let unresolvedShown = 10
    /// Characters per member line in type and file views before it wraps.
    static let memberLineLimit = 120
    /// Tokens kept free for the Budgeter's page footer.
    static let footerReserve = 40

    enum Detail: Int, CaseIterable, Comparable {
        case full
        /// Test files on one line: the members they use, then their lines.
        case testsOneLine
        /// File and type views keep statements only where they explain a label (type-inferred files); their
        /// member lines say what is used and where.
        case compact
        /// Member lines name members without their labels, long line lists collapse to `first-last ×N`, the
        /// enclosing declarations are listed once per owner line, footers keep 3 items.
        case tight
        /// No docs, no enclosing declarations in member lines.
        case lean

        static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
    }

    /// UI test files with literal links listed before the rest are counted.
    static let uiLinksShown = 6

    public static func render(_ result: UsagesResult, budget: Budget) -> String {
        if result.view == .choices { return choices(result) }
        if budget.isUnlimited { return Budgeter.render(document(result, detail: .full), budget: budget) }
        // The Budgeter reserves room for a `showing X of Y` line; a result that fits leaves that room unused.
        let room = max(1, budget.tokens - footerReserve)
        var chosen = document(result, detail: .lean)
        for detail in Detail.allCases {
            let candidate = document(result, detail: detail)
            if TokenEstimate.of(Budgeter.render(candidate, budget: .unlimited)) <= room {
                chosen = candidate
                break
            }
        }
        return Budgeter.render(chosen, budget: budget)
    }

    static func document(_ result: UsagesResult, detail: Detail) -> RenderDocument {
        var head = [headerLine(result), totalsLine(result)]
        head += result.notes
        var tail: [String] = []
        if let declaring = result.declaringFile { tail.append(declaringLine(declaring)) }
        tail += result.footers.map { footerLine($0, limit: detail >= .tight ? 3 : 5) }
        if let sections = result.sections { tail += sectionLines(sections, result: result) }
        var call = [MoreCall.Argument("target", .string(result.target))]
        if let change = result.change { call.append(MoreCall.Argument("change", .string(change.rawValue))) }
        return RenderDocument(
            head: head,
            completeness: result.completeness?.summary,
            unresolved: unresolvedLines(result.completeness),
            blocks: result.files.map { block($0, view: result.view, detail: detail) },
            tail: tail,
            more: MoreCall(tool: "usages", arguments: call))
    }

    // MARK: Head

    static func headerLine(_ result: UsagesResult) -> String {
        let header = result.header
        var line = ""
        if let change = result.change { line += change.rawValue.uppercased() + " " }
        switch result.view {
        case .file, .folder, .module:
            line += header.title
            if result.view != .file { line += " (\(header.kind))" }
            if !header.declares.isEmpty {
                line += " declares " + header.declares.map { "\($0.name) :\($0.lines)" }.joined(separator: " · ")
                if header.declaresMore > 0 { line += " +\(header.declaresMore)" }
            }
            line += targetsText(header).map { " · " + $0 } ?? ""
        case .framework, .environment:
            line += "\(header.title) (\(header.kind))"
        default:
            line += header.title
            if let path = header.path {
                line += "  \(path)" + (header.lines.map { ":\($0)" } ?? "")
            }
            line += " · " + header.kind
            if let targets = targetsText(header) { line += " · " + targets }
            if let conditions = header.conditions, !conditions.isEmpty { line += " · #if " + conditions }
        }
        return line
    }

    /// `target Atlas`, `targets Atlas + AtlasWatch Watch App (membership exception, …pbxproj:135)`.
    static func targetsText(_ header: UsageHeader) -> String? {
        guard !header.buildTargets.isEmpty else { return nil }
        var text = (header.buildTargets.count == 1 ? "target " : "targets ") + header.buildTargets.joined(separator: " + ")
        if let membership = header.membership { text += " (\(membership))" }
        return text
    }

    static func totalsLine(_ result: UsagesResult) -> String {
        let totals = result.totals
        var line: String
        switch totals.noun {
        case "importer":
            line = "imported by \(plural(totals.count, "file"))"
        case "file":
            line = "\(plural(totals.count, "file")) \(totals.count == 1 ? "uses" : "use") \(result.view == .file ? "it" : "them")"
        default:
            line = "\(plural(totals.count, totals.noun)) in \(plural(totals.files, "file"))"
        }
        let split = splitText(totals)
        if !split.isEmpty { line += " (\(split))" }
        if !totals.extra.isEmpty { line += "; " + totals.extra.joined(separator: "; ") }
        return line
    }

    /// `app 3, test 0` or `Atlas 2 · AtlasWatch Watch App 10`; for files `7 source, 4 test`.
    static func splitText(_ totals: UsageTotals) -> String {
        guard !totals.split.isEmpty else { return "" }
        if totals.splitByTarget { return totals.split.map { "\($0.label) \($0.count)" }.joined(separator: " · ") }
        if totals.noun == "file" || totals.noun == "importer" {
            let app = totals.split.first { $0.label == "app" }?.count ?? 0, test = totals.split.first { $0.label == "test" }?.count ?? 0
            return "\(app) \(totals.noun == "importer" ? "source" : "app"), \(test) test"
        }
        return totals.split.map { "\($0.label) \($0.count)" }.joined(separator: ", ")
    }

    static func unresolvedLines(_ completeness: UsageCompleteness?) -> [String] {
        guard let completeness, !completeness.unresolved.isEmpty else { return [] }
        var lines = completeness.unresolved.prefix(unresolvedShown).map { occurrence in
            "unresolved: \(occurrence.path):\(occurrence.line)" + (occurrence.code.map { "  " + $0 } ?? "") + (occurrence.detail.map { "  (\($0))" } ?? "")
        }
        if completeness.unresolved.count > unresolvedShown { lines.append("unresolved: +\(completeness.unresolved.count - unresolvedShown) more (listed in the completeness line)") }
        return lines
    }

    // MARK: Files

    static func block(_ file: UsageFile, view: UsagesResult.View, detail: Detail) -> FileBlock {
        var header = ""
        if let line = file.importLine { header += ":\(line)" + (file.importedNames.isEmpty ? "" : " imports {\(file.importedNames.joined(separator: ", "))}") }
        if let via = file.via { header += "  via \(via.line) │ \(via.text)" }
        var labels = file.labels.filter { !$0.isEmpty }.map { "[\($0)]" }
        if let note = file.note { labels.append(note) }
        var members: [MemberBlock] = []
        if !file.owners.isEmpty {
            for owner in file.owners {
                members += ownerLines(owner, showOwner: view != .type, detail: detail).map { MemberBlock(heading: $0) }
            }
            // Evidence statements in file and type views: kept while they fit, and always for type-inferred files.
            let inferred = file.labels.contains { $0.hasPrefix("type-inferred") }
            if detail < .compact || inferred {
                for group in file.groups { members.append(MemberBlock(sites: sites(group.sites, note: nil))) }
            }
        } else {
            for group in file.groups {
                members.append(member(group, file: file, view: view, detail: detail))
            }
        }
        let inferredFile = file.labels.contains { $0.hasPrefix("type-inferred") }
        if detail >= .testsOneLine && file.isTest && (!inferredFile || detail >= .tight) {
            return FileBlock(path: file.path, header: header.isEmpty ? nil : header, labels: labels + [oneLine(file)])
        }
        return FileBlock(path: file.path, header: header.isEmpty ? nil : header, labels: labels, isTest: file.isTest, members: members)
    }

    /// A test file on one line: the members it uses (type and file views), then its lines.
    static func oneLine(_ file: UsageFile) -> String {
        var parts: [String] = []
        if !file.owners.isEmpty {
            var budget = 170
            var owners: [String] = []
            for owner in file.owners {
                var names: [String] = []
                for member in owner.members {
                    let name = member.name == "type" ? "type" : baseName(member.name)
                    guard !names.contains(name) else { continue }
                    if budget - name.count - 2 < 0 { break }
                    budget -= name.count + 2
                    names.append(name)
                }
                let hidden = owner.members.count - names.count
                guard !names.isEmpty else { continue }
                owners.append(owner.owner + ": " + names.joined(separator: ", ") + (hidden > 0 ? " +\(hidden)" : ""))
                budget -= owner.owner.count + 4
            }
            if !owners.isEmpty { parts.append(owners.joined(separator: " · ")) }
        }
        let lines = file.groups.flatMap { $0.sites.map(\.line) } + file.owners.flatMap { $0.members.flatMap(\.lines) }
        if !lines.isEmpty { parts.append(LineList.collapsed(lines)) }
        return parts.joined(separator: "  ")
    }

    /// `weekNumber` for `weekNumber(for:startedAt:calendar:)`, `.date` for `.date(of:)`.
    static func baseName(_ name: String) -> String {
        name.split(separator: "(", maxSplits: 1).first.map(String.init) ?? name
    }

    /// One enclosing declaration: its heading, its sites and the one-hop callers.
    static func member(_ group: UsageGroup, file: UsageFile, view: UsagesResult.View, detail: Detail) -> MemberBlock {
        let compactNotes = view == .property || view == .environment
        var heading: String?
        if !compactNotes {
            var text = group.route ?? group.declaration ?? "(top level)"
            if let lines = group.lines, group.declaration != nil { text += " :\(lines)" }
            if let conditions = group.conditions { text += " [#if \(conditions)]" }
            if group.isReferenceOnly { text += "  (not a call: referenced as a value)" }
            if !group.inFileCallers.isEmpty {
                text += "  " + group.inFileCallers.map { "← \($0.name) :\($0.line)" }.joined(separator: " ")
            }
            if detail < .lean, let doc = group.doc { text += "  " + (group.isTypeDoc ? "type doc: " : "") + "\"\(doc)\"" }
            heading = text
        }
        let note = compactNotes ? group.declaration.map { "(" + shortName($0) + (group.conditions.map { " #if " + $0 } ?? "") + ")" } : nil
        var trailer: [String] = []
        if !group.calledBy.isEmpty {
            trailer.append("called by: " + group.calledBy.map(callerText).joined(separator: " · ") + (group.calledByMore > 0 ? " · +\(group.calledByMore)" : ""))
        }
        return MemberBlock(heading: heading, sites: sites(group.sites, note: note), trailer: trailer)
    }

    /// Sites as the Budgeter prints them: the governing condition, then the primary statements (with their
    /// consumer), then the secondary sites on one line.
    static func sites(_ list: [UsageSite], note: String?) -> [Site] {
        var result: [Site] = []
        var noted = false
        for site in list {
            if site.isPrimary, let condition = site.condition {
                result.append(Site(line: condition.line, code: condition.text, primary: true))
            }
            if site.isPrimary, let first = site.code.first {
                var notes: [String] = []
                if let consumer = site.consumer { notes.append("→ :\(consumer.line) \(consumer.text)") }
                if let form = formNote(site) { notes.append(form) }
                if !noted, let note {
                    notes.append(note)
                    noted = true
                }
                // Consecutive lines print as one site; a gap would renumber them, so it gets its own.
                var start = first.line
                var rows = [first.text]
                for line in site.code.dropFirst() {
                    if line.line == start + rows.count {
                        rows.append(line.text)
                    } else {
                        result.append(Site(line: start, code: rows.joined(separator: "\n"), primary: true))
                        start = line.line
                        rows = [line.text]
                    }
                }
                result.append(Site(line: start, code: rows.joined(separator: "\n"), primary: true, note: notes.isEmpty ? nil : notes.joined(separator: "  ")))
            } else {
                result.append(Site(line: site.line, code: site.code.first?.text ?? "", primary: false))
            }
        }
        return result
    }

    /// `($isSubscribed)`-style marks for dynamic and implicit forms, and a write.
    static func formNote(_ site: UsageSite) -> String? {
        switch site.form {
        case "projected": "[projected $]"
        case "keypath": "[keypath]"
        case "implicit": "[implicit member]"
        default: site.kind == "write" ? "[writes]" : nil
        }
    }

    /// Type and file views: `Owner  member 12,40 (enclosing) · member 7`, wrapped under the first member when
    /// long. Tighter levels drop the selectors' labels, collapse long line lists and name the enclosing
    /// declarations once per owner (`  in ReadingPlan.schedule, ReadingList.items`).
    static func ownerLines(_ owner: UsageOwnerUses, showOwner: Bool, detail: Detail) -> [String] {
        let tight = detail >= .tight
        var enclosing: [String] = []
        let items = (tight ? mergedByBaseName(owner.members) : owner.members).map { member -> String in
            var name = member.name == "type" && !showOwner ? owner.owner : member.name
            if tight { name = baseName(name) }
            var text = name + " " + (tight ? LineList.collapsed(member.lines) : LineList.format(member.lines))
            var notes: [String] = member.kinds == ["write"] ? ["write"] : []
            if detail < .tight {
                notes += member.enclosing.prefix(2)
                if member.enclosing.count > 2 { notes.append("+\(member.enclosing.count - 2)") }
            }
            for name in member.enclosing where !enclosing.contains(name) { enclosing.append(name) }
            if !notes.isEmpty { text += " (" + notes.joined(separator: ", ") + ")" }
            return text
        }
        let prefix = showOwner ? owner.owner + "  " : ""
        let indent = String(repeating: " ", count: prefix.count)
        var lines: [String] = []
        var current = ""
        for item in items {
            if current.isEmpty {
                current = (lines.isEmpty ? prefix : indent) + item
            } else if current.count + 3 + item.count > memberLineLimit {
                lines.append(current)
                current = indent + item
            } else {
                current += " · " + item
            }
        }
        if !current.isEmpty { lines.append(current) }
        if detail == .tight, !enclosing.isEmpty, let last = lines.indices.last {
            lines[last] += "  in " + enclosing.prefix(3).joined(separator: ", ") + (enclosing.count > 3 ? " +\(enclosing.count - 3)" : "")
        }
        return lines
    }

    /// Members that print under one base name (`suggestedReadingDays(for:firstWeekday:)` and
    /// `suggestedReadingDays(count:)` once their labels are dropped) as one, in first-use order.
    static func mergedByBaseName(_ members: [UsageMemberUse]) -> [UsageMemberUse] {
        var order: [String] = []
        var merged: [String: UsageMemberUse] = [:]
        for member in members {
            let name = baseName(member.name)
            guard var entry = merged[name] else {
                order.append(name)
                merged[name] = member
                continue
            }
            entry.lines = Array(Set(entry.lines + member.lines)).sorted()
            entry.kinds = Array(Set(entry.kinds + member.kinds)).sorted()
            entry.enclosing += member.enclosing.filter { !entry.enclosing.contains($0) }
            merged[name] = entry
        }
        return order.compactMap { merged[$0] }
    }

    /// The last component of a declaration heading: `beginImport(urls:)` for `private func ImportSheet.beginImport(urls:)`.
    static func shortName(_ heading: String) -> String {
        let name = heading.split(separator: " ").last.map(String.init) ?? heading
        guard let paren = name.firstIndex(of: "(") else { return name.split(separator: ".").last.map(String.init) ?? name }
        let base = name[..<paren]
        return (base.split(separator: ".").last.map(String.init) ?? String(base)) + name[paren...]
    }

    static func callerText(_ caller: UsageCaller) -> String {
        var text = caller.name + " " + (caller.path.map { ($0 as NSString).lastPathComponent } ?? "") + ":\(caller.line)"
        if let conditions = caller.conditions, !conditions.isEmpty { text += " [#if \(conditions)]" }
        return text
    }

    // MARK: Tail

    static func declaringLine(_ declaring: UsageDeclaringFile) -> String {
        func list(_ entries: [UsageCaller]) -> String {
            var order: [String] = []
            var lines: [String: [Int]] = [:]
            var conditions: [String: String] = [:]
            for entry in entries {
                if lines[entry.name] == nil { order.append(entry.name) }
                lines[entry.name, default: []].append(entry.line)
                if let condition = entry.conditions, !condition.isEmpty { conditions[entry.name] = condition }
            }
            return order.map { name in
                "·" + LineList.format(lines[name] ?? []) + " " + shortName(name) + (conditions[name].map { " [#if \($0)]" } ?? "")
            }.joined(separator: " ")
        }
        var parts: [String] = []
        if !declaring.reads.isEmpty { parts.append("reads " + list(declaring.reads)) }
        if !declaring.writes.isEmpty { parts.append("writes " + list(declaring.writes)) }
        return "declaring file  " + parts.joined(separator: " | ")
    }

    static func footerLine(_ footer: UsageFooter, limit: Int) -> String {
        let shown = footer.items.prefix(limit)
        var line = footer.kind.rawValue + (footer.qualifier.map { " " + $0 } ?? "") + ": " + shown.joined(separator: " · ")
        let more = footer.more + footer.items.count - shown.count
        if more > 0 { line += " · +\(more)" }
        return line
    }

    static func sectionLines(_ sections: UsageChangeSections, result: UsagesResult) -> [String] {
        var lines: [String] = []
        if !sections.textOnly.isEmpty {
            lines.append("TEXT ONLY  " + sections.textOnly.joined(separator: " · ") + (sections.textOnlyMore > 0 ? " · +\(sections.textOnlyMore) files" : ""))
        } else {
            lines.append("TEXT ONLY  none")
        }
        if !sections.dynamicChecked.isEmpty {
            lines.append("DYNAMIC  checked " + sections.dynamicChecked.joined(separator: ", ") + ": " + (sections.dynamicHits.isEmpty ? "none found" : sections.dynamicHits.joined(separator: " · ")))
        }
        lines += testLines(sections.tests, targetName: result.header.title)
        if !sections.entryPoints.isEmpty {
            lines.append("ENTRY POINTS  " + sections.entryPoints.map { point in
                "\(point.root) \(point.path):\(point.line)" + (point.via.isEmpty ? "" : " → " + point.via.prefix(2).joined(separator: " → "))
            }.joined(separator: " · ") + (sections.entryPointsMore > 0 ? " · +\(sections.entryPointsMore)" : ""))
        }
        if !sections.notAffected.isEmpty { lines.append("NOT AFFECTED  " + sections.notAffected.joined(separator: " · ")) }
        if let coverage = sections.coverage { lines.append("COVERAGE  " + coverage) }
        return lines
    }

    static func testLines(_ tests: UsageTests, targetName: String) -> [String] {
        guard !tests.isEmpty else { return ["TESTS  none reference it, use its type, or share a literal with it"] }
        var lines = ["TESTS"]
        func suites(_ test: UsageTestFile) -> String {
            guard !test.suites.isEmpty else { return " " }
            return ": " + test.suites.prefix(4).joined(separator: ", ") + (test.suites.count > 4 ? " +\(test.suites.count - 4)" : "") + " "
        }
        for test in tests.direct {
            lines.append("  \(test.kind == "ui" ? "UI  " : "unit")  \(test.path)" + suites(test) + "(uses it: " + LineList.collapsed(test.lines) + ")")
        }
        for test in tests.compileCoupled {
            lines.append("  \(test.kind == "ui" ? "UI  " : "unit")  \(test.path)" + suites(test)
                + "(compile-coupled: uses " + test.uses.prefix(5).joined(separator: ", ") + (test.uses.count > 5 ? ", +\(test.uses.count - 5)" : "") + "; none use the target)")
        }
        // One line per UI test file: its strongest link, the other tests it links through, the other literals.
        var files: [String] = []
        var byFile: [String: [UsageUILink]] = [:]
        for link in tests.ui {
            if byFile[link.testPath] == nil { files.append(link.testPath) }
            byFile[link.testPath, default: []].append(link)
        }
        for path in files.prefix(uiLinksShown) {
            guard let links = byFile[path], let best = links.first else { continue }
            let relation = best.match == "contains" ? "⊂" : "="
            var line = "  UI    \(best.testPath):\(best.testLine) \(shortName(best.test)) ← \"\(best.literal)\" :\(best.literalLine) \(relation) \(best.appPath):\(best.appLine)"
            let otherTests = Set(links.map(\.test)).subtracting([best.test])
            if !otherTests.isEmpty { line += " (+\(otherTests.count) more \(otherTests.count == 1 ? "test" : "tests"))" }
            lines.append(line)
        }
        if files.count > uiLinksShown { lines.append("  UI    +\(files.count - uiLinksShown) more UI test files share literals with it") }
        for hook in tests.hooks {
            let setters = hook.setters.map { "\($0.path):\($0.lines.map(String.init).joined(separator: ","))" + ($0.note.map { " (\($0))" } ?? "") }.joined(separator: ", ")
            var line = "  hook  \(hook.variable) set in \(setters)" + (hook.settersMore > 0 ? " (+\(hook.settersMore) files)" : "")
            line += " → read in \(hook.readerPath):\(hook.readLine) \(shortName(hook.reader))"
            if let write = hook.write { line += ", which sets \(write.text) :\(write.line)" }
            lines.append(line)
        }
        if !tests.run.isEmpty {
            lines.append("  run   " + tests.run.map { command in
                guard let path = command.path, let line = command.line, command.command.hasPrefix(path) else { return command.command }
                return path + ":\(line)" + command.command.dropFirst(path.count)
            }.joined(separator: " · "))
            // Classes the default test plan skips, on their own line so no other class reads as skipped.
            for note in tests.run.compactMap(\.description) where note.contains(" skipped by ") {
                lines.append("  note  " + note)
            }
        }
        return lines
    }

    // MARK: Choices

    static func choices(_ result: UsagesResult) -> String {
        var lines = ["“\(result.header.title)” names \(result.choices.count) targets; nothing merged. Ask for one by its exact target:"]
        for choice in result.choices {
            let counted = switch choice.kind {
            case "module", "framework": "imported by \(plural(choice.files, "file"))"
            case "file": plural(choice.files, "dependent file")
            case "folder": plural(choice.files, "file")
            default: "\(plural(choice.uses, "use")) in \(plural(choice.files, "file"))"
            }
            lines.append("  usages(target:\(MoreCall.quoted(choice.target)))  \(choice.kind)" + (choice.location.map { " · \($0)" } ?? "") + " · \(counted)")
        }
        return lines.joined(separator: "\n")
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : (noun.hasSuffix("s") ? "es" : "s"))"
    }
}
