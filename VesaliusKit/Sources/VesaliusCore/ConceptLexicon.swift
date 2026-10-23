import Foundation

/// Curated software-engineering vocabulary. Used to expand natural-language questions
/// ("where does login happen") into the words developers actually use in identifiers
/// (`auth`, `session`, `credential`, `signIn`), and to recognise concerns for health analysis.
public enum ConceptLexicon {
    public struct Concept: Sendable {
        public let name: String
        /// Words that strongly indicate the concept in identifiers and paths.
        public let terms: [String]
        /// Health "concern" bucket, used for mixed-responsibility detection.
        public let concern: Concern?
    }

    public enum Concern: String, Sendable, Codable, CaseIterable {
        case ui, networking, persistence, authentication, payments, analytics, concurrency, media, navigation, testing

        public var displayName: String {
            switch self {
            case .ui: "UI"
            case .networking: "networking"
            case .persistence: "persistence"
            case .authentication: "authentication"
            case .payments: "payments"
            case .analytics: "analytics"
            case .concurrency: "concurrency"
            case .media: "media"
            case .navigation: "navigation"
            case .testing: "testing"
            }
        }
    }

    public static let concepts: [Concept] = [
        Concept(name: "authentication", terms: ["auth", "authentication", "authenticate", "authenticator", "login", "logout", "signin", "signout", "signup", "sign", "session", "token", "credential", "credentials", "password", "passcode", "oauth", "jwt", "keychain", "biometric", "faceid", "touchid", "identity", "account", "user", "otp", "mfa", "sso", "apple", "firebaseauth"], concern: .authentication),
        Concept(name: "payments", terms: ["purchase", "purchases", "payment", "payments", "pay", "paywall", "checkout", "billing", "invoice", "subscription", "subscriptions", "storekit", "iap", "transaction", "receipt", "price", "pricing", "product", "products", "cart", "order", "orders", "stripe", "revenuecat", "entitlement", "premium", "pro", "trial"], concern: .payments),
        Concept(name: "networking", terms: ["network", "networking", "api", "http", "https", "request", "response", "client", "endpoint", "fetch", "url", "urlsession", "rest", "graphql", "websocket", "socket", "download", "upload", "alamofire", "axios", "requests", "server", "route", "router", "service"], concern: .networking),
        Concept(name: "persistence", terms: ["persistence", "persist", "database", "db", "storage", "store", "cache", "caching", "coredata", "swiftdata", "realm", "sqlite", "sql", "repository", "dao", "model", "models", "entity", "migration", "userdefaults", "defaults", "file", "disk", "save", "load", "orm", "query", "table"], concern: .persistence),
        Concept(name: "ui", terms: ["view", "views", "screen", "screens", "page", "component", "components", "widget", "button", "cell", "layout", "ui", "swiftui", "uikit", "appkit", "controller", "viewcontroller", "render", "style", "theme", "color", "font", "animation", "sheet", "modal", "dialog", "list", "form", "react", "jsx", "template"], concern: .ui),
        Concept(name: "navigation", terms: ["navigation", "navigate", "router", "routing", "route", "coordinator", "flow", "tab", "tabs", "deeplink", "link", "path", "stack"], concern: .navigation),
        Concept(name: "onboarding", terms: ["onboarding", "onboard", "welcome", "intro", "introduction", "tutorial", "walkthrough", "getstarted", "started", "signup", "setup", "firstlaunch", "permissions", "paywall"], concern: nil),
        Concept(name: "settings", terms: ["settings", "setting", "preferences", "preference", "prefs", "config", "configuration", "options", "toggle", "defaults", "profile"], concern: nil),
        Concept(name: "notifications", terms: ["notification", "notifications", "push", "apns", "fcm", "alert", "reminder", "badge", "remote", "local"], concern: nil),
        Concept(name: "analytics", terms: ["analytics", "tracking", "track", "tracker", "telemetry", "event", "events", "metric", "metrics", "log", "logging", "logger", "amplitude", "mixpanel", "firebase", "segment", "crashlytics", "sentry"], concern: .analytics),
        Concept(name: "search", terms: ["search", "query", "filter", "find", "lookup", "index", "results", "match", "autocomplete", "suggest", "suggestion"], concern: nil),
        Concept(name: "media", terms: ["image", "images", "photo", "photos", "picture", "camera", "video", "audio", "media", "thumbnail", "render", "renderer", "generate", "generation", "canvas", "draw", "drawing", "pdf", "avfoundation", "player", "gallery"], concern: .media),
        Concept(name: "ai", terms: ["ai", "llm", "gpt", "openai", "claude", "anthropic", "model", "prompt", "completion", "chat", "assistant", "embedding", "inference", "ml", "coreml", "vision", "generate", "generation"], concern: nil),
        Concept(name: "travel", terms: ["trip", "trips", "itinerary", "travel", "journey", "destination", "flight", "hotel", "booking", "plan", "planner", "planning", "route", "map", "location", "place", "places", "poi"], concern: nil),
        Concept(name: "location", terms: ["location", "map", "maps", "mapkit", "geo", "gps", "coordinate", "coordinates", "corelocation", "region", "address", "geocode", "places"], concern: nil),
        Concept(name: "concurrency", terms: ["async", "await", "actor", "task", "thread", "queue", "dispatch", "concurrency", "combine", "publisher", "observable", "stream", "worker", "background", "operation"], concern: .concurrency),
        Concept(name: "errors", terms: ["error", "errors", "exception", "failure", "fail", "retry", "fallback", "crash", "recover", "handler"], concern: nil),
        Concept(name: "testing", terms: ["test", "tests", "testing", "spec", "mock", "mocks", "stub", "fixture", "fixtures", "xctest", "pytest", "jest", "vitest", "snapshot"], concern: .testing),
        Concept(name: "messaging", terms: ["message", "messages", "messaging", "chat", "conversation", "inbox", "thread", "email", "mail", "sms", "send", "reply"], concern: nil),
        Concept(name: "social", terms: ["friend", "friends", "follow", "follower", "feed", "post", "posts", "comment", "comments", "like", "likes", "share", "profile", "social"], concern: nil),
        Concept(name: "localization", terms: ["localization", "localize", "localized", "l10n", "i18n", "translation", "locale", "language", "strings"], concern: nil),
        Concept(name: "security", terms: ["security", "encrypt", "encryption", "decrypt", "crypto", "hash", "secret", "secrets", "key", "keys", "certificate", "permission", "permissions", "privacy", "sanitize", "validate", "validation"], concern: nil),
        Concept(name: "scheduling", terms: ["schedule", "scheduler", "calendar", "date", "dates", "time", "timer", "cron", "event", "events", "reminder", "booking", "availability"], concern: nil),
        Concept(name: "health", terms: ["health", "healthkit", "workout", "workouts", "exercise", "fitness", "steps", "heart", "sleep", "nutrition", "calories"], concern: nil),
        Concept(name: "finance", terms: ["finance", "financial", "money", "currency", "price", "stock", "stocks", "portfolio", "invest", "investing", "investment", "budget", "expense", "transaction", "balance", "account"], concern: nil),
        Concept(name: "dependency injection", terms: ["di", "dependency", "dependencies", "container", "resolver", "inject", "injection", "factory", "environment", "provider", "assembly"], concern: nil),
        Concept(name: "state management", terms: ["state", "store", "reducer", "reducers", "action", "actions", "redux", "dispatch", "selector", "slice", "observable", "viewmodel", "binding", "published"], concern: nil),
        Concept(name: "build", terms: ["build", "config", "configuration", "webpack", "vite", "babel", "tsconfig", "package", "manifest", "script", "scripts", "ci", "deploy", "fastlane", "makefile"], concern: nil),
    ]

