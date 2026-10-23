import Foundation

/// What `outline` shows: what a file, type, folder or function contains at about a fifth of the
/// tokens of reading it, or where a name is declared. Everything comes from the index: declarations with their
/// signatures as written (attributes, setter access and short initial values kept), line ranges and first
/// doc sentences, the calls that leave the outlined code (into the repository, frameworks and the environment),
/// and how many files use it. A function's outline is its flow.
public struct OutlineResult: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case file
        /// A type, function, property or other declaration: `symbol`, plus `flow` for a function.
        case symbol
        /// A folder or a repository module: `folder`.
        case folder
        /// A name declared in several places: `choices`.
        case choices
    }

    public var kind: Kind
    /// The target as it was asked for.
    public var target: String
    /// Characters of source the outline stands in for: the file (for a declaration, the file that declares it,
    /// plus the file of the body its flow follows the work into; for a type, its declaration and extensions), or
    /// a folder's files. The budget is a fifth of it.
    public var sourceCharacters: Int
    public var file: OutlineFile?
    public var symbol: OutlineSymbol?
    /// A function's call sites in order, with sinks flagged; nil when it could not be built.
    public var flow: FlowView?
    public var folder: OutlineFolder?
    public var choices: [OutlineChoice]
    /// Outlined files edited since they were indexed: their line numbers may point at other code.
    public var staleFiles: [String]

    public init(kind: Kind, target: String, sourceCharacters: Int, file: OutlineFile? = nil, symbol: OutlineSymbol? = nil, flow: FlowView? = nil,
                folder: OutlineFolder? = nil, choices: [OutlineChoice] = [], staleFiles: [String] = []) {
        self.kind = kind
        self.target = target
        self.sourceCharacters = sourceCharacters
        self.file = file
        self.symbol = symbol
        self.flow = flow
        self.folder = folder
        self.choices = choices
        self.staleFiles = staleFiles
    }

    /// The files whose line numbers (and, in a flow, code) the outline quotes.
    public var quotedFiles: [String] {
        var paths: [String] = []
        if let file { paths.append(file.path) }
        if let symbol { paths += [symbol.path] + symbol.extensions.map(\.path) }
        if let flow { paths += [flow.body.path] + flow.otherWriters.map(\.path) + flow.readers.map(\.path) }
        if let folder { paths += folder.files.map(\.path) }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}

/// One file: its declarations in line order, its imports, what it calls outside itself, and who uses it.
public struct OutlineFile: Codable, Sendable, Hashable {
    public var path: String
    /// Display name of its language.
    public var language: String
    public var lines: Int
    /// Build targets that compile it.
    public var targets: [String]
    /// `unit`, `ui` or `support` for a test file, `test` when the kind is unknown; nil otherwise.
    public var testKind: String?
    public var usedBy: OutlineUsers
    /// Top-level declarations, each with its members.
    public var declarations: [OutlineDeclaration]
    public var imports: [OutlineImport]
    public var calls: OutlineCalls
    /// A Markdown file's headings, read from disk.
    public var headings: [OutlineHeading]
    /// Why the declarations may be incomplete: the file was only scanned lexically, or did not parse.
    public var note: String?

    public init(path: String, language: String, lines: Int, targets: [String] = [], testKind: String? = nil, usedBy: OutlineUsers = OutlineUsers(),
                declarations: [OutlineDeclaration] = [], imports: [OutlineImport] = [], calls: OutlineCalls = OutlineCalls(), headings: [OutlineHeading] = [],
                note: String? = nil) {
        self.path = path
        self.language = language
        self.lines = lines
        self.targets = targets
        self.testKind = testKind
        self.usedBy = usedBy
        self.declarations = declarations
        self.imports = imports
        self.calls = calls
        self.headings = headings
        self.note = note
    }
}

/// A Markdown heading: `## File Format` at line 22 is level 2.
public struct OutlineHeading: Codable, Sendable, Hashable {
    public var line: Int
    public var level: Int
    public var text: String

    public init(line: Int, level: Int, text: String) {
        self.line = line
        self.level = level
        self.text = text
    }
}

/// Files outside the outlined code that use it: references at the use threshold, or a non-mock import.
public struct OutlineUsers: Codable, Sendable, Hashable {
    public var files: Int
    /// How many of `files` are tests.
    public var testFiles: Int

    public init(files: Int = 0, testFiles: Int = 0) {
        self.files = files
        self.testFiles = testFiles
    }
}

