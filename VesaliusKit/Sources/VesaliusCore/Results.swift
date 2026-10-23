import Foundation

// Result types returned by the query engine and shared by the app, the CLI (`--json`) and the MCP server.
// Optional fields are omitted from JSON when nil to keep agent-facing output small.

// MARK: - Repository

public struct RepositoryInfo: Codable, Sendable, Hashable {
    public var name: String
    public var path: String
    public var isGitRepository: Bool
    public var branch: String?
    public var headCommit: String?
    public var remoteURL: String?

    public init(name: String, path: String, isGitRepository: Bool, branch: String? = nil, headCommit: String? = nil, remoteURL: String? = nil) {
        self.name = name
        self.path = path
        self.isGitRepository = isGitRepository
        self.branch = branch
        self.headCommit = headCommit
        self.remoteURL = remoteURL
    }
}

public struct RepositoryStats: Codable, Sendable, Hashable {
    public var files: Int = 0
    public var sourceFiles: Int = 0
    public var testFiles: Int = 0
    public var directories: Int = 0
    public var lines: Int = 0
    public var codeLines: Int = 0
    public var symbols: Int = 0
    public var types: Int = 0
    public var functions: Int = 0
    public var modules: Int = 0
    public var dependencies: Int = 0
    public var references: Int = 0
    public var externalModules: Int = 0
    public var parseFailures: Int = 0

    public init() {}
}

public struct LanguageStat: Codable, Sendable, Hashable, Identifiable {
    public var language: Language
    public var files: Int
    public var lines: Int
    public var share: Double

    public var id: Language { language }

    public init(language: Language, files: Int, lines: Int, share: Double) {
        self.language = language
        self.files = files
        self.lines = lines
        self.share = share
    }
}

public struct RepositoryStatus: Codable, Sendable {
    public var repository: RepositoryInfo
    public var indexPath: String
    public var isIndexed: Bool
    public var lastIndexed: Date?
    public var indexDurationSeconds: Double?
    public var schemaVersion: Int
    public var stats: RepositoryStats
    public var staleFiles: Int?
    public var embeddings: Int?
    /// Third-party projects inside the repository that were skipped.
    public var vendoredDirectories: [String]?

    public init(repository: RepositoryInfo, indexPath: String, isIndexed: Bool, lastIndexed: Date?, indexDurationSeconds: Double?, schemaVersion: Int, stats: RepositoryStats, staleFiles: Int? = nil, embeddings: Int? = nil, vendoredDirectories: [String]? = nil) {
        self.repository = repository
        self.indexPath = indexPath
        self.isIndexed = isIndexed
        self.lastIndexed = lastIndexed
        self.indexDurationSeconds = indexDurationSeconds
        self.schemaVersion = schemaVersion
        self.stats = stats
        self.staleFiles = staleFiles
        self.embeddings = embeddings
        self.vendoredDirectories = vendoredDirectories
    }
}

// MARK: - Files & symbols

public struct FileSummary: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var language: Language
    public var size: Int
    public var lines: Int
    public var codeLines: Int
    public var symbols: Int
    public var complexity: Int
    public var fanIn: Int
    public var fanOut: Int
    public var centrality: Double
    public var risk: Double
    public var churn: Int?
    public var diagnostics: Int
    public var isTest: Bool
    public var isGenerated: Bool
    public var module: String?
    public var parseStatus: String?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var directory: String { (path as NSString).deletingLastPathComponent }

    public init(path: String, language: Language, size: Int, lines: Int, codeLines: Int, symbols: Int, complexity: Int, fanIn: Int, fanOut: Int, centrality: Double, risk: Double, churn: Int?, diagnostics: Int, isTest: Bool, isGenerated: Bool, module: String?, parseStatus: String?) {
        self.path = path
        self.language = language
        self.size = size
        self.lines = lines
        self.codeLines = codeLines
        self.symbols = symbols
        self.complexity = complexity
        self.fanIn = fanIn
        self.fanOut = fanOut
        self.centrality = centrality
        self.risk = risk
        self.churn = churn
        self.diagnostics = diagnostics
        self.isTest = isTest
        self.isGenerated = isGenerated
        self.module = module
        self.parseStatus = parseStatus
    }
}

