import Foundation
import Testing
@testable import AstroCore

/// `NightsQueries` reads only `Database` rows (files + fits_meta + ratings +
/// sensor_profile + session_notes) -- these tests build exactly those rows
/// directly (no scanner, no real FITS/image files), same spirit as
/// `SessionQualityTests`.
private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

/// Inserts one light-frame row (`files` + `fits_meta`) and returns its
/// `fileID`.
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
    // A real scan always captures a per-file `inode` (`FrameSet.lightBuckets`'s
    // PRIMARY dedup key). These synthetic rows have no real file to `stat()`,
    // so without this every same-exptime, no-DATE-OBS frame in one session
    // would collide under `FrameSet`'s fallback key and collapse to a single
    // "canonical" copy -- same fix `SessionQualityTests`' own
    // `insertRatedLight` applies, for the same reason.
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
    db: Database, fileID: Int64, fwhm: Double? = nil, background: Double? = nil,
    starCount: Int? = nil, score: Double? = nil
) throws -> RatingRecord {
    let rating = RatingRecord(
        fileID: fileID, fwhm: fwhm, starCount: starCount, background: background,
        score: score, ratedAt: 1_700_000_200, inputSig: "sig-\(fileID)"
    )
    try db.upsertRating(rating)
    return rating
}

/// Inserts a measured `sensor_profile` row -- `SessionQuality` refuses to
/// convert a background reading to e-/s/arcsec2 without one on file for the
/// exact `(camera, gain, offset)` combo (see that type's own doc comment).
@discardableResult
private func insertSensorProfile(
    db: Database, camera: String, gain: Double?, offset: Double?, biasLevelADU: Double?
) throws -> SensorProfileRecord {
    let profile = SensorProfileRecord(
        camera: camera, gain: gain, offset: offset, biasLevelADU: biasLevelADU, measuredAt: 1_700_000_000
    )
    try db.upsertSensorProfile(profile)
    return profile
}

// MARK: - Cross-target aggregation + ordering

@Test func allNightsAggregatesAcrossTargetsNewestDateFirst() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    // M42: two sessions.
    try insertLight(db: db, target: "M42", date: "2026-01-05", name: "a1", exptime: 300, instrume: "CamA", filter: "L")
    try insertLight(db: db, target: "M42", date: "2026-01-05", name: "a2", exptime: 300, instrume: "CamA", filter: "L")
    try insertLight(db: db, target: "M42", date: "2026-03-10", name: "b1", exptime: 600, instrume: "CamA", filter: "L")

    // NGC7000: two sessions.
    try insertLight(db: db, target: "NGC7000", date: "2026-02-01", name: "c1", exptime: 120, instrume: "CamB", filter: "Ha")
    try insertLight(db: db, target: "NGC7000", date: "2026-02-01", name: "c2", exptime: 120, instrume: "CamB", filter: "Ha")
    try insertLight(db: db, target: "NGC7000", date: "2026-02-01", name: "c3", exptime: 120, instrume: "CamB", filter: "Ha")
    try insertLight(db: db, target: "NGC7000", date: "2026-04-01", name: "d1", exptime: 180, instrume: "CamB", filter: "OIII")

    let rows = try NightsQueries.allNights(db: db, config: config)
    #expect(rows.map { "\($0.target)|\($0.date)" } == [
        "NGC7000|2026-04-01",
        "M42|2026-03-10",
        "NGC7000|2026-02-01",
        "M42|2026-01-05",
    ])

    let m42Jan = try #require(rows.first { $0.target == "M42" && $0.date == "2026-01-05" })
    #expect(m42Jan.usableLightCount == 2)
    #expect(m42Jan.integrationSeconds == 600.0)
    #expect(m42Jan.exposureSummary == "300s×2")
    #expect(m42Jan.cameras == ["CamA"])
    #expect(m42Jan.filters == ["L"])
    #expect(m42Jan.isExcludedFromTotals == false)

    let ngcFeb = try #require(rows.first { $0.target == "NGC7000" && $0.date == "2026-02-01" })
    #expect(ngcFeb.usableLightCount == 3)
    #expect(ngcFeb.integrationSeconds == 360.0)
    #expect(ngcFeb.exposureSummary == "120s×3")
    #expect(ngcFeb.filters == ["Ha"])
}

