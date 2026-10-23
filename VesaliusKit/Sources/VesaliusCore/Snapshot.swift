import Foundation

/// An in-memory, read-only view of an indexed repository, assembled by the query engine from the index
/// and handed to graph/health analysis. Ids are database row ids and are only meaningful within one snapshot.
public struct RepositorySnapshot: Sendable {
    public struct File: Sendable, Hashable {
        public var id: Int64
        public var path: String
        /// Repository-relative directory ("" for the root).
        public var directory: String
        public var module: String?
        public var language: Language
        public var lines: Int
        public var codeLines: Int
        public var complexity: Int
        public var symbolCount: Int
        public var isTest: Bool
        public var isGenerated: Bool
        /// App entry points, CLI mains, package entry files, config files: never "unused".
        public var isEntryPoint: Bool
        /// Imported module specifiers that did not resolve to a repository file (frameworks, packages).
        public var externalImports: [String]
        public var churn: Int?

        public init(id: Int64, path: String, directory: String, module: String?, language: Language, lines: Int, codeLines: Int, complexity: Int, symbolCount: Int, isTest: Bool, isGenerated: Bool, isEntryPoint: Bool, externalImports: [String], churn: Int? = nil) {
            self.id = id
            self.path = path
            self.directory = directory
            self.module = module
            self.language = language
            self.lines = lines
            self.codeLines = codeLines
            self.complexity = complexity
            self.symbolCount = symbolCount
            self.isTest = isTest
            self.isGenerated = isGenerated
            self.isEntryPoint = isEntryPoint
            self.externalImports = externalImports
            self.churn = churn
        }

        public var fileName: String { (path as NSString).lastPathComponent }
        public var stem: String { (fileName as NSString).deletingPathExtension }
    }

    public struct Symbol: Sendable, Hashable {
        public var id: Int64
        public var fileID: Int64
        public var parentID: Int64?
        public var name: String
        public var qualifiedName: String
        public var kind: SymbolKind
        public var lines: LineRange
        public var visibility: Visibility?
        public var isExported: Bool
        public var attributes: [String]
        public var inheritedTypes: [String]
        public var complexity: Int
        public var bodyHash: UInt64?
        /// Resolved references from other symbols/files.
        public var incomingReferences: Int
        /// Distinct files referencing this symbol (excluding its own file).
        public var referencingFiles: Int

        public init(id: Int64, fileID: Int64, parentID: Int64?, name: String, qualifiedName: String, kind: SymbolKind, lines: LineRange, visibility: Visibility?, isExported: Bool, attributes: [String], inheritedTypes: [String], complexity: Int, bodyHash: UInt64?, incomingReferences: Int, referencingFiles: Int) {
            self.id = id
            self.fileID = fileID
            self.parentID = parentID
            self.name = name
            self.qualifiedName = qualifiedName
            self.kind = kind
            self.lines = lines
            self.visibility = visibility
            self.isExported = isExported
            self.attributes = attributes
            self.inheritedTypes = inheritedTypes
            self.complexity = complexity
            self.bodyHash = bodyHash
            self.incomingReferences = incomingReferences
            self.referencingFiles = referencingFiles
        }
    }

    /// A file-level dependency edge: `source` depends on `target`.
    public struct Edge: Sendable, Hashable {
        public var source: Int64
        public var target: Int64
        public var kind: EdgeKind
        public var weight: Int

        public init(source: Int64, target: Int64, kind: EdgeKind, weight: Int) {
            self.source = source
            self.target = target
            self.kind = kind
            self.weight = weight
        }
    }

    public struct Cluster: Sendable, Hashable {
        public var id: Int
        public var fileIDs: [Int64]
        public var label: String

        public init(id: Int, fileIDs: [Int64], label: String) {
            self.id = id
            self.fileIDs = fileIDs
            self.label = label
        }
    }

    public var repositoryName: String
    public var files: [File]
    public var symbols: [Symbol]
    public var edges: [Edge]
    public var modules: [ModuleInfo]
    /// Per-file graph metrics keyed by file id (computed by GraphEngine).
    public var metrics: [Int64: FileGraphMetrics]
    /// Strongly connected components with more than one file (dependency cycles), as file ids.
    public var cycles: [[Int64]]
    /// Community-detection clusters over the file graph.
    public var clusters: [Cluster]
    /// Manifest-level facts: dependency names from Package.swift, package.json, requirements, Podfile...
    public var manifestDependencies: [String]

    public init(repositoryName: String, files: [File], symbols: [Symbol], edges: [Edge], modules: [ModuleInfo], metrics: [Int64: FileGraphMetrics], cycles: [[Int64]], clusters: [Cluster], manifestDependencies: [String]) {
        self.repositoryName = repositoryName
        self.files = files
        self.symbols = symbols
        self.edges = edges
        self.modules = modules
        self.metrics = metrics
        self.cycles = cycles
        self.clusters = clusters
        self.manifestDependencies = manifestDependencies
    }
}
