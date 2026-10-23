import Foundation
import VesaliusCore

/// How a repository runs its tests, beyond Xcode schemes: JavaScript test-runner configs (which files are
/// tests), `package.json` scripts, and the usage lines at the top of runner scripts
/// (`#   scripts/test.sh unit    the AtlasTests unit suite …`).
public struct TestRunnerDetection: Sendable, Hashable, Codable {
    public var configs: [TestRunnerConfig]
    public var npmScripts: [NPMScript]
    public var usageLines: [RunnerUsage]

    public init(configs: [TestRunnerConfig] = [], npmScripts: [NPMScript] = [], usageLines: [RunnerUsage] = []) {
        self.configs = configs
        self.npmScripts = npmScripts
        self.usageLines = usageLines
    }
}

/// A test runner's file selection: vitest/jest/playwright/cypress `include`/`testMatch`/`testDir`/`specPattern`.
public struct TestRunnerConfig: Sendable, Hashable, Codable {
    /// `vitest`, `jest`, `playwright` or `cypress`.
    public var runner: String
    /// Repository-relative config file (`package.json` for a `jest` key).
    public var path: String
    /// Line of the setting that selects the tests; nil when the runner's defaults apply.
    public var line: Int?
    /// Repository-relative globs a test file matches.
    public var patterns: [String]
    /// Test folders the globs start in (`tests`); files there that no glob matches are test support.
    public var roots: [String]
    /// `unit` (vitest, jest) or `ui` (playwright, cypress).
    public var testKind: String

    /// `test` when a glob matches, `support` when the file only sits in a test folder, nil otherwise.
    public func classify(_ path: String) -> String? {
        makeClassifier()(path)
    }

    /// `classify(_:)` with the globs compiled once, for classifying many paths.
    public func makeClassifier() -> (String) -> String? {
        let expressions = patterns.compactMap { try? Regex(GlobPattern.regexSource($0)) }
        let roots = roots.filter { !$0.isEmpty }
        return { path in
            if expressions.contains(where: { path.wholeMatch(of: $0) != nil }) { return "test" }
            if roots.contains(where: { ProjectPaths.contains($0, path) }) { return "support" }
            return nil
        }
    }
}

public struct NPMScript: Sendable, Hashable, Codable {
    /// Repository-relative `package.json`.
    public var path: String
    public var name: String
    public var command: String
    public var line: Int?
}

/// One usage line of a runner script's header comment.
public struct RunnerUsage: Sendable, Hashable, Codable {
    /// Repository-relative script.
    public var path: String
    public var line: Int
    /// The sub-command and its argument syntax as written (`test [--only Class[/test]]`); empty for none.
    public var command: String
    public var description: String
    /// Environment assignments written before the script (`DEVICE=<udid>`), if any.
    public var environment: String?
}

