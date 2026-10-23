import Foundation
import VesaliusCore

/// One `targets` row: an Xcode native target or a SwiftPM target.
public struct TargetRecord: Sendable, Hashable {
    public var name: String
    public var moduleName: String?
    /// `xcode` or `swiftpm`.
    public var system: String
    /// The Xcode product type (`com.apple.product-type.application`) or the SwiftPM declaration (`testTarget`).
    public var productType: String?
    public var platform: String?
    public var deploymentTarget: String?
    public var bundleID: String?
    public var isTest: Bool
    /// `unit` or `ui` for test targets.
    public var testKind: String?
    /// The target a test bundle runs in.
    public var testHost: String?
    /// The file that declares the target (`Atlas.xcodeproj/project.pbxproj`, `Packages/Kit/Package.swift`) and the line.
    public var projectPath: String?
    public var projectLine: Int?
    public var infoPlistPath: String?
    public var entitlementsPath: String?
    public var extensionPoint: String?
    public var moduleID: Int64?

    public init(name: String, moduleName: String?, system: String, productType: String?, platform: String?, deploymentTarget: String?, bundleID: String?, isTest: Bool,
                testKind: String?, testHost: String?, projectPath: String?, projectLine: Int?, infoPlistPath: String?, entitlementsPath: String?, extensionPoint: String?, moduleID: Int64?) {
        self.name = name
        self.moduleName = moduleName
        self.system = system
        self.productType = productType
        self.platform = platform
        self.deploymentTarget = deploymentTarget
        self.bundleID = bundleID
        self.isTest = isTest
        self.testKind = testKind
        self.testHost = testHost
        self.projectPath = projectPath
        self.projectLine = projectLine
        self.infoPlistPath = infoPlistPath
        self.entitlementsPath = entitlementsPath
        self.extensionPoint = extensionPoint
        self.moduleID = moduleID
    }

    var values: [SQLValue] {
        [name.sqlValue, moduleName.sqlValue, system.sqlValue, productType.sqlValue, platform.sqlValue, deploymentTarget.sqlValue, bundleID.sqlValue, isTest.sqlValue,
         testKind.sqlValue, testHost.sqlValue, projectPath.sqlValue, projectLine.sqlValue, infoPlistPath.sqlValue, entitlementsPath.sqlValue, extensionPoint.sqlValue, moduleID.sqlValue]
    }
}

/// One `target_deps` row, with targets given as indexes into the list being written.
public struct TargetDependencyRecord: Sendable, Hashable {
    public var target: Int
    /// `target`, `product`, `embed` or `framework`.
    public var kind: String
    public var name: String
    public var dependency: Int?
    public var package: String?
    public var evidencePath: String?
    public var evidenceLine: Int?

    public init(target: Int, kind: String, name: String, dependency: Int?, package: String?, evidencePath: String?, evidenceLine: Int?) {
        self.target = target
        self.kind = kind
        self.name = name
        self.dependency = dependency
        self.package = package
        self.evidencePath = evidencePath
        self.evidenceLine = evidenceLine
    }
}

/// One `packages` row and its `package_products`.
public struct PackageRecord: Sendable, Hashable {
    public var name: String?
    public var path: String?
    public var url: String?
    /// `local`, `remote` or `submodule`.
    public var kind: String
    public var manifestPath: String?
    public var products: [PackageProductRecord]

    public init(name: String?, path: String?, url: String?, kind: String, manifestPath: String?, products: [PackageProductRecord]) {
        self.name = name
        self.path = path
        self.url = url
        self.kind = kind
        self.manifestPath = manifestPath
        self.products = products
    }
}

public struct PackageProductRecord: Sendable, Hashable {
    public var name: String
    /// `library`, `executable` or `plugin`.
    public var kind: String
    /// The product's targets, comma-joined.
    public var targets: String
    public var manifestLine: Int?

    public init(name: String, kind: String, targets: String, manifestLine: Int?) {
        self.name = name
        self.kind = kind
        self.targets = targets
        self.manifestLine = manifestLine
    }
}

/// One `file_targets` row: target `targetID` builds file `fileID`.
public struct FileTargetRecord: Sendable, Hashable {
    public var fileID: Int64
    public var targetID: Int64
    /// `sync-root`, `exception-add`, `build-phase`, `swiftpm-path` or `legacy-folder` (no membership data in
    /// the project: the folder named like the target stands in, so visibility rules should treat it as unknown).
    public var via: String
    public var evidencePath: String?
    public var evidenceLine: Int?

    public init(fileID: Int64, targetID: Int64, via: String, evidencePath: String?, evidenceLine: Int?) {
        self.fileID = fileID
        self.targetID = targetID
        self.via = via
        self.evidencePath = evidencePath
        self.evidenceLine = evidenceLine
    }
}

/// One `config_links` row: a fact in a configuration file, optionally tied to a code line and a target.
public struct ConfigLinkRecord: Sendable, Hashable {
    public var configPath: String
    public var configLine: Int?
    public var kind: String
    public var key: String?
    public var fileID: Int64?
    public var line: Int?
    public var targetID: Int64?
    public var evidence: String?

