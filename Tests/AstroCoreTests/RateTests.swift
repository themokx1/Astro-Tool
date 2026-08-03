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

/// Builds a realistic `.fz` (fpack-style Rice-compressed) FITS layout: a
/// primary HDU with `NAXIS=0` (no pixel data of its own) immediately
/// followed by a `BINTABLE` extension whose `ZNAXIS1`/`ZNAXIS2`/`ZIMAGE`/
/// `ZCMPTYPE`/`ZBITPIX` describe the *actual* compressed image -- the real
/// pixels live Rice-encoded inside the "heap" bytes after the extension
/// header, not as a flat pixel grid `NativeStats` could ever read directly.
/// `heapByteCount` is deliberately larger than `znaxis1 * znaxis2` so that,
/// if compressed-layout detection were ever missing, the naive "read
/// znaxis1*znaxis2 bytes as BITPIX=8 pixels" path would NOT fail via the
/// unrelated "truncated pixel data" guard -- the only thing that should ever
/// reject this fixture is the dedicated compressed-layout check.
private func buildFZShapedFITS(znaxis1: Int, znaxis2: Int, heapByteCount: Int) -> Data {
    let primaryCards = [
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "END",
    ]
    let extensionCards = [
        "XTENSION= 'BINTABLE'",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    1",
        "NAXIS2  =                    1",
        "PCOUNT  =                 \(heapByteCount)",
        "GCOUNT  =                    1",
        "TFIELDS =                    1",
        "ZIMAGE  =                    T",
        "ZCMPTYPE= 'RICE_1  '",
        "ZBITPIX =                   16",
        "ZNAXIS  =                    2",
        "ZNAXIS1 =                 \(znaxis1)",
        "ZNAXIS2 =                 \(znaxis2)",
        "END",
    ]
    var data = buildHeaderData(primaryCards)
    data.append(buildHeaderData(extensionCards))
    data.append(Data(repeating: 0xAB, count: heapByteCount))
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
        mtime: Double = 1_700_000_000,
        exptime: Double? = nil
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
        if let exptime {
            try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: exptime))
        }
        return (fileID, Int64(data.count))
    }

    /// Writes arbitrary bytes (e.g. a `.fz`-shaped fixture) at `relativePath`
    /// and registers a matching `files` row, with `ext` derived from the
    /// path exactly like the real scanner does (`Scanner.swift`'s
    /// `(relativePath as NSString).pathExtension.lowercased()`).
    @discardableResult
    func addRawLightFrame(
        relativePath: String,
        target: String,
        sessionDate: String = "2026-01-01",
        data: Data,
        mtime: Double = 1_700_000_000
    ) throws -> (fileID: Int64, size: Int64) {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let ext = (relativePath as NSString).pathExtension.lowercased()
        let record = FileRecord(
            path: relativePath,
            size: Int64(data.count),
            mtime: mtime,
            ext: ext,
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

@Test func nativeStatsThrowsCorruptFITSForCompressedFZLayout() throws {
    // Realistic .fz shape: primary NAXIS=0 + BINTABLE extension carrying
    // ZIMAGE/ZCMPTYPE/ZBITPIX/ZNAXIS1/ZNAXIS2. `FITSReader.parse` merges
    // the extension's keys (including backfilling NAXIS1/NAXIS2 from
    // ZNAXIS1/ZNAXIS2), so a naive BITPIX/NAXIS-only guard would never
    // catch this -- `NativeStats` must positively detect the compressed
    // layout instead of reading extension-header text / Rice heap bytes as
    // pixels.
    let data = buildFZShapedFITS(znaxis1: 10, znaxis2: 10, heapByteCount: 500)

    do {
        _ = try NativeStats.compute(data: data)
        Issue.record("expected AstroError.corruptFITS for compressed (.fz) layout")
    } catch let AstroError.corruptFITS(_, reason) {
        #expect(reason.contains("compressed"))
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

// MARK: - Crash regression: CR+LF byte pair inside NativeStats' own header scan
//
// `NativeStats.primaryHeaderInfo` duplicates `FITSReader.readOneHeader`'s
// block-scanning logic (deliberately, per its own doc comment, since it
// needs the *raw* unmerged primary NAXIS) -- including the same
// `Array(blockString)` 0-based card-slicing loop. A stray CR+LF byte pair
// inside the first header block collapses that array from 2880 to 2879
// elements (Swift's grapheme-cluster rules treat "\r\n" as one `Character`),
// which traps "Array index is out of range" once the loop reaches a card
// whose range no longer fits -- the same class of bug as the
// `FITSReader.readOneHeader` crash, just in the sibling implementation.
@Test func nativeStatsCrLfBytePairInFirstBlockOfMultiBlockHeaderDoesNotCrash() throws {
    var cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                    2",
        "NAXIS2  =                    2",
    ]
    for i in 0..<40 {
        let keyword = "TESTK\(i)".padding(toLength: 8, withPad: " ", startingAt: 0)
        cards.append("\(keyword)=                    \(i)")
    }
    cards.append("END")
    var data = buildHeaderData(cards)
    #expect(data.count == 2 * 2880, "45 cards must overflow a single 36-card block")

    // Overwrite two padding bytes inside card 0 (block 1 has no END card,
    // so it must be scanned in full) with a literal CR+LF.
    data[50] = 0x0D
    data[51] = 0x0A

    // Pixel bytes so a successful parse path has something to read.
    for value in [1, 2, 3, 4] as [Int16] {
        let unsigned = UInt16(bitPattern: value)
        data.append(UInt8(unsigned >> 8))
        data.append(UInt8(unsigned & 0xFF))
    }

    // Must not trap. Either successfully computing stats or throwing
    // `AstroError.corruptFITS` is acceptable -- a crash is not.
    _ = try? NativeStats.compute(data: data)
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

@Test func sirilCLIBuildScriptContainsRequiresLoadFindstarClose() throws {
    let script = try SirilCLI.buildScript(imagePath: "/tmp/some frame.fit")
    #expect(script.contains("requires 1.2.0"))
    #expect(script.contains("load \"/tmp/some frame.fit\""))
    #expect(script.contains("findstar"))
    #expect(script.contains("close"))
}

@Test func buildScriptRejectsPathContainingDoubleQuoteToPreventScriptInjection() {
    // A path containing an unescaped `"` could otherwise break out of the
    // `load "..."` string and inject arbitrary Siril script commands (e.g.
    // a filename like `foo".fit\nshell rm -rf ~`). Reject outright rather
    // than guess at Siril's DSL escaping rules.
    let evilPath = "/tmp/evil\".fit\nclose\nrequires 1.2.0\nload \"/etc/passwd"
    #expect(throws: SirilCLI.ProcessError.self) {
        _ = try SirilCLI.buildScript(imagePath: evilPath)
    }
}

@Test func buildScriptRejectsPathContainingBackslash() {
    let weirdPath = "/tmp/weird\\path.fit"
    #expect(throws: SirilCLI.ProcessError.self) {
        _ = try SirilCLI.buildScript(imagePath: weirdPath)
    }
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

// MARK: - Rater: compressed (.fz) frames skip NativeStats but still rate

@Test func rateSkipsNativeStatsForFZFramesButStillCallsProviderAndPersists() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    // Defense in depth: even though `NativeStats.compute` itself now
    // rejects this shape, `Rater` must not even attempt it for a `.fz`
    // file -- Siril can read `.fz` directly, so the frame should still be
    // rated (metrics present), just with no native background/saturation.
    let fzData = buildFZShapedFITS(znaxis1: 10, znaxis2: 10, heapByteCount: 500)
    let (fileID, _) = try fixture.addRawLightFrame(
        relativePath: "sessions/M27/2026-04-04/lights/light_0001.fits.fz",
        target: "M27", data: fzData
    )

    let mock = ScriptedMockProvider(responses: [
        "light_0001.fits.fz": StarMetrics(fwhm: 2.1, roundness: 0.88, starCount: 210),
    ])
    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)
    let results = try rater.rate(target: "M27")

    #expect(results.count == 1)
    #expect(results[0].metrics == StarMetrics(fwhm: 2.1, roundness: 0.88, starCount: 210))
    #expect(results[0].background == nil)

    let stored = try fixture.db.rating(fileID: fileID)
    #expect(stored?.background == nil)
    #expect(stored?.saturatedFraction == nil)
    #expect(stored?.fwhm == 2.1)
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

// MARK: - Rater: per-exposure-group z-scoring

@Test func scoringZScoresWithinExposureGroupsNotAcrossTheWholeBatch() throws {
    // Ground-truthed against tools/rate/LightFrameRater.py, which always
    // compares frames of the same exposure time separately. Two exposure
    // groups, each internally evenly spaced by background (only
    // `background` contributes -- no provider), so each group's own z-score
    // magnitude is exactly sqrt(2/3) (the 3-point evenly-spaced case).
    //
    // Group "short" (5s): backgrounds 10, 20, 30 -> S1 (10) is this group's
    // BEST frame (lowest background).
    // Group "long" (50s): backgrounds 1000, 1010, 1020 -> L1 (1000) is this
    // group's BEST frame too, despite every one of its backgrounds being
    // far higher than the whole "short" group -- if z-scoring were (wrongly)
    // computed across the full 6-frame batch, L1 would come out as one of
    // the WORST frames overall (its background is high relative to the
    // pooled mean), not tied for best. Per-exposure-group scoring must give
    // L1 the same best-in-group score as S1, not the globally-pooled one.
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLightFrame(
        relativePath: "sessions/G/2026-01-01/lights/S1.fit", target: "G",
        pixels: Array(repeating: 10, count: 4), width: 2, height: 2, exptime: 5.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/G/2026-01-01/lights/S2.fit", target: "G",
        pixels: Array(repeating: 20, count: 4), width: 2, height: 2, exptime: 5.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/G/2026-01-01/lights/S3.fit", target: "G",
        pixels: Array(repeating: 30, count: 4), width: 2, height: 2, exptime: 5.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/G/2026-01-01/lights/L1.fit", target: "G",
        pixels: Array(repeating: 1000, count: 4), width: 2, height: 2, exptime: 50.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/G/2026-01-01/lights/L2.fit", target: "G",
        pixels: Array(repeating: 1010, count: 4), width: 2, height: 2, exptime: 50.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/G/2026-01-01/lights/L3.fit", target: "G",
        pixels: Array(repeating: 1020, count: 4), width: 2, height: 2, exptime: 50.0
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    let results = try rater.rate(target: "G")

    #expect(results.count == 6)
    let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0) })
    // sqrt(3/2): the z-score magnitude for any 3-point evenly-spaced set,
    // regardless of the absolute spacing (10 here) -- same constant as
    // `scoringOrientationAndOutlierDetection`'s.
    let expectedMagnitude = (3.0 / 2.0).squareRoot()

    // Best-in-group frames (S1, L1) tie at the same top score...
    #expect(abs(byPath["sessions/G/2026-01-01/lights/S1.fit"]!.score - expectedMagnitude) < 0.0001)
    #expect(abs(byPath["sessions/G/2026-01-01/lights/L1.fit"]!.score - expectedMagnitude) < 0.0001)
    // ...middle frames (S2, L2) both score ~0...
    #expect(abs(byPath["sessions/G/2026-01-01/lights/S2.fit"]!.score - 0) < 0.0001)
    #expect(abs(byPath["sessions/G/2026-01-01/lights/L2.fit"]!.score - 0) < 0.0001)
    // ...and worst-in-group frames (S3, L3) tie at the same bottom score --
    // none of this would hold if L1/L2/L3 were z-scored against the pooled
    // "short" + "long" background values instead of within their own group.
    #expect(abs(byPath["sessions/G/2026-01-01/lights/S3.fit"]!.score - (-expectedMagnitude)) < 0.0001)
    #expect(abs(byPath["sessions/G/2026-01-01/lights/L3.fit"]!.score - (-expectedMagnitude)) < 0.0001)
}

