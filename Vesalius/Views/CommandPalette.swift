import QueryEngine
import SwiftUI
import VesaliusCore

/// Raycast-style palette: fuzzy files, symbols, diagnostics, sections, and natural-language questions.
struct CommandPalette: View {
    let workspace: Workspace
    var initialQuery = ""
    let dismiss: () -> Void

    @State private var query = ""
    @State private var results: UnifiedSearchResults?
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        /// Icons follow the app's colour coding: section tiles, language colours, kind badges, and the
        /// category emoji for diagnostics.
        enum Icon {
            case tile(String, Color)
            case glyph(String, Color)
            case kind(SymbolKind)
            case emoji(String)
        }

        let id: String
        let icon: Icon
        let title: String
        let subtitle: String?
        let group: String
        let action: () -> Void
    }

    private var items: [Item] {
        var items: [Item] = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // A sentence is a question: offer Ask first. A single identifier is a lookup: offer it last.
        let isQuestion = trimmed.split(separator: " ").count >= 3 || trimmed.hasSuffix("?")
        let askItem = trimmed.isEmpty ? nil : Item(id: "ask", icon: .tile(SidebarSection.search.systemImage, SidebarSection.search.tint), title: "Ask “\(trimmed)”", subtitle: "Natural-language search across the index", group: "Ask") {
            workspace.ask(trimmed)
        }
        if isQuestion, let askItem { items.append(askItem) }
        for section in SidebarSection.allCases where trimmed.isEmpty || section.title.localizedCaseInsensitiveContains(trimmed) {
            items.append(Item(id: "section-\(section.rawValue)", icon: .tile(section.systemImage, section.tint), title: "Go to \(section.title)", subtitle: nil, group: "Navigate") {
                workspace.section = section
            })
        }
        if let results {
            for file in results.files.prefix(8) {
                items.append(Item(id: "file-\(file.path)", icon: .glyph(file.language.systemImage, file.language.tint), title: (file.path as NSString).lastPathComponent, subtitle: file.path, group: "Files") {
                    workspace.inspect(.file(file.path))
                })
            }
            for hit in results.symbols.prefix(10) {
                let symbol = hit.symbol
                items.append(Item(id: "symbol-\(symbol.id)", icon: .kind(symbol.kind), title: symbol.qualifiedName, subtitle: "\(symbol.kind.displayName) · \(symbol.path):\(symbol.lines.start)", group: "Symbols") {
                    workspace.inspect(.symbol(symbol.id))
                })
            }
            for diagnostic in results.diagnostics.prefix(5) {
                items.append(Item(id: "diag-\(diagnostic.id)", icon: .emoji(diagnostic.category.emoji), title: diagnostic.title, subtitle: diagnostic.category.displayName, group: "Diagnostics") {
                    workspace.inspect(.diagnostic(diagnostic))
                })
            }
            for concept in results.concepts.prefix(3) {
                items.append(Item(id: "concept-\(concept.name)", icon: .tile(SidebarSection.architecture.systemImage, SidebarSection.architecture.tint), title: concept.label, subtitle: concept.evidence.first, group: "Architecture") {
                    workspace.section = .architecture
                })
            }
        }
        if !isQuestion, let askItem { items.append(askItem) }
        return items
    }

    var body: some View {
        let items = self.items
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.Colors.text3)
                    TextField("Search files, symbols, diagnostics, or ask a question", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { activate(items) }
                        .accessibilityIdentifier("palette-field")
                }
                .padding(Theme.Space.m)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || items[index - 1].group != item.group {
                                    Text(item.group.uppercased())
                                        .font(Theme.Font.label)
                                        .foregroundStyle(Theme.Colors.text3)
                                        .padding(.horizontal, Theme.Space.m)
                                        .padding(.top, Theme.Space.s)
                                        .padding(.bottom, 2)
                                }
                                row(item, selected: index == selectedIndex)
                                    .id(item.id)
                                    .onTapGesture {
                                        selectedIndex = index
                                        activate(items)
                                    }
                            }
                        }
                        .padding(.bottom, Theme.Space.s)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selectedIndex) { _, index in
                        if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                    }
                }
            }
            .frame(width: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 80)
            .accessibilityIdentifier("command-palette")
        }
        .onAppear {
            if query.isEmpty && !initialQuery.isEmpty { query = initialQuery }
            focused = true
        }
        .task(id: query) { await search() }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(0, items.count - 1))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            icon(item.icon)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Theme.Font.rowTitle).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 6)
        .background(selected ? Theme.Colors.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .padding(.horizontal, Theme.Space.xs)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func icon(_ icon: Item.Icon) -> some View {
        switch icon {
        case .tile(let systemImage, let color): IconTile(systemImage: systemImage, color: color, size: 18)
        case .glyph(let systemImage, let color): Image(systemName: systemImage).foregroundStyle(color)
        case .kind(let kind): SymbolBadge(kind: kind, size: 16)
        case .emoji(let emoji): Text(emoji).font(.system(size: 13))
        }
    }

    private func activate(_ items: [Item]) {
        guard items.indices.contains(selectedIndex) else { return }
        items[selectedIndex].action()
        dismiss()
    }

    private func search() async {
        selectedIndex = 0
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(90))
        guard !Task.isCancelled else { return }
        let engine = workspace.engine
        let found = try? await offMain { try engine.search(trimmed, limit: 8) }
        if !Task.isCancelled { results = found }
    }
}
