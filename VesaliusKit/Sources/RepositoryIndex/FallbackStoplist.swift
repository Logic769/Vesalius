import Foundation

/// Names the linker never resolves by name alone.
///
/// When a member's receiver type is unknown, the linker falls back to the only declaration with that name
/// (ReferenceLinker step E). For ubiquitous standard-library and framework members (`count`, `append`, `font`,
/// `commit`) that guess is almost always wrong: `wal.append(…)` is an `Array` append, not the repository's one
/// `append` method, and `commandBuffer.commit()` is Metal's. Typed resolution ignores these lists.
public enum FallbackStoplist {
    /// The Swift analyzer's former `SwiftSyntaxSupport.ignoredNames`, which it used to drop at the source: the
    /// names a v3 index never resolved, so the v3 unique-name guess (`refs.alt_symbol_id`) skips them too.
    public static let legacy: Set<String> = [
        "print", "debugPrint", "map", "compactMap", "flatMap", "filter", "reduce", "forEach", "sorted", "sort",
        "append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "contains", "first", "last", "count",
        "isEmpty", "joined", "split", "min", "max", "zip", "abs", "stride", "fatalError", "precondition",
        "preconditionFailure", "assert", "assertionFailure", "String", "Int", "Int64", "Double", "Float", "CGFloat",
        "Bool", "Array", "Dictionary", "Set", "Optional", "Character", "Void", "Any", "AnyObject", "Never", "Error",
        "true", "false", "nil", "self", "super", "Self", "init", "description", "some", "any", "Task", "withAnimation",
        "type",
    ]

    /// Every name the fallback refuses: the legacy list plus the false bindings measured on the benchmark
    /// repositories (framework members such as SwiftUI modifiers, StoreKit and Metal properties, lifecycle verbs).
    public static let names: Set<String> = legacy.union([
        "font", "padding", "animation", "shadow", "frame", "offset", "opacity", "position", "weight", "string", "unit",
        "identifier", "domain", "offer", "delete", "decode", "encode", "component", "rawValue", "prefix", "formatted",
        "fill", "set", "length", "data", "size", "flags", "key", "id", "name", "value", "minX", "minY", "maxX", "maxY",
        "midX", "midY", "width", "height", "bounds", "origin", "center", "url", "path", "title", "date", "kind", "index",
        "error", "result", "state", "text", "color", "image", "open", "close", "start", "stop", "commit", "sync", "run",
        "update", "cancel", "resume", "load", "save", "reset", "lock", "unlock",
    ])

    /// Implicit members (`.leading`, `.headline`, `.red`) that SwiftUI and the standard library declare on
    /// countless types. Without a contextual type the linker never binds them to a repository case of that name.
    public static let implicit: Set<String> = [
        // Alignment, edges, axes and layout.
        "leading", "trailing", "center", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing",
        "firstTextBaseline", "lastTextBaseline", "horizontal", "vertical", "all", "both", "zero", "infinity", "identity",
        "fit", "fill", "fixed", "flexible", "adaptive", "automatic", "inline", "large", "small", "medium", "regular",
        "compact", "extraLarge", "mini", "prominent", "front", "back", "left", "right", "up", "down",
        // Fonts, weights and designs.
        "largeTitle", "title", "title2", "title3", "headline", "subheadline", "body", "callout", "footnote", "caption",
        "caption2", "ultraLight", "thin", "light", "semibold", "bold", "heavy", "black", "serif", "rounded",
        "monospaced", "italic", "monospacedDigit", "smallCaps",
        // Colors and styles.
        "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "white",
        "gray", "clear", "primary", "secondary", "tertiary", "quaternary", "accentColor", "tint", "plain", "bordered",
        "borderedProminent", "borderless", "glass", "glassProminent", "capsule", "circle", "roundedRectangle",
        "ultraThinMaterial", "thinMaterial", "regularMaterial", "thickMaterial", "ultraThickMaterial", "bar",
        "destructive", "cancel", "confirm", "hidden", "visible", "never", "always", "dark", "default",
        // Animations and transitions.
        "easeIn", "easeOut", "easeInOut", "linear", "spring", "smooth", "snappy", "bouncy", "interactiveSpring",
        "opacity", "scale", "slide", "move", "push", "asymmetric", "symbolEffect",
        // Standard library and Foundation.
        "none", "some", "init", "now", "distantPast", "distantFuture", "utf8", "utf16", "ascii", "main", "global",
        "shared", "standard", "current", "autoupdatingCurrent", "gregorian", "iso8601", "success", "failure",
        "userInitiated", "userInteractive", "utility", "background", "high", "low", "immediate", "atomic",
        "prettyPrinted", "sortedKeys", "withoutEscapingSlashes", "secondsSince1970", "millisecondsSince1970",
        "deferredToDate", "convertFromSnakeCase", "convertToSnakeCase", "useDefaultKeys", "caseInsensitive",
        "regularExpression", "literal", "backwards", "anchored", "whitespaces", "whitespacesAndNewlines", "newlines",
        "alphanumerics", "decimalDigits", "letters", "punctuationCharacters", "ascending", "descending", "forward",
        "reverse", "orderedSame", "orderedAscending", "orderedDescending", "year", "month", "day", "hour", "minute",
        "second", "nanosecond", "weekday", "weekOfYear", "weekOfMonth", "dayOfYear", "era", "quarter", "seconds",
        "milliseconds", "microseconds", "nanoseconds", "minutes", "hours", "days", "abbreviated", "wide", "narrow",
        "short", "long", "full", "complete", "omitted", "numeric", "twoDigits", "percent", "currency", "decimal",
        "atomicWrite", "completeFileProtection", "skipsHiddenFiles", "userDomainMask", "documentDirectory",
        "cachesDirectory", "applicationSupportDirectory", "libraryDirectory", "temporaryDirectory", "get", "post",
        "put", "patch", "head", "options", "text", "image", "video", "audio", "url", "json", "data", "plainText",
        "pdf", "png", "jpeg", "heic", "item", "content", "folder", "directory", "file", "active", "inactive",
        "phone", "pad", "mac", "tv", "watch", "vision", "portrait", "landscape", "landscapeLeft", "landscapeRight",
        "unknown", "notDetermined", "authorized", "denied", "restricted", "provisional", "ephemeral", "limited",
        "alert", "sound", "badge", "error", "warning", "info", "debug", "fault", "notice", "trace", "critical",
        "public", "private", "equal", "lessThan", "greaterThan", "selected", "disabled", "enabled", "normal",
        "highlighted", "focused", "submit", "next", "done", "go", "search", "send", "join", "route", "continue",
        "light", "tabBar", "navigationBar", "toolbar", "bottomBar", "keyboard", "sheet", "popover", "fullScreenCover",
        "infinite", "once", "repeating", "off", "on", "auto", "manual",
    ]
}
