import Foundation
import Testing
@testable import RepositoryScanner
import VesaliusCore

@Suite("Ignore rules and repository scanning")
struct ScannerTests {
    private func ignored(_ path: String, _ rules: String, directory: Bool = false, base: String = "") -> Bool {
        IgnoreStack([IgnoreRuleSet(baseDirectory: base, contents: rules)]).isIgnored(path, isDirectory: directory)
    }

    @Test("Unanchored patterns match at any depth")
    func unanchored() {
        #expect(ignored("debug.log", "*.log"))
        #expect(ignored("a/b/c/debug.log", "*.log"))
        #expect(!ignored("a/b/c/debug.txt", "*.log"))
        #expect(ignored("deep/node/cache", "cache", directory: true))
    }

    @Test("Anchored patterns only match relative to the ignore file")
    func anchored() {
        #expect(ignored("build", "/build", directory: true))
        #expect(!ignored("src/build", "/build", directory: true))
        #expect(ignored("docs/api/index.md", "docs/api/*.md"))
        #expect(!ignored("other/docs/api/index.md", "docs/api/*.md"))
    }

    @Test("Negation re-includes, and the last matching rule wins")
    func negation() {
        let rules = "*.gen.ts\n!keep.gen.ts"
        #expect(ignored("web/drop.gen.ts", rules))
        #expect(!ignored("web/keep.gen.ts", rules))
        #expect(ignored("web/keep.gen.ts", "!keep.gen.ts\n*.gen.ts"))
    }

    @Test("Directory-only patterns ignore folders but not files")
    func directoryOnly() {
        #expect(ignored("out", "out/", directory: true))
        #expect(!ignored("out", "out/", directory: false))
    }

    @Test("Double-star, character classes, escapes and comments")
    func globs() {
        #expect(ignored("a/b/c/d.txt", "a/**/d.txt"))
        #expect(ignored("a/d.txt", "a/**/d.txt"))
        #expect(ignored("logs/x/y/z", "logs/**", directory: true))
        #expect(ignored("Temp", "[Tt]emp", directory: true))
        #expect(ignored("temp", "[Tt]emp", directory: true))
        #expect(!ignored("Kemp", "[Tt]emp", directory: true))
        #expect(ignored("#notes", "\\#notes"))
        #expect(!ignored("anything", "# just a comment"))
        #expect(ignored("file?.txt".replacingOccurrences(of: "?", with: "1"), "file?.txt"))
    }

    @Test("Nested ignore files apply only inside their folder")
    func nested() {
        let stack = IgnoreStack([
            IgnoreRuleSet(baseDirectory: "", contents: "*.tmp"),
            IgnoreRuleSet(baseDirectory: "web", contents: "dist/\n!important.tmp"),
        ])
        #expect(stack.isIgnored("x.tmp", isDirectory: false))
        #expect(!stack.isIgnored("web/important.tmp", isDirectory: false))
        #expect(stack.isIgnored("web/dist", isDirectory: true))
        #expect(!stack.isIgnored("dist", isDirectory: true))
    }

    @Test("Scanning respects .gitignore, defaults, binaries, symlinks and vendored projects")
    func scanFixture() throws {
        let root = try RepoFixture.make(RepoFixture.app, name: "scan")
        // A nested .gitignore and a .vesaliusignore.
        try RepoFixture.write("generated.py\n", to: "py/.gitignore", in: root)
        try RepoFixture.write("x = 1\n", to: "py/generated.py", in: root)
        try RepoFixture.write("docs-internal/\n", to: ".vesaliusignore", in: root)
        try RepoFixture.write("# internal\n", to: "docs-internal/notes.md", in: root)
        // Symlinks are never followed.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.ts"), withDestinationURL: root.appendingPathComponent("web/src/api/client.ts"))

        let result = try RepositoryScanner(root: root).scan()
        let paths = Set(result.files.map(\.path))
        #expect(paths == RepoFixture.expectedAppFiles)
        #expect(result.vendoredDirectories == ["vendor-lib/Dependencies/snapshot-master"])
        let reasons = Dictionary(grouping: result.skipped, by: \.reason)
        #expect(reasons[.symlink]?.contains { $0.path == "linked.ts" } == true)
        #expect(reasons[.binary]?.contains { $0.path == "assets/logo.png" } == true)
        #expect(reasons[.defaultExclusion]?.contains { $0.path == "node_modules" } == true)
        #expect(reasons[.ignoredByRule]?.contains { $0.path == "ignored" } == true)
        #expect(reasons[.ignoredByRule]?.contains { $0.path == "py/generated.py" } == true)
        #expect(reasons[.ignoredByRule]?.contains { $0.path == "docs-internal" } == true)
        // Languages are detected from extensions.
        #expect(result.files.first { $0.path == "web/src/ui/UserCard.tsx" }?.language == .typescript)
        #expect(result.files.first { $0.path == "py/app/models.py" }?.language == .python)
    }