public struct SymbolSummary: Codable, Sendable, Hashable, Identifiable {
    /// Stable id: `sym:<path>#<qualifiedName>`.
    public var id: String
    public var name: String
    public var qualifiedName: String
    public var kind: SymbolKind
    public var path: String
    public var lines: LineRange
    public var signature: String?
    public var doc: String?
    public var visibility: Visibility?
    public var isExported: Bool?
    /// Number of resolved references to this symbol across the repository.
    public var references: Int?
    public var depth: Int?

    public init(id: String, name: String, qualifiedName: String, kind: SymbolKind, path: String, lines: LineRange, signature: String? = nil, doc: String? = nil, visibility: Visibility? = nil, isExported: Bool? = nil, references: Int? = nil, depth: Int? = nil) {
        self.id = id
        self.name = name
        self.qualifiedName = qualifiedName
        self.kind = kind
        self.path = path
        self.lines = lines
        self.signature = signature
        self.doc = doc
        self.visibility = visibility
        self.isExported = isExported
        self.references = references
        self.depth = depth
    }
}

public struct SymbolHit: Codable, Sendable, Hashable, Identifiable {
    public var symbol: SymbolSummary
    public var score: Double
    public var id: String { symbol.id }

    public init(symbol: SymbolSummary, score: Double) {
        self.symbol = symbol
        self.score = score
    }
}

public struct FileHit: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var language: Language
    public var score: Double
    public var reason: String?
    public var id: String { path }

    public init(path: String, language: Language, score: Double, reason: String? = nil) {
        self.path = path
        self.language = language
        self.score = score
        self.reason = reason
    }
}

public struct ImportSummary: Codable, Sendable, Hashable {
    public var module: String
    public var line: Int
    public var resolvedPath: String?
    public var isExternal: Bool
    public var names: [String]?

    public init(module: String, line: Int, resolvedPath: String?, isExternal: Bool, names: [String]? = nil) {
        self.module = module
        self.line = line
        self.resolvedPath = resolvedPath
        self.isExternal = isExternal
        self.names = names
    }
}

/// A file related to another file through dependency edges.
public struct FileRelation: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var kinds: [EdgeKind]
    public var weight: Int
    /// Symbol names involved in the relationship (what is used).
    public var symbols: [String]?
    /// Hops from the origin (1 = direct).
    public var distance: Int?

    public var id: String { path }

    public init(path: String, kinds: [EdgeKind], weight: Int, symbols: [String]? = nil, distance: Int? = nil) {
        self.path = path
        self.kinds = kinds
        self.weight = weight
        self.symbols = symbols
        self.distance = distance
    }
}

public struct ReferenceSite: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var line: Int
    public var kind: ReferenceKind
    /// Qualified name of the enclosing symbol at the use site.
    public var from: String?
    public var snippet: String?
    public var count: Int?

    public var id: String { "\(path):\(line):\(kind.rawValue):\(from ?? "")" }

    public init(path: String, line: Int, kind: ReferenceKind, from: String? = nil, snippet: String? = nil, count: Int? = nil) {
        self.path = path
        self.line = line
        self.kind = kind
        self.from = from
        self.snippet = snippet
        self.count = count
    }
}

public struct ReferencesResult: Codable, Sendable {
    public var query: String
    /// The symbols the query resolved to (several when the name is ambiguous).
    public var symbols: [SymbolSummary]
    public var references: [ReferenceSite]
    public var total: Int
    /// Unresolved uses of the name (e.g. external API usage) when no repository symbol matched.
    public var textualMatches: [ReferenceSite]?

    public init(query: String, symbols: [SymbolSummary], references: [ReferenceSite], total: Int, textualMatches: [ReferenceSite]? = nil) {
        self.query = query
        self.symbols = symbols
        self.references = references
        self.total = total
        self.textualMatches = textualMatches
    }
}

public struct CallRelation: Codable, Sendable, Hashable, Identifiable {
    public var symbol: SymbolSummary
    public var sites: [Int]
    public var count: Int
    public var id: String { symbol.id }

    public init(symbol: SymbolSummary, sites: [Int], count: Int) {
        self.symbol = symbol
        self.sites = sites
        self.count = count
    }
}

public struct CallGraphResult: Codable, Sendable {
    public var query: String
    public var direction: String
    public var symbols: [SymbolSummary]
    public var relations: [CallRelation]

