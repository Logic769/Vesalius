import AppKit
import SwiftUI
import VesaliusCore

/// Every visual value used by the app. Feature views never use literal sizes or colours.
enum Theme {
    // MARK: Spacing (8pt grid, with 4 for tight clusters)
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: Radii (three, continuous)
    enum Radius {
        static let small: CGFloat = 5
        static let medium: CGFloat = 9
        static let large: CGFloat = 14
    }

    // MARK: Typography (macOS-density roles)
    enum Font {
        /// The one dominant number on a screen (the health score).
        static let display = SwiftUI.Font.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit()
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let section = SwiftUI.Font.system(size: 14, weight: .semibold)
        static let rowTitle = SwiftUI.Font.system(size: 13, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13)
        static let small = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        static let metric = SwiftUI.Font.system(size: 20, weight: .semibold).monospacedDigit()
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
        static let monoSmall = SwiftUI.Font.system(size: 11, design: .monospaced)
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold)
    }

    // MARK: Colour
    enum Colors {
        static let accent = Color.accentColor
        static let base = Color(nsColor: .windowBackgroundColor)
        static let raised = Color(nsColor: .controlBackgroundColor)
        static let inset = Color(nsColor: NSColor(name: "vesalius.inset") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.105, green: 0.11, blue: 0.125, alpha: 1)
                : NSColor(calibratedRed: 0.955, green: 0.958, blue: 0.965, alpha: 1)
        })
        static let hairline = Color(nsColor: .separatorColor)
        static let text1 = Color(nsColor: .labelColor)
        static let text2 = Color(nsColor: .secondaryLabelColor)
        static let text3 = Color(nsColor: .tertiaryLabelColor)
        static let fill = Color(nsColor: .quaternaryLabelColor).opacity(0.5)

        static let good = Color(nsColor: .systemGreen)
        static let caution = Color(nsColor: .systemYellow)
        static let warning = Color(nsColor: .systemOrange)
        static let danger = Color(nsColor: .systemRed)

        /// Shared with the System Map, so a severity is the same colour on the canvas and in lists.
        static func severity(_ severity: Severity) -> Color {
            Color(nsColor: MapPalette.severityColor(severity))
        }

        static func score(_ score: Int) -> Color {
            switch score {
            case 85...: good
            case 70..<85: Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.45, alpha: 1) : NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.22, alpha: 1) })
            case 55..<70: caution
            case 40..<55: warning
            default: danger
            }
        }

        static func risk(_ level: RiskLevel) -> Color {
            switch level {
            case .low: good
            case .moderate: caution
            case .high: warning
            case .critical: danger
            }
        }
    }

    // MARK: Colour coding
    /// One meaning, one hue, everywhere. Sections, severities, languages and symbol kinds each own a
    /// fixed colour; the accent is kept for interaction. Health categories are marked with an emoji
    /// rather than a hue, so a diagnostic row never carries two competing colours.
    enum Hue {
        static let blue = Color(nsColor: .systemBlue)
        static let indigo = Color(nsColor: .systemIndigo)
        static let purple = Color(nsColor: .systemPurple)
        static let pink = Color(nsColor: .systemPink)
        static let red = Color(nsColor: .systemRed)
        static let orange = Color(nsColor: .systemOrange)
        static let green = Color(nsColor: .systemGreen)
        static let brown = Color(nsColor: .systemBrown)
        static let gray = Color(nsColor: .systemGray)
    }
}

// MARK: - Reusable components

/// A section heading used inside scrolling pages.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var trailing: AnyView?

    init(_ title: String, subtitle: String? = nil, trailing: AnyView? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title).font(Theme.Font.section).foregroundStyle(Theme.Colors.text1)
            if let subtitle {
                Text(subtitle).font(Theme.Font.small).foregroundStyle(Theme.Colors.text3)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// A solid raised surface with a hairline border. One elevation level: never nest panels.
struct Panel<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).strokeBorder(Theme.Colors.hairline, lineWidth: 0.5))
    }
}

/// Label + value pair used in metric grids. Neutral by design: numbers are never tinted.
struct MetricView: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(label.uppercased()).font(Theme.Font.label).foregroundStyle(Theme.Colors.text3).tracking(0.4)
            Text(value).font(Theme.Font.metric).foregroundStyle(Theme.Colors.text1).lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text2).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A System Settings style icon tile: a white glyph on a coloured rounded square. Used for navigation
/// identity (sections), never for status.
struct IconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Severity as a tinted capsule: coloured dot, neutral label, so it stays legible on every hue.
struct SeverityPill: View {
    let severity: Severity
    var count: Int?

    var body: some View {
        let color = Theme.Colors.severity(severity)
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(count.map { "\($0.grouped) \(severity.displayName.lowercased())" } ?? severity.displayName)
                .monospacedDigit()
        }
        .font(Theme.Font.caption.weight(.medium))
        .foregroundStyle(Theme.Colors.text1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Xcode style symbol badge: a letter on the hue of the symbol's family (types, functions, values).
struct SymbolBadge: View {
    let kind: SymbolKind
    var size: CGFloat = 16

    var body: some View {
        let letter = kind.badgeLetter
        Text(letter)
            .font(.system(size: size * (letter.count > 1 ? 0.48 : 0.64), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityLabel(kind.displayName)
    }
}

/// A health category with its emoji marker. The emoji is the category's identity; it always sits next
/// to the name and is never used alone or as a control.
struct CategoryLabel: View {
    let category: HealthCategory
    var font: Font = Theme.Font.caption
    var color: Color = Theme.Colors.text2

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(category.emoji).accessibilityHidden(true)
            Text(category.displayName).foregroundStyle(color)
        }
        .font(font)
        .lineLimit(1)
    }
}

/// Small status dot + text for severities.
struct SeverityBadge: View {
    let severity: Severity
    var showsLabel = true

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(Theme.Colors.severity(severity)).frame(width: 7, height: 7)
            if showsLabel {
                Text(severity.displayName).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text2)
            }
        }
        .accessibilityLabel("Severity \(severity.displayName)")
    }
}

