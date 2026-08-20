@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Session Summary Card thumbnail follow-up (expert ideation spec #4):
/// `RepresentativeFrameQuery` picks one usable light to thumbnail. `pick(_:)`
/// is tested directly against synthetic candidates (no `Database` needed);
/// `representativeFrame(target:date:)` is tested end-to-end against a real
/// `Database` fixture, same spirit as `SessionQualityTests`' own
/// `insertRatedLight` helper (duplicated here rather than shared, matching
/// that file's own "each fixture owns its own copy" convention).
@Suite("RepresentativeFrameQuery")
struct RepresentativeFrameQueryTests {
    // MARK: - Pure selection rule

    @Test("Empty candidates pick nothing")
    func emptyCandidatesPickNothing() {
        #expect(RepresentativeFrameQuery.pick([]) == nil)
    }

    @Test("The highest-scored usable light wins when any candidate has a score")
    func highestScoreWins() {
        let candidates = [
            RepresentativeFrameCandidate(relativePath: "a.fit", score: 0.1, captureTime: nil),
            RepresentativeFrameCandidate(relativePath: "b.fit", score: 0.9, captureTime: nil),
            RepresentativeFrameCandidate(relativePath: "c.fit", score: -0.4, captureTime: nil),
        ]
        #expect(RepresentativeFrameQuery.pick(candidates) == "b.fit")
    }

    @Test("A mix of scored and unscored candidates still picks the highest score, ignoring unscored ones")
    func mixedScoredAndUnscoredPicksHighestScore() {
        let candidates = [
            RepresentativeFrameCandidate(relativePath: "unscored.fit", score: nil, captureTime: Date(timeIntervalSince1970: 0)),
            RepresentativeFrameCandidate(relativePath: "scored.fit", score: 0.2, captureTime: nil),
        ]
        #expect(RepresentativeFrameQuery.pick(candidates) == "scored.fit")
    }

    @Test("With no scores at all, the middle usable light by capture time is picked")
    func noScoresFallsBackToMiddleByCaptureTime() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates = [
            RepresentativeFrameCandidate(relativePath: "first.fit", score: nil, captureTime: base),
            RepresentativeFrameCandidate(relativePath: "middle.fit", score: nil, captureTime: base.addingTimeInterval(60)),
            RepresentativeFrameCandidate(relativePath: "last.fit", score: nil, captureTime: base.addingTimeInterval(120)),
        ]
        #expect(RepresentativeFrameQuery.pick(candidates) == "middle.fit")
    }

    @Test("Capture-time ordering, not insertion order, decides the middle frame")
    func captureTimeOrderingNotInsertionOrder() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let candidates = [
            RepresentativeFrameCandidate(relativePath: "last.fit", score: nil, captureTime: base.addingTimeInterval(120)),
            RepresentativeFrameCandidate(relativePath: "first.fit", score: nil, captureTime: base),
            RepresentativeFrameCandidate(relativePath: "middle.fit", score: nil, captureTime: base.addingTimeInterval(60)),
        ]
        #expect(RepresentativeFrameQuery.pick(candidates) == "middle.fit")
    }

    @Test("With no scores and no capture times at all, nothing is picked")
    func noScoresNoCaptureTimesPicksNothing() {
        let candidates = [
            RepresentativeFrameCandidate(relativePath: "a.fit", score: nil, captureTime: nil),
            RepresentativeFrameCandidate(relativePath: "b.fit", score: nil, captureTime: nil),
        ]
        #expect(RepresentativeFrameQuery.pick(candidates) == nil)
    }

    @Test("A single unscored, untimed candidate still picks nothing -- 'middle of one' needs a time to rank by")
    func singleUnscoredUntimedCandidatePicksNothing() {
        let candidates = [RepresentativeFrameCandidate(relativePath: "only.fit", score: nil, captureTime: nil)]
        #expect(RepresentativeFrameQuery.pick(candidates) == nil)
    }

    // MARK: - End-to-end against a real Database fixture

    private func makeMemoryDB() throws -> Database {
        try Database(path: ":memory:")
    }

    /// Inserts one usable light-frame row (`files` + `fits_meta`, optionally
    /// `ratings`) and returns its `fileID`. Mirrors `SessionQualityTests`'
    /// own `insertRatedLight` helper, including its `backfillInode` trick so
    /// synthetic rows with no real file to `stat()` don't collide in
    /// `FrameSet.lightBuckets`'s dedup pass (see that helper's own doc
    /// comment for exactly why).
    @discardableResult
    private func insertUsableLight(
        db: Database,
        target: String,
        date: String,
        name: String,
        dateObs: String? = nil,
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
        try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
        try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, dateObs: dateObs))
        if withRating {
            try db.upsertRating(
                RatingRecord(fileID: fileID, score: score, ratedAt: 1_700_000_200, inputSig: "sig-\(name)")
            )
        }
        return fileID
    }

    @Test("An unrated session with no ratings.score anywhere falls back to the middle frame by DATE-OBS")
    func endToEndFallsBackToMiddleByDateObs() throws {
        let db = try makeMemoryDB()
        var config = AstroConfig()
        config.rootPath = "/tmp/does-not-matter"

        try insertUsableLight(db: db, target: "T1", date: "2026-08-17", name: "a", dateObs: "2026-08-17T01:00:00", withRating: false)
        try insertUsableLight(db: db, target: "T1", date: "2026-08-17", name: "b", dateObs: "2026-08-17T02:00:00", withRating: false)
        try insertUsableLight(db: db, target: "T1", date: "2026-08-17", name: "c", dateObs: "2026-08-17T03:00:00", withRating: false)

        let result = try RepresentativeFrameQuery(db: db, config: config).representativeFrame(target: "T1", date: "2026-08-17")
        #expect(result == "sessions/T1/2026-08-17/lights/b.fit")
    }

    @Test("A rated session picks the highest-scored usable light regardless of capture time")
    func endToEndPicksHighestScoredLight() throws {
        let db = try makeMemoryDB()
        var config = AstroConfig()
        config.rootPath = "/tmp/does-not-matter"

        try insertUsableLight(db: db, target: "T1", date: "2026-08-17", name: "a", dateObs: "2026-08-17T01:00:00", score: -0.2)
        try insertUsableLight(db: db, target: "T1", date: "2026-08-17", name: "b", dateObs: "2026-08-17T02:00:00", score: 1.4)
        try insertUsableLight(db: db, target: "T1", date: "2026-08-17", name: "c", dateObs: "2026-08-17T03:00:00", score: 0.1)

        let result = try RepresentativeFrameQuery(db: db, config: config).representativeFrame(target: "T1", date: "2026-08-17")
        #expect(result == "sessions/T1/2026-08-17/lights/b.fit")
    }

    @Test("A target/date with no session files at all picks nothing")
    func endToEndNoFilesPicksNothing() throws {
        let db = try makeMemoryDB()
        var config = AstroConfig()
        config.rootPath = "/tmp/does-not-matter"

        let result = try RepresentativeFrameQuery(db: db, config: config).representativeFrame(target: "Ghost", date: "2026-01-01")
        #expect(result == nil)
    }
}