    public init(query: String, direction: String, symbols: [SymbolSummary], relations: [CallRelation]) {
        self.query = query
        self.direction = direction
        self.symbols = symbols
        self.relations = relations
    }
}

public struct DependencyResult: Codable, Sendable {
    public var target: String
    public var direction: String
    public var depth: Int
    public var files: [FileRelation]
    public var externalModules: [String]?
    public var total: Int

    public init(target: String, direction: String, depth: Int, files: [FileRelation], externalModules: [String]? = nil, total: Int) {
        self.target = target
        self.direction = direction
        self.depth = depth
        self.files = files
        self.externalModules = externalModules
        self.total = total
    }
}

// MARK: - Graph metrics

public struct FileGraphMetrics: Codable, Sendable, Hashable {
    public var fanIn: Int = 0
    public var fanOut: Int = 0
    /// PageRank normalised so the most central file is 1.0.
    public var centrality: Double = 0
    public var transitiveDependents: Int = 0
    public var transitiveDependencies: Int = 0
    /// Length of the longest dependency chain starting at this file.
    public var depth: Int = 0
    public var cycleID: Int?
    public var cycleSize: Int?
    public var clusterID: Int?
    /// Commits touching the file in the last year (git), when available.
    public var churn: Int?
    /// Change risk 0–1.
    public var risk: Double = 0

    public init() {}
}

// MARK: - Context

public struct RelatedFile: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var score: Double
    public var reason: String
    public var id: String { path }

    public init(path: String, score: Double, reason: String) {
        self.path = path
        self.score = score
        self.reason = reason
    }
}

public struct FileContext: Codable, Sendable {
    public var file: FileSummary
    public var symbols: [SymbolSummary]
    public var imports: [ImportSummary]
    public var dependencies: [FileRelation]
    public var dependents: [FileRelation]
    public var metrics: FileGraphMetrics
    public var diagnostics: [Diagnostic]
    public var related: [RelatedFile]
    public var impact: ImpactSummary

    public init(file: FileSummary, symbols: [SymbolSummary], imports: [ImportSummary], dependencies: [FileRelation], dependents: [FileRelation], metrics: FileGraphMetrics, diagnostics: [Diagnostic], related: [RelatedFile], impact: ImpactSummary) {
        self.file = file
        self.symbols = symbols
        self.imports = imports
        self.dependencies = dependencies
        self.dependents = dependents
        self.metrics = metrics
        self.diagnostics = diagnostics
        self.related = related
        self.impact = impact
    }
}

public struct SymbolContext: Codable, Sendable {
    public var symbol: SymbolSummary
    public var parent: SymbolSummary?
    public var members: [SymbolSummary]
    public var references: [ReferenceSite]
    public var callers: [CallRelation]
    public var callees: [CallRelation]
    public var diagnostics: [Diagnostic]
    public var impact: ImpactSummary

    public init(symbol: SymbolSummary, parent: SymbolSummary?, members: [SymbolSummary], references: [ReferenceSite], callers: [CallRelation], callees: [CallRelation], diagnostics: [Diagnostic], impact: ImpactSummary) {
        self.symbol = symbol
        self.parent = parent
        self.members = members
        self.references = references
        self.callers = callers
        self.callees = callees
        self.diagnostics = diagnostics
        self.impact = impact
    }
}

// MARK: - Impact

public enum RiskLevel: String, Codable, Sendable, Comparable {
    case low, moderate, high, critical

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        let order: [RiskLevel] = [.low, .moderate, .high, .critical]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    public static func from(score: Double) -> RiskLevel {
        switch score {
        case ..<25: .low
        case ..<50: .moderate
        case ..<75: .high
        default: .critical
        }
    }
}

public struct ScoreFactor: Codable, Sendable, Hashable, Identifiable {
    public var label: String
    public var detail: String
    /// Contribution in score points (negative = penalty for health scores, positive = added risk for risk scores).
    public var impact: Double
    public var value: Double?

    public var id: String { label + detail }

    public init(label: String, detail: String, impact: Double, value: Double? = nil) {
        self.label = label
        self.detail = detail
        self.impact = impact
        self.value = value
    }
}

public struct ImpactSummary: Codable, Sendable, Hashable {
    public var directDependents: Int
    public var transitiveDependents: Int
    public var relatedTests: Int
    public var riskScore: Double
    public var riskLevel: RiskLevel