    /// Single-word synonyms that should map onto each other in either direction.
    public static let synonyms: [String: [String]] = [
        "login": ["signin", "sign", "auth", "authenticate", "session", "credential"],
        "logout": ["signout", "session", "auth"],
        "signup": ["register", "registration", "create", "account", "onboarding"],
        "register": ["signup", "registration"],
        "auth": ["authentication", "authenticate", "login", "session", "token", "credential"],
        "authentication": ["auth", "login", "session", "token", "credential", "signin"],
        "authorization": ["auth", "permission", "role", "access", "token"],
        "user": ["account", "profile", "member", "customer"],
        "purchase": ["payment", "checkout", "subscription", "storekit", "transaction", "buy", "iap", "paywall"],
        "purchases": ["payment", "checkout", "subscription", "storekit", "transaction", "paywall"],
        "buy": ["purchase", "checkout", "payment"],
        "pay": ["payment", "checkout", "billing"],
        "subscription": ["purchase", "paywall", "storekit", "entitlement", "premium", "billing"],
        "image": ["photo", "picture", "thumbnail", "render", "graphics", "media"],
        "images": ["image", "photo", "picture", "thumbnail"],
        "photo": ["image", "picture", "camera"],
        "generate": ["generator", "generation", "create", "build", "make", "render"],
        "generating": ["generate", "generator", "generation"],
        "create": ["new", "make", "add", "build", "generate"],
        "creating": ["create", "new", "make", "add", "build"],
        "delete": ["remove", "destroy", "clear"],
        "remove": ["delete", "clear"],
        "update": ["edit", "modify", "change", "save"],
        "save": ["persist", "store", "write", "update"],
        "load": ["fetch", "read", "get", "restore"],
        "fetch": ["load", "request", "download", "get", "api", "list"],
        "send": ["post", "submit", "create", "publish", "deliver", "reply"],
        "network": ["api", "http", "request", "client", "fetch"],
        "api": ["client", "endpoint", "request", "network", "service"],
        "database": ["db", "storage", "persistence", "store", "repository", "sql"],
        "storage": ["store", "persistence", "database", "cache", "disk"],
        "cache": ["caching", "store", "memo", "storage"],
        "settings": ["preferences", "config", "configuration", "options"],
        "preferences": ["settings", "defaults", "config"],
        "config": ["configuration", "settings", "environment"],
        "notification": ["push", "alert", "apns", "reminder"],
        "notifications": ["notification", "push", "alert", "reminder"],
        "trip": ["itinerary", "travel", "journey", "plan"],
        "trips": ["trip", "itinerary", "travel"],
        "itinerary": ["trip", "plan", "schedule", "day", "travel"],
        "onboarding": ["welcome", "intro", "tutorial", "walkthrough", "getstarted"],
        "error": ["failure", "exception", "fail"],
        "errors": ["error", "failure", "exception"],
        "test": ["tests", "spec", "xctest"],
        "tests": ["test", "spec", "xctest"],
        "map": ["mapkit", "location", "annotation", "region"],
        "chat": ["message", "conversation", "assistant"],
        "search": ["query", "filter", "find", "lookup"],
        "navigation": ["router", "coordinator", "route", "navigate"],
        "routing": ["router", "route", "navigation"],
        "start": ["launch", "boot", "main", "init", "startup"],
        "startup": ["launch", "main", "app", "init", "boot"],
        "entry": ["main", "app", "launch", "index"],
        "render": ["draw", "view", "display", "renderer"],
        "parse": ["parser", "decode", "parsing", "deserialize"],
        "parsing": ["parse", "parser", "decode"],
        "serialize": ["encode", "codable", "json"],
        "decode": ["parse", "decoder", "codable", "json"],
        "analytics": ["tracking", "event", "telemetry", "track"],
        "logging": ["log", "logger", "os_log"],
        "permissions": ["permission", "authorization", "privacy", "access"],
        "location": ["gps", "corelocation", "coordinate", "map"],
        "email": ["mail", "message"],
        "upload": ["file", "storage", "send"],
        "download": ["fetch", "file", "cache"],
        "schedule": ["scheduler", "calendar", "timer", "cron"],
        "workout": ["exercise", "fitness", "training", "session"],
        "stock": ["ticker", "quote", "market", "portfolio"],
    ]

