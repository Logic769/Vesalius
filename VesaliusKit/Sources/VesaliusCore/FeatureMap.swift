import Foundation

/// Where and how a feature is implemented: the core type or file, its members grouped by the roles the
/// question names, each with its decisive lines, the environment and data it touches, every call site of the
/// core, configuration, one doc section, lookalikes that are not the feature, and which roles were found.
///
/// A "how does X write/commit…" question gets a `flow` instead of roles: the ordered call sites of the main
/// method with IO sinks flagged, the other writers, the readers of what it writes and the files of the format.
/// Every line carries its code as it reads on disk; nothing carries a score.
public struct FeatureMapResult: Codable, Sendable, Hashable {
    public var question: String
    public var headline: FeatureHeadline
    public var core: FeatureCore?
    /// Type- or file-level constants that matter (`static let annualID = "yearly_atlas"`).
    public var keyLiterals: [FeatureEvidence]
    public var roles: [FeatureRole]
    public var environment: [FeatureEnvLink]
    public var tables: [FeatureTable]
    public var callSites: FeatureCallSites?
    public var flow: FlowView?
    public var config: [FeatureConfig]
    public var docs: FeatureDocSection?
    public var notThisFeature: [FeatureLookalike]
    public var coverage: FeatureCoverage

    public init(question: String, headline: FeatureHeadline, core: FeatureCore? = nil, keyLiterals: [FeatureEvidence] = [], roles: [FeatureRole] = [],
                environment: [FeatureEnvLink] = [], tables: [FeatureTable] = [], callSites: FeatureCallSites? = nil, flow: FlowView? = nil,
                config: [FeatureConfig] = [], docs: FeatureDocSection? = nil, notThisFeature: [FeatureLookalike] = [], coverage: FeatureCoverage = FeatureCoverage()) {
        self.question = question
        self.headline = headline
        self.core = core
        self.keyLiterals = keyLiterals
        self.roles = roles
        self.environment = environment
        self.tables = tables
        self.callSites = callSites
        self.flow = flow
        self.config = config
        self.docs = docs
        self.notThisFeature = notThisFeature
        self.coverage = coverage
    }
}

/// The first line: what the feature is and which frameworks implement it.
public struct FeatureHeadline: Codable, Sendable, Hashable {
    /// The question's subject in its own words (`in-app purchases & subscriptions`).
    public var feature: String
    public var frameworks: [FeatureFramework]
    /// Said when the question's concept has known SDKs and the repository imports none of the others.
    public var note: String?

    public init(feature: String, frameworks: [FeatureFramework] = [], note: String? = nil) {
        self.feature = feature
        self.frameworks = frameworks
        self.note = note
    }
}

public struct FeatureFramework: Codable, Sendable, Hashable {
    public var name: String
    /// Files that import it (mocks excluded).
    public var importers: Int

    public init(name: String, importers: Int) {
        self.name = name
        self.importers = importers
    }
}

/// The type (or, for TypeScript and Python, the file) the feature is built around.
public struct FeatureCore: Codable, Sendable, Hashable {
    public var path: String
    /// The type's qualified name; nil for a file.
    public var name: String?
    /// Its declaration with attributes (`@MainActor final class PremiumStore: ObservableObject`).
    public var signature: String?
    public var lines: LineRange
    /// How code gets hold of it (`static let shared :24`).
    public var access: String?

    public init(path: String, name: String? = nil, signature: String? = nil, lines: LineRange, access: String? = nil) {
        self.path = path
        self.name = name
        self.signature = signature
        self.lines = lines
        self.access = access
    }
}

/// One line of evidence: its number and its code as it reads on disk.
public struct FeatureEvidence: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A framework or library call (`Transaction.updates`, `safeStorage.encryptString`).
        case external
        /// An IO sink (`pwrite`, `fs.writeFileSync`, `db.insert`) or a function that wraps one.
        case sink
        /// An environment variable read or write.
        case env
        /// The return value of a short Boolean getter (`return isReady && !isSubscribed`).
        case gate
        /// A write to the core's stored state.
        case write
        /// A string constant (`static let annualID = "yearly_atlas"`).
        case literal
        /// A `guard` that decides whether the member goes on.
        case `guard`
        /// A call into the feature (`await subs.purchase(planID: plan.id)`).
        case call
        /// A use of the feature that is not a call.
        case read
        /// A column of a table definition.
        case column
        /// Any other step of a flow.
        case step
    }

    public var line: Int
    /// The statement (up to 3 source lines joined, middle elided), or for a compact line just its gist.
    public var code: String
    public var kind: Kind
    /// Printed as `NNN │ code`; others print compactly as `·NNN code`.
    public var primary: Bool
    /// Printed after the code: `→ :42 db.insert(apiTokens)`, `(catch)`.
    public var note: String?
    /// Further lines with the same use, printed with a compact line (`·120,133,146 showsUpgrade`).
    public var moreLines: [Int]

    public init(line: Int, code: String, kind: Kind, primary: Bool = false, note: String? = nil, moreLines: [Int] = []) {
        self.line = line
        self.code = code
        self.kind = kind
        self.primary = primary
        self.note = note
        self.moreLines = moreLines
    }
}

