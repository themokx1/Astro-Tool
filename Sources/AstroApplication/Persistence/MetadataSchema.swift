import AstroCore
import Foundation

public enum MetadataStoreError: Error, Equatable, Sendable {
    case invalidSchemaVersion
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case invalidRecord(table: String, id: String)
}

public enum MetadataSchema {
    public static let currentVersion = 2

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

    static func migrate(_ database: SQLiteDB) throws {
        var version = try readVersion(in: database)
        guard version <= currentVersion else {
            throw MetadataStoreError.unsupportedSchemaVersion(
                found: version,
                supported: currentVersion
            )
        }

        if version < 1 {
            try transaction(in: database) {
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
            }
            version = 1
        }

        if version < 2 {
            try transaction(in: database) {
                try database.exec(versionTwoSQL)
                try database.run(
                    "UPDATE metadata_schema SET version = 2 WHERE singleton = 1;"
                )
            }
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
