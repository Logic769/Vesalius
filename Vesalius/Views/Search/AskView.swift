import SwiftUI
import VesaliusCore

/// Natural-language questions answered from the index.
struct AskView: View {
    @Bindable var workspace: Workspace
    @FocusState private var focused: Bool

    private let examples = [
        "Where is authentication handled?",
        "What depends on the database layer?",
        "Where are network requests made?",
        "What files are involved in onboarding?",
        "Where is the main entry point?",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(Theme.Colors.text3)
                TextField("Ask about this codebase, e.g. where is authentication handled?", text: $workspace.askQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { workspace.ask() }
                    .accessibilityIdentifier("ask-field")
                if workspace.isAsking {
                    ProgressView().controlSize(.small)
                }
                Button("Ask") { workspace.ask() }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.askQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(Theme.Space.m)
            .background(Theme.Colors.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
            .padding(Theme.Space.xl)

            Divider()

            if let result = workspace.askResult {
                results(result)
            } else {
                emptyState
            }
        }
        .onAppear { focused = true }
        .accessibilityIdentifier("ask")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Ask in plain language").font(Theme.Font.section)
            Text("Vesalius combines symbol names, file paths, full-text search, the dependency graph and on-device semantic similarity. Structural questions like “what depends on User” or “who calls refreshToken” are answered from the graph.")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Colors.text2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(examples, id: \.self) { example in
                    Button(example) { workspace.ask(example) }
                        .buttonStyle(.link)
                        .font(Theme.Font.small)
                }
            }
            Spacer()
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func results(_ result: AskResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(result.answer).font(Theme.Font.body).foregroundStyle(Theme.Colors.text1).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if result.intent != "search" {
                        Text("Answered from the dependency graph").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                    } else if !result.terms.isEmpty {
                        Text("Matched terms: " + result.terms.prefix(8).joined(separator: ", ")).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                    }
                }
                if result.files.isEmpty {
                    ContentUnavailableView("No Matching Code", systemImage: "magnifyingglass", description: Text("Try a type or feature name used in the code."))
                }
                ForEach(Array(result.files.enumerated()), id: \.element.id) { index, file in
                    AskResultRow(rank: index + 1, file: file, workspace: workspace)
                }
                if let related = result.related, !related.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Structurally related").font(Theme.Font.rowTitle)
                        ForEach(related) { file in
                            InspectableRow { workspace.inspect(.file(file.path)) } content: {
                                FileIcon(path: file.path)
                                PathText(path: file.path, font: Theme.Font.small)
                                Spacer()
                                Text(file.reason).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AskResultRow: View {
    let rank: Int
    let file: AskFile
    let workspace: Workspace

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Text("\(rank)")
                .font(Theme.Font.small)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.text3)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    Button { workspace.inspect(.file(file.path)) } label: {
                        HStack(spacing: Theme.Space.xs) {
                            FileIcon(path: file.path)
                            PathText(path: file.path, font: Theme.Font.rowTitle)
                        }
                    }
                    .buttonStyle(.plain)
                    if let lines = file.lines {
                        Text(":\(lines.description)").font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3)
                    }
                    Spacer()
                    ProportionBar(value: file.relevance, color: Theme.Colors.accent, height: 4).frame(width: 64)
                    Text(String(format: "%.2f", file.relevance)).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3)
                }
                Text(file.reason).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).fixedSize(horizontal: false, vertical: true)
                if !file.symbols.isEmpty {
                    // Chips wrap as whole units: a symbol name is never broken across lines.
                    FlowLayout(spacing: Theme.Space.m) {
                        ForEach(file.symbols, id: \.self) { symbol in
                            Button {
                                workspace.open(path: file.path, line: symbol.lines.start)
                            } label: {
                                HStack(spacing: 3) {
                                    SymbolBadge(kind: symbol.kind, size: 13)
                                    Text(symbol.name)
                                    Text(symbol.lines.description).foregroundStyle(Theme.Colors.text3)
                                }
                                .font(Theme.Font.caption)
                                .lineLimit(1)
                                .fixedSize()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Colors.text2)
                            .help("Open at line \(symbol.lines.start)")
                        }
                    }
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .contextMenu {
            Button("Open in Editor") { workspace.open(path: file.path, line: file.lines?.start) }
            Button("Show in System Map") { workspace.revealInMap(file.path) }
            Button("Show Change Impact") { workspace.inspect(.impact(file.path)) }
        }
        .accessibilityIdentifier("ask-result-\(rank)")
    }
}
