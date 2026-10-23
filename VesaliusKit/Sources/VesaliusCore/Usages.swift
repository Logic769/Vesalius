import Foundation

/// The edit `usages(target, change:)` plans for.
public enum UsageChange: String, Codable, Sendable, CaseIterable {
    case rename
    case signature
    case remove
}

/// Who calls, uses, imports or depends on one target: the target's declaration, the totals and the
/// completeness line computed from the same rows, every use grouped by file and enclosing declaration with its
/// code, the footers (lookalikes, transitive files, mocks, text mentions), and with `change` the edit sections.
///
/// The view follows from the kind of target, never from a guess at intent: a function gives its callers, a
/// property its writes and reads, a type its users with how each file obtains it, a file (or folder, module) its
/// dependents by owner type and member, a framework its importers and their calls into it, an environment
/// variable its reads and writes. A name that matches several declarations gives `choices` and nothing merged.
public struct UsagesResult: Codable, Sendable, Hashable {
    public enum View: String, Codable, Sendable {
        case callers
        case property
        case type
        /// A symbol that is neither callable, a property nor a type (an enum case, a macro…): its uses.
        case references
        case file
        case folder
        case module
        case framework
        case environment
        case choices
    }

    public var view: View
    /// The exact target string: passing it back selects the same target (`more:` calls use it).
    public var target: String
    public var change: UsageChange?
    /// Line 1.
    public var header: UsageHeader
    /// Line 2, before the completeness.
    public var totals: UsageTotals
    public var completeness: UsageCompleteness?
    /// Head lines after line 2, never cut (`PremiumStore is used by 4 files; 3 read isSubscribed`).
    public var notes: [String]
    /// Production before tests, direct before type-inferred, unconditional before `#if`, then by path.
    public var files: [UsageFile]
    /// The declaring file of a property, on one line (`reads ·86 showsUpgrade … | writes ·96 init …`).
    public var declaringFile: UsageDeclaringFile?
    public var footers: [UsageFooter]
    public var sections: UsageChangeSections?
    public var choices: [UsageChoice]
    /// Files edited since indexing among those quoted: their lines may have moved.
    public var staleFiles: [String]

    public init(view: View, target: String, change: UsageChange? = nil, header: UsageHeader, totals: UsageTotals, completeness: UsageCompleteness? = nil,
                notes: [String] = [], files: [UsageFile] = [], declaringFile: UsageDeclaringFile? = nil, footers: [UsageFooter] = [],
                sections: UsageChangeSections? = nil, choices: [UsageChoice] = [], staleFiles: [String] = []) {
        self.view = view
        self.target = target
        self.change = change
        self.header = header
        self.totals = totals
        self.completeness = completeness
        self.notes = notes
        self.files = files
        self.declaringFile = declaringFile
        self.footers = footers
        self.sections = sections
        self.choices = choices
        self.staleFiles = staleFiles
    }
}

/// Line 1: the resolved declaration (with attributes and setter access), or the file, folder, module, framework
/// or environment variable.
public struct UsageHeader: Codable, Sendable, Hashable {
    /// `@Published private(set) var isSubscribed = false`, `LibraryService.importBook(from:preferences:modelContext:)
    /// async -> Book?`, a path, `StoreKit`, `env:API_KEY`.
    public var title: String
    public var path: String?
    public var lines: LineRange?
    /// `method of LibraryService`, `class`, `framework`, `environment variable`.
    public var kind: String
    /// The build targets that compile the declaration's file.
    public var buildTargets: [String]
    /// How membership was decided when it is not the target's own folder (`membership exception,
    /// Atlas.xcodeproj/project.pbxproj:135`).
    public var membership: String?
    /// The `#if` condition around the declaration.
    public var conditions: String?
    /// File, folder and module targets: their top-level declarations (`WALFlags :3-11`).
    public var declares: [UsageDeclared]
    public var declaresMore: Int

