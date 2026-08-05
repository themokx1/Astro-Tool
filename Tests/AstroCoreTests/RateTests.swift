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

// MARK: - Per-Bayer-parity medians (R7-B1)

/// A 4x4 frame where every pixel's value is fully determined by its
/// `(row%2, col%2)` parity -- 4 pixels landing in each of the 4 buckets, all
/// sharing the SAME value within a bucket, so each bucket's median is exact
/// and unambiguous.
@Test func nativeStatsComputesExactPerBayerParityMediansForDistinctPositions() throws {
    var pixels = [Int](repeating: 0, count: 16)
    for row in 0..<4 {
        for col in 0..<4 {
            let value: Int
            switch (row % 2, col % 2) {
            case (0, 0): value = 100
            case (0, 1): value = 200
            case (1, 0): value = 300
            default: value = 400
            }
            pixels[row * 4 + col] = value
        }
    }
    let data = build16BitFITS(width: 4, height: 4, pixels: pixels)

    let stats = try NativeStats.compute(data: data)
    #expect(stats.backgroundMedian00 == 100)
    #expect(stats.backgroundMedian01 == 200)
    #expect(stats.backgroundMedian10 == 300)
    #expect(stats.backgroundMedian11 == 400)
    // Overall median is unaffected -- sorted [100,100,100,100,200,200,200,200,
    // 300,300,300,300,400,400,400,400], mid two are 200 and 300.
    #expect(stats.backgroundMedian == 250)
}

@Test func nativeStatsPerBayerParityMediansHandleEvenCountPerBucket() throws {
    // 2x2 tile repeated 2x2 times (8x8 total), two distinct values PER
    // bucket so each bucket's own median is an average of two values.
    var pixels = [Int](repeating: 0, count: 64)
    for row in 0..<8 {
        for col in 0..<8 {
            let base: Int
            switch (row % 2, col % 2) {
            case (0, 0): base = 10
            case (0, 1): base = 20
            case (1, 0): base = 30
            default: base = 40
            }
            // Alternate base/base+2 across tiles so each bucket sees two
            // distinct values in equal counts.
            let tileIndex = (row / 2) * 4 + (col / 2)
            pixels[row * 8 + col] = base + (tileIndex % 2 == 0 ? 0 : 2)
        }
    }
    let data = build16BitFITS(width: 8, height: 8, pixels: pixels)

    let stats = try NativeStats.compute(data: data)
    #expect(stats.backgroundMedian00 == 11) // (10+12)/2
    #expect(stats.backgroundMedian01 == 21)
    #expect(stats.backgroundMedian10 == 31)
    #expect(stats.backgroundMedian11 == 41)
}

@Test func nativeStatsPerBayerParityMediansNilForDegenerateSingleColumnFrame() throws {
    // A single-column frame has no col%2==1 pixels at all -- buckets 01/11
    // must be nil rather than crashing on an empty median.
    let pixels = [10, 20, 30, 40]
    let data = build16BitFITS(width: 1, height: 4, pixels: pixels)

    let stats = try NativeStats.compute(data: data)
    #expect(stats.backgroundMedian00 != nil)
    #expect(stats.backgroundMedian01 == nil)
    #expect(stats.backgroundMedian10 != nil)
    #expect(stats.backgroundMedian11 == nil)
}

// MARK: - NativeStats.centralCropPixels (SensorProfiler's data-reading path)

@Test func centralCropPixelsReadsOnlyTheCenterFractionInRowMajorOrder() throws {
    // 4x4 frame, every pixel's value is row*10+col so the crop's exact
    // contents are unambiguous. fraction=0.5 -> a 2x2 crop starting at
    // (x0,y0) = (1,1), i.e. rows 1-2, cols 1-2.
    var pixels = [Int](repeating: 0, count: 16)
    for row in 0..<4 {
        for col in 0..<4 {
            pixels[row * 4 + col] = row * 10 + col
        }
    }
    let data = build16BitFITS(width: 4, height: 4, pixels: pixels)

    let crop = try NativeStats.centralCropPixels(data: data, fraction: 0.5)
    #expect(crop == [11, 12, 21, 22])
}

