import CTreeSitter
import VesaliusCore

/// TypeScript and JavaScript analyzer (including JSX/TSX) built on tree-sitter.
///
/// One iterative pass over the syntax tree extracts declarations, ES module / CommonJS imports and
/// exports, and references (calls, instantiations, type uses, heritage, JSX components, reads/writes).
/// Locals and parameters are tracked per function so unqualified references only name things that can
/// resolve outside the function. Every reference carries its statement span, whether it runs while the
/// module loads, and for a call bound to a local, the statement that consumes the result; environment
/// variables (`process.env.X`, `import.meta.env.X`) become `env:X` references.
public struct TypeScriptAnalyzer: LanguageAnalyzer {
    public init() {}

    public var identifier: String { "tree-sitter-typescript" }

    public var version: Int { 2 }

    public func canAnalyze(_ language: Language, path: String) -> Bool {
        language == .typescript || language == .javascript
    }

    public func analyze(_ file: SourceFile) throws -> FileAnalysis {
        let grammar = Self.grammar(for: file.path, language: file.language)
        let source = SourceBytes(file.text)
        let tree = try TreeSitterParser.parse(source.bytes, grammar: grammar)
        let tables: ScriptTables
        switch grammar {
        case .tsx: tables = tsxTables
        case .javascript: tables = javaScriptTables
        default: tables = typeScriptTables
        }
        var walker = ScriptWalker(source: source, tables: tables, isJSXFile: file.isJSX, root: tree.root)
        walker.run(tree.root)
        return FileAnalysis(
            symbols: walker.symbols.symbols,
            imports: walker.imports,
            references: walker.references,
            complexity: walker.complexity,
            syntaxErrorCount: TreeSitterUtilities.countSyntaxErrors(tree.root),
            exportedNames: walker.exportedNames,
            isEntryPoint: source.bytes.starts(with: [UInt8(ascii: "#"), UInt8(ascii: "!")])
        )
    }

    static func grammar(for path: String, language: Language) -> TreeSitterGrammar {
        let lower = path.lowercased()
        if lower.hasSuffix(".tsx") { return .tsx }
        if lower.hasSuffix(".ts") || lower.hasSuffix(".mts") || lower.hasSuffix(".cts") { return .typescript }
        if language == .typescript { return .typescript }
        return .javascript
    }
}

extension TypeScriptAnalyzer {
    /// Unqualified names the walker never records as references (`console`, `require`, `then`, `map`, …).
    static var stopNames: Set<String> { ScriptWalker.stopNames }
}

// MARK: - Grammar tables

/// Node kinds the script walker dispatches on. Raw values index `NodeKindTable`.
enum ScriptKind: UInt8 {
    case other = 0
    case program, comment, errorNode
    // Modules
    case importStatement, importClause, namedImports, importSpecifier, namespaceImport, importRequireClause, importKeyword
    case exportStatement, exportClause, exportSpecifier, namespaceExport
    // Declarations
    case classDeclaration, abstractClassDeclaration, classExpression, classHeritage, extendsClause, implementsClause, classBody
    case methodDefinition, publicFieldDefinition, fieldDefinition, methodSignature, abstractMethodSignature, propertySignature, indexSignature
    case interfaceDeclaration, interfaceBody, extendsTypeClause
    case typeAliasDeclaration, enumDeclaration, enumBody, enumAssignment
    case functionDeclaration, generatorFunctionDeclaration, functionSignature, functionExpression, generatorFunction, arrowFunction
    case lexicalDeclaration, variableDeclaration, variableDeclarator
    case internalModule, moduleDeclaration, ambientDeclaration
    case typeParameters, typeParameter
    // Expressions
    case callExpression, newExpression, memberExpression, subscriptExpression, nonNullExpression, awaitExpression
    case instantiationExpression, parenthesizedExpression, mappedTypeClause
    case assignmentExpression, augmentedAssignmentExpression
    case identifier, propertyIdentifier, privatePropertyIdentifier, shorthandPropertyIdentifier, shorthandPropertyIdentifierPattern
    case typeIdentifier, nestedTypeIdentifier, nestedIdentifier, genericType, predefinedType, statementIdentifier
    case this, superKeyword
    case formalParameters, requiredParameter, optionalParameter, restPattern, objectPattern, arrayPattern, pairPattern, assignmentPattern, objectAssignmentPattern
    case decorator, string, templateString, number, regex, trueLiteral, falseLiteral, nullLiteral, undefinedLiteral
    case pair, object, array, computedPropertyName
    case jsxElement, jsxOpeningElement, jsxSelfClosingElement, jsxClosingElement, jsxAttribute
    case statementBlock
    // Statements (spans), `delete`, `import.meta` and `typeof` in types
    case expressionStatement, returnStatement, throwStatement, switchStatement, tryStatement, unaryExpression, metaProperty, typeQuery
    // Control flow
    case ifStatement, forStatement, forInStatement, whileStatement, doStatement, switchCase, catchClause, ternaryExpression, binaryExpression
    // Anonymous tokens
    case tokDefault, tokType, tokAndAnd, tokOrOr, tokNullish, tokStatic, tokAsync, tokGet, tokSet, tokReadonly, tokAbstract, tokOverride, tokStar, tokDeclare, tokConst, tokLet, tokVar
}

struct ScriptFields: Sendable {
    let name, body, value, declaration, source, alias, function, object, property, constructor, arguments: TSFieldId
    let parameters, parameter, type, left, right, kind, decorator, `operator`, typeArguments, returnType: TSFieldId
    let key, pattern, module, typeParameters, constraint, member, attribute, index, consequence: TSFieldId

    init(language: OpaquePointer) {
        let table = FieldTable(language: language, names: [
            "name", "body", "value", "declaration", "source", "alias", "function", "object", "property", "constructor",
            "arguments", "parameters", "parameter", "type", "left", "right", "kind", "decorator", "operator",
            "type_arguments", "return_type", "key", "pattern", "module", "type_parameters", "constraint", "member", "attribute",
            "index", "consequence",
        ])
        name = table["name"]; body = table["body"]; value = table["value"]; declaration = table["declaration"]
        source = table["source"]; alias = table["alias"]; function = table["function"]; object = table["object"]
        property = table["property"]; constructor = table["constructor"]; arguments = table["arguments"]
        parameters = table["parameters"]; parameter = table["parameter"]; type = table["type"]; left = table["left"]
        right = table["right"]; kind = table["kind"]; decorator = table["decorator"]; `operator` = table["operator"]
        typeArguments = table["type_arguments"]; returnType = table["return_type"]; key = table["key"]
        pattern = table["pattern"]; module = table["module"]; typeParameters = table["type_parameters"]
        constraint = table["constraint"]; member = table["member"]; attribute = table["attribute"]; index = table["index"]
        consequence = table["consequence"]
    }
}

struct ScriptTables: Sendable {
    let kinds: NodeKindTable
    let fields: ScriptFields

    init(grammar: TreeSitterGrammar) {
        let language = grammar.language
        let named: [String: ScriptKind] = [
            "program": .program, "comment": .comment, "ERROR": .errorNode,
            "import_statement": .importStatement, "import_clause": .importClause, "named_imports": .namedImports,
            "import_specifier": .importSpecifier, "namespace_import": .namespaceImport, "import_require_clause": .importRequireClause,
            "import": .importKeyword,
            "export_statement": .exportStatement, "export_clause": .exportClause, "export_specifier": .exportSpecifier,
            "namespace_export": .namespaceExport,
            "class_declaration": .classDeclaration, "abstract_class_declaration": .abstractClassDeclaration, "class": .classExpression,
            "class_heritage": .classHeritage, "extends_clause": .extendsClause, "implements_clause": .implementsClause, "class_body": .classBody,
            "method_definition": .methodDefinition, "public_field_definition": .publicFieldDefinition, "field_definition": .fieldDefinition,
            "method_signature": .methodSignature, "abstract_method_signature": .abstractMethodSignature, "property_signature": .propertySignature,
            "index_signature": .indexSignature,
            "interface_declaration": .interfaceDeclaration, "interface_body": .interfaceBody, "extends_type_clause": .extendsTypeClause,
            "type_alias_declaration": .typeAliasDeclaration, "enum_declaration": .enumDeclaration, "enum_body": .enumBody,
            "enum_assignment": .enumAssignment,
            "function_declaration": .functionDeclaration, "generator_function_declaration": .generatorFunctionDeclaration,
            "function_signature": .functionSignature, "function_expression": .functionExpression, "function": .functionExpression,
            "generator_function": .generatorFunction, "arrow_function": .arrowFunction,
            "lexical_declaration": .lexicalDeclaration, "variable_declaration": .variableDeclaration, "variable_declarator": .variableDeclarator,
            "internal_module": .internalModule, "module": .moduleDeclaration, "ambient_declaration": .ambientDeclaration,
            "type_parameters": .typeParameters, "type_parameter": .typeParameter,
            "call_expression": .callExpression, "new_expression": .newExpression, "member_expression": .memberExpression,
            "subscript_expression": .subscriptExpression, "non_null_expression": .nonNullExpression, "await_expression": .awaitExpression,
            "instantiation_expression": .instantiationExpression, "parenthesized_expression": .parenthesizedExpression,
            "mapped_type_clause": .mappedTypeClause,
            "assignment_expression": .assignmentExpression, "augmented_assignment_expression": .augmentedAssignmentExpression,
            "identifier": .identifier, "property_identifier": .propertyIdentifier, "private_property_identifier": .privatePropertyIdentifier,
            "shorthand_property_identifier": .shorthandPropertyIdentifier,
            "shorthand_property_identifier_pattern": .shorthandPropertyIdentifierPattern,
            "type_identifier": .typeIdentifier, "nested_type_identifier": .nestedTypeIdentifier, "nested_identifier": .nestedIdentifier,
            "generic_type": .genericType, "predefined_type": .predefinedType, "statement_identifier": .statementIdentifier,
            "this": .this, "super": .superKeyword,
            "formal_parameters": .formalParameters, "required_parameter": .requiredParameter, "optional_parameter": .optionalParameter,
            "rest_pattern": .restPattern, "object_pattern": .objectPattern, "array_pattern": .arrayPattern, "pair_pattern": .pairPattern,
            "assignment_pattern": .assignmentPattern, "object_assignment_pattern": .objectAssignmentPattern,
            "decorator": .decorator, "string": .string, "template_string": .templateString, "number": .number, "regex": .regex,
            "true": .trueLiteral, "false": .falseLiteral, "null": .nullLiteral, "undefined": .undefinedLiteral,
            "pair": .pair, "object": .object, "array": .array, "computed_property_name": .computedPropertyName,
            "jsx_element": .jsxElement, "jsx_opening_element": .jsxOpeningElement, "jsx_self_closing_element": .jsxSelfClosingElement,
            "jsx_closing_element": .jsxClosingElement, "jsx_attribute": .jsxAttribute,
            "statement_block": .statementBlock,
            "expression_statement": .expressionStatement, "return_statement": .returnStatement, "throw_statement": .throwStatement,
            "switch_statement": .switchStatement, "try_statement": .tryStatement, "unary_expression": .unaryExpression,
            "meta_property": .metaProperty, "type_query": .typeQuery,
            "if_statement": .ifStatement, "for_statement": .forStatement, "for_in_statement": .forInStatement,
            "while_statement": .whileStatement, "do_statement": .doStatement, "switch_case": .switchCase,
            "catch_clause": .catchClause, "ternary_expression": .ternaryExpression, "binary_expression": .binaryExpression,
        ]
        let anonymous: [String: ScriptKind] = [
            "default": .tokDefault, "type": .tokType, "&&": .tokAndAnd, "||": .tokOrOr, "??": .tokNullish,
            "static": .tokStatic, "async": .tokAsync, "get": .tokGet, "set": .tokSet, "readonly": .tokReadonly,
            "abstract": .tokAbstract, "override": .tokOverride, "*": .tokStar, "declare": .tokDeclare,
            "const": .tokConst, "let": .tokLet, "var": .tokVar,
        ]
        kinds = NodeKindTable(
            language: language,
            named: named.mapValues(\.rawValue),
            anonymous: anonymous.mapValues(\.rawValue)
        )
        fields = ScriptFields(language: language)
    }
}