    /// Expands a set of query words with lexicon synonyms and concept terms.
    /// Returns weighted terms; original words weigh 1.0, synonyms 0.6, concept neighbours 0.35.
    public static func expand(_ words: [String]) -> [String: Double] {
        var weights: [String: Double] = [:]
        func add(_ term: String, _ weight: Double) {
            let key = term.lowercased()
            weights[key] = max(weights[key] ?? 0, weight)
        }
        for word in words {
            add(word, 1.0)
            let stemmed = Tokenizer.stem(word)
            if stemmed != word { add(stemmed, 0.9) }
            for synonym in synonyms[word] ?? synonyms[stemmed] ?? [] { add(synonym, 0.6) }
            for concept in concepts where concept.name == word || concept.terms.prefix(6).contains(word) {
                for term in concept.terms.prefix(12) { add(term, 0.35) }
            }
        }
        return weights
    }

    // MARK: - Phrases

    /// A multi-word expression that means more than its words ("at rest" is about encryption, not REST). Phrases
    /// are matched on the question's words before tokenising; the words they cover do not trigger concepts.
    public struct Phrase: Sendable {
        /// Lowercase words; the last may also match its plural (`purchase` matches `purchases`).
        public let words: [String]
        /// How results name the phrase (`at rest`, `in-app purchases`).
        public let label: String
        /// Identifier words the phrase stands for, searched at a high weight.
        public let terms: [String]
        /// Frameworks the phrase implies (`StoreKit` for in-app purchases).
        public let frameworks: [String]
        /// Phrase words that stay search words (`premium`, `access`); the others go (`rest`, `in`, `app`).
        public let keptWords: [String]
        /// The question asks how something flows through the code ("the code path that writes").
        public let isFlow: Bool

        public init(_ text: String, label: String? = nil, terms: [String] = [], frameworks: [String] = [], keep: [String] = [], flow: Bool = false) {
            words = text.split(separator: " ").map(String.init)
            self.label = label ?? text
            self.terms = terms
            self.frameworks = frameworks
            keptWords = keep
            isFlow = flow
        }
    }

    static let atRestTerms = ["encrypt", "encryption", "encrypted", "decrypt", "keychain", "safestorage", "secret", "crypto", "cipher"]

