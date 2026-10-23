import Foundation
@testable import GraphEngine
@testable import HealthEngine
import Testing
import VesaliusCore

// MARK: - Fixture builder

/// Builds synthetic repository snapshots for health-engine tests.
private struct Fixture {
    var files: [RepositorySnapshot.File] = []
    var symbols: [RepositorySnapshot.Symbol] = []
    var edges: [RepositorySnapshot.Edge] = []
    var modules: [ModuleInfo] = []
    var manifest: [String] = []
    private var nextFile: Int64 = 1
    private var nextSymbol: Int64 = 10_000
    private var qualifiedNames: [Int64: String] = [:]
    private var fileIndex: [Int64: Int] = [:]

    @discardableResult
    mutating func file(
        _ path: String,
        lines: Int = 40,
        complexity: Int = 4,
        test: Bool? = nil,
        entry: Bool = false,
        imports: [String] = [],
        generated: Bool = false,
        module: String? = nil
    ) -> Int64 {
        let id = nextFile
        nextFile += 1
        let language = Language.detect(fileName: (path as NSString).lastPathComponent)
        fileIndex[id] = files.count
        files.append(RepositorySnapshot.File(
            id: id,
            path: path,
            directory: (path as NSString).deletingLastPathComponent,
            module: module,
            language: language,
            lines: lines + 10,
            codeLines: lines,
            complexity: complexity,
            symbolCount: 0,
            isTest: test ?? PathClassifier.isTest(path),
            isGenerated: generated,
            isEntryPoint: entry,
            externalImports: imports
        ))
        return id
    }

    @discardableResult
    mutating func symbol(
        _ file: Int64,
        _ name: String,
        _ kind: SymbolKind,
        lines: ClosedRange<Int> = 1...10,
        parent: Int64? = nil,
        exported: Bool = false,
        visibility: Visibility? = nil,
        attributes: [String] = [],
        inherits: [String] = [],
        complexity: Int = 1,
        bodyHash: UInt64? = nil,
        refs: Int = 1,
        refFiles: Int = 0
    ) -> Int64 {
        let id = nextSymbol
        nextSymbol += 1
        let parentName = parent.flatMap { qualifiedNames[$0] }
        let qualified = parentName.map { "\($0).\(name)" } ?? name
        qualifiedNames[id] = qualified
        symbols.append(RepositorySnapshot.Symbol(
            id: id,
            fileID: file,
            parentID: parent,
            name: name,
            qualifiedName: qualified,
            kind: kind,
            lines: LineRange(lines.lowerBound, lines.upperBound),
            visibility: visibility,
            isExported: exported,
            attributes: attributes,
            inheritedTypes: inherits,
            complexity: complexity,
            bodyHash: bodyHash,
            incomingReferences: refs,
            referencingFiles: refFiles
        ))
        if let index = fileIndex[file] { files[index].symbolCount += 1 }
        return id
    }

    mutating func depend(_ source: Int64, _ target: Int64, kind: EdgeKind = .references, weight: Int = 1) {
        edges.append(RepositorySnapshot.Edge(source: source, target: target, kind: kind, weight: weight))
    }

    func build(name: String = "Fixture") -> (RepositorySnapshot, GraphAnalysis) {
        let inputs = files.map {
            GraphAnalysis.FileInput(id: $0.id, path: $0.path, codeLines: $0.codeLines, complexity: $0.complexity, isCode: $0.language.isCode, isTest: $0.isTest, churn: $0.churn)
        }
        let graph = GraphAnalysis.compute(files: inputs, edges: edges)
        let snapshot = RepositorySnapshot(
            repositoryName: name,
            files: files,
            symbols: symbols,
            edges: edges,
            modules: modules,
            metrics: graph.metrics,
            cycles: graph.cycles,
            clusters: graph.clusters,
            manifestDependencies: manifest
        )
        return (snapshot, graph)
    }

    func analyze(_ configuration: HealthConfiguration = .default) -> HealthAnalysis {
        let (snapshot, graph) = build()
        return HealthEngine(configuration: configuration).analyze(snapshot: snapshot, graph: graph)
    }