public struct TestRunnerDetector: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func detect(files: [ScannedFile]) -> TestRunnerDetection {
        var detection = TestRunnerDetection()
        for file in files {
            let name = (file.path as NSString).lastPathComponent
            let directory = (file.path as NSString).deletingLastPathComponent
            let stem = name.split(separator: ".").first.map(String.init) ?? name
            let isScriptConfig = [".ts", ".mts", ".cts", ".js", ".mjs", ".cjs"].contains { name.hasSuffix($0) }
            if name == "package.json" {
                guard let text = read(file.path) else { continue }
                detection.npmScripts.append(contentsOf: npmScripts(text: text, path: file.path))
                if let jest = packageJestConfig(text: text, path: file.path, directory: directory) { detection.configs.append(jest) }
            } else if isScriptConfig, ["vitest.config", "vite.config", "jest.config", "playwright.config", "cypress.config"].contains(name.components(separatedBy: ".").prefix(2).joined(separator: ".")) {
                guard let text = read(file.path), let config = runnerConfig(stem: stem, text: text, path: file.path, directory: directory) else { continue }
                detection.configs.append(config)
            } else if name == "jest.config.json" {
                guard let text = read(file.path), let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
                detection.configs.append(jestConfig(object: object, text: text, path: file.path, directory: directory))
            } else if isRunnerScript(file) {
                guard let text = read(file.path, limit: 64_000) else { continue }
                detection.usageLines.append(contentsOf: usageLines(text: text, path: file.path))
            }
        }
        return detection
    }

    // MARK: Runner configs

    private func runnerConfig(stem: String, text: String, path: String, directory: String) -> TestRunnerConfig? {
        let tokens = ScriptTokens(text: text)
        switch stem {
        case "vitest", "vite":
            // Only a `test: { … }` block makes a vite config a vitest config.
            let block = tokens.object(forKey: "test", from: 0)
            guard stem == "vitest" || block != nil else { return nil }
            if let block, let include = tokens.strings(forKey: "include", in: block) {
                return config("vitest", path: path, line: include.line, patterns: include.values, directory: directory, kind: "unit")
            }
            return config("vitest", path: path, line: nil, patterns: ["**/*.{test,spec}.?(c|m)[jt]s?(x)"], directory: directory, kind: "unit")
        case "jest":
            let whole = 0..<tokens.tokens.count
            if let match = tokens.strings(forKey: "testMatch", in: whole, nested: true) {
                return config("jest", path: path, line: match.line, patterns: match.values, directory: directory, kind: "unit")
            }
            return config("jest", path: path, line: nil, patterns: Self.jestDefaults, directory: directory, kind: "unit")
        case "playwright":
            let whole = 0..<tokens.tokens.count
            let testDir = tokens.strings(forKey: "testDir", in: whole, nested: true)
            let folder = testDir?.values.first.map { ProjectPaths.join(directory, $0) } ?? directory
            let match = tokens.strings(forKey: "testMatch", in: whole, nested: true)
            let patterns = (match?.values ?? ["**/*.@(spec|test).?(c|m)[jt]s?(x)"]).map { ProjectPaths.join(folder, $0) }
            return TestRunnerConfig(runner: "playwright", path: path, line: testDir?.line ?? match?.line, patterns: patterns, roots: folder == directory ? [] : [folder], testKind: "ui")
        case "cypress":
            let whole = 0..<tokens.tokens.count
            if let spec = tokens.strings(forKey: "specPattern", in: whole, nested: true) {
                return config("cypress", path: path, line: spec.line, patterns: spec.values, directory: directory, kind: "ui")
            }
            return config("cypress", path: path, line: nil, patterns: ["cypress/e2e/**/*.cy.{js,jsx,ts,tsx}"], directory: directory, kind: "ui")
        default:
            return nil
        }
    }

    private static let jestDefaults = ["**/__tests__/**/*.?([mc])[jt]s?(x)", "**/?(*.)+(spec|test).?([mc])[jt]s?(x)"]

    private func packageJestConfig(text: String, path: String, directory: String) -> TestRunnerConfig? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let jest = object["jest"] as? [String: Any] else { return nil }
        return jestConfig(object: jest, text: text, path: path, directory: directory)
    }

    private func jestConfig(object: [String: Any], text: String, path: String, directory: String) -> TestRunnerConfig {
        let patterns = (object["testMatch"] as? [String]) ?? Self.jestDefaults
        let line = object["testMatch"] == nil ? nil : ProjectPaths.firstLine(containing: "\"testMatch\"", in: text)
        return config("jest", path: path, line: line, patterns: patterns, directory: directory, kind: "unit")
    }

    /// A config whose globs are relative to its folder. Static roots count as test folders only when they
    /// look like one (`tests/**/*.test.ts` → `tests`; `src/**/*.spec.ts` does not make `src` a test folder).
    private func config(_ runner: String, path: String, line: Int?, patterns: [String], directory: String, kind: String) -> TestRunnerConfig {
        let resolved = patterns.map { pattern -> String in
            let trimmed = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
            return directory.isEmpty ? trimmed : directory + "/" + trimmed
        }
        var roots: [String] = []
        for pattern in resolved {
            let staticPrefix = pattern.split(separator: "/").prefix { !$0.contains(where: { "*?[{(!".contains($0) }) }.map(String.init)
            // The last static component is a file name when the pattern has no glob at all.
            let folders = staticPrefix.count == pattern.split(separator: "/").count ? Array(staticPrefix.dropLast()) : staticPrefix
            guard let last = folders.last?.lowercased(), Self.testFolderNames.contains(last) || last.hasSuffix("tests") else { continue }
            let root = folders.joined(separator: "/")
            if !roots.contains(root) { roots.append(root) }
        }
        return TestRunnerConfig(runner: runner, path: path, line: line, patterns: resolved, roots: roots, testKind: kind)
    }

    private static let testFolderNames: Set<String> = ["tests", "test", "__tests__", "spec", "specs", "e2e", "cypress", "playwright", "integration"]

    // MARK: package.json scripts

    private func npmScripts(text: String, path: String) -> [NPMScript] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = lines.firstIndex { $0.contains("\"scripts\"") } ?? 0
        var result: [NPMScript] = []
        for (name, value) in scripts {
            guard let command = value as? String else { continue }
            let line = lines[start...].firstIndex { $0.contains("\"\(name)\"") }.map { $0 + 1 }
            result.append(NPMScript(path: path, name: name, command: command, line: line))
        }
        return result.sorted { ($0.line ?? .max, $0.name) < ($1.line ?? .max, $1.name) }
    }

    // MARK: Runner scripts

    private func isRunnerScript(_ file: ScannedFile) -> Bool {
        let ext = (file.path as NSString).pathExtension.lowercased()
        if file.language == .shell { return ["sh", "bash", "zsh"].contains(ext) }
        let folders = file.path.split(separator: "/").dropLast()
        return ext.isEmpty && file.language == .unknown && (folders.contains("scripts") || folders.contains("bin"))
    }

    /// Usage lines (`#   <script> <sub-command> …  <description>`) of a script whose header talks about tests.
    func usageLines(text: String, path: String) -> [RunnerUsage] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(120)
        var header: [(number: Int, text: Substring)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0 && trimmed.hasPrefix("#!") { continue }
            if trimmed.isEmpty && header.isEmpty { continue }
            guard trimmed.hasPrefix("#") else { break }
            header.append((index + 1, line))
        }
        let headerText = header.map(\.text).joined(separator: "\n").lowercased()
        guard headerText.contains("test") || headerText.contains("e2e") else { return [] }
        let name = (path as NSString).lastPathComponent
        let references: Set<String> = [path, "./" + path, name, "./" + name]
        var usages: [RunnerUsage] = []
        for (number, line) in header {
            let body = line.drop { $0 == " " || $0 == "\t" }.dropFirst()
            guard let match = body.wholeMatch(of: /\s+((?:[A-Z_][A-Z0-9_]*=\S+\s+)*)(\S+)(?:\s+(\S.*?))?\s{2,}(\S.*)/) else { continue }
            let script = String(match.2)
            guard references.contains(script) || script.hasSuffix("/" + name) else { continue }
            let environment = match.1.trimmingCharacters(in: .whitespaces)
            usages.append(RunnerUsage(
                path: path, line: number, command: match.3.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "",
                description: String(match.4).trimmingCharacters(in: .whitespaces), environment: environment.isEmpty ? nil : environment
            ))
        }
        return usages
    }

    private func read(_ relativePath: String, limit: Int = 2_000_000) -> String? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(relativePath)), data.count < 2_000_000 else { return nil }
        return String(decoding: data.prefix(limit), as: UTF8.self)
    }
}

