import Foundation
import VesaliusCore

/// Infers architectural patterns from names, directories, imports, attributes and dependency
/// directions. Every pattern carries the evidence it was derived from; confidence is a weighted sum of
/// independent signals, never a certainty.
enum ArchitectureInferrer {
    enum Role: String, CaseIterable {
        case view, viewModel, controller, presenter, interactor, router, coordinator, service, repository,
             useCase, entity, reducer, store, model, container, manager, client
    }

    struct Facts {
        var roleFiles: [Role: [Int64]] = [:]
        var roleTypes: [Role: [String]] = [:]
        var fileRoles: [Int64: Set<Role>] = [:]
        var importFiles: [String: Int] = [:]
        var manifest: Set<String> = []
        var directoryNames: [String: Int] = [:]
        var attributeCounts: [String: Int] = [:]
        var observableViewModels = 0
        var swiftUIViews = 0
        var reducerAttributed: [String] = []

        func files(_ role: Role) -> [Int64] { roleFiles[role] ?? [] }
        func types(_ role: Role) -> [String] { roleTypes[role] ?? [] }
        func imports(_ names: [String]) -> Int { names.reduce(0) { $0 + (importFiles[$1] ?? 0) } }
        func hasDependency(_ names: [String]) -> Bool { names.contains { manifest.contains($0) } }
        func directories(_ names: [String]) -> Int { names.reduce(0) { $0 + (directoryNames[$1] ?? 0) } }
    }

