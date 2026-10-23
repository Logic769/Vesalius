import Foundation
import SwiftSyntax

// MARK: - Types as the collector sees them

/// What the Swift collector knows about the type of a value, before it is written in the collector → linker
/// grammar of `ExtractedReference.receiverHint` and `ExtractedSymbol.declaredType`.
indirect enum TypeExpr: Hashable {
    /// A type in that grammar: `Store`, `[Book]`, `(label: String, reason: String)`.
    case named(String)
    /// The type of the value produced by the reference emitted for this expression (`^`). `fallback` names the
    /// type when no reference is emitted for it (an instantiated local or standard-library type).
    case expr(SyntaxIdentifier, fallback: String?)
    /// The type of the value produced by the reference at this index (`^`).
    case ref(Int)
    /// The element type of a sequence (`elem(…)`).
    case element(TypeExpr)
}

/// A parameter, local, closure parameter or local declaration in scope.
struct LocalBinding {
    enum Kind {
        case value
        /// A local function: calling it produces `type`.
        case function
        /// A local type or a generic parameter: as a receiver, its name is the type.
        case type
    }

    var type: TypeExpr?
    /// Line of the declaration (→ `typeEvidenceLine`).
    var line: Int
    var kind: Kind = .value
}

/// A type written in the hint grammar, with the reference that `^` in it stands for.
struct TypeHint: Equatable {
    var text: String
    var ref: Int?
}

/// How the receiver of a member reference is typed. Decided during the walk, written once every reference
/// exists (`SwiftSyntaxCollector.finishTypes`).
enum ReceiverNote {
    /// A local or parameter: its binding's type (`T`, `^`, `elem(…)`), or `?` when the collector cannot tell.
    case local(TypeExpr?, line: Int?)
    /// Any other value (a property, a call, a member, a literal): the type of what produces it.
    case value(TypeExpr)
    /// An implicit member, looked up in a contextual type: `ctx(T)`, `ctx(^)`.
    case context(TypeExpr)
    /// An implicit member passed as argument `index` of a call: `param(^,index)`.
    case argument(call: SyntaxIdentifier, index: Int)
    /// A key-path component after the first: the value of the component before it.
    case component(Int)
}

/// Where an implicit member (`.idle`, `.data(…)`) is looked up.
enum ImplicitContext {
    case type(TypeExpr)
    case argument(call: SyntaxIdentifier, index: Int)
}

// MARK: - Rules and vocabularies

/// The receiver and implicit-member inference rules of the Swift collector and the standard-library knowledge they use.
enum SwiftTypeInference {
    /// Every inference rule, by name. A process can switch rules off to see whether one is behind a wrong edge:
    /// `VESALIUS_SWIFT_DISABLED_RULES=closureElement,contextArgument` (`all` switches off every rule). The
    /// analyzer version does not change with it, so an index built that way must be rebuilt afterwards.
    enum Rule: String, CaseIterable, Sendable {
        // Bindings: parameters, locals and closure parameters.
        case parameter, localAnnotation, localInitializer, tuplePattern, forElement, optionalBinding, castPattern,
             closureElement, swiftUIData, closureValue, captureList, catchError, accessorValue, localFunction
        // Expressions.
        case instantiation, literal, cast, ternary, nilCoalescing, operatorResult, collectionMember, subscriptIndex,
             unwrap, range, nonLocalValue, selfType, uiTestQuery, knownClosure, keyPathRoot
        // Declarations.
        case propertyType, environmentValue, returnType, ownerType
        // Receivers and implicit-member contexts.
        case receiverChain, contextAnnotation, contextDefault, contextComparison, contextAssignment, contextReturn,
             contextPattern, contextSetOperation, contextArrayElement, contextArgument, contextChain, contextTernary,
             implicitInit
    }

    /// Rules switched off for this process.
    static let disabledRules: Set<Rule> = rules(named: ProcessInfo.processInfo.environment["VESALIUS_SWIFT_DISABLED_RULES"])

    static func rules(named list: String?) -> Set<Rule> {
        guard let list else { return [] }
        var rules = Set<Rule>()
        for item in list.split(separator: ",") {
            let name = item.trimmingCharacters(in: .whitespaces)
            if name == "all" { return Set(Rule.allCases) }
            if let rule = Rule(rawValue: name) { rules.insert(rule) }
        }
        return rules
    }

    enum ClosureShape {
        /// `map { element in }`
        case element
        /// `sorted { a, b in }`
        case pair
        /// `reduce(initial) { partial, element in }`
        case accumulator
    }

    /// Standard-library methods whose closure receives the sequence's elements.
    static let elementClosures: [String: ClosureShape] = [
        "map": .element, "compactMap": .element, "flatMap": .element, "filter": .element, "forEach": .element,
        "first": .element, "last": .element, "contains": .element, "allSatisfy": .element, "firstIndex": .element,
        "lastIndex": .element, "drop": .element, "prefix": .element, "removeAll": .element, "count": .element,
        "partition": .element, "split": .element,
        "sorted": .pair, "sort": .pair, "min": .pair, "max": .pair,
        "reduce": .accumulator,
    ]

    /// Methods that return a sequence of the receiver's elements (`filter`, `sorted()`, `reversed()`…).
    static let sameSequenceMethods: Set<String> = [
        "filter", "sorted", "reversed", "shuffled", "prefix", "suffix", "dropFirst", "dropLast", "drop",
    ]

    /// Methods that return one of the receiver's elements.
    static let elementMethods: Set<String> = [
        "first", "last", "randomElement", "min", "max", "popLast", "removeFirst", "removeLast",
    ]

    /// Collection and option-set operations whose first argument is an element of the receiver (or, for an
    /// option set, a value of its own type): `flags.contains(.isPadding)`, `tags.insert(.urgent)`.
    static let elementArgumentMethods: Set<String> = [
        "contains", "insert", "remove", "append", "formUnion", "formIntersection", "formSymmetricDifference",
        "subtract", "subtracting", "union", "intersection", "symmetricDifference", "isSuperset", "isSubset",
        "isStrictSuperset", "isStrictSubset", "isDisjoint", "update", "firstIndex", "lastIndex",
    ]

    /// SwiftUI views that build one row per element of their data argument.
    static let dataViews: Set<String> = ["ForEach", "List", "Table"]