@Test func allNightsBreaksSameDateTiesByTargetNameAscending() throws {
    let db = try makeMemoryDB()
    try insertLight(db: db, target: "Zeta", date: "2026-05-01", name: "z1", exptime: 60)
    try insertLight(db: db, target: "Alpha", date: "2026-05-01", name: "a1", exptime: 60)

    let rows = try NightsQueries.allNights(db: db, config: AstroConfig())
    #expect(rows.map(\.target) == ["Alpha", "Zeta"])
}

@Test func allNightsReturnsEmptyArrayForEmptyLibrary() throws {
    let db = try makeMemoryDB()
    let rows = try NightsQueries.allNights(db: db, config: AstroConfig())
    #expect(rows.isEmpty)
}

// MARK: - year/month filter

@Test func allNightsFiltersByYearAndMonth() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-05", name: "a", exptime: 60)
    try insertLight(db: db, target: "T1", date: "2026-02-10", name: "b", exptime: 60)
    try insertLight(db: db, target: "T1", date: "2025-02-20", name: "c", exptime: 60)

    let year2026 = try NightsQueries.allNights(db: db, config: config, year: 2026)
    #expect(Set(year2026.map(\.date)) == ["2026-01-05", "2026-02-10"])

    let feb2026 = try NightsQueries.allNights(db: db, config: config, year: 2026, month: 2)
    #expect(feb2026.map(\.date) == ["2026-02-10"])

    let feb2025 = try NightsQueries.allNights(db: db, config: config, year: 2025, month: 2)
    #expect(feb2025.map(\.date) == ["2025-02-20"])

    let noMatch = try NightsQueries.allNights(db: db, config: config, year: 2030)
    #expect(noMatch.isEmpty)
}

// MARK: - Excluded (`_hibas`) sessions stay listed

@Test func allNightsKeepsExcludedSessionListedButFlagged() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-10_hibas", name: "a", exptime: 300)
    try insertLight(db: db, target: "T1", date: "2026-01-11", name: "b", exptime: 300)

    let rows = try NightsQueries.allNights(db: db, config: config)
    #expect(rows.count == 2)

    let bad = try #require(rows.first { $0.date == "2026-01-10_hibas" })
    #expect(bad.isExcludedFromTotals == true)
    // The session's OWN numbers stay real -- only the target roll-up
    // (`StatsQueries`/`TargetStats`) would exclude it, not this browsing
    // surface.
    #expect(bad.usableLightCount == 1)
    #expect(bad.integrationSeconds == 300.0)

    let good = try #require(rows.first { $0.date == "2026-01-11" })
    #expect(good.isExcludedFromTotals == false)
}

// MARK: - Quality fields (join with SessionQuality)