/// A capsule tag for frameworks, kinds and similar metadata.
struct Tag: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.Colors.text2)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Theme.Colors.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }
}

/// A repository-relative path rendered with a dimmed directory and a strong file name.
struct PathText: View {
    let path: String
    var font: Font = Theme.Font.body

    var body: some View {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        (Text(directory.isEmpty ? "" : directory + "/").foregroundStyle(Theme.Colors.text3) + Text(name).foregroundStyle(Theme.Colors.text1))
            .font(font)
            .lineLimit(1)
            .truncationMode(.head)
            .help(path)
    }
}

/// Horizontal proportion bar (0…1) in a single hue.
struct ProportionBar: View {
    let value: Double
    var color: Color = Theme.Colors.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.fill)
                Capsule().fill(color).frame(width: max(height, proxy.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Circular score gauge used for the health score.
struct ScoreGauge: View {
    let score: Int
    var diameter: CGFloat = 112
    var lineWidth: CGFloat = 9
    var showsNumber = true

    var body: some View {
        ZStack {
            Circle().stroke(Theme.Colors.fill, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, score))) / 100)
                .stroke(Theme.Colors.score(score), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsNumber {
                VStack(spacing: 0) {
                    Text("\(score)").font(diameter > 80 ? Theme.Font.display : Theme.Font.metric).foregroundStyle(Theme.Colors.text1)
                    if diameter > 80 {
                        Text("of 100").font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
                    }
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health score \(score) of 100")
    }
}

/// A row that can be clicked to inspect something, with consistent hover feedback.
struct InspectableRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) { content }
                .padding(.vertical, 5)
                .padding(.horizontal, Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(hovering ? Theme.Colors.fill : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension SymbolKind {
    var systemImage: String {
        switch self {
        case .class: "c.square"
        case .struct: "s.square"
        case .enum: "e.square"
        case .protocol, .interface: "p.square"
        case .actor: "a.square"
        case .extension: "puzzlepiece.extension"
        case .typeAlias: "t.square"
        case .function, .method: "f.square"
        case .initializer: "hammer"
        case .property, .variable, .constant: "v.square"
        case .enumCase: "list.bullet"
        case .namespace: "shippingbox"
        case .macro: "number.square"
        case .component: "rectangle.3.group"
        }
    }
}

extension SymbolKind {
    /// Types are purple, protocols indigo, functions blue, stored values green, cases and macros orange.
    var tint: Color {
        switch self {
        case .class, .struct, .enum, .actor, .component: Theme.Hue.purple
        case .protocol, .interface: Theme.Hue.indigo
        case .typeAlias: Theme.Hue.brown
        case .function, .method, .initializer: Theme.Hue.blue
        case .property, .variable, .constant: Theme.Hue.green
        case .enumCase, .macro: Theme.Hue.orange
        case .extension, .namespace: Theme.Hue.gray
        }
    }

    var badgeLetter: String {
        switch self {
        case .class: "C"
        case .struct: "S"
        case .enum: "E"
        case .actor: "A"
        case .component: "Co"
        case .protocol, .interface: "Pr"
        case .typeAlias: "T"
        case .function: "f"
        case .method: "M"
        case .initializer: "I"
        case .property: "P"
        case .variable: "V"
        case .constant: "K"
        case .enumCase: "c"
        case .macro: "#"
        case .extension: "Ex"
        case .namespace: "N"
        }
    }
}

extension HealthCategory {
    var emoji: String {
        switch self {
        case .modularity: "🧩"
        case .coupling: "🔗"
        case .complexity: "🌀"
        case .cycles: "🪢"
        case .organization: "🗂️"
        case .boundaries: "🧱"
        case .maintainability: "🛠️"
        case .deadCode: "🧹"
        }
    }
}

extension Language {
    /// GitHub-style language colours, shared with the System Map.
    var tint: Color { Color(nsColor: MapPalette.languageColor(self)) }

    var systemImage: String {
        switch self {
        case .swift: "swift"
        case .markdown: "doc.richtext"
        case .json, .yaml, .toml, .xml: "curlybraces"
        case .shell: "terminal"
        default: "doc.text"
        }
    }
}

extension Int {
    var compact: String { formatted(.number.notation(.compactName)) }
    var grouped: String { formatted(.number) }
}

extension Diagnostic {
    /// A dependency loop closed by explicit imports (the health engine titles softer loops
    /// "Interconnected … files").
    var isImportCycle: Bool { rule == "dependency-cycle" && !title.hasPrefix("Interconnected") }
}

/// A file's language glyph in that language's colour (Swift files wear Swift orange, as in Xcode).
struct FileIcon: View {
    let path: String

    var body: some View {
        let language = Language.detect(fileName: (path as NSString).lastPathComponent)
        Image(systemName: language.systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(language.tint)
            .frame(width: 14)
            .accessibilityHidden(true)
    }
}