    /// A tidy feature-organised SwiftUI app used as a baseline.
    static func tidyApp() -> Fixture {
        var f = Fixture()
        let app = f.file("App/ShelfApp.swift", lines: 25, entry: true, imports: ["SwiftUI"])
        f.symbol(app, "ShelfApp", .struct, attributes: ["@main"], inherits: ["App"], refs: 0)
        let model = f.file("App/Models/Volume.swift", lines: 30)
        f.symbol(model, "Volume", .struct, inherits: ["Codable"], refs: 6, refFiles: 4)
        let api = f.file("App/Services/APIClient.swift", lines: 80, imports: ["Foundation"])
        f.symbol(api, "APIClient", .class, refs: 3, refFiles: 2)
        let volumeService = f.file("App/Services/VolumeService.swift", lines: 70)
        f.symbol(volumeService, "VolumeService", .class, refs: 2, refFiles: 2)
        let listVM = f.file("App/Features/Volumes/VolumeListViewModel.swift", lines: 60, imports: ["Observation"])
        f.symbol(listVM, "VolumeListViewModel", .class, attributes: ["@Observable"], refs: 2, refFiles: 1)
        let listView = f.file("App/Features/Volumes/VolumeListView.swift", lines: 70, imports: ["SwiftUI"])
        f.symbol(listView, "VolumeListView", .struct, inherits: ["View"], refs: 1, refFiles: 1)
        let detailVM = f.file("App/Features/Volumes/VolumeDetailViewModel.swift", lines: 50)
        f.symbol(detailVM, "VolumeDetailViewModel", .class, attributes: ["@Observable"], refs: 1, refFiles: 1)
        let detailView = f.file("App/Features/Volumes/VolumeDetailView.swift", lines: 65, imports: ["SwiftUI"])
        f.symbol(detailView, "VolumeDetailView", .struct, inherits: ["View"], refs: 1, refFiles: 1)
        let settingsVM = f.file("App/Features/Settings/SettingsViewModel.swift", lines: 40)
        f.symbol(settingsVM, "SettingsViewModel", .class, attributes: ["@Observable"], refs: 1, refFiles: 1)
        let settingsView = f.file("App/Features/Settings/SettingsView.swift", lines: 55, imports: ["SwiftUI"])
        f.symbol(settingsView, "SettingsView", .struct, inherits: ["View"], refs: 1, refFiles: 1)
        let root = f.file("App/RootView.swift", lines: 30, imports: ["SwiftUI"])
        f.symbol(root, "RootView", .struct, inherits: ["View"], refs: 1, refFiles: 1)
        let tests = f.file("Tests/VolumeServiceTests.swift", lines: 60, imports: ["XCTest"])
        f.symbol(tests, "VolumeServiceTests", .class, inherits: ["XCTestCase"], refs: 0)

        f.depend(app, root)
        f.depend(root, listView)
        f.depend(root, settingsView)
        f.depend(listView, listVM)
        f.depend(listView, detailView)
        f.depend(listView, model)
        f.depend(detailView, detailVM)
        f.depend(detailView, model)
        f.depend(listVM, volumeService)
        f.depend(listVM, model)
        f.depend(detailVM, volumeService)
        f.depend(detailVM, model)
        f.depend(volumeService, api)
        f.depend(volumeService, model)
        f.depend(settingsView, settingsVM)
        f.depend(settingsVM, api)
        f.depend(tests, volumeService)
        return f
    }
}

private extension HealthAnalysis {
    func diagnostics(_ rule: String) -> [Diagnostic] { diagnostics.filter { $0.rule == rule } }
    func category(_ category: HealthCategory) -> CategoryScore? { report.categories.first { $0.category == category } }
    func pattern(_ name: String) -> ArchitecturePattern? { architecture.patterns.first { $0.name == name } }
}

// MARK: - Tests

@Suite("HealthEngine")
struct HealthEngineTests {
    @Test("A tidy small repository scores high and raises no structural problems")
    func cleanRepositoryScoresHigh() throws {
        let analysis = Fixture.tidyApp().analyze()
        #expect(analysis.report.score >= 85, "score \(analysis.report.score): \(analysis.report.summary)")
        #expect(analysis.report.score <= 100)
        #expect(analysis.report.categories.count == HealthCategory.allCases.count)
        let structural: Set<String> = ["dependency-cycle", "large-file", "large-type", "high-fan-out", "unused-file", "tight-coupling", "boundary-violation", "massive-ui-file", "mixed-concerns"]
        let fired = analysis.diagnostics.filter { structural.contains($0.rule) }
        #expect(fired.isEmpty, "unexpected: \(fired.map(\.title))")
        #expect(analysis.diagnostics.allSatisfy { $0.severity <= .low })
        #expect(analysis.report.grade == HealthReport.grade(for: analysis.report.score))
        #expect(analysis.report.diagnosticCounts.keys.sorted() == Severity.allCases.map(\.rawValue).sorted())
        // Every category explains itself.
        for category in analysis.report.categories {
            #expect(!category.factors.isEmpty, "\(category.category) has no factors")
            #expect(!category.summary.isEmpty)
        }
    }

    @Test("Large files are tiered by code lines, tests get doubled thresholds")
    func largeFileTiers() throws {
        var f = Fixture()
        let medium = f.file("Sources/Medium.swift", lines: 450)
        let high = f.file("Sources/Big.swift", lines: 900)
        let critical = f.file("Sources/Huge.swift", lines: 1_600)
        let testFile = f.file("Tests/BigTests.swift", lines: 700)
        let hugeTest = f.file("Tests/HugeTests.swift", lines: 3_500)
        for (index, id) in [medium, high, critical, testFile, hugeTest].enumerated() {
            f.symbol(id, "Type\(index)", .struct, lines: 1...20, refs: 2, refFiles: 1)
        }
        let analysis = f.analyze()
        let large = analysis.diagnostics("large-file")
        func severity(_ name: String) -> Severity? { large.first { $0.targets.first?.path.hasSuffix(name) == true }?.severity }
        #expect(severity("Medium.swift") == .medium)
        #expect(severity("Big.swift") == .high)
        #expect(severity("Huge.swift") == .critical)
        #expect(severity("BigTests.swift") == nil, "test files use 2× thresholds")
        #expect(severity("HugeTests.swift") == .medium, "test files are capped at medium severity")
        let huge = try #require(large.first { $0.targets.first?.path == "Sources/Huge.swift" })
        let metric = try #require(huge.metrics.first { $0.name == "code lines" })
        #expect(metric.value == 1_600)
        #expect(metric.threshold == 1_500)
        #expect(huge.reason.contains("1,600"))
        #expect(huge.id == Diagnostic.fingerprint(rule: "large-file", targets: huge.targets))
        #expect((analysis.category(.complexity)?.score ?? 100) < 100)
    }