    public init(directDependents: Int, transitiveDependents: Int, relatedTests: Int, riskScore: Double, riskLevel: RiskLevel) {
        self.directDependents = directDependents
        self.transitiveDependents = transitiveDependents
        self.relatedTests = relatedTests
        self.riskScore = riskScore
        self.riskLevel = riskLevel
    }
}

public struct AffectedArea: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var files: Int
    public var id: String { name }

    public init(name: String, files: Int) {
        self.name = name
        self.files = files
    }
}

public struct ImpactReport: Codable, Sendable {
    public var target: String
    public var targetKind: String
    public var symbols: [SymbolSummary]?
    public var directDependents: [FileRelation]
    public var transitiveDependents: [FileRelation]
    public var callers: [ReferenceSite]
    public var relatedTests: [String]
    public var affectedAreas: [AffectedArea]
    public var riskScore: Double
    public var riskLevel: RiskLevel
    public var factors: [ScoreFactor]
    public var summary: String

    public init(target: String, targetKind: String, symbols: [SymbolSummary]?, directDependents: [FileRelation], transitiveDependents: [FileRelation], callers: [ReferenceSite], relatedTests: [String], affectedAreas: [AffectedArea], riskScore: Double, riskLevel: RiskLevel, factors: [ScoreFactor], summary: String) {
        self.target = target
        self.targetKind = targetKind
        self.symbols = symbols
        self.directDependents = directDependents
        self.transitiveDependents = transitiveDependents
        self.callers = callers
        self.relatedTests = relatedTests
        self.affectedAreas = affectedAreas
        self.riskScore = riskScore
        self.riskLevel = riskLevel
        self.factors = factors
        self.summary = summary
    }
}

// MARK: - Search / ask

public struct AskSymbol: Codable, Sendable, Hashable {
    public var name: String
    public var kind: SymbolKind
    public var lines: LineRange

    public init(name: String, kind: SymbolKind, lines: LineRange) {
        self.name = name
        self.kind = kind
        self.lines = lines
    }
}

public struct AskFile: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var relevance: Double
    public var reason: String
    public var symbols: [AskSymbol]
    public var lines: LineRange?
    public var dependents: Int?
    public var dependencies: Int?

    public var id: String { path }

    public init(path: String, relevance: Double, reason: String, symbols: [AskSymbol], lines: LineRange? = nil, dependents: Int? = nil, dependencies: Int? = nil) {
        self.path = path
        self.relevance = relevance
        self.reason = reason
        self.symbols = symbols
        self.lines = lines
        self.dependents = dependents
        self.dependencies = dependencies
    }
}

public struct AskResult: Codable, Sendable {
    public var query: String
    /// What the engine understood the question as (`search`, `references`, `dependents`, `impact`, …).
    public var intent: String
    public var answer: String
    public var terms: [String]
    public var files: [AskFile]
    public var related: [RelatedFile]?
    public var confidence: Double

    public init(query: String, intent: String, answer: String, terms: [String], files: [AskFile], related: [RelatedFile]?, confidence: Double) {
        self.query = query
        self.intent = intent
        self.answer = answer
        self.terms = terms
        self.files = files
        self.related = related
        self.confidence = confidence
    }
}

/// Mixed results for the command palette.
public struct UnifiedSearchResults: Codable, Sendable {
    public var query: String
    public var files: [FileHit]
    public var symbols: [SymbolHit]
    public var diagnostics: [Diagnostic]
    public var concepts: [ArchitecturePattern]

    public init(query: String, files: [FileHit], symbols: [SymbolHit], diagnostics: [Diagnostic], concepts: [ArchitecturePattern]) {
        self.query = query
        self.files = files
        self.symbols = symbols
        self.diagnostics = diagnostics
        self.concepts = concepts
    }
}

// MARK: - Health

