import Foundation
import Testing
@testable import AstroCore

// MARK: - TrendMath.movingAverage

@Test func movingAverageOfEmptyArrayIsEmpty() throws {
    #expect(TrendMath.movingAverage([]).isEmpty)
}

@Test func movingAverageOfAllNilsIsAllNils() throws {
    let result = TrendMath.movingAverage([nil, nil, nil])
    #expect(result == [nil, nil, nil])
}

@Test func movingAverageWindowFillsGraduallyThenSlidesFiveWide() throws {
    // 1,2,3,4,5,6,7 with window 5:
    // idx0: avg(1)=1; idx1: avg(1,2)=1.5; idx2: avg(1,2,3)=2; idx3: avg(1,2,3,4)=2.5;
    // idx4: avg(1,2,3,4,5)=3; idx5 (window slides, drops 1): avg(2,3,4,5,6)=4;
    // idx6 (drops 2): avg(3,4,5,6,7)=5.
    let values: [Double?] = [1, 2, 3, 4, 5, 6, 7]
    let result = TrendMath.movingAverage(values, window: 5)
    #expect(result == [1, 1.5, 2, 2.5, 3, 4, 5])
}

@Test func movingAverageSkipsGapsWithoutResettingTheWindow() throws {
    // A `nil` (no rated session that date) contributes nothing to the
    // average and stays `nil` in the output, but the NEXT real value still
    // averages against the earlier real ones, not just itself.
    let values: [Double?] = [2, nil, 4]
    let result = TrendMath.movingAverage(values, window: 5)
    #expect(result == [2, nil, 3])
}

@Test func movingAverageWindowOneEqualsRawValuesAtNonNilPositions() throws {
    let values: [Double?] = [5, nil, 9, 1]
    let result = TrendMath.movingAverage(values, window: 1)
    #expect(result == [5, nil, 9, 1])
}

@Test func movingAverageRejectsNonPositiveWindowWithAllNils() throws {
    let values: [Double?] = [1, 2, 3]
    #expect(TrendMath.movingAverage(values, window: 0) == [nil, nil, nil])
}

// MARK: - TrendQueries.points fixtures

private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

@discardableResult
private func insertLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    exptime: Double? = nil,
    instrume: String? = nil,
    focallen: Double? = nil,
    filter: String? = nil,
    xpixsz: Double? = nil,
    egain: Double? = nil,
    gain: Double? = nil,
    offset: Double? = nil,
    dateObs: String? = nil
) throws -> Int64 {
    let path = "sessions/\(target)/\(date)/lights/\(name).fit"
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light,
            scannedAt: 1_700_000_100
        )
    )
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
    try db.upsertFITSMeta(
        FITSMetaRecord(
            fileID: fileID, exptime: exptime, gain: gain, offset: offset,
            instrume: instrume, focallen: focallen, filter: filter, dateObs: dateObs,
            xpixsz: xpixsz, egain: egain
        )
    )
    return fileID
}

@discardableResult
private func insertRating(
    db: Database, fileID: Int64, fwhm: Double? = nil, background: Double? = nil
) throws -> RatingRecord {
    let rating = RatingRecord(fileID: fileID, fwhm: fwhm, background: background, ratedAt: 1_700_000_200, inputSig: "sig-\(fileID)")
    try db.upsertRating(rating)
    return rating
}

// MARK: - Ordering (chronological, opposite of NightsQueries)

@Test func pointsSortsChronologicallyAscendingUnlikeAllNights() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    try insertLight(db: db, target: "M42", date: "2026-03-10", name: "a", exptime: 60, instrume: "CamA")
    try insertLight(db: db, target: "M42", date: "2026-01-05", name: "b", exptime: 60, instrume: "CamA")

    let points = try TrendQueries.points(db: db, config: config)
    #expect(points.map(\.date) == ["2026-01-05", "2026-03-10"])
}

@Test func pointsReturnsEmptyArrayForEmptyLibrary() throws {
    let db = try makeMemoryDB()
    #expect(try TrendQueries.points(db: db, config: AstroConfig()).isEmpty)
}