    @Test("Oversized UI files are reported as massive UI files instead of large files")
    func massiveUIFile() throws {
        var f = Fixture()
        let view = f.file("App/Views/ProfileView.swift", lines: 650, imports: ["SwiftUI"])
        f.symbol(view, "ProfileView", .struct, lines: 1...640, inherits: ["View"], refs: 1, refFiles: 1)
        let analysis = f.analyze()
        let massive = try #require(analysis.diagnostics("massive-ui-file").first)
        #expect(massive.severity == .high)
        #expect(massive.title.contains("ProfileView.swift"))
        #expect(analysis.diagnostics("large-file").isEmpty)
        #expect((analysis.category(.maintainability)?.score ?? 100) < 100)
    }

    @Test("God objects count members declared in same-name extensions")
    func largeTypeIncludesExtensions() throws {
        var f = Fixture()
        let file = f.file("Sources/Session/SessionManager.swift", lines: 380)
        let type = f.symbol(file, "SessionManager", .class, lines: 1...360, refs: 9, refFiles: 7)
        for index in 0..<30 { f.symbol(file, "member\(index)", .method, lines: (10 + index * 5)...(12 + index * 5), parent: type) }
        let extFile = f.file("Sources/Session/SessionManager+Storage.swift", lines: 120)
        let ext = f.symbol(extFile, "SessionManager", .extension, lines: 1...110)
        for index in 0..<15 { f.symbol(extFile, "storageMember\(index)", .method, lines: (5 + index * 6)...(8 + index * 6), parent: ext) }
        let analysis = f.analyze()
        let diagnostic = try #require(analysis.diagnostics("large-type").first)
        #expect(diagnostic.metrics.first { $0.name == "members" }?.value == 45)
        #expect(diagnostic.metrics.first { $0.name == "lines" }?.value == 470)
        #expect(diagnostic.severity == .medium)
        #expect(diagnostic.targets.first?.symbol == "SessionManager")
        #expect(diagnostic.summary.contains("1 extension"))
    }

    @Test("Long and complex functions are graded and capped to the worst offenders")
    func longFunctions() throws {
        var f = Fixture()
        let file = f.file("Sources/Engine.swift", lines: 380)
        f.symbol(file, "render", .function, lines: 1...200, complexity: 10)          // 2.5× lines → medium
        f.symbol(file, "decide", .function, lines: 201...260, complexity: 90)        // 4.5× complexity → high
        f.symbol(file, "small", .function, lines: 261...280, complexity: 3)
        let others = f.file("Sources/Many.swift", lines: 300)
        for index in 0..<70 {
            f.symbol(others, "step\(index)", .function, lines: (1 + index * 100)...(85 + index * 100), complexity: 5)
        }
        let analysis = f.analyze()
        let long = analysis.diagnostics("long-function")
        #expect(long.count == 60, "capped at maxLongFunctionDiagnostics")
        #expect(long.first { $0.title.contains("decide") }?.severity == .high)
        #expect(long.first { $0.title.contains("render") }?.severity == .medium)
        #expect(!long.contains { $0.title.contains("small") })
        let factor = analysis.category(.complexity)?.factors.first { $0.label == "Long or complex functions" }
        #expect(factor?.detail.contains("72") == true, "\(factor?.detail ?? "")")
    }

    @Test("Fan-out and fan-in thresholds adapt to the repository and explain the ripple")
    func fanOutAndFanIn() throws {
        var f = Fixture()
        let hub = f.file("Sources/Core/Store.swift", lines: 120)
        f.symbol(hub, "Store", .class, refs: 40, refFiles: 25)
        let coordinator = f.file("Sources/App/Coordinator.swift", lines: 200)
        f.symbol(coordinator, "Coordinator", .class, refs: 1, refFiles: 1)
        var leaves: [Int64] = []
        for index in 0..<25 {
            let leaf = f.file("Sources/Features/Feature\(index)/Feature\(index)Screen.swift", lines: 60)
            f.symbol(leaf, "Feature\(index)Screen", .struct, refs: 1, refFiles: 1)
            f.depend(leaf, hub)
            leaves.append(leaf)
        }
        for leaf in leaves.prefix(20) { f.depend(coordinator, leaf) }
        let analysis = f.analyze()
        let fanOut = try #require(analysis.diagnostics("high-fan-out").first)
        #expect(fanOut.targets.first?.path == "Sources/App/Coordinator.swift")
        #expect(fanOut.metrics.first { $0.name == "fan-out" }?.value == 20)
        #expect(fanOut.metrics.first { $0.name == "fan-out" }?.threshold == 15)
        let fanIn = try #require(analysis.diagnostics("high-fan-in").first)
        #expect(fanIn.targets.first?.path == "Sources/Core/Store.swift")
        #expect(fanIn.severity == .medium, "the hub reaches more than half the codebase")
        #expect(fanIn.reason.contains("ripple"))
        #expect((analysis.category(.coupling)?.score ?? 100) < 100)
    }