    @Test("User exclusions and the vendored-project switch are honoured")
    func options() throws {
        let root = try RepoFixture.make(RepoFixture.app, name: "options")
        var options = ScanOptions()
        options.userExclusions = ["web/src/cycle/"]
        options.skipVendoredProjects = false
        let paths = Set(try RepositoryScanner(root: root, options: options).scan().files.map(\.path))
        #expect(!paths.contains("web/src/cycle/a.ts"))
        #expect(paths.contains("vendor-lib/Dependencies/snapshot-master/lib.c"))
    }

    @Test("Xcode projects, .gitmodules, test plans and StoreKit files are recorded for the project model")
    func projectFiles() throws {
        let root = try RepoFixture.make([
            ".gitignore": "Scratch.xcodeproj/\n",
            ".gitmodules": "[submodule \"Packages/Kit\"]\n\tpath = Packages/Kit\n\turl = https://example.com/kit.git\n[core]\n\tbare = false\n",
            "App.xcodeproj/project.pbxproj": "// !$*UTF8*$!\n{ objects = { }; }\n",
            "App.xcodeproj/xcshareddata/xcschemes/App.xcscheme": "<Scheme/>\n",
            "Scratch.xcodeproj/project.pbxproj": "{ objects = { }; }\n",
            "Tools/Tool.xcworkspace/contents.xcworkspacedata": "<Workspace/>\n",
            "App.xctestplan": "{ \"testTargets\": [] }\n",
            "Config/App.storekit": "{ \"products\": [] }\n",
            "App/Main.swift": "let x = 1\n",
        ], name: "bundles")
        let scan = try RepositoryScanner(root: root).scan()
        #expect(scan.projectBundles == [
            ProjectBundle(path: "App.xcodeproj", ignored: false),
            ProjectBundle(path: "Scratch.xcodeproj", ignored: true),
            ProjectBundle(path: "Tools/Tool.xcworkspace", ignored: false),
        ])
        // The folder-only walk and the lookup in scanned folders find the same bundles, and name the ignoring rule.
        let scanner = RepositoryScanner(root: root)
        #expect(try scanner.projectBundles() == scan.projectBundles)
        #expect(scanner.projectBundles(in: scan.directories) == scan.projectBundles)
        #expect(scanner.ignoreSource(of: "Scratch.xcodeproj", isDirectory: true) == ".gitignore:1")
        #expect(scanner.ignoreSource(of: "App.xcodeproj", isDirectory: true) == nil)
        #expect(scan.submodules == [GitSubmodule(name: "Packages/Kit", path: "Packages/Kit", url: "https://example.com/kit.git", line: 1)])
        // Bundle contents stay out of the index; test plans and StoreKit files are indexed as JSON.
        #expect(Set(scan.files.map(\.path)) == ["App.xctestplan", "App/Main.swift", "Config/App.storekit"])
        #expect(scan.files.first { $0.path == "App.xctestplan" }?.language == .json)
        #expect(scan.files.first { $0.path == "Config/App.storekit" }?.language == .json)
    }

    @Test("Vendored-project heuristics keep first-party packages")
    func vendorHeuristics() {
        #expect(VendorHeuristics.isVendoredProject(path: "Packages/Kit/Dependencies/MarkdownUI", entries: ["LICENSE", "Package.swift", "Sources"]))
        #expect(VendorHeuristics.isVendoredProject(path: "third/llama.cpp-master", entries: ["LICENSE", "CMakeLists.txt"]))
        #expect(VendorHeuristics.isVendoredProject(path: "Resources/python-stdlib", entries: ["os.py"]))
        #expect(!VendorHeuristics.isVendoredProject(path: "Packages/AtlasKit", entries: ["LICENSE", "Package.swift", "README.md", "Sources"]))
        #expect(!VendorHeuristics.isVendoredProject(path: "Sources/Dependencies", entries: ["AuthClient.swift"]))
    }

    @Test("Text decoding rejects binaries and tolerates legacy encodings")
    func decoding() {
        if case .binary = SourceDecoder.decode(Data([0x89, 0x50, 0x00, 0x47])) {} else { Issue.record("NUL bytes should mean binary") }
        if case .text(let text, _) = SourceDecoder.decode(Data([0x63, 0x61, 0x66, 0xE9])) { #expect(text == "café") } else { Issue.record("Latin-1 should decode") }
        #expect(SourceDecoder.generatedMarker(path: "Model.generated.swift", text: ""))
        #expect(SourceDecoder.generatedMarker(path: "x.swift", text: "// Code generated by protoc. DO NOT EDIT."))
        #expect(SourceDecoder.isMinified(text: String(repeating: "a", count: 6000)))
    }
}
