import AstroCore
import Foundation

public enum MetadataStoreError: Error, Equatable, Sendable {
    case invalidSchemaVersion
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case invalidRecord(table: String, id: String)
    case metadataDestinationInsideLibrary
    case invalidMetadataDestination
    case cannotCreateMetadataParent
    case unsafeMetadataParent
    case unsafeMetadataDatabase
    case metadataDestinationChanged
    case invalidField(record: String, field: String)
    case staleProjectAnnotation(UUID)
}

public enum MetadataSchema {
    public static let currentVersion = 11

    static let versionOneSQL = """
    CREATE TABLE projects(
      id TEXT PRIMARY KEY NOT NULL,
      catalog_id TEXT NOT NULL COLLATE NOCASE UNIQUE,
      display_name TEXT NOT NULL,
      phase TEXT NOT NULL CHECK(phase IN ('planned', 'collecting', 'processing', 'complete', 'archived'))
    );
    CREATE TABLE nights(
      id TEXT PRIMARY KEY NOT NULL,
      local_date TEXT NOT NULL,
      time_zone_id TEXT NOT NULL,
      UNIQUE(local_date, time_zone_id)
    );
    CREATE TABLE series(
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
      night_id TEXT NOT NULL REFERENCES nights(id) ON DELETE RESTRICT,
      setup_id TEXT,
      setup_descriptor TEXT NOT NULL,
      sensor_mode TEXT NOT NULL CHECK(sensor_mode IN ('osc', 'mono', 'dslr', 'unknown')),
      passband TEXT NOT NULL CHECK(passband IN ('broadband', 'dual_band', 'narrowband', 'lrgb', 'luminance', 'unfiltered', 'other', 'unknown')),
      exposure_seconds REAL NOT NULL CHECK(exposure_seconds > 0),
      filter_name TEXT,
      filter_id TEXT,
      gain REAL,
      offset REAL,
      binning TEXT NOT NULL CHECK(length(binning) > 0)
    );
    CREATE TABLE frame_decisions(
      id TEXT PRIMARY KEY NOT NULL,
      series_id TEXT NOT NULL REFERENCES series(id) ON DELETE RESTRICT,
      relative_path TEXT NOT NULL UNIQUE,
      verdict TEXT NOT NULL CHECK(verdict IN ('undecided', 'accepted', 'rejected')),
      logically_excluded INTEGER NOT NULL CHECK(logically_excluded IN (0, 1))
    );
    CREATE INDEX idx_series_project ON series(project_id);
    CREATE INDEX idx_series_night ON series(night_id);
    CREATE INDEX idx_frame_decisions_series ON frame_decisions(series_id);
    """

    static let versionTwoSQL = """
    CREATE TABLE results(
      id TEXT PRIMARY KEY NOT NULL,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
      parent_result_id TEXT REFERENCES results(id) ON DELETE RESTRICT,
      kind TEXT NOT NULL CHECK(kind IN ('stack', 'processing_variant')),
      role TEXT NOT NULL CHECK(role IN ('intermediate', 'starless', 'mask', 'final')),
      relative_path TEXT UNIQUE,
      created_at REAL NOT NULL,
      software_name TEXT,
      software_version TEXT,
      CHECK(parent_result_id IS NULL OR parent_result_id <> id),
      CHECK(
        (software_name IS NULL AND software_version IS NULL)
        OR (software_name IS NOT NULL AND software_version IS NOT NULL)
      )
    );
    CREATE TABLE lineage_edges(
      id TEXT PRIMARY KEY NOT NULL,
      result_id TEXT NOT NULL REFERENCES results(id) ON DELETE RESTRICT,
      source_kind TEXT NOT NULL CHECK(source_kind IN ('series', 'frame', 'result')),
      source_series_id TEXT REFERENCES series(id) ON DELETE RESTRICT,
      source_frame_id TEXT REFERENCES frame_decisions(id) ON DELETE RESTRICT,
      source_result_id TEXT REFERENCES results(id) ON DELETE RESTRICT,
      CHECK(source_result_id IS NULL OR source_result_id <> result_id),
      CHECK(
        (source_kind = 'series' AND source_series_id IS NOT NULL AND source_frame_id IS NULL AND source_result_id IS NULL)
        OR (source_kind = 'frame' AND source_series_id IS NULL AND source_frame_id IS NOT NULL AND source_result_id IS NULL)
        OR (source_kind = 'result' AND source_series_id IS NULL AND source_frame_id IS NULL AND source_result_id IS NOT NULL)
      )
    );
    CREATE TABLE review_states(
      id TEXT PRIMARY KEY NOT NULL,
      series_id TEXT NOT NULL REFERENCES series(id) ON DELETE RESTRICT UNIQUE,
      status TEXT NOT NULL CHECK(status IN ('pending', 'in_progress', 'complete')),
      updated_at REAL NOT NULL
    );
    CREATE TABLE mutation_journal(
      id TEXT PRIMARY KEY NOT NULL,
      operation_id TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('planned', 'applying', 'applied', 'rolling_back', 'rolled_back', 'failed')),
      created_at REAL NOT NULL,
      payload_json TEXT NOT NULL
    );
    CREATE INDEX idx_results_project ON results(project_id);
    CREATE INDEX idx_results_parent ON results(parent_result_id);
    CREATE INDEX idx_lineage_result ON lineage_edges(result_id);
    CREATE UNIQUE INDEX idx_lineage_series_source ON lineage_edges(result_id, source_series_id)
      WHERE source_kind = 'series';
    CREATE UNIQUE INDEX idx_lineage_frame_source ON lineage_edges(result_id, source_frame_id)
      WHERE source_kind = 'frame';
    CREATE UNIQUE INDEX idx_lineage_result_source ON lineage_edges(result_id, source_result_id)
      WHERE source_kind = 'result';
    CREATE INDEX idx_review_states_series ON review_states(series_id);
    CREATE INDEX idx_mutation_journal_operation ON mutation_journal(operation_id, created_at);
    """