    public init(title: String, path: String? = nil, lines: LineRange? = nil, kind: String, buildTargets: [String] = [], membership: String? = nil,
                conditions: String? = nil, declares: [UsageDeclared] = [], declaresMore: Int = 0) {
        self.title = title
        self.path = path
        self.lines = lines
        self.kind = kind
        self.buildTargets = buildTargets
        self.membership = membership
        self.conditions = conditions
        self.declares = declares
        self.declaresMore = declaresMore
    }
}

public struct UsageDeclared: Codable, Sendable, Hashable {
    public var name: String
    public var kind: String
    public var lines: LineRange

    public init(name: String, kind: String, lines: LineRange) {
        self.name = name
        self.kind = kind
        self.lines = lines
    }
}

/// Line 2: `3 callers in 3 files (app 3, test 0)`, `20 uses in 12 files (Atlas 2 · AtlasWatch Watch App 10)`,
/// `imported by 11 files (7 source, 4 test)`. Every number comes from the rows the result lists.
public struct UsageTotals: Codable, Sendable, Hashable {
    /// `caller`, `use`, `site`, `file`, `importer`, `read or write`.
    public var noun: String
    public var count: Int
    public var files: Int
    /// By build target when the files span several, else production against tests.
    public var split: [UsageCount]
    public var splitByTarget: Bool
    /// Further facts: `2 writes, 15 reads`, `2 more only mock it`, `+1 by type flow`.
    public var extra: [String]

    public init(noun: String, count: Int, files: Int, split: [UsageCount] = [], splitByTarget: Bool = false, extra: [String] = []) {
        self.noun = noun
        self.count = count
        self.files = files
        self.split = split
        self.splitByTarget = splitByTarget
        self.extra = extra
    }
}

public struct UsageCount: Codable, Sendable, Hashable {
    public var label: String
    public var count: Int

    public init(_ label: String, _ count: Int) {
        self.label = label
        self.count = count
    }
}

/// The reconciliation of every occurrence of the target's name in the indexed text.
public struct UsageCompleteness: Codable, Sendable, Hashable {
    /// True only when every occurrence is accounted for: nothing unresolved or unrecorded, no capped scan, no
    /// common name left unchecked, no file edited since indexing.
    public var isComplete: Bool
    /// `complete: "importBook" occurs 9×: 3 resolved to the target, 1 declaration, …; 0 unresolved`.
    public var summary: String
    /// Every occurrence the index cannot account for, each with its code.
    public var unresolved: [UsageOccurrence]
    /// Comments, docs, strings and non-source text that mention the name (`TEXT ONLY`).
    public var textOnly: [UsageOccurrence]
    /// `$name`, `\.name`, `#selector(name)` and `"name"` forms found.
    public var dynamic: [UsageOccurrence]
    /// The forms checked (`$isSubscribed`, `\.isSubscribed`, `"isSubscribed"`).
    public var formsChecked: [String]

    public init(isComplete: Bool, summary: String, unresolved: [UsageOccurrence] = [], textOnly: [UsageOccurrence] = [], dynamic: [UsageOccurrence] = [], formsChecked: [String] = []) {
        self.isComplete = isComplete
        self.summary = summary
        self.unresolved = unresolved
        self.textOnly = textOnly
        self.dynamic = dynamic
        self.formsChecked = formsChecked
    }
}

/// One occurrence of the name outside the resolved uses.
public struct UsageOccurrence: Codable, Sendable, Hashable {
    public var path: String
    public var line: Int
    /// `comment`, `doc`, `string`, `non-source`, `unresolved`, `unrecorded`, `projected`, `keypath`…
    public var category: String
    /// The line's code (unresolved and unrecorded sites).
    public var code: String?
    /// Why it is unresolved, or what it resolved to.
    public var detail: String?

    public init(path: String, line: Int, category: String, code: String? = nil, detail: String? = nil) {
        self.path = path
        self.line = line
        self.category = category
        self.code = code
        self.detail = detail
    }
}