@Test func centralCropPixelsReadsFromURL() throws {
    let dir = try makeTempDir("central-crop-url")
    defer { try? FileManager.default.removeItem(at: dir) }

    let pixels = [1, 2, 3, 4]
    let data = build16BitFITS(width: 2, height: 2, pixels: pixels)
    let url = dir.appendingPathComponent("frame.fit")
    try data.write(to: url)

    // fraction=1.0 over a 2x2 frame -> the whole frame, row-major.
    let crop = try NativeStats.centralCropPixels(url: url, fraction: 1.0)
    #expect(crop == [1, 2, 3, 4])
}

@Test func centralCropPixelsThrowsCorruptFITSForCompressedFZLayout() throws {
    let data = buildFZShapedFITS(znaxis1: 10, znaxis2: 10, heapByteCount: 500)
    #expect(throws: AstroError.self) {
        _ = try NativeStats.centralCropPixels(data: data, fraction: 0.5)
    }
}

// MARK: - BayerMap

@Test func bayerMapRGGBMapsPositionsToRedGreenGreenBlue() {
    let stats = NativeFrameStats(
        backgroundMedian: 250, saturatedFraction: 0,
        backgroundMedian00: 100, backgroundMedian01: 200,
        backgroundMedian10: 300, backgroundMedian11: 400
    )
    let channels = BayerMap.channelMedians(stats: stats, bayerPattern: "RGGB")
    #expect(channels.r == 100)
    #expect(channels.g == 250) // average of 200 and 300
    #expect(channels.b == 400)
}

@Test func bayerMapReturnsNilForUnknownBayerPattern() {
    let stats = NativeFrameStats(
        backgroundMedian: 250, saturatedFraction: 0,
        backgroundMedian00: 100, backgroundMedian01: 200,
        backgroundMedian10: 300, backgroundMedian11: 400
    )
    let channels = BayerMap.channelMedians(stats: stats, bayerPattern: "XYZW")
    #expect(channels.r == nil)
    #expect(channels.g == nil)
    #expect(channels.b == nil)
}