    @Test("Import cycles report the concrete path and severity by size")
    func cyclesProducePaths() throws {
        var f = Fixture()
        let a = f.file("src/A.ts"), b = f.file("src/B.ts"), c = f.file("src/C.ts")
        let d = f.file("src/D.ts"), e = f.file("src/E.ts")
        for (id, name) in [(a, "A"), (b, "B"), (c, "C"), (d, "D"), (e, "E")] { f.symbol(id, name, .class, refs: 2, refFiles: 1) }
        f.depend(a, b, kind: .imports, weight: 5)
        f.depend(b, c, kind: .imports, weight: 1)
        f.depend(c, a, kind: .imports, weight: 3)
        f.depend(d, e, kind: .imports)
        f.depend(e, d, kind: .imports)
        let (snapshot, graph) = f.build()
        #expect(graph.cyclePaths.count == 2)
        let analysis = HealthEngine().analyze(snapshot: snapshot, graph: graph)
        let cycles = analysis.diagnostics("dependency-cycle")
        #expect(cycles.count == 2)
        let triangle = try #require(cycles.first { $0.targets.count == 3 })
        #expect(triangle.severity == .high)
        #expect(triangle.summary.contains("→"))
        #expect(triangle.recommendation.contains("B.ts → C.ts"), "weakest link is the weight-1 edge: \(triangle.recommendation)")
        let pair = try #require(cycles.first { $0.targets.count == 2 })
        #expect(pair.severity == .medium)
        let cycleScore = try #require(analysis.category(.cycles))
        #expect(cycleScore.score < 100)
        #expect(cycleScore.factors.contains { $0.label == "Files in import cycles" && $0.impact < 0 })
    }

    @Test("Loops that no import closes (headers sharing declarations) are not import cycles")
    func referenceOnlyLoopsAreNotImportCycles() throws {
        var f = Fixture()
        let parent = f.file("Include/descrobject.h"), part = f.file("Include/cpython/descrobject.h")
        let x = f.file("lib/x.c"), y = f.file("lib/y.c")
        for (id, name) in [(parent, "PyDescr"), (part, "PyDescrPart"), (x, "x"), (y, "y")] { f.symbol(id, name, .struct, refs: 2, refFiles: 1) }
        // descrobject.h includes cpython/descrobject.h, which uses its declarations by name.
        f.depend(parent, part, kind: .imports)
        f.depend(part, parent, kind: .references, weight: 4)
        // x.c and y.c include each other: a real import cycle.
        f.depend(x, y, kind: .imports)
        f.depend(y, x, kind: .imports)
        let (snapshot, graph) = f.build()
        let analysis = HealthEngine().analyze(snapshot: snapshot, graph: graph)
        let cycles = analysis.diagnostics("dependency-cycle")
        let headers = try #require(cycles.first { $0.targets.contains { $0.path == "Include/descrobject.h" } })
        #expect(headers.title.hasPrefix("Interconnected files"))
        #expect(headers.severity == .low)
        #expect(headers.reason.contains("no chain of imports closes the loop"))
        let sources = try #require(cycles.first { $0.targets.contains { $0.path == "lib/x.c" } })
        #expect(sources.title == "Dependency cycle across 2 files")
        #expect(sources.severity == .medium)
    }

    @Test("Swift files that reference each other in one module are reported gently")
    func swiftLoopsAreNotImportCycles() throws {
        var f = Fixture()
        let a = f.file("Sources/App/A.swift", module: "App"), b = f.file("Sources/App/B.swift", module: "App"), c = f.file("Sources/App/C.swift", module: "App")
        for (id, name) in [(a, "A"), (b, "B"), (c, "C")] { f.symbol(id, name, .class, refs: 2, refFiles: 1) }
        f.depend(a, b)
        f.depend(b, c)
        f.depend(c, a)
        let analysis = f.analyze()
        let loop = try #require(analysis.diagnostics("dependency-cycle").first)
        #expect(loop.severity == .low)
        #expect(loop.title.hasPrefix("Interconnected Swift files"))
        #expect(loop.reason.contains("without imports"))
        let cycleScore = try #require(analysis.category(.cycles))
        #expect(cycleScore.factors.contains { $0.label == "Interconnected files" })
        #expect(!cycleScore.factors.contains { $0.label == "Files in import cycles" })
    }

    @Test("Deep dependency chains are reported with the chain")
    func deepChains() throws {
        func chain(_ length: Int) -> HealthAnalysis {
            var f = Fixture()
            var previous: Int64?
            for index in 0..<length {
                let id = f.file("Sources/Layer\(index)/Step\(index).swift")
                f.symbol(id, "Step\(index)", .struct, refs: 1, refFiles: 1)
                if let previous { f.depend(previous, id) }
                previous = id
            }
            return f.analyze()
        }
        #expect(chain(8).diagnostics("deep-chain").isEmpty, "7 levels is under the threshold")
        let medium = try #require(chain(11).diagnostics("deep-chain").first)
        #expect(medium.severity == .medium)
        #expect(medium.metrics.first?.value == 10)
        #expect(medium.summary.contains("Step0.swift → Step1.swift"))
        let high = try #require(chain(15).diagnostics("deep-chain").first)
        #expect(high.severity == .high)
        #expect(high.summary.contains("…"))
    }