    static func infer(_ ctx: HealthContext, violations: Int) -> ArchitectureReport {
        let facts = collect(ctx)
        var patterns: [ArchitecturePattern] = []
        func add(_ name: String, _ confidence: Double, _ evidence: [String], _ paths: [Int64] = []) {
            let clamped = min(1, max(0, confidence))
            guard clamped >= 0.25, !evidence.isEmpty else { return }
            let examples = Array(Set(paths)).map { ctx.path($0) }.sorted().prefix(5)
            patterns.append(ArchitecturePattern(name: name, confidence: (clamped * 100).rounded() / 100, evidence: evidence, paths: examples.isEmpty ? nil : Array(examples)))
        }
        let pairCount = rolePairCounter(ctx, facts)

        // MVVM
        let viewModels = facts.types(.viewModel)
        if !viewModels.isEmpty {
            let viewToVM = pairCount([.view, .controller], [.viewModel])
            let vmToService = pairCount([.viewModel], [.service, .repository, .client, .useCase, .manager, .store])
            var evidence = ["\(Format.plural(viewModels.count, "type")) end in ViewModel (e.g. \(Format.list(Array(viewModels.prefix(3)), limit: 3)))"]
            if viewToVM > 0 { evidence.append("\(Format.plural(viewToVM, "view-to-view-model dependency", "view-to-view-model dependencies"))") }
            if vmToService > 0 { evidence.append("View models depend on services/repositories in \(Format.plural(vmToService, "place"))") }
            if facts.observableViewModels > 0 { evidence.append("\(Format.plural(facts.observableViewModels, "view model")) are observable (@Observable / ObservableObject)") }
            let confidence = 0.35 * min(1, Double(viewModels.count) / 3)
                + 0.3 * min(1, Double(viewToVM) / Double(max(1, viewModels.count)))
                + 0.2 * (vmToService > 0 ? 1 : 0)
                + 0.15 * (facts.observableViewModels > 0 ? 1 : 0)
            add("MVVM", confidence, evidence, facts.files(.viewModel))
        }

        // MVC
        let controllers = facts.types(.controller)
        let controllerDirs = facts.directories(["controllers"])
        if !controllers.isEmpty || controllerDirs > 0 {
            var evidence: [String] = []
            if !controllers.isEmpty { evidence.append("\(Format.plural(controllers.count, "controller type")) (e.g. \(Format.list(Array(controllers.prefix(3)), limit: 3)))") }
            if controllerDirs > 0 { evidence.append("controllers/ directories present") }
            let models = facts.types(.model).count + facts.directories(["models", "model"])
            if models > 0 { evidence.append("\(Format.plural(facts.types(.model).count, "model type")) and \(Format.plural(facts.directories(["models", "model"]), "models/ directory", "models/ directories"))") }
            let views = facts.files(.view).count + facts.directories(["views", "templates"])
            if views > 0 { evidence.append("\(Format.plural(facts.files(.view).count, "view file")) alongside the controllers") }
            let vmRatio = controllers.isEmpty ? 0 : Double(viewModels.count) / Double(controllers.count)
            let confidence = 0.4 * min(1, Double(controllers.count + controllerDirs * 3) / 4)
                + 0.2 * (models > 0 ? 1 : 0)
                + 0.2 * (views > 0 ? 1 : 0)
                + 0.2 * max(0, 1 - vmRatio)
            add("MVC", confidence, evidence, facts.files(.controller))
        }

        // VIPER / MVP
        let presenters = facts.types(.presenter), interactors = facts.types(.interactor), routers = facts.types(.router)
        if !presenters.isEmpty && (!interactors.isEmpty || !routers.isEmpty) {
            var evidence = ["\(Format.plural(presenters.count, "Presenter")) type(s)"]
            if !interactors.isEmpty { evidence.append("\(Format.plural(interactors.count, "Interactor")) type(s)") }
            if !routers.isEmpty { evidence.append("\(Format.plural(routers.count, "Router/Wireframe")) type(s)") }
            if !facts.types(.entity).isEmpty { evidence.append("\(Format.plural(facts.types(.entity).count, "Entity")) type(s)") }
            let confidence = 0.3 + 0.25 * (interactors.isEmpty ? 0 : 1) + 0.25 * (routers.isEmpty ? 0 : 1) + 0.2 * min(1, Double(presenters.count) / 3)
            add("VIPER", confidence, evidence, facts.files(.presenter) + facts.files(.interactor))
        } else if presenters.count >= 2 {
            add("MVP", 0.3 + 0.5 * min(1, Double(presenters.count) / 5), ["\(Format.plural(presenters.count, "type")) end in Presenter (e.g. \(Format.list(Array(presenters.prefix(3)), limit: 3)))"], facts.files(.presenter))
        }

        // Clean Architecture
        do {
            var confidence = 0.0
            var evidence: [String] = []
            let layerDirs = ["domain", "data", "presentation"].filter { (facts.directoryNames[$0] ?? 0) > 0 }
            if !layerDirs.isEmpty {
                confidence += 0.2 * Double(layerDirs.count)
                evidence.append("Layer directories: \(layerDirs.map { $0.capitalized }.joined(separator: ", "))")
            }
            let useCases = facts.types(.useCase)
            if !useCases.isEmpty || facts.directories(["usecases", "usecase"]) > 0 {
                confidence += 0.25
                evidence.append("\(Format.plural(useCases.count, "use case type")) (e.g. \(Format.list(Array(useCases.prefix(3)), limit: 3)))")
            }
            let repositoryProtocols = ctx.snapshot.symbols.filter { ($0.kind == .protocol || $0.kind == .interface) && ($0.name.hasSuffix("Repository") || $0.name.hasSuffix("RepositoryProtocol") || $0.name.hasSuffix("RepositoryType")) }.count
            if repositoryProtocols > 0 {
                confidence += 0.15
                evidence.append("\(Format.plural(repositoryProtocols, "repository abstraction")) (protocols/interfaces)")
            }
            if !facts.types(.entity).isEmpty || facts.directories(["entities"]) > 0 {
                confidence += 0.1
                evidence.append("Entities defined separately")
            }
            if confidence > 0, layerDirs.contains("domain"), violations == 0 {
                confidence += 0.1
                evidence.append("No dependencies from inner layers back into presentation were found")
            }
            if confidence >= 0.35 { add("Clean Architecture", confidence, evidence, facts.files(.useCase)) }
        }

        // TCA
        do {
            let tcaImports = facts.imports(["composablearchitecture"])
            var confidence = 0.0
            var evidence: [String] = []
            if tcaImports > 0 {
                confidence += 0.5
                evidence.append("\(Format.plural(tcaImports, "file")) import ComposableArchitecture")
            }
            if !facts.reducerAttributed.isEmpty {
                confidence += 0.25
                evidence.append("\(Format.plural(facts.reducerAttributed.count, "@Reducer type")) (e.g. \(Format.list(Array(facts.reducerAttributed.prefix(3)), limit: 3)))")
            }
            let features = ctx.snapshot.symbols.filter { $0.kind.isType && ($0.name.hasSuffix("Feature") || $0.name.hasSuffix("Reducer")) }.count
            if features > 0 && tcaImports > 0 {
                confidence += 0.15
                evidence.append("\(Format.plural(features, "Feature/Reducer type"))")
            }
            if facts.hasDependency(["swift-composable-architecture"]) {
                confidence += 0.2
                evidence.append("Package dependency on swift-composable-architecture")
            }
            add("TCA (The Composable Architecture)", confidence, evidence, facts.files(.reducer))
        }

        // Redux-style
        do {
            let reduxImports = facts.imports(["redux", "@reduxjs/toolkit", "react-redux", "reswift", "zustand", "mobx", "vuex", "pinia", "@ngrx/store"])
            let dirs = ["reducers", "actions", "slices", "store"].filter { (facts.directoryNames[$0] ?? 0) > 0 }
            let reducers = facts.types(.reducer).count + ctx.snapshot.symbols.filter { $0.kind == .function && ($0.name.hasSuffix("Reducer") || $0.name.hasSuffix("Slice")) }.count
            var confidence = 0.0
            var evidence: [String] = []
            if reduxImports > 0 { confidence += 0.45; evidence.append("\(Format.plural(reduxImports, "file")) import a Redux/flux store library") }
            if !dirs.isEmpty { confidence += 0.15 * Double(dirs.count); evidence.append("Directories: \(dirs.joined(separator: ", "))") }
            if reducers > 0 && facts.imports(["composablearchitecture"]) == 0 { confidence += 0.2; evidence.append("\(Format.plural(reducers, "reducer/slice"))") }
            if facts.hasDependency(["redux", "@reduxjs/toolkit", "react-redux", "zustand"]) { confidence += 0.15; evidence.append("Store library in package.json") }
            if facts.imports(["composablearchitecture"]) == 0 { add("Redux-style state management", confidence, evidence, facts.files(.reducer) + facts.files(.store)) }
        }

        // Coordinator
        let coordinators = facts.types(.coordinator)
        if coordinators.count >= 2 || (coordinators.count == 1 && facts.directories(["coordinators"]) > 0) {
            let protocols = ctx.snapshot.symbols.filter { ($0.kind == .protocol || $0.kind == .interface) && $0.name.hasSuffix("Coordinator") }.count
            var evidence = ["\(Format.plural(coordinators.count, "Coordinator type")) (e.g. \(Format.list(Array(coordinators.prefix(3)), limit: 3)))"]
            if protocols > 0 { evidence.append("A shared Coordinator protocol") }
            add("Coordinator navigation", 0.4 + 0.1 * Double(min(3, coordinators.count)) + (protocols > 0 ? 0.2 : 0), evidence, facts.files(.coordinator))
        }

        // Repository pattern
        let repositories = facts.types(.repository)
        if !repositories.isEmpty {
            let abstractions = ctx.snapshot.symbols.filter { ($0.kind == .protocol || $0.kind == .interface) && $0.name.contains("Repository") }.count
            var evidence = ["\(Format.plural(repositories.count, "Repository type")) (e.g. \(Format.list(Array(repositories.prefix(3)), limit: 3)))"]
            if abstractions > 0 { evidence.append("\(Format.plural(abstractions, "repository protocol/interface", "repository protocols/interfaces"))") }
            add("Repository pattern", 0.4 + (abstractions > 0 ? 0.3 : 0) + (repositories.count >= 3 ? 0.3 : 0.1), evidence, facts.files(.repository))
        }

        // Service layer
        let services = facts.types(.service)
        if services.count >= 2 {
            let protocols = ctx.snapshot.symbols.filter { ($0.kind == .protocol || $0.kind == .interface) && ($0.name.hasSuffix("Service") || $0.name.hasSuffix("ServiceProtocol") || $0.name.hasSuffix("ServiceType")) }.count
            var evidence = ["\(Format.plural(services.count, "Service type")) (e.g. \(Format.list(Array(services.prefix(3)), limit: 3)))"]
            let serviceDirs = facts.directories(["services", "service"])
            if serviceDirs > 0 { evidence.append("services/ directories present") }
            if protocols > 0 { evidence.append("\(Format.plural(protocols, "service protocol/interface", "service protocols/interfaces"))") }
            add("Service layer", 0.4 + (serviceDirs > 0 ? 0.3 : 0) + (protocols > 0 ? 0.3 : 0), evidence, facts.files(.service))
        }

        // Dependency injection
        do {
            let containers = facts.types(.container)
            let diImports = facts.imports(["swinject", "resolver", "factory", "needle", "dependencies", "inversify", "tsyringe", "@nestjs/common", "injector", "dependency_injector", "typedi"])
            var confidence = 0.0
            var evidence: [String] = []
            if !containers.isEmpty { confidence += 0.45; evidence.append("Container types: \(Format.list(Array(containers.prefix(3)), limit: 3))") }
            if diImports > 0 { confidence += 0.45; evidence.append("\(Format.plural(diImports, "file")) import a dependency-injection library") }
            add("Dependency-injection container", confidence, evidence, facts.files(.container))
        }

        // Feature-based modularization
        do {
            var featureRoots: [String: Set<String>] = [:]
            var featureLayers: [String: Set<String>] = [:]
            for file in ctx.participating {
                let parts = file.directory.split(separator: "/").map(String.init)
                for (index, part) in parts.enumerated() where ["features", "feature", "modules", "scenes", "screens", "flows"].contains(part.lowercased()) && index + 1 < parts.count {
                    let root = parts[0...index].joined(separator: "/")
                    featureRoots[root, default: []].insert(parts[index + 1])
                    if let layer = ctx.layerOfFile[file.id] {
                        featureLayers[root + "/" + parts[index + 1], default: []].insert(layer)
                    }
                }
            }
            if let (root, features) = featureRoots.max(by: { $0.value.count == $1.value.count ? $0.key > $1.key : $0.value.count < $1.value.count }), features.count >= 2 {
                // Features with more than one layer inside are self-contained verticals.
                let mixed = features.filter { (featureLayers[root + "/" + $0]?.count ?? 0) >= 2 }.count
                var evidence = ["\(Format.plural(features.count, "feature folder")) under \(root)/ (\(Format.list(features.sorted(), limit: 4)))"]
                if mixed > 0 { evidence.append("\(Format.plural(mixed, "feature")) contain several layers (views, models, services) as vertical slices") }
                add("Feature-based modularization", 0.5 + 0.05 * Double(min(6, features.count)) + (mixed > 0 ? 0.2 : 0), evidence)
            }
        }

        // Layered
        do {
            var counts: [String: Int] = [:]
            for file in ctx.sourceFiles { if let layer = ctx.layerOfFile[file.id] { counts[layer, default: 0] += 1 } }
            let layers = counts.filter { $0.value >= 2 }.sorted { layerOrder($0.key) < layerOrder($1.key) }
            if layers.count >= 3 {
                let total = max(1, ctx.sourceFiles.count)
                let covered = layers.reduce(0) { $0 + $1.value }
                var evidence = ["Files group into \(layers.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))"]
                evidence.append("\(Format.percent(Double(covered) / Double(total))) of source files sit in a recognisable layer")
                if violations == 0 { evidence.append("Dependencies between layers point in one direction") } else { evidence.append("\(Format.plural(violations, "upward dependency", "upward dependencies")) between layers") }
                add("Layered architecture", 0.35 + 0.1 * Double(layers.count - 3) + 0.25 * Double(covered) / Double(total) + (violations == 0 ? 0.15 : 0), evidence)
            }
        }

        // Packages / monorepo
        do {
            let swiftTargets = ctx.snapshot.modules.filter { $0.kind == .swiftPackageTarget && !$0.rootPath.lowercased().hasPrefix("tests") && !$0.name.hasSuffix("Tests") }
            if swiftTargets.count >= 3 {
                add("Package-based modularization", 0.5 + 0.05 * Double(min(8, swiftTargets.count)), ["\(swiftTargets.count) Swift package targets (\(Format.list(swiftTargets.map(\.name).sorted(), limit: 5)))"])
            }
            let npm = ctx.snapshot.modules.filter { $0.kind == .npmPackage && !$0.rootPath.isEmpty }
            if npm.count >= 2 {
                add("Monorepo (workspace packages)", 0.55 + 0.05 * Double(min(8, npm.count)), ["\(npm.count) workspace packages (\(Format.list(npm.map(\.name).sorted(), limit: 5)))"])
            }
            let python = ctx.snapshot.modules.filter { $0.kind == .pythonPackage && $0.manifestPath != nil }
            if python.count >= 2 {
                add("Multi-package Python repository", 0.5 + 0.05 * Double(min(8, python.count)), ["\(python.count) Python distributions (\(Format.list(python.map(\.name).sorted(), limit: 5)))"])
            }
        }

        // Web stacks
        webStacks(ctx, facts, add)

        patterns.sort { $0.confidence == $1.confidence ? $0.name < $1.name : $0.confidence > $1.confidence }

        let frameworks = frameworks(facts)
        let layers = layers(ctx)
        let areas = areas(ctx)
        let entryPoints = entryPoints(ctx)
        let summary = summary(ctx, patterns: patterns, frameworks: frameworks, layers: layers, areas: areas)
        return ArchitectureReport(summary: summary, patterns: patterns, frameworks: frameworks, layers: layers, areas: areas, entryPoints: entryPoints)
    }

