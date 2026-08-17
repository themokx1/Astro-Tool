@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Pads a FITS card line to 80 characters, block-pads to 2880 -- mirrors
/// `Tests/AstroCoreTests/FITSTestBuilder.swift`'s helper of the same shape;
/// duplicated here because AstroApplicationTests cannot import
/// AstroCoreTests' file-private test target (same note
/// `CalibrationQueryTests.swift`/`ExportServiceTests.swift` already carry
/// for themselves).
private func insightsCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func insightsHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(insightsCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// A fresh fixture library + fresh sqlite-backed `Database`, real files
/// scanned by `LibraryScanner` -- NOT a hand-rolled ad hoc `files` table.
/// `InsightsQuery.snapshot` now runs its integration/frame totals through
/// `Database.allFiles`/`fitsMetaBatch` + `FrameSet.lightBuckets` (the same
/// dedup engine `StatsQueries`/`astrotool stats` use), which needs real
/// `path`/`inode` columns a minimal `CREATE TABLE files(id, area, target,
/// session_date, role, missing)` never had.
private struct InsightsQueryFixture {
    let libraryDir: URL
    let dbDir: URL
    let indexURL: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> InsightsQueryFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insights-query-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insights-query-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let indexURL = dbDir.appendingPathComponent("test.sqlite")
        let db = try Database(path: indexURL.path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return InsightsQueryFixture(libraryDir: libraryDir, dbDir: dbDir, indexURL: indexURL, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    @discardableResult
    func writeFITSLight(
        _ relativePath: String,
        exptime: Double? = nil,
        filter: String? = nil,
        instrume: String? = nil,
        focallen: Double? = nil,
        dateObs: String? = nil
    ) throws -> URL {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let filter { cards.append("FILTER  = '\(filter)'") }
        if let instrume { cards.append("INSTRUME= '\(instrume)'") }
        if let focallen { cards.append("FOCALLEN=                \(focallen)") }
        if let dateObs { cards.append("DATE-OBS= '\(dateObs)'") }
        cards.append("END")
        try insightsHeaderData(cards).write(to: url)
        return url
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }

    /// The real `InsightsQuery` production would build for this fixture --
    /// `libraryForTesting` reads from the SAME `db`/`config` `snapshot`'s raw
    /// SQL half reads from (`indexDatabaseForTesting: indexURL`), so both
    /// halves of a snapshot always agree on what's in the library.
    func query() -> InsightsQuery {
        let db = self.db
        let config = self.config
        return InsightsQuery(
            indexDatabaseForTesting: indexURL,
            trendPointsForTesting: { [] },
            libraryForTesting: {
                let files = try db.allFiles(includeMissing: false)
                let meta = try db.fitsMetaBatch(fileIDs: files.compactMap(\.id))
                return (files, meta, config)
            }
        )
    }
}

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

    @Test("Insights aggregate capture time, nights, targets and monthly activity from the scanned library")
    func aggregatesExternalIndex() async throws {
        let fixture = try InsightsQueryFixture.make()
        defer { fixture.cleanup() }

        // Two distinct M42 frames (different files, different inodes -- NOT
        // duplicates of each other) sharing a session/exposure/setup.
        try fixture.writeFITSLight(
            "sessions/M42/2026-01-10/lights/l1.fit", exptime: 300, filter: "SV220", instrume: "ASI2600MC", focallen: 261
        )
        try fixture.writeFITSLight(
            "sessions/M42/2026-01-10/lights/l2.fit", exptime: 300, filter: "SV220", instrume: "ASI2600MC", focallen: 261
        )
        try fixture.writeFITSLight(
            "sessions/IC1396/2026-08-08/lights/l1.fit", exptime: 120, instrume: "ASI2600MC", focallen: 200
        )
        // Must NOT count toward any total: a flat frame.
        try fixture.writeFITSLight("sessions/IC1396/2026-08-08/flats/f1.fit")
        try fixture.writeFITSLight(
            "sessions/M31/2025-09-01/lights/l1.fit", exptime: 600, filter: "L", instrume: "ASI2600MM", focallen: 500
        )

        try fixture.scan()
        // DSS-rejects one of the M42 (2026-01-10) lights -- matching the
        // original fixture, which rejected a 2026 frame so the `year: 2026`
        // assertions below still see it.
        let rejectedFile = try #require(try fixture.db.allFiles(includeMissing: false).first {
            $0.target == "M42" && $0.role == .light && $0.path.hasSuffix("l2.fit")
        })
        try fixture.db.setUserVerdict(fileID: try #require(rejectedFile.id), accepted: false, source: "test")

        let result = try await fixture.query().snapshot()

        #expect(result.nightCount == 3)
        #expect(result.targetCount == 3)
        #expect(result.frameCount == 4)
        #expect(result.integrationSeconds == 1320)
        #expect(result.grossIntegrationSeconds == 1320)
        #expect(!result.hasDuplicateExposure)
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

        let year = try await fixture.query().snapshot(year: 2026)
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

    // MARK: - Owner feedback wave 3, Task 2: don't count the same frame twice

    /// The exact bug the owner measured: light frames present twice in the
    /// index (a hardlinked triage copy, the real-world shape "207 light
    /// frames sharing a filename" turned out to be) inflated the Insights
    /// total by counting the same physical exposure once per row. This
    /// mirrors `Tests/AstroCoreTests/StatsTests.swift`'s
    /// `statsDedupesHardlinkedTriageCopyCountingItOnceTowardIntegration` --
    /// same fixture shape, so `InsightsQuery` and `StatsQueries` are
    /// verified to agree on the same input.
    @Test("A light frame present twice in the index (same filename, hardlinked triage copy) counts once")
    func dedupesRepeatedLightFrameCountingItOnce() async throws {
        let fixture = try InsightsQueryFixture.make()
        defer { fixture.cleanup() }

        let originalURL = try fixture.writeFITSLight(
            "sessions/T1/2026-01-10/lights/l1.fit", exptime: 300, filter: "L", instrume: "Cam", focallen: 400
        )
        let linkURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/Review/l1.fit")
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: originalURL, to: linkURL)

        try fixture.scan()
        let result = try await fixture.query().snapshot()

        #expect(result.frameCount == 1)
        #expect(result.integrationSeconds == 300)
        #expect(result.grossIntegrationSeconds == 600)
        #expect(result.hasDuplicateExposure)
        #expect(result.topTargets.first?.integrationSeconds == 300)
        #expect(result.filterUsage.first?.frameCount == 1)
        #expect(result.filterUsage.first?.integrationSeconds == 300)
        #expect(result.setupUsage.first?.frameCount == 1)
        #expect(result.months.first?.frameCount == 1)
        #expect(result.months.first?.integrationSeconds == 300)
    }

    @Test("No duplicates in the library means gross equals the true integration")
    func noDuplicatesMeansGrossEqualsTrue() async throws {
        let fixture = try InsightsQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300, instrume: "Cam")
        try fixture.scan()

        let result = try await fixture.query().snapshot()
        #expect(result.integrationSeconds == result.grossIntegrationSeconds)
        #expect(!result.hasDuplicateExposure)
    }
}