    /// SwiftUI modifiers whose closure receives the value of an argument: `.onChange(of: value) { new in }`,
    /// `.sheet(item: $selection) { item in }`, `.navigationDestination(for: Book.self) { book in }`. `closures`
    /// are the labels of the closures that receive it (`""` is the first trailing closure).
    static let valueClosures: [String: (arguments: Set<String>, closures: Set<String>)] = [
        "onChange": (["of"], [""]), "sheet": (["item"], ["", "content"]), "fullScreenCover": (["item"], ["", "content"]),
        "popover": (["item"], ["", "content"]), "navigationDestination": (["item", "for"], ["", "destination"]),
        "alert": (["presenting"], ["", "actions", "message"]), "confirmationDialog": (["presenting"], ["", "actions", "message"]),
        "onGeometryChange": (["for"], ["action"]),
    ]

    /// Closures whose parameter types a well-known API fixes, by callee and closure label (`""` is the first
    /// trailing closure): `GeometryReader { proxy in }`, `withCheckedContinuation { continuation in }`.
    static let knownClosureParameters: [String: [String: [String]]] = [
        "GeometryReader": ["": ["GeometryProxy"], "content": ["GeometryProxy"]],
        "ScrollViewReader": ["": ["ScrollViewProxy"], "content": ["ScrollViewProxy"]],
        "MapReader": ["": ["MapProxy"], "content": ["MapProxy"]],
        "Canvas": ["": ["GraphicsContext", "CGSize"], "renderer": ["GraphicsContext", "CGSize"]],
        "onGeometryChange": ["": ["GeometryProxy"], "of": ["GeometryProxy"]],
        "withCheckedContinuation": ["": ["CheckedContinuation"]], "withCheckedThrowingContinuation": ["": ["CheckedContinuation"]],
        "withUnsafeContinuation": ["": ["UnsafeContinuation"]], "withUnsafeThrowingContinuation": ["": ["UnsafeContinuation"]],
        "withTaskGroup": ["": ["TaskGroup"], "body": ["TaskGroup"]],
        "withThrowingTaskGroup": ["": ["ThrowingTaskGroup"], "body": ["ThrowingTaskGroup"]],
        "withDiscardingTaskGroup": ["": ["DiscardingTaskGroup"], "body": ["DiscardingTaskGroup"]],
        "withThrowingDiscardingTaskGroup": ["": ["ThrowingDiscardingTaskGroup"], "body": ["ThrowingDiscardingTaskGroup"]],
        "AsyncStream": ["": ["AsyncStream.Continuation"]], "AsyncThrowingStream": ["": ["AsyncThrowingStream.Continuation"]],
    ]

    /// XCUITest element queries: `app.buttons["Save"]` is an `XCUIElement`.
    static let uiTestQueries: Set<String> = [
        "buttons", "staticTexts", "otherElements", "textFields", "secureTextFields", "cells", "switches", "navigationBars",
        "alerts", "sheets", "images", "links", "tabBars", "collectionViews", "tables", "scrollViews", "segmentedControls",
        "sliders", "pickers", "pickerWheels", "toggles", "textViews", "menuItems", "windows", "webViews", "steppers",
        "searchFields", "keys", "icons", "progressIndicators", "activityIndicators", "datePickers", "maps", "menus",
        "menuBars", "menuBarItems", "toolbars", "toolbarButtons", "popUpButtons", "radioButtons", "checkBoxes",
        "groups", "statusBars", "outlines", "outlineRows", "tableRows", "tableColumns", "browsers", "splitGroups",
        "disclosureTriangles", "comboBoxes", "colorWells", "relevanceIndicators", "valueIndicators", "touchBars",
        "dialogs", "drawers", "popovers", "ratingIndicators", "rulers", "rulerMarkers", "scrollBars", "splitters",
        "steppers", "tabGroups", "handles", "layoutAreas", "layoutItems", "levelIndicators", "matrices", "grids",
        "descendants", "children",
    ]

    /// Operators whose result is a `Bool`, and arithmetic ones whose result has their operands' type.
    static let booleanOperators: Set<String> = ["==", "!=", "<", ">", "<=", ">=", "&&", "||", "===", "!==", "~="]
    static let arithmeticOperators: Set<String> = ["+", "-", "*", "/", "%", "&+", "&-", "&*", "<<", ">>", "&", "|", "^"]

    /// `@Environment(\.key)`: the types of SwiftUI's own environment values.
    static let environmentValues: [String: String] = [
        "modelContext": "ModelContext", "dismiss": "DismissAction", "scenePhase": "ScenePhase", "openURL": "OpenURLAction",
        "colorScheme": "ColorScheme", "colorSchemeContrast": "ColorSchemeContrast", "horizontalSizeClass": "UserInterfaceSizeClass",
        "verticalSizeClass": "UserInterfaceSizeClass", "locale": "Locale", "calendar": "Calendar", "timeZone": "TimeZone",
        "managedObjectContext": "NSManagedObjectContext", "undoManager": "UndoManager", "openWindow": "OpenWindowAction",
        "dismissWindow": "DismissWindowAction", "openSettings": "OpenSettingsAction", "requestReview": "RequestReviewAction",
        "purchase": "PurchaseAction", "refresh": "RefreshAction", "openImmersiveSpace": "OpenImmersiveSpaceAction",
        "dismissImmersiveSpace": "DismissImmersiveSpaceAction", "newDocument": "NewDocumentAction",
        "openDocument": "OpenDocumentAction", "webAuthenticationSession": "WebAuthenticationSession",
        "authorizationController": "AuthorizationController", "editMode": "Binding", "presentationMode": "Binding",
        "isEnabled": "Bool", "isSearching": "Bool", "isPresented": "Bool", "isFocused": "Bool", "isLuminanceReduced": "Bool",
        "supportsMultipleWindows": "Bool", "accessibilityEnabled": "Bool", "accessibilityReduceMotion": "Bool",
        "accessibilityReduceTransparency": "Bool", "accessibilityDifferentiateWithoutColor": "Bool",
        "accessibilityVoiceOverEnabled": "Bool", "dynamicTypeSize": "DynamicTypeSize", "sizeCategory": "ContentSizeCategory",
        "displayScale": "CGFloat", "pixelLength": "CGFloat", "layoutDirection": "LayoutDirection", "font": "Font",
        "lineLimit": "Int", "redactionReasons": "RedactionReasons", "controlSize": "ControlSize",
        "legibilityWeight": "LegibilityWeight", "multilineTextAlignment": "TextAlignment", "widgetFamily": "WidgetFamily",
        "widgetRenderingMode": "WidgetRenderingMode", "showsWidgetContainerBackground": "Bool",
    ]