// MARK: - Date-range filter

@Test func pointsFromToFiltersToTheInclusiveRange() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-01", name: "a", exptime: 60)
    try insertLight(db: db, target: "T1", date: "2026-02-15", name: "b", exptime: 60)
    try insertLight(db: db, target: "T1", date: "2026-03-30", name: "c", exptime: 60)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"

    let from = try #require(formatter.date(from: "2026-02-01"))
    let to = try #require(formatter.date(from: "2026-03-01"))

    let points = try TrendQueries.points(db: db, config: config, from: from, to: to)
    #expect(points.map(\.date) == ["2026-02-15"])
}

@Test func pointsExcludesUnparseableDateDirsWhenARangeFilterIsActive() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    // "_hibas" still parses (it's a recognized intentional suffix on a real
    // calendar date) -- use a date-dir that ISN'T a date at all.
    try insertLight(db: db, target: "T1", date: "not-a-date", name: "a", exptime: 60)
    try insertLight(db: db, target: "T1", date: "2026-02-15", name: "b", exptime: 60)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    let from = try #require(formatter.date(from: "2026-01-01"))

    let points = try TrendQueries.points(db: db, config: config, from: from)
    #expect(points.map(\.date) == ["2026-02-15"])

    // Unfiltered, the unparseable one is still listed (browsing convention).
    let unfiltered = try TrendQueries.points(db: db, config: config)
    #expect(Set(unfiltered.map(\.date)) == ["not-a-date", "2026-02-15"])
}

// MARK: - Setup-fingerprint filter

@Test func pointsFiltersBySetupDescriptorExactMatch() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-01", name: "a", exptime: 60, instrume: "CamA", focallen: 500, xpixsz: 3.76)
    try insertLight(db: db, target: "T1", date: "2026-01-02", name: "b", exptime: 60, instrume: "CamB", focallen: 200, xpixsz: 2.4)

    let all = try TrendQueries.points(db: db, config: config)
    let descriptors = TrendQueries.distinctSetupDescriptors(all)
    #expect(descriptors.count == 2)

    let camADescriptor = try #require(all.first { $0.date == "2026-01-01" }?.setupDescriptor)
    let filtered = try TrendQueries.points(db: db, config: config, setupFingerprint: camADescriptor)
    #expect(filtered.map(\.date) == ["2026-01-01"])
}

@Test func pointsWithUnknownSetupFingerprintReturnsEmpty() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-01", name: "a", exptime: 60, instrume: "CamA")

    let points = try TrendQueries.points(db: db, config: config, setupFingerprint: "no-such-setup")
    #expect(points.isEmpty)
}

// MARK: - Metric fields mirror NightsQueries/SessionQuality

@Test func pointsCarriesTheSameQualityFieldsAllNightsAlreadyComputes() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    try db.upsertSensorProfile(
        SensorProfileRecord(camera: "ASI2600MC", gain: 100, offset: 50, biasLevelADU: 20, measuredAt: 1_700_000_000)
    )
    let ratedID = try insertLight(
        db: db, target: "T1", date: "2026-01-02", name: "b",
        exptime: 10, instrume: "ASI2600MC", focallen: 206.265, xpixsz: 1.0, egain: 2.0,
        gain: 100, offset: 50
    )
    try insertRating(db: db, fileID: ratedID, fwhm: 2.5, background: 100)

    let points = try TrendQueries.points(db: db, config: config)
    let point = try #require(points.first { $0.date == "2026-01-02" })
    #expect(point.medianFWHMArcsec != nil)
    #expect(point.backgroundEPerSecPerArcsec2 != nil)

    let nightRow = try #require(
        try NightsQueries.allNights(db: db, config: config).first { $0.date == "2026-01-02" }
    )
    #expect(point.medianFWHMArcsec == nightRow.medianFWHMArcsec)
    #expect(point.backgroundEPerSecPerArcsec2 == nightRow.backgroundEPerSecPerArcsec2)
    #expect(point.efficiencyPercent == nightRow.dutyCyclePercent)
}

