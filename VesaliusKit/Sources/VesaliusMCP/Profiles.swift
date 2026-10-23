import Foundation

/// Which tools the server offers and how they load: `vesalius mcp --profile`, else `VESALIUS_MCP_PROFILE`.
public enum MCPProfile: String, CaseIterable, Sendable {
    /// The five tools. `usages` and `feature_map` load up front once their golden gates pass.
    case `default`
    /// The five tools, all deferred: the least cost per request in sessions that never navigate code.
    case lean
    /// The five tools plus a deferred `repo_report` (health, diagnostics, hotspots, unused code, overview, files).
    case full

    public static let environmentKey = "VESALIUS_MCP_PROFILE"

    /// The profile named in the environment, else `default`; an unknown name is reported through `warn`.
    public static func from(environment: [String: String], warn: (String) -> Void = { _ in }) -> MCPProfile {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return .default }
        guard let profile = MCPProfile(rawValue: value) else {
            warn("ignoring \(environmentKey)=\(value): expected one of \(allCases.map(\.rawValue).joined(separator: ", "))")
            return .default
        }
        return profile
    }
}

/// `VESALIUS_MCP_ALWAYS_LOAD=usages,feature_map` loads exactly the listed tools up front whatever their gates
/// say, and `none` loads none: for benchmark arms. Unset or empty leaves the gates in charge.
public enum AlwaysLoadOverride {
    public static let environmentKey = "VESALIUS_MCP_ALWAYS_LOAD"

    public static func from(environment: [String: String]) -> Set<String>? {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.lowercased() == "none" { return [] }
        return Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}
