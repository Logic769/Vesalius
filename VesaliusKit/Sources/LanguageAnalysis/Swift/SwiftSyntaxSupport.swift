import Foundation
import SwiftSyntax
import VesaliusCore

/// Stateless helpers shared by the Swift analyzer's visitors.
enum SwiftSyntaxSupport {
    // MARK: - Vocabularies

    /// Standard-library free functions (and SwiftUI's `withAnimation`). An unqualified call to one is never a
    /// repository reference, so it is not emitted; `type` is `type(of:)`.
    static let freeFunctionNames: Set<String> = [
        "print", "debugPrint", "zip", "abs", "stride", "min", "max", "fatalError", "precondition",
        "preconditionFailure", "assert", "assertionFailure", "withAnimation", "type",
    ]

    /// Standard-library types, and keywords that can surface as identifiers. Not emitted when unqualified.
    static let stdlibTypeNames: Set<String> = [
        "String", "Int", "Int64", "Double", "Float", "CGFloat", "Bool", "Array", "Dictionary", "Set", "Optional",
        "Character", "Void", "Any", "AnyObject", "Never", "Error", "Task",
        "true", "false", "nil", "self", "super", "Self", "init", "some", "any",
    ]

    /// Ubiquitous standard-library members. They are always emitted, because a repository type may declare
    /// one (`log.append(…)` on a `JournalWriter`); the linker only refuses to bind them by name alone
    /// (`FallbackStoplist` must contain every one of them).
    static let memberNoise: Set<String> = [
        "map", "compactMap", "flatMap", "filter", "reduce", "forEach", "sorted", "sort", "append", "insert", "remove",
        "removeAll", "removeFirst", "removeLast", "contains", "first", "last", "count", "isEmpty", "joined", "split",
        "min", "max", "description", "type",
    ]

    /// Names never recorded when unqualified (`print(…)`, `String`), so the reference table cannot show every
    /// use of them. Member uses (`x.min()`, `Foo.type`) are recorded.
    static let untrackedWhenUnqualified: Set<String> = freeFunctionNames.union(stdlibTypeNames)

    /// Freestanding macros provided by the language, Foundation or the testing frameworks.
    static let wellKnownMacros: Set<String> = [
        "Preview", "expect", "require", "warning", "error", "if", "available", "selector", "keyPath", "file", "line",
        "function", "column", "fileID", "filePath", "dsohandle", "colorLiteral", "imageLiteral", "fileLiteral",
        "externalMacro", "isolation", "Playground", "Predicate", "Expression", "unavailable", "sourceLocation",
    ]

    /// Attributes built into the compiler or the ObjC bridge. Everything else (property wrappers, attached
    /// macros, result builders) is a reference to a type that may live in the repository.
    static let builtInAttributes: Set<String> = [
        "available", "objc", "nonobjc", "objcMembers", "main", "MainActor", "discardableResult", "escaping",
        "autoclosure", "Sendable", "inlinable", "usableFromInline", "inline", "frozen", "testable", "unknown",
        "dynamicMemberLookup", "dynamicCallable", "resultBuilder", "propertyWrapper", "globalActor", "IBAction",
        "IBOutlet", "IBInspectable", "IBDesignable", "IBSegueAction", "NSManaged", "NSCopying", "NSApplicationMain",
        "UIApplicationMain", "GKInspectable", "preconcurrency", "retroactive", "unchecked", "convention", "noescape",
        "warn_unqualified_access", "requires_stored_property_inits", "backDeployed", "freestanding", "attached",
        "differentiable", "derivative", "transpose", "noDerivative", "isolated", "concurrent", "execution", "safe",
        "unsafe", "lifetime", "abi", "_exported", "_implementationOnly", "_spi", "_silgen_name", "_cdecl",
        "_transparent", "_disfavoredOverload", "_specialize", "_alwaysEmitIntoClient", "_effects", "_optimize",
        "_semantics", "_originallyDefinedIn", "_dynamicReplacement", "_spi_available", "_objcRuntimeName",
        "_nonoverride", "_marker", "_unsafeInheritExecutor", "_implements", "_documentation", "_nonSendable",
        "_predatesConcurrency", "_projectedValueProperty", "_show_in_interface", "_weakLinked", "_private",
        "_staticInitializeObjCMetadata", "_hasMissingDesignatedInitializers", "_inheritsConvenienceInitializers",
        "_borrowed", "_noImplicitCopy", "_noLocks", "_noAllocation", "_noRuntime", "_noExistentials",
        "_noObjCBridging", "_rawLayout", "_extern", "_expose", "_section", "_used", "_unavailableFromAsync",
        "_typeEraser", "_restatedObjCConformance", "_compilerInitialized", "_alwaysEmitConformanceMetadata",
    ]

