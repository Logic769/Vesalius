import Foundation
import VesaliusCore

/// A `Package.swift` read statically: comments are stripped, strings kept, and the `Package(…)` call is
/// parsed as balanced, labeled arguments. Running the manifest (`swift package dump-package`) would be
/// exact but writes caches and costs seconds; this reads the declarative manifests real repositories use,
/// follows top-level `let` bindings, and flags anything it cannot follow as partial.
public struct SwiftPackageManifest: Sendable, Hashable, Codable {
    /// Repository-relative path of `Package.swift`.
    public var path: String
    /// Repository-relative package folder.
    public var directory: String
    public var name: String?
    public var products: [Product]
    public var targets: [Target]
    public var dependencies: [PackageDependency]
    /// True when the manifest computes something this reader cannot follow (functions, loops, conditionals).
    public var isPartial: Bool

    public struct Product: Sendable, Hashable, Codable {
        public var name: String
        /// `library`, `executable` or `plugin`.
        public var kind: String
        public var targets: [String]
        public var line: Int
    }

    public struct Target: Sendable, Hashable, Codable {
        public var name: String
        /// The declaring function: `target`, `executableTarget`, `testTarget`, `macro`, `plugin`, `systemLibrary`, `binaryTarget`.
        public var kind: String
        /// Repository-relative source folder (the explicit `path:`, else the SwiftPM default).
        public var path: String
        public var hasExplicitPath: Bool
        public var dependencies: [Dependency]
        /// Repository-relative paths the target's `exclude:` removes.
        public var exclude: [String]
        /// Repository-relative paths of an explicit `sources:` list; nil means every file under `path`.
        public var sources: [String]?
        public var line: Int

        public var isTest: Bool { kind == "testTarget" }
    }

    public struct Dependency: Sendable, Hashable, Codable {
        /// `target` (`.target(name:)`), `product` (`.product(name:package:)`) or `byName` (a plain string).
        public var kind: String
        public var name: String
        public var package: String?
        public var line: Int
    }

    public struct PackageDependency: Sendable, Hashable, Codable {
        /// `url`, `path` or `registry`.
        public var kind: String
        /// The URL, the registry id, or the repository-relative folder of a `path:` dependency.
        public var location: String
        /// SwiftPM's identity: the last URL or path component without `.git`.
        public var identity: String
        public var line: Int
    }