@Test func bayerMapReturnsNilForNilBayerPattern() {
    let stats = NativeFrameStats(
        backgroundMedian: 250, saturatedFraction: 0,
        backgroundMedian00: 100, backgroundMedian01: 200,
        backgroundMedian10: 300, backgroundMedian11: 400
    )
    let channels = BayerMap.channelMedians(stats: stats, bayerPattern: nil)
    #expect(channels.r == nil)
    #expect(channels.g == nil)
    #expect(channels.b == nil)
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

@Test func parseFindstarOutputReturnsNilRoundnessWhenAbsent() {
    // Regression guard: this used to default to a fabricated 0.5 "neutral"
    // roundness, which fed fake data into rating stats. Missing means
    // missing.
    let output = "log: Found 88 stars in image, channel #0 (FWHM 2.95)"
    let metrics = SirilCLI.parseFindstarOutput(output)
    #expect(metrics?.starCount == 88)
    #expect(metrics?.fwhm == 2.95)
    #expect(metrics?.roundness == nil)
}

@Test func parseFindstarOutputReturnsNilForGarbage() {
    let output = "some unrelated log noise, nothing usable here"
    #expect(SirilCLI.parseFindstarOutput(output) == nil)
}

/// Regression guard for the real bug found on this machine (item D):
/// `ratings.fwhm/roundness/star_count` were 100% NULL on all 586 real rows
/// because Siril 1.4's actual wording -- "Found N Gaussian profile stars"
/// (extra words between the count and "stars") -- never matched the old
/// `Found\s+(\d+)\s+star` pattern, which required "star" to sit immediately
/// after the number. Exact wording observed from a real
/// `siril-cli -s -` run against a synthetic star FITS on this machine.
@Test func parseFindstarOutputParsesRealSiril144WordingWithGaussianProfilePhrase() {
    let output = """
    log: Findstar: processing for channel 0...
    log: Found 5 Gaussian profile stars in image, channel #0 (FWHM 5.416091)
    """
    let metrics = SirilCLI.parseFindstarOutput(output)
    #expect(metrics?.starCount == 5)
    #expect(metrics?.fwhm == 5.416091)
    #expect(metrics?.roundness == nil, "Siril 1.4's findstar log line carries no roundness figure at all")
}

// MARK: - SirilCLI.readVersion parsing

/// Regression guard for the real bug found on this machine: `siril-cli
/// --version`'s ACTUAL first line is a macOS-launch banner
/// ("Siril is started as macOS application"), with the real version on
/// line 2 ("siril 1.4.4") -- the old code kept only the first line
/// verbatim, so every real rating row got `siril_version` set to the
/// banner text instead of a version. Exact two-line output observed from a
/// real `siril-cli --version` run on this machine.
@Test func parseVersionOutputPrefersLineContainingSirilAndADigitOverAnEarlierBannerLine() {
    let output = "Siril is started as macOS application\nsiril 1.4.4\n"
    #expect(SirilCLI.parseVersionOutput(output) == "siril 1.4.4")
}

@Test func parseVersionOutputFallsBackToLastLineWithVersionPatternWhenNoSirilKeywordLineHasADigit() {
    let output = "Siril is started as macOS application\nsome other line\n1.4.4\n"
    #expect(SirilCLI.parseVersionOutput(output) == "1.4.4")
}

@Test func parseVersionOutputReturnsUnknownWhenNothingMatches() {
    let output = "Siril is started as macOS application\nno version info here\n"
    #expect(SirilCLI.parseVersionOutput(output) == "unknown")
}

@Test func parseVersionOutputReturnsUnknownForEmptyString() {
    #expect(SirilCLI.parseVersionOutput("") == "unknown")
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

// MARK: - Rater.shouldWarnNoMetrics (item D.3 -- silent-failure guard)

/// Structural guard against a repeat of the real bug (item D): if a Siril
/// adapter goes silently non-functional again in the future (a new Siril
/// version changing its log wording yet again, say), a whole batch quietly
/// getting zero star metrics should be loud, not silent. `Rater` itself
/// stays oblivious to *why* metrics are missing (a `nil` provider, a
/// legitimately unmeasurable `.fz` frame, or a broken adapter all look the
/// same at this layer) -- this predicate only fires the "something is
/// probably wrong" signal when a provider WAS supplied and NOTHING in a
/// batch big enough to be meaningful (>=5 frames) came back with metrics.
@Test func shouldWarnNoMetricsIsTrueWhenProviderUsedAndBatchOfAtLeastFiveGetsZeroMetrics() throws {
    let scores = (1...5).map { i in
        FrameScore(path: "f\(i).fit", score: 0, isOutlier: false, metrics: nil, background: 100)
    }
    #expect(Rater.shouldWarnNoMetrics(scores, providerWasUsed: true))
}

@Test func shouldWarnNoMetricsIsFalseWhenProviderWasNotUsed() throws {
    let scores = (1...5).map { i in
        FrameScore(path: "f\(i).fit", score: 0, isOutlier: false, metrics: nil, background: 100)
    }
    #expect(!Rater.shouldWarnNoMetrics(scores, providerWasUsed: false))
}

@Test func shouldWarnNoMetricsIsFalseWhenBatchIsSmallerThanFive() throws {
    let scores = (1...4).map { i in
        FrameScore(path: "f\(i).fit", score: 0, isOutlier: false, metrics: nil, background: 100)
    }
    #expect(!Rater.shouldWarnNoMetrics(scores, providerWasUsed: true))
}

@Test func shouldWarnNoMetricsIsFalseWhenAtLeastOneFrameGotMetrics() throws {
    var scores = (1...5).map { i in
        FrameScore(path: "f\(i).fit", score: 0, isOutlier: false, metrics: nil, background: 100)
    }
    scores[0].metrics = StarMetrics(fwhm: 2.0, roundness: 0.9, starCount: 100)
    #expect(!Rater.shouldWarnNoMetrics(scores, providerWasUsed: true))
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
        relativePath: "sessions/M31/2026-01-01/lights/Junk/light_0001.fit",
        target: "M31", pixels: pixels, width: 3, height: 3, mtime: 1_650_000_000, exptime: 120.0
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

    // `FrameScore`'s display-oriented fields, populated straight through
    // from the `RatingRecord` (`saturatedFraction`), the fits_meta exptime
    // used for exposure-group scoring, and the path itself
    // (`fileName`/`sessionSubdir`).
    let score = try #require(results.first)
    #expect(score.fileName == "light_0001.fit")
    #expect(score.sessionSubdir == "lights/Junk")
    #expect(score.exptime == 120.0)
    #expect(score.saturatedFraction == 0)
}

@Test func rateWritesPerBayerBackgroundMediansOntoTheRatingRow() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    // 4x4 frame, one constant value per (row%2, col%2) parity -- same
    // fixture shape as `NativeStatsTests`'s exact-median test.
    var pixels = [Int](repeating: 0, count: 16)
    for row in 0..<4 {
        for col in 0..<4 {
            let value: Int
            switch (row % 2, col % 2) {
            case (0, 0): value = 500
            case (0, 1): value = 510
            case (1, 0): value = 520
            default: value = 530
            }
            pixels[row * 4 + col] = value
        }
    }
    let (fileID, _) = try fixture.addLightFrame(
        relativePath: "sessions/M31/2026-01-01/lights/light_0001.fit",
        target: "M31", pixels: pixels, width: 4, height: 4
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    _ = try rater.rate(target: "M31")

    let stored = try #require(try fixture.db.rating(fileID: fileID))
    #expect(stored.bg00 == 500)
    #expect(stored.bg01 == 510)
    #expect(stored.bg10 == 520)
    #expect(stored.bg11 == 530)
}

@Test func frameScoreSessionSubdirIsNilWhenFrameSitsDirectlyInDateDir() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLightFrame(
        relativePath: "sessions/M42/2026-01-01/light_0001.fit",
        target: "M42", pixels: Array(repeating: 10, count: 4), width: 2, height: 2
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    let results = try rater.rate(target: "M42")

    #expect(results.count == 1)
    #expect(results[0].sessionSubdir == nil)
    #expect(results[0].fileName == "light_0001.fit")
}

@Test func frameScoreDecodesJSONMissingFieldsAddedAfterInitialRelease() throws {
    // Simulates a `--json` capture written before `saturatedFraction`,
    // `exptime`, and `sessionSubdir` existed on `FrameScore` -- must still
    // decode, with all three simply `nil`.
    let legacyJSON = """
    {"path": "sessions/M1/2026-01-01/lights/a.fit", "score": 1.5, "isOutlier": false,
     "metrics": null, "background": 123.0}
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(FrameScore.self, from: legacyJSON)
    #expect(decoded.path == "sessions/M1/2026-01-01/lights/a.fit")
    #expect(decoded.score == 1.5)
    #expect(decoded.saturatedFraction == nil)
    #expect(decoded.exptime == nil)
    #expect(decoded.sessionSubdir == nil)
    #expect(decoded.fileName == "a.fit")
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

/// R7-B2: a `DSSIngest`-written rating (`source == "dss"`) whose `inputSig`
/// still matches the light frame is exactly as much of a cache hit as any
/// other stored rating -- `Rater` doesn't special-case `source` at all, it
/// only ever compares `inputSig`. This is what lets a DSS-only frame (no
/// Siril data, just harvested `.info.txt` metrics) participate in z-scoring
/// without ever invoking the (expensive) provider.
@Test func rateTreatsADSSSourcedRatingWithMatchingInputSigAsACacheHit() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    let pixels = Array(repeating: 100, count: 16)
    let relativePath = "sessions/M51/2026-05-05/lights/light_0001.fit"
    let (fileID, size) = try fixture.addLightFrame(
        relativePath: relativePath, target: "M51", pixels: pixels, width: 4, height: 4,
        mtime: 1_700_000_000
    )

    // Simulate DSSIngest having already written a rating for this exact
    // frame (same inputSig convention as Rater's own: "<size>-<mtime>").
    let dssRating = RatingRecord(
        fileID: fileID, fwhm: 3.0, roundness: 0.8, starCount: 120,
        ratedAt: 1_700_000_050, inputSig: "\(size)-1700000000", source: "dss"
    )
    try fixture.db.upsertRating(dssRating)

    let mock = CountingMockProvider()
    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)
    let results = try rater.rate(target: "M51")

    #expect(results.count == 1)
    #expect(mock.callCount == 0, "the provider must never be called for a cache-hit dss-sourced row")
    #expect(results[0].metrics == StarMetrics(fwhm: 3.0, roundness: 0.8, starCount: 120))

    let stored = try fixture.db.rating(fileID: fileID)
    #expect(stored?.source == "dss", "scoring must not clear the dss source marker")
    #expect(stored?.score != nil, "a cache-hit dss row still gets scored like any other rated frame")
}

// MARK: - Rater: cache self-heal (R7-B6, item 1)
//
// Real symptom this reproduces: 141 real frames sat at "Siril metrika:
// 0/141" forever, because their cached ratings had the RIGHT `inputSig`
// (the files themselves never changed) but were written while the Siril
// adapter was silently broken -- plain `inputSig` equality treated that as
// a permanent cache hit with no way to ever recover once the adapter got
// fixed. These tests exercise `Rater.staleness` end to end through
// `rate(target:)` itself, not just the predicate in isolation.

/// A cached row whose native half is complete (background/bg00..11 already
/// present, deliberately set to `999` -- a value `NativeStats` would never
/// compute from the fixture's actual flat `100` pixels, so a wrongly
/// triggered native recompute is caught) but whose star-metric columns are
/// all `nil` and `source == nil` (astrotool's own pipeline, not a dss row).
/// A provider newly available now must be called, and only the metrics
/// half of the row should change.
@Test func rateSelfHealsStaleNilMetricsRowWhenProviderIsNowAvailable() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    let pixels = Array(repeating: 100, count: 16)
    let relativePath = "sessions/M60/2026-06-06/lights/light_0001.fit"
    let (fileID, size) = try fixture.addLightFrame(
        relativePath: relativePath, target: "M60", pixels: pixels, width: 4, height: 4,
        mtime: 1_700_000_000
    )

    let staleRow = RatingRecord(
        fileID: fileID, background: 999, ratedAt: 1_700_000_050,
        inputSig: "\(size)-1700000000",
        bg00: 999, bg01: 999, bg10: 999, bg11: 999
    )
    try fixture.db.upsertRating(staleRow)

    let mock = CountingMockProvider()
    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)
    let results = try rater.rate(target: "M60")

    #expect(results.count == 1)
    #expect(mock.callCount == 1, "a provider newly available for a stale nil-metrics row must be called")
    #expect(results[0].metrics == StarMetrics(fwhm: 2.0, roundness: 0.9, starCount: 100))

    let stored = try fixture.db.rating(fileID: fileID)
    #expect(stored?.background == 999, "the native half was NOT stale -- must not be recomputed")
    #expect(stored?.fwhm == 2.0)
}

/// A `DSSIngest`-written row (`source == "dss"`, real star metrics already
/// present) whose native background/bg00..11 were never computed (DSS
/// never fills those). Only the native half is stale -- the fix must
/// recompute native stats WITHOUT touching the dss metrics/source, and
/// must never call the Siril provider for a dss row.
@Test func rateSelfHealsDSSRowMissingNativeStatsPreservingDSSMetricsAndSource() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    let pixels = Array(repeating: 250, count: 16)
    let relativePath = "sessions/M61/2026-06-07/lights/light_0001.fit"
    let (fileID, size) = try fixture.addLightFrame(
        relativePath: relativePath, target: "M61", pixels: pixels, width: 4, height: 4,
        mtime: 1_700_000_000
    )

    let dssRow = RatingRecord(
        fileID: fileID, fwhm: 3.5, roundness: 0.75, starCount: 88,
        ratedAt: 1_700_000_050, inputSig: "\(size)-1700000000", source: "dss"
    )
    try fixture.db.upsertRating(dssRow)

    let mock = CountingMockProvider()
    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)
    let results = try rater.rate(target: "M61")

    #expect(results.count == 1)
    #expect(mock.callCount == 0, "a dss-sourced row's real metrics must never trigger a fresh Siril run")
    #expect(
        results[0].metrics == StarMetrics(fwhm: 3.5, roundness: 0.75, starCount: 88),
        "dss metrics must survive the self-heal untouched"
    )

    let stored = try fixture.db.rating(fileID: fileID)
    #expect(stored?.source == "dss", "the dss source marker must survive a native-only self-heal")
    #expect(stored?.background == 250, "the native half WAS stale -- must actually get computed")
    #expect(stored?.bg00 == 250)
}

/// A row with both halves already complete must be a true cache hit: no
/// native recompute, no provider call -- verified the same way the
/// pre-existing `cacheHitReusesStoredRatingWithoutRecomputingOrCallingProvider`
/// test does, by deleting the underlying file first.
@Test func rateLeavesACompleteCachedRowUntouched() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    let pixels = Array(repeating: 100, count: 16)
    let relativePath = "sessions/M62/2026-06-08/lights/light_0001.fit"
    let (fileID, size) = try fixture.addLightFrame(
        relativePath: relativePath, target: "M62", pixels: pixels, width: 4, height: 4,
        mtime: 1_700_000_000
    )

    let completeRow = RatingRecord(
        fileID: fileID, fwhm: 2.5, roundness: 0.85, starCount: 150,
        background: 100, ratedAt: 1_700_000_050, inputSig: "\(size)-1700000000",
        bg00: 100, bg01: 100, bg10: 100, bg11: 100
    )
    try fixture.db.upsertRating(completeRow)

    let fileURL = fixture.libraryDir.appendingPathComponent(relativePath)
    try FileManager.default.removeItem(at: fileURL)

    let mock = CountingMockProvider()
    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)
    let results = try rater.rate(target: "M62")

    #expect(results.count == 1, "a complete cached row must still be usable even with the file gone")
    #expect(mock.callCount == 0)
    #expect(results[0].metrics == StarMetrics(fwhm: 2.5, roundness: 0.85, starCount: 150))
}

/// `force: true` must treat every frame as a cache miss regardless of how
/// complete its cached row already looks -- a deliberate full re-measure,
/// not just a targeted self-heal.
@Test func rateForceRecomputesACompleteRowRegardlessOfCacheState() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    let pixels = Array(repeating: 100, count: 16)
    let relativePath = "sessions/M63/2026-06-09/lights/light_0001.fit"
    let (fileID, size) = try fixture.addLightFrame(
        relativePath: relativePath, target: "M63", pixels: pixels, width: 4, height: 4,
        mtime: 1_700_000_000
    )

    // A deliberately implausible "complete" row -- 999 sentinels
    // `NativeStats` would never produce from this fixture's flat `100`
    // pixels -- so a genuine force-recompute is unambiguous in the result.
    let completeRow = RatingRecord(
        fileID: fileID, fwhm: 999, roundness: 999, starCount: 999,
        background: 999, ratedAt: 1_700_000_050, inputSig: "\(size)-1700000000",
        bg00: 999, bg01: 999, bg10: 999, bg11: 999
    )
    try fixture.db.upsertRating(completeRow)

    let mock = CountingMockProvider()
    let rater = Rater(db: fixture.db, config: fixture.config, provider: mock)
    let results = try rater.rate(target: "M63", force: true)

    #expect(results.count == 1)
    #expect(mock.callCount == 1, "--force must call the provider even though the cached row already looked complete")
    #expect(results[0].metrics == StarMetrics(fwhm: 2.0, roundness: 0.9, starCount: 100))

    let stored = try fixture.db.rating(fileID: fileID)
    #expect(stored?.background == 100, "force must genuinely recompute native stats too, not just reuse the stale sentinel")
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

// MARK: - Rater: nominal-exposure grouping (R4-2 fix a)

/// Ground-truthed against a real library: exptime 30.0 (x822 frames) and
/// 29.899999618523 (x91 frames) are the SAME nominal "30s" sub, but the old
/// 0.1s-rounded grouping key put the 29.9s frames in their own tiny group
/// (`Int((29.899999618523 * 10).rounded()) == 299`, vs. `300` for 30.0) --
/// with only itself in that group, its z-score (and therefore score) was
/// always exactly 0, regardless of how good or bad the frame actually was.
/// After rounding to the nominal exptime (`NominalExposure`), all three
/// frames below share one group and get a real, non-degenerate score.
@Test func scoringMergesFloatNoisyExptimesIntoOneNominalGroup() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLightFrame(
        relativePath: "sessions/N/2026-01-01/lights/S1.fit", target: "N",
        pixels: Array(repeating: 10, count: 4), width: 2, height: 2, exptime: 30.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/N/2026-01-01/lights/S2.fit", target: "N",
        pixels: Array(repeating: 20, count: 4), width: 2, height: 2, exptime: 30.0
    )
    // Float-noisy "30s" sub -- must land in the SAME group as the two
    // frames above, not its own singleton.
    try fixture.addLightFrame(
        relativePath: "sessions/N/2026-01-01/lights/S3.fit", target: "N",
        pixels: Array(repeating: 30, count: 4), width: 2, height: 2, exptime: 29.899999618523
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    let results = try rater.rate(target: "N")

    #expect(results.count == 3)
    let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0) })
    let expectedMagnitude = (3.0 / 2.0).squareRoot()

    // S3 (background 30, the group's worst) must NOT score 0 (the old,
    // wrongly-singleton-grouped behavior) -- it must tie with what a
    // 3-point evenly-spaced worst frame scores.
    #expect(abs(byPath["sessions/N/2026-01-01/lights/S3.fit"]!.score - (-expectedMagnitude)) < 0.0001)
    #expect(abs(byPath["sessions/N/2026-01-01/lights/S1.fit"]!.score - expectedMagnitude) < 0.0001)
    #expect(abs(byPath["sessions/N/2026-01-01/lights/S2.fit"]!.score - 0) < 0.0001)
}

// MARK: - Rater: per-(date, exposure)-group scoring (R4-2 fix b)

/// A multi-night `rate(target:)` call with no `--date` must not pool
/// different nights' sky conditions into one z-score population, even when
/// they share the same nominal exptime: two nights, both shot at 60s, one
/// much brighter overall (a hazier night) than the other. Per-(date,
/// exptime) grouping means each night's best/worst frame gets the SAME
/// relative score as the other night's, rather than the whole "bright"
/// night scoring uniformly worse than the whole "dim" one just because
/// their backgrounds are pooled together.
@Test func scoringGroupsPerSessionDateNotPooledAcrossNights() throws {
    let fixture = try RateFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLightFrame(
        relativePath: "sessions/P/2026-01-01/lights/D1_1.fit", target: "P", sessionDate: "2026-01-01",
        pixels: Array(repeating: 10, count: 4), width: 2, height: 2, exptime: 60.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/P/2026-01-01/lights/D1_2.fit", target: "P", sessionDate: "2026-01-01",
        pixels: Array(repeating: 20, count: 4), width: 2, height: 2, exptime: 60.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/P/2026-01-01/lights/D1_3.fit", target: "P", sessionDate: "2026-01-01",
        pixels: Array(repeating: 30, count: 4), width: 2, height: 2, exptime: 60.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/P/2026-02-02/lights/D2_1.fit", target: "P", sessionDate: "2026-02-02",
        pixels: Array(repeating: 1000, count: 4), width: 2, height: 2, exptime: 60.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/P/2026-02-02/lights/D2_2.fit", target: "P", sessionDate: "2026-02-02",
        pixels: Array(repeating: 1010, count: 4), width: 2, height: 2, exptime: 60.0
    )
    try fixture.addLightFrame(
        relativePath: "sessions/P/2026-02-02/lights/D2_3.fit", target: "P", sessionDate: "2026-02-02",
        pixels: Array(repeating: 1020, count: 4), width: 2, height: 2, exptime: 60.0
    )

    let rater = Rater(db: fixture.db, config: fixture.config, provider: nil)
    let results = try rater.rate(target: "P") // no --date: spans both nights

    #expect(results.count == 6)
    let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0) })
    let expectedMagnitude = (3.0 / 2.0).squareRoot()

    #expect(abs(byPath["sessions/P/2026-01-01/lights/D1_1.fit"]!.score - expectedMagnitude) < 0.0001)
    #expect(abs(byPath["sessions/P/2026-02-02/lights/D2_1.fit"]!.score - expectedMagnitude) < 0.0001)
    #expect(abs(byPath["sessions/P/2026-01-01/lights/D1_2.fit"]!.score - 0) < 0.0001)
    #expect(abs(byPath["sessions/P/2026-02-02/lights/D2_2.fit"]!.score - 0) < 0.0001)
    #expect(abs(byPath["sessions/P/2026-01-01/lights/D1_3.fit"]!.score - (-expectedMagnitude)) < 0.0001)
    #expect(abs(byPath["sessions/P/2026-02-02/lights/D2_3.fit"]!.score - (-expectedMagnitude)) < 0.0001)
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
    // synthetic FITS via the real subprocess is covered separately below
    // (`realSirilCLIFindstarOnSyntheticStarFieldReturnsNonNilFWHMAndStars`).
    let cli = try SirilCLI(path: cfg.rating.sirilPath)
    #expect(!cli.version.isEmpty)
    // Regression guard for the real bug on this machine: the version must
    // never be the bare macOS-launch banner (see `parseVersionOutput`'s
    // tests above for the exact two-line real output this parses).
    #expect(cli.version.range(of: #"\d"#, options: .regularExpression) != nil, "expected an actual version string, got: \(cli.version)")

    let script = try SirilCLI.buildScript(imagePath: "/tmp/x.fit")
    #expect(script.contains("findstar"))
}

/// Builds a small mono 16-bit FITS with a handful of synthetic Gaussian
/// star blobs on a flat background -- `FITSTestBuilder`'s plain
/// `buildHeaderData` only builds headers, and `build16BitFITS` above only
/// takes a flat pixel array, so this renders the blobs into that array
/// first. Used only by the real-Siril integration test below: Siril's
/// `findstar` needs an actual stellar PSF-like profile to detect anything,
/// unlike `NativeStats`'s tests (which only care about pixel VALUES, not
/// shape).
private func buildSyntheticStarFieldFITS(
    width: Int, height: Int, background: Int,
    stars: [(x: Int, y: Int, amplitude: Double, sigma: Double)]
) -> Data {
    var pixels = [Double](repeating: Double(background), count: width * height)
    for star in stars {
        let radius = Int(star.sigma * 6) + 1
        for y in max(0, star.y - radius)..<min(height, star.y + radius + 1) {
            for x in max(0, star.x - radius)..<min(width, star.x + radius + 1) {
                let dx = Double(x - star.x)
                let dy = Double(y - star.y)
                let value = star.amplitude * exp(-(dx * dx + dy * dy) / (2 * star.sigma * star.sigma))
                pixels[y * width + x] += value
            }
        }
    }
    let intPixels = pixels.map { Int($0.rounded()) }
    return build16BitFITS(width: width, height: height, pixels: intPixels)
}

/// Integration test (guard-skipped when Siril isn't installed): runs the
/// REAL `siril-cli` subprocess's `load` + `findstar` against a synthetic
/// star field in a TEMP directory (never touches the scanned image
/// library) and verifies `SirilCLI.metrics` actually comes back with a
/// positive star count and a non-nil FWHM -- the acceptance criterion for
/// item D's fix. Before the fix, this reproduced the real bug exactly:
/// Siril 1.4's actual findstar wording ("Found N Gaussian profile stars")
/// never matched the old parser, so this call always threw
/// `ProcessError.unparsableOutput`.
@Test func realSirilCLIFindstarOnSyntheticStarFieldReturnsNonNilFWHMAndStarCount() throws {
    let cfg = AstroConfig()
    guard FileManager.default.isExecutableFile(atPath: cfg.rating.sirilPath) else { return }

    let workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-siril-findstar-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    let data = buildSyntheticStarFieldFITS(
        width: 256, height: 256, background: 500,
        stars: [
            (x: 60, y: 60, amplitude: 8000, sigma: 2.0),
            (x: 120, y: 90, amplitude: 20000, sigma: 2.5),
            (x: 180, y: 150, amplitude: 5000, sigma: 1.8),
            (x: 200, y: 40, amplitude: 12000, sigma: 2.2),
            (x: 90, y: 200, amplitude: 30000, sigma: 3.0),
        ]
    )
    let imageURL = workDir.appendingPathComponent("stars.fit")
    try data.write(to: imageURL)

    let cli = try SirilCLI(path: cfg.rating.sirilPath)
    let metrics = try cli.metrics(for: imageURL, workDir: workDir)

    #expect(metrics.starCount >= 1)
    #expect(metrics.fwhm > 0)
}
