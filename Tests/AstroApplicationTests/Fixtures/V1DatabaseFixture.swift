import AstroCore
import Foundation

struct V1DatabaseFixture {
    let root: URL
    let storeDirectory: URL
    let databaseURL: URL
    let database: SQLiteDB

    static func make() throws -> V1DatabaseFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-V1Import-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = root.appendingPathComponent(".astro_tool", isDirectory: true)
        try FileManager.default.createDirectory(
            at: store.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: store.appendingPathComponent("conversions/conversion-1", isDirectory: true),
            withIntermediateDirectories: true
        )
        let databaseURL = store.appendingPathComponent("astrotool.sqlite")
        let database = try SQLiteDB(path: databaseURL.path)
        try database.exec("PRAGMA wal_autocheckpoint=0;")
        try database.exec("""
        CREATE TABLE schema_version(version INTEGER NOT NULL);
        INSERT INTO schema_version(version) VALUES (12);
        CREATE TABLE tags(
          id INTEGER PRIMARY KEY, kind TEXT NOT NULL, target TEXT NOT NULL,
          session_date TEXT, tag TEXT NOT NULL
        );
        CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL);
        CREATE TABLE user_verdicts(
          file_id INTEGER PRIMARY KEY, accepted INTEGER NOT NULL,
          source TEXT NOT NULL, recorded_at REAL NOT NULL
        );
        CREATE TABLE session_notes(
          target TEXT NOT NULL, session_date TEXT NOT NULL,
          key TEXT NOT NULL, value TEXT NOT NULL
        );
        CREATE TABLE finding_acks(
          ack_key TEXT PRIMARY KEY, category TEXT NOT NULL, group_key TEXT NOT NULL,
          acked_at REAL NOT NULL, note TEXT
        );
        CREATE TABLE filter_profiles(
          id INTEGER PRIMARY KEY, manufacturer TEXT, model TEXT, name TEXT,
          signal_mode TEXT NOT NULL, notes TEXT, identity_key TEXT NOT NULL,
          created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE capture_groups(
          id INTEGER PRIMARY KEY, target TEXT NOT NULL, session_date TEXT NOT NULL,
          slug TEXT NOT NULL, display_name TEXT NOT NULL, sensor_mode TEXT NOT NULL,
          signal_mode TEXT NOT NULL, filter_manufacturer TEXT, filter_model TEXT,
          filter_name TEXT, notes TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE capture_sources(
          id INTEGER PRIMARY KEY, capture_group_id INTEGER NOT NULL,
          relative_path TEXT NOT NULL, role TEXT NOT NULL
        );
        CREATE TABLE file_capture_assignments(
          file_id INTEGER PRIMARY KEY, capture_group_id INTEGER NOT NULL,
          sensor_mode_override TEXT, signal_mode_override TEXT,
          filter_manufacturer_override TEXT, filter_model_override TEXT,
          filter_name_override TEXT, assignment_source TEXT NOT NULL,
          assigned_at REAL NOT NULL
        );
        CREATE TABLE sensor_profile(
          camera TEXT NOT NULL, gain REAL, offset REAL, bias_level_adu REAL,
          read_noise_e REAL, dark_rate_e_per_s REAL, dark_temp_c REAL, egain REAL,
          measured_at REAL NOT NULL, frame_count INTEGER, estimator_version INTEGER
        );
        CREATE TABLE sensor_profile_history(
          id INTEGER PRIMARY KEY, camera TEXT NOT NULL, gain REAL, offset REAL,
          bias_level_adu REAL, read_noise_e REAL, dark_rate_e_per_s REAL,
          dark_temp_c REAL, egain REAL, measured_at REAL NOT NULL,
          estimator_version INTEGER
        );
        """)
        try database.run(
            "INSERT INTO tags(kind, target, session_date, tag) VALUES (?, ?, ?, ?);",
            bind: [.text("target"), .text("IC_1396"), .null, .text("goal:10h")]
        )
        try database.exec("""
        INSERT INTO files(id, path) VALUES (41, 'sessions/IC_1396/2026-08-08/lights/frame.fit');
        INSERT INTO user_verdicts VALUES (41, 0, 'app', 1786404200);
        INSERT INTO session_notes VALUES ('IC_1396', '2026-08-08', 'Transparency', 'jó');
        INSERT INTO finding_acks VALUES ('residue|x', 'residue', 'x', 1786404200, 'ellenőrizve');
        INSERT INTO filter_profiles VALUES (3, 'SVBONY', 'SV220', 'SV220', 'dual_band', 'Ha/OIII', 'sv220', 1, 2);
        INSERT INTO capture_groups VALUES (9, 'IC_1396', '2026-08-08', 'sv220-300s', 'SV220 300 s', 'osc', 'dual_band', 'SVBONY', 'SV220', 'SV220', NULL, 1, 2);
        INSERT INTO capture_sources VALUES (5, 9, 'sessions/IC_1396/2026-08-08/lights', 'light');
        INSERT INTO file_capture_assignments VALUES (41, 9, NULL, NULL, NULL, NULL, NULL, 'app', 1786404200);
        INSERT INTO sensor_profile VALUES ('ASI2600MC', 100, 50, 500, 1.3, 0.01, -10, 0.25, 1786404200, 20, 2);
        INSERT INTO sensor_profile_history VALUES (77, 'ASI2600MC', 100, 50, 501, 1.4, 0.02, -10, 0.25, 1786404100, 1);
        """)

        try Data("Bortle: 4\nSeeing: jó\n".utf8).write(
            to: store.appendingPathComponent("notes/IC_1396-2026-08-08.txt")
        )
        try Data("{\"site\":{\"name\":\"Teszt égbolt\"}}\n".utf8).write(
            to: store.appendingPathComponent("config.json")
        )
        try Data("{\"status\":\"applied\",\"id\":\"conversion-1\"}\n".utf8).write(
            to: store.appendingPathComponent("conversions/conversion-1/receipt.json")
        )
        try FileManager.default.createDirectory(
            at: store.appendingPathComponent("cleanup_quarantine/batch-1", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{\"status\":\"quarantined\"}\n".utf8).write(
            to: store.appendingPathComponent("cleanup_quarantine/batch-1/receipt.json")
        )
        return V1DatabaseFixture(
            root: root,
            storeDirectory: store,
            databaseURL: databaseURL,
            database: database
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
