import Foundation
import VesaliusCore

/// Static knowledge about external modules: which concern they belong to and their human names.
enum Catalog {
    typealias Concern = ConceptLexicon.Concern

    /// External module (lowercased, top-level) → concern.
    static let importConcerns: [String: Concern] = {
        var map: [String: Concern] = [:]
        let table: [Concern: [String]] = [
            .ui: [
                "swiftui", "uikit", "appkit", "watchkit", "widgetkit", "react", "react-dom", "react-native", "vue", "svelte",
                "@angular/core", "solid-js", "preact", "tkinter", "pyqt5", "pyqt6", "pyside6", "kivy", "streamlit",
                "react-router", "react-router-dom", "@react-navigation/native", "expo-router",
            ],
            .networking: [
                "alamofire", "moya", "axios", "requests", "httpx", "aiohttp", "urllib3", "network", "apollo", "@apollo/client",
                "graphql-request", "socket.io-client", "ws", "got", "node-fetch", "superagent", "grpc", "@grpc/grpc-js",
                "starscream", "ky", "swr", "@tanstack/react-query", "urlsession", "websockets",
            ],
            .persistence: [
                "coredata", "swiftdata", "grdb", "realmswift", "realm", "sqlite3", "sqlite", "sqlalchemy", "prisma",
                "@prisma/client", "mongoose", "typeorm", "sequelize", "knex", "pg", "mysql", "mysql2", "redis", "ioredis",
                "pymongo", "psycopg2", "peewee", "firebasefirestore", "firebasedatabase", "cloudkit", "drizzle-orm",
                "better-sqlite3", "dexie", "idb", "localforage", "tortoise", "motor", "sqlmodel",
            ],
            .payments: [
                "storekit", "revenuecat", "revenuecatui", "stripe", "@stripe/stripe-js", "@stripe/react-stripe-js", "braintree",
                "purchases", "react-native-purchases", "adapty", "qonversion", "superwallkit",
            ],
            .analytics: [
                "firebaseanalytics", "mixpanel", "amplitude", "amplitude-js", "@amplitude/analytics-browser", "segment",
                "analytics-node", "posthog-js", "posthog", "firebasecrashlytics", "sentry", "@sentry/react", "@sentry/node",
                "@sentry/nextjs", "telemetrydeck", "datadog", "@vercel/analytics", "appsflyerlib", "branch",
            ],
            .media: [
                "avfoundation", "avkit", "photos", "photosui", "coreimage", "imageio", "pil", "cv2", "sharp", "ffmpeg",
                "visionkit", "pdfkit", "scenekit", "realitykit", "metalkit", "coreaudio", "audiotoolbox", "moviepy",
            ],
            .authentication: [
                "authenticationservices", "localauthentication", "firebaseauth", "next-auth", "passport", "jsonwebtoken", "jwt",
                "pyjwt", "oauthlib", "auth0", "@auth0/auth0-react", "googlesignin", "msal", "@clerk/nextjs", "@supabase/auth-js",
                "bcrypt", "argon2", "keychainaccess",
            ],
        ]
        for (concern, names) in table {
            for name in names { map[name] = concern }
        }
        return map
    }()

    /// Concerns that count towards "mixed responsibilities". Testing and concurrency are cross-cutting;
    /// navigation is folded into UI.
    static func normalized(_ concern: Concern) -> Concern? {
        switch concern {
        case .testing, .concurrency: nil
        case .navigation: .ui
        default: concern
        }
    }

    /// UI frameworks: used for UI-coupling checks in extraction suggestions.
    static let uiModules: Set<String> = [
        "swiftui", "uikit", "appkit", "watchkit", "react", "react-dom", "react-native", "vue", "svelte", "@angular/core",
        "solid-js", "preact", "tkinter", "pyqt5", "pyqt6", "pyside6", "kivy", "streamlit",
    ]

    /// External module / manifest dependency (lowercased) → human framework name.
    static let frameworkNames: [String: String] = [
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
    ]

    /// Directory names that are pure architectural layers rather than features.
    static let layerDirectoryNames: Set<String> = [
        "views", "view", "ui", "screens", "screen", "pages", "components", "presentation", "scenes", "widgets",
        "viewcontrollers", "controllers", "viewmodels", "viewmodel", "presenters", "domain", "usecases", "usecase",
        "entities", "interactors", "data", "repositories", "repository", "persistence", "storage", "database", "db",
        "stores", "services", "service", "api", "network", "networking", "clients", "client", "providers", "models",
        "model", "schemas", "types", "dto", "dtos", "utils", "util", "utilities", "helpers", "helper", "common", "shared",
        "extensions", "misc", "lib", "support", "core", "resources", "assets", "config", "configuration", "tests", "test",
        "routes", "router", "hooks", "store", "reducers", "actions", "slices", "middleware", "templates", "styles",
        "coordinators", "managers", "protocols", "interfaces", "mocks", "fixtures", "constants",
    ]

    /// Names of directories/files that typically collect unrelated helpers.
    static let utilityNames: Set<String> = [
        "utils", "util", "utilities", "utility", "helpers", "helper", "common", "misc", "miscellaneous", "shared",
        "extensions", "extension", "globals", "global", "tools", "stuff", "functions",
    ]

    /// Directory names whose children are features/modules/packages.
    static let containerNames: Set<String> = [
        "features", "feature", "modules", "module", "packages", "apps", "libs", "sources", "src", "plugins",
        "services", "microservices", "domains", "screens", "scenes", "flows",
    ]

    /// Generic file-name words that never identify a feature.
    static let genericWords: Set<String> = [
        "view", "views", "model", "models", "viewmodel", "controller", "controllers", "service", "services", "manager",
        "managers", "store", "repository", "repo", "helper", "helpers", "util", "utils", "test", "tests", "spec", "cell",
        "screen", "page", "component", "provider", "client", "api", "protocol", "protocols", "type", "types", "extension",
        "extensions", "impl", "base", "default", "app", "main", "index", "data", "info", "item", "items", "list", "detail",
        "details", "row", "button", "builder", "factory", "handler", "config", "configuration", "constants", "mock",
        "mocks", "stub", "fixture", "error", "errors", "state", "action", "actions", "reducer", "feature", "router",
        "coordinator", "presenter", "interactor", "entity", "dto", "request", "response", "result", "results", "utility",
        "common", "shared", "core", "new", "edit", "create", "update", "delete", "card", "header", "footer", "sheet",
        "modal", "form", "field", "section", "container", "wrapper", "layout", "style", "styles", "theme", "icon",
        "image", "text", "label", "tab", "tabs", "nav", "navigation", "menu", "toolbar", "init", "setup", "context",
        "hook", "hooks", "use", "types", "schema", "schemas", "routes", "route", "middleware", "plugin", "module",
        "package", "lib", "src", "source", "sources", "kit", "ui", "for", "with", "and", "the", "of", "to", "from", "in",
    ]
}