private let typeScriptTables = ScriptTables(grammar: .typescript)
private let tsxTables = ScriptTables(grammar: .tsx)
private let javaScriptTables = ScriptTables(grammar: .javascript)

// MARK: - Walker

private struct ScriptWalker {
    struct Context {
        /// Innermost emitted symbol (attribution of references).
        var enclosing: Int?
        /// Innermost function-like symbol (attribution of complexity).
        var owner: Int?
        var scope: LocalScope?
        /// Declarations at this level become symbols (program, namespace bodies).
        var topLevel: Bool
        /// Identifiers are assignment targets.
        var write: Bool
        /// Inside a function body or an instance field initializer: runs when called, not while the module loads.
        var deferred = false
        /// Lines of the innermost enclosing statement (only the header of a compound statement); 0 when none.
        var statementStart = 0
        var statementEnd = 0
        /// Inside a `typeof x` type query: value names used as types.
        var typeQuery = false
        /// The operand of `delete`.
        var deleting = false
    }

    struct Frame {
        var node: TSNode
        var context: Context
    }

    /// A local binding: the scope that declares it and its name. The key holds the scope, so a scope that has
    /// gone out of the walk can never lend its address (and identity) to a later one.
    struct Binding: Hashable {
        let scope: LocalScope
        let name: String

