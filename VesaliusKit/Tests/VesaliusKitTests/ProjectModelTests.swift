import Foundation
@testable import QueryEngine
import RepositoryIndex
@testable import RepositoryScanner
import Testing
import VesaliusCore

/// The project model, test classification by build target, test runners and config
/// links, indexed from small repositories through the real pipeline.
@Suite("Project model: targets, membership, packages, schemes, test plans and runners", .serialized)
struct ProjectModelTests {
    // MARK: Fixtures

    /// An Xcode 16 project (objectVersion 77) with synchronized folders and two exception sets: one removes
    /// App/Info.plist from App, the other adds App/Models/Workout.swift to Watch, which does not sync App.
    static let synchronizedProject = """
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
                        "Shared Assets/Colors.swift",
                    );
                    target = T3 /* Watch */;
                };
        /* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

        /* Begin PBXFileSystemSynchronizedRootGroup section */
                G1 /* App */ = {
                    isa = PBXFileSystemSynchronizedRootGroup;
                    exceptions = (
                        E1 /* Exceptions for "App" folder in "App" target */,
                        E2 /* Exceptions for "App" folder in "Watch" target */,
                    );
                    path = App;
                    sourceTree = "<group>";
                };
                G2 /* Shared */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Shared; sourceTree = "<group>"; };
                G3 /* Widget */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Widget; sourceTree = "<group>"; };
                G4 /* Watch */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Watch; sourceTree = "<group>"; };
                G5 /* AppTests */ = {isa = PBXFileSystemSynchronizedRootGroup; path = AppTests; sourceTree = "<group>"; };
                G6 /* AppUITests */ = {isa = PBXFileSystemSynchronizedRootGroup; path = AppUITests; sourceTree = "<group>"; };
        /* End PBXFileSystemSynchronizedRootGroup section */

                M0 = {isa = PBXGroup; children = (G1, G2, G4, G5, G6, ); sourceTree = "<group>"; };
                P1 /* App.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
                P2 /* Widget.appex */ = {isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = Widget.appex; sourceTree = BUILT_PRODUCTS_DIR; };
                P3 /* Watch.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; path = Watch.app; sourceTree = BUILT_PRODUCTS_DIR; };
                F1 /* WidgetKit.framework */ = {isa = PBXFileReference; name = WidgetKit.framework; path = System/Library/Frameworks/WidgetKit.framework; sourceTree = SDKROOT; };
                BF1 /* Widget.appex in Embed Foundation Extensions */ = {isa = PBXBuildFile; fileRef = P2 /* Widget.appex */; };
                BF2 /* WidgetKit.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = F1 /* WidgetKit.framework */; };
                CP1 /* Embed Foundation Extensions */ = {isa = PBXCopyFilesBuildPhase; dstSubfolderSpec = 13; files = (BF1, ); };
                FW2 /* Frameworks */ = {isa = PBXFrameworksBuildPhase; files = (BF2, ); };
                D1 /* PBXTargetDependency */ = {isa = PBXTargetDependency; target = T2 /* Widget */; };

        /* Begin PBXNativeTarget section */
                T1 /* App */ = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = L1;
                    buildPhases = (
                        CP1 /* Embed Foundation Extensions */,
                    );
                    dependencies = (
                        D1 /* PBXTargetDependency */,
                    );
                    fileSystemSynchronizedGroups = (
                        G1 /* App */,
                        G2 /* Shared */,
                    );
                    name = App;
                    packageProductDependencies = (
                        PD1 /* Charts */,
                    );
                    productReference = P1 /* App.app */;
                    productType = "com.apple.product-type.application";
                };
                T2 /* Widget */ = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = L2;
                    buildPhases = (
                        FW2 /* Frameworks */,
                    );
                    fileSystemSynchronizedGroups = (
                        G3 /* Widget */,
                        G2 /* Shared */,
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
                T5 /* AppUITests */ = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = L5;
                    fileSystemSynchronizedGroups = (
                        G6 /* AppUITests */,
                    );
                    name = AppUITests;
                    productType = "com.apple.product-type.bundle.ui-testing";
                };
        /* End PBXNativeTarget section */

                R0 /* Project object */ = {
                    isa = PBXProject;
                    buildConfigurationList = L0;
                    mainGroup = M0;
                    packageReferences = (
                        PR1 /* XCRemoteSwiftPackageReference "charts" */,
                    );
                    targets = (
                        T1 /* App */,
                        T2 /* Widget */,
                        T3 /* Watch */,
                        T4 /* AppTests */,
                        T5 /* AppUITests */,
                    );
                };
                PR1 /* XCRemoteSwiftPackageReference "charts" */ = {isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/example/charts.git"; };
                PD1 /* Charts */ = {isa = XCSwiftPackageProductDependency; package = PR1; productName = Charts; };
                C0 /* Release */ = {isa = XCBuildConfiguration; buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "SHIPPING"; }; name = Release; };
                C0D /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {IPHONEOS_DEPLOYMENT_TARGET = 16.0; SDKROOT = iphoneos; }; name = Debug; };
                L0 = {isa = XCConfigurationList; buildConfigurations = (C0D, C0, ); defaultConfigurationName = Release; };
                C1 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGN_ENTITLEMENTS = App/App.entitlements; PRODUCT_BUNDLE_IDENTIFIER = com.example.app; PRODUCT_NAME = "$(TARGET_NAME)"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "PRO $(inherited)"; }; name = Release; };
                L1 = {isa = XCConfigurationList; buildConfigurations = (C1, ); defaultConfigurationName = Release; };
                C2 = {isa = XCBuildConfiguration; buildSettings = {INFOPLIST_FILE = Widget/Info.plist; PRODUCT_BUNDLE_IDENTIFIER = "com.example.app.$(PRODUCT_NAME:rfc1034identifier)"; }; name = Release; };
                L2 = {isa = XCConfigurationList; buildConfigurations = (C2, ); defaultConfigurationName = Release; };
                C3 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "Watch Companion"; SDKROOT = watchos; WATCHOS_DEPLOYMENT_TARGET = 11.0; }; name = Release; };
                L3 = {isa = XCConfigurationList; buildConfigurations = (C3, ); defaultConfigurationName = Release; };
                C4 = {isa = XCBuildConfiguration; buildSettings = {TEST_HOST = "$(BUILT_PRODUCTS_DIR)/App.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/App"; }; name = Release; };
                L4 = {isa = XCConfigurationList; buildConfigurations = (C4, ); defaultConfigurationName = Release; };
                C5 = {isa = XCBuildConfiguration; buildSettings = {TEST_TARGET_NAME = App; }; name = Release; };
                L5 = {isa = XCConfigurationList; buildConfigurations = (C5, ); defaultConfigurationName = Release; };
            };
            rootObject = R0 /* Project object */;
        }
        """

