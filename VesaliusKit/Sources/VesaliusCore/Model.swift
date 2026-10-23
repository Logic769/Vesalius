import Foundation

// MARK: - Graph vocabulary

/// Kinds of symbols extracted from source code, normalised across languages.
public enum SymbolKind: String, Codable, Sendable, CaseIterable {
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case interface
    case actor
    case `extension`
    case typeAlias = "typealias"
    case function
    case method
    case initializer
    case property
    case variable
    case constant
    case enumCase = "case"
    case namespace
    case macro
    case component

    /// Types that can own members and participate in inheritance.
    public var isType: Bool {
        switch self {
        case .class, .struct, .enum, .protocol, .interface, .actor, .typeAlias, .component: true
        default: false
        }
    }

    public var isCallable: Bool {
        switch self {
        case .function, .method, .initializer, .macro, .component: true
        default: false
        }
    }

    public var isContainer: Bool {
        isType || self == .extension || self == .namespace
    }

    public var displayName: String {
        switch self {
        case .typeAlias: "type alias"
        case .enumCase: "enum case"
        default: rawValue
        }
    }
}

/// Kinds of references found at use sites.
public enum ReferenceKind: String, Codable, Sendable, CaseIterable {
    case call
    case typeUse = "type"
    case inherit
    case conform
    case instantiate
    case read
    case write
    case decorator
    case member

    /// The graph edge produced when the reference resolves.
    public var edgeKind: EdgeKind {
        switch self {
        case .call, .decorator: .calls
        case .typeUse, .member: .references
        case .inherit: .inherits
        case .conform: .conformsTo
        case .instantiate: .instantiates
        case .read: .reads
        case .write: .writes
        }
    }
}

/// The syntactic role of a use site, finer than `ReferenceKind` (stored in `refs.context`).
public enum ReferenceContext: String, Codable, Sendable, CaseIterable {
    case call
    case read
    case write
    case type
    /// `typeof x` in a TypeScript type position.
    case typeof
    /// A `case .x` pattern or `for case`.
    case pattern
    /// An implicit member (`.red`, `.init(…)`) whose type comes from context.
    case implicit
    case keypath
    /// `$x`: a property wrapper's projected value.
    case projected
    case delete
    /// A read or write of one environment variable (`env:NAME`).
    case env
    /// An environment lookup with a computed key.
    case envDynamic = "env-dynamic"
    /// The whole environment (`process.env`, `os.environ`) passed or iterated.
    case envAll = "env-all"
    /// `extends` / `implements` clauses.
    case heritage
    case decorator
}

/// How the linker decided a reference's target (stored in `refs.basis`).
public enum ResolutionBasis: String, Codable, Sendable, CaseIterable {
    /// An explicit import binding.
    case `import`
    /// The receiver's type is known.
    case typed
    /// A member of the enclosing type (implicit or explicit `self`).
    case `self`
    /// A member reached through a type name.
    case `static`
    /// A same-file or same-project declaration.
    case lexical
    /// The only declaration with that name; a guess.
    case uniqueName = "unique-name"
    /// A declaration outside the repository (framework or package).
    case external
    /// An environment variable.
    case env
}

/// Typed graph edges stored in the index.
public enum EdgeKind: String, Codable, Sendable, CaseIterable {
    case contains
    case imports
    case references
    case calls
    case inherits
    case conformsTo
    case instantiates
    case reads
    case writes
    case dependsOn
    case relatedTo

    /// Edge kinds that represent a code dependency from source to target.
    public var isDependency: Bool {
        switch self {
        case .contains, .relatedTo: false
        default: true
        }
    }
}

public enum Visibility: String, Codable, Sendable {
    case open, `public`, package, `internal`, `fileprivate`, `private`

    public var isExternallyVisible: Bool { self == .open || self == .public }
}

public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
    case info, low, medium, high, critical

    public var rank: Int {
        switch self {
        case .info: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        case .critical: 4
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String { rawValue.capitalized }
}

/// Stable string identifiers for graph nodes. They stay valid across re-indexing because they are
/// derived from repository-relative paths and qualified names rather than database row ids.
public enum NodeID {
    public static func file(_ path: String) -> String { "file:\(path)" }
    public static func directory(_ path: String) -> String { "dir:\(path.isEmpty ? "." : path)" }
    public static func module(_ name: String) -> String { "mod:\(name)" }
    public static func symbol(path: String, qualifiedName: String) -> String { "sym:\(path)#\(qualifiedName)" }
    public static func external(_ name: String) -> String { "ext:\(name)" }

    public enum Kind: String, Sendable { case file, dir, mod, sym, ext }

    /// Splits a stable id into kind and payload.
    public static func parse(_ id: String) -> (kind: Kind, value: String)? {
        guard let colon = id.firstIndex(of: ":"), let kind = Kind(rawValue: String(id[..<colon])) else { return nil }
        return (kind, String(id[id.index(after: colon)...]))
    }
}

/// An inclusive line range that serialises compactly as `"12-48"` (or `"12"`).
public struct LineRange: Codable, Sendable, Hashable, CustomStringConvertible {
    public var start: Int
    public var end: Int

    public init(_ start: Int, _ end: Int) {
        self.start = max(1, start)
        self.end = max(self.start, end)
    }

    public var count: Int { end - start + 1 }
    public var description: String { start == end ? "\(start)" : "\(start)-\(end)" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard let first = parts.first else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid line range \(text)")
        }
        self.init(first, parts.count > 1 ? parts[1] : first)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Repository structure

public enum ModuleKind: String, Codable, Sendable {
    case swiftPackageTarget = "swiftpm-target"
    case xcodeTarget = "xcode-target"
    case npmPackage = "npm-package"
    case pythonPackage = "python-package"
    case goModule = "go-module"
    case cargoCrate = "cargo-crate"
    case directory = "directory"
}

/// A module/package detected from manifests or repository structure.
public struct ModuleInfo: Codable, Sendable, Hashable {
    public var name: String
    public var kind: ModuleKind
    public var rootPath: String
    public var manifestPath: String?
    public var language: Language?

    public init(name: String, kind: ModuleKind, rootPath: String, manifestPath: String? = nil, language: Language? = nil) {
        self.name = name
        self.kind = kind
        self.rootPath = rootPath
        self.manifestPath = manifestPath
        self.language = language
    }
}
