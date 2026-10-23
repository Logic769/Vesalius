import Foundation

/// Adds or removes one `permissions.allow` rule in Claude Code's user settings, editing the text in place so the
/// rest of the file keeps its order and formatting. An edit is written only when the result parses and equals
/// the original plus (or minus) that one rule; anything else leaves the file alone.
struct ClaudeSettings {
    /// Pre-approves every Vesalius tool. They are all read-only.
    static let vesaliusRule = "mcp__vesalius__*"

    enum Outcome: Equatable {
        case changed
        case unchanged
        /// The file couldn't be edited safely; the reason says why.
        case skipped(String)
    }

    /// The smallest thing adding the rule creates, so undo can take away exactly that: the whole file, the
    /// `permissions` member, the `allow` member, or just the rule.
    enum Created: String, Codable, Sendable {
        case file, permissions, allow, rule
    }

    let url: URL

    /// `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
    static func userSettings(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeSettings {
        let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        return ClaudeSettings(url: URL(fileURLWithPath: directory).appendingPathComponent("settings.json"))
    }

    func allows(_ rule: String) -> Bool {
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Self.allowList(root).contains(rule)
    }

    /// What `addAllowRule` would create in the file as it is now; nil when it can't tell.
    func creation() -> Created? {
        guard exists else { return .file }
        guard case .success(let read) = contents() else { return nil }
        let root = read.1
        guard let permissions = root["permissions"] as? [String: Any] else { return .permissions }
        return permissions["allow"] == nil ? .allow : .rule
    }

    func addAllowRule(_ rule: String, dryRun: Bool = false) -> Outcome {
        guard exists else {
            let fresh = "{\n  \"permissions\": {\n    \"allow\": [\n      \(Self.quoted(rule))\n    ]\n  }\n}\n"
            return dryRun ? .changed : write(fresh, to: url)
        }
        let text: String, root: [String: Any]
        switch contents() {
        case .success(let read): (text, root) = read
        case .failure(let reason): return reason
        }
        if Self.allowList(root).contains(rule) { return .unchanged }
        if Self.hasDuplicateKeys(text) { return .skipped(Self.duplicateKeys(url)) }
        guard let edited = Self.inserting(rule, into: text) else { return .skipped("couldn't find where to add the rule in \(url.path)") }
        guard let after = Self.parse(edited), Self.allowList(after) == Self.allowList(root) + [rule] || Self.allowList(after) == [rule] + Self.allowList(root),
              NSDictionary(dictionary: Self.removing(rule, from: after)).isEqual(to: Self.removing(rule, from: root)) else {
            return .skipped("an edit of \(url.path) didn't check out, so it was left alone")
        }
        return dryRun ? .changed : write(edited, to: url.resolvingSymlinksInPath())
    }

    /// Removes the rule, and with it whatever adding it created (`created`, from the setup record); with no record,
    /// an `allow` or `permissions` left empty goes too. A file setup created that ends up empty is deleted.
    func removeAllowRule(_ rule: String, created: Created? = nil, dryRun: Bool = false) -> Outcome {
        guard exists else { return .unchanged }
        let text: String, root: [String: Any]
        switch contents() {
        case .success(let read): (text, root) = read
        case .failure(let reason): return reason
        }
        guard Self.allowList(root).contains(rule) else { return .unchanged }
        if Self.hasDuplicateKeys(text) { return .skipped(Self.duplicateKeys(url)) }
        guard let edited = Self.deleting(rule, from: text, upTo: created ?? .permissions), let after = Self.parse(edited), !Self.allowList(after).contains(rule),
              NSDictionary(dictionary: Self.removing(rule, from: after)).isEqual(to: Self.removing(rule, from: root)) else {
            return .skipped("an edit of \(url.path) didn't check out, so it was left alone")
        }
        if dryRun { return .changed }
        if created == .file, after.isEmpty {
            do {
                try FileManager.default.removeItem(at: url)
                return .changed
            } catch {
                return .skipped("couldn't delete \(url.path): \(error.localizedDescription)")
            }
        }
        return write(edited, to: url.resolvingSymlinksInPath())
    }

    private static func duplicateKeys(_ url: URL) -> String {
        "\(url.path) repeats a key, so it's unclear which one Claude Code reads"
    }

    /// Whether anything is at the path, a symlink (even a dangling one) included.
    private var exists: Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private enum Read {
        case success((String, [String: Any]))
        case failure(Outcome)
    }

    /// The file's text and parsed contents, or why it can't be edited safely.
    private func contents() -> Read {
        guard let data = try? Data(contentsOf: url.resolvingSymlinksInPath()) else { return .failure(.skipped("couldn't read \(url.path)")) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.skipped("\(url.path) isn't UTF-8 text")) }
        guard let root = Self.parse(text) else { return .failure(.skipped("\(url.path) isn't plain JSON")) }
        return .success((text, root))
    }