    @Test("Bidirectional dependencies between feature areas are reported")
    func tightCoupling() throws {
        var f = Fixture()
        var booking: [Int64] = [], profile: [Int64] = []
        for index in 0..<4 {
            let b = f.file("App/Features/Booking/Booking\(index).swift")
            f.symbol(b, "Booking\(index)", .struct, refs: 2, refFiles: 1)
            booking.append(b)
            let p = f.file("App/Features/Profile/Profile\(index).swift")
            f.symbol(p, "Profile\(index)", .struct, refs: 2, refFiles: 1)
            profile.append(p)
        }
        for index in 0..<3 {
            f.depend(booking[index], profile[index])
            f.depend(profile[index + 1], booking[index + 1])
        }
        let analysis = f.analyze()
        let tight = try #require(analysis.diagnostics("tight-coupling").first)
        #expect(tight.severity == .medium)
        #expect(Set(tight.targets.map(\.path)) == ["App/Features/Booking", "App/Features/Profile"])
        #expect(tight.targets.allSatisfy { $0.kind == .directory })
        #expect(tight.title.contains("↔"))
        #expect((analysis.category(.boundaries)?.score ?? 100) < 100)
    }

    @Test("Lower layers depending on presentation violate boundaries")
    func boundaryViolations() throws {
        var f = Fixture()
        let user = f.file("App/Models/User.swift")
        f.symbol(user, "User", .struct, refs: 3, refFiles: 2)
        let userView = f.file("App/Views/UserView.swift", imports: ["SwiftUI"])
        f.symbol(userView, "UserView", .struct, refs: 1, refFiles: 1)
        let useCase = f.file("App/Domain/LoadUser.swift")
        f.symbol(useCase, "LoadUser", .struct, refs: 1, refFiles: 1)
        let repository = f.file("App/Data/UserRepositoryImpl.swift")
        f.symbol(repository, "UserRepositoryImpl", .class, refs: 1, refFiles: 1)
        f.depend(userView, user)
        f.depend(user, userView)          // Models → Presentation: medium
        f.depend(useCase, repository)     // Domain → Data: low
        let analysis = f.analyze()
        let violations = analysis.diagnostics("boundary-violation")
        #expect(violations.count == 2)
        #expect(violations.first { $0.targets.first?.path == "App/Models/User.swift" }?.severity == .medium)
        #expect(violations.first { $0.targets.first?.path == "App/Domain/LoadUser.swift" }?.severity == .low)
        let factor = analysis.category(.boundaries)?.factors.first { $0.label == "Layer violations" }
        #expect(factor != nil && factor!.impact < 0)
    }

    @Test("Files that combine UI, persistence, payments and networking are flagged")
    func mixedConcerns() throws {
        var f = Fixture()
        let file = f.file("App/Checkout/CheckoutScreen.swift", lines: 220, imports: ["SwiftUI", "CoreData", "StoreKit", "Alamofire"])
        f.symbol(file, "CheckoutScreen", .struct, refs: 1, refFiles: 1)
        let small = f.file("App/Checkout/Badge.swift", lines: 20, imports: ["SwiftUI", "CoreData", "StoreKit"])
        f.symbol(small, "Badge", .struct, refs: 1, refFiles: 1)
        let analysis = f.analyze()
        let mixed = analysis.diagnostics("mixed-concerns")
        #expect(mixed.count == 1, "small files are exempt")
        let diagnostic = try #require(mixed.first)
        #expect(diagnostic.severity == .medium)
        #expect(diagnostic.metrics.first?.value == 4)
        #expect(diagnostic.reason.contains("imports StoreKit"))
    }

    @Test("Utility folders and helper files become dumping grounds")
    func dumpingGrounds() throws {
        var f = Fixture()
        for index in 0..<14 {
            let id = f.file("App/Utils/Helper\(index).swift", lines: 30)
            f.symbol(id, "helper\(index)", .function, refs: 1, refFiles: 1)
        }
        let helpers = f.file("App/Shared/Helpers.swift", lines: 300)
        for index in 0..<30 { f.symbol(helpers, "format\(index)", .function, lines: (index * 8 + 1)...(index * 8 + 6), refs: 1, refFiles: 1) }
        let analysis = f.analyze()
        let grounds = analysis.diagnostics("utility-dumping-ground")
        #expect(grounds.contains { $0.targets.first?.kind == .directory && $0.targets.first?.path == "App/Utils" })
        #expect(grounds.contains { $0.targets.first?.path == "App/Shared/Helpers.swift" })
        #expect((analysis.category(.organization)?.score ?? 100) < 100)
    }

    @Test("Structurally identical function bodies are grouped as duplicates")
    func duplicateCode() throws {
        var f = Fixture()
        let hash: UInt64 = 0xDEAD_BEEF
        for index in 0..<3 {
            let id = f.file("Sources/Module\(index)/Loader\(index).swift", lines: 60)
            f.symbol(id, "load", .function, lines: 10...29, bodyHash: hash, refs: 1, refFiles: 1)
        }
        let unique = f.file("Sources/Other.swift")
        f.symbol(unique, "load", .function, lines: 1...20, bodyHash: 42, refs: 1, refFiles: 1)
        let short = f.file("Sources/Short.swift")
        f.symbol(short, "tiny", .function, lines: 1...3, bodyHash: 7, refs: 1)
        f.symbol(short, "tiny2", .function, lines: 4...6, bodyHash: 7, refs: 1)
        let analysis = f.analyze()
        let duplicates = analysis.diagnostics("duplicate-code")
        #expect(duplicates.count == 1, "short bodies are ignored")
        let group = try #require(duplicates.first)
        #expect(group.severity == .medium)
        #expect(group.targets.count == 3)
        #expect(group.targets.allSatisfy { $0.kind == .symbol && $0.symbol == "load" })
        #expect(group.metrics.first { $0.name == "copies" }?.value == 3)
    }

