import Foundation
@testable import RepositoryIndex
import Testing
import VesaliusCore

/// Linker v4 on hand-built analyses shaped like the Swift collector's output (receiver hints, `receiver_ref`
/// chains, declared types, selectors): typed resolution, access rules, labels, implicit members,
/// externals, tuples, determinism and incremental invalidation.
@Suite("Linker v4: typed resolution, access, labels, implicit members, externals", .serialized)
struct LinkerV4Tests {
    // MARK: Typed receivers

    @Test("A receiver typed as a protocol resolves to the requirement")
    func protocolRequirement() throws {
        let index = try LinkIndex("protocol")
        try index.write("Sources/Embedding.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "EmbeddingProvider", kind: .protocol, range: LineRange(1, 3)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "embed", kind: .method, range: LineRange(2, 2), selector: "embed(_:)", parameterFlags: "-", declaredType: "[Float]"),
            ExtractedSymbol(localID: 2, name: "MiniLM", kind: .struct, range: LineRange(5, 7), inheritedTypes: ["EmbeddingProvider"]),
            ExtractedSymbol(localID: 3, parentLocalID: 2, name: "embed", kind: .method, range: LineRange(6, 6), selector: "embed(_:)", parameterFlags: "-"),
        ], references: [
            ExtractedReference(name: "EmbeddingProvider", kind: .conform, line: 5, column: 15, enclosingSymbol: 2),
        ])
        try index.write("Sources/Orchestrator.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Orchestrator", kind: .struct, range: LineRange(1, 6)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "remember", kind: .method, range: LineRange(2, 5)),
        ], references: [
            // `embedder: some EmbeddingProvider` is a parameter: the collector hints its type.
            ExtractedReference(name: "embed", kind: .call, line: 3, column: 26, enclosingSymbol: 1, receiver: "embedder",
                               argumentLabels: ["_"], receiverHint: "EmbeddingProvider", typeEvidenceLine: 2),
        ])
        try index.module("App", root: "Sources")
        try index.link()
        let site = try index.site("embed", line: 3, in: "Sources/Orchestrator.swift")
        #expect(site.target == "EmbeddingProvider.embed" && site.basis == "typed" && site.confidence == 0.9)
        #expect(site.receiverType == "EmbeddingProvider")
        #expect(site.evidence == 2, "the collector's evidence line is kept")
    }

    @Test("`super` starts at the superclass, and inherited helpers resolve through it")
    func superclassAndSuper() throws {
        let index = try LinkIndex("super")
        try index.write("Sources/Base.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Base", kind: .class, range: LineRange(1, 4)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "setUp", kind: .method, range: LineRange(2, 2), selector: "setUp()", parameterFlags: ""),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "helper", kind: .method, range: LineRange(3, 3), selector: "helper()", parameterFlags: ""),
        ])
        try index.write("Sources/Child.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Child", kind: .class, range: LineRange(1, 7), inheritedTypes: ["Base"]),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "setUp", kind: .method, range: LineRange(2, 6), attributes: ["override"],
                            selector: "setUp()", parameterFlags: ""),
        ], references: [
            ExtractedReference(name: "Base", kind: .inherit, line: 1, column: 20, enclosingSymbol: 0),
            ExtractedReference(name: "setUp", kind: .call, line: 3, column: 15, enclosingSymbol: 1, receiver: "super", argumentLabels: []),
            ExtractedReference(name: "helper", kind: .call, line: 4, column: 9, enclosingSymbol: 1, argumentLabels: []),
        ])
        try index.module("App", root: "Sources")
        try index.link()
        let superCall = try index.site("setUp", line: 3, in: "Sources/Child.swift")
        #expect(superCall.target == "Base.setUp" && superCall.targetPath == "Sources/Base.swift")
        #expect(superCall.basis == "self" && superCall.confidence == 0.85)
        let inherited = try index.site("helper", line: 4, in: "Sources/Child.swift")
        #expect(inherited.target == "Base.helper" && inherited.basis == "self")
        #expect(try index.scalar("SELECT COUNT(*) FROM refs WHERE receiver = 'super' AND target_symbol_id = from_symbol_id") == 0)
    }

    @Test("Extensions join the type they extend by identity, not by name")
    func extensionIdentity() throws {
        let index = try LinkIndex("extensions")
        try index.write("Sources/Kit/Settings.swift", symbols: [ExtractedSymbol(localID: 0, name: "Settings", kind: .struct, range: LineRange(1, 1))])
        try index.write("Sources/Kit/Panel.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Panel", kind: .struct, range: LineRange(1, 5)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "show", kind: .method, range: LineRange(2, 4)),
        ], references: [
            ExtractedReference(name: "theme", kind: .call, line: 3, column: 22, enclosingSymbol: 1, receiver: "settings", argumentLabels: [], receiverHint: "Settings"),
        ])
        try index.write("Sources/App/Settings.swift", symbols: [ExtractedSymbol(localID: 0, name: "Settings", kind: .struct, range: LineRange(1, 1))])
        try index.write("Sources/App/Settings+Theme.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Settings", kind: .extension, range: LineRange(1, 3)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "theme", kind: .method, range: LineRange(2, 2), selector: "theme()", parameterFlags: ""),
        ])
        try index.write("Sources/App/Screen.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Screen", kind: .struct, range: LineRange(1, 5)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "render", kind: .method, range: LineRange(2, 4)),
        ], references: [
            ExtractedReference(name: "theme", kind: .call, line: 3, column: 22, enclosingSymbol: 1, receiver: "settings", argumentLabels: [], receiverHint: "Settings"),
        ])
        try index.module("Kit", root: "Sources/Kit")
        try index.module("App", root: "Sources/App")
        try index.link()
        let app = try index.site("theme", line: 3, in: "Sources/App/Screen.swift")
        #expect(app.target == "Settings.theme" && app.targetPath == "Sources/App/Settings+Theme.swift" && app.basis == "typed" && app.confidence == 0.95)
        // Kit's own `Settings` has no `theme`: the App extension of a different type must not answer.
        let kit = try index.site("theme", line: 3, in: "Sources/Kit/Panel.swift")
        #expect(kit.target == nil && !kit.isExternal && kit.receiverType == "Settings")
    }

    @Test("A tuple-typed receiver resolves its element without a declaration")
    func tupleReceiver() throws {
        let index = try LinkIndex("tuple")
        try index.write("Sources/Classifier.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Classifier", kind: .struct, range: LineRange(1, 8)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "classifyBook", kind: .method, range: LineRange(2, 2),
                            selector: "classifyBook()", parameterFlags: "", declaredType: "(label: String, reason: String)"),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "describe", kind: .method, range: LineRange(4, 7)),
            // Another type's `reason`: the guess a name-only linker would make.
            ExtractedSymbol(localID: 3, name: "Failure", kind: .struct, range: LineRange(10, 12)),
            ExtractedSymbol(localID: 4, parentLocalID: 3, name: "reason", kind: .property, range: LineRange(11, 11)),
        ], references: [
            ExtractedReference(name: "classifyBook", kind: .call, line: 5, column: 21, enclosingSymbol: 2, argumentLabels: []),
            ExtractedReference(name: "reason", kind: .read, line: 6, column: 18, enclosingSymbol: 2, receiver: "result", receiverHint: "^", receiverRef: 0, typeEvidenceLine: 5),
        ])
        try index.link()
        let element = try index.site("reason", line: 6, in: "Sources/Classifier.swift")
        #expect(element.resolved && element.target == nil && element.receiverType == "(tuple)" && element.basis == "typed")
        #expect(element.alt == "Failure.reason", "the name-only guess is kept as a rejected lookalike")
    }

    @Test("A receiver chain types through declarations in other files: property, static member, instantiation")
    func declaredTypeChain() throws {
        let index = try LinkIndex("chain")
        try index.write("Sources/PremiumStore.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "PremiumStore", kind: .class, range: LineRange(1, 10)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "shared", kind: .property, range: LineRange(2, 2), attributes: ["static"],
                            declaredType: "^", declaredTypeRef: 0),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "start", kind: .method, range: LineRange(4, 6), selector: "start()", parameterFlags: ""),
        ], references: [
            ExtractedReference(name: "PremiumStore", kind: .instantiate, line: 2, column: 25, enclosingSymbol: 1, context: "call", argumentLabels: []),
        ])
        try index.write("Sources/Paywall.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Paywall", kind: .struct, range: LineRange(1, 9)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "start", kind: .method, range: LineRange(2, 2), visibility: .private, selector: "start()", parameterFlags: ""),
        ])
        try index.write("Sources/ContentView.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "ContentView", kind: .struct, range: LineRange(1, 9)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "subscriptions", kind: .property, range: LineRange(2, 2), declaredType: "^", declaredTypeRef: 1),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "body", kind: .property, range: LineRange(4, 8)),
        ], references: [
            ExtractedReference(name: "PremiumStore", kind: .typeUse, line: 2, column: 30, enclosingSymbol: 1, context: "type"),
            ExtractedReference(name: "shared", kind: .read, line: 2, column: 50, enclosingSymbol: 1, receiver: "PremiumStore"),
            // `subscriptions.start()`: the member's receiver is the read of the property.
            ExtractedReference(name: "start", kind: .call, line: 6, column: 31, enclosingSymbol: 2, receiver: "subscriptions", argumentLabels: [], receiverRef: 3),
            ExtractedReference(name: "subscriptions", kind: .read, line: 6, column: 17, enclosingSymbol: 2),
        ])
        try index.module("App", root: "Sources")
        try index.link()
        let start = try index.site("start", line: 6, in: "Sources/ContentView.swift")
        #expect(start.target == "PremiumStore.start" && start.basis == "typed" && start.confidence == 0.95)
        #expect(start.receiverType == "PremiumStore")
        #expect(start.evidence == 2, "typed through `subscriptions`, declared on line 2 of the same file")
        let shared = try index.site("shared", line: 2, in: "Sources/ContentView.swift")
        #expect(shared.target == "PremiumStore.shared" && shared.basis == "static" && shared.confidence == 0.88)
    }

    // MARK: Access

    @Test("Private declarations never answer from another file; the same file still sees them")
    func privateCrossFile() throws {
        let index = try LinkIndex("private")
        try index.write("Sources/Paywall.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "PaywallView", kind: .struct, range: LineRange(1, 6)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "presentSheet", kind: .method, range: LineRange(2, 2), visibility: .private,
                            selector: "presentSheet()", parameterFlags: ""),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "footer", kind: .method, range: LineRange(3, 5)),
        ], references: [
            ExtractedReference(name: "presentSheet", kind: .call, line: 4, column: 9, enclosingSymbol: 2, argumentLabels: []),
        ])
        try index.write("Tests/SharedDropTests.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "testShare", kind: .function, range: LineRange(1, 4)),
        ], references: [
            ExtractedReference(name: "presentSheet", kind: .call, line: 2, column: 13, enclosingSymbol: 0, receiver: "browser", argumentLabels: []),
        ])
        try index.link()
        #expect(try index.site("presentSheet", line: 4, in: "Sources/Paywall.swift").target == "PaywallView.presentSheet")
        #expect(try index.site("presentSheet", line: 2, in: "Tests/SharedDropTests.swift").target == nil)
        #expect(try index.scalar("""
            SELECT COUNT(*) FROM refs r JOIN symbols s ON s.id = r.target_symbol_id
            WHERE r.file_id != s.file_id AND s.visibility IN ('private', 'fileprivate')
            """) == 0)
    }

    @Test("A Python subclass reaches its base class's underscore methods through `self`, across files")
    func pythonUnderscoreInheritance() throws {
        let index = try LinkIndex("python")
        try index.write("app/base.py", .python, symbols: [
            ExtractedSymbol(localID: 0, name: "Base", kind: .class, range: LineRange(1, 3), isExported: true),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "_helper", kind: .method, range: LineRange(2, 3), visibility: .private),
        ])
        try index.write("app/child.py", .python, symbols: [
            ExtractedSymbol(localID: 0, name: "Child", kind: .class, range: LineRange(3, 6), inheritedTypes: ["Base"]),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "run", kind: .method, range: LineRange(4, 6)),
        ], references: [
            ExtractedReference(name: "Base", kind: .inherit, line: 3, column: 13, enclosingSymbol: 0),
            ExtractedReference(name: "_helper", kind: .call, line: 5, column: 14, enclosingSymbol: 1, receiver: "self"),
        ], imports: [ExtractedImport(module: ".base", kind: .relative, names: [ImportedName(name: "Base")], line: 1)])
        try index.store.db.run("UPDATE imports SET resolved_file_id = (SELECT id FROM files WHERE path = 'app/base.py')")
        try index.link()
        #expect(try index.site("Base", line: 3, in: "app/child.py").target == "Base")
        let helper = try index.site("_helper", line: 5, in: "app/child.py")
        #expect(helper.target == "Base._helper" && helper.basis == "self", "a leading underscore is a convention, not an access level")
    }

    @Test("Across modules, internal declarations need `@testable import`; app code never reaches into tests")
    func testableImports() throws {
        let index = try LinkIndex("testable")
        try index.write("Sources/App/Store.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Store", kind: .struct, range: LineRange(1, 3)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "reload", kind: .method, range: LineRange(2, 2), selector: "reload()", parameterFlags: ""),
            ExtractedSymbol(localID: 2, name: "PublicStore", kind: .struct, range: LineRange(5, 5), visibility: .public, isExported: true),
            ExtractedSymbol(localID: 3, name: "boot", kind: .function, range: LineRange(7, 9)),
        ], references: [
            ExtractedReference(name: "StoreFixture", kind: .instantiate, line: 8, column: 5, enclosingSymbol: 3, context: "call", argumentLabels: []),
        ])
        try index.write("Tests/AppTests/StoreTests.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "testReload", kind: .function, range: LineRange(3, 7)),
        ], references: [
            ExtractedReference(name: "Store", kind: .instantiate, line: 4, column: 21, enclosingSymbol: 0, context: "call", argumentLabels: []),
            ExtractedReference(name: "reload", kind: .call, line: 5, column: 11, enclosingSymbol: 0, receiver: "store", argumentLabels: [],
                               receiverHint: "Store", typeEvidenceLine: 4),
        ], imports: [ExtractedImport(module: "App", kind: .module, line: 1, isTestable: true)])
        try index.write("Tests/AppTests/StoreFixture.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "StoreFixture", kind: .struct, range: LineRange(1, 1)),
        ])
        try index.write("Tests/PlainTests/PlainTests.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "testPlain", kind: .function, range: LineRange(3, 6)),
        ], references: [
            ExtractedReference(name: "Store", kind: .instantiate, line: 4, column: 13, enclosingSymbol: 0, context: "call", argumentLabels: []),
            ExtractedReference(name: "PublicStore", kind: .instantiate, line: 5, column: 13, enclosingSymbol: 0, context: "call", argumentLabels: []),
        ], imports: [ExtractedImport(module: "App", kind: .module, line: 1)])
        try index.module("App", root: "Sources/App")
        try index.module("AppTests", root: "Tests/AppTests")
        try index.module("PlainTests", root: "Tests/PlainTests")
        try index.link()

        #expect(try index.site("Store", line: 4, in: "Tests/AppTests/StoreTests.swift").target == "Store")
        let reload = try index.site("reload", line: 5, in: "Tests/AppTests/StoreTests.swift")
        #expect(reload.target == "Store.reload" && reload.basis == "typed")
        #expect(try index.site("Store", line: 4, in: "Tests/PlainTests/PlainTests.swift").target == nil, "internal without @testable")
        #expect(try index.site("PublicStore", line: 5, in: "Tests/PlainTests/PlainTests.swift").target == "PublicStore")
        #expect(try index.site("StoreFixture", line: 8, in: "Sources/App/Store.swift").target == nil, "app code never names test-only code")
    }

    @Test("Target membership decides visibility; a UI-test bundle sees nothing of the app it drives")
    func targetMembership() throws {
        let index = try LinkIndex("targets")
        try index.write("App/Model.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Model", kind: .struct, range: LineRange(1, 3)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "refresh", kind: .method, range: LineRange(2, 2)),
        ])
        try index.write("Shared/Constants.swift", symbols: [ExtractedSymbol(localID: 0, name: "Constants", kind: .enum, range: LineRange(1, 1))])
        try index.write("Widget/Card.swift", symbols: [ExtractedSymbol(localID: 0, name: "card", kind: .function, range: LineRange(1, 4))], references: [
            ExtractedReference(name: "Model", kind: .instantiate, line: 2, column: 9, enclosingSymbol: 0, context: "call", argumentLabels: []),
            ExtractedReference(name: "Constants", kind: .typeUse, line: 3, column: 9, enclosingSymbol: 0, context: "type"),
        ])
        try index.write("AppUITests/FlowTests.swift", symbols: [ExtractedSymbol(localID: 0, name: "testFlow", kind: .function, range: LineRange(1, 4))], references: [
            ExtractedReference(name: "Model", kind: .instantiate, line: 2, column: 9, enclosingSymbol: 0, context: "call", argumentLabels: []),
            ExtractedReference(name: "Constants", kind: .typeUse, line: 3, column: 9, enclosingSymbol: 0, context: "type"),
        ])
        // Three targets of one Xcode project; Shared/Constants.swift is a member of all three.
        let app = try index.target("App", files: ["App/Model.swift", "Shared/Constants.swift"])
        let widget = try index.target("Widget", files: ["Widget/Card.swift", "Shared/Constants.swift"])
        let ui = try index.target("AppUITests", files: ["AppUITests/FlowTests.swift", "Shared/Constants.swift"], isTest: true, testKind: "ui")
        try index.module("App", root: "App", kind: "xcode-target", manifest: "App.xcodeproj")
        try index.module("Widget", root: "Widget", kind: "xcode-target", manifest: "App.xcodeproj")
        try index.module("AppUITests", root: "AppUITests", kind: "xcode-target", manifest: "App.xcodeproj")
        #expect(Set([app, widget, ui]).count == 3)
        try index.link()

        // The widget shares no target with App/Model.swift and does not import App: not visible, despite one project
        // (only v3's below-threshold "declared in a module this file never imports" guess remains).
        let model = try index.site("Model", line: 2, in: "Widget/Card.swift")
        #expect(model.confidence < ReferenceLinker.edgeThreshold)
        #expect(try index.site("Constants", line: 3, in: "Widget/Card.swift").target == "Constants")
        #expect(try index.site("Model", line: 2, in: "AppUITests/FlowTests.swift").target == nil)
        #expect(try index.site("Constants", line: 3, in: "AppUITests/FlowTests.swift").target == "Constants", "a shared target is visible")
    }

    @Test("A function-local type answers only inside its function")
    func localTypeScope() throws {
        let index = try LinkIndex("local")
        try index.write("Sources/Parser.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Parser", kind: .struct, range: LineRange(1, 20)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "parse", kind: .method, range: LineRange(2, 10)),
            ExtractedSymbol(localID: 2, parentLocalID: 1, name: "Section", kind: .struct, range: LineRange(3, 5), isLocal: true),
            ExtractedSymbol(localID: 3, parentLocalID: 2, name: "month", kind: .property, range: LineRange(4, 4), isLocal: true),
            ExtractedSymbol(localID: 4, parentLocalID: 0, name: "other", kind: .method, range: LineRange(12, 18)),
        ], references: [
            ExtractedReference(name: "month", kind: .read, line: 7, column: 15, enclosingSymbol: 1, receiver: "section"),
            ExtractedReference(name: "month", kind: .read, line: 8, column: 15, enclosingSymbol: 1, receiver: "first", receiverHint: "Section", typeEvidenceLine: 6),
            ExtractedReference(name: "month", kind: .read, line: 15, column: 15, enclosingSymbol: 4, receiver: "c"),
        ])
        try index.link()
        let inside = try index.site("month", line: 7, in: "Sources/Parser.swift")
        #expect(inside.target == "Parser.parse.Section.month" && inside.confidence == 0.6, "corroborated by the receiver's name")
        let typed = try index.site("month", line: 8, in: "Sources/Parser.swift")
        #expect(typed.target == "Parser.parse.Section.month" && typed.basis == "typed" && typed.confidence == 0.95)
        #expect(try index.site("month", line: 15, in: "Sources/Parser.swift").target == nil, "outside parse(), Section does not exist")
    }

    // MARK: Labels

    @Test("Argument labels choose an overload; defaulted and closure parameters follow the selector's flags")
    func labelsChooseOverloads() throws {
        let index = try LinkIndex("labels")
        try index.write("Sources/Embedder.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Embedder", kind: .struct, range: LineRange(1, 20)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "embed", kind: .method, range: LineRange(2, 2), selector: "embed(_:)", parameterFlags: "-"),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "embed", kind: .method, range: LineRange(3, 3), selector: "embed(batch:)", parameterFlags: "-"),
            // `load(force: Bool = false, completion: (() -> Void)? = nil)`: D is defaulted and closure-typed.
            ExtractedSymbol(localID: 3, parentLocalID: 0, name: "load", kind: .method, range: LineRange(4, 4), selector: "load(force:completion:)", parameterFlags: "dD"),
            ExtractedSymbol(localID: 4, parentLocalID: 0, name: "load", kind: .method, range: LineRange(5, 5), selector: "load(id:)", parameterFlags: "-"),
            ExtractedSymbol(localID: 5, parentLocalID: 0, name: "run", kind: .method, range: LineRange(7, 14)),
        ], references: [
            ExtractedReference(name: "embed", kind: .call, line: 8, column: 9, enclosingSymbol: 5, argumentLabels: ["_"]),
            ExtractedReference(name: "embed", kind: .call, line: 9, column: 9, enclosingSymbol: 5, argumentLabels: ["batch"]),
            ExtractedReference(name: "load", kind: .call, line: 10, column: 9, enclosingSymbol: 5, argumentLabels: ["{}"]),
            ExtractedReference(name: "load", kind: .call, line: 11, column: 9, enclosingSymbol: 5, argumentLabels: []),
            ExtractedReference(name: "load", kind: .call, line: 12, column: 9, enclosingSymbol: 5, argumentLabels: ["id"]),
            ExtractedReference(name: "load", kind: .call, line: 13, column: 9, enclosingSymbol: 5, argumentLabels: ["force", "{}"]),
        ])
        try index.link()
        #expect(try index.site("embed", line: 8, in: "Sources/Embedder.swift").targetLine == 2)
        #expect(try index.site("embed", line: 9, in: "Sources/Embedder.swift").targetLine == 3)
        for line in [10, 11, 13] {
            let site = try index.site("load", line: line, in: "Sources/Embedder.swift")
            #expect(site.targetLine == 4 && site.confidence == 0.92, "line \(line)")
        }
        #expect(try index.site("load", line: 12, in: "Sources/Embedder.swift").targetLine == 5)
    }

    @Test("Argument assignment: defaults are skipped, trailing closures fill closure parameters, variadics absorb")
    func argumentAssignment() {
        func assign(_ labels: [String], _ selector: String, _ flags: String, lenient: Bool = false) -> [Int]? {
            ReferenceLinker.assignArguments(labels, to: ReferenceLinker.selectorLabels(selector), flags: Array(flags), lenient: lenient)
        }
        #expect(assign(["_"], "embed(_:)", "-") == [0])
        #expect(assign(["batch"], "embed(_:)", "-") == nil)
        #expect(assign([], "load(force:completion:)", "dD") == [])
        #expect(assign(["{}"], "load(force:completion:)", "dD") == [1])
        #expect(assign(["force", "{}"], "load(force:completion:)", "dD") == [0, 1])
        #expect(assign(["completion"], "load(force:completion:)", "dD") == [1])
        #expect(assign(["{}"], "sheet(isPresented:content:)", "-c") == nil)
        #expect(assign(["isPresented", "{}"], "sheet(isPresented:content:)", "-c") == [0, 1])
        #expect(assign(["{}", "label{}"], "button(action:label:)", "cc") == [0, 1])
        #expect(assign(["_", "_", "_"], "log(_:)", "v") == [0, 0, 0])
        #expect(assign(["_", "separator"], "log(_:separator:)", "vd") == [0, 1])
        #expect(assign(["{}"], "observe(handler:)", "-") == nil)
        #expect(assign(["{}"], "observe(handler:)", "-", lenient: true) == [0], "a closure type hidden behind an alias")
        #expect(ReferenceLinker.selectorLabels("importBook(from:preferences:modelContext:)") == ["from", "preferences", "modelContext"])
        #expect(ReferenceLinker.selectorLabels("reload()") == [])
    }

    // MARK: Implicit members

    @Test("An implicit member resolves on its contextual type; without one only a unique, non-ubiquitous name does")
    func implicitMembers() throws {
        let index = try LinkIndex("implicit")
        try index.write("Sources/WAL.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "WALFlags", kind: .struct, range: LineRange(1, 4), inheritedTypes: ["OptionSet"]),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "isPadding", kind: .property, range: LineRange(2, 2), attributes: ["static"], declaredType: "WALFlags"),
            ExtractedSymbol(localID: 2, name: "Header", kind: .struct, range: LineRange(6, 8)),
            ExtractedSymbol(localID: 3, parentLocalID: 2, name: "flags", kind: .property, range: LineRange(7, 7), declaredType: "WALFlags"),
            ExtractedSymbol(localID: 4, name: "Phase", kind: .enum, range: LineRange(10, 13)),
            ExtractedSymbol(localID: 5, parentLocalID: 4, name: "warmingUp", kind: .enumCase, range: LineRange(11, 11)),
            ExtractedSymbol(localID: 6, parentLocalID: 4, name: "red", kind: .enumCase, range: LineRange(12, 12)),
            ExtractedSymbol(localID: 7, name: "Scheduler", kind: .enum, range: LineRange(14, 16)),
            ExtractedSymbol(localID: 8, parentLocalID: 7, name: "date", kind: .method, range: LineRange(15, 15), attributes: ["static"],
                            selector: "date(of:)", parameterFlags: "-"),
        ])
        try index.write("Sources/Reader.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "scan", kind: .function, range: LineRange(1, 8)),
        ], references: [
            // `header.flags.contains(.isPadding)`, with `header: Header` a parameter.
            ExtractedReference(name: "flags", kind: .read, line: 3, column: 19, enclosingSymbol: 0, receiver: "header", receiverHint: "Header", typeEvidenceLine: 1),
            ExtractedReference(name: "contains", kind: .call, line: 3, column: 25, enclosingSymbol: 0, receiver: "_", argumentLabels: ["_"], receiverRef: 0),
            ExtractedReference(name: "isPadding", kind: .read, line: 3, column: 35, enclosingSymbol: 0, receiver: ".", context: "implicit",
                               receiverHint: "ctx(^)", receiverRef: 0),
            ExtractedReference(name: "warmingUp", kind: .read, line: 5, column: 20, enclosingSymbol: 0, receiver: ".", context: "implicit"),
            ExtractedReference(name: "red", kind: .read, line: 6, column: 20, enclosingSymbol: 0, receiver: ".", context: "implicit"),
            // `DatePicker(…, displayedComponents: [.date])` names SwiftUI's case; `.date(of: 3)` can be the method.
            ExtractedReference(name: "date", kind: .read, line: 7, column: 20, enclosingSymbol: 0, receiver: ".", context: "implicit"),
            ExtractedReference(name: "date", kind: .call, line: 8, column: 20, enclosingSymbol: 0, receiver: ".", context: "implicit", argumentLabels: ["of"]),
        ])
        try index.module("App", root: "Sources")
        try index.link()
        let padding = try index.site("isPadding", line: 3, in: "Sources/Reader.swift")
        #expect(padding.target == "WALFlags.isPadding" && padding.basis == "typed" && padding.confidence == 0.95)
        #expect(try index.site("flags", line: 3, in: "Sources/Reader.swift").target == "Header.flags")
        let contains = try index.site("contains", line: 3, in: "Sources/Reader.swift")
        #expect(contains.isExternal && contains.target == nil && contains.receiverType == "WALFlags", "an OptionSet member the repository does not declare")
        let unique = try index.site("warmingUp", line: 5, in: "Sources/Reader.swift")
        #expect(unique.target == "Phase.warmingUp" && unique.basis == "unique-name" && unique.confidence == 0.6)
        #expect(try index.site("red", line: 6, in: "Sources/Reader.swift").target == nil, "`.red` is a SwiftUI color far more often")
        #expect(try index.site("date", line: 7, in: "Sources/Reader.swift").target == nil, "an uncalled implicit member is never a method")
        let called = try index.site("date", line: 8, in: "Sources/Reader.swift")
        #expect(called.target == "Scheduler.date" && called.basis == "unique-name" && called.confidence == 0.6)
    }

    @Test("A collection a reference produces gives its elements' implicit members their type; a written one does not")
    func implicitCollectionElements() throws {
        let index = try LinkIndex("implicit-collection")
        try index.write("Sources/Health.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Repair", kind: .enum, range: LineRange(1, 4)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "dropStaleBookmark", kind: .enumCase, range: LineRange(2, 2)),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "reloadShelf", kind: .enumCase, range: LineRange(3, 3)),
            ExtractedSymbol(localID: 3, name: "diagnose", kind: .function, range: LineRange(6, 6), selector: "diagnose()", parameterFlags: "", declaredType: "[Repair]"),
            // Another enum's `reloadShelf`: what a name-only guess could bind.
            ExtractedSymbol(localID: 4, name: "Command", kind: .enum, range: LineRange(8, 10)),
            ExtractedSymbol(localID: 5, parentLocalID: 4, name: "reloadShelf", kind: .enumCase, range: LineRange(9, 9)),
            ExtractedSymbol(localID: 6, name: "Item", kind: .struct, range: LineRange(12, 14)),
            ExtractedSymbol(localID: 7, parentLocalID: 6, name: "init", kind: .initializer, range: LineRange(13, 13), selector: "init(name:)", parameterFlags: "-"),
        ])
        try index.write("Sources/Store.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Store", kind: .struct, range: LineRange(1, 8)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "items", kind: .property, range: LineRange(2, 2), declaredType: "[Item]"),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "check", kind: .method, range: LineRange(3, 7)),
        ], references: [
            // `let repairs = diagnose()`, then `repairs.contains(.reloadShelf)`.
            ExtractedReference(name: "diagnose", kind: .call, line: 4, column: 23, enclosingSymbol: 2, argumentLabels: []),
            ExtractedReference(name: "reloadShelf", kind: .read, line: 5, column: 30, enclosingSymbol: 2, receiver: ".", context: "implicit",
                               receiverHint: "ctx(^)", receiverRef: 0),
            // `items.append(.init(name: "a"))`.
            ExtractedReference(name: "items", kind: .read, line: 6, column: 9, enclosingSymbol: 2),
            ExtractedReference(name: "init", kind: .instantiate, line: 6, column: 23, enclosingSymbol: 2, receiver: ".", context: "implicit",
                               argumentLabels: ["name"], receiverHint: "ctx(^)", receiverRef: 2),
            // `let fresh: [Item] = .init()`: the written collection type is the context itself.
            ExtractedReference(name: "init", kind: .instantiate, line: 7, column: 30, enclosingSymbol: 2, receiver: ".", context: "implicit",
                               argumentLabels: [], receiverHint: "ctx([Item])"),
        ])
        try index.module("App", root: "Sources")
        try index.link()
        let repair = try index.site("reloadShelf", line: 5, in: "Sources/Store.swift")
        #expect(repair.target == "Repair.reloadShelf" && repair.basis == "typed" && repair.confidence == 0.95 && !repair.isExternal)
        let element = try index.site("init", line: 6, in: "Sources/Store.swift")
        #expect(element.target == "Item" && element.basis == "typed", "an element built in place")
        let written = try index.site("init", line: 7, in: "Sources/Store.swift")
        #expect(written.target == nil && written.isExternal && written.module == "Swift", "the array's own initializer")
    }

    @Test("Under a framework API an implicit member is the framework's, unless a repository extension of a framework type declares it")
    func implicitFrameworkContexts() throws {
        let index = try LinkIndex("implicit-framework")
        try index.write("Sources/Palette.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "ThemePalette", kind: .enum, range: LineRange(1, 3)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "color", kind: .method, range: LineRange(2, 2), attributes: ["static"],
                            selector: "color(_:)", parameterFlags: "-"),
            ExtractedSymbol(localID: 2, name: "Font", kind: .extension, range: LineRange(5, 7)),
            ExtractedSymbol(localID: 3, parentLocalID: 2, name: "brand", kind: .property, range: LineRange(6, 6), attributes: ["static"]),
            ExtractedSymbol(localID: 4, name: "Phase", kind: .enum, range: LineRange(9, 12)),
            ExtractedSymbol(localID: 5, parentLocalID: 4, name: "paused", kind: .enumCase, range: LineRange(10, 10)),
            ExtractedSymbol(localID: 6, parentLocalID: 4, name: "system", kind: .enumCase, range: LineRange(11, 11)),
        ], imports: [ExtractedImport(module: "SwiftUI", kind: .module, line: 1)])
        try index.write("Sources/Canvas.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "draw", kind: .function, range: LineRange(1, 8)),
        ], references: [
            // `ctx.fill(path, with: .color(.white))`, with `ctx: GraphicsContext` a parameter.
            ExtractedReference(name: "fill", kind: .call, line: 3, column: 13, enclosingSymbol: 0, receiver: "ctx", argumentLabels: ["_", "with"],
                               receiverHint: "GraphicsContext"),
            ExtractedReference(name: "color", kind: .call, line: 3, column: 31, enclosingSymbol: 0, receiver: ".", context: "implicit",
                               argumentLabels: ["_"], receiverHint: "param(^,1)", receiverRef: 0),
            ExtractedReference(name: "white", kind: .read, line: 3, column: 38, enclosingSymbol: 0, receiver: ".", context: "implicit",
                               receiverHint: "param(^,0)", receiverRef: 1),
            // `Text("Hi").font(.brand)` and `Text("Hi").font(.system(size: 12))`.
            ExtractedReference(name: "Text", kind: .instantiate, line: 4, column: 9, enclosingSymbol: 0, context: "call", argumentLabels: ["_"]),
            ExtractedReference(name: "font", kind: .call, line: 4, column: 20, enclosingSymbol: 0, receiver: "_", argumentLabels: ["_"], receiverRef: 3),
            ExtractedReference(name: "brand", kind: .read, line: 4, column: 26, enclosingSymbol: 0, receiver: ".", context: "implicit",
                               receiverHint: "param(^,0)", receiverRef: 4),
            ExtractedReference(name: "Text", kind: .instantiate, line: 5, column: 9, enclosingSymbol: 0, context: "call", argumentLabels: ["_"]),
            ExtractedReference(name: "font", kind: .call, line: 5, column: 20, enclosingSymbol: 0, receiver: "_", argumentLabels: ["_"], receiverRef: 6),
            ExtractedReference(name: "system", kind: .call, line: 5, column: 26, enclosingSymbol: 0, receiver: ".", context: "implicit",
                               argumentLabels: ["size"], receiverHint: "param(^,0)", receiverRef: 7),
            // `XCTAssertEqual(state, .paused)`: the generic assertion takes its type from `state`.
            ExtractedReference(name: "XCTAssertEqual", kind: .call, line: 6, column: 9, enclosingSymbol: 0, argumentLabels: ["_", "_"]),
            ExtractedReference(name: "paused", kind: .read, line: 6, column: 32, enclosingSymbol: 0, receiver: ".", context: "implicit",
                               receiverHint: "param(^,1)", receiverRef: 9),
        ], imports: [ExtractedImport(module: "SwiftUI", kind: .module, line: 1), ExtractedImport(module: "XCTest", kind: .module, line: 2)])
        try index.store.db.run("UPDATE imports SET external_name = module")
        try index.module("App", root: "Sources")
        try index.link()
        let color = try index.site("color", line: 3, in: "Sources/Canvas.swift")
        #expect(color.target == nil && color.isExternal && color.module == "SwiftUI", "GraphicsContext's shading, not ThemePalette.color")
        let white = try index.site("white", line: 3, in: "Sources/Canvas.swift")
        #expect(white.target == nil && white.isExternal && white.module == "SwiftUI")
        let brand = try index.site("brand", line: 4, in: "Sources/Canvas.swift")
        #expect(brand.target == "Font.brand" && brand.basis == "unique-name" && brand.confidence == 0.6)
        let system = try index.site("system", line: 5, in: "Sources/Canvas.swift")
        #expect(system.target == nil && system.isExternal, "Font.system, not the repository's Phase.system")
        let paused = try index.site("paused", line: 6, in: "Sources/Canvas.swift")
        #expect(paused.target == "Phase.paused" && paused.basis == "unique-name")
    }

    @Test("An instantiation's implicit arguments take the initializer's parameter types, or the memberwise initializer's")
    func implicitInitializerArguments() throws {
        let index = try LinkIndex("implicit-init")
        try index.write("Sources/Card.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Style", kind: .enum, range: LineRange(1, 4)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "compact", kind: .enumCase, range: LineRange(2, 2)),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "hero", kind: .enumCase, range: LineRange(3, 3)),
            ExtractedSymbol(localID: 3, name: "Card", kind: .struct, range: LineRange(6, 9)),
            ExtractedSymbol(localID: 4, parentLocalID: 3, name: "title", kind: .property, range: LineRange(7, 7), declaredType: "String"),
            ExtractedSymbol(localID: 5, parentLocalID: 3, name: "style", kind: .property, range: LineRange(8, 8), declaredType: "Style"),
            ExtractedSymbol(localID: 6, name: "Badge", kind: .class, range: LineRange(11, 14)),
            ExtractedSymbol(localID: 7, parentLocalID: 6, name: "init", kind: .initializer, range: LineRange(12, 12), selector: "init(_:look:)",
                            parameterFlags: "--", parameterTypes: ["String", "Look"]),
            // `hero` is a case of both enums, so only the parameter's type can choose.
            ExtractedSymbol(localID: 8, name: "Look", kind: .enum, range: LineRange(16, 18)),
            ExtractedSymbol(localID: 9, parentLocalID: 8, name: "hero", kind: .enumCase, range: LineRange(17, 17)),
        ])
        try index.write("Sources/Screen.swift", symbols: [ExtractedSymbol(localID: 0, name: "render", kind: .function, range: LineRange(1, 5))], references: [
            // `Card(title: "A", style: .hero)`: the memberwise initializer.
            ExtractedReference(name: "Card", kind: .instantiate, line: 2, column: 9, enclosingSymbol: 0, context: "call", argumentLabels: ["title", "style"]),
            ExtractedReference(name: "hero", kind: .read, line: 2, column: 37, enclosingSymbol: 0, receiver: ".", context: "implicit",
                               receiverHint: "param(^,1)", receiverRef: 0),
            // `Badge("B", look: .hero)`: the declared initializer.
            ExtractedReference(name: "Badge", kind: .instantiate, line: 3, column: 9, enclosingSymbol: 0, context: "call", argumentLabels: ["_", "look"]),
            ExtractedReference(name: "hero", kind: .read, line: 3, column: 29, enclosingSymbol: 0, receiver: ".", context: "implicit",
                               receiverHint: "param(^,1)", receiverRef: 2),
        ])
        try index.module("App", root: "Sources")
        try index.link()
        let memberwise = try index.site("hero", line: 2, in: "Sources/Screen.swift")
        #expect(memberwise.target == "Style.hero" && memberwise.basis == "typed" && memberwise.confidence == 0.95)
        let declared = try index.site("hero", line: 3, in: "Sources/Screen.swift")
        #expect(declared.target == "Look.hero" && declared.basis == "typed" && declared.confidence == 0.95)
    }

    // MARK: Externals

    @Test("A name bound by a package import is an external reference to that package")
    func externalScriptBinding() throws {
        let index = try LinkIndex("external-ts")
        try index.write("src/main.ts", .typescript, symbols: [
            ExtractedSymbol(localID: 0, name: "unlock", kind: .function, range: LineRange(3, 6)),
        ], references: [
            ExtractedReference(name: "decryptString", kind: .call, line: 4, column: 25, enclosingSymbol: 0, receiver: "safeStorage"),
            ExtractedReference(name: "safeStorage", kind: .read, line: 4, column: 13, enclosingSymbol: 0),
            ExtractedReference(name: "readFileSync", kind: .call, line: 5, column: 8, enclosingSymbol: 0, receiver: "fs"),
        ], imports: [
            ExtractedImport(module: "electron", kind: .module, names: [ImportedName(name: "safeStorage")], line: 1),
            ExtractedImport(module: "node:fs", kind: .module, names: [ImportedName(name: "default", alias: "fs")], line: 2),
        ])
        // What ImportResolver records for packages outside the repository.
        try index.store.db.run("UPDATE imports SET external_name = 'electron' WHERE module = 'electron'")
        try index.store.db.run("UPDATE imports SET external_name = 'fs' WHERE module = 'node:fs'")
        // A same-named repository function must not capture the call.
        try index.write("src/crypto.ts", .typescript, symbols: [
            ExtractedSymbol(localID: 0, name: "decryptString", kind: .function, range: LineRange(1, 1), isExported: true),
        ])
        try index.link()
        let decrypt = try index.site("decryptString", line: 4, in: "src/main.ts")
        #expect(decrypt.isExternal && decrypt.module == "electron" && decrypt.basis == "import" && decrypt.receiverType == "safeStorage")
        #expect(decrypt.target == nil && decrypt.confidence == 0.95)
        let read = try index.site("readFileSync", line: 5, in: "src/main.ts")
        #expect(read.isExternal && read.module == "fs" && read.receiverType == "fs")
    }

    @Test("Framework types are external references with their module, never a repository lookalike")
    func swiftFrameworkReferences() throws {
        let index = try LinkIndex("external-swift")
        try index.write("Sources/Reminders.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "ReadingReminders", kind: .enum, range: LineRange(1, 3)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "sync", kind: .method, range: LineRange(2, 2), attributes: ["static"], selector: "sync()", parameterFlags: ""),
            ExtractedSymbol(localID: 2, name: "Engine", kind: .struct, range: LineRange(5, 7)),
            ExtractedSymbol(localID: 3, parentLocalID: 2, name: "length", kind: .property, range: LineRange(6, 6)),
        ])
        try index.write("Sources/Store.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Store", kind: .class, range: LineRange(3, 12)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "buffer", kind: .property, range: LineRange(4, 4), declaredType: "MTLBuffer"),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "restore", kind: .method, range: LineRange(6, 11)),
        ], references: [
            ExtractedReference(name: "updates", kind: .read, line: 7, column: 25, enclosingSymbol: 2, receiver: "Transaction"),
            ExtractedReference(name: "sync", kind: .call, line: 8, column: 24, enclosingSymbol: 2, receiver: "AppStore", argumentLabels: []),
            ExtractedReference(name: "sync", kind: .call, line: 9, column: 27, enclosingSymbol: 2, receiver: "ReadingReminders", argumentLabels: []),
            ExtractedReference(name: "length", kind: .read, line: 10, column: 23, enclosingSymbol: 2, receiver: "buffer", receiverRef: 4),
            ExtractedReference(name: "buffer", kind: .read, line: 10, column: 16, enclosingSymbol: 2),
        ], imports: [ExtractedImport(module: "StoreKit", kind: .module, line: 1), ExtractedImport(module: "Metal", kind: .module, line: 2)])
        try index.store.db.run("UPDATE imports SET external_name = module")
        try index.link()
        let updates = try index.site("updates", line: 7, in: "Sources/Store.swift")
        #expect(updates.isExternal && updates.module == "StoreKit" && updates.basis == "static" && updates.receiverType == "Transaction")
        let appStore = try index.site("sync", line: 8, in: "Sources/Store.swift")
        #expect(appStore.isExternal && appStore.module == "StoreKit" && appStore.target == nil)
        #expect(try index.site("sync", line: 9, in: "Sources/Store.swift").target == "ReadingReminders.sync")
        let length = try index.site("length", line: 10, in: "Sources/Store.swift")
        #expect(length.isExternal && length.module == "Metal" && length.receiverType == "MTLBuffer" && length.basis == "typed")
        #expect(length.alt == "Engine.length", "the v3 guess survives as a rejected lookalike")
    }

    @Test("In a file that imports a UI framework, unlisted names and names two imports declare get no framework module")
    func uiFrameworkFileModules() throws {
        let index = try LinkIndex("external-ui")
        try index.write("Sources/Paywall.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Paywall", kind: .struct, range: LineRange(3, 9)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "body", kind: .property, range: LineRange(4, 8)),
        ], references: [
            ExtractedReference(name: "StrokeStyle", kind: .call, line: 5, column: 20, enclosingSymbol: 1, argumentLabels: ["lineWidth"]),
            ExtractedReference(name: "disablesAnimations", kind: .read, line: 6, column: 25, enclosingSymbol: 1, receiver: "Transaction"),
            ExtractedReference(name: "price", kind: .read, line: 7, column: 21, enclosingSymbol: 1, receiver: "Product"),
            ExtractedReference(name: "Transaction", kind: .instantiate, line: 8, column: 27, enclosingSymbol: 1, context: "call", argumentLabels: []),
        ], imports: [ExtractedImport(module: "SwiftUI", kind: .module, line: 1), ExtractedImport(module: "StoreKit", kind: .module, line: 2)])
        try index.write("Sources/Store.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Store", kind: .class, range: LineRange(3, 8)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "listen", kind: .method, range: LineRange(4, 7)),
        ], references: [
            ExtractedReference(name: "updates", kind: .read, line: 5, column: 25, enclosingSymbol: 1, receiver: "Transaction"),
            ExtractedReference(name: "RenewalState", kind: .call, line: 6, column: 21, enclosingSymbol: 1, argumentLabels: ["rawValue"]),
            ExtractedReference(name: "Transaction", kind: .instantiate, line: 7, column: 21, enclosingSymbol: 1, context: "call", argumentLabels: []),
        ], imports: [ExtractedImport(module: "Foundation", kind: .module, line: 1), ExtractedImport(module: "StoreKit", kind: .module, line: 2)])
        try index.store.db.run("UPDATE imports SET external_name = module")
        try index.link()
        let stroke = try index.site("StrokeStyle", line: 5, in: "Sources/Paywall.swift")
        #expect(stroke.isExternal && stroke.module == nil, "SwiftUI declares far more than the catalog lists")
        let animations = try index.site("disablesAnimations", line: 6, in: "Sources/Paywall.swift")
        #expect(animations.isExternal && animations.module == nil, "SwiftUI and StoreKit both declare Transaction")
        let transaction = try index.site("Transaction", line: 8, in: "Sources/Paywall.swift")
        #expect(transaction.isExternal && transaction.module == nil, "a bare `Transaction()` is as ambiguous as a member of it")
        #expect(try index.site("price", line: 7, in: "Sources/Paywall.swift").module == "StoreKit")
        #expect(try index.site("updates", line: 5, in: "Sources/Store.swift").module == "StoreKit")
        #expect(try index.site("RenewalState", line: 6, in: "Sources/Store.swift").module == "StoreKit")
        #expect(try index.site("Transaction", line: 7, in: "Sources/Store.swift").module == "StoreKit")
    }

    @Test("A repository `extension View` answers on SwiftUI views, and its parameter types type the arguments")
    func viewExtensionOnFrameworkViews() throws {
        let index = try LinkIndex("view-extension")
        try index.write("Sources/Typography.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Prominence", kind: .enum, range: LineRange(1, 4)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "primary", kind: .enumCase, range: LineRange(2, 2)),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "tertiary", kind: .enumCase, range: LineRange(3, 3)),
            ExtractedSymbol(localID: 3, name: "View", kind: .extension, range: LineRange(6, 8)),
            ExtractedSymbol(localID: 4, parentLocalID: 3, name: "dataLabel", kind: .method, range: LineRange(7, 7), selector: "dataLabel(_:)",
                            parameterFlags: "-", parameterTypes: ["Prominence"]),
        ], imports: [ExtractedImport(module: "SwiftUI", kind: .module, line: 1)])
        try index.write("Sources/Card.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Card", kind: .struct, range: LineRange(1, 6), inheritedTypes: ["View"]),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "body", kind: .property, range: LineRange(2, 5)),
        ], references: [
            // `Text(title).dataLabel(.tertiary)`.
            ExtractedReference(name: "Text", kind: .instantiate, line: 3, column: 9, enclosingSymbol: 1, context: "call", argumentLabels: ["_"]),
            ExtractedReference(name: "dataLabel", kind: .call, line: 4, column: 14, enclosingSymbol: 1, receiver: "_", argumentLabels: ["_"], receiverRef: 0),
            ExtractedReference(name: "tertiary", kind: .read, line: 4, column: 25, enclosingSymbol: 1, receiver: ".", context: "implicit",
                               receiverHint: "param(^,0)", receiverRef: 1),
        ], imports: [ExtractedImport(module: "SwiftUI", kind: .module, line: 1)])
        try index.store.db.run("UPDATE imports SET external_name = module")
        try index.module("App", root: "Sources")
        try index.link()
        let call = try index.site("dataLabel", line: 4, in: "Sources/Card.swift")
        #expect(call.target == "View.dataLabel" && call.basis == "typed" && call.confidence == 0.9 && call.receiverType == "Text")
        let argument = try index.site("tertiary", line: 4, in: "Sources/Card.swift")
        #expect(argument.target == "Prominence.tertiary" && argument.basis == "typed" && argument.confidence == 0.95)
    }

    @Test("A member no framework parent can give stays unresolved: marker protocols, raw types, generic constraints")
    func frameworkParentsGiveOnlyTheirMembers() throws {
        let index = try LinkIndex("framework-parents")
        try index.write("Sources/Model.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Writer", kind: .class, range: LineRange(1, 3), inheritedTypes: ["Sendable"]),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "appendRecord", kind: .method, range: LineRange(2, 2), selector: "appendRecord()", parameterFlags: ""),
            ExtractedSymbol(localID: 2, name: "Level", kind: .enum, range: LineRange(5, 7), inheritedTypes: ["String", "CaseIterable"]),
            ExtractedSymbol(localID: 3, parentLocalID: 2, name: "low", kind: .enumCase, range: LineRange(6, 6)),
            ExtractedSymbol(localID: 4, name: "Generable", kind: .protocol, range: LineRange(9, 9), inheritedTypes: ["Codable"]),
            ExtractedSymbol(localID: 5, name: "Store", kind: .class, range: LineRange(11, 11), inheritedTypes: ["ObservableObject"]),
        ])
        try index.write("Sources/Use.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "use", kind: .function, range: LineRange(1, 8)),
        ], references: [
            // Stale code: `Writer` no longer has `append`, and `Sendable` gives nothing.
            ExtractedReference(name: "append", kind: .call, line: 2, column: 16, enclosingSymbol: 0, receiver: "writer", argumentLabels: [], receiverHint: "Writer"),
            ExtractedReference(name: "rawValue", kind: .read, line: 3, column: 15, enclosingSymbol: 0, receiver: "level", receiverHint: "Level"),
            ExtractedReference(name: "allCases", kind: .read, line: 4, column: 15, enclosingSymbol: 0, receiver: "Level"),
            // `parsed: T` with `T: Generable`: the member is the concrete model's, which the constraint does not name.
            ExtractedReference(name: "title", kind: .read, line: 5, column: 16, enclosingSymbol: 0, receiver: "parsed", receiverHint: "Generable"),
            ExtractedReference(name: "objectWillChange", kind: .read, line: 6, column: 15, enclosingSymbol: 0, receiver: "store", receiverHint: "Store"),
        ])
        try index.module("App", root: "Sources")
        try index.link()
        let stale = try index.site("append", line: 2, in: "Sources/Use.swift")
        #expect(stale.target == nil && !stale.isExternal && stale.receiverType == "Writer" && stale.basis == nil)
        let raw = try index.site("rawValue", line: 3, in: "Sources/Use.swift")
        #expect(raw.isExternal && raw.module == "Swift" && raw.receiverType == "Level")
        let cases = try index.site("allCases", line: 4, in: "Sources/Use.swift")
        #expect(cases.isExternal && cases.module == "Swift" && cases.receiverType == "Level")
        let generic = try index.site("title", line: 5, in: "Sources/Use.swift")
        #expect(generic.target == nil && !generic.isExternal && generic.receiverType == "Generable")
        let publisher = try index.site("objectWillChange", line: 6, in: "Sources/Use.swift")
        #expect(publisher.isExternal && publisher.module == "Combine" && publisher.receiverType == "Store")
    }

    // MARK: The unique-name fallback

    @Test("Unknown receivers: stoplisted names stay unresolved, a lone member is 0.45, 0.6 when corroborated")
    func uniqueNameFallback() throws {
        let index = try LinkIndex("fallback")
        try index.write("Sources/Wax.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Wax", kind: .class, range: LineRange(1, 4)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "commit", kind: .method, range: LineRange(2, 2), selector: "commit()", parameterFlags: ""),
            ExtractedSymbol(localID: 2, parentLocalID: 0, name: "compactFrames", kind: .method, range: LineRange(3, 3), selector: "compactFrames()", parameterFlags: ""),
        ])
        try index.write("Sources/Engine.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "render", kind: .function, range: LineRange(1, 8)),
        ], references: [
            ExtractedReference(name: "commit", kind: .call, line: 2, column: 23, enclosingSymbol: 0, receiver: "commandBuffer", argumentLabels: [], receiverHint: "?"),
            ExtractedReference(name: "commit", kind: .call, line: 3, column: 13, enclosingSymbol: 0, receiver: "wax", argumentLabels: [], receiverHint: "Wax"),
            ExtractedReference(name: "compactFrames", kind: .call, line: 4, column: 13, enclosingSymbol: 0, receiver: "store", argumentLabels: [], receiverHint: "?"),
            ExtractedReference(name: "compactFrames", kind: .call, line: 5, column: 13, enclosingSymbol: 0, receiver: "wax", argumentLabels: [], receiverHint: "?"),
        ])
        try index.module("App", root: "Sources")
        try index.link()
        #expect(try index.site("commit", line: 2, in: "Sources/Engine.swift").target == nil, "Metal's commit, not the repository's")
        let typed = try index.site("commit", line: 3, in: "Sources/Engine.swift")
        #expect(typed.target == "Wax.commit" && typed.basis == "typed", "typing ignores the stoplist")
        let guess = try index.site("compactFrames", line: 4, in: "Sources/Engine.swift")
        #expect(guess.target == "Wax.compactFrames" && guess.confidence == 0.45 && guess.basis == "unique-name")
        #expect(try index.site("compactFrames", line: 5, in: "Sources/Engine.swift").confidence == 0.6, "`wax` names the owner")
    }

    // MARK: Determinism

    @Test("Equal candidates break ties by path, whatever order the files were written in")
    func deterministicTies() throws {
        func linkedTarget(order: [String]) throws -> String? {
            let index = try LinkIndex("ties")
            let files: [String: [ExtractedSymbol]] = [
                "Sources/B/Other.swift": [
                    ExtractedSymbol(localID: 0, name: "Other", kind: .struct, range: LineRange(1, 3)),
                    ExtractedSymbol(localID: 1, parentLocalID: 0, name: "ping", kind: .method, range: LineRange(2, 2)),
                ],
                "Sources/A/Helper.swift": [
                    ExtractedSymbol(localID: 0, name: "Helper", kind: .struct, range: LineRange(1, 3)),
                    ExtractedSymbol(localID: 1, parentLocalID: 0, name: "ping", kind: .method, range: LineRange(2, 2)),
                ],
            ]
            for path in order { try index.write(path, symbols: files[path] ?? []) }
            try index.write("Sources/C/Use.swift", symbols: [ExtractedSymbol(localID: 0, name: "use", kind: .function, range: LineRange(1, 3))], references: [
                ExtractedReference(name: "ping", kind: .call, line: 2, column: 7, enclosingSymbol: 0, receiver: "x", argumentLabels: [], receiverHint: "?"),
            ])
            try index.link()
            return try index.site("ping", line: 2, in: "Sources/C/Use.swift").targetPath
        }
        let forward = try linkedTarget(order: ["Sources/A/Helper.swift", "Sources/B/Other.swift"])
        let backward = try linkedTarget(order: ["Sources/B/Other.swift", "Sources/A/Helper.swift"])
        #expect(forward == "Sources/A/Helper.swift")
        #expect(backward == forward)
    }

    // MARK: Incremental linking

    @Test("A changed return type re-links uses in other files through declared types and receiver chains")
    func incrementalChains() throws {
        let index = try LinkIndex("incremental")
        func factory(returning type: String) -> [ExtractedSymbol] {
            [
                ExtractedSymbol(localID: 0, name: "Factory", kind: .enum, range: LineRange(1, 3)),
                ExtractedSymbol(localID: 1, parentLocalID: 0, name: "make", kind: .method, range: LineRange(2, 2), attributes: ["static"],
                                selector: "make()", parameterFlags: "", declaredType: type),
            ]
        }
        try index.write("Sources/Services.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Service", kind: .struct, range: LineRange(1, 3)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "start", kind: .method, range: LineRange(2, 2), selector: "start()", parameterFlags: ""),
            ExtractedSymbol(localID: 2, name: "Other", kind: .struct, range: LineRange(5, 7)),
            ExtractedSymbol(localID: 3, parentLocalID: 2, name: "start", kind: .method, range: LineRange(6, 6), selector: "start()", parameterFlags: ""),
        ])
        try index.write("Sources/Factory.swift", symbols: factory(returning: "Service"))
        try index.write("Sources/Holder.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Holder", kind: .struct, range: LineRange(1, 3)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "service", kind: .property, range: LineRange(2, 2), declaredType: "^", declaredTypeRef: 0),
        ], references: [
            ExtractedReference(name: "make", kind: .call, line: 2, column: 27, enclosingSymbol: 1, receiver: "Factory", argumentLabels: []),
        ])
        try index.write("Sources/Use.swift", symbols: [ExtractedSymbol(localID: 0, name: "use", kind: .function, range: LineRange(1, 3))], references: [
            ExtractedReference(name: "service", kind: .read, line: 2, column: 12, enclosingSymbol: 0, receiver: "holder", receiverHint: "Holder", typeEvidenceLine: 1),
            ExtractedReference(name: "start", kind: .call, line: 2, column: 20, enclosingSymbol: 0, receiver: "_", argumentLabels: [], receiverRef: 0),
        ])
        try index.module("App", root: "Sources")
        let linker = ReferenceLinker(db: index.store.db)
        _ = try linker.link()
        #expect(try index.site("start", line: 2, in: "Sources/Use.swift").target == "Service.start")

        // Factory.make now returns Other. The pipeline invalidates the names the rewritten file declares; the linker
        // follows Holder.service's declared type and Use.swift's receiver chain from there.
        try index.write("Sources/Factory.swift", symbols: factory(returning: "Other"))
        try linker.invalidate(names: ["Factory", "make"])
        let result = try linker.link()
        let start = try index.site("start", line: 2, in: "Sources/Use.swift")
        #expect(start.target == "Other.start" && start.basis == "typed")
        #expect(result.processed < 10, "only the affected rows are re-linked: \(result.processed)")
    }

    @Test("Changing a type's parents re-links what was resolved through its subclasses")
    func hierarchyChange() throws {
        let index = try LinkIndex("hierarchy")
        try index.write("Sources/Bases.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "Base", kind: .class, range: LineRange(1, 3)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "greet", kind: .method, range: LineRange(2, 2), selector: "greet()", parameterFlags: ""),
            ExtractedSymbol(localID: 2, name: "Other", kind: .class, range: LineRange(5, 7)),
            ExtractedSymbol(localID: 3, parentLocalID: 2, name: "greet", kind: .method, range: LineRange(6, 6), selector: "greet()", parameterFlags: ""),
        ])
        try index.write("Sources/Mid.swift", symbols: [ExtractedSymbol(localID: 0, name: "Mid", kind: .class, range: LineRange(1, 1), inheritedTypes: ["Base"])])
        try index.write("Sources/Leaf.swift", symbols: [ExtractedSymbol(localID: 0, name: "Leaf", kind: .class, range: LineRange(1, 1), inheritedTypes: ["Mid"])])
        try index.write("Sources/Use.swift", symbols: [ExtractedSymbol(localID: 0, name: "use", kind: .function, range: LineRange(1, 3))], references: [
            ExtractedReference(name: "greet", kind: .call, line: 2, column: 10, enclosingSymbol: 0, receiver: "leaf", argumentLabels: [], receiverHint: "Leaf"),
        ])
        try index.module("App", root: "Sources")
        let linker = ReferenceLinker(db: index.store.db)
        _ = try linker.link()
        let before = try index.site("greet", line: 2, in: "Sources/Use.swift")
        #expect(before.target == "Base.greet" && before.confidence == 0.9 && before.receiverType == "Leaf")

        try index.write("Sources/Mid.swift", symbols: [ExtractedSymbol(localID: 0, name: "Mid", kind: .class, range: LineRange(1, 1), inheritedTypes: ["Other"])])
        try linker.invalidate(names: ["Mid"])
        _ = try linker.link()
        let site = try index.site("greet", line: 2, in: "Sources/Use.swift")
        #expect(site.target == "Other.greet")
    }

    @Test("link_stats records how the references resolved")
    func linkStats() throws {
        let index = try LinkIndex("stats")
        try index.write("Sources/A.swift", symbols: [
            ExtractedSymbol(localID: 0, name: "A", kind: .struct, range: LineRange(1, 4)),
            ExtractedSymbol(localID: 1, parentLocalID: 0, name: "run", kind: .method, range: LineRange(2, 3)),
        ], references: [
            ExtractedReference(name: "run", kind: .call, line: 3, column: 9, enclosingSymbol: 1, argumentLabels: []),
            ExtractedReference(name: "Text", kind: .instantiate, line: 3, column: 15, enclosingSymbol: 1, context: "call", argumentLabels: ["_"]),
            ExtractedReference(name: "missing", kind: .call, line: 3, column: 25, enclosingSymbol: 1, receiver: "value", argumentLabels: [], receiverHint: "?"),
            ExtractedReference(name: "env:HOME", kind: .read, line: 3, column: 35, enclosingSymbol: 1, context: "env"),
        ], imports: [ExtractedImport(module: "SwiftUI", kind: .module, line: 1)])
        try index.store.db.run("UPDATE imports SET external_name = module")
        try index.link()
        let json = try #require(index.store.meta("link_stats"))
        let stats = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(stats["refs"] as? Int == 4 && stats["external"] as? Int == 1 && stats["unresolved"] as? Int == 1)
        let basis = try #require(stats["basis"] as? [String: Int])
        #expect(basis["self"] == 1 && basis["env"] == 1 && basis["external"] == 1)
    }
}

// MARK: - Harness

/// A scratch index written directly with `IndexStore.writeFile`, as the pipeline would, then linked. Files outside
/// any module see each other only through the legacy rule (×0.9), so tests about other rules put them in one.
private final class LinkIndex {
    let directory: URL
    let store: IndexStore

    init(_ name: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vesalius-linker-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        store = try IndexStore(path: directory.appendingPathComponent("index.v\(IndexSchema.version).sqlite").path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func write(_ path: String, _ language: Language = .swift, symbols: [ExtractedSymbol] = [], references: [ExtractedReference] = [],
               imports: [ExtractedImport] = []) throws -> Int64 {
        let record = FileRecord(path: path, language: language, size: 1, modified: 1, contentHash: UUID().uuidString, lines: .init(), complexity: 1,
                                isTest: false, isGenerated: false, isEntryPoint: false, analyzer: "test", parseStatus: "ok", parseMessage: nil)
        let analysis = FileAnalysis(symbols: symbols, imports: imports, references: references)
        return try store.writeFile(record, directoryID: nil, analysis: analysis, lexical: LexicalDocument(pathText: path, symbolText: "", docText: "", bodyText: ""))
    }

    /// A module whose files live under `root`; imports that name it resolve to it.
    @discardableResult
    func module(_ name: String, root: String, kind: String = "swiftpm-target", manifest: String? = nil) throws -> Int64 {
        try store.db.run("INSERT INTO modules(name, kind, root_path, manifest_path) VALUES(?, ?, ?, ?)", [name, kind, root, manifest])
        let id = store.db.lastInsertRowID
        try store.db.run("UPDATE files SET module_id = ? WHERE path LIKE ?", [id, root + "/%"])
        try store.db.run("UPDATE imports SET resolved_module_id = ? WHERE module = ?", [id, name])
        return id
    }

    /// An Xcode target that builds exactly `files`.
    @discardableResult
    func target(_ name: String, files: [String], isTest: Bool = false, testKind: String? = nil) throws -> Int64 {
        try store.db.run("INSERT INTO targets(name, module_name, system, is_test, test_kind, project_path) VALUES(?, ?, 'xcode', ?, ?, 'App.xcodeproj/project.pbxproj')",
                         [name, name, isTest, testKind])
        let id = store.db.lastInsertRowID
        for path in files {
            try store.db.run("INSERT INTO file_targets(file_id, target_id, via) SELECT id, ?, 'sync-root' FROM files WHERE path = ?", [id, path])
        }
        return id
    }

    @discardableResult
    func link() throws -> ReferenceLinker.Result {
        try ReferenceLinker(db: store.db).link()
    }

    func scalar(_ sql: String) throws -> Int {
        try store.db.scalarInt(sql)
    }

    struct Site {
        let resolved: Bool
        let target: String?
        let targetPath: String?
        let targetLine: Int?
        let confidence: Double
        let basis: String?
        let receiverType: String?
        let isExternal: Bool
        let module: String?
        let alt: String?
        let evidence: Int?
    }

    func site(_ name: String, line: Int, in path: String) throws -> Site {
        let row = try store.db.queryOne("""
            SELECT r.resolved, s.qualified_name, sf.path, s.start_line, r.confidence, r.basis, r.receiver_type, r.is_external, r.external_module, a.qualified_name,
                r.type_evidence_line
            FROM refs r JOIN files f ON f.id = r.file_id
            LEFT JOIN symbols s ON s.id = r.target_symbol_id LEFT JOIN files sf ON sf.id = s.file_id
            LEFT JOIN symbols a ON a.id = r.alt_symbol_id
            WHERE f.path = ? AND r.name = ? AND r.line = ?
            """, [path, name, line]) { row in
            Site(resolved: row.bool(0), target: row.optionalString(1), targetPath: row.optionalString(2), targetLine: row.optionalInt(3),
                 confidence: row.double(4), basis: row.optionalString(5), receiverType: row.optionalString(6), isExternal: row.bool(7),
                 module: row.optionalString(8), alt: row.optionalString(9), evidence: row.optionalInt(10))
        }
        guard let row else { throw MissingSite(description: "\(path):\(line) \(name)") }
        return row
    }
}

private struct MissingSite: Error, CustomStringConvertible {
    let description: String
}
