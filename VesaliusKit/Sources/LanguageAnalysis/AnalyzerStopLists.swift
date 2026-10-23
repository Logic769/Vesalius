import Foundation
import VesaliusCore

/// Names an analyzer deliberately leaves out of the reference table. The reference table can never show
/// every use of such a name, so the evidence layer reports a search for one as "not tracked by name"
/// instead of claiming it is complete.
public enum AnalyzerStopLists {
    /// For Swift, the names never recorded when unqualified (`print(…)`, `String`); member uses of every
    /// name, `x.count` and `wal.append(…)` included, are recorded.
    public static func untrackedNames(language: Language) -> Set<String> {
        switch language {
        case .swift: SwiftSyntaxSupport.untrackedWhenUnqualified
        case .typescript, .javascript: TypeScriptAnalyzer.stopNames
        case .python: PythonAnalyzer.stopNames
        default: []
        }
    }
}
