import Foundation
import QueryEngine
import VesaliusCore
import VesaliusRender

/// Helpers for the v1-backed handlers each tool ships with until its v2 engine replaces them.
enum LegacyShim {
    /// Backticks and a trailing `()` are stripped.
    static func normalizedTarget(_ text: String) -> String {
        var target = text.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if target.hasSuffix("()") { target.removeLast(2) }
        return target
    }

    /// The v1 resolver knows no selectors: `Type.method(label:)` is looked up as `Type.method`, overloads together.
    static func symbolName(_ target: String) -> String {
        guard target.hasSuffix(")"), let open = target.firstIndex(of: "("), open > target.startIndex else { return target }
        let inside = target[target.index(after: open)..<target.index(before: target.endIndex)]
        guard inside.isEmpty || inside.contains(":") else { return target }
        return String(target[..<open])
    }

    static let sourceExtensions: Set<String> = [
        "swift", "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "py", "pyi", "m", "mm", "h", "hpp", "c", "cc", "cpp",
        "kt", "kts", "java", "go", "rs", "rb", "php", "cs", "metal", "sh", "json", "md", "yml", "yaml", "plist", "toml",
    ]

    /// A file or folder path rather than a symbol: it has a slash or ends in a source file extension.
    static func looksLikePath(_ target: String) -> Bool {
        target.contains("/") || sourceExtensions.contains((target as NSString).pathExtension.lowercased())
    }

    /// `path:line`, when the part before the last colon looks like a path.
    static func pathAndLine(_ target: String) -> (path: String, line: Int)? {
        guard let colon = target.lastIndex(of: ":"), let line = Int(target[target.index(after: colon)...]), line > 0 else { return nil }
        let path = String(target[..<colon])
        return looksLikePath(path) ? (path, line) : nil
    }

    /// Plain text paged by line within a budget; the first `head` lines appear on every page.
    static func paged(_ text: String, head: Int = 1, budget: Budget, more: MoreCall? = nil) -> String {
        let lines = text.components(separatedBy: "\n")
        let document = RenderDocument(head: Array(lines.prefix(head)), blocks: lines.dropFirst(head).map { FileBlock(path: $0) }, more: more, unit: "lines")
        return Budgeter.render(document, budget: budget)
    }

    /// Reference sites as file blocks: one member per enclosing declaration (`(top level)` outside any), its first
    /// site printed in full.
    static func blocks(_ sites: [ReferenceSite], kindNotes: Bool) -> [FileBlock] {
        var files: [String] = []
        var byFile: [String: [ReferenceSite]] = [:]
        for site in sites {
            if byFile[site.path] == nil { files.append(site.path) }
            byFile[site.path, default: []].append(site)
        }
        return files.map { path in
            var owners: [String] = []
            var byOwner: [String: [ReferenceSite]] = [:]
            for site in byFile[path] ?? [] {
                let owner = site.from ?? ""
                if byOwner[owner] == nil { owners.append(owner) }
                byOwner[owner, default: []].append(site)
            }
            let members = owners.map { owner -> MemberBlock in
                let sites = (byOwner[owner] ?? []).sorted { $0.line < $1.line }
                return MemberBlock(heading: owner.isEmpty ? "(top level)" : owner, sites: sites.enumerated().map { index, site in
                    Site(line: site.line, code: site.snippet ?? "", primary: index == 0,
                         note: kindNotes && site.kind != .call ? "(\(site.kind.rawValue))" : nil)
                })
            }
            return FileBlock(path: path, members: members)
        }
    }

    /// `3 references in 2 files (call 2, read 1)`.
    static func totals(_ sites: [ReferenceSite], total: Int, noun: String = "reference") -> String {
        let files = Set(sites.map(\.path)).count
        var kinds: [String: Int] = [:]
        for site in sites { kinds[site.kind.rawValue, default: 0] += 1 }
        var line = "\(total) \(noun)\(total == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
        if !kinds.isEmpty { line += " (" + kinds.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")" }
        if sites.count < total { line += " · first \(sites.count) listed" }
        return line
    }

    /// `  import/reference · uses WALRecord, WALFlags` after a dependent file's path.
    static func dependentHeader(_ file: FileRelation) -> String? {
        var parts: [String] = []
        if !file.kinds.isEmpty { parts.append(file.kinds.map(\.rawValue).joined(separator: "/")) }
        if let symbols = file.symbols, !symbols.isEmpty { parts.append("uses " + symbols.joined(separator: ", ")) }
        return parts.isEmpty ? nil : "  " + parts.joined(separator: " · ")
    }
}

/// Exact targets to choose from when a name matches several declarations.
struct TargetChoices: Encodable, Sendable {
    struct Choice: Encodable, Sendable {
        let target: String
        let kind: String
        let path: String
        let lines: String
        let references: Int
    }

    let query: String
    let choices: [Choice]

    func text(tool: String) -> String {
        var lines = ["“\(query)” names \(choices.count) declarations; ask for one by its exact target:"]
        for choice in choices {
            lines.append("  \(choice.path):\(choice.lines)  \(choice.kind) · \(choice.references) reference\(choice.references == 1 ? "" : "s") → \(tool)(target:\(MoreCall.quoted(choice.target)))")
        }
        return lines.joined(separator: "\n")
    }
}
