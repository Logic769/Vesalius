import Foundation
@testable import QueryEngine
import Testing
import VesaliusCore
import VesaliusMCP
@testable import VesaliusRender

/// A flow's format roll-up: a folder holding 3 or more of the flow's format types is listed whole when most
/// of its files declare one, else by those files and a count of the others. The fixture is a real repository on
/// disk, indexed and queried through the engine, the `outline` tool and the built `vesalius` executable.
@Suite("Flow format roll-up", .serialized)
struct FormatRollupTests {
    /// `Journal.commit()` writes through a sink and uses 3 types from each of three folders: 3 of the 4 files of
    /// `Store/Format/`, 3 of the 6 of `Store/Codec/` and 3 of the 10 of `App/Shared Services/` (a space in the
    /// folder, as in `Atlas/Views/Reading List/`).
    static let journal: [String: String] = {
        var files: [String: String] = [
            "Store/Journal.swift": """
                import Foundation
                import Darwin

                final class FileHandleBox {
                    let fd: Int32 = 3

                    func writeAll(_ data: [UInt8], at offset: Int) {
                        _ = data.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
                    }
                }

                final class Journal {
                    let file = FileHandleBox()

                    func commit() throws {
                        let started = WallClock.now()
                        var bytes = PageHeader(version: 1).encode()
                        bytes += PageIndex(count: 2).encode()
                        bytes += Varint(value: 7).encode() + Zigzag(value: -1).encode() + Crc(seed: 0).encode()
                        bytes += PageFooter(length: bytes.count).encode()
                        file.writeAll(bytes, at: 0)
                        JournalLog(label: "journal").note(bytes.count)
                        CommitMetrics(name: "commit").record(WallClock.now() - started)
                    }
                }
                """,
        ]
        for name in ["PageHeader", "PageIndex", "PageFooter", "PageFlags"] {
            files["Store/Format/\(name).swift"] = "struct \(name) {\n    let value: Int\n    init(version: Int = 0, count: Int = 0, length: Int = 0) { value = version + count + length }\n    func encode() -> [UInt8] { [UInt8(value & 0xFF)] }\n}\n"
        }
        for name in ["Varint", "Zigzag", "Crc", "Base64Text", "HexText", "Utf8Text"] {
            files["Store/Codec/\(name).swift"] = "struct \(name) {\n    let value: Int\n    init(value: Int = 0, seed: Int = 0) { self.value = value + seed }\n    func encode() -> [UInt8] { [UInt8(value & 0xFF)] }\n}\n"
        }
        files["App/Shared Services/WallClock.swift"] = "enum WallClock {\n    static func now() -> Int { 0 }\n}\n"
        files["App/Shared Services/JournalLog.swift"] = "struct JournalLog {\n    let label: String\n    func note(_ count: Int) {}\n}\n"
        files["App/Shared Services/CommitMetrics.swift"] = "struct CommitMetrics {\n    let name: String\n    func record(_ value: Int) {}\n}\n"
        for name in ["WeatherService", "MapService", "PhotoService", "ContactService", "CalendarService", "MailService", "ShareService"] {
            files["App/Shared Services/\(name).swift"] = "final class \(name) {\n    func refresh() {}\n}\n"
        }
        return files
    }()

    static let formatLines = [
        "format  App/Shared Services/  CommitMetrics.swift · JournalLog.swift · WallClock.swift · +7 more in App/Shared Services/",
        "        Store/Codec/  Crc.swift · Varint.swift · Zigzag.swift · +3 more in Store/Codec/",
        "        Store/Format/  PageFlags.swift · PageFooter.swift · PageHeader.swift · PageIndex.swift",
    ]