/// One declaration as an outline line shows it.
public struct OutlineDeclaration: Codable, Sendable, Hashable {
    public var name: String
    public var qualifiedName: String
    public var kind: SymbolKind
    public var lines: LineRange
    /// The declaration as written: attributes, modifiers, name, parameters, effects and result.
    public var signature: String?
    /// The HTTP route a Next.js handler serves (`POST /api/tokens`).
    public var route: String?
    /// The first sentence of its doc comment.
    public var doc: String?
    /// `decode(from:offset:)` for a function, initializer, subscript or enum case with associated values.
    public var selector: String?
    /// `@MainActor`, `@Published`: attributes without their arguments.
    public var attributes: [String]
    /// A `static` or `class` member.
    public var isStatic: Bool
    /// `private` or `fileprivate`; nil when the declaration is visible beyond its file.
    public var access: String?
    /// `private`, `fileprivate`: the setter's access when narrower (`private(set)`).
    public var setterAccess: String?
    /// Exported from its module (TypeScript `export`, a Python public name).
    public var isExported: Bool
    /// A property's or parameter-less declaration's type; a function's result type.
    public var type: String?
    /// A property's initial value (at most 60 characters), an enum case's raw value, a type alias's type.
    public var value: String?
    /// `async`, `throws`, `async throws`.
    public var effects: String?
    /// A function's parameter clause when no selector says it (TypeScript, Python): `(plaintext: string)`.
    public var parameters: String?
    /// The `#if` condition it is compiled under.
    public var condition: String?
    /// Its members, in line order (function-local declarations are left out).
    public var members: [OutlineDeclaration]

    public init(name: String, qualifiedName: String, kind: SymbolKind, lines: LineRange, signature: String? = nil, route: String? = nil, doc: String? = nil, selector: String? = nil,
                attributes: [String] = [], isStatic: Bool = false, access: String? = nil, setterAccess: String? = nil, isExported: Bool = false,
                type: String? = nil, value: String? = nil, effects: String? = nil, parameters: String? = nil, condition: String? = nil, members: [OutlineDeclaration] = []) {
        self.name = name
        self.qualifiedName = qualifiedName
        self.kind = kind
        self.lines = lines
        self.signature = signature
        self.route = route
        self.doc = doc
        self.selector = selector
        self.attributes = attributes
        self.isStatic = isStatic
        self.access = access
        self.setterAccess = setterAccess
        self.isExported = isExported
        self.type = type
        self.value = value
        self.effects = effects
        self.parameters = parameters
        self.condition = condition
        self.members = members
    }

    /// Members at every depth.
    public var memberCount: Int { members.reduce(members.count) { $0 + $1.memberCount } }
}

/// One import statement: the module as written, the file it resolves to in the repository, and its names.
public struct OutlineImport: Codable, Sendable, Hashable {
    public var line: Int
    public var module: String
    /// Repository-relative path when the import resolves to a file.
    public var path: String?
    public var names: [String]
    public var isTypeOnly: Bool

    public init(line: Int, module: String, path: String? = nil, names: [String] = [], isTypeOnly: Bool = false) {
        self.line = line
        self.module = module
        self.path = path
        self.names = names
        self.isTypeOnly = isTypeOnly
    }
}

/// What the outlined code calls outside itself, in order of first use.
public struct OutlineCalls: Codable, Sendable, Hashable {
    /// Declarations elsewhere in the repository: calls, initializers and static members.
    public var repository: [OutlineCall]
    /// Framework and package APIs, by module.
    public var external: [OutlineModuleCalls]
    /// Environment variables read or written.
    public var environment: [OutlineEnvironmentUse]

    public init(repository: [OutlineCall] = [], external: [OutlineModuleCalls] = [], environment: [OutlineEnvironmentUse] = []) {
        self.repository = repository
        self.external = external
        self.environment = environment
    }

    public var isEmpty: Bool { repository.isEmpty && external.isEmpty && environment.isEmpty }
}

public struct OutlineCall: Codable, Sendable, Hashable {
    /// `SHA256Checksum.digest`, `WALRecordHeader.init`, `Product.products`.
    public var name: String
    /// Where a repository callee is declared.
    public var path: String?
    /// Lines of the outlined code that call it.
    public var lines: [Int]
    /// The callee is, or belongs to, an error type (`WaxError.walCorruption`).
    public var isError: Bool

    public init(name: String, path: String? = nil, lines: [Int], isError: Bool = false) {
        self.name = name
        self.path = path
        self.lines = lines
        self.isError = isError
    }
}

