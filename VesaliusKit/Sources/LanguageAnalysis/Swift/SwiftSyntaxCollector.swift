import Foundation
import SwiftSyntax
import VesaliusCore

/// Single-pass visitor that extracts symbols, imports, references and complexity from a Swift syntax tree.
///
/// Context is tracked with stacks keyed by the syntax node that opened them, so `leave(_:)` in
/// `visitPost` can unwind exactly what a node pushed:
/// - `openSymbols`: emitted symbols whose extent we are inside (→ `enclosingSymbol`).
/// - `containers`: emitted types/extensions (→ `parentLocalID`, member-ness, inherited member visibility).
/// - `scopes`: parameters/locals/generic parameters with what is known of their types. Unqualified
///   references to them are not reported; member references on them carry the type.
/// - `bodyOwners`: function/closure/accessor bodies; declarations inside them are locals, not symbols. A
///   function-local type sets them aside while its members are visited (`savedBodyOwners`).
/// - `frames`: complexity accumulators for emitted symbols.
/// - `statements`: the innermost statement or member declaration (→ a reference's statement span).
/// - `returnTypes`: what the innermost function, accessor or closure returns (→ `return .value` contexts).
/// `conditions` holds the `#if` clauses around the walk; each clause pushes and pops its own around its contents.
///
/// Receiver types are decided during the walk but written afterwards (`finishTypes`): a member reference is
/// emitted before its base, so "the reference that produces this value" (`producers`) is only complete then.
/// The inference rules themselves live in SwiftTypeInference.swift.
///
/// String literals are recorded with where their value goes, and environment variables and launch arguments
/// become `env:NAME` / `env:arg:VALUE` references. Whether a local holds an environment is often clear only
/// after its uses (`env["X"] = "1"` … `app.launchEnvironment = env`), so uses on locals wait for
/// `finishEnvironment`. The vocabularies live in SwiftLiterals.swift.
final class SwiftSyntaxCollector: SyntaxVisitor {
    private struct OpenSymbol {
        let node: SyntaxIdentifier
        let localID: Int
    }

    private struct Container {
        let node: SyntaxIdentifier
        let localID: Int
        let kind: SymbolKind
        /// Access level members inherit when they declare none (public extensions/protocols, enums for cases).
        let memberVisibility: Visibility?
        /// A function-local type, or a type nested in one: its members are local too.
        let isLocal: Bool
    }

    private struct Scope {
        let owner: SyntaxIdentifier?
        var bindings: [String: LocalBinding]
        /// Generic parameters declared here, mapped to the type that stands for them in parameter types.
        var generics: [String: String] = [:]
    }

    private struct ComplexityFrame {
        let node: SyntaxIdentifier
        let localID: Int
        var decisions: Int
    }

    /// Lines of the innermost statement; for a compound statement or a declaration with a body, its header.
    private struct Statement {
        let node: SyntaxIdentifier
        let start: Int
        let end: Int
    }

    /// What a call site passes: argument labels, and the line its argument list ends on.
    private struct CallShape {
        let labels: [String]
        let endLine: Int
    }

    /// What a callable declares: its selector, one flag per parameter and the parameters' types.
    private struct CallableShape {
        let selector: String
        let flags: String
        let types: [String]
    }

    /// A name that may hold environment variables or launch arguments: a local or parameter (the scope that
    /// binds it), or a property or global of this file (no scope).
    private struct Holder: Hashable {
        let scope: SyntaxIdentifier?
        let name: String
    }

    /// What an expression holds: the process environment or a launch environment, launch arguments, or whatever a
    /// local or property holds.
    private enum EnvironmentSource {
        case environment
        case arguments
        case holder(Holder)
    }

    /// An `env:` reference on a holder, emitted if the holder turns out to hold what it needs.
    private struct PendingEnvironment {
        let holder: Holder
        let isArguments: Bool
        let reference: ExtractedReference
    }

    private let converter: SourceLocationConverter
    private let source: [UInt8]

    private(set) var symbols: [ExtractedSymbol] = []
    private(set) var imports: [ExtractedImport] = []
    private(set) var references: [ExtractedReference] = []
    private(set) var literals: [ExtractedLiteral] = []
    private(set) var decisionCount = 0
    private(set) var hasMainAttribute = false

    private var openSymbols: [OpenSymbol] = []
    private var containers: [Container] = []
    private var scopes: [Scope] = [Scope(owner: nil, bindings: [:])]
    private var bodyOwners: [SyntaxIdentifier] = []
    private var savedBodyOwners: [(node: SyntaxIdentifier, owners: [SyntaxIdentifier])] = []
    private var frames: [ComplexityFrame] = []
    private var statements: [Statement] = []
    private var conditions: [String] = []
    /// Depth of `case` patterns being visited: implicit members inside them match enum cases.
    private var patternDepth = 0
    /// Symbols of multi-binding variables / multi-element enum cases, opened when their own node is visited.
    private var pendingSymbols: [SyntaxIdentifier: Int] = [:]
    private var writeTargets = Set<SyntaxIdentifier>()
    private var handledTypes = Set<SyntaxIdentifier>()
    private var handledExpressions = Set<SyntaxIdentifier>()
    /// Base-less member accesses that continue a postfix `#if` (`Text(…)` `#if os(iOS)` `.padding()` `#endif`).
    private var postfixConfigMembers = Set<SyntaxIdentifier>()

    // Type-inference state, shared with SwiftTypeInference.swift.
    let disabledRules: Set<SwiftTypeInference.Rule>
    /// The reference whose value an expression is: an identifier's or member's own reference, and for a call, the
    /// callee's.
    var producers: [SyntaxIdentifier: Int] = [:]
    var typeMemo: [SyntaxIdentifier: TypeExpr?] = [:]
    var returnTypes: [(node: SyntaxIdentifier, type: TypeExpr?)] = []
    private var receiverNotes: [(reference: Int, note: ReceiverNote)] = []
    private var declaredTypes: [(symbol: Int, type: TypeExpr)] = []

    // Environment state: what holders are known to hold, which holders exchange values (`var env = lastEnvironment`,
    // `env.merge(environment)`), and the uses waiting on them.
    private var environmentHolders = Set<Holder>()
    private var argumentHolders = Set<Holder>()
    private var processInfoHolders = Set<Holder>()
    private var holderFlows: [(Holder, Holder)] = []
    private var pendingEnvironment: [PendingEnvironment] = []

    init(converter: SourceLocationConverter, source: [UInt8], disabledRules: Set<SwiftTypeInference.Rule> = SwiftTypeInference.disabledRules) {
        self.converter = converter
        self.source = source
        self.disabledRules = disabledRules
        super.init(viewMode: .sourceAccurate)
    }

    private var isInsideBody: Bool { !bodyOwners.isEmpty }
    private var inheritedMemberVisibility: Visibility? { containers.last?.memberVisibility }

