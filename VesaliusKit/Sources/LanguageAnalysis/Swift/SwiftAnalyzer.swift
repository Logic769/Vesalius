import Foundation
import SwiftParser
import SwiftSyntax
import VesaliusCore

/// Swift language adapter backed by SwiftSyntax.
///
/// One syntax-tree walk extracts declarations (types, extensions, members, enum cases, top-level
/// functions and variables, function-local types marked `isLocal`), imports, references (calls,
/// instantiations, type uses, inheritance, conformances, reads/writes, implicit members, property-wrapper
/// and macro uses) and per-symbol complexity. References carry their statement span, call shape (argument
/// labels, end line), syntactic context and `#if` conditions. Locals and parameters are tracked by scope, with
/// what is known of their types, so they never appear as references; member references instead carry what
/// the collector knows about their receiver's type (`receiverHint`, `receiverRef`), and symbols the type a
/// use of them produces (`declaredType`), for the linker to finish. String literals are recorded with the call or
/// assignment they feed, and environment variables and launch arguments become `env:` references.
///
/// The analyzer is stateless and safe to call concurrently. Parsing runs on a dedicated thread with a
/// large stack: SwiftSyntax recurses per nesting level, and its debug builds otherwise cap nesting at 20,
/// which would truncate deeply nested SwiftUI files. `SwiftSourceGuard` defuses the one input shape
/// (long runs of `[[[[`) that makes the parser exponential.
public struct SwiftAnalyzer: LanguageAnalyzer {
    /// Parser nesting limit (the release default; set explicitly so debug builds behave the same).
    static let maximumNestingLevel = 256
    /// Stack for the parsing thread; generous enough for the nesting limit in unoptimized builds and for
    /// very long member-access chains, which the visitor walks recursively.
    static let stackSize = 64 << 20

    public init() {}

    public var identifier: String { "swift-syntax" }

    /// 2: one row per occurrence with statement spans, call shapes, contexts, `#if` conditions, implicit
    /// members, selectors, local types, attribute signatures and stdlib member names.
    /// 3: receiver types and implicit-member contexts, declared types.
    /// 4: string literals at use sites; environment variables and launch arguments as `env:NAME` and
    /// `env:arg:VALUE` references.
    public var version: Int { 4 }

    public func canAnalyze(_ language: Language, path: String) -> Bool {
        language == .swift
    }

    public func analyze(_ file: SourceFile) throws -> FileAnalysis {
        Self.onLargeStack { Self.extract(file) }
    }

    static func extract(_ file: SourceFile, disabledRules: Set<SwiftTypeInference.Rule> = SwiftTypeInference.disabledRules) -> FileAnalysis {
        var bytes = Array(file.text.utf8)
        if let defused = SwiftSourceGuard.defuse(bytes) { bytes = defused }
        let tree = bytes.withUnsafeBufferPointer { buffer in
            Parser.parse(source: buffer, maximumNestingLevel: maximumNestingLevel)
        }
        let converter = SourceLocationConverter(fileName: file.path, tree: tree)
        let collector = SwiftSyntaxCollector(converter: converter, source: bytes, disabledRules: disabledRules)
        collector.walk(tree)
        collector.finishTypes()
        collector.finishEnvironment()

        var syntaxErrors = 0
        if tree.hasError {
            let counter = SyntaxErrorCounter()
            counter.walk(tree)
            syntaxErrors = max(1, counter.count)
        }

        let hasTopLevelCode = tree.statements.contains { statement in
            if case .decl = statement.item { return false }
            return true
        }
        let isEntryPoint = collector.hasMainAttribute || (file.fileName == "main.swift" && hasTopLevelCode)

        return FileAnalysis(
            symbols: collector.symbols,
            imports: collector.imports,
            references: collector.references,
            complexity: 1 + collector.decisionCount,
            syntaxErrorCount: syntaxErrors,
            exportedNames: [],
            isEntryPoint: isEntryPoint,
            literals: collector.literals
        )
    }

    /// Runs `work` on a thread with a large stack and waits for it.
    static func onLargeStack(_ work: @escaping @Sendable () -> FileAnalysis) -> FileAnalysis {
        let result = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result.value = work()
            done.signal()
        }
        thread.stackSize = stackSize
        thread.qualityOfService = Thread.current.qualityOfService
        thread.name = "Vesalius.SwiftAnalyzer"
        thread.start()
        done.wait()
        return result.value ?? FileAnalysis()
    }
}

/// Hands the result from the parsing thread back to the caller (synchronised by the semaphore).
private final class ResultBox: @unchecked Sendable {
    var value: FileAnalysis?
}
