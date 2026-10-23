import QueryEngine
import SwiftUI
import VesaliusCore

struct InspectorView: View {
    let workspace: Workspace

    var body: some View {
        Group {
            switch workspace.inspector {
            case .file(let path):
                FileInspector(workspace: workspace, path: path).id(path)
            case .symbol(let id):
                SymbolInspector(workspace: workspace, query: id).id(id)
            case .node(let node):
                NodeInspector(workspace: workspace, node: node).id(node.id)
            case .diagnostic(let diagnostic):
                DiagnosticInspector(workspace: workspace, diagnostic: diagnostic).id(diagnostic.id)
            case .impact(let target):
                ImpactInspector(workspace: workspace, target: target).id(target)
            case nil:
                ContentUnavailableView {
                    Label("Nothing Selected", systemImage: "sidebar.trailing")
                } description: {
                    Text("Select a file, symbol, map node or diagnostic to inspect its anatomy.")
                }
            }
        }
        .accessibilityIdentifier("inspector")
    }
}

// MARK: - Shared inspector building blocks

struct InspectorSection<Content: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Text(title.uppercased()).font(Theme.Font.label).foregroundStyle(Theme.Colors.text3).tracking(0.4)
                if let count { Text("\(count)").font(Theme.Font.label).foregroundStyle(Theme.Colors.text3) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A list that shows a few rows and expands on demand.
struct ExpandableList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var limit = 8
    @ViewBuilder var row: (Item) -> Row
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(expanded ? items : Array(items.prefix(limit))) { row($0) }
            if items.count > limit {
                Button(expanded ? "Show fewer" : "Show all \(items.count)") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(Theme.Font.caption)
                    .padding(.top, Theme.Space.xs)
                    .padding(.leading, Theme.Space.s)
            }
        }
    }
}

struct OpenButtons: View {
    let workspace: Workspace
    let path: String
    var line: Int?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            let editors = Editor.installed
            if let primary = EditorLauncher.defaultEditor {
                Menu {
                    ForEach(editors) { editor in
                        Button {
                            EditorLauncher.open(workspace.root.appendingPathComponent(path), line: line, editor: editor)
                        } label: {
                            Text("Open in \(editor.name)")
                        }
                    }
                } label: {
                    Text("Open in \(primary.name)")
                } primaryAction: {
                    workspace.open(path: path, line: line)
                }
                .menuStyle(.button)
                .fixedSize()
                .accessibilityIdentifier("inspector-open")
            } else {
                Button("Open") { workspace.open(path: path, line: line) }
            }
            Button {
                workspace.reveal(path: path)
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal in Finder")
            Button {
                workspace.revealInMap(path)
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .help("Show in System Map")
        }
        .controlSize(.small)
    }
}

struct LoadingState: View {
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text("Loading…").font(Theme.Font.small).foregroundStyle(Theme.Colors.text3)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RiskSummary: View {
    let impact: ImpactSummary
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Circle().fill(Theme.Colors.risk(impact.riskLevel)).frame(width: 8, height: 8)
                Text("\(impact.riskLevel.rawValue.capitalized) change risk").font(Theme.Font.rowTitle)
                Text("\(Int(impact.riskScore.rounded()))/100").font(Theme.Font.small).foregroundStyle(Theme.Colors.text3).monospacedDigit()
            }
            Text("\(impact.directDependents) direct and \(impact.transitiveDependents) transitive dependents. \(impact.relatedTests == 0 ? "No related tests found." : "\(impact.relatedTests) related test file\(impact.relatedTests == 1 ? "" : "s").")")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Colors.text2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show blast radius", action: action)
                .buttonStyle(.link)
                .font(Theme.Font.small)
                .accessibilityIdentifier("show-blast-radius")
        }
    }
}

// MARK: - File