    // MARK: Expressions

    /// The expression without what does not change its type: `try`, `await`, `unsafe`, `!`, `?`, parentheses.
    static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
        var current = expression
        while true {
            if let wrapper = current.as(TryExprSyntax.self) {
                current = wrapper.expression
            } else if let wrapper = current.as(AwaitExprSyntax.self) {
                current = wrapper.expression
            } else if let wrapper = current.as(UnsafeExprSyntax.self) {
                current = wrapper.expression
            } else if let wrapper = current.as(ForceUnwrapExprSyntax.self) {
                current = wrapper.expression
            } else if let wrapper = current.as(OptionalChainingExprSyntax.self) {
                current = wrapper.expression
            } else if let tuple = current.as(TupleExprSyntax.self), tuple.elements.count == 1,
                      let only = tuple.elements.first, only.label == nil {
                current = only.expression
            } else {
                return current
            }
        }
    }

    /// The operator of a sequence element: a binary operator's text, `=` for an assignment, nil otherwise.
    static func operatorText(_ element: ExprSyntax) -> String? {
        if let binary = element.as(BinaryOperatorExprSyntax.self) { return binary.operator.text }
        if element.is(AssignmentExprSyntax.self) { return "=" }
        if element.is(UnresolvedTernaryExprSyntax.self) { return "?:" }
        return nil
    }

    /// Operators that bind more loosely than a comparison, so they end its operands.
    static let looserThanComparison: Set<String> = ["&&", "||", "=", "?:"]
    static let comparisons: Set<String> = ["==", "!=", "~="]

    // MARK: Types written in the grammar

    /// The element type of a sequence type written in the grammar, when the text tells: `[T]` → `T`,
    /// `[K: V]` → `(key: K, value: V)`, `String` → `Character`. Nil when only the linker can tell.
    static func element(of type: String) -> String? {
        switch type {
        case "String", "Substring": return "Character"
        case "Data": return "UInt8"
        default: break
        }
        guard type.hasPrefix("["), type.hasSuffix("]") else { return nil }
        if let parts = dictionaryParts(type) { return "(key: \(parts.key), value: \(parts.value))" }
        let inner = String(type.dropFirst().dropLast())
        return inner == "?" ? nil : inner
    }

    /// `[K: V]` as its key and value types; nil for any other type.
    static func dictionaryParts(_ type: String) -> (key: String, value: String)? {
        guard type.hasPrefix("["), type.hasSuffix("]") else { return nil }
        let inner = type.dropFirst().dropLast()
        var depth = 0
        var index = inner.startIndex
        while index < inner.endIndex {
            switch inner[index] {
            case "[", "(": depth += 1
            case "]", ")": depth -= 1
            case ":" where depth == 0:
                let key = inner[..<index].trimmingCharacters(in: .whitespaces)
                let value = inner[inner.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return (key, value)
            default: break
            }
            index = inner.index(after: index)
        }
        return nil
    }

    /// A dotted nominal type (`Foo`, `Foo.Bar`), as opposed to a collection, a tuple, `elem(…)` or `?`.
    static func isNominal(_ type: String) -> Bool {
        guard let first = type.unicodeScalars.first else { return false }
        return first != "[" && first != "(" && first != "?" && first != "^" && !type.hasPrefix("elem(")
    }

    /// What `ctx(…)` may hold: a nominal type, a collection (the linker looks in its element type) or `^`.
    static func canBeContext(_ type: String) -> Bool {
        type == "^" || type.hasPrefix("[") || isNominal(type)
    }
}

// MARK: - Inference over the collector's scope environment

extension SwiftSyntaxCollector {
    func allows(_ rule: SwiftTypeInference.Rule) -> Bool {
        !disabledRules.contains(rule)
    }

    /// A written type as a binding's type: the normalised grammar text, nil when nothing is known.
    func declaredType(_ type: TypeSyntax, generics: [String: String] = [:]) -> TypeExpr? {
        let text = normalizedType(type, generics)
        return text == "?" ? nil : .named(text)
    }

    /// The type of the value an expression produces, as far as the collector can tell. Memoised per node,
    /// so a member chain costs O(1) per segment.
    func typeOf(_ expression: ExprSyntax) -> TypeExpr? {
        if let known = typeMemo[expression.id] { return known }
        let type = computeType(of: expression)
        typeMemo.updateValue(type, forKey: expression.id)
        return type
    }

    private func computeType(of expression: ExprSyntax) -> TypeExpr? {
        let expression = SwiftTypeInference.unwrapped(expression)
        switch expression.as(ExprSyntaxEnum.self) {
        case .stringLiteralExpr, .simpleStringLiteralExpr:
            return allows(.literal) ? .named("String") : nil
        case .integerLiteralExpr:
            return allows(.literal) ? .named("Int") : nil
        case .floatLiteralExpr:
            return allows(.literal) ? .named("Double") : nil
        case .booleanLiteralExpr:
            return allows(.literal) ? .named("Bool") : nil
        case .arrayExpr(let array):
            // `[a, b]`: an array of the first element's type, when it is written out.
            guard allows(.literal), let first = array.elements.first, let element = staticType(typeOf(first.expression)) else { return nil }
            return .named("[" + element + "]")
        case .dictionaryExpr(let dictionary):
            guard allows(.literal), case .elements(let elements) = dictionary.content, let first = elements.first,
                  let key = staticType(typeOf(first.key)), let value = staticType(typeOf(first.value)) else { return nil }
            return .named("[" + key + ": " + value + "]")
        case .sequenceExpr(let sequence):
            return sequenceType(sequence)
        case .declReferenceExpr(let reference):
            return referenceType(reference)
        case .memberAccessExpr(let member):
            return memberType(member)
        case .functionCallExpr(let call):
            return callType(call)
        case .subscriptCallExpr(let subscriptCall):
            return subscriptType(subscriptCall)
        case .macroExpansionExpr(let macro):
            // `try #require(plans.first)` gives its argument, unwrapped.
            guard allows(.unwrap), macro.macroName.text == "require", let first = macro.arguments.first else { return nil }
            return typeOf(first.expression)
        default:
            return nil
        }
    }

