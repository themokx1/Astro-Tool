import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixture helpers

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-rate-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Builds a complete FITS file: a plain primary header (`BITPIX 16`,
/// `NAXIS1`/`NAXIS2` set from `width`/`height`, `BZERO` included only when
/// `bzero` is given) immediately followed by big-endian `Int16` pixel data.
/// When `bzero == 32768` (the standard "unsigned 16-bit stored as signed"
/// convention), each physical `pixels` value is written as `value - 32768`
/// so that `NativeStats` (which adds the offset back) reads back the
/// original value.
private func build16BitFITS(width: Int, height: Int, pixels: [Int], bzero: Int? = nil) -> Data {
    precondition(pixels.count == width * height)
    var cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
    ]
    if let bzero {
        cards.append("BZERO   =                \(bzero)")
    }
    cards.append("END")

    var data = buildHeaderData(cards)
    var pixelBytes = Data()
    pixelBytes.reserveCapacity(pixels.count * 2)
    for value in pixels {
        let raw = Int16(bzero.map { value - $0 } ?? value)
        let unsigned = UInt16(bitPattern: raw)
        pixelBytes.append(UInt8(unsigned >> 8))
        pixelBytes.append(UInt8(unsigned & 0xFF))
    }
    data.append(pixelBytes)
    return data
}

/// A fresh fixture library + fresh sqlite-backed `Database`, plus a helper
/// to register a light frame directly (bypassing the scanner/classifier —
/// these tests only care about `Rater`/`NativeStats`/`SirilCLI`, so the DB
/// row's `area`/`role`/`target`/`sessionDate` are set explicitly rather
/// than derived from a directory-naming convention).
private struct RateFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> RateFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return RateFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Writes a 16-bit FITS light frame at `relativePath` and registers a
    /// matching `files` row for it. Returns the DB `fileID` and the byte
    /// size actually written, so tests can predict the exact `inputSig`.
    @discardableResult
    func addLightFrame(
        relativePath: String,
        target: String,
        sessionDate: String = "2026-01-01",
        pixels: [Int],
        width: Int,
        height: Int,
        bzero: Int? = nil,
        mtime: Double = 1_700_000_000
    ) throws -> (fileID: Int64, size: Int64) {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = build16BitFITS(width: width, height: height, pixels: pixels, bzero: bzero)
        try data.write(to: url)

        let record = FileRecord(
            path: relativePath,
            size: Int64(data.count),
            mtime: mtime,
            ext: "fit",
            kind: "fits",
            area: .sessions,
            target: target,
            sessionDate: sessionDate,
            role: .light,
            scannedAt: Date().timeIntervalSince1970
        )
        let fileID = try db.upsertFile(record)
        return (fileID, Int64(data.count))
    }
}

// MARK: - Mock providers

/// Counts calls and always returns the same metrics -- used for cache-hit
/// verification (the count must not increase on a second `rate()` call for
/// an unchanged frame).
private final class CountingMockProvider: StarMetricsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    let version = "mock-counting-1.0"
    let fixedResult: StarMetrics

    init(fixedResult: StarMetrics = StarMetrics(fwhm: 2.0, roundness: 0.9, starCount: 100)) {
        self.fixedResult = fixedResult
    }

    func metrics(for url: URL, workDir: URL) throws -> StarMetrics {
        lock.lock()
        _callCount += 1
        lock.unlock()
        return fixedResult
    }
}

/// Returns a scripted `StarMetrics` keyed by the image's filename, and
/// records every `workDir` it was called with.
private final class ScriptedMockProvider: StarMetricsProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _workDirs: [URL] = []
    var workDirs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _workDirs
    }

    let version = "mock-scripted-1.0"
    private let responses: [String: StarMetrics]

    init(responses: [String: StarMetrics]) {
        self.responses = responses
    }

    struct NoResponse: Error {}

    func metrics(for url: URL, workDir: URL) throws -> StarMetrics {
        lock.lock()
        _workDirs.append(workDir)
        lock.unlock()
        guard let result = responses[url.lastPathComponent] else {
            throw NoResponse()
        }
        return result
    }
}

