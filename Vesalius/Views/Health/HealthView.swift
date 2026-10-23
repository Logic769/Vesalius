import SwiftUI
import VesaliusCore

struct HealthView: View {
    let workspace: Workspace
    @State private var expanded: Set<HealthCategory> = []

    var body: some View {
        if let report = workspace.overview?.health {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    header(report)
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader("Score breakdown", subtitle: "each category is scored 0 to 100 from measured signals")
                        Panel(padding: 0) {
                            ForEach(Array(report.categories.enumerated()), id: \.element.id) { index, category in
                                if index > 0 { Divider().padding(.leading, Theme.Space.l + 62) }
                                CategoryRow(category: category, diagnostics: count(category.category), isExpanded: Binding(
                                    get: { expanded.contains(category.category) },
                                    set: { if $0 { expanded.insert(category.category) } else { expanded.remove(category.category) } }
                                )) {
                                    workspace.section = .diagnostics
                                }
                            }
                        }
                    }
                    methodology
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("health")
        } else {
            ContentUnavailableView("No Health Data", systemImage: "waveform.path.ecg", description: Text("Index the repository to compute its health."))
        }
    }

    private func count(_ category: HealthCategory) -> Int {
        workspace.diagnostics.filter { $0.category == category && $0.severity >= .low }.count
    }

    private func header(_ report: HealthReport) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.xl) {
            ScoreGauge(score: report.score, diameter: 132, lineWidth: 10)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Repository Health").font(Theme.Font.label).foregroundStyle(Theme.Colors.text3).textCase(.uppercase)
                Text(report.grade).font(Theme.Font.title)
                Text(report.summary).font(Theme.Font.body).foregroundStyle(Theme.Colors.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.s) {
                    ForEach(Severity.allCases.reversed(), id: \.self) { severity in
                        let count = report.diagnosticCounts[severity.rawValue] ?? 0
                        if count > 0 {
                            SeverityPill(severity: severity, count: count)
                        }
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
        }
    }

    private var methodology: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("How this is measured").font(Theme.Font.rowTitle)
            Text("Scores come from deterministic measurements of the dependency graph, file and symbol sizes, complexity, duplication and references. The overall score is the weighted average of the categories above. Expand a category to see every deduction and the numbers behind it. Nothing is estimated by a language model.")
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Colors.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Space.s)
    }
}

private struct CategoryRow: View {
    let category: CategoryScore
    let diagnostics: Int
    @Binding var isExpanded: Bool
    let showDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Colors.text3)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(category.category.emoji)
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                        .background(Theme.Colors.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.small + 2, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.category.displayName).font(Theme.Font.rowTitle)
                        Text(category.summary).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 280, alignment: .leading)
                    ProportionBar(value: Double(category.score) / 100, color: Theme.Colors.score(category.score), height: 6)
                    Text("\(category.score)")
                        .font(Theme.Font.rowTitle)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("health-category-\(category.category.rawValue)")

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(category.category.explanation)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Colors.text2)
                    if category.factors.isEmpty {
                        Text("No deductions.").font(Theme.Font.small).foregroundStyle(Theme.Colors.text3)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.xs) {
                            ForEach(category.factors) { factor in
                                GridRow {
                                    Text(String(format: "%+.1f", factor.impact))
                                        .font(Theme.Font.monoSmall)
                                        .foregroundStyle(factor.impact < 0 ? Theme.Colors.text1 : Theme.Colors.text3)
                                        .frame(width: 44, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(factor.label).font(Theme.Font.small)
                                        Text(factor.detail).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        Text("Weight \(Int((category.weight * 100).rounded()))% of the overall score").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                        Spacer()
                        if diagnostics > 0 {
                            Button("\(diagnostics) related diagnostic\(diagnostics == 1 ? "" : "s")", action: showDiagnostics)
                                .buttonStyle(.link)
                                .font(Theme.Font.small)
                        }
                    }
                }
                .padding(.leading, 62)  // chevron 10 + 12 + tile 28 + 12: aligned with the name
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }
}