struct FileInspector: View {
    let workspace: Workspace
    let path: String
    @State private var context: FileContext?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                if let context {
                    content(context)
                } else if let error {
                    Text(error).font(Theme.Font.small).foregroundStyle(Theme.Colors.text3)
                } else {
                    LoadingState()
                }
            }
            .padding(Theme.Space.l)
        }
        .task(id: workspace.generation) {
            let engine = workspace.engine
            let path = self.path
            do {
                context = try await offMain { try engine.fileContext(path) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: context?.file.language.systemImage ?? "doc.text").foregroundStyle(context?.file.language.tint ?? Theme.Colors.text2)
                Text((path as NSString).lastPathComponent).font(Theme.Font.section).lineLimit(1).textSelection(.enabled)
            }
            Text(path).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3).lineLimit(2).textSelection(.enabled)
            OpenButtons(workspace: workspace, path: path)
        }
    }

    @ViewBuilder
    private func content(_ c: FileContext) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.m) {
            GridRow {
                MetricView(label: "Lines", value: c.file.codeLines.grouped, detail: "\(c.file.lines.grouped) total")
                MetricView(label: "Symbols", value: c.file.symbols.grouped)
                MetricView(label: "Complexity", value: c.file.complexity.grouped)
            }
            GridRow {
                MetricView(label: "Used by", value: c.metrics.fanIn.grouped, detail: "\(c.metrics.transitiveDependents) transitively")
                MetricView(label: "Uses", value: c.metrics.fanOut.grouped, detail: "\(c.metrics.transitiveDependencies) transitively")
                MetricView(label: "Centrality", value: String(format: "%.2f", c.metrics.centrality), detail: c.metrics.churn.map { "\($0) commits/yr" })
            }
        }

        Divider()
        RiskSummary(impact: c.impact) { workspace.inspect(.impact(path)) }

        if c.metrics.cycleID != nil {
            // Same rule as the Diagnostics list: only a loop closed by explicit imports is an import cycle.
            if !c.diagnostics.contains(where: \.isImportCycle) {
                Label("Part of an interconnected group of \(c.metrics.cycleSize ?? 0) \(c.file.language == .swift ? "Swift files" : "files")", systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Colors.text2)
                    .help("These files reference each other without importing each other (Swift files in one module, or headers sharing declarations). The loop only matters if the group should be split.")
            } else {
                Label("Part of an import cycle of \(c.metrics.cycleSize ?? 0) files", systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Colors.warning)
            }
        }

        if !c.diagnostics.isEmpty {
            InspectorSection(title: "Diagnostics", count: c.diagnostics.count) {
                ForEach(c.diagnostics) { diagnostic in
                    InspectableRow { workspace.inspect(.diagnostic(diagnostic)) } content: {
                        SeverityBadge(severity: diagnostic.severity, showsLabel: false)
                        Text(diagnostic.title).font(Theme.Font.small).lineLimit(2)
                    }
                }
            }
        }

        if !c.symbols.isEmpty {
            InspectorSection(title: "Symbols", count: c.symbols.count) {
                ExpandableList(items: c.symbols, limit: 14) { symbol in
                    InspectableRow { workspace.inspect(.symbol(symbol.id)) } content: {
                        SymbolBadge(kind: symbol.kind, size: 14)
                        Text(symbol.name).font(Theme.Font.small).lineLimit(1)
                        Spacer(minLength: 0)
                        if let refs = symbol.references, refs > 0 {
                            Text("\(refs)").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).monospacedDigit()
                        }
                        Text(symbol.lines.description).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3)
                    }
                    .padding(.leading, CGFloat(symbol.depth ?? 0) * 12)
                }
            }
        }

        if !c.dependencies.isEmpty {
            relationSection("Depends on", c.dependencies)
        }
        if !c.dependents.isEmpty {
            relationSection("Used by", c.dependents)
        }

        let external = c.imports.filter(\.isExternal).map(\.module)
        if !external.isEmpty {
            InspectorSection(title: "External imports", count: external.count) {
                FlowTags(tags: Array(Set(external)).sorted())
            }
        }

        if !c.related.isEmpty {
            InspectorSection(title: "Related files") {
                ForEach(c.related) { related in
                    InspectableRow { workspace.inspect(.file(related.path)) } content: {
                        FileIcon(path: related.path)
                        VStack(alignment: .leading, spacing: 1) {
                            PathText(path: related.path, font: Theme.Font.small)
                            Text(related.reason).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                        }
                    }
                }
            }
        }
    }

    private func relationSection(_ title: String, _ relations: [FileRelation]) -> some View {
        InspectorSection(title: title, count: relations.count) {
            ExpandableList(items: relations, limit: 8) { relation in
                InspectableRow { workspace.inspect(.file(relation.path)) } content: {
                    FileIcon(path: relation.path)
                    VStack(alignment: .leading, spacing: 1) {
                        PathText(path: relation.path, font: Theme.Font.small)
                        if let symbols = relation.symbols, !symbols.isEmpty {
                            Text(symbols.joined(separator: ", ")).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Symbol

struct SymbolInspector: View {
    let workspace: Workspace
    let query: String
    @State private var context: SymbolContext?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let context {
                    content(context)
                } else if let error {
                    ContentUnavailableView("Symbol Not Found", systemImage: "curlybraces", description: Text(error))
                } else {
                    LoadingState()
                }
            }
            .padding(Theme.Space.l)
        }
        .task(id: workspace.generation) {
            let engine = workspace.engine
            let query = self.query
            do {
                context = try await offMain { try engine.symbolContext(query) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func content(_ c: SymbolContext) -> some View {
        let symbol = c.symbol
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                SymbolBadge(kind: symbol.kind, size: 20)
                Text(symbol.qualifiedName).font(Theme.Font.section).textSelection(.enabled)
            }
            HStack(spacing: Theme.Space.xs) {
                Tag(text: symbol.kind.displayName)
                if let visibility = symbol.visibility { Tag(text: visibility.rawValue) }
                if symbol.isExported == true { Tag(text: "exported") }
            }
            Button {
                workspace.inspect(.file(symbol.path))
            } label: {
                Text("\(symbol.path):\(symbol.lines.description)").font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3).lineLimit(2)
            }
            .buttonStyle(.plain)
            OpenButtons(workspace: workspace, path: symbol.path, line: symbol.lines.start)
        }
        if let signature = symbol.signature {
            Text(signature)
                .font(Theme.Font.mono)
                .textSelection(.enabled)
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        if let doc = symbol.doc {
            Text(doc).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).fixedSize(horizontal: false, vertical: true)
        }
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.l) {
            GridRow {
                MetricView(label: "References", value: (symbol.references ?? 0).grouped)
                MetricView(label: "Callers", value: c.callers.count.grouped)
                MetricView(label: "Calls", value: c.callees.count.grouped)
            }
        }
        Divider()
        RiskSummary(impact: c.impact) { workspace.inspect(.impact(symbol.id)) }

        if !c.diagnostics.isEmpty {
            InspectorSection(title: "Diagnostics", count: c.diagnostics.count) {
                ForEach(c.diagnostics) { diagnostic in
                    InspectableRow { workspace.inspect(.diagnostic(diagnostic)) } content: {
                        SeverityBadge(severity: diagnostic.severity, showsLabel: false)
                        Text(diagnostic.title).font(Theme.Font.small).lineLimit(2)
                    }
                }
            }
        }
        if let parent = c.parent {
            InspectorSection(title: "Member of") {
                InspectableRow { workspace.inspect(.symbol(parent.id)) } content: {
                    SymbolBadge(kind: parent.kind, size: 14)
                    Text(parent.qualifiedName).font(Theme.Font.small)
                }
            }
        }
        if !c.members.isEmpty {
            InspectorSection(title: "Members", count: c.members.count) {
                ExpandableList(items: c.members, limit: 10) { member in
                    InspectableRow { workspace.inspect(.symbol(member.id)) } content: {
                        SymbolBadge(kind: member.kind, size: 14)
                        Text(member.name).font(Theme.Font.small).lineLimit(1)
                        Spacer(minLength: 0)
                        if let refs = member.references, refs > 0 {
                            Text("\(refs)").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                        }
                    }
                }
            }
        }
        if !c.callers.isEmpty {
            InspectorSection(title: "Called by", count: c.callers.count) {
                ExpandableList(items: c.callers, limit: 8) { relation in
                    InspectableRow { workspace.open(path: relation.symbol.path, line: relation.sites.first) } content: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(relation.symbol.qualifiedName).font(Theme.Font.small).lineLimit(1)
                            Text("\((relation.symbol.path as NSString).lastPathComponent):\(relation.sites.prefix(4).map(String.init).joined(separator: ","))")
                                .font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3)
                        }
                    }
                }
            }
        }
        if !c.callees.isEmpty {
            InspectorSection(title: "Calls", count: c.callees.count) {
                ExpandableList(items: c.callees, limit: 8) { relation in
                    InspectableRow { workspace.inspect(.symbol(relation.symbol.id)) } content: {
                        SymbolBadge(kind: relation.symbol.kind, size: 14)
                        Text(relation.symbol.qualifiedName).font(Theme.Font.small).lineLimit(1)
                    }
                }
            }
        }
        if !c.references.isEmpty {
            InspectorSection(title: "References", count: c.references.count) {
                ExpandableList(items: c.references, limit: 10) { site in
                    InspectableRow { workspace.open(path: site.path, line: site.line) } content: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Theme.Space.xs) {
                                Text("\((site.path as NSString).lastPathComponent):\(site.line)").font(Theme.Font.monoSmall)
                                Text(site.kind.rawValue).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                            }
                            if let snippet = site.snippet {
                                Text(snippet).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text2).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Map node

struct NodeInspector: View {
    let workspace: Workspace
    let node: MapNode

    var body: some View {
        switch node.kind {
        case .file:
            if let path = node.path { FileInspector(workspace: workspace, path: path) }
        case .symbol:
            SymbolInspector(workspace: workspace, query: "\(node.path ?? "")#\(node.label)")
        case .external where !node.id.hasPrefix("ext|"):
            SymbolInspector(workspace: workspace, query: "\(node.path ?? "")#\(node.label)")
        default:
            groupBody
        }
    }

    private var memberFiles: [FileSummary] {
        let prefix: String? = {
            if let path = node.path { return path }
            if let parsed = NodeID.parse(node.id.hasPrefix("ext|") ? String(node.id.dropFirst(4)) : node.id), parsed.kind == .dir { return parsed.value }
            return nil
        }()
        let files = workspace.files.filter { file in
            if node.kind == .module, let module = file.module { return module == node.label }
            guard let prefix else { return false }
            return prefix.isEmpty || prefix == "." || file.path.hasPrefix(prefix + "/")
        }
        return files.sorted { $0.centrality > $1.centrality }
    }

    private var groupBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: node.kind == .module ? "shippingbox" : "folder").foregroundStyle(Theme.Colors.text2)
                        Text(node.label).font(Theme.Font.section)
                    }
                    Text(node.kind == .external ? "Outside the current focus" : (node.kind == .module ? "Module" : "Folder"))
                        .font(Theme.Font.small).foregroundStyle(Theme.Colors.text3)
                    Button(node.kind == .external ? "Go to \(node.label)" : "Explore in map") {
                        workspace.section = .map
                        workspace.map.activate(node, in: workspace)
                    }
                    .controlSize(.small)
                }
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.m) {
                    GridRow {
                        MetricView(label: "Files", value: node.files.grouped)
                        MetricView(label: "Lines", value: node.lines.compact)
                        MetricView(label: "Symbols", value: node.symbols.compact)
                    }
                    GridRow {
                        MetricView(label: "Incoming", value: node.fanIn.grouped, detail: "groups")
                        MetricView(label: "Outgoing", value: node.fanOut.grouped, detail: "groups")
                        MetricView(label: "Issues", value: node.diagnostics.grouped)
                    }
                }
                let files = memberFiles
                if !files.isEmpty {
                    InspectorSection(title: "Most central files", count: files.count) {
                        ExpandableList(items: files, limit: 10) { file in
                            InspectableRow { workspace.inspect(.file(file.path)) } content: {
                                FileIcon(path: file.path)
                                PathText(path: file.path, font: Theme.Font.small)
                                Spacer(minLength: 0)
                                Text(file.codeLines.grouped).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).monospacedDigit()
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.l)
        }
    }
}

