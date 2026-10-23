import Foundation
import VesaliusCore

/// Which declarations code in a file can name.
///
/// - private and fileprivate declarations, and anything nested in them, only from their own file;
/// - function-local declarations only from inside the declaration whose body holds them;
/// - across Swift modules, only what the file imports: public declarations, or internal ones through
///   `@testable import`; files built by a common target see each other's internal declarations (E3b);
/// - app code never reaches into test-only files, and UI-test bundles see nothing of the app they drive.
/// When either file has no target membership data, the legacy rule applies: same module, or module-less files
/// and targets of one Xcode project see each other, at 0.9 × the confidence and basis `lexical`.
extension ReferenceLinker {
    struct TargetInfo {
        let name: String
        let moduleName: String
        let isTest: Bool
        let isUITest: Bool
    }

    enum TestKind {
        case none, unit, ui
    }

    /// What the access rules need to know about one file.
    struct FileScope {
        /// Targets that build the file, from membership data.
        let targets: Set<Int64>
        /// Targets guessed from a folder of the same name (no membership data in the project).
        let legacyTargets: Set<Int64>
        let testKind: TestKind
        /// Names other modules import this file's code under.
        let moduleNames: Set<String>
        /// Modules imported by this file: name → `@testable`.
        let imports: [String: Bool]
        /// Modules imported by any file of the same target or module (members leak module-wide in Swift).
        let moduleWideImports: [String: Bool]
    }

    /// How a file relates to another one, for declarations of the second.
    struct FileRelation {
        let sharedTarget: Bool
        let membershipKnown: Bool
        let sameModule: Bool
        /// Module-less, or two targets of one Xcode project: visible under the legacy rule only.
        let legacyVisible: Bool
        /// The other file's module is imported by this file: nil, or whether through `@testable`.
        let importTestable: Bool?
        /// …or by another file of this file's module (enough for members, not for top-level names).
        let moduleWideTestable: Bool?
        let testDenied: Bool
    }

    enum Access: Equatable {
        case visible
        /// Visible only through the legacy same-project / module-less rule.
        case legacy
        /// In a module this file does not import.
        case notImported
        case denied

        var isVisible: Bool { self == .visible || self == .legacy }
    }