    // MARK: Facts

    static func roles(for symbol: RepositorySnapshot.Symbol) -> Set<Role> {
        guard symbol.kind.isType || symbol.kind == .component else { return [] }
        let name = symbol.name
        var roles = Set<Role>()
        if name.hasSuffix("ViewModel") { roles.insert(.viewModel) }
        else if name.hasSuffix("ViewController") || name.hasSuffix("Controller") { roles.insert(.controller) }
        else if name.hasSuffix("View") || name.hasSuffix("Screen") || name.hasSuffix("Page") || symbol.kind == .component || symbol.inheritedTypes.contains("View") { roles.insert(.view) }
        if name.hasSuffix("Presenter") { roles.insert(.presenter) }
        if name.hasSuffix("Interactor") { roles.insert(.interactor) }
        if name.hasSuffix("Router") || name.hasSuffix("Wireframe") { roles.insert(.router) }
        if name.hasSuffix("Coordinator") { roles.insert(.coordinator) }
        if name.hasSuffix("Service") || name.hasSuffix("ServiceProtocol") { roles.insert(.service) }
        if name.hasSuffix("Repository") || name.hasSuffix("Repo") || name.hasSuffix("RepositoryProtocol") { roles.insert(.repository) }
        if name.hasSuffix("UseCase") || name.hasSuffix("Usecase") || name.hasSuffix("UseCases") { roles.insert(.useCase) }
        if name.hasSuffix("Entity") { roles.insert(.entity) }
        if name.hasSuffix("Reducer") || symbol.attributes.contains("@Reducer") { roles.insert(.reducer) }
        if name.hasSuffix("Store") { roles.insert(.store) }
        if name.hasSuffix("Model") && !name.hasSuffix("ViewModel") { roles.insert(.model) }
        if ["Container", "Assembly", "Resolver", "DependencyContainer", "Injector", "DIContainer", "ServiceLocator", "CompositionRoot"].contains(where: { name.hasSuffix($0) }) { roles.insert(.container) }
        if name.hasSuffix("Manager") { roles.insert(.manager) }
        if name.hasSuffix("Client") || name.hasSuffix("APIClient") { roles.insert(.client) }
        return roles
    }