    /// Reads the manifest at `path` (repository-relative). `directories` (the scanned folders) lets default
    /// target folders follow SwiftPM's `Sources`/`Source`/`src`/`srcs` search; pass nil to assume `Sources`.
    public static func parse(text: String, path: String, directories: Set<String>? = nil) -> SwiftPackageManifest {
        let directory = (path as NSString).deletingLastPathComponent
        var parser = ManifestParser(tokens: ManifestLexer.tokenize(text))
        let (package, bindings, partialStatements) = parser.parseTopLevel()
        var manifest = SwiftPackageManifest(path: path, directory: directory, name: nil, products: [], targets: [], dependencies: [], isPartial: partialStatements)
        guard case .call(_, let arguments, _)? = package else {
            manifest.isPartial = true
            return manifest
        }
        var resolver = ManifestResolver(bindings: bindings)
        for (label, value) in arguments {
            switch label {
            case "name":
                manifest.name = resolver.string(value)
            case "products":
                for element in resolver.elements(value) {
                    guard case .call(let callee, let args, let line) = element, let name = resolver.string(args.first { $0.label == "name" }?.value) else {
                        resolver.partial = true
                        continue
                    }
                    let kind = ManifestResolver.functionName(callee)
                    manifest.products.append(Product(name: name, kind: kind, targets: resolver.strings(args.first { $0.label == "targets" }?.value), line: line))
                }
            case "dependencies":
                for element in resolver.elements(value) {
                    guard case .call(_, let args, let line) = element else {
                        resolver.partial = true
                        continue
                    }
                    if let url = resolver.string(args.first { $0.label == "url" }?.value) {
                        manifest.dependencies.append(PackageDependency(kind: "url", location: url, identity: ProjectPaths.packageIdentity(url), line: line))
                    } else if let local = resolver.string(args.first { $0.label == "path" }?.value) {
                        let location = ProjectPaths.join(directory, local)
                        manifest.dependencies.append(PackageDependency(kind: "path", location: location, identity: (location as NSString).lastPathComponent, line: line))
                    } else if let id = resolver.string(args.first { $0.label == "id" }?.value) {
                        manifest.dependencies.append(PackageDependency(kind: "registry", location: id, identity: id, line: line))
                    }
                }
            case "targets":
                for element in resolver.elements(value) {
                    guard case .call(let callee, let args, let line) = element, let name = resolver.string(args.first { $0.label == "name" }?.value) else {
                        resolver.partial = true
                        continue
                    }
                    let kind = ManifestResolver.functionName(callee)
                    let explicitPath = resolver.string(args.first { $0.label == "path" }?.value)
                    let root = explicitPath.map { ProjectPaths.join(directory, $0) } ?? defaultPath(kind: kind, name: name, directory: directory, directories: directories)
                    var dependencies: [Dependency] = []
                    for dependency in resolver.elements(args.first { $0.label == "dependencies" }?.value) {
                        switch dependency {
                        case .string(let name, let line):
                            dependencies.append(Dependency(kind: "byName", name: name, package: nil, line: line))
                        case .call(let callee, let args, let line):
                            guard let name = resolver.string(args.first { $0.label == "name" || $0.label == nil }?.value) else { continue }
                            let function = ManifestResolver.functionName(callee)
                            let dependencyKind = function == "product" ? "product" : function == "target" ? "target" : "byName"
                            dependencies.append(Dependency(kind: dependencyKind, name: name, package: resolver.string(args.first { $0.label == "package" }?.value), line: line))
                        default:
                            resolver.partial = true
                        }
                    }
                    let sourcesArgument = args.first { $0.label == "sources" }?.value
                    manifest.targets.append(Target(
                        name: name,
                        kind: kind,
                        path: root,
                        hasExplicitPath: explicitPath != nil,
                        dependencies: dependencies,
                        exclude: resolver.strings(args.first { $0.label == "exclude" }?.value).map { ProjectPaths.join(root, $0) },
                        sources: sourcesArgument.map { resolver.strings($0).map { ProjectPaths.join(root, $0) } },
                        line: line
                    ))
                }
            default:
                break
            }
        }
        manifest.isPartial = manifest.isPartial || resolver.partial
        return manifest
    }

    /// SwiftPM's default folder for a target without `path:`.
    static func defaultPath(kind: String, name: String, directory: String, directories: Set<String>?) -> String {
        let roots: [String]
        switch kind {
        case "testTarget": roots = ["Tests", "Sources", "Source", "src", "srcs"]
        case "plugin": roots = ["Plugins"]
        default: roots = ["Sources", "Source", "src", "srcs"]
        }
        if let directories {
            for root in roots {
                let candidate = ProjectPaths.join(directory, "\(root)/\(name)")
                if directories.contains(candidate) { return candidate }
            }
        }
        return ProjectPaths.join(directory, "\(roots[0])/\(name)")
    }
}

// MARK: - Lexer

private struct ManifestToken {
    enum Kind { case identifier, string, number, punctuation }
    let kind: Kind
    let text: String
    let line: Int
}