    public init(configPath: String, configLine: Int?, kind: String, key: String?, fileID: Int64?, line: Int?, targetID: Int64?, evidence: String?) {
        self.configPath = configPath
        self.configLine = configLine
        self.kind = kind
        self.key = key
        self.fileID = fileID
        self.line = line
        self.targetID = targetID
        self.evidence = evidence
    }

    var values: [SQLValue] {
        [configPath.sqlValue, configLine.sqlValue, kind.sqlValue, key.sqlValue, fileID.sqlValue, line.sqlValue, targetID.sqlValue, evidence.sqlValue]
    }
}

/// Whether a file is a test, of which kind (`unit`, `ui`, `support`), and why (`AtlasTests` membership at a
/// pbxproj line, `vitest.config.ts:8`, or `path` for the name heuristic).
public struct TestClassification: Sendable, Hashable {
    public var fileID: Int64
    public var isTest: Bool
    public var kind: String?
    public var evidence: String?

    public init(fileID: Int64, isTest: Bool, kind: String?, evidence: String?) {
        self.fileID = fileID
        self.isTest = isTest
        self.kind = kind
        self.evidence = evidence
    }
}

/// Writes for the project model. Each one compares with what is stored first and writes nothing when it is
/// the same, so a no-op index run neither rewrites rows nor changes target ids.
extension IndexStore {
    /// Replaces `targets`, `target_deps`, `packages` and `package_products` unless they already hold exactly
    /// these rows. Returns the target ids in input order. Replacing targets also drops their `file_targets`
    /// rows (cascade); write those afterwards.
    @discardableResult
    public func replaceProjectStructure(targets: [TargetRecord], dependencies: [TargetDependencyRecord], packages: [PackageRecord]) throws -> [Int64] {
        var storedIDs: [Int64] = []
        var storedTargets: [[SQLValue]] = []
        try db.forEach("""
            SELECT id, name, module_name, system, product_type, platform, deployment_target, bundle_id, is_test, test_kind, test_host,
                project_path, project_line, info_plist_path, entitlements_path, extension_point, module_id
            FROM targets ORDER BY id
            """) { row in
            storedIDs.append(row.int64(0))
            storedTargets.append((1...16).map { row.value(Int32($0)) })
        }
        let position = Dictionary(uniqueKeysWithValues: storedIDs.enumerated().map { ($1, $0) })
        var storedDependencies: [[SQLValue]] = []
        try db.forEach("SELECT target_id, kind, name, dep_target_id, package, evidence_path, evidence_line FROM target_deps ORDER BY rowid") { row in
            storedDependencies.append([
                position[row.int64(0)].sqlValue, row.value(1), row.value(2), row.optionalInt64(3).flatMap { position[$0] }.sqlValue,
                row.value(4), row.value(5), row.value(6),
            ])
        }
        var storedPackages: [[SQLValue]] = []
        var packagePositions: [Int64: Int] = [:]
        try db.forEach("SELECT id, name, path, url, kind, manifest_path FROM packages ORDER BY id") { row in
            packagePositions[row.int64(0)] = storedPackages.count
            storedPackages.append((1...5).map { row.value(Int32($0)) })
        }
        var storedProducts: [[SQLValue]] = []
        try db.forEach("SELECT package_id, name, kind, targets, manifest_line FROM package_products ORDER BY rowid") { row in
            storedProducts.append([row.optionalInt64(0).flatMap { packagePositions[$0] }.sqlValue, row.value(1), row.value(2), row.value(3), row.value(4)])
        }

        let wantedDependencies: [[SQLValue]] = dependencies.map {
            [$0.target.sqlValue, $0.kind.sqlValue, $0.name.sqlValue, $0.dependency.sqlValue, $0.package.sqlValue, $0.evidencePath.sqlValue, $0.evidenceLine.sqlValue]
        }
        let wantedPackages: [[SQLValue]] = packages.map { [$0.name.sqlValue, $0.path.sqlValue, $0.url.sqlValue, $0.kind.sqlValue, $0.manifestPath.sqlValue] }
        let wantedProducts: [[SQLValue]] = packages.enumerated().flatMap { index, package in
            package.products.map { [index.sqlValue, $0.name.sqlValue, $0.kind.sqlValue, $0.targets.sqlValue, $0.manifestLine.sqlValue] }
        }
        if storedTargets == targets.map(\.values), storedDependencies == wantedDependencies, storedPackages == wantedPackages, storedProducts == wantedProducts {
            return storedIDs
        }

        return try db.transaction {
            try db.run("DELETE FROM targets")
            try db.run("DELETE FROM target_deps")
            try db.run("DELETE FROM package_products")
            try db.run("DELETE FROM packages")
            var ids: [Int64] = []
            for target in targets {
                try db.run("""
                    INSERT INTO targets(name, module_name, system, product_type, platform, deployment_target, bundle_id, is_test, test_kind, test_host,
                        project_path, project_line, info_plist_path, entitlements_path, extension_point, module_id)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, target.values)
                ids.append(db.lastInsertRowID)
            }
            for dependency in dependencies where ids.indices.contains(dependency.target) {
                try db.run("INSERT INTO target_deps(target_id, kind, name, dep_target_id, package, evidence_path, evidence_line) VALUES(?, ?, ?, ?, ?, ?, ?)", [
                    ids[dependency.target], dependency.kind, dependency.name, dependency.dependency.flatMap { ids.indices.contains($0) ? ids[$0] : nil },
                    dependency.package, dependency.evidencePath, dependency.evidenceLine,
                ])
            }
            for package in packages {
                try db.run("INSERT INTO packages(name, path, url, kind, manifest_path) VALUES(?, ?, ?, ?, ?)", [package.name, package.path, package.url, package.kind, package.manifestPath])
                let packageID = db.lastInsertRowID
                for product in package.products {
                    try db.run("INSERT INTO package_products(package_id, name, kind, targets, manifest_line) VALUES(?, ?, ?, ?, ?)", [packageID, product.name, product.kind, product.targets, product.manifestLine])
                }
            }
            return ids
        }
    }

    /// Makes `file_targets` hold exactly `rows`. Returns true when anything changed.
    @discardableResult
    public func replaceFileTargets(_ rows: [FileTargetRecord]) throws -> Bool {
        var stored = Set<FileTargetRecord>()
        try db.forEach("SELECT file_id, target_id, via, evidence_path, evidence_line FROM file_targets") { row in
            stored.insert(FileTargetRecord(fileID: row.int64(0), targetID: row.int64(1), via: row.string(2), evidencePath: row.optionalString(3), evidenceLine: row.optionalInt(4)))
        }
        let wanted = Set(rows)
        guard stored != wanted else { return false }
        let wantedKeys = Set(wanted.map { [$0.fileID, $0.targetID] })
        try db.transaction {
            for row in stored.subtracting(wanted) where !wantedKeys.contains([row.fileID, row.targetID]) {
                try db.run("DELETE FROM file_targets WHERE file_id = ? AND target_id = ?", [row.fileID, row.targetID])
            }
            for row in wanted.subtracting(stored) {
                try db.run("INSERT OR REPLACE INTO file_targets(file_id, target_id, via, evidence_path, evidence_line) VALUES(?, ?, ?, ?, ?)", [
                    row.fileID, row.targetID, row.via, row.evidencePath, row.evidenceLine,
                ])
            }
        }
        return true
    }

    /// Makes `config_links` hold exactly `rows` (in this order). Returns true when anything changed.
    @discardableResult
    public func replaceConfigLinks(_ rows: [ConfigLinkRecord]) throws -> Bool {
        var stored: [[SQLValue]] = []
        try db.forEach("SELECT config_path, config_line, kind, key, file_id, line, target_id, evidence FROM config_links ORDER BY rowid") { row in
            stored.append((0...7).map { row.value(Int32($0)) })
        }
        guard stored != rows.map(\.values) else { return false }
        try db.transaction {
            try db.run("DELETE FROM config_links")
            for row in rows {
                try db.run("INSERT INTO config_links(config_path, config_line, kind, key, file_id, line, target_id, evidence) VALUES(?, ?, ?, ?, ?, ?, ?, ?)", row.values)
            }
        }
        return true
    }

    /// Writes `files.is_test`, `test_kind` and `test_evidence` where they differ. Returns the number of files updated.
    @discardableResult
    public func applyTestClassification(_ rows: [TestClassification]) throws -> Int {
        var stored: [Int64: TestClassification] = [:]
        try db.forEach("SELECT id, is_test, test_kind, test_evidence FROM files") { row in
            stored[row.int64(0)] = TestClassification(fileID: row.int64(0), isTest: row.bool(1), kind: row.optionalString(2), evidence: row.optionalString(3))
        }
        let changes = rows.filter { stored[$0.fileID] != nil && stored[$0.fileID] != $0 }
        guard !changes.isEmpty else { return 0 }
        try db.transaction {
            for row in changes {
                try db.run("UPDATE files SET is_test = ?, test_kind = ?, test_evidence = ? WHERE id = ?", [row.isTest, row.kind, row.evidence, row.fileID])
            }
        }
        return changes.count
    }

    // MARK: Reads

    /// The targets that build a file, with how the membership is known.
    public func targets(ofFile path: String) throws -> [(name: String, system: String, isTest: Bool, via: String, evidencePath: String?, evidenceLine: Int?)] {
        try db.query("""
            SELECT t.name, t.system, t.is_test, ft.via, ft.evidence_path, ft.evidence_line
            FROM file_targets ft JOIN targets t ON t.id = ft.target_id JOIN files f ON f.id = ft.file_id
            WHERE f.path = ? ORDER BY t.id
            """, [path]) { row in
            (row.string(0), row.string(1), row.bool(2), row.string(3), row.optionalString(4), row.optionalInt(5))
        }
    }
}