/// A role the question names (`load`, `buy`, `restore`, `premium access`) and the members that play it.
public struct FeatureRole: Codable, Sendable, Hashable {
    public var label: String
    public var members: [FeatureMember]

    public init(label: String, members: [FeatureMember]) {
        self.label = label
        self.members = members
    }
}

/// A function, method or property and the lines that decide what it does.
public struct FeatureMember: Codable, Sendable, Hashable {
    /// `start()`, `purchase(planID:)`, `showsUpgrade`, `POST /api/tokens`.
    public var name: String
    public var path: String
    public var lines: LineRange
    /// The first sentence of its documentation.
    public var doc: String?
    /// The member it hands the work to (`purchase(planID:)` → `purchase(_:)`).
    public var delegate: FeatureRef?
    public var evidence: [FeatureEvidence]
    /// Who calls it, when that is part of the answer (`← :483`).
    public var calledBy: [FeatureCaller]

    public init(name: String, path: String, lines: LineRange, doc: String? = nil, delegate: FeatureRef? = nil, evidence: [FeatureEvidence] = [], calledBy: [FeatureCaller] = []) {
        self.name = name
        self.path = path
        self.lines = lines
        self.doc = doc
        self.delegate = delegate
        self.evidence = evidence
        self.calledBy = calledBy
    }
}

public struct FeatureRef: Codable, Sendable, Hashable {
    public var name: String
    public var path: String
    public var lines: LineRange

    public init(name: String, path: String, lines: LineRange) {
        self.name = name
        self.path = path
        self.lines = lines
    }
}

public struct FeatureCaller: Codable, Sendable, Hashable {
    /// The calling declaration (`WaxSession.commit`), or nil at file level.
    public var name: String?
    public var path: String
    public var line: Int
    /// What consumes the call's result: `→ :58 signJwt(…)`.
    public var note: String?

    public init(name: String?, path: String, line: Int, note: String? = nil) {
        self.name = name
        self.path = path
        self.line = line
        self.note = note
    }
}

/// An environment variable the feature reads or writes, with the code on both sides.
public struct FeatureEnvLink: Codable, Sendable, Hashable {
    public var name: String
    public var writers: [FeatureEnvSite]
    public var readers: [FeatureEnvSite]
    /// The function that sets it for the code that reads it (`ensureDataKey()`), with its decisive lines.
    public var producer: FeatureMember?

    public init(name: String, writers: [FeatureEnvSite], readers: [FeatureEnvSite], producer: FeatureMember? = nil) {
        self.name = name
        self.writers = writers
        self.readers = readers
        self.producer = producer
    }
}

public struct FeatureEnvSite: Codable, Sendable, Hashable {
    public var path: String
    public var line: Int
    /// The enclosing declaration (`readDataKey()`).
    public var function: String?
    public var isTest: Bool

    public init(path: String, line: Int, function: String?, isTest: Bool) {
        self.path = path
        self.line = line
        self.function = function
        self.isTest = isTest
    }
}

/// A table (or persisted model) the feature writes or reads, with the columns the question is about.
public struct FeatureTable: Codable, Sendable, Hashable {
    /// The stored name (`asc_credentials`), else the declaration's.
    public var name: String
    /// The declaration in code (`apiTokens`).
    public var symbol: String
    public var path: String
    public var lines: LineRange
    public var columns: [FeatureEvidence]
    /// Functions that insert, update or delete rows, and functions that read them.
    public var writers: [FeatureCaller]
    public var readers: [FeatureCaller]

    public init(name: String, symbol: String, path: String, lines: LineRange, columns: [FeatureEvidence], writers: [FeatureCaller] = [], readers: [FeatureCaller] = []) {
        self.name = name
        self.symbol = symbol
        self.path = path
        self.lines = lines
        self.columns = columns
        self.writers = writers
        self.readers = readers
    }
}

/// Every file that uses the core, with the sites in each (production before tests).
public struct FeatureCallSites: Codable, Sendable, Hashable {
    /// What the sites use: a type name or a file path.
    public var subject: String
    public var files: [FeatureCallSiteFile]
    /// The count line's reconciliation: `complete: …` or `INCOMPLETE: …`, computed, never assumed.
    public var completeness: String?
    /// Files that only mock the core (`vi.mock`).
    public var mockOnly: [String]

    public init(subject: String, files: [FeatureCallSiteFile], completeness: String? = nil, mockOnly: [String] = []) {
        self.subject = subject
        self.files = files
        self.completeness = completeness
        self.mockOnly = mockOnly
    }

    public var appFiles: Int { files.filter { !$0.isTest }.count }
    public var testFiles: Int { files.filter(\.isTest).count }
}

public struct FeatureCallSiteFile: Codable, Sendable, Hashable {
    public var path: String
    /// `[test]`, `[#if DEBUG]`.
    public var labels: [String]
    public var isTest: Bool
    /// After the path: `:6 imports {encrypt}`.
    public var header: String?
    public var groups: [FeatureCallSiteGroup]

