import CTreeSitter
import VesaliusCore

/// Python analyzer built on tree-sitter.
///
/// Extracts classes, functions, methods, properties (class attributes and `self.x` assignments in
/// `__init__`), module variables/constants, imports (one record per imported name), `__all__` exports,
/// and references (calls, instantiations, type annotations, base classes, decorators, reads/writes),
/// skipping parameters and function-local names. Every reference carries its statement span, whether it runs
/// while the module loads, and for a call bound to a local, the statement that consumes the result;
/// environment variables (`os.environ["X"]`, `os.getenv("X")`) become `env:X` references.
public struct PythonAnalyzer: LanguageAnalyzer {
    public init() {}

    public var identifier: String { "tree-sitter-python" }

    public var version: Int { 2 }

    public func canAnalyze(_ language: Language, path: String) -> Bool {
        language == .python
    }

    public func analyze(_ file: SourceFile) throws -> FileAnalysis {
        let source = SourceBytes(file.text)
        let tree = try TreeSitterParser.parse(source.bytes, grammar: .python)
        var walker = PythonWalker(source: source, tables: pythonTables, root: tree.root)
        walker.run(tree.root)
        return FileAnalysis(
            symbols: walker.symbols.symbols,
            imports: walker.imports,
            references: walker.references,
            complexity: walker.complexity,
            syntaxErrorCount: TreeSitterUtilities.countSyntaxErrors(tree.root),
            exportedNames: walker.exportedNames,
            isEntryPoint: walker.isEntryPoint
        )
    }
}

extension PythonAnalyzer {
    /// Names the walker never records as unqualified references or attribute calls (`print`, `len`, `get`, …).
    static var stopNames: Set<String> { PythonWalker.stopNames }
}

// MARK: - Grammar tables

enum PythonKind: UInt8 {
    case other = 0
    case module, comment, errorNode
    case importStatement, importFromStatement, futureImportStatement, aliasedImport, dottedName, relativeImport, wildcardImport
    case classDefinition, functionDefinition, decoratedDefinition, decorator, block, expressionStatement
    case assignment, augmentedAssignment, namedExpression
    case call, attribute, identifier, keywordArgument, argumentList, subscriptExpression
    case parameters, lambdaParameters, typedParameter, defaultParameter, typedDefaultParameter, listSplatPattern, dictionarySplatPattern
    case tuplePattern, listPattern, patternList, asPattern, asPatternTarget
    case lambda, forStatement, whileStatement, ifStatement, elifClause, exceptClause, withStatement, withItem
    case listComprehension, setComprehension, dictionaryComprehension, generatorExpression, forInClause, ifClause
    case booleanOperator, conditionalExpression, caseClause, globalStatement, nonlocalStatement
    case type, string, interpolation, integer, float, trueLiteral, falseLiteral, none, concatenatedString
    case list, tuple, expressionList, parenthesizedExpression
    case tokAsync
    // Statements (spans), `del`, `await`
    case returnStatement, raiseStatement, assertStatement, deleteStatement, awaitExpression
}

struct PythonFields: Sendable {
    let name, alias, moduleName, body, superclasses, parameters, returnType, definition, left, right, type: TSFieldId
    let function, arguments, object, attribute, value, condition, subscriptIndex, consequence: TSFieldId

    init(language: OpaquePointer) {
        let table = FieldTable(language: language, names: [
            "name", "alias", "module_name", "body", "superclasses", "parameters", "return_type", "definition",
            "left", "right", "type", "function", "arguments", "object", "attribute", "value", "condition", "subscript",
            "consequence",
        ])
        name = table["name"]; alias = table["alias"]; moduleName = table["module_name"]; body = table["body"]
        superclasses = table["superclasses"]; parameters = table["parameters"]; returnType = table["return_type"]
        definition = table["definition"]; left = table["left"]; right = table["right"]; type = table["type"]
        function = table["function"]; arguments = table["arguments"]; object = table["object"]
        attribute = table["attribute"]; value = table["value"]; condition = table["condition"]; subscriptIndex = table["subscript"]
        consequence = table["consequence"]
    }
}

struct PythonTables: Sendable {
    let kinds: NodeKindTable
    let fields: PythonFields

    init() {
        let language = TreeSitterGrammar.python.language
        let named: [String: PythonKind] = [
            "module": .module, "comment": .comment, "ERROR": .errorNode,
            "import_statement": .importStatement, "import_from_statement": .importFromStatement,
            "future_import_statement": .futureImportStatement, "aliased_import": .aliasedImport, "dotted_name": .dottedName,
            "relative_import": .relativeImport, "wildcard_import": .wildcardImport,
            "class_definition": .classDefinition, "function_definition": .functionDefinition,
            "decorated_definition": .decoratedDefinition, "decorator": .decorator, "block": .block,
            "expression_statement": .expressionStatement, "assignment": .assignment, "augmented_assignment": .augmentedAssignment,
            "named_expression": .namedExpression,
            "call": .call, "attribute": .attribute, "identifier": .identifier, "keyword_argument": .keywordArgument,
            "argument_list": .argumentList, "subscript": .subscriptExpression,
            "parameters": .parameters, "lambda_parameters": .lambdaParameters, "typed_parameter": .typedParameter,
            "default_parameter": .defaultParameter, "typed_default_parameter": .typedDefaultParameter,
            "list_splat_pattern": .listSplatPattern, "dictionary_splat_pattern": .dictionarySplatPattern,
            "tuple_pattern": .tuplePattern, "list_pattern": .listPattern, "pattern_list": .patternList,
            "as_pattern": .asPattern, "as_pattern_target": .asPatternTarget,
            "lambda": .lambda, "for_statement": .forStatement, "while_statement": .whileStatement, "if_statement": .ifStatement,
            "elif_clause": .elifClause, "except_clause": .exceptClause, "with_statement": .withStatement, "with_item": .withItem,
            "list_comprehension": .listComprehension, "set_comprehension": .setComprehension,
            "dictionary_comprehension": .dictionaryComprehension, "generator_expression": .generatorExpression,
            "for_in_clause": .forInClause, "if_clause": .ifClause,
            "boolean_operator": .booleanOperator, "conditional_expression": .conditionalExpression, "case_clause": .caseClause,
            "global_statement": .globalStatement, "nonlocal_statement": .nonlocalStatement,
            "type": .type, "string": .string, "interpolation": .interpolation, "integer": .integer, "float": .float,
            "true": .trueLiteral, "false": .falseLiteral, "none": .none, "concatenated_string": .concatenatedString,
            "list": .list, "tuple": .tuple, "expression_list": .expressionList, "parenthesized_expression": .parenthesizedExpression,
            "return_statement": .returnStatement, "raise_statement": .raiseStatement, "assert_statement": .assertStatement,
            "delete_statement": .deleteStatement, "await": .awaitExpression,
        ]
        kinds = NodeKindTable(language: language, named: named.mapValues(\.rawValue), anonymous: ["async": PythonKind.tokAsync.rawValue])
        fields = PythonFields(language: language)
    }
}

