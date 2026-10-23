import Foundation

/// Circular import dependencies in a scope: strongly connected components of the import graph
/// only (a reference between two files is not an import), each import with its statement, names, flags and the
/// uses that make it a runtime dependency, plus what was scanned, so "no other cycle" needs no re-scan.
///
/// Swift files in one module see each other without imports, so for Swift only the module import graph is
/// checked. The reference-level cycles of `DependencyCycle` (health, the app) are a different, larger notion.
public struct ImportCycleReport: Codable, Sendable, Hashable {
    public var scope: ImportCycleScope
    /// Largest first.
    public var cycles: [ImportCycle]
    /// Components of the whole repository's import graph that hold files in the scope and files outside it.
    /// They are not cycles of the scope, but a cycle question about the folder may care.
    public var crossingCycles: Int
    /// The module import graph of the Swift files in scope; nil when there are none.
    public var swiftModules: SwiftModuleImports?
    /// Cycle files edited since indexing: their import lines and uses may have moved.
    public var staleFiles: [String]

    public init(scope: ImportCycleScope, cycles: [ImportCycle], crossingCycles: Int = 0, swiftModules: SwiftModuleImports? = nil, staleFiles: [String] = []) {
        self.scope = scope
        self.cycles = cycles
        self.crossingCycles = crossingCycles
        self.swiftModules = swiftModules
        self.staleFiles = staleFiles
    }
}

/// What a cycle check covered.
public struct ImportCycleScope: Codable, Sendable, Hashable {
    /// The folder (no trailing slash), or a file whose cycles were asked for; nil for the whole repository.
    public var path: String?
    /// True when `path` is a file: the repository was checked and only cycles through it are listed.
    public var isFile: Bool
    public var includeTests: Bool
    /// Source files in scope.
    public var files: Int
    /// Test files left out of the graph (0 when tests are included).
    public var testFilesExcluded: Int
    /// Import statements from a file in scope to another file in scope.
    public var edges: Int
    /// `edges` by the importing file's language (display name).
    public var edgeLanguages: [String: Int]
    /// Relative, path-alias and package imports in scope that resolve to no file.
    public var unresolved: Int
    /// The first few of them.
    public var unresolvedSites: [ImportSite]
    /// Imports from a file in scope to a file outside it (not edges of this graph).
    public var leavingScope: Int
    /// How many of `edges` are `import type` / `export type`, re-exports, dynamic `import()` or `require` inside a
    /// function, and side-effect-only imports. All of them are counted as edges.
    public var typeOnly: Int
    public var reexports: Int
    public var dynamic: Int
    public var sideEffect: Int
    /// `vi.mock` / `jest.mock` imports in scope: never edges.
    public var mocks: Int

    public init(path: String?, isFile: Bool = false, includeTests: Bool, files: Int, testFilesExcluded: Int, edges: Int, edgeLanguages: [String: Int] = [:], unresolved: Int, unresolvedSites: [ImportSite] = [], leavingScope: Int = 0, typeOnly: Int = 0, reexports: Int = 0, dynamic: Int = 0, sideEffect: Int = 0, mocks: Int = 0) {
        self.path = path
        self.isFile = isFile
        self.includeTests = includeTests
        self.files = files
        self.testFilesExcluded = testFilesExcluded
        self.edges = edges
        self.edgeLanguages = edgeLanguages
        self.unresolved = unresolved
        self.unresolvedSites = unresolvedSites
        self.leavingScope = leavingScope
        self.typeOnly = typeOnly
        self.reexports = reexports
        self.dynamic = dynamic
        self.sideEffect = sideEffect
        self.mocks = mocks
    }
}

/// An import statement's place: `src/a.ts:3` importing `"./missing"`.
public struct ImportSite: Codable, Sendable, Hashable {
    public var path: String
    public var line: Int
    public var module: String

    public init(path: String, line: Int, module: String) {
        self.path = path
        self.line = line
        self.module = module
    }
}

/// One strongly connected component of the import graph: every file in it reaches every other through imports.
public struct ImportCycle: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// Member files, sorted.
    public var files: [String]
    /// A shortest closed walk through the first file, e.g. `[a, b, a]`.
    public var path: [String]
    /// Every import statement between member files: the walk's hops first, in walk order.
    public var edges: [ImportCycleEdge]
    /// Uses of an imported binding while a member module is being evaluated. Empty: load-time safe.
    public var loadTimeUses: [ImportLoadUse]
    /// The components among these files when only value imports count (type-only and elided imports dropped),
    /// and when dynamic imports are dropped too. Equal to `[files]` when the cycle is the same in that mode.
    public var valueOnly: [[String]]
    public var staticOnly: [[String]]
    /// Files outside the cycle that re-export from its members.
    public var barrels: [ImportBarrel]

    public init(id: Int, files: [String], path: [String], edges: [ImportCycleEdge], loadTimeUses: [ImportLoadUse] = [], valueOnly: [[String]], staticOnly: [[String]], barrels: [ImportBarrel] = []) {
        self.id = id
        self.files = files
        self.path = path
        self.edges = edges
        self.loadTimeUses = loadTimeUses
        self.valueOnly = valueOnly
        self.staticOnly = staticOnly
        self.barrels = barrels
    }

    public var isLoadTimeSafe: Bool { loadTimeUses.isEmpty }
}

