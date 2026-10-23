import Foundation

/// Frameworks by name and by the concept they implement, for question parsing and feature maps.
///
/// `names` is a copy of the HealthEngine catalog's human framework names (SemanticSearch cannot import
/// HealthEngine); `byConcept` adds which frameworks implement a concept, so "in-app purchases" seeds StoreKit and
/// "protected at rest" seeds the crypto modules. A repository's own `imports.external_name` values are merged in
/// by the caller.
public enum ConceptFrameworks {
    /// External module / manifest dependency (lowercased) → human framework name.
    public static let names: [String: String] = [
        "swiftui": "SwiftUI", "uikit": "UIKit", "appkit": "AppKit", "combine": "Combine", "swiftdata": "SwiftData",
        "coredata": "Core Data", "composablearchitecture": "The Composable Architecture",
        "swift-composable-architecture": "The Composable Architecture", "storekit": "StoreKit", "mapkit": "MapKit",
        "corelocation": "Core Location", "avfoundation": "AVFoundation", "foundationmodels": "Foundation Models",
        "coreml": "Core ML", "vision": "Vision", "healthkit": "HealthKit", "cloudkit": "CloudKit", "widgetkit": "WidgetKit",
        "appintents": "App Intents", "activitykit": "ActivityKit", "realmswift": "Realm", "grdb": "GRDB",
        "grdb.swift": "GRDB", "alamofire": "Alamofire", "kingfisher": "Kingfisher", "firebasecore": "Firebase",
        "firebaseanalytics": "Firebase", "firebaseauth": "Firebase", "firebasefirestore": "Firebase",
        "firebase-ios-sdk": "Firebase", "revenuecat": "RevenueCat", "revenuecatui": "RevenueCat",
        "purchases-ios": "RevenueCat", "sqlite3": "SQLite", "argumentparser": "Swift Argument Parser",
        "swift-argument-parser": "Swift Argument Parser", "swiftsyntax": "SwiftSyntax", "swift-syntax": "SwiftSyntax",
        "swiftparser": "SwiftSyntax", "xctest": "XCTest", "testing": "Swift Testing", "rxswift": "RxSwift",
        "swinject": "Swinject", "factory": "Factory", "dependencies": "Swift Dependencies",
        "swift-dependencies": "Swift Dependencies", "snapkit": "SnapKit", "lottie": "Lottie", "vapor": "Vapor",
        "react": "React", "react-dom": "React", "next": "Next.js", "vue": "Vue", "nuxt": "Nuxt", "svelte": "Svelte",
        "@sveltejs/kit": "SvelteKit", "@angular/core": "Angular", "express": "Express", "@nestjs/core": "NestJS",
        "@nestjs/common": "NestJS", "fastify": "Fastify", "koa": "Koa", "redux": "Redux", "@reduxjs/toolkit": "Redux",
        "react-redux": "Redux", "zustand": "Zustand", "mobx": "MobX", "@tanstack/react-query": "TanStack Query",
        "axios": "Axios", "prisma": "Prisma", "@prisma/client": "Prisma", "mongoose": "Mongoose", "typeorm": "TypeORM",
        "sequelize": "Sequelize", "graphql": "GraphQL", "@apollo/client": "Apollo", "jest": "Jest", "vitest": "Vitest",
        "tailwindcss": "Tailwind CSS", "electron": "Electron", "react-native": "React Native", "expo": "Expo",
        "three": "three.js", "d3": "D3", "socket.io": "Socket.IO", "zod": "Zod", "drizzle-orm": "Drizzle",
        "django": "Django", "flask": "Flask", "fastapi": "FastAPI", "sqlalchemy": "SQLAlchemy", "pydantic": "Pydantic",
        "celery": "Celery", "numpy": "NumPy", "pandas": "pandas", "torch": "PyTorch", "tensorflow": "TensorFlow",
        "pytest": "pytest", "requests": "Requests", "httpx": "HTTPX", "aiohttp": "aiohttp", "scipy": "SciPy",
        "sklearn": "scikit-learn", "scikit-learn": "scikit-learn", "matplotlib": "Matplotlib", "streamlit": "Streamlit",
        "langchain": "LangChain", "openai": "OpenAI SDK", "anthropic": "Anthropic SDK", "starlette": "Starlette",
        "uvicorn": "Uvicorn", "click": "Click", "typer": "Typer",
        // Additions for concept seeding.
        "cryptokit": "CryptoKit", "security": "Security", "localauthentication": "LocalAuthentication",
        "authenticationservices": "AuthenticationServices", "keychainaccess": "KeychainAccess",
        "usernotifications": "UserNotifications", "crypto": "node:crypto", "node:crypto": "node:crypto",
        "better-sqlite3": "better-sqlite3", "stripe": "Stripe", "watchconnectivity": "WatchConnectivity",
    ]

