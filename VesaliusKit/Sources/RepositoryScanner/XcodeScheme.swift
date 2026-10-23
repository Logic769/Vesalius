import Foundation
import VesaliusCore

/// A shared scheme (`<project>.xcodeproj/xcshareddata/xcschemes/*.xcscheme`): what it builds and launches,
/// its StoreKit configuration, its test plans or testables, and the environment it sets. User schemes
/// (`xcuserdata`) are personal and never read.
public struct XcodeScheme: Sendable, Hashable, Codable {
    /// Repository-relative path of the `.xcscheme` file.
    public var path: String
    public var name: String
    /// The `.xcodeproj` the scheme belongs to.
    public var projectPath: String
    public var buildTargets: [String]
    /// The target the Run action launches.
    public var launchTarget: String?
    public var storeKitConfiguration: FileReference?
    public var testPlans: [TestPlanReference]
    /// Test targets listed in the Test action itself (schemes without test plans).
    public var testables: [Testable]
    public var environment: [EnvironmentVariable]

    public struct FileReference: Sendable, Hashable, Codable {
        /// Repository-relative path.
        public var path: String
        public var line: Int?
    }

    public struct TestPlanReference: Sendable, Hashable, Codable {
        public var path: String
        public var isDefault: Bool
        public var line: Int?
    }

    public struct Testable: Sendable, Hashable, Codable {
        public var target: String
        public var isSkipped: Bool
        /// `Class` or `Class/testMethod()` identifiers the scheme skips.
        public var skippedTests: [String]
        public var line: Int?
    }

    public struct EnvironmentVariable: Sendable, Hashable, Codable {
        public var key: String
        public var value: String
        public var isEnabled: Bool
        /// `launch` or `test`.
        public var action: String
        public var line: Int?
    }

    /// Reads one scheme file. `projectPath` is the `.xcodeproj` that contains it.
    public static func load(path: String, projectPath: String, root: URL) -> XcodeScheme? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path)), data.count < 5_000_000 else { return nil }
        return parse(data: data, path: path, projectPath: projectPath, root: root)
    }

    public static func parse(data: Data, path: String, projectPath: String, root: URL?) -> XcodeScheme? {
        let delegate = SchemeParserDelegate(text: String(decoding: data, as: UTF8.self))
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() || !delegate.elements.isEmpty else { return nil }

        let schemeFolder = (path as NSString).deletingLastPathComponent
        let container = (projectPath as NSString).deletingLastPathComponent
        func resolve(_ reference: String, relativeTo folder: String) -> String? {
            if reference.hasPrefix("container:") { return ProjectPaths.join(container, String(reference.dropFirst("container:".count))) }
            if reference.hasPrefix("group:") { return ProjectPaths.join(container, String(reference.dropFirst("group:".count))) }
            if reference.hasPrefix("absolute:") || reference.hasPrefix("/") {
                let absolute = reference.hasPrefix("absolute:") ? String(reference.dropFirst("absolute:".count)) : reference
                guard let rootPath = root?.standardizedFileURL.path, absolute.hasPrefix(rootPath + "/") else { return nil }
                return String(absolute.dropFirst(rootPath.count + 1))
            }
            return ProjectPaths.join(folder, reference)
        }

        var scheme = XcodeScheme(
            path: path, name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension, projectPath: projectPath,
            buildTargets: [], launchTarget: nil, storeKitConfiguration: nil, testPlans: [], testables: [], environment: []
        )
        var currentTestable: Int?
        for element in delegate.elements {
            let inside = { (name: String) in element.ancestors.contains(name) }
            switch element.name {
            case "BuildableReference":
                guard let blueprint = element.attributes["BlueprintName"] else { continue }
                if inside("BuildActionEntry"), !scheme.buildTargets.contains(blueprint) { scheme.buildTargets.append(blueprint) }
                if inside("LaunchAction"), inside("BuildableProductRunnable") || inside("MacroExpansion"), scheme.launchTarget == nil { scheme.launchTarget = blueprint }
                if inside("TestableReference"), let index = currentTestable, scheme.testables[index].target.isEmpty { scheme.testables[index].target = blueprint }
            case "StoreKitConfigurationFileReference":
                if let identifier = element.attributes["identifier"], let resolved = resolve(identifier, relativeTo: schemeFolder) {
                    scheme.storeKitConfiguration = FileReference(path: resolved, line: element.line)
                }
            case "TestPlanReference":
                if let reference = element.attributes["reference"], let resolved = resolve(reference, relativeTo: container) {
                    scheme.testPlans.append(TestPlanReference(path: resolved, isDefault: element.attributes["default"] == "YES", line: element.line))
                }
            case "TestableReference":
                scheme.testables.append(Testable(target: "", isSkipped: element.attributes["skipped"] == "YES", skippedTests: [], line: element.line))
                currentTestable = scheme.testables.count - 1
            case "Test":
                if inside("SkippedTests"), inside("TestableReference"), let index = currentTestable, let identifier = element.attributes["Identifier"] {
                    scheme.testables[index].skippedTests.append(identifier)
                }
            case "EnvironmentVariable":
                guard let key = element.attributes["key"] else { continue }
                let action = inside("TestAction") ? "test" : inside("LaunchAction") ? "launch" : nil
                guard let action else { continue }
                scheme.environment.append(EnvironmentVariable(key: key, value: element.attributes["value"] ?? "", isEnabled: element.attributes["isEnabled"] != "NO", action: action, line: element.line))
            default:
                break
            }
        }
        scheme.testables.removeAll { $0.target.isEmpty }
        return scheme
    }
}

