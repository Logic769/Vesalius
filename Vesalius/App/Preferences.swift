import AppKit
import Foundation

/// User preferences backed by UserDefaults (also editable from Settings).
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var semanticVectors: Bool {
        get { defaults.object(forKey: "semanticVectors") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "semanticVectors") }
    }

    static var gitHistory: Bool {
        get { defaults.object(forKey: "gitHistory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "gitHistory") }
    }

    static var watchForChanges: Bool {
        get { defaults.object(forKey: "watchForChanges") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "watchForChanges") }
    }

    static var preferredEditor: String? {
        get { defaults.string(forKey: "preferredEditor") }
        set { defaults.set(newValue, forKey: "preferredEditor") }
    }

    /// Extra exclusions (gitignore syntax) per repository path.
    static func exclusions(for repository: String) -> [String] {
        (defaults.dictionary(forKey: "exclusions") as? [String: [String]])?[repository] ?? []
    }

    static func setExclusions(_ patterns: [String], for repository: String) {
        var all = (defaults.dictionary(forKey: "exclusions") as? [String: [String]]) ?? [:]
        all[repository] = patterns.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        defaults.set(all, forKey: "exclusions")
    }
}

/// Installed code editors and how to open a file at a line in each.
struct Editor: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String
    /// URL scheme supporting `scheme://file/<path>:<line>`, if any.
    let urlScheme: String?

    var applicationURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) }
    var isInstalled: Bool { applicationURL != nil }
    var icon: NSImage? { applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    static let all: [Editor] = [
        Editor(id: "xcode", name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", urlScheme: nil),
        Editor(id: "cursor", name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", urlScheme: "cursor"),
        Editor(id: "vscode", name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", urlScheme: "vscode"),
        Editor(id: "windsurf", name: "Windsurf", bundleIdentifier: "com.exafunction.windsurf", urlScheme: "windsurf"),
        Editor(id: "zed", name: "Zed", bundleIdentifier: "dev.zed.Zed", urlScheme: "zed"),
        Editor(id: "sublime", name: "Sublime Text", bundleIdentifier: "com.sublimetext.4", urlScheme: nil),
        Editor(id: "nova", name: "Nova", bundleIdentifier: "com.panic.Nova", urlScheme: nil),
        Editor(id: "bbedit", name: "BBEdit", bundleIdentifier: "com.barebones.bbedit", urlScheme: nil),
    ]

    static var installed: [Editor] { all.filter(\.isInstalled) }
}

enum EditorLauncher {
    static var defaultEditor: Editor? {
        let installed = Editor.installed
        if let preferred = Preferences.preferredEditor, let editor = installed.first(where: { $0.id == preferred }) { return editor }
        return installed.first
    }

    static func open(_ url: URL, line: Int? = nil, editor: Editor? = nil) {
        guard let editor = editor ?? defaultEditor else {
            NSWorkspace.shared.open(url)
            return
        }
        if editor.id == "xcode", FileManager.default.isExecutableFile(atPath: "/usr/bin/xed") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            process.arguments = (line.map { ["--line", String($0)] } ?? []) + [url.path]
            if (try? process.run()) != nil { return }
        }
        if let scheme = editor.urlScheme,
           let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let target = URL(string: "\(scheme)://file\(encoded)\(line.map { ":\($0)" } ?? "")") {
            NSWorkspace.shared.open(target)
            return
        }
        if let app = editor.applicationURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
