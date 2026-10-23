import SwiftUI
import VesaliusCore

struct OverviewView: View {
    let workspace: Workspace

    var body: some View {
        if let overview = workspace.overview {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    header(overview)
                    hero(overview)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.l, alignment: .top), GridItem(.flexible(), spacing: Theme.Space.l, alignment: .top)], alignment: .leading, spacing: Theme.Space.l) {
                        hotspots(overview)
                        central(overview)
                        cycles(overview)
                        largeFiles(overview)
                        suggestions(overview)
                        unused(overview)
                    }
                    diagnostics(overview)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 1280, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("overview")
        }
    }

    // MARK: Header

    private func header(_ overview: RepositoryOverview) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(overview.repository.name).font(Theme.Font.title)
            HStack(spacing: Theme.Space.m) {
                Label((overview.repository.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                if let branch = overview.repository.branch {
                    Label("\(branch)\(overview.repository.headCommit.map { " @ \($0)" } ?? "")", systemImage: "arrow.triangle.branch")
                }
                if let date = overview.lastIndexed {
                    Label {
                        Text("Indexed ") + Text(date, format: .relative(presentation: .named))
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
            }
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Colors.text2)
            LanguageBar(languages: overview.languages)
                .padding(.top, Theme.Space.xs)
        }
    }

    // MARK: Hero

    private func hero(_ overview: RepositoryOverview) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            statStrip(overview)
            // Both panels flex; their text wraps, so they share the row at any width.
            HStack(alignment: .top, spacing: Theme.Space.l) {
                healthPanel(overview).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                architecturePanel(overview).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            if let first = overview.topDiagnostics.first {
                startHere(first)
            }
        }
    }

    /// Six headline numbers in one row: a single group, no cards. Each carries the colour tile of the
    /// section that explains it, and clicking it goes there.
    private func statStrip(_ overview: RepositoryOverview) -> some View {
        let stats = overview.stats
        let items: [(String, String, String, SidebarSection)] = [
            ("Source files", stats.sourceFiles.grouped, "\(stats.testFiles.grouped) tests", .files),
            ("Code lines", stats.codeLines.compact, "\(stats.lines.compact) total", .files),
            ("Symbols", stats.symbols.compact, "\(stats.types.grouped) types", .symbols),
            ("Modules", stats.modules.grouped, "\(stats.externalModules) external", .architecture),
            ("Dependencies", stats.dependencies.compact, "between files", .map),
            ("Cycles", overview.cycles.count.grouped, overview.cycles.isEmpty ? "none found" : "\(overview.cycles.reduce(0) { $0 + $1.files.count }) files", .diagnostics),
        ]
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle().fill(Theme.Colors.hairline).frame(width: 0.5).padding(.horizontal, Theme.Space.l)
                }
                Button { workspace.section = item.3 } label: {
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        IconTile(systemImage: item.3.systemImage, color: item.3.tint, size: 16)
                            .padding(.top, 1)
                        MetricView(label: item.0, value: item.1, detail: item.2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(item.3.title)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Theme.Space.s)
        .accessibilityIdentifier("overview-stats")
    }

    /// The single most significant finding, with one action: answers "where do I start?". The one
    /// emphasised element on the page: tinted by its severity, marked with its category.
    private func startHere(_ diagnostic: Diagnostic) -> some View {
        let tint = Theme.Colors.severity(diagnostic.severity)
        return HStack(spacing: Theme.Space.m) {
            Text(diagnostic.category.emoji)
                .font(.system(size: 20))
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text("Start here").font(Theme.Font.label).foregroundStyle(Theme.Colors.text3).textCase(.uppercase)
                    SeverityPill(severity: diagnostic.severity)
                }
                Text(diagnostic.title).font(Theme.Font.rowTitle)
                Text(diagnostic.recommendation).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).lineLimit(2)
            }
            Spacer(minLength: Theme.Space.m)
            Button("Inspect") { workspace.inspect(.diagnostic(diagnostic)) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityIdentifier("start-here")
        }
        .padding(Theme.Space.m)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
    }

    private func healthPanel(_ overview: RepositoryOverview) -> some View {
        Panel {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                ScoreGauge(score: overview.health.score)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Repository Health").font(Theme.Font.label).foregroundStyle(Theme.Colors.text3).textCase(.uppercase)
                    Text(overview.health.grade).font(Theme.Font.title)
                    Text(overview.health.summary).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).fixedSize(horizontal: false, vertical: true).lineLimit(4)
                    Button("View breakdown") { workspace.section = .health }
                        .buttonStyle(.link)
                        .font(Theme.Font.small)
                        .padding(.top, Theme.Space.xs)
                }
            }
        }
        .accessibilityIdentifier("overview-health")
    }

    private func architecturePanel(_ overview: RepositoryOverview) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Architecture").font(Theme.Font.label).foregroundStyle(Theme.Colors.text3).textCase(.uppercase)
                if let pattern = overview.architecture.patterns.first {
                    Text(pattern.label).font(Theme.Font.section)
                    ForEach(pattern.evidence.prefix(3), id: \.self) { evidence in
                        Label(evidence, systemImage: "checkmark")
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.Colors.text2)
                            .labelStyle(EvidenceLabelStyle())
                    }
                } else {
                    Text(overview.architecture.summary).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2)
                }
                if !overview.architecture.frameworks.isEmpty {
                    FlowTags(tags: Array(overview.architecture.frameworks.prefix(6)))
                }
                Button("Explore architecture") { workspace.section = .architecture }
                    .buttonStyle(.link)
                    .font(Theme.Font.small)
            }
        }
    }

    // MARK: Sections

    private func hotspots(_ overview: RepositoryOverview) -> some View {
        OverviewSection(title: "Hotspots", subtitle: "large, complex, coupled, often changed", isEmpty: overview.hotspots.isEmpty, emptyText: "No hotspots stand out.") {
            ForEach(overview.hotspots.prefix(6)) { hotspot in
                InspectableRow { workspace.inspect(.file(hotspot.path)) } content: {
                    FileIcon(path: hotspot.path)
                    PathText(path: hotspot.path, font: Theme.Font.small)
                    Spacer(minLength: Theme.Space.s)
                    Text(hotspot.reasons.first ?? "").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).lineLimit(1)
                }
            }
        }
    }

    private func central(_ overview: RepositoryOverview) -> some View {
        OverviewSection(title: "Critical files", subtitle: "most depended upon", isEmpty: overview.centralFiles.isEmpty, emptyText: "No file is a hub yet.") {
            ForEach(overview.centralFiles.prefix(6)) { file in
                InspectableRow { workspace.inspect(.file(file.path)) } content: {
                    FileIcon(path: file.path)
                    PathText(path: file.path, font: Theme.Font.small)
                    Spacer(minLength: Theme.Space.s)
                    Text(file.detail).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).lineLimit(1)
                }
            }
        }
    }

    private func cycles(_ overview: RepositoryOverview) -> some View {
        OverviewSection(title: "Circular dependencies", subtitle: overview.cycles.isEmpty ? nil : "\(overview.cycles.count) found", isEmpty: overview.cycles.isEmpty, emptyText: "No dependency cycles. Files depend on each other in one direction.") {
            ForEach(overview.cycles.prefix(4)) { cycle in
                InspectableRow { workspace.inspect(.file(cycle.files.first ?? "")) } content: {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.Colors.warning)
                    Text(cycle.path.map { ($0 as NSString).lastPathComponent }.joined(separator: " → "))
                        .font(Theme.Font.small)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func largeFiles(_ overview: RepositoryOverview) -> some View {
        OverviewSection(title: "Largest files", subtitle: "by code lines", isEmpty: overview.largeFiles.isEmpty, emptyText: "No source files.") {
            ForEach(overview.largeFiles.prefix(6)) { file in
                InspectableRow { workspace.inspect(.file(file.path)) } content: {
                    FileIcon(path: file.path)
                    PathText(path: file.path, font: Theme.Font.small)
                    Spacer(minLength: Theme.Space.s)
                    Text(Int(file.value).grouped).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).monospacedDigit()
                }
            }
        }
    }

    private func suggestions(_ overview: RepositoryOverview) -> some View {
        OverviewSection(title: "Suggested extractions", subtitle: "cohesive groups that could become packages", isEmpty: overview.suggestions.isEmpty, emptyText: "No group is cohesive and loosely coupled enough to extract yet.") {
            ForEach(overview.suggestions.prefix(4)) { suggestion in
                InspectableRow {
                    workspace.section = .architecture
                } content: {
                    Image(systemName: "shippingbox.fill").foregroundStyle(SidebarSection.architecture.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(suggestion.name).font(Theme.Font.rowTitle)
                        Text("\(suggestion.files.count) files · cohesion \(Int((suggestion.cohesion * 100).rounded()))% · \(suggestion.externalDependencies) outside dependencies")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Colors.text3)
                    }
                }
            }
        }
    }

    private func unused(_ overview: RepositoryOverview) -> some View {
        OverviewSection(title: "Possibly unused", subtitle: "no references detected", isEmpty: overview.unused.isEmpty, emptyText: "Everything appears to be referenced.") {
            ForEach(overview.unused.prefix(6)) { item in
                InspectableRow {
                    workspace.inspect(.file(item.path))
                } content: {
                    if let kind = item.symbolKind, item.kind != .file {
                        SymbolBadge(kind: kind, size: 15)
                    } else {
                        FileIcon(path: item.path)
                    }
                    if let symbol = item.symbol {
                        Text(symbol).font(Theme.Font.small).lineLimit(1)
                        Text((item.path as NSString).lastPathComponent).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).lineLimit(1)
                    } else {
                        PathText(path: item.path, font: Theme.Font.small)
                    }
                }
            }
        }
    }

    private func diagnostics(_ overview: RepositoryOverview) -> some View {
        OverviewSection(title: "Needs attention", subtitle: "most significant diagnostics", isEmpty: overview.topDiagnostics.isEmpty, emptyText: "No medium or higher diagnostics.") {
            ForEach(overview.topDiagnostics) { diagnostic in
                InspectableRow { workspace.inspect(.diagnostic(diagnostic)) } content: {
                    SeverityBadge(severity: diagnostic.severity, showsLabel: false)
                    Text(diagnostic.title).font(Theme.Font.small).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    CategoryLabel(category: diagnostic.category, color: Theme.Colors.text3)
                }
            }
            Button("All diagnostics") { workspace.section = .diagnostics }
                .buttonStyle(.link)
                .font(Theme.Font.small)
                .padding(.top, Theme.Space.xs)
        }
    }
}

