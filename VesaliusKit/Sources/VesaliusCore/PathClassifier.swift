import Foundation

/// Path-based facts about files: tests, entry points, layers.
public enum PathClassifier {
    /// Folder names that hold tests.
    private static let testDirectoryNames: Set<String> = ["tests", "test", "__tests__", "spec", "specs", "uitests", "testing", "e2e", "cypress", "playwright"]
    /// The test folders that also make a non-code file (fixture, snapshot, config) a test file. `spec`, `specs`
    /// and `testing` folders hold design documents as often as tests.
    private static let testRootNames: Set<String> = ["tests", "test", "__tests__", "uitests", "e2e", "cypress", "playwright"]

    /// Whether a path looks like a test by its name alone. The index decides by build target first (an Xcode
    /// test bundle, a SwiftPM test target, a test runner's include globs); this is the fallback for files no
    /// target or runner claims.
    public static func isTest(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let language = Language.detect(fileName: (path as NSString).lastPathComponent)
        var directories = Array(lower.split(separator: "/").dropLast())
        // In TS/JS, folders under a Next.js-style `app/` or `pages/` router are URL segments
        // (`app/api/webhooks/test/route.ts` serves POST /api/webhooks/test), never test folders.
        if language == .typescript || language == .javascript,
           let router = directories.firstIndex(where: { $0 == "app" || $0 == "pages" }) {
            directories = Array(directories[..<router]) + directories[router...].filter { $0 == "__tests__" }
        }
        // Documents, workflows and data are tests only inside a test folder (not `ProductSpec.md`, `tests.yml`).
        guard language.isCode else {
            return directories.contains { testRootNames.contains(String($0)) || $0.hasSuffix("tests") }
        }
        if directories.contains(where: { testDirectoryNames.contains(String($0)) || $0.hasSuffix("tests") }) {
            return true
        }
        // Name suffixes count at a word boundary only: `LoginTests`, `user_test`, `checkout-spec`, not `latest`.
        let originalStem = (((path as NSString).lastPathComponent) as NSString).deletingPathExtension
        let stem = originalStem.lowercased()
        if ["test", "tests", "spec", "specs"].contains(stem) { return true }
        for suffix in ["Test", "Tests", "Spec", "Specs"] where originalStem.hasSuffix(suffix) && originalStem.count > suffix.count {
            return true
        }
        for suffix in ["_test", "_tests", "-test", "-tests", "_spec", "-spec"] where stem.hasSuffix(suffix) { return true }
        if name.hasPrefix("test_") || name == "conftest.py" { return true }
        if name.contains(".test.") || name.contains(".spec.") || name.contains(".e2e.") || name.contains(".cy.") { return true }
        // Swift mocks, stubs and fixtures are usually compiled into the app (DEBUG harnesses, previews), so
        // only their build target can make them tests.
        if language != .swift, stem.hasPrefix("mock") || stem.hasSuffix("mock") || stem.hasSuffix("mocks") || stem.hasSuffix("stub") || stem.hasSuffix("fixture") || stem.hasSuffix("fixtures") {
            return true
        }
        return false
    }

    /// Files that are reached by tools/runtimes rather than imports, so having no dependents is expected.
    public static func isConventionalEntryPoint(_ path: String, language: Language) -> Bool {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        let stem = (lower as NSString).deletingPathExtension
        let directories = path.lowercased().split(separator: "/").dropLast()

        if !language.isCode { return true }
        switch language {
        case .swift:
            if lower == "main.swift" || lower == "package.swift" || stem.hasSuffix("app") || stem == "appdelegate" || stem == "scenedelegate" || stem.hasSuffix("extension") || stem == "project" || stem.hasSuffix("intent") || stem.hasSuffix("widget") || stem.hasSuffix("bundle") {
                return true
            }
            if directories.contains("plugins") || directories.contains("previews") || stem.hasSuffix("preview") || stem.hasSuffix("previews") { return true }
        case .typescript, .javascript:
            if ["index", "main", "app", "server", "cli", "_app", "_document", "layout", "page", "route", "middleware", "loading", "error", "not-found", "template", "default", "worker", "service-worker", "sw", "instrumentation"].contains(stem) {
                return true
            }
            if lower.contains(".config.") || lower.hasSuffix("rc.js") || lower.hasSuffix(".d.ts") || stem == "setupTests".lowercased() || lower.contains(".stories.") { return true }
            if directories.contains("pages") || directories.contains("app") && ["page", "layout", "route"].contains(stem) || directories.contains("api") || directories.contains("routes") || directories.contains("scripts") || directories.contains("bin") || directories.contains("migrations") {
                return true
            }
        case .python:
            if ["__main__", "__init__", "manage", "setup", "wsgi", "asgi", "app", "main", "cli", "conftest", "settings", "urls", "admin", "apps", "tasks", "celery"].contains(stem) {
                return true
            }
            if directories.contains("scripts") || directories.contains("bin") || directories.contains("migrations") || directories.contains("management") { return true }
        case .shell, .sql:
            return true
        default:
            if ["main", "index", "app", "lib", "mod", "build"].contains(stem) { return true }
        }
        return false
    }