/// One import statement inside a cycle.
public struct ImportCycleEdge: Codable, Sendable, Hashable {
    public var from: String
    public var to: String
    public var line: Int
    public var endLine: Int
    /// The statement as written, comments dropped and whitespace collapsed; nil when the file can't be read.
    public var statement: String?
    /// The specifier as written (`./groups`, `@/lib/cache`, `.models`).
    public var module: String
    public var names: [ImportedName]
    /// `import type` / `export type`: erased at compile time.
    public var isTypeOnly: Bool
    public var isReexport: Bool
    /// `import()`, or `require` / a Python import inside a function: loaded when that code runs.
    public var isDynamic: Bool
    /// Imports nothing by name, loaded for its side effects (`import "./polyfill"`).
    public var isSideEffect: Bool
    /// Loads `to` when `from` runs. False for type-only imports and for TypeScript imports whose names are used
    /// only as types (the compiler elides them).
    public var isValue: Bool
    /// Uses in `from` of declarations in `to`, in line order.
    public var uses: [ImportUse]
    /// Where the used or imported names are declared in `to`.
    public var definitions: [ImportDefinition]

    public init(from: String, to: String, line: Int, endLine: Int, statement: String?, module: String, names: [ImportedName], isTypeOnly: Bool, isReexport: Bool, isDynamic: Bool, isSideEffect: Bool, isValue: Bool, uses: [ImportUse] = [], definitions: [ImportDefinition] = []) {
        self.from = from
        self.to = to
        self.line = line
        self.endLine = endLine
        self.statement = statement
        self.module = module
        self.names = names
        self.isTypeOnly = isTypeOnly
        self.isReexport = isReexport
        self.isDynamic = isDynamic
        self.isSideEffect = isSideEffect
        self.isValue = isValue
        self.uses = uses
        self.definitions = definitions
    }
}

/// A use of an imported declaration: `listInvoices` called at line 188 in `resolveOrderInvoiceMap`.
public struct ImportUse: Codable, Sendable, Hashable {
    /// The declaration used (its name in the imported file).
    public var name: String
    public var line: Int
    public var kind: ReferenceKind
    /// The declaration the use sits in; nil at module top level.
    public var enclosing: String?
    public var enclosingIsCallable: Bool
    /// Runs while the importing module is evaluated: at top level, in a static initializer, decorator or
    /// `extends` clause, or inside a same-file function or class that runs there.
    public var atLoad: Bool
    /// The same-file function or class that is run at load and leads to this use (`via`), when it is not direct.
    public var via: String?

    public init(name: String, line: Int, kind: ReferenceKind, enclosing: String?, enclosingIsCallable: Bool, atLoad: Bool, via: String? = nil) {
        self.name = name
        self.line = line
        self.kind = kind
        self.enclosing = enclosing
        self.enclosingIsCallable = enclosingIsCallable
        self.atLoad = atLoad
        self.via = via
    }

    /// Only types are named: no runtime dependency.
    public var isTypeUse: Bool { kind == .typeUse || kind == .conform }
}

/// Where an imported name is declared in the imported file.
public struct ImportDefinition: Codable, Sendable, Hashable {
    public var name: String
    public var line: Int

    public init(name: String, line: Int) {
        self.name = name
        self.line = line
    }
}

/// A use of a cycle member's binding while another member loads: the binding may not be initialized yet,
/// depending on which module of the cycle is imported first.
public struct ImportLoadUse: Codable, Sendable, Hashable {
    public var path: String
    public var line: Int
    public var name: String
    public var enclosing: String?
    /// The same-file function or class run at load that leads to the use; nil when the use itself is at load.
    public var via: String?
    /// Python `from m import name`: the name is read when the statement runs.
    public var isFromImport: Bool

    public init(path: String, line: Int, name: String, enclosing: String? = nil, via: String? = nil, isFromImport: Bool = false) {
        self.path = path
        self.line = line
        self.name = name
        self.enclosing = enclosing
        self.via = via
        self.isFromImport = isFromImport
    }
}

/// A file outside a cycle that re-exports from members of it (`shop/index.ts`).
public struct ImportBarrel: Codable, Sendable, Hashable {
    public var path: String
    /// The members it re-exports from, sorted.
    public var members: [String]
    public var lines: [Int]

    public init(path: String, members: [String], lines: [Int]) {
        self.path = path
        self.members = members
        self.lines = lines
    }
}

/// Swift imports name modules (build targets), not files.
public struct SwiftModuleImports: Codable, Sendable, Hashable {
    /// Modules with Swift files in scope, plus repository modules they import.
    public var modules: Int
    /// Distinct module → module dependencies, and the `import` lines behind them.
    public var dependencies: Int
    public var importLines: Int
    /// Strongly connected components of the module graph (module names), largest first.
    public var cycles: [[String]]
    /// For each module cycle, one import line per dependency inside it.
    public var cycleImports: [[ImportSite]]

    public init(modules: Int, dependencies: Int, importLines: Int, cycles: [[String]] = [], cycleImports: [[ImportSite]] = []) {
        self.modules = modules
        self.dependencies = dependencies
        self.importLines = importLines
        self.cycles = cycles
        self.cycleImports = cycleImports
    }
}