/// An `.xctestplan` (JSON): the test targets it runs, with the tests each one skips or selects.
public struct XcodeTestPlan: Sendable, Hashable, Codable {
    public var path: String
    public var targets: [Target]

    public struct Target: Sendable, Hashable, Codable {
        public var name: String
        public var isEnabled: Bool
        /// `Class` or `Class/testMethod()` identifiers.
        public var skippedTests: [String]
        public var selectedTests: [String]
        /// Line of the target's `"name"` in the plan.
        public var line: Int?
    }

    public static func load(path: String, root: URL) -> XcodeTestPlan? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path)), data.count < 5_000_000 else { return nil }
        return parse(data: data, path: path)
    }

    public static func parse(data: Data, path: String) -> XcodeTestPlan? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        var searchFrom = lines.firstIndex { $0.contains("\"testTargets\"") } ?? 0
        var targets: [Target] = []
        for entry in object["testTargets"] as? [[String: Any]] ?? [] {
            guard let target = entry["target"] as? [String: Any], let name = target["name"] as? String else { continue }
            // Each target's `"name" : "…"` follows the previous one.
            var line: Int?
            if let found = lines[searchFrom...].firstIndex(where: { $0.contains("\"name\"") && $0.contains("\"\(name)\"") }) {
                line = found + 1
                searchFrom = found + 1
            }
            targets.append(Target(
                name: name,
                isEnabled: entry["enabled"] as? Bool ?? true,
                skippedTests: testIdentifiers(entry["skippedTests"]),
                selectedTests: testIdentifiers(entry["selectedTests"]),
                line: line
            ))
        }
        return XcodeTestPlan(path: path, targets: targets)
    }

    /// Test identifiers from either the classic string list or the newer `{"suites": [{"name": …}]}` form.
    static func testIdentifiers(_ value: Any?) -> [String] {
        if let list = value as? [String] { return list }
        guard let object = value as? [String: Any] else { return [] }
        var identifiers: [String] = []
        for suite in object["suites"] as? [[String: Any]] ?? [] {
            guard let name = suite["name"] as? String else { continue }
            let functions = (suite["testFunctions"] as? [String]) ?? []
            identifiers.append(contentsOf: functions.isEmpty ? [name] : functions.map { "\(name)/\($0)" })
        }
        return identifiers
    }
}

/// Collects every element with its attributes, ancestors and the line its start tag begins on.
private final class SchemeParserDelegate: NSObject, XMLParserDelegate {
    struct Element {
        let name: String
        let attributes: [String: String]
        let ancestors: [String]
        let line: Int?
    }

    private let lines: [Substring]
    private(set) var elements: [Element] = []
    private var stack: [String] = []

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        elements.append(Element(name: elementName, attributes: attributes, ancestors: stack, line: startLine(of: elementName, near: parser.lineNumber)))
        stack.append(elementName)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    /// The parser reports where a start tag ends; attributes on their own lines push that past the `<Name`.
    private func startLine(of name: String, near line: Int) -> Int? {
        guard line >= 1 else { return nil }
        let tag = "<\(name)"
        var candidate = min(line, lines.count)
        while candidate >= 1 && line - candidate < 40 {
            let text = lines[candidate - 1].trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(tag) || text.contains(tag + " ") || text.contains(tag + ">") || text.contains(tag + "/") { return candidate }
            candidate -= 1
        }
        return line
    }
}
