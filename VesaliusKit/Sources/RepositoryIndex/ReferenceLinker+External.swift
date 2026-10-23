import Foundation
import VesaliusCore

/// Explicit import bindings (TS/JS/Python, step A) and references to code outside the repository.
///
/// A name bound by an import of a package (`import { safeStorage } from "electron"`, `import fs from "node:fs"`)
/// resolves to that package: `is_external = 1`, `external_module`, `receiver_type` = the imported name, no
/// target. A Swift framework type (`Transaction.updates`, a receiver typed `MTLBuffer`) gets its module from
/// `FrameworkCatalog`, or from the file's only framework import that is not ubiquitous. External references
/// never become file edges.
extension ReferenceLinker {
    /// Records the names an import of a package binds in a script or Python file.
    func bindExternal(fileID: Int64, module: String, external: String, names: [ImportedName], family: Family) {
        if names.isEmpty {
            // `import numpy` / `import os.path` binds the first component; `import "./polyfill"` binds nothing.
            guard family == .python else { return }
            let first = module.split(separator: ".").first.map(String.init) ?? module
            externalBindings[fileID, default: [:]][first] = (external, "*")
            return
        }
        for name in names {
            if name.name == "*" {
                if let alias = name.alias { externalBindings[fileID, default: [:]][alias] = (external, "*") }
            } else {
                externalBindings[fileID, default: [:]][name.localName] = (external, name.name)
            }
        }
    }

    /// Step A: a receiver or bare name bound by an import.
    func resolveImport(_ row: RefRow, file: FileInfo) -> Resolution? {
        let fileID = row.fileID
        let name = row.name
        if let receiver = row.receiver, let binding = bindings[fileID]?[receiver] {
            switch binding {
            case .module(let target):
                if let symbol = lookupExport(file: target, name: name, depth: 0) { return imported(symbol, fallbackFile: target, confidence: 0.95) }
                return Resolution(symbol: nil, file: target, confidence: 0.85, basis: .import)
            case .symbol(let target, let exported):
                if let owner = lookupExport(file: target, name: exported, depth: 0) {
                    if let member = importedMember(of: owner, named: name, from: fileID) { return imported(member, fallbackFile: target, confidence: 0.9) }
                    return imported(owner, fallbackFile: target, confidence: 0.8)
                }
                return Resolution(symbol: nil, file: target, confidence: 0.8, basis: .import)
            case .defaultExport(let target):
                if let owner = defaultSymbol(file: target) {
                    if let member = importedMember(of: owner, named: name, from: fileID) { return imported(member, fallbackFile: target, confidence: 0.9) }
                    return imported(owner, fallbackFile: target, confidence: 0.8)
                }
                return Resolution(symbol: nil, file: target, confidence: 0.8, basis: .import)
            }
        }
        if row.receiver == nil, let binding = bindings[fileID]?[name] {
            switch binding {
            case .module(let target):
                return Resolution(symbol: nil, file: target, confidence: 0.9, basis: .import)
            case .symbol(let target, let exported):
                if let symbol = lookupExport(file: target, name: exported, depth: 0) { return imported(symbol, fallbackFile: target, confidence: 0.95) }
                return Resolution(symbol: nil, file: target, confidence: 0.9, basis: .import)
            case .defaultExport(let target):
                if let symbol = defaultSymbol(file: target) { return imported(symbol, fallbackFile: target, confidence: 0.95) }
                return Resolution(symbol: nil, file: target, confidence: 0.9, basis: .import)
            }
        }
        if row.receiver == nil, let stars = starImports[fileID] {
            for target in stars {
                if let symbol = lookupExport(file: target, name: name, depth: 0) { return imported(symbol, fallbackFile: target, confidence: 0.85) }
            }
        }
        // A-ext: bound by an import of a package outside the repository.
        let bound = row.receiver.map { receiver -> (String, (module: String, exported: String))? in
            let root = receiver.split(separator: ".").first.map(String.init) ?? receiver
            return externalBindings[fileID]?[root].map { (root, $0) }
        } ?? externalBindings[fileID]?[name].map { (name, $0) }
        guard case let (local, binding)? = bound else { return nil }
        let exported = binding.exported == "*" || binding.exported == "default" ? local : binding.exported
        return Resolution(symbol: nil, file: nil, confidence: 0.95, basis: .import, receiverType: exported,
                          isExternal: true, externalModule: binding.module)
    }