/// The uses in one file.
public struct UsageFile: Codable, Sendable, Hashable {
    public var path: String
    public var isTest: Bool
    /// `unit`, `ui` or `support` (from the build target, else the test runner's globs).
    public var testKind: String?
    /// `#if DEBUG`, `type-inferred via scanRecords → WALRecordLocation.record: WALRecord`, `reads`, `writes`…
    public var labels: [String]
    /// TypeScript and Python: the import statement's line and the names it imports.
    public var importLine: Int?
    public var importedNames: [String]
    /// Type and owner-user views: the line that gives the file the type (an annotation, an instantiation, a
    /// static read), as code.
    public var via: UsageCodeLine?
    /// Callers, property and TypeScript views: the uses grouped by enclosing declaration.
    public var groups: [UsageGroup]
    /// Type and file views: the members used, by owner type.
    public var owners: [UsageOwnerUses]
    /// A fact about the file in one line (`uses Copy, monthlyID, Plan; not isSubscribed`).
    public var note: String?

    public init(path: String, isTest: Bool = false, testKind: String? = nil, labels: [String] = [], importLine: Int? = nil, importedNames: [String] = [],
                via: UsageCodeLine? = nil, groups: [UsageGroup] = [], owners: [UsageOwnerUses] = [], note: String? = nil) {
        self.path = path
        self.isTest = isTest
        self.testKind = testKind
        self.labels = labels
        self.importLine = importLine
        self.importedNames = importedNames
        self.via = via
        self.groups = groups
        self.owners = owners
        self.note = note
    }

    public var siteCount: Int { groups.reduce(0) { $0 + $1.sites.count } }
}

/// The uses inside one enclosing declaration (or the file's top level).
public struct UsageGroup: Codable, Sendable, Hashable {
    /// `private func ImportSheet.beginImport(urls:)`, `var ContentView.body`; nil for top-level code.
    public var declaration: String?
    public var lines: LineRange?
    /// The `#if` condition around the declaration (when the file as a whole has another one, or none).
    public var conditions: String?
    /// The first sentence of the declaration's doc comment, else of its type's (`isTypeDoc`).
    public var doc: String?
    public var isTypeDoc: Bool
    /// The HTTP route the declaration serves (`POST /api/tokens`).
    public var route: String?
    /// True when no site is a call (a method passed as a value, a read of a function).
    public var isReferenceOnly: Bool
    /// In ascending line order. The first is the primary site and carries the whole statement.
    public var sites: [UsageSite]
    /// One hop up: who calls this declaration, at most 3.
    public var calledBy: [UsageCaller]
    public var calledByMore: Int
    /// A non-exported helper's callers in its own file (`← loadToken :41`).
    public var inFileCallers: [UsageCaller]

    public init(declaration: String? = nil, lines: LineRange? = nil, conditions: String? = nil, doc: String? = nil, isTypeDoc: Bool = false, route: String? = nil,
                isReferenceOnly: Bool = false, sites: [UsageSite] = [], calledBy: [UsageCaller] = [], calledByMore: Int = 0, inFileCallers: [UsageCaller] = []) {
        self.declaration = declaration
        self.lines = lines
        self.conditions = conditions
        self.doc = doc
        self.isTypeDoc = isTypeDoc
        self.route = route
        self.isReferenceOnly = isReferenceOnly
        self.sites = sites
        self.calledBy = calledBy
        self.calledByMore = calledByMore
        self.inFileCallers = inFileCallers
    }
}

/// One use of the target.
public struct UsageSite: Codable, Sendable, Hashable {
    public var line: Int
    /// 1-based UTF-8 column.
    public var column: Int
    /// `call`, `read`, `write`, `type`, `instantiate`, `inherit`, `conform`…
    public var kind: String
    /// `projected` (`$x`), `keypath` (`\.x`), `implicit` (`.x`), `pattern` (`case .x`).
    public var form: String?
    /// How the linker decided it (`typed`, `self`, `static`, `import`, `lexical`, `unique-name`).
    public var basis: String?
    public var conditions: String?
    /// The first sites of a group are primary: they carry the whole statement; the others carry their line.
    public var isPrimary: Bool
    /// The whole statement for a primary site (at most 3 lines, elided to 110 characters each), else its line.
    public var code: [UsageCodeLine]
    /// The `if`, `guard`, `switch` or `case` line that governs the statement.
    public var condition: UsageCodeLine?
    /// The statement that consumes the assigned result (`→ :42 db.insert(apiTokens)`).
    public var consumer: UsageCodeLine?
    /// The member of the target used (type and file views).
    public var member: String?

