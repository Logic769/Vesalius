import Foundation

/// The HTTP route a Next.js handler serves, for labelling use sites (`POST /api/tokens`).
///
/// App Router: `(src/)app/**/route.(ts|js)` plus an exported `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`
/// or `OPTIONS` function gives `<METHOD> <path>`; route groups `(group)` and parallel-route slots `@slot` add no
/// path segment, and intercepting markers (`(.)photo`) are dropped from theirs. Pages Router: the default export
/// of `(src/)pages/api/**` gives `ANY /api/<path>` (the handler checks the method itself); `index` files serve
/// their folder. Dynamic segments stay as written (`/api/users/[id]`).
public enum RouteLabel {
    public static let httpMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    public enum Router: String, Sendable {
        case app
        case pages
    }

    private static let scriptExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts"]

    /// The router and URL path a route file serves (`src/app/api/tokens/route.ts` → `/api/tokens`), or nil when
    /// `path` is not a route file.
    public static func route(forFile path: String) -> (router: Router, urlPath: String)? {
        let components = path.split(separator: "/").map(String.init)
        guard let fileName = components.last else { return nil }
        let stem = (fileName as NSString).deletingPathExtension
        guard scriptExtensions.contains((fileName as NSString).pathExtension) else { return nil }
        if stem == "route", let app = rootIndex(of: "app", in: components) {
            return (.app, urlPath(components[(app + 1)..<(components.count - 1)]))
        }
        if let pages = rootIndex(of: "pages", in: components), components.count > pages + 2, components[pages + 1] == "api" {
            var segments = Array(components[(pages + 1)..<(components.count - 1)])
            if stem != "index" { segments.append(stem) }
            return (.pages, urlPath(segments[...]))
        }
        return nil
    }

    /// `POST /api/tokens` for the `POST` handler of `src/app/api/tokens/route.ts`, `ANY /api/hello` for the default
    /// export of `pages/api/hello.ts`; nil for any other function or file.
    public static func label(path: String, handler: String, isDefaultExport: Bool = false) -> String? {
        guard let route = route(forFile: path) else { return nil }
        switch route.router {
        case .app: return httpMethods.contains(handler) ? "\(handler) \(route.urlPath)" : nil
        case .pages: return isDefaultExport || handler == "default" ? "ANY \(route.urlPath)" : nil
        }
    }

    /// The `app` or `pages` folder of the project: at the repository root or under `src/` first (also inside
    /// a monorepo package), else the first folder with that name.
    private static func rootIndex(of name: String, in components: [String]) -> Int? {
        let folders = components.dropLast()
        for (index, component) in folders.enumerated() where component == name {
            if index == 0 || components[index - 1] == "src" { return index }
        }
        return folders.firstIndex(of: name)
    }

    private static func urlPath(_ segments: ArraySlice<String>) -> String {
        let kept = segments.compactMap { segment -> String? in
            if segment.hasPrefix("@") { return nil }
            guard segment.hasPrefix("("), let close = segment.firstIndex(of: ")") else { return segment }
            // `(group)` adds nothing; `(.)photo`, `(..)photo` and `(...)photo` intercept `photo`.
            let rest = String(segment[segment.index(after: close)...])
            return rest.isEmpty ? nil : rest
        }
        return "/" + kept.joined(separator: "/")
    }
}