/// Always throws -- used to verify a per-frame provider failure keeps the
/// native stats but drops the star metrics for that frame.
private struct ThrowingMockProvider: StarMetricsProvider {
    struct Boom: Error {}
    let version = "mock-throwing-1.0"
    func metrics(for url: URL, workDir: URL) throws -> StarMetrics {
        throw Boom()
    }
}

/// Thread-safe recorder for the `progress` callback.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(done: Int, total: Int)] = []
    var calls: [(done: Int, total: Int)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    func record(_ done: Int, _ total: Int) {
        lock.lock(); _calls.append((done, total)); lock.unlock()
    }
}

// MARK: - NativeStats

@Test func nativeStatsComputesExactMedianAndSaturatedFractionForSigned16Bit() throws {
    // No BZERO: plain signed reads. maxValue = 32767, so the 0.98 threshold
    // (~32111) is far above every value here -- saturatedFraction is 0.
    let pixels = [10, 20, 30, 40, 5]
    let data = build16BitFITS(width: 5, height: 1, pixels: pixels)

    let stats = try NativeStats.compute(data: data)
    #expect(stats.backgroundMedian == 20) // sorted: 5,10,20,30,40 -> median 20
    #expect(stats.saturatedFraction == 0)
}

@Test func nativeStatsComputesExactMedianAndSaturatedFractionForUnsigned16BitWithBZero() throws {
    // BZERO=32768: unsigned range 0...65535, maxValue = 65535, threshold
    // 0.98*65535 = 64224.3. Only the 65535 pixel clears it.
    let pixels = [1000, 2000, 64000, 65535, 500]
    let data = build16BitFITS(width: 5, height: 1, pixels: pixels, bzero: 32768)

    let stats = try NativeStats.compute(data: data)
    #expect(stats.backgroundMedian == 2000) // sorted: 500,1000,2000,64000,65535 -> median 2000
    #expect(stats.saturatedFraction == 1.0 / 5.0)
}

@Test func nativeStatsMedianHandlesEvenPixelCount() throws {
    let pixels = [10, 20, 30, 40] // sorted median = (20+30)/2 = 25
    let data = build16BitFITS(width: 2, height: 2, pixels: pixels)

    let stats = try NativeStats.compute(data: data)
    #expect(stats.backgroundMedian == 25)
}

@Test func nativeStatsThrowsCorruptFITSForUnsupportedBitpix() throws {
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                  -32",
        "NAXIS   =                    2",
        "NAXIS1  =                    2",
        "NAXIS2  =                    2",
        "END",
    ]
    let data = buildHeaderData(cards)

    do {
        _ = try NativeStats.compute(data: data)
        Issue.record("expected AstroError.corruptFITS for unsupported BITPIX")
    } catch let AstroError.corruptFITS(_, reason) {
        #expect(reason.contains("BITPIX"))
    } catch {
        Issue.record("expected AstroError.corruptFITS, got \(error)")
    }
}

@Test func nativeStatsComputeFromURLReadsFile() throws {
    let dir = try makeTempDir("native-url")
    defer { try? FileManager.default.removeItem(at: dir) }

    let pixels = [1, 2, 3, 4]
    let data = build16BitFITS(width: 2, height: 2, pixels: pixels)
    let url = dir.appendingPathComponent("frame.fit")
    try data.write(to: url)

    let stats = try NativeStats.compute(url: url)
    #expect(stats.backgroundMedian == 2.5)
}

// MARK: - SirilCLI.parseFindstarOutput

@Test func parseFindstarOutputParsesTypicalOutput() {
    let output = """
    log: Loading image /tmp/foo.fit...
    log: Image size: 6252 x 4176 x 1
    log: Found 137 stars in image, channel #0 (FWHM 3.42, roundness 0.89)
    """
    let metrics = SirilCLI.parseFindstarOutput(output)
    #expect(metrics?.starCount == 137)
    #expect(metrics?.fwhm == 3.42)
    #expect(metrics?.roundness == 0.89)
}