public struct OutlineModuleCalls: Codable, Sendable, Hashable {
    public var module: String
    public var calls: [OutlineCall]
    /// Imported by much of the repository (Foundation, SwiftUI, the standard library): its calls say little
    /// about what this code is for.
    public var isAmbient: Bool

    public init(module: String, calls: [OutlineCall], isAmbient: Bool = false) {
        self.module = module
        self.calls = calls
        self.isAmbient = isAmbient
    }

    public var count: Int { calls.reduce(0) { $0 + $1.lines.count } }
}

public struct OutlineEnvironmentUse: Codable, Sendable, Hashable {
    public var name: String
    public var reads: [Int]
    public var writes: [Int]

    public init(name: String, reads: [Int] = [], writes: [Int] = []) {
        self.name = name
        self.reads = reads
        self.writes = writes
    }
}

/// One declaration: a type with its members and extensions, a function, or a property, case or alias with the
/// type that owns it.
public struct OutlineSymbol: Codable, Sendable, Hashable {
    public var path: String
    /// Display name of its file's language.
    public var language: String
    public var declaration: OutlineDeclaration
    /// The type (or extension) it is declared in, as `PremiumStore :12-410`.
    public var owner: String?
    public var ownerLines: LineRange?
    public var targets: [String]
    public var usedBy: OutlineUsers
    /// A type's extensions, in this file and others.
    public var extensions: [OutlineExtension]
    public var calls: OutlineCalls

    public init(path: String, language: String, declaration: OutlineDeclaration, owner: String? = nil, ownerLines: LineRange? = nil, targets: [String] = [],
                usedBy: OutlineUsers = OutlineUsers(), extensions: [OutlineExtension] = [], calls: OutlineCalls = OutlineCalls()) {
        self.path = path
        self.language = language
        self.declaration = declaration
        self.owner = owner
        self.ownerLines = ownerLines
        self.targets = targets
        self.usedBy = usedBy
        self.extensions = extensions
        self.calls = calls
    }
}

public struct OutlineExtension: Codable, Sendable, Hashable {
    public var path: String
    public var declaration: OutlineDeclaration

    public init(path: String, declaration: OutlineDeclaration) {
        self.path = path
        self.declaration = declaration
    }
}

/// A folder (or a repository module): its files with their main declarations.
public struct OutlineFolder: Codable, Sendable, Hashable {
    /// Without a trailing slash; empty for the repository root.
    public var path: String
    /// Set when the target named a module rather than a folder.
    public var module: String?
    /// Build targets of its files, with how many files each compiles.
    public var targets: [OutlineTargetCount]
    public var files: [OutlineFolderFile]

    public init(path: String, module: String? = nil, targets: [OutlineTargetCount] = [], files: [OutlineFolderFile] = []) {
        self.path = path
        self.module = module
        self.targets = targets
        self.files = files
    }

    public var lines: Int { files.reduce(0) { $0 + $1.lines } }
}

public struct OutlineTargetCount: Codable, Sendable, Hashable {
    public var name: String
    public var files: Int

    public init(name: String, files: Int) {
        self.name = name
        self.files = files
    }
}

public struct OutlineFolderFile: Codable, Sendable, Hashable {
    public var path: String
    public var lines: Int
    public var isTest: Bool
    /// Its main declarations: types first (the one named like the file first), then functions; no members.
    public var primary: [OutlineDeclaration]
    /// All its top-level declarations.
    public var declarations: Int
    public var usedBy: Int

    public init(path: String, lines: Int, isTest: Bool = false, primary: [OutlineDeclaration] = [], declarations: Int = 0, usedBy: Int = 0) {
        self.path = path
        self.lines = lines
        self.isTest = isTest
        self.primary = primary
        self.declarations = declarations
        self.usedBy = usedBy
    }
}

/// One of several declarations (or files, folders, modules) a name matches, with the exact target that selects it.
public struct OutlineChoice: Codable, Sendable, Hashable {
    public var target: String
    /// `class`, `method`, `file`, `folder`, `module`…
    public var kind: String
    /// `path:start-end` for a declaration.
    public var location: String?
    public var signature: String?
    /// References at the use threshold (importing files for a module or framework), and their files.
    public var uses: Int
    public var files: Int

    public init(target: String, kind: String, location: String? = nil, signature: String? = nil, uses: Int = 0, files: Int = 0) {
        self.target = target
        self.kind = kind
        self.location = location
        self.signature = signature
        self.uses = uses
        self.files = files
    }
}