    static func collect(_ ctx: HealthContext) -> Facts {
        var facts = Facts()
        var typeSeen: [Role: Set<String>] = [:]
        for file in ctx.participating {
            var fileRoles = Set<Role>()
            for symbol in ctx.symbolsByFile[file.id] ?? [] {
                let roles = roles(for: symbol)
                fileRoles.formUnion(roles)
                for role in roles where !file.isTest {
                    if typeSeen[role, default: []].insert(symbol.name).inserted {
                        facts.roleTypes[role, default: []].append(symbol.name)
                    }
                }
                for attribute in symbol.attributes { facts.attributeCounts[attribute, default: 0] += 1 }
                if roles.contains(.viewModel) && (symbol.attributes.contains("@Observable") || symbol.inheritedTypes.contains("ObservableObject")) {
                    facts.observableViewModels += 1
                }
                if symbol.attributes.contains("@Reducer") { facts.reducerAttributed.append(symbol.name) }
            }
            let stem = file.stem
            if stem.hasSuffix("ViewModel") { fileRoles.insert(.viewModel) }
            else if stem.hasSuffix("View") || stem.hasSuffix("Screen") || stem.hasSuffix("Page") { fileRoles.insert(.view) }
            if file.isTest { continue }
            if !fileRoles.isEmpty {
                facts.fileRoles[file.id] = fileRoles
                for role in fileRoles { facts.roleFiles[role, default: []].append(file.id) }
            }
            for module in Set(file.externalImports.map { $0.lowercased() }) {
                facts.importFiles[module, default: 0] += 1
            }
        }
        // Count distinct directories per name (over unique directories of source files).
        var sourceDirectories = Set<Int>()
        for file in ctx.sourceFiles { sourceDirectories.insert(ctx.directoryIndex(of: file.id)) }
        var directories = Set<String>()
        for index in sourceDirectories where index >= 0 {
            var prefix = ""
            for part in ctx.directoryPaths[index].split(separator: "/") {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                directories.insert(prefix)
            }
        }
        for directory in directories {
            facts.directoryNames[(directory as NSString).lastPathComponent.lowercased(), default: 0] += 1
        }
        for key in facts.roleTypes.keys { facts.roleTypes[key]?.sort() }
        facts.manifest = Set(ctx.snapshot.manifestDependencies.map { $0.lowercased() })
        return facts
    }

