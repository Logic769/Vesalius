import Foundation
import Testing
import VesaliusRender

/// The budgeter's cut order and paging. Self-contained logic with edge cases; the real proof is
/// the MCP and CLI output on real repositories.
@Suite("Budgeter")
struct BudgeterTests {
    static func site(_ line: Int, _ code: String, primary: Bool = false) -> Site {
        Site(line: line, code: code, primary: primary)
    }

    /// `files` files, each with one member of `sites` sites whose code repeats every `repeatEvery` sites.
    static func document(files: Int, sites: Int, repeatEvery: Int = 1_000, testFiles: Set<Int> = []) -> RenderDocument {
        let blocks = (0..<files).map { file in
            FileBlock(path: "Sources/Feature\(file)/File\(file).swift", labels: testFiles.contains(file) ? ["[test]"] : [], isTest: testFiles.contains(file), members: [
                MemberBlock(heading: "func caller\(file)() :10-90", sites: (0..<sites).map { index in
                    site(20 + index * 3, "let value\(index % repeatEvery) = service.compute(input: \(index % repeatEvery))", primary: index == 0)
                }, trailer: ["called by: root() :5"]),
            ])
        }
        return RenderDocument(head: ["Service.compute(input:)  Sources/Service.swift:10-40", "\(files * sites) calls in \(files) files"],
                              completeness: "complete: all sites resolved", unresolved: ["unresolved: Sources/Other.swift:7 compute(x)"],
                              blocks: blocks, tail: ["not code uses: comments Sources/Service.swift:3"],
                              more: MoreCall(tool: "usages", arguments: [MoreCall.Argument("target", .string("Service.compute(input:)"))]))
    }

    @Test("A result that fits prints whole, with the completeness line joined to line 2")
    func fits() {
        let text = Budgeter.render(Self.document(files: 2, sites: 3), budget: Budget(tokens: 10_000))
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "Service.compute(input:)  Sources/Service.swift:10-40")
        #expect(lines[1] == "6 calls in 2 files · complete: all sites resolved")
        #expect(lines[2] == "unresolved: Sources/Other.swift:7 compute(x)")
        #expect(lines.contains("    20 │ let value0 = service.compute(input: 0)"))
        #expect(lines.contains("    ·23 let value1 = service.compute(input: 1) ·26 let value2 = service.compute(input: 2)"))
        #expect(lines.last == "not code uses: comments Sources/Service.swift:3")
        #expect(!text.contains("showing"))
    }

    @Test("Cuts apply in order: same code, then line lists, then five sites per file, then tests on one line")
    func cutOrder() {
        let repeated = Self.document(files: 1, sites: 4, repeatEvery: 1)
        let full = Budgeter.render(repeated, budget: Budget(tokens: 10_000))
        let tight = TokenEstimate.of(full) - 1
        #expect(Budgeter.render(repeated, budget: Budget(tokens: tight)).contains("·23 same ·26 same ·29 same"))

        let many = Self.document(files: 1, sites: 12)
        let lists = Budgeter.render(many, budget: Budget(tokens: TokenEstimate.of(Budgeter.render(many, budget: .unlimited)) - 1))
        #expect(lists.contains("    also at 23-53 ×11"))

        let capped = Budgeter.render(Self.document(files: 3, sites: 12), budget: Budget(tokens: 160))
        #expect(capped.contains("  +7 more"))
        #expect(!capped.contains("also at 23-53 ×11"))

        let tests = Budgeter.render(Self.document(files: 3, sites: 12, testFiles: [0]), budget: Budget(tokens: 140))
        #expect(tests.contains("\nSources/Feature0/File0.swift  [test]  20-53 ×12\n"))
    }

    @Test("Over budget it pages by file; head, completeness, unresolved and tail stay on every page")
    func paging() {
        let document = Self.document(files: 30, sites: 6)
        let budget = Budget(tokens: 300)
        let first = Budgeter.render(document, budget: budget)
        #expect(TokenEstimate.of(first) <= 300)
        #expect(first.split(separator: "\n").last?.hasPrefix("showing ") == true)
        #expect(first.contains("· more: usages(target:\"Service.compute(input:)\", page:2)"))

        var page = 1
        var seen: [String] = []
        while true {
            let text = Budgeter.render(document, budget: budget.page(page))
            let lines = text.split(separator: "\n").map(String.init)
            #expect(lines[1].hasSuffix("· complete: all sites resolved"))
            #expect(lines.contains("unresolved: Sources/Other.swift:7 compute(x)"))
            #expect(lines.contains("not code uses: comments Sources/Service.swift:3"))
            seen += lines.filter { $0.hasPrefix("Sources/Feature") }
            if lines.last?.hasSuffix("(last page)") == true { break }
            page += 1
            if page > 40 { Issue.record("paging never ends"); break }
        }
        #expect(seen.count == 30 && Set(seen).count == 30)
        #expect(Budgeter.render(document, budget: budget.page(page + 1)).contains("page \(page + 1) is past the end: \(page) pages of 30 files"))
    }

    @Test("Line lists keep every line readable")
    func lineLists() {
        #expect(LineList.format([55, 53, 100, 101, 148, 149, 150, 151, 152, 153]) == "53,55,100,101,148-153")
        #expect(LineList.format(Array(148...160) + [171]) == "171 148-160 ×13")
        #expect(LineList.collapsed(Array(stride(from: 151, through: 842, by: 22))) == "151-833 ×32")
        #expect(LineList.collapsed([3, 1, 2]) == "1-3")
    }

    @Test("Long code keeps both ends")
    func elision() {
        let code = "let encrypted = try await credentialStore.encryptAndPersist(privateKey: data.privateKey, issuer: data.issuerID, keyID: data.keyID)"
        let short = Elide.middle(code)
        #expect(short.count <= Elide.codeLimit)
        #expect(short.hasPrefix("let encrypted = try await") && short.hasSuffix("keyID: data.keyID)") && short.contains("…"))
        #expect(Elide.middle("short") == "short")
        #expect(TokenEstimate.of("abcd") == 2)
    }
}
