import Foundation
import Testing
@testable import AstroCore

/// `SessionQuality` reads only `Database` rows (files + fits_meta +
/// ratings) -- these tests build exactly those rows directly (no scanner,
/// no real FITS/image files), same spirit as `DatabaseTests`'s round-trip
/// tests.
private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

/// Inserts one light-frame row (`files` + `fits_meta` + `ratings`) and
/// returns its `fileID`. Every metric parameter is optional so a test can
/// build exactly the "graceful nil" shape it needs.
@discardableResult
private func insertRatedLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    exptime: Double? = nil,
    xpixsz: Double? = nil,
    focallen: Double? = nil,
    egain: Double? = nil,
    fwhm: Double? = nil,
    background: Double? = nil,
    starCount: Int? = nil,
    score: Double? = nil,
    withRating: Bool = true
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
    // PRIMARY dedup key), so distinct real frames never collide. These
    // synthetic rows have no real file to `stat()`, so without this they'd
    // all share `inode == nil` and fall through to `FrameSet`'s FALLBACK key
    // (`target|sessionDate|dateObs|exptime`) -- which, with none of these
    // fixtures setting `dateObs`, would make every same-exptime frame in one
    // session collide and collapse to a single "canonical" copy. Using the
    // never-reused `fileID` itself as a fake inode keeps every synthetic row
    // in its own dedup group of one, same as a real scan would.
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
    try db.upsertFITSMeta(
        FITSMetaRecord(fileID: fileID, exptime: exptime, focallen: focallen, xpixsz: xpixsz, egain: egain)
    )
    if withRating {
        try db.upsertRating(
            RatingRecord(
                fileID: fileID, fwhm: fwhm, starCount: starCount, background: background,
                score: score, ratedAt: 1_700_000_200, inputSig: "sig-\(name)"
            )
        )
    }
    return fileID
}

// MARK: - Arcsec math

@Test func sessionQualityComputesExactPixelScaleAndFWHMArcsecFromXpixszAndFocallen() throws {
    let db = try makeMemoryDB()
    // Real-data ground truth from the task spec: 3.76µm pixels / 302mm focal
    // length -> ~2.569 arcsec/px.
    try insertRatedLight(
        db: db, target: "M42", date: "2026-01-01", name: "a",
        exptime: 300, xpixsz: 3.76, focallen: 302, egain: 0.75,
        fwhm: 3.0, background: 500, starCount: 800, score: 0.5
    )

    let summaries = try SessionQuality.summaries(target: "M42", db: db, config: AstroConfig())
    let summary = try #require(summaries.first)

    let expectedScale = 206.265 * 3.76 / 302.0
    #expect(abs(expectedScale - 2.569) < 0.01)
    let pixelScale = try #require(summary.pixelScaleArcsec)
    #expect(abs(pixelScale - expectedScale) < 0.0001)

    let fwhmArcsec = try #require(summary.medianFWHMArcsec)
    #expect(abs(fwhmArcsec - 3.0 * expectedScale) < 0.0001)
    #expect(summary.medianFWHMPixels == 3.0)
    #expect(summary.frameCount == 1)
}

@Test func sessionQualityComputesBackgroundInElectronsPerSecondPerArcsec2() throws {
    let db = try makeMemoryDB()
    // Chosen so the pixel scale comes out to exactly 1 arcsec/px
    // (206.265 * 1 / 206.265 == 1), so the background conversion's own
    // arithmetic is the only thing under test:
    // background(ADU) * egain / exptime / scale^2 = 100 * 2.0 / 10 / 1 = 20.
    try insertRatedLight(
        db: db, target: "M31", date: "2026-02-02", name: "a",
        exptime: 10, xpixsz: 1.0, focallen: 206.265, egain: 2.0,
        fwhm: 2.5, background: 100, starCount: 500, score: 0.1
    )

    let summaries = try SessionQuality.summaries(target: "M31", db: db, config: AstroConfig())
    let summary = try #require(summaries.first)

    #expect(summary.medianBackgroundADU == 100)
    let backgroundE = try #require(summary.backgroundEPerSecPerArcsec2)
    #expect(abs(backgroundE - 20.0) < 0.0001)
}

// MARK: - Median over multiple frames