private let pythonTables = PythonTables()

// MARK: - Walker

private struct PythonWalker {
    enum Level: Equatable {
        case module
        case classBody(Int?)
        case function
    }

    struct Context {
        var enclosing: Int?
        var owner: Int?
        var scope: LocalScope?
        var level: Level
        var write: Bool
        var inType: Bool
        /// Inside the body of an `if TYPE_CHECKING:` block: imported only by type checkers.
        var typeCheckingOnly = false
        /// Inside a function body or lambda: runs when called, not while the module loads.
        var deferred = false
        /// Lines of the innermost enclosing statement (only the header of a compound statement); 0 when none.
        var statementStart = 0
        var statementEnd = 0
        /// The target of `del`.
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

    let source: SourceBytes
    let kinds: NodeKindTable
    let f: PythonFields

    var symbols = SymbolCollector()
    var imports: [ExtractedImport] = []
    var references: [ExtractedReference] = []
    var exportedNames: [String] = []
    var complexity = 1
    var isEntryPoint = false
    private var stack: [Frame] = []
    /// Property names already declared per class symbol (class attributes and `self.x`).
    private var classProperties: [Int: Set<String>] = [:]
    private let cursor: ReusableCursor
    /// Call nodes (by start byte) whose result is bound to locals, or returned (`"return"`).
    private var pendingAssignments: [Int: String] = [:]
    /// Names that receive a call result somewhere in the file; only their reads are recorded.
    private var assignedNames: Set<String> = []
    /// References whose call result is bound to locals, with the binding scope.
    private var assignments: [(reference: Int, scope: LocalScope, names: [String])] = []
    /// Reads of local bindings: the head line of the reading statement and the line of the read.
    private var localReads: [Binding: [(head: Int, line: Int)]] = [:]