    /// Architectural layer suggested by path components and file names, if any.
    public static func layer(of path: String) -> String? {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        let stem = ((parts.last ?? "") as NSString).deletingPathExtension
        let table: [(String, [String])] = [
            ("Presentation", ["views", "view", "ui", "screens", "screen", "pages", "components", "presentation", "scenes", "widgets", "viewcontrollers", "controllers"]),
            ("ViewModels", ["viewmodels", "viewmodel", "presenters", "presenter"]),
            ("Domain", ["domain", "usecases", "usecase", "entities", "interactors", "core"]),
            ("Data", ["data", "repositories", "repository", "persistence", "storage", "database", "db", "dao", "stores"]),
            ("Services", ["services", "service", "api", "network", "networking", "clients", "client", "providers"]),
            ("Models", ["models", "model", "schemas", "types", "dto", "dtos"]),
            ("Utilities", ["utils", "util", "utilities", "helpers", "helper", "common", "shared", "extensions", "misc", "lib", "support"]),
        ]
        for (layer, names) in table where parts.dropLast().contains(where: { names.contains($0) }) {
            return layer
        }
        if stem.hasSuffix("viewmodel") || stem.hasSuffix("presenter") { return "ViewModels" }
        if stem.hasSuffix("view") || stem.hasSuffix("screen") || stem.hasSuffix("viewcontroller") || stem.hasSuffix("page") || stem.hasSuffix("component") { return "Presentation" }
        if stem.hasSuffix("repository") || stem.hasSuffix("store") || stem.hasSuffix("dao") { return "Data" }
        if stem.hasSuffix("service") || stem.hasSuffix("client") || stem.hasSuffix("api") { return "Services" }
        if stem.hasSuffix("usecase") || stem.hasSuffix("interactor") { return "Domain" }
        return nil
    }
}

/// Counts total, code, comment and blank lines with a language-aware but lightweight scan.
public enum LineCounter {
    public struct Counts: Sendable, Hashable {
        public var total = 0
        public var code = 0
        public var comment = 0
        public var blank = 0

        public init() {}
    }

    public static func count(_ text: String, language: Language) -> Counts {
        var counts = Counts()
        let prefixes = language.lineCommentPrefixes
        let blockComments = language.hasBlockComments
        var inBlock = false
        var inDocstring = false
        text.enumerateLines { rawLine, _ in
            counts.total += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                counts.blank += 1
                return
            }
            if inBlock {
                counts.comment += 1
                if line.contains("*/") { inBlock = false }
                return
            }
            if inDocstring {
                counts.comment += 1
                if line.contains("\"\"\"") || line.contains("'''") { inDocstring = false }
                return
            }
            if blockComments && line.hasPrefix("/*") {
                counts.comment += 1
                if !line.contains("*/") { inBlock = true }
                return
            }
            if language == .python && (line.hasPrefix("\"\"\"") || line.hasPrefix("'''")) {
                counts.comment += 1
                let marker = line.hasPrefix("\"\"\"") ? "\"\"\"" : "'''"
                if line.count < 6 || !line.dropFirst(3).contains(marker) { inDocstring = true }
                return
            }
            if prefixes.contains(where: { line.hasPrefix($0) }) {
                counts.comment += 1
                return
            }
            counts.code += 1
        }
        if text.hasSuffix("\n") == false && !text.isEmpty {
            // enumerateLines already counted the final unterminated line.
        }
        return counts
    }
}
