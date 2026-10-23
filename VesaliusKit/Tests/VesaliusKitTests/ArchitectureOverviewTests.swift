import Foundation
@testable import QueryEngine
import Testing
import VesaliusCore
import VesaliusMCP
@testable import VesaliusRender

/// `architecture`: targets, unbuilt code, packages, an app module's folders with direction, upward
/// edges, cycles and feature edges, the composition root, cross-target links and style counts, plus `focus`
/// and the text under a budget. The fixture is a real repository on disk (an Xcode 16 project with an exception
/// set, a local package, an unbuilt folder), indexed and queried through the engine and the tool.
@Suite("Architecture overview", .serialized)
struct ArchitectureOverviewTests {
    /// App (iOS 17) embeds Widget and Watch and links the local package Kit; Watch also compiles
    /// App/Models/Workout.swift through exception set E2; AppTests is hosted by App.
    static let project = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            classes = {
            };
            objectVersion = 77;
            objects = {

        /* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
                E1 /* Exceptions for "App" folder in "App" target */ = {
                    isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
                    membershipExceptions = (
                        Info.plist,
                    );
                    target = T1 /* App */;
                };
                E2 /* Exceptions for "App" folder in "Watch" target */ = {
                    isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
                    membershipExceptions = (
                        Models/Workout.swift,
                    );
                    target = T3 /* Watch */;
                };
        /* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

                G1 /* App */ = {
                    isa = PBXFileSystemSynchronizedRootGroup;
                    exceptions = (
                        E1 /* Exceptions for "App" folder in "App" target */,
                        E2 /* Exceptions for "App" folder in "Watch" target */,
                    );
                    path = App;
                    sourceTree = "<group>";
                };
                G3 /* Widget */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Widget; sourceTree = "<group>"; };
                G4 /* Watch */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Watch; sourceTree = "<group>"; };
                G5 /* AppTests */ = {isa = PBXFileSystemSynchronizedRootGroup; path = AppTests; sourceTree = "<group>"; };
                M0 = {isa = PBXGroup; children = (G1, G3, G4, G5, ); sourceTree = "<group>"; };
                P1 /* App.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
                P2 /* Widget.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = Widget.appex; sourceTree = BUILT_PRODUCTS_DIR; };
                P3 /* Watch.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; path = Watch.app; sourceTree = BUILT_PRODUCTS_DIR; };
                BF1 /* Widget.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = P2 /* Widget.appex */; };
                BF2 /* Watch.app in Embed Watch Content */ = {isa = PBXBuildFile; fileRef = P3 /* Watch.app */; };
                CP1 /* Embed Foundation Extensions */ = {isa = PBXCopyFilesBuildPhase; dstSubfolderSpec = 13; files = (BF1, ); };
                CP2 /* Embed Watch Content */ = {isa = PBXCopyFilesBuildPhase; dstSubfolderSpec = 16; files = (BF2, ); };
                D1 /* PBXTargetDependency */ = {isa = PBXTargetDependency; target = T2 /* Widget */; };
                D2 /* PBXTargetDependency */ = {isa = PBXTargetDependency; target = T3 /* Watch */; };

        /* Begin PBXNativeTarget section */
                T1 /* App */ = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = L1;
                    buildPhases = (
                        CP1 /* Embed Foundation Extensions */,
                        CP2 /* Embed Watch Content */,
                    );
                    dependencies = (
                        D1 /* PBXTargetDependency */,
                        D2 /* PBXTargetDependency */,
                    );
                    fileSystemSynchronizedGroups = (
                        G1 /* App */,
                    );
                    name = App;
                    packageProductDependencies = (
                        PD1 /* Kit */,
                        PD2 /* KitCore */,
                    );
                    productReference = P1 /* App.app */;
                    productType = "com.apple.product-type.application";
                };
                T2 /* Widget */ = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = L2;
                    fileSystemSynchronizedGroups = (
                        G3 /* Widget */,
                    );
                    name = Widget;
                    productReference = P2 /* Widget.appex */;
                    productType = "com.apple.product-type.app-extension";
                };
                T3 /* Watch */ = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = L3;
                    fileSystemSynchronizedGroups = (
                        G4 /* Watch */,
                    );
                    name = Watch;
                    productReference = P3 /* Watch.app */;
                    productType = "com.apple.product-type.application";
                };
                T4 /* AppTests */ = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = L4;
                    fileSystemSynchronizedGroups = (
                        G5 /* AppTests */,
                    );
                    name = AppTests;
                    productType = "com.apple.product-type.bundle.unit-test";
                };
        /* End PBXNativeTarget section */

                R0 /* Project object */ = {
                    isa = PBXProject;
                    buildConfigurationList = L0;
                    mainGroup = M0;
                    packageReferences = (
                        PR1 /* XCLocalSwiftPackageReference "Packages/Kit" */,
                    );
                    targets = (
                        T1 /* App */,
                        T2 /* Widget */,
                        T3 /* Watch */,
                        T4 /* AppTests */,
                    );
                };
                PR1 /* XCLocalSwiftPackageReference "Packages/Kit" */ = {isa = XCLocalSwiftPackageReference; relativePath = Packages/Kit; };
                PD1 /* Kit */ = {isa = XCSwiftPackageProductDependency; package = PR1; productName = Kit; };
                PD2 /* KitCore */ = {isa = XCSwiftPackageProductDependency; package = PR1; productName = KitCore; };
                C0 /* Release */ = {isa = XCBuildConfiguration; buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; }; name = Release; };
                L0 = {isa = XCConfigurationList; buildConfigurations = (C0, ); defaultConfigurationName = Release; };
                C1 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_ENTITLEMENTS = App/App.entitlements; PRODUCT_BUNDLE_IDENTIFIER = com.example.app; }; name = Release; };
                L1 = {isa = XCConfigurationList; buildConfigurations = (C1, ); defaultConfigurationName = Release; };
                C2 = {isa = XCBuildConfiguration; buildSettings = {INFOPLIST_FILE = Widget/Info.plist; PRODUCT_BUNDLE_IDENTIFIER = com.example.app.Widget; }; name = Release; };
                L2 = {isa = XCConfigurationList; buildConfigurations = (C2, ); defaultConfigurationName = Release; };
                C3 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = com.example.app.watch; SDKROOT = watchos; WATCHOS_DEPLOYMENT_TARGET = 11.0; }; name = Release; };
                L3 = {isa = XCConfigurationList; buildConfigurations = (C3, ); defaultConfigurationName = Release; };
                C4 = {isa = XCBuildConfiguration; buildSettings = {TEST_HOST = "$(BUILT_PRODUCTS_DIR)/App.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/App"; }; name = Release; };
                L4 = {isa = XCConfigurationList; buildConfigurations = (C4, ); defaultConfigurationName = Release; };
            };
            rootObject = R0 /* Project object */;
        }
        """

    static let repository: [String: String] = [
        "App.xcodeproj/project.pbxproj": project,
        "App/AppMain.swift": """
            import SwiftUI
            import SwiftData

            @main
            struct AppMain: App {
                let container: ModelContainer

                init() {
                    Analytics.shared.start()
                    let url = URL.applicationSupportDirectory.appendingPathComponent("main.store")
                    let schema = Schema([Workout.self, Plan.self])
                    container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(url: url)])
                }

                var body: some Scene {
                    WindowGroup {
                        RootView()
                    }
                    .modelContainer(container)
                }
            }
            """,
        "App/RootView.swift": """
            import SwiftUI

            struct RootView: View {
                @State private var showOnboarding = false

                var body: some View {
                    TabView {
                        HomeView()
                            .tabItem {
                                Label("Home", systemImage: "house")
                            }
                        StatsView()
                            .tabItem {
                                Label("Progress", systemImage: "chart.bar")
                            }
                    }
                    .sheet(isPresented: $showOnboarding) {
                        OnboardingView()
                    }
                }
            }
            """,
        "App/Features/Home/HomeView.swift": """
            import SwiftUI
            import KitCore

            struct HomeView: View {
                let service = WorkoutService.shared

                var body: some View {
                    StatsCard(total: service.load().count)
                }
            }
            """,
        "App/Features/Stats/StatsView.swift": """
            import SwiftUI

            struct StatsView: View {
                let workouts: [Workout] = WorkoutService.shared.load()

                var body: some View {
                    StatsCard(total: workouts.count)
                }
            }

            struct StatsCard: View {
                let total: Int

                var body: some View {
                    Text("\\(total)")
                }
            }
            """,
        "App/Features/Onboarding/OnboardingView.swift": """
            import SwiftUI

            struct OnboardingView: View {
                var body: some View {
                    Text("Welcome")
                }
            }
            """,
        "App/Services/WorkoutService.swift": """
            import Foundation
            import KitCore

            final class WorkoutService {
                static let shared = WorkoutService()

                func load() -> [Workout] {
                    [Workout(minutes: 30)]
                }

                func badge() -> StatsCard {
                    StatsCard(total: load().count)
                }
            }
            """,
        "App/Services/Analytics.swift": """
            final class Analytics {
                static let shared = Analytics()

                func start() {}
            }
            """,
        "App/Services/PhoneSync.swift": """
            import WatchConnectivity

            final class PhoneSync {
                let session = WCSession.default
            }
            """,
        "App/Models/Workout.swift": "struct Workout {\n    var minutes = 0\n}\n",
        "App/Models/Plan.swift": "struct Plan {\n    var name = \"\"\n}\n",
        "App/Models/RunAttributes.swift": """
            import ActivityKit

            struct RunAttributes: ActivityAttributes {
                struct ContentState: Codable, Hashable {
                    var meters = 0
                }
            }
            """,
        "App/Info.plist": "<plist><dict/></plist>\n",
        "App/App.entitlements": """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
                <key>com.apple.security.application-groups</key>
                <array>
                    <string>group.com.example.app</string>
                </array>
            </dict>
            </plist>
            """,
        "Widget/WidgetBundle.swift": """
            import WidgetKit
            import SwiftUI

            @main
            struct MainWidgets: WidgetBundle {
                var body: some Widget {
                    RunLiveActivity()
                }
            }
            """,
        "Widget/RunLiveActivity.swift": """
            import ActivityKit
            import WidgetKit
            import SwiftUI

            struct RunAttributes: ActivityAttributes {
                struct ContentState: Codable, Hashable {
                    var meters = 0
                }
            }

            struct RunLiveActivity: Widget {
                var body: some WidgetConfiguration {
                    ActivityConfiguration(for: RunAttributes.self) { context in
                        Text("Run")
                    }
                }
            }
            """,
        "Widget/Info.plist": """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
                <key>NSExtension</key>
                <dict>
                    <key>NSExtensionPointIdentifier</key>
                    <string>com.apple.widgetkit-extension</string>
                </dict>
            </dict>
            </plist>
            """,
        "Watch/WatchMain.swift": """
            import SwiftUI
            import WatchConnectivity

            @main
            struct WatchMain: App {
                let workout = Workout()

                var body: some Scene {
                    WindowGroup {
                        Text("Watch")
                    }
                }
            }
            """,
        "AppTests/WorkoutTests.swift": """
            import Testing
            @testable import App

            struct WorkoutTests {
                @Test func minutes() {
                    #expect(Workout().minutes == 0)
                }
            }
            """,
        // An old watch app no project builds, with its own entry point.
        "OldWatch/OldMain.swift": """
            import SwiftUI

            @main
            struct OldMain: App {
                var body: some Scene {
                    WindowGroup {
                        Text("Old")
                    }
                }
            }
            """,
        "Packages/Kit/Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "Kit",
                products: [
                    .library(name: "Kit", targets: ["Kit"]),
                    .library(name: "KitCore", targets: ["KitCore"]),
                ],
                targets: [
                    .target(name: "Kit", dependencies: ["KitCore"], path: "Sources/KitUmbrella"),
                    .target(name: "KitCore"),
                    .testTarget(name: "KitCoreTests", dependencies: ["KitCore"]),
                ]
            )
            """,
        "Packages/Kit/Sources/KitUmbrella/Exports.swift": "@_exported import KitCore\n",
        "Packages/Kit/Sources/KitCore/Engine.swift": "public struct Engine {\n    public init() {}\n}\n",
        "Packages/Kit/Tests/KitCoreTests/EngineTests.swift": "import Testing\n@testable import KitCore\n",
        // A loose file in a folder that is otherwise built.
        "Packages/Kit/Scratch.swift": "struct Scratch {}\n",
    ]

    static func line(_ needle: String, in text: String) throws -> Int {
        let index = try #require(text.components(separatedBy: "\n").firstIndex { $0.contains(needle) })
        return index + 1
    }

    // MARK: Targets, unbuilt code, packages

    @Test("Targets come from the project model: kind, platform, folders, exceptions, links, embeds and entry points")
    func targets() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.repository, name: "arch-targets")
        let overview = try engine.architectureOverview()
        #expect(overview.projects == ["App.xcodeproj"])
        #expect(overview.targets.map(\.name) == ["App", "Widget", "Watch", "AppTests"])

        let app = try #require(overview.targets.first)
        #expect(app.role == "app" && app.kind == "iOS app" && app.deploymentTarget == "17.0" && app.bundleID == "com.example.app")
        #expect(app.roots == [ArchitectureOverview.Root(path: "App", codeFiles: 11, language: "swift")])
        #expect(app.links == ["Kit", "KitCore"])
        #expect(app.embeds == ["Widget", "Watch"])
        #expect(app.dependsOn.isEmpty)
        #expect(app.entry == ArchitectureOverview.Entry(kind: "@main", name: "AppMain", path: "App/AppMain.swift", line: try Self.line("@main", in: Self.repository["App/AppMain.swift"]!)))

        let widget = overview.targets[1]
        #expect(widget.role == "widget" && widget.kind == "WidgetKit extension" && widget.extensionPoint == "com.apple.widgetkit-extension")
        #expect(widget.entry?.name == "MainWidgets" && widget.registers == ["RunLiveActivity"])

        // The exception set that adds App/Models/Workout.swift, by its definition lines.
        let watch = overview.targets[2]
        #expect(watch.role == "watch" && watch.kind == "watchOS app" && watch.deploymentTarget == "11.0")
        let first = try Self.line("E2 /* Exceptions for", in: Self.project)
        let last = try Self.line("target = T3 /* Watch */;", in: Self.project)
        #expect(watch.addedFiles == [ArchitectureOverview.AddedFiles(paths: ["App/Models/Workout.swift"], via: "membership exception",
                                                                     evidencePath: "App.xcodeproj/project.pbxproj", firstLine: first, lastLine: last)])
        #expect(watch.entry?.name == "WatchMain")

        let tests = overview.targets[3]
        #expect(tests.isTest && tests.role == "tests" && tests.testHost == "App" && tests.testFramework == "Swift Testing")

        // Code no target builds: a folder with its own entry point, and a loose file in a built package.
        #expect(overview.notBuilt == [
            ArchitectureOverview.UnbuiltCode(path: "OldWatch/", files: 1, hasMain: true),
            ArchitectureOverview.UnbuiltCode(path: "Packages/Kit/Scratch.swift", files: 1),
        ])

        let kit = try #require(overview.packages.first)
        #expect(overview.packages.count == 1)
        #expect(kit.path == "Packages/Kit" && kit.kind == "local")
        #expect(kit.products.map(\.name) == ["Kit", "KitCore"])
        #expect(kit.dependencies == [ArchitectureOverview.Dependency(from: "Kit", to: ["KitCore"])])
        #expect(kit.reexports == [ArchitectureOverview.Dependency(from: "Kit", to: ["KitCore"])])
        #expect(kit.linkedBy == ["app"])
        #expect(kit.usedTargets == ["Kit", "KitCore"])
        #expect(kit.importers == [ArchitectureOverview.Importers(module: "KitCore", counts: [ArchitectureOverview.RoleCount(role: "app", count: 2)])])
    }

    // MARK: The app module

    @Test("Folders, direction, upward edges, cycles and feature edges come from type references within the target")
    func module() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.repository, name: "arch-module")
        let module = try #require(try engine.architectureOverview().modules.first)
        #expect(module.name == "App" && module.root == "App" && module.edgeSource == "type references" && module.isSingleModule)
        #expect(module.folders.map(\.name) == ["Features", "Models", "Services"])
        #expect(module.folders[0].children.map(\.name).sorted() == ["Home", "Onboarding", "Stats"])
        #expect(module.rootFiles == ["AppMain.swift", "RootView.swift"])

        // Features use Services twice (HomeView, StatsView); Services use Features once (WorkoutService.badge).
        #expect(module.direction == [
            ArchitectureOverview.Dependency(from: "Features", to: ["Services", "Models"]),
            ArchitectureOverview.Dependency(from: "Services", to: ["Models"]),
        ])
        let badge = try Self.line("func badge() -> StatsCard", in: Self.repository["App/Services/WorkoutService.swift"]!)
        let card = try Self.line("StatsCard(total: load().count)", in: Self.repository["App/Services/WorkoutService.swift"]!)
        #expect(module.upward == [ArchitectureOverview.UpwardEdge(path: "App/Services/WorkoutService.swift", lines: [badge, card], types: ["StatsCard"],
                                                                  fromFolder: "Services", toFolder: "Features/Stats", weight: 1, reverseWeight: 2)])
        // The upward use closes a loop through StatsView.swift, which uses WorkoutService back.
        let cycle = try #require(module.cycles.first)
        #expect(module.cycles.count == 1 && cycle.isFilePair)
        #expect(cycle.forward == ArchitectureOverview.SiteRef(path: "App/Services/WorkoutService.swift", line: badge, type: "StatsCard"))
        let back = try Self.line("let workouts: [Workout] = WorkoutService.shared.load()", in: Self.repository["App/Features/Stats/StatsView.swift"]!)
        #expect(cycle.back == [ArchitectureOverview.SiteRef(path: "App/Features/Stats/StatsView.swift", line: back, type: "WorkoutService")])
        #expect(module.featureEdges == [ArchitectureOverview.Dependency(from: "Home", to: ["Stats"])])

        let root = try #require(module.composition)
        #expect(root.type == "AppMain" && root.path == "App/AppMain.swift")
        #expect(root.launch == ["Analytics.shared.start"])
        #expect(root.rootView == "RootView")
        #expect(root.tabs == [ArchitectureOverview.Tab(view: "HomeView"), ArchitectureOverview.Tab(view: "StatsView", title: "Progress")])
        #expect(root.presents == ["OnboardingView"])
        let store = try Self.line("\"main.store\"", in: Self.repository["App/AppMain.swift"]!)
        #expect(root.stores == [ArchitectureOverview.Store(name: "main.store", path: "App/AppMain.swift", line: store, models: 2)])
    }

    @Test("Shared source, duplicated types, framework bridges, app groups and style are reported between targets")
    func crossTarget() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.repository, name: "arch-cross")
        let overview = try engine.architectureOverview()
        let cross = overview.crossTarget
        #expect(cross.sharedSources == [ArchitectureOverview.SharedSource(paths: ["App/Models/Workout.swift"], files: 1, targets: ["app", "watch"], via: "membership exception")])
        #expect(cross.duplicates == [ArchitectureOverview.DuplicateTypes(names: ["RunAttributes"], sites: [
            ArchitectureOverview.DuplicateSite(role: "app", path: "App/Models/RunAttributes.swift", lines: [3]),
            ArchitectureOverview.DuplicateSite(role: "widget", path: "Widget/RunLiveActivity.swift", lines: [5]),
        ])])
        #expect(cross.bridges == [
            ArchitectureOverview.Bridge(framework: "WatchConnectivity", sides: [
                ArchitectureOverview.BridgeSide(role: "app", files: ["App/Services/PhoneSync.swift"]),
                ArchitectureOverview.BridgeSide(role: "watch", files: ["Watch/WatchMain.swift"]),
            ]),
            ArchitectureOverview.Bridge(framework: "ActivityKit", sides: [
                ArchitectureOverview.BridgeSide(role: "app", files: ["App/Models/RunAttributes.swift"]),
                ArchitectureOverview.BridgeSide(role: "widget", files: ["Widget/RunLiveActivity.swift"]),
            ]),
        ])
        #expect(cross.appGroups == [ArchitectureOverview.AppGroup(group: "group.com.example.app", declaredBy: ["app"], entitlements: ["App/App.entitlements"], uses: [])])
        #expect(overview.style == [ArchitectureOverview.Style(target: "App", views: 5, viewModels: 0, models: 0, singletons: 2, observables: 0)])
    }

    // MARK: Text

    @Test("The text: one line per target, folder facts with file:line, counts instead of patterns, within the budget")
    func text() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.repository, name: "arch-text")
        let overview = try engine.architectureOverview()
        let text = ArchitectureRenderer.render(overview, budget: .architecture)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "App.xcodeproj")
        #expect(lines[1] == "4 targets (1 test) · 1 local package")
        #expect(lines.contains { $0.hasPrefix(" App [iOS 17.0 app, com.example.app] App/ 11 swift · links Kit, KitCore · embeds Widget, Watch · @main AppMain AppMain.swift:") })
        // Everything fits, so embedded products show their bundle ids too.
        #expect(lines.contains(" Watch [watchOS 11.0 app, com.example.app.watch] Watch/ 1 swift + App/Models/Workout.swift (membership exception pbxproj:\(try Self.line("E2 /* Exceptions for", in: Self.project))-\(try Self.line("target = T3 /* Watch */;", in: Self.project))) · @main WatchMain WatchMain.swift:4"))
        #expect(lines.contains(" not built: OldWatch/ (1 file, own @main), Packages/Kit/Scratch.swift"))
        #expect(lines.contains(" Packages/Kit (local): products Kit, KitCore · deps Kit → KitCore · Kit re-exports KitCore (@_exported) · linked by app · imported by app 2"))
        #expect(lines.contains("APP MODULE App: Features 3 (Home 1, Onboarding 1, Stats 1) · Models 3 · Services 3 · AppMain.swift · RootView.swift"))
        #expect(lines.contains(" direction Features → Services, Models · Services → Models (convention only, one module)"))
        #expect(lines.contains { $0.hasPrefix(" upward Services/WorkoutService.swift:") && $0.hasSuffix(" → StatsCard (Features/Stats)") })
        #expect(lines.contains { $0.hasPrefix(" cycles WorkoutService.swift:") && $0.contains(" ↔ StatsView.swift:") })
        #expect(lines.contains(" feature→feature Home → Stats"))
        #expect(lines.contains { $0.hasPrefix(" root AppMain AppMain.swift:") && $0.contains("launch Analytics.shared.start · stores main.store :")
            && $0.hasSuffix("(2 models) · RootView: TabView HomeView, StatsView \"Progress\"; presents OnboardingView") })
        #expect(lines.contains(" duplicate types RunAttributes (app, widget)"))
        #expect(lines.contains(" bridges WatchConnectivity app PhoneSync ↔ watch WatchMain · ActivityKit app RunAttributes ↔ widget RunLiveActivity"))
        #expect(lines.contains(" app group group.com.example.app declared by app (App/App.entitlements), unused"))
        #expect(lines.last == "STYLE app: 5 SwiftUI views, 0 view models, 2 .shared singletons")
        #expect(!text.contains("MVVM") && !text.contains("%") && !text.hasPrefix("{"))
        #expect(TokenEstimate.of(text) <= Budget.architecture.tokens)

        // Over a small budget detail goes first, then lines, and the text says how to see the rest.
        let small = ArchitectureRenderer.render(overview, budget: Budget(tokens: 150))
        #expect(TokenEstimate.of(small) <= 150)
        #expect(small.hasPrefix("App.xcodeproj\n4 targets"))
        #expect(small.hasSuffix("more: architecture(focus:\"App\")"))
    }

    // MARK: Focus

    @Test("Focus narrows to a target, a package or a folder, and names what it accepts on a miss")
    func focus() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.repository, name: "arch-focus")
        let watch = try engine.architectureOverview(focus: "watch")
        #expect(watch.focus == ArchitectureOverview.Focus(kind: .target, name: "Watch"))
        #expect(watch.targets.map(\.name) == ["Watch"])
        #expect(watch.modules.map(\.name) == ["Watch"])
        #expect(watch.crossTarget.bridges.map(\.framework) == ["WatchConnectivity"])
        #expect(watch.packages.isEmpty && watch.notBuilt.isEmpty)

        let features = try engine.architectureOverview(focus: "App/Features/")
        #expect(features.focus == ArchitectureOverview.Focus(kind: .folder, name: "App/Features"))
        let module = try #require(features.modules.first)
        #expect(module.root == "App/Features" && module.folders.map(\.name).sorted() == ["Home", "Onboarding", "Stats"])
        #expect(module.featureEdges.isEmpty && module.direction == [ArchitectureOverview.Dependency(from: "Home", to: ["Stats"])])
        #expect(module.usesOutside == ["Services", "Models"])
        #expect(module.usedFromOutside == ["RootView.swift", "Services"])

        let kit = try engine.architectureOverview(focus: "Packages/Kit")
        #expect(kit.focus == ArchitectureOverview.Focus(kind: .package, name: "Packages/Kit"))
        #expect(kit.packages.map(\.name) == ["Kit"])
        #expect(kit.targets.map(\.name) == ["Kit", "KitCore", "KitCoreTests"])
        // A package named like its own target means the package; its other targets by name mean themselves.
        #expect(try engine.architectureOverview(focus: "Kit").focus == ArchitectureOverview.Focus(kind: .package, name: "Packages/Kit"))
        #expect(try engine.architectureOverview(focus: "KitCore").focus == ArchitectureOverview.Focus(kind: .target, name: "KitCore"))

        #expect(throws: EngineError.self) { try engine.architectureOverview(focus: "Nowhere") }
    }

    @Test("The MCP tool returns the rendered overview with its v2 description")
    func tool() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.repository, name: "arch-tool")
        let tool = ArchitectureTool()
        #expect(tool.isV2 && tool.description == tool.descriptionV2 && tool.description.count <= 320)
        let context = ToolContext(engine: engine) { 0 }
        let output = await MCPToolCatalog.execute(tool, arguments: [:], context: context)
        #expect(!output.isError)
        #expect(output.text == ArchitectureRenderer.render(try engine.architectureOverview(), budget: .architecture))
        let focused = await MCPToolCatalog.execute(tool, arguments: ["focus": .string("Nowhere")], context: context)
        #expect(focused.isError && focused.text.contains("App"))
    }
}
