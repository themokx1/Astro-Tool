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
            captureTrendPointsForTesting: { try InsightsQuery.captureTrendPoints(db: db, config: config) },
            libraryForTesting: {
                let files = try db.allFiles(includeMissing: false)
                let meta = try db.fitsMetaBatch(fileIDs: files.compactMap(\.id))
                return (files, meta, config)
            }
        )
    }
}

struct InsightsQueryTests {
    @Test("Insights carries per-capture quality/efficiency trend points, not per-session ones")
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
        let points = [CaptureTrendPoint(
            target: "IC1396", date: "2026-08-08", sessionStartDate: "2026-08-08",
            displayName: "OSC 30 s", filterLabel: "SV220",
            setupDescriptor: "ASI2600MC · 261 mm",
            medianFWHMArcsec: 2.4, backgroundEPerSecPerArcsec2: 0.003,
            efficiencyPercent: 82, usableFrameCount: 40, integrationSeconds: 1200,
            groupKey: "implicit"
        )]

        let result = try await InsightsQuery(
            indexDatabaseForTesting: index,
            captureTrendPointsForTesting: { points }
        ).snapshot()

        #expect(result.captureTrendPoints == points)
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

    // MARK: - W6-B: per-capture trend rows, reconciled against NightReportQuery

    /// The owner's own reported shape: one night, two capture groups, two
    /// different rigs (a Canon EOS R8 widefield setup and a ZWO ASI2600MC
    /// narrowband setup) -- the exact mix his screenshot showed folded into
    /// one blended "Efficiency" trend line under the old per-SESSION
    /// `TrendPoint`. Pins two things at once: (1) `InsightsQuery.
    /// captureTrendPoints` never blends the two captures' FWHM/efficiency
    /// together, and (2) its numbers for each capture are IDENTICAL to what
    /// `NightReportQuery.run` (the night workspace's own "Capture Groups"
    /// table engine) reports for the same capture, since both are built by
    /// joining the exact same `SessionStatsQueries.sessions`/`SessionQuality.
    /// summaries` calls -- never a second, independently re-derived
    /// computation of the same fact.
    @Test("A capture's FWHM/efficiency in the Insights trend reconciles with NightReportQuery's own Capture Groups numbers")
    func reconcilesWithNightReportCaptureGroups() async throws {
        let fixture = try InsightsQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight(
            "sessions/MIX/2026-03-01/captures/wide/lights/w1.fit",
            exptime: 60, filter: "L", instrume: "Canon EOS R8", focallen: 16
        )
        try fixture.writeFITSLight(
            "sessions/MIX/2026-03-01/captures/wide/lights/w2.fit",
            exptime: 60, filter: "L", instrume: "Canon EOS R8", focallen: 16
        )
        try fixture.writeFITSLight(
            "sessions/MIX/2026-03-01/captures/narrow/lights/n1.fit",
            exptime: 300, filter: "SV220", instrume: "ASI2600MC", focallen: 261
        )
        try fixture.writeFITSLight(
            "sessions/MIX/2026-03-01/captures/narrow/lights/n2.fit",
            exptime: 300, filter: "SV220", instrume: "ASI2600MC", focallen: 261
        )
        try fixture.scan()

        _ = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "MIX", sessionDate: "2026-03-01", slug: "wide", displayName: "Widefield L"
        ))
        _ = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "MIX", sessionDate: "2026-03-01", slug: "narrow", displayName: "Narrowband SV220"
        ))

        let allFiles = try fixture.db.allFiles(includeMissing: false)
        func rate(_ suffix: String, fwhm: Double) throws {
            let file = try #require(allFiles.first { $0.path.hasSuffix(suffix) })
            try fixture.db.upsertRating(RatingRecord(
                fileID: try #require(file.id), fwhm: fwhm, starCount: 100, background: 200,
                score: 0, ratedAt: 1_700_000_000, inputSig: "sig-\(suffix)"
            ))
        }
        try rate("w1.fit", fwhm: 3.0)
        try rate("w2.fit", fwhm: 5.0)
        try rate("n1.fit", fwhm: 2.0)
        try rate("n2.fit", fwhm: 4.0)

        let capturePoints = try InsightsQuery.captureTrendPoints(db: fixture.db, config: fixture.config)
        let wide = try #require(capturePoints.first { $0.displayName == "Widefield L" })
        let narrow = try #require(capturePoints.first { $0.displayName == "Narrowband SV220" })

        // Never blended: each capture keeps its own median FWHM -- the old
        // session-wide `TrendPoint` would have reported this whole night's
        // FWHM as `nil` (`SessionQuality` suppresses the session-level
        // aggregate outright once more than one capture group contributed
        // rated frames).
        #expect(wide.medianFWHMPixels == 4.0)
        #expect(narrow.medianFWHMPixels == 3.0)
        #expect(wide.setupDescriptor?.contains("Canon EOS R8") == true)
        #expect(narrow.setupDescriptor?.contains("ASI2600MC") == true)
        #expect(wide.filterLabel == "L")
        #expect(narrow.filterLabel == "SV220")
        // No rejects on either capture -- both fully usable.
        #expect(wide.efficiencyPercent == 100)
        #expect(narrow.efficiencyPercent == 100)

        let report = try NightReportQuery(db: fixture.db, config: fixture.config).run(target: "MIX", date: "2026-03-01")
        let reportWide = try #require(report.captureGroups.first { $0.group.displayName == "Widefield L" })
        let reportNarrow = try #require(report.captureGroups.first { $0.group.displayName == "Narrowband SV220" })

        #expect(wide.medianFWHMPixels == reportWide.quality?.medianFWHMPixels)
        #expect(narrow.medianFWHMPixels == reportNarrow.quality?.medianFWHMPixels)
        #expect(wide.usableFrameCount == reportWide.group.usableLightCount)
        #expect(narrow.usableFrameCount == reportNarrow.group.usableLightCount)
        #expect(wide.integrationSeconds == reportWide.group.integrationSeconds)
        #expect(narrow.integrationSeconds == reportNarrow.group.integrationSeconds)
    }

    // MARK: - Moon x sky-brightness correlation

    /// `moonSkyCorrelation` defaults to the honest empty summary when no
    /// `trendPointsForTesting` provider is wired -- every other test in
    /// this file (and every existing caller of `InsightsQueryFixture.query()`)
    /// never supplies one, and must keep working exactly as before.
    @Test("Moon-sky correlation defaults to the empty summary when no trend-point provider is wired")
    func moonSkyCorrelationDefaultsToEmptyWithNoProvider() async throws {
        let fixture = try InsightsQueryFixture.make()
        defer { fixture.cleanup() }
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300, instrume: "Cam")
        try fixture.scan()

        let result = try await fixture.query().snapshot()
        #expect(result.moonSkyCorrelation == MoonSkyCorrelationSummary.empty)
        #expect(!result.moonSkyCorrelation.hasEnoughDataToDisplay)
    }

    /// Wires real `TrendPoint`s (dates with known, independently confirmed
    /// Moon illumination -- see `MoonSkyCorrelationTests`'s own fixture
    /// comment for the source dates) through `trendPointsForTesting` and
    /// checks both halves of the AstroApplication-layer wrapper: (1) it
    /// defers bucketing entirely to `MoonSkyCorrelation.buckets(points:)`
    /// (never re-derives band membership itself), and (2) it actually
    /// calls `MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2:)`
    /// per bucket rather than leaving the mag/arcsec2 reading `nil`.
    @Test("Moon-sky correlation buckets TrendPoints and converts each bucket's median to mag/arcsec2")
    func exposesMoonSkyCorrelationWithMagnitudeConversion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL);
        """)

        func point(_ target: String, _ date: String, _ background: Double) -> TrendPoint {
            TrendPoint(target: target, date: date, sessionStartDate: date, backgroundEPerSecPerArcsec2: background)
        }
        // 2024-01-11 (0.19% illum, veryDark) x3, 2024-01-25 (99.76%, veryBright) x3
        // -- both extremes clear `MoonSkyCorrelation.minimumSampleCount`, so a
        // headline ratio (0.006 / 0.002 = 3.0) is expected.
        let points = (0..<3).map { point("D\($0)", "2024-01-11", 0.002) }
            + (0..<3).map { point("B\($0)", "2024-01-25", 0.006) }

        let result = try await InsightsQuery(
            indexDatabaseForTesting: index,
            trendPointsForTesting: { points }
        ).snapshot()

        let moonSky = result.moonSkyCorrelation
        #expect(moonSky.buckets.count == 4)
        #expect(moonSky.usableBucketCount == 2)
        #expect(moonSky.hasEnoughDataToDisplay)
        #expect(moonSky.headlineRatio == 3.0)

        let veryDark = try #require(moonSky.buckets.first { $0.band == .veryDark })
        #expect(veryDark.sampleCount == 3)
        #expect(veryDark.isLowConfidence == false)
        #expect(veryDark.medianBackgroundEPerSecPerArcsec2 == 0.002)
        #expect(veryDark.medianMagnitudePerArcsec2 == MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: 0.002))

        let veryBright = try #require(moonSky.buckets.first { $0.band == .veryBright })
        #expect(veryBright.medianBackgroundEPerSecPerArcsec2 == 0.006)
        #expect(veryBright.medianMagnitudePerArcsec2 == MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: 0.006))

        let untouchedBands: [MoonSkyCorrelation.IlluminationBand] = [.dark, .bright]
        for band in untouchedBands {
            let bucket = try #require(moonSky.buckets.first { $0.band == band })
            #expect(bucket.sampleCount == 0)
            #expect(bucket.isLowConfidence)
            #expect(bucket.medianMagnitudePerArcsec2 == nil)
        }
    }

    // MARK: - Year Wrapped (expert ideation reserve #9)

    /// No `year` given ("Minden év") means no single year to summarize --
    /// `yearWrapped` stays `nil` regardless of how much history is on
    /// record, matching `InsightsView`'s own "only on a selected year"
    /// visibility rule.
    @Test("Year Wrapped stays nil when no year is selected")
    func yearWrappedNilWithoutYearSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL);
        """)

        let points = [
            TrendPoint(target: "M42", date: "2026-01-10", sessionStartDate: "2026-01-10", integrationSeconds: 600, usableFrameCount: 5),
        ]

        let result = try await InsightsQuery(
            indexDatabaseForTesting: index,
            trendPointsForTesting: { points }
        ).snapshot()

        #expect(result.yearWrapped == nil)
    }

    /// Selecting a year with real sessions on record builds the year card
    /// from the SAME `trendPointsForTesting` provider the Moon-sky card
    /// reads -- never a second, independently-queried trend list -- and
    /// `AstroCore`'s own `YearWrapped.summarize` does the year isolation.
    @Test("Year Wrapped summarizes the selected year from the same trend points the Moon-sky card reads")
    func yearWrappedSummarizesSelectedYear() async throws {
        func point(_ target: String, _ date: String, seconds: Double = 600) -> TrendPoint {
            TrendPoint(target: target, date: date, sessionStartDate: date, integrationSeconds: seconds, usableFrameCount: 5)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL);
        """)

        let points = [
            point("NGC 2237", "2026-02-01", seconds: 3600),
            point("M45", "2025-12-01", seconds: 1200),
        ]

        let result = try await InsightsQuery(
            indexDatabaseForTesting: index,
            trendPointsForTesting: { points }
        ).snapshot(year: 2026)

        let wrapped = try #require(result.yearWrapped)
        #expect(wrapped.year == 2026)
        #expect(wrapped.sessionCount == 1)
        #expect(wrapped.mostShotTarget?.target == "NGC 2237")
        #expect(wrapped.firstLights == ["NGC 2237"])
    }

    // MARK: - This month vs last year (ideation #3)

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func fixedToday(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return utcCalendar.date(from: components)!
    }

    /// `yearOverYearComparison` is built from the SAME `trendPointsForTesting`
    /// provider the Moon-sky/Year-Wrapped cards read, never a second,
    /// independently-queried trend list -- and reflects the real wall-clock
    /// "today" (here fixed via `todayForTesting`), never the `year` argument
    /// passed to `snapshot`. Present both on "Minden év" (`year: nil`) and
    /// under a selected year, since the caller (not `InsightsQuery`) decides
    /// which of those two contexts actually renders the card.
    @Test("Year-over-year comparison is built regardless of the snapshot's own year scope")
    func yearOverYearComparisonIgnoresYearScope() async throws {
        func point(_ target: String, _ date: String, seconds: Double = 600) -> TrendPoint {
            TrendPoint(target: target, date: date, sessionStartDate: date, integrationSeconds: seconds, usableFrameCount: 5)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL);
        """)

        let points = [
            point("M31", "2026-08-05", seconds: 1800),
            point("M31", "2025-08-03", seconds: 1200),
        ]
        let today = Self.fixedToday(year: 2026, month: 8, day: 19)

        let query = InsightsQuery(
            indexDatabaseForTesting: index,
            trendPointsForTesting: { points },
            todayForTesting: { today }
        )

        let allYears = try await query.snapshot()
        let comparisonAllYears = try #require(allYears.yearOverYearComparison)
        #expect(comparisonAllYears.month == 8)
        #expect(comparisonAllYears.thisYear == 2026)
        #expect(comparisonAllYears.lastYear == 2025)
        #expect(comparisonAllYears.thisYearIntegrationSeconds == 1800)
        #expect(comparisonAllYears.lastYearIntegrationSeconds == 1200)

        let scopedToOtherYear = try await query.snapshot(year: 2025)
        let comparisonScoped = try #require(scopedToOtherYear.yearOverYearComparison)
        #expect(comparisonScoped == comparisonAllYears)
    }

    /// `currentMonth`/`currentYear` come from the SAME `todayForTesting`
    /// clock as `yearOverYearComparison` and stay populated even when the
    /// comparison itself is `nil` -- `InsightsView`'s own visibility gate
    /// needs them independently of whether a comparison could be built.
    @Test("currentMonth/currentYear stay populated from the same clock even when the comparison itself is nil")
    func currentMonthYearPopulatedEvenWhenComparisonIsNil() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL);
        """)

        let today = Self.fixedToday(year: 2026, month: 8, day: 19)
        let result = try await InsightsQuery(
            indexDatabaseForTesting: index,
            trendPointsForTesting: { [] },
            todayForTesting: { today }
        ).snapshot()

        #expect(result.yearOverYearComparison == nil)
        #expect(result.currentMonth == 8)
        #expect(result.currentYear == 2026)
    }

    /// No prior-year session in the same calendar month at all -- the whole
    /// comparison is `nil`, matching `YearOverYearComparison.summarize`'s
    /// own "nothing to compare against yet" contract.
    @Test("Year-over-year comparison is nil when last year has no session in the same month")
    func yearOverYearComparisonNilWithoutPriorYearData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL);
        """)

        let points = [
            TrendPoint(target: "M31", date: "2026-08-05", sessionStartDate: "2026-08-05", integrationSeconds: 600, usableFrameCount: 5),
        ]
        let today = Self.fixedToday(year: 2026, month: 8, day: 19)

        let result = try await InsightsQuery(
            indexDatabaseForTesting: index,
            trendPointsForTesting: { points },
            todayForTesting: { today }
        ).snapshot()

        #expect(result.yearOverYearComparison == nil)
    }
}