    static let synchronizedRepository: [String: String] = [
        ".gitignore": "Scratch.xcodeproj/\n",
        "App.xcodeproj/project.pbxproj": synchronizedProject,
        // An ignored scratch copy claiming the unbuilt folder; the model must skip it.
        "Scratch.xcodeproj/project.pbxproj": """
            // !$*UTF8*$!
            {
                objects = {
                    S1 /* Orphan */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Orphan; sourceTree = "<group>"; };
                    ST /* App */ = {isa = PBXNativeTarget; fileSystemSynchronizedGroups = (S1, ); name = App; productType = "com.apple.product-type.application"; };
                    SR = {isa = PBXProject; targets = (ST, ); };
                };
                rootObject = SR;
            }
            """,
        "App/AppMain.swift": """
            import SwiftUI

            @main
            struct AppMain: App {
                let defaults = UserDefaults(suiteName: "group.com.example.app")
                var body: some Scene { WindowGroup { Text("Hi") } }
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
                    <string>group.com.example.unused</string>
                </array>
            </dict>
            </plist>
            """,
        "App/Models/Workout.swift": "struct Workout {\n    var minutes = 0\n}\n",
        "App/Shared Assets/Colors.swift": "enum Colors {}\n",
        "App/Debug/MockWorkouts.swift": "enum MockWorkouts {\n    static let all = [Workout()]\n}\n",
        "Shared/Palette.swift": "enum Palette {}\n",
        "Widget/WidgetMain.swift": "struct WidgetMain {}\n",
        "Widget/Info.plist": """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
                <key>NSExtension</key>
                <dict>
                    <key>NSExtensionAttributes</key>
                    <dict>
                        <key>IntentsSupported</key>
                        <array>
                            <string>INStartWorkoutIntent</string>
                        </array>
                    </dict>
                    <key>NSExtensionPointIdentifier</key>
                    <string>com.apple.widgetkit-extension</string>
                </dict>
            </dict>
            </plist>
            """,
        "Watch/WatchMain.swift": "struct WatchMain {\n    let workout = Workout()\n}\n",
        "AppTests/WorkoutTests.swift": "import XCTest\n\nfinal class WorkoutTests: XCTestCase {}\n",
        "AppTests/Fixtures/sample.json": "{}\n",
        "AppUITests/LaunchTests.swift": "import XCTest\n\nfinal class LaunchTests: XCTestCase {}\n",
        "Orphan/Stray.swift": "struct Stray {}\n",
        "docs/specs/design.md": "# Design\n",
    ]

    // MARK: Target membership