    /// The type as grammar text, when it is known without the linker: a written type, an instantiated type's
    /// name, or the element of either. A value that only a reference can type (`^`) has none.
    func staticType(_ type: TypeExpr?) -> String? {
        switch type {
        case .named(let name)?: return name
        case .expr(_, let fallback)?: return fallback
        case .element(let inner)?: return staticType(inner).flatMap { SwiftTypeInference.element(of: $0) }
        default: return nil
        }
    }

    private func referenceType(_ reference: DeclReferenceExprSyntax) -> TypeExpr? {
        let token = reference.baseName
        switch token.tokenKind {
        case .keyword(.self), .keyword(.Self):
            return allows(.selfType) ? enclosingTypeName.map { .named($0) } : nil
        case .identifier, .dollarIdentifier:
            break
        default:
            return nil
        }
        guard reference.argumentNames == nil else { return nil }
        let name = SwiftSyntaxSupport.identifierText(token)
        if let binding = binding(for: name) {
            return binding.kind == .value ? binding.type : nil
        }
        // `$x` is a property wrapper's projected value, not the value; a bare `Foo` is a metatype.
        if name.hasPrefix("$") || name.first?.isUppercase == true { return nil }
        return allows(.nonLocalValue) ? .expr(reference.id, fallback: nil) : nil
    }

    private func memberType(_ member: MemberAccessExprSyntax) -> TypeExpr? {
        guard let base = member.base else {
            // `.shared` in a typed position: whatever the implicit member's reference produces.
            return allows(.nonLocalValue) ? .expr(member.id, fallback: nil) : nil
        }
        let token = member.declName.baseName
        if token.tokenKind == .keyword(.self) { return typeOf(base) }
        guard SwiftSyntaxSupport.isReferenceToken(token) else { return nil }
        let name = SwiftSyntaxSupport.identifierText(token)
        let isTypeBase = SwiftSyntaxSupport.typeChain(base) != nil
        if isTypeBase && name.first?.isUppercase == true { return nil }
        if !isTypeBase, allows(.collectionMember) {
            switch name {
            case "first", "last":
                if let baseType = typeOf(base) { return .element(baseType) }
            case "count", "startIndex", "endIndex":
                if typeOf(base) != nil { return .named("Int") }
            case "isEmpty":
                if typeOf(base) != nil { return .named("Bool") }
            case "indices":
                if typeOf(base) != nil { return .named("[Int]") }
            case "lazy":
                if let baseType = typeOf(base) { return baseType }
            case "keys", "values":
                if let baseType = staticType(typeOf(base)), let parts = SwiftTypeInference.dictionaryParts(baseType) {
                    return .named("[" + (name == "keys" ? parts.key : parts.value) + "]")
                }
            case "firstMatch":
                if allows(.uiTestQuery), staticType(typeOf(base)) == "XCUIElement" { return .named("XCUIElement") }
            default:
                break
            }
        }
        return allows(.nonLocalValue) ? .expr(member.id, fallback: nil) : nil
    }

    private func callType(_ call: FunctionCallExprSyntax) -> TypeExpr? {
        var callee = call.calledExpression
        if let specialized = callee.as(GenericSpecializationExprSyntax.self) {
            // `Array<Book>()`, `Set<Tag>()`, `Dictionary<String, Int>()`.
            if allows(.instantiation), let name = specialized.expression.as(DeclReferenceExprSyntax.self)?.baseName.text {
                let arguments = specialized.genericArgumentClause.arguments.compactMap { argument -> String? in
                    if case .type(let type) = argument.argument { return normalizedType(type, [:]) }
                    return nil
                }
                switch (name, arguments.count) {
                case ("Array", 1), ("Set", 1), ("ContiguousArray", 1): return .named("[" + arguments[0] + "]")
                case ("Dictionary", 2): return .named("[" + arguments[0] + ": " + arguments[1] + "]")
                default: break
                }
            }
            callee = specialized.expression
        }
        // `[Book]()`, `[String: Int]()`: the type is written as a literal.
        if let array = callee.as(ArrayExprSyntax.self) {
            guard allows(.instantiation), array.elements.count == 1, let only = array.elements.first,
                  let element = writtenType(only.expression) else { return nil }
            return .named("[" + element + "]")
        }
        if let dictionary = callee.as(DictionaryExprSyntax.self) {
            guard allows(.instantiation), case .elements(let elements) = dictionary.content, elements.count == 1,
                  let only = elements.first, let key = writtenType(only.key), let value = writtenType(only.value) else { return nil }
            return .named("[" + key + ": " + value + "]")
        }
        if let reference = callee.as(DeclReferenceExprSyntax.self) {
            return calledReferenceType(reference, call: call)
        }
        if let member = callee.as(MemberAccessExprSyntax.self) {
            return calledMemberType(member, call: call)
        }
        return nil
    }

    /// `Foo(…)`, `Self(…)`, `helper(…)`, `XCTUnwrap(x)`, `stride(from:to:by:)`, `makeClient()`.
    private func calledReferenceType(_ reference: DeclReferenceExprSyntax, call: FunctionCallExprSyntax) -> TypeExpr? {
        let token = reference.baseName
        if token.tokenKind == .keyword(.Self) {
            return allows(.instantiation) ? enclosingTypeName.map { .named($0) } : nil
        }
        guard SwiftSyntaxSupport.isReferenceToken(token), reference.argumentNames == nil else { return nil }
        let name = SwiftSyntaxSupport.identifierText(token)
        if let binding = binding(for: name) {
            switch binding.kind {
            case .function: return allows(.localFunction) ? binding.type : nil
            case .type: return allows(.instantiation) ? .named(name) : nil
            case .value: return nil
            }
        }
        let firstArgument = call.arguments.first
        switch name {
        case "XCTUnwrap":
            guard allows(.unwrap), let firstArgument else { return nil }
            return typeOf(firstArgument.expression)
        case "stride":
            guard allows(.range), let firstArgument, let element = staticType(typeOf(firstArgument.expression)) else { return nil }
            return .named("[" + element + "]")
        case "Array", "ContiguousArray", "Set":
            // `Array(repeating: x, count: n)`, `Array(books)`.
            guard allows(.instantiation), let firstArgument else { return nil }
            if firstArgument.label?.text == "repeating" {
                return staticType(typeOf(firstArgument.expression)).map { .named("[" + $0 + "]") }
            }
            guard firstArgument.label == nil, let sequence = typeOf(firstArgument.expression) else { return nil }
            if let text = staticType(sequence), !text.hasPrefix("[") { return nil }
            return sequence
        default:
            break
        }
        if name.first?.isUppercase == true {
            return allows(.instantiation) ? .expr(call.id, fallback: name) : nil
        }
        return allows(.nonLocalValue) ? .expr(call.id, fallback: nil) : nil
    }