    public init(line: Int, column: Int = 0, kind: String, form: String? = nil, basis: String? = nil, conditions: String? = nil, isPrimary: Bool = false,
                code: [UsageCodeLine] = [], condition: UsageCodeLine? = nil, consumer: UsageCodeLine? = nil, member: String? = nil) {
        self.line = line
        self.column = column
        self.kind = kind
        self.form = form
        self.basis = basis
        self.conditions = conditions
        self.isPrimary = isPrimary
        self.code = code
        self.condition = condition
        self.consumer = consumer
        self.member = member
    }
}

/// A source line as evidence: its number and its text (comments dropped, whitespace collapsed, `…` for text
/// left out).
public struct UsageCodeLine: Codable, Sendable, Hashable {
    public var line: Int
    public var text: String

    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

/// A caller one hop up, or an entry point.
public struct UsageCaller: Codable, Sendable, Hashable {
    /// `pickFiles(urls:)` in the same type, `ContentView.body` elsewhere.
    public var name: String
    /// The file, when it is not the file of the declaration it calls.
    public var path: String?
    public var line: Int
    public var conditions: String?

    public init(name: String, path: String? = nil, line: Int, conditions: String? = nil) {
        self.name = name
        self.path = path
        self.line = line
        self.conditions = conditions
    }
}

/// Type and file views: what one dependent file uses of one owner type (or of a file's top-level declarations).
public struct UsageOwnerUses: Codable, Sendable, Hashable {
    /// `WALRecord`; for top-level functions and constants, their own name.
    public var owner: String
    public var members: [UsageMemberUse]

    public init(owner: String, members: [UsageMemberUse]) {
        self.owner = owner
        self.members = members
    }
}

public struct UsageMemberUse: Codable, Sendable, Hashable {
    /// `headerSize`, `decode(from:offset:)`, `.isPadding`; `type` for the owner's own name.
    public var name: String
    public var lines: [Int]
    /// `r`, `w`, `call`… when they say more than the name does.
    public var kinds: [String]
    /// The declarations the uses are in (`ReadingPlan.schedule(week:calendar:)`).
    public var enclosing: [String]

    public init(name: String, lines: [Int], kinds: [String] = [], enclosing: [String] = []) {
        self.name = name
        self.lines = lines
        self.kinds = kinds
        self.enclosing = enclosing
    }
}

/// A property's own file: its reads and writes there, by enclosing declaration.
public struct UsageDeclaringFile: Codable, Sendable, Hashable {
    public var path: String
    public var reads: [UsageCaller]
    public var writes: [UsageCaller]

    public init(path: String, reads: [UsageCaller], writes: [UsageCaller]) {
        self.path = path
        self.reads = reads
        self.writes = writes
    }
}

/// A labelled line after the files. The labels are the ones the output grammar reserves for material that is
/// not a use.
public struct UsageFooter: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Other declarations of the same name, with their use counts and exact targets.
        case alsoNamed = "also named"
        /// Sites the linker rejected for the target (`MetalVectorEngine.swift:877 vectorsBuffer.length (MTLBuffer)`).
        case rejectedLookalikes = "rejected lookalikes"
        /// Files that reach the target only through other files.
        case transitiveOnly = "transitive only"
        /// Files that only mock the target (`vi.mock`).
        case mockOnly = "mock only"
        /// Files no build target compiles.
        case notBuilt = "not built"
        /// Comments, docs, strings and non-source mentions.
        case notCodeUses = "not code uses"
    }

    public var kind: Kind
    /// `(not listed)`, `(vi.mock)`.
    public var qualifier: String?
    public var items: [String]
    public var more: Int

    public init(kind: Kind, qualifier: String? = nil, items: [String], more: Int = 0) {
        self.kind = kind
        self.qualifier = qualifier
        self.items = items
        self.more = more
    }
}