    // MARK: - Type declarations

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node, name: SwiftSyntaxSupport.identifierText(node.name), kind: .class, attributes: node.attributes, modifiers: node.modifiers,
                  keyword: node.classKeyword, generics: node.genericParameterClause, inheritance: node.inheritanceClause,
                  headerEnd: node.memberBlock.position, firstInheritedIsSuperclass: true)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { leave(node.id) }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node, name: SwiftSyntaxSupport.identifierText(node.name), kind: .struct, attributes: node.attributes, modifiers: node.modifiers,
                  keyword: node.structKeyword, generics: node.genericParameterClause, inheritance: node.inheritanceClause,
                  headerEnd: node.memberBlock.position, firstInheritedIsSuperclass: false)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { leave(node.id) }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node, name: SwiftSyntaxSupport.identifierText(node.name), kind: .enum, attributes: node.attributes, modifiers: node.modifiers,
                  keyword: node.enumKeyword, generics: node.genericParameterClause, inheritance: node.inheritanceClause,
                  headerEnd: node.memberBlock.position, firstInheritedIsSuperclass: false)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { leave(node.id) }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node, name: SwiftSyntaxSupport.identifierText(node.name), kind: .protocol, attributes: node.attributes, modifiers: node.modifiers,
                  keyword: node.protocolKeyword, generics: nil, inheritance: node.inheritanceClause,
                  headerEnd: node.memberBlock.position, firstInheritedIsSuperclass: false)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) { leave(node.id) }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node, name: SwiftSyntaxSupport.identifierText(node.name), kind: .actor, attributes: node.attributes, modifiers: node.modifiers,
                  keyword: node.actorKeyword, generics: node.genericParameterClause, inheritance: node.inheritanceClause,
                  headerEnd: node.memberBlock.position, firstInheritedIsSuperclass: false)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { leave(node.id) }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = SwiftSyntaxSupport.typeName(node.extendedType) ?? node.extendedType.trimmedDescription
        enterType(node, name: name, kind: .extension, attributes: node.attributes, modifiers: node.modifiers,
                  keyword: node.extensionKeyword, generics: nil, inheritance: node.inheritanceClause,
                  headerEnd: node.memberBlock.position, firstInheritedIsSuperclass: false)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { leave(node.id) }

    private func enterType(
        _ node: some DeclSyntaxProtocol,
        name: String,
        kind: SymbolKind,
        attributes: AttributeListSyntax,
        modifiers: DeclModifierListSyntax,
        keyword: TokenSyntax,
        generics: GenericParameterClauseSyntax?,
        inheritance: InheritanceClauseSyntax?,
        headerEnd: AbsolutePosition,
        firstInheritedIsSuperclass: Bool
    ) {
        let attributeNames = SwiftSyntaxSupport.attributeNames(attributes)
        if attributeNames.contains(where: { $0 == "@main" || $0 == "@UIApplicationMain" || $0 == "@NSApplicationMain" }) {
            hasMainAttribute = true
        }
        let genericNames = SwiftSyntaxSupport.genericParameterNames(generics)

        // A type declared in a function body is a symbol visible only inside that function. Its name also
        // shadows outer declarations for the rest of the block.
        let isLocal = isInsideBody
        if isLocal { bind(name, LocalBinding(type: nil, line: line(node.positionAfterSkippingLeadingTrivia), kind: .type)) }

        let explicitVisibility = SwiftSyntaxSupport.visibility(modifiers)
        let visibility = isLocal ? explicitVisibility : explicitVisibility ?? inheritedMemberVisibility
        let localID = addSymbol(
            name: name,
            kind: kind,
            range: lineRange(of: node),
            signature: signature(attributes: attributes, from: headerStart(modifiers, keyword), to: headerEnd),
            doc: SwiftSyntaxSupport.docComment(node.leadingTrivia),
            visibility: visibility,
            attributes: attributeNames + SwiftSyntaxSupport.notableModifierNames(modifiers),
            inheritedTypes: SwiftSyntaxSupport.inheritedTypeNames(inheritance),
            isLocal: isLocal
        )
        let memberVisibility: Visibility?
        switch kind {
        case .extension: memberVisibility = explicitVisibility
        case .protocol: memberVisibility = visibility
        default: memberVisibility = nil
        }
        openSymbol(node.id, localID)
        containers.append(Container(node: node.id, localID: localID, kind: kind, memberVisibility: memberVisibility,
                                    isLocal: symbols[localID].isLocal))
        frames.append(ComplexityFrame(node: node.id, localID: localID, decisions: 0))
        if isLocal {
            // The members of a local type are symbols: set the function bodies aside until the type is left.
            savedBodyOwners.append((node.id, bodyOwners))
            bodyOwners = []
        }
        pushScope(node.id, typeBindings(genericNames, at: keyword.positionAfterSkippingLeadingTrivia),
                  generics: SwiftSyntaxSupport.genericConstraints(generics))
        emitInheritance(inheritance, firstIsSuperclass: firstInheritedIsSuperclass)
    }

    /// Emits `.inherit`/`.conform` references for an inheritance clause and marks those type nodes so the
    /// generic type visitor does not report them again as plain type uses.
    private func emitInheritance(_ clause: InheritanceClauseSyntax?, firstIsSuperclass: Bool) {
        guard let clause else { return }
        for (index, inherited) in clause.inheritedTypes.enumerated() {
            let kind: ReferenceKind = firstIsSuperclass && index == 0 ? .inherit : .conform
            for type in SwiftSyntaxSupport.nominalTypes(in: inherited.type) {
                if let identifier = type.as(IdentifierTypeSyntax.self) {
                    handledTypes.insert(identifier.id)
                    if SwiftSyntaxSupport.isReferenceToken(identifier.name) {
                        emit(SwiftSyntaxSupport.identifierText(identifier.name), kind: kind, at: identifier.name, receiver: nil, context: .type)
                    }
                } else if let member = type.as(MemberTypeSyntax.self) {
                    handledTypes.insert(member.id)
                    if SwiftSyntaxSupport.isReferenceToken(member.name) {
                        emit(SwiftSyntaxSupport.identifierText(member.name), kind: kind, at: member.name,
                             receiver: SwiftSyntaxSupport.typeName(member.baseType) ?? "_", context: .type)
                    }
                }
            }
        }
    }

    // MARK: - Callable declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = SwiftSyntaxSupport.identifierText(node.name)
        let generics = SwiftSyntaxSupport.genericConstraints(node.genericParameterClause, node.genericWhereClause)
        let bindings = callableBindings(node.genericParameterClause, node.signature.parameterClause.parameters, generics: generics)
        // What the function returns, tuple labels kept (`(label: String, reason: String)`).
        let returnType = node.signature.returnClause.flatMap { declaredType($0.type, generics: generics) }
        if isInsideBody {
            bind(name, LocalBinding(type: returnType, line: line(node.positionAfterSkippingLeadingTrivia), kind: .function))
        } else {
            var attributes = SwiftSyntaxSupport.attributeNames(node.attributes)
                + SwiftSyntaxSupport.notableModifierNames(node.modifiers)
                + SwiftSyntaxSupport.effects(node.signature.effectSpecifiers)
            if !SwiftSyntaxSupport.isIdentifierLike(name) { attributes.append("operator") }
            let localID = addSymbol(
                name: name,
                kind: containers.isEmpty ? .function : .method,
                range: lineRange(of: node),
                signature: signature(attributes: node.attributes, from: headerStart(node.modifiers, node.funcKeyword),
                                     to: node.body?.position ?? node.endPositionBeforeTrailingTrivia),
                doc: SwiftSyntaxSupport.docComment(node.leadingTrivia),
                visibility: SwiftSyntaxSupport.visibility(node.modifiers) ?? inheritedMemberVisibility,
                attributes: attributes,
                bodyHash: bodyHash(node.body),
                shape: callableShape(name, node.signature.parameterClause.parameters, generics: generics),
                declaredType: allows(.returnType) ? returnType : nil
            )
            openSymbol(node.id, localID)
            frames.append(ComplexityFrame(node: node.id, localID: localID, decisions: 0))
        }
        pushScope(node.id, bindings, generics: generics)
        noteEnvironmentParameters(node.signature.parameterClause.parameters, scope: node.id)
        returnTypes.append((node.id, returnType))
        bodyOwners.append(node.id)
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) { leave(node.id) }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let generics = SwiftSyntaxSupport.genericConstraints(node.genericParameterClause, node.genericWhereClause)
        let bindings = callableBindings(node.genericParameterClause, node.signature.parameterClause.parameters, generics: generics)
        if !isInsideBody {
            let attributes = SwiftSyntaxSupport.attributeNames(node.attributes)
                + SwiftSyntaxSupport.notableModifierNames(node.modifiers)
                + SwiftSyntaxSupport.effects(node.signature.effectSpecifiers)
            let localID = addSymbol(
                name: "init",
                kind: .initializer,
                range: lineRange(of: node),
                signature: signature(attributes: node.attributes, from: headerStart(node.modifiers, node.initKeyword),
                                     to: node.body?.position ?? node.endPositionBeforeTrailingTrivia),
                doc: SwiftSyntaxSupport.docComment(node.leadingTrivia),
                visibility: SwiftSyntaxSupport.visibility(node.modifiers) ?? inheritedMemberVisibility,
                attributes: attributes,
                bodyHash: bodyHash(node.body),
                shape: callableShape("init", node.signature.parameterClause.parameters, generics: generics),
                // An initializer produces its owner.
                declaredType: allows(.ownerType) ? enclosingTypeName.map { .named($0) } : nil
            )
            openSymbol(node.id, localID)
            frames.append(ComplexityFrame(node: node.id, localID: localID, decisions: 0))
        }
        pushScope(node.id, bindings, generics: generics)
        noteEnvironmentParameters(node.signature.parameterClause.parameters, scope: node.id)
        returnTypes.append((node.id, nil))
        bodyOwners.append(node.id)
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) { leave(node.id) }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushScope(node.id, [:])
        returnTypes.append((node.id, nil))
        bodyOwners.append(node.id)
        return .visitChildren
    }

    override func visitPost(_ node: DeinitializerDeclSyntax) { leave(node.id) }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let generics = SwiftSyntaxSupport.genericConstraints(node.genericParameterClause, node.genericWhereClause)
        let bindings = callableBindings(node.genericParameterClause, node.parameterClause.parameters, generics: generics)
        if !isInsideBody {
            let localID = addSymbol(
                name: "subscript",
                kind: .method,
                range: lineRange(of: node),
                signature: signature(attributes: node.attributes, from: headerStart(node.modifiers, node.subscriptKeyword),
                                     to: node.accessorBlock?.position ?? node.endPositionBeforeTrailingTrivia),
                doc: SwiftSyntaxSupport.docComment(node.leadingTrivia),
                visibility: SwiftSyntaxSupport.visibility(node.modifiers) ?? inheritedMemberVisibility,
                attributes: SwiftSyntaxSupport.attributeNames(node.attributes) + SwiftSyntaxSupport.notableModifierNames(node.modifiers),
                shape: callableShape("subscript", node.parameterClause.parameters, generics: generics, isSubscript: true),
                declaredType: allows(.returnType) ? declaredType(node.returnClause.type, generics: generics) : nil
            )
            openSymbol(node.id, localID)
            frames.append(ComplexityFrame(node: node.id, localID: localID, decisions: 0))
        }
        // The accessor block records what the subscript returns.
        pushScope(node.id, bindings, generics: generics)
        bodyOwners.append(node.id)
        return .visitChildren
    }

    override func visitPost(_ node: SubscriptDeclSyntax) { leave(node.id) }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = SwiftSyntaxSupport.identifierText(node.name)
        let bindings = callableBindings(node.genericParameterClause, node.signature.parameterClause.parameters, generics: [:])
        if !isInsideBody {
            let localID = addSymbol(
                name: name,
                kind: .macro,
                range: lineRange(of: node),
                signature: signature(from: headerStart(node.modifiers, node.macroKeyword), to: node.endPositionBeforeTrailingTrivia),
                doc: SwiftSyntaxSupport.docComment(node.leadingTrivia),
                visibility: SwiftSyntaxSupport.visibility(node.modifiers) ?? inheritedMemberVisibility,
                attributes: SwiftSyntaxSupport.attributeNames(node.attributes) + SwiftSyntaxSupport.notableModifierNames(node.modifiers)
            )
            openSymbol(node.id, localID)
        }
        pushScope(node.id, bindings)
        bodyOwners.append(node.id)
        return .visitChildren
    }

    override func visitPost(_ node: MacroDeclSyntax) { leave(node.id) }

    /// A callable's generic parameters (types) and parameters, typed from their annotations:
    /// `store: Store`, `items: Item...` → `[Item]`, `T: Store` → `Store`, `some EmbeddingProvider` →
    /// `EmbeddingProvider`.
    private func callableBindings(_ genericClause: GenericParameterClauseSyntax?, _ parameters: FunctionParameterListSyntax,
                                  generics: [String: String]) -> [String: LocalBinding] {
        var bindings = typeBindings(SwiftSyntaxSupport.genericParameterNames(genericClause),
                                    at: genericClause?.positionAfterSkippingLeadingTrivia ?? parameters.positionAfterSkippingLeadingTrivia)
        for parameter in parameters {
            let token = parameter.secondName ?? parameter.firstName
            guard SwiftSyntaxSupport.isReferenceToken(token) else { continue }
            var type: TypeExpr?
            if allows(.parameter), let written = declaredType(parameter.type, generics: generics), case .named(let text) = written {
                type = .named(parameter.ellipsis == nil ? text : "[" + text + "]")
            }
            bindings[SwiftSyntaxSupport.identifierText(token)] = LocalBinding(type: type, line: line(parameter.positionAfterSkippingLeadingTrivia))
        }
        return bindings
    }

    /// Generic parameters and local type names: in scope as types, never reported as references.
    private func typeBindings(_ names: Set<String>, at position: AbsolutePosition) -> [String: LocalBinding] {
        let line = line(position)
        var bindings: [String: LocalBinding] = [:]
        for name in names { bindings[name] = LocalBinding(type: nil, line: line, kind: .type) }
        return bindings
    }

    /// The selector (`importBook(from:preferences:modelContext:)`), parameter flags and parameter types of a
    /// function, initializer or subscript. A subscript parameter has an argument label only when it is
    /// written with two names (`subscript(key k: String)`); an operator's arguments never have one.
    private func callableShape(_ name: String, _ parameters: FunctionParameterListSyntax, generics: [String: String], isSubscript: Bool = false) -> CallableShape {
        let isOperator = !SwiftSyntaxSupport.isIdentifierLike(name)
        var labels = ""
        var flags = ""
        var types: [String] = []
        for parameter in parameters {
            let unlabeled = isOperator || (isSubscript && parameter.secondName == nil)
            let label = unlabeled ? "_" : SwiftSyntaxSupport.argumentLabel(parameter.firstName)
            labels += label + ":"
            flags.append(SwiftSyntaxSupport.parameterFlag(type: parameter.type, isVariadic: parameter.ellipsis != nil,
                                                          hasDefault: parameter.defaultValue != nil))
            // A variadic parameter's arguments each have the element type.
            types.append(normalizedType(parameter.type, generics))
        }
        return CallableShape(selector: name + "(" + labels + ")", flags: flags, types: types)
    }

    /// A written type in the hint grammar; generic parameters become their constraint and `Self` the enclosing type.
    func normalizedType(_ type: TypeSyntax, _ generics: [String: String] = [:]) -> String {
        SwiftSyntaxSupport.normalizedType(type) { name in
            if let constraint = generics[name] { return constraint }
            for scope in scopes.reversed() {
                if let constraint = scope.generics[name] { return constraint }
            }
            return name == "Self" ? self.enclosingTypeName : nil
        }
    }

    // MARK: - Type aliases

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = SwiftSyntaxSupport.identifierText(node.name)
        let genericNames = SwiftSyntaxSupport.genericParameterNames(node.genericParameterClause)
        if isInsideBody {
            bind(name, LocalBinding(type: nil, line: line(node.positionAfterSkippingLeadingTrivia), kind: .type))
        } else {
            let localID = addSymbol(
                name: name,
                kind: .typeAlias,
                range: lineRange(of: node),
                signature: signature(from: headerStart(node.modifiers, node.typealiasKeyword), to: node.endPositionBeforeTrailingTrivia),
                doc: SwiftSyntaxSupport.docComment(node.leadingTrivia),
                visibility: SwiftSyntaxSupport.visibility(node.modifiers) ?? inheritedMemberVisibility,
                attributes: SwiftSyntaxSupport.attributeNames(node.attributes) + SwiftSyntaxSupport.notableModifierNames(node.modifiers)
            )
            openSymbol(node.id, localID)
        }
        pushScope(node.id, typeBindings(genericNames, at: node.positionAfterSkippingLeadingTrivia))
        return .visitChildren
    }

    override func visitPost(_ node: TypeAliasDeclSyntax) { leave(node.id) }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isInsideBody else { return .visitChildren }
        let localID = addSymbol(
            name: SwiftSyntaxSupport.identifierText(node.name),
            kind: .typeAlias,
            range: lineRange(of: node),
            signature: signature(from: headerStart(node.modifiers, node.associatedtypeKeyword), to: node.endPositionBeforeTrailingTrivia),
            doc: SwiftSyntaxSupport.docComment(node.leadingTrivia),
            visibility: SwiftSyntaxSupport.visibility(node.modifiers) ?? inheritedMemberVisibility,
            attributes: SwiftSyntaxSupport.attributeNames(node.attributes) + SwiftSyntaxSupport.notableModifierNames(node.modifiers),
            inheritedTypes: SwiftSyntaxSupport.inheritedTypeNames(node.inheritanceClause)
        )
        openSymbol(node.id, localID)
        return .visitChildren
    }

    override func visitPost(_ node: AssociatedTypeDeclSyntax) { leave(node.id) }

    // MARK: - Variables and enum cases

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isInsideBody else {
            noteEnvironmentBindings(node)
            return .visitChildren
        }
        let isMember = !containers.isEmpty
        let isLet = node.bindingSpecifier.tokenKind == .keyword(.let)
        let kind: SymbolKind = isMember ? .property : (isLet ? .constant : .variable)
        let attributes = SwiftSyntaxSupport.attributeNames(node.attributes) + SwiftSyntaxSupport.notableModifierNames(node.modifiers)
        let visibility = SwiftSyntaxSupport.visibility(node.modifiers) ?? inheritedMemberVisibility
        let setterVisibility = SwiftSyntaxSupport.setterVisibility(node.modifiers)
        let doc = SwiftSyntaxSupport.docComment(node.leadingTrivia)
        let startLine = line(node.positionAfterSkippingLeadingTrivia)
        let attributeText = SwiftSyntaxSupport.signatureAttributes(node.attributes)
        let modifierText = node.modifiers.isEmpty
            ? ""
            : text(from: node.modifiers.positionAfterSkippingLeadingTrivia, to: node.modifiers.endPositionBeforeTrailingTrivia) + " "

        var emitted: [(node: SyntaxIdentifier, localID: Int)] = []
        let bindings = Array(node.bindings)
        for (position, binding) in bindings.enumerated() {
            let names = SwiftSyntaxSupport.patternNames(binding.pattern)
            guard !names.isEmpty else { continue }
            var header = (attributeText.isEmpty ? "" : attributeText + " ")
                + modifierText + node.bindingSpecifier.text + " " + binding.pattern.trimmedDescription
            if let annotation = binding.typeAnnotation {
                header += annotation.trimmedDescription
            }
            if let value = binding.initializer?.value {
                // Short initializers carry the value (`= 4096`, `= false`), annotated or not.
                let valueText = value.trimmedDescription
                if valueText.count <= 60 { header += " = " + valueText }
            }
            let signature = header.compactSignature()
            let range = LineRange(startLine, line(binding.endPositionBeforeTrailingTrivia))
            let type = names.count == 1 && allows(.propertyType)
                ? propertyType(binding, attributes: node.attributes, sharedAnnotation: Self.sharedAnnotation(bindings, from: position))
                : nil
            for name in names {
                let localID = addSymbol(name: name, kind: kind, range: range, signature: signature, doc: doc,
                                        visibility: visibility, attributes: attributes, setterVisibility: setterVisibility,
                                        declaredType: type)
                emitted.append((binding.id, localID))
            }
        }
        if emitted.count == 1, let only = emitted.first {
            openSymbol(node.id, only.localID)
            frames.append(ComplexityFrame(node: node.id, localID: only.localID, decisions: 0))
        } else {
            for entry in emitted where pendingSymbols[entry.node] == nil {
                pendingSymbols[entry.node] = entry.localID
            }
        }
        noteEnvironmentBindings(node)
        return .visitChildren
    }

    override func visitPost(_ node: VariableDeclSyntax) {
        if isInsideBody {
            // Local bindings become visible after their initializers have been visited.
            let bindings = Array(node.bindings)
            for (position, binding) in bindings.enumerated() {
                bindLocal(binding, sharedAnnotation: Self.sharedAnnotation(bindings, from: position))
            }
        }
        leave(node.id)
    }

    /// `var a, b: Int`: a binding with neither annotation nor initializer has the type annotated after it.
    private static func sharedAnnotation(_ bindings: [PatternBindingSyntax], from position: Int) -> TypeSyntax? {
        guard bindings[position].typeAnnotation == nil, bindings[position].initializer == nil else { return nil }
        for binding in bindings[(position + 1)...] {
            if let annotation = binding.typeAnnotation { return annotation.type }
            if binding.initializer != nil { return nil }
        }
        return nil
    }

    /// What a property holds: its annotation (for a property wrapper, the wrapped value's type), the type an
    /// `@Environment` attribute names, or its initializer's type (`= PremiumStore.shared` → `^`).
    private func propertyType(_ binding: PatternBindingSyntax, attributes: AttributeListSyntax, sharedAnnotation: TypeSyntax?) -> TypeExpr? {
        if let annotation = binding.typeAnnotation?.type ?? sharedAnnotation {
            return declaredType(annotation)
        }
        if let environment = environmentType(attributes) { return environment }
        return binding.initializer.flatMap { typeOf($0.value) }
    }

    /// `@Environment(Store.self)` → `Store`; `@Environment(\.modelContext)` → `ModelContext` (SwiftUI's values).
    private func environmentType(_ attributes: AttributeListSyntax) -> TypeExpr? {
        for element in attributes {
            guard case .attribute(let attribute) = element, SwiftSyntaxSupport.attributeName(attribute) == "Environment",
                  case .argumentList(let arguments)? = attribute.arguments, let argument = arguments.first?.expression else { continue }
            guard allows(.environmentValue) else { return nil }
            if let member = argument.as(MemberAccessExprSyntax.self), member.declName.baseName.tokenKind == .keyword(.self),
               let base = member.base, let chain = SwiftSyntaxSupport.typeChain(base) {
                return .named(chain.joined(separator: "."))
            }
            if let keyPath = argument.as(KeyPathExprSyntax.self), keyPath.root == nil, keyPath.components.count == 1,
               case .property(let property)? = keyPath.components.first?.component,
               let type = SwiftTypeInference.environmentValues[property.declName.baseName.text] {
                return .named(type)
            }
            return nil
        }
        return nil
    }

    /// A local declaration's names, typed: `let x: T`, `let x = <expr>`, `let (a, b): (A, B) = …`,
    /// `let (a, b) = (x, y)`.
    private func bindLocal(_ binding: PatternBindingSyntax, sharedAnnotation: TypeSyntax?) {
        let line = line(binding.positionAfterSkippingLeadingTrivia)
        let annotation = binding.typeAnnotation?.type ?? sharedAnnotation
        if let identifier = binding.pattern.as(IdentifierPatternSyntax.self), SwiftSyntaxSupport.isReferenceToken(identifier.identifier) {
            var type: TypeExpr?
            if let annotation {
                type = allows(.localAnnotation) ? declaredType(annotation) : nil
            } else if let value = binding.initializer?.value, allows(.localInitializer) {
                type = typeOf(value)
            }
            bind(SwiftSyntaxSupport.identifierText(identifier.identifier), LocalBinding(type: type, line: line))
            return
        }
        if let tuple = binding.pattern.as(TuplePatternSyntax.self), allows(.tuplePattern) {
            var types: [TypeExpr?] = []
            if let tupleType = annotation?.as(TupleTypeSyntax.self) {
                types = tupleType.elements.map { declaredType($0.type) }
            } else if let value = binding.initializer?.value.as(TupleExprSyntax.self) {
                types = value.elements.map { typeOf($0.expression) }
            }
            for (index, element) in tuple.elements.enumerated() {
                let type = index < types.count ? types[index] : nil
                for name in SwiftSyntaxSupport.patternNames(element.pattern) {
                    bind(name, LocalBinding(type: element.pattern.is(IdentifierPatternSyntax.self) ? type : nil, line: line))
                }
            }
            return
        }
        for name in SwiftSyntaxSupport.patternNames(binding.pattern) {
            bind(name, LocalBinding(type: nil, line: line))
        }
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let localID = pendingSymbols.removeValue(forKey: node.id) {
            openSymbol(node.id, localID)
            frames.append(ComplexityFrame(node: node.id, localID: localID, decisions: 0))
        }
        return .visitChildren
    }

    override func visitPost(_ node: PatternBindingSyntax) { leave(node.id) }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isInsideBody else { return .visitChildren }
        let doc = SwiftSyntaxSupport.docComment(node.leadingTrivia)
        let attributes = SwiftSyntaxSupport.attributeNames(node.attributes) + SwiftSyntaxSupport.notableModifierNames(node.modifiers)
        // Enum cases always have the access level of their enum.
        let containerVisibility: Visibility?
        if let container = containers.last, container.kind == .enum {
            containerVisibility = symbols[container.localID].visibility
        } else {
            containerVisibility = inheritedMemberVisibility
        }
        let visibility = SwiftSyntaxSupport.visibility(node.modifiers) ?? containerVisibility
        let startLine = line(node.positionAfterSkippingLeadingTrivia)
        // A case produces its enum.
        let owner = allows(.ownerType) ? enclosingTypeName.map { TypeExpr.named($0) } : nil
        var emitted: [(node: SyntaxIdentifier, localID: Int)] = []
        for element in node.elements {
            guard SwiftSyntaxSupport.isReferenceToken(element.name) else { continue }
            let name = SwiftSyntaxSupport.identifierText(element.name)
            let end = element.trailingComma?.positionAfterSkippingLeadingTrivia ?? element.endPositionBeforeTrailingTrivia
            let elementText = text(from: element.positionAfterSkippingLeadingTrivia, to: end)
            let localID = addSymbol(
                name: name,
                kind: .enumCase,
                range: LineRange(startLine, line(element.endPositionBeforeTrailingTrivia)),
                signature: ("case " + elementText).compactSignature(),
                doc: doc,
                visibility: visibility,
                attributes: attributes,
                shape: element.parameterClause.map { caseShape(name, $0.parameters) },
                declaredType: owner
            )
            emitted.append((element.id, localID))
        }
        if emitted.count == 1, let only = emitted.first {
            openSymbol(node.id, only.localID)
        } else {
            for entry in emitted { pendingSymbols[entry.node] = entry.localID }
        }
        return .visitChildren
    }

    override func visitPost(_ node: EnumCaseDeclSyntax) { leave(node.id) }

    /// `data(sequence:flags:payload:)` for a case with associated values; unnamed values are `_`.
    private func caseShape(_ name: String, _ parameters: EnumCaseParameterListSyntax) -> CallableShape {
        var labels = ""
        var flags = ""
        var types: [String] = []
        for parameter in parameters {
            labels += SwiftSyntaxSupport.argumentLabel(parameter.firstName) + ":"
            flags.append(SwiftSyntaxSupport.parameterFlag(type: parameter.type, isVariadic: false, hasDefault: parameter.defaultValue != nil))
            types.append(normalizedType(parameter.type))
        }
        return CallableShape(selector: name + "(" + labels + ")", flags: flags, types: types)
    }

    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
        if let localID = pendingSymbols.removeValue(forKey: node.id) {
            openSymbol(node.id, localID)
        }
        return .visitChildren
    }

    override func visitPost(_ node: EnumCaseElementSyntax) { leave(node.id) }

    // MARK: - Bodies and local scopes

    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        let valueType = accessorValueType(node)
        let line = line(node.positionAfterSkippingLeadingTrivia)
        let value = LocalBinding(type: allows(.accessorValue) ? valueType : nil, line: line)
        pushScope(node.id, ["newValue": value, "oldValue": value])
        returnTypes.append((node.id, valueType))
        bodyOwners.append(node.id)
        return .visitChildren
    }

    override func visitPost(_ node: AccessorBlockSyntax) { leave(node.id) }

    /// What a property's or subscript's accessors get and set: the annotation, the initializer's type, or the
    /// subscript's return type.
    private func accessorValueType(_ block: AccessorBlockSyntax) -> TypeExpr? {
        if let binding = block.parent?.as(PatternBindingSyntax.self) {
            if let annotation = binding.typeAnnotation { return declaredType(annotation.type) }
            return binding.initializer.flatMap { typeOf($0.value) }
        }
        if let subscriptDecl = block.parent?.as(SubscriptDeclSyntax.self) {
            return declaredType(subscriptDecl.returnClause.type)
        }
        return nil
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        if let parameter = node.parameters, SwiftSyntaxSupport.isReferenceToken(parameter.name) {
            // `set(value)` renames `newValue`.
            bind(SwiftSyntaxSupport.identifierText(parameter.name),
                 LocalBinding(type: binding(for: "newValue")?.type, line: line(parameter.positionAfterSkippingLeadingTrivia)))
        }
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        pushScope(node.id, closureBindings(node))
        returnTypes.append((node.id, node.signature?.returnClause.flatMap { declaredType($0.type) }))
        bodyOwners.append(node.id)
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) { leave(node.id) }

    /// A closure's parameters, typed from their annotations or from the call the closure is passed to
    /// (`plans.contains { plan in … }` → an element of `plans`), `$0…` when it has no parameter list, and the
    /// names its capture list declares. `[x]` and `[weak x]` capture the outer `x` and keep its meaning.
    private func closureBindings(_ closure: ClosureExprSyntax) -> [String: LocalBinding] {
        let line = line(closure.positionAfterSkippingLeadingTrivia)
        var bindings: [String: LocalBinding] = [:]
        if closure.signature?.parameterClause == nil {
            // `$0`, `$1`… (also after a capture list alone); bound even when untyped, so that they never reach an
            // enclosing closure's.
            let types = closureParameterTypes(closure, parameters: nil)
            for index in 0..<max(types.count, 4) {
                bindings["$\(index)"] = LocalBinding(type: index < types.count ? types[index] : nil, line: line)
            }
        }
        guard let signature = closure.signature else { return bindings }
        for item in signature.capture?.items ?? [] where SwiftSyntaxSupport.isReferenceToken(item.name) {
            guard let initializer = item.initializer else { continue }
            bindings[SwiftSyntaxSupport.identifierText(item.name)] = LocalBinding(
                type: allows(.captureList) ? typeOf(initializer.value) : nil, line: self.line(item.positionAfterSkippingLeadingTrivia))
        }
        switch signature.parameterClause {
        case .simpleInput(let parameters):
            let types = closureParameterTypes(closure, parameters: parameters.count)
            for (index, parameter) in parameters.enumerated() where SwiftSyntaxSupport.isReferenceToken(parameter.name) {
                bindings[SwiftSyntaxSupport.identifierText(parameter.name)] = LocalBinding(type: index < types.count ? types[index] : nil, line: line)
            }
        case .parameterClause(let clause):
            let types = closureParameterTypes(closure, parameters: clause.parameters.count)
            for (index, parameter) in clause.parameters.enumerated() {
                let token = parameter.secondName ?? parameter.firstName
                guard SwiftSyntaxSupport.isReferenceToken(token) else { continue }
                let written = parameter.type.flatMap { allows(.parameter) ? declaredType($0) : nil }
                bindings[SwiftSyntaxSupport.identifierText(token)] = LocalBinding(type: written ?? (index < types.count ? types[index] : nil), line: line)
            }
        case nil:
            break
        }
        return bindings
    }

    override func visitPost(_ node: OptionalBindingConditionSyntax) {
        let line = line(node.pattern.positionAfterSkippingLeadingTrivia)
        guard let identifier = node.pattern.as(IdentifierPatternSyntax.self), SwiftSyntaxSupport.isReferenceToken(identifier.identifier) else {
            for name in SwiftSyntaxSupport.patternNames(node.pattern) { bind(name, LocalBinding(type: nil, line: line)) }
            return
        }
        let name = SwiftSyntaxSupport.identifierText(identifier.identifier)
        var type: TypeExpr?
        if let annotation = node.typeAnnotation {
            type = declaredType(annotation.type)
        } else if let value = node.initializer?.value {
            type = typeOf(value)
        } else {
            // `if let user {` reads the outer `user` before shadowing it, and keeps its type.
            let outer = binding(for: name)
            let read = emit(name, kind: .read, position: node.pattern.positionAfterSkippingLeadingTrivia, receiver: nil, context: .read)
            if let outer { type = outer.type } else if let read { type = .ref(read) }
        }
        bind(name, LocalBinding(type: allows(.optionalBinding) ? type : nil, line: line))
    }

    override func visit(_ node: MatchingPatternConditionSyntax) -> SyntaxVisitorContinueKind {
        let line = line(node.positionAfterSkippingLeadingTrivia)
        for (name, binding) in casePatternBindings(node.pattern, value: typeOf(node.initializer.value), line: line) {
            bind(name, binding)
        }
        return .visitChildren
    }

    /// Names a `case` pattern binds. The whole value bound by `let x`, `let x?` or `.some(let x)` has the matched
    /// value's type and `let x as T` is a `T`; enum payloads stay untyped.
    private func casePatternBindings(_ pattern: PatternSyntax, value: TypeExpr?, line: Int) -> [String: LocalBinding] {
        var bindings: [String: LocalBinding] = [:]
        for name in SwiftSyntaxSupport.patternNames(pattern) { bindings[name] = LocalBinding(type: nil, line: line) }
        guard allows(.castPattern), let whole = SwiftSyntaxSupport.wholeValueBinding(pattern) else { return bindings }
        bindings[whole.name] = LocalBinding(type: whole.cast.flatMap { declaredType($0) } ?? value, line: line)
        return bindings
    }

    /// Locals declared in a block are visible only inside it.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        pushScope(node.id, [:])
        return .visitChildren
    }

    override func visitPost(_ node: CodeBlockSyntax) { leave(node.id) }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        decision()
        pushScope(node.id, loopBindings(node))
        return .visitChildren
    }

    override func visitPost(_ node: ForStmtSyntax) { leave(node.id) }

    /// `for x in xs` → an element of `xs`; `for (i, x) in xs.enumerated()`, `for (key, value) in table`.
    private func loopBindings(_ node: ForStmtSyntax) -> [String: LocalBinding] {
        let line = line(node.positionAfterSkippingLeadingTrivia)
        var bindings: [String: LocalBinding] = [:]
        for name in SwiftSyntaxSupport.patternNames(node.pattern) { bindings[name] = LocalBinding(type: nil, line: line) }
        guard allows(.forElement) else { return bindings }
        if let identifier = node.pattern.as(IdentifierPatternSyntax.self), SwiftSyntaxSupport.isReferenceToken(identifier.identifier) {
            let name = SwiftSyntaxSupport.identifierText(identifier.identifier)
            let type = node.typeAnnotation.flatMap { declaredType($0.type) } ?? elementTypes(of: node.sequence).single
            bindings[name] = LocalBinding(type: type, line: line)
        } else if let tuple = node.pattern.as(TuplePatternSyntax.self), tuple.elements.count == 2,
                  let pair = elementTypes(of: node.sequence).pair, pair.count == 2 {
            for (element, type) in zip(tuple.elements, pair) {
                guard let identifier = element.pattern.as(IdentifierPatternSyntax.self), SwiftSyntaxSupport.isReferenceToken(identifier.identifier) else { continue }
                bindings[SwiftSyntaxSupport.identifierText(identifier.identifier)] = LocalBinding(type: type, line: line)
            }
        } else if node.caseKeyword != nil {
            bindings.merge(casePatternBindings(node.pattern, value: elementTypes(of: node.sequence).single, line: line)) { $1 }
        }
        return bindings
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        decision()
        let line = line(node.positionAfterSkippingLeadingTrivia)
        let error: TypeExpr? = allows(.catchError) ? .named("Error") : nil
        var bindings: [String: LocalBinding] = node.catchItems.isEmpty ? ["error": LocalBinding(type: error, line: line)] : [:]
        for item in node.catchItems {
            if let pattern = item.pattern { bindings.merge(casePatternBindings(pattern, value: error, line: line)) { $1 } }
        }
        pushScope(node.id, bindings)
        openStatement(node.id, from: node.catchKeyword.positionAfterSkippingLeadingTrivia,
                      to: node.body.leftBrace.positionAfterSkippingLeadingTrivia)
        return .visitChildren
    }

    override func visitPost(_ node: CatchClauseSyntax) { leave(node.id) }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        var bindings: [String: LocalBinding] = [:]
        switch node.label {
        case .case(let label):
            decision()
            let line = line(node.positionAfterSkippingLeadingTrivia)
            let subject = SwiftSyntaxSupport.switchStatement(of: node).flatMap { typeOf($0.subject) }
            for item in label.caseItems {
                bindings.merge(casePatternBindings(item.pattern, value: subject, line: line)) { $1 }
            }
            // The `case …:` label is the statement for its patterns; the body's statements are their own.
            openStatement(node.id, from: label.caseKeyword.positionAfterSkippingLeadingTrivia, to: label.colon.positionAfterSkippingLeadingTrivia)
        case .default:
            break
        }
        pushScope(node.id, bindings)
        return .visitChildren
    }

    override func visitPost(_ node: SwitchCaseSyntax) { leave(node.id) }

    /// Implicit members inside a `case` pattern (`case .data(let payload)`) name enum cases.
    override func visit(_ node: ExpressionPatternSyntax) -> SyntaxVisitorContinueKind {
        patternDepth += 1
        return .visitChildren
    }

    override func visitPost(_ node: ExpressionPatternSyntax) { patternDepth -= 1 }

    // MARK: - Statements

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        openStatement(node.id, Syntax(node.item))
        return .visitChildren
    }

    override func visitPost(_ node: CodeBlockItemSyntax) { leave(node.id) }

    override func visit(_ node: MemberBlockItemSyntax) -> SyntaxVisitorContinueKind {
        openStatement(node.id, Syntax(node.decl))
        return .visitChildren
    }

    override func visitPost(_ node: MemberBlockItemSyntax) { leave(node.id) }

    // MARK: - Decision points

    /// `if` bindings are scoped to the statement; `guard` bindings flow into the enclosing block.
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        decision()
        pushScope(node.id, [:])
        // Each `if` of an `else if` chain has its own header.
        openStatement(node.id, from: node.ifKeyword.positionAfterSkippingLeadingTrivia, to: node.body.leftBrace.positionAfterSkippingLeadingTrivia)
        return .visitChildren
    }

    override func visitPost(_ node: IfExprSyntax) { leave(node.id) }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        decision()
        return .visitChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        decision()
        pushScope(node.id, [:])
        return .visitChildren
    }

    override func visitPost(_ node: WhileStmtSyntax) { leave(node.id) }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        decision()
        // The condition follows the body: `} while condition` is its statement.
        openStatement(node.id, from: node.whileKeyword.positionAfterSkippingLeadingTrivia, to: node.endPositionBeforeTrailingTrivia)
        return .visitChildren
    }

    override func visitPost(_ node: RepeatStmtSyntax) { leave(node.id) }

    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        decision()
        return .visitChildren
    }

    override func visit(_ node: UnresolvedTernaryExprSyntax) -> SyntaxVisitorContinueKind {
        decision()
        return .visitChildren
    }

    override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        switch node.operator.text {
        case "&&", "||", "??": decision()
        default: break
        }
        return .skipChildren
    }

    // MARK: - Imports

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let first = node.path.first {
            let attributes = SwiftSyntaxSupport.attributeNames(node.attributes)
            imports.append(ExtractedImport(
                module: SwiftSyntaxSupport.identifierText(first.name),
                kind: .module,
                line: line(node.positionAfterSkippingLeadingTrivia),
                isReExport: attributes.contains("@_exported"),
                isTestable: attributes.contains("@testable"),
                conditions: conditions
            ))
        }
        return .skipChildren
    }

    // MARK: - Conditional compilation

    /// Visits every clause's contents under the clause's condition (`DEBUG`, `!DEBUG`, `canImport(UIKit)`).
    /// The conditions themselves are not references.
    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        guard let elements = node.elements else { return .skipChildren }
        if case .postfixExpression(let expression) = elements, let member = SwiftSyntaxSupport.leadingMember(of: expression) {
            postfixConfigMembers.insert(member.id)
        }
        let condition = SwiftSyntaxSupport.clauseCondition(node)
        if let condition { conditions.append(condition) }
        walk(elements)
        if condition != nil { conditions.removeLast() }
        return .skipChildren
    }

    // MARK: - Attributes and macros

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if SwiftSyntaxSupport.builtInAttributes.contains(SwiftSyntaxSupport.attributeName(node)) {
            return .skipChildren
        }
        // Property wrappers and attached macros: the attribute name is reported as a type use by the
        // type visitors, and arguments are visited normally.
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        emitMacro(node.macroName, call: callShape(arguments: node.arguments, trailingClosure: node.trailingClosure,
                                                  additionalTrailingClosures: node.additionalTrailingClosures,
                                                  rightParen: node.rightParen, calleeEnd: node.macroName.endPositionBeforeTrailingTrivia))
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        emitMacro(node.macroName, call: callShape(arguments: node.arguments, trailingClosure: node.trailingClosure,
                                                  additionalTrailingClosures: node.additionalTrailingClosures,
                                                  rightParen: node.rightParen, calleeEnd: node.macroName.endPositionBeforeTrailingTrivia))
        return .visitChildren
    }

    private func emitMacro(_ token: TokenSyntax, call: CallShape) {
        guard SwiftSyntaxSupport.isReferenceToken(token) else { return }
        let name = SwiftSyntaxSupport.identifierText(token)
        guard !SwiftSyntaxSupport.wellKnownMacros.contains(name) else { return }
        emit(name, kind: .call, at: token, receiver: nil, context: .call, call: call)
    }

    // MARK: - Types in reference position

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        if !handledTypes.contains(node.id), SwiftSyntaxSupport.isReferenceToken(node.name) {
            emit(SwiftSyntaxSupport.identifierText(node.name), kind: .typeUse, at: node.name, receiver: nil, context: .type)
        }
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        if !handledTypes.contains(node.id), SwiftSyntaxSupport.isReferenceToken(node.name) {
            emit(SwiftSyntaxSupport.identifierText(node.name), kind: .typeUse, at: node.name,
                 receiver: SwiftSyntaxSupport.typeName(node.baseType) ?? "_", context: .type)
        }
        return .visitChildren
    }

    // MARK: - Expressions

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        var iterator = node.elements.makeIterator()
        if let target = iterator.next(), let op = iterator.next(), SwiftSyntaxSupport.isAssignment(op) {
            markWriteTarget(target)
            if let value = iterator.next(), iterator.next() == nil { noteEnvironmentAssignment(target, op, value) }
        }
        return .visitChildren
    }

    override func visit(_ node: InOutExprSyntax) -> SyntaxVisitorContinueKind {
        markWriteTarget(node.expression)
        return .visitChildren
    }

    private func markWriteTarget(_ expression: ExprSyntax) {
        if expression.is(DeclReferenceExprSyntax.self) || expression.is(MemberAccessExprSyntax.self) {
            writeTargets.insert(expression.id)
        } else if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
            markWriteTarget(subscriptCall.calledExpression)
        } else if let optional = expression.as(OptionalChainingExprSyntax.self) {
            markWriteTarget(optional.expression)
        } else if let forced = expression.as(ForceUnwrapExprSyntax.self) {
            markWriteTarget(forced.expression)
        } else if let tuple = expression.as(TupleExprSyntax.self) {
            for element in tuple.elements { markWriteTarget(element.expression) }
        }
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if handledExpressions.contains(node.id) { return .skipChildren }
        if let parent = node.parent {
            if let member = parent.as(MemberAccessExprSyntax.self), member.declName.id == node.id { return .skipChildren }
            if parent.is(KeyPathPropertyComponentSyntax.self) { return .skipChildren }
        }
        let token = node.baseName
        guard SwiftSyntaxSupport.isReferenceToken(token) else { return .skipChildren }
        let name = SwiftSyntaxSupport.identifierText(token)
        let use = usage(of: node, name: name)
        if let index = emit(name, kind: use.kind, at: token, receiver: nil, context: use.context, call: use.call) {
            registerProducer(index, of: node)
        }
        return .skipChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let base = node.base else {
            emitImplicitMember(node)
            return .skipChildren
        }
        let token = node.declName.baseName
        switch token.tokenKind {
        case .keyword(.`init`):
            // `Foo.init(...)` / `Foo.Bar.init` instantiate the base type; `self.init`/`super.init` delegate.
            if let chain = SwiftSyntaxSupport.typeChain(base), let typeName = chain.last {
                let call = callExpression(calling: node)
                if let index = emit(typeName, kind: .instantiate, position: base.positionAfterSkippingLeadingTrivia,
                                    receiver: chain.count > 1 ? chain.dropLast().joined(separator: ".") : nil,
                                    context: call == nil ? .read : .call, call: call.map { callShape($0) }) {
                    registerProducer(index, of: node)
                }
                handledExpressions.insert(base.id)
            }
            return .visitChildren
        case .identifier, .dollarIdentifier:
            break
        default:
            // `Foo.self` and other keyword members: only the base is a reference.
            return .visitChildren
        }
        if handledExpressions.contains(node.id) { return .visitChildren }

        let name = SwiftSyntaxSupport.identifierText(token)
        let use = usage(of: node, name: name)
        if let index = emit(name, kind: use.kind, at: token, receiver: SwiftSyntaxSupport.receiverText(base), context: use.context, call: use.call) {
            registerProducer(index, of: node)
            noteReceiver(of: index, base: base)
        }
        return .visitChildren
    }

    /// Implicit members: `.red`, `.data(…)`, `case .idle:` are emitted with receiver `"."` and the context they are looked up
    /// in (`ctx(T)`, `param(^,i)`); the linker resolves them only through it. `.init(…)` instantiates its
    /// contextual type when the collector knows it.
    private func emitImplicitMember(_ node: MemberAccessExprSyntax) {
        let token = node.declName.baseName
        if token.tokenKind == .keyword(.`init`) {
            emitImplicitInit(node)
            return
        }
        guard SwiftSyntaxSupport.isReferenceToken(token) else { return }
        let name = SwiftSyntaxSupport.identifierText(token)
        if postfixConfigMembers.contains(node.id) {
            // `.padding()` under a postfix `#if` is a member of the expression before the `#if`.
            let use = usage(of: node, name: name)
            guard let index = emit(name, kind: use.kind, at: token, receiver: "_", context: use.context, call: use.call) else { return }
            registerProducer(index, of: node)
            if let base = SwiftSyntaxSupport.postfixConfigBase(of: node) { noteReceiver(of: index, base: base) }
            return
        }
        let call = callExpression(calling: node)
        guard let index = emit(name, kind: call == nil ? .read : .call, at: token, receiver: ".",
                               context: patternDepth > 0 ? .pattern : .implicit, call: call.map { callShape($0) }) else { return }
        registerProducer(index, of: node)
        switch implicitContext(of: node) {
        case .type(let type)?: receiverNotes.append((index, .context(type)))
        case .argument(let call, let position)?: receiverNotes.append((index, .argument(call: call, index: position)))
        case nil: break
        }
    }

    /// `let box: Box = .init(width: 1)` instantiates `Box`.
    private func emitImplicitInit(_ node: MemberAccessExprSyntax) {
        guard allows(.implicitInit), case .type(let context)? = implicitContext(of: node), let typeName = staticType(context),
              SwiftTypeInference.isNominal(typeName) else { return }
        let components = typeName.split(separator: ".").map(String.init)
        guard let name = components.last else { return }
        let call = callExpression(calling: node)
        if let index = emit(name, kind: .instantiate, at: node.declName.baseName,
                            receiver: components.count > 1 ? components.dropLast().joined(separator: ".") : nil,
                            context: call == nil ? .read : .call, call: call.map { callShape($0) }) {
            registerProducer(index, of: node)
        }
    }

    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        var receiver = node.root.flatMap { SwiftSyntaxSupport.typeName($0) } ?? "_"
        var root = node.root == nil ? keyPathRoot(node) : nil
        var previous: Int?
        for component in node.components {
            switch component.component {
            case .property(let property):
                let token = property.declName.baseName
                var index: Int?
                if SwiftSyntaxSupport.isReferenceToken(token) {
                    index = emit(SwiftSyntaxSupport.identifierText(token), kind: .read, at: token, receiver: receiver, context: .keypath)
                    // `\Book.author.name`: `name` is a member of what `author` holds; `books.map(\.name)`
                    // starts at an element of `books`.
                    if let index, let previous, allows(.receiverChain) { receiverNotes.append((index, .component(previous))) }
                    if let index, let root { receiverNotes.append((index, .value(root))) }
                }
                previous = index
            case .optional:
                // `\.book?.name`: unwrapping keeps the value.
                break
            default:
                previous = nil
            }
            receiver = "_"
            root = nil
        }
        return .visitChildren
    }

    /// The reference emitted for `node` is the value of `node`, and of the call it is the callee of.
    private func registerProducer(_ index: Int, of node: some ExprSyntaxProtocol) {
        producers[node.id] = index
        if let call = callExpression(calling: node) { producers[call.id] = index }
    }

    /// Receiver types: what the collector knows about the value a member is looked up on. Locals carry their binding's
    /// type; a property, global, call or member chain points at the reference that produces it; `self`, `super`
    /// and type names are left to the receiver text.
    private func noteReceiver(of reference: Int, base: ExprSyntax) {
        let base = SwiftTypeInference.unwrapped(base)
        if let identifier = base.as(DeclReferenceExprSyntax.self) {
            let token = identifier.baseName
            guard SwiftSyntaxSupport.isReferenceToken(token), identifier.argumentNames == nil else { return }
            let name = SwiftSyntaxSupport.identifierText(token)
            if let binding = binding(for: name) {
                if binding.kind == .value { receiverNotes.append((reference, .local(binding.type, line: binding.line))) }
                return
            }
            if name.hasPrefix("$") {
                // `$0` of a closure without a parameter list; `$x` is a projected value, which is not `x`.
                if name.dropFirst().first?.isNumber == true { receiverNotes.append((reference, .local(nil, line: nil))) }
                return
            }
            if name.first?.isUppercase == true || !allows(.nonLocalValue) { return }
            receiverNotes.append((reference, .value(.expr(identifier.id, fallback: nil))))
            return
        }
        if base.is(SuperExprSyntax.self) || SwiftSyntaxSupport.typeChain(base) != nil { return }
        guard allows(.receiverChain), let type = typeOf(base) else { return }
        receiverNotes.append((reference, .value(type)))
    }

    /// How a value expression is used: called (with the call's shape), assigned, named as a type, or read.
    private func usage(of node: some ExprSyntaxProtocol, name: String) -> (kind: ReferenceKind, context: ReferenceContext, call: CallShape?) {
        let isUppercase = name.first?.isUppercase ?? false
        if let call = callExpression(calling: node) {
            return (isUppercase ? .instantiate : .call, .call, callShape(call))
        }
        if writeTargets.contains(node.id) { return (.write, .write, nil) }
        if isUppercase && isMemberBase(node) { return (.typeUse, .type, nil) }
        return (.read, .read, nil)
    }

    /// The call whose called expression this is (looking through `Foo<T>`).
    private func callExpression(calling node: some SyntaxProtocol) -> FunctionCallExprSyntax? {
        var current = Syntax(node)
        while let parent = current.parent {
            if let specialized = parent.as(GenericSpecializationExprSyntax.self), specialized.expression.id == current.id {
                current = parent
                continue
            }
            if let call = parent.as(FunctionCallExprSyntax.self), call.calledExpression.id == current.id {
                return call
            }
            return nil
        }
        return nil
    }

    private func callShape(_ call: FunctionCallExprSyntax) -> CallShape {
        callShape(arguments: call.arguments, trailingClosure: call.trailingClosure, additionalTrailingClosures: call.additionalTrailingClosures,
                  rightParen: call.rightParen, calleeEnd: call.calledExpression.endPositionBeforeTrailingTrivia)
    }

    /// Labels in order (`_` unlabeled, `{}` / `label{}` trailing closures). The call ends at its `)`:
    /// trailing closures are left out, so a SwiftUI container's call stays on its first line.
    private func callShape(
        arguments: LabeledExprListSyntax,
        trailingClosure: ClosureExprSyntax?,
        additionalTrailingClosures: MultipleTrailingClosureElementListSyntax,
        rightParen: TokenSyntax?,
        calleeEnd: AbsolutePosition
    ) -> CallShape {
        var labels = arguments.map { SwiftSyntaxSupport.argumentLabel($0.label) }
        if trailingClosure != nil { labels.append("{}") }
        for closure in additionalTrailingClosures {
            labels.append(SwiftSyntaxSupport.argumentLabel(closure.label) + "{}")
        }
        let end = rightParen?.positionAfterSkippingLeadingTrivia ?? arguments.last?.endPositionBeforeTrailingTrivia ?? calleeEnd
        return CallShape(labels: labels, endLine: line(end))
    }

    /// True when the expression is the base of a member access (looking through `?` and `!`).
    private func isMemberBase(_ node: some SyntaxProtocol) -> Bool {
        var current = Syntax(node)
        while let parent = current.parent {
            if parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self) {
                current = parent
                continue
            }
            if let member = parent.as(MemberAccessExprSyntax.self) {
                return member.base?.id == current.id
            }
            return false
        }
        return false
    }

    // MARK: - String literals

    /// Records a literal with where its value goes (`Text("Unlock Premium")` is `ui`, `restoreMessage = "…"` is
    /// `assign`). An interpolated literal is not a value; the references inside `\(…)` are visited as usual.
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard let value = node.representedLiteralValue else { return .visitChildren }
        guard SwiftLiterals.isRecorded(value) else { return .skipChildren }
        let site = SwiftLiterals.site(of: node)
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        literals.append(ExtractedLiteral(
            value: value, line: location.line, column: location.column, enclosingSymbol: openSymbols.last?.localID,
            context: site.context, callee: site.callee, label: site.label, conditions: conditions
        ))
        return .skipChildren
    }

    // MARK: - Environment variables and launch arguments

    /// `ProcessInfo.processInfo.environment["X"]` reads `env:X`; `app.launchEnvironment["X"] = "1"` writes it and
    /// `= nil` deletes it. A computed key is `env:*`.
    override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.arguments.count == 1, let key = node.arguments.first, key.label == nil,
              let source = environmentSource(node.calledExpression) else { return .visitChildren }
        if case .arguments = source { return .visitChildren }
        let assignment = SwiftLiterals.assignment(to: node)
        let kind: ReferenceKind = assignment == nil ? .read : .write
        let position = key.expression.positionAfterSkippingLeadingTrivia
        if let name = SwiftLiterals.stringValue(key.expression) {
            let deletes = assignment?.value?.is(NilLiteralExprSyntax.self) == true
            noteEnvironment("env:" + name, kind: kind, context: deletes ? .delete : .env, at: position, in: source, receiver: node.calledExpression)
            return .visitChildren
        }
        // A computed key (`items[index]`) counts only on what is already known to hold an environment.
        if case .holder(let holder) = source, !environmentHolders.contains(holder) { return .visitChildren }
        noteEnvironment("env:*", kind: kind, context: .envDynamic, at: position, in: source, receiver: node.calledExpression)
        return .visitChildren
    }

    /// `env.merge(["X": "1"])`, `env.removeValue(forKey: "X")`, `app.launchArguments.append("-UITests")`,
    /// `ProcessInfo.processInfo.arguments.contains("-FIRDebugEnabled")`, `launch(environment: ["X": "1"])` and
    /// `getenv("X")`.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        noteEnvironmentCall(node)
        return .visitChildren
    }

    private func noteEnvironmentCall(_ call: FunctionCallExprSyntax) {
        // Arguments that configure a launch, whatever the callee: `launch(.fresh, environment: ["X": "1"])`.
        for argument in call.arguments {
            switch argument.label?.text ?? "" {
            case "environment", "launchEnvironment": noteFlow(argument.expression, into: .environment, receiver: nil)
            case "launchArguments": noteFlow(argument.expression, into: .arguments, receiver: nil)
            default: break
            }
        }
        if let function = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            // The C interface: `getenv("HOME")`, `setenv("X", "1", 1)`, `unsetenv("X")`.
            let name = function.baseName.text
            guard name == "getenv" || name == "setenv" || name == "unsetenv", let first = call.arguments.first,
                  let variable = SwiftLiterals.stringValue(first.expression) else { return }
            noteEnvironment("env:" + variable, kind: name == "getenv" ? .read : .write, context: name == "unsetenv" ? .delete : .env,
                            at: first.expression.positionAfterSkippingLeadingTrivia, in: .environment, receiver: nil)
            return
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base else { return }
        let method = member.declName.baseName.text
        switch method {
        case "merge", "merging", "removeValue", "updateValue", "append", "insert", "contains", "firstIndex": break
        default: return
        }
        guard let source = environmentSource(base), let first = call.arguments.first else { return }
        let label = first.label?.text
        switch method {
        case "merge", "merging":
            if label == nil { noteFlow(first.expression, into: source, receiver: base) }
        case "removeValue", "updateValue":
            guard let key = call.arguments.first(where: { $0.label?.text == "forKey" }),
                  let variable = SwiftLiterals.stringValue(key.expression) else { return }
            noteEnvironment("env:" + variable, kind: .write, context: method == "removeValue" ? .delete : .env,
                            at: key.expression.positionAfterSkippingLeadingTrivia, in: source, receiver: base)
        case "append", "insert":
            if label == "contentsOf" {
                noteFlow(first.expression, into: source, receiver: base)
            } else if label == nil, let value = SwiftLiterals.stringValue(first.expression) {
                noteEnvironment("env:arg:" + value, kind: .write, context: .env, at: first.expression.positionAfterSkippingLeadingTrivia,
                                in: source, receiver: base)
            }
        default:
            // `contains("-x")`, `firstIndex(of: "-x")`
            guard label == nil || label == "of", let value = SwiftLiterals.stringValue(first.expression) else { return }
            noteEnvironment("env:arg:" + value, kind: .read, context: .env, at: first.expression.positionAfterSkippingLeadingTrivia,
                            in: source, receiver: base)
        }
    }

    /// `app.launchEnvironment = env`, `app.launchArguments += ["-UITests"]`, `lastEnvironment = env`.
    private func noteEnvironmentAssignment(_ target: ExprSyntax, _ op: ExprSyntax, _ value: ExprSyntax) {
        guard op.is(AssignmentExprSyntax.self) || op.as(BinaryOperatorExprSyntax.self)?.operator.text == "+=",
              let destination = environmentSource(target) else { return }
        noteFlow(value, into: destination, receiver: target)
    }

    /// `let env = ProcessInfo.processInfo.environment`, `var env: [String: String] = ["QUIET_MODE": "1"]`,
    /// `let info = ProcessInfo.processInfo`: what a new local, property or global holds.
    private func noteEnvironmentBindings(_ node: VariableDeclSyntax) {
        // Locals are bound in the innermost scope once their declaration has been visited.
        let scope: SyntaxIdentifier? = isInsideBody ? scopes[scopes.count - 1].owner : nil
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  SwiftSyntaxSupport.isReferenceToken(identifier.identifier) else { continue }
            let holder = Holder(scope: scope, name: SwiftSyntaxSupport.identifierText(identifier.identifier))
            if let annotation = binding.typeAnnotation?.type, SwiftLiterals.isEnvironmentName(holder.name),
               SwiftSyntaxSupport.normalizedType(annotation) == "[String: String]" {
                environmentHolders.insert(holder)
            }
            guard let value = binding.initializer?.value else { continue }
            if isProcessInfo(value) {
                processInfoHolders.insert(holder)
            } else {
                noteFlow(value, into: .holder(holder), receiver: nil)
            }
        }
    }

    /// A `[String: String]` parameter named like an environment holds one: `isRequested(environment:)`.
    private func noteEnvironmentParameters(_ parameters: FunctionParameterListSyntax, scope: SyntaxIdentifier) {
        for parameter in parameters {
            let token = parameter.secondName ?? parameter.firstName
            guard SwiftSyntaxSupport.isReferenceToken(token) else { continue }
            let name = SwiftSyntaxSupport.identifierText(token)
            guard SwiftLiterals.isEnvironmentName(name), SwiftSyntaxSupport.normalizedType(parameter.type) == "[String: String]" else { continue }
            environmentHolders.insert(Holder(scope: scope, name: name))
        }
    }

    /// `value` flows into `destination`: a dictionary literal's keys are written, an array literal's launch arguments
    /// are passed, and a holder holds what the other side holds.
    private func noteFlow(_ value: ExprSyntax, into destination: EnvironmentSource, receiver: ExprSyntax?) {
        let value = SwiftTypeInference.unwrapped(value)
        if let dictionary = value.as(DictionaryExprSyntax.self) {
            for key in SwiftLiterals.stringKeys(dictionary) {
                noteEnvironment("env:" + key.value, kind: .write, context: .env, at: key.expression.positionAfterSkippingLeadingTrivia,
                                in: destination, receiver: receiver)
            }
            return
        }
        if let array = value.as(ArrayExprSyntax.self) {
            for argument in SwiftLiterals.launchArguments(array) {
                noteEnvironment("env:arg:" + argument.value, kind: .write, context: .env,
                                at: argument.expression.positionAfterSkippingLeadingTrivia, in: destination, receiver: receiver)
            }
            return
        }
        // `ProcessInfo.processInfo.environment.merging(extra) { $1 }` is a copy of the environment.
        var source = environmentSource(value)
        if source == nil, let call = value.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "merging", let base = member.base {
            source = environmentSource(base)
        }
        switch (source, destination) {
        case (.holder(let from)?, .holder(let into)): holderFlows.append((from, into))
        case (.holder(let from)?, .environment): environmentHolders.insert(from)
        case (.holder(let from)?, .arguments): argumentHolders.insert(from)
        case (.environment?, .holder(let into)): environmentHolders.insert(into)
        case (.arguments?, .holder(let into)): argumentHolders.insert(into)
        default: break
        }
    }

    /// An `env:NAME` or `env:arg:VALUE` use at `position`: emitted now on the environment or arguments themselves, and
    /// after the walk on a holder that turns out to hold them.
    private func noteEnvironment(_ name: String, kind: ReferenceKind, context: ReferenceContext, at position: AbsolutePosition,
                                 in source: EnvironmentSource, receiver: ExprSyntax?) {
        let isArguments = name.hasPrefix("env:arg:")
        let receiverText = receiver.map { expression -> String in
            let text = SwiftSyntaxSupport.collapsingWhitespace(expression.trimmedDescription)
            return text.count <= 60 ? text : "_"
        }
        let use = makeReference(name, kind: kind, position: position, receiver: receiverText, context: context)
        switch source {
        case .environment:
            if !isArguments { references.append(use) }
        case .arguments:
            if isArguments { references.append(use) }
        case .holder(let holder):
            pendingEnvironment.append(PendingEnvironment(holder: holder, isArguments: isArguments, reference: use))
        }
    }

    /// What an expression holds: the process environment or a launch environment (`ProcessInfo.processInfo.environment`,
    /// `app.launchEnvironment`, `process.environment`), launch arguments (`ProcessInfo.processInfo.arguments`,
    /// `CommandLine.arguments`, `app.launchArguments`), or what a local or property (`env`, `self.lastEnvironment`) holds.
    private func environmentSource(_ expression: ExprSyntax) -> EnvironmentSource? {
        let expression = SwiftTypeInference.unwrapped(expression)
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            guard reference.argumentNames == nil, SwiftSyntaxSupport.isReferenceToken(reference.baseName) else { return nil }
            let name = SwiftSyntaxSupport.identifierText(reference.baseName)
            return name.first?.isUppercase == true ? nil : .holder(holder(named: name))
        }
        guard let member = expression.as(MemberAccessExprSyntax.self), let base = member.base else { return nil }
        switch member.declName.baseName.text {
        case "environment", "launchEnvironment":
            return .environment
        case "launchArguments":
            return .arguments
        case "arguments":
            return isProcessInfo(base) || SwiftSyntaxSupport.typeChain(base)?.last == "CommandLine" ? .arguments : nil
        default:
            guard base.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self),
                  SwiftSyntaxSupport.isReferenceToken(member.declName.baseName) else { return nil }
            return .holder(Holder(scope: nil, name: SwiftSyntaxSupport.identifierText(member.declName.baseName)))
        }
    }

    /// `ProcessInfo.processInfo`, `ProcessInfo()`, or a local or property bound to one.
    private func isProcessInfo(_ expression: ExprSyntax) -> Bool {
        let expression = SwiftTypeInference.unwrapped(expression)
        if let member = expression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "processInfo", let base = member.base {
            return SwiftSyntaxSupport.typeChain(base)?.last == "ProcessInfo"
        }
        if let call = expression.as(FunctionCallExprSyntax.self), call.arguments.isEmpty, call.trailingClosure == nil {
            return SwiftSyntaxSupport.typeChain(call.calledExpression)?.last == "ProcessInfo"
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self), SwiftSyntaxSupport.isReferenceToken(reference.baseName) {
            return processInfoHolders.contains(holder(named: SwiftSyntaxSupport.identifierText(reference.baseName)))
        }
        return false
    }

    /// The holder a name means here: the innermost local or parameter, else a property or global of this file.
    private func holder(named name: String) -> Holder {
        for scope in scopes.reversed() where scope.bindings[name] != nil {
            return Holder(scope: scope.owner, name: name)
        }
        return Holder(scope: nil, name: name)
    }

    /// Emits the uses waiting on holders that hold the environment or launch arguments. Holders that exchange values
    /// hold the same: `var env = lastEnvironment` … `app.launchEnvironment = env` makes `lastEnvironment` one too.
    /// Called once, after the walk.
    func finishEnvironment() {
        defer {
            pendingEnvironment = []
            holderFlows = []
        }
        guard !pendingEnvironment.isEmpty else { return }
        var parent: [Holder: Holder] = [:]
        func root(_ holder: Holder) -> Holder {
            var current = holder
            while let next = parent[current] { current = next }
            return current
        }
        for (from, into) in holderFlows {
            let (a, b) = (root(from), root(into))
            if a != b { parent[a] = b }
        }
        let environments = Set(environmentHolders.map(root))
        let arguments = Set(argumentHolders.map(root))
        for pending in pendingEnvironment where (pending.isArguments ? arguments : environments).contains(root(pending.holder)) {
            references.append(pending.reference)
        }
    }

    // MARK: - Emission

    /// Appends a reference and returns its index, or nil when the name is not reported (a local, `$0`, a
    /// standard-library type or free function).
    @discardableResult
    private func emit(_ name: String, kind: ReferenceKind, at token: TokenSyntax, receiver: String?, context: ReferenceContext, call: CallShape? = nil) -> Int? {
        emit(name, kind: kind, position: token.positionAfterSkippingLeadingTrivia, receiver: receiver, context: context, call: call)
    }

    @discardableResult
    private func emit(_ rawName: String, kind: ReferenceKind, position: AbsolutePosition, receiver: String?, context: ReferenceContext, call: CallShape? = nil) -> Int? {
        var name = rawName
        var context = context
        if name.hasPrefix("$") {
            // `$0` is a closure argument; `$viewModel` is the projected value of `viewModel`.
            let rest = name.dropFirst()
            guard let first = rest.first, !first.isNumber else { return nil }
            name = String(rest)
            if context == .read { context = .projected }
        }
        guard name != "_", let first = name.first, first.isLetter || first == "_" else { return nil }
        if receiver == nil {
            // Unqualified standard-library types and free-function calls are noise; members never are.
            if SwiftSyntaxSupport.stdlibTypeNames.contains(name) { return nil }
            if kind == .call, SwiftSyntaxSupport.freeFunctionNames.contains(name) { return nil }
            if binding(for: name) != nil { return nil }
        }
        references.append(makeReference(name, kind: kind, position: position, receiver: receiver, context: context, call: call))
        return references.count - 1
    }

    /// A reference at `position`, in the current statement, symbol and `#if` clauses.
    private func makeReference(_ name: String, kind: ReferenceKind, position: AbsolutePosition, receiver: String?, context: ReferenceContext,
                               call: CallShape? = nil) -> ExtractedReference {
        let location = converter.location(for: position)
        let statement = statements.last.flatMap { $0.start <= location.line && location.line <= $0.end ? $0 : nil }
        return ExtractedReference(
            name: name,
            kind: kind,
            line: location.line,
            column: location.column,
            enclosingSymbol: openSymbols.last?.localID,
            receiver: receiver,
            statementLine: statement?.start,
            endLine: statement?.end,
            callEndLine: call?.endLine,
            context: context.rawValue,
            argumentLabels: call?.labels,
            conditions: conditions
        )
    }

    /// Writes the receiver types and declared types noted during the walk in the hint grammar, now that
    /// every expression's reference is known. Called once, after the walk.
    func finishTypes() {
        for (index, note) in receiverNotes {
            switch note {
            case .local(let type, let line):
                // A local the collector could not type is `?`: the linker must not type it as a property.
                let written = type.flatMap(hint(for:))
                references[index].receiverHint = written?.text ?? "?"
                references[index].receiverRef = written?.ref
                references[index].typeEvidenceLine = line
            case .value(let type):
                // `^` alone is implied by the pointer: a property's or chain's member carries only `receiverRef`.
                guard let written = hint(for: type) else { continue }
                references[index].receiverHint = written.text == "^" ? nil : written.text
                references[index].receiverRef = written.ref
            case .context(let type):
                guard let written = hint(for: type), SwiftTypeInference.canBeContext(written.text) else { continue }
                references[index].receiverHint = "ctx(" + written.text + ")"
                references[index].receiverRef = written.ref
            case .argument(let call, let position):
                guard let callee = producers[call] else { continue }
                references[index].receiverHint = "param(^," + String(position) + ")"
                references[index].receiverRef = callee
            case .component(let previous):
                references[index].receiverRef = previous
            }
        }
        for (symbol, type) in declaredTypes {
            guard let written = hint(for: type) else { continue }
            symbols[symbol].declaredType = written.text
            symbols[symbol].declaredTypeRef = written.ref
        }
        receiverNotes = []
        declaredTypes = []
        typeMemo = [:]
    }

    /// Appends a symbol. A function-local declaration (`isLocal`) hangs off the innermost open symbol, its
    /// function; anything declared inside a local type is local too. `declaredType` is written by `finishTypes`.
    private func addSymbol(
        name: String,
        kind: SymbolKind,
        range: LineRange,
        signature: String?,
        doc: String?,
        visibility: Visibility?,
        attributes: [String],
        inheritedTypes: [String] = [],
        bodyHash: UInt64? = nil,
        shape: CallableShape? = nil,
        setterVisibility: Visibility? = nil,
        declaredType: TypeExpr? = nil,
        isLocal: Bool = false
    ) -> Int {
        let localID = symbols.count
        if let declaredType { declaredTypes.append((localID, declaredType)) }
        let local = isLocal || containers.last?.isLocal == true
        symbols.append(ExtractedSymbol(
            localID: localID,
            parentLocalID: isLocal ? openSymbols.last?.localID : containers.last?.localID,
            name: name,
            kind: kind,
            range: range,
            signature: signature,
            doc: doc,
            visibility: visibility,
            isExported: !local && (visibility?.isExternallyVisible ?? false),
            attributes: attributes,
            inheritedTypes: inheritedTypes,
            complexity: 1,
            bodyHash: bodyHash,
            selector: shape?.selector,
            parameterFlags: shape?.flags,
            parameterTypes: shape?.types,
            setterVisibility: setterVisibility,
            conditions: conditions,
            isLocal: local
        ))
        return localID
    }

    // MARK: - Context stacks

    private func openSymbol(_ node: SyntaxIdentifier, _ localID: Int) {
        openSymbols.append(OpenSymbol(node: node, localID: localID))
    }

    private func pushScope(_ owner: SyntaxIdentifier, _ bindings: [String: LocalBinding], generics: [String: String] = [:]) {
        scopes.append(Scope(owner: owner, bindings: bindings, generics: generics))
    }

    /// Declares a name in the innermost scope; it shadows outer declarations for the rest of that scope.
    private func bind(_ name: String, _ binding: LocalBinding) {
        scopes[scopes.count - 1].bindings[name] = binding
    }

    /// The innermost local, parameter or local declaration with this name; nil for properties and globals.
    func binding(for name: String) -> LocalBinding? {
        for scope in scopes.reversed() {
            if let binding = scope.bindings[name] { return binding }
        }
        return nil
    }

    /// The type `self` has here: the enclosing type's dotted name (an extension names its type in full; a
    /// function-local type is not qualified by what encloses its function).
    var enclosingTypeName: String? {
        guard !containers.isEmpty else { return nil }
        var components: [String] = []
        for index in containers.indices.reversed() {
            let container = containers[index]
            components.insert(symbols[container.localID].name, at: 0)
            if container.kind == .extension { break }
            if container.isLocal && (index == 0 || !containers[index - 1].isLocal) { break }
        }
        return components.joined(separator: ".")
    }

    /// A statement or member declaration; one with a body counts only up to its `{`.
    private func openStatement(_ node: SyntaxIdentifier, _ content: Syntax) {
        let end = SwiftSyntaxSupport.bodyBrace(content)?.positionAfterSkippingLeadingTrivia ?? content.endPositionBeforeTrailingTrivia
        openStatement(node, from: content.positionAfterSkippingLeadingTrivia, to: end)
    }

    private func openStatement(_ node: SyntaxIdentifier, from start: AbsolutePosition, to end: AbsolutePosition) {
        let first = line(start)
        statements.append(Statement(node: node, start: first, end: max(first, line(end))))
    }

    private func decision() {
        decisionCount += 1
        for index in frames.indices {
            frames[index].decisions += 1
        }
    }

    /// Pops everything `node` pushed (in any combination of the context stacks).
    private func leave(_ node: SyntaxIdentifier) {
        if let frame = frames.last, frame.node == node {
            frames.removeLast()
            symbols[frame.localID].complexity = 1 + frame.decisions
        }
        if let open = openSymbols.last, open.node == node { openSymbols.removeLast() }
        if let container = containers.last, container.node == node { containers.removeLast() }
        if let scope = scopes.last, scope.owner == node { scopes.removeLast() }
        if let returnType = returnTypes.last, returnType.node == node { returnTypes.removeLast() }
        if let owner = bodyOwners.last, owner == node { bodyOwners.removeLast() }
        if let saved = savedBodyOwners.last, saved.node == node {
            bodyOwners = saved.owners
            savedBodyOwners.removeLast()
        }
        if let statement = statements.last, statement.node == node { statements.removeLast() }
    }

    // MARK: - Positions and text

    private func line(_ position: AbsolutePosition) -> Int {
        converter.location(for: position).line
    }

    private func lineRange(of node: some SyntaxProtocol) -> LineRange {
        LineRange(line(node.positionAfterSkippingLeadingTrivia), line(node.endPositionBeforeTrailingTrivia))
    }

    /// Start of a declaration header after its attributes: the first modifier, or the introducer keyword.
    private func headerStart(_ modifiers: DeclModifierListSyntax, _ keyword: TokenSyntax) -> AbsolutePosition {
        modifiers.isEmpty ? keyword.positionAfterSkippingLeadingTrivia : modifiers.positionAfterSkippingLeadingTrivia
    }

    private func text(from start: AbsolutePosition, to end: AbsolutePosition) -> String {
        let lower = max(0, min(start.utf8Offset, source.count))
        let upper = max(lower, min(end.utf8Offset, source.count))
        return String(decoding: source[lower..<upper], as: UTF8.self)
    }

    private func signature(from start: AbsolutePosition, to end: AbsolutePosition) -> String? {
        let compact = text(from: start, to: end).compactSignature()
        return compact.isEmpty ? nil : compact
    }

    /// A declaration header prefixed with its attributes (`@MainActor final class Store: ObservableObject`).
    private func signature(attributes: AttributeListSyntax, from start: AbsolutePosition, to end: AbsolutePosition) -> String? {
        let prefix = SwiftSyntaxSupport.signatureAttributes(attributes)
        let header = text(from: start, to: end)
        let compact = (prefix.isEmpty ? header : prefix + " " + header).compactSignature()
        return compact.isEmpty ? nil : compact
    }

    private func bodyHash(_ body: CodeBlockSyntax?) -> UInt64? {
        guard let body else { return nil }
        let lines = line(body.endPositionBeforeTrailingTrivia) - line(body.positionAfterSkippingLeadingTrivia) + 1
        guard lines >= 5 else { return nil }
        return SwiftSyntaxSupport.structuralHash(body)
    }
}
