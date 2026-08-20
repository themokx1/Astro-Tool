@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// A fresh fixture library + fresh sqlite-backed `Database`, writing `files`/
/// `ratings` rows directly (no scanner, no real FITS bytes on disk) --
/// `FrameQualityQuery` never touches the filesystem, only the index DB, so
/// this mirrors `Tests/AstroCoreTests/RateTests.swift`'s own `RateFixture`
/// minus the parts that write actual pixel data.
private struct QualityFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> QualityFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-quality-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-quality-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return QualityFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Registers a scanned light frame row, without writing any bytes.
    @discardableResult
    func addFile(
        relativePath: String,
        target: String = "M31",
        sessionDate: String = "2026-01-01",
        mtime: Double = 1_700_000_000
    ) throws -> Int64 {
        let record = FileRecord(
            path: relativePath,
            size: 1024,
            mtime: mtime,
            ext: "fit",
            kind: "fits",
            area: .sessions,
            target: target,
            sessionDate: sessionDate,
            role: .light,
            scannedAt: Date().timeIntervalSince1970
        )
        return try db.upsertFile(record)
    }

    /// Registers a rating row for a previously-added file.
    func addRating(
        fileID: Int64,
        fwhm: Double? = nil,
        roundness: Double? = nil,
        starCount: Int? = nil,
        background: Double? = nil,
        saturatedFraction: Double? = nil,
        score: Double?
    ) throws {
        try db.upsertRating(RatingRecord(
            fileID: fileID,
            fwhm: fwhm,
            roundness: roundness,
            starCount: starCount,
            background: background,
            saturatedFraction: saturatedFraction,
            score: score,
            ratedAt: Date().timeIntervalSince1970,
            inputSig: "1024-1700000000"
        ))
    }
}

@Suite("FrameQualityQuery")
struct FrameQualityQueryTests {
    @Test("A rated frame's measured metrics come back straight from the index DB")
    func measuredFrameReturnsItsStoredMetrics() throws {
        let fixture = try QualityFixture.make()
        defer { fixture.cleanup() }

        let fileID = try fixture.addFile(relativePath: "sessions/M31/2026-01-01/lights/a.fit")
        try fixture.addRating(
            fileID: fileID, fwhm: 2.4, roundness: 0.91, starCount: 210,
            background: 320, saturatedFraction: 0.01, score: 0.5
        )

        let query = FrameQualityQuery(db: fixture.db, config: fixture.config)
        let results = try query.metrics(relativePaths: ["sessions/M31/2026-01-01/lights/a.fit"])

        let row = try #require(results.first)
        #expect(row.relativePath == "sessions/M31/2026-01-01/lights/a.fit")
        #expect(row.fwhm == 2.4)
        #expect(row.roundness == 0.91)
        #expect(row.starCount == 210)
        #expect(row.background == 320)
        #expect(row.saturatedFraction == 0.01)
        #expect(row.score == 0.5)
    }

    @Test("A frame with no rating row yet reports nil metrics, never zeros")
    func unratedFrameReportsNilNotZero() throws {
        let fixture = try QualityFixture.make()
        defer { fixture.cleanup() }

        try fixture.addFile(relativePath: "sessions/M31/2026-01-01/lights/never-rated.fit")

        let query = FrameQualityQuery(db: fixture.db, config: fixture.config)
        let results = try query.metrics(relativePaths: ["sessions/M31/2026-01-01/lights/never-rated.fit"])

        let row = try #require(results.first)
        #expect(row.fwhm == nil)
        #expect(row.roundness == nil)
        #expect(row.starCount == nil)
        #expect(row.background == nil)
        #expect(row.saturatedFraction == nil)
        #expect(row.score == nil)
        #expect(row.isOutlier == nil)
        #expect(row.libraryPercentile == nil)
    }

    @Test("A relative path with no scanned file row at all still reports nil metrics, not a crash")
    func neverScannedPathReportsNilMetrics() throws {
        let fixture = try QualityFixture.make()
        defer { fixture.cleanup() }

        let query = FrameQualityQuery(db: fixture.db, config: fixture.config)
        let results = try query.metrics(relativePaths: ["sessions/M31/2026-01-01/lights/ghost.fit"])

        let row = try #require(results.first)
        #expect(row.relativePath == "sessions/M31/2026-01-01/lights/ghost.fit")
        #expect(row.score == nil)
    }

