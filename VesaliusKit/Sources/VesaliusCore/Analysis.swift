import Foundation

// MARK: - Analyzer input

/// A source file handed to a language analyzer. The text is decoded once by the pipeline and dropped
/// as soon as analysis finishes, so the whole repository is never resident in memory.
public struct SourceFile: Sendable {
    /// Repository-relative path using `/` separators.
    public let path: String
    public let language: Language
    public let text: String

    public init(path: String, language: Language, text: String) {
        self.path = path
        self.language = language
        self.text = text
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var isJSX: Bool { Language.isJSXExtension(path) }
}

// MARK: - Analyzer output

public struct ExtractedSymbol: Sendable, Hashable {
    /// Index of this symbol in `FileAnalysis.symbols`; used for parent links and enclosing-symbol references.
    public var localID: Int
    public var parentLocalID: Int?
    public var name: String
    public var kind: SymbolKind
    public var range: LineRange
    /// A one-line declaration signature, e.g. `func signIn(email: String) async throws -> Session`.
    public var signature: String?
    /// First paragraph of the documentation comment, if any.
    public var doc: String?
    public var visibility: Visibility?
    /// True when the symbol is part of the file's public surface (TS `export`, Swift `public`/`open`,
    /// Python top-level names without a leading underscore).
    public var isExported: Bool
    /// Attributes, decorators and notable modifiers (`@main`, `@objc`, `override`, `static`, `async`, `@app.route`).
    public var attributes: [String]
    /// Names this type inherits from or conforms to (also emitted as references).
    public var inheritedTypes: [String]
    /// Approximate cyclomatic complexity of the body (1 + decision points).
    public var complexity: Int
    /// Structural hash of the body with identifiers/literals normalised; equal hashes suggest duplicated code.
    public var bodyHash: UInt64?
    /// Name with argument labels: `embed(_:)`, `importBook(from:preferences:modelContext:)`, `init(from:)`.
    public var selector: String?
    /// One character per parameter: `d` defaulted, `v` variadic, `c` closure-typed, `D` defaulted and
    /// closure-typed (skippable, or filled by a trailing closure), `-` plain.
    public var parameterFlags: String?
    /// Normalised parameter types, in order (the type grammar of `receiverHint`).
    public var parameterTypes: [String]?
    /// The type a use of this symbol produces: a property's annotation or initializer type, a function's
    /// return type (tuple labels kept), an initializer's or enum case's owner. Same grammar as `receiverHint`.
    public var declaredType: String?
    /// Index into `FileAnalysis.references` of the expression whose type `declaredType` `^` stands for.
    public var declaredTypeRef: Int?
    /// Access of the setter when it differs from the getter (`private(set)`).
    public var setterVisibility: Visibility?
    /// Active `#if` conditions around the declaration, outermost first.
    public var conditions: [String]
    /// Declared inside a function body: visible only in its own file, within its parent.
    public var isLocal: Bool

