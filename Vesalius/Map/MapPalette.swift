import AppKit
import VesaliusCore

/// Colours for the System Map. Every colour is appearance-aware (light/dark variants resolved at draw
/// time), and group colours are derived from a stable hash so an area keeps its colour at every level.
enum MapPalette {
    // MARK: Categorical (areas, modules, folders, symbol groups)

    /// Hand-tuned hues with matched perceived lightness: deeper in light mode, lifted in dark mode.
    /// Ordered so neighbouring entries are far apart in hue (collision probing walks this order).
    /// Pure reds and oranges are left out on purpose: they mark cycles, dependencies and severities.
    static let categorical: [NSColor] = [
        dynamic(light: 0x2F6FEB, dark: 0x5E9BFF), // blue
        dynamic(light: 0xC9820E, dark: 0xF2B544), // amber
        dynamic(light: 0x3A9346, dark: 0x67CB76), // green
        dynamic(light: 0xC8456E, dark: 0xF57FA1), // rose
        dynamic(light: 0x7A4FD6, dark: 0xA88BFF), // violet
        dynamic(light: 0xA86F3C, dark: 0xD9A56E), // sand
        dynamic(light: 0xA2489F, dark: 0xD889D4), // orchid
        dynamic(light: 0x1B8CBF, dark: 0x52C1EE), // cyan
        dynamic(light: 0x7A9221, dark: 0xB4D25A), // olive
        dynamic(light: 0x4C59CF, dark: 0x8C95FF), // indigo
        dynamic(light: 0x556A82, dark: 0x9AAEC4), // slate
    ]

    /// Preferred palette slot for a group key (stable across launches).
    static func preferredSlot(_ key: String) -> Int {
        Int(stableHash(key) % UInt64(categorical.count))
    }

    /// Stable colour for a group key when no assigner is involved.
    static func groupColor(_ key: String) -> NSColor {
        categorical[preferredSlot(key)]
    }

    // MARK: Languages

    static func languageColor(_ language: Language?) -> NSColor {
        guard let language else { return neutralNode }
        switch language {
        case .swift: return dynamic(light: 0xE8553A, dark: 0xFF7A5C)
        case .typescript: return dynamic(light: 0x3178C6, dark: 0x5B9CEB)
        case .javascript: return dynamic(light: 0xC9A100, dark: 0xF1D44C)
        case .python: return dynamic(light: 0x3572A5, dark: 0x6FA5D6)
        case .objectiveC: return dynamic(light: 0x3E7BE0, dark: 0x6EA2FF)
        case .c: return dynamic(light: 0x5D6877, dark: 0xA1ACBA)
        case .cpp: return dynamic(light: 0xD8446F, dark: 0xF5789B)
        case .go: return dynamic(light: 0x0098BD, dark: 0x3CCCEB)
        case .rust: return dynamic(light: 0xB25A2E, dark: 0xE09A70)
        case .java: return dynamic(light: 0xA86A17, dark: 0xD99C4C)
        case .kotlin: return dynamic(light: 0x8A5CE6, dark: 0xB290FF)
        case .ruby: return dynamic(light: 0xC0392B, dark: 0xF06A5E)
        case .php: return dynamic(light: 0x4F5D95, dark: 0x8C9AD2)
        case .csharp: return dynamic(light: 0x2D8A3E, dark: 0x5FC46F)
        case .dart: return dynamic(light: 0x00968C, dark: 0x3DCFC2)
        case .shell: return dynamic(light: 0x4E8F2C, dark: 0x8CD066)
        case .html: return dynamic(light: 0xD0502C, dark: 0xF2825F)
        case .css: return dynamic(light: 0x6A4BB5, dark: 0x9E86E8)
        case .sql: return dynamic(light: 0xC27C0E, dark: 0xEBAA45)
        default: return neutralNode
        }
    }

    // MARK: Health & risk

    static func severityColor(_ severity: Severity?) -> NSColor {
        guard let severity else { return healthy }
        switch severity {
        case .info: return dynamic(light: 0x7E8794, dark: 0x9EA7B3)
        case .low: return dynamic(light: 0x3C8DBC, dark: 0x6CB4E0)
        case .medium: return dynamic(light: 0xD39A0B, dark: 0xF2C14E)
        case .high: return dynamic(light: 0xE0661F, dark: 0xFF9152)
        case .critical: return dynamic(light: 0xD93A42, dark: 0xFF6369)
        }
    }

    static let healthy = dynamic(light: 0x3D9A62, dark: 0x5CC98A)