    /// Curated phrases, longest first within a shared first word. Kept small: each entry is covered by a golden
    /// question or a test, and English only.
    public static let phrases: [Phrase] = [
        Phrase("at rest", terms: atRestTerms),
        Phrase("protected", label: "protected", terms: atRestTerms),
        Phrase("secure storage", terms: atRestTerms, keep: ["storage"]),
        Phrase("securely stored", label: "secure storage", terms: atRestTerms),
        Phrase("in app purchase", label: "in-app purchases", terms: ["storekit", "iap", "purchase", "transaction", "product", "subscription"], frameworks: ["StoreKit"], keep: ["purchase", "purchases"]),
        Phrase("premium access", terms: ["entitlement", "entitlements", "subscribed", "premium", "paywall", "gate", "unlocked"], keep: ["premium", "access"]),
        Phrase("on disk", label: "on disk", terms: ["file", "write", "fsync", "persist", "flush", "disk"], keep: ["disk"]),
        Phrase("to disk", label: "on disk", terms: ["file", "write", "fsync", "persist", "flush", "disk"], keep: ["disk"]),
        Phrase("file format", terms: ["format", "header", "footer", "encode", "decode", "magic", "version", "layout"], keep: ["format"]),
        Phrase("code path", flow: true),
        Phrase("write path", terms: ["write"], keep: ["write"], flow: true),
        Phrase("commit path", terms: ["commit"], keep: ["commit"], flow: true),
        Phrase("data flow", flow: true),
        Phrase("sign in", label: "sign-in", terms: ["signin", "login", "auth", "authentication", "session", "credential"], keep: ["sign"]),
        Phrase("log in", label: "sign-in", terms: ["signin", "login", "auth", "authentication", "session", "credential"]),
        Phrase("push notification", label: "push notifications", terms: ["push", "notification", "apns", "remote", "token"], keep: ["push", "notification", "notifications"]),
        Phrase("deep link", label: "deep links", terms: ["deeplink", "url", "link", "route", "open"], keep: ["deep", "link", "links"]),
        Phrase("app group", label: "app groups", terms: ["appgroup", "suite", "container", "shared", "group"], keep: ["group", "groups"]),
        Phrase("private key", terms: ["privatekey", "key", "pem", "secret"], keep: ["key"]),
        Phrase("api key", label: "API key", terms: ["apikey", "key", "token", "secret"], keep: ["key"]),
        Phrase("user defaults", terms: ["userdefaults", "defaults", "preferences"], keep: ["defaults"]),
    ]

    /// Question scaffolding that names no feature: "list the key files and the main types and functions
    /// involved". Removed before tokenising, longest first, so "private key" or "main thread" survive.
    public static let metaPhrases: [[String]] = [
        "list the key files and the main types and functions involved",
        "list the key files and functions",
        "list the key files and the main types",
        "list the key files",
        "the key files and the main types and functions involved",
        "the main types and functions involved",
        "main types and functions involved",
        "the main types and functions",
        "types and functions involved",
        "types and functions",
        "files and functions",
        "files and types",
        "key files",
        "the main types",
        "identify the files that define",
        "identify the files that",
        "identify the files",
        "identify the",
        "the files that define",
        "list each",
        "list every",
        "list all",
        "list the",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Classifies identifier/path words into health concerns.
    public static func concerns(for words: some Sequence<String>) -> [Concern: Int] {
        var result: [Concern: Int] = [:]
        let index = concernIndex
        for word in words {
            if let concern = index[word] { result[concern, default: 0] += 1 }
        }
        return result
    }

    /// Strong, low-ambiguity words per concern (subset of concept terms).
    private static let concernIndex: [String: Concern] = {
        var map: [String: Concern] = [:]
        let strong: [Concern: [String]] = [
            .ui: ["view", "views", "screen", "swiftui", "uikit", "appkit", "button", "cell", "layout", "viewcontroller", "jsx", "component", "widget"],
            .networking: ["urlsession", "http", "https", "endpoint", "request", "response", "websocket", "alamofire", "axios", "graphql", "api"],
            .persistence: ["coredata", "swiftdata", "realm", "sqlite", "database", "userdefaults", "persistence", "migration", "dao", "orm"],
            .authentication: ["auth", "authentication", "login", "logout", "signin", "password", "credential", "oauth", "jwt", "keychain"],
            .payments: ["storekit", "purchase", "payment", "checkout", "subscription", "billing", "paywall", "receipt", "stripe", "revenuecat"],
            .analytics: ["analytics", "telemetry", "tracking", "mixpanel", "amplitude", "crashlytics", "sentry"],
            .media: ["avfoundation", "camera", "photo", "video", "audio", "thumbnail", "image"],
            .navigation: ["coordinator", "router", "navigation", "deeplink"],
        ]
        for (concern, words) in strong {
            for word in words { map[word] = concern }
        }
        return map
    }()
}