    public init(
        localID: Int,
        parentLocalID: Int? = nil,
        name: String,
        kind: SymbolKind,
        range: LineRange,
        signature: String? = nil,
        doc: String? = nil,
        visibility: Visibility? = nil,
        isExported: Bool = false,
        attributes: [String] = [],
        inheritedTypes: [String] = [],
        complexity: Int = 1,
        bodyHash: UInt64? = nil,
        selector: String? = nil,
        parameterFlags: String? = nil,
        parameterTypes: [String]? = nil,
        declaredType: String? = nil,
        declaredTypeRef: Int? = nil,
        setterVisibility: Visibility? = nil,
        conditions: [String] = [],
        isLocal: Bool = false
    ) {
        self.localID = localID
        self.parentLocalID = parentLocalID
        self.name = name
        self.kind = kind
        self.range = range
        self.signature = signature
        self.doc = doc
        self.visibility = visibility
        self.isExported = isExported
        self.attributes = attributes
        self.inheritedTypes = inheritedTypes
        self.complexity = complexity
        self.bodyHash = bodyHash
        self.selector = selector
        self.parameterFlags = parameterFlags
        self.parameterTypes = parameterTypes
        self.declaredType = declaredType
        self.declaredTypeRef = declaredTypeRef
        self.setterVisibility = setterVisibility
        self.conditions = conditions
        self.isLocal = isLocal
    }
}

public enum ImportKind: String, Codable, Sendable {
    /// A named module (`import Foundation`, `import numpy`, `import React from "react"`).
    case module
    /// A path relative to the importing file (`./auth`, `../utils/date`, `from .models import User`).
    case relative
    /// A C-family `#include "file.h"`.
    case include
}

public struct ImportedName: Sendable, Hashable, Codable {
    /// Name exported by the imported module (`default` for default imports, `*` for namespace imports).
    public var name: String
    /// Local binding name in the importing file, when different.
    public var alias: String?
    /// Inline `type` modifier on this one name (`import { type A, b }`).
    public var isTypeOnly: Bool = false

    public init(name: String, alias: String? = nil, isTypeOnly: Bool = false) {
        self.name = name
        self.alias = alias
        self.isTypeOnly = isTypeOnly
    }

    public var localName: String { alias ?? name }
}

public struct ExtractedImport: Sendable, Hashable {
    /// Module specifier exactly as written (`Foundation`, `./auth/session`, `.models`, `app.services.auth`).
    public var module: String
    public var kind: ImportKind
    public var names: [ImportedName]
    public var line: Int
    public var isTypeOnly: Bool
    /// True for re-exports (`export * from`, `export { a } from`).
    public var isReExport: Bool
    /// Loaded when code runs, not when the file loads: `import("m")`, Python function-level imports.
    public var isDynamic: Bool
    /// `import "m"` with no bindings: loaded only for its side effects.
    public var isSideEffect: Bool
    /// `vi.mock("m")` / `jest.mock("m")`: names a module without loading it, so it never becomes an edge.
    public var isMock: Bool
    /// Last line of the import statement (multi-line `import {…}`).
    public var endLine: Int?
    /// Swift `@testable import`: the importer also sees the module's internal declarations.
    public var isTestable: Bool
    /// Active `#if` conditions around the import, outermost first.
    public var conditions: [String]

    public init(
        module: String, kind: ImportKind, names: [ImportedName] = [], line: Int, isTypeOnly: Bool = false, isReExport: Bool = false,
        isDynamic: Bool = false, isSideEffect: Bool = false, isMock: Bool = false, endLine: Int? = nil,
        isTestable: Bool = false, conditions: [String] = []
    ) {
        self.module = module
        self.kind = kind
        self.names = names
        self.line = line
        self.isTypeOnly = isTypeOnly
        self.isReExport = isReExport
        self.isDynamic = isDynamic
        self.isSideEffect = isSideEffect
        self.isMock = isMock
        self.endLine = endLine
        self.isTestable = isTestable
        self.conditions = conditions
    }
}

public struct ExtractedReference: Sendable, Hashable {
    /// The referenced identifier (the last component for member accesses: `session.refresh()` → `refresh`).
    public var name: String
    public var kind: ReferenceKind
    public var line: Int
    public var column: Int
    /// `localID` of the innermost symbol containing the use site.
    public var enclosingSymbol: Int?
    /// Simple base expression for member accesses (`AuthService` in `AuthService.shared`, `self`, `api`).
    public var receiver: String?
    /// Head line of the innermost statement; for a compound statement, its header.
    public var statementLine: Int? = nil
    /// Last line of that statement.
    public var endLine: Int? = nil
    /// Last line of the call this reference is the callee of, trailing closures excluded.
    public var callEndLine: Int? = nil
    /// Finer syntactic role than `kind`: a `ReferenceContext` raw value.
    public var context: String? = nil
    /// Argument labels of a call: nil = not a call, `[]` = `f()`, `"_"` = unlabeled, `"{}"` / `"label{}"` =
    /// trailing closures.
    public var argumentLabels: [String]? = nil
    /// What the collector knows about the receiver's type: `T`, `^`, `elem(…)`, `ctx(…)`, `param(^,i)` or `?`.
    public var receiverHint: String? = nil
    /// Index into `FileAnalysis.references` of the expression that produces the receiver.
    public var receiverRef: Int? = nil
    /// Line of the same-file binding that typed the receiver.
    public var typeEvidenceLine: Int? = nil
    /// Active `#if` conditions around the use, outermost first.
    public var conditions: [String] = []
    /// Evaluated while the module loads (not inside a function body).
    public var atLoad: Bool = false
    /// The local the call result is bound to (`const x = f()`), or `"return"`.
    public var assignedTo: String? = nil
    /// First later line in the same function that reads `assignedTo`.
    public var consumerLine: Int? = nil