    private func imported(_ symbol: Int64, fallbackFile: Int64, confidence: Double) -> Resolution {
        Resolution(symbol: symbol, file: symbols[symbol]?.fileID ?? fallbackFile, confidence: confidence, basis: .import)
    }

    /// A member of an imported class (`Store.load` after `import { Store } from "./store"`), its own or inherited.
    private func importedMember(of owner: Int64, named name: String, from fileID: Int64) -> Int64? {
        guard let hit = lookupMember(.repo(owner), named: name, accept: { self.access($0, from: fileID, line: 0).isVisible }) else { return nil }
        return hit.ids.min { rank($0) < rank($1) }
    }

    func lookupExport(file: Int64, name: String, depth: Int) -> Int64? {
        guard depth < 4 else { return nil }
        if let local = exports[file]?[name] {
            if let symbol = topLevel[file]?[local] { return symbol }
            if let binding = bindings[file]?[local] { return follow(binding, depth: depth + 1) }
        }
        if let symbol = topLevel[file]?[name] { return symbol }
        if let binding = bindings[file]?[name] { return follow(binding, depth: depth + 1) }
        for reexport in reexports[file] ?? [] {
            if reexport.names.isEmpty || reexport.names.contains(where: { $0.name == "*" && $0.alias == nil }) {
                if let symbol = lookupExport(file: reexport.target, name: name, depth: depth + 1) { return symbol }
            } else if let match = reexport.names.first(where: { $0.localName == name }) {
                if let symbol = lookupExport(file: reexport.target, name: match.name, depth: depth + 1) { return symbol }
            }
        }
        return nil
    }

    private func follow(_ binding: Binding, depth: Int) -> Int64? {
        switch binding {
        case .module: nil
        case .symbol(let target, let name): lookupExport(file: target, name: name, depth: depth)
        case .defaultExport(let target): defaultSymbol(file: target)
        }
    }

    func defaultSymbol(file: Int64) -> Int64? {
        if let local = exports[file]?["default"], let symbol = topLevel[file]?[local] { return symbol }
        return defaultExports[file]
    }

    // MARK: - Swift frameworks

    /// The module a framework type comes from: the catalog, else the file's only non-ubiquitous framework import.
    /// A name that two of the file's imports both declare (`Transaction` with SwiftUI and StoreKit) has no module:
    /// either could be meant.
    func externalModule(forType name: String, fileID: Int64) -> String? {
        let imports = externalImports[fileID] ?? []
        if FrameworkCatalog.typeCandidates(name).filter(imports.contains).count > 1 { return nil }
        if let module = FrameworkCatalog.module(forType: name, imports: imports) { return module }
        return soleFrameworkImport(fileID)
    }

    /// The file's only non-ubiquitous framework import, for a framework name the catalog does not list. None when
    /// the file also imports a UI framework: an unlisted name there is as likely the UI framework's
    /// (`StrokeStyle` in a SwiftUI view that imports StoreKit).
    func soleFrameworkImport(_ fileID: Int64) -> String? {
        let imports = externalImports[fileID] ?? []
        guard imports.isDisjoint(with: FrameworkCatalog.uiFrameworks) else { return nil }
        let candidates = imports.filter { !FrameworkCatalog.ubiquitousModules.contains($0) }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// A member of a type outside the repository.
    func externalMember(of typeName: String, row: RefRow, basis: ResolutionBasis, confidence: Double = 0.9) -> Resolution {
        let module: String?
        switch typeName.first {
        case "[": module = "Swift"
        default: module = externalModule(forType: typeName, fileID: row.fileID)
        }
        return Resolution(symbol: nil, file: nil, confidence: confidence, basis: basis, receiverType: typeName,
                          isExternal: true, externalModule: module)
    }
}