@Test func sessionQualityMediansOddAndEvenFrameCountsCorrectly() throws {
    let db = try makeMemoryDB()
    for (name, fwhm) in [("a", 2.0), ("b", 3.0), ("c", 4.0)] {
        try insertRatedLight(
            db: db, target: "T1", date: "2026-01-01", name: name,
            exptime: 60, fwhm: fwhm, background: 100, starCount: 100, score: 0
        )
    }
    let summaries = try SessionQuality.summaries(target: "T1", db: db, config: AstroConfig())
    #expect(try #require(summaries.first).medianFWHMPixels == 3.0)

    // A 4th frame makes it even -- median becomes the average of the two
    // middle values (3.0 and 4.0).
    try insertRatedLight(
        db: db, target: "T2", date: "2026-01-01", name: "d",
        exptime: 60, fwhm: 2.0, background: 100, starCount: 100, score: 0
    )
    try insertRatedLight(
        db: db, target: "T2", date: "2026-01-01", name: "e",
        exptime: 60, fwhm: 3.0, background: 100, starCount: 100, score: 0
    )
    try insertRatedLight(
        db: db, target: "T2", date: "2026-01-01", name: "f",
        exptime: 60, fwhm: 4.0, background: 100, starCount: 100, score: 0
    )
    try insertRatedLight(
        db: db, target: "T2", date: "2026-01-01", name: "g",
        exptime: 60, fwhm: 10.0, background: 100, starCount: 100, score: 0
    )
    let summaries2 = try SessionQuality.summaries(target: "T2", db: db, config: AstroConfig())
    #expect(try #require(summaries2.first).medianFWHMPixels == 3.5)
}

// MARK: - Outlier fraction

@Test func sessionQualityOutlierFractionUsesConfiguredZScoreThreshold() throws {
    let db = try makeMemoryDB()
    var config = AstroConfig()
    config.rating.outlierZScore = 1.0

    try insertRatedLight(db: db, target: "T3", date: "2026-01-01", name: "good", exptime: 60, score: 0.5)
    try insertRatedLight(db: db, target: "T3", date: "2026-01-01", name: "ok", exptime: 60, score: 0)
    try insertRatedLight(db: db, target: "T3", date: "2026-01-01", name: "bad", exptime: 60, score: -1.5)

    let summaries = try SessionQuality.summaries(target: "T3", db: db, config: config)
    let summary = try #require(summaries.first)
    // Only "bad" (-1.5) falls below -1.0.
    #expect(abs((summary.outlierFraction ?? -1) - (1.0 / 3.0)) < 0.0001)
}

// MARK: - Ranking

@Test func sessionQualityRanksSessionsByAscendingFWHMArcsecWithNilsExcluded() throws {
    let db = try makeMemoryDB()
    // Best (lowest FWHM arcsec): 2026-01-03. Worst: 2026-01-01.
    try insertRatedLight(
        db: db, target: "R1", date: "2026-01-01", name: "a", exptime: 60,
        xpixsz: 3.76, focallen: 302, fwhm: 5.0, score: 0
    )
    try insertRatedLight(
        db: db, target: "R1", date: "2026-01-02", name: "b", exptime: 60,
        xpixsz: 3.76, focallen: 302, fwhm: 3.0, score: 0
    )
    try insertRatedLight(
        db: db, target: "R1", date: "2026-01-03", name: "c", exptime: 60,
        xpixsz: 3.76, focallen: 302, fwhm: 1.0, score: 0
    )
    // A 4th session with no rated frames at all -- no FWHM to rank by.
    _ = try insertRatedLight(
        db: db, target: "R1", date: "2026-01-04", name: "d", exptime: 60, withRating: false
    )

    let summaries = try SessionQuality.summaries(target: "R1", db: db, config: AstroConfig())
    #expect(summaries.map(\.date) == ["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04"])

    let byDate = Dictionary(uniqueKeysWithValues: summaries.map { ($0.date, $0) })
    #expect(byDate["2026-01-03"]?.rankAmongSessions == 1)
    #expect(byDate["2026-01-02"]?.rankAmongSessions == 2)
    #expect(byDate["2026-01-01"]?.rankAmongSessions == 3)
    #expect(byDate["2026-01-04"]?.rankAmongSessions == nil)
    #expect(summaries.allSatisfy { $0.sessionCountForTarget == 4 })
}

// MARK: - Graceful nils

@Test func sessionQualityGracefullyHandlesMissingMetadataAndUnratedFrames() throws {
    let db = try makeMemoryDB()
    // No fits_meta xpixsz/focallen/egain at all -- only native background is
    // measurable, everything arcsec/electron-derived stays nil.
    try insertRatedLight(
        db: db, target: "G1", date: "2026-01-01", name: "a",
        exptime: 60, fwhm: 3.0, background: 200, starCount: 300, score: 0.2
    )

    let summaries = try SessionQuality.summaries(target: "G1", db: db, config: AstroConfig())
    let summary = try #require(summaries.first)

    #expect(summary.frameCount == 1)
    #expect(summary.medianFWHMPixels == 3.0)
    #expect(summary.medianFWHMArcsec == nil)
    #expect(summary.pixelScaleArcsec == nil)
    #expect(summary.medianBackgroundADU == 200)
    #expect(summary.backgroundEPerSecPerArcsec2 == nil)
    #expect(summary.medianStarCount == 300)
    #expect(summary.rankAmongSessions == nil)
}

@Test func sessionQualityReturnsEmptyArrayForUnknownTarget() throws {
    let db = try makeMemoryDB()
    let summaries = try SessionQuality.summaries(target: "DoesNotExist", db: db, config: AstroConfig())
    #expect(summaries.isEmpty)
}