    @Test("Unused files and symbols respect entry points, tests and framework conventions")
    func unusedCode() throws {
        var f = Fixture()
        let main = f.file("App/MainApp.swift", entry: true)
        f.symbol(main, "MainApp", .struct, attributes: ["@main"], refs: 0)
        let used = f.file("App/Used.swift")
        f.symbol(used, "Used", .struct, refs: 2, refFiles: 1)
        f.depend(main, used)
        let orphan = f.file("App/Orphan.swift", lines: 90)
        f.symbol(orphan, "Orphan", .struct, refs: 0)
        let referencedNoEdge = f.file("App/Referenced.swift")
        f.symbol(referencedNoEdge, "Referenced", .struct, refs: 1, refFiles: 1)
        let tests = f.file("Tests/OrphanTests.swift")
        f.symbol(tests, "OrphanTests", .class, inherits: ["XCTestCase"], refs: 0)
        let controller = f.file("App/Legacy/LegacyViewController.swift")
        f.symbol(controller, "LegacyViewController", .class, inherits: ["UIViewController"], refs: 0)

        // Symbols in a used file.
        let owner = f.file("App/Profile/ProfileModel.swift")
        let model = f.symbol(owner, "ProfileModel", .class, refs: 3, refFiles: 1)
        f.depend(used, owner)
        f.symbol(owner, "deadHelper", .method, parent: model, visibility: .private, refs: 0)
        f.symbol(owner, "viewDidLoad", .method, parent: model, attributes: ["override"], refs: 0)
        f.symbol(owner, "tapped", .method, parent: model, attributes: ["@objc"], refs: 0)
        f.symbol(owner, "publicAPI", .method, parent: model, visibility: .public, refs: 0)
        f.symbol(owner, "body", .method, parent: model, refs: 0)
        let proto = f.symbol(owner, "Refreshing", .protocol, refs: 1, refFiles: 1)
        f.symbol(owner, "refresh", .method, parent: proto, refs: 0)
        f.symbol(owner, "refresh", .method, parent: model, refs: 0)                 // protocol requirement
        let conforming = f.symbol(owner, "DataSource", .class, inherits: ["UITableViewDataSource"], refs: 1, refFiles: 1)
        f.symbol(owner, "numberOfRows", .method, parent: conforming, refs: 0)      // external protocol member
        f.symbol(owner, "UnusedType", .struct, visibility: .private, refs: 0)

        let python = f.file("service/routes.py")
        f.symbol(python, "_unused_helper", .function, refs: 0)
        f.symbol(python, "index", .function, attributes: ["@app.route"], refs: 0)
        f.symbol(python, "public_function", .function, exported: true, refs: 0)
        f.depend(used, python)

        let analysis = f.analyze()
        let unusedFiles = Set(analysis.unused.files.filter { $0.confidence >= 0.5 }.map(\.path))
        #expect(unusedFiles == ["App/Orphan.swift"], "\(unusedFiles)")
        #expect(analysis.unused.files.first { $0.path == "App/Legacy/LegacyViewController.swift" }?.confidence ?? 0 < 0.5)
        #expect(analysis.diagnostics("unused-file").map { $0.targets.first?.path } == ["App/Orphan.swift"])

        let unusedSymbols = Set(analysis.unused.symbols.map { $0.symbol ?? "" })
        #expect(unusedSymbols.contains("ProfileModel.deadHelper"))
        #expect(unusedSymbols.contains("UnusedType"))
        #expect(unusedSymbols.contains("_unused_helper"))
        for excluded in ["ProfileModel.viewDidLoad", "ProfileModel.tapped", "ProfileModel.publicAPI", "ProfileModel.body", "ProfileModel.refresh", "Refreshing.refresh", "DataSource.numberOfRows", "index", "public_function", "Orphan"] {
            #expect(!unusedSymbols.contains(excluded), "\(excluded) should be excluded")
        }
        let perFile = try #require(analysis.diagnostics("unused-symbols").first { $0.targets.first?.path == "App/Profile/ProfileModel.swift" })
        #expect(perFile.metrics.first?.value == 2)
        #expect(!analysis.unused.note.isEmpty)
        #expect((analysis.category(.deadCode)?.score ?? 100) < 100)
    }

    @Test("MVVM is inferred from view models, views and services with evidence")
    func architectureMVVM() throws {
        let analysis = Fixture.tidyApp().analyze()
        let mvvm = try #require(analysis.pattern("MVVM"))
        #expect(mvvm.confidence >= 0.75, "\(mvvm)")
        #expect(mvvm.evidence.contains { $0.contains("ViewModel") })
        #expect(mvvm.evidence.contains { $0.contains("observable") })
        #expect(mvvm.paths?.contains("App/Features/Volumes/VolumeListViewModel.swift") == true)
        #expect(analysis.architecture.frameworks.first == "SwiftUI")
        #expect(analysis.architecture.summary.hasPrefix("Likely MVVM SwiftUI app"), "\(analysis.architecture.summary)")
        #expect(analysis.architecture.entryPoints.first == "App/ShelfApp.swift")
        let feature = try #require(analysis.pattern("Feature-based modularization"))
        #expect(feature.evidence.first?.contains("Settings") == true)
        #expect(!analysis.architecture.areas.isEmpty)
        #expect(analysis.architecture.layers.contains { $0.name == "ViewModels" })
    }