    public init(
        name: String, kind: ReferenceKind, line: Int, column: Int = 0, enclosingSymbol: Int? = nil, receiver: String? = nil,
        statementLine: Int? = nil, endLine: Int? = nil, callEndLine: Int? = nil, context: String? = nil,
        argumentLabels: [String]? = nil, receiverHint: String? = nil, receiverRef: Int? = nil, typeEvidenceLine: Int? = nil,
        conditions: [String] = [], atLoad: Bool = false, assignedTo: String? = nil, consumerLine: Int? = nil
    ) {
        self.name = name
        self.kind = kind
        self.line = line
        self.column = column
        self.enclosingSymbol = enclosingSymbol
        self.receiver = receiver
        self.statementLine = statementLine
        self.endLine = endLine
        self.callEndLine = callEndLine
        self.context = context
        self.argumentLabels = argumentLabels
        self.receiverHint = receiverHint
        self.receiverRef = receiverRef
        self.typeEvidenceLine = typeEvidenceLine
        self.conditions = conditions
        self.atLoad = atLoad
        self.assignedTo = assignedTo
        self.consumerLine = consumerLine
    }
}

/// A string literal at a use site, with the call or assignment it feeds (`Text("Settings")`,
/// `.accessibilityIdentifier("save")`, `UserDefaults.standard.bool(forKey: "onboarded")`).
public struct ExtractedLiteral: Sendable, Hashable {
    public var value: String
    public var line: Int
    public var column: Int
    /// `localID` of the innermost symbol containing the literal.
    public var enclosingSymbol: Int?
    /// One of `ui`, `call-arg`, `subscript`, `assign`, `initializer`, `return`, `array`, `other`.
    public var context: String
    /// The function, initializer or member the literal is passed to.
    public var callee: String?
    /// The argument label it is passed under.
    public var label: String?
    /// Active `#if` conditions around the literal, outermost first.
    public var conditions: [String]

    public init(value: String, line: Int, column: Int = 0, enclosingSymbol: Int? = nil, context: String = "other", callee: String? = nil, label: String? = nil, conditions: [String] = []) {
        self.value = value
        self.line = line
        self.column = column
        self.enclosingSymbol = enclosingSymbol
        self.context = context
        self.callee = callee
        self.label = label
        self.conditions = conditions
    }
}

public struct FileAnalysis: Sendable {
    public var symbols: [ExtractedSymbol]
    public var imports: [ExtractedImport]
    public var references: [ExtractedReference]
    /// String literals at use sites (UI text, identifiers, keys).
    public var literals: [ExtractedLiteral]
    /// Total decision points in the file (1 + branches), summed over all bodies.
    public var complexity: Int
    /// Number of syntax errors the parser recovered from. The analysis is still usable.
    public var syntaxErrorCount: Int
    /// Export clauses as `"<exportedName>=<localName>"` pairs: `export { a as b }` → `"b=a"`,
    /// `export default App` → `"default=App"`, Python `__all__ = ["x"]` → `"x=x"`.
    public var exportedNames: [String]
    /// True when the file is a program entry point (`@main`, top-level Swift code in main.swift,
    /// Python `if __name__ == "__main__":`, a Node script with a shebang).
    public var isEntryPoint: Bool

