import SwiftParser
import SwiftSyntax

/// What the Swift collector records about string literals and the environment: where a literal's value
/// goes, and how environment variables and launch arguments are written in source.
enum SwiftLiterals {
    // MARK: - Literals

    /// Where a literal's value goes, as `ExtractedLiteral` records it.
    struct Site: Equatable {
        /// `ui`, `call-arg`, `subscript`, `assign`, `initializer`, `return`, `array` (an array or dictionary
        /// literal's element) or `other`.
        var context: String
        var callee: String? = nil
        var label: String? = nil
    }

    /// SwiftUI views and modifiers whose unlabeled argument is text on screen or an accessibility identifier: what UI
    /// tests look elements up by.
    static let uiTextCallees: Set<String> = [
        "Text", "Button", "Label", "Toggle", "TextField", "SecureField", "Picker", "Section", "Link", "NavigationLink",
        "Menu", "Stepper", "DatePicker", "ColorPicker", "LabeledContent", "ContentUnavailableView", "Tab", "ShareLink",
        "GroupBox", "DisclosureGroup", "ProgressView",
        "alert", "confirmationDialog", "navigationTitle", "navigationSubtitle", "navigationBarTitle", "searchable",
        "accessibilityIdentifier", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "help", "badge",
    ]

    /// Labels under which those callees take their text (`Text(verbatim:)`, `.searchable(text:prompt:)`).
    static let uiTextLabels: Set<String> = ["verbatim", "title", "titleKey", "prompt"]

    /// Literals worth recording: 2-200 characters with a letter (not `"1"`, `"%@"` or `"#"`).
    static func isRecorded(_ value: String) -> Bool {
        let bytes = value.utf8.count
        guard bytes >= 2, bytes <= 800 else { return false }
        return (2...200).contains(value.count) && value.contains(where: \.isLetter)
    }

    /// Where a literal's value goes: the call or subscript it is an argument of (with the label), the name it
    /// initializes or is assigned to, a `return`, or a collection literal. A branch of `?:`, the fallback of `??` and a
    /// parenthesized literal go where the whole expression goes (`Text(name ?? "Guest")` is text on screen).
    static func site(of literal: StringLiteralExprSyntax) -> Site {
        var node = Syntax(literal)
        while let parent = node.parent {
            if parent.is(UnresolvedTernaryExprSyntax.self) {
                // `condition ? "a" : …`: the ternary is an operand of the sequence around it.
                node = parent
                continue
            }
            if let operands = parent.as(ExprListSyntax.self) {
                // An operand of an operator sequence, which is unfolded: `title = name ?? "Guest"` is one flat list.
                guard let sequence = operands.parent?.as(SequenceExprSyntax.self) else { break }
                let elements = Array(operands)
                guard let index = elements.firstIndex(where: { $0.id == node.id }), index > 0 else { break }
                let before = elements[index - 1]
                let isValue = node.is(UnresolvedTernaryExprSyntax.self) || before.is(UnresolvedTernaryExprSyntax.self)
                    || SwiftSyntaxSupport.isAssignment(before) || before.as(BinaryOperatorExprSyntax.self)?.operator.text == "??"
                guard isValue else { break }
                if elements.count >= 3, SwiftSyntaxSupport.isAssignment(elements[1]) {
                    return Site(context: "assign", callee: calleeName(elements[0]))
                }
                node = Syntax(sequence)
                continue
            }
            if let argument = parent.as(LabeledExprSyntax.self) {
                let label = argument.label.map { SwiftSyntaxSupport.identifierText($0) }
                guard let owner = argument.parent?.parent else { break }
                if let call = owner.as(FunctionCallExprSyntax.self) {
                    let callee = calleeName(call.calledExpression)
                    let isText = callee.map { uiTextCallees.contains($0) } == true && (label.map { uiTextLabels.contains($0) } ?? true)
                    return Site(context: isText ? "ui" : "call-arg", callee: callee, label: label)
                }
                if let subscriptCall = owner.as(SubscriptCallExprSyntax.self) {
                    // `app.buttons["Save"]` looks an element up; `environment["X"]` reads a key.
                    let callee = calleeName(subscriptCall.calledExpression)
                    let isQuery = callee.map { SwiftTypeInference.uiTestQueries.contains($0) } == true
                    return Site(context: isQuery ? "ui" : "subscript", callee: callee, label: label)
                }
                if let macro = owner.as(MacroExpansionExprSyntax.self) {
                    return Site(context: "call-arg", callee: SwiftSyntaxSupport.identifierText(macro.macroName), label: label)
                }
                if let macro = owner.as(MacroExpansionDeclSyntax.self) {
                    return Site(context: "call-arg", callee: SwiftSyntaxSupport.identifierText(macro.macroName), label: label)
                }
                if let attribute = owner.as(AttributeSyntax.self) {
                    // `@AppStorage("hasSeenIntro")`
                    return Site(context: "call-arg", callee: SwiftSyntaxSupport.attributeName(attribute), label: label)
                }
                if let tuple = owner.as(TupleExprSyntax.self), tuple.elements.count == 1, label == nil {
                    node = Syntax(tuple)
                    continue
                }
                return Site(context: "other", label: label)
            }
            if let clause = parent.as(InitializerClauseSyntax.self) {
                return Site(context: "initializer", callee: initializedName(clause))
            }
            if parent.is(ReturnStmtSyntax.self) { return Site(context: "return") }
            if parent.is(ArrayElementSyntax.self) || parent.is(DictionaryElementSyntax.self) { return Site(context: "array") }
            if parent.is(CodeBlockItemSyntax.self), parent.parent?.as(CodeBlockItemListSyntax.self)?.count == 1 {
                // The only expression of a body is its value: `var title: String { "Books" }`, `case .a: "A"`.
                return Site(context: "return")
            }
            break
        }
        return Site(context: "other")
    }