public enum HealthCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case modularity
    case coupling
    case complexity
    case cycles
    case organization
    case boundaries
    case maintainability
    case deadCode = "dead-code"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .modularity: "Modularity"
        case .coupling: "Coupling"
        case .complexity: "Complexity"
        case .cycles: "Cycles"
        case .organization: "File Organization"
        case .boundaries: "Dependency Boundaries"
        case .maintainability: "Maintainability"
        case .deadCode: "Dead Code Signals"
        }
    }

    public var explanation: String {
        switch self {
        case .modularity: "How well the code separates into cohesive groups with few cross-group dependencies."
        case .coupling: "How many dependencies files carry and receive; high fan-in/fan-out makes changes ripple."
        case .complexity: "Size and branching of files, types and functions."
        case .cycles: "Circular dependencies between files, which prevent independent change and testing."
        case .organization: "Directory structure: dumping-ground folders, scattered features, misplaced files."
        case .boundaries: "Whether dependencies flow in a consistent direction between layers and modules."
        case .maintainability: "Duplicate-looking code, oversized UI/controller files and mixed responsibilities."
        case .deadCode: "Files and symbols with no detected references."
        }
    }
}

public struct DiagnosticTarget: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case file, symbol, directory, module }
    public var kind: Kind
    public var path: String
    public var symbol: String?
    public var line: Int?

    public init(kind: Kind, path: String, symbol: String? = nil, line: Int? = nil) {
        self.kind = kind
        self.path = path
        self.symbol = symbol
        self.line = line
    }
}

public struct DiagnosticMetric: Codable, Sendable, Hashable {
    public var name: String
    public var value: Double
    public var threshold: Double?
    public var unit: String?

    public init(name: String, value: Double, threshold: Double? = nil, unit: String? = nil) {
        self.name = name
        self.value = value
        self.threshold = threshold
        self.unit = unit
    }

    public var formattedValue: String {
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
        return unit.map { "\(number) \($0)" } ?? number
    }
}

public struct Diagnostic: Codable, Sendable, Hashable, Identifiable {
    /// Stable fingerprint (rule + targets) so diagnostics keep identity across re-indexing.
    public var id: String
    public var rule: String
    public var category: HealthCategory
    public var severity: Severity
    public var title: String
    public var summary: String
    public var reason: String
    public var recommendation: String
    public var targets: [DiagnosticTarget]
    public var metrics: [DiagnosticMetric]

    public init(id: String, rule: String, category: HealthCategory, severity: Severity, title: String, summary: String, reason: String, recommendation: String, targets: [DiagnosticTarget], metrics: [DiagnosticMetric]) {
        self.id = id
        self.rule = rule
        self.category = category
        self.severity = severity
        self.title = title
        self.summary = summary
        self.reason = reason
        self.recommendation = recommendation
        self.targets = targets
        self.metrics = metrics
    }

    /// Builds a deterministic id from the rule and target paths.
    public static func fingerprint(rule: String, targets: [DiagnosticTarget]) -> String {
        var hasher = FNV1a()
        hasher.combine(rule)
        for target in targets.sorted(by: { ($0.path, $0.symbol ?? "") < ($1.path, $1.symbol ?? "") }) {
            hasher.combine(target.kind.rawValue)
            hasher.combine(target.path)
            hasher.combine(target.symbol ?? "")
        }
        return "\(rule)-\(String(hasher.value, radix: 36))"
    }
}

public struct CategoryScore: Codable, Sendable, Hashable, Identifiable {
    public var category: HealthCategory
    public var score: Int
    public var weight: Double
    public var summary: String
    public var factors: [ScoreFactor]

    public var id: HealthCategory { category }

    public init(category: HealthCategory, score: Int, weight: Double, summary: String, factors: [ScoreFactor]) {
        self.category = category
        self.score = score
        self.weight = weight
        self.summary = summary
        self.factors = factors
    }
}

public struct HealthReport: Codable, Sendable, Hashable {
    public var score: Int
    public var grade: String
    public var summary: String
    public var categories: [CategoryScore]
    public var diagnosticCounts: [String: Int]

    public init(score: Int, grade: String, summary: String, categories: [CategoryScore], diagnosticCounts: [String: Int]) {
        self.score = score
        self.grade = grade
        self.summary = summary
        self.categories = categories
        self.diagnosticCounts = diagnosticCounts
    }

    public static let empty = HealthReport(score: 0, grade: "Unknown", summary: "Not analysed yet.", categories: [], diagnosticCounts: [:])

    public static func grade(for score: Int) -> String {
        switch score {
        case 85...: "Healthy"
        case 70..<85: "Stable"
        case 55..<70: "Strained"
        case 40..<55: "Fragile"
        default: "Critical"
        }
    }
}

