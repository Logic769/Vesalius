import Foundation
import QueryEngine
import VesaliusCore
import VesaliusRender

/// One tool of the MCP catalog. The CLI runs the same tools (`vesalius usages …`), so a tool's text is the same
/// in both places.
///
/// Each tool carries two descriptions: `descriptionShim`, true of the v1-backed handler that ships first (no
/// claims about code evidence or completeness), and `descriptionV2`, switched on with `isV2` by the work
/// package that ships the tool's engine.
public protocol MCPTool: Sendable {
    var name: String { get }
    /// `annotations.title`: the name Claude Code shows (`vesalius - Usages (MCP)`).
    var title: String { get }
    var descriptionShim: String { get }
    var descriptionV2: String { get }
    var isV2: Bool { get }
    /// `_meta["anthropic/searchHint"]`: ToolSearch scores each matched word.
    var searchHint: String { get }
    var loading: ToolLoading { get }
    /// In schema order. At most 3.
    var parameters: [ToolParameter] { get }

    /// Arguments are validated against `parameters` before this is called.
    func run(arguments: ToolArguments, context: ToolContext) async throws -> ToolOutput
}

extension MCPTool {
    /// What tools/list sends: the v2 text once the tool's engine has shipped.
    public var description: String { isV2 ? descriptionV2 : descriptionShim }

    public var inputSchema: JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.schema) })),
            "additionalProperties": .bool(false),
        ]
        let required = parameters.filter(\.isRequired).map { JSONValue.string($0.name) }
        if !required.isEmpty { object["required"] = .array(required) }
        return .object(object)
    }
}

/// Whether Claude Code loads a tool into the first prompt (`_meta["anthropic/alwaysLoad"]`).
public enum ToolLoading: Sendable, Hashable {
    /// Loaded up front once its golden gate passed (`true`). Before that the key is left out, so the tool is
    /// deferred under tool search but a server-level `alwaysLoad` can still load it.
    case gated(Bool)
    /// Always behind tool search: sends `false`, which keeps it deferred even under a server-level `alwaysLoad`.
    case deferred
}

/// One input property. Its `description` doubles as the list of accepted values in argument errors.
public struct ToolParameter: Sendable {
    public enum Kind: Sendable {
        case string
        case integer(minimum: Int)
        case boolean
        case oneOf([String])
    }

    public let name: String
    public let kind: Kind
    public let description: String?
    public let isRequired: Bool

    public init(_ name: String, _ kind: Kind, description: String? = nil, required: Bool = false) {
        self.name = name
        self.kind = kind
        self.description = description
        self.isRequired = required
    }

    var schema: JSONValue {
        var object: [String: JSONValue] = [:]
        switch kind {
        case .string:
            object["type"] = .string("string")
        case .integer(let minimum):
            object["type"] = .string("integer")
            object["minimum"] = .int(Int64(minimum))
        case .boolean:
            object["type"] = .string("boolean")
        case .oneOf(let values):
            object["type"] = .string("string")
            object["enum"] = .array(values.map { .string($0) })
        }
        if let description { object["description"] = .string(description) }
        return .object(object)
    }

    /// Nil when `value` is acceptable; otherwise the error, naming what is accepted.
    func problem(with value: JSONValue?) -> String? {
        guard let value, value != .null else {
            return isRequired ? "Missing required argument `\(name)`" + (description.map { ": \($0)" } ?? ".") : nil
        }
        switch kind {
        case .string:
            if isRequired, (value.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "`\(name)` is empty" + (description.map { ": \($0)" } ?? ".")
            }
            return value.stringValue == nil ? "`\(name)` must be a string" + (description.map { ": \($0)" } ?? ".") : nil
        case .integer(let minimum):
            guard let number = value.intValue, number >= minimum else {
                return "`\(name)` must be an integer ≥ \(minimum) (got \(Self.shown(value)))."
            }
            return nil
        case .boolean:
            return value.boolValue == nil ? "`\(name)` must be true or false (got \(Self.shown(value)))." : nil
        case .oneOf(let values):
            guard let text = value.stringValue, values.contains(text) else {
                return "`\(name)` must be one of \(values.joined(separator: ", ")) (got \(Self.shown(value)))."
            }
            return nil
        }
    }

    static func shown(_ value: JSONValue) -> String {
        if case .string(let text) = value { return "\"\(text)\"" }
        return (try? VesaliusJSON.string(value)) ?? "?"
    }
}

/// Validated tool arguments. Unknown keys (an old `repo`, say) are ignored.
public struct ToolArguments: Sendable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue]) {
        self.values = values
    }

    /// The trimmed string, nil when absent or blank.
    public func string(_ name: String) -> String? {
        guard let text = values[name]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    public func int(_ name: String) -> Int? { values[name]?.intValue }

    public func bool(_ name: String) -> Bool? { values[name]?.boolValue }
}

/// What a tool runs against.
public struct ToolContext: Sendable {
    public let engine: RepositoryEngine
    /// CLI `--full`: render without a token budget or pages.
    public let unbudgeted: Bool
    /// Re-indexes now, ignoring the freshness throttle, and returns how many files changed. The MCP server joins
    /// its single-flight refresh; the CLI indexes directly.
    public let reindex: @Sendable () async throws -> Int

    public init(engine: RepositoryEngine, unbudgeted: Bool = false, reindex: @escaping @Sendable () async throws -> Int) {
        self.engine = engine
        self.unbudgeted = unbudgeted
        self.reindex = reindex
    }

    /// The tool's budget for `page`, or no limit under `--full`.
    public func budget(_ budget: Budget, page: Int = 1) -> Budget {
        unbudgeted ? .unlimited : budget.page(page)
    }
}

/// A tool's result: plain text for MCP and the CLI, plus the result value for CLI `--json`.
public struct ToolOutput: Sendable {
    public var text: String
    public var json: AnyEncodable?
    public var isError: Bool
    /// Files whose quoted lines no longer match the disk. The dispatcher re-indexes once, runs the tool again and
    /// starts the result with `re-indexed N files`.
    public var staleFiles: [String]
    /// The answer's completeness check, for tools that run one (`usages`, `feature_map`): true when it says
    /// complete. Recorded by `vesalius stats`.
    public var complete: Bool?

    public init(text: String, json: AnyEncodable? = nil, isError: Bool = false, staleFiles: [String] = [], complete: Bool? = nil) {
        self.text = text
        self.json = json
        self.isError = isError
        self.staleFiles = staleFiles
        self.complete = complete
    }

    public static func error(_ message: String) -> ToolOutput {
        ToolOutput(text: message, isError: true)
    }
}

/// A result value of any type, for CLI `--json`.
public struct AnyEncodable: Encodable, Sendable {
    private let encodeValue: @Sendable (Encoder) throws -> Void

    public init<Value: Encodable & Sendable>(_ value: Value) {
        encodeValue = { encoder in try value.encode(to: encoder) }
    }

    public func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