    /// Declaration modifiers worth recording on symbols (access levels are recorded as visibility).
    static let notableModifiers: Set<String> = [
        "override", "static", "class", "final", "mutating", "convenience", "required", "lazy", "weak", "unowned",
        "nonisolated", "dynamic", "optional", "indirect", "distributed", "nonmutating",
    ]

    private static let comparisonOperators: Set<String> = ["==", "!=", "<=", ">=", "===", "!==", "~="]

    // MARK: - Tokens and names

    /// Token text without surrounding backticks.
    static func identifierText(_ token: TokenSyntax) -> String {
        let text = token.text
        if text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// True for identifiers and `$`-identifiers; false for keywords (`self`, `Self`, `init`…), operators,
    /// wildcards and missing tokens.
    static func isReferenceToken(_ token: TokenSyntax) -> Bool {
        guard token.presence == .present else { return false }
        switch token.tokenKind {
        case .identifier, .dollarIdentifier: return true
        default: return false
        }
    }

    /// Whether a declared name is an ordinary identifier (as opposed to an operator like `==`).
    static func isIdentifierLike(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        return first == "_" || first == "`" || CharacterSet.letters.contains(first)
    }

    /// Dotted name of a nominal type without generic arguments (`Foo`, `Foo.Bar`); nil for structural types.
    static func typeName(_ type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifierText(identifier.name)
        }
        if let member = type.as(MemberTypeSyntax.self) {
            guard let base = typeName(member.baseType) else { return nil }
            return base + "." + identifierText(member.name)
        }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return typeName(attributed.baseType)
        }
        if let someOrAny = type.as(SomeOrAnyTypeSyntax.self) {
            return typeName(someOrAny.constraint)
        }
        return nil
    }

    /// The nominal types named by an inheritance-clause entry (unwraps `@unchecked`, `A & B`, `any P`).
    static func nominalTypes(in type: TypeSyntax) -> [TypeSyntax] {
        if type.is(IdentifierTypeSyntax.self) || type.is(MemberTypeSyntax.self) { return [type] }
        if let attributed = type.as(AttributedTypeSyntax.self) { return nominalTypes(in: attributed.baseType) }
        if let someOrAny = type.as(SomeOrAnyTypeSyntax.self) { return nominalTypes(in: someOrAny.constraint) }
        if let composition = type.as(CompositionTypeSyntax.self) {
            return composition.elements.flatMap { nominalTypes(in: $0.type) }
        }
        return []
    }

    static func inheritedTypeNames(_ clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.flatMap { inherited in
            nominalTypes(in: inherited.type).compactMap { typeName($0) }
        }
    }

    /// Uppercase identifier chains in expression position (`Foo`, `Foo.Bar`, `Foo<Int>`), as components.
    static func typeChain(_ expression: ExprSyntax) -> [String]? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            guard reference.argumentNames == nil, isReferenceToken(reference.baseName) else { return nil }
            let name = identifierText(reference.baseName)
            return name.first?.isUppercase == true ? [name] : nil
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base {
            // The name is checked first, so a chain of lowercase members costs O(1) per segment.
            let token = member.declName.baseName
            guard isReferenceToken(token) else { return nil }
            let name = identifierText(token)
            guard name.first?.isUppercase == true, var chain = typeChain(base) else { return nil }
            chain.append(name)
            return chain
        }
        if let specialized = expression.as(GenericSpecializationExprSyntax.self) {
            return typeChain(specialized.expression)
        }
        if let typeExpression = expression.as(TypeExprSyntax.self), let name = typeName(typeExpression.type) {
            let components = name.split(separator: ".").map(String.init)
            return components.allSatisfy({ $0.first?.isUppercase == true }) ? components : nil
        }
        return nil
    }

    /// The linker's receiver for a member access base: a simple identifier, `self`/`super`/`Self`, a dotted
    /// type chain, or `"_"` for any other expression.
    static func receiverText(_ expression: ExprSyntax) -> String {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            guard reference.argumentNames == nil else { return "_" }
            switch reference.baseName.tokenKind {
            case .identifier, .dollarIdentifier: return identifierText(reference.baseName)
            case .keyword(.self): return "self"
            case .keyword(.Self): return "Self"
            default: return "_"
            }
        }
        if expression.is(SuperExprSyntax.self) { return "super" }
        if let optional = expression.as(OptionalChainingExprSyntax.self), optional.expression.is(DeclReferenceExprSyntax.self) {
            return receiverText(optional.expression)
        }
        if let forced = expression.as(ForceUnwrapExprSyntax.self), forced.expression.is(DeclReferenceExprSyntax.self) {
            return receiverText(forced.expression)
        }
        if let chain = typeChain(expression) { return chain.joined(separator: ".") }
        return "_"
    }

    static func isAssignment(_ expression: ExprSyntax) -> Bool {
        if expression.is(AssignmentExprSyntax.self) { return true }
        if let binary = expression.as(BinaryOperatorExprSyntax.self) {
            let text = binary.operator.text
            return text.hasSuffix("=") && !comparisonOperators.contains(text)
        }
        return false
    }

    // MARK: - Declarations

    static func visibility(_ modifiers: DeclModifierListSyntax) -> Visibility? {
        for modifier in modifiers where modifier.detail == nil {
            if let level = accessLevel(modifier.name) { return level }
        }
        return nil
    }

    /// The setter's access when a modifier restricts it (`private(set)`, `fileprivate(set)`).
    static func setterVisibility(_ modifiers: DeclModifierListSyntax) -> Visibility? {
        for modifier in modifiers where modifier.detail?.detail.text == "set" {
            if let level = accessLevel(modifier.name) { return level }
        }
        return nil
    }

    private static func accessLevel(_ token: TokenSyntax) -> Visibility? {
        switch token.tokenKind {
        case .keyword(.open): .open
        case .keyword(.public): .public
        case .keyword(.package): .package
        case .keyword(.internal): .internal
        case .keyword(.fileprivate): .fileprivate
        case .keyword(.private): .private
        default: nil
        }
    }

    static func attributeName(_ attribute: AttributeSyntax) -> String {
        typeName(attribute.attributeName) ?? attribute.attributeName.trimmedDescription
    }

    /// `@`-prefixed attribute names, e.g. `["@MainActor", "@Published"]`.
    static func attributeNames(_ attributes: AttributeListSyntax) -> [String] {
        var names: [String] = []
        for element in attributes {
            if case .attribute(let attribute) = element {
                names.append("@" + attributeName(attribute))
            }
        }
        return names
    }

    /// Attributes as a signature shows them: `@MainActor @Query(sort: \Book.date)`. Argument lists are cut to
    /// 40 characters; `@available` and underscored attributes are noise and left out.
    static func signatureAttributes(_ attributes: AttributeListSyntax) -> String {
        var pieces: [String] = []
        for element in attributes {
            guard case .attribute(let attribute) = element else { continue }
            let name = attribute.attributeName.trimmedDescription
            if name == "available" || name.hasPrefix("_") { continue }
            var piece = "@" + name
            if let arguments = attribute.arguments {
                var text = collapsingWhitespace(arguments.trimmedDescription)
                if text.count > 40 { text = String(text.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" }
                piece += "(" + text + ")"
            } else if attribute.leftParen != nil {
                piece += "()"
            }
            pieces.append(piece)
        }
        return pieces.joined(separator: " ")
    }

    static func notableModifierNames(_ modifiers: DeclModifierListSyntax) -> [String] {
        modifiers.compactMap { modifier in
            let text = modifier.name.text
            return notableModifiers.contains(text) ? text : nil
        }
    }

    static func effects(_ specifiers: FunctionEffectSpecifiersSyntax?) -> [String] {
        guard let specifiers else { return [] }
        var result: [String] = []
        if let async = specifiers.asyncSpecifier { result.append(async.text) }
        if let throwsClause = specifiers.throwsClause { result.append(throwsClause.throwsSpecifier.text) }
        return result
    }

    static func genericParameterNames(_ clause: GenericParameterClauseSyntax?) -> Set<String> {
        guard let clause else { return [] }
        return Set(clause.parameters.map { identifierText($0.name) })
    }

    /// Generic parameters mapped to the type that stands for them in a normalised type: the first constraint
    /// (`T: Store` → `Store`, from the clause or a `where` requirement), a same-type requirement, or `?`.
    static func genericConstraints(_ clause: GenericParameterClauseSyntax?, _ whereClause: GenericWhereClauseSyntax? = nil) -> [String: String] {
        guard let clause else { return [:] }
        var constraints: [String: String] = [:]
        for parameter in clause.parameters {
            constraints[identifierText(parameter.name)] = parameter.inheritedType.map { normalizedType($0) } ?? "?"
        }
        for requirement in whereClause?.requirements ?? [] {
            switch requirement.requirement {
            case .conformanceRequirement(let conformance):
                if let name = typeName(conformance.leftType), constraints[name] == "?" {
                    constraints[name] = normalizedType(conformance.rightType)
                }
            case .sameTypeRequirement(let sameType):
                if case .type(let left) = sameType.leftType, case .type(let right) = sameType.rightType,
                   let name = typeName(left), constraints[name] != nil {
                    constraints[name] = normalizedType(right)
                }
            default:
                break
            }
        }
        return constraints
    }

    /// A type in the collector → linker grammar: a dotted nominal name with generic arguments, Optional/IUO,
    /// `some`/`any` and attributes stripped; `[T]` (also for `Array`/`Set`), `[K: V]`, or a labelled tuple
    /// `(a: A, _: B)`. `generic` maps a generic parameter to its constraint. Anything else (function types,
    /// metatypes) is `?`.
    static func normalizedType(_ type: TypeSyntax, generic: (String) -> String? = { _ in nil }) -> String {
        if let optional = type.as(OptionalTypeSyntax.self) { return normalizedType(optional.wrappedType, generic: generic) }
        if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return normalizedType(unwrapped.wrappedType, generic: generic) }
        if let attributed = type.as(AttributedTypeSyntax.self) { return normalizedType(attributed.baseType, generic: generic) }
        if let someOrAny = type.as(SomeOrAnyTypeSyntax.self) { return normalizedType(someOrAny.constraint, generic: generic) }
        if let composition = type.as(CompositionTypeSyntax.self), let first = composition.elements.first {
            return normalizedType(first.type, generic: generic)
        }
        if let array = type.as(ArrayTypeSyntax.self) { return "[" + normalizedType(array.element, generic: generic) + "]" }
        if let dictionary = type.as(DictionaryTypeSyntax.self) {
            return "[" + normalizedType(dictionary.key, generic: generic) + ": " + normalizedType(dictionary.value, generic: generic) + "]"
        }
        if let tuple = type.as(TupleTypeSyntax.self) {
            if tuple.elements.isEmpty { return "Void" }
            if tuple.elements.count == 1, let only = tuple.elements.first { return normalizedType(only.type, generic: generic) }
            let elements = tuple.elements.map { element in
                let label = element.firstName.flatMap { isReferenceToken($0) ? identifierText($0) : nil } ?? "_"
                return label + ": " + normalizedType(element.type, generic: generic)
            }
            return "(" + elements.joined(separator: ", ") + ")"
        }
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            let name = identifierText(identifier.name)
            let arguments = identifier.genericArgumentClause?.arguments.compactMap { argument -> TypeSyntax? in
                if case .type(let type) = argument.argument { return type }
                return nil
            } ?? []
            switch (name, arguments.count) {
            case ("Optional", 1): return normalizedType(arguments[0], generic: generic)
            case ("Array", 1), ("Set", 1), ("ArraySlice", 1), ("ContiguousArray", 1):
                return "[" + normalizedType(arguments[0], generic: generic) + "]"
            case ("Dictionary", 2):
                return "[" + normalizedType(arguments[0], generic: generic) + ": " + normalizedType(arguments[1], generic: generic) + "]"
            default:
                break
            }
            if arguments.isEmpty, let constraint = generic(name) { return constraint }
            return name
        }
        if let member = type.as(MemberTypeSyntax.self) {
            let base = normalizedType(member.baseType, generic: generic)
            return base == "?" || base.hasPrefix("[") || base.hasPrefix("(") ? "?" : base + "." + identifierText(member.name)
        }
        return "?"
    }

    /// A closure-typed parameter (`() -> Void`, `@escaping (T) -> U`, `(() -> Void)?`), which a trailing
    /// closure can fill. `@autoclosure` parameters take an expression, so they are not.
    static func isClosureType(_ type: TypeSyntax) -> Bool {
        if type.is(FunctionTypeSyntax.self) { return true }
        if let attributed = type.as(AttributedTypeSyntax.self) {
            let isAutoclosure = attributed.attributes.contains { element in
                if case .attribute(let attribute) = element { return attributeName(attribute) == "autoclosure" }
                return false
            }
            return !isAutoclosure && isClosureType(attributed.baseType)
        }
        if let optional = type.as(OptionalTypeSyntax.self) { return isClosureType(optional.wrappedType) }
        if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return isClosureType(unwrapped.wrappedType) }
        if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return isClosureType(only.type)
        }
        return false
    }

    /// One character per parameter: `d` defaulted, `v` variadic, `c` closure-typed, `D` defaulted and
    /// closure-typed (skippable, or filled by a trailing closure), `-` plain.
    static func parameterFlag(type: TypeSyntax, isVariadic: Bool, hasDefault: Bool) -> Character {
        if isVariadic { return "v" }
        let isClosure = isClosureType(type)
        if hasDefault { return isClosure ? "D" : "d" }
        return isClosure ? "c" : "-"
    }

    /// An argument label as a selector spells it: the name (keywords such as `for` included), or `_`.
    static func argumentLabel(_ token: TokenSyntax?) -> String {
        guard let token, token.presence == .present, token.tokenKind != .wildcard else { return "_" }
        return identifierText(token)
    }

    /// The name a `case` pattern binds to the whole matched value, and the type it casts to: `let x` and
    /// `let x?` → (x, nil), `.some(let x)` → (x, nil), `let x as T` → (x, T). Nil for enum payloads and tuples.
    static func wholeValueBinding(_ pattern: PatternSyntax) -> (name: String, cast: TypeSyntax?)? {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            return isReferenceToken(identifier.identifier) ? (identifierText(identifier.identifier), nil) : nil
        }
        if let binding = pattern.as(ValueBindingPatternSyntax.self) { return wholeValueBinding(binding.pattern) }
        guard let expression = pattern.as(ExpressionPatternSyntax.self)?.expression else { return nil }
        return wholeValueBinding(expression)
    }

    private static func wholeValueBinding(_ expression: ExprSyntax) -> (name: String, cast: TypeSyntax?)? {
        if let patternExpression = expression.as(PatternExprSyntax.self) { return wholeValueBinding(patternExpression.pattern) }
        if let optional = expression.as(OptionalChainingExprSyntax.self) { return wholeValueBinding(optional.expression) }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            // `let x as T`
            let elements = Array(sequence.elements)
            guard elements.count == 3, elements[1].is(UnresolvedAsExprSyntax.self), let type = elements[2].as(TypeExprSyntax.self),
                  let bound = wholeValueBinding(elements[0]) else { return nil }
            return (bound.name, type.type)
        }
        if let call = expression.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.base == nil, member.declName.baseName.text == "some", call.arguments.count == 1, let only = call.arguments.first {
            return wholeValueBinding(only.expression)
        }
        return nil
    }

    /// The `switch` a case belongs to (looking through `#if` blocks between the cases).
    static func switchStatement(of switchCase: SwitchCaseSyntax) -> SwitchExprSyntax? {
        var ancestor = switchCase.parent
        for _ in 0..<12 {
            guard let current = ancestor else { return nil }
            if let statement = current.as(SwitchExprSyntax.self) { return statement }
            ancestor = current.parent
        }
        return nil
    }

    /// The expression a postfix `#if` continues (`Text(…)` in `Text(…) #if os(iOS) .padding() #endif`).
    static func postfixConfigBase(of member: MemberAccessExprSyntax) -> ExprSyntax? {
        var ancestor = member.parent
        while let current = ancestor {
            if let postfix = current.as(PostfixIfConfigExprSyntax.self) { return postfix.base }
            if current.is(CodeBlockItemSyntax.self) || current.is(MemberBlockItemSyntax.self) { return nil }
            ancestor = current.parent
        }
        return nil
    }

    /// Names bound by a pattern (`x`, `(a, b)`, `.success(let value)`, `let .some(x)`).
    static func patternNames(_ pattern: PatternSyntax) -> [String] {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            return isReferenceToken(identifier.identifier) ? [identifierText(identifier.identifier)] : []
        }
        let collector = PatternNameCollector()
        collector.walk(pattern)
        return collector.names
    }

    /// The last contiguous group of `///` or `/** */` comments in a declaration's leading trivia.
    static func docComment(_ trivia: Trivia) -> String? {
        var lines: [String] = []
        var lastWasBlock = false
        for piece in trivia {
            switch piece {
            case .docLineComment(let text):
                if lastWasBlock { lines.removeAll() }
                lines.append(text)
                lastWasBlock = false
            case .docBlockComment(let text):
                lines = [text]
                lastWasBlock = true
            case .lineComment, .blockComment:
                lines.removeAll()
                lastWasBlock = false
            default:
                continue
            }
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n").cleanedDocComment()
    }

    // MARK: - Conditional compilation

    /// The condition under which an `#if` clause's contents compile, as one conjunct: `#if A` → `A`,
    /// `#elseif B` → `!A && B`, `#else` → `!A && !B`. Nil when there is nothing to say (a malformed clause).
    static func clauseCondition(_ clause: IfConfigClauseSyntax) -> String? {
        var parts: [String] = []
        if let list = clause.parent?.as(IfConfigClauseListSyntax.self) {
            for sibling in list {
                if sibling.id == clause.id { break }
                if let condition = sibling.condition { parts.append(negated(conditionText(condition))) }
            }
        }
        if let condition = clause.condition {
            let text = conditionText(condition)
            parts.append(hasTopLevelOperator(text, "|") ? "(" + text + ")" : text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " && ")
    }

    private static func conditionText(_ condition: ExprSyntax) -> String {
        collapsingWhitespace(condition.trimmedDescription)
    }

    /// `!DEBUG`, `!os(iOS)`, `!(A || B)`; a negation is undone instead of doubled.
    private static func negated(_ condition: String) -> String {
        if condition.hasPrefix("!"), !hasTopLevelOperator(condition, "&"), !hasTopLevelOperator(condition, "|") {
            return String(condition.dropFirst())
        }
        if hasTopLevelOperator(condition, "&") || hasTopLevelOperator(condition, "|") {
            return "!(" + condition + ")"
        }
        return "!" + condition
    }

    /// Whether `&&` / `||` (by its first character) occurs outside parentheses.
    private static func hasTopLevelOperator(_ condition: String, _ symbol: Character) -> Bool {
        var depth = 0
        for character in condition {
            switch character {
            case "(": depth += 1
            case ")": depth -= 1
            case symbol where depth == 0: return true
            default: break
            }
        }
        return false
    }

    /// The base-less member access that starts a postfix `#if` clause (`Text(…)` `#if os(iOS)` `.padding()`).
    /// It continues the expression before the `#if`, so it is not an implicit member expression.
    static func leadingMember(of expression: ExprSyntax) -> MemberAccessExprSyntax? {
        var current = expression
        while true {
            if let member = current.as(MemberAccessExprSyntax.self) {
                guard let base = member.base else { return member }
                current = base
            } else if let call = current.as(FunctionCallExprSyntax.self) {
                current = call.calledExpression
            } else if let subscriptCall = current.as(SubscriptCallExprSyntax.self) {
                current = subscriptCall.calledExpression
            } else if let optional = current.as(OptionalChainingExprSyntax.self) {
                current = optional.expression
            } else if let forced = current.as(ForceUnwrapExprSyntax.self) {
                current = forced.expression
            } else if let specialized = current.as(GenericSpecializationExprSyntax.self) {
                current = specialized.expression
            } else if let postfix = current.as(PostfixIfConfigExprSyntax.self), let base = postfix.base {
                current = base
            } else {
                return nil
            }
        }
    }

    // MARK: - Statements

    /// The `{` that opens the body of a compound statement or declaration (`if`, `guard`, `for`, `switch`,
    /// `func`, `struct`, a computed property…). A reference's statement is only the header before it.
    static func bodyBrace(_ node: Syntax) -> TokenSyntax? {
        switch node.as(SyntaxEnum.self) {
        case .expressionStmt(let statement): bodyBrace(Syntax(statement.expression))
        case .labeledStmt(let labeled): bodyBrace(Syntax(labeled.statement))
        case .ifExpr(let statement): statement.body.leftBrace
        case .switchExpr(let statement): statement.leftBrace
        case .guardStmt(let statement): statement.body.leftBrace
        case .forStmt(let statement): statement.body.leftBrace
        case .whileStmt(let statement): statement.body.leftBrace
        case .repeatStmt(let statement): statement.body.leftBrace
        case .doStmt(let statement): statement.body.leftBrace
        case .deferStmt(let statement): statement.body.leftBrace
        case .functionDecl(let declaration): declaration.body?.leftBrace
        case .initializerDecl(let declaration): declaration.body?.leftBrace
        case .deinitializerDecl(let declaration): declaration.body?.leftBrace
        case .subscriptDecl(let declaration): declaration.accessorBlock?.leftBrace
        case .classDecl(let declaration): declaration.memberBlock.leftBrace
        case .structDecl(let declaration): declaration.memberBlock.leftBrace
        case .enumDecl(let declaration): declaration.memberBlock.leftBrace
        case .protocolDecl(let declaration): declaration.memberBlock.leftBrace
        case .actorDecl(let declaration): declaration.memberBlock.leftBrace
        case .extensionDecl(let declaration): declaration.memberBlock.leftBrace
        case .variableDecl(let declaration):
            declaration.bindings.count == 1 ? declaration.bindings.first?.accessorBlock?.leftBrace : nil
        case .ifConfigDecl(let declaration): declaration.clauses.first?.poundKeyword
        default: nil
        }
    }

    static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Fingerprints

    /// FNV-1a over a body's token stream with identifiers → "id" and literals → "lit", so copies that only
    /// differ in names and constants hash equal.
    static func structuralHash(_ node: some SyntaxProtocol) -> UInt64 {
        var hasher = FNV1a()
        for token in node.tokens(viewMode: .sourceAccurate) {
            switch token.tokenKind {
            case .identifier, .dollarIdentifier:
                hasher.combine("id")
            case .integerLiteral, .floatLiteral, .stringSegment, .regexLiteralPattern:
                hasher.combine("lit")
            default:
                hasher.combine(token.text)
            }
        }
        return hasher.value
    }
}

/// Collects identifiers bound inside a pattern, including value-binding sub-patterns of enum case patterns.
final class PatternNameCollector: SyntaxVisitor {
    private(set) var names: [String] = []
    private var bindingDepth = 0

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        if SwiftSyntaxSupport.isReferenceToken(node.identifier) {
            names.append(SwiftSyntaxSupport.identifierText(node.identifier))
        }
        return .skipChildren
    }

    override func visit(_ node: ValueBindingPatternSyntax) -> SyntaxVisitorContinueKind {
        bindingDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: ValueBindingPatternSyntax) {
        bindingDepth -= 1
    }

    /// Inside `let .some(x)`, the parser may represent `x` as an expression; it is still a binding.
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if bindingDepth > 0, SwiftSyntaxSupport.isReferenceToken(node.baseName), node.argumentNames == nil {
            if let parent = node.parent, parent.is(MemberAccessExprSyntax.self) { return .skipChildren }
            names.append(SwiftSyntaxSupport.identifierText(node.baseName))
        }
        return .skipChildren
    }
}

/// Counts parser recovery points: unexpected node runs and missing tokens.
final class SyntaxErrorCounter: SyntaxVisitor {
    private(set) var count = 0

    init() {
        super.init(viewMode: .all)
    }

    override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
        count += 1
        return .skipChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if token.presence == .missing { count += 1 }
        return .skipChildren
    }
}