// MARK: - Architecture

public struct ArchitecturePattern: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    /// 0–1.
    public var confidence: Double
    public var evidence: [String]
    public var paths: [String]?

    public var id: String { name }

    public var label: String {
        switch confidence {
        case 0.75...: "Likely \(name)"
        case 0.45..<0.75: "Possibly \(name)"
        default: "Traces of \(name)"
        }
    }

    public init(name: String, confidence: Double, evidence: [String], paths: [String]? = nil) {
        self.name = name
        self.confidence = confidence
        self.evidence = evidence
        self.paths = paths
    }
}

public struct ArchitectureLayer: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var paths: [String]
    public var files: Int
    public var dependsOn: [String]

    public var id: String { name }

    public init(name: String, paths: [String], files: Int, dependsOn: [String]) {
        self.name = name
        self.paths = paths
        self.files = files
        self.dependsOn = dependsOn
    }
}

public struct FeatureArea: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var files: Int
    public var lines: Int
    public var primaryLanguage: Language?
    public var dependsOn: [String]
    public var dependents: [String]

    public var id: String { path }

    public init(name: String, path: String, files: Int, lines: Int, primaryLanguage: Language?, dependsOn: [String], dependents: [String]) {
        self.name = name
        self.path = path
        self.files = files
        self.lines = lines
        self.primaryLanguage = primaryLanguage
        self.dependsOn = dependsOn
        self.dependents = dependents
    }
}

public struct ArchitectureReport: Codable, Sendable, Hashable {
    public var summary: String
    public var patterns: [ArchitecturePattern]
    public var frameworks: [String]
    public var layers: [ArchitectureLayer]
    public var areas: [FeatureArea]
    public var entryPoints: [String]

    public init(summary: String, patterns: [ArchitecturePattern], frameworks: [String], layers: [ArchitectureLayer], areas: [FeatureArea], entryPoints: [String]) {
        self.summary = summary
        self.patterns = patterns
        self.frameworks = frameworks
        self.layers = layers
        self.areas = areas
        self.entryPoints = entryPoints
    }

    public static let empty = ArchitectureReport(summary: "Not analysed yet.", patterns: [], frameworks: [], layers: [], areas: [], entryPoints: [])
}

public struct ExtractionSuggestion: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var rootPath: String?
    public var files: [String]
    public var lines: Int
    public var internalDependencies: Int
    public var externalDependencies: Int
    public var externalDependents: Int
    /// Share of the group's dependency edges that stay inside the group (0–1).
    public var cohesion: Double
    public var entryPoints: [String]
    public var score: Double
    public var reasons: [String]
    public var benefits: [String]
    public var risks: [String]

    public var id: String { name + (rootPath ?? "") }

    public init(name: String, rootPath: String?, files: [String], lines: Int, internalDependencies: Int, externalDependencies: Int, externalDependents: Int, cohesion: Double, entryPoints: [String], score: Double, reasons: [String], benefits: [String], risks: [String]) {
        self.name = name
        self.rootPath = rootPath
        self.files = files
        self.lines = lines
        self.internalDependencies = internalDependencies
        self.externalDependencies = externalDependencies
        self.externalDependents = externalDependents
        self.cohesion = cohesion
        self.entryPoints = entryPoints
        self.score = score
        self.reasons = reasons
        self.benefits = benefits
        self.risks = risks
    }
}

/// Complete output of the health engine for one index snapshot.
public struct HealthAnalysis: Codable, Sendable {
    public var report: HealthReport
    public var diagnostics: [Diagnostic]
    public var architecture: ArchitectureReport
    public var suggestions: [ExtractionSuggestion]
    public var unused: UnusedReport

    public init(report: HealthReport, diagnostics: [Diagnostic], architecture: ArchitectureReport, suggestions: [ExtractionSuggestion], unused: UnusedReport) {
        self.report = report
        self.diagnostics = diagnostics
        self.architecture = architecture
        self.suggestions = suggestions
        self.unused = unused
    }
}

// MARK: - Hotspots, cycles, unused