    init(source: SourceBytes, tables: PythonTables, root: TSNode) {
        self.source = source
        self.kinds = tables.kinds
        self.f = tables.fields
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

    static let stopNames: Set<String> = [
        "print", "len", "range", "str", "int", "float", "bool", "list", "dict", "set", "tuple", "isinstance", "issubclass",
        "hasattr", "getattr", "setattr", "super", "self", "cls", "None", "True", "False", "enumerate", "zip", "map", "filter",
        "sorted", "open", "type", "object", "Exception", "ValueError", "KeyError", "TypeError", "append", "extend", "get",
        "items", "keys", "values", "format", "join", "split", "strip", "replace", "update", "pop", "add",
    ]

    static let builtinDecorators: Set<String> = ["property", "staticmethod", "classmethod", "abstractmethod", "cached_property"]

    /// Built-in and `typing` names that never resolve to repository declarations.
    static let builtinTypes: Set<String> = [
        "int", "str", "float", "bool", "bytes", "bytearray", "list", "dict", "set", "frozenset", "tuple", "None", "object",
        "type", "complex", "Any", "Optional", "Union", "List", "Dict", "Set", "FrozenSet", "Tuple", "Callable", "Iterable",
        "Iterator", "Generator", "AsyncIterator", "AsyncIterable", "AsyncGenerator", "Awaitable", "Coroutine", "Sequence",
        "MutableSequence", "Mapping", "MutableMapping", "Type", "TypeVar", "Generic", "Literal", "ClassVar", "Final",
        "Annotated", "Self", "NoReturn", "Never", "Protocol", "TypedDict", "NamedTuple", "Exception", "BaseException",
        "ValueError", "KeyError", "TypeError", "RuntimeError", "NotImplementedError", "AttributeError", "IndexError",
        "StopIteration", "OSError", "IOError", "AssertionError", "ParamSpec", "TypeAlias", "Concatenate", "Required", "NotRequired",
    ]

    mutating func run(_ root: TSNode) {
        stack.append(Frame(node: root, context: Context(enclosing: nil, owner: nil, scope: nil, level: .module, write: false, inType: false)))
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

    /// Lines of a statement: the whole of a simple statement, the header of a compound statement (up to its colon).
    /// Function and class headers are set where the definitions are visited, decorated or not.
    private func statementSpan(_ node: TSNode) -> (start: Int, end: Int)? {
        switch kind(node) {
        case .expressionStatement, .returnStatement, .raiseStatement, .assertStatement, .deleteStatement,
             .importStatement, .importFromStatement:
            return (node.startLine, node.endLine)
        case .ifStatement, .elifClause, .whileStatement, .forStatement, .withStatement, .exceptClause, .caseClause:
            return (node.startLine, headerEnd(node))
        default:
            return nil
        }
    }

    /// Last line of a compound statement's header: the latest-ending child before its first block.
    private func headerEnd(_ node: TSNode) -> Int {
        var end = node.startLine
        for child in kids(node) {
            let childKind = kind(child)
            if childKind == .block { break }
            if childKind != .comment { end = max(end, child.endLine) }
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

    /// The value inside `await` and parentheses.
    private func unwrapValue(_ node: TSNode) -> TSNode {
        var current = node
        while kind(current) == .awaitExpression || kind(current) == .parenthesizedExpression, let inner = kids(current).first {
            current = inner
        }
        return current
    }

    /// Remembers that the result of a call is bound to `names`: the reference it produces records them as
    /// `assignedTo`, and their later reads give its consuming statement.
    private mutating func bind(_ call: TSNode, to names: [String]) {
        guard !names.isEmpty else { return }
        pendingAssignments[call.startByte] = names.joined(separator: ",")
        assignedNames.formUnion(names)
    }

    @inline(__always)
    private func kind(_ node: TSNode) -> PythonKind {
        PythonKind(rawValue: kinds.code(node)) ?? .other
    }

    private func text(_ node: TSNode) -> String {
        source.text(node)
    }

    private mutating func push(_ node: TSNode?, _ context: Context) {
        guard let node else { return }
        stack.append(Frame(node: node, context: context))
    }

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

    // MARK: Dispatch

    private mutating func visit(_ node: TSNode, _ context: Context) {
        var context = context
        if let span = statementSpan(node) {
            context = inStatement(context, span.start, span.end)
        }
        switch kind(node) {
        case .comment, .integer, .float, .trueLiteral, .falseLiteral, .none, .futureImportStatement,
             .globalStatement, .nonlocalStatement, .wildcardImport:
            return
        case .block:
            // Every statement in a block sets its own span; nothing inherits the span of the code around the block.
            pushChildren(node, inStatement(context, 0, 0))
        case .returnStatement:
            if let value = kids(node).first, kind(unwrapValue(value)) == .call {
                pendingAssignments[unwrapValue(value).startByte] = "return"
            }
            pushChildren(node, context)
        case .string, .concatenatedString:
            visitString(node, context)
        case .importStatement:
            visitImport(node, context)
        case .importFromStatement:
            visitImportFrom(node, context)
        case .decoratedDefinition:
            let decorators = kids(node).filter { kind($0) == .decorator }
            guard let definition = node.field(f.definition) else { return }
            if kind(definition) == .classDefinition {
                visitClass(definition, context, decorators: decorators, outer: node)
            } else {
                visitFunction(definition, context, decorators: decorators, outer: node)
            }
        case .classDefinition:
            visitClass(node, context, decorators: [], outer: node)
        case .functionDefinition:
            visitFunction(node, context, decorators: [], outer: node)
        case .assignment:
            visitAssignment(node, context)
        case .augmentedAssignment:
            var write = context
            write.write = true
            var read = context
            read.write = false
            push(node.field(f.right), read)
            push(node.field(f.left), write)
        case .namedExpression:
            var read = context
            read.write = false
            push(node.field(f.value), read)
            if context.level != .function, let name = node.field(f.name) {
                var write = context
                write.write = true
                push(name, write)
            }
        case .call:
            visitCall(node, context)
        case .attribute:
            visitAttribute(node, context)
        case .identifier:
            visitIdentifier(node, context)
        case .keywordArgument:
            push(node.field(f.value), context)
        case .type:
            var inner = context
            inner.inType = true
            inner.write = false
            pushChildren(node, inner)
        case .subscriptExpression:
            var read = context
            read.write = false
            if let value = node.field(f.value), let chain = identifierChain(value), Self.isEnvironment(chain) {
                // `os.environ["X"]` names one variable; `os.environ[key]` could be any of them.
                let access: ReferenceKind = context.write ? .write : .read
                let index = kids(node, field: f.subscriptIndex).first
                if let index, let variable = literalString(index) {
                    emit("env:" + variable, access, index, context, receiver: chain, role: context.deleting ? .delete : .env)
                } else {
                    emit("env:*", access, node, context, receiver: chain, role: .envDynamic)
                    pushInOrder(kids(node, field: f.subscriptIndex).map { Optional($0) }, read)
                }
                return
            }
            pushInOrder([node.field(f.value)] + kids(node, field: f.subscriptIndex).map { Optional($0) }, read)
        case .lambda:
            let scope = LocalScope(parent: context.scope)
            var defaults: [TSNode?] = []
            if let parameters = node.field(f.parameters) { defaults = collectParameters(parameters, into: scope) }
            var inner = context
            inner.scope = scope
            inner.write = false
            // Defaults are evaluated where the lambda is created; the body when it is called.
            var body = inner
            body.deferred = true
            push(node.field(f.body), body)
            pushInOrder(defaults, inner)
        case .listComprehension, .setComprehension, .dictionaryComprehension, .generatorExpression:
            visitComprehension(node, context)
        case .forStatement:
            countDecision(context)
            var read = context
            read.write = false
            if context.level != .function, let left = node.field(f.left) {
                // Module-level loop variables are module globals; record writes to attributes only.
                if kind(left) == .attribute || kind(left) == .subscriptExpression {
                    var write = context
                    write.write = true
                    push(left, write)
                }
            }
            var parts: [TSNode?] = [node.field(f.right), node.field(f.body)]
            parts.append(contentsOf: kids(node).filter { $0.typeName == "else_clause" })
            pushInOrder(parts, read)
        case .ifStatement:
            countDecision(context)
            if context.level == .module, let condition = node.field(f.condition) {
                let conditionText = text(condition)
                if conditionText.contains("__name__") && conditionText.contains("__main__") { isEntryPoint = true }
            }
            if let condition = node.field(f.condition), ["TYPE_CHECKING", "typing.TYPE_CHECKING"].contains(text(condition)),
               let consequence = node.field(f.consequence) {
                // Only the guarded block is for type checkers; `else:` branches run.
                var typeChecking = context
                typeChecking.typeCheckingOnly = true
                for child in kids(node).reversed() {
                    push(child, child.startByte == consequence.startByte ? typeChecking : context)
                }
            } else {
                pushChildren(node, context)
            }
        case .elifClause, .whileStatement, .booleanOperator, .conditionalExpression, .caseClause, .ifClause:
            countDecision(context)
            pushChildren(node, context)
        case .exceptClause:
            countDecision(context)
            for child in kids(node) {
                switch kind(child) {
                case .asPattern:
                    // `except AuthError as error`: the type is a reference, the alias a local binding.
                    if let typeNode = kids(child).first(where: { kind($0) != .asPatternTarget }) {
                        var typeContext = context
                        typeContext.inType = true
                        push(typeNode, typeContext)
                    }
                case .block:
                    push(child, context)
                default:
                    var typeContext = context
                    typeContext.inType = true
                    push(child, typeContext)
                }
            }
        case .withItem:
            if let value = node.field(f.value) {
                if kind(value) == .asPattern {
                    if let expression = kids(value).first(where: { kind($0) != .asPatternTarget }) {
                        push(expression, context)
                    }
                } else {
                    push(value, context)
                }
            }
        case .decorator:
            visitDecorator(node, context)
        case .deleteStatement:
            var target = context
            target.write = true
            target.deleting = true
            pushChildren(node, target)
        default:
            pushChildren(node, context)
        }
    }

    // MARK: Imports

    /// Records an import. Imports inside functions run when the function is called, so they are dynamic like
    /// `importlib.import_module`; imports under `if TYPE_CHECKING:` never run and are type-only.
    private mutating func addImport(_ module: String, names: [ImportedName], line: Int, endLine: Int? = nil, context: Context, dynamic: Bool = false) {
        let kind: ImportKind = module.hasPrefix(".") ? .relative : .module
        imports.append(ExtractedImport(
            module: module, kind: kind, names: names, line: line, isTypeOnly: context.typeCheckingOnly,
            isDynamic: dynamic || context.deferred, endLine: endLine
        ))
    }

    private func dottedText(_ node: TSNode) -> String {
        // Normalise whitespace inside dotted names and relative prefixes.
        String(text(node).filter { !$0.isWhitespace })
    }

    private mutating func visitImport(_ node: TSNode, _ context: Context) {
        for child in kids(node, field: f.name) {
            switch kind(child) {
            case .dottedName:
                addImport(dottedText(child), names: [], line: child.startLine, endLine: node.endLine, context: context)
            case .aliasedImport:
                guard let name = child.field(f.name) else { continue }
                let alias = child.field(f.alias).map(text)
                addImport(dottedText(name), names: alias.map { [ImportedName(name: "*", alias: $0)] } ?? [], line: child.startLine,
                          endLine: node.endLine, context: context)
            default:
                break
            }
        }
    }

    private mutating func visitImportFrom(_ node: TSNode, _ context: Context) {
        guard let moduleNode = node.field(f.moduleName) else { return }
        let module = dottedText(moduleNode)
        var any = false
        for child in kids(node, field: f.name) {
            any = true
            switch kind(child) {
            case .dottedName:
                addImport(module, names: [ImportedName(name: dottedText(child))], line: child.startLine, endLine: node.endLine, context: context)
            case .aliasedImport:
                guard let name = child.field(f.name) else { continue }
                let alias = child.field(f.alias).map(text)
                let imported = dottedText(name)
                addImport(module, names: [ImportedName(name: imported, alias: alias == imported ? nil : alias)], line: child.startLine,
                          endLine: node.endLine, context: context)
            default:
                break
            }
        }
        if kids(node).contains(where: { kind($0) == .wildcardImport }) {
            addImport(module, names: [ImportedName(name: "*")], line: node.startLine, endLine: node.endLine, context: context)
        } else if !any {
            addImport(module, names: [], line: node.startLine, endLine: node.endLine, context: context)
        }
    }

    // MARK: Definitions

    private func docstring(_ body: TSNode?) -> String? {
        guard let body, let first = kids(body).first(where: { kind($0) != .comment }),
              kind(first) == .expressionStatement,
              let expression = kids(first).first,
              kind(expression) == .string || kind(expression) == .concatenatedString else { return nil }
        return TreeSitterUtilities.unquote(text(expression)).cleanedDocComment()
    }

    private func header(_ node: TSNode) -> String {
        var signature = source.text(node, upTo: node.field(f.body)).compactSignature()
        if signature.hasSuffix(":") { signature.removeLast() }
        return signature.trimmingCharacters(in: .whitespaces)
    }

    private func decoratorAttribute(_ decorator: TSNode) -> String? {
        guard let expression = kids(decorator).first else { return nil }
        if kind(expression) == .call, let function = expression.field(f.function) {
            return "@" + dottedText(function)
        }
        return "@" + dottedText(expression)
    }

    private static func visibility(of name: String) -> Visibility? {
        guard name.hasPrefix("_") else { return nil }
        if name.hasPrefix("__") && name.hasSuffix("__") { return nil }
        return .private
    }

    private mutating func visitDecorator(_ decorator: TSNode, _ context: Context) {
        guard let expression = kids(decorator).first else { return }
        // A decorator line is a statement of its own.
        let context = inStatement(context, decorator.startLine, decorator.endLine)
        var target = expression
        var callEnd: Int?
        if kind(expression) == .call {
            push(expression.field(f.arguments), context)
            guard let function = expression.field(f.function) else { return }
            target = function
            callEnd = expression.endLine
        }
        switch kind(target) {
        case .identifier:
            let name = text(target)
            if !Self.stopNames.contains(name) && !Self.builtinDecorators.contains(name) { emit(name, .decorator, target, context, callEnd: callEnd) }
        case .attribute:
            if let attribute = target.field(f.attribute), let object = target.field(f.object) {
                emit(text(attribute), .decorator, attribute, context, receiver: identifierChain(object) ?? "_", callEnd: callEnd)
            }
        default:
            push(target, context)
        }
    }

    private mutating func visitClass(_ node: TSNode, _ context: Context, decorators: [TSNode], outer: TSNode) {
        guard let nameNode = node.field(f.name) else { return }
        let name = text(nameNode)
        var inherited: [String] = []
        var baseReferences: [(String, TSNode, String?)] = []
        var otherArguments: [TSNode] = []
        if let superclasses = node.field(f.superclasses) {
            for argument in kids(superclasses) {
                switch kind(argument) {
                case .identifier:
                    let base = text(argument)
                    inherited.append(base)
                    if !Self.builtinTypes.contains(base) { baseReferences.append((base, argument, nil)) }
                case .attribute:
                    if let attribute = argument.field(f.attribute), let object = argument.field(f.object) {
                        let base = text(attribute)
                        inherited.append(base)
                        baseReferences.append((base, attribute, identifierChain(object) ?? "_"))
                    }
                case .subscriptExpression:
                    // `Generic[T]`, `Base[Model]`.
                    if let value = argument.field(f.value) {
                        if kind(value) == .identifier {
                            let base = text(value)
                            inherited.append(base)
                            if !Self.builtinTypes.contains(base) { baseReferences.append((base, value, nil)) }
                        } else if kind(value) == .attribute, let attribute = value.field(f.attribute), let object = value.field(f.object) {
                            inherited.append(text(attribute))
                            baseReferences.append((text(attribute), attribute, identifierChain(object) ?? "_"))
                        }
                    }
                    for index in kids(argument, field: f.subscriptIndex) { otherArguments.append(index) }
                default:
                    otherArguments.append(argument)
                }
            }
        }
        let symbol = symbols.add(
            name: name,
            kind: .class,
            range: LineRange(outer.startLine, node.endLine),
            parent: context.enclosing,
            signature: header(node),
            doc: docstring(node.field(f.body)),
            visibility: Self.visibility(of: name),
            isExported: context.level == .module && !name.hasPrefix("_"),
            attributes: decorators.compactMap(decoratorAttribute),
            inheritedTypes: inherited
        )
        classProperties[symbol] = []
        // `class A(Base):` is the statement of the base-class references; body statements set their own spans.
        var classContext = inStatement(context, node.startLine, headerEnd(node))
        classContext.enclosing = symbol
        classContext.owner = nil
        classContext.level = .classBody(symbol)
        classContext.write = false
        classContext.inType = false

        for (base, referenceNode, receiver) in baseReferences {
            emit(base, .inherit, referenceNode, classContext, receiver: receiver)
        }
        var typeContext = classContext
        typeContext.inType = true
        for decorator in decorators { visitDecorator(decorator, classContext) }
        if let body = node.field(f.body) {
            pushChildren(body, classContext)
        }
        // Base-class arguments such as `metaclass=Meta` or generic parameters.
        for argument in otherArguments.reversed() {
            push(argument, kind(argument) == .keywordArgument ? classContext : typeContext)
        }
    }

    private mutating func visitFunction(_ node: TSNode, _ context: Context, decorators: [TSNode], outer: TSNode) {
        guard let nameNode = node.field(f.name) else { return }
        let name = text(nameNode)
        let symbolKind: SymbolKind
        var classSymbol: Int?
        switch context.level {
        case .classBody(let owner):
            symbolKind = name == "__init__" ? .initializer : .method
            classSymbol = owner
        default:
            symbolKind = .function
        }
        var attributes = decorators.compactMap(decoratorAttribute)
        if cursor.hasAnonymousChild(of: node, table: kinds, code: PythonKind.tokAsync.rawValue) {
            attributes.append("async")
        }
        let body = node.field(f.body)
        let symbol = symbols.add(
            name: name,
            kind: symbolKind,
            range: LineRange(outer.startLine, node.endLine),
            parent: context.enclosing,
            signature: header(node),
            doc: docstring(body),
            visibility: Self.visibility(of: name),
            isExported: context.level == .module && !name.hasPrefix("_"),
            attributes: attributes
        )
        var decoratorContext = context
        decoratorContext.enclosing = symbol
        for decorator in decorators { visitDecorator(decorator, decoratorContext) }

        let scope = LocalScope(parent: context.scope)
        var defaults: [TSNode?] = []
        if let parameters = node.field(f.parameters) {
            defaults = collectParameters(parameters, into: scope)
        }
        if let body { collectLocals(body, into: scope) }

        // `def f(…) -> T:` is the statement of the annotations and defaults, which run when `def` does; the body runs
        // when the function is called.
        var header = inStatement(context, node.startLine, headerEnd(node))
        header.enclosing = symbol
        header.owner = symbol
        header.scope = scope
        header.level = .function
        header.write = false
        header.inType = false
        var inner = header
        inner.deferred = true
        var returnContext = header
        returnContext.inType = true

        if symbolKind == .initializer, let classSymbol, let body {
            addSelfProperties(body, classSymbol: classSymbol)
        }
        if let body, body.endLine - body.startLine + 1 >= 5 {
            symbols[symbol].bodyHash = hashBody(body)
        }
        push(body, inner)
        push(node.field(f.returnType), returnContext)
        pushInOrder(defaults, header)
    }

    /// Records parameter names in `scope`; returns annotation/default nodes to analyze.
    private func collectParameters(_ parameters: TSNode, into scope: LocalScope) -> [TSNode?] {
        var parts: [TSNode?] = []
        for parameter in kids(parameters) {
            switch kind(parameter) {
            case .identifier:
                scope.insert(text(parameter))
            case .typedParameter:
                for child in kids(parameter) where kind(child) != .type {
                    collectTargetNames(child, into: scope)
                }
                parts.append(parameter.field(f.type))
            case .defaultParameter:
                if let name = parameter.field(f.name) { collectTargetNames(name, into: scope) }
                parts.append(parameter.field(f.value))
            case .typedDefaultParameter:
                if let name = parameter.field(f.name) { collectTargetNames(name, into: scope) }
                parts.append(parameter.field(f.type))
                parts.append(parameter.field(f.value))
            case .listSplatPattern, .dictionarySplatPattern, .tuplePattern:
                collectTargetNames(parameter, into: scope)
            default:
                break
            }
        }
        return parts
    }

    /// Identifiers bound by an assignment/loop target (not attributes or subscripts).
    private func collectTargetNames(_ target: TSNode, into scope: LocalScope) {
        var pending = [target]
        while let node = pending.popLast() {
            switch kind(node) {
            case .identifier:
                scope.insert(text(node))
            case .tuplePattern, .listPattern, .patternList, .listSplatPattern, .dictionarySplatPattern, .tuple, .list,
                 .expressionList, .parenthesizedExpression, .asPatternTarget:
                pending.append(contentsOf: kids(node))
            default:
                break
            }
        }
    }

    /// Function-local bindings (not descending into nested functions, classes, lambdas or comprehensions).
    private func collectLocals(_ body: TSNode, into scope: LocalScope) {
        var pending = [body]
        while let node = pending.popLast() {
            switch kind(node) {
            case .functionDefinition, .classDefinition:
                if let name = node.field(f.name) { scope.insert(text(name)) }
            case .decoratedDefinition:
                if let definition = node.field(f.definition), let name = definition.field(f.name) { scope.insert(text(name)) }
            case .assignment:
                if let left = node.field(f.left) { collectTargetNames(left, into: scope) }
                if let right = node.field(f.right), kind(right) == .assignment { pending.append(right) }
            case .augmentedAssignment:
                if let left = node.field(f.left) { collectTargetNames(left, into: scope) }
            case .forStatement:
                if let left = node.field(f.left) { collectTargetNames(left, into: scope) }
                pending.append(contentsOf: kids(node).filter { kind($0) == .block || $0.typeName == "else_clause" })
            case .withStatement:
                for clause in kids(node) {
                    if kind(clause) == .block {
                        pending.append(clause)
                        continue
                    }
                    for item in kids(clause) where kind(item) == .withItem {
                        if let value = item.field(f.value), kind(value) == .asPattern {
                            for target in kids(value, field: f.alias) { collectTargetNames(target, into: scope) }
                        }
                    }
                }
            case .exceptClause:
                for child in kids(node) {
                    if kind(child) == .asPattern {
                        for target in kids(child, field: f.alias) { collectTargetNames(target, into: scope) }
                    } else if kind(child) == .block {
                        pending.append(child)
                    }
                }
            case .namedExpression:
                if let name = node.field(f.name) { scope.insert(text(name)) }
            case .parenthesizedExpression:
                // `if (match := pattern.search(text)):` binds `match` in the function.
                pending.append(contentsOf: kids(node).filter { kind($0) == .namedExpression || kind($0) == .parenthesizedExpression })
            case .globalStatement, .nonlocalStatement:
                for child in kids(node) where kind(child) == .identifier { scope.insert(text(child)) }
            case .block, .expressionStatement, .ifStatement, .elifClause, .whileStatement:
                pending.append(contentsOf: kids(node))
            case .other:
                let type = node.typeName
                if type == "else_clause" || type == "try_statement" || type == "finally_clause" || type == "match_statement"
                    || type == "case_clause" || type == "with_clause" {
                    pending.append(contentsOf: kids(node))
                }
            case .caseClause:
                pending.append(contentsOf: kids(node))
            default:
                break
            }
        }
    }

    /// `self.x = …` inside `__init__` declares instance properties on the class.
    private mutating func addSelfProperties(_ body: TSNode, classSymbol: Int) {
        var pending = [body]
        var found: [(String, TSNode)] = []
        while let node = pending.popLast() {
            switch kind(node) {
            case .assignment:
                if let left = node.field(f.left) {
                    var targets = [left]
                    while let target = targets.popLast() {
                        if kind(target) == .attribute, let object = target.field(f.object), kind(object) == .identifier,
                           text(object) == "self", let attribute = target.field(f.attribute) {
                            found.append((text(attribute), node))
                        } else if kind(target) == .patternList || kind(target) == .tuplePattern {
                            targets.append(contentsOf: kids(target))
                        }
                    }
                }
            case .functionDefinition, .classDefinition, .decoratedDefinition, .lambda:
                break
            case .block, .expressionStatement, .ifStatement, .elifClause, .forStatement, .whileStatement, .withStatement:
                pending.append(contentsOf: kids(node).reversed())
            case .other:
                let type = node.typeName
                if type == "else_clause" || type == "try_statement" || type == "finally_clause" || type == "except_clause" {
                    pending.append(contentsOf: kids(node).reversed())
                }
            default:
                break
            }
        }
        for (name, assignment) in found.sorted(by: { $0.1.startByte < $1.1.startByte }) {
            guard classProperties[classSymbol]?.contains(name) != true else { continue }
            classProperties[classSymbol, default: []].insert(name)
            symbols.add(
                name: name,
                kind: .property,
                range: LineRange(assignment.startLine, assignment.endLine),
                parent: classSymbol,
                signature: source.text(assignment).compactSignature(maxLength: 120),
                visibility: Self.visibility(of: name)
            )
        }
    }

    private func hashBody(_ body: TSNode) -> UInt64 {
        TreeSitterUtilities.structuralHash(body) { node in
            switch kind(node) {
            case .identifier: return -1
            case .string, .concatenatedString, .integer, .float, .trueLiteral, .falseLiteral, .none: return -2
            default: return nil
            }
        }
    }

    // MARK: Assignments

    private mutating func visitAssignment(_ node: TSNode, _ context: Context) {
        let left = node.field(f.left)
        let right = node.field(f.right)
        let typeNode = node.field(f.type)
        var read = context
        read.write = false
        read.inType = false
        var typeContext = read
        typeContext.inType = true
        if let left, let right {
            // `x = f()` and `a, b = f()` bind the call's result.
            let value = unwrapValue(right)
            if kind(value) == .call { bind(value, to: boundNames(left)) }
        }

        switch context.level {
        case .module, .classBody:
            guard let left else {
                pushInOrder([typeNode, right], read)
                return
            }
            if context.level == .module, kind(left) == .identifier, text(left) == "__all__", let right {
                for element in kids(right) where kind(element) == .string {
                    let name = TreeSitterUtilities.unquote(text(element))
                    if !name.isEmpty { exportedNames.append("\(name)=\(name)") }
                }
                return
            }
            var targetNames: [(name: String, node: TSNode)] = []
            var otherTargets: [TSNode] = []
            var pending = [left]
            while let target = pending.popLast() {
                switch kind(target) {
                case .identifier:
                    targetNames.append((text(target), target))
                case .patternList, .tuplePattern, .listPattern, .tuple, .list, .expressionList:
                    pending.append(contentsOf: kids(target).reversed())
                default:
                    otherTargets.append(target)
                }
            }
            var firstSymbol: Int?
            for (name, _) in targetNames {
                let symbolKind: SymbolKind
                var parent = context.enclosing
                if case .classBody(let owner) = context.level {
                    symbolKind = .property
                    parent = owner
                    if let owner {
                        if classProperties[owner]?.contains(name) == true { continue }
                        classProperties[owner, default: []].insert(name)
                    }
                } else {
                    symbolKind = TreeSitterUtilities.isScreamingCase(name) ? .constant : .variable
                }
                let symbol = symbols.add(
                    name: name,
                    kind: symbolKind,
                    range: LineRange(node.startLine, node.endLine),
                    parent: parent,
                    signature: text(node).compactSignature(maxLength: 120),
                    visibility: Self.visibility(of: name),
                    isExported: context.level == .module && !name.hasPrefix("_")
                )
                if firstSymbol == nil { firstSymbol = symbol }
            }
            var valueContext = read
            var valueTypeContext = typeContext
            if let firstSymbol {
                valueContext.enclosing = firstSymbol
                valueTypeContext.enclosing = firstSymbol
            }
            var write = read
            write.write = true
            pushInOrder(otherTargets, write)
            push(right, valueContext)
            push(typeNode, valueTypeContext)
        case .function:
            var write = read
            write.write = true
            push(right, read)
            push(typeNode, typeContext)
            push(left, write)
        }
    }

    /// Names an assignment target binds, in order (`a`, `a, b`, `(a, [b, c])`); attributes and subscripts bind none.
    private func boundNames(_ target: TSNode) -> [String] {
        var names: [String] = []
        var pending = [target]
        while let node = pending.popLast() {
            switch kind(node) {
            case .identifier:
                names.append(text(node))
            case .patternList, .tuplePattern, .listPattern, .tuple, .list, .expressionList, .parenthesizedExpression, .listSplatPattern:
                pending.append(contentsOf: kids(node).reversed())
            default:
                break
            }
        }
        return names
    }

    // MARK: Comprehensions

    private mutating func visitComprehension(_ node: TSNode, _ context: Context) {
        let scope = LocalScope(parent: context.scope)
        for clause in kids(node) where kind(clause) == .forInClause {
            if let left = clause.field(f.left) { collectTargetNames(left, into: scope) }
        }
        var inner = context
        inner.scope = scope
        inner.write = false
        var parts: [TSNode] = []
        for child in kids(node) {
            if kind(child) == .forInClause {
                if let right = child.field(f.right) { parts.append(right) }
            } else {
                parts.append(child)
            }
        }
        pushInOrder(parts, inner)
    }

    // MARK: Expressions

    private func identifierChain(_ node: TSNode) -> String? {
        var parts: [String] = []
        var current = node
        while true {
            switch kind(current) {
            case .identifier:
                parts.append(text(current))
                return parts.reversed().joined(separator: ".")
            case .attribute:
                guard let attribute = current.field(f.attribute), let object = current.field(f.object) else { return nil }
                parts.append(text(attribute))
                current = object
            default:
                return nil
            }
        }
    }

    private static func isDunder(_ name: String) -> Bool {
        name.count > 4 && name.hasPrefix("__") && name.hasSuffix("__")
    }

    /// The value of a plain string literal; nil for an f-string with interpolations or any other expression.
    private func literalString(_ node: TSNode) -> String? {
        guard kind(node) == .string, !kids(node).contains(where: { kind($0) == .interpolation }) else { return nil }
        return TreeSitterUtilities.unquote(text(node))
    }

    /// `os.environ`, or `environ` imported from `os`: the mapping whose keys are environment variables.
    private static func isEnvironment(_ chain: String) -> Bool {
        chain == "os.environ" || chain == "environ"
    }

    /// Calls that read or write one environment variable named by their first argument: `os.getenv`, `os.putenv`,
    /// `os.unsetenv`, and `get`, `setdefault` and `pop` on `os.environ`. Nil for any other call.
    private static func environmentAccess(_ name: String, receiver: String) -> ReferenceKind? {
        if receiver == "os" {
            switch name {
            case "getenv": return .read
            case "putenv", "unsetenv": return .write
            default: return nil
            }
        }
        guard isEnvironment(receiver) else { return nil }
        switch name {
        case "get": return .read
        case "setdefault", "pop": return .write
        default: return nil
        }
    }

    private mutating func emit(
        _ name: String, _ kind: ReferenceKind, _ node: TSNode, _ context: Context, receiver: String? = nil,
        role: ReferenceContext? = nil, callEnd: Int? = nil, assignedTo: String? = nil
    ) {
        guard !name.isEmpty else { return }
        let line = node.startLine
        // Outside any statement (a lambda default, a comprehension in a decorator) a reference has no span.
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

    /// The syntactic role of a reference unless its emitter names one (environment variables).
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

    private func isLocal(_ name: String, _ context: Context) -> Bool {
        context.scope?.contains(name) ?? false
    }

    /// Records a read of a local that holds a call result: its statement may be the call's consuming statement.
    private mutating func noteLocalRead(_ name: String, _ node: TSNode, _ context: Context) {
        guard assignedNames.contains(name), let scope = context.scope?.declaringScope(of: name) else { return }
        let line = node.startLine
        let head = context.statementStart > 0 && context.statementStart <= line ? context.statementStart : line
        localReads[Binding(scope: scope, name: name), default: []].append((head, line))
    }

    private mutating func visitIdentifier(_ node: TSNode, _ context: Context) {
        let name = text(node)
        if context.inType {
            if !Self.builtinTypes.contains(name) && !isLocal(name, context) && name != "self" && name != "cls" {
                emit(name, .typeUse, node, context)
            }
            return
        }
        guard !Self.stopNames.contains(name), !Self.isDunder(name) else { return }
        if isLocal(name, context) {
            if !context.write { noteLocalRead(name, node, context) }
            return
        }
        emit(name, context.write ? .write : .read, node, context)
    }

    private mutating func visitAttribute(_ node: TSNode, _ context: Context) {
        guard let attribute = node.field(f.attribute), let object = node.field(f.object) else {
            pushChildren(node, context)
            return
        }
        let name = text(attribute)
        let receiver = identifierChain(object) ?? "_"
        if receiver == "os" && name == "environ" {
            // The whole environment: copied, iterated, updated or passed on (single variables are read above).
            emit("env:*", context.write ? .write : .read, attribute, context, receiver: receiver, role: .envAll)
            return
        }
        let root = receiver.split(separator: ".", maxSplits: 1).first.map(String.init) ?? receiver
        // Attribute access on a local value (other than self/cls) cannot be resolved without types.
        let onLocal = root != "self" && root != "cls" && receiver != "_" && isLocal(root, context)
        if !onLocal && !Self.isDunder(name) && !(Self.stopNames.contains(name) && receiver != "self" && receiver != "cls") {
            let referenceKind: ReferenceKind = context.inType ? .typeUse : (context.write ? .write : .read)
            emit(name, referenceKind, attribute, context, receiver: receiver)
        }
        var objectContext = context
        objectContext.write = false
        objectContext.inType = false
        push(object, objectContext)
    }

    private mutating func visitCall(_ node: TSNode, _ context: Context) {
        var inner = context
        inner.write = false
        inner.inType = false
        guard let function = node.field(f.function) else {
            pushChildren(node, inner)
            return
        }
        let assigned = pendingAssignments.removeValue(forKey: node.startByte)
        let firstArgument = node.field(f.arguments).flatMap { kids($0).first }
        let literal = firstArgument.flatMap(literalString)
        switch kind(function) {
        case .identifier:
            let name = text(function)
            if name == "__import__", let literal {
                addImport(literal, names: [], line: node.startLine, endLine: node.endLine, context: context, dynamic: true)
            }
            if Self.stopNames.contains(name) || Self.isDunder(name) { break }
            if isLocal(name, context) {
                // Calling a local reads it.
                noteLocalRead(name, function, context)
            } else {
                emit(name, TreeSitterUtilities.isPascalCase(name) ? .instantiate : .call, function, inner, callEnd: node.endLine, assignedTo: assigned)
            }
        case .attribute:
            if let attribute = function.field(f.attribute), let object = function.field(f.object) {
                let name = text(attribute)
                let receiver = identifierChain(object) ?? "_"
                if let access = Self.environmentAccess(name, receiver: receiver) {
                    // `os.getenv("X")` names one variable; `os.getenv(key)` could be any of them.
                    if let literal, let firstArgument {
                        emit("env:" + literal, access, firstArgument, inner, receiver: receiver, role: .env)
                    } else {
                        emit("env:*", access, attribute, inner, receiver: receiver, role: .envDynamic)
                    }
                    push(node.field(f.arguments), inner)
                    return
                }
                if receiver == "importlib", name == "import_module", let literal {
                    addImport(literal, names: [], line: node.startLine, endLine: node.endLine, context: context, dynamic: true)
                }
                if !Self.isDunder(name) && !Self.stopNames.contains(name) {
                    emit(name, TreeSitterUtilities.isPascalCase(name) ? .instantiate : .call, attribute, inner, receiver: receiver,
                         callEnd: node.endLine, assignedTo: assigned)
                }
                push(object, inner)
            }
        default:
            push(function, inner)
        }
        push(node.field(f.arguments), inner)
    }

    /// String annotations (`"User"`) are forward type references; f-string interpolations hold expressions.
    private mutating func visitString(_ node: TSNode, _ context: Context) {
        if context.inType {
            let value = TreeSitterUtilities.unquote(text(node))
            let parts = value.split(separator: ".")
            if let last = parts.last, !last.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }),
               !Self.builtinTypes.contains(String(last)) {
                emit(String(last), .typeUse, node, context, receiver: parts.count > 1 ? parts.dropLast().joined(separator: ".") : nil)
            }
            return
        }
        var inner = context
        inner.write = false
        for child in kids(node) where kind(child) == .interpolation || kind(child) == .string {
            pushChildren(child, inner)
        }
    }

    private mutating func countDecision(_ context: Context) {
        complexity += 1
        symbols.addComplexity(context.owner)
    }
}