    /// `Foo.init(…)`, `Foo.Bar(…)`, `Foo.make()`, `books.first(where:)`, `store.load()`.
    private func calledMemberType(_ member: MemberAccessExprSyntax, call: FunctionCallExprSyntax) -> TypeExpr? {
        guard let base = member.base else {
            // `.make()` / `.init()` in a typed position: whatever the implicit member's reference produces.
            return allows(.nonLocalValue) ? .expr(call.id, fallback: nil) : nil
        }
        let token = member.declName.baseName
        if token.tokenKind == .keyword(.`init`) {
            guard allows(.instantiation) else { return nil }
            if let chain = SwiftSyntaxSupport.typeChain(base) { return .expr(call.id, fallback: chain.joined(separator: ".")) }
            if let keyword = base.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind, keyword == .keyword(.self) || keyword == .keyword(.Self) {
                return enclosingTypeName.map { .named($0) }
            }
            return nil
        }
        guard SwiftSyntaxSupport.isReferenceToken(token) else { return nil }
        let name = SwiftSyntaxSupport.identifierText(token)
        if let chain = SwiftSyntaxSupport.typeChain(base) {
            // `Foo.Bar(…)` instantiates a nested type; `Foo.make()` is a factory whose return type the linker reads.
            if name.first?.isUppercase == true {
                return allows(.instantiation) ? .expr(call.id, fallback: (chain + [name]).joined(separator: ".")) : nil
            }
            return allows(.nonLocalValue) ? .expr(call.id, fallback: nil) : nil
        }
        if allows(.collectionMember), let baseType = collectionBaseType(base, member: name) {
            if SwiftTypeInference.sameSequenceMethods.contains(name) { return baseType }
            if SwiftTypeInference.elementMethods.contains(name) { return .element(baseType) }
            if name == "firstIndex" || name == "lastIndex" { return .named("Int") }
        }
        return allows(.nonLocalValue) ? .expr(call.id, fallback: nil) : nil
    }

    /// The base's type when `member` is a standard-library sequence method the collector types itself.
    private func collectionBaseType(_ base: ExprSyntax, member: String) -> TypeExpr? {
        guard SwiftTypeInference.sameSequenceMethods.contains(member) || SwiftTypeInference.elementMethods.contains(member)
            || member == "firstIndex" || member == "lastIndex" else { return nil }
        return typeOf(base)
    }

    /// `xs[0]` (an element), `table[key]` (a dictionary's value), `app.buttons["Save"]` (an `XCUIElement`).
    private func subscriptType(_ subscriptCall: SubscriptCallExprSyntax) -> TypeExpr? {
        guard subscriptCall.arguments.count == 1, let index = subscriptCall.arguments.first, index.label == nil else { return nil }
        if let query = subscriptCall.calledExpression.as(MemberAccessExprSyntax.self), query.base != nil,
           SwiftTypeInference.uiTestQueries.contains(query.declName.baseName.text), allows(.uiTestQuery),
           staticType(typeOf(index.expression)) == "String" {
            return .named("XCUIElement")
        }
        guard allows(.subscriptIndex), let base = typeOf(subscriptCall.calledExpression) else { return nil }
        if let text = staticType(base), let parts = SwiftTypeInference.dictionaryParts(text) { return .named(parts.value) }
        guard staticType(typeOf(index.expression)) == "Int" else { return nil }
        return .element(base)
    }

    /// `x as? T`, `x is T`, `c ? a : b`, `a ?? b`, `0..<n`, `a == b`, `index - 1`.
    private func sequenceType(_ sequence: SequenceExprSyntax) -> TypeExpr? {
        let elements = Array(sequence.elements)
        guard elements.count >= 3 else { return nil }
        let operators = elements.compactMap(SwiftTypeInference.operatorText)
        if operators.contains("=") { return nil }
        // A cast binds tighter than `??` and the ternary: `x as? T ?? fallback` is a T.
        if elements[1].is(UnresolvedAsExprSyntax.self) {
            guard allows(.cast), let type = elements[2].as(TypeExprSyntax.self),
                  elements.count == 3 || SwiftTypeInference.operatorText(elements[3]) == "??" else { return nil }
            return declaredType(type.type)
        }
        if elements[1].is(UnresolvedIsExprSyntax.self) {
            return allows(.operatorResult) && elements.count == 3 ? .named("Bool") : nil
        }
        // Past casts and checks, operators alternate with their operands.
        guard !operators.isEmpty, operators.count * 2 + 1 == elements.count else { return nil }
        if let ternaryIndex = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
           let ternary = elements[ternaryIndex].as(UnresolvedTernaryExprSyntax.self) {
            guard allows(.ternary) else { return nil }
            if let then = typeOf(ternary.thenExpression) { return then }
            return ternaryIndex + 2 == elements.count ? typeOf(elements[ternaryIndex + 1]) : nil
        }
        if operators.allSatisfy({ $0 == "??" }) {
            guard allows(.nilCoalescing) else { return nil }
            for (index, element) in elements.enumerated() where index % 2 == 0 {
                if let type = typeOf(element) { return type }
            }
            return nil
        }
        if allows(.range), elements.count == 3, let op = SwiftTypeInference.operatorText(elements[1]), op == "..<" || op == "..." {
            let bound = staticType(typeOf(elements[0])) ?? staticType(typeOf(elements[2]))
            return bound == "Int" ? .named("[Int]") : nil
        }
        // `a == b && c` is a Bool; `index - 1` and `total + item.cost` have their operands' type.
        guard allows(.operatorResult) else { return nil }
        if operators.contains(where: SwiftTypeInference.booleanOperators.contains) { return .named("Bool") }
        guard operators.allSatisfy(SwiftTypeInference.arithmeticOperators.contains) else { return nil }
        var shared: String?
        var floatLiteral = false
        for (index, element) in elements.enumerated() where index % 2 == 0 {
            // A number literal takes the type of the other operands.
            if element.is(IntegerLiteralExprSyntax.self) { continue }
            if element.is(FloatLiteralExprSyntax.self) { floatLiteral = true; continue }
            guard let type = staticType(typeOf(element)), shared == nil || shared == type else { return nil }
            shared = type
        }
        return .named(shared ?? (floatLiteral ? "Double" : "Int"))
    }