    static let versionThreeSQL = """
    CREATE TABLE legacy_imports(
      id TEXT PRIMARY KEY NOT NULL,
      source_key TEXT NOT NULL UNIQUE,
      kind TEXT NOT NULL CHECK(kind IN (
        'tag', 'session_note', 'frame_verdict', 'filter_profile',
        'capture_group', 'capture_source', 'capture_assignment',
        'acknowledgement', 'user_configuration', 'conversion_receipt',
        'quarantine_receipt', 'legacy_sensor_measurement'
      )),
      payload_json TEXT NOT NULL CHECK(json_valid(payload_json))
    );
    CREATE INDEX idx_legacy_imports_kind ON legacy_imports(kind, source_key);
    """

    static let versionFourSQL = """
    CREATE TABLE project_annotations(
      project_id TEXT PRIMARY KEY NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      integration_goal_hours REAL CHECK(integration_goal_hours IS NULL OR integration_goal_hours > 0),
      notes TEXT NOT NULL DEFAULT '',
      updated_at REAL NOT NULL
    );
    CREATE INDEX idx_project_annotations_updated ON project_annotations(updated_at DESC);
    """

    static let versionFiveSQL = """
    CREATE TABLE audit_acknowledgements(
      id TEXT PRIMARY KEY,
      ack_key TEXT NOT NULL UNIQUE,
      category TEXT NOT NULL,
      group_key TEXT NOT NULL,
      acked_at TEXT NOT NULL,
      note TEXT
    );
    CREATE TABLE audit_run_history(
      id TEXT PRIMARY KEY,
      ran_at TEXT NOT NULL,
      finding_count INTEGER NOT NULL,
      group_keys TEXT NOT NULL
    );
    CREATE INDEX idx_audit_run_history_ran_at ON audit_run_history(ran_at);
    """

    /// Planning's saved-targets list (wave 5 Task 4) -- one row per bookmarked
    /// catalog designation, with an optional free-text note. `designation`
    /// is `UNIQUE` so `MetadataStore.saveTarget` can upsert on it the same
    /// way `acknowledgeFindingGroup` upserts on `ack_key`.
    static let versionSixSQL = """
    CREATE TABLE IF NOT EXISTS planning_saved_targets (
        id TEXT PRIMARY KEY,
        designation TEXT NOT NULL UNIQUE,
        saved_at TEXT NOT NULL,
        note TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_planning_saved_targets_saved_at ON planning_saved_targets(saved_at);
    """

    /// Archive Map's freshness signal (wave 6 Task 15) -- ONE row recording
    /// when V2's own scan pipeline (`ScanWorkflowMaterializer.materialize`)
    /// last completed successfully. Not a history: `MetadataStore.
    /// recordScanCompleted` upserts the single `singleton = 1` row, the same
    /// shape as `metadata_schema` itself. This deliberately does NOT read
    /// from the read-only index's `runs` table -- only `AuditEngine`,
    /// `FixityVerifier` and V1's `AppState` ever write a `runs` row, and V2's
    /// scan path never does, so `runs WHERE kind = 'scan'` never has a row
    /// to find on a real library.
    static let versionSevenSQL = """
    CREATE TABLE IF NOT EXISTS scan_completions (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
        completed_at TEXT NOT NULL
    );
    """

