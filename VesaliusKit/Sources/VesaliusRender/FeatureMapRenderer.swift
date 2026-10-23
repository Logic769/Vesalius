import Foundation
import VesaliusCore

/// Prints a feature map as plain text:
///
///     feature: in-app purchases, premium access · StoreKit (imported by 5 files; no other payments SDK imported) · found: load, buy
///     core  Atlas/Services/PremiumStore.swift  @MainActor final class PremiumStore: ObservableObject :12-410 · static let shared :14
///       ids      16 │ static let annualID = "yearly_atlas"  ·17 monthlyID "monthly_atlas"
///       load     start() :96-130 "Listens for transaction updates: …"
///                  104 │ for await result in Transaction.updates {  ·108 await transaction.finish()
///     env DATA_ENCRYPTION_KEY  set electron/main.ts:31-44 ensureDataKey() ← :190 · read src/lib/crypto.ts:12 readDataKey()
///     call sites: PremiumStore in 4 files (app 3, test 1) · complete: …
///       Atlas/ContentView.swift  64 │ .task { await premium.start() }  ·120,133 premium.showsUpgrade
///     config  Atlas.storekit:18  lifetime_atlas :18, … = PremiumStore.swift:16-18
///     docs  Atlas/Docs/Store.md:8-21 "Purchases" (may be stale)
///     not this feature: Telemetry.tagPremiumUser Atlas/Services/Telemetry.swift (analytics)
///
/// A flow prints its entry, steps (`[sink]` flagged), other writers, readers and format files instead of roles; a
/// folder that is not mostly format files names those that are and counts the others (`+79 more in Atlas/Services/`).
/// Code after `│` is the statement as it reads on disk; nothing carries a score. Over budget, the result is cut
/// in order: doc quotes, compact sites, test files, then call-site files (each cut says what it left out).
public enum FeatureMapRenderer {
    public static func render(_ result: FeatureMapResult, budget: Budget = .featureMap) -> String {
        var level = 0
        var text = lines(result, cut: level).joined(separator: "\n")
        while !budget.isUnlimited, TokenEstimate.of(text) > budget.tokens, level < maxCut {
            level += 1
            text = lines(result, cut: level).joined(separator: "\n")
        }
        return text
    }

    /// The flow view alone (outline of a function, `vesalius outline Type.method`).
    public static func render(flow: FlowView, budget: Budget = Budget(tokens: 2_000)) -> String {
        var level = 0
        var text = flowLines(flow, cut: level).joined(separator: "\n")
        while !budget.isUnlimited, TokenEstimate.of(text) > budget.tokens, level < maxCut {
            level += 1
            text = flowLines(flow, cut: level).joined(separator: "\n")
        }
        return text
    }

    static let maxCut = 6

    // MARK: Whole result