/// A titled panel of rows on the overview.
struct OverviewSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var isEmpty: Bool
    var emptyText: String
    @ViewBuilder var content: Content

    var body: some View {
        Panel(padding: Theme.Space.m) {
            SectionHeader(title, subtitle: subtitle)
                .padding(.horizontal, Theme.Space.s)
                .padding(.bottom, Theme.Space.s)
            if isEmpty {
                Text(emptyText)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Colors.text3)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.bottom, Theme.Space.xs)
            } else {
                content
            }
        }
    }
}

/// Language composition in each language's own colour (the same colours as the System Map).
struct LanguageBar: View {
    let languages: [LanguageStat]

    var body: some View {
        let shown = Array(languages.filter { $0.share >= 0.01 }.prefix(5))
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(shown) { language in
                        Rectangle()
                            .fill(language.language.tint)
                            .frame(width: max(2, proxy.size.width * language.share))
                    }
                    Rectangle().fill(Theme.Colors.fill)
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            HStack(spacing: Theme.Space.m) {
                ForEach(shown) { language in
                    HStack(spacing: Theme.Space.xs) {
                        Circle().fill(language.language.tint).frame(width: 7, height: 7)
                        Text(language.language.displayName).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text2)
                        Text("\(Int((language.share * 100).rounded()))%").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).monospacedDigit()
                    }
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct EvidenceLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            configuration.icon.foregroundStyle(Theme.Colors.text3).imageScale(.small)
            configuration.title
        }
    }
}

/// Wrapping tag list.
struct FlowTags: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: Theme.Space.xs) {
            ForEach(tags, id: \.self) { Tag(text: $0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