@Test func scoringTreatsFramesWithoutExptimeAsTheirOwnSharedGroup() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    // No exptime set for any of these -- must all land in one shared group
    // (not each its own singleton, which would force every score to 0).
    try fixture.addLightFrame(
        relativePath: "sessions/H/2026-01-01/lights/A.fit", target: "H",
        pixels: Array(repeating: 50, count: 4), width: 2, height: 2
    )
    try fixture.addLightFrame(
        relativePath: "sessions/H/2026-01-01/lights/B.fit", target: "H",
        pixels: Array(repeating: 100, count: 4), width: 2, height: 2
    )
    try fixture.addLightFrame(
        relativePath: "sessions/H/2026-01-01/lights/C.fit", target: "H",
        pixels: Array(repeating: 150, count: 4), width: 2, height: 2
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    let results = try rater.rate(target: "H")

    #expect(results.count == 3)
    let expectedMagnitude = (3.0 / 2.0).squareRoot()
    let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0) })
    #expect(abs(byPath["sessions/H/2026-01-01/lights/A.fit"]!.score - expectedMagnitude) < 0.0001)
    #expect(abs(byPath["sessions/H/2026-01-01/lights/B.fit"]!.score - 0) < 0.0001)
    #expect(abs(byPath["sessions/H/2026-01-01/lights/C.fit"]!.score - (-expectedMagnitude)) < 0.0001)
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
    guard FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath) else {
        // No real Siril binary on this machine (e.g. CI runners never have
        // it installed) -- this integration smoke test only runs when one
        // is actually present, so skip rather than fail.
        return
    }

    // A real Siril binary is present on this machine. Only smoke-test
    // `buildScript` + `version` here -- actually running `findstar` on a
    // synthetic FITS via the real subprocess is slow and flaky in CI/dev
    // environments, so it's deliberately out of scope for this test.
    let cli = try SirilCLI(path: cfg.rating.sirilPath)
    #expect(!cli.version.isEmpty)

    let script = try SirilCLI.buildScript(imagePath: "/tmp/x.fit")
    #expect(script.contains("findstar"))
}
