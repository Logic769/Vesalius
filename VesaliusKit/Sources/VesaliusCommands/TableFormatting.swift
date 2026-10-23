import Foundation
import QueryEngine
import VesaliusRender

extension TextFormatter {
    /// `vesalius query` rows, tab-separated. Lives here because the result type is QueryEngine's.
    static func table(_ result: RepositoryEngine.RawQueryResult) -> String {
        var lines = [result.columns.joined(separator: "\t")]
        for row in result.rows {
            lines.append(row.map { value in
                switch value {
                case .null: "NULL"
                case .string(let s): s
                case .int(let i): String(i)
                case .double(let d): String(d)
                case .bool(let b): String(b)
                default: "…"
                }
            }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }
}