private enum ManifestLexer {
    /// Swift tokens with comments removed. Strings keep their contents (escapes resolved loosely; raw and
    /// multi-line strings supported); interpolations are kept as text.
    static func tokenize(_ text: String) -> [ManifestToken] {
        let bytes = Array(text.utf8)
        var tokens: [ManifestToken] = []
        var i = 0
        var line = 1
        func at(_ offset: Int) -> UInt8? { i + offset < bytes.count ? bytes[i + offset] : nil }
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x0A {
                line += 1
                i += 1
            } else if c == 0x20 || c == 0x09 || c == 0x0D {
                i += 1
            } else if c == UInt8(ascii: "/"), at(1) == UInt8(ascii: "/") {
                while i < bytes.count, bytes[i] != 0x0A { i += 1 }
            } else if c == UInt8(ascii: "/"), at(1) == UInt8(ascii: "*") {
                var depth = 0
                repeat {
                    if bytes[i] == UInt8(ascii: "/"), at(1) == UInt8(ascii: "*") {
                        depth += 1
                        i += 2
                    } else if bytes[i] == UInt8(ascii: "*"), at(1) == UInt8(ascii: "/") {
                        depth -= 1
                        i += 2
                    } else {
                        if bytes[i] == 0x0A { line += 1 }
                        i += 1
                    }
                } while depth > 0 && i < bytes.count
            } else if c == UInt8(ascii: "\"") || (c == UInt8(ascii: "#") && rawStringStart(bytes, i)) {
                var hashes = 0
                while i < bytes.count, bytes[i] == UInt8(ascii: "#") {
                    hashes += 1
                    i += 1
                }
                let startLine = line
                let multiline = at(0) == UInt8(ascii: "\"") && at(1) == UInt8(ascii: "\"") && at(2) == UInt8(ascii: "\"")
                i += multiline ? 3 : 1
                var value: [UInt8] = []
                while i < bytes.count {
                    if bytes[i] == UInt8(ascii: "\\"), hashes == 0, i + 1 < bytes.count {
                        value.append(bytes[i + 1])
                        if bytes[i + 1] == 0x0A { line += 1 }
                        i += 2
                        continue
                    }
                    let closes = multiline
                        ? bytes[i] == UInt8(ascii: "\"") && at(1) == UInt8(ascii: "\"") && at(2) == UInt8(ascii: "\"")
                        : bytes[i] == UInt8(ascii: "\"")
                    if closes {
                        let quoteLength = multiline ? 3 : 1
                        var closingHashes = 0
                        while closingHashes < hashes, i + quoteLength + closingHashes < bytes.count, bytes[i + quoteLength + closingHashes] == UInt8(ascii: "#") {
                            closingHashes += 1
                        }
                        if closingHashes == hashes {
                            i += quoteLength + hashes
                            break
                        }
                    }
                    if bytes[i] == 0x0A {
                        line += 1
                        if !multiline { break }
                    }
                    value.append(bytes[i])
                    i += 1
                }
                tokens.append(ManifestToken(kind: .string, text: String(decoding: value, as: UTF8.self), line: startLine))
            } else if isIdentifierStart(c) {
                let start = i
                while i < bytes.count, isIdentifierStart(bytes[i]) || (bytes[i] >= 0x30 && bytes[i] <= 0x39) { i += 1 }
                tokens.append(ManifestToken(kind: .identifier, text: String(decoding: bytes[start..<i], as: UTF8.self), line: line))
            } else if c >= 0x30 && c <= 0x39 {
                let start = i
                while i < bytes.count, (bytes[i] >= 0x30 && bytes[i] <= 0x39) || bytes[i] == UInt8(ascii: "_") || isIdentifierStart(bytes[i]) { i += 1 }
                tokens.append(ManifestToken(kind: .number, text: String(decoding: bytes[start..<i], as: UTF8.self), line: line))
            } else {
                tokens.append(ManifestToken(kind: .punctuation, text: String(UnicodeScalar(c)), line: line))
                i += 1
            }
        }
        return tokens
    }

    private static func rawStringStart(_ bytes: [UInt8], _ index: Int) -> Bool {
        var i = index
        while i < bytes.count, bytes[i] == UInt8(ascii: "#") { i += 1 }
        return i < bytes.count && bytes[i] == UInt8(ascii: "\"")
    }

    private static func isIdentifierStart(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == UInt8(ascii: "_") || c == UInt8(ascii: "$") || c >= 0x80
    }
}

// MARK: - Parser

/// The manifest expressions this reader understands.
private indirect enum ManifestValue {
    case string(String, line: Int)
    case array([ManifestValue], line: Int)
    /// A call: `Package(…)`, `.target(…)`, `Target.target(…)`; the callee keeps its leading dot.
    case call(String, [(label: String?, value: ManifestValue)], line: Int)
    case identifier(String, line: Int)
    /// Array concatenation (`base + [ … ]`).
    case concat(ManifestValue, ManifestValue)
    case unknown(line: Int)
}

private struct ManifestParser {
    let tokens: [ManifestToken]
    var position = 0

    init(tokens: [ManifestToken]) {
        self.tokens = tokens
    }