    /// A type written in expression position (`Book`, `Book.Chapter`, `[Book]`), as grammar text.
    private func writtenType(_ expression: ExprSyntax) -> String? {
        if let typeExpression = expression.as(TypeExprSyntax.self) {
            let text = normalizedType(typeExpression.type, [:])
            return text == "?" ? nil : text
        }
        if let chain = SwiftSyntaxSupport.typeChain(expression) { return chain.joined(separator: ".") }
        if let array = expression.as(ArrayExprSyntax.self), array.elements.count == 1, let only = array.elements.first {
            return writtenType(only.expression).map { "[" + $0 + "]" }
        }
        return nil
    }

    // MARK: Sequences and closures

    /// The type of one element of a sequence (`for x in seq`, `seq.map { x in }`), and of the two parts an
    /// element destructures into (`for (i, x) in seq.enumerated()`, `for (key, value) in table`, `zip(a, b)`).
    func elementTypes(of sequence: ExprSyntax) -> (single: TypeExpr?, pair: [TypeExpr?]?) {
        var sequence = SwiftTypeInference.unwrapped(sequence)
        // `Array(xs.enumerated())` iterates what it wraps.
        if let call = sequence.as(FunctionCallExprSyntax.self), call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Array",
           call.arguments.count == 1, let only = call.arguments.first, only.label == nil {
            sequence = SwiftTypeInference.unwrapped(only.expression)
        }
        if let call = sequence.as(FunctionCallExprSyntax.self) {
            if call.arguments.isEmpty, let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base,
               member.declName.baseName.text == "enumerated" {
                let element = elementTypes(of: base).single
                let tuple = staticType(element).map { TypeExpr.named("(offset: Int, element: " + $0 + ")") }
                return (tuple, [.named("Int"), element])
            }
            if call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "zip", call.arguments.count == 2 {
                return (nil, call.arguments.map { elementTypes(of: $0.expression).single })
            }
        }
        guard let type = typeOf(sequence) else { return (nil, nil) }
        if let text = staticType(type), let parts = SwiftTypeInference.dictionaryParts(text) {
            return (.named("(key: " + parts.key + ", value: " + parts.value + ")"), [.named(parts.key), .named(parts.value)])
        }
        return (.element(type), nil)
    }