@Test func parseFindstarOutputDefaultsRoundnessWhenAbsent() {
    let output = "log: Found 88 stars in image, channel #0 (FWHM 2.95)"
    let metrics = SirilCLI.parseFindstarOutput(output)
    #expect(metrics?.starCount == 88)
    #expect(metrics?.fwhm == 2.95)
    #expect(metrics?.roundness == 0.5)
}

@Test func parseFindstarOutputReturnsNilForGarbage() {
    let output = "some unrelated log noise, nothing usable here"
    #expect(SirilCLI.parseFindstarOutput(output) == nil)
}

// MARK: - SirilCLI.init

@Test func sirilCLIInitThrowsSirilNotFoundForNonexistentPath() {
    let bogusPath = "/definitely/not/a/real/binary/siril-cli"
    do {
        _ = try SirilCLI(path: bogusPath)
        Issue.record("expected AstroError.sirilNotFound")
    } catch let AstroError.sirilNotFound(path) {
        #expect(path == bogusPath)
    } catch {
        Issue.record("expected AstroError.sirilNotFound, got \(error)")
    }
}

@Test func sirilCLIBuildScriptContainsRequiresLoadFindstarClose() {
    let script = SirilCLI.buildScript(imagePath: "/tmp/some frame.fit")
    #expect(script.contains("requires 1.2.0"))
    #expect(script.contains("load \"/tmp/some frame.fit\""))
    #expect(script.contains("findstar"))
    #expect(script.contains("close"))
}

// MARK: - Rater: no frames

@Test func rateReturnsEmptyWhenNoFramesMatchTarget() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    let results = try rater.rate(target: "NoSuchTarget")
    #expect(results.isEmpty)
}

// MARK: - Rater: persistence + inputSig

@Test func rateWritesRatingRowWithExpectedInputSig() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    let pixels = Array(repeating: 200, count: 9)
    let (fileID, size) = try fixture.addLightFrame(
        relativePath: "sessions/M31/2026-01-01/lights/light_0001.fit",
        target: "M31", pixels: pixels, width: 3, height: 3, mtime: 1_650_000_000
    )

    let mock = CountingMockProvider()
    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)
    let results = try rater.rate(target: "M31")

    #expect(results.count == 1)
    #expect(mock.callCount == 1)

    let stored = try fixture.db.rating(fileID: fileID)
    #expect(stored?.inputSig == "\(size)-1650000000")
    #expect(stored?.background == 200)
    #expect(stored?.fwhm == 2.0)
    #expect(stored?.sirilVersion == "mock-counting-1.0")
    #expect(stored?.score != nil)
}

// MARK: - Rater: cache hit

@Test func cacheHitReusesStoredRatingWithoutRecomputingOrCallingProvider() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    let pixels = Array(repeating: 100, count: 16)
    let relativePath = "sessions/M42/2026-02-02/lights/light_0001.fit"
    try fixture.addLightFrame(
        relativePath: relativePath, target: "M42", pixels: pixels, width: 4, height: 4,
        mtime: 1_700_000_000
    )

    let mock = CountingMockProvider()
    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)

    let first = try rater.rate(target: "M42")
    #expect(first.count == 1)
    #expect(mock.callCount == 1)

    // Delete the underlying file: a re-rate that (incorrectly) tried to
    // recompute native stats or call the provider again would fail to read
    // it and drop the frame from the results.
    let fileURL = fixture.libraryDir.appendingPathComponent(relativePath)
    try FileManager.default.removeItem(at: fileURL)

    let second = try rater.rate(target: "M42")
    #expect(second.count == 1, "cached rating should be reused even though the source file is gone")
    #expect(mock.callCount == 1, "provider must not be called again on a cache hit")
}