    private func peek(_ offset: Int = 0) -> ManifestToken? {
        position + offset < tokens.count ? tokens[position + offset] : nil
    }

    private func isPunctuation(_ text: String, _ offset: Int = 0) -> Bool {
        guard let token = peek(offset) else { return false }
        return token.kind == .punctuation && token.text == text
    }

    /// The `Package(…)` call, the top-level `let`/`var` bindings, and whether the file mutates the package
    /// afterwards (`package.targets += …`) or otherwise computes it.
    mutating func parseTopLevel() -> (ManifestValue?, [String: ManifestValue], Bool) {
        var package: ManifestValue?
        var bindings: [String: ManifestValue] = [:]
        var partial = false
        var packageVariable: String?
        while let token = peek() {
            if token.kind == .identifier, token.text == "let" || token.text == "var", let name = peek(1), name.kind == .identifier {
                position += 2
                // Skip a type annotation up to `=`.
                var depth = 0
                while let next = peek(), !(depth == 0 && next.kind == .punctuation && next.text == "=") {
                    if next.kind == .punctuation, ["(", "[", "<"].contains(next.text) { depth += 1 }
                    if next.kind == .punctuation, [")", "]", ">"].contains(next.text) { depth -= 1 }
                    if next.kind == .identifier, ["let", "var", "func"].contains(next.text), depth == 0 { break }
                    position += 1
                }
                guard isPunctuation("=") else { continue }
                position += 1
                let value = parseExpression()
                if case .call(let callee, _, _) = value, callee == "Package" {
                    package = value
                    packageVariable = name.text
                } else {
                    bindings[name.text] = value
                }
                continue
            }
            if token.kind == .identifier, token.text == "Package", isPunctuation("(", 1), package == nil {
                package = parseExpression()
                continue
            }
            if token.kind == .identifier, token.text == packageVariable, isPunctuation(".", 1) {
                partial = true
            }
            if token.kind == .identifier, ["for", "if", "func", "switch", "while", "guard"].contains(token.text) {
                partial = true
            }
            position += 1
        }
        return (package, bindings, partial)
    }

    /// An expression up to the next `,`, `)`, `]` or `}` of the enclosing list.
    mutating func parseExpression() -> ManifestValue {
        let line = peek()?.line ?? 0
        var value = parsePostfix()
        while isPunctuation("+") {
            position += 1
            value = .concat(value, parsePostfix())
        }
        // Anything else (ternaries, other operators): skip to the end of the expression, which is the end of
        // the enclosing list's element or, at the top level, the end of the line.
        var skipped = false
        var depth = 0
        var previousLine = position > 0 ? tokens[position - 1].line : line
        while let token = peek() {
            if depth == 0, token.line > previousLine { break }
            if token.kind == .punctuation {
                if depth == 0, [",", ")", "]", "}"].contains(token.text) { break }
                if ["(", "[", "{"].contains(token.text) { depth += 1 }
                if [")", "]", "}"].contains(token.text) { depth -= 1 }
            }
            if depth == 0, token.kind == .identifier, ["let", "var", "func"].contains(token.text) { break }
            skipped = true
            previousLine = token.line
            position += 1
        }
        return skipped ? .unknown(line: line) : value
    }

    private mutating func parsePostfix() -> ManifestValue {
        var value = parsePrimary()
        while true {
            if isPunctuation("."), let member = peek(1), member.kind == .identifier {
                position += 2
                let base: String
                switch value {
                case .identifier(let name, _): base = name
                case .call(let callee, _, _): base = callee
                default: base = ""
                }
                let callee = base + "." + member.text
                if isPunctuation("(") {
                    value = .call(callee, parseArguments(), line: member.line)
                } else {
                    value = .identifier(callee, line: member.line)
                }
            } else if isPunctuation("("), case .identifier(let name, let line) = value {
                value = .call(name, parseArguments(), line: line)
            } else if isPunctuation("{") {
                skipBalanced()
            } else {
                return value
            }
        }
    }