    /// Types of a closure's parameters, by position, from the call it is passed to: the elements of the
    /// sequence a standard-library method walks, the rows of a SwiftUI `ForEach`/`List`/`Table`, or the value a
    /// SwiftUI modifier hands over (`.onChange(of:)`, `.sheet(item:)`). `parameters` is how many the closure
    /// declares, nil for `$0`-style closures (where an element that destructures is still one tuple).
    func closureParameterTypes(_ closure: ClosureExprSyntax, parameters: Int?) -> [TypeExpr?] {
        guard let (call, label) = SwiftTypeInference.call(passing: closure) else { return [] }
        let destructures = (parameters ?? 1) >= 2
        let callee = SwiftTypeInference.calleeName(call)
        if let callee, let known = SwiftTypeInference.knownClosureParameters[callee]?[label], allows(.knownClosure) {
            // `.onGeometryChange(for:of:action:)` passes the proxy to `of`, whichever way it is written.
            if callee != "onGeometryChange" || label != "" || !call.arguments.contains(where: { $0.label?.text == "of" }) {
                return known.map { .named($0) }
            }
        }
        if let callee, let value = SwiftTypeInference.valueClosures[callee], value.closures.contains(label) || callee == "onGeometryChange" && label == "",
           allows(.closureValue), let argument = call.arguments.first(where: { $0.label.map { value.arguments.contains($0.text) } ?? false }) {
            // `.onChange(of:)` hands over the old and the new value.
            return Array(repeating: closureValue(argument.expression), count: max(parameters ?? 2, 1))
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base {
            let name = member.declName.baseName.text
            if let shape = SwiftTypeInference.elementClosures[name], allows(.closureElement) {
                let elements = elementTypes(of: base)
                switch shape {
                case .element:
                    if destructures, let pair = elements.pair { return pair }
                    return [elements.single]
                case .pair:
                    return [elements.single, elements.single]
                case .accumulator:
                    let initial = call.arguments.first.flatMap { typeOf($0.expression) }
                    return [initial, elements.single]
                }
            }
            return []
        }
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
           SwiftTypeInference.dataViews.contains(reference.baseName.text), allows(.swiftUIData),
           let data = call.arguments.first(where: { $0.label == nil || $0.label?.text == "data" }) {
            let elements = elementTypes(of: data.expression)
            if destructures, let pair = elements.pair { return pair }
            return [elements.single]
        }
        return []
    }

    /// The root of a key path written without one (`\.name`): an element of the sequence a standard-library method
    /// or a SwiftUI `ForEach` walks (`books.map(\.name)`, `ForEach(items, id: \.id)`), or `EnvironmentValues` in
    /// `@Environment(\.dismiss)`.
    func keyPathRoot(_ keyPath: KeyPathExprSyntax) -> TypeExpr? {
        guard allows(.keyPathRoot), keyPath.root == nil, let argument = keyPath.parent?.as(LabeledExprSyntax.self) else { return nil }
        if let attribute = argument.parent?.parent?.as(AttributeSyntax.self) {
            return SwiftSyntaxSupport.attributeName(attribute) == "Environment" ? .named("EnvironmentValues") : nil
        }
        guard let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) else { return nil }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base,
           SwiftTypeInference.elementClosures[member.declName.baseName.text] != nil {
            return elementTypes(of: base).single
        }
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self), SwiftTypeInference.dataViews.contains(reference.baseName.text),
           let data = call.arguments.first(where: { $0.label == nil || $0.label?.text == "data" }), data.id != argument.id {
            return elementTypes(of: data.expression).single
        }
        return nil
    }

    /// The value a SwiftUI modifier hands to its closure: `of: value`, `item: $selection`, `for: Book.self`.
    private func closureValue(_ expression: ExprSyntax) -> TypeExpr? {
        if let member = expression.as(MemberAccessExprSyntax.self), member.declName.baseName.tokenKind == .keyword(.self),
           let base = member.base {
            return writtenType(base).map { .named($0) }
        }
        // `$selection` is the binding of `selection`; the closure gets `selection`'s value. The projected read's
        // reference names `selection`, so the linker types it as `selection`.
        if let reference = expression.as(DeclReferenceExprSyntax.self), reference.baseName.text.hasPrefix("$"),
           reference.baseName.text.dropFirst().first?.isLetter == true {
            if let binding = binding(for: String(reference.baseName.text.dropFirst())) { return binding.type }
            return .expr(reference.id, fallback: nil)
        }
        return typeOf(expression)
    }

    // MARK: Implicit members

    /// Where an implicit member is looked up: the contextual type of the implicit-member chain it starts
    /// (`.accentColor.opacity(0.5)`), from an annotation, a default argument, the other side of `==`/`=`, a
    /// `return`, a `case` pattern's subject, an option-set operation, an array literal, or a call argument.
    func implicitContext(of member: MemberAccessExprSyntax) -> ImplicitContext? {
        var top = Syntax(member)
        while let parent = top.parent {
            if let call = parent.as(FunctionCallExprSyntax.self), call.calledExpression.id == top.id {
                top = parent
            } else if parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self) {
                top = parent
            } else if allows(.contextChain), let outer = parent.as(MemberAccessExprSyntax.self), outer.base?.id == top.id {
                top = parent
            } else {
                break
            }
        }
        return context(of: top, depth: 0)
    }

    private func context(of expression: Syntax, depth: Int) -> ImplicitContext? {
        guard depth < 6 else { return nil }
        var node = expression
        // Parentheses, `try` and `await` do not change the context.
        while let parent = node.parent {
            if parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) {
                node = parent
            } else if let labeled = parent.as(LabeledExprSyntax.self), labeled.label == nil,
                      let tuple = labeled.parent?.parent?.as(TupleExprSyntax.self), tuple.elements.count == 1 {
                node = Syntax(tuple)
            } else {
                break
            }
        }
        guard let parent = node.parent else { return nil }
        if let labeled = parent.as(LabeledExprSyntax.self) {
            return argumentContext(labeled)
        }
        if let initializer = parent.as(InitializerClauseSyntax.self) {
            return initializerContext(initializer)
        }
        if let list = parent.as(ExprListSyntax.self), let sequence = list.parent?.as(SequenceExprSyntax.self) {
            return sequenceContext(node, in: sequence, depth: depth)
        }
        if let ternary = parent.as(UnresolvedTernaryExprSyntax.self), ternary.thenExpression.id == node.id,
           let sequence = ternary.parent?.parent?.as(SequenceExprSyntax.self) {
            return ternaryContext(sequence, depth: depth)
        }
        if parent.is(ReturnStmtSyntax.self) {
            guard allows(.contextReturn), let type = returnTypes.last?.type else { return nil }
            return .type(type)
        }
        if let item = parent.as(CodeBlockItemSyntax.self) {
            return implicitReturnContext(item)
        }
        if let element = parent.as(ArrayElementSyntax.self), let array = element.parent?.parent?.as(ArrayExprSyntax.self) {
            guard allows(.contextArrayElement), case .type(let type)? = context(of: Syntax(array), depth: depth + 1) else { return nil }
            return elementContext(type).map { .type($0) }
        }
        if parent.is(ExpressionPatternSyntax.self) {
            return patternContext(parent)
        }
        return nil
    }

    /// `f(style: .plain)` → parameter 0 of `f`; `flags.contains(.isPadding)` → the type of `flags`.
    private func argumentContext(_ argument: LabeledExprSyntax) -> ImplicitContext? {
        guard let list = argument.parent?.as(LabeledExprListSyntax.self), let call = list.parent?.as(FunctionCallExprSyntax.self) else { return nil }
        var position = 0
        for element in list {
            if element.id == argument.id { break }
            position += 1
        }
        if position == 0, let callee = call.calledExpression.as(MemberAccessExprSyntax.self), let base = callee.base,
           SwiftTypeInference.elementArgumentMethods.contains(callee.declName.baseName.text),
           argument.label == nil || ["of", "with", "contentsOf"].contains(argument.label?.text ?? ""), allows(.contextSetOperation) {
            // The linker looks an implicit member up in a collection context's element type.
            return typeOf(base).flatMap(elementContext).map { .type($0) }
        }
        guard allows(.contextArgument) else { return nil }
        return .argument(call: call.id, index: position)
    }

    /// `let tint: Color = .red`; `func f(style: Style = .plain)`.
    private func initializerContext(_ initializer: InitializerClauseSyntax) -> ImplicitContext? {
        if let binding = initializer.parent?.as(PatternBindingSyntax.self) {
            guard allows(.contextAnnotation), let annotation = binding.typeAnnotation else { return nil }
            return declaredType(annotation.type).map { .type($0) }
        }
        guard allows(.contextDefault) else { return nil }
        if let parameter = initializer.parent?.as(FunctionParameterSyntax.self) {
            return declaredType(parameter.type).map { .type($0) }
        }
        if let parameter = initializer.parent?.as(EnumCaseParameterSyntax.self) {
            return declaredType(parameter.type).map { .type($0) }
        }
        return nil
    }

    /// `state == .idle`, `.idle != state`, `mode = .edit`, `x ?? .fallback`, `c ? .a : .b`.
    private func sequenceContext(_ node: Syntax, in sequence: SequenceExprSyntax, depth: Int) -> ImplicitContext? {
        let elements = Array(sequence.elements)
        guard let index = elements.firstIndex(where: { $0.id == node.id }) else { return nil }
        func op(_ position: Int) -> String? {
            elements.indices.contains(position) ? SwiftTypeInference.operatorText(elements[position]) : nil
        }
        // An operand ends where an operator looser than the comparison (or the sequence) does.
        func bounded(_ position: Int, before: Bool) -> Bool {
            let neighbour = before ? position - 1 : position + 1
            guard elements.indices.contains(neighbour) else { return true }
            return op(neighbour).map(SwiftTypeInference.looserThanComparison.contains) ?? false
        }
        func typed(_ position: Int) -> ImplicitContext? {
            // `.a == .b`: an implicit member cannot give the other one its context.
            let operand = SwiftTypeInference.unwrapped(elements[position])
            if let root = SwiftSyntaxSupport.leadingMember(of: operand), root.base == nil { return nil }
            return typeOf(operand).map { .type($0) }
        }
        if index == 2, op(1) == "=" {
            return allows(.contextAssignment) ? typed(0) : nil
        }
        if index >= 2, let left = op(index - 1), SwiftTypeInference.comparisons.contains(left), bounded(index - 2, before: true) {
            return allows(.contextComparison) ? typed(index - 2) : nil
        }
        if index + 2 < elements.count, let right = op(index + 1), SwiftTypeInference.comparisons.contains(right),
           bounded(index, before: true), bounded(index + 2, before: false) {
            return allows(.contextComparison) ? typed(index + 2) : nil
        }
        if index >= 2, op(index - 1) == "??" {
            return allows(.nilCoalescing) ? typed(index - 2) : nil
        }
        if index >= 1, op(index - 1) == "?:" {
            return ternaryContext(sequence, depth: depth)
        }
        return nil
    }

    /// A branch of `c ? .a : .b` has the context of the whole conditional (`x = c ? .a : .b` → `x`).
    private func ternaryContext(_ sequence: SequenceExprSyntax, depth: Int) -> ImplicitContext? {
        guard allows(.contextTernary) else { return nil }
        let elements = Array(sequence.elements)
        if elements.count >= 2, SwiftTypeInference.operatorText(elements[1]) == "=" {
            return typeOf(elements[0]).map { .type($0) }
        }
        return context(of: Syntax(sequence), depth: depth + 1)
    }

    /// The single expression of a body with a return type is what it returns: `var tint: Color { .red }`.
    private func implicitReturnContext(_ item: CodeBlockItemSyntax) -> ImplicitContext? {
        guard allows(.contextReturn), let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
              let current = returnTypes.last, let type = current.type, let owner = list.parent else { return nil }
        var body = owner
        if body.is(CodeBlockSyntax.self), let declaration = body.parent {
            body = declaration
            // `get { .red }`: the accessor block owns the return type.
            if body.is(AccessorDeclSyntax.self), let block = body.parent?.parent { body = block }
        }
        return body.id == current.node ? .type(type) : nil
    }

    /// `case .loaded(let x):` in a `switch subject`, `if case .failed = state`, `for case .data in records`.
    private func patternContext(_ pattern: Syntax) -> ImplicitContext? {
        guard allows(.contextPattern) else { return nil }
        var node = pattern
        if let binding = node.parent?.as(ValueBindingPatternSyntax.self) { node = Syntax(binding) }
        guard let parent = node.parent else { return nil }
        if parent.is(SwitchCaseItemSyntax.self) {
            guard let switchCase = parent.parent?.parent?.parent?.as(SwitchCaseSyntax.self),
                  let statement = SwiftSyntaxSupport.switchStatement(of: switchCase) else { return nil }
            return typeOf(statement.subject).map { .type($0) }
        }
        if let condition = parent.as(MatchingPatternConditionSyntax.self) {
            return typeOf(condition.initializer.value).map { .type($0) }
        }
        if let loop = parent.as(ForStmtSyntax.self) {
            return typeOf(loop.sequence).flatMap(elementContext).map { .type($0) }
        }
        return nil
    }

    /// The context for an element of a collection-typed context: `[T]` → `T`. An option set (`[.a, .b]` of a
    /// `WALFlags`) and a type only the linker knows stay as they are; the linker looks an implicit member up in
    /// the element type of a collection.
    private func elementContext(_ type: TypeExpr) -> TypeExpr? {
        switch type {
        case .named(let name):
            if SwiftTypeInference.dictionaryParts(name) != nil { return nil }
            if name.hasPrefix("[") { return SwiftTypeInference.element(of: name).map { .named($0) } }
            return type
        case .expr, .ref:
            return type
        case .element:
            return nil
        }
    }

    // MARK: Writing the grammar

    /// A type in the hint grammar, once every reference is known; nil when it cannot be written.
    func hint(for type: TypeExpr) -> TypeHint? {
        switch type {
        case .named(let name):
            return name == "?" ? nil : TypeHint(text: name, ref: nil)
        case .ref(let index):
            return TypeHint(text: "^", ref: index)
        case .expr(let node, let fallback):
            if let index = producers[node] { return TypeHint(text: "^", ref: index) }
            return fallback.map { TypeHint(text: $0, ref: nil) }
        case .element(let inner):
            guard let sequence = hint(for: inner) else { return nil }
            if let index = sequence.ref {
                return sequence.text == "^" ? TypeHint(text: "elem(^)", ref: index) : nil
            }
            if let element = SwiftTypeInference.element(of: sequence.text) { return TypeHint(text: element, ref: nil) }
            guard SwiftTypeInference.isNominal(sequence.text) else { return nil }
            return TypeHint(text: "elem(" + sequence.text + ")", ref: nil)
        }
    }
}

extension SwiftTypeInference {
    /// The call a closure is passed to, and the label it is passed under (`""` for the first trailing closure or
    /// an unlabeled argument).
    static func call(passing closure: ClosureExprSyntax) -> (call: FunctionCallExprSyntax, label: String)? {
        guard let parent = closure.parent else { return nil }
        if let call = parent.as(FunctionCallExprSyntax.self), call.trailingClosure?.id == closure.id { return (call, "") }
        if let argument = parent.as(LabeledExprSyntax.self), let call = parent.parent?.parent?.as(FunctionCallExprSyntax.self) {
            return (call, argument.label?.text ?? "")
        }
        if let element = parent.as(MultipleTrailingClosureElementSyntax.self), let call = parent.parent?.parent?.as(FunctionCallExprSyntax.self) {
            return (call, element.label.text)
        }
        return nil
    }

    /// The name a call is made through: `Foo` in `Foo(…)`, `bar` in `x.bar(…)` and `.bar(…)`.
    static func calleeName(_ call: FunctionCallExprSyntax) -> String? {
        var callee = call.calledExpression
        if let specialized = callee.as(GenericSpecializationExprSyntax.self) { callee = specialized.expression }
        if let reference = callee.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
        if let member = callee.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        return nil
    }
}