    /// Counts file-level dependency pairs from files with any of `from` roles to files with any of `to` roles.
    static func rolePairCounter(_ ctx: HealthContext, _ facts: Facts) -> ([Role], [Role]) -> Int {
        return { from, to in
            var count = 0
            for entry in ctx.pairs {
                guard let sourceRoles = facts.fileRoles[entry.pair.source], let targetRoles = facts.fileRoles[entry.pair.target] else { continue }
                if from.contains(where: sourceRoles.contains) && to.contains(where: targetRoles.contains) { count += 1 }
            }
            return count
        }
    }

    // MARK: Web stacks

    private static func webStacks(_ ctx: HealthContext, _ facts: Facts, _ add: (String, Double, [String], [Int64]) -> Void) {
        let paths = ctx.participating.map(\.path)
        let nextImports = facts.imports(["next"]) + (facts.hasDependency(["next"]) ? 1 : 0)
        if nextImports > 0 {
            let appRouter = ctx.participating.filter { file in
                let parts = file.path.split(separator: "/")
                return parts.contains("app") && ["page", "layout", "route"].contains(file.stem)
            }
            let pagesRouter = ctx.participating.filter { file in
                file.path.split(separator: "/").dropLast().contains("pages") && (file.language == .typescript || file.language == .javascript)
            }
            if !appRouter.isEmpty {
                add("Next.js App Router", 0.6 + min(0.35, Double(appRouter.count) * 0.05), ["\(Format.plural(appRouter.count, "route file")) (page/layout/route) under app/", "Depends on next"], appRouter.map(\.id))
            } else if !pagesRouter.isEmpty {
                add("Next.js Pages Router", 0.6 + min(0.35, Double(pagesRouter.count) * 0.05), ["\(Format.plural(pagesRouter.count, "page")) under pages/", "Depends on next"], pagesRouter.map(\.id))
            }
        }
        let reactImports = facts.imports(["react", "react-dom", "react-native"])
        let components = ctx.snapshot.symbols.filter { $0.kind == .component }.count
        if reactImports >= 3 || components >= 3 {
            var evidence: [String] = []
            if reactImports > 0 { evidence.append("\(Format.plural(reactImports, "file")) import React") }
            if components > 0 { evidence.append("\(Format.plural(components, "component")) declared") }
            let componentDirs = facts.directories(["components"])
            if componentDirs > 0 { evidence.append("components/ directories present") }
            let hooks = ctx.snapshot.symbols.filter { $0.kind == .function && $0.name.hasPrefix("use") && $0.name.count > 3 && ($0.name.dropFirst(3).first?.isUppercase ?? false) }.count
            if hooks > 0 { evidence.append("\(Format.plural(hooks, "custom hook"))") }
            add("React component architecture", 0.4 + 0.2 * min(1, Double(components) / 10) + (componentDirs > 0 ? 0.2 : 0) + (hooks > 0 ? 0.15 : 0), evidence, [])
        }
        let expressImports = facts.imports(["express", "fastify", "koa"])
        if expressImports > 0 {
            let routeDirs = ["routes", "middleware", "controllers"].filter { (facts.directoryNames[$0] ?? 0) > 0 }
            add("Express-style HTTP service", 0.45 + 0.15 * Double(routeDirs.count) + min(0.15, Double(expressImports) * 0.03), ["\(Format.plural(expressImports, "file")) import express/fastify/koa"] + (routeDirs.isEmpty ? [] : ["Directories: \(routeDirs.joined(separator: ", "))"]), [])
        }
        let nest = facts.imports(["@nestjs/common", "@nestjs/core"])
        if nest > 0 {
            add("NestJS modules", 0.6 + min(0.3, Double(nest) * 0.03), ["\(Format.plural(nest, "file")) import NestJS"], [])
        }
        let djangoFiles = Set(paths.map { ($0 as NSString).lastPathComponent }).intersection(["models.py", "views.py", "urls.py", "admin.py", "apps.py"])
        if facts.imports(["django"]) > 0 || facts.hasDependency(["django"]) {
            add("Django MVT", 0.45 + 0.1 * Double(djangoFiles.count), ["Django dependency/imports"] + (djangoFiles.isEmpty ? [] : ["Django module files: \(djangoFiles.sorted().joined(separator: ", "))"]), [])
        }
        if facts.imports(["flask"]) > 0 {
            add("Flask application", 0.6 + min(0.3, Double(facts.imports(["flask"])) * 0.05), ["\(Format.plural(facts.imports(["flask"]), "file")) import flask"], [])
        }
        let fastapi = facts.imports(["fastapi"])
        if fastapi > 0 {
            var evidence = ["\(Format.plural(fastapi, "file")) import fastapi"]
            if facts.imports(["pydantic"]) > 0 { evidence.append("Pydantic models (\(Format.plural(facts.imports(["pydantic"]), "file")))") }
            if (facts.directoryNames["routers"] ?? 0) > 0 { evidence.append("routers/ directory") }
            add("FastAPI service", 0.55 + min(0.35, Double(fastapi) * 0.05), evidence, [])
        }
    }

