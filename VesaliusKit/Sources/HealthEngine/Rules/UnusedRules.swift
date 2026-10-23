import Foundation
import VesaliusCore

/// "unused-file", "unused-symbols" and the unused-code report.
enum UnusedRules {
    static let note = "Unused-code signals are heuristics based on statically resolved references. Code reached through dynamic dispatch, reflection, Objective-C runtime, storyboards/XIBs, string-based lookups, dependency-injection containers, framework callbacks or external consumers of a public API can appear unused. Review each item before deleting it."

    /// Swift attributes/modifiers that make a declaration reachable without a visible reference.
    private static let reachableAttributes: Set<String> = [
        "override", "@objc", "@objcMembers", "@IBAction", "@IBOutlet", "@IBSegueAction", "@IBInspectable", "@IBDesignable",
        "@main", "@UIApplicationMain", "@NSApplicationMain", "@Test", "@Suite", "@NSManaged", "dynamic", "@_cdecl",
        "@_silgen_name", "@_dynamicReplacement", "@resultBuilder", "@propertyWrapper", "@dynamicMemberLookup",
        "@dynamicCallable", "@Model", "@Reducer",
    ]

    /// Protocols and base classes whose conformers are instantiated by frameworks or test runners.
    private static let frameworkEntryTypes: Set<String> = [
        "App", "PreviewProvider", "XCTestCase", "UIApplicationDelegate", "NSApplicationDelegate", "UIWindowSceneDelegate",
        "UISceneDelegate", "ParsableCommand", "AsyncParsableCommand", "AppIntent", "Widget", "WidgetBundle",
        "TimelineProvider", "AppIntentTimelineProvider", "AppShortcutsProvider", "NSExtensionRequestHandling",
        "UNNotificationServiceExtension", "UNNotificationContentExtension", "TestCase", "unittest.TestCase",
        "XCUIApplication", "LibraryContentProvider", "ControlWidget", "AppEntity", "EntityQuery",
    ]

    /// Base classes commonly instantiated from storyboards/XIBs or by reflection.
    private static let dynamicBaseTypes: Set<String> = [
        "UIViewController", "NSViewController", "UITableViewController", "UICollectionViewController", "UIView", "NSView",
        "UITableViewCell", "UICollectionViewCell", "NSWindowController", "UINavigationController", "UITabBarController",
        "NSObject", "NSManagedObject", "Model", "BaseModel",
    ]

    /// Names that implement framework requirements or lifecycle callbacks.
    private static let callbackNames: Set<String> = [
        "body", "main", "init", "deinit", "description", "debugDescription", "hash", "encode", "makeBody", "makeUIView",
        "updateUIView", "makeNSView", "updateNSView", "makeCoordinator", "makeUIViewController", "updateUIViewController",
        "makeNSViewController", "updateNSViewController", "sizeThatFits", "dismantleUIView", "dismantleNSView",
        "application", "scene", "sceneDidBecomeActive", "sceneWillResignActive", "sceneWillEnterForeground",
        "sceneDidEnterBackground", "sceneDidDisconnect", "applicationDidFinishLaunching", "applicationWillTerminate",
        "viewDidLoad", "viewWillAppear", "viewDidAppear", "viewWillDisappear", "viewDidDisappear", "viewDidLayoutSubviews",
        "viewWillLayoutSubviews", "awakeFromNib", "prepare", "prepareForReuse", "layoutSubviews", "draw", "tableView",
        "collectionView", "numberOfSections", "loadView", "updateConstraints", "traitCollectionDidChange", "perform",
        "render", "componentDidMount", "componentWillUnmount", "componentDidUpdate", "shouldComponentUpdate",
        "getDerivedStateFromProps", "getSnapshotBeforeUpdate", "componentDidCatch", "getServerSideProps", "getStaticProps",
        "getStaticPaths", "generateMetadata", "generateStaticParams", "middleware", "loader", "action", "ngOnInit",
        "ngOnDestroy", "ngOnChanges", "ngAfterViewInit", "setup", "teardown", "setUp", "tearDown", "setUpWithError",
        "tearDownWithError", "callAsFunction", "reduce", "handle", "run", "execute", "validate", "save", "clean",
        "get", "post", "put", "patch", "delete", "dispatch", "default", "constructor", "toString", "toJSON",
        "placeholder", "snapshot", "timeline", "getTimeline", "getSnapshot", "recommendations", "makeIterator", "next",
    ]

