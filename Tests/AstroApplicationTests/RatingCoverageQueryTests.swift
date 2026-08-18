@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Same fixture shape as `FrameQualityQueryTests.QualityFixture` -- a fresh
/// sqlite-backed `Database`, writing `files`/`ratings` rows directly (no
/// scanner, no real FITS bytes) -- `RatingCoverageQuery` never touches the
/// filesystem, only the index DB.
private struct CoverageFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database

    static func make() throws -> CoverageFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rating-coverage-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rating-coverage-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        return CoverageFixture(libraryDir: libraryDir, dbDir: dbDir, db: db)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    @discardableResult
    func addLight(
        relativePath: String,
        target: String,
        sessionDate: String,
        area: LibraryArea = .sessions,
        role: FrameRole = .light,
        mtime: Double = 1_700_000_000
    ) throws -> Int64 {
        let record = FileRecord(
            path: relativePath, size: 1024, mtime: mtime, ext: "fit", kind: "fits",
            area: area, target: target, sessionDate: sessionDate, role: role,
            scannedAt: Date().timeIntervalSince1970
        )
        return try db.upsertFile(record)
    }

    func addRating(fileID: Int64, score: Double?) throws {
        try db.upsertRating(RatingRecord(
            fileID: fileID, score: score,
            ratedAt: Date().timeIntervalSince1970, inputSig: "1024-1700000000"
        ))
    }
}

@Suite("RatingCoverageQuery")
struct RatingCoverageQueryTests {
    @Test("A library with no scanned lights at all is honestly fully rated")
    func emptyLibraryReportsNothingUnrated() throws {
        let fixture = try CoverageFixture.make()
        defer { fixture.cleanup() }

        let snapshot = try RatingCoverageQuery(db: fixture.db).snapshot()

        #expect(snapshot.unratedNightCount == 0)
        #expect(snapshot.unratedFrameCount == 0)
    }

    @Test("A night whose frames have never been rated counts as one unrated night")
    func neverRatedNightCountsAsUnrated() throws {
        let fixture = try CoverageFixture.make()
        defer { fixture.cleanup() }

        try fixture.addLight(relativePath: "sessions/M31/2026-01-01/lights/a.fit", target: "M31", sessionDate: "2026-01-01")
        try fixture.addLight(relativePath: "sessions/M31/2026-01-01/lights/b.fit", target: "M31", sessionDate: "2026-01-01")

        let snapshot = try RatingCoverageQuery(db: fixture.db).snapshot()

        #expect(snapshot.unratedNightCount == 1)
        #expect(snapshot.unratedFrameCount == 2)
    }

    @Test("A night where every frame has a scored rating drops out of the count")
    func fullyRatedNightIsNotCounted() throws {
        let fixture = try CoverageFixture.make()
        defer { fixture.cleanup() }

        let fileID = try fixture.addLight(relativePath: "sessions/M31/2026-01-01/lights/a.fit", target: "M31", sessionDate: "2026-01-01")
        try fixture.addRating(fileID: fileID, score: 0.5)

        let snapshot = try RatingCoverageQuery(db: fixture.db).snapshot()

        #expect(snapshot.unratedNightCount == 0)
        #expect(snapshot.unratedFrameCount == 0)
    }

    @Test("One unrated frame is enough to count its whole night, even alongside rated siblings")
    func partiallyRatedNightStillCounts() throws {
        let fixture = try CoverageFixture.make()
        defer { fixture.cleanup() }

        let ratedID = try fixture.addLight(relativePath: "sessions/M31/2026-01-01/lights/a.fit", target: "M31", sessionDate: "2026-01-01")
        try fixture.addRating(fileID: ratedID, score: 0.5)
        try fixture.addLight(relativePath: "sessions/M31/2026-01-01/lights/b.fit", target: "M31", sessionDate: "2026-01-01")

        let snapshot = try RatingCoverageQuery(db: fixture.db).snapshot()

        #expect(snapshot.unratedNightCount == 1)
        #expect(snapshot.unratedFrameCount == 1)
    }

    @Test("A rating row with no score yet (never fully measured) still counts as unrated")
    func ratingRowWithNilScoreStillCountsAsUnrated() throws {
        let fixture = try CoverageFixture.make()
        defer { fixture.cleanup() }

        let fileID = try fixture.addLight(relativePath: "sessions/M31/2026-01-01/lights/a.fit", target: "M31", sessionDate: "2026-01-01")
        try fixture.addRating(fileID: fileID, score: nil)

        let snapshot = try RatingCoverageQuery(db: fixture.db).snapshot()

        #expect(snapshot.unratedNightCount == 1)
    }

    @Test("Distinct (target, sessionDate) pairs count as distinct nights, matching FrameRatingCommand's own session anchor")
    func distinctSessionsCountSeparately() throws {
        let fixture = try CoverageFixture.make()
        defer { fixture.cleanup() }

        try fixture.addLight(relativePath: "sessions/M31/2026-01-01/lights/a.fit", target: "M31", sessionDate: "2026-01-01")
        try fixture.addLight(relativePath: "sessions/M31/2026-01-02/lights/a.fit", target: "M31", sessionDate: "2026-01-02")
        try fixture.addLight(relativePath: "sessions/M42/2026-01-01/lights/a.fit", target: "M42", sessionDate: "2026-01-01")

        let snapshot = try RatingCoverageQuery(db: fixture.db).snapshot()

        #expect(snapshot.unratedNightCount == 3)
    }

    @Test("Non-light and non-session-area frames never count, matching Rater.rate's own filter")
    func onlySessionAreaLightFramesCount() throws {
        let fixture = try CoverageFixture.make()
        defer { fixture.cleanup() }

        try fixture.addLight(relativePath: "calibration/darks/300s/dark1.fit", target: "M31", sessionDate: "2026-01-01", area: .calibration, role: .dark)
        try fixture.addLight(relativePath: "stacks/M31/stack.fit", target: "M31", sessionDate: "2026-01-01", area: .stacks, role: .light)

        let snapshot = try RatingCoverageQuery(db: fixture.db).snapshot()

        #expect(snapshot.unratedNightCount == 0)
        #expect(snapshot.unratedFrameCount == 0)
    }

    @Test("A missing frame with no target/sessionDate at all is excluded, never mistaken for one unrated night")
    func frameWithNoTargetIsExcluded() throws {
        let fixture = try CoverageFixture.make()
        defer { fixture.cleanup() }

        let record = FileRecord(
            path: "sessions/unknown/lights/a.fit", size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: nil, sessionDate: nil, role: .light,
            scannedAt: Date().timeIntervalSince1970
        )
        try fixture.db.upsertFile(record)

        let snapshot = try RatingCoverageQuery(db: fixture.db).snapshot()

        #expect(snapshot.unratedNightCount == 0)
        #expect(snapshot.unratedFrameCount == 0)
    }
}