    @Test("Results preserve the caller's requested path order")
    func resultsPreserveRequestedOrder() throws {
        let fixture = try QualityFixture.make()
        defer { fixture.cleanup() }

        let idB = try fixture.addFile(relativePath: "sessions/M31/2026-01-01/lights/b.fit")
        let idA = try fixture.addFile(relativePath: "sessions/M31/2026-01-01/lights/a.fit")
        try fixture.addRating(fileID: idA, score: 0.1)
        try fixture.addRating(fileID: idB, score: 0.2)

        let query = FrameQualityQuery(db: fixture.db, config: fixture.config)
        let results = try query.metrics(relativePaths: [
            "sessions/M31/2026-01-01/lights/b.fit",
            "sessions/M31/2026-01-01/lights/a.fit",
        ])

        #expect(results.map(\.relativePath) == [
            "sessions/M31/2026-01-01/lights/b.fit",
            "sessions/M31/2026-01-01/lights/a.fit",
        ])
    }

    @Test("isOutlier reflects the same score < -outlierZScore threshold the rating engine itself uses")
    func isOutlierUsesEngineThreshold() throws {
        let fixture = try QualityFixture.make()
        defer { fixture.cleanup() }

        let goodID = try fixture.addFile(relativePath: "sessions/M31/2026-01-01/lights/good.fit")
        let badID = try fixture.addFile(relativePath: "sessions/M31/2026-01-01/lights/bad.fit")
        try fixture.addRating(fileID: goodID, score: 0.4)
        try fixture.addRating(fileID: badID, score: -10)

        let query = FrameQualityQuery(db: fixture.db, config: fixture.config)
        let results = try query.metrics(relativePaths: [
            "sessions/M31/2026-01-01/lights/good.fit",
            "sessions/M31/2026-01-01/lights/bad.fit",
        ])

        #expect(results[0].isOutlier == false)
        #expect(results[1].isOutlier == true)
    }

    @Test("Library percentile ranks a rated frame's score against every other rated frame in the library")
    func libraryPercentileRanksAgainstTheWholeLibrary() throws {
        let fixture = try QualityFixture.make()
        defer { fixture.cleanup() }

        // Six rated frames (the minimum sample size) so the percentile band
        // is a confident color, not a low-sample neutral marker.
        let scores = [0.9, 0.7, 0.5, 0.3, 0.1, -0.2]
        var paths: [String] = []
        for (index, score) in scores.enumerated() {
            let path = "sessions/M31/2026-01-01/lights/f\(index).fit"
            paths.append(path)
            let fileID = try fixture.addFile(relativePath: path)
            try fixture.addRating(fileID: fileID, score: score)
        }

        let query = FrameQualityQuery(db: fixture.db, config: fixture.config)
        let results = try query.metrics(relativePaths: paths)

        let best = try #require(results.first { $0.relativePath == paths[0] })
        let worst = try #require(results.first { $0.relativePath == paths[5] })
        #expect(best.libraryPercentile?.band == .best)
        #expect(worst.libraryPercentile?.band == .worst)
        #expect(best.libraryPercentile?.isLowSample == false)
    }

    @Test("Too few rated frames in the library report a low-sample percentile rather than a color band")
    func libraryPercentileIsLowSampleBelowMinimum() throws {
        let fixture = try QualityFixture.make()
        defer { fixture.cleanup() }

        let fileID = try fixture.addFile(relativePath: "sessions/M31/2026-01-01/lights/only.fit")
        try fixture.addRating(fileID: fileID, score: 0.5)

        let query = FrameQualityQuery(db: fixture.db, config: fixture.config)
        let results = try query.metrics(relativePaths: ["sessions/M31/2026-01-01/lights/only.fit"])

        #expect(results.first?.libraryPercentile?.isLowSample == true)
    }
}
