import QueryEngine
import SwiftUI
import VesaliusCore

struct ArchitectureView: View {
    let workspace: Workspace
    @State private var suggestions: [ExtractionSuggestion] = []

    var body: some View {
        if let report = workspace.overview?.architecture {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Architecture").font(Theme.Font.title)
                        Text(report.summary).font(Theme.Font.body).foregroundStyle(Theme.Colors.text2).fixedSize(horizontal: false, vertical: true)
                        if !report.frameworks.isEmpty { FlowTags(tags: report.frameworks) }
                    }
                    patterns(report)
                    if !report.layers.isEmpty { layers(report) }
                    if !report.areas.isEmpty { areas(report) }
                    extraction
                    if !report.entryPoints.isEmpty { entryPoints(report) }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: workspace.generation) {
                let engine = workspace.engine
                suggestions = (try? await offMain { try engine.suggestions() }) ?? []
            }
            .accessibilityIdentifier("architecture")
        }
    }

    private func patterns(_ report: ArchitectureReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Observed patterns", subtitle: "evidence-backed observations, not certainties")
            if report.patterns.isEmpty {
                Text("No recognisable architectural pattern. The code may be small, a library, or organised by convention Vesalius does not recognise yet.")
                    .font(Theme.Font.small).foregroundStyle(Theme.Colors.text3)
            } else {
                Panel(padding: 0) {
                    ForEach(Array(report.patterns.enumerated()), id: \.element.id) { index, pattern in
                        if index > 0 { Divider().padding(.leading, Theme.Space.l) }
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            HStack(spacing: Theme.Space.m) {
                                Text(pattern.label).font(Theme.Font.rowTitle)
                                Spacer()
                                ProportionBar(value: pattern.confidence, color: Theme.Colors.accent, height: 5).frame(width: 120)
                                Text("\(Int((pattern.confidence * 100).rounded()))%").font(Theme.Font.small).monospacedDigit().foregroundStyle(Theme.Colors.text2).frame(width: 36, alignment: .trailing)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(pattern.evidence, id: \.self) { evidence in
                                    Label(evidence, systemImage: "checkmark").font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).labelStyle(EvidenceLabelStyle())
                                }
                            }
                            if let paths = pattern.paths, !paths.isEmpty {
                                HStack(spacing: Theme.Space.s) {
                                    ForEach(paths.prefix(4), id: \.self) { path in
                                        Button((path as NSString).lastPathComponent) { workspace.inspect(.file(path)) }
                                            .buttonStyle(.link)
                                            .font(Theme.Font.caption)
                                    }
                                }
                            }
                        }
                        .padding(Theme.Space.l)
                    }
                }
            }
        }
    }

    private func layers(_ report: ArchitectureReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Layers", subtitle: "inferred from folder and type naming; arrows show dependency direction")
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ForEach(report.layers) { layer in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(layer.name).font(Theme.Font.rowTitle)
                        Text("\(layer.files) files").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                        if !layer.dependsOn.isEmpty {
                            Label(layer.dependsOn.joined(separator: ", "), systemImage: "arrow.right")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Colors.text2)
                                .labelStyle(EvidenceLabelStyle())
                        }
                    }
                    .padding(Theme.Space.m)
                    .frame(minWidth: 140, alignment: .leading)
                    .background(Theme.Colors.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
                }
            }
        }
    }

    private func areas(_ report: ArchitectureReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Areas", subtitle: "\(report.areas.count) feature areas or modules")
            Panel(padding: 0) {
                ForEach(Array(report.areas.prefix(30).enumerated()), id: \.element.id) { index, area in
                    if index > 0 { Divider().padding(.leading, Theme.Space.l) }
                    InspectableRow {
                        workspace.section = .map
                        workspace.map.navigate(to: .init(level: .directories, focus: NodeID.directory(area.path)), in: workspace)
                    } content: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(area.name).font(Theme.Font.rowTitle)
                            Text(area.path).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3)
                        }
                        .frame(width: 260, alignment: .leading)
                        Text("\(area.files) files · \(area.lines.compact) lines").font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).frame(width: 150, alignment: .leading)
                        Text(area.dependsOn.isEmpty ? "No dependencies on other areas" : "Uses " + area.dependsOn.prefix(4).joined(separator: ", "))
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.Colors.text3)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.Colors.text3)
                    }
                    .padding(.horizontal, Theme.Space.s)
                }
            }
        }
    }

    private var extraction: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Package and module candidates", subtitle: "groups that are strongly connected inside and loosely coupled outside")
            if suggestions.isEmpty {
                Text("No candidates yet. Groups either are small or depend heavily on the rest of the code.")
                    .font(Theme.Font.small).foregroundStyle(Theme.Colors.text3)
            }
            ForEach(suggestions) { suggestion in
                Panel {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "shippingbox").foregroundStyle(Theme.Colors.text2)
                            Text("\(suggestion.name) could become an independent package").font(Theme.Font.rowTitle)
                            Spacer()
                            if let root = suggestion.rootPath {
                                Text(root).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3)
                            }
                        }
                        HStack(spacing: Theme.Space.xl) {
                            MetricView(label: "Files", value: suggestion.files.count.grouped)
                            MetricView(label: "Cohesion", value: "\(Int((suggestion.cohesion * 100).rounded()))%")
                            MetricView(label: "Internal deps", value: suggestion.internalDependencies.grouped)
                            MetricView(label: "Uses outside", value: suggestion.externalDependencies.grouped)
                            MetricView(label: "Used from outside", value: suggestion.externalDependents.grouped)
                        }
                        HStack(alignment: .top, spacing: Theme.Space.xl) {
                            bulletList("Why", suggestion.reasons, symbol: "checkmark")
                            bulletList("Benefits", suggestion.benefits, symbol: "plus")
                            bulletList("Risks", suggestion.risks, symbol: "exclamationmark.triangle")
                        }
                        HStack {
                            Spacer()
                            Button("Plan extraction with an agent…") { workspace.planExtraction(suggestion) }
                                .controlSize(.small)
                        }
                        if !suggestion.entryPoints.isEmpty {
                            HStack(spacing: Theme.Space.s) {
                                Text("Public entry points").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                                ForEach(suggestion.entryPoints.prefix(5), id: \.self) { path in
                                    Button((path as NSString).lastPathComponent) { workspace.inspect(.file(path)) }
                                        .buttonStyle(.link)
                                        .font(Theme.Font.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func bulletList(_ title: String, _ items: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.Font.label).foregroundStyle(Theme.Colors.text3).textCase(.uppercase)
            if items.isEmpty {
                Text("None noted").font(Theme.Font.small).foregroundStyle(Theme.Colors.text3)
            }
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: symbol).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).labelStyle(EvidenceLabelStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func entryPoints(_ report: ArchitectureReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Entry points", subtitle: "where execution starts")
            FlowLayout(spacing: Theme.Space.xs) {
                ForEach(report.entryPoints.prefix(24), id: \.self) { path in
                    Button {
                        workspace.inspect(.file(path))
                    } label: {
                        Tag(text: path, systemImage: "play")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