public struct Hotspot: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var score: Double
    public var lines: Int
    public var complexity: Int
    public var fanIn: Int
    public var fanOut: Int
    public var churn: Int?
    public var diagnostics: Int
    public var reasons: [String]

    public var id: String { path }

    public init(path: String, score: Double, lines: Int, complexity: Int, fanIn: Int, fanOut: Int, churn: Int?, diagnostics: Int, reasons: [String]) {
        self.path = path
        self.score = score
        self.lines = lines
        self.complexity = complexity
        self.fanIn = fanIn
        self.fanOut = fanOut
        self.churn = churn
        self.diagnostics = diagnostics
        self.reasons = reasons
    }
}

public struct DependencyCycle: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var files: [String]
    /// One concrete closed path through the cycle, e.g. `a → b → c → a`.
    public var path: [String]
    public var edges: Int

    public init(id: Int, files: [String], path: [String], edges: Int) {
        self.id = id
        self.files = files
        self.path = path
        self.edges = edges
    }
}

public struct UnusedItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case file, symbol }
    public var kind: Kind
    public var path: String
    public var symbol: String?
    public var symbolKind: SymbolKind?
    public var line: Int?
    public var lines: Int?
    public var confidence: Double
    public var reason: String

    public var id: String { "\(kind.rawValue):\(path)#\(symbol ?? "")" }

    public init(kind: Kind, path: String, symbol: String? = nil, symbolKind: SymbolKind? = nil, line: Int? = nil, lines: Int? = nil, confidence: Double, reason: String) {
        self.kind = kind
        self.path = path
        self.symbol = symbol
        self.symbolKind = symbolKind
        self.line = line
        self.lines = lines
        self.confidence = confidence
        self.reason = reason
    }
}

public struct UnusedReport: Codable, Sendable {
    public var files: [UnusedItem]
    public var symbols: [UnusedItem]
    public var note: String

    public init(files: [UnusedItem], symbols: [UnusedItem], note: String) {
        self.files = files
        self.symbols = symbols
        self.note = note
    }
}

// MARK: - Overview

public struct RankedFile: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var value: Double
    public var detail: String
    public var id: String { path }

    public init(path: String, value: Double, detail: String) {
        self.path = path
        self.value = value
        self.detail = detail
    }
}

public struct RepositoryOverview: Codable, Sendable {
    public var repository: RepositoryInfo
    public var stats: RepositoryStats
    public var languages: [LanguageStat]
    public var lastIndexed: Date?
    public var health: HealthReport
    public var architecture: ArchitectureReport
    public var hotspots: [Hotspot]
    public var centralFiles: [RankedFile]
    public var largeFiles: [RankedFile]
    public var cycles: [DependencyCycle]
    public var unused: [UnusedItem]
    public var suggestions: [ExtractionSuggestion]
    public var topDiagnostics: [Diagnostic]
    public var externalModules: [RankedFile]

    public init(repository: RepositoryInfo, stats: RepositoryStats, languages: [LanguageStat], lastIndexed: Date?, health: HealthReport, architecture: ArchitectureReport, hotspots: [Hotspot], centralFiles: [RankedFile], largeFiles: [RankedFile], cycles: [DependencyCycle], unused: [UnusedItem], suggestions: [ExtractionSuggestion], topDiagnostics: [Diagnostic], externalModules: [RankedFile]) {
        self.repository = repository
        self.stats = stats
        self.languages = languages
        self.lastIndexed = lastIndexed
        self.health = health
        self.architecture = architecture
        self.hotspots = hotspots
        self.centralFiles = centralFiles
        self.largeFiles = largeFiles
        self.cycles = cycles
        self.unused = unused
        self.suggestions = suggestions
        self.topDiagnostics = topDiagnostics
        self.externalModules = externalModules
    }
}

// MARK: - Map

public enum MapLevel: String, Codable, Sendable, CaseIterable {
    case modules, directories, files, symbols
}

public enum MapNodeKind: String, Codable, Sendable {
    case module, directory, file, symbol, external
}