    @Test("TCA is inferred from ComposableArchitecture imports and @Reducer types")
    func architectureTCA() throws {
        var f = Fixture()
        for name in ["Counter", "Settings", "Search"] {
            let id = f.file("App/\(name)/\(name)Feature.swift", imports: ["ComposableArchitecture", "SwiftUI"])
            f.symbol(id, "\(name)Feature", .struct, attributes: ["@Reducer"], refs: 1, refFiles: 1)
        }
        f.manifest = ["swift-composable-architecture"]
        let analysis = f.analyze()
        let tca = try #require(analysis.pattern("TCA (The Composable Architecture)"))
        #expect(tca.confidence >= 0.9)
        #expect(tca.evidence.contains { $0.contains("import ComposableArchitecture") })
        #expect(tca.evidence.contains { $0.contains("@Reducer") })
        #expect(analysis.pattern("Redux-style state management") == nil)
        #expect(analysis.architecture.frameworks.contains("The Composable Architecture"))
    }

    @Test("Clean Architecture is inferred from layers, use cases and repository abstractions")
    func architectureClean() throws {
        var f = Fixture()
        let entity = f.file("Domain/Entities/OrderEntity.swift")
        f.symbol(entity, "OrderEntity", .struct, refs: 3, refFiles: 2)
        let useCase = f.file("Domain/UseCases/PlaceOrderUseCase.swift")
        f.symbol(useCase, "PlaceOrderUseCase", .struct, refs: 1, refFiles: 1)
        let repoProtocol = f.file("Domain/Repositories/OrderRepository.swift")
        f.symbol(repoProtocol, "OrderRepository", .protocol, refs: 2, refFiles: 2)
        let repoImpl = f.file("Data/Repositories/RemoteOrderRepository.swift")
        f.symbol(repoImpl, "RemoteOrderRepository", .class, inherits: ["OrderRepository"], refs: 1, refFiles: 1)
        let view = f.file("Presentation/OrderView.swift", imports: ["SwiftUI"])
        f.symbol(view, "OrderView", .struct, refs: 1, refFiles: 1)
        f.depend(useCase, repoProtocol)
        f.depend(useCase, entity)
        f.depend(repoImpl, repoProtocol)
        f.depend(view, useCase)
        let analysis = f.analyze()
        let clean = try #require(analysis.pattern("Clean Architecture"))
        #expect(clean.confidence >= 0.75, "\(clean)")
        #expect(clean.evidence.contains { $0.contains("Domain") && $0.contains("Data") && $0.contains("Presentation") })
        #expect(clean.evidence.contains { $0.contains("use case") })
        #expect(analysis.pattern("Repository pattern") != nil)
    }

    @Test("A cohesive, loosely coupled group is suggested for extraction")
    func extractionSuggestion() throws {
        var f = Fixture()
        var billing: [Int64] = []
        for index in 0..<8 {
            let id = f.file("App/Features/Billing/Billing\(index).swift", lines: 60)
            f.symbol(id, "Billing\(index)", .struct, refs: 2, refFiles: 1)
            billing.append(id)
        }
        for index in 0..<8 {
            f.depend(billing[index], billing[(index + 1) % 8 == 0 ? 7 : (index + 1)])
            if index + 2 < 8 { f.depend(billing[index], billing[index + 2]) }
        }
        let shared = f.file("App/Core/Money.swift")
        f.symbol(shared, "Money", .struct, refs: 4, refFiles: 3)
        f.depend(billing[3], shared)
        var others: [Int64] = []
        for index in 0..<14 {
            let id = f.file("App/Features/Feed/Feed\(index).swift")
            f.symbol(id, "Feed\(index)", .struct, refs: 1, refFiles: 1)
            if let previous = others.last { f.depend(id, previous) }
            others.append(id)
        }
        f.depend(others[0], billing[0])
        f.depend(others[5], billing[0])
        let analysis = f.analyze()
        let suggestion = try #require(analysis.suggestions.first { $0.rootPath == "App/Features/Billing" || $0.name == "Billing" })
        #expect(suggestion.files.count == 8)
        #expect(suggestion.cohesion >= 0.7, "\(suggestion)")
        #expect(suggestion.externalDependencies == 1)
        #expect(suggestion.externalDependents == 2)
        #expect(suggestion.entryPoints == ["App/Features/Billing/Billing0.swift"])
        #expect(suggestion.reasons.contains { $0.contains("Only 1 external dependency") })
        #expect(!suggestion.benefits.isEmpty && !suggestion.risks.isEmpty)
        #expect(analysis.diagnostics("extraction-candidate").contains { $0.title.contains(suggestion.name) })
    }

