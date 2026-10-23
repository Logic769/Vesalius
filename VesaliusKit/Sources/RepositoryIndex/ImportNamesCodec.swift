import Foundation
import VesaliusCore

/// Compact storage for imported names: `name` or `name as alias`, comma separated. A name imported with an
/// inline `type` modifier (`import { type A }`) carries a `type ` prefix, which `decode` turns back into
/// `isTypeOnly`, so readers that only need names and aliases are unaffected.
public enum ImportNamesCodec {
    public static func encode(_ names: [ImportedName]) -> String {
        names.map { name in
            let prefix = name.isTypeOnly ? "type " : ""
            if let alias = name.alias, alias != name.name { return "\(prefix)\(name.name) as \(alias)" }
            return prefix + name.name
        }
        .joined(separator: ",")
    }

    public static func decode(_ text: String?) -> [ImportedName] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: ",").map { raw in
            var part = Substring(raw)
            let isTypeOnly = part.hasPrefix("type ")
            if isTypeOnly { part = part.dropFirst(5) }
            let pieces = part.components(separatedBy: " as ")
            if pieces.count == 2 { return ImportedName(name: pieces[0], alias: pieces[1], isTypeOnly: isTypeOnly) }
            return ImportedName(name: String(part), isTypeOnly: isTypeOnly)
        }
    }
}