    @Test("A folder that is mostly format files is listed whole; at half or less, only its format files and a count")
    func rollup() async throws {
        let (engine, _) = try await RepoFixture.indexed(Self.journal, name: "format-rollup")
        let flow = try engine.flow(of: "Journal.commit")
        #expect(flow.steps.contains { $0.isSink }, "\(flow.steps)")
        #expect(flow.format.map(\.folder) == ["App/Shared Services", "Store/Codec", "Store/Format"])
        // 3 of 10 files: the three, and the other seven as a count.
        #expect(flow.format.first { $0.folder == "App/Shared Services" }.map { group in group.files.map(\.path) } ==
                ["App/Shared Services/CommitMetrics.swift", "App/Shared Services/JournalLog.swift", "App/Shared Services/WallClock.swift"])
        #expect(flow.format.first { $0.folder == "App/Shared Services" }?.more == 7)
        // Exactly half is not most.
        #expect(flow.format.first { $0.folder == "Store/Codec" }?.files.count == 3)
        #expect(flow.format.first { $0.folder == "Store/Codec" }?.more == 3)
        // 3 of 4: the format's own folder, PageFlags.swift included.
        #expect(flow.format.first { $0.folder == "Store/Format" }?.files.count == 4)
        #expect(flow.format.first { $0.folder == "Store/Format" }?.more == 0)

        let text = FeatureMapRenderer.render(flow: flow, budget: .unlimited).components(separatedBy: "\n")
        #expect(Array(text.suffix(3)) == Self.formatLines, "\(text)")
    }

    @Test("The count stays when a tight budget drops the files' types")
    func rendererCut() {
        let services = FlowFormatGroup(folder: "Atlas/Services", files: [
            FlowFormatFile(path: "Atlas/Services/BookDebugDump.swift", types: ["BookDebugDump"]),
            FlowFormatFile(path: "Atlas/Services/EpubImportService.swift", types: ["EpubImportService", "ImportedEpubDraft"]),
        ], more: 79)
        let wal = FlowFormatGroup(folder: "Sources/WaxCore/WAL", files: [
            FlowFormatFile(path: "Sources/WaxCore/WAL/Metadata.swift", types: ["Metadata"]),
            FlowFormatFile(path: "Sources/WaxCore/WAL/WALRecord.swift", types: ["WALFlags", "WALRecordHeader"]),
        ])
        var flow = FlowView(entry: FeatureRef(name: "LibraryService.importBook()", path: "Atlas/Services/LibraryService.swift", lines: LineRange(10, 40)),
                            body: FeatureRef(name: "LibraryService.importBook()", path: "Atlas/Services/LibraryService.swift", lines: LineRange(10, 40)),
                            sinks: ["modelContext.delete"], steps: [FlowStep(line: 12, code: "modelContext.delete(book)", isSink: true)], format: [services, wal])
        let full = FeatureMapRenderer.render(flow: flow, budget: .unlimited).components(separatedBy: "\n")
        #expect(Array(full.suffix(2)) == [
            "format  Atlas/Services/  BookDebugDump.swift · EpubImportService.swift (ImportedEpubDraft) · +79 more in Atlas/Services/",
            "        Sources/WaxCore/WAL/  Metadata.swift · WALRecord.swift (WALFlags, WALRecordHeader)",
        ])
        let cut = FeatureMapRenderer.flowLines(flow, cut: 2)
        #expect(cut.contains("format  Atlas/Services/  BookDebugDump.swift · EpubImportService.swift · +79 more in Atlas/Services/"))
        flow.format = [FlowFormatGroup(folder: "Atlas/Services", files: services.files)]
        #expect(!FeatureMapRenderer.render(flow: flow, budget: .unlimited).contains("more in"), "nothing left out, no count")
    }

    @Test("outline prints the roll-up through the tool and the built executable")
    func outline() async throws {
        let (engine, root) = try await RepoFixture.indexed(Self.journal, name: "format-rollup-outline")
        // Unbudgeted, as `--full`: a fifth of this small file has no room for the flow's format lines.
        let context = ToolContext(engine: engine, unbudgeted: true) {
            let summary = try await engine.index(options: RepoFixture.fastOptions)
            return summary.filesAdded + summary.filesChanged + summary.filesRemoved
        }
        let tool = await MCPToolCatalog.execute(OutlineTool(), arguments: ["target": .string("Journal.commit")], context: context)
        #expect(!tool.isError, "\(tool.text)")
        let lines = tool.text.components(separatedBy: "\n")
        for line in Self.formatLines { #expect(lines.contains(line), "\(tool.text)") }

        let cli = try CLI.run(["outline", "Journal.commit", "--full", "--repo", root.path, "--no-refresh"])
        #expect(cli.status == 0, "\(cli.stderr)")
        #expect(cli.stdout.trimmingCharacters(in: .newlines) == tool.text, "the CLI prints the tool's text")
    }
}