    // MARK: Frameworks, layers, areas

    private static func frameworks(_ facts: Facts) -> [String] {
        var counts: [String: Int] = [:]
        for (module, files) in facts.importFiles {
            if let name = Catalog.frameworkNames[module] { counts[name, default: 0] += files }
        }
        var manifestOnly = Set<String>()
        for dependency in facts.manifest {
            if let name = Catalog.frameworkNames[dependency], counts[name] == nil { manifestOnly.insert(name) }
        }
        let used = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        return Array((used + manifestOnly.sorted()).prefix(20))
    }

    static let canonicalLayers = ["Presentation", "ViewModels", "Domain", "Services", "Data", "Models", "Utilities"]

    static func layerOrder(_ layer: String) -> Int { canonicalLayers.firstIndex(of: layer) ?? canonicalLayers.count }

    private static func layers(_ ctx: HealthContext) -> [ArchitectureLayer] {
        var files: [String: [RepositorySnapshot.File]] = [:]
        for file in ctx.sourceFiles {
            if let layer = ctx.layerOfFile[file.id] { files[layer, default: []].append(file) }
        }
        var dependsOn: [String: [String: Int]] = [:]
        for entry in ctx.pairs where ctx.sourceIDs.contains(entry.pair.source) && ctx.sourceIDs.contains(entry.pair.target) {
            guard let from = ctx.layerOfFile[entry.pair.source], let to = ctx.layerOfFile[entry.pair.target], from != to else { continue }
            dependsOn[from, default: [:]][to, default: 0] += 1
        }
        return files.keys.sorted { layerOrder($0) == layerOrder($1) ? $0 < $1 : layerOrder($0) < layerOrder($1) }.map { layer in
            let members = files[layer] ?? []
            var directoryCounts: [String: Int] = [:]
            for file in members { directoryCounts[file.directory.isEmpty ? "." : file.directory, default: 0] += 1 }
            let paths = directoryCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(4).map(\.key)
            let deps = (dependsOn[layer] ?? [:]).keys.sorted { layerOrder($0) == layerOrder($1) ? $0 < $1 : layerOrder($0) < layerOrder($1) }
            return ArchitectureLayer(name: layer, paths: Array(paths), files: members.count, dependsOn: deps)
        }
    }