@Test func allNightsQualityFieldsNilWhenNoRatingsElseMatchSessionQuality() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    // Unrated session -- lights exist, but nobody ran `rate` yet.
    try insertLight(db: db, target: "T1", date: "2026-01-01", name: "a", exptime: 60)

    // Rated session with a measured sensor profile on file, so background
    // e-/s/arcsec2 is computable too (same setup as `SessionQualityTests`'s
    // background-conversion test).
    try insertSensorProfile(db: db, camera: "ASI2600MC", gain: 100, offset: 50, biasLevelADU: 20)
    let ratedID = try insertLight(
        db: db, target: "T1", date: "2026-01-02", name: "b",
        exptime: 10, instrume: "ASI2600MC", focallen: 206.265, xpixsz: 1.0, egain: 2.0,
        gain: 100, offset: 50
    )
    try insertRating(db: db, fileID: ratedID, fwhm: 2.5, background: 100, starCount: 500, score: 0.1)

    let rows = try NightsQueries.allNights(db: db, config: config)

    let unrated = try #require(rows.first { $0.date == "2026-01-01" })
    #expect(unrated.medianFWHMArcsec == nil)
    #expect(unrated.backgroundEPerSecPerArcsec2 == nil)

    let rated = try #require(rows.first { $0.date == "2026-01-02" })
    let expectedQuality = try #require(
        SessionQuality.summaries(target: "T1", db: db, config: config).first { $0.date == "2026-01-02" }
    )
    #expect(rated.medianFWHMArcsec != nil)
    #expect(rated.medianFWHMArcsec == expectedQuality.medianFWHMArcsec)
    #expect(rated.backgroundEPerSecPerArcsec2 != nil)
    #expect(rated.backgroundEPerSecPerArcsec2 == expectedQuality.backgroundEPerSecPerArcsec2)
}

/// R10 review (item 11): `NightsPage.fwhmText` needs a pixel-only fallback
/// (like `SessionsSegment.fwhmText`) for a rated session with no derivable
/// arcsec value -- `NightRow` didn't carry `medianFWHMPixels` at all before
/// this, even though `SessionQualitySummary` (its join source) always did.
@Test func allNightsMedianFWHMPixelsPopulatedWhenArcsecUnavailable() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    // Rated, but with NO xpixsz/focallen on record -- `medianFWHMArcsec`
    // can't be derived (no pixel scale to convert with), while the raw
    // `ratings.fwhm` pixel value still can be.
    let ratedID = try insertLight(db: db, target: "T1", date: "2026-01-01", name: "a", exptime: 60, instrume: "CamA")
    try insertRating(db: db, fileID: ratedID, fwhm: 3.2)

    let rows = try NightsQueries.allNights(db: db, config: config)
    let row = try #require(rows.first { $0.date == "2026-01-01" })
    #expect(row.medianFWHMArcsec == nil)
    #expect(row.medianFWHMPixels == 3.2)
}

// MARK: - Duty cycle (join with SessionTimeline)

@Test func allNightsDutyCyclePercentMatchesSessionTimelineOrNilWithoutDateObs() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    // No DATE-OBS at all -- `SessionTimeline` can't build a window.
    try insertLight(db: db, target: "T1", date: "2026-01-01", name: "a", exptime: 60)

    // Two evenly-spaced frames with real DATE-OBS -- a real window/duty
    // cycle exists.
    try insertLight(db: db, target: "T1", date: "2026-01-02", name: "b", exptime: 60, dateObs: "2026-01-02T20:00:00")
    try insertLight(db: db, target: "T1", date: "2026-01-02", name: "c", exptime: 60, dateObs: "2026-01-02T20:02:00")

    let rows = try NightsQueries.allNights(db: db, config: config)

    let noTimestamps = try #require(rows.first { $0.date == "2026-01-01" })
    #expect(noTimestamps.dutyCyclePercent == nil)

    let timed = try #require(rows.first { $0.date == "2026-01-02" })
    let expectedTimeline = try SessionTimeline.timeline(target: "T1", date: "2026-01-02", db: db, config: config)
    #expect(timed.dutyCyclePercent != nil)
    #expect(timed.dutyCyclePercent == expectedTimeline.dutyCycle.map { $0 * 100 })
}

// MARK: - hasNotes

@Test func allNightsHasNotesTrueOnlyForSessionWithSessionNotesRecorded() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-01", name: "a", exptime: 60)
    try insertLight(db: db, target: "T1", date: "2026-01-02", name: "b", exptime: 60)
    try db.upsertSessionNotes(target: "T1", date: "2026-01-01", notes: ["Camera": "ASI2600MC"])

    let rows = try NightsQueries.allNights(db: db, config: config)
    #expect(try #require(rows.first { $0.date == "2026-01-01" }).hasNotes == true)
    #expect(try #require(rows.first { $0.date == "2026-01-02" }).hasNotes == false)
}