    static func lines(_ result: FeatureMapResult, cut: Int) -> [String] {
        if let flow = result.flow {
            var out = flowLines(flow, cut: cut)
            if let docs = result.docs { out += docsLines(docs, cut: cut) }
            return out
        }
        var out = [headline(result)]
        if let core = result.core {
            var line = "core  \(core.path)"
            if let signature = core.signature { line += "  " + Elide.middle(oneLine(signature), limit: 90) }
            if core.name != nil { line += " :\(core.lines)" }
            if let access = core.access { line += " · \(access)" }
            out.append(line)
        }
        if !result.keyLiterals.isEmpty {
            out.append(evidenceLine(prefix: "  ids  ", result.keyLiterals, cut: cut))
        }
        let labelWidth = min(16, (result.roles.map(\.label.count).max() ?? 0) + 2)
        for role in result.roles {
            for (index, member) in role.members.enumerated() {
                let label = index == 0 ? role.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0) : String(repeating: " ", count: labelWidth)
                out.append("  " + label + memberHeading(member, cut: cut))
                out += evidenceLines(member.evidence, indent: "  " + String(repeating: " ", count: labelWidth + 2), cut: cut)
            }
        }
        for link in result.environment {
            out += environmentLines(link, cut: cut)
        }
        for table in result.tables {
            out.append("table \(table.name)  \(table.path):\(table.lines) \(table.symbol)")
            out += evidenceLines(table.columns, indent: "      ", cut: cut)
            if !table.writers.isEmpty {
                out.append("      written by " + table.writers.map { "\($0.name ?? "(top level)") \($0.path):\($0.line)" }.joined(separator: " · "))
            }
            if !table.readers.isEmpty {
                out.append("      read by " + table.readers.map { "\($0.name ?? "(top level)") \($0.path):\($0.line)" }.joined(separator: " · "))
            }
        }
        if let sites = result.callSites {
            out += callSiteLines(sites, cut: cut)
        }
        for config in result.config {
            out.append("config  \(config.path)\(config.line.map { ":\($0)" } ?? "")  \(config.summary)")
        }
        if let docs = result.docs { out += docsLines(docs, cut: cut) }
        if !result.notThisFeature.isEmpty {
            out.append("not this feature: " + result.notThisFeature.map { "\($0.name) \($0.path) (\($0.reason))" }.joined(separator: " · "))
        }
        return out
    }

    static func headline(_ result: FeatureMapResult) -> String {
        var line = "feature: \(result.headline.feature)"
        if !result.headline.frameworks.isEmpty {
            let frameworks = result.headline.frameworks.map { "\($0.name) (imported by \($0.importers) \($0.importers == 1 ? "file" : "files"))" }.joined(separator: ", ")
            line += " · " + frameworks
            if let note = result.headline.note { line += "; \(note)" }
        }
        if !result.coverage.found.isEmpty { line += " · found: " + result.coverage.found.joined(separator: ", ") }
        if !result.coverage.missing.isEmpty { line += " · missing: " + result.coverage.missing.joined(separator: ", ") }
        return line
    }

    static func memberHeading(_ member: FeatureMember, cut: Int) -> String {
        var line = "\(member.name) :\(member.lines)"
        if let delegate = member.delegate { line += " → \(delegate.name) :\(delegate.lines)" }
        if !member.calledBy.isEmpty {
            line += " ← " + member.calledBy.prefix(2).map { ":\($0.line)" }.joined(separator: " ")
        }
        if let doc = member.doc, cut < 3 { line += "  \"\(doc)\"" }
        return line
    }

    /// Evidence under a heading: each primary as its own `NNN │ code` line, the compact ones after the first.
    static func evidenceLines(_ evidence: [FeatureEvidence], indent: String, cut: Int) -> [String] {
        guard !evidence.isEmpty else { return [] }
        let primaries = evidence.filter(\.primary)
        let compact = evidence.filter { !$0.primary }
        var out: [String] = []
        for (index, item) in primaries.enumerated() {
            var line = "\(indent)\(item.line) │ \(item.code)"
            if let note = item.note { line += "  \(note)" }
            if index == 0 && !compact.isEmpty && cut < 4 {
                line += "  " + compact.map { compactText($0, cut: cut) }.joined(separator: " ")
            }
            out.append(line)
        }
        if primaries.isEmpty && cut < 4 {
            out.append(indent + compact.map { compactText($0, cut: cut) }.joined(separator: " "))
        }
        return out
    }

    /// One line: a primary statement then compact items (`ids  16 │ … ·17 monthlyID "monthly_atlas"`).
    static func evidenceLine(prefix: String, _ evidence: [FeatureEvidence], cut: Int) -> String {
        var parts: [String] = []
        for item in evidence {
            if item.primary {
                parts.append("\(item.line) │ \(item.code)" + (item.note.map { "  \($0)" } ?? ""))
            } else {
                parts.append(compactText(item, cut: cut))
            }
        }
        return prefix + parts.joined(separator: "  ")
    }

    static func compactText(_ item: FeatureEvidence, cut: Int) -> String {
        let lines = ([item.line] + item.moreLines).filter { $0 > 0 }
        guard !lines.isEmpty else { return item.code }
        let numbers = LineList.format(lines).replacingOccurrences(of: " ", with: ",")
        var text = "·\(numbers)"
        if !item.code.isEmpty { text += " " + (cut >= 2 ? Elide.middle(item.code, limit: 40) : item.code) }
        if let note = item.note, cut < 2 { text += " \(note)" }
        return text
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    // MARK: Environment

    static func environmentLines(_ link: FeatureEnvLink, cut: Int) -> [String] {
        var line = "env \(link.name)"
        let writers = link.writers.filter { !$0.isTest }
        let readers = link.readers.filter { !$0.isTest }
        if let producer = link.producer {
            line += "  set \(producer.path):\(producer.lines) \(producer.name)"
            if !producer.calledBy.isEmpty { line += " ← " + producer.calledBy.prefix(2).map { ":\($0.line)" }.joined(separator: " ") }
        } else if let writer = writers.first {
            line += "  set \(writer.path):\(LineList.format(writers.filter { $0.path == writer.path }.map(\.line)))\(writer.function.map { " \($0)" } ?? "")"
        }
        if let reader = readers.first {
            line += " · read \(reader.path):\(LineList.format(readers.filter { $0.path == reader.path }.map(\.line)))\(reader.function.map { " \($0)" } ?? "")"
            let others = Set(readers.map(\.path)).subtracting([reader.path])
            if !others.isEmpty { line += " +\(others.count) \(others.count == 1 ? "file" : "files")" }
        }
        let tests = Set((link.writers + link.readers).filter(\.isTest).map(\.path))
        if !tests.isEmpty { line += " · tests \(tests.count)" }
        var out = [line]
        if let producer = link.producer {
            out += evidenceLines(producer.evidence, indent: "      ", cut: cut)
        }
        return out
    }

    // MARK: Call sites

    static func callSiteLines(_ sites: FeatureCallSites, cut: Int) -> [String] {
        let app = sites.files.filter { !$0.isTest }
        let tests = sites.files.filter(\.isTest)
        var head = "call sites: \(sites.subject) in \(sites.files.count) \(sites.files.count == 1 ? "file" : "files") (app \(app.count), test \(tests.count))"
        if let completeness = sites.completeness { head += " · " + completeness }
        var out = [head]
        let fileLimit = cut >= 6 ? 4 : cut >= 5 ? 6 : Int.max
        for file in app.prefix(fileLimit) {
            out += callSiteFileLines(file, cut: cut)
        }
        if app.count > fileLimit {
            out.append("  +\(app.count - fileLimit) more files: " + app.dropFirst(fileLimit).map(\.path).joined(separator: ", "))
        }
        if !tests.isEmpty {
            if cut >= 3 || tests.count > 3 {
                out.append("  tests: " + tests.map(\.path).joined(separator: ", "))
            } else {
                for file in tests {
                    let lines = file.groups.flatMap(\.sites).flatMap { [$0.line] + $0.moreLines }.filter { $0 > 0 }
                    out.append("  \(file.path)\(file.header ?? "")  [test]" + (lines.isEmpty ? "" : "  " + LineList.collapsed(lines)))
                }
            }
        }
        if !sites.mockOnly.isEmpty {
            out.append("mock only (vi.mock): " + sites.mockOnly.joined(separator: ", "))
        }
        return out
    }

    static func callSiteFileLines(_ file: FeatureCallSiteFile, cut: Int) -> [String] {
        var out: [String] = []
        let labels = file.labels.isEmpty ? "" : "  " + file.labels.joined(separator: " ")
        let single = file.groups.count == 1
        var first = "  \(file.path)\(file.header ?? "")\(labels)"
        for (groupIndex, group) in file.groups.enumerated() {
            var heading = ""
            if let caller = group.caller { heading = caller + (group.callerLines.map { " :\($0)" } ?? "") }
            if !group.calledBy.isEmpty {
                heading += " ← " + group.calledBy.map { caller in
                    (caller.name.map { "\($0) " } ?? "") + ":\(caller.line)" + (caller.note.map { " \($0)" } ?? "")
                }.joined(separator: " · ")
            }
            let maxCompact = cut >= 4 ? 1 : cut >= 2 ? 3 : 6
            let primaries = group.sites.filter(\.primary)
            let compact = group.sites.filter { !$0.primary }.prefix(maxCompact)
            let hidden = group.sites.filter { !$0.primary }.count - compact.count
            var siteLines: [String] = []
            for (index, site) in primaries.enumerated() {
                var line = "\(site.line) │ \(site.code)"
                if let note = site.note { line += "  \(note)" }
                if !site.moreLines.isEmpty { line += "  ·" + LineList.format(site.moreLines).replacingOccurrences(of: " ", with: ",") }
                if index == 0 && !compact.isEmpty {
                    line += "  " + compact.map { compactText($0, cut: cut) }.joined(separator: " ")
                    if hidden > 0 { line += " +\(hidden) more" }
                }
                siteLines.append(line)
            }
            if primaries.isEmpty && !compact.isEmpty {
                siteLines.append(compact.map { compactText($0, cut: cut) }.joined(separator: " ") + (hidden > 0 ? " +\(hidden) more" : ""))
            }
            if single && groupIndex == 0 {
                if !heading.isEmpty { first += "  " + heading }
                if let firstSite = siteLines.first {
                    out.append(first + "  " + firstSite)
                    out += siteLines.dropFirst().map { "     " + $0 }
                } else {
                    out.append(first)
                }
            } else {
                if groupIndex == 0 { out.append(first) }
                out.append("    " + (heading.isEmpty ? "(top level)" : heading))
                out += siteLines.map { "      " + $0 }
            }
        }
        if file.groups.isEmpty { out.append(first) }
        return out
    }

    // MARK: Docs

    static func docsLines(_ docs: FeatureDocSection, cut: Int) -> [String] {
        var out = ["docs  \(docs.path):\(docs.lines) \"\(docs.heading)\" (may be stale)"]
        let quoted = cut >= 1 ? docs.quote.prefix(cut >= 2 ? 0 : 2) : docs.quote.prefix(5)
        out += quoted.map { "    \($0.line) │ \($0.code)" }
        return out
    }

    // MARK: Flow

    static func flowLines(_ flow: FlowView, cut: Int) -> [String] {
        var head = "flow \(flow.entry.name)"
        if flow.body != flow.entry { head += " → \(shortName(flow.body.name))" }
        head += "  \(flow.body.path):\(flow.body.lines)"
        if !flow.sinks.isEmpty { head += " · sinks: " + flow.sinks.joined(separator: ", ") }
        var out = [head]
        if !flow.calledBy.isEmpty {
            out.append("called by: " + flow.calledBy.map { "\($0.name ?? "(top level)") \($0.path):\($0.line)" }.joined(separator: " · ")
                + (flow.moreCallers > 0 ? " · +\(flow.moreCallers) more" : ""))
        }
        for step in flow.steps {
            var line = "  \(step.line) │ \(step.code)"
            if step.isSink {
                line += "  [sink]"
            } else if let target = step.target {
                line += "  → \(target)" + (step.targetLines.map { " :\($0)" } ?? "")
            }
            out.append(line)
        }
        if !flow.otherWriters.isEmpty {
            for (index, writer) in flow.otherWriters.enumerated() where cut < 5 || index < 2 {
                let label = index == 0 ? "also writes  " : "             "
                var line = label + "\(writer.name) :\(writer.lines)"
                if cut < 4 {
                    line += "  " + writer.evidence.map { item in
                        "·\(item.line) \(cut >= 2 ? Elide.middle(item.code, limit: 40) : item.code)" + (item.kind == .sink ? " [sink]" : "")
                    }.joined(separator: " ")
                }
                out.append(line)
            }
        }
        for (index, reader) in flow.readers.enumerated() {
            let label = index == 0 ? "readers  " : "         "
            var line = label + "\(reader.name) :\(reader.lines)"
            let primary = reader.evidence.first { $0.primary }
            let compact = reader.evidence.filter { !$0.primary }
            if let primary { line += "  \(primary.line) │ \(primary.code)" }
            if !compact.isEmpty, cut < 4 { line += "  " + compact.map { compactText($0, cut: cut) }.joined(separator: " ") }
            out.append(line)
        }
        for (index, group) in flow.format.enumerated() {
            let label = index == 0 ? "format  " : "        "
            if group.folder.isEmpty {
                out.append(label + group.files.map { file in file.path + (file.types.isEmpty || cut >= 2 ? "" : " (\(file.types.prefix(2).joined(separator: ", ")))") }.joined(separator: " · "))
            } else {
                var names = group.files.map { file -> String in
                    let name = (file.path as NSString).lastPathComponent
                    let stem = (name as NSString).deletingPathExtension
                    let types = file.types.filter { $0 != stem }.prefix(2)
                    return name + (types.isEmpty || cut >= 2 ? "" : " (\(types.joined(separator: ", ")))")
                }
                if group.more > 0 { names.append("+\(group.more) more in \(group.folder)/") }
                out.append(label + "\(group.folder)/  " + names.joined(separator: " · "))
            }
        }
        return out
    }

    /// `Wax.commitLocked()` → `commitLocked()`.
    static func shortName(_ name: String) -> String {
        guard let paren = name.firstIndex(of: "(") else { return name.split(separator: ".").last.map(String.init) ?? name }
        let base = name[..<paren]
        let last = base.split(separator: ".").last.map(String.init) ?? String(base)
        return last + name[paren...]
    }
}