/// A declaration among several that a target string matched.
public struct UsageChoice: Codable, Sendable, Hashable {
    /// The string that selects exactly this choice.
    public var target: String
    public var kind: String
    public var location: String?
    public var uses: Int
    public var files: Int

    public init(target: String, kind: String, location: String?, uses: Int, files: Int) {
        self.target = target
        self.kind = kind
        self.location = location
        self.uses = uses
        self.files = files
    }
}

// MARK: - Change sections

/// What `change: rename | signature | remove` adds, in a fixed order (WITNESS OF / OVERRIDES / VIA PROTOCOL
/// need the witness table, which is not built yet).
public struct UsageChangeSections: Codable, Sendable, Hashable {
    /// OWNER USERS is the result's file list; this is its head line (`PremiumStore is used by 4 files;
    /// 3 read isSubscribed`).
    public var ownerUsers: String?
    /// TEXT ONLY: comments, docs, strings and non-source mentions that a rename leaves stale.
    public var textOnly: [String]
    public var textOnlyMore: Int
    /// DYNAMIC: the forms checked, and where they occur.
    public var dynamicChecked: [String]
    public var dynamicHits: [String]
    public var tests: UsageTests
    /// ENTRY POINTS: roots reached through callers in at most 3 hops (`body`, `@main`, tests, route handlers).
    public var entryPoints: [UsageEntryPoint]
    public var entryPointsMore: Int
    /// NOT AFFECTED: other declarations with the same base name (other overloads).
    public var notAffected: [String]
    /// COVERAGE: how many sites of the name were resolved.
    public var coverage: String?

    public init(ownerUsers: String? = nil, textOnly: [String] = [], textOnlyMore: Int = 0, dynamicChecked: [String] = [], dynamicHits: [String] = [],
                tests: UsageTests = UsageTests(), entryPoints: [UsageEntryPoint] = [], entryPointsMore: Int = 0, notAffected: [String] = [], coverage: String? = nil) {
        self.ownerUsers = ownerUsers
        self.textOnly = textOnly
        self.textOnlyMore = textOnlyMore
        self.dynamicChecked = dynamicChecked
        self.dynamicHits = dynamicHits
        self.tests = tests
        self.entryPoints = entryPoints
        self.entryPointsMore = entryPointsMore
        self.notAffected = notAffected
        self.coverage = coverage
    }
}

/// An entry point and the chain from it to the target.
public struct UsageEntryPoint: Codable, Sendable, Hashable {
    /// `ContentView.body`, `POST /api/tokens`, `BookTests.testImport()`.
    public var root: String
    public var path: String
    public var line: Int
    /// Callers between the root and the target, outermost first.
    public var via: [String]

    public init(root: String, path: String, line: Int, via: [String] = []) {
        self.root = root
        self.path = path
        self.line = line
        self.via = via
    }
}

/// TESTS: which tests a change touches and how to run them. Each tier states what links the test to the target;
/// nothing beyond that link is claimed.
public struct UsageTests: Codable, Sendable, Hashable {
    /// Test files with uses of the target itself.
    public var direct: [UsageTestFile]
    /// Test files that use the target's owner type but not the target: they recompile, with their suites.
    public var compileCoupled: [UsageTestFile]
    /// UI tests whose literals equal (or, in a CONTAINS check, are part of) an app literal next to a use.
    public var ui: [UsageUILink]
    /// Launch hooks: environment variables UI tests set that a function writing the target reads.
    public var hooks: [UsageHook]
    /// Commands that run them, quoted from the repository's runner scripts, schemes and package scripts.
    public var run: [UsageRunCommand]