    @Test("Synchronized folders, exception sets and evidence lines become targets and file_targets")
    func synchronizedMembership() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.synchronizedRepository, name: "sync")
        let pbxproj = Self.synchronizedProject
        let pbxprojPath = "App.xcodeproj/project.pbxproj"

        let targets = try engine.rawQuery("SELECT name, system, product_type, platform, deployment_target, bundle_id, test_host, is_test, test_kind, module_name, project_line, extension_point FROM targets ORDER BY id")
        #expect(targets.rows.map { $0[0].stringValue } == ["App", "Widget", "Watch", "AppTests", "AppUITests"])
        let app = try #require(targets.rows.first)
        #expect(app[3].stringValue == "iOS")
        #expect(app[4].stringValue == "17.0")  // Release: the default configuration, not Debug's 16.0
        #expect(app[5].stringValue == "com.example.app")
        #expect(app[10].intValue == line("T1 /* App */ = {", in: pbxproj))
        #expect(targets.rows[1][5].stringValue == "com.example.app.Widget")
        #expect(targets.rows[1][11].stringValue == "com.apple.widgetkit-extension")
        #expect(targets.rows[2][3].stringValue == "watchOS")
        #expect(targets.rows[2][4].stringValue == "11.0")
        #expect(targets.rows[2][9].stringValue == "Watch_Companion")
        #expect(targets.rows[3][6].stringValue == "App")  // TEST_HOST
        #expect(targets.rows[3][8].stringValue == "unit")
        #expect(targets.rows[4][6].stringValue == "App")  // TEST_TARGET_NAME
        #expect(targets.rows[4][8].stringValue == "ui")

        func memberships(_ path: String) throws -> [String] {
            try engine.rawQuery("""
                SELECT t.name || '|' || ft.via || '|' || ft.evidence_path || '|' || ft.evidence_line
                FROM file_targets ft JOIN targets t ON t.id = ft.target_id JOIN files f ON f.id = ft.file_id
                WHERE f.path = '\(path)' ORDER BY t.id
                """).rows.compactMap { $0[0].stringValue }
        }
        let appGroupLine = try lineNumber("G1 /* App */,", in: pbxproj, after: "T1 /* App */ = {")
        let addedLine = try lineNumber("Models/Workout.swift,", in: pbxproj)
        // Added to Watch by the exception set, with the entry's own line as evidence.
        #expect(try memberships("App/Models/Workout.swift") == ["App|sync-root|\(pbxprojPath)|\(appGroupLine)", "Watch|exception-add|\(pbxprojPath)|\(addedLine)"])
        #expect(try memberships("App/Shared Assets/Colors.swift").last == "Watch|exception-add|\(pbxprojPath)|\(try lineNumber("\"Shared Assets/Colors.swift\",", in: pbxproj))")
        // Removed from App by its own exception set.
        #expect(try memberships("App/Info.plist").isEmpty)
        // One folder synchronized into two targets.
        #expect(try memberships("Shared/Palette.swift").map { $0.split(separator: "|")[0] } == ["App", "Widget"])
        // Synchronized groups referenced only by a target resolve against the project folder.
        #expect(try memberships("Widget/WidgetMain.swift").map { $0.split(separator: "|")[0] } == ["Widget"])
        // Nothing builds Orphan/ (the ignored scratch project would have).
        #expect(try memberships("Orphan/Stray.swift").isEmpty)

        let modules = try engine.rawQuery("SELECT name, root_path, manifest_path FROM modules WHERE kind = 'xcode-target' ORDER BY name")
        #expect(modules.rows.map { "\($0[0].stringValue ?? "")|\($0[1].stringValue ?? "")|\($0[2].stringValue ?? "")" } == [
            "App|App|App.xcodeproj", "AppTests|AppTests|App.xcodeproj", "AppUITests|AppUITests|App.xcodeproj", "Watch|Watch|App.xcodeproj", "Widget|Widget|App.xcodeproj",
        ])

        let dependencies = try engine.rawQuery("SELECT t.name, d.kind, d.name, d.dep_target_id IS NOT NULL, d.package, d.evidence_line FROM target_deps d JOIN targets t ON t.id = d.target_id ORDER BY d.rowid")
        let described = dependencies.rows.map { "\($0[0].stringValue ?? "") \($0[1].stringValue ?? "") \($0[2].stringValue ?? "") \($0[3].intValue ?? 0) \($0[4].stringValue ?? "-")" }
        #expect(described == ["App embed Widget 1 -", "App target Widget 1 -", "App product Charts 0 charts", "Widget framework WidgetKit 0 -"])
        let packages = try engine.rawQuery("SELECT name, kind, url FROM packages")
        #expect(packages.rows.map { "\($0[0].stringValue ?? "")|\($0[1].stringValue ?? "")|\($0[2].stringValue ?? "")" } == ["charts|remote|https://github.com/example/charts.git"])

        let skipped = try engine.rawQuery("SELECT value FROM meta WHERE key = 'skipped_projects'").rows.first?[0].stringValue ?? ""
        #expect(skipped.contains("\"path\":\"Scratch.xcodeproj\""))
        #expect(skipped.contains("\"reason\":\"gitignored\""))
        #expect(skipped.contains("\"evidence\":\".gitignore:1\""))
    }

    // MARK: Tests by build target

    @Test("Tests are classified by build target before names")
    func testsByTarget() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.synchronizedRepository, name: "e13")
        let pbxproj = Self.synchronizedProject
        let rows = try engine.rawQuery("SELECT path, is_test, test_kind, test_evidence FROM files ORDER BY path")
        var byPath: [String: (Int?, String?, String?)] = [:]
        for row in rows.rows { byPath[row[0].stringValue ?? ""] = (row[1].intValue, row[2].stringValue, row[3].stringValue) }
        let testsLine = try lineNumber("G5 /* AppTests */,", in: pbxproj, after: "T4 /* AppTests */ = {")
        #expect(byPath["AppTests/WorkoutTests.swift"]?.0 == 1)
        #expect(byPath["AppTests/WorkoutTests.swift"]?.1 == "unit")
        #expect(byPath["AppTests/WorkoutTests.swift"]?.2 == "App.xcodeproj/project.pbxproj:\(testsLine) AppTests")
        #expect(byPath["AppTests/Fixtures/sample.json"]?.1 == "support")
        #expect(byPath["AppUITests/LaunchTests.swift"]?.1 == "ui")
        // Named like test support, compiled into the app: not a test.
        #expect(byPath["App/Debug/MockWorkouts.swift"]?.0 == 0)
        // A design document in a `specs` folder is not a test.
        #expect(byPath["docs/specs/design.md"]?.0 == 0)
        #expect(byPath["Orphan/Stray.swift"]?.0 == 0)
    }

    // MARK: Classic projects

    @Test("Classic build phases resolve file paths through the group tree")
    func classicBuildPhases() async throws {
        let pbxproj = """
            // !$*UTF8*$!
            {
                archiveVersion = 1;
                objectVersion = 56;
                objects = {
                    F1 /* main.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
                    F2 /* Helper.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Helper.swift; sourceTree = "<group>"; };
                    F3 /* Legacy.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = Legacy.swift; path = Sources/Legacy.swift; sourceTree = SOURCE_ROOT; };
                    F4 /* Data.json */ = {isa = PBXFileReference; path = Data.json; sourceTree = "<group>"; };
                    B1 /* main.swift in Sources */ = {isa = PBXBuildFile; fileRef = F1 /* main.swift */; };
                    B2 /* Helper.swift in Sources */ = {isa = PBXBuildFile; fileRef = F2 /* Helper.swift */; };
                    B3 /* Legacy.swift in Sources */ = {isa = PBXBuildFile; fileRef = F3 /* Legacy.swift */; };
                    B4 /* Data.json in Resources */ = {isa = PBXBuildFile; fileRef = F4 /* Data.json */; };
                    B5 /* Localizable.strings in Resources */ = {isa = PBXBuildFile; fileRef = V1 /* Localizable.strings */; };
                    V1 /* Localizable.strings */ = {isa = PBXVariantGroup; children = (V2, ); name = Localizable.strings; sourceTree = "<group>"; };
                    V2 /* en */ = {isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = en; path = en.lproj/Localizable.strings; sourceTree = "<group>"; };
                    G0 = {isa = PBXGroup; children = (G1, F3, ); sourceTree = "<group>"; };
                    G1 /* Tool */ = {isa = PBXGroup; children = (F1, G2, F4, V1, ); path = Tool; sourceTree = "<group>"; };
                    G2 /* Support */ = {isa = PBXGroup; children = (F2, ); path = Support; sourceTree = "<group>"; };
                    P1 /* Sources */ = {isa = PBXSourcesBuildPhase; files = (B1, B2, B3, ); };
                    P2 /* Resources */ = {isa = PBXResourcesBuildPhase; files = (B4, B5, ); };
                    T1 /* Tool */ = {isa = PBXNativeTarget; buildPhases = (P1, P2, ); name = Tool; productType = "com.apple.product-type.tool"; };
                    R0 = {isa = PBXProject; mainGroup = G0; targets = (T1, ); };
                };
                rootObject = R0;
            }
            """
        let (engine, _) = try await RepoFixture.indexed([
            "Classic/Classic.xcodeproj/project.pbxproj": pbxproj,
            "Classic/Tool/main.swift": "print(Helper().name)\n",
            "Classic/Tool/Support/Helper.swift": "struct Helper { let name = \"x\" }\n",
            "Classic/Tool/Data.json": "{}\n",
            "Classic/Sources/Legacy.swift": "struct Legacy {}\n",
            // Not in any build phase; a variant group (no path of its own) must not pull in its whole folder.
            "Classic/Tool/Unlisted.swift": "struct Unlisted {}\n",
        ], name: "classic")
        let rows = try engine.rawQuery("""
            SELECT f.path, ft.via, ft.evidence_line FROM file_targets ft JOIN files f ON f.id = ft.file_id ORDER BY f.path
            """)
        #expect(rows.rows.map { "\($0[0].stringValue ?? "")|\($0[1].stringValue ?? "")|\($0[2].intValue ?? 0)" } == [
            "Classic/Sources/Legacy.swift|build-phase|\(try lineNumber("B3 /* Legacy.swift in Sources */", in: pbxproj))",
            "Classic/Tool/Data.json|build-phase|\(try lineNumber("B4 /* Data.json in Resources */", in: pbxproj))",
            "Classic/Tool/Support/Helper.swift|build-phase|\(try lineNumber("B2 /* Helper.swift in Sources */", in: pbxproj))",
            "Classic/Tool/main.swift|build-phase|\(try lineNumber("B1 /* main.swift in Sources */", in: pbxproj))",
        ])
        let module = try engine.rawQuery("SELECT root_path FROM modules WHERE name = 'Tool'")
        #expect(module.rows.first?[0].stringValue == "Classic")
    }

    @Test("A project with no membership data falls back to the same-name folder")
    func legacyFolders() throws {
        let project = XcodeProject.parse(data: Data("""
            // !$*UTF8*$!
            {
                objects = {
                    A1 /* Phone */ = {
                        isa = PBXNativeTarget;
                        name = Phone;
                    };
                    A2 /* WatchTests */ = {
                        isa = PBXNativeTarget;
                        name = WatchTests;
                    };
                };
            }
            """.utf8), bundle: "App.xcodeproj", root: nil)
        #expect(project.targets.map(\.name) == ["Phone", "WatchTests"])
        #expect(project.targets.map(\.line) == [4, 8])
        #expect(project.targets.allSatisfy { !$0.hasMembershipData })
        #expect(project.targets[1].testKind == "unit")  // no product type: the conventional name decides

        // A merge conflict breaks the property list: target names still come through, with a warning.
        let conflicted = XcodeProject.parse(data: Data("""
            {
                objects = {
            <<<<<<< HEAD
                    A1 = { isa = PBXNativeTarget; name = Phone; };
            =======
                    A1 = { isa = PBXNativeTarget; name = Tablet; };
            >>>>>>> branch
                };
            }
            """.utf8), bundle: "App.xcodeproj", root: nil)
        #expect(conflicted.isFallback)
        #expect(conflicted.targets.map(\.name) == ["Phone", "Tablet"])
        #expect(!conflicted.warnings.isEmpty)
    }

    // MARK: Swift packages

    static let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription

        let sharedSettings: [SwiftSetting] = [.enableExperimentalFeature("StrictConcurrency")]
        let coreDependencies: [Target.Dependency] = [
            .product(name: "Logging", package: "swift-log"),
        ]

        let package = Package(
            name: "Kit",
            platforms: [.iOS(.v17), .macOS(.v14)],
            products: [
                .library(name: "Kit", targets: ["KitCore", "KitUI"]),
                .executable(name: "kit-cli", targets: ["KitCLI"]),
            ],
            dependencies: [
                .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
                .package(path: "../Shared"),
            ],
            targets: [
                // .target(name: "Commented") is not a target.
                .target(name: "KitCore", dependencies: coreDependencies, swiftSettings: sharedSettings),
                .target(
                    name: "KitUI",
                    dependencies: ["KitCore", .target(name: "KitExtras", condition: .when(platforms: [.iOS]))],
                    path: "Sources/UI",
                    exclude: ["Legacy"]
                ),
                .target(name: "KitExtras", resources: [.process("Assets")]),
                .executableTarget(name: "KitCLI", dependencies: [.byName(name: "KitCore")]),
                .testTarget(name: "KitCoreTests", dependencies: ["KitCore", .product(name: "Logging", package: "swift-log")]),
                .binaryTarget(name: "Blob", path: "Blob.xcframework"),
            ]
        )
        """

    @Test("Package.swift is read statically: products, targets, paths, dependencies and bindings")
    func manifestParsing() throws {
        let parsed = SwiftPackageManifest.parse(text: Self.manifest, path: "Packages/Kit/Package.swift")
        #expect(parsed.name == "Kit")
        #expect(!parsed.isPartial)
        #expect(parsed.products.map { "\($0.name):\($0.kind):\($0.targets.joined(separator: "+")):\($0.line)" } == [
            "Kit:library:KitCore+KitUI:\(try lineNumber(".library(name: \"Kit\"", in: Self.manifest))",
            "kit-cli:executable:KitCLI:\(try lineNumber(".executable(", in: Self.manifest))",
        ])
        #expect(parsed.dependencies.map { "\($0.kind) \($0.identity) \($0.location)" } == [
            "url swift-log https://github.com/apple/swift-log.git", "path Shared Packages/Shared",
        ])
        #expect(parsed.targets.map(\.name) == ["KitCore", "KitUI", "KitExtras", "KitCLI", "KitCoreTests", "Blob"])
        let core = parsed.targets[0]
        #expect(core.path == "Packages/Kit/Sources/KitCore")
        #expect(core.dependencies.map { "\($0.kind) \($0.name) \($0.package ?? "-")" } == ["product Logging swift-log"])  // through `let coreDependencies`
        let ui = parsed.targets[1]
        #expect(ui.path == "Packages/Kit/Sources/UI")
        #expect(ui.hasExplicitPath)
        #expect(ui.exclude == ["Packages/Kit/Sources/UI/Legacy"])
        #expect(ui.dependencies.map { "\($0.kind) \($0.name)" } == ["byName KitCore", "target KitExtras"])
        #expect(ui.line == line("name: \"KitUI\"", in: Self.manifest).map { $0 - 1 })
        #expect(parsed.targets[3].kind == "executableTarget")
        #expect(parsed.targets[4].isTest)
        #expect(parsed.targets[4].path == "Packages/Kit/Tests/KitCoreTests")

        // Mutating the package after creating it: what the call declares is kept, and the result says so.
        let mutated = SwiftPackageManifest.parse(text: """
            import PackageDescription
            let package = Package(name: "X", targets: [.target(name: "A")])
            package.targets.append(.target(name: "B"))
            """, path: "Package.swift")
        #expect(mutated.targets.map(\.name) == ["A"])
        #expect(mutated.isPartial)
    }

    @Test("SwiftPM targets, membership, products and test targets are indexed")
    func swiftPackages() async throws {
        let (engine, _) = try await RepoFixture.indexed([
            "Packages/Kit/Package.swift": Self.manifest,
            "Packages/Kit/Sources/KitCore/Core.swift": "public struct Core {}\n",
            "Packages/Kit/Sources/UI/Screen.swift": "struct Screen {}\n",
            "Packages/Kit/Sources/UI/Legacy/Old.swift": "struct Old {}\n",
            "Packages/Kit/Sources/KitExtras/Extra.swift": "struct Extra {}\n",
            "Packages/Kit/Sources/KitCLI/main.swift": "print(1)\n",
            "Packages/Kit/Tests/KitCoreTests/CoreTests.swift": "import XCTest\n",
            "Packages/Kit/Tests/Helpers/Mock.swift": "struct Mock {}\n",
        ], name: "spm")
        let targets = try engine.rawQuery("SELECT name, system, product_type, is_test, project_path, module_id IS NOT NULL FROM targets ORDER BY id")
        #expect(targets.rows.map { "\($0[0].stringValue ?? "")|\($0[2].stringValue ?? "")|\($0[3].intValue ?? -1)|\($0[5].intValue ?? 0)" } == [
            "KitCore|target|0|1", "KitUI|target|0|1", "KitExtras|target|0|1", "KitCLI|executableTarget|0|1", "KitCoreTests|testTarget|1|1",
        ])
        let members = try engine.rawQuery("SELECT f.path, t.name, ft.via FROM file_targets ft JOIN files f ON f.id = ft.file_id JOIN targets t ON t.id = ft.target_id ORDER BY f.path")
        #expect(members.rows.map { "\($0[0].stringValue ?? "") \($0[1].stringValue ?? "")" } == [
            "Packages/Kit/Sources/KitCLI/main.swift KitCLI",
            "Packages/Kit/Sources/KitCore/Core.swift KitCore",
            "Packages/Kit/Sources/KitExtras/Extra.swift KitExtras",
            "Packages/Kit/Sources/UI/Screen.swift KitUI",  // Legacy/ is excluded
            "Packages/Kit/Tests/KitCoreTests/CoreTests.swift KitCoreTests",
        ])
        let products = try engine.rawQuery("SELECT p.name, p.kind, pp.name, pp.kind, pp.targets FROM package_products pp JOIN packages p ON p.id = pp.package_id ORDER BY pp.rowid")
        #expect(products.rows.map { "\($0[0].stringValue ?? "") \($0[2].stringValue ?? "") \($0[3].stringValue ?? "") \($0[4].stringValue ?? "")" } == [
            "Kit Kit library KitCore,KitUI", "Kit kit-cli executable KitCLI",
        ])
        let packages = try engine.rawQuery("SELECT name, kind, path, url FROM packages ORDER BY id")
        #expect(packages.rows.map { "\($0[0].stringValue ?? "")|\($0[1].stringValue ?? "")" } == ["Kit|local", "swift-log|remote", "Shared|local"])
        let tests = try engine.rawQuery("SELECT path, is_test, test_kind, test_evidence FROM files WHERE path LIKE 'Packages/Kit/Tests/%' ORDER BY path")
        #expect(tests.rows.map { "\($0[0].stringValue ?? "")|\($0[1].intValue ?? -1)|\($0[2].stringValue ?? "-")" } == [
            "Packages/Kit/Tests/Helpers/Mock.swift|1|-",  // no target: the folder name decides
            "Packages/Kit/Tests/KitCoreTests/CoreTests.swift|1|unit",
        ])
        #expect(tests.rows.last?[3].stringValue == "Packages/Kit/Package.swift:\(try lineNumber(".testTarget(", in: Self.manifest)) KitCoreTests")
        let dependency = try engine.rawQuery("SELECT d.kind, d.name, t2.name FROM target_deps d JOIN targets t ON t.id = d.target_id LEFT JOIN targets t2 ON t2.id = d.dep_target_id WHERE t.name = 'KitUI' ORDER BY d.rowid")
        #expect(dependency.rows.map { "\($0[0].stringValue ?? "") \($0[1].stringValue ?? "") \($0[2].stringValue ?? "-")" } == ["target KitCore KitCore", "target KitExtras KitExtras"])
    }

    // MARK: Schemes, test plans, StoreKit, entitlements, runners

    static let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme
           LastUpgradeVersion = "2600"
           version = "1.7">
           <BuildAction>
              <BuildActionEntries>
                 <BuildActionEntry buildForRunning = "YES">
                    <BuildableReference
                       BuildableIdentifier = "primary"
                       BlueprintName = "App"
                       ReferencedContainer = "container:App.xcodeproj">
                    </BuildableReference>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
           <TestAction buildConfiguration = "Debug">
              <TestPlans>
                 <TestPlanReference
                    reference = "container:App.xctestplan"
                    default = "YES">
                 </TestPlanReference>
                 <TestPlanReference
                    reference = "container:Nightly.xctestplan">
                 </TestPlanReference>
              </TestPlans>
           </TestAction>
           <LaunchAction buildConfiguration = "Debug">
              <BuildableProductRunnable runnableDebuggingMode = "0">
                 <BuildableReference
                    BuildableIdentifier = "primary"
                    BlueprintName = "App"
                    ReferencedContainer = "container:App.xcodeproj">
                 </BuildableReference>
              </BuildableProductRunnable>
              <EnvironmentVariables>
                 <EnvironmentVariable
                    key = "FEATURE_FLAG"
                    value = "1"
                    isEnabled = "YES">
                 </EnvironmentVariable>
                 <EnvironmentVariable
                    key = "VERBOSE"
                    value = "2"
                    isEnabled = "NO">
                 </EnvironmentVariable>
              </EnvironmentVariables>
              <StoreKitConfigurationFileReference
                 identifier = "../../../Config/App.storekit">
              </StoreKitConfigurationFileReference>
           </LaunchAction>
        </Scheme>
        """

    static let testPlan = """
        {
          "configurations" : [ { "id" : "1", "name" : "Default", "options" : { } } ],
          "testTargets" : [
            {
              "target" : {
                "containerPath" : "container:App.xcodeproj",
                "identifier" : "T4",
                "name" : "AppTests"
              }
            },
            {
              "skippedTests" : [
                "SlowTests",
                "FlakyTests\\/testRetry()"
              ],
              "target" : {
                "containerPath" : "container:App.xcodeproj",
                "identifier" : "T5",
                "name" : "AppUITests"
              }
            }
          ],
          "version" : 1
        }
        """

    static let storeKit = """
        {
          "products" : [
            {
              "productID" : "lifetime_pro",
              "type" : "NonConsumable"
            }
          ],
          "subscriptionGroups" : [
            {
              "subscriptions" : [
                {
                  "productID" : "pro_monthly",
                  "type" : "RecurringSubscription"
                }
              ]
            }
          ]
        }
        """

    @Test("Schemes, test plans, StoreKit products, app groups and intents become config links")
    func configLinks() async throws {
        var files = Self.synchronizedRepository
        files["App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"] = Self.scheme
        files["App.xctestplan"] = Self.testPlan
        files["Config/App.storekit"] = Self.storeKit
        files["App/Store.swift"] = "enum Store {\n    static let monthly = \"pro_monthly\"\n}\n"
        let (engine, _) = try await RepoFixture.indexed(files, name: "config")

        func links(_ kind: String) throws -> [String] {
            flat(try engine.rawQuery("""
                SELECT c.config_path, c.config_line, c.key, f.path, c.line, t.name, c.evidence FROM config_links c
                LEFT JOIN files f ON f.id = c.file_id LEFT JOIN targets t ON t.id = c.target_id WHERE c.kind = '\(kind)' ORDER BY c.rowid
                """).rows)
        }
        let schemePath = "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"
        #expect(try links("scheme-storekit") == ["\(schemePath)|\(try lineNumber("<StoreKitConfigurationFileReference", in: Self.scheme))|Config/App.storekit|Config/App.storekit|-|App|App"])
        let planLine = try lineNumber("<TestPlanReference", in: Self.scheme)
        #expect(try links("scheme-testplan") == [
            "\(schemePath)|\(planLine)|App.xctestplan|App.xctestplan|-|-|default",
            "\(schemePath)|\(try lineNumber("<TestPlanReference", in: Self.scheme, after: "default = \"YES\""))|Nightly.xctestplan|-|-|-|-",
        ])
        #expect(try links("scheme-env") == [
            "\(schemePath)|\(try lineNumber("<EnvironmentVariable", in: Self.scheme))|FEATURE_FLAG|-|-|-|launch: 1",
            "\(schemePath)|\(try lineNumber("<EnvironmentVariable", in: Self.scheme, after: "FEATURE_FLAG"))|VERBOSE|-|-|-|launch: 2 (disabled)",
        ])
        #expect(try links("testplan-target") == [
            "App.xctestplan|\(try lineNumber("\"AppTests\"", in: Self.testPlan))|AppTests|App.xctestplan|-|AppTests|-",
            "App.xctestplan|\(try lineNumber("\"AppUITests\"", in: Self.testPlan))|AppUITests|App.xctestplan|-|AppUITests|skipped: SlowTests, FlakyTests/testRetry()",
        ])
        #expect(try links("storekit-product") == [
            "Config/App.storekit|\(try lineNumber("lifetime_pro", in: Self.storeKit))|lifetime_pro|-|-|-|NonConsumable",
            "Config/App.storekit|\(try lineNumber("pro_monthly", in: Self.storeKit))|pro_monthly|App/Store.swift|2|-|RecurringSubscription",
        ])
        #expect(try links("entitlement-appgroup") == [
            "App/App.entitlements|6|group.com.example.app|App/AppMain.swift|5|App|suiteName",
            "App/App.entitlements|7|group.com.example.unused|-|-|App|unused",
        ])
        #expect(try links("extension-intent") == ["Widget/Info.plist|10|INStartWorkoutIntent|-|-|Widget|com.apple.widgetkit-extension"])
    }

    @Test("Test runners: vitest globs classify TypeScript tests; scripts and usage lines are recorded")
    func testRunners() async throws {
        let vitest = """
            import { defineConfig } from "vitest/config";

            export default defineConfig({
              test: {
                environment: "node",
                include: ["tests/**/*.test.ts"],
                coverage: {
                  include: ["src/**/*.ts"],
                },
              },
            });
            """
        let script = """
            #!/bin/bash
            # Runs the end-to-end tests.
            #
            #   scripts/run-tests.sh unit                   the unit suite
            #   scripts/run-tests.sh e2e [--only Name]      browser tests (repeat --only)
            #   CI=1 scripts/run-tests.sh all               everything, as CI runs it
            #   --verbose            more output
            set -u
            """
        let (engine, _) = try await RepoFixture.indexed([
            "vitest.config.ts": vitest,
            "package.json": """
                {
                  "name": "web",
                  "scripts": {
                    "test": "vitest run",
                    "lint": "eslint"
                  }
                }
                """,
            "scripts/run-tests.sh": script,
            // A sub-package's jest config: globs are relative to its folder, keys sit inside `module.exports`.
            "packages/api/jest.config.js": "module.exports = {\n  testEnvironment: \"node\",\n  testMatch: [\"**/specs/**/*.ts\"],\n};\n",
            "packages/api/specs/handler.ts": "import { handle } from '../src/handler';\n",
            "packages/api/src/handler.ts": "export const handle = () => 1;\n",
            "tests/unit/math.test.ts": "import { add } from '../../src/lib/math';\n",
            "tests/helpers/db.ts": "export const db = 1;\n",
            "src/lib/math.ts": "export const add = (a: number, b: number) => a + b;\n",
            "src/lib/latest.ts": "export const latest = 1;\n",
            "src/app/api/settings/test/route.ts": "export async function POST() {}\n",
        ], name: "runners")
        let rows = try engine.rawQuery("SELECT path, is_test, test_kind, test_evidence FROM files WHERE path LIKE '%.ts' ORDER BY path")
        let includeLine = try lineNumber("include: [\"tests", in: vitest)
        #expect(flat(rows.rows) == [
            "packages/api/specs/handler.ts|1|unit|packages/api/jest.config.js:3",
            "packages/api/src/handler.ts|0|-|-",
            "src/app/api/settings/test/route.ts|0|-|-",
            "src/lib/latest.ts|0|-|-",
            "src/lib/math.ts|0|-|-",
            "tests/helpers/db.ts|1|support|vitest.config.ts:\(includeLine)",
            "tests/unit/math.test.ts|1|unit|vitest.config.ts:\(includeLine)",
            "vitest.config.ts|0|-|-",
        ])
        let links = try engine.rawQuery("SELECT kind, config_path, config_line, key, evidence FROM config_links ORDER BY rowid")
        #expect(flat(links.rows) == [
            "runner-usage|scripts/run-tests.sh|4|unit|the unit suite",
            "runner-usage|scripts/run-tests.sh|5|e2e [--only Name]|browser tests (repeat --only)",
            "runner-usage|scripts/run-tests.sh|6|all|CI=1 · everything, as CI runs it",
            "npm-script|package.json|4|test|vitest run",
            "npm-script|package.json|5|lint|eslint",
            "test-config|packages/api/jest.config.js|3|jest|packages/api/**/specs/**/*.ts",
            "test-config|vitest.config.ts|\(includeLine)|vitest|tests/**/*.test.ts",
        ])
    }

    @Test("Schemes and test plans parse on their own")
    func schemeParsing() throws {
        let scheme = try #require(XcodeScheme.parse(data: Data(Self.scheme.utf8), path: "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme", projectPath: "App.xcodeproj", root: nil))
        #expect(scheme.name == "App")
        #expect(scheme.buildTargets == ["App"])
        #expect(scheme.launchTarget == "App")
        #expect(scheme.storeKitConfiguration?.path == "Config/App.storekit")
        #expect(scheme.testPlans.map(\.path) == ["App.xctestplan", "Nightly.xctestplan"])
        #expect(scheme.testPlans.map(\.isDefault) == [true, false])
        let plan = try #require(XcodeTestPlan.parse(data: Data(Self.testPlan.utf8), path: "App.xctestplan"))
        #expect(plan.targets.map(\.name) == ["AppTests", "AppUITests"])
        #expect(plan.targets[1].skippedTests == ["SlowTests", "FlakyTests/testRetry()"])
    }

    // MARK: Paths and globs

    @Test("Name heuristics: router folders, word boundaries, Swift mocks and non-code files")
    func pathFallback() {
        // Next.js route segments are not test folders; real test folders still are.
        #expect(!PathClassifier.isTest("src/app/api/admin/webhooks/test/route.ts"))
        #expect(PathClassifier.isTest("src/app/__tests__/page.test.tsx"))
        #expect(PathClassifier.isTest("tests/unit/client.test.ts"))
        // Suffixes count at a word boundary.
        #expect(!PathClassifier.isTest("src/lib/latest.ts"))
        #expect(PathClassifier.isTest("Sources/App/LoginTests.swift"))
        #expect(PathClassifier.isTest("pkg/client_test.go"))
        #expect(PathClassifier.isTest("py/tests/test_service.py"))
        // Swift mocks and fixtures are decided by their target, not their name.
        #expect(!PathClassifier.isTest("App/Services/MockLibrarySeeder.swift"))
        #expect(!PathClassifier.isTest("App/Services/UITestSupport+SampleFixture.swift"))
        #expect(PathClassifier.isTest("web/src/mockServer.ts"))
        // Documents and workflows are tests only inside a test folder.
        #expect(!PathClassifier.isTest("Documentation/ProductSpec.md"))
        #expect(!PathClassifier.isTest(".github/workflows/tests.yml"))
        #expect(!PathClassifier.isTest("docs/superpowers/specs/design.md"))
        #expect(PathClassifier.isTest("Tests/Fixtures/sample.json"))
    }

    @Test("Runner globs: double stars, braces and extglobs")
    func globs() {
        #expect(GlobPattern.matches("tests/**/*.test.ts", "tests/unit/a/b.test.ts"))
        #expect(GlobPattern.matches("tests/**/*.test.ts", "tests/b.test.ts"))
        #expect(!GlobPattern.matches("tests/**/*.test.ts", "src/b.test.ts"))
        #expect(GlobPattern.matches("**/*.{test,spec}.?(c|m)[jt]s?(x)", "src/x.spec.mjs"))
        #expect(GlobPattern.matches("**/*.{test,spec}.?(c|m)[jt]s?(x)", "x.test.tsx"))
        #expect(!GlobPattern.matches("**/*.{test,spec}.?(c|m)[jt]s?(x)", "src/x.ts"))
        #expect(GlobPattern.matches("**/?(*.)+(spec|test).?([mc])[jt]s?(x)", "a/b.test.js"))
    }

    // MARK: Freshness

    @Test("Editing a project file the scanner never indexes makes the index stale; re-indexing applies it")
    func projectFileStaleness() async throws {
        let (engine, root) = try await RepoFixture.indexed(Self.synchronizedRepository, name: "stale")
        let version = engine.indexVersion()
        #expect(try engine.staleFileCount(options: RepoFixture.fastOptions.scan) == 0)
        // A no-op run changes nothing.
        try await engine.index(options: RepoFixture.fastOptions)
        #expect(engine.indexVersion() == version)

        // Watch stops compiling App/Models/Workout.swift.
        let edited = Self.synchronizedProject.replacingOccurrences(of: "                Models/Workout.swift,\n", with: "")
        #expect(edited != Self.synchronizedProject)
        try RepoFixture.write(edited, to: "App.xcodeproj/project.pbxproj", in: root)
        #expect(try engine.staleFileCount(options: RepoFixture.fastOptions.scan) == 1)
        try await engine.index(options: RepoFixture.fastOptions)
        #expect(engine.indexVersion() == version + 1)
        let watch = try engine.rawQuery("""
            SELECT COUNT(*) FROM file_targets ft JOIN files f ON f.id = ft.file_id JOIN targets t ON t.id = ft.target_id
            WHERE f.path = 'App/Models/Workout.swift' AND t.name = 'Watch'
            """)
        #expect(watch.rows.first?[0].intValue == 0)
        #expect(try engine.staleFileCount(options: RepoFixture.fastOptions.scan) == 0)
    }

    // MARK: Helpers

    /// Query rows as `a|b|c` lines, NULL as `-`.
    private func flat(_ rows: [[JSONValue]]) -> [String] {
        rows.map { (row: [JSONValue]) -> String in
            row.map { (value: JSONValue) -> String in value.stringValue ?? "-" }.joined(separator: "|")
        }
    }

    private struct MissingLine: Error {
        let needle: String
    }

    /// `line(_:in:after:)` that throws when the needle is missing.
    private func lineNumber(_ needle: String, in text: String, after anchor: String? = nil) throws -> Int {
        guard let found = line(needle, in: text, after: anchor) else { throw MissingLine(needle: needle) }
        return found
    }

    /// 1-based line of the first line containing `needle` below the first line containing `anchor`. An XML
    /// tag needle (`<EnvironmentVariable`) matches that tag only, not `<EnvironmentVariables>`.
    private func line(_ needle: String, in text: String, after anchor: String? = nil) -> Int? {
        let lines = text.components(separatedBy: "\n")
        var start = 0
        if let anchor {
            guard let found = lines.firstIndex(where: { $0.contains(anchor) }) else { return nil }
            start = found + 1
        }
        return lines[start...].firstIndex { line in
            guard needle.hasPrefix("<") else { return line.contains(needle) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == needle || trimmed.contains(needle + " ") || trimmed.contains(needle + ">")
        }.map { $0 + 1 }
    }
}
