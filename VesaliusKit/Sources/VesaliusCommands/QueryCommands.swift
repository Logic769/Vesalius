import ArgumentParser
import Foundation
import QueryEngine
import VesaliusCore
import VesaliusMCP
import VesaliusRender

struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Ask a natural-language question; returns ranked files, symbols and line ranges.")

    @Argument(help: "The question, e.g. \"where is authentication handled?\"")
    var question: [String]

    @Option(name: .shortAndLong, help: "Maximum files.")
    var limit = 8

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let result = try engine.ask(question.joined(separator: " "), limit: limit)
            try global.emit(result) { TextFormatter.ask(result) }
        }
    }
}

struct Files: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Fuzzy-find files by path or name.")

    @Argument(help: "Path fragment or fuzzy name.")
    var query: String = ""

    @Option(name: .shortAndLong, help: "Maximum results.")
    var limit = 20

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let hits = try engine.searchFiles(query, limit: limit)
            try global.emit(hits) { TextFormatter.files(hits) }
        }
    }
}

struct Symbols: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Find symbol declarations by name, prefix or CamelCase abbreviation.")

    @Argument(help: "Symbol name or fragment.")
    var query: String

    @Option(name: .shortAndLong, help: "Filter by kind (class, struct, enum, protocol, interface, function, method, property, …). Repeatable.")
    var kind: [String] = []

    @Option(name: .shortAndLong, help: "Maximum results.")
    var limit = 30

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let kinds = Set(kind.compactMap { name -> SymbolKind? in
                let lower = name.lowercased()
                return SymbolKind(rawValue: lower) ?? SymbolKind.allCases.first { $0.displayName == lower }
            })
            let hits = try engine.searchSymbols(query, kinds: kinds.isEmpty ? nil : kinds, limit: limit)
            try global.emit(hits) { TextFormatter.symbols(hits.map(\.symbol)) }
        }
    }
}

struct References: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Where is a symbol used? Every resolved reference with its enclosing symbol.")

    @Argument(help: "Symbol name, qualified name (Type.member) or stable id.")
    var symbol: String

    @Option(name: .shortAndLong, help: "Maximum reference sites.")
    var limit = 100

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let result = try engine.references(symbol, limit: limit)
            try global.emit(result) { TextFormatter.references(result) }
        }
    }
}

struct Callers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Functions and methods that call a symbol.")

    @Argument(help: "Function, method or type name, or a symbol id (sym:path#Name).")
    var symbol: String

    @Option(name: .shortAndLong, help: "Maximum callers.")
    var limit = 50

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let result = try engine.callers(symbol, limit: limit)
            try global.emit(result) { TextFormatter.callGraph(result) }
        }
    }
}

struct Callees: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Repository symbols called by a function, method or type.")

    @Argument(help: "Function, method or type name, or a symbol id (sym:path#Name).")
    var symbol: String

    @Option(name: .shortAndLong, help: "Maximum callees.")
    var limit = 50

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let result = try engine.callees(symbol, limit: limit)
            try global.emit(result) { TextFormatter.callGraph(result) }
        }
    }
}

struct Dependencies: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dependencies", abstract: "What a file, folder, module or symbol depends on.", aliases: ["depends-on", "deps"])

    @Argument(help: "File path, file name, folder, module or symbol.")
    var target: String

    @Option(name: .shortAndLong, help: "Hops to follow.")
    var depth = 1

    @Option(name: .shortAndLong, help: "Maximum files.")
    var limit = 100

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let result = try engine.dependencies(of: target, depth: depth, limit: limit)
            try global.emit(result) { TextFormatter.dependencies(result) }
        }
    }
}

struct Dependents: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What depends on a file, folder, module or symbol.", aliases: ["rdeps", "importers"])

    @Argument(help: "File path, file name, folder, module or symbol.")
    var target: String

    @Option(name: .shortAndLong, help: "Hops to follow.")
    var depth = 1

    @Option(name: .shortAndLong, help: "Maximum files.")
    var limit = 100

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let result = try engine.dependents(of: target, depth: depth, limit: limit)
            try global.emit(result) { TextFormatter.dependencies(result) }
        }
    }
}

struct Impact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Blast radius of changing a file or symbol: dependents, call sites, tests, risk.", aliases: ["blast-radius"])

    @Argument(help: "File path or symbol.")
    var target: String

    @Option(name: .shortAndLong, help: "Maximum transitive depth.")
    var depth = 8

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let report = try engine.impact(of: target, depth: depth)
            try global.emit(report) { TextFormatter.impact(report) }
        }
    }
}

struct Context: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Everything about one file or symbol: outline, imports, dependencies, dependents, diagnostics, impact.", aliases: ["inspect"])

    @Argument(help: "File path, file name or symbol.")
    var target: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            if let file = try? engine.fileContext(target) {
                try global.emit(file) { TextFormatter.fileContext(file) }
            } else {
                let symbol = try engine.symbolContext(target)
                try global.emit(symbol) { TextFormatter.symbolContext(symbol) }
            }
        }
    }
}

struct Related: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Files most related to a file.")

    @Argument(help: "File path or name.")
    var path: String

    @Option(name: .shortAndLong, help: "Maximum files.")
    var limit = 12

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let related = try engine.relatedFiles(path, limit: limit)
            try global.emit(related) { related.map { String(format: "%.2f  %@  · %@", $0.score, $0.path, $0.reason) }.joined(separator: "\n") }
        }
    }
}