public struct MapNode: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: MapNodeKind
    public var label: String
    public var path: String?
    public var files: Int
    public var lines: Int
    public var symbols: Int
    public var language: Language?
    public var fanIn: Int
    public var fanOut: Int
    public var centrality: Double
    public var diagnostics: Int
    public var maxSeverity: Severity?
    /// Group used for colouring (top-level area or cluster).
    public var group: String?
    public var isExpandable: Bool
    public var isTest: Bool
    public var risk: Double
    public var symbolKind: SymbolKind?

    public init(id: String, kind: MapNodeKind, label: String, path: String?, files: Int, lines: Int, symbols: Int, language: Language?, fanIn: Int, fanOut: Int, centrality: Double, diagnostics: Int, maxSeverity: Severity?, group: String?, isExpandable: Bool, isTest: Bool, risk: Double, symbolKind: SymbolKind? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.path = path
        self.files = files
        self.lines = lines
        self.symbols = symbols
        self.language = language
        self.fanIn = fanIn
        self.fanOut = fanOut
        self.centrality = centrality
        self.diagnostics = diagnostics
        self.maxSeverity = maxSeverity
        self.group = group
        self.isExpandable = isExpandable
        self.isTest = isTest
        self.risk = risk
        self.symbolKind = symbolKind
    }
}

public struct MapEdge: Codable, Sendable, Hashable, Identifiable {
    public var source: String
    public var target: String
    public var kinds: [EdgeKind]
    public var weight: Int
    public var isCycle: Bool

    public var id: String { source + "→" + target }

    public init(source: String, target: String, kinds: [EdgeKind], weight: Int, isCycle: Bool) {
        self.source = source
        self.target = target
        self.kinds = kinds
        self.weight = weight
        self.isCycle = isCycle
    }
}

public struct MapBreadcrumb: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct MapGraph: Codable, Sendable {
    public var level: MapLevel
    public var focus: String?
    public var breadcrumbs: [MapBreadcrumb]
    public var nodes: [MapNode]
    public var edges: [MapEdge]
    public var hiddenNodes: Int

    public init(level: MapLevel, focus: String?, breadcrumbs: [MapBreadcrumb], nodes: [MapNode], edges: [MapEdge], hiddenNodes: Int) {
        self.level = level
        self.focus = focus
        self.breadcrumbs = breadcrumbs
        self.nodes = nodes
        self.edges = edges
        self.hiddenNodes = hiddenNodes
    }
}

// MARK: - Indexing progress

public enum IndexPhase: String, Codable, Sendable {
    case scanning, analyzing, writing, resolving, graph, health, embeddings, finished

    public var displayName: String {
        switch self {
        case .scanning: "Scanning files"
        case .analyzing: "Parsing sources"
        case .writing: "Writing index"
        case .resolving: "Resolving references"
        case .graph: "Building graph"
        case .health: "Diagnosing health"
        case .embeddings: "Computing semantic vectors"
        case .finished: "Finished"
        }
    }
}

public struct IndexProgress: Sendable, Codable {
    public var phase: IndexPhase
    public var completed: Int
    public var total: Int
    public var currentPath: String?

    public init(phase: IndexPhase, completed: Int, total: Int, currentPath: String? = nil) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.currentPath = currentPath
    }

    public var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
}

public struct IndexSummary: Codable, Sendable {
    public var repository: String
    public var indexPath: String
    public var filesScanned: Int
    public var filesAdded: Int
    public var filesChanged: Int
    public var filesRemoved: Int
    public var filesUnchanged: Int
    public var filesFailed: Int
    public var symbols: Int
    public var references: Int
    public var edges: Int
    public var durationSeconds: Double
    public var warnings: [String]
    /// True when derived analysis (graph metrics, health, architecture) was recomputed.
    public var analysisUpdated: Bool

    public init(repository: String, indexPath: String, filesScanned: Int, filesAdded: Int, filesChanged: Int, filesRemoved: Int, filesUnchanged: Int, filesFailed: Int, symbols: Int, references: Int, edges: Int, durationSeconds: Double, warnings: [String], analysisUpdated: Bool = false) {
        self.repository = repository
        self.indexPath = indexPath
        self.filesScanned = filesScanned
        self.filesAdded = filesAdded
        self.filesChanged = filesChanged
        self.filesRemoved = filesRemoved
        self.filesUnchanged = filesUnchanged
        self.filesFailed = filesFailed
        self.symbols = symbols
        self.references = references
        self.edges = edges
        self.durationSeconds = durationSeconds
        self.warnings = warnings
        self.analysisUpdated = analysisUpdated
    }

    public var didChange: Bool { filesAdded + filesChanged + filesRemoved > 0 || analysisUpdated }
}