// MARK: - Rater: provider throw keeps native stats

@Test func providerThrowKeepsNativeStatsButDropsMetrics() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    let pixels = Array(repeating: 77, count: 4)
    try fixture.addLightFrame(
        relativePath: "sessions/M13/2026-03-03/lights/light_0001.fit",
        target: "M13", pixels: pixels, width: 2, height: 2
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: ThrowingMockProvider())
    let results = try rater.rate(target: "M13")

    #expect(results.count == 1)
    #expect(results[0].metrics == nil)
    #expect(results[0].background == 77)
}

// MARK: - Rater: scoring orientation + outlier

@Test func scoringOrientationAndOutlierDetection() throws {
    var fixture = try RateFixture.make()
    fixture.config.rating.outlierZScore = 1.0
    defer { fixture.cleanup() }

    // All four metrics arranged so "A" is best on every axis, "C" worst,
    // evenly spaced (so the |z| magnitude is identical, sqrt(3/2), across
    // every metric and every frame) -- this makes the combined score exact
    // and the ordering/outlier result fully deterministic.
    try fixture.addLightFrame(
        relativePath: "sessions/T/2026-01-01/lights/A.fit",
        target: "T", pixels: Array(repeating: 50, count: 4), width: 2, height: 2
    )
    try fixture.addLightFrame(
        relativePath: "sessions/T/2026-01-01/lights/B.fit",
        target: "T", pixels: Array(repeating: 100, count: 4), width: 2, height: 2
    )
    try fixture.addLightFrame(
        relativePath: "sessions/T/2026-01-01/lights/C.fit",
        target: "T", pixels: Array(repeating: 150, count: 4), width: 2, height: 2
    )

    let mock = ScriptedMockProvider(responses: [
        "A.fit": StarMetrics(fwhm: 1, roundness: 0.9, starCount: 300),
        "B.fit": StarMetrics(fwhm: 2, roundness: 0.8, starCount: 200),
        "C.fit": StarMetrics(fwhm: 3, roundness: 0.7, starCount: 100),
    ])

    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)
    let results = try rater.rate(target: "T")

    #expect(results.count == 3)
    #expect(results.map(\.path) == [
        "sessions/T/2026-01-01/lights/A.fit",
        "sessions/T/2026-01-01/lights/B.fit",
        "sessions/T/2026-01-01/lights/C.fit",
    ], "expected descending score order A > B > C")

    let expectedMagnitude = (3.0 / 2.0).squareRoot() // sqrt(3/2), the z-score magnitude for an evenly spaced 3-point set
    #expect(abs(results[0].score - expectedMagnitude) < 0.0001)
    #expect(abs(results[1].score - 0) < 0.0001)
    #expect(abs(results[2].score - (-expectedMagnitude)) < 0.0001)

    #expect(results[0].isOutlier == false)
    #expect(results[1].isOutlier == false)
    #expect(results[2].isOutlier == true, "C's score is below -outlierZScore (1.0)")
}

// MARK: - Rater: weight renormalization with nil provider

@Test func weightRenormalizationWhenProviderIsNilUsesOnlyBackground() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLightFrame(
        relativePath: "sessions/T2/2026-01-01/lights/A.fit",
        target: "T2", pixels: Array(repeating: 50, count: 4), width: 2, height: 2
    )
    try fixture.addLightFrame(
        relativePath: "sessions/T2/2026-01-01/lights/B.fit",
        target: "T2", pixels: Array(repeating: 100, count: 4), width: 2, height: 2
    )
    try fixture.addLightFrame(
        relativePath: "sessions/T2/2026-01-01/lights/C.fit",
        target: "T2", pixels: Array(repeating: 150, count: 4), width: 2, height: 2
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    let results = try rater.rate(target: "T2")

    #expect(results.count == 3)
    // Lower background is better, so the frame with background 50 scores
    // highest -- and since only `background` has a value (no provider),
    // renormalized weighting means score == -zScore(background) exactly.
    let expectedMagnitude = (3.0 / 2.0).squareRoot()
    let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0) })
    #expect(abs(byPath["sessions/T2/2026-01-01/lights/A.fit"]!.score - expectedMagnitude) < 0.0001)
    #expect(abs(byPath["sessions/T2/2026-01-01/lights/B.fit"]!.score - 0) < 0.0001)
    #expect(abs(byPath["sessions/T2/2026-01-01/lights/C.fit"]!.score - (-expectedMagnitude)) < 0.0001)
    #expect(results.allSatisfy { $0.metrics == nil })
}