// MARK: - Diagnostic

struct DiagnosticInspector: View {
    let workspace: Workspace
    let diagnostic: Diagnostic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        SeverityPill(severity: diagnostic.severity)
                        CategoryLabel(category: diagnostic.category)
                    }
                    Text(diagnostic.title).font(Theme.Font.section).fixedSize(horizontal: false, vertical: true)
                    Text(diagnostic.summary).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).fixedSize(horizontal: false, vertical: true)
                }
                InspectorSection(title: "Why it was flagged") {
                    Text(diagnostic.reason).font(Theme.Font.small).fixedSize(horizontal: false, vertical: true)
                }
                if !diagnostic.metrics.isEmpty {
                    InspectorSection(title: "Evidence") {
                        Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.xs) {
                            ForEach(diagnostic.metrics, id: \.name) { metric in
                                GridRow {
                                    Text(metric.name).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2)
                                    Text(metric.formattedValue).font(Theme.Font.small).monospacedDigit()
                                    if let threshold = metric.threshold {
                                        Text("threshold \(DiagnosticMetric(name: "", value: threshold).formattedValue)").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                                    }
                                }
                            }
                        }
                    }
                }
                InspectorSection(title: "Suggested improvement") {
                    Text(diagnostic.recommendation).font(Theme.Font.small).fixedSize(horizontal: false, vertical: true)
                }
                ImproveButtons(title: "Improve with", action: { workspace.improve(diagnostic) })
                InspectorSection(title: "Affected", count: diagnostic.targets.count) {
                    ExpandableList(items: diagnostic.targets.enumerated().map { IdentifiedTarget(index: $0.offset, target: $0.element) }, limit: 12) { item in
                        InspectableRow {
                            if item.target.kind == .directory || item.target.kind == .module {
                                workspace.section = .map
                                workspace.map.navigate(to: .init(level: .directories, focus: NodeID.directory(item.target.path)), in: workspace)
                            } else {
                                workspace.inspect(.file(item.target.path))
                            }
                        } content: {
                            FileIcon(path: item.target.path)
                            VStack(alignment: .leading, spacing: 1) {
                                PathText(path: item.target.path, font: Theme.Font.small)
                                if let symbol = item.target.symbol {
                                    Text(symbol + (item.target.line.map { " · line \($0)" } ?? "")).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                                }
                            }
                        }
                        .contextMenu {
                            Button("Open in Editor") { workspace.open(path: item.target.path, line: item.target.line) }
                        }
                    }
                }
            }
            .padding(Theme.Space.l)
        }
    }

    struct IdentifiedTarget: Identifiable {
        let index: Int
        let target: DiagnosticTarget
        var id: Int { index }
    }
}