@Test func pointsCarryAcquisitionAndResolvedFilterDataForDashboard() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(
        db: db, target: "T1", date: "2026-01-02", name: "a",
        exptime: 300, instrume: "Cam", filter: "Ha"
    )

    let point = try #require(try TrendQueries.points(db: db, config: config).first)
    #expect(point.integrationSeconds == 300)
    #expect(point.usableFrameCount == 1)
    #expect(point.filterBreakdown.map(\.filter) == ["Ha"])
    #expect(point.filterBreakdown.first?.integrationSeconds == 300)
}

@Test func trendDashboardSummarizesWhenHoursTargetsMonthsAndFilters() throws {
    let points = [
        TrendPoint(
            target: "T1", date: "2026-01-02", sessionStartDate: "2026-01-02",
            efficiencyPercent: 60, integrationSeconds: 3600, usableFrameCount: 12,
            filterBreakdown: [FilterIntegration(filter: "Ha", usableFrameCount: 12, integrationSeconds: 3600)]
        ),
        TrendPoint(
            target: "T1", date: "2026-01-03", sessionStartDate: "2026-01-03",
            efficiencyPercent: 80, integrationSeconds: 1800, usableFrameCount: 6,
            filterBreakdown: [FilterIntegration(filter: "OIII", usableFrameCount: 6, integrationSeconds: 1800)]
        ),
        TrendPoint(
            target: "T2", date: "2026-02-10", sessionStartDate: "2026-02-10",
            efficiencyPercent: nil, integrationSeconds: 7200, usableFrameCount: 24,
            filterBreakdown: [FilterIntegration(filter: "SVBONY SV220", usableFrameCount: 24, integrationSeconds: 7200)]
        ),
    ]

    let dashboard = TrendAnalytics.summarize(points)
    #expect(dashboard.sessionCount == 3)
    #expect(dashboard.distinctNightCount == 3)
    #expect(dashboard.integrationSeconds == 12_600)
    #expect(dashboard.usableFrameCount == 42)
    #expect(dashboard.firstDate == "2026-01-02")
    #expect(dashboard.lastDate == "2026-02-10")
    #expect(dashboard.averageEfficiencyPercent == 70)
    #expect(dashboard.months.map(\.month) == ["2026-01", "2026-02"])
    #expect(dashboard.months.map(\.integrationSeconds) == [5400, 7200])
    #expect(dashboard.targets.map(\.target) == ["T2", "T1"])
    #expect(dashboard.filters.map(\.filter) == ["SVBONY SV220", "Ha", "OIII"])
}

// MARK: - fwhmValue fallback

@Test func fwhmValuePrefersArcsecOverPixelsAndFlagsThePixelFallback() throws {
    let arcsecPoint = TrendPoint(target: "T", date: "d", medianFWHMArcsec: 2.5, medianFWHMPixels: 3.2)
    let arcsecResult = try #require(arcsecPoint.fwhmValue)
    #expect(arcsecResult.value == 2.5)
    #expect(arcsecResult.isPixelFallback == false)

    let pixelOnlyPoint = TrendPoint(target: "T", date: "d", medianFWHMPixels: 3.2)
    let pixelResult = try #require(pixelOnlyPoint.fwhmValue)
    #expect(pixelResult.value == 3.2)
    #expect(pixelResult.isPixelFallback == true)

    let neitherPoint = TrendPoint(target: "T", date: "d")
    #expect(neitherPoint.fwhmValue == nil)
}

@Test func trendPointDecodesLegacyJSONWithoutAcquisitionDashboardFields() throws {
    let data = try #require(
        """
        {
          "target": "M 42",
          "date": "2026-03-15",
          "sessionStartDate": "2026-03-15",
          "medianFWHMArcsec": 3.1,
          "efficiencyPercent": 82.0
        }
        """.data(using: .utf8)
    )

    let point = try JSONDecoder().decode(TrendPoint.self, from: data)

    #expect(point.target == "M 42")
    #expect(point.integrationSeconds == 0)
    #expect(point.usableFrameCount == 0)
    #expect(point.filterBreakdown.isEmpty)
}
