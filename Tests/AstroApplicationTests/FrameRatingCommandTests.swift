@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Pads a FITS card line to 80 characters and assembles a full 2880-byte
/// header block -- duplicated (not imported) from
/// `Tests/AstroCoreTests/RateTests.swift`'s own private helpers, since
/// AstroApplicationTests cannot import AstroCoreTests' file-private target
/// (same reasoning `CalibrationQueryTests.swift` already documents for its
/// own copy).
private func ratingCommandCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func ratingCommandHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(ratingCommandCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// A minimal signed-16-bit FITS light frame -- just enough for
/// `NativeStats.compute` to read real pixel data.
private func build16BitFITSFrame(width: Int, height: Int, pixels: [Int]) -> Data {
    precondition(pixels.count == width * height)
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
        "END",
    ]
    var data = ratingCommandHeaderData(cards)
    for value in pixels {
        let unsigned = UInt16(bitPattern: Int16(value))
        data.append(UInt8(unsigned >> 8))
        data.append(UInt8(unsigned & 0xFF))
    }
    return data
}

/// A fresh fixture library + fresh sqlite-backed `Database`, writing real
/// FITS bytes to disk (unlike `FrameQualityQueryTests`'s DB-only fixture) --
/// `FrameRatingCommand` delegates to `Rater`, which reads pixels off disk.
private struct RatingCommandFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> RatingCommandFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-rating-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-rating-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        // A path that is guaranteed not to exist, so `.fullReMeasure`
        // deterministically hits the "Siril unavailable" path regardless of
        // whether the machine running this test happens to have a real
        // Siril install at the library default.
        config.rating.sirilPath = "/definitely/not/a/real/binary/siril-cli"
        return RatingCommandFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    @discardableResult
    func addLightFrame(
        relativePath: String,
        target: String,
        sessionDate: String = "2026-01-01",
        pixels: [Int],
        width: Int,
        height: Int,
        mtime: Double = 1_700_000_000
    ) throws -> Int64 {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = build16BitFITSFrame(width: width, height: height, pixels: pixels)
        try data.write(to: url)
        let record = FileRecord(
            path: relativePath, size: Int64(data.count), mtime: mtime, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: sessionDate, role: .light,
            scannedAt: Date().timeIntervalSince1970
        )
        return try db.upsertFile(record)
    }

    /// A trivial "fake siril-cli" executable script that always reports a
    /// fixed, parseable findstar result -- lets `.fullReMeasure` be tested
    /// end to end (native stats + "Siril" star metrics) without depending on
    /// a real Siril install being present on the machine running this suite.
    func installFakeSirilCLI() throws -> String {
        let scriptURL = dbDir.appendingPathComponent("fake-siril-cli.sh")
        let script = """
        #!/bin/sh
        echo "log: Found 42 Gaussian profile stars in image, channel #0 (FWHM 3.0, roundness 0.87)"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }
}

/// Thread-safe recorder for a `progress`/`isCancelled` pair under test --
/// mirrors `Tests/AstroCoreTests/RateTests.swift`'s own `ProgressRecorder`,
/// since `progress`/`isCancelled` are `@Sendable` closures and a plain `var`
/// capture is rejected by the compiler's Sendable-closure-capture check.
private final class RatingProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(done: Int, total: Int)] = []
    var calls: [(done: Int, total: Int)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls.count
    }
    func record(_ done: Int, _ total: Int) {
        lock.lock(); _calls.append((done, total)); lock.unlock()
    }
}

@Suite("FrameRatingCommand")
struct FrameRatingCommandTests {
    @Test("Native-only mode rates fixture frames using only native pixel statistics")
    func nativeOnlyModeRatesWithoutSiril() throws {
        let fixture = try RatingCommandFixture.make()
        defer { fixture.cleanup() }

        let path = "sessions/M31/2026-01-01/lights/a.fit"
        let fileID = try fixture.addLightFrame(
            relativePath: path, target: "M31",
            pixels: Array(repeating: 200, count: 16), width: 4, height: 4
        )

        let command = FrameRatingCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        let results = try command.run(relativePaths: [path], mode: .nativeOnly)

        #expect(results.count == 1)
        let stored = try #require(try fixture.db.rating(fileID: fileID))
        #expect(stored.background == 200)
        #expect(stored.fwhm == nil, "native-only mode must never populate star metrics")
        #expect(stored.score != nil)
    }

    @Test("Full re-measure mode throws a clear typed error when Siril is unavailable")
    func fullReMeasureThrowsWhenSirilUnavailable() throws {
        let fixture = try RatingCommandFixture.make()
        defer { fixture.cleanup() }

        let path = "sessions/M31/2026-01-01/lights/a.fit"
        try fixture.addLightFrame(
            relativePath: path, target: "M31",
            pixels: Array(repeating: 200, count: 16), width: 4, height: 4
        )

        let command = FrameRatingCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        #expect(throws: FrameRatingCommandError.self) {
            _ = try command.run(relativePaths: [path], mode: .fullReMeasure)
        }
    }

    @Test("Full re-measure mode uses the configured Siril binary when it is available")
    func fullReMeasureUsesConfiguredSiril() throws {
        var fixture = try RatingCommandFixture.make()
        defer { fixture.cleanup() }
        fixture.config.rating.sirilPath = try fixture.installFakeSirilCLI()

        let path = "sessions/M31/2026-01-01/lights/a.fit"
        let fileID = try fixture.addLightFrame(
            relativePath: path, target: "M31",
            pixels: Array(repeating: 200, count: 16), width: 4, height: 4
        )

        let command = FrameRatingCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        let results = try command.run(relativePaths: [path], mode: .fullReMeasure)

        #expect(results.count == 1)
        let stored = try #require(try fixture.db.rating(fileID: fileID))
        #expect(stored.fwhm == 3.0)
        #expect(stored.starCount == 42)
        #expect(stored.sirilVersion != nil)
    }

    @Test("Rating a session scope rates every frame of that session, not only the ones passed in")
    func ratingUsesTheFullSessionScope() throws {
        let fixture = try RatingCommandFixture.make()
        defer { fixture.cleanup() }

        let anchorPath = "sessions/M31/2026-01-01/lights/a.fit"
        try fixture.addLightFrame(
            relativePath: anchorPath, target: "M31",
            pixels: Array(repeating: 200, count: 16), width: 4, height: 4
        )
        let siblingPath = "sessions/M31/2026-01-01/lights/b.fit"
        try fixture.addLightFrame(
            relativePath: siblingPath, target: "M31",
            pixels: Array(repeating: 210, count: 16), width: 4, height: 4
        )
        // A different session entirely -- must NOT be touched by a run
        // scoped to `anchorPath`'s own target/date.
        try fixture.addLightFrame(
            relativePath: "sessions/M42/2026-02-02/lights/c.fit", target: "M42", sessionDate: "2026-02-02",
            pixels: Array(repeating: 50, count: 16), width: 4, height: 4
        )

        let command = FrameRatingCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        // Only `anchorPath` is passed in, but the whole M31/2026-01-01
        // session (including `siblingPath`) is expected back, mirroring
        // `Rater.rate(target:date:)`'s own session-wide scope.
        let results = try command.run(relativePaths: [anchorPath], mode: .nativeOnly)

        #expect(Set(results.map(\.path)) == [anchorPath, siblingPath])
    }

    @Test("Rating throws a clear typed error when none of the requested paths are indexed")
    func throwsWhenNoFramesMatch() throws {
        let fixture = try RatingCommandFixture.make()
        defer { fixture.cleanup() }

        let command = FrameRatingCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        #expect(throws: FrameRatingCommandError.self) {
            _ = try command.run(relativePaths: ["sessions/Ghost/2026-01-01/lights/none.fit"], mode: .nativeOnly)
        }
    }

    @Test("Progress is reported once per frame in the session scope")
    func progressReportsPerFrame() throws {
        let fixture = try RatingCommandFixture.make()
        defer { fixture.cleanup() }

        let paths = (0..<3).map { "sessions/M31/2026-01-01/lights/f\($0).fit" }
        for path in paths {
            try fixture.addLightFrame(
                relativePath: path, target: "M31",
                pixels: Array(repeating: 200, count: 16), width: 4, height: 4
            )
        }

        let command = FrameRatingCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        let recorder = RatingProgressRecorder()
        _ = try command.run(relativePaths: [paths[0]], mode: .nativeOnly) { done, total in
            recorder.record(done, total)
        }

        #expect(recorder.count == 3)
        #expect(recorder.calls.last?.done == 3)
        #expect(recorder.calls.allSatisfy { $0.total == 3 })
    }

    @Test("Cancellation between frames stops the batch without losing already-rated frames")
    func cancellationBetweenFramesIsSafe() throws {
        let fixture = try RatingCommandFixture.make()
        defer { fixture.cleanup() }

        let paths = (0..<3).map { "sessions/M31/2026-01-01/lights/f\($0).fit" }
        var fileIDs: [Int64] = []
        for path in paths {
            let id = try fixture.addLightFrame(
                relativePath: path, target: "M31",
                pixels: Array(repeating: 200, count: 16), width: 4, height: 4
            )
            fileIDs.append(id)
        }

        let command = FrameRatingCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        let recorder = RatingProgressRecorder()
        #expect(throws: CancellationError.self) {
            _ = try command.run(
                relativePaths: [paths[0]], mode: .nativeOnly,
                progress: { done, total in recorder.record(done, total) },
                isCancelled: { recorder.count >= 1 }
            )
        }

        // The first frame's native measurement must already be durably
        // persisted even though the batch as a whole was cancelled before
        // finishing (batch-wide z-score scoring only ever runs after the
        // whole loop -- see `Rater.rate`'s own doc comment -- so a
        // cancelled run's frames are measured but not yet scored, exactly
        // like an interrupted process would leave them).
        let firstRated = try fixture.db.rating(fileID: fileIDs[0])
        #expect(firstRated?.background == 200, "a frame completed before cancellation must not be lost")
    }
}