// MARK: - Impact

struct ImpactInspector: View {
    let workspace: Workspace
    let target: String
    @State private var report: ImpactReport?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if let report {
                    content(report)
                } else if let error {
                    ContentUnavailableView("Impact Unavailable", systemImage: "scope", description: Text(error))
                } else {
                    LoadingState()
                }
            }
            .padding(Theme.Space.l)
        }
        .task(id: workspace.generation) {
            let engine = workspace.engine
            let target = self.target
            do {
                report = try await offMain { try engine.impact(of: target) }
            } catch {
                self.error = error.localizedDescription
            }
        }
        .accessibilityIdentifier("impact-inspector")
    }

    @ViewBuilder
    private func content(_ r: ImpactReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Change Impact").font(Theme.Font.label).foregroundStyle(Theme.Colors.text3).textCase(.uppercase)
            Text(r.target).font(Theme.Font.section).lineLimit(2).textSelection(.enabled)
            HStack(spacing: Theme.Space.s) {
                Circle().fill(Theme.Colors.risk(r.riskLevel)).frame(width: 9, height: 9)
                Text("\(r.riskLevel.rawValue.capitalized) risk").font(Theme.Font.rowTitle)
                Text("\(Int(r.riskScore.rounded()))/100").font(Theme.Font.small).foregroundStyle(Theme.Colors.text3).monospacedDigit()
            }
            Text(r.summary).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).fixedSize(horizontal: false, vertical: true)
        }
        InspectorSection(title: "Risk factors") {
            ForEach(r.factors) { factor in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(String(format: "%+.0f", factor.impact)).font(Theme.Font.monoSmall).frame(width: 30, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(factor.label).font(Theme.Font.small)
                        Text(factor.detail).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                    }
                }
            }
        }
        if !r.relatedTests.isEmpty {
            InspectorSection(title: "Tests to run", count: r.relatedTests.count) {
                ForEach(r.relatedTests, id: \.self) { path in
                    InspectableRow { workspace.inspect(.file(path)) } content: {
                        Image(systemName: "checkmark.seal").foregroundStyle(Theme.Colors.text3)
                        PathText(path: path, font: Theme.Font.small)
                    }
                }
            }
        }
        if !r.directDependents.isEmpty {
            InspectorSection(title: "Direct dependents", count: r.directDependents.count) {
                ExpandableList(items: r.directDependents, limit: 10) { relation in
                    InspectableRow { workspace.inspect(.file(relation.path)) } content: {
                        FileIcon(path: relation.path)
                        VStack(alignment: .leading, spacing: 1) {
                            PathText(path: relation.path, font: Theme.Font.small)
                            if let symbols = relation.symbols, !symbols.isEmpty {
                                Text("uses " + symbols.joined(separator: ", ")).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        if !r.transitiveDependents.isEmpty {
            InspectorSection(title: "Transitive dependents", count: r.transitiveDependents.count) {
                ExpandableList(items: r.transitiveDependents, limit: 10) { relation in
                    InspectableRow { workspace.inspect(.file(relation.path)) } content: {
                        Text("\(relation.distance ?? 2)").font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3).frame(width: 14)
                        FileIcon(path: relation.path)
                        PathText(path: relation.path, font: Theme.Font.small)
                    }
                }
            }
        }
        if !r.callers.isEmpty {
            InspectorSection(title: "Call and reference sites", count: r.callers.count) {
                ExpandableList(items: r.callers, limit: 8) { site in
                    InspectableRow { workspace.open(path: site.path, line: site.line) } content: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\((site.path as NSString).lastPathComponent):\(site.line)").font(Theme.Font.monoSmall)
                            if let snippet = site.snippet { Text(snippet).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3).lineLimit(1) }
                        }
                    }
                }
            }
        }
        if !r.affectedAreas.isEmpty {
            InspectorSection(title: "Affected areas") {
                FlowTags(tags: r.affectedAreas.map { "\($0.name) · \($0.files)" })
            }
        }
        ImproveButtons(title: "Plan this change with", action: { workspace.planChange(r) })
    }
}

/// The closing action of an inspection: hand the finding to a coding agent.
struct ImproveButtons: View {
    let title: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button(action: action) {
                Label("\(title) Claude Code or Codex…", systemImage: "wand.and.stars.inverse")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("improve-with-agent")
            Text("Review the prompt first. Runs in your repository; the agent uses its own account and model.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Colors.text3)
        }
        .padding(.top, Theme.Space.s)
    }
}