    @Test("Identical input produces identical output, independent of input order")
    func determinism() throws {
        var f = Fixture.tidyApp()
        let extra = f.file("App/Features/Volumes/VolumeMapView.swift", lines: 420, imports: ["SwiftUI", "MapKit", "CoreData", "StoreKit"])
        f.symbol(extra, "VolumeMapView", .struct, lines: 1...400, refs: 0)
        f.depend(extra, f.files[1].id)
        f.depend(f.files[1].id, extra)
        let (snapshot, graph) = f.build()
        let engine = HealthEngine()
        let first = try VesaliusJSON.string(engine.analyze(snapshot: snapshot, graph: graph))
        let second = try VesaliusJSON.string(HealthEngine().analyze(snapshot: snapshot, graph: graph))
        #expect(first == second)
        var shuffled = snapshot
        var generator = SeededGenerator(seed: 7)
        shuffled.files.shuffle(using: &generator)
        shuffled.symbols.shuffle(using: &generator)
        shuffled.edges.shuffle(using: &generator)
        let third = try VesaliusJSON.string(engine.analyze(snapshot: shuffled, graph: graph))
        #expect(first == third)
    }

    @Test("An empty repository produces an empty, explained report")
    func emptyRepository() throws {
        let analysis = Fixture().analyze()
        #expect(analysis.diagnostics.isEmpty)
        #expect(analysis.report.grade == "Unknown")
        #expect(analysis.suggestions.isEmpty)
        #expect(analysis.unused.files.isEmpty && analysis.unused.symbols.isEmpty)
        #expect(analysis.architecture.patterns.isEmpty)
        #expect(analysis.architecture.summary == "No source code to analyse yet.")
    }

    @Test("A 20,000-file repository is analysed quickly")
    func largeRepositoryPerformance() throws {
        var f = Fixture()
        var generator = SeededGenerator(seed: 42)
        let areas = 40, perArea = 500
        var ids: [[Int64]] = []
        for area in 0..<areas {
            var areaIDs: [Int64] = []
            for index in 0..<perArea {
                let sub = index % 5
                let id = f.file("Sources/Area\(area)/Sub\(sub)/File\(area)_\(index).swift", lines: 40 + (index * 37) % 900, complexity: 3 + index % 40, imports: index % 50 == 0 ? ["SwiftUI", "CoreData", "Alamofire"] : ["Foundation"])
                let type = f.symbol(id, "Type\(area)_\(index)", .class, lines: 1...(20 + (index * 13) % 700), refs: index % 7 == 0 ? 0 : 3, refFiles: index % 7 == 0 ? 0 : 2)
                f.symbol(id, "method\(area)_\(index)", .method, lines: 2...(10 + index % 120), parent: type, complexity: 1 + index % 30, bodyHash: UInt64(index % 900), refs: index % 3)
                areaIDs.append(id)
            }
            ids.append(areaIDs)
        }
        for area in 0..<areas {
            for (index, id) in ids[area].enumerated() {
                for _ in 0..<2 {
                    let target = ids[area][Int.random(in: 0..<perArea, using: &generator)]
                    if target != id { f.depend(id, target) }
                }
                if index % 10 == 0 {
                    let otherArea = Int.random(in: 0..<areas, using: &generator)
                    f.depend(id, ids[otherArea][Int.random(in: 0..<perArea, using: &generator)])
                }
            }
        }
        // Build graph metrics directly (GraphAnalysis on 20k nodes is benchmarked separately).
        var fanIn: [Int64: Int] = [:], fanOut: [Int64: Int] = [:]
        var seen = Set<HealthContextPairKey>()
        for edge in f.edges where seen.insert(HealthContextPairKey(a: edge.source, b: edge.target)).inserted {
            fanOut[edge.source, default: 0] += 1
            fanIn[edge.target, default: 0] += 1
        }
        var metrics: [Int64: FileGraphMetrics] = [:]
        for file in f.files {
            var m = FileGraphMetrics()
            m.fanIn = fanIn[file.id] ?? 0
            m.fanOut = fanOut[file.id] ?? 0
            m.transitiveDependents = m.fanIn * 40
            m.centrality = Double(m.fanIn) / 20
            metrics[file.id] = m
        }
        let cycles = (0..<30).map { area in Array(ids[area].prefix(4)) }
        let clusters = (0..<areas).map { RepositorySnapshot.Cluster(id: $0, fileIDs: ids[$0], label: "Area\($0)") }
        let graph = GraphAnalysis(
            metrics: metrics,
            hotspotScores: [:],
            cycles: cycles,
            cyclePaths: cycles.map { $0 + [$0[0]] },
            clusters: clusters,
            longestChain: Array(ids[0].prefix(14))
        )
        let snapshot = RepositorySnapshot(repositoryName: "Large", files: f.files, symbols: f.symbols, edges: f.edges, modules: [], metrics: metrics, cycles: cycles, clusters: clusters, manifestDependencies: [])
        let start = Date()
        let analysis = HealthEngine().analyze(snapshot: snapshot, graph: graph)
        let duration = Date().timeIntervalSince(start)
        print("HealthEngine: \(f.files.count) files, \(f.symbols.count) symbols, \(f.edges.count) edges analysed in \(String(format: "%.2f", duration))s → \(analysis.diagnostics.count) diagnostics, score \(analysis.report.score)")
        #expect(f.files.count == 20_000)
        #expect(duration < 60, "took \(duration)s")
        #expect(analysis.diagnostics.count <= HealthConfiguration.default.maxDiagnostics)
        #expect(analysis.category(.cycles)?.factors.contains { $0.impact < 0 } == true)
        #expect(analysis.report.categories.count == 8)
    }
}

private struct HealthContextPairKey: Hashable {
    let a: Int64
    let b: Int64
}

/// Deterministic random numbers for reproducible fixtures.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