    /// Modules (lowercased) that implement a concept, by `ConceptLexicon` concept name or phrase label. A question
    /// about the concept seeds whichever of them the repository imports.
    public static let byConcept: [String: [String]] = [
        "payments": [
            "storekit", "revenuecat", "revenuecatui", "purchases-ios", "stripe", "@stripe/stripe-js", "@stripe/react-stripe-js",
            "braintree", "purchases", "react-native-purchases", "adapty", "qonversion", "superwallkit",
        ],
        "in-app purchases": ["storekit", "revenuecat", "revenuecatui", "purchases-ios", "react-native-purchases", "adapty", "qonversion", "superwallkit"],
        "security": ["cryptokit", "security", "commoncrypto", "crypto", "node:crypto", "keychainaccess", "bcrypt", "argon2", "localauthentication"],
        "at rest": ["cryptokit", "security", "commoncrypto", "crypto", "node:crypto", "keychainaccess"],
        "protected": ["cryptokit", "security", "commoncrypto", "crypto", "node:crypto", "keychainaccess"],
        "secure storage": ["cryptokit", "security", "keychainaccess"],
        "authentication": [
            "authenticationservices", "localauthentication", "firebaseauth", "next-auth", "passport", "jsonwebtoken", "jwt",
            "pyjwt", "oauthlib", "auth0", "@auth0/auth0-react", "googlesignin", "msal", "@clerk/nextjs", "@supabase/auth-js",
            "keychainaccess",
        ],
        "persistence": [
            "coredata", "swiftdata", "grdb", "realmswift", "realm", "sqlite3", "sqlite", "sqlalchemy", "prisma",
            "@prisma/client", "mongoose", "typeorm", "sequelize", "knex", "pg", "mysql", "mysql2", "redis", "ioredis",
            "pymongo", "psycopg2", "peewee", "firebasefirestore", "firebasedatabase", "cloudkit", "drizzle-orm",
            "better-sqlite3", "dexie", "idb", "localforage", "sqlmodel",
        ],
        "analytics": [
            "firebaseanalytics", "mixpanel", "amplitude", "amplitude-js", "@amplitude/analytics-browser", "segment",
            "analytics-node", "posthog-js", "posthog", "firebasecrashlytics", "sentry", "@sentry/react", "@sentry/node",
            "@sentry/nextjs", "telemetrydeck", "datadog", "@vercel/analytics", "appsflyerlib", "branch",
        ],
        "notifications": ["usernotifications", "firebasemessaging", "onesignal"],
        "push notifications": ["usernotifications", "firebasemessaging", "onesignal"],
        "location": ["corelocation", "mapkit"],
        "health": ["healthkit"],
        "media": ["avfoundation", "avkit", "photos", "photosui", "coreimage", "imageio", "visionkit", "pdfkit"],
    ]

    /// Lowercase module names that are also everyday words (`testing`, `vision`, `next`, `path`): a question names
    /// them only when written as a proper name (`Vision`, `Next.js`).
    static let ambiguousNames: Set<String> = [
        "testing", "vision", "next", "react", "factory", "dependencies", "click", "three", "express", "requests",
        "security", "combine", "crypto", "path", "fs", "os", "re", "json", "memory", "thread", "utility", "atomic",
        "sys", "bits", "glob", "http", "ai", "notify", "signal", "sanitizer", "photos", "metadata", "name", "model",
        "string", "math", "time", "date", "data", "events", "url", "util", "zlib", "net", "stream", "process",
    ]

    /// The display name of a module (`storekit` → `StoreKit`), or the module itself.
    public static func displayName(_ module: String) -> String {
        names[module.lowercased()] ?? module
    }

    /// Whether `token`, as written in a question, names the framework `module`: an exact case-insensitive match
    /// that is not an everyday word written in lower case (`StoreKit`, `storekit`, `SwiftData`, but not `testing`).
    public static func token(_ token: String, names module: String) -> Bool {
        guard token.caseInsensitiveCompare(module) == .orderedSame || token.caseInsensitiveCompare(displayName(module)) == .orderedSame else { return false }
        let lower = token.lowercased()
        if !ambiguousNames.contains(lower) { return true }
        // An everyday word counts only when capitalised past its first letter or written with punctuation.
        return token.dropFirst().contains { $0.isUppercase } || token.contains { !$0.isLetter && !$0.isNumber }
    }

    /// Modules that implement a concept or phrase (lowercased), from `byConcept`.
    public static func modules(forConcept concept: String) -> [String] {
        byConcept[concept.lowercased()] ?? []
    }
}