        static func == (lhs: Binding, rhs: Binding) -> Bool {
            lhs.scope === rhs.scope && lhs.name == rhs.name
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(scope))
            hasher.combine(name)
        }
    }

    /// The parameter of `import("m").then(…)` that receives the module.
    enum ImportCallback {
        /// `m => …`: the module object, under a file-unique alias (`m@11`).
        case namespace(name: String, alias: String)
        /// `({ A, B }) => …`: names imported from the module, not locals.
        case names([String])
    }

    let source: SourceBytes
    let kinds: NodeKindTable
    let f: ScriptFields
    let isJSXFile: Bool

    var symbols = SymbolCollector()
    var imports: [ExtractedImport] = []
    var references: [ExtractedReference] = []
    var exportedNames: [String] = []
    var complexity = 1
    private var stack: [Frame] = []
    private let cursor: ReusableCursor
    /// Call and `new` nodes (by start byte) whose result is bound to a local, or returned (`"return"`).
    private var pendingAssignments: [Int: String] = [:]
    /// Names that receive a call result somewhere in the file; only their reads are recorded.
    private var assignedNames: Set<String> = []
    /// References whose call result is bound to locals, with the binding scope.
    private var assignments: [(reference: Int, scope: LocalScope, names: [String])] = []
    /// Reads of local bindings: the head line of the reading statement and the line of the read.
    private var localReads: [Binding: [(head: Int, line: Int)]] = [:]
    /// Callbacks (by start byte) whose first parameter receives a dynamically imported module.
    private var importCallbacks: [Int: ImportCallback] = [:]
    /// True once a module alias is in scope somewhere, so receivers are only rewritten when one can apply.
    private var hasImportAliases = false

    init(source: SourceBytes, tables: ScriptTables, isJSXFile: Bool, root: TSNode) {
        self.source = source
        self.kinds = tables.kinds
        self.f = tables.fields
        self.isJSXFile = isJSXFile
        self.cursor = ReusableCursor(root)
        stack.reserveCapacity(256)
    }

    /// Named children (collected, so callers may iterate freely).
    private func kids(_ node: TSNode) -> [TSNode] {
        cursor.children(of: node, namedOnly: true)
    }

    private func kids(_ node: TSNode, field: TSFieldId) -> [TSNode] {
        cursor.children(of: node, field: field)
    }

    // MARK: Stoplists

    static let stopNames: Set<String> = [
        "console", "require", "module", "exports", "window", "document", "globalThis", "process", "Object", "Array",
        "String", "Number", "Boolean", "Promise", "JSON", "Math", "Date", "Error", "Map", "Set", "Symbol", "undefined",
        "NaN", "Infinity", "this", "super", "push", "map", "filter", "reduce", "forEach", "then", "catch", "finally",
        "length", "toString", "includes", "indexOf", "slice", "splice", "join", "split", "keys", "values", "entries",
        "parseInt", "parseFloat", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "arguments",
    ]

    /// Receivers whose members are platform APIs rather than repository code (`import` stands for `import.meta`).
    /// Environment variables are read before this list applies (`process.env.X`, `import.meta.env.X`).
    static let globalReceivers: Set<String> = [
        "console", "window", "document", "globalThis", "process", "Object", "Array", "String", "Number", "Boolean",
        "Promise", "JSON", "Math", "Date", "Reflect", "Symbol", "Intl", "navigator", "localStorage", "sessionStorage",
        "import",
    ]

    /// `vi`/`jest` calls that name a module to replace (or, for `*Actual`, load for real) inside a test.
    static let mockCalls: Set<String> = [
        "mock", "doMock", "unmock", "doUnmock", "setMock", "importMock", "requireMock", "importActual", "requireActual",
    ]

    /// Built-in and utility types that never resolve to repository declarations.
    static let builtinTypes: Set<String> = [
        "Array", "ReadonlyArray", "Promise", "PromiseLike", "Record", "Partial", "Required", "Readonly", "Pick", "Omit",
        "Exclude", "Extract", "ReturnType", "Parameters", "InstanceType", "NonNullable", "Awaited", "Map", "Set", "WeakMap",
        "WeakSet", "Date", "Error", "Function", "Object", "String", "Number", "Boolean", "Symbol", "Iterable", "Iterator",
        "AsyncIterable", "AsyncIterator", "Generator", "AsyncGenerator", "Uppercase", "Lowercase", "Capitalize", "RegExp",
        "ArrayLike", "ThisType", "ConstructorParameters", "Uncapitalize",
    ]

    // MARK: Driver

    mutating func run(_ root: TSNode) {
        stack.append(Frame(node: root, context: Context(enclosing: nil, owner: nil, scope: nil, topLevel: true, write: false)))
        while let frame = stack.popLast() {
            visit(frame.node, frame.context)
        }
        // The consuming statement of a bound call result: the first later statement that reads the local.
        for assignment in assignments {
            let after = references[assignment.reference].endLine ?? references[assignment.reference].line
            var first: Int?
            for name in assignment.names {
                for read in localReads[Binding(scope: assignment.scope, name: name)] ?? [] where read.line > after {
                    first = min(first ?? read.head, read.head)
                }
            }
            references[assignment.reference].consumerLine = first
        }
    }

    /// The value inside `await`, parentheses, `!`, `as T` and `satisfies T`.
    private func unwrapValue(_ node: TSNode) -> TSNode {
        var current = node
        while true {
            switch kind(current) {
            case .awaitExpression, .parenthesizedExpression, .nonNullExpression:
                guard let inner = kids(current).first else { return current }
                current = inner
            default:
                let type = current.typeName
                if type == "as_expression" || type == "satisfies_expression", let inner = kids(current).first {
                    current = inner
                } else {
                    return current
                }
            }
        }
    }

    /// Lines of a statement: the whole of a simple statement, the header of a compound statement or declaration.
    private func statementSpan(_ node: TSNode) -> (start: Int, end: Int)? {
        switch kind(node) {
        case .expressionStatement, .returnStatement, .throwStatement, .lexicalDeclaration, .variableDeclaration,
             .typeAliasDeclaration, .functionSignature, .importStatement:
            return (node.startLine, node.endLine)
        case .exportStatement:
            // `export class A {` is a header; `export const a = …` and `export default f(…)` are whole statements.
            if let declaration = node.field(f.declaration) ?? node.field(f.value), let end = headerEnd(declaration) {
                return (node.startLine, end)
            }
            return (node.startLine, node.endLine)
        case .ifStatement, .whileStatement, .forStatement, .forInStatement, .switchStatement, .switchCase, .catchClause,
             .functionDeclaration, .generatorFunctionDeclaration, .classDeclaration, .abstractClassDeclaration,
             .interfaceDeclaration, .enumDeclaration, .internalModule, .moduleDeclaration:
            return (node.startLine, headerEnd(node) ?? node.startLine)
        default:
            return nil
        }
    }

    /// Last line of a compound node's header (everything before its body); nil when the node has no body.
    private func headerEnd(_ node: TSNode) -> Int? {
        guard let body = node.field(f.body) ?? node.field(f.consequence) else { return nil }
        var end = node.startLine
        for child in kids(node) where child.startByte < body.startByte {
            end = max(end, child.endLine)
        }
        return end
    }

    /// `context` inside the statement spanning `start...end`.
    private func inStatement(_ context: Context, _ start: Int, _ end: Int) -> Context {
        var inner = context
        inner.statementStart = start
        inner.statementEnd = max(start, end)
        return inner
    }

    @inline(__always)
    private func kind(_ node: TSNode) -> ScriptKind {
        ScriptKind(rawValue: kinds.code(node)) ?? .other
    }

    private func text(_ node: TSNode) -> String {
        source.text(node)
    }

    private mutating func push(_ node: TSNode?, _ context: Context) {
        guard let node else { return }
        stack.append(Frame(node: node, context: context))
    }

    /// Pushes nodes so they are processed in the given (source) order.
    private mutating func pushInOrder(_ nodes: [TSNode?], _ context: Context) {
        for node in nodes.reversed() {
            if let node { stack.append(Frame(node: node, context: context)) }
        }
    }

    private mutating func pushChildren(_ node: TSNode, _ context: Context) {
        let start = stack.count
        let cursor = self.cursor
        guard cursor.begin(node) else { return }
        repeat {
            let child = cursor.current
            if ts_node_is_named(child) {
                stack.append(Frame(node: child, context: context))
            }
        } while cursor.next()
        if stack.count - start > 1 {
            stack[start..<stack.count].reverse()
        }
    }

    private func hasToken(_ node: TSNode, _ token: ScriptKind) -> Bool {
        cursor.hasAnonymousChild(of: node, table: kinds, code: token.rawValue)
    }

    // MARK: Dispatch

    private mutating func visit(_ node: TSNode, _ context: Context) {
        var context = context
        if let span = statementSpan(node) {
            context = inStatement(context, span.start, span.end)
        }
        switch kind(node) {
        case .returnStatement:
            if let value = kids(node).first {
                let target = unwrapValue(value)
                if kind(target) == .callExpression || kind(target) == .newExpression { pendingAssignments[target.startByte] = "return" }
            }
            pushChildren(node, context)
        case .unaryExpression:
            var inner = context
            if let op = node.field(f.operator), text(op) == "delete" {
                inner.write = true
                inner.deleting = true
            }
            pushChildren(node, inner)
        case .typeQuery:
            var inner = context
            inner.typeQuery = true
            pushChildren(node, inner)
        case .comment, .string, .number, .regex, .trueLiteral, .falseLiteral, .nullLiteral, .undefinedLiteral,
             .propertyIdentifier, .privatePropertyIdentifier, .statementIdentifier, .predefinedType, .this, .superKeyword,
             .jsxClosingElement:
            return
        case .importStatement:
            visitImport(node)
        case .exportStatement:
            visitExport(node, context)
        case .classDeclaration, .abstractClassDeclaration:
            visitClass(node, context, declaredName: nil, exportNode: nil, isDefault: false)
        case .classExpression:
            visitClass(node, context, declaredName: nil, exportNode: nil, isDefault: false, emitSymbol: false)
        case .interfaceDeclaration:
            visitInterface(node, context, exportNode: nil)
        case .typeAliasDeclaration:
            visitTypeAlias(node, context, exportNode: nil)
        case .enumDeclaration:
            visitEnum(node, context, exportNode: nil)
        case .functionDeclaration, .generatorFunctionDeclaration, .functionSignature:
            visitFunctionDeclaration(node, context, exportNode: nil, isDefault: false)
        case .lexicalDeclaration, .variableDeclaration:
            visitVariableDeclaration(node, context, exportNode: nil, isDefault: false)
        case .internalModule, .moduleDeclaration:
            visitNamespace(node, context, exportNode: nil)
        case .callExpression:
            visitCall(node, context)
        case .newExpression:
            visitNew(node, context)
        case .memberExpression:
            visitMember(node, context)
        case .subscriptExpression:
            var objectContext = context
            objectContext.write = false
            if let object = node.field(f.object), let chain = identifierChain(object), Self.isEnvironment(chain) {
                // `process.env["X"]` names one variable; `process.env[key]` could be any of them.
                let access: ReferenceKind = context.write ? .write : .read
                if let index = node.field(f.index), kind(index) == .string {
                    emit("env:" + stringValue(index), access, index, context, receiver: chain, role: context.deleting ? .delete : .env)
                } else {
                    emit("env:*", access, node, context, receiver: chain, role: .envDynamic)
                    push(node.field(f.index), objectContext)
                }
                return
            }
            pushInOrder([node.field(f.object), node.field(f.index)], objectContext)
        case .assignmentExpression, .augmentedAssignmentExpression:
            visitAssignment(node, context)
        case .identifier:
            visitIdentifier(node, context)
        case .shorthandPropertyIdentifier, .shorthandPropertyIdentifierPattern:
            visitIdentifier(node, context)
        case .typeIdentifier:
            emitType(text(node), node, context)
        case .nestedTypeIdentifier:
            if let name = node.field(f.name) {
                emitType(text(name), name, context, receiver: node.field(f.module).map(text))
            }
        case .typeParameters:
            visitTypeParameters(node, context)
        case .mappedTypeClause:
            // `[K in keyof T]`: K is a binding; only the constraint and alias are references.
            pushInOrder([node.field(f.type), node.field(f.alias)], context)
        case .indexSignature:
            // `[key: string]: Value` — the key name is a binding, only the types are references.
            for child in kids(node) where kind(child) != .identifier {
                push(child, context)
            }
        case .jsxOpeningElement, .jsxSelfClosingElement:
            visitJSX(node, context)
        case .jsxAttribute:
            // Attribute names are not references; only values are.
            for child in kids(node) where kind(child) != .propertyIdentifier {
                push(child, context)
            }
        case .arrowFunction, .functionExpression, .generatorFunction:
            visitFunctionBody(node, context, symbol: nil)
        case .methodDefinition:
            // Object-literal method (class methods are handled by visitClassBody).
            visitFunctionBody(node, context, symbol: nil)
        case .pair:
            if let key = node.field(f.key), kind(key) == .computedPropertyName { push(key, context) }
            push(node.field(f.value), context)
        case .decorator:
            visitDecorator(node, context)
        case .catchClause:
            countDecision(context)
            let scope = LocalScope(parent: context.scope)
            if let parameter = node.field(f.parameter) { collectPatternNames(parameter, into: scope) }
            var inner = context
            inner.scope = scope
            inner.topLevel = false
            pushInOrder([node.field(f.type), node.field(f.body)], inner)
        case .forInStatement:
            countDecision(context)
            let scope = LocalScope(parent: context.scope)
            if let left = node.field(f.left) {
                if kind(left) == .memberExpression || kind(left) == .subscriptExpression {
                    var write = context
                    write.write = true
                    push(left, write)
                } else {
                    collectPatternNames(left, into: scope)
                }
            }
            var inner = context
            inner.scope = scope
            inner.topLevel = false
            pushInOrder([node.field(f.right), node.field(f.body)], inner)
        case .ifStatement, .forStatement, .whileStatement, .doStatement, .switchCase, .ternaryExpression:
            countDecision(context)
            var inner = context
            inner.topLevel = false
            pushChildren(node, inner)
        case .binaryExpression:
            if let op = node.field(f.operator) {
                let opKind = kind(op)
                if opKind == .tokAndAnd || opKind == .tokOrOr || opKind == .tokNullish { countDecision(context) }
            }
            var inner = context
            inner.write = false
            pushChildren(node, inner)
        case .statementBlock:
            // Every statement in a block sets its own span; nothing inherits the span of the code around the block.
            var inner = inStatement(context, 0, 0)
            inner.topLevel = false
            pushChildren(node, inner)
        case .ambientDeclaration:
            pushChildren(node, context)
        default:
            pushChildren(node, context)
        }
    }

    // MARK: Modules

    private mutating func addImport(_ specifier: String, names: [ImportedName], line: Int, typeOnly: Bool = false, reExport: Bool = false,
                                    dynamic: Bool = false, sideEffect: Bool = false, mock: Bool = false, endLine: Int? = nil) {
        guard !specifier.isEmpty else { return }
        let kind: ImportKind = specifier.hasPrefix(".") || specifier.hasPrefix("/") ? .relative : .module
        imports.append(ExtractedImport(module: specifier, kind: kind, names: names, line: line, isTypeOnly: typeOnly, isReExport: reExport,
                                       isDynamic: dynamic, isSideEffect: sideEffect, isMock: mock, endLine: endLine))
    }

    /// A value that loads a module: `require("m")` → ("m", false); `import("m")`, possibly awaited → ("m", true).
    private func moduleCall(_ value: TSNode) -> (specifier: String, dynamic: Bool)? {
        let call = unwrapValue(value)
        guard kind(call) == .callExpression, let function = call.field(f.function), let arguments = call.field(f.arguments),
              let first = kids(arguments).first, kind(first) == .string else { return nil }
        if kind(function) == .importKeyword { return (stringValue(first), true) }
        if kind(function) == .identifier, text(function) == "require" { return (stringValue(first), false) }
        return nil
    }

    /// `import("m")`, possibly awaited or parenthesised → the call node and its specifier.
    private func dynamicImportCall(_ node: TSNode) -> (call: TSNode, specifier: String)? {
        let call = unwrapValue(node)
        guard kind(call) == .callExpression, let function = call.field(f.function), kind(function) == .importKeyword,
              let arguments = call.field(f.arguments), let first = kids(arguments).first, kind(first) == .string else { return nil }
        return (call, stringValue(first))
    }

    /// `process.env` and `import.meta.env`: the object whose members are environment variables.
    private static func isEnvironment(_ chain: String) -> Bool {
        chain == "process.env" || chain == "import.meta.env"
    }

    private func stringValue(_ node: TSNode) -> String {
        TreeSitterUtilities.unquote(text(node))
    }

    /// Name text for import/export specifiers (identifiers or string module names).
    private func specifierName(_ node: TSNode?) -> String? {
        guard let node else { return nil }
        return kind(node) == .string ? stringValue(node) : text(node)
    }

    private mutating func visitImport(_ node: TSNode) {
        let typeOnly = hasToken(node, .tokType)
        guard let sourceNode = node.field(f.source) else {
            // TypeScript `import x = require("m")`.
            for child in kids(node) where kind(child) == .importRequireClause {
                let local = kids(child).first { kind($0) == .identifier }.map(text)
                if let specifier = child.field(f.source).map(stringValue) {
                    addImport(specifier, names: local.map { [ImportedName(name: "*", alias: $0)] } ?? [], line: node.startLine,
                              typeOnly: typeOnly, endLine: node.endLine)
                }
            }
            return
        }
        var names: [ImportedName] = []
        for child in kids(node) where kind(child) == .importClause {
            for part in kids(child) {
                switch kind(part) {
                case .identifier:
                    names.append(ImportedName(name: "default", alias: text(part)))
                case .namespaceImport:
                    if let local = kids(part).first(where: { kind($0) == .identifier }) {
                        names.append(ImportedName(name: "*", alias: text(local)))
                    }
                case .namedImports:
                    for specifier in kids(part) where kind(specifier) == .importSpecifier {
                        guard let name = specifierName(specifier.field(f.name)) else { continue }
                        let alias = specifierName(specifier.field(f.alias))
                        names.append(ImportedName(name: name, alias: alias == name ? nil : alias, isTypeOnly: hasToken(specifier, .tokType)))
                    }
                default:
                    break
                }
            }
        }
        // `import "./styles.css"` binds nothing: the module is loaded only for its side effects.
        let hasClause = kids(node).contains { kind($0) == .importClause }
        addImport(stringValue(sourceNode), names: names, line: node.startLine, typeOnly: typeOnly, sideEffect: !hasClause, endLine: node.endLine)
    }

    private mutating func visitExport(_ node: TSNode, _ context: Context) {
        let isDefault = hasToken(node, .tokDefault)
        if let sourceNode = node.field(f.source) {
            var names: [ImportedName] = []
            var sawClause = false
            for child in kids(node) {
                switch kind(child) {
                case .exportClause:
                    sawClause = true
                    for specifier in kids(child) where kind(specifier) == .exportSpecifier {
                        guard let name = specifierName(specifier.field(f.name)) else { continue }
                        let alias = specifierName(specifier.field(f.alias))
                        names.append(ImportedName(name: name, alias: alias == name ? nil : alias, isTypeOnly: hasToken(specifier, .tokType)))
                    }
                case .namespaceExport:
                    sawClause = true
                    if let local = kids(child).first {
                        names.append(ImportedName(name: "*", alias: specifierName(local)))
                    }
                default:
                    break
                }
            }
            if !sawClause { names = [ImportedName(name: "*")] }
            addImport(stringValue(sourceNode), names: names, line: node.startLine, typeOnly: hasToken(node, .tokType), reExport: true, endLine: node.endLine)
            return
        }

        if let declaration = node.field(f.declaration) {
            visitExportedDeclaration(declaration, context, exportNode: node, isDefault: isDefault)
            return
        }

        if let value = node.field(f.value) {
            switch kind(value) {
            case .identifier:
                exportedNames.append("default=\(text(value))")
            case .classExpression:
                visitClass(value, context, declaredName: value.field(f.name).map(text) ?? "default", exportNode: node, isDefault: true)
            case .functionExpression, .generatorFunction, .arrowFunction:
                let name = value.field(f.name).map(text) ?? "default"
                let symbol = addFunctionSymbol(name: name, function: value, outer: node, context: context, exported: true, isDefault: true)
                visitFunctionBody(value, context, symbol: symbol)
            default:
                push(value, context)
            }
            return
        }

        var handled = false
        for child in kids(node) {
            switch kind(child) {
            case .exportClause:
                handled = true
                for specifier in kids(child) where kind(specifier) == .exportSpecifier {
                    guard let local = specifierName(specifier.field(f.name)) else { continue }
                    let exported = specifierName(specifier.field(f.alias)) ?? local
                    exportedNames.append("\(exported)=\(local)")
                }
            case .identifier where !handled:
                // TypeScript `export = Foo`.
                exportedNames.append("default=\(text(child))")
                handled = true
            case .decorator:
                break
            default:
                push(child, context)
            }
        }
    }

    private mutating func visitExportedDeclaration(_ declaration: TSNode, _ context: Context, exportNode: TSNode, isDefault: Bool) {
        switch kind(declaration) {
        case .classDeclaration, .abstractClassDeclaration:
            visitClass(declaration, context, declaredName: nil, exportNode: exportNode, isDefault: isDefault)
        case .functionDeclaration, .generatorFunctionDeclaration, .functionSignature:
            visitFunctionDeclaration(declaration, context, exportNode: exportNode, isDefault: isDefault)
        case .lexicalDeclaration, .variableDeclaration:
            visitVariableDeclaration(declaration, context, exportNode: exportNode, isDefault: isDefault)
        case .interfaceDeclaration:
            visitInterface(declaration, context, exportNode: exportNode)
        case .typeAliasDeclaration:
            visitTypeAlias(declaration, context, exportNode: exportNode)
        case .enumDeclaration:
            visitEnum(declaration, context, exportNode: exportNode)
        case .internalModule, .moduleDeclaration:
            visitNamespace(declaration, context, exportNode: exportNode)
        case .ambientDeclaration:
            for child in kids(declaration) {
                visitExportedDeclaration(child, context, exportNode: exportNode, isDefault: isDefault)
            }
        default:
            push(declaration, context)
        }
    }

    // MARK: Symbols helpers

    private func docComment(before node: TSNode) -> String? {
        guard let previous = node.previousSibling, kind(previous) == .comment else { return nil }
        guard previous.endLine >= node.startLine - 1 else { return nil }
        let comment = text(previous)
        guard comment.hasPrefix("/**") else { return nil }
        return comment.cleanedDocComment()
    }

    private func signature(_ node: TSNode, upTo limit: TSNode?) -> String {
        source.text(node, upTo: limit).compactSignature()
    }

    /// Parent for a new symbol: the enclosing symbol when it can own declarations.
    private func parent(_ context: Context) -> Int? {
        context.enclosing
    }

    private func range(_ outer: TSNode, _ node: TSNode) -> LineRange {
        LineRange(outer.startLine, node.endLine)
    }

    private func decoratorAttribute(_ decorator: TSNode) -> String? {
        guard let expression = kids(decorator).first else { return nil }
        switch kind(expression) {
        case .callExpression:
            guard let function = expression.field(f.function) else { return nil }
            return "@" + text(function)
        default:
            return "@" + text(expression)
        }
    }

    private mutating func visitDecorator(_ decorator: TSNode, _ context: Context) {
        guard let expression = kids(decorator).first else { return }
        var target = expression
        var callEnd: Int?
        if kind(expression) == .callExpression {
            if let arguments = expression.field(f.arguments) { push(arguments, context) }
            guard let function = expression.field(f.function) else { return }
            target = function
            callEnd = expression.endLine
        }
        switch kind(target) {
        case .identifier:
            emit(text(target), .decorator, target, context, callEnd: callEnd)
        case .memberExpression:
            if let property = target.field(f.property), let object = target.field(f.object) {
                emit(text(property), .decorator, property, context, receiver: receiverText(object, context), callEnd: callEnd)
            }
        default:
            push(target, context)
        }
    }

    private mutating func addFunctionSymbol(name: String, function: TSNode, outer: TSNode, context: Context, exported: Bool, isDefault: Bool, signatureNode: TSNode? = nil, signaturePrefix: String = "") -> Int {
        var attributes: [String] = []
        if isDefault { attributes.append("default") }
        if hasToken(function, .tokAsync) { attributes.append("async") }
        let kind: SymbolKind = isJSXFile && TreeSitterUtilities.isPascalCase(name) ? .component : .function
        let header = signaturePrefix + source.text(signatureNode ?? function, upTo: function.field(f.body))
        return symbols.add(
            name: name,
            kind: kind,
            range: range(outer, function),
            parent: parent(context),
            signature: header.compactSignature(),
            doc: docComment(before: outer),
            isExported: exported,
            attributes: attributes
        )
    }

    // MARK: Functions

    private mutating func visitFunctionDeclaration(_ node: TSNode, _ context: Context, exportNode: TSNode?, isDefault: Bool) {
        let name = node.field(f.name).map(text) ?? "default"
        let symbol = addFunctionSymbol(name: name, function: node, outer: exportNode ?? node, context: context, exported: exportNode != nil, isDefault: isDefault)
        visitFunctionBody(node, context, symbol: symbol)
    }

    /// Analyzes parameters, return type and body of any function-like node in a fresh local scope.
    private mutating func visitFunctionBody(_ function: TSNode, _ context: Context, symbol: Int?) {
        let scope = LocalScope(parent: context.scope)
        collectTypeParameterNames(function, into: scope)
        collectParameterNames(function, into: scope)
        if let callback = importCallbacks.removeValue(forKey: function.startByte) {
            switch callback {
            case .namespace(let name, let alias):
                // `m` stays a local (a bare `m` is no reference); `m.X` is rewritten to `m@11.X`.
                scope.importAliases[name] = alias
                hasImportAliases = true
            case .names(let names):
                for name in names { scope.remove(name) }
            }
        }
        let body = function.field(f.body)
        if let body, kind(body) == .statementBlock {
            collectLocals(body, into: scope)
        }
        var inner = context
        inner.scope = scope
        inner.topLevel = false
        inner.write = false
        inner.deferred = true
        if let symbol {
            inner.enclosing = symbol
            inner.owner = symbol
            if let body, body.endLine - body.startLine + 1 >= 5 {
                symbols[symbol].bodyHash = hashBody(body)
            }
        }
        var parts: [TSNode?] = []
        if let typeParameters = function.field(f.typeParameters) { parts.append(typeParameters) }
        if let parameters = function.field(f.parameters) {
            for parameter in kids(parameters) {
                parts.append(contentsOf: parameterParts(parameter))
            }
        }
        parts.append(function.field(f.returnType))
        parts.append(body)
        pushInOrder(parts, inner)
    }

    /// Type annotations, default values and decorators of a parameter (never the bound names).
    private func parameterParts(_ parameter: TSNode) -> [TSNode?] {
        switch kind(parameter) {
        case .requiredParameter, .optionalParameter:
            var parts: [TSNode?] = kids(parameter, field: f.decorator)
            parts.append(parameter.field(f.type))
            parts.append(parameter.field(f.value))
            if let pattern = parameter.field(f.pattern) { parts.append(contentsOf: patternDefaults(pattern)) }
            return parts
        case .assignmentPattern:
            return [parameter.field(f.right)] + (parameter.field(f.left).map(patternDefaults) ?? [])
        case .objectPattern, .arrayPattern, .restPattern:
            return patternDefaults(parameter)
        case .decorator:
            return [parameter]
        default:
            return []
        }
    }

    /// Default-value expressions inside a destructuring pattern.
    private func patternDefaults(_ pattern: TSNode) -> [TSNode?] {
        var result: [TSNode?] = []
        var pending = [pattern]
        while let node = pending.popLast() {
            switch kind(node) {
            case .assignmentPattern, .objectAssignmentPattern:
                result.append(node.field(f.right))
                if let left = node.field(f.left) { pending.append(left) }
            case .pairPattern:
                if let value = node.field(f.value) { pending.append(value) }
                if let key = node.field(f.key), kind(key) == .computedPropertyName { result.append(key) }
            case .objectPattern, .arrayPattern, .restPattern:
                pending.append(contentsOf: kids(node))
            default:
                break
            }
        }
        return result
    }

    private func collectParameterNames(_ function: TSNode, into scope: LocalScope) {
        if let single = function.field(f.parameter) {
            collectPatternNames(single, into: scope)
        }
        guard let parameters = function.field(f.parameters) else { return }
        for parameter in kids(parameters) {
            switch kind(parameter) {
            case .requiredParameter, .optionalParameter:
                if let pattern = parameter.field(f.pattern) ?? parameter.field(f.name) {
                    collectPatternNames(pattern, into: scope)
                }
            default:
                collectPatternNames(parameter, into: scope)
            }
        }
    }

    private func collectTypeParameterNames(_ node: TSNode, into scope: LocalScope) {
        guard let typeParameters = node.field(f.typeParameters) else { return }
        for parameter in kids(typeParameters) where kind(parameter) == .typeParameter {
            if let name = parameter.field(f.name) { scope.insert(text(name)) }
        }
    }

    /// Binding names in a pattern (identifiers, shorthand properties), skipping keys and default values.
    private func collectPatternNames(_ pattern: TSNode, into scope: LocalScope) {
        var pending = [pattern]
        while let node = pending.popLast() {
            switch kind(node) {
            case .identifier, .shorthandPropertyIdentifierPattern:
                scope.insert(text(node))
            case .pairPattern:
                if let value = node.field(f.value) { pending.append(value) }
            case .assignmentPattern, .objectAssignmentPattern:
                if let left = node.field(f.left) { pending.append(left) }
            case .objectPattern, .arrayPattern, .restPattern:
                pending.append(contentsOf: kids(node))
            case .requiredParameter, .optionalParameter:
                if let inner = node.field(f.pattern) ?? node.field(f.name) { pending.append(inner) }
            default:
                break
            }
        }
    }

    /// Declarations inside a function body (not nested functions): variables, nested function and class
    /// names, catch parameters, loop variables.
    private func collectLocals(_ body: TSNode, into scope: LocalScope) {
        var pending = [body]
        while let node = pending.popLast() {
            switch kind(node) {
            case .variableDeclarator:
                if let name = node.field(f.name) {
                    // `const { a } = await import("m")` and `require("m")` bind imports, not locals.
                    if let value = node.field(f.value), moduleCall(value) != nil { break }
                    collectPatternNames(name, into: scope)
                }
            case .functionDeclaration, .generatorFunctionDeclaration, .classDeclaration, .abstractClassDeclaration:
                if let name = node.field(f.name) { scope.insert(text(name)) }
            case .enumDeclaration:
                if let name = node.field(f.name) { scope.insert(text(name)) }
            case .catchClause:
                if let parameter = node.field(f.parameter) { collectPatternNames(parameter, into: scope) }
                if let body = node.field(f.body) { pending.append(body) }
            case .forInStatement:
                if let left = node.field(f.left), kind(left) != .memberExpression, kind(left) != .subscriptExpression {
                    collectPatternNames(left, into: scope)
                }
                if let body = node.field(f.body) { pending.append(body) }
            case .statementBlock, .ifStatement, .forStatement, .whileStatement, .doStatement, .lexicalDeclaration, .variableDeclaration:
                pending.append(contentsOf: kids(node))
            case .other:
                // Statement containers without dedicated kinds: else/finally/switch body/labeled statements.
                let type = node.typeName
                if type == "else_clause" || type == "finally_clause" || type == "switch_body" || type == "switch_case"
                    || type == "switch_default" || type == "labeled_statement" {
                    pending.append(contentsOf: kids(node))
                }
            case .switchCase, .tryStatement, .switchStatement:
                // These have their own kinds (statement spans); their locals belong to the function all the same.
                pending.append(contentsOf: kids(node))
            default:
                break
            }
        }
    }

    private func hashBody(_ body: TSNode) -> UInt64 {
        TreeSitterUtilities.structuralHash(body) { node in
            switch kind(node) {
            case .identifier, .propertyIdentifier, .privatePropertyIdentifier, .shorthandPropertyIdentifier,
                 .shorthandPropertyIdentifierPattern, .typeIdentifier, .statementIdentifier:
                return -1
            case .string, .templateString, .number, .regex, .trueLiteral, .falseLiteral, .nullLiteral, .undefinedLiteral:
                return -2
            default:
                return nil
            }
        }
    }

    // MARK: Variables

    private mutating func visitVariableDeclaration(_ node: TSNode, _ context: Context, exportNode: TSNode?, isDefault: Bool) {
        let keyword: String
        if kind(node) == .variableDeclaration {
            keyword = "var"
        } else if let kindNode = node.field(f.kind) {
            keyword = text(kindNode)
        } else {
            keyword = "let"
        }
        let declarators = kids(node).filter { kind($0) == .variableDeclarator }
        let outer = exportNode ?? node
        for declarator in declarators {
            let nameNode = declarator.field(f.name)
            var value = declarator.field(f.value)
            let typeNode = declarator.field(f.type)

            if let value, let call = moduleCall(value) {
                // A `require` inside a function body loads the module when the function runs, like `import()`.
                addImport(call.specifier, names: nameNode.map(requireBindings) ?? [], line: declarator.startLine,
                          dynamic: call.dynamic || context.deferred, endLine: declarator.endLine)
                continue
            }
            if let nameNode, kind(nameNode) == .objectPattern, let chain = value.flatMap(identifierChain), Self.isEnvironment(chain) {
                // `const { A, B: b } = process.env` reads variables A and B, not the whole environment.
                for (name, keyNode) in environmentBindings(nameNode) {
                    if let name {
                        emit("env:" + name, .read, keyNode, context, receiver: chain, role: .env)
                    } else {
                        emit("env:*", .read, keyNode, context, receiver: chain, role: kind(keyNode) == .restPattern ? .envAll : .envDynamic)
                    }
                }
                value = nil
            }
            if let value, let nameNode {
                let target = unwrapValue(value)
                if kind(target) == .callExpression || kind(target) == .newExpression {
                    bind(target, to: patternNames(nameNode))
                }
            }

            guard context.topLevel, let nameNode else {
                pushInOrder([typeNode, value], context)
                continue
            }

            if kind(nameNode) != .identifier {
                // Top-level destructuring: each bound name becomes a module-level symbol.
                let scope = LocalScope(parent: nil)
                collectPatternNames(nameNode, into: scope)
                var namesInOrder: [String] = []
                var pending = [nameNode]
                while let current = pending.popLast() {
                    switch kind(current) {
                    case .identifier, .shorthandPropertyIdentifierPattern: namesInOrder.append(text(current))
                    case .pairPattern: if let v = current.field(f.value) { pending.append(v) }
                    case .assignmentPattern, .objectAssignmentPattern: if let l = current.field(f.left) { pending.append(l) }
                    default: pending.append(contentsOf: kids(current).reversed())
                    }
                }
                for name in namesInOrder {
                    symbols.add(
                        name: name,
                        kind: keyword == "const" ? .constant : .variable,
                        range: LineRange(declarator.startLine, declarator.endLine),
                        parent: parent(context),
                        signature: (keyword + " " + text(declarator)).compactSignature(),
                        isExported: exportNode != nil
                    )
                }
                pushInOrder([typeNode, value], context)
                continue
            }

            let name = text(nameNode)
            let symbolRange = declarators.count == 1 ? range(outer, node) : LineRange(declarator.startLine, declarator.endLine)
            if let value {
                switch kind(value) {
                case .arrowFunction, .functionExpression, .generatorFunction:
                    let symbol = addFunctionSymbol(
                        name: name,
                        function: value,
                        outer: declarators.count == 1 ? outer : declarator,
                        context: context,
                        exported: exportNode != nil,
                        isDefault: isDefault,
                        signatureNode: declarator,
                        signaturePrefix: keyword + " "
                    )
                    symbols[symbol].range = symbolRange
                    if let typeNode { push(typeNode, withEnclosing(context, symbol)) }
                    visitFunctionBody(value, context, symbol: symbol)
                    continue
                case .classExpression:
                    visitClass(value, context, declaredName: name, exportNode: exportNode, isDefault: isDefault, outerOverride: declarators.count == 1 ? outer : declarator)
                    continue
                default:
                    break
                }
            }
            var symbolKind: SymbolKind = keyword == "const" ? .constant : .variable
            if isJSXFile, TreeSitterUtilities.isPascalCase(name), let value, kind(value) == .callExpression, wrapsFunction(value) {
                symbolKind = .component   // React.memo(() => …), forwardRef(function …)
            }
            let symbol = symbols.add(
                name: name,
                kind: symbolKind,
                range: symbolRange,
                parent: parent(context),
                signature: (keyword + " " + text(declarator)).compactSignature(),
                doc: docComment(before: declarators.count == 1 ? outer : declarator),
                isExported: exportNode != nil,
                attributes: isDefault ? ["default"] : []
            )
            pushInOrder([typeNode, value], withEnclosing(context, symbol))
        }
    }

    private func withEnclosing(_ context: Context, _ symbol: Int) -> Context {
        var inner = context
        inner.enclosing = symbol
        return inner
    }

    /// `require("m")` → "m".
    private func requireSpecifier(_ value: TSNode) -> String? {
        var call = value
        if kind(call) == .awaitExpression, let inner = kids(call).first { call = inner }
        guard kind(call) == .callExpression, let function = call.field(f.function), kind(function) == .identifier,
              text(function) == "require", let arguments = call.field(f.arguments),
              let first = kids(arguments).first, kind(first) == .string else { return nil }
        return stringValue(first)
    }

    private func requireBindings(_ pattern: TSNode) -> [ImportedName] {
        switch kind(pattern) {
        case .identifier:
            return [ImportedName(name: "*", alias: text(pattern))]
        case .objectPattern:
            var names: [ImportedName] = []
            for child in kids(pattern) {
                switch kind(child) {
                case .shorthandPropertyIdentifierPattern:
                    names.append(ImportedName(name: text(child)))
                case .pairPattern:
                    if let key = child.field(f.key), let value = child.field(f.value), kind(value) == .identifier {
                        let keyName = text(key), local = text(value)
                        names.append(ImportedName(name: keyName, alias: local == keyName ? nil : local))
                    }
                case .objectAssignmentPattern:
                    if let left = child.field(f.left) { names.append(ImportedName(name: text(left))) }
                default:
                    break
                }
            }
            return names
        default:
            return []
        }
    }

    /// Variables destructured from the environment, at their keys: `{ A, B: b, C = "x" }` → A, B, C. A computed key
    /// (`[name]: v`) or a rest element (`...rest`) has no single name.
    private func environmentBindings(_ pattern: TSNode) -> [(name: String?, node: TSNode)] {
        var bindings: [(String?, TSNode)] = []
        for child in kids(pattern) {
            switch kind(child) {
            case .shorthandPropertyIdentifierPattern:
                bindings.append((text(child), child))
            case .pairPattern:
                if let key = child.field(f.key) { bindings.append((kind(key) == .computedPropertyName ? nil : specifierName(key), key)) }
            case .objectAssignmentPattern:
                if let left = child.field(f.left) { bindings.append((text(left), left)) }
            case .restPattern:
                bindings.append((nil, child))
            default:
                break
            }
        }
        return bindings
    }

    /// Names a binding pattern declares, in source order (identifiers and shorthand properties, not keys or defaults).
    private func patternNames(_ pattern: TSNode) -> [String] {
        var names: [String] = []
        var pending = [pattern]
        while let node = pending.popLast() {
            switch kind(node) {
            case .identifier, .shorthandPropertyIdentifierPattern:
                names.append(text(node))
            case .pairPattern:
                if let value = node.field(f.value) { pending.append(value) }
            case .assignmentPattern, .objectAssignmentPattern:
                if let left = node.field(f.left) { pending.append(left) }
            case .objectPattern, .arrayPattern, .restPattern:
                pending.append(contentsOf: kids(node).reversed())
            default:
                break
            }
        }
        return names
    }

    /// Remembers that the result of a call (or `new`) is bound to `names`: the reference it produces records them
    /// as `assignedTo`, and their later reads give its consuming statement.
    private mutating func bind(_ call: TSNode, to names: [String]) {
        guard !names.isEmpty else { return }
        pendingAssignments[call.startByte] = names.joined(separator: ",")
        assignedNames.formUnion(names)
    }

    private func wrapsFunction(_ call: TSNode) -> Bool {
        guard let arguments = call.field(f.arguments) else { return false }
        return kids(arguments).contains { argument in
            let argumentKind = kind(argument)
            return argumentKind == .arrowFunction || argumentKind == .functionExpression
        }
    }

    // MARK: Classes

    private mutating func visitClass(_ node: TSNode, _ context: Context, declaredName: String?, exportNode: TSNode?, isDefault: Bool, emitSymbol: Bool = true, outerOverride: TSNode? = nil) {
        let name = declaredName ?? node.field(f.name).map(text) ?? (isDefault ? "default" : nil)
        let decorators = (exportNode.map { kids($0, field: f.decorator) } ?? []) + kids(node, field: f.decorator)
        let outer = outerOverride ?? exportNode ?? node
        var attributes = decorators.compactMap(decoratorAttribute)
        if isDefault { attributes.append("default") }
        if kind(node) == .abstractClassDeclaration { attributes.append("abstract") }

        // Heritage: extends → inherit, implements → conform.
        var inherited: [String] = []
        var heritageRefs: [(name: String, node: TSNode, kind: ReferenceKind, receiver: String?)] = []
        var typeArgumentNodes: [TSNode] = []
        var otherHeritage: [TSNode] = []
        for heritage in kids(node) where kind(heritage) == .classHeritage {
            for clause in kids(heritage) {
                switch kind(clause) {
                case .extendsClause:
                    for (part, field) in cursor.fieldedChildren(of: clause) {
                        if field == f.typeArguments {
                            typeArgumentNodes.append(part)
                        } else if let (base, baseNode, receiver) = heritageName(part) {
                            inherited.append(base)
                            heritageRefs.append((base, baseNode, .inherit, receiver))
                        } else {
                            otherHeritage.append(part)
                        }
                    }
                case .implementsClause:
                    for type in kids(clause) {
                        if let (base, baseNode, receiver, arguments) = typeName(type) {
                            inherited.append(base)
                            heritageRefs.append((base, baseNode, .conform, receiver))
                            if let arguments { typeArgumentNodes.append(arguments) }
                        }
                    }
                default:
                    // JavaScript: `class A extends B` has the expression directly under class_heritage.
                    if let (base, baseNode, receiver) = heritageName(clause) {
                        inherited.append(base)
                        heritageRefs.append((base, baseNode, .inherit, receiver))
                    } else {
                        otherHeritage.append(clause)
                    }
                }
            }
        }

        var symbol: Int?
        if emitSymbol, let name {
            symbol = symbols.add(
                name: name,
                kind: .class,
                range: range(outer, node),
                parent: parent(context),
                signature: signature(node, upTo: node.field(f.body)),
                doc: docComment(before: outer),
                isExported: exportNode != nil,
                attributes: attributes,
                inheritedTypes: inherited
            )
        }
        var classContext = context
        classContext.enclosing = symbol ?? context.enclosing
        classContext.owner = nil
        classContext.topLevel = false
        classContext.write = false
        let classScope = LocalScope(parent: context.scope)
        collectTypeParameterNames(node, into: classScope)
        classContext.scope = classScope

        for reference in heritageRefs {
            emit(reference.name, reference.kind, reference.node, classContext, receiver: reference.receiver)
        }
        for decorator in decorators { visitDecorator(decorator, classContext) }
        if let body = node.field(f.body) {
            visitClassBody(body, classContext, classSymbol: symbol)
        }
        pushInOrder((typeArgumentNodes + otherHeritage).map { Optional($0) } + [node.field(f.typeParameters)], classContext)
    }

    /// `Base`, `ns.Base`, `Base<T>` (via the extends clause value) → name, node and receiver.
    private func heritageName(_ node: TSNode) -> (String, TSNode, String?)? {
        switch kind(node) {
        case .identifier, .typeIdentifier:
            return (text(node), node, nil)
        case .memberExpression:
            guard let property = node.field(f.property), let object = node.field(f.object) else { return nil }
            return (text(property), property, identifierChain(object) ?? "_")
        case .callExpression:
            return nil
        default:
            return nil
        }
    }

    /// Type references in heritage/implements positions.
    private func typeName(_ node: TSNode) -> (String, TSNode, String?, TSNode?)? {
        switch kind(node) {
        case .typeIdentifier, .identifier:
            return (text(node), node, nil, nil)
        case .nestedTypeIdentifier:
            guard let name = node.field(f.name) else { return nil }
            return (text(name), name, node.field(f.module).map(text), nil)
        case .genericType:
            guard let base = node.field(f.name), let (name, nameNode, receiver, _) = typeName(base) else { return nil }
            return (name, nameNode, receiver, node.field(f.typeArguments))
        default:
            return nil
        }
    }

    private mutating func visitClassBody(_ body: TSNode, _ context: Context, classSymbol: Int?) {
        var pendingDecorators: [TSNode] = []
        for member in kids(body) {
            switch kind(member) {
            case .decorator:
                pendingDecorators.append(member)
            case .methodDefinition, .methodSignature, .abstractMethodSignature:
                let decorators = pendingDecorators + kids(member, field: f.decorator)
                pendingDecorators = []
                // A method's statement is its header (decorators through the return type).
                let memberContext = inStatement(context, min(decorators.first?.startLine ?? member.startLine, member.startLine),
                                                headerEnd(member) ?? member.endLine)
                if classSymbol == nil {
                    // Anonymous class expression: no symbols, but bodies still produce references.
                    for decorator in decorators { visitDecorator(decorator, memberContext) }
                    visitFunctionBody(member, memberContext, symbol: nil)
                } else {
                    visitMethod(member, memberContext, classSymbol: classSymbol, decorators: decorators)
                }
            case .publicFieldDefinition, .fieldDefinition:
                let decorators = pendingDecorators + kids(member, field: f.decorator)
                pendingDecorators = []
                let value = member.field(f.value)
                let isFunctionValue = value.map { [.arrowFunction, .functionExpression].contains(kind($0)) } ?? false
                // A field is one statement; a field holding a function with a block body is a header, like a method.
                let hasBlockBody = isFunctionValue && value?.field(f.body).map { kind($0) == .statementBlock } == true
                let memberContext = inStatement(context, min(decorators.first?.startLine ?? member.startLine, member.startLine),
                                                (hasBlockBody ? value.flatMap(headerEnd) : nil) ?? member.endLine)
                if classSymbol == nil {
                    for decorator in decorators { visitDecorator(decorator, memberContext) }
                    // Instance fields are initialized by the constructor; static ones when the class is defined.
                    var fieldContext = memberContext
                    if !hasToken(member, .tokStatic) { fieldContext.deferred = true }
                    push(member.field(f.type), fieldContext)
                    if let value {
                        if isFunctionValue {
                            visitFunctionBody(value, memberContext, symbol: nil)
                        } else {
                            push(value, fieldContext)
                        }
                    }
                } else {
                    visitField(member, memberContext, classSymbol: classSymbol, decorators: decorators)
                }
            case .comment:
                break
            default:
                pendingDecorators = []
                // Index signatures, static blocks: references only.
                var inner = inStatement(context, member.startLine, member.endLine)
                inner.scope = LocalScope(parent: context.scope)
                if member.typeName == "class_static_block", let block = member.field(f.body) {
                    collectLocals(block, into: inner.scope!)
                }
                push(member, inner)
            }
        }
    }

    private func memberName(_ member: TSNode) -> (String, TSNode)? {
        guard let nameNode = member.field(f.name) ?? member.field(f.property) else { return nil }
        switch kind(nameNode) {
        case .string: return (stringValue(nameNode), nameNode)
        default: return (text(nameNode), nameNode)
        }
    }

    private func memberModifiers(_ member: TSNode) -> (visibility: Visibility?, attributes: [String]) {
        var visibility: Visibility?
        var attributes: [String] = []
        for child in cursor.children(of: member) {
            if ts_node_is_named(child) {
                if child.typeName == "accessibility_modifier" {
                    switch text(child) {
                    case "private": visibility = .private
                    case "protected": visibility = .internal
                    case "public": visibility = .public
                    default: break
                    }
                } else if child.typeName == "override_modifier" {
                    attributes.append("override")
                }
            } else {
                switch kind(child) {
                case .tokStatic: attributes.append("static")
                case .tokAsync: attributes.append("async")
                case .tokGet: attributes.append("get")
                case .tokSet: attributes.append("set")
                case .tokReadonly: attributes.append("readonly")
                case .tokAbstract: attributes.append("abstract")
                case .tokOverride: attributes.append("override")
                case .tokDeclare: attributes.append("declare")
                default: break
                }
            }
        }
        if let nameNode = member.field(f.name) ?? member.field(f.property), kind(nameNode) == .privatePropertyIdentifier {
            visibility = .private
        }
        return (visibility, attributes)
    }

    /// Start of a member excluding leading decorators (so signatures stay readable).
    private func signatureStart(_ member: TSNode) -> Int {
        var start = member.startByte
        for child in kids(member) where kind(child) == .decorator {
            start = max(start, child.endByte)
        }
        return start
    }

    private mutating func visitMethod(_ member: TSNode, _ context: Context, classSymbol: Int?, decorators: [TSNode]) {
        guard let (name, _) = memberName(member) else {
            visitFunctionBody(member, context, symbol: nil)
            return
        }
        let (visibility, modifiers) = memberModifiers(member)
        let isConstructor = name == "constructor" && kind(member) == .methodDefinition
        let anchor = decorators.first ?? member
        let body = member.field(f.body)
        let header = source.text(from: signatureStart(member), to: body?.startByte ?? member.endByte).compactSignature()
        let symbol = symbols.add(
            name: name,
            kind: isConstructor ? .initializer : .method,
            range: LineRange(min(anchor.startLine, member.startLine), member.endLine),
            parent: classSymbol,
            signature: header,
            doc: docComment(before: anchor),
            visibility: visibility,
            isExported: false,
            attributes: decorators.compactMap(decoratorAttribute) + modifiers
        )
        let methodContext = withEnclosing(context, symbol)
        for decorator in decorators { visitDecorator(decorator, methodContext) }

        // TypeScript parameter properties: `constructor(private api: Api)` declares `api` on the class.
        if isConstructor, let parameters = member.field(f.parameters) {
            for parameter in kids(parameters) where kind(parameter) == .requiredParameter || kind(parameter) == .optionalParameter {
                let (parameterVisibility, parameterModifiers) = memberModifiers(parameter)
                guard parameterVisibility != nil || parameterModifiers.contains("readonly") else { continue }
                guard let pattern = parameter.field(f.pattern) ?? parameter.field(f.name), kind(pattern) == .identifier else { continue }
                symbols.add(
                    name: text(pattern),
                    kind: .property,
                    range: LineRange(parameter.startLine, parameter.endLine),
                    parent: classSymbol,
                    signature: text(parameter).compactSignature(),
                    visibility: parameterVisibility,
                    attributes: parameterModifiers
                )
            }
        }
        visitFunctionBody(member, context, symbol: symbol)
    }

    private mutating func visitField(_ member: TSNode, _ context: Context, classSymbol: Int?, decorators: [TSNode]) {
        guard let (name, _) = memberName(member) else { return }
        let (visibility, modifiers) = memberModifiers(member)
        let value = member.field(f.value)
        let isFunctionValue = value.map { [.arrowFunction, .functionExpression].contains(kind($0)) } ?? false
        let anchor = decorators.first ?? member
        let header: String
        if isFunctionValue, let value {
            header = source.text(from: signatureStart(member), to: value.field(f.body)?.startByte ?? value.endByte).compactSignature()
        } else {
            header = source.text(from: signatureStart(member), to: member.endByte).compactSignature()
        }
        let symbol = symbols.add(
            name: name,
            kind: isFunctionValue ? .method : .property,
            range: LineRange(min(anchor.startLine, member.startLine), member.endLine),
            parent: classSymbol,
            signature: header,
            doc: docComment(before: anchor),
            visibility: visibility,
            attributes: decorators.compactMap(decoratorAttribute) + modifiers
        )
        var fieldContext = withEnclosing(context, symbol)
        for decorator in decorators { visitDecorator(decorator, fieldContext) }
        // Instance fields are initialized by the constructor; static ones when the class is defined.
        if !modifiers.contains("static") { fieldContext.deferred = true }
        push(member.field(f.type), fieldContext)
        if let value {
            if isFunctionValue {
                visitFunctionBody(value, context, symbol: symbol)
            } else {
                push(value, fieldContext)
            }
        }
    }

    // MARK: Interfaces, aliases, enums, namespaces

    private mutating func visitInterface(_ node: TSNode, _ context: Context, exportNode: TSNode?) {
        guard let nameNode = node.field(f.name) else { return }
        let outer = exportNode ?? node
        var inherited: [String] = []
        var references: [(String, TSNode, String?)] = []
        var typeArguments: [TSNode] = []
        for clause in kids(node) where kind(clause) == .extendsTypeClause {
            for type in kids(clause) {
                if let (name, nameNode, receiver, arguments) = typeName(type) {
                    inherited.append(name)
                    references.append((name, nameNode, receiver))
                    if let arguments { typeArguments.append(arguments) }
                }
            }
        }
        let symbol = symbols.add(
            name: text(nameNode),
            kind: .interface,
            range: range(outer, node),
            parent: parent(context),
            signature: signature(node, upTo: node.field(f.body)),
            doc: docComment(before: outer),
            isExported: exportNode != nil,
            inheritedTypes: inherited
        )
        let scope = LocalScope(parent: context.scope)
        collectTypeParameterNames(node, into: scope)
        var inner = withEnclosing(context, symbol)
        inner.scope = scope
        inner.topLevel = false
        for (name, referenceNode, receiver) in references {
            emit(name, .inherit, referenceNode, inner, receiver: receiver)
        }
        if let body = node.field(f.body) {
            for member in kids(body) {
                // Each member signature is a statement of its own.
                let memberContext = inStatement(inner, member.startLine, member.endLine)
                switch kind(member) {
                case .propertySignature:
                    guard let (name, _) = memberName(member) else { continue }
                    let (visibility, modifiers) = memberModifiers(member)
                    let property = symbols.add(
                        name: name,
                        kind: .property,
                        range: LineRange(member.startLine, member.endLine),
                        parent: symbol,
                        signature: text(member).compactSignature(),
                        doc: docComment(before: member),
                        visibility: visibility,
                        attributes: modifiers
                    )
                    push(member.field(f.type), withEnclosing(memberContext, property))
                case .methodSignature:
                    guard let (name, _) = memberName(member) else { continue }
                    let method = symbols.add(
                        name: name,
                        kind: .method,
                        range: LineRange(member.startLine, member.endLine),
                        parent: symbol,
                        signature: text(member).compactSignature(),
                        doc: docComment(before: member)
                    )
                    visitFunctionBody(member, memberContext, symbol: method)
                case .comment:
                    break
                default:
                    push(member, memberContext)
                }
            }
        }
        pushInOrder(typeArguments.map { Optional($0) } + [node.field(f.typeParameters)], inner)
    }

    private mutating func visitTypeAlias(_ node: TSNode, _ context: Context, exportNode: TSNode?) {
        guard let nameNode = node.field(f.name) else { return }
        let outer = exportNode ?? node
        let symbol = symbols.add(
            name: text(nameNode),
            kind: .typeAlias,
            range: range(outer, node),
            parent: parent(context),
            signature: text(node).compactSignature(),
            doc: docComment(before: outer),
            isExported: exportNode != nil
        )
        let scope = LocalScope(parent: context.scope)
        collectTypeParameterNames(node, into: scope)
        var inner = withEnclosing(context, symbol)
        inner.scope = scope
        inner.topLevel = false
        pushInOrder([node.field(f.typeParameters), node.field(f.value)], inner)
    }

    private mutating func visitEnum(_ node: TSNode, _ context: Context, exportNode: TSNode?) {
        guard let nameNode = node.field(f.name) else { return }
        let outer = exportNode ?? node
        let symbol = symbols.add(
            name: text(nameNode),
            kind: .enum,
            range: range(outer, node),
            parent: parent(context),
            signature: signature(node, upTo: node.field(f.body)),
            doc: docComment(before: outer),
            isExported: exportNode != nil
        )
        guard let body = node.field(f.body) else { return }
        let inner = withEnclosing(context, symbol)
        for member in kids(body) {
            switch kind(member) {
            case .propertyIdentifier, .string:
                let name = kind(member) == .string ? stringValue(member) : text(member)
                symbols.add(name: name, kind: .enumCase, range: LineRange(member.startLine, member.endLine), parent: symbol, signature: name)
            case .enumAssignment:
                guard let memberName = member.field(f.name) else { continue }
                let name = kind(memberName) == .string ? stringValue(memberName) : text(memberName)
                let enumCase = symbols.add(name: name, kind: .enumCase, range: LineRange(member.startLine, member.endLine), parent: symbol, signature: text(member).compactSignature())
                push(member.field(f.value), inStatement(withEnclosing(inner, enumCase), member.startLine, member.endLine))
            default:
                break
            }
        }
    }

    private mutating func visitNamespace(_ node: TSNode, _ context: Context, exportNode: TSNode?) {
        guard let nameNode = node.field(f.name) else {
            pushChildren(node, context)
            return
        }
        let name = kind(nameNode) == .string ? stringValue(nameNode) : text(nameNode)
        let outer = exportNode ?? node
        let symbol = symbols.add(
            name: name,
            kind: .namespace,
            range: range(outer, node),
            parent: parent(context),
            signature: signature(node, upTo: node.field(f.body)),
            doc: docComment(before: outer),
            isExported: exportNode != nil
        )
        guard let body = node.field(f.body) else { return }
        var inner = withEnclosing(context, symbol)
        inner.topLevel = true
        inner.owner = nil
        pushChildren(body, inner)
    }

    // MARK: Type parameters

    private mutating func visitTypeParameters(_ node: TSNode, _ context: Context) {
        for parameter in kids(node) where kind(parameter) == .typeParameter {
            pushInOrder([parameter.field(f.constraint), parameter.field(f.value)], context)
        }
    }

    // MARK: Expressions

    /// `a`, `this`, `a.b.c`, `this.store` → dotted text; nil for anything more complex.
    private func identifierChain(_ node: TSNode) -> String? {
        var parts: [String] = []
        var current = node
        while true {
            switch kind(current) {
            case .identifier, .this, .superKeyword:
                parts.append(text(current))
                return parts.reversed().joined(separator: ".")
            case .metaProperty:
                parts.append("import.meta")
                return parts.reversed().joined(separator: ".")
            case .memberExpression:
                guard let property = current.field(f.property), let object = current.field(f.object),
                      kind(property) == .propertyIdentifier || kind(property) == .privatePropertyIdentifier else { return nil }
                parts.append(text(property))
                current = object
            case .nonNullExpression:
                guard let inner = kids(current).first else { return nil }
                current = inner
            default:
                return nil
            }
        }
    }

    private func isSkipped(_ name: String, _ context: Context) -> Bool {
        Self.stopNames.contains(name) || (context.scope?.contains(name) ?? false)
    }

    private func isSkippedMember(_ name: String, receiver: String) -> Bool {
        if Self.stopNames.contains(name) { return true }
        let root = receiver.split(separator: ".", maxSplits: 1).first.map(String.init) ?? receiver
        return Self.globalReceivers.contains(root)
    }

    /// The receiver of a member access as dotted text (`_` when it is not a simple chain). A callback parameter
    /// that holds a dynamically imported module becomes its file-unique alias (`m.X` → `m@11.X`).
    private func receiverText(_ object: TSNode, _ context: Context) -> String {
        guard let chain = identifierChain(object) else { return "_" }
        guard hasImportAliases else { return chain }
        let root = rootOf(chain)
        guard let alias = context.scope?.importAlias(root) else { return chain }
        return alias + chain.dropFirst(root.count)
    }

    private mutating func emit(
        _ name: String, _ kind: ReferenceKind, _ node: TSNode, _ context: Context, receiver: String? = nil,
        role: ReferenceContext? = nil, callEnd: Int? = nil, assignedTo: String? = nil
    ) {
        guard !name.isEmpty else { return }
        let line = node.startLine
        // Outside any statement (a parameter default, a class expression's heritage) a reference has no span.
        let inStatement = context.statementStart > 0 && context.statementStart <= line
        if let assignedTo, assignedTo != "return" {
            let names = assignedTo.split(separator: ",").map(String.init)
            if let first = names.first, let scope = context.scope?.declaringScope(of: first) {
                assignments.append((references.count, scope, names))
            }
        }
        references.append(ExtractedReference(
            name: name,
            kind: kind,
            line: line,
            column: node.startColumn + 1,
            enclosingSymbol: context.enclosing,
            receiver: receiver,
            statementLine: inStatement ? context.statementStart : nil,
            endLine: inStatement ? max(context.statementEnd, line) : nil,
            callEndLine: callEnd,
            context: (role ?? Self.role(of: kind, context)).rawValue,
            atLoad: !context.deferred,
            assignedTo: assignedTo
        ))
    }

    /// The syntactic role of a reference unless its emitter names one (`typeof`, environment variables).
    private static func role(of kind: ReferenceKind, _ context: Context) -> ReferenceContext {
        switch kind {
        case .call, .instantiate: .call
        case .write: context.deleting ? .delete : .write
        case .read, .member: .read
        case .typeUse: .type
        case .inherit, .conform: .heritage
        case .decorator: .decorator
        }
    }

    private mutating func emitType(_ name: String, _ node: TSNode, _ context: Context, receiver: String? = nil) {
        if receiver == nil {
            if Self.builtinTypes.contains(name) || (context.scope?.contains(name) ?? false) { return }
        }
        emit(name, .typeUse, node, context, receiver: receiver)
    }

    private mutating func visitIdentifier(_ node: TSNode, _ context: Context) {
        let name = text(node)
        if Self.stopNames.contains(name) { return }
        if context.scope?.contains(name) == true {
            if !context.write { noteLocalRead(name, node, context) }
            return
        }
        if context.typeQuery {
            emit(name, .typeUse, node, context, role: .typeof)
            return
        }
        emit(name, context.write ? .write : .read, node, context)
    }

    /// Records a read of a local that holds a call result: its statement may be the call's consuming statement.
    private mutating func noteLocalRead(_ name: String, _ node: TSNode, _ context: Context) {
        guard assignedNames.contains(name), let scope = context.scope?.declaringScope(of: name) else { return }
        let line = node.startLine
        let head = context.statementStart > 0 && context.statementStart <= line ? context.statementStart : line
        localReads[Binding(scope: scope, name: name), default: []].append((head, line))
    }

    private mutating func visitMember(_ node: TSNode, _ context: Context) {
        guard let property = node.field(f.property), let object = node.field(f.object) else {
            pushChildren(node, context)
            return
        }
        let receiver = receiverText(object, context)
        let name = text(property)
        let access: ReferenceKind = context.write ? .write : .read
        if Self.isEnvironment(receiver) {
            // `process.env.X` is the variable X; the environment object itself is no further reference.
            emit("env:" + name, access, property, context, receiver: receiver, role: context.deleting ? .delete : .env)
            return
        }
        if name == "env" && (receiver == "process" || receiver == "import.meta") {
            // The whole environment: passed on, spread, iterated or replaced.
            emit("env:*", access, property, context, receiver: receiver, role: .envAll)
            return
        }
        if !isSkippedMember(name, receiver: receiver) {
            if receiver == "_" || isSelfReceiver(receiver) || !(context.scope?.contains(rootOf(receiver)) ?? false) {
                if context.typeQuery {
                    emit(name, .typeUse, property, context, receiver: receiver, role: .typeof)
                } else {
                    emit(name, access, property, context, receiver: receiver)
                }
            }
        }
        var objectContext = context
        objectContext.write = false
        push(object, objectContext)
    }

    private func isSelfReceiver(_ receiver: String) -> Bool {
        receiver == "this" || receiver == "super" || receiver.hasPrefix("this.") || receiver.hasPrefix("super.")
    }

    private func rootOf(_ receiver: String) -> String {
        receiver.split(separator: ".", maxSplits: 1).first.map(String.init) ?? receiver
    }

    private mutating func visitCall(_ node: TSNode, _ context: Context) {
        var inner = context
        inner.write = false
        let arguments = node.field(f.arguments)
        guard var function = node.field(f.function) else {
            pushChildren(node, inner)
            return
        }
        // `await a.b<T>(…)` parses as a call whose function is the await expression; generic
        // instantiations, non-null assertions and parentheses wrap the callee the same way.
        var extraTypeArguments: TSNode?
        unwrap: while true {
            switch kind(function) {
            case .awaitExpression, .nonNullExpression, .parenthesizedExpression:
                guard let innerExpression = kids(function).first else { break unwrap }
                function = innerExpression
            case .instantiationExpression:
                extraTypeArguments = function.field(f.typeArguments)
                guard let innerExpression = function.field(f.function) ?? kids(function).first else { break unwrap }
                function = innerExpression
            default:
                break unwrap
            }
        }
        if let extraTypeArguments { push(extraTypeArguments, inner) }
        let assigned = pendingAssignments.removeValue(forKey: node.startByte)
        switch kind(function) {
        case .identifier:
            let name = text(function)
            if name == "require" {
                if let specifier = requireSpecifier(node) {
                    // `require("m");` as a statement loads the module only for its side effects.
                    let isStatement = node.parentNode.map { kind($0) == .expressionStatement } ?? false
                    addImport(specifier, names: [], line: node.startLine, dynamic: context.deferred, sideEffect: isStatement, endLine: node.endLine)
                }
                return
            }
            if Self.stopNames.contains(name) { break }
            if context.scope?.contains(name) == true {
                // Calling a local reads it.
                noteLocalRead(name, function, context)
            } else {
                emit(name, .call, function, inner, callEnd: node.endLine, assignedTo: assigned)
            }
        case .importKeyword:
            if let first = arguments.flatMap({ kids($0).first }), kind(first) == .string {
                addImport(stringValue(first), names: [], line: node.startLine, dynamic: true, endLine: node.endLine)
                return
            }
        case .memberExpression:
            if let property = function.field(f.property), let object = function.field(f.object) {
                let name = text(property)
                if name == "then", let module = dynamicImportCall(object), let callback = arguments.flatMap({ kids($0).first }),
                   kind(callback) == .arrowFunction || kind(callback) == .functionExpression {
                    bindImportCallback(callback, to: module)
                    pushInOrder([node.field(f.typeArguments), arguments], inner)
                    return
                }
                let receiver = receiverText(object, context)
                if receiver == "vi" || receiver == "jest", Self.mockCalls.contains(name), let arguments, addMock(name, arguments, node, inner) {
                    // `vi` itself is still read.
                    push(object, inner)
                    return
                }
                if !isSkippedMember(name, receiver: receiver) {
                    emit(name, .call, property, inner, receiver: receiver, callEnd: node.endLine, assignedTo: assigned)
                }
                push(object, inner)
            }
        case .superKeyword:
            break
        default:
            push(function, inner)
        }
        pushInOrder([node.field(f.typeArguments), arguments], inner)
    }

    /// `import("m").then(cb)`: the module is a dynamic import whose bindings are the callback's first parameter.
    private mutating func bindImportCallback(_ callback: TSNode, to module: (call: TSNode, specifier: String)) {
        var names: [ImportedName] = []
        if let parameter = firstParameter(callback) {
            switch kind(parameter) {
            case .identifier:
                // A file-unique alias, so `m` in four callbacks of one file binds four different modules.
                let name = text(parameter)
                let alias = "\(name)@\(module.call.startLine)"
                names = [ImportedName(name: "*", alias: alias)]
                importCallbacks[callback.startByte] = .namespace(name: name, alias: alias)
            case .objectPattern:
                names = requireBindings(parameter)
                importCallbacks[callback.startByte] = .names(names.map(\.localName))
            default:
                break
            }
        }
        addImport(module.specifier, names: names, line: module.call.startLine, dynamic: true, endLine: module.call.endLine)
    }

    /// The pattern of a function's first parameter: `m` in `m => …`, `(m) => …` and `function (m: M) {…}`.
    private func firstParameter(_ function: TSNode) -> TSNode? {
        if let single = function.field(f.parameter) { return single }
        guard let parameters = function.field(f.parameters), let first = kids(parameters).first else { return nil }
        switch kind(first) {
        case .requiredParameter, .optionalParameter: return first.field(f.pattern) ?? first.field(f.name)
        default: return first
        }
    }

    /// `vi.mock("m", factory)` and friends: a mock row that names the module without importing it. False when the
    /// first argument is no module specifier.
    private mutating func addMock(_ name: String, _ arguments: TSNode, _ call: TSNode, _ context: Context) -> Bool {
        let parts = kids(arguments)
        guard let first = parts.first else { return false }
        guard let specifier = kind(first) == .string ? stringValue(first) : dynamicImportCall(first)?.specifier else { return false }
        // `importActual`/`requireActual` load the real module, when the test runs.
        let loadsModule = name == "importActual" || name == "requireActual"
        addImport(specifier, names: [], line: call.startLine, dynamic: loadsModule, mock: true)
        // The factory still references code.
        pushInOrder(parts.dropFirst().map { Optional($0) }, context)
        return true
    }

    private mutating func visitNew(_ node: TSNode, _ context: Context) {
        var inner = context
        inner.write = false
        let assigned = pendingAssignments.removeValue(forKey: node.startByte)
        if let constructor = node.field(f.constructor) {
            switch kind(constructor) {
            case .identifier:
                let name = text(constructor)
                if !isSkipped(name, context) { emit(name, .instantiate, constructor, inner, callEnd: node.endLine, assignedTo: assigned) }
            case .memberExpression:
                if let property = constructor.field(f.property), let object = constructor.field(f.object) {
                    let receiver = receiverText(object, context)
                    let name = text(property)
                    if !isSkippedMember(name, receiver: receiver) {
                        emit(name, .instantiate, property, inner, receiver: receiver, callEnd: node.endLine, assignedTo: assigned)
                    }
                    push(object, inner)
                }
            default:
                push(constructor, inner)
            }
        }
        pushInOrder([node.field(f.typeArguments), node.field(f.arguments)], inner)
    }

    private mutating func visitAssignment(_ node: TSNode, _ context: Context) {
        let left = node.field(f.left)
        let right = node.field(f.right)
        var readContext = context
        readContext.write = false

        if let left, kind(left) == .memberExpression, kind(node) == .assignmentExpression, let chain = identifierChain(left) {
            if chain == "module.exports" {
                if let right {
                    switch kind(right) {
                    case .identifier:
                        exportedNames.append("default=\(text(right))")
                    case .object:
                        for entry in kids(right) {
                            if kind(entry) == .shorthandPropertyIdentifier {
                                let name = text(entry)
                                exportedNames.append("\(name)=\(name)")
                            } else if kind(entry) == .pair, let key = entry.field(f.key), let value = entry.field(f.value), kind(value) == .identifier {
                                exportedNames.append("\(text(key))=\(text(value))")
                            }
                        }
                    default:
                        break
                    }
                    push(right, readContext)
                }
                return
            }
            if chain.hasPrefix("exports.") || chain.hasPrefix("module.exports.") {
                let exportedName = String(chain.split(separator: ".").last ?? "")
                if let right {
                    switch kind(right) {
                    case .identifier:
                        exportedNames.append("\(exportedName)=\(text(right))")
                        push(right, readContext)
                    case .functionExpression, .arrowFunction, .generatorFunction:
                        exportedNames.append("\(exportedName)=\(exportedName)")
                        if context.topLevel {
                            let symbol = addFunctionSymbol(name: exportedName, function: right, outer: node, context: context, exported: true, isDefault: false, signatureNode: node)
                            visitFunctionBody(right, context, symbol: symbol)
                        } else {
                            visitFunctionBody(right, context, symbol: nil)
                        }
                    default:
                        exportedNames.append("\(exportedName)=\(exportedName)")
                        push(right, readContext)
                    }
                }
                return
            }
        }
        var writeContext = context
        writeContext.write = true
        if let left, let right, kind(left) == .identifier, kind(node) == .assignmentExpression {
            // `x = f()` binds the result to x.
            let target = unwrapValue(right)
            if kind(target) == .callExpression || kind(target) == .newExpression { bind(target, to: [text(left)]) }
        }
        if let left {
            switch kind(left) {
            case .identifier, .memberExpression, .subscriptExpression, .objectPattern, .arrayPattern:
                push(right, readContext)
                push(left, writeContext)
            default:
                push(right, readContext)
                push(left, readContext)
            }
        } else {
            push(right, readContext)
        }
    }

    private mutating func visitJSX(_ node: TSNode, _ context: Context) {
        var inner = context
        inner.write = false
        if let nameNode = node.field(f.name) {
            switch kind(nameNode) {
            case .identifier:
                let name = text(nameNode)
                if TreeSitterUtilities.isPascalCase(name) || (name.first?.isUppercase ?? false) {
                    if !(context.scope?.contains(name) ?? false) {
                        emit(name, .instantiate, nameNode, inner, callEnd: node.endLine)
                    }
                }
            case .memberExpression:
                if let property = nameNode.field(f.property), let object = nameNode.field(f.object) {
                    emit(text(property), .instantiate, property, inner, receiver: receiverText(object, context), callEnd: node.endLine)
                }
            case .nestedIdentifier:
                let parts = text(nameNode).split(separator: ".")
                if let last = parts.last {
                    emit(String(last), .instantiate, nameNode, inner, receiver: parts.dropLast().joined(separator: "."), callEnd: node.endLine)
                }
            default:
                break
            }
        }
        var parts: [TSNode?] = kids(node, field: f.attribute)
        parts.append(node.field(f.typeArguments))
        pushInOrder(parts, inner)
    }

    private mutating func countDecision(_ context: Context) {
        complexity += 1
        symbols.addComplexity(context.owner)
    }
}