    private mutating func parsePrimary() -> ManifestValue {
        guard let token = peek() else { return .unknown(line: 0) }
        switch token.kind {
        case .string:
            position += 1
            // Adjacent `"a" + "b"` is handled by parseExpression; a lone string is a value.
            return .string(token.text, line: token.line)
        case .identifier:
            position += 1
            if isPunctuation("(") {
                return .call(token.text, parseArguments(), line: token.line)
            }
            return .identifier(token.text, line: token.line)
        case .number:
            position += 1
            return .unknown(line: token.line)
        case .punctuation:
            switch token.text {
            case "[":
                position += 1
                var elements: [ManifestValue] = []
                var isDictionary = false
                while let next = peek(), !(next.kind == .punctuation && next.text == "]") {
                    let before = position
                    elements.append(parseExpression())
                    if isPunctuation(":") {
                        isDictionary = true
                        position += 1
                        _ = parseExpression()
                    }
                    if isPunctuation(",") { position += 1 }
                    if position == before { position += 1 }
                }
                if isPunctuation("]") { position += 1 }
                return isDictionary ? .unknown(line: token.line) : .array(elements, line: token.line)
            case ".":
                if let member = peek(1), member.kind == .identifier {
                    position += 2
                    if isPunctuation("(") {
                        return .call("." + member.text, parseArguments(), line: token.line)
                    }
                    return .identifier("." + member.text, line: token.line)
                }
                position += 1
                return .unknown(line: token.line)
            case "(":
                position += 1
                let value = parseExpression()
                while let next = peek(), !(next.kind == .punctuation && next.text == ")") { position += 1 }
                if isPunctuation(")") { position += 1 }
                return value
            default:
                position += 1
                return .unknown(line: token.line)
            }
        }
    }

    /// `( label: value, value, … )`, consuming the parentheses.
    private mutating func parseArguments() -> [(label: String?, value: ManifestValue)] {
        guard isPunctuation("(") else { return [] }
        position += 1
        var arguments: [(label: String?, value: ManifestValue)] = []
        while let token = peek(), !(token.kind == .punctuation && token.text == ")") {
            let before = position
            var label: String?
            if token.kind == .identifier, isPunctuation(":", 1) {
                label = token.text
                position += 2
            }
            arguments.append((label, parseExpression()))
            if isPunctuation(",") { position += 1 }
            if position == before { position += 1 }
        }
        if isPunctuation(")") { position += 1 }
        if isPunctuation("{") { skipBalanced() }
        return arguments
    }

    private mutating func skipBalanced() {
        guard let open = peek(), open.kind == .punctuation else { return }
        let pairs = ["{": "}", "(": ")", "[": "]"]
        guard let close = pairs[open.text] else { return }
        var depth = 0
        while let token = peek() {
            position += 1
            if token.kind == .punctuation, token.text == open.text { depth += 1 }
            if token.kind == .punctuation, token.text == close {
                depth -= 1
                if depth == 0 { return }
            }
        }
    }
}

/// Turns parsed values into strings and lists, following top-level bindings.
private struct ManifestResolver {
    let bindings: [String: ManifestValue]
    var partial = false

    init(bindings: [String: ManifestValue]) {
        self.bindings = bindings
    }

    static func functionName(_ callee: String) -> String {
        String(callee.split(separator: ".").last ?? Substring(callee))
    }

    mutating func resolve(_ value: ManifestValue?, depth: Int = 0) -> ManifestValue? {
        guard let value else { return nil }
        if case .identifier(let name, _) = value, depth < 8 {
            guard let bound = bindings[name] else {
                partial = true
                return nil
            }
            return resolve(bound, depth: depth + 1)
        }
        return value
    }

    mutating func string(_ value: ManifestValue?) -> String? {
        guard case .string(let text, _)? = resolve(value) else { return nil }
        return text
    }

    mutating func strings(_ value: ManifestValue?) -> [String] {
        elements(value).compactMap { element in
            if case .string(let text, _) = element { return text }
            return nil
        }
    }

    mutating func elements(_ value: ManifestValue?, depth: Int = 0) -> [ManifestValue] {
        guard depth < 8, let resolved = resolve(value) else { return [] }
        switch resolved {
        case .array(let elements, _):
            return elements
        case .concat(let lhs, let rhs):
            return elements(lhs, depth: depth + 1) + elements(rhs, depth: depth + 1)
        case .unknown, .call:
            partial = true
            return []
        default:
            return []
        }
    }
}
