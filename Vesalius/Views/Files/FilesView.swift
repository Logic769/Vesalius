import SwiftUI
import VesaliusCore

struct FilesView: View {
    let workspace: Workspace
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\FileSummary.centrality, order: .reverse)]
    @State private var selection: FileSummary.ID?
    @State private var language: Language?
    @State private var showTests = true
    @State private var showGenerated = false

    private var rows: [FileSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return workspace.files
            .filter { file in
                (query.isEmpty || file.path.lowercased().contains(query))
                    && (language == nil || file.language == language)
                    && (showTests || !file.isTest)
                    && (showGenerated || !file.isGenerated)
            }
            .sorted(using: sortOrder)
    }

    private var languages: [Language] {
        Array(Set(workspace.files.map(\.language))).sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        if workspace.generation == 0 {
            ProgressView("Loading files…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            table
        }
    }

    @ViewBuilder private var table: some View {
        let rows = self.rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("File", value: \.path) { file in
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: file.isTest ? "checkmark.seal.fill" : file.language.systemImage)
                        .foregroundStyle(file.isTest ? Theme.Hue.green : file.language.tint)
                        .frame(width: 14)
                    PathText(path: file.path, font: Theme.Font.small)
                }
            }
            .width(min: 260, ideal: 420)
            TableColumn("Language", value: \.language.displayName) { file in
                HStack(spacing: Theme.Space.xs) {
                    Circle().fill(file.language.tint).frame(width: 7, height: 7)
                    Text(file.language.displayName).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2)
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Lines", value: \.codeLines) { file in
                Text(file.codeLines.grouped).font(Theme.Font.small).monospacedDigit()
            }
            .width(min: 50, ideal: 64)
            TableColumn("Symbols", value: \.symbols) { file in
                Text(file.symbols.grouped).font(Theme.Font.small).monospacedDigit()
            }
            .width(min: 50, ideal: 64)
            TableColumn("Complexity", value: \.complexity) { file in
                Text(file.complexity.grouped).font(Theme.Font.small).monospacedDigit()
            }
            .width(min: 60, ideal: 76)
            TableColumn("Used by", value: \.fanIn) { file in
                Text(file.fanIn.grouped).font(Theme.Font.small).monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Uses", value: \.fanOut) { file in
                Text(file.fanOut.grouped).font(Theme.Font.small).monospacedDigit()
            }
            .width(min: 44, ideal: 54)
            TableColumn("Centrality", value: \.centrality) { file in
                ProportionBar(value: file.centrality, color: Theme.Colors.text3, height: 4)
                    .frame(width: 56)
                    .help(String(format: "%.3f", file.centrality))
            }
            .width(min: 70, ideal: 80)
            TableColumn("Risk", value: \.risk) { file in
                let level = RiskLevel.from(score: file.risk * 100)
                HStack(spacing: Theme.Space.xs) {
                    Circle().fill(Theme.Colors.risk(level)).frame(width: 6, height: 6)
                    Text(level.rawValue.capitalized).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2)
                }
            }
            .width(min: 70, ideal: 84)
            TableColumn("Issues", value: \.diagnostics) { file in
                Text(file.diagnostics == 0 ? "" : file.diagnostics.grouped).font(Theme.Font.small).monospacedDigit()
            }
            .width(min: 40, ideal: 50)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: FileSummary.ID.self) { ids in
            if let path = ids.first {
                Button("Open in Editor") { workspace.open(path: path) }
                Button("Reveal in Finder") { workspace.reveal(path: path) }
                Button("Show in System Map") { workspace.revealInMap(path) }
                Button("Show Change Impact") { workspace.inspect(.impact(path)) }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let path = ids.first { workspace.open(path: path) }
        }
        .onChange(of: selection) { _, path in
            if let path { workspace.inspect(.file(path)) }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter files")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Language", selection: $language) {
                        Text("All Languages").tag(Language?.none)
                        Divider()
                        ForEach(languages, id: \.self) { Text($0.displayName).tag(Language?.some($0)) }
                    }
                    Divider()
                    Toggle("Show Tests", isOn: $showTests)
                    Toggle("Show Generated", isOn: $showGenerated)
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                if workspace.files.isEmpty {
                    ContentUnavailableView("No Files Indexed", systemImage: "doc", description: Text("This folder has no source files Vesalius can read."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(rows.count.grouped) of \(workspace.files.count.grouped) files").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.xs)
            .background(.bar)
        }
        .accessibilityIdentifier("files-table")
    }
}