    /// W4-6 (owner decision, 2026-08-17): drops `results`/`lineage_edges`,
    /// the two tables from `versionTwoSQL` that no writer anywhere in V1 or
    /// V2 has ever inserted a row into (verified against the owner's real
    /// `metadata.sqlite`: 0 rows in both, always). The owner stacks in
    /// Siril and selects there by hand -- "válogatás és az archiválás
    /// kell... szóval eltávolítás" ("triage and archiving is what's
    /// needed... so removal") -- this app's job is triage and archiving,
    /// not lineage tracking.
    ///
    /// `results` first, `lineage_edges` second: `DROP TABLE` with
    /// `PRAGMA foreign_keys = ON` performs an implicit `DELETE FROM` before
    /// removing the table, and that delete is checked against every FK that
    /// still exists at that moment. On a real (empty) install both deletes
    /// affect zero rows and the order is inert. Dropping `results` first
    /// only matters for the failure path this same ordering makes possible
    /// to test deterministically: with a `lineage_edges` row still present
    /// referencing a `results` row, `DROP TABLE results`'s implicit delete
    /// hits that row's `ON DELETE RESTRICT` and fails outright (proven at
    /// the SQLite level before writing this), which rolls the whole
    /// migration transaction back via `transaction(in:_:)` below -- see
    /// `MetadataStoreTests.failedVersionEightMigrationDoesNotAdvanceVersion`.
    /// The reverse order would let `lineage_edges` drop silently while
    /// `results` (still referenced by nothing at that point) might not fail
    /// at all, which would defeat that test's ability to force a real
    /// rollback to check.
    static let versionEightSQL = """
    DROP TABLE results;
    DROP TABLE lineage_edges;
    """

    static let versionNineSQL = "ALTER TABLE project_annotations ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;"
    static let versionTenSQL = "ALTER TABLE project_annotations ADD COLUMN mobile_change_ids TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(mobile_change_ids));"
    static let versionElevenSQL = "ALTER TABLE project_annotations ADD COLUMN mobile_change_markers TEXT NOT NULL DEFAULT '[]' CHECK(json_valid(mobile_change_markers));"

    static func migrate(_ database: SQLiteDB) throws {
        try transaction(in: database) {
            var version = try readVersion(in: database)
            guard version <= currentVersion else {
                throw MetadataStoreError.unsupportedSchemaVersion(
                    found: version,
                    supported: currentVersion
                )
            }

            if version < 1 {
                try database.exec("""
                CREATE TABLE metadata_schema(
                  singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                  version INTEGER NOT NULL CHECK(version >= 0)
                );
                """)
                try database.exec(versionOneSQL)
                try database.run(
                    "INSERT INTO metadata_schema(singleton, version) VALUES (1, 1);"
                )
                version = 1
            }

            if version < 2 {
                try database.exec(versionTwoSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 2 WHERE singleton = 1;"
                )
                version = 2
            }

            if version < 3 {
                try database.exec(versionThreeSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 3 WHERE singleton = 1;"
                )
                version = 3
            }

            if version < 4 {
                try database.exec(versionFourSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 4 WHERE singleton = 1;"
                )
                version = 4
            }

            if version < 5 {
                try database.exec(versionFiveSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 5 WHERE singleton = 1;"
                )
                version = 5
            }

            if version < 6 {
                try database.exec(versionSixSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 6 WHERE singleton = 1;"
                )
                version = 6
            }

            if version < 7 {
                try database.exec(versionSevenSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 7 WHERE singleton = 1;"
                )
                version = 7
            }

            if version < 8 {
                try database.exec(versionEightSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 8 WHERE singleton = 1;"
                )
                version = 8
            }

            if version < 9 {
                try database.exec(versionNineSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 9 WHERE singleton = 1;"
                )
                version = 9
            }

            if version < 10 {
                try database.exec(versionTenSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 10 WHERE singleton = 1;"
                )
                version = 10
            }

            if version < 11 {
                try database.exec(versionElevenSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 11 WHERE singleton = 1;"
                )
            }
        }
    }

    static func rejectUnsupportedSchema(at databaseURL: URL) throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        let probe = try SQLiteDB(readOnlyPath: databaseURL.path)
        let version = try readVersion(in: probe)
        guard version <= currentVersion else {
            throw MetadataStoreError.unsupportedSchemaVersion(
                found: version,
                supported: currentVersion
            )
        }
    }

    static func readVersion(in database: SQLiteDB) throws -> Int {
        guard try tableExists("metadata_schema", in: database) else { return 0 }
        var versions: [Int] = []
        try database.query(
            "SELECT version FROM metadata_schema WHERE singleton = 1;"
        ) { row in
            if let value = row.int64(0) {
                versions.append(Int(value))
            }
        }
        guard versions.count == 1, let version = versions.first, version >= 0 else {
            throw MetadataStoreError.invalidSchemaVersion
        }
        return version
    }

    private static func tableExists(_ name: String, in database: SQLiteDB) throws -> Bool {
        var exists = false
        try database.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            bind: [.text(name)]
        ) { _ in exists = true }
        return exists
    }

    private static func transaction(
        in database: SQLiteDB,
        _ body: () throws -> Void
    ) throws {
        try database.exec("BEGIN IMMEDIATE;")
        do {
            try body()
            try database.exec("COMMIT;")
        } catch {
            try? database.exec("ROLLBACK;")
            throw error
        }
    }
}
