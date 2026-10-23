import QueryEngine
import SwiftUI
import VesaliusCore

struct SymbolsView: View {
    let workspace: Workspace
    @State private var search = ""
    @State private var kindFilter: KindFilter = .types
    @State private var sortOrder = [KeyPathComparator(\SymbolRow.references, order: .reverse)]
    @State private var selection: SymbolRow.ID?
    @State private var searchResults: [SymbolSummary]?

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", types = "Types", functions = "Functions", properties = "Properties"
        var id: String { rawValue }

        func matches(_ kind: SymbolKind) -> Bool {
            switch self {
            case .all: true
            case .types: kind.isType || kind == .namespace
            case .functions: kind.isCallable
            case .properties: kind == .property || kind == .variable || kind == .constant || kind == .enumCase
            }
        }
    }

    struct SymbolRow: Identifiable {
        let symbol: SymbolSummary
        var id: String { symbol.id }
        var name: String { symbol.qualifiedName }
        var kind: String { symbol.kind.displayName }
        var path: String { symbol.path }
        var references: Int { symbol.references ?? 0 }
        var lines: Int { symbol.lines.count }
    }

    private var rows: [SymbolRow] {
        let source = searchResults ?? workspace.symbols
        return source.filter { kindFilter.matches($0.kind) }.map(SymbolRow.init).sorted(using: sortOrder)
    }

    var body: some View {
        // The table is created once symbols exist (see DiagnosticsView): a new table loads its rows in
        // one pass instead of diffing thousands of rows into an empty one.
        Group {
            if workspace.symbolsLoaded || searchResults != nil {
                table
            } else {
                ProgressView("Loading symbols…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Find symbols (name, Type.member, abbreviation)")
        .task(id: search) { await runSearch() }
        .task { await workspace.loadSymbolsIfNeeded() }
        .toolbar {
            ToolbarItem {
                Picker("Kind", selection: $kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
        }
    }

    @ViewBuilder private var table: some View {
        let rows = self.rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Symbol", value: \.name) { row in
                HStack(spacing: Theme.Space.s) {
                    SymbolBadge(kind: row.symbol.kind, size: 15)
                    Text(row.symbol.qualifiedName).font(Theme.Font.small).lineLimit(1)
                }
            }
            .width(min: 220, ideal: 320)
            TableColumn("Kind", value: \.kind) { row in
                Text(row.kind).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2)
            }
            .width(min: 70, ideal: 90)
            TableColumn("File", value: \.path) { row in
                PathText(path: row.path, font: Theme.Font.small)
            }
            .width(min: 200, ideal: 340)
            TableColumn("Lines", value: \.lines) { row in
                Text(row.symbol.lines.description).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text2)
            }
            .width(min: 60, ideal: 80)
            TableColumn("References", value: \.references) { row in
                Text(row.references == 0 ? "" : row.references.grouped).font(Theme.Font.small).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onChange(of: selection) { _, id in
            if let id { workspace.inspect(.symbol(id)) }
        }
        .contextMenu(forSelectionType: SymbolRow.ID.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                Button("Open in Editor") { workspace.open(path: row.path, line: row.symbol.lines.start) }
                Button("Show References") { workspace.inspect(.symbol(id)) }
                Button("Show Change Impact") { workspace.inspect(.impact(id)) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                workspace.open(path: row.path, line: row.symbol.lines.start)
            }
        }
        .overlay {
            if rows.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView("No Symbols", systemImage: "curlybraces", description: Text("No declarations of this kind were found."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .accessibilityIdentifier("symbols-table")
    }

    private func runSearch() async {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let engine = workspace.engine
        let hits = (try? await offMain { try engine.searchSymbols(query, limit: 300) }) ?? []
        if !Task.isCancelled { searchResults = hits.map(\.symbol) }
    }
}