    private static func areas(_ ctx: HealthContext) -> [FeatureArea] {
        let count = ctx.areas.areas.count
        guard count > 0 else { return [] }
        var files = Array(repeating: 0, count: count)
        var lines = Array(repeating: 0, count: count)
        var languageLines = Array(repeating: [Language: Int](), count: count)
        for file in ctx.participating {
            let area = ctx.areaIndex(of: file.id)
            guard area >= 0 else { continue }
            files[area] += 1
            lines[area] += file.codeLines
            languageLines[area][file.language, default: 0] += file.codeLines
        }
        var dependsOn = Array(repeating: [Int: Int](), count: count)
        var dependents = Array(repeating: [Int: Int](), count: count)
        for entry in ctx.pairs where ctx.sourceIDs.contains(entry.pair.source) && ctx.sourceIDs.contains(entry.pair.target) {
            let a = ctx.areaIndex(of: entry.pair.source), b = ctx.areaIndex(of: entry.pair.target)
            guard a >= 0, b >= 0, a != b else { continue }
            dependsOn[a][b, default: 0] += 1
            dependents[b][a, default: 0] += 1
        }
        func names(_ map: [Int: Int]) -> [String] {
            map.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(8).map { ctx.areas.name(at: $0.key) }
        }
        let result = (0..<count).map { index -> FeatureArea in
            let language = languageLines[index].max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
            let path = ctx.areas.areas[index]
            return FeatureArea(
                name: ctx.areas.name(at: index),
                path: path.isEmpty ? "." : path,
                files: files[index],
                lines: lines[index],
                primaryLanguage: language,
                dependsOn: names(dependsOn[index]),
                dependents: names(dependents[index])
            )
        }
        return Array(result.sorted { $0.lines == $1.lines ? $0.path < $1.path : $0.lines > $1.lines }.prefix(40))
    }

