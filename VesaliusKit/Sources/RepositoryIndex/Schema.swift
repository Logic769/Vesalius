import Foundation

/// The persistent repository graph.
///
/// Nodes: repository (meta), directories, modules, files, symbols (types, functions, methods, properties…),
/// build targets and packages (targets, packages).
/// Edges: `contains` (directory/module → file, symbol → member via parent_id), `imports` (imports table +
/// file_edges), references/calls/inherits/conformsTo/instantiates/reads/writes (refs table, one row per
/// occurrence, aggregated into file_edges), target membership (file_targets), diagnostics → affected nodes
/// (diagnostic_targets).
/// Every reverse lookup (importers, callers, dependents, descendants) is backed by an index.
public enum IndexSchema {
    public static let version = 4

    public static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS directories (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            parent_id INTEGER,
            name TEXT NOT NULL,
            depth INTEGER NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_directories_parent ON directories(parent_id)",
        """
        CREATE TABLE IF NOT EXISTS modules (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            root_path TEXT NOT NULL,
            manifest_path TEXT,
            language TEXT,
            UNIQUE(kind, root_path)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_modules_name ON modules(name)",
        """
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            directory_id INTEGER REFERENCES directories(id) ON DELETE SET NULL,
            module_id INTEGER REFERENCES modules(id) ON DELETE SET NULL,
            language TEXT NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            mtime REAL NOT NULL DEFAULT 0,
            content_hash TEXT,
            line_count INTEGER NOT NULL DEFAULT 0,
            code_lines INTEGER NOT NULL DEFAULT 0,
            comment_lines INTEGER NOT NULL DEFAULT 0,
            complexity INTEGER NOT NULL DEFAULT 0,
            symbol_count INTEGER NOT NULL DEFAULT 0,
            is_test INTEGER NOT NULL DEFAULT 0,
            test_kind TEXT,
            test_evidence TEXT,
            is_generated INTEGER NOT NULL DEFAULT 0,
            is_entry INTEGER NOT NULL DEFAULT 0,
            analyzer TEXT,
            parse_status TEXT NOT NULL DEFAULT 'ok',
            parse_message TEXT,
            indexed_at REAL NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_files_directory ON files(directory_id)",
        "CREATE INDEX IF NOT EXISTS idx_files_module ON files(module_id)",
        "CREATE INDEX IF NOT EXISTS idx_files_name ON files(name COLLATE NOCASE)",
        // `param_types` is '|'-joined; every `conditions` column holds the `#if` stack ' && '-joined, outermost first.
        """
        CREATE TABLE IF NOT EXISTS symbols (
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            parent_id INTEGER REFERENCES symbols(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            qualified_name TEXT NOT NULL,
            kind TEXT NOT NULL,
            start_line INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            signature TEXT,
            doc TEXT,
            visibility TEXT,
            is_exported INTEGER NOT NULL DEFAULT 0,
            attributes TEXT,
            inherits TEXT,
            complexity INTEGER NOT NULL DEFAULT 1,
            body_hash INTEGER,
            depth INTEGER NOT NULL DEFAULT 0,
            selector TEXT,
            param_flags TEXT,
            param_types TEXT,
            declared_type TEXT,
            declared_type_ref INTEGER,
            setter_visibility TEXT,
            conditions TEXT,
            is_local INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id)",
        "CREATE INDEX IF NOT EXISTS idx_symbols_parent ON symbols(parent_id)",
        "CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name)",
        "CREATE INDEX IF NOT EXISTS idx_symbols_name_nocase ON symbols(name COLLATE NOCASE)",
        "CREATE INDEX IF NOT EXISTS idx_symbols_qualified ON symbols(qualified_name COLLATE NOCASE)",
        "CREATE INDEX IF NOT EXISTS idx_symbols_body_hash ON symbols(body_hash) WHERE body_hash IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_symbols_selector ON symbols(selector) WHERE selector IS NOT NULL",
        """
        CREATE TABLE IF NOT EXISTS imports (
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            module TEXT NOT NULL,
            kind TEXT NOT NULL,
            names TEXT,
            line INTEGER NOT NULL,
            is_type_only INTEGER NOT NULL DEFAULT 0,
            is_reexport INTEGER NOT NULL DEFAULT 0,
            end_line INTEGER,
            is_dynamic INTEGER NOT NULL DEFAULT 0,
            is_side_effect INTEGER NOT NULL DEFAULT 0,
            is_mock INTEGER NOT NULL DEFAULT 0,
            is_testable INTEGER NOT NULL DEFAULT 0,
            conditions TEXT,
            resolved_file_id INTEGER REFERENCES files(id) ON DELETE SET NULL,
            resolved_module_id INTEGER REFERENCES modules(id) ON DELETE SET NULL,
            external_name TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_imports_file ON imports(file_id)",
        "CREATE INDEX IF NOT EXISTS idx_imports_resolved ON imports(resolved_file_id)",
        "CREATE INDEX IF NOT EXISTS idx_imports_external ON imports(external_name)",
        "CREATE INDEX IF NOT EXISTS idx_imports_module ON imports(resolved_module_id)",
        """
        CREATE TABLE IF NOT EXISTS exports (
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            exported_name TEXT NOT NULL,
            local_name TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_exports_file ON exports(file_id)",
        // One row per occurrence. `col` is the 1-based UTF-8 byte column (approximate for lexical languages);
        // `receiver_ref` and `symbols.declared_type_ref` point at refs rows of the same file (no foreign key);
        // `arg_labels` is ','-joined ('' = a call without arguments, NULL = not a call); `count` is always 1
        // and kept so every SUM(count) consumer stays exact; `alt_symbol_id` is the unique-name guess that
        // typing rejected.
        """
        CREATE TABLE IF NOT EXISTS refs (
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            from_symbol_id INTEGER REFERENCES symbols(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            context TEXT,
            line INTEGER NOT NULL,
            col INTEGER NOT NULL DEFAULT 0,
            stmt_line INTEGER,
            end_line INTEGER,
            call_end_line INTEGER,
            receiver TEXT,
            receiver_hint TEXT,
            receiver_ref INTEGER,
            type_evidence_line INTEGER,
            arg_labels TEXT,
            conditions TEXT,
            at_load INTEGER NOT NULL DEFAULT 0,
            assigned_to TEXT,
            consumer_line INTEGER,
            count INTEGER NOT NULL DEFAULT 1,
            target_symbol_id INTEGER REFERENCES symbols(id) ON DELETE SET NULL,
            target_file_id INTEGER REFERENCES files(id) ON DELETE SET NULL,
            confidence REAL NOT NULL DEFAULT 0,
            resolved INTEGER NOT NULL DEFAULT 0,
            basis TEXT,
            receiver_type TEXT,
            is_external INTEGER NOT NULL DEFAULT 0,
            external_module TEXT,
            alt_symbol_id INTEGER REFERENCES symbols(id) ON DELETE SET NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_refs_file ON refs(file_id)",
        "CREATE INDEX IF NOT EXISTS idx_refs_file_line ON refs(file_id, line)",
        "CREATE INDEX IF NOT EXISTS idx_refs_from ON refs(from_symbol_id)",
        "CREATE INDEX IF NOT EXISTS idx_refs_target_symbol ON refs(target_symbol_id, confidence)",
        "CREATE INDEX IF NOT EXISTS idx_refs_target_file ON refs(target_file_id)",
        "CREATE INDEX IF NOT EXISTS idx_refs_name ON refs(name)",
        "CREATE INDEX IF NOT EXISTS idx_refs_unresolved ON refs(resolved) WHERE resolved = 0",
        "CREATE INDEX IF NOT EXISTS idx_refs_receiver_ref ON refs(receiver_ref) WHERE receiver_ref IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_refs_receiver_type ON refs(receiver_type) WHERE receiver_type IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_refs_external ON refs(external_module, name) WHERE is_external = 1",
        "CREATE INDEX IF NOT EXISTS idx_refs_alt ON refs(alt_symbol_id) WHERE alt_symbol_id IS NOT NULL",
        """
        CREATE TABLE IF NOT EXISTS file_edges (
            src_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            dst_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            weight INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (src_file_id, dst_file_id, kind)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX IF NOT EXISTS idx_file_edges_dst ON file_edges(dst_file_id, src_file_id)",
        // String literals at use sites, with the call or assignment they feed.
        """
        CREATE TABLE IF NOT EXISTS literals (
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            symbol_id INTEGER REFERENCES symbols(id) ON DELETE CASCADE,
            value TEXT NOT NULL,
            line INTEGER NOT NULL,
            col INTEGER NOT NULL DEFAULT 0,
            context TEXT NOT NULL,
            callee TEXT,
            label TEXT,
            conditions TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_literals_value ON literals(value)",
        "CREATE INDEX IF NOT EXISTS idx_literals_file ON literals(file_id)",
        "CREATE INDEX IF NOT EXISTS idx_literals_symbol ON literals(symbol_id) WHERE symbol_id IS NOT NULL",
        // The project model: build targets (Xcode, SwiftPM, npm), what they depend on and which files they compile.
        """
        CREATE TABLE IF NOT EXISTS targets (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            module_name TEXT,
            system TEXT NOT NULL,
            product_type TEXT,
            platform TEXT,
            deployment_target TEXT,
            bundle_id TEXT,
            is_test INTEGER NOT NULL DEFAULT 0,
            test_kind TEXT,
            test_host TEXT,
            project_path TEXT,
            project_line INTEGER,
            info_plist_path TEXT,
            entitlements_path TEXT,
            extension_point TEXT,
            module_id INTEGER REFERENCES modules(id) ON DELETE SET NULL,
            UNIQUE(system, project_path, name)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS target_deps (
            target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            dep_target_id INTEGER,
            package TEXT,
            evidence_path TEXT,
            evidence_line INTEGER
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS file_targets (
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
            via TEXT NOT NULL,
            evidence_path TEXT,
            evidence_line INTEGER,
            PRIMARY KEY (file_id, target_id)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX IF NOT EXISTS idx_file_targets_target ON file_targets(target_id)",
        """
        CREATE TABLE IF NOT EXISTS packages (
            id INTEGER PRIMARY KEY,
            name TEXT,
            path TEXT,
            url TEXT,
            kind TEXT,
            manifest_path TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS package_products (
            package_id INTEGER REFERENCES packages(id) ON DELETE CASCADE,
            name TEXT,
            kind TEXT,
            targets TEXT,
            manifest_line INTEGER
        )
        """,
        // Links from configuration (schemes, test plans, StoreKit files, entitlements, runner scripts) to code.
        """
        CREATE TABLE IF NOT EXISTS config_links (
            config_path TEXT NOT NULL,
            config_line INTEGER,
            kind TEXT NOT NULL,
            key TEXT,
            file_id INTEGER REFERENCES files(id) ON DELETE CASCADE,
            line INTEGER,
            target_id INTEGER,
            evidence TEXT
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_config_links_kind ON config_links(kind)",
        """
        CREATE TABLE IF NOT EXISTS file_metrics (
            file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            fan_in INTEGER NOT NULL DEFAULT 0,
            fan_out INTEGER NOT NULL DEFAULT 0,
            centrality REAL NOT NULL DEFAULT 0,
            transitive_in INTEGER NOT NULL DEFAULT 0,
            transitive_out INTEGER NOT NULL DEFAULT 0,
            depth INTEGER NOT NULL DEFAULT 0,
            cycle_id INTEGER,
            cycle_size INTEGER,
            cluster_id INTEGER,
            churn INTEGER,
            risk REAL NOT NULL DEFAULT 0,
            hotspot REAL NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_file_metrics_cycle ON file_metrics(cycle_id) WHERE cycle_id IS NOT NULL",
        """
        CREATE TABLE IF NOT EXISTS clusters (
            id INTEGER PRIMARY KEY,
            label TEXT NOT NULL,
            size INTEGER NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS diagnostics (
            id TEXT PRIMARY KEY,
            rule TEXT NOT NULL,
            category TEXT NOT NULL,
            severity TEXT NOT NULL,
            severity_rank INTEGER NOT NULL,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            reason TEXT NOT NULL,
            recommendation TEXT NOT NULL,
            metrics TEXT NOT NULL,
            targets TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_diagnostics_severity ON diagnostics(severity_rank DESC)",
        """
        CREATE TABLE IF NOT EXISTS diagnostic_targets (
            diagnostic_id TEXT NOT NULL REFERENCES diagnostics(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            path TEXT NOT NULL,
            symbol TEXT,
            file_id INTEGER
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_diagnostic_targets_path ON diagnostic_targets(path)",
        "CREATE INDEX IF NOT EXISTS idx_diagnostic_targets_file ON diagnostic_targets(file_id)",
        "CREATE INDEX IF NOT EXISTS idx_diagnostic_targets_diag ON diagnostic_targets(diagnostic_id)",
        """
        CREATE TABLE IF NOT EXISTS reports (
            name TEXT PRIMARY KEY,
            json TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS embeddings (
            file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            content_hash TEXT NOT NULL,
            model TEXT NOT NULL,
            vector BLOB NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS vocabulary (
            term TEXT PRIMARY KEY,
            df INTEGER NOT NULL
        ) WITHOUT ROWID
        """,
        // Full-text search over files: path words, defined symbol names, docs and identifier/comment words.
        // Contentless (the text lives in the repository, not the index) with delete support.
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS fts_files USING fts5(
            path, symbols, docs, body,
            content='', contentless_delete=1,
            tokenize='porter unicode61 remove_diacritics 2'
        )
        """,
        """
        CREATE VIRTUAL TABLE IF NOT EXISTS fts_symbols USING fts5(
            name, words, qualified, doc, path,
            content='', contentless_delete=1,
            tokenize='porter unicode61 remove_diacritics 2'
        )
        """,
    ]

    /// Reads the schema version of an existing database, or nil for a fresh/foreign file.
    public static func existingVersion(_ db: SQLiteDatabase) -> Int? {
        let hasMeta = (try? db.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'meta'")) ?? 0
        guard hasMeta > 0 else { return nil }
        return (try? db.queryOne("SELECT value FROM meta WHERE key = 'schema_version'") { Int($0.string(0)) }) ?? nil
    }

    /// Creates the schema. Callers delete databases with a different version first (indexes are caches of
    /// the repository, so rebuilding is always safe).
    public static func create(_ db: SQLiteDatabase) throws {
        for statement in statements {
            try db.execute(statement)
        }
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)", [String(version)])
    }
}