    static func run(_ ctx: HealthContext, _ findings: inout HealthFindings) -> UnusedReport {
        var fileItems: [UnusedItem] = []
        var symbolItems: [UnusedItem] = []

        for file in ctx.sourceFiles {
            let symbols = ctx.symbolsByFile[file.id] ?? []
            let isEntry = file.isEntryPoint || PathClassifier.isConventionalEntryPoint(file.path, language: file.language)

            // Files.
            if !isEntry, let item = unusedFile(file, symbols: symbols, ctx: ctx) {
                fileItems.append(item)
            }

            // Symbols.
            guard !isEntry else { continue }
            for symbol in symbols {
                guard let confidence = candidateConfidence(symbol, file: file, ctx: ctx) else { continue }
                findings.unusedCandidateSymbols += 1
                guard symbol.incomingReferences == 0 else { continue }
                symbolItems.append(UnusedItem(
                    kind: .symbol,
                    path: file.path,
                    symbol: symbol.qualifiedName,
                    symbolKind: symbol.kind,
                    line: symbol.lines.start,
                    lines: symbol.lines.count,
                    confidence: confidence,
                    reason: "No references to this \(symbol.kind.displayName) were found anywhere in the repository."
                ))
            }
        }

        // Symbols of files that are unused as a whole are reported once, through the file.
        let unusedFilePaths = Set(fileItems.filter { $0.confidence >= 0.5 }.map(\.path))
        symbolItems = symbolItems.filter { !unusedFilePaths.contains($0.path) }
        let reportedSymbols = symbolItems

        findings.unusedFiles = fileItems.filter { $0.confidence >= 0.5 }.count
        findings.unusedSymbols = symbolItems.filter { $0.confidence >= 0.5 }.count

        fileDiagnostics(fileItems, ctx: ctx, findings: &findings)
        symbolDiagnostics(reportedSymbols, ctx: ctx, findings: &findings)

        let sortedFiles = fileItems.sorted { lhs, rhs in
            lhs.confidence != rhs.confidence ? lhs.confidence > rhs.confidence : ((lhs.lines ?? 0), rhs.path) > ((rhs.lines ?? 0), lhs.path)
        }
        let sortedSymbols = symbolItems.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return (lhs.line ?? 0) < (rhs.line ?? 0)
        }
        return UnusedReport(files: Array(sortedFiles.prefix(500)), symbols: Array(sortedSymbols.prefix(1_000)), note: note)
    }

    // MARK: Files

    private static func unusedFile(_ file: RepositorySnapshot.File, symbols: [RepositorySnapshot.Symbol], ctx: HealthContext) -> UnusedItem? {
        let metrics = ctx.metric(file.id)
        guard metrics.fanIn == 0, !symbols.isEmpty else { return nil }
        guard !symbols.contains(where: { $0.referencingFiles > 0 }) else { return nil }
        let declared = symbols.filter { $0.kind != .extension }
        // Files that only add extensions are used implicitly through the extended type.
        guard !declared.isEmpty else { return nil }
        for symbol in symbols {
            if symbol.attributes.contains(where: { reachableAttributes.contains($0) && $0 != "override" && $0 != "dynamic" }) { return nil }
            if symbol.inheritedTypes.contains(where: { frameworkEntryTypes.contains($0) }) { return nil }
            if symbol.name.hasSuffix("_Previews") || symbol.name.hasSuffix("Previews") { return nil }
        }
        let topLevel = declared.filter { $0.parentID == nil }
        if file.language == .swift, !topLevel.isEmpty, topLevel.allSatisfy({ $0.isExported || $0.visibility?.isExternallyVisible == true }) {
            // Public API of a library target: consumers may live outside the repository.
            return nil
        }
        var confidence: Double
        switch file.language {
        case .typescript, .javascript: confidence = 0.8
        case .swift: confidence = 0.7
        case .python: confidence = 0.65
        default: confidence = 0.6
        }
        if symbols.contains(where: { $0.inheritedTypes.contains(where: { dynamicBaseTypes.contains($0) }) }) {
            confidence = 0.45
        }
        return UnusedItem(
            kind: .file,
            path: file.path,
            lines: file.codeLines,
            confidence: confidence,
            reason: declared.count == 1
                ? "No references detected from other files: nothing imports it and its only declaration (\(declared[0].name)) is not used elsewhere."
                : "No references detected from other files: nothing imports it and none of its \(declared.count) declarations is used elsewhere."
        )
    }

    // MARK: Symbols

    /// Returns the confidence with which an unreferenced symbol is unused, or nil when the symbol is not
    /// a candidate at all (exported, reachable by convention, protocol requirement, …).
    private static func candidateConfidence(_ symbol: RepositorySnapshot.Symbol, file: RepositorySnapshot.File, ctx: HealthContext) -> Double? {
        let kinds: Set<SymbolKind> = [.class, .struct, .enum, .protocol, .interface, .actor, .typeAlias, .function, .method, .component]
        guard kinds.contains(symbol.kind) else { return nil }
        if symbol.isExported { return nil }
        if let visibility = symbol.visibility, visibility.isExternallyVisible || visibility == .package { return nil }

        let name = symbol.name
        if callbackNames.contains(name) { return nil }
        let lower = name.lowercased()
        if lower.hasPrefix("test") || name.hasPrefix("Test") || name.hasSuffix("Previews") || name.hasSuffix("_Previews") { return nil }
        if name.hasPrefix("__") && name.hasSuffix("__") { return nil }
        if ctx.protocolRequirementNames.contains(name) { return nil }
        if symbol.inheritedTypes.contains(where: { frameworkEntryTypes.contains($0) }) { return nil }

        switch file.language {
        case .swift:
            if symbol.attributes.contains(where: { reachableAttributes.contains($0) }) { return nil }
        default:
            // Decorators usually register the symbol with a framework (routes, fixtures, properties).
            if symbol.attributes.contains(where: { $0.hasPrefix("@") }) { return nil }
        }

        // Members: skip protocol requirements and members of types conforming to external protocols.
        var parentID = symbol.parentID
        var hops = 0
        while let id = parentID, let parent = ctx.symbolsByID[id], hops < 8 {
            if parent.kind == .protocol || parent.kind == .interface { return nil }
            if parent.kind.isType || parent.kind == .extension {
                let external = parent.inheritedTypes.filter { !ctx.repositoryTypeNames.contains($0) }
                if !external.isEmpty && symbol.kind.isCallable { return nil }
                if parent.attributes.contains(where: { reachableAttributes.contains($0) && $0 != "override" }) && file.language == .swift {
                    return nil
                }
            }
            parentID = parent.parentID
            hops += 1
        }

        var confidence: Double
        switch file.language {
        case .typescript, .javascript: confidence = 0.85
        case .python: confidence = 0.8
        case .swift:
            confidence = (symbol.visibility == .private || symbol.visibility == .fileprivate) ? 0.85 : 0.7
        default: confidence = 0.6
        }
        if symbol.kind == .method { confidence -= 0.1 }
        if symbol.kind.isType { confidence += 0.05 }
        if symbol.inheritedTypes.contains(where: { dynamicBaseTypes.contains($0) }) {
            // Possibly instantiated from a storyboard/XIB or by reflection.
            confidence = 0.45
        }
        return min(0.95, max(0.3, confidence))
    }

    // MARK: Diagnostics

    private static func fileDiagnostics(_ items: [UnusedItem], ctx: HealthContext, findings: inout HealthFindings) {
        let eligible = items.filter { $0.confidence >= 0.5 }
            .sorted { ($0.lines ?? 0) == ($1.lines ?? 0) ? $0.path < $1.path : ($0.lines ?? 0) > ($1.lines ?? 0) }
        for item in eligible.prefix(ctx.config.maxUnusedFileDiagnostics) {
            let name = (item.path as NSString).lastPathComponent
            findings.drafts.append(DiagnosticDraft(
                rule: "unused-file",
                category: .deadCode,
                severity: item.confidence >= 0.6 ? .low : .info,
                title: "Possibly unused file: \(name)",
                summary: "No references detected to \(name) (\(Format.count(item.lines ?? 0)) code lines).",
                reason: "\(item.reason) Confidence \(Format.percent(item.confidence)); dynamic loading, reflection or external consumers would not be visible to static analysis.",
                recommendation: "Confirm the file is not loaded dynamically (storyboards, reflection, configuration, external callers); if not, remove it or wire it into the feature it was written for.",
                targets: [.file(item.path)],
                metrics: [
                    DiagnosticMetric(name: "fan-in", value: 0, threshold: 0, unit: "files"),
                    DiagnosticMetric(name: "code lines", value: Double(item.lines ?? 0), unit: "lines"),
                    DiagnosticMetric(name: "confidence", value: item.confidence),
                ],
                rank: Double(item.lines ?? 0) * item.confidence
            ))
        }
    }

    private static func symbolDiagnostics(_ items: [UnusedItem], ctx: HealthContext, findings: inout HealthFindings) {
        var byFile: [String: [UnusedItem]] = [:]
        for item in items where item.confidence >= 0.5 { byFile[item.path, default: []].append(item) }
        let ordered = byFile.sorted { lhs, rhs in
            lhs.value.count == rhs.value.count ? lhs.key < rhs.key : lhs.value.count > rhs.value.count
        }
        for (path, group) in ordered.prefix(ctx.config.maxUnusedSymbolDiagnostics) {
            let sorted = group.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
            let name = (path as NSString).lastPathComponent
            let names = sorted.map { "\($0.symbol ?? "?") (\($0.symbolKind?.displayName ?? "symbol"), line \($0.line ?? 0))" }
            let lines = sorted.reduce(0) { $0 + ($1.lines ?? 0) }
            let confidence = sorted.map(\.confidence).reduce(0, +) / Double(sorted.count)
            findings.drafts.append(DiagnosticDraft(
                rule: "unused-symbols",
                category: .deadCode,
                severity: confidence >= 0.6 ? .low : .info,
                title: "\(Format.plural(sorted.count, "unreferenced declaration")) in \(name)",
                summary: "\(Format.list(names, limit: 4)) \(sorted.count == 1 ? "has" : "have") no detected references.",
                reason: "These non-public declarations (\(Format.count(lines)) lines) are never referenced in the repository. Overrides, protocol requirements, framework callbacks, decorated and @objc members were excluded; average confidence \(Format.percent(confidence)).",
                recommendation: "Delete the declarations that are truly dead, or add a test/call site if they are meant to be used. Removing dead code shrinks what readers have to understand.",
                targets: [.file(path)] + sorted.map { .symbol(path, $0.symbol ?? "?", line: $0.line) },
                metrics: [
                    DiagnosticMetric(name: "unreferenced declarations", value: Double(sorted.count)),
                    DiagnosticMetric(name: "lines", value: Double(lines), unit: "lines"),
                    DiagnosticMetric(name: "confidence", value: (confidence * 100).rounded() / 100),
                ],
                rank: Double(sorted.count) * confidence
            ))
        }
    }
}