    private static func entryPoints(_ ctx: HealthContext) -> [String] {
        let entries = ctx.participating.filter { $0.isEntryPoint && !$0.isTest }
        let withMain = Set(entries.filter { file in
            (ctx.symbolsByFile[file.id] ?? []).contains { $0.attributes.contains("@main") }
        }.map(\.id))
        return entries.sorted { lhs, rhs in
            let l = withMain.contains(lhs.id), r = withMain.contains(rhs.id)
            return l != r ? l : lhs.path < rhs.path
        }.prefix(20).map(\.path)
    }

    private static func summary(_ ctx: HealthContext, patterns: [ArchitecturePattern], frameworks: [String], layers: [ArchitectureLayer], areas: [FeatureArea]) -> String {
        guard !ctx.sourceFiles.isEmpty else { return "No source code to analyse yet." }
        var languageLines: [Language: Int] = [:]
        for file in ctx.sourceFiles { languageLines[file.language, default: 0] += file.codeLines }
        let language = languageLines.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key.displayName ?? "Code"
        let uiFrameworks = ["SwiftUI", "UIKit", "AppKit", "React", "Next.js", "Vue", "Svelte", "Angular", "React Native", "Flutter"]
        let serverFrameworks = ["Express", "FastAPI", "Flask", "Django", "NestJS", "Fastify", "Koa", "Vapor"]
        let stack = frameworks.first { uiFrameworks.contains($0) || serverFrameworks.contains($0) }
        let kind: String = stack.map { serverFrameworks.contains($0) ? "service" : "app" } ?? "codebase"
        let subject = stack.map { "\($0) \(kind)" } ?? "\(language) \(kind)"

        let architectural = patterns.filter { !["Feature-based modularization", "Layered architecture", "Package-based modularization", "Monorepo (workspace packages)"].contains($0.name) }
        var sentence: String
        if let top = architectural.first, top.confidence >= 0.45 {
            sentence = "\(top.label) \(subject)"
        } else {
            sentence = subject.prefix(1).uppercased() + subject.dropFirst()
        }
        if patterns.contains(where: { $0.name == "Feature-based modularization" && $0.confidence >= 0.45 }) {
            sentence += " organised by feature"
        } else if patterns.contains(where: { ($0.name == "Package-based modularization" || $0.name == "Monorepo (workspace packages)") && $0.confidence >= 0.45 }) {
            sentence += " split into packages"
        } else if patterns.contains(where: { $0.name == "Layered architecture" && $0.confidence >= 0.45 }) {
            sentence += " organised in layers"
        }
        sentence += " (\(Format.plural(areas.count, "area")))."
        if architectural.first.map({ $0.confidence < 0.45 }) ?? true {
            sentence += " No dominant architectural pattern detected."
        }
        if !layers.isEmpty {
            sentence += " Layers: \(layers.map(\.name).joined(separator: ", "))."
        }
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}