// MARK: - Per-filter breakdown (R11-T5/F1)

@Test func allNightsFilterBreakdownMatchesFilterBreakdownQueriesForThatDate() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "ha1", exptime: 300, filter: "Ha")
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "ha2", exptime: 300, filter: "Ha")
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "oiii1", exptime: 900, filter: "OIII")

    let rows = try NightsQueries.allNights(db: db, config: config)
    let row = try #require(rows.first { $0.date == "2026-01-10" })

    let expected = try FilterBreakdownQueries.breakdown(db: db, config: config, target: "T1", date: "2026-01-10")
    #expect(row.filterBreakdown == expected)
    #expect(row.filterBreakdown.map(\.filter) == ["OIII", "Ha"])
    #expect(row.filterBreakdown.first { $0.filter == "Ha" }?.usableFrameCount == 2)
    #expect(row.filterBreakdown.first { $0.filter == "Ha" }?.integrationSeconds == 600.0)
    #expect(row.filterBreakdown.first { $0.filter == "OIII" }?.integrationSeconds == 900.0)
}

/// An OSC/DSLR session (no `FILTER` header at all) still gets a single
/// sentinel-bucket row -- same "(nincs szűrő-adat)" convention
/// `FilterBreakdownQueries` documents, never an empty array masquerading as
/// "no data at all".
@Test func allNightsFilterBreakdownBucketsFilterlessFramesUnderTheSentinel() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-01", name: "a", exptime: 60)

    let rows = try NightsQueries.allNights(db: db, config: config)
    let row = try #require(rows.first { $0.date == "2026-01-01" })
    #expect(row.filterBreakdown.count == 1)
    #expect(row.filterBreakdown[0].filter == FilterBreakdownQueries.noFilterSentinel)
}

/// Scoped strictly to its own date -- a sibling session's frames on another
/// night must never leak into this row's breakdown.
@Test func allNightsFilterBreakdownIsScopedToItsOwnDateOnly() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-10", name: "a", exptime: 300, filter: "Ha")
    try insertLight(db: db, target: "T1", date: "2026-01-11", name: "b", exptime: 300, filter: "OIII")

    let rows = try NightsQueries.allNights(db: db, config: config)
    let jan10 = try #require(rows.first { $0.date == "2026-01-10" })
    #expect(jan10.filterBreakdown.map(\.filter) == ["Ha"])
    let jan11 = try #require(rows.first { $0.date == "2026-01-11" })
    #expect(jan11.filterBreakdown.map(\.filter) == ["OIII"])
}

/// An excluded (`_hibas`) night still reports its own real per-filter
/// numbers here -- same "browsing surface, not a stats roll-up" stance the
/// rest of `NightRow` already takes.
@Test func allNightsFilterBreakdownStillReportsAnExcludedHibasNightsOwnFrames() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T1", date: "2026-01-10_hibas", name: "a", exptime: 300, filter: "Ha")

    let rows = try NightsQueries.allNights(db: db, config: config)
    let row = try #require(rows.first { $0.date == "2026-01-10_hibas" })
    #expect(row.filterBreakdown.map(\.filter) == ["Ha"])
    #expect(row.filterBreakdown[0].integrationSeconds == 300.0)
}

// MARK: - Display name resolution

@Test func allNightsResolvesDisplayNameViaTargetNameResolver() throws {
    let db = try makeMemoryDB()
    try insertLight(db: db, target: "NGC7000", date: "2026-01-01", name: "a", exptime: 60)

    let rows = try NightsQueries.allNights(db: db, config: AstroConfig())
    let row = try #require(rows.first)
    #expect(row.displayName.hasPrefix("NGC 7000"))
}