struct Health: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Repository health score with category breakdown and top diagnostics.")

    @Option(name: .shortAndLong, help: "Maximum diagnostics.")
    var limit = 12

    @Flag(help: "Show every scoring factor.")
    var verbose = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            struct Output: Encodable {
                let health: HealthReport
                let diagnostics: [Diagnostic]
            }
            let output = Output(health: try engine.health(), diagnostics: try engine.diagnostics(minimumSeverity: .medium, limit: limit))
            try global.emit(output) { TextFormatter.health(output.health, diagnostics: output.diagnostics, verbose: verbose) }
        }
    }
}

struct Diagnostics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List code-health diagnostics with evidence and recommendations.")

    @Option(name: .shortAndLong, help: "Minimum severity: info, low, medium, high, critical.")
    var severity: String?

    @Option(name: .shortAndLong, help: "Category: \(HealthCategory.allCases.map(\.rawValue).joined(separator: ", ")).")
    var category: String?

    @Option(help: "Rule id, e.g. dependency-cycle, large-file.")
    var rule: String?

    @Option(help: "Only diagnostics touching this file or folder.")
    var path: String?

    @Option(name: .shortAndLong, help: "Maximum diagnostics.")
    var limit = 50

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let list = try engine.diagnostics(minimumSeverity: severity.flatMap(Severity.init(rawValue:)), category: category.flatMap(HealthCategory.init(rawValue:)), rule: rule, path: path, limit: limit)
            try global.emit(list) { list.isEmpty ? "No diagnostics." : list.map { TextFormatter.diagnostic($0, detailed: true) }.joined(separator: "\n\n") }
        }
    }
}

struct Hotspots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Large, complex, frequently changed and highly coupled files.")

    @Option(name: .shortAndLong, help: "Maximum files.")
    var limit = 15

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let hotspots = try engine.hotspots(limit: limit)
            try global.emit(hotspots) { TextFormatter.hotspots(hotspots) }
        }
    }
}

struct Cycles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Circular file dependencies.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let cycles = try engine.cycles()
            try global.emit(cycles) { TextFormatter.cycles(cycles) }
        }
    }
}

struct Unused: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Files and symbols with no detected references.")

    @Option(name: .shortAndLong, help: "Maximum items per list.")
    var limit = 40

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let report = try engine.unused()
            let trimmed = UnusedReport(files: Array(report.files.prefix(limit)), symbols: Array(report.symbols.prefix(limit)), note: report.note)
            try global.emit(trimmed) { TextFormatter.unused(trimmed) }
        }
    }
}

struct Architecture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inferred architecture with evidence, layers and feature areas.")

    @Flag(name: .customLong("v2"), help: "Print the MCP `architecture` tool's result instead.")
    var v2 = false

    @Option(help: "With --v2: a target, package or folder to focus on.")
    var focus: String?

    @Flag(help: "With --v2: print the whole result, with no token budget.")
    var full = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            if v2 {
                var arguments: [String: JSONValue] = [:]
                if let focus { arguments["focus"] = .string(focus) }
                try await global.runTool(ArchitectureTool(), arguments, full: full)
                return
            }
            let engine = try await global.engine()
            let report = try engine.architecture()
            try global.emit(report) { TextFormatter.architecture(report) }
        }
    }
}

struct Suggestions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Candidate packages/modules to extract, with cohesion and coupling evidence.", aliases: ["extractions"])

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            let suggestions = try engine.suggestions()
            try global.emit(suggestions) { TextFormatter.suggestions(suggestions) }
        }
    }
}

struct MapCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "map", abstract: "The clustered dependency map: areas, a folder's contents, a file's neighbourhood or symbols.")

    @Option(name: .shortAndLong, help: "Level: modules, directories, files, symbols.")
    var level: String?

    @Option(name: .shortAndLong, help: "Focus: a folder, module, file, or stable id (dir:…, mod:…, file:…).")
    var focus: String?

    @Flag(help: "Include test files.")
    var tests = false

    @Option(help: "Maximum nodes.")
    var maxNodes = 150

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            let engine = try await global.engine()
            var focusID = focus
            if let focus, NodeID.parse(focus) == nil {
                if (try? engine.fileContext(focus)) != nil {
                    let path = (try engine.fileContext(focus)).file.path
                    focusID = NodeID.file(path)
                } else {
                    focusID = NodeID.directory(focus.hasSuffix("/") ? String(focus.dropLast()) : focus)
                }
            }
            let resolvedLevel = level.flatMap(MapLevel.init(rawValue:)) ?? (focusID == nil ? .modules : (focusID!.hasPrefix("file:") ? .files : .directories))
            let graph = try engine.map(level: resolvedLevel, focus: focusID, options: MapOptions(includeTests: tests, maxNodes: maxNodes))
            try global.emit(graph) { TextFormatter.map(graph) }
        }
    }
}

struct Query: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a read-only SQL query against the index (see --schema).")

    @Argument(help: "SQL (SELECT only).")
    var sql: String?

    @Flag(help: "Print the index schema.")
    var schema = false

    @Option(name: .shortAndLong, help: "Maximum rows.")
    var limit = 200

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await global.run {
            if schema || sql == nil {
                print(RepositoryEngine.schemaDescription)
                return
            }
            let engine = try await global.engine()
            let result = try engine.rawQuery(sql!, limit: limit)
            try global.emit(result) { TextFormatter.table(result) }
        }
    }
}