    /// The name of what is called, subscripted or assigned: `Text`, `navigationTitle`, `buttons` in
    /// `app.buttons["Save"]`, `descendants` in `app.descendants(matching: .any)["id"]`, `title` in `self.title`.
    static func calleeName(_ expression: ExprSyntax) -> String? {
        var current = expression
        while true {
            if let reference = current.as(DeclReferenceExprSyntax.self) {
                return SwiftSyntaxSupport.identifierText(reference.baseName)
            }
            if let member = current.as(MemberAccessExprSyntax.self) {
                // `Text.init("…")` calls `Text`.
                if member.declName.baseName.tokenKind == .keyword(.`init`), let base = member.base {
                    current = base
                    continue
                }
                return SwiftSyntaxSupport.identifierText(member.declName.baseName)
            }
            if let call = current.as(FunctionCallExprSyntax.self) {
                current = call.calledExpression
            } else if let subscriptCall = current.as(SubscriptCallExprSyntax.self) {
                current = subscriptCall.calledExpression
            } else if let specialized = current.as(GenericSpecializationExprSyntax.self) {
                current = specialized.expression
            } else if let optional = current.as(OptionalChainingExprSyntax.self) {
                current = optional.expression
            } else if let forced = current.as(ForceUnwrapExprSyntax.self) {
                current = forced.expression
            } else {
                return nil
            }
        }
    }

    /// The name an initializer clause gives its value: a variable, an enum case (raw value), a parameter (default).
    private static func initializedName(_ clause: InitializerClauseSyntax) -> String? {
        guard let owner = clause.parent else { return nil }
        if let binding = owner.as(PatternBindingSyntax.self), let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
            return SwiftSyntaxSupport.identifierText(identifier.identifier)
        }
        if let element = owner.as(EnumCaseElementSyntax.self) { return SwiftSyntaxSupport.identifierText(element.name) }
        if let parameter = owner.as(FunctionParameterSyntax.self) {
            return SwiftSyntaxSupport.identifierText(parameter.secondName ?? parameter.firstName)
        }
        return nil
    }

    // MARK: - Environment variables and launch arguments

    /// The value of a string literal without interpolation, unless it is empty.
    static func stringValue(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self), let value = literal.representedLiteralValue,
              !value.isEmpty else { return nil }
        return value
    }

    /// The string keys of a dictionary literal, each with the expression that spells it.
    static func stringKeys(_ dictionary: DictionaryExprSyntax) -> [(value: String, expression: ExprSyntax)] {
        guard case .elements(let elements) = dictionary.content else { return [] }
        return elements.compactMap { element in stringValue(element.key).map { ($0, element.key) } }
    }

    /// The launch arguments an array literal passes: `["-hasSeenIntro", "YES", "-UITests"]` passes the user
    /// default `-hasSeenIntro` (set to `YES`) and the flag `-UITests`. A value after a `-key` is not an argument
    /// of its own.
    static func launchArguments(_ array: ArrayExprSyntax) -> [(value: String, expression: ExprSyntax)] {
        var arguments: [(value: String, expression: ExprSyntax)] = []
        var afterKey = false
        for element in array.elements {
            guard let value = stringValue(element.expression) else {
                afterKey = false
                continue
            }
            if afterKey && !value.hasPrefix("-") {
                afterKey = false
                continue
            }
            arguments.append((value, element.expression))
            afterKey = value.hasPrefix("-")
        }
        return arguments
    }

    /// A `[String: String]` named like an environment holds one: `environment`, `launchEnvironment`, `env`, `childEnv`.
    static func isEnvironmentName(_ name: String) -> Bool {
        name == "env" || name == "environ" || name.hasSuffix("Env") || name.lowercased().hasSuffix("environment")
    }

    /// The operator and (single) value of an assignment whose left side is `target`: `env["X"] = "1"`,
    /// `app.launchArguments += ["-UITests"]`. The value is nil when it is an operator sequence of its own.
    static func assignment(to target: some SyntaxProtocol) -> (operator: ExprSyntax, value: ExprSyntax?)? {
        guard let operands = target.parent?.as(ExprListSyntax.self), operands.parent?.is(SequenceExprSyntax.self) == true,
              operands.first?.id == target.id else { return nil }
        let elements = Array(operands)
        guard elements.count >= 3, SwiftSyntaxSupport.isAssignment(elements[1]) else { return nil }
        return (elements[1], elements.count == 3 ? elements[2] : nil)
    }
}