    /// Imports, bindings and module structure.
    func loadImports() throws {
        exports = [:]
        try db.forEach("SELECT file_id, exported_name, local_name FROM exports") { row in
            exports[row.int64(0), default: [:]][row.string(1)] = row.string(2)
        }

        bindings = [:]
        externalBindings = [:]
        starImports = [:]
        reexports = [:]
        moduleImports = [:]
        reexportedModules = [:]
        swiftImports = [:]
        externalImports = [:]
        try db.forEach("""
            SELECT file_id, module, names, is_reexport, resolved_file_id, resolved_module_id, external_name, is_testable
            FROM imports WHERE is_mock = 0 ORDER BY id
            """) { row in
            let fileID = row.int64(0)
            let module = row.string(1)
            let names = ImportNamesCodec.decode(row.optionalString(2))
            let target = row.optionalInt64(4)
            guard let file = files[fileID] else { return }
            if file.family == .swift || file.family == .other(.objectiveC) {
                swiftImports[fileID, default: [:]][module] = (swiftImports[fileID]?[module] ?? false) || row.bool(7)
            }
            if let external = row.optionalString(6) { externalImports[fileID, default: []].insert(external) }
            if let moduleID = row.optionalInt64(5) {
                moduleImports[fileID, default: []].insert(moduleID)
                if row.bool(3), let importer = file.moduleID {
                    reexportedModules[importer, default: []].insert(moduleID)
                }
            }
            guard let target else {
                if let external = row.optionalString(6), file.family == .script || file.family == .python {
                    bindExternal(fileID: fileID, module: module, external: external, names: names, family: file.family)
                }
                return
            }
            if row.bool(3) {
                reexports[fileID, default: []].append((target, names))
            }
            switch file.family {
            case .python:
                if names.isEmpty {
                    bindings[fileID, default: [:]][module] = .module(target)
                    return
                }
                let targetPath = files[target]?.path ?? ""
                let targetStem = ((targetPath as NSString).lastPathComponent as NSString).deletingPathExtension
                let targetPackage = ((targetPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
                for name in names {
                    if name.name == "*" {
                        if let alias = name.alias {
                            bindings[fileID, default: [:]][alias] = .module(target)
                        } else {
                            starImports[fileID, default: []].append(target)
                        }
                    } else if targetStem == name.name || (targetStem == "__init__" && targetPackage == name.name) {
                        bindings[fileID, default: [:]][name.localName] = .module(target)
                    } else {
                        bindings[fileID, default: [:]][name.localName] = .symbol(target, name.name)
                    }
                }
            default:
                for name in names {
                    switch name.name {
                    case "*": if let alias = name.alias { bindings[fileID, default: [:]][alias] = .module(target) }
                    case "default": bindings[fileID, default: [:]][name.localName] = .defaultExport(target)
                    default: bindings[fileID, default: [:]][name.localName] = .symbol(target, name.name)
                    }
                }
            }
        }

        moduleWideImports = [:]
        for (fileID, imported) in moduleImports {
            if let module = files[fileID]?.moduleID { moduleWideImports[module, default: []].formUnion(imported) }
        }
        modulesByName = [:]
        moduleNames = [:]
        xcodeProjects = [:]
        try db.forEach("SELECT id, name, kind, manifest_path FROM modules ORDER BY id") { row in
            modulesByName[row.string(1), default: []].append(row.int64(0))
            moduleNames[row.int64(0)] = row.string(1)
            if row.string(2) == "xcode-target", let project = row.optionalString(3) { xcodeProjects[row.int64(0)] = project }
        }
    }

    /// Targets and which files they build.
    func loadProjectModel() throws {
        targets = [:]
        fileTargets = [:]
        legacyFileTargets = [:]
        targetsByModuleName = [:]
        try db.forEach("SELECT id, name, module_name, is_test, test_kind FROM targets ORDER BY id") { row in
            let name = row.string(1)
            let info = TargetInfo(name: name, moduleName: row.optionalString(2) ?? name, isTest: row.bool(3), isUITest: row.optionalString(4) == "ui")
            targets[row.int64(0)] = info
            targetsByModuleName[info.moduleName, default: []].append(row.int64(0))
            if name != info.moduleName { targetsByModuleName[name, default: []].append(row.int64(0)) }
        }
        try db.forEach("SELECT file_id, target_id, via FROM file_targets ORDER BY file_id, target_id") { row in
            if row.string(2) == "legacy-folder" {
                legacyFileTargets[row.int64(0), default: []].append(row.int64(1))
            } else {
                fileTargets[row.int64(0), default: []].append(row.int64(1))
            }
        }
    }

    // MARK: - Access

    func isAccessible(_ symbolID: Int64, from fileID: Int64, line: Int?) -> Bool {
        access(symbolID, from: fileID, line: line ?? 0).isVisible
    }

    /// Whether code at `line` of `fileID` can name the declaration.
    func access(_ symbolID: Int64, from fileID: Int64, line: Int) -> Access {
        guard let symbol = symbols[symbolID], let own = files[fileID], let other = files[symbol.fileID] else { return .denied }
        if symbol.isLocal {
            guard symbol.fileID == fileID else { return .denied }
            return line == 0 || (symbol.scope?.contains(line) ?? true) ? .visible : .denied
        }
        if symbol.isFileScoped { return symbol.fileID == fileID ? .visible : .denied }
        if symbol.fileID == fileID { return .visible }
        guard own.family == .swift, other.family == .swift else { return .visible }

        let relation = relation(from: fileID, to: symbol.fileID)
        if relation.testDenied { return .denied }
        if relation.sharedTarget { return .visible }
        let isMember = symbol.ownerID != nil
        let imported: Bool? = relation.importTestable ?? (isMember ? relation.moduleWideTestable : nil)
        if relation.membershipKnown {
            guard let testable = imported else { return .notImported }
            return symbol.isExported || testable ? .visible : .denied
        }
        if relation.sameModule { return .visible }
        if let testable = imported { return symbol.isExported || testable ? .visible : .denied }
        if relation.legacyVisible { return .legacy }
        return .notImported
    }

    func fileScope(_ fileID: Int64) -> FileScope {
        if let known = fileScopes[fileID] { return known }
        let known = Set(fileTargets[fileID] ?? [])
        let legacy = Set(legacyFileTargets[fileID] ?? [])
        var names = Set<String>()
        for target in known.union(legacy) {
            if let info = targets[target] {
                names.insert(info.moduleName)
                names.insert(info.name)
            }
        }
        let moduleID = files[fileID]?.moduleID
        if let moduleID, let name = moduleNames[moduleID] { names.insert(name) }

        let testKind: TestKind
        let deciding = known.isEmpty ? legacy : known
        if !deciding.isEmpty {
            let infos = deciding.compactMap { targets[$0] }
            if !infos.isEmpty, infos.allSatisfy(\.isTest) {
                testKind = infos.contains(where: \.isUITest) ? .ui : .unit
            } else {
                testKind = .none
            }
        } else if let name = moduleID.flatMap({ moduleNames[$0] }) {
            testKind = name.hasSuffix("UITests") ? .ui : (name.hasSuffix("Tests") ? .unit : .none)
        } else {
            testKind = .none
        }

        // What the whole target (or module) imports.
        var wide: [String: Bool] = [:]
        var peers = Set<Int64>()
        if !known.isEmpty {
            for (file, fileTargetIDs) in fileTargets where !known.isDisjoint(with: fileTargetIDs) { peers.insert(file) }
        } else if let moduleID {
            for (file, info) in files where info.moduleID == moduleID { peers.insert(file) }
        }
        for peer in peers {
            for (module, testable) in swiftImports[peer] ?? [:] { wide[module] = (wide[module] ?? false) || testable }
        }
        let scope = FileScope(targets: known, legacyTargets: legacy, testKind: testKind, moduleNames: names,
                              imports: swiftImports[fileID] ?? [:], moduleWideImports: wide)
        fileScopes[fileID] = scope
        return scope
    }

    func relation(from fileID: Int64, to otherID: Int64) -> FileRelation {
        let key = UInt64(UInt32(truncatingIfNeeded: fileID)) << 32 | UInt64(UInt32(truncatingIfNeeded: otherID))
        if let known = fileRelations[key] { return known }
        let own = fileScope(fileID)
        let other = fileScope(otherID)
        let ownModule = files[fileID]?.moduleID
        let otherModule = files[otherID]?.moduleID

        let sharedTarget = !own.targets.isDisjoint(with: other.targets)
            || (own.targets.isEmpty && other.targets.isEmpty && !own.legacyTargets.isDisjoint(with: other.legacyTargets))
        let membershipKnown = !own.targets.isEmpty && !other.targets.isEmpty
        let sameModule = ownModule != nil && ownModule == otherModule
        var legacyVisible = ownModule == nil || otherModule == nil
        if let ownModule, let otherModule, let project = xcodeProjects[ownModule], xcodeProjects[otherModule] == project {
            legacyVisible = true
        }

        // The other file's module is visible when imported by name, or re-exported by an imported module.
        func testable(in imports: [String: Bool]) -> Bool? {
            var result: Bool?
            for name in other.moduleNames {
                if let flag = imports[name] { result = (result ?? false) || flag }
            }
            if result == nil, let otherModule {
                for (name, flag) in imports {
                    for module in modulesByName[name] ?? [] where module == otherModule || reexportedModules[module]?.contains(otherModule) == true {
                        result = (result ?? false) || flag
                    }
                }
            }
            return result
        }
        var importTestable = testable(in: own.imports)
        if importTestable == nil, let ownModule, let otherModule, reexportedModules[ownModule]?.contains(otherModule) == true {
            importTestable = false
        }
        let moduleWideTestable = testable(in: own.moduleWideImports)

        // App code never names test-only code; a UI-test bundle runs the app in another process, so it sees only
        // what it builds itself or imports (a package), never the app's files.
        let testDenied = (own.testKind == .none && other.testKind != .none)
            || (own.testKind == .ui && other.testKind != .ui && !sharedTarget && importTestable == nil)

        let relation = FileRelation(sharedTarget: sharedTarget, membershipKnown: membershipKnown, sameModule: sameModule,
                                    legacyVisible: legacyVisible, importTestable: importTestable,
                                    moduleWideTestable: moduleWideTestable, testDenied: testDenied)
        fileRelations[key] = relation
        return relation
    }

    // MARK: - The v3 unique-name guess

    /// The declaration a v3 index would have bound a value-receiver member to: the only member of that name a
    /// module import reaches, ignoring privacy and function-local types. Recorded as `alt_symbol_id` when typing
    /// resolves the site differently, so `usages` can list it among the rejected lookalikes.
    func legacyGuess(_ row: RefRow, file: FileInfo) -> Int64? {
        guard let receiver = row.receiver, receiver != ".", !Self.selfReceivers.contains(receiver),
              receiver.first?.isUppercase != true || isGlobalValue(receiver) else { return nil }
        guard !FallbackStoplist.legacy.contains(row.name) else { return nil }
        let key = GuessKey(file: row.fileID, name: row.name, kind: row.kind)
        if let known = legacyGuesses[key] { return known }
        let guess = computeLegacyGuess(row, file: file)
        legacyGuesses[key] = .some(guess)
        return guess
    }

    private func computeLegacyGuess(_ row: RefRow, file: FileInfo) -> Int64? {
        let isSwift = file.family == .swift
        let candidates = (byName[row.name] ?? []).filter { id in
            guard let symbol = symbols[id], symbol.ownerName != nil, !symbol.isLocal, compatible(id, family: file.family),
                  kindMatches(symbol.kind, row.kind) else { return false }
            return !isSwift || (!symbol.isTypeLevel && symbol.kind != .initializer)
        }
        let reachable = candidates.filter { legacyVisibility(of: $0, from: row.fileID) }
        return reachable.count == 1 ? reachable[0] : nil
    }

    /// v3's module visibility: module-less files and targets of one Xcode project see each other; otherwise the
    /// declaring module must be imported by the file, re-exported to it, or imported anywhere in its module.
    private func legacyVisibility(of symbolID: Int64, from fileID: Int64) -> Bool {
        guard let symbol = symbols[symbolID], let other = files[symbol.fileID], let info = files[fileID],
              other.family == .swift, info.family == .swift,
              let module = other.moduleID, let own = info.moduleID, module != own else { return true }
        if let project = xcodeProjects[own], xcodeProjects[module] == project { return true }
        let direct = moduleImports[fileID] ?? []
        if direct.contains(module) || reexportedModules[own]?.contains(module) == true { return true }
        if direct.contains(where: { reexportedModules[$0]?.contains(module) == true }) { return true }
        return moduleWideImports[own]?.contains(module) == true
    }
}
