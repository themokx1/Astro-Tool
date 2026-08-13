@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct InsightsQueryTests {
    @Test("Insights carries session quality focus and efficiency trend points")
    func exposesQualityTrendSeries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL);
        """)
        let points = [TrendPoint(
            target: "IC1396", date: "2026-08-08", sessionStartDate: "2026-08-08",
            medianFWHMArcsec: 2.4, backgroundEPerSecPerArcsec2: 0.003,
            efficiencyPercent: 82, setupDescriptor: "ASI2600MC · 261 mm"
        )]

        let result = try await InsightsQuery(
            indexDatabaseForTesting: index,
            trendPointsForTesting: { points }
        ).snapshot()

        #expect(result.trendPoints == points)
        #expect(result.setupChoices == ["ASI2600MC · 261 mm"])
    }

    @Test("Insights aggregate capture time, nights, targets and monthly activity from the external index")
    func aggregatesExternalIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL, filter TEXT, instrume TEXT, focallen REAL);
        CREATE TABLE user_verdicts(file_id INTEGER PRIMARY KEY, accepted INTEGER NOT NULL);
        INSERT INTO files VALUES(1,'sessions','M42','2026-01-10','light',0);
        INSERT INTO files VALUES(2,'sessions','M42','2026-01-10','light',0);
        INSERT INTO files VALUES(3,'sessions','IC1396','2026-08-08','light',0);
        INSERT INTO files VALUES(4,'sessions','IC1396','2026-08-08','flat',0);
        INSERT INTO files VALUES(5,'sessions','M31','2025-09-01','light',0);
        INSERT INTO fits_meta VALUES(1,300,'SV220','ASI2600MC',261);
        INSERT INTO fits_meta VALUES(2,300,'SV220','ASI2600MC',261);
        INSERT INTO fits_meta VALUES(3,120,NULL,'ASI2600MC',200);
        INSERT INTO fits_meta VALUES(5,600,'L','ASI2600MM',500);
        INSERT INTO user_verdicts VALUES(2,0);
        """)

        let result = try await InsightsQuery(indexDatabaseForTesting: index).snapshot()

        #expect(result.nightCount == 3)
        #expect(result.targetCount == 3)
        #expect(result.frameCount == 4)
        #expect(result.integrationSeconds == 1320)
        #expect(result.months.map(\.month) == ["2025-09", "2026-01", "2026-08"])
        #expect(result.topTargets.first?.target == "M31")
        #expect(result.filterUsage.first?.name == "L")
        #expect(result.filterUsage.first?.frameCount == 1)
        #expect(result.setupUsage.first?.camera == "ASI2600MC")
        #expect(result.bestMonth?.month == "2025-09")
        #expect(result.averageIntegrationPerNight == 440)
        #expect(result.rejectedFrameCount == 1)
        #expect(result.usableFrameCount == 3)
        #expect(result.captureEfficiency == 0.75)
        #expect(result.isReadOnly)

        let year = try await InsightsQuery(indexDatabaseForTesting: index).snapshot(year: 2026)
        #expect(year.nightCount == 2)
        #expect(year.targetCount == 2)
        #expect(year.frameCount == 3)
        #expect(year.integrationSeconds == 720)
        #expect(year.months.map(\.month) == ["2026-01", "2026-08"])
        #expect(year.topTargets.first?.target == "M42")
        #expect(year.filterUsage.first?.name == "SV220")
        #expect(year.filterUsage.first?.frameCount == 2)
        #expect(year.bestMonth?.month == "2026-01")
        #expect(year.rejectedFrameCount == 1)
    }
}