    /// Cool slate → amber → orange → red.
    static func riskColor(_ risk: Double) -> NSColor {
        let stops: [(Double, UInt32, UInt32)] = [
            (0.00, 0x7D8EA3, 0x8FA2B8),
            (0.35, 0xD3A429, 0xEFC75E),
            (0.65, 0xE36E24, 0xFF9455),
            (1.00, 0xD93A42, 0xFF6369),
        ]
        let t = min(1, max(0, risk.isFinite ? risk : 0))
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for index in 0..<(stops.count - 1) where t >= stops[index].0 && t <= stops[index + 1].0 {
            lower = stops[index]
            upper = stops[index + 1]
            break
        }
        let span = max(upper.0 - lower.0, 0.0001)
        let fraction = (t - lower.0) / span
        return NSColor(name: nil) { appearance in
            let dark = appearance.isMapDark
            return interpolate(rgb(dark ? lower.2 : lower.1), rgb(dark ? upper.2 : upper.1), fraction)
        }
    }

    // MARK: Chrome

    static let canvasBackground = dynamic(light: 0xF8F8FA, dark: 0x18191C)
    static let gridDot = NSColor(name: nil) { $0.isMapDark ? NSColor(white: 1, alpha: 0.085) : NSColor(white: 0, alpha: 0.11) }
    static let neutralNode = dynamic(light: 0x8A94A3, dark: 0x9AA4B2)
    static let edgeNeutral = NSColor(name: nil) { $0.isMapDark ? NSColor(white: 1, alpha: 0.24) : NSColor(white: 0.1, alpha: 0.2) }
    static let edgeDimmed = NSColor(name: nil) { $0.isMapDark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.045) }
    /// Incoming edges of the selection: files that depend on it.
    static let dependents = dynamic(light: 0x2F7DF6, dark: 0x5AA2FF)
    /// Outgoing edges of the selection: what it depends on.
    static let dependencies = dynamic(light: 0xE8821E, dark: 0xFFA552)
    static let cycle = dynamic(light: 0xD9434A, dark: 0xFF6A6F)
    static let highlightRing = dynamic(light: 0xD4A20B, dark: 0xF4CA4D)
    static let ghostStroke = NSColor(name: nil) { $0.isMapDark ? NSColor(white: 1, alpha: 0.3) : NSColor(white: 0, alpha: 0.28) }
    static let cardText = NSColor.labelColor
    static let cardSecondaryText = NSColor.secondaryLabelColor
    static let tooltipBackground = NSColor(name: nil) { $0.isMapDark ? NSColor(srgbRed: 0.16, green: 0.165, blue: 0.18, alpha: 0.97) : NSColor(white: 1, alpha: 0.97) }
    static let tooltipBorder = NSColor(name: nil) { $0.isMapDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1) }

    // MARK: Helpers

    /// FNV-1a: stable across launches (unlike `Hasher`).
    nonisolated static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        let lightColor = rgb(light)
        let darkColor = rgb(dark)
        return NSColor(name: nil) { $0.isMapDark ? darkColor : lightColor }
    }

    nonisolated static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    nonisolated static func interpolate(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
        let a = a.usingColorSpace(.sRGB) ?? a
        let b = b.usingColorSpace(.sRGB) ?? b
        let f = CGFloat(t)
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * f,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
            alpha: 1
        )
    }
}

extension NSAppearance {
    /// True for dark and high-contrast dark appearances.
    nonisolated var isMapDark: Bool {
        bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]).map {
            $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua
        } ?? false
    }
}

/// Gives each group in view a distinct palette slot. Slots start from the key's stable hash, probe
/// past slots already used by other groups on screen, and are remembered for the life of the canvas,
/// so an area keeps its colour when you drill into it.
final class MapColorAssigner {
    private var slots: [String: Int] = [:]

    /// Assigns slots for the groups of a new scene (sorted for determinism), keeping earlier choices.
    func prepare(_ keys: Set<String>) {
        let count = MapPalette.categorical.count
        var used = Set(keys.compactMap { slots[$0] })
        for key in keys.sorted() where slots[key] == nil {
            let preferred = MapPalette.preferredSlot(key)
            var slot = preferred
            if used.count < count {
                for step in 0..<count {
                    let candidate = (preferred + step) % count
                    if !used.contains(candidate) {
                        slot = candidate
                        break
                    }
                }
            }
            slots[key] = slot
            used.insert(slot)
        }
    }

    func color(_ key: String) -> NSColor {
        MapPalette.categorical[slots[key] ?? MapPalette.preferredSlot(key)]
    }
}
