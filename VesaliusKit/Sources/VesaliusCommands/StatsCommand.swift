import ArgumentParser
import Foundation
import QueryEngine
import RepositoryIndex
import VesaliusMCP
import VesaliusRender

/// `vesalius stats`: what agents asked Vesalius, read from the local usage log.
struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What Claude asked Vesalius here: calls per tool, answer sizes and times.",
        discussion: """
            Read from a local log of answered calls (\(UsageReport.tilde(UsageLog.url.path))): the repository path, \
            the tool, the answer's size and time, and whether its completeness check passed. Never questions, \
            symbols or code. Set VESALIUS_STATS=off to stop recording.
            """
    )

    @Flag(name: .long, help: "Every repository, one row each, instead of this one by tool.")
    var all = false

    @Option(name: .long, help: "How many days back to count (0 for everything recorded).")
    var days = 30

    @Flag(name: .long, help: "Delete the usage log.")
    var reset = false

    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if days < 0 { throw ValidationError("--days must be 0 or more.") }
    }

    func run() async throws {
        try await global.run {
            if reset {
                struct Reset: Encodable { let deleted: Bool; let path: String }
                let result = Reset(deleted: try UsageLog.reset(), path: UsageLog.url.path)
                try global.emit(result) { result.deleted ? "Deleted the usage log (\(UsageReport.tilde(result.path)))." : "There was no usage log to delete." }
                return
            }
            let since = days > 0 ? Date().addingTimeInterval(-Double(days) * 86_400) : nil
            let records = UsageLog.read().filter { since == nil || $0.time >= since! }
            let repository = all ? nil : IndexLocation.canonicalRoot(global.repositoryURL()).path
            let report = UsageReport(records: records, repository: repository, days: days)
            try global.emit(report) { report.text() }
        }
    }
}

/// Totals over the usage log, by tool for one repository or by repository for all of them.
struct UsageReport: Encodable {
    struct Row: Encodable {
        let name: String
        var calls = 0
        var errors = 0
        var answerCharacters = 0
        var complete = 0
        var incomplete = 0
        var medianMilliseconds = 0
        private var times: [Int] = []

        init(name: String) { self.name = name }

        mutating func add(_ record: UsageRecord) {
            calls += 1
            if record.isError { errors += 1 }
            answerCharacters += record.answerCharacters
            if record.complete == true { complete += 1 }
            if record.complete == false { incomplete += 1 }
            times.append(record.milliseconds)
        }

        /// Sets the median once every record is in.
        mutating func finish() {
            let sorted = times.sorted()
            guard !sorted.isEmpty else { return }
            medianMilliseconds = sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
        }

        enum CodingKeys: String, CodingKey { case name, calls, errors, answerCharacters, complete, incomplete, medianMilliseconds }
    }

    /// The repository reported on, or nil for all of them.
    let repository: String?
    let days: Int
    let rows: [Row]
    let total: Row
    let lastCall: Date?
    let overMCP: Int
    let fromCommandLine: Int
    let recording: Bool

    init(records: [UsageRecord], repository: String?, days: Int) {
        // Records stamped in the future come from a clock that ran ahead; they count once their time comes.
        let now = Date().addingTimeInterval(300)
        let mine = records.filter { $0.time <= now && (repository == nil || IndexLocation.canonicalRoot(URL(fileURLWithPath: $0.repository)).path == repository) }
        var rows: [String: Row] = [:]
        var total = Row(name: "total")
        for record in mine {
            let key = repository == nil ? IndexLocation.canonicalRoot(URL(fileURLWithPath: record.repository)).path : record.tool
            rows[key, default: Row(name: key)].add(record)
            total.add(record)
        }
        total.finish()
        self.repository = repository
        self.days = days
        self.rows = rows.values.map { row in
            var row = row
            row.finish()
            return row
        }.sorted { ($0.calls, $1.name) > ($1.calls, $0.name) }
        self.total = total
        self.lastCall = mine.map(\.time).max().map { min($0, Date()) }
        self.overMCP = mine.filter { $0.via == "mcp" }.count
        self.fromCommandLine = mine.count - overMCP
        self.recording = UsageLog.isEnabled()
    }

    func text() -> String {
        let scope = repository.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "all repositories"
        let window = days > 0 ? "last \(days) day\(days == 1 ? "" : "s")" : "everything recorded"
        var lines = ["Vesalius usage · \(scope) · \(window)", ""]
        guard total.calls > 0 else {
            lines.append(repository == nil
                ? "No calls recorded yet. Once Claude Code calls Vesalius, they show up here."
                : "No calls recorded for this repository yet. Once Claude Code calls Vesalius here, they show up here.")
            lines.append(recording ? "To check that Claude Code can reach it, run `vesalius doctor`." : "Recording is off (\(UsageLog.environmentKey)=off).")
            return lines.joined(separator: "\n")
        }
        let label = repository == nil ? "repository" : "tool"
        let names = rows.map { repository == nil ? Self.tilde($0.name) : $0.name }
        let width = max(label.count, names.map(\.count).max() ?? 0, 5) + 3
        func row(_ name: String, _ row: Row) -> String {
            "  " + name.padding(toLength: width, withPad: " ", startingAt: 0) + "\(row.calls)".leftPadded(to: 5)
                + Self.tokens(row.answerCharacters).leftPadded(to: 9)
                + Self.tokens(row.answerCharacters / max(row.calls, 1)).leftPadded(to: 13)
                + "\(row.medianMilliseconds) ms".leftPadded(to: 15)
        }
        lines.append("  " + label.padding(toLength: width, withPad: " ", startingAt: 0) + "calls   tokens   per answer   typical time")
        for (name, value) in zip(names, rows) { lines.append(row(name, value)) }
        if rows.count > 1 { lines.append(row("total", total)) }
        lines.append("")
        let origin = fromCommandLine == 0 ? "all over MCP" : overMCP == 0 ? "all from the command line"
            : "\(overMCP) over MCP, \(fromCommandLine) from the command line"
        lines.append("  Last call \(lastCall.map { TextFormatter.relative($0) } ?? "never"); \(origin).")
        let judged = total.complete + total.incomplete
        if judged > 0 { lines.append("  Completeness checks passed: \(total.complete) of \(judged).") }
        if total.errors > 0 { lines.append("  \(total.errors) call\(total.errors == 1 ? "" : "s") returned an error.") }
        lines.append("  Tokens are what Vesalius sent, estimated at 4 characters each, not what it saved; docs/benchmark")
        lines.append("  measures the savings. Typical time is the median.")
        if !recording { lines.append("  Recording is off (\(UsageLog.environmentKey)=off), so newer calls are missing.") }
        if repository != nil { lines.append("  Other repositories: vesalius stats --all") }
        return lines.joined(separator: "\n")
    }

    /// Characters as estimated tokens: `850`, `14.2k`, `412k`, `1.9M`.
    static func tokens(_ characters: Int) -> String {
        let tokens = Int((Double(characters) / 4).rounded())
        if tokens < 1_000 { return "\(tokens)" }
        let tenths = (Double(tokens) / 100).rounded() / 10
        if tenths < 100 { return String(format: "%.1fk", tenths) }
        let thousands = Int((Double(tokens) / 1_000).rounded())
        if thousands < 1_000 { return "\(thousands)k" }
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
