import Foundation
import VesaliusCore

/// Prints an outline as plain text:
///
///     VesaliusKit/Sources/RepositoryIndex/IndexLocation.swift  152 lines · target RepositoryIndex · used by 9 files (7 app, 2 test)
///     5-25    public struct IndexedRepositoryRecord  "Metadata stored next to each index so the registry can list…"
///               path :6 · name :7 · identity :9 · createdAt :10 · lastIndexedAt :11 · indexDirectory :12 · id :14 · exists :15
///     29-152  public struct IndexLocation  "Where a repository's index lives: `~/Library/Application Su…"
///               repositoryRoot :30 · directory :31 · databaseURL :35 · manifestURL :36 · lockURL :38
///               static baseDirectory :40 · static indexesDirectory :49 · static canonicalRoot(_:) -> URL :52
///     calls out: IndexSchema.version :35
///
/// A type lists one member per line, a function prints its flow, a folder its files with their main
/// declarations, an ambiguous name the exact target of each declaration. Over budget, the result is cut in
/// order: doc sentences, framework call details, types and long values, private declarations, members by name
/// only, then declarations by kind and name; a function gives up its header's details and the flow's context
/// (format files, other writers, readers) before its steps. What still does not fit is cut from the end with a
/// line saying how much and from where. Nothing carries a score.
public enum OutlineRenderer {
    public static func render(_ result: OutlineResult, budget: Budget) -> String {
        if budget.isUnlimited { return compose(sections(result, level: 0, budget: budget)) }
        var last = sections(result, level: 0, budget: budget)
        for level in 0...maxLevel {
            if level > 0 { last = sections(result, level: level, budget: budget) }
            if fits(last, budget) { return compose(last) }
        }
        return compose(truncated(last, budget: budget))
    }

    /// The deepest cut; past it, body entries are cut from the end.
    static let maxLevel = 8
    /// Lines wrap at this width, continuation lines indented under their declaration.
    static let width = 120

    /// Body lines that are kept or cut together.
    struct Entry {
        var lines: [String]
        /// The declarations, members, files or lines it shows, as the line replacing it counts them.
        var count = 1
        /// The first source line it shows.
        var line: Int?
        /// A collapsed subfolder of a folder outline.
        var isFolder = false
    }

    /// A rendered result in three parts. Only body entries are cut; head and tail lines always appear.
    struct Sections {
        var head: [String]
        var body: [Entry]
        var tail: [String]
        /// The line that replaces the entries cut from the end of the body: how many, and from where.
        var more: (ArraySlice<Entry>) -> String
    }

    static func compose(_ sections: Sections) -> String {
        (sections.head + sections.body.flatMap(\.lines) + sections.tail).joined(separator: "\n")
    }

    static func fits(_ sections: Sections, _ budget: Budget) -> Bool {
        TokenEstimate.of(compose(sections)) <= budget.tokens
    }

    /// Cuts body entries from the end until the result fits.
    static func truncated(_ sections: Sections, budget: Budget) -> Sections {
        var candidate = sections
        for kept in stride(from: sections.body.count - 1, through: 0, by: -1) {
            candidate.body = Array(sections.body[..<kept])
            candidate.tail = [sections.more(sections.body[kept...])] + sections.tail
            if fits(candidate, budget) { break }
        }
        return candidate
    }

    static func sections(_ result: OutlineResult, level: Int, budget: Budget) -> Sections {
        switch result.kind {
        case .file:
            if let file = result.file { return fileSections(file, level: level) }
        case .symbol:
            if let symbol = result.symbol { return symbolSections(symbol, flow: result.flow, level: level, budget: budget) }
        case .folder:
            if let folder = result.folder { return folderSections(folder, level: level) }
        case .choices:
            return choiceSections(result.choices, target: result.target, level: level)
        }
        return Sections(head: ["\(result.target): nothing to outline"], body: [], tail: [], more: { _ in "" })
    }

    /// One entry per line.
    static func entries(_ lines: [String]) -> [Entry] {
        lines.map { Entry(lines: [$0]) }
    }

    // MARK: File