// MARK: - JavaScript config scanning

/// Tokens of a JS/TS config file (comments dropped, strings kept), enough to read `key: [ "…" ]` values
/// inside `defineConfig({ … })` without evaluating the file.
private struct ScriptTokens {
    struct Token {
        enum Kind { case word, string, punctuation }
        let kind: Kind
        let text: String
        let line: Int
    }

    let tokens: [Token]

    init(text: String) {
        var tokens: [Token] = []
        let bytes = Array(text.utf8)
        var i = 0
        var line = 1
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x0A {
                line += 1
                i += 1
            } else if c == 0x20 || c == 0x09 || c == 0x0D {
                i += 1
            } else if c == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") {
                while i < bytes.count, bytes[i] != 0x0A { i += 1 }
            } else if c == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < bytes.count, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) {
                    if bytes[i] == 0x0A { line += 1 }
                    i += 1
                }
                i += 2
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") || c == UInt8(ascii: "`") {
                let quote = c
                let start = line
                var value: [UInt8] = []
                i += 1
                while i < bytes.count, bytes[i] != quote {
                    if bytes[i] == UInt8(ascii: "\\"), i + 1 < bytes.count {
                        value.append(bytes[i + 1])
                        i += 2
                        continue
                    }
                    if bytes[i] == 0x0A { line += 1 }
                    value.append(bytes[i])
                    i += 1
                }
                i += 1
                tokens.append(Token(kind: .string, text: String(decoding: value, as: UTF8.self), line: start))
            } else if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$") {
                let start = i
                while i < bytes.count, (bytes[i] >= 0x41 && bytes[i] <= 0x5A) || (bytes[i] >= 0x61 && bytes[i] <= 0x7A) || (bytes[i] >= 0x30 && bytes[i] <= 0x39) || bytes[i] == UInt8(ascii: "_") || bytes[i] == UInt8(ascii: "$") {
                    i += 1
                }
                tokens.append(Token(kind: .word, text: String(decoding: bytes[start..<i], as: UTF8.self), line: line))
            } else {
                tokens.append(Token(kind: .punctuation, text: String(UnicodeScalar(c)), line: line))
                i += 1
            }
        }
        self.tokens = tokens
    }

    private func isKey(_ index: Int, _ key: String) -> Bool {
        guard index + 1 < tokens.count else { return false }
        let token = tokens[index]
        return (token.kind == .word || token.kind == .string) && token.text == key && tokens[index + 1].kind == .punctuation && tokens[index + 1].text == ":"
    }

    /// The token range inside `key: { … }`, searching the whole file from `from`.
    func object(forKey key: String, from: Int) -> Range<Int>? {
        var index = from
        while index < tokens.count {
            if isKey(index, key), index + 2 < tokens.count, tokens[index + 2].text == "{" {
                guard let end = closing(index + 2) else { return nil }
                return (index + 3)..<end
            }
            index += 1
        }
        return nil
    }

    /// `key: "a"` or `key: ["a", "b"]` inside `range`: directly inside it (not in nested objects such as
    /// vitest's `coverage`), or at any depth when `nested` is true (the first occurrence wins).
    func strings(forKey key: String, in range: Range<Int>, nested: Bool = false) -> (values: [String], line: Int)? {
        var depth = 0
        var index = range.lowerBound
        while index < range.upperBound {
            let token = tokens[index]
            if token.kind == .punctuation, ["{", "[", "("].contains(token.text) { depth += 1 }
            if token.kind == .punctuation, ["}", "]", ")"].contains(token.text) { depth -= 1 }
            if depth == 0 || nested, isKey(index, key), index + 2 < tokens.count {
                let value = tokens[index + 2]
                if value.kind == .string { return ([value.text], token.line) }
                if value.text == "[", let end = closing(index + 2) {
                    let strings = tokens[(index + 3)..<end].filter { $0.kind == .string }.map(\.text)
                    return (strings, token.line)
                }
            }
            index += 1
        }
        return nil
    }

    private func closing(_ open: Int) -> Int? {
        let pairs = ["{": "}", "[": "]", "(": ")"]
        guard let close = pairs[tokens[open].text] else { return nil }
        var depth = 0
        for index in open..<tokens.count where tokens[index].kind == .punctuation {
            if tokens[index].text == tokens[open].text { depth += 1 }
            if tokens[index].text == close {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }
}

// MARK: - Globs

/// Test-runner globs (micromatch syntax): `**`, `*`, `?`, `[…]`, `{a,b}` and the extglobs `?(…)`, `*(…)`,
/// `+(…)`, `@(…)`, `!(…)`, matched against repository-relative paths.
public enum GlobPattern {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        guard let regex = try? Regex(regexSource(pattern)) else { return false }
        return path.wholeMatch(of: regex) != nil
    }

    static func regexSource(_ pattern: String) -> String {
        let characters = Array(pattern)
        var output = ""
        var i = 0
        var groupStack: [Character] = []   // extglob kinds of open `(` groups
        var braceDepth = 0
        while i < characters.count {
            let c = characters[i]
            let next: Character? = i + 1 < characters.count ? characters[i + 1] : nil
            switch c {
            case "*":
                if next == "*" {
                    // `**/` matches zero or more folders; a trailing `**` matches anything.
                    if i + 2 < characters.count, characters[i + 2] == "/" {
                        output += "(?:[^/]*/)*"
                        i += 3
                    } else {
                        output += ".*"
                        i += 2
                    }
                    continue
                }
                if next == "(" {
                    groupStack.append("*")
                    output += "(?:"
                    i += 2
                    continue
                }
                output += "[^/]*"
            case "?", "+", "@", "!":
                if next == "(" {
                    groupStack.append(c)
                    output += c == "!" ? "(?:(?!" : "(?:"
                    i += 2
                    continue
                }
                output += c == "?" ? "[^/]" : NSRegularExpression.escapedPattern(for: String(c))
            case ")":
                if let kind = groupStack.popLast() {
                    switch kind {
                    case "?": output += ")?"
                    case "*": output += ")*"
                    case "+": output += ")+"
                    case "!": output += ")[^/]*?)"
                    default: output += ")"
                    }
                } else {
                    output += "\\)"
                }
            case "|":
                output += groupStack.isEmpty ? "\\|" : "|"
            case "{":
                braceDepth += 1
                output += "(?:"
            case "}":
                if braceDepth > 0 {
                    braceDepth -= 1
                    output += ")"
                } else {
                    output += "\\}"
                }
            case ",":
                output += braceDepth > 0 ? "|" : ","
            case "[":
                if let close = characters[(i + 1)...].firstIndex(of: "]") {
                    var body = String(characters[(i + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                    output += "[" + body + "]"
                    i = close + 1
                    continue
                }
                output += "\\["
            default:
                output += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        return output
    }
}
