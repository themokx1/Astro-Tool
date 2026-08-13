@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct SensorProfilesQueryTests {
    @Test("Sensor inventory reads measured values from the external index")
    func readsProfiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE sensor_profile(camera TEXT NOT NULL,gain REAL,offset REAL,bias_level_adu REAL,read_noise_e REAL,dark_rate_e_per_s REAL,dark_temp_c REAL,egain REAL,measured_at REAL NOT NULL,frame_count INTEGER,estimator_version INTEGER,PRIMARY KEY(camera,gain,offset));
        INSERT INTO sensor_profile VALUES('ZWO ASI2600MC Pro',100,50,500.2,1.4,0.003,-10,0.76,1786147200,40,2);
        """)

        let snapshot = try await SensorProfilesQuery(indexDatabase: index).snapshot()

        #expect(snapshot.profiles.count == 1)
        #expect(snapshot.profiles[0].camera == "ZWO ASI2600MC Pro")
        #expect(snapshot.profiles[0].readNoiseElectrons == 1.4)
        #expect(snapshot.profiles[0].frameCount == 40)
        #expect(snapshot.profiles[0].history.isEmpty)
        #expect(snapshot.missingCombos.isEmpty)
        #expect(snapshot.isReadOnly)
    }

    /// A pre-schema-v10 index database has `sensor_profile` but never
    /// created `sensor_profile_history`, `files`, or `fits_meta` -- a
    /// read-only snapshot never migrates the database it opens, so this is
    /// a real state to tolerate, not just old-test noise.
    @Test("Reading a bare index database with no history or files table still returns the profile, with no history and no missing combos")
    func readsProfilesFromBareIndexWithoutHistoryOrFilesTables() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE sensor_profile(camera TEXT NOT NULL,gain REAL,offset REAL,bias_level_adu REAL,read_noise_e REAL,dark_rate_e_per_s REAL,dark_temp_c REAL,egain REAL,measured_at REAL NOT NULL,frame_count INTEGER,PRIMARY KEY(camera,gain,offset));
        INSERT INTO sensor_profile VALUES('ZWO ASI2600MC Pro',100,50,500.2,1.4,0.003,-10,0.76,1786147200,40);
        """)

        let snapshot = try await SensorProfilesQuery(indexDatabase: index).snapshot()

        #expect(snapshot.profiles.count == 1)
        #expect(snapshot.profiles[0].history.isEmpty)
        #expect(snapshot.profiles[0].estimatorVersion == nil)
        #expect(snapshot.profiles[0].isEstimatorStale)
        #expect(snapshot.missingCombos.isEmpty)
    }

    @Test("A profile's history reads sensor_profile_history rows in chronological order")
    func historyReadsChronologically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE sensor_profile(camera TEXT NOT NULL,gain REAL,offset REAL,bias_level_adu REAL,read_noise_e REAL,dark_rate_e_per_s REAL,dark_temp_c REAL,egain REAL,measured_at REAL NOT NULL,frame_count INTEGER,estimator_version INTEGER,PRIMARY KEY(camera,gain,offset));
        CREATE TABLE sensor_profile_history(id INTEGER PRIMARY KEY,camera TEXT NOT NULL,gain REAL,offset REAL,bias_level_adu REAL,read_noise_e REAL,dark_rate_e_per_s REAL,dark_temp_c REAL,egain REAL,measured_at REAL NOT NULL,estimator_version INTEGER);
        INSERT INTO sensor_profile VALUES('ZWO ASI2600MC Pro',100,50,510,1.5,0.004,-10,0.76,1786233600,42,2);
        INSERT INTO sensor_profile_history VALUES(1,'ZWO ASI2600MC Pro',100,50,500.2,1.4,0.003,-10,0.76,1786147200,2);
        INSERT INTO sensor_profile_history VALUES(2,'ZWO ASI2600MC Pro',100,50,510,1.5,0.004,-10,0.76,1786233600,2);
        """)

        let snapshot = try await SensorProfilesQuery(indexDatabase: index).snapshot()

        let profile = try #require(snapshot.profiles.first)
        #expect(profile.history.count == 2)
        #expect(profile.history.map(\.readNoiseElectrons) == [1.4, 1.5])
        #expect(profile.history[0].measuredAt < profile.history[1].measuredAt)
        #expect(!profile.isEstimatorStale)
    }

    @Test("Missing combos surface a light-frame camera/gain/offset combo with no usable measured profile")
    func missingCombosSurfaceALightsComboWithNoUsableProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE sensor_profile(camera TEXT NOT NULL,gain REAL,offset REAL,bias_level_adu REAL,read_noise_e REAL,dark_rate_e_per_s REAL,dark_temp_c REAL,egain REAL,measured_at REAL NOT NULL,frame_count INTEGER,estimator_version INTEGER,PRIMARY KEY(camera,gain,offset));
        CREATE TABLE files(id INTEGER PRIMARY KEY,path TEXT UNIQUE NOT NULL,size INTEGER NOT NULL,mtime REAL NOT NULL,ext TEXT NOT NULL,kind TEXT NOT NULL,area TEXT NOT NULL,target TEXT,session_date TEXT,role TEXT NOT NULL,scanned_at REAL NOT NULL,missing INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY REFERENCES files(id),gain REAL,"offset" REAL,instrume TEXT);
        INSERT INTO files VALUES(1,'sessions/M31/2026-01-01/lights/a.fit',1024,1700000000,'fit','fits','sessions',NULL,NULL,'light',1700000100,0);
        INSERT INTO fits_meta VALUES(1,100,50,'ASI2600MC');
        """)

        let snapshot = try await SensorProfilesQuery(indexDatabase: index).snapshot()

        #expect(snapshot.missingCombos.count == 1)
        #expect(snapshot.missingCombos[0].camera == "ASI2600MC")
        #expect(snapshot.missingCombos[0].gain == 100)
        #expect(snapshot.missingCombos[0].offset == 50)
    }

    @Test("Missing combos exclude a combo that already has a usable measured profile")
    func missingCombosExcludeAComboWithAUsableProfile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE sensor_profile(camera TEXT NOT NULL,gain REAL,offset REAL,bias_level_adu REAL,read_noise_e REAL,dark_rate_e_per_s REAL,dark_temp_c REAL,egain REAL,measured_at REAL NOT NULL,frame_count INTEGER,estimator_version INTEGER,PRIMARY KEY(camera,gain,offset));
        CREATE TABLE files(id INTEGER PRIMARY KEY,path TEXT UNIQUE NOT NULL,size INTEGER NOT NULL,mtime REAL NOT NULL,ext TEXT NOT NULL,kind TEXT NOT NULL,area TEXT NOT NULL,target TEXT,session_date TEXT,role TEXT NOT NULL,scanned_at REAL NOT NULL,missing INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY REFERENCES files(id),gain REAL,"offset" REAL,instrume TEXT);
        INSERT INTO files VALUES(1,'sessions/M31/2026-01-01/lights/a.fit',1024,1700000000,'fit','fits','sessions',NULL,NULL,'light',1700000100,0);
        INSERT INTO fits_meta VALUES(1,100,50,'ASI2600MC');
        INSERT INTO sensor_profile VALUES('ASI2600MC',100,50,501,1.2,0.002,-10,0.75,1700000000,10,2);
        """)

        let snapshot = try await SensorProfilesQuery(indexDatabase: index).snapshot()

        #expect(snapshot.missingCombos.isEmpty)
    }
}
