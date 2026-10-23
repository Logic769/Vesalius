import Foundation

/// One tool result before budgeting. The `Budgeter` prints it as
///
///     head[0]                                   declaration or header
///     head[1] · completeness                    totals and `complete:` / `INCOMPLETE:` (line 2)
///     head[2…], unresolved                      never cut
///     <path><header>  [labels]                  one block per file, cut and paged by the budget
///       <heading>
///         NNN │ code  note                     primary sites: the full statement
///         ·NNN code ·NNN same                   secondary sites, one line
///         trailer                               e.g. `called by: …`
///     tail                                      footer labels (`not code uses:`, `rejected lookalikes:` …)
///     showing X of Y files · more: tool(…, page:2)
///
/// Only blocks are cut or paged; head, completeness, unresolved and tail appear on every page.
public struct RenderDocument: Sendable, Hashable {
    public var head: [String]
    /// Joined to the second head line (the totals), so line 2 always carries it.
    public var completeness: String?
    public var unresolved: [String]
    public var blocks: [FileBlock]
    public var tail: [String]
    /// The call that shows the next page; nil when the result cannot be paged.
    public var more: MoreCall?
    /// What one block is, in the `showing X of Y <unit>` line.
    public var unit: String

    public init(head: [String], completeness: String? = nil, unresolved: [String] = [], blocks: [FileBlock] = [], tail: [String] = [], more: MoreCall? = nil, unit: String = "files") {
        self.head = head
        self.completeness = completeness
        self.unresolved = unresolved
        self.blocks = blocks
        self.tail = tail
        self.more = more
        self.unit = unit
    }
}

/// The part of a result about one file (or, for list-shaped results, one entry): its first line is `path`
/// followed by `header`, then its members.
public struct FileBlock: Sendable, Hashable {
    /// Repository-relative path, printed at the start of the block's first line.
    public var path: String
    /// Text right after the path on the first line (`:6 imports {encrypt}`, `uses WALRecord, WALFlags`).
    public var header: String?
    /// `[test]`, `[#if DEBUG]`, `[type-inferred via …]`…
    public var labels: [String]
    /// Test files collapse to one line when the result is over budget.
    public var isTest: Bool
    public var members: [MemberBlock]

    public init(path: String, header: String? = nil, labels: [String] = [], isTest: Bool = false, members: [MemberBlock] = []) {
        self.path = path
        self.header = header
        self.labels = labels
        self.isTest = isTest
        self.members = members
    }

    public var siteCount: Int { members.reduce(0) { $0 + $1.sites.count } }
}

/// The sites inside one enclosing declaration (a caller, a type that uses the target…).
public struct MemberBlock: Sendable, Hashable {
    /// The enclosing declaration's line, e.g. `private func ImportSheet.beginImport(urls:) :210-248`. Nil puts
    /// the sites directly under the file line.
    public var heading: String?
    public var sites: [Site]
    /// Lines after the sites, e.g. `called by: pickFiles(urls:) :204 · retryImport() :301`.
    public var trailer: [String]

    public init(heading: String? = nil, sites: [Site] = [], trailer: [String] = []) {
        self.heading = heading
        self.sites = sites
        self.trailer = trailer
    }
}

/// One use of the target. A primary site prints its statement (`226 │ book = await …`); a secondary one prints
/// compactly (`·231 importBook(from: url)`).
public struct Site: Sendable, Hashable {
    public var line: Int
    /// The statement as it reads in the file. Further lines (`\n`-separated) print as `line+1 │ …`, `line+2 │ …`.
    public var code: String
    public var primary: Bool
    /// Printed two spaces after the code, so it is never read as code: `(body)`, `→ :54 db.insert(…)`.
    public var note: String?

    public init(line: Int, code: String, primary: Bool = true, note: String? = nil) {
        self.line = line
        self.code = code
        self.primary = primary
        self.note = note
    }
}

/// The exact tool call that shows another page: `usages(target:"Foo.bar", page:2)`.
public struct MoreCall: Sendable, Hashable {
    public enum Value: Sendable, Hashable {
        case string(String)
        case int(Int)
        case bool(Bool)
    }

    public var tool: String
    /// In call order; `page` is added by the budgeter.
    public var arguments: [Argument]

    public struct Argument: Sendable, Hashable {
        public var name: String
        public var value: Value

        public init(_ name: String, _ value: Value) {
            self.name = name
            self.value = value
        }
    }

    public init(tool: String, arguments: [Argument]) {
        self.tool = tool
        self.arguments = arguments
    }

    public func call(page: Int) -> String {
        let parts = (arguments.filter { $0.name != "page" } + [Argument("page", .int(page))]).map { argument -> String in
            switch argument.value {
            case .string(let text): "\(argument.name):\(Self.quoted(text))"
            case .int(let number): "\(argument.name):\(number)"
            case .bool(let flag): "\(argument.name):\(flag)"
            }
        }
        return "\(tool)(\(parts.joined(separator: ", ")))"
    }

    /// A string argument as it appears in a call: `"Foo.bar"`, with quotes and backslashes escaped.
    public static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