    /// Writes `text` to `target` (the file behind any symlink), keeping its permissions.
    private func write(_ text: String, to target: URL) -> Outcome {
        do {
            let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions]
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target, options: .atomic)
            if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
            return .changed
        } catch {
            return .skipped("couldn't write \(target.path): \(error.localizedDescription)")
        }
    }

    // MARK: Reading

    static func parse(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    static func allowList(_ root: [String: Any]) -> [String] {
        ((root["permissions"] as? [String: Any])?["allow"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// `root` without `rule` in permissions.allow, and without an `allow` or `permissions` left empty, so an edit
    /// can be compared with the original whichever containers it had to create.
    static func removing(_ rule: String, from root: [String: Any]) -> [String: Any] {
        guard var permissions = root["permissions"] as? [String: Any] else { return root }
        var copy = root
        if let allow = permissions["allow"] as? [Any] {
            let kept = allow.filter { ($0 as? String) != rule }
            if kept.isEmpty { permissions.removeValue(forKey: "allow") } else { permissions["allow"] = kept }
        }
        if permissions.isEmpty { copy.removeValue(forKey: "permissions") } else { copy["permissions"] = permissions }
        return copy
    }

    /// Whether the top level or `permissions` names a key twice. Readers disagree on which one wins.
    static func hasDuplicateKeys(_ text: String) -> Bool {
        let scanner = JSONScanner(bytes: Array(text.utf8))
        let root = scanner.skipSpace(from: 0)
        guard let members = scanner.members(ofObjectAt: root) else { return false }
        if Set(members.map(\.key)).count != members.count { return true }
        guard let permissions = members.first(where: { $0.key == "permissions" }), let inner = scanner.members(ofObjectAt: permissions.value.lowerBound) else { return false }
        return Set(inner.map(\.key)).count != inner.count
    }

    // MARK: Editing the text

    static func quoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// `text` with `rule` added: first in an existing `permissions.allow`, else in a new `allow`, else in a new
    /// `permissions` at the top. New members copy the spacing before the first existing one.
    static func inserting(_ rule: String, into text: String) -> String? {
        let bytes = Array(text.utf8)
        let scanner = JSONScanner(bytes: bytes)
        let root = scanner.skipSpace(from: 0)
        guard let members = scanner.members(ofObjectAt: root) else { return nil }
        guard let permissions = members.first(where: { $0.key == "permissions" }) else {
            return insertMember("\"permissions\": {\"allow\": [\(quoted(rule))]}", into: bytes, objectStart: root, members: members)
        }
        guard let inner = scanner.members(ofObjectAt: permissions.value.lowerBound) else { return nil }
        guard let allow = inner.first(where: { $0.key == "allow" }) else {
            return insertMember("\"allow\": [\(quoted(rule))]", into: bytes, objectStart: permissions.value.lowerBound, members: inner)
        }
        let open = allow.value.lowerBound
        guard let elements = scanner.elements(ofArrayAt: open) else { return nil }
        guard let first = elements.first else { return splice(bytes, at: open + 1, quoted(rule)) }
        let gap = String(decoding: bytes[(open + 1)..<first.lowerBound], as: UTF8.self)
        return splice(bytes, at: open + 1, gap + quoted(rule) + ",")
    }

    /// `text` without the `rule` element of permissions.allow and the comma that joined it. When it was the only
    /// rule and `level` allows, the `allow` member goes too, and so does `permissions` if nothing else is in it.
    static func deleting(_ rule: String, from text: String, upTo level: Created = .permissions) -> String? {
        let bytes = Array(text.utf8)
        let scanner = JSONScanner(bytes: bytes)
        let root = scanner.skipSpace(from: 0)
        guard let members = scanner.members(ofObjectAt: root),
              let permissionsIndex = members.firstIndex(where: { $0.key == "permissions" }),
              let inner = scanner.members(ofObjectAt: members[permissionsIndex].value.lowerBound),
              let allowIndex = inner.firstIndex(where: { $0.key == "allow" }),
              let elements = scanner.elements(ofArrayAt: inner[allowIndex].value.lowerBound) else { return nil }
        let target = quoted(rule)
        guard let index = elements.firstIndex(where: { String(decoding: bytes[$0], as: UTF8.self) == target }) else { return nil }
        var edited = bytes
        let permissions = members[permissionsIndex].value
        let onlyRule = elements.count == 1
        if onlyRule, inner.count == 1, level == .permissions || level == .file {
            edited.removeSubrange(removal(of: permissionsIndex, among: members.map { $0.keyStart..<$0.value.upperBound }, in: root..<(scanner.endOfValue(at: root) ?? bytes.count)))
        } else if onlyRule, level != .rule {
            edited.removeSubrange(removal(of: allowIndex, among: inner.map { $0.keyStart..<$0.value.upperBound }, in: permissions))
        } else {
            edited.removeSubrange(removal(of: index, among: elements, in: inner[allowIndex].value))
        }
        return String(decoding: edited, as: UTF8.self)
    }

    /// The bytes to cut to remove item `index` of a container: the item and the comma and spacing that tie it
    /// to its neighbour, or everything between the brackets when it is the only one.
    static func removal(of index: Int, among items: [Range<Int>], in container: Range<Int>) -> Range<Int> {
        if index + 1 < items.count { return items[index].lowerBound..<items[index + 1].lowerBound }
        if index > 0 { return items[index - 1].upperBound..<items[index].upperBound }
        return (container.lowerBound + 1)..<(container.upperBound - 1)
    }

    private static func insertMember(_ member: String, into bytes: [UInt8], objectStart: Int, members: [JSONScanner.Member]) -> String {
        guard let first = members.first else { return splice(bytes, at: objectStart + 1, member) }
        let gap = String(decoding: bytes[(objectStart + 1)..<first.keyStart], as: UTF8.self)
        return splice(bytes, at: objectStart + 1, gap + member + ",")
    }

    private static func splice(_ bytes: [UInt8], at index: Int, _ insertion: String) -> String {
        var edited = bytes
        edited.insert(contentsOf: Array(insertion.utf8), at: index)
        return String(decoding: edited, as: UTF8.self)
    }
}

/// Finds the members of objects and the elements of arrays in JSON text, by byte offset.
struct JSONScanner {
    struct Member {
        let key: String
        let keyStart: Int
        /// The value's bytes, from its first byte to just past its last.
        let value: Range<Int>
    }

    let bytes: [UInt8]

    func skipSpace(from index: Int) -> Int {
        var index = index
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        return index
    }

    /// The end of the value starting at `index` (one past its last byte).
    func endOfValue(at index: Int) -> Int? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "\""):
            var i = index + 1
            while i < bytes.count {
                if bytes[i] == UInt8(ascii: "\\") { i += 2; continue }
                if bytes[i] == UInt8(ascii: "\"") { return i + 1 }
                i += 1
            }
            return nil
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var i = index
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    guard let end = endOfValue(at: i) else { return nil }
                    i = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return nil
        default:
            var i = index
            while i < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
            return i
        }
    }

    func members(ofObjectAt start: Int) -> [Member]? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "{") else { return nil }
        var members: [Member] = []
        var i = skipSpace(from: start + 1)
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { return [] }
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "\""), let keyEnd = endOfValue(at: i),
                  let key = try? JSONDecoder().decode(String.self, from: Data(bytes[i..<keyEnd])),
                  case let colon = skipSpace(from: keyEnd), colon < bytes.count, bytes[colon] == UInt8(ascii: ":"),
                  case let valueStart = skipSpace(from: colon + 1), let valueEnd = endOfValue(at: valueStart) else { return nil }
            members.append(Member(key: key, keyStart: i, value: valueStart..<valueEnd))
            let next = skipSpace(from: valueEnd)
            guard next < bytes.count else { return nil }
            if bytes[next] == UInt8(ascii: "}") { return members }
            guard bytes[next] == UInt8(ascii: ",") else { return nil }
            i = skipSpace(from: next + 1)
        }
        return nil
    }

    func elements(ofArrayAt start: Int) -> [Range<Int>]? {
        guard start < bytes.count, bytes[start] == UInt8(ascii: "[") else { return nil }
        var elements: [Range<Int>] = []
        var i = skipSpace(from: start + 1)
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { return [] }
        while i < bytes.count {
            guard let end = endOfValue(at: i) else { return nil }
            elements.append(i..<end)
            let next = skipSpace(from: end)
            guard next < bytes.count else { return nil }
            if bytes[next] == UInt8(ascii: "]") { return elements }
            guard bytes[next] == UInt8(ascii: ",") else { return nil }
            i = skipSpace(from: next + 1)
        }
        return nil
    }
}