    public init(
        symbols: [ExtractedSymbol] = [],
        imports: [ExtractedImport] = [],
        references: [ExtractedReference] = [],
        complexity: Int = 1,
        syntaxErrorCount: Int = 0,
        exportedNames: [String] = [],
        isEntryPoint: Bool = false,
        literals: [ExtractedLiteral] = []
    ) {
        self.symbols = symbols
        self.imports = imports
        self.references = references
        self.complexity = complexity
        self.syntaxErrorCount = syntaxErrorCount
        self.exportedNames = exportedNames
        self.isEntryPoint = isEntryPoint
        self.literals = literals
    }
}

// MARK: - Analyzer protocol

/// A language adapter. Analyzers must be stateless and thread-safe: the indexing pipeline calls
/// `analyze` concurrently for many files.
///
/// The conceptual stages (parse → extract symbols/imports/references/calls → semantic chunks) run as a
/// single syntax-tree walk for speed; calls are references with `kind == .call`, and semantic chunks
/// are derived from the extracted symbols by the indexing pipeline.
public protocol LanguageAnalyzer: Sendable {
    /// Stable identifier, e.g. `swift-syntax`, `tree-sitter-typescript`.
    var identifier: String { get }
    /// Bump when the analyzer's output changes: the pipeline re-parses every file it handles.
    var version: Int { get }
    func canAnalyze(_ language: Language, path: String) -> Bool
    func analyze(_ file: SourceFile) throws -> FileAnalysis
}

extension LanguageAnalyzer {
    public var version: Int { 1 }
}

public struct AnalyzerError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Utilities shared by analyzers

/// Fast FNV-1a 64-bit hasher for structural fingerprints.
public struct FNV1a: Sendable {
    public private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    public init() {}

    public mutating func combine(_ string: some StringProtocol) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        value ^= 0xFF
        value = value &* 0x0000_0100_0000_01B3
    }

    public mutating func combine(_ int: Int) {
        var v = UInt64(bitPattern: Int64(int))
        for _ in 0..<8 {
            value ^= v & 0xFF
            value = value &* 0x0000_0100_0000_01B3
            v >>= 8
        }
    }
}

extension String {
    /// Collapses whitespace runs and truncates for compact one-line signatures.
    public func compactSignature(maxLength: Int = 160) -> String {
        var result = ""
        result.reserveCapacity(min(count, maxLength))
        var lastWasSpace = false
        for ch in self {
            if ch.isWhitespace {
                if !lastWasSpace && !result.isEmpty { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(ch)
                lastWasSpace = false
            }
            if result.count >= maxLength { return result + "…" }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Cleans a raw doc comment (`///`, `/** */`, `#`, docstring quotes) down to its first paragraph.
    public func cleanedDocComment(maxLength: Int = 280) -> String? {
        var lines: [String] = []
        for raw in split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            for prefix in ["///", "//!", "/**", "/*!", "/*", "*/", "**", "*", "#", "\"\"\"", "'''", "//"] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                break
            }
            if line.hasSuffix("*/") { line = String(line.dropLast(2)) }
            if line.hasSuffix("\"\"\"") || line.hasSuffix("'''") { line = String(line.dropLast(3)) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- Parameter") || line.hasPrefix("- Returns") || line.hasPrefix("@param") || line.hasPrefix("@returns") || line.hasPrefix(":param") {
                break
            }
            if line.isEmpty {
                if !lines.isEmpty { break }
                continue
            }
            lines.append(line)
        }
        let text = lines.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }
}
