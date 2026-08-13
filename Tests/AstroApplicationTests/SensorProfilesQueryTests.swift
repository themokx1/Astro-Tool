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
        CREATE TABLE sensor_profile(camera TEXT NOT NULL,gain REAL,offset REAL,bias_level_adu REAL,read_noise_e REAL,dark_rate_e_per_s REAL,dark_temp_c REAL,egain REAL,measured_at REAL NOT NULL,frame_count INTEGER,PRIMARY KEY(camera,gain,offset));
        INSERT INTO sensor_profile VALUES('ZWO ASI2600MC Pro',100,50,500.2,1.4,0.003,-10,0.76,1786147200,40);
        """)

        let snapshot = try await SensorProfilesQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.profiles.count == 1)
        #expect(snapshot.profiles[0].camera == "ZWO ASI2600MC Pro")
        #expect(snapshot.profiles[0].readNoiseElectrons == 1.4)
        #expect(snapshot.profiles[0].frameCount == 40)
        #expect(snapshot.isReadOnly)
    }
}