    public init(path: String, labels: [String] = [], isTest: Bool = false, header: String? = nil, groups: [FeatureCallSiteGroup] = []) {
        self.path = path
        self.labels = labels
        self.isTest = isTest
        self.header = header
        self.groups = groups
    }

    public var siteCount: Int { groups.reduce(0) { $0 + $1.sites.count } }
}

/// The sites inside one enclosing declaration.
public struct FeatureCallSiteGroup: Codable, Sendable, Hashable {
    /// `body`, `openSecret()`, `POST /api/tokens`; nil at file level.
    public var caller: String?
    public var callerLines: LineRange?
    public var sites: [FeatureEvidence]
    /// One hop up when the caller is a local helper (`loadToken :41`).
    public var calledBy: [FeatureCaller]

    public init(caller: String?, callerLines: LineRange? = nil, sites: [FeatureEvidence], calledBy: [FeatureCaller] = []) {
        self.caller = caller
        self.callerLines = callerLines
        self.sites = sites
        self.calledBy = calledBy
    }
}

/// A function's call sites in order, with resolved targets and IO sinks flagged.
public struct FlowView: Codable, Sendable, Hashable {
    /// Where the flow starts (`Wax.commit`).
    public var entry: FeatureRef
    /// The body that does the work when the entry only hands it on (`commitLocked()`).
    public var body: FeatureRef
    /// The sinks the flow reaches, as `FDFile.writeAll → pwrite`.
    public var sinks: [String]
    public var calledBy: [FeatureCaller]
    /// Callers left out of `calledBy`.
    public var moreCallers: Int
    public var steps: [FlowStep]
    /// The core type's other members that write through a sink (`putLocked`).
    public var otherWriters: [FeatureMember]
    /// The core type's members that read back what the flow writes (`Wax.open`).
    public var readers: [FeatureMember]
    /// The files that define what is written, rolled up by folder.
    public var format: [FlowFormatGroup]

    public init(entry: FeatureRef, body: FeatureRef, sinks: [String] = [], calledBy: [FeatureCaller] = [], steps: [FlowStep] = [],
                otherWriters: [FeatureMember] = [], readers: [FeatureMember] = [], format: [FlowFormatGroup] = [], moreCallers: Int = 0) {
        self.entry = entry
        self.body = body
        self.sinks = sinks
        self.calledBy = calledBy
        self.moreCallers = moreCallers
        self.steps = steps
        self.otherWriters = otherWriters
        self.readers = readers
        self.format = format
    }
}

public struct FlowStep: Codable, Sendable, Hashable {
    public var line: Int
    public var code: String
    /// What the step calls, when it resolved into the repository (`MV2STOC.encode`), with its span.
    public var target: String?
    public var targetLines: LineRange?
    public var isSink: Bool

    public init(line: Int, code: String, target: String? = nil, targetLines: LineRange? = nil, isSink: Bool = false) {
        self.line = line
        self.code = code
        self.target = target
        self.targetLines = targetLines
        self.isSink = isSink
    }
}

/// A folder of format files (or a single file) and the types each declares.
public struct FlowFormatGroup: Codable, Sendable, Hashable {
    public var folder: String
    public var files: [FlowFormatFile]
    /// The folder's other files, left out: they declare none of the flow's types (`+79 more in Atlas/Services/`).
    public var more: Int

    public init(folder: String, files: [FlowFormatFile], more: Int = 0) {
        self.folder = folder
        self.files = files
        self.more = more
    }
}

public struct FlowFormatFile: Codable, Sendable, Hashable {
    public var path: String
    public var types: [String]

    public init(path: String, types: [String]) {
        self.path = path
        self.types = types
    }
}

/// A configuration file tied to the feature (`Atlas.storekit`), with what ties it.
public struct FeatureConfig: Codable, Sendable, Hashable {
    public var path: String
    public var line: Int?
    public var summary: String

    public init(path: String, line: Int? = nil, summary: String) {
        self.path = path
        self.line = line
        self.summary = summary
    }
}

/// The best documentation section near the feature, which may be out of date.
public struct FeatureDocSection: Codable, Sendable, Hashable {
    public var path: String
    public var heading: String
    public var lines: LineRange
    public var quote: [FeatureEvidence]

    public init(path: String, heading: String, lines: LineRange, quote: [FeatureEvidence]) {
        self.path = path
        self.heading = heading
        self.lines = lines
        self.quote = quote
    }
}

/// A search match that is not this feature, and why.
public struct FeatureLookalike: Codable, Sendable, Hashable {
    public var name: String
    public var path: String
    public var reason: String

    public init(name: String, path: String, reason: String) {
        self.name = name
        self.path = path
        self.reason = reason
    }
}

/// Which of the question's roles (or concepts) the map found code for.
public struct FeatureCoverage: Codable, Sendable, Hashable {
    public var found: [String]
    public var missing: [String]

    public init(found: [String] = [], missing: [String] = []) {
        self.found = found
        self.missing = missing
    }
}
