@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Same fixture shape as `SessionQualityTests.swift`'s own helpers (that
/// file's are `private`, so not reusable across test files -- the accepted
/// per-file duplication this codebase already has for `makeMemoryDB` and
/// friends) -- writes exactly the `files`/`fits_meta`/`ratings`/
/// `sensor_profile` rows `MeasuredSkyQuery` (via `SessionQuality`) reads,
/// with no scanner and no real FITS bytes.
private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

@discardableResult
private func insertMeasuredSession(
    db: Database,
    target: String,
    date: String,
    backgroundADU: Double,
    biasLevelADU: Double,
    camera: String = "ASI2600MC",
    gain: Double = 100,
    offset: Double = 50,
    egain: Double = 2.0,
    exptime: Double = 10,
    xpixsz: Double = 1.0,
    focallen: Double = 206.265
) throws -> Int64 {
    // `db.sensorProfile(camera:gain:offset:)` matches EXACTLY -- a repeat
    // insert for the same combo is harmless (`upsertSensorProfile`).
    try db.upsertSensorProfile(SensorProfileRecord(
        camera: camera, gain: gain, offset: offset, biasLevelADU: biasLevelADU, measuredAt: 1_700_000_000
    ))
    let path = "sessions/\(target)/\(date)/lights/a.fit"
    let fileID = try db.upsertFile(FileRecord(
        path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
        area: .sessions, target: target, sessionDate: date, role: .light,
        scannedAt: 1_700_000_100
    ))
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
    try db.upsertFITSMeta(FITSMetaRecord(
        fileID: fileID, exptime: exptime, gain: gain, offset: offset,
        instrume: camera, focallen: focallen, xpixsz: xpixsz, egain: egain
    ))
    try db.upsertRating(RatingRecord(
        fileID: fileID, fwhm: 2.5, background: backgroundADU, score: 0.1,
        ratedAt: 1_700_000_200, inputSig: "sig-\(target)-\(date)"
    ))
    return fileID
}

@Suite("MeasuredSkyQuery")
struct MeasuredSkyQueryTests {
    // MARK: - Conversion

    @Test("The documented zero-point anchor reproduces the audit's own illustrative μ≈20.4 example")
    func conversionAnchorReproducesTheAuditsIllustrativeFigure() throws {
        // The exact real (bias-corrected) background this codebase's own
        // `SessionQuality.swift` doc comment cites (the Rosette session) --
        // `MeasuredSkyQuery.assumedZeroPointMag`'s own doc explains why this
        // specific number anchors the zero point.
        let mag = try #require(MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: 0.0023))
        #expect(abs(mag - 20.4) < 0.01)
    }

    @Test("A brighter (larger) measured background yields a numerically smaller (brighter) magnitude")
    func brighterBackgroundYieldsSmallerMagnitude() throws {
        let dim = try #require(MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: 0.001))
        let bright = try #require(MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: 0.01))
        #expect(bright < dim, "a brighter sky (more flux) must read as a smaller/brighter mag/arcsec2 number")
    }

    @Test("Non-finite or non-positive flux never manufactures a number")
    func invalidFluxYieldsNil() {
        #expect(MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: 0) == nil)
        #expect(MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: -0.001) == nil)
        #expect(MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: .nan) == nil)
        #expect(MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: .infinity) == nil)
    }

    // MARK: - Snapshot: too few measured sessions -> honest nil

    @Test("A library with no measured sessions at all reports no measured sky")
    func emptyLibraryReportsNoMeasuredSky() throws {
        let db = try makeMemoryDB()
        let snapshot = try MeasuredSkyQuery.snapshot(db: db, config: AstroConfig())
        #expect(snapshot == nil)
    }

    @Test("Fewer than the minimum measured sessions falls back to nil, not a shaky median")
    func tooFewMeasuredSessionsFallsBackToNil() throws {
        let db = try makeMemoryDB()
        // One fewer than `minimumSessionCount` (3) -- two measured sessions.
        try insertMeasuredSession(db: db, target: "M31", date: "2026-01-01", backgroundADU: 100, biasLevelADU: 20)
        try insertMeasuredSession(db: db, target: "M31", date: "2026-01-02", backgroundADU: 100, biasLevelADU: 20)

        let snapshot = try MeasuredSkyQuery.snapshot(db: db, config: AstroConfig())
        #expect(snapshot == nil, "two measured sessions is below MeasuredSkyQuery.minimumSessionCount and must not produce a number")
    }

    // MARK: - Snapshot: enough measured sessions -> a real, derived figure

    @Test("Enough measured sessions across the library produce a median-derived sky brightness with an honest session count")
    func enoughMeasuredSessionsProduceAMeasuredSkyBrightness() throws {
        let db = try makeMemoryDB()
        // Three sessions across two different targets -- `MeasuredSkyQuery`
        // is deliberately target-agnostic (the sky background isn't a
        // property of what's pointed at). Pixel scale chosen as exactly
        // 1 arcsec/px (206.265 * 1 / 206.265) so
        // background(e-/s/arcsec2) = (ADU - bias) * egain / exptime.
        try insertMeasuredSession(db: db, target: "M31", date: "2026-01-01", backgroundADU: 100, biasLevelADU: 20) // (100-20)*2/10 = 16
        try insertMeasuredSession(db: db, target: "M31", date: "2026-01-02", backgroundADU: 120, biasLevelADU: 20) // (120-20)*2/10 = 20
        try insertMeasuredSession(db: db, target: "M42", date: "2026-01-03", backgroundADU: 140, biasLevelADU: 20) // (140-20)*2/10 = 24

        let snapshot = try #require(try MeasuredSkyQuery.snapshot(db: db, config: AstroConfig()))
        #expect(snapshot.sessionCount == 3)
        // Median flux is 20 e-/s/arcsec2 -- the middle of [16, 20, 24].
        let expectedMag = try #require(MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2: 20))
        #expect(abs(snapshot.magnitudePerArcsec2 - expectedMag) < 0.000_001)
    }

    @Test("A session with no measured bias level (no sensor profile match) never contributes a guessed background")
    func sessionWithoutASensorProfileMatchIsExcluded() throws {
        let db = try makeMemoryDB()
        try insertMeasuredSession(db: db, target: "M31", date: "2026-01-01", backgroundADU: 100, biasLevelADU: 20)
        try insertMeasuredSession(db: db, target: "M31", date: "2026-01-02", backgroundADU: 100, biasLevelADU: 20)
        // Third session's camera never gets a `sensor_profile` row -- its
        // background must stay `nil` (SessionQuality's own bias-pedestal
        // rule), so it cannot push this library over `minimumSessionCount`.
        let fileID = try db.upsertFile(FileRecord(
            path: "sessions/M31/2026-01-03/lights/a.fit", size: 1024, mtime: 1_700_000_000,
            ext: "fit", kind: "fits", area: .sessions, target: "M31", sessionDate: "2026-01-03",
            role: .light, scannedAt: 1_700_000_100
        ))
        try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
        try db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, exptime: 10, gain: 999, offset: 999,
            instrume: "UnmeasuredCamera", focallen: 206.265, xpixsz: 1.0, egain: 2.0
        ))
        try db.upsertRating(RatingRecord(
            fileID: fileID, fwhm: 2.5, background: 100, score: 0.1,
            ratedAt: 1_700_000_200, inputSig: "sig-unmeasured"
        ))

        let snapshot = try MeasuredSkyQuery.snapshot(db: db, config: AstroConfig())
        #expect(snapshot == nil, "only 2 of the 3 sessions have a measured background -- still below minimumSessionCount")
    }
}
