import Foundation
import Testing
@testable import AstroCore

/// `SessionTimeline.timeline` reads only `Database` rows (files +
/// fits_meta) -- these tests build exactly those rows directly, same spirit
/// as `SessionQualityTests`.
private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

/// Inserts one light-frame row (`files` + `fits_meta`) with a unique fake
/// `inode` (see `SessionQualityTests`'s `insertRatedLight` doc comment for
/// why -- without it, same-exptime/no-`dateObs` synthetic frames would
/// collide on `FrameSet`'s fallback dedup key and collapse to one).
@discardableResult
private func insertLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    exptime: Double? = nil,
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
    try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: exptime, dateObs: dateObs))
    return fileID
}

// MARK: - Window / gap / duty cycle math

@Test func timelineComputesWindowIntegrationAndDutyCycleWithExplicitGapThreshold() throws {
    let db = try makeMemoryDB()
    var config = AstroConfig()
    config.stats.gapThresholdSeconds = 100 // explicit, smaller than the 300s gaps below

    try insertLight(db: db, target: "M42", date: "2026-01-01", name: "a", exptime: 300, dateObs: "2026-01-01T22:00:00")
    try insertLight(db: db, target: "M42", date: "2026-01-01", name: "b", exptime: 300, dateObs: "2026-01-01T22:10:00")
    try insertLight(db: db, target: "M42", date: "2026-01-01", name: "c", exptime: 300, dateObs: "2026-01-01T22:20:00")

    let timeline = try SessionTimeline.timeline(target: "M42", date: "2026-01-01", db: db, config: config)

    #expect(timeline.windowStart == "2026-01-01T22:00:00Z")
    #expect(timeline.windowEnd == "2026-01-01T22:25:00Z") // last start (22:20) + 300s exptime
    #expect(timeline.windowSeconds == 1500) // 25 minutes
    #expect(timeline.integrationSeconds == 900) // 3 * 300s
    let dutyCycle = try #require(timeline.dutyCycle)
    #expect(abs(dutyCycle - 0.6) < 0.0001) // 900 / 1500

    // Two silent 5-minute (300s) gaps: 22:05->22:10 and 22:15->22:20.
    #expect(timeline.gaps.count == 2)
    #expect(timeline.gaps[0].start == "2026-01-01T22:05:00Z")
    #expect(timeline.gaps[0].end == "2026-01-01T22:10:00Z")
    #expect(timeline.gaps[0].seconds == 300)
    #expect(timeline.gaps[1].start == "2026-01-01T22:15:00Z")
    #expect(timeline.gaps[1].end == "2026-01-01T22:20:00Z")
    #expect(timeline.gaps[1].seconds == 300)
}

@Test func timelineAutoGapThresholdIsThreeTimesMedianNominalExptimeAndSuppressesSmallerGaps() throws {
    let db = try makeMemoryDB()
    // Default config: gapThresholdSeconds == 0 -> auto (3x median nominal
    // exptime). Median nominal exptime here is 300s, so the auto threshold
    // is 900s -- the same 300s gaps as the explicit-threshold test above
    // must NOT be flagged.
    let config = AstroConfig()
    #expect(config.stats.gapThresholdSeconds == 0)

    try insertLight(db: db, target: "M42", date: "2026-01-01", name: "a", exptime: 300, dateObs: "2026-01-01T22:00:00")
    try insertLight(db: db, target: "M42", date: "2026-01-01", name: "b", exptime: 300, dateObs: "2026-01-01T22:10:00")
    try insertLight(db: db, target: "M42", date: "2026-01-01", name: "c", exptime: 300, dateObs: "2026-01-01T22:20:00")

    let timeline = try SessionTimeline.timeline(target: "M42", date: "2026-01-01", db: db, config: config)
    #expect(timeline.gaps.isEmpty, "300s gaps must be under the auto 900s (3x median nominal exptime) threshold")
}

@Test func timelineAutoGapThresholdStillFlagsAGapLargerThanThreeTimesMedianExptime() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig() // auto threshold

    try insertLight(db: db, target: "M31", date: "2026-02-02", name: "a", exptime: 60, dateObs: "2026-02-02T20:00:00")
    try insertLight(db: db, target: "M31", date: "2026-02-02", name: "b", exptime: 60, dateObs: "2026-02-02T20:01:00")
    // A big cloud-out gap: auto threshold is 3 * 60s = 180s -- this 37min
    // gap (20:02:00, the end of frame "b", to 20:39:00) must be flagged.
    try insertLight(db: db, target: "M31", date: "2026-02-02", name: "c", exptime: 60, dateObs: "2026-02-02T20:39:00")

    let timeline = try SessionTimeline.timeline(target: "M31", date: "2026-02-02", db: db, config: config)
    #expect(timeline.gaps.count == 1)
    #expect(timeline.gaps[0].seconds == 37 * 60)
}

// MARK: - Mixed DATE-OBS formats

@Test func timelineParsesBothFITSAndEXIFDateObsFormatsAndSortsByStart() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    // EXIF-style timestamp inserted SECOND (out of chronological order) --
    // the timeline must still sort by actual start time.
    try insertLight(db: db, target: "M45", date: "2026-04-18", name: "later", exptime: 30, dateObs: "2026:04:18 04:40:24")
    try insertLight(
        db: db, target: "M45", date: "2026-04-18", name: "earlier", exptime: 30,
        dateObs: "2026-04-18T04:36:24.123"
    )

    let timeline = try SessionTimeline.timeline(target: "M45", date: "2026-04-18", db: db, config: config)

    #expect(timeline.windowStart == "2026-04-18T04:36:24Z")
    #expect(timeline.windowEnd == "2026-04-18T04:40:54Z") // 04:40:24 + 30s
    #expect(timeline.integrationSeconds == 60)
}

// MARK: - Graceful degradation

@Test func timelineHasNilWindowWhenNoDateObsParsesButStillSumsIntegration() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    try insertLight(db: db, target: "T1", date: "2026-01-01", name: "a", exptime: 60, dateObs: nil)
    try insertLight(db: db, target: "T1", date: "2026-01-01", name: "b", exptime: 90, dateObs: "not a real date")

    let timeline = try SessionTimeline.timeline(target: "T1", date: "2026-01-01", db: db, config: config)
    #expect(timeline.windowStart == nil)
    #expect(timeline.windowEnd == nil)
    #expect(timeline.windowSeconds == nil)
    #expect(timeline.dutyCycle == nil)
    #expect(timeline.gaps.isEmpty)
    #expect(timeline.integrationSeconds == 150)
}

@Test func timelineSingleFrameHasNoGapsAndFullDutyCycle() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    try insertLight(db: db, target: "T2", date: "2026-01-01", name: "a", exptime: 120, dateObs: "2026-01-01T21:00:00")

    let timeline = try SessionTimeline.timeline(target: "T2", date: "2026-01-01", db: db, config: config)
    #expect(timeline.gaps.isEmpty)
    #expect(timeline.windowSeconds == 120)
    #expect(timeline.dutyCycle == 1.0)
}

@Test func timelineUnknownSessionReturnsZeroedTimeline() throws {
    let db = try makeMemoryDB()
    let timeline = try SessionTimeline.timeline(target: "Nope", date: "2026-01-01", db: db, config: AstroConfig())
    #expect(timeline.windowStart == nil)
    #expect(timeline.integrationSeconds == 0)
    #expect(timeline.gaps.isEmpty)
}
