import SwiftUI
import VesaliusCore

struct DiagnosticsView: View {
    let workspace: Workspace
    @State private var search = ""
    @State private var category: HealthCategory?
    @State private var minimum: Severity = .low
    @State private var selection: Diagnostic.ID?

    private var filtered: [Diagnostic] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return workspace.diagnostics.filter { diagnostic in
            diagnostic.severity >= minimum
                && (category == nil || diagnostic.category == category)
                && (query.isEmpty || diagnostic.title.lowercased().contains(query) || diagnostic.summary.lowercased().contains(query) || diagnostic.targets.contains { $0.path.lowercased().contains(query) })
        }
    }

    var body: some View {
        // The list is created once the first results exist: populating a new list is a plain reload,
        // while diffing hundreds of rows into an empty one re-enters AppKit's row-height cache. It also
        // keeps "All Clear" from flashing before anything has loaded.
        if workspace.generation == 0 {
            ProgressView("Loading diagnostics…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        let items = filtered
        let groups = Severity.allCases.reversed().compactMap { severity -> (Severity, [Diagnostic])? in
            let list = items.filter { $0.severity == severity }
            return list.isEmpty ? nil : (severity, list)
        }
        VStack(spacing: 0) {
        filterBar(count: items.count)
        Divider()
        List(selection: $selection) {
            ForEach(groups, id: \.0) { severity, list in
                Section {
                    ForEach(list) { diagnostic in
                        DiagnosticRow(diagnostic: diagnostic)
                            .tag(diagnostic.id)
                            .contextMenu {
                                if let target = diagnostic.targets.first {
                                    Button("Open \((target.path as NSString).lastPathComponent)") { workspace.open(path: target.path, line: target.line) }
                                    Button("Show in System Map") { workspace.revealInMap(target.path) }
                                }
                            }
                    }
                } header: {
                    SeverityPill(severity: severity, count: list.count)
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: selection) { _, id in
            if let id, let diagnostic = workspace.diagnostics.first(where: { $0.id == id }) {
                workspace.inspect(.diagnostic(diagnostic))
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter diagnostics")
        .overlay {
            if items.isEmpty {
                if workspace.diagnostics.isEmpty {
                    ContentUnavailableView("All Clear 🎉", systemImage: "checkmark.seal", description: Text("Nothing in this repository crossed a health threshold."))
                } else {
                    ContentUnavailableView("No Matching Diagnostics", systemImage: "line.3.horizontal.decrease.circle", description: Text("Adjust the filters to see more."))
                }
            }
        }
        .accessibilityIdentifier("diagnostics-list")
        }
    }

    /// Filters sit directly above the list they filter.
    private func filterBar(count: Int) -> some View {
        HStack(spacing: Theme.Space.m) {
            Picker("Category", selection: $category) {
                Text("All categories").tag(HealthCategory?.none)
                Divider()
                ForEach(HealthCategory.allCases) { Text("\($0.emoji)  \($0.displayName)").tag(HealthCategory?.some($0)) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("diagnostics-category")
            Picker("Severity", selection: $minimum) {
                ForEach(Severity.allCases, id: \.self) { Text($0 == .info ? "All severities" : "\($0.displayName) and above").tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("diagnostics-severity")
            Spacer()
            Text("\(count.grouped) of \(workspace.diagnostics.count.grouped)")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Colors.text3)
                .monospacedDigit()
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }
}

private struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.s) {
                Text(diagnostic.title).font(Theme.Font.rowTitle).lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                CategoryLabel(category: diagnostic.category, color: Theme.Colors.text3)
            }
            Text(diagnostic.summary).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).lineLimit(2)
            if let target = diagnostic.targets.first {
                HStack(spacing: Theme.Space.xs) {
                    PathText(path: target.path, font: Theme.Font.monoSmall)
                    if diagnostic.targets.count > 1 {
                        Text("+\(diagnostic.targets.count - 1)").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}