// MARK: - Rater: workDir isolation

@Test func workDirPassedToProviderIsOutsideLibraryRoot() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLightFrame(
        relativePath: "sessions/M1/2026-01-01/lights/light_0001.fit",
        target: "M1", pixels: Array(repeating: 42, count: 4), width: 2, height: 2
    )

    let mock = ScriptedMockProvider(responses: [
        "light_0001.fit": StarMetrics(fwhm: 2, roundness: 0.9, starCount: 50),
    ])
    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)
    _ = try rater.rate(target: "M1")

    #expect(mock.workDirs.count == 1)
    let workDir = mock.workDirs[0]
    let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
    #expect(workDir.standardizedFileURL.path.hasPrefix(tempRoot))
    #expect(!workDir.standardizedFileURL.path.hasPrefix(fixture.libraryDir.standardizedFileURL.path))
}

// MARK: - Rater: progress callback

@Test func progressCallbackReportsEachCompletedFrame() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLightFrame(
        relativePath: "sessions/M2/2026-01-01/lights/a.fit",
        target: "M2", pixels: Array(repeating: 10, count: 4), width: 2, height: 2
    )
    try fixture.addLightFrame(
        relativePath: "sessions/M2/2026-01-01/lights/b.fit",
        target: "M2", pixels: Array(repeating: 20, count: 4), width: 2, height: 2
    )
    try fixture.addLightFrame(
        relativePath: "sessions/M2/2026-01-01/lights/c.fit",
        target: "M2", pixels: Array(repeating: 30, count: 4), width: 2, height: 2
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    let recorder = ProgressRecorder()
    _ = try rater.rate(target: "M2", progress: { done, total in recorder.record(done, total) })

    let calls = recorder.calls
    #expect(calls.count == 3)
    #expect(calls.map(\.done) == [1, 2, 3])
    #expect(calls.allSatisfy { $0.total == 3 })
}

// MARK: - Rater: sessionDate filtering

@Test func rateFiltersBySessionDateWhenGiven() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLightFrame(
        relativePath: "sessions/M5/2026-01-01/lights/a.fit",
        target: "M5", sessionDate: "2026-01-01", pixels: Array(repeating: 10, count: 4), width: 2, height: 2
    )
    try fixture.addLightFrame(
        relativePath: "sessions/M5/2026-01-02/lights/b.fit",
        target: "M5", sessionDate: "2026-01-02", pixels: Array(repeating: 20, count: 4), width: 2, height: 2
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    let results = try rater.rate(target: "M5", date: "2026-01-01")

    #expect(results.count == 1)
    #expect(results[0].path == "sessions/M5/2026-01-01/lights/a.fit")
}

// MARK: - Real Siril smoke test (integration, guarded)

@Test func realSirilCLISmokeTestBuildScriptAndVersion() throws {
    let cfg = AstroConfig()
    try #require(FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath))

    // A real Siril binary is present on this machine. Only smoke-test
    // `buildScript` + `version` here -- actually running `findstar` on a
    // synthetic FITS via the real subprocess is slow and flaky in CI/dev
    // environments, so it's deliberately out of scope for this test.
    let cli = try SirilCLI(path: cfg.rating.sirilPath)
    #expect(!cli.version.isEmpty)

    let script = SirilCLI.buildScript(imagePath: "/tmp/x.fit")
    #expect(script.contains("findstar"))
}