    static func fileSections(_ file: OutlineFile, level: Int) -> Sections {
        // A condition every top-level declaration is compiled under is said once.
        let shared = sharedCondition(file.declarations)
        var header = "\(file.path)  " + linesCount(file.lines)
        if !file.targets.isEmpty { header += " · " + targetsText(file.targets) }
        if let testKind = file.testKind { header += " · " + (testKind == "test" ? "test file" : "\(testKind) test file") }
        header += " · " + usersText(file.usedBy, language: file.language)
        if let shared { header += " · #if \(shared)" }
        var head = [header]
        if let note = file.note { head.append("note: \(note)") }

        var body: [Entry] = []
        let imports = importsLines(file.imports, language: file.language, level: level)
        if !imports.isEmpty { body.append(Entry(lines: imports, count: 0)) }
        if !file.headings.isEmpty {
            // A document's headings, the deeper ones dropped as the budget tightens.
            let deepest = level >= 5 ? 1 : (level >= 3 ? 2 : 6)
            let headings = file.headings.filter { $0.level <= deepest }
            let width = headings.map { String($0.line).count }.max() ?? 0
            body += headings.map { heading in
                Entry(lines: ["\(String(heading.line).padding(toLength: width, withPad: " ", startingAt: 0))  \(String(repeating: "#", count: heading.level)) \(heading.text)"], line: heading.line)
            }
        } else if file.declarations.isEmpty {
            body.append(Entry(lines: ["  no declarations"], count: 0))
        }
        // From level 4 the file's API stays and its private declarations are named on one line (as long as
        // something else remains).
        let exports = file.declarations.contains { $0.isExported }
        var hiddenIndices = level >= 4 ? Set(file.declarations.indices.filter { isPrivate(file.declarations[$0], language: file.language, fileHasExports: exports) }) : []
        if hiddenIndices.count == file.declarations.count { hiddenIndices = [] }
        let hidden = file.declarations.indices.filter { hiddenIndices.contains($0) }.map { file.declarations[$0] }
        let visible = file.declarations.indices.filter { !hiddenIndices.contains($0) }.map { file.declarations[$0] }
        let width = rangeWidth(visible)
        var printed: [OutlineDeclaration] = []
        for declaration in visible {
            // Names bound by one statement (`a, b = 1, 2` in Python) share a line and a signature: print it once.
            if let last = printed.last, last.lines == declaration.lines, last.signature == declaration.signature, declaration.members.isEmpty { continue }
            body.append(Entry(lines: declarationLines(declaration, rangeWidth: width, level: level, language: file.language, sharedCondition: shared),
                              line: declaration.lines.start))
            printed.append(declaration)
        }
        var tail: [String] = []
        if !hidden.isEmpty {
            let label = ["TypeScript", "JavaScript"].contains(file.language) ? "not exported: " : "private: "
            var names = hidden.map { "\($0.name) :\($0.lines.start)" }
            if level >= 6, names.count > 4 { names = Array(names.prefix(4)) + ["+\(names.count - 4) more"] }
            tail += wrap(names, first: label, rest: "    ")
        }
        tail += callLines(file.calls, level: level)
        return Sections(head: head, body: body, tail: tail) { cut in
            // Entries are cut from the end: declarations (or headings) from the last, the imports last of all.
            let count = cut.reduce(0) { $0 + $1.count }
            guard count > 0 else { return cut.first?.lines.first?.hasPrefix("imports: ") == true ? "imports not shown" : "no declarations" }
            return "+\(count) more not shown" + (cut.compactMap(\.line).min().map { ", from line \($0)" } ?? "")
        }
    }

    /// The `#if` condition every declaration shares, if there are several of them and they all have it.
    static func sharedCondition(_ declarations: [OutlineDeclaration]) -> String? {
        guard declarations.count > 1, let condition = declarations[0].condition else { return nil }
        return declarations.allSatisfy { $0.condition == condition } ? condition : nil
    }

    /// A top-level declaration other files cannot use: `private`/`fileprivate`, not exported from a TypeScript
    /// or JavaScript file that exports something, or a Python name with a leading underscore.
    static func isPrivate(_ declaration: OutlineDeclaration, language: String, fileHasExports: Bool) -> Bool {
        if declaration.access != nil { return true }
        switch language {
        case "TypeScript", "JavaScript": return fileHasExports && !declaration.isExported
        case "Python": return declaration.name.hasPrefix("_")
        default: return false
        }
    }

    /// `3-11    public struct WALFlags: OptionSet — rawValue: UInt32 :4 · …`, wrapped under the signature.
    static func declarationLines(_ declaration: OutlineDeclaration, rangeWidth: Int, level: Int, language: String, sharedCondition: String? = nil) -> [String] {
        let range = declaration.lines.description.padding(toLength: max(rangeWidth, declaration.lines.description.count), withPad: " ", startingAt: 0)
        var head = range + "  " + headText(declaration, level: level, language: language)
        if let route = declaration.route { head += "  [\(route)]" }
        if let condition = declaration.condition, condition != sharedCondition, level < 5 { head += "  [#if \(condition)]" }
        let doc = docText(declaration.doc, level: level, topLevel: true)
        // From level 7 a declaration keeps only the number of its members.
        let segments = level >= 7
            ? (declaration.members.isEmpty ? [] : ["\(declaration.memberCount) \(declaration.memberCount == 1 ? "member" : "members")"])
            : memberSegments(declaration.members, parentCondition: declaration.condition, level: level).map(\.text)
        let indent = String(repeating: " ", count: rangeWidth + 4)
        if let doc {
            return [head + "  " + doc] + wrap(segments, first: indent, rest: indent)
        }
        if segments.isEmpty { return [head] }
        return wrap(segments, first: head + " — ", rest: indent)
    }

    /// A top-level declaration's signature as its line starts with it; a long initial value is shortened. At the
    /// last level only its kind and name (`struct WALRecordHeader`, `func decode(from:offset:)`).
    static func headText(_ declaration: OutlineDeclaration, level: Int, language: String = "") -> String {
        if level >= 8 { return shortHead(declaration, language: language) }
        var text = collapsed(declaration.signature ?? "\(keyword(declaration)) \(declaration.name)")
        if isValue(declaration.kind), let value = declaration.value.map(collapsed), let range = text.range(of: value, options: .backwards) {
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) + " " + shortValue(value, limit: level >= 2 ? 30 : 50)
        }
        if level >= 2 { text = trimmedConformances(text) }
        return Elide.middle(text, limit: level >= 4 ? 70 : (level >= 2 ? 100 : 140))
    }

    /// A declaration by kind and name only: `struct WALRecordHeader`, `static func decode(from:offset:)`,
    /// `def bake(path, pid, dest, outdir)`, `function seal(text)`, `rawValue`.
    static func shortHead(_ declaration: OutlineDeclaration, language: String) -> String {
        var words: [String] = []
        if declaration.isStatic { words.append("static") }
        switch declaration.kind {
        case .function, .method:
            words += [language == "Python" ? "def" : (language == "Swift" ? "func" : "function"), callableName(declaration)]
        case .initializer:
            words.append(callableName(declaration))
        case .property, .variable, .constant:
            words.append(declaration.name)
        case .typeAlias where language == "TypeScript" || language == "JavaScript":
            words += ["type", declaration.name]
        default:
            words += [keyword(declaration), declaration.name]
        }
        return words.joined(separator: " ")
    }

    /// An initial value up to its first comment, at most `limit` characters.
    static func shortValue(_ value: String, limit: Int) -> String {
        var text = value
        if let comment = text.range(of: "//") ?? text.range(of: "/*") { text = String(text[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) + "…" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A ` · `-joined piece of a member list, and how many members it stands for.
    struct Segment {
        var text: String
        var count: Int

        init(_ text: String, count: Int = 1) {
            self.text = text
            self.count = count
        }
    }

    /// The members of a declaration as segments: an enum's cases first (cases on one line merged), then the
    /// rest in line order; private members counted from level 4, members past 6 from level 6.
    static func memberSegments(_ members: [OutlineDeclaration], parentCondition: String?, level: Int) -> [Segment] {
        let cases = members.filter { $0.kind == .enumCase }
        let others = members.filter { $0.kind != .enumCase }
        var segments: [Segment] = []
        var byLine: [(line: Int, names: [String])] = []
        for member in cases {
            let name = caseText(member, level: level)
            if let last = byLine.last, last.line == member.lines.start {
                byLine[byLine.count - 1].names.append(name)
            } else {
                byLine.append((member.lines.start, [name]))
            }
        }
        for (index, group) in byLine.enumerated() {
            segments.append(Segment((index == 0 ? "cases " : "") + group.names.joined(separator: ", ") + " :\(group.line)", count: group.names.count))
        }
        var privates = 0
        var more = 0
        for member in others {
            if level >= 4, member.access != nil {
                privates += 1
            } else if level >= 6, segments.count >= 6 {
                more += 1
            } else {
                var text = memberText(member, level: level)
                if let condition = member.condition, condition != parentCondition, level < 5 { text += " [#if \(condition)]" }
                segments.append(Segment(text + " :" + memberLines(member)))
            }
        }
        if privates > 0 { segments.append(Segment("+\(privates) private", count: privates)) }
        if more > 0 { segments.append(Segment("+\(more) more", count: more)) }
        return segments
    }

    /// `:28`, or `:40-60` for a nested type.
    static func memberLines(_ member: OutlineDeclaration) -> String {
        isNestedType(member) ? member.lines.description : "\(member.lines.start)"
    }

    static func isNestedType(_ member: OutlineDeclaration) -> Bool {
        member.kind.isContainer && member.kind != .typeAlias
    }

    /// `data(sequence:flags:payload:)`, `annual = "yearly"`.
    static func caseText(_ member: OutlineDeclaration, level: Int) -> String {
        var text = member.selector ?? member.name
        if let value = member.value, level < 3, value.count <= 24 { text += " = " + value }
        return text
    }

    /// One member, compactly: `static size = 48`, `@Published private(set) isSubscribed = false`,
    /// `encode() throws -> Data`, `static decode(from:offset:) throws -> WALRecordHeader`, `struct Intro (6)`.
    static func memberText(_ member: OutlineDeclaration, level: Int) -> String {
        var prefix: [String] = []
        if level < 2, isValue(member.kind) { prefix += member.attributes }
        if level < 4, let access = member.access { prefix.append(access) }
        if level < 3, let setter = member.setterAccess { prefix.append("\(setter)(set)") }
        if member.isStatic { prefix.append("static") }
        var text: String
        switch member.kind {
        case .function, .method, .initializer, .macro:
            text = callableName(member)
            if level < 3 {
                if let effects = member.effects { text += " " + effects }
                if let type = member.type { text += (member.parameters != nil && member.signature?.contains("->") != true ? ": " : " -> ") + type }
            }
        case .property, .variable, .constant:
            text = member.name
            let valueLimit = level >= 5 ? 0 : (level >= 3 ? 24 : 60)
            if let value = member.value.map(collapsed), value.count <= valueLimit {
                // An empty literal says nothing about the type: `products: [Product] = []`.
                if let type = member.type, level < 2, ["[]", "[:]", "nil", "\"\"", "{}"].contains(value) { text += ": " + type }
                text += " = " + value
            } else if let type = member.type, level < 2 {
                text += ": " + type
            }
        case .typeAlias:
            text = "typealias " + member.name + (level < 3 ? member.value.map { " = " + $0 } ?? "" : "")
        case .enumCase:
            text = caseText(member, level: level)
        case .extension:
            text = "extension " + member.name
        default:
            text = keyword(member) + " " + member.name
            let count = member.memberCount
            if count > 0 { text += " (\(count))" }
        }
        return Elide.middle((prefix + [text]).joined(separator: " "), limit: level >= 3 ? 60 : 90)
    }

    /// `decode(from:offset:)`; without a selector, `name(a, b)` from the parameter clause.
    static func callableName(_ member: OutlineDeclaration) -> String {
        if let selector = member.selector { return selector }
        guard let parameters = member.parameters else { return member.name + "()" }
        return member.name + "(" + parameterNames(parameters).joined(separator: ", ") + ")"
    }

    /// `(key: Buffer, plaintext = "")` → `key, plaintext`; a destructured parameter by its shape (`{…}`).
    static func parameterNames(_ clause: String) -> [String] {
        var inner = clause.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("(") { inner.removeFirst() }
        if inner.hasSuffix(")") { inner.removeLast() }
        var parameters: [String] = []
        var depth = 0
        var current = ""
        for character in inner {
            if "([{<".contains(character) { depth += 1 }
            if ")]}>".contains(character) { depth -= 1 }
            if character == "," && depth == 0 {
                parameters.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parameters.append(current)
        return parameters.compactMap { parameter in
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{") { return "{…}" }
            if trimmed.hasPrefix("[") { return "[…]" }
            let end = trimmed.firstIndex { $0 == ":" || $0 == "=" } ?? trimmed.endIndex
            let name = trimmed[..<end].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "?", with: "")
            return name.isEmpty ? nil : name
        }
    }

    static func keyword(_ declaration: OutlineDeclaration) -> String {
        switch declaration.kind {
        case .typeAlias: "typealias"
        case .enumCase: "case"
        default: declaration.kind.rawValue
        }
    }

    // MARK: Declaration (type, function, property…)

    static func symbolSections(_ symbol: OutlineSymbol, flow: FlowView?, level: Int, budget: Budget) -> Sections {
        let declaration = symbol.declaration
        var head = [symbolHeader(symbol, level: level)]
        if level < 5, let doc = docText(declaration.doc, level: min(level, 3), topLevel: true) { head.append("  " + doc) }
        let outside = OutlineCalls(repository: [], external: symbol.calls.external, environment: symbol.calls.environment)

        if declaration.kind.isCallable {
            let tail = callLines(outside, level: level)
            var body: [Entry] = []
            if let flow, let lastStep = flow.steps.last {
                // The flow carries the calls in order; its renderer cuts it to the room left.
                let used = TokenEstimate.of((head + tail).joined(separator: "\n")) + 1
                var lines = FeatureMapRenderer.render(flow: flow, budget: budget.isUnlimited ? .unlimited : Budget(tokens: max(100, budget.tokens - used)))
                    .components(separatedBy: "\n")
                // Its lines are the head, who calls it, one per step, then the other writers, the readers and the format
                // files: those go before the steps do, the format files from level 3, the rest from level 4.
                let stepsEnd = 1 + (flow.calledBy.isEmpty ? 0 : 1) + flow.steps.count
                if level >= 3, lines.count >= stepsEnd, lines[stepsEnd - 1].hasPrefix("  \(lastStep.line) │") {
                    let after = lines[stepsEnd...]
                    lines = Array(lines[..<stepsEnd]) + (level >= 4 ? [] : after.dropLast(min(after.count, flow.format.count)))
                }
                // From level 2 the flow's first line goes when it only repeats where the function is; its sinks stay.
                if level >= 2, flow.body == flow.entry, flow.body.path == symbol.path, flow.body.lines == declaration.lines, lines.first?.hasPrefix("flow ") == true {
                    lines.removeFirst()
                    if !flow.sinks.isEmpty { lines.insert("sinks: " + flow.sinks.joined(separator: ", "), at: 0) }
                }
                body = entries(lines)
            } else {
                // No steps to show (or no flow): what it calls, in order, then who calls it, three callers at most
                // from level 3 and one from level 5.
                let calls = symbol.calls.repository.sorted { ($0.lines.first ?? 0) < ($1.lines.first ?? 0) }
                body += entries(wrap(calls.map { "\($0.name) :" + linesText($0.lines, level: level) }, first: "calls in order: ", rest: "    "))
                if let flow, !flow.calledBy.isEmpty {
                    let shown = flow.calledBy.prefix(level >= 5 ? 1 : (level >= 3 ? 3 : flow.calledBy.count))
                    var callers = shown.map { "\($0.name ?? "(top level)") \($0.path):\($0.line)" }
                    let more = flow.calledBy.count - shown.count + flow.moreCallers
                    if more > 0 { callers.append("+\(more) more") }
                    body += entries(wrap(callers, first: "called by: ", rest: "    "))
                }
            }
            return Sections(head: head, body: body, tail: tail) { cut in "+\(cut.count) more \(cut.count == 1 ? "line" : "lines") not shown" }
        }

        // A type: one member per line up to level 2, then the members wrapped as in a file outline.
        var body: [Entry] = []
        let members = declaration.members
        if level <= 2 {
            let width = min(9, members.map { memberLines($0).count }.max() ?? 0)
            for group in groupedCases(members) {
                body.append(Entry(lines: memberLine(group, width: width, parentCondition: declaration.condition, level: level), count: group.count, line: group[0].lines.start))
            }
        } else {
            body += wrapEntries(memberSegments(members, parentCondition: declaration.condition, level: level + 1), first: "  ", rest: "  ")
        }
        // Extensions in the type's own file first: they need only their lines.
        let extensions = symbol.extensions.enumerated().sorted { a, b in
            (a.element.path == symbol.path ? 0 : 1, a.offset) < (b.element.path == symbol.path ? 0 : 1, b.offset)
        }.map(\.element)
        for item in extensions {
            let ext = item.declaration
            var line = Elide.middle(collapsed(ext.signature ?? "extension \(ext.name)"), limit: 100) + (item.path == symbol.path ? "  :\(ext.lines)" : "  \(item.path):\(ext.lines)")
            if let condition = ext.condition { line += "  [#if \(condition)]" }
            let segments = memberSegments(ext.members, parentCondition: ext.condition, level: level <= 2 ? 0 : level + 1)
            body.append(Entry(lines: [line] + wrap(segments.map(\.text), first: "    ", rest: "    "), count: ext.members.count))
        }
        let tail = callLines(symbol.calls, level: level)
        let total = members.count + symbol.extensions.reduce(0) { $0 + $1.declaration.members.count }
        return Sections(head: head, body: body, tail: tail) { cut in
            let count = cut.reduce(0) { $0 + $1.count }
            return "+\(count) more \(count == 1 ? "member" : "members") not shown (\(total) in all)"
        }
    }

    /// `func commitLocked() async throws  Sources/WaxCore/Wax.swift:1360-1521 · in Wax :72-2523 · target WaxCore
    /// · used by no other file`. As the budget tightens the route goes (the path says it) and conformances every
    /// value type has from level 2, the owner's lines from level 3, and a long signature is shortened in the middle.
    static func symbolHeader(_ symbol: OutlineSymbol, level: Int) -> String {
        let declaration = symbol.declaration
        let limit = level >= 4 ? 90 : (level >= 3 ? 110 : 160)
        var signature = collapsed(declaration.signature ?? "\(keyword(declaration)) \(declaration.qualifiedName)")
        if level >= 2 { signature = trimmedConformances(signature) }
        var header = Elide.middle(signature, limit: limit)
        header += "  \(symbol.path):\(declaration.lines)"
        if let route = declaration.route, level < 2 { header += " · \(route)" }
        if let owner = symbol.owner { header += " · in \(owner)" + (level < 3 ? symbol.ownerLines.map { " :\($0)" } ?? "" : "") }
        if !symbol.targets.isEmpty { header += " · " + targetsText(symbol.targets) }
        header += " · " + usersText(symbol.usedBy, language: symbol.language)
        if let condition = declaration.condition { header += " · #if \(condition)" }
        return header
    }

    /// Members in line order; enum cases declared on one line (`case cancelled, pending, success`) together.
    static func groupedCases(_ members: [OutlineDeclaration]) -> [[OutlineDeclaration]] {
        var groups: [[OutlineDeclaration]] = []
        for member in members {
            if member.kind == .enumCase, let last = groups.last?.last, last.kind == .enumCase, last.lines.start == member.lines.start {
                groups[groups.count - 1].append(member)
            } else {
                groups.append([member])
            }
        }
        return groups
    }

    /// A member on its own line: its line or range, its signature (compact from level 2), its doc sentence. Cases
    /// declared together share the line.
    static func memberLine(_ group: [OutlineDeclaration], width: Int, parentCondition: String?, level: Int) -> [String] {
        let member = group[0]
        let lines = memberLines(member)
        let range = lines.padding(toLength: max(width, lines.count), withPad: " ", startingAt: 0)
        var text: String
        if group.count > 1 {
            text = "case " + group.map { caseText($0, level: 0) }.joined(separator: ", ")
        } else if level < 2, let signature = member.signature, !isNestedType(member) {
            text = Elide.middle(collapsed(signature), limit: 110)
        } else {
            text = memberText(member, level: 0)
        }
        if let condition = member.condition, condition != parentCondition { text += "  [#if \(condition)]" }
        if group.count == 1, let doc = docText(member.doc, level: level, topLevel: false) { text += "  " + doc }
        var result = ["  \(range)  \(text)"]
        if isNestedType(member), !member.members.isEmpty {
            let indent = String(repeating: " ", count: 4 + range.count + 2)
            result += wrap(memberSegments(member.members, parentCondition: member.condition, level: 2).map(\.text), first: indent, rest: indent)
        }
        return result
    }

    // MARK: Folder

    static func folderSections(_ folder: OutlineFolder, level: Int) -> Sections {
        let name = folder.path.isEmpty ? "." : folder.path
        var header = folder.module.map { "module \($0)  \(folder.files.count) files in \(name)/" } ?? "\(name)/  \(folder.files.count) files"
        header += " · " + linesCount(folder.lines)
        if !folder.targets.isEmpty {
            header += " · " + (folder.targets.count == 1 ? "target " : "targets ")
                + folder.targets.prefix(4).map { folder.targets.count == 1 ? $0.name : "\($0.name) (\($0.files))" }.joined(separator: ", ")
                + (folder.targets.count > 4 ? ", +\(folder.targets.count - 4)" : "")
        }
        let prefix = folder.path.isEmpty ? "" : folder.path + "/"
        func relative(_ file: OutlineFolderFile) -> String {
            file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
        }
        // The first-level subfolder a file is in, if any.
        func subfolder(_ file: OutlineFolderFile) -> String? {
            let parts = relative(file).split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : nil
        }
        var sizes: [String: Int] = [:]
        for file in folder.files { if let sub = subfolder(file) { sizes[sub, default: 0] += 1 } }
        // From level 4 subfolders of more than 8 files collapse into one line each; from level 5 all of them.
        func collapses(_ sub: String) -> Bool { level >= 5 || (level == 4 && (sizes[sub] ?? 0) > 8) }
        var order: [(file: OutlineFolderFile?, subfolder: String?)] = []
        var subfolders: [String: [OutlineFolderFile]] = [:]
        for file in folder.files {
            if let top = subfolder(file), collapses(top) {
                if subfolders[top] == nil { order.append((nil, top)) }
                subfolders[top, default: []].append(file)
            } else {
                order.append((file, nil))
            }
        }
        let body = order.map { item -> Entry in
            if let file = item.file { return Entry(lines: [folderFileLine(file, relative: relative(file), level: min(level, 3))]) }
            let top = item.subfolder ?? ""
            let files = subfolders[top] ?? []
            var text = "  \(top)/  \(files.count) \(files.count == 1 ? "file" : "files") · " + linesCount(files.reduce(0) { $0 + $1.lines })
            if level < 6 {
                // The main declarations of the most used files say most about what the subfolder holds.
                var names: [String] = []
                for file in files.sorted(by: { $0.usedBy == $1.usedBy ? $0.path < $1.path : $0.usedBy > $1.usedBy }) {
                    if let name = file.primary.first?.name, !names.contains(name) { names.append(name) }
                }
                if !names.isEmpty { text += ": " + names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", +\(names.count - 6)" : "") }
            }
            return Entry(lines: [text], count: files.count, isFolder: true)
        }
        return Sections(head: [header], body: body, tail: []) { cut in
            let files = cut.reduce(0) { $0 + $1.count }
            return "+\(files) more \(files == 1 ? "file" : "files") not shown" + (cut.contains { $0.isFolder } ? ": outline a subfolder for its files" : "")
        }
    }

    /// `  WALRecord.swift  183 lines  public enum WALRecord · public struct WALFlags: OptionSet · used by 9`.
    static func folderFileLine(_ file: OutlineFolderFile, relative: String, level: Int) -> String {
        var line = "  \(relative)  " + linesCount(file.lines)
        if file.isTest { line += " [test]" }
        let primary = file.primary
        if !primary.isEmpty {
            let heads = primary.map { declaration -> String in
                switch level {
                case 0, 1: Elide.middle(headText(declaration, level: 2), limit: 70)
                case 2, 3: keyword(declaration) + " " + declaration.name
                default: declaration.name
                }
            }
            line += "  " + heads.joined(separator: " · ")
            let more = file.declarations - primary.count
            if more > 0 { line += " +\(more)" }
            if level == 0, let doc = primary.first?.doc { line += "  " + quoted(doc, limit: 60) }
        }
        if level < 3, file.usedBy > 0 { line += " · used by \(file.usedBy)" }
        return line
    }

    // MARK: Choices

    static func choiceSections(_ choices: [OutlineChoice], target: String, level: Int) -> Sections {
        let declarations = choices.filter { $0.location != nil }.count
        let head = "“\(target)” names \(choices.count) \(declarations == choices.count ? "declarations" : "targets"); outline one by its exact target:"
        let body = choices.map { choice -> String in
            var line = "  " + (choice.location ?? choice.target)
            if let signature = choice.signature, level < 2 {
                line += "  " + Elide.middle(collapsed(signature), limit: level == 0 ? 100 : 60)
            } else {
                line += "  " + choice.kind
            }
            if choice.location != nil {
                line += " · \(choice.uses) \(choice.uses == 1 ? "use" : "uses") in \(choice.files) \(choice.files == 1 ? "file" : "files")"
            }
            return line + " → outline(target:\(MoreCall.quoted(choice.target)))"
        }
        return Sections(head: [head], body: entries(body), tail: []) { cut in "+\(cut.count) more \(cut.count == 1 ? "choice" : "choices") not shown" }
    }

    // MARK: Shared parts

    /// `target WaxCore`, `targets Atlas + AtlasWatch Watch App`.
    static func targetsText(_ targets: [String]) -> String {
        (targets.count == 1 ? "target " : "targets ") + targets.joined(separator: " + ")
    }

    /// `used by 9 files (4 app, 5 test)`.
    static func usersText(_ users: OutlineUsers, language: String?) -> String {
        guard users.files > 0 else { return "used by no other file" }
        let noun = users.files == 1 ? "file" : "files"
        if users.testFiles == 0 { return "used by \(users.files) \(noun)" }
        if users.testFiles == users.files { return "used by \(users.files) test \(noun)" }
        let app = language.map { ["Swift", "Objective-C"].contains($0) } ?? true ? "app" : "source"
        return "used by \(users.files) \(noun) (\(users.files - users.testFiles) \(app), \(users.testFiles) test)"
    }

    /// `imports: @/db {db} · drizzle-orm {eq}`; a Swift file's module imports only at level 0, a script's
    /// imports without names from level 3 and not at all from level 4.
    static func importsLines(_ imports: [OutlineImport], language: String, level: Int) -> [String] {
        guard !imports.isEmpty else { return [] }
        if language == "Swift" || language == "Objective-C" {
            return level == 0 ? ["imports: " + imports.map(\.module).joined(separator: " · ")] : []
        }
        guard level < 4 else { return [] }
        let parts = imports.map { item -> String in
            var text = item.module + (item.isTypeOnly ? " (type)" : "")
            if level < 3, !item.names.isEmpty {
                let names = item.names.prefix(level < 2 ? 6 : 3)
                text += " {" + names.joined(separator: ", ") + (item.names.count > names.count ? ", +\(item.names.count - names.count)" : "") + "}"
            }
            return text
        }
        return wrap(parts, first: "imports: ", rest: "    ")
    }

    /// `calls out: …`, `external: …`, `env: …`.
    static func callLines(_ calls: OutlineCalls, level: Int) -> [String] {
        var lines = repositoryLines(calls.repository, level: level)
        let specific = calls.external.filter { !$0.isAmbient }
        let ambient = calls.external.filter(\.isAmbient)
        if level >= 5 {
            if !calls.external.isEmpty {
                lines.append("external: " + calls.external.map { "\($0.module) ×\($0.count)" }.joined(separator: " · "))
            }
        } else {
            let cap = [8, 4, 3, 3, 2][level]
            for (index, module) in specific.enumerated() {
                let kept = mostCalled(module.calls, cap: cap)
                var segments = kept.map { "\($0.name) :" + linesText($0.lines, level: level) }
                if module.calls.count > kept.count { segments.append("+\(module.calls.count - kept.count) more") }
                lines += wrap(segments, first: (index == 0 ? "external: " : "    ") + module.module + "  ", rest: "    ")
            }
            if !ambient.isEmpty {
                var text = (specific.isEmpty ? "external: " : "    ") + ambient.map { "\($0.module) ×\($0.count)" }.joined(separator: " · ")
                if level == 0 {
                    let called = ambient.flatMap(\.calls).sorted { $0.lines.count > $1.lines.count }
                    let names = called.prefix(4).map(\.name)
                    if !names.isEmpty { text += " (" + names.joined(separator: ", ") + (called.count > names.count ? ", …" : "") + ")" }
                }
                lines.append(text)
            }
        }
        if !calls.environment.isEmpty {
            let segments = calls.environment.map { use -> String in
                var parts: [String] = []
                if !use.reads.isEmpty { parts.append("read :" + LineList.format(use.reads)) }
                if !use.writes.isEmpty { parts.append("write :" + LineList.format(use.writes)) }
                return use.name + " " + parts.joined(separator: " ")
            }
            lines += wrap(segments, first: "env: ", rest: "    ")
        }
        return lines
    }

    /// Repository callees in order of first use. From level 1 error values are counted per error type
    /// (`WaxError ×95 (invalidToc, io, capacityExceeded, +5)`) and the list keeps the most-called callees; at the
    /// last level only the types (or functions) called are named.
    static func repositoryLines(_ calls: [OutlineCall], level: Int) -> [String] {
        guard !calls.isEmpty else { return [] }
        if level >= 8 {
            var owners: [String] = []
            for call in calls {
                let owner = ownerName(call.name)
                if !owners.contains(owner) { owners.append(owner) }
            }
            return wrap(Array(owners.prefix(6)) + (owners.count > 6 ? ["+\(owners.count - 6) more"] : []), first: "calls out: ", rest: "    ")
        }
        let plain = calls.filter { !$0.isError }
        let errors = calls.filter(\.isError)
        let kept = mostCalled(plain, cap: [Int.max, 40, 24, 16, 10, 6, 4, 4][min(level, 7)])
        var segments = kept.map { level >= 6 ? $0.name : "\($0.name) :" + linesText($0.lines, level: level) }
        if level == 0 {
            segments += errors.map { "\($0.name) :" + linesText($0.lines, level: level) }
        } else {
            var order: [String] = []
            var byType: [String: [(name: String, count: Int)]] = [:]
            for call in errors {
                let dot = call.name.lastIndex(of: ".")
                let type = dot.map { String(call.name[..<$0]) } ?? call.name
                let member = dot.map { String(call.name[call.name.index(after: $0)...]) } ?? ""
                if byType[type] == nil { order.append(type) }
                byType[type, default: []].append((member, call.lines.count))
            }
            for type in order {
                let members = (byType[type] ?? []).sorted { $0.count > $1.count }
                var text = "\(type) ×\(members.reduce(0) { $0 + $1.count })"
                if level < 4 {
                    let names = members.prefix(3).map(\.name).filter { !$0.isEmpty }
                    if !names.isEmpty { text += " (" + names.joined(separator: ", ") + (members.count > 3 ? ", +\(members.count - 3)" : "") + ")" }
                }
                segments.append(text)
            }
        }
        if plain.count > kept.count { segments.append("+\(plain.count - kept.count) more") }
        return wrap(segments, first: "calls out: ", rest: "    ")
    }

    /// The type a callee belongs to (`SHA256Checksum.digest` → `SHA256Checksum`, `new Button` → `Button`), or
    /// the callee itself when it belongs to none (`encrypt`, `db.insert`).
    static func ownerName(_ callee: String) -> String {
        var name = callee.hasPrefix("new ") ? String(callee.dropFirst(4)) : callee
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        guard let dot = name.lastIndex(of: ".") else { return name }
        let owner = String(name[..<dot])
        return owner.first?.isUppercase == true ? owner : name
    }

    /// At most `cap` calls, the most-called ones, in their original order.
    static func mostCalled(_ calls: [OutlineCall], cap: Int) -> [OutlineCall] {
        guard calls.count > cap else { return calls }
        let chosen = Set(calls.indices.sorted { a, b in
            calls[a].lines.count == calls[b].lines.count ? a < b : calls[a].lines.count > calls[b].lines.count
        }.prefix(cap))
        return calls.indices.filter { chosen.contains($0) }.map { calls[$0] }
    }

    /// A line list: in full, collapsed to `first-last ×N` from level 3.
    static func linesText(_ lines: [Int], level: Int) -> String {
        level >= 3 ? LineList.collapsed(lines, above: 3) : LineList.format(lines)
    }

    /// A doc sentence in quotes, shorter at higher levels; top-level ones until level 3, members' until 1.
    static func docText(_ doc: String?, level: Int, topLevel: Bool) -> String? {
        guard let doc else { return nil }
        if topLevel {
            switch level {
            case 0: return quoted(doc, limit: 110)
            case 1...3: return quoted(doc, limit: 60)
            default: return nil
            }
        }
        switch level {
        case 0: return quoted(doc, limit: 80)
        case 1: return quoted(doc, limit: 50)
        default: return nil
        }
    }

    static func quoted(_ text: String, limit: Int) -> String {
        let shortened = text.count > limit ? String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
        return "\"" + shortened + "\""
    }

    /// Conformances every value type has say little: `public struct WALRecordHeader: Equatable, Sendable` →
    /// `public struct WALRecordHeader`.
    static func trimmedConformances(_ signature: String) -> String {
        guard let colon = topLevelColon(signature) else { return signature }
        let head = signature[..<colon]
        let keywords = ["struct ", "class ", "enum ", "actor ", "protocol ", "extension "]
        guard keywords.contains(where: { head.contains($0) }) else { return signature }
        var tail = String(signature[signature.index(after: colon)...])
        var whereClause = ""
        if let range = tail.range(of: " where ") {
            whereClause = String(tail[range.lowerBound...])
            tail = String(tail[..<range.lowerBound])
        }
        let kept = tail.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !boilerplateConformances.contains($0) }
        return kept.isEmpty ? String(head) + whereClause : String(head) + ": " + kept.joined(separator: ", ") + whereClause
    }

    static let boilerplateConformances: Set<String> = [
        "Sendable", "@unchecked Sendable", "Equatable", "Hashable", "Codable", "Encodable", "Decodable", "Identifiable",
        "CustomStringConvertible", "CustomDebugStringConvertible",
    ]

    private static func topLevelColon(_ text: String) -> String.Index? {
        var depth = 0
        for index in text.indices {
            let character = text[index]
            if "(<[".contains(character) { depth += 1 }
            if ")>]".contains(character) { depth -= 1 }
            if character == ":" && depth == 0 { return index }
        }
        return nil
    }

    /// Whitespace runs as one space, and a parameter list written over several lines as on one line:
    /// `f( a: A, b: B, )` → `f(a: A, b: B)`.
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "( ", with: "(").replacingOccurrences(of: ", )", with: ")").replacingOccurrences(of: " )", with: ")")
    }

    /// `183 lines`, `1 line`.
    static func linesCount(_ count: Int) -> String {
        "\(grouped(count)) \(count == 1 ? "line" : "lines")"
    }

    /// `1,482`.
    static func grouped(_ number: Int) -> String {
        let digits = String(abs(number))
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return (number < 0 ? "-" : "") + result
    }

    /// Joins segments with ` · `, wrapping at `width`: the first line starts with `first`, the others with `rest`.
    static func wrap(_ segments: [String], first: String, rest: String) -> [String] {
        wrapEntries(segments.map { Segment($0) }, first: first, rest: rest).map { $0.lines[0] }
    }

    /// `wrap` for counted segments: one entry per printed line, counting the members on it.
    static func wrapEntries(_ segments: [Segment], first: String, rest: String) -> [Entry] {
        guard !segments.isEmpty else { return [] }
        var entries: [Entry] = []
        var current = Entry(lines: [first], count: 0)
        var empty = true
        for segment in segments {
            if empty {
                current.lines[0] += segment.text
                current.count += segment.count
                empty = false
            } else if current.lines[0].count + 3 + segment.text.count > width {
                entries.append(current)
                current = Entry(lines: [rest + segment.text], count: segment.count)
            } else {
                current.lines[0] += " · " + segment.text
                current.count += segment.count
            }
        }
        entries.append(current)
        return entries
    }

    /// The width of the widest top-level range, at most 9 (`1234-5678`).
    static func rangeWidth(_ declarations: [OutlineDeclaration]) -> Int {
        min(9, declarations.map(\.lines.description.count).max() ?? 0)
    }

    /// Declarations that hold a value: properties, variables and constants.
    static func isValue(_ kind: SymbolKind) -> Bool { kind == .property || kind == .variable || kind == .constant }
}