    public init(direct: [UsageTestFile] = [], compileCoupled: [UsageTestFile] = [], ui: [UsageUILink] = [], hooks: [UsageHook] = [], run: [UsageRunCommand] = []) {
        self.direct = direct
        self.compileCoupled = compileCoupled
        self.ui = ui
        self.hooks = hooks
        self.run = run
    }

    public var isEmpty: Bool { direct.isEmpty && compileCoupled.isEmpty && ui.isEmpty && hooks.isEmpty && run.isEmpty }
}

public struct UsageTestFile: Codable, Sendable, Hashable {
    public var path: String
    /// `unit` or `ui`.
    public var kind: String
    /// Suites declared in the file (types with `@Suite` or `@Test` members, `XCTestCase` subclasses).
    public var suites: [String]
    public var lines: [Int]
    /// What the file uses of the owner type, for compile-coupled files.
    public var uses: [String]

    public init(path: String, kind: String, suites: [String] = [], lines: [Int] = [], uses: [String] = []) {
        self.path = path
        self.kind = kind
        self.suites = suites
        self.lines = lines
        self.uses = uses
    }
}

/// A UI-test literal that matches an app literal near a use of the target.
public struct UsageUILink: Codable, Sendable, Hashable {
    public var testPath: String
    /// The test function around the literal, and its line.
    public var test: String
    public var testLine: Int
    public var literal: String
    public var literalLine: Int
    /// `equal`, or `contains` when the test checks that a text contains the literal.
    public var match: String
    public var appPath: String
    public var appLine: Int
    /// 1: in a declaration that uses the target; 2: in a declaration such a declaration references (same file);
    /// 3: elsewhere in a file that uses the target.
    public var tier: Int

    public init(testPath: String, test: String, testLine: Int, literal: String, literalLine: Int, match: String, appPath: String, appLine: Int, tier: Int) {
        self.testPath = testPath
        self.test = test
        self.testLine = testLine
        self.literal = literal
        self.literalLine = literalLine
        self.match = match
        self.appPath = appPath
        self.appLine = appLine
        self.tier = tier
    }
}

/// `ATLAS_SKIP_INTRO set in UITestBase.swift:41,45 → read in PremiumStore.start :96, which sets
/// isSubscribed = true :97`.
public struct UsageHook: Codable, Sendable, Hashable {
    public var variable: String
    /// Where tests set it.
    public var setters: [UsageLocationList]
    public var settersMore: Int
    /// The function that reads it and writes the target.
    public var reader: String
    public var readerPath: String
    public var readLine: Int
    /// The target's write in that function.
    public var write: UsageCodeLine?

    public init(variable: String, setters: [UsageLocationList], settersMore: Int = 0, reader: String, readerPath: String, readLine: Int, write: UsageCodeLine?) {
        self.variable = variable
        self.setters = setters
        self.settersMore = settersMore
        self.reader = reader
        self.readerPath = readerPath
        self.readLine = readLine
        self.write = write
    }
}

/// Lines in one file.
public struct UsageLocationList: Codable, Sendable, Hashable {
    public var path: String
    public var lines: [Int]
    /// What the lines are in, when that says more than the file: `in launch, 156 callers`.
    public var note: String?

    public init(path: String, lines: [Int], note: String? = nil) {
        self.path = path
        self.lines = lines
        self.note = note
    }
}

/// A command that runs the tests, as the repository spells it.
public struct UsageRunCommand: Codable, Sendable, Hashable {
    /// `scripts/test.sh build`, `xcodebuild test -scheme Atlas -only-testing:AtlasTests/ShelfTests`.
    public var command: String
    /// Where it is written (a runner script's usage line, a scheme, `package.json`).
    public var path: String?
    public var line: Int?
    /// The usage line's own description.
    public var description: String?

    public init(command: String, path: String? = nil, line: Int? = nil, description: String? = nil) {
        self.command = command
        self.path = path
        self.line = line
        self.description = description
    }
}
