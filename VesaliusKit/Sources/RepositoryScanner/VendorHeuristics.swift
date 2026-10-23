import Foundation

/// Recognises third-party projects copied into a repository (vendored libraries, upstream checkouts,
/// embedded language runtimes). They are excluded by default because they would dominate metrics and
/// search results while not being part of the codebase's own architecture.
public enum VendorHeuristics {
    /// Folders that conventionally hold other people's code.
    public static let containerNames: Set<String> = [
        "dependencies", "deps", "vendor", "vendors", "vendored", "third_party", "third-party", "thirdparty",
        "3rdparty", "external", "externals", "extern", "submodules", "lib-vendor",
    ]

    private static let licenseNames: [String] = ["license", "licence", "copying", "notice", "unlicense"]
    private static let upstreamMarkers: Set<String> = [
        "contributing.md", "contributing", "codeowners", "authors", "authors.md", "code_of_conduct.md",
        "security.md", "maintainers", "maintainers.md", "changelog.md", "changes.md", "history.md", "governance.md",
        ".github", ".gitlab-ci.yml", ".travis.yml", "appveyor.yml", "codecov.yml", ".circleci",
    ]
    private static let runtimeNames: Set<String> = ["python-stdlib", "stdlib", "lib-dynload", "site-packages", "dist-packages"]

    /// - Parameters:
    ///   - path: repository-relative directory path (never the root).
    ///   - entries: names of the directory's immediate children.
    public static func isVendoredProject(path: String, entries: Set<String>) -> Bool {
        let components = path.split(separator: "/").map { $0.lowercased() }
        guard let name = components.last else { return false }
        if runtimeNames.contains(name) { return true }

        let lowerEntries = Set(entries.map { $0.lowercased() })
        let hasLicense = lowerEntries.contains { entry in licenseNames.contains { entry.hasPrefix($0) } }
        let markers = lowerEntries.intersection(upstreamMarkers).count
        let snapshotSuffix = name.hasSuffix("-master") || name.hasSuffix("-main") || name.hasSuffix("-develop")
            || name.range(of: #"-v?\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil
        let parent = components.count >= 2 ? components[components.count - 2] : ""
        let insideContainer = containerNames.contains(parent)

        if snapshotSuffix && (hasLicense || markers >= 1) { return true }
        if insideContainer && (hasLicense || markers >= 1) { return true }
        if hasLicense && markers >= 2 { return true }
        return false
    }
}
