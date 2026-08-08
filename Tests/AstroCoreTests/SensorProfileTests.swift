import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixture helpers

/// Builds a plain 16-bit mono FITS (no BZERO -- signed reads, values here
/// never approach the negative range) from a flat `Data` pixel buffer, same
/// header shape as `RateTests.swift`'s own `build16BitFITS` -- duplicated
/// here rather than shared, since it's a private, file-scoped test helper
/// there.
private func buildSensorFITS(width: Int, height: Int, pixels: [Int]) -> Data {
    precondition(pixels.count == width * height)
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
        "END",
    ]
    var data = buildHeaderData(cards)
    var pixelBytes = Data()
    pixelBytes.reserveCapacity(pixels.count * 2)
    for value in pixels {
        let unsigned = UInt16(bitPattern: Int16(value))
        pixelBytes.append(UInt8(unsigned >> 8))
        pixelBytes.append(UInt8(unsigned & 0xFF))
    }
    data.append(pixelBytes)
    return data
}

/// An 8x8 checkerboard: `(row+col)%2 == 0` pixels get `base + delta`, the
/// rest get `base - delta`. Any even-area rectangular crop of this pattern
/// (in particular `NativeStats.centralCropPixels`'s central-50% 4x4 crop of
/// an 8x8 frame) contains EXACTLY half of each value -- deterministic
/// median and deterministic difference-vs-a-flat-frame statistics, no
/// randomness needed.
private func buildCheckerboardFITS(base: Int, delta: Int) -> Data {
    var pixels = [Int](repeating: 0, count: 64)
    for row in 0..<8 {
        for col in 0..<8 {
            pixels[row * 8 + col] = (row + col) % 2 == 0 ? base + delta : base - delta
        }
    }
    return buildSensorFITS(width: 8, height: 8, pixels: pixels)
}

private func buildFlatFITS(value: Int) -> Data {
    buildSensorFITS(width: 8, height: 8, pixels: [Int](repeating: value, count: 64))
}

private struct SensorFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> SensorFixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-sensor-tests-\(UUID().uuidString)", isDirectory: true)
        let libraryDir = base.appendingPathComponent("library", isDirectory: true)
        let dbDir = base.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        let db = try Database(path: dbDir.appendingPathComponent("astrotool.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return SensorFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir.deletingLastPathComponent())
    }

    @discardableResult
    func addFrame(
        relativePath: String,
        role: FrameRole,
        data: Data,
        camera: String = "ASI2600MC",
        gain: Double? = 100,
        offset: Double? = 50,
        egain: Double? = 1.0,
        exptime: Double? = nil,
        ccdTemp: Double? = nil
    ) throws -> Int64 {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)

        let record = FileRecord(
            path: relativePath,
            size: Int64(data.count),
            mtime: 1_700_000_000,
            ext: "fit",
            kind: "fits",
            area: .calibration,
            role: role,
            scannedAt: Date().timeIntervalSince1970
        )
        let fileID = try db.upsertFile(record)
        try db.upsertFITSMeta(
            FITSMetaRecord(
                fileID: fileID, exptime: exptime, gain: gain, offset: offset,
                ccdTemp: ccdTemp, instrume: camera, egain: egain
            )
        )
        return fileID
    }
}

// MARK: - bias_level_adu + read_noise_e

@Test func sensorProfilerMeasuresBiasLevelAsMedianOfOneBiasFrameCentralCrop() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    // A single bias frame -- checkerboard 500±5 -- median of any even-area
    // crop is exactly 500 (see `buildCheckerboardFITS`'s doc comment).
    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildCheckerboardFITS(base: 500, delta: 5)
    )

    let profiles = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)

    let profile = try #require(profiles.first)
    #expect(profile.camera == "ASI2600MC")
    #expect(profile.gain == 100)
    #expect(profile.offset == 50)
    #expect(profile.biasLevelADU == 500)
    #expect(profile.readNoiseE == nil, "only one bias frame -- read noise needs a pair")
    #expect(profile.frameCount == 1)
}

@Test func sensorProfilerMeasuresReadNoiseFromBiasPairDifferenceClippedSigmaOverSqrt2TimesEGain() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    // bias_a: checkerboard 500±5. bias_b: flat 500. Their difference is
    // exactly +5/-5 in equal counts within any even-area crop -> population
    // std == 5 exactly, no clipping ever triggers (no outliers at all).
    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildCheckerboardFITS(base: 500, delta: 5), egain: 2.0
    )
    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_b.fit", role: .bias,
        data: buildFlatFITS(value: 500), egain: 2.0
    )

    let profiles = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)

    let profile = try #require(profiles.first)
    #expect(profile.frameCount == 2)
    #expect(profile.biasLevelADU == 500)
    // read_noise_e = sigma/sqrt(2) * egain = 5/sqrt(2) * 2.0
    let expected = 5.0 / 2.0.squareRoot() * 2.0
    let readNoise = try #require(profile.readNoiseE)
    #expect(abs(readNoise - expected) < 0.0001)
}

// MARK: - clippedStandardDeviation (R7-B6: single-pass, not iterated to convergence)

/// Regression guard for the real bug: on discrete/quantized data, iterating
/// sigma-clipping to convergence collapses the result toward a MAD-based
/// estimate, which reads noticeably low. A clean discrete population (no
/// outliers at all) must come back through unmodified as its own plain
/// (population) sigma -- NOT the MAD×1.4826 figure, which is measurably
/// different even on this small synthetic set.
@Test func clippedStandardDeviationOnCleanDiscreteDataEqualsPlainSigmaNotMAD() throws {
    // 200 each of -2,-1,0,1,2 -- population variance = mean of squares =
    // (4+1+0+1+4)/5 = 2, so sigma == sqrt(2) exactly.
    var values: [Double] = []
    for v in [-2.0, -1.0, 0.0, 1.0, 2.0] {
        values.append(contentsOf: Array(repeating: v, count: 200))
    }
    let expectedPlainSigma = 2.0.squareRoot()
    // MAD on this same set: median 0, sorted absolute deviations put the
    // median abs-dev at 1 -> MAD-scaled (x1.4826) == 1.4826, a ~5% but very
    // real difference from the true sqrt(2) -- exactly the kind of gap that
    // made the old iterated estimator read low on real sensor data.
    let madScaled = 1.4826

    let result = SensorProfiler.clippedStandardDeviation(values)
    #expect(abs(result - expectedPlainSigma) < 0.0001, "clean data has no outliers -- a single clipping pass must change nothing")
    #expect(abs(result - madScaled) > 0.01, "must NOT collapse toward the MAD-scaled estimate")
}

/// A single clipping pass must still do its actual job: genuine far
/// outliers (a hot/corrupt pixel, a cosmic-ray hit) get dropped, and the
/// returned sigma reflects the clean core population, not one blown up by
/// the outliers.
@Test func clippedStandardDeviationDropsGenuineOutliersInASinglePass() throws {
    var values: [Double] = []
    for v in [-2.0, -1.0, 0.0, 1.0, 2.0] {
        values.append(contentsOf: Array(repeating: v, count: 200))
    }
    // A handful of extreme outliers, far beyond any plausible multiple of
    // the core's own sigma (sqrt(2) ~= 1.41).
    values.append(contentsOf: Array(repeating: 1000.0, count: 5))

    let expectedPlainSigmaOfCore = 2.0.squareRoot()
    let result = SensorProfiler.clippedStandardDeviation(values)
    #expect(abs(result - expectedPlainSigmaOfCore) < 0.01, "a single 5-sigma pass must drop the outliers and return the clean core's own sigma")
}

/// Regression guard for the real read-noise under-read bug: on a real
/// IMX571 bias-pair difference, ~0.5% of pixels are genuine sensor noise
/// (RTS/"twinkling" pixels), not cosmic rays -- an earlier 5σ clip pass was
/// discarding that whole tail, reading 1.06 e⁻ against a true ~1.30 e⁻
/// (matching an independently measured expert reference). The fix widens
/// the clip to 10σ so that tail survives. Verified directly against
/// `clippedStandardDeviation` (not through the full `SensorProfiler.measure`
/// pipeline) by comparing the SAME data at both thresholds: an explicit 5σ
/// pass must still drop the tail (collapsing to the core-only sigma), while
/// the actual default (10σ) must keep it (landing on the full, unclipped
/// population sigma instead).
@Test func clippedStandardDeviationAt10SigmaKeepsFatTailRTSPixelsA5SigmaClipWouldDrop() throws {
    // Core: 1000 samples, sigma == sqrt(2) exactly (same clean discrete
    // population as the sibling tests above).
    var values: [Double] = []
    for v in [-2.0, -1.0, 0.0, 1.0, 2.0] {
        values.append(contentsOf: Array(repeating: v, count: 200))
    }
    let coreSigma = 2.0.squareRoot()

    // ~0.5% fat tail (5 of 1005 total) at 6x the core sigma -- far enough
    // out to sit beyond a 5σ clip of the full (tail-inflated) population,
    // but still well inside a 10σ one.
    let tailValue = 6.0 * coreSigma
    values.append(contentsOf: Array(repeating: tailValue, count: 5))

    let fiveSigmaResult = SensorProfiler.clippedStandardDeviation(values, sigma: 5.0)
    let tenSigmaResult = SensorProfiler.clippedStandardDeviation(values, sigma: 10.0)

    #expect(
        abs(fiveSigmaResult - coreSigma) < 0.01,
        "a 5-sigma clip drops the tail entirely and collapses back to the core-only sigma"
    )

    // The default (`SensorProfiler`'s own `clipSigmaThreshold`) must behave
    // exactly like the explicit 10σ call above.
    #expect(SensorProfiler.clippedStandardDeviation(values) == tenSigmaResult)

    let fullMean = values.reduce(0, +) / Double(values.count)
    let fullVariance = values.reduce(0) { $0 + ($1 - fullMean) * ($1 - fullMean) } / Double(values.count)
    let fullSigma = fullVariance.squareRoot()

    #expect(
        abs(tenSigmaResult - fullSigma) < 0.0001,
        "a 10-sigma clip keeps every sample -- must equal the plain (unclipped) population sigma"
    )
    #expect(
        tenSigmaResult - fiveSigmaResult > 0.05,
        "10-sigma must retain measurably more spread than 5-sigma's tail-dropped result -- the whole point of widening the clip"
    )
}

// MARK: - dark_rate_e_per_s

@Test func sensorProfilerMeasuresDarkRateFromMatchingDarkFrameClampedAtZero() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildFlatFITS(value: 500), egain: 1.0
    )
    // Dark median 560 -- 60 ADU above the 500 bias level, 60s exposure,
    // egain 1.0 -> rate = 60 * 1.0 / 60 = 1.0 e-/s.
    try fixture.addFrame(
        relativePath: "calibration_library/darks/dark_60s.fit", role: .dark,
        data: buildFlatFITS(value: 560), egain: 1.0, exptime: 60, ccdTemp: -10.0
    )

    let profiles = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)

    let profile = try #require(profiles.first)
    let darkRate = try #require(profile.darkRateEPerS)
    #expect(abs(darkRate - 1.0) < 0.0001)
    #expect(profile.darkTempC == -10.0)
}

@Test func sensorProfilerClampsNegativeDarkRateToZero() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildFlatFITS(value: 500), egain: 1.0
    )
    // Dark median BELOW bias level (quantization/noise can do this on a
    // sensor with sub-ADU dark current) -- must clamp to 0, never negative.
    try fixture.addFrame(
        relativePath: "calibration_library/darks/dark_60s.fit", role: .dark,
        data: buildFlatFITS(value: 498), egain: 1.0, exptime: 60, ccdTemp: -10.0
    )

    let profiles = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
    let profile = try #require(profiles.first)
    #expect(profile.darkRateEPerS == 0)
}

@Test func sensorProfilerLeavesDarkRateNilWhenNoDarkFrameExistsForTheCombo() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildFlatFITS(value: 500)
    )

    let profiles = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
    let profile = try #require(profiles.first)
    #expect(profile.darkRateEPerS == nil)
    #expect(profile.darkTempC == nil)
}

// MARK: - Grouping by (camera, gain, offset)

@Test func sensorProfilerProducesSeparateProfilesForDifferentGainOffsetCombos() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_g100.fit", role: .bias,
        data: buildFlatFITS(value: 500), gain: 100, offset: 50
    )
    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_g0.fit", role: .bias,
        data: buildFlatFITS(value: 300), gain: 0, offset: 30
    )

    let profiles = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
    #expect(profiles.count == 2)

    let g100 = try #require(profiles.first { $0.gain == 100 })
    #expect(g100.biasLevelADU == 500)
    let g0 = try #require(profiles.first { $0.gain == 0 })
    #expect(g0.biasLevelADU == 300)
}

@Test func sensorProfilerSkipsBiasFramesWithNoInstrumeCamera() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_unknown.fit", role: .bias,
        data: buildFlatFITS(value: 500), camera: "", gain: nil, offset: nil
    )
    // Empty-string "camera" param maps straight to `instrume: ""` in
    // `addFrame` -- exercise the REAL missing-camera case by writing nil
    // directly via a second, explicit upsert instead.
    let fileID = try fixture.db.fileID(path: "calibration_library/biases/bias_unknown.fit")
    if let fileID {
        try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, instrume: nil))
    }

    let profiles = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
    #expect(profiles.isEmpty)
}

// MARK: - Persistence

@Test func sensorProfilerUpsertsIntoDatabaseAndIsReadableAfterward() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildFlatFITS(value: 500)
    )

    _ = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)

    let stored = try fixture.db.sensorProfile(camera: "ASI2600MC", gain: 100, offset: 50)
    #expect(stored?.biasLevelADU == 500)
    #expect(try fixture.db.allSensorProfiles().count == 1)
}

// MARK: - History append (R11-T10/F8)

/// `measure` writes BOTH the "latest view" (`sensor_profile`) row AND a new
/// `sensor_profile_history` entry, and both are stamped with the SAME
/// `SensorProfiler.estimatorVersion` -- the two must never disagree about
/// what estimator produced this measurement.
@Test func sensorProfilerMeasureStampsBothTheLatestRowAndANewHistoryRowWithTheCurrentEstimatorVersion() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildFlatFITS(value: 500)
    )

    _ = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)

    let stored = try #require(try fixture.db.sensorProfile(camera: "ASI2600MC", gain: 100, offset: 50))
    #expect(stored.estimatorVersion == SensorProfiler.estimatorVersion)

    let history = try fixture.db.sensorProfileHistory(camera: "ASI2600MC", gain: 100, offset: 50)
    #expect(history.count == 1)
    #expect(history[0].estimatorVersion == SensorProfiler.estimatorVersion)
    #expect(history[0].biasLevelADU == 500)
}

/// A SECOND `measure` run (e.g. after taking fresh bias frames) APPENDS a
/// new history row rather than replacing the first one -- `sensor_profile`
/// itself still only ever holds the latest.
@Test func sensorProfilerMeasureTwiceAppendsTwoHistoryRowsButOnlyOneLatestProfile() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildFlatFITS(value: 500)
    )
    _ = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)

    // Re-measure against a changed bias level (e.g. fresh frames taken).
    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildFlatFITS(value: 520)
    )
    _ = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)

    #expect(try fixture.db.allSensorProfiles().count == 1)
    let latest = try #require(try fixture.db.sensorProfile(camera: "ASI2600MC", gain: 100, offset: 50))
    #expect(latest.biasLevelADU == 520)

    let history = try fixture.db.sensorProfileHistory(camera: "ASI2600MC", gain: 100, offset: 50)
    #expect(history.count == 2)
    #expect(history.map(\.biasLevelADU) == [500, 520])
}

// MARK: - isEstimatorStale / comboKey

@Test func isEstimatorStaleIsTrueForNilOrOlderVersionFalseForCurrentOrNewer() throws {
    let unknown = SensorProfileRecord(camera: "Cam", measuredAt: 1_700_000_000, estimatorVersion: nil)
    #expect(unknown.isEstimatorStale == true)

    let older = SensorProfileRecord(camera: "Cam", measuredAt: 1_700_000_000, estimatorVersion: SensorProfiler.estimatorVersion - 1)
    #expect(older.isEstimatorStale == true)

    let current = SensorProfileRecord(camera: "Cam", measuredAt: 1_700_000_000, estimatorVersion: SensorProfiler.estimatorVersion)
    #expect(current.isEstimatorStale == false)
}

@Test func comboKeyDistinguishesDifferentCombosAndHandlesNilGainOffset() throws {
    let a = SensorProfileRecord(camera: "Cam", gain: 100, offset: 50, measuredAt: 0)
    let b = SensorProfileRecord(camera: "Cam", gain: 200, offset: 50, measuredAt: 0)
    let c = SensorProfileRecord(camera: "Cam", measuredAt: 0)
    #expect(a.comboKey != b.comboKey)
    #expect(a.comboKey != c.comboKey)
    #expect(c.comboKey == "Cam|-|-")
}

@Test func sensorProfilerReportsProgressPerCombo() throws {
    let fixture = try SensorFixture.make()
    defer { fixture.cleanup() }

    try fixture.addFrame(
        relativePath: "calibration_library/biases/bias_a.fit", role: .bias,
        data: buildFlatFITS(value: 500)
    )

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [String] = []
        func record(_ message: String) { lock.lock(); _messages.append(message); lock.unlock() }
        var messages: [String] { lock.lock(); defer { lock.unlock() }; return _messages }
    }
    let recorder = Recorder()

    _ = try SensorProfiler.measure(
        db: fixture.db, config: fixture.config, root: fixture.libraryDir,
        progress: { recorder.record($0) }
    )
    #expect(!recorder.messages.isEmpty)
}

// MARK: - Drift warnings (missing profile for a combo lights actually use)

@Test func sensorProfilerCombosMissingProfileFlagsALightsComboWithNoBiasEverMeasured() throws {
    let db = try Database(path: ":memory:")
    let fileID = try db.upsertFile(
        FileRecord(
            path: "sessions/M31/2026-01-01/lights/a.fit", size: 1024, mtime: 1_700_000_000,
            ext: "fit", kind: "fits", area: .sessions, target: "M31", sessionDate: "2026-01-01",
            role: .light, scannedAt: 1_700_000_100
        )
    )
    try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, gain: 100, offset: 50, instrume: "ASI2600MC"))

    let lights = try db.allFiles(includeMissing: false)
    var meta: [Int64: FITSMetaRecord] = [:]
    if let id = lights.first?.id, let m = try db.fitsMeta(fileID: id) { meta[id] = m }

    let missing = SensorProfiler.combosMissingProfile(lights: lights, meta: meta, profiles: [])
    #expect(missing.count == 1)
    #expect(missing.first?.camera == "ASI2600MC")
    #expect(missing.first?.gain == 100)
    #expect(missing.first?.offset == 50)
}

@Test func sensorProfilerCombosMissingProfileIsEmptyWhenAMatchingProfileExists() throws {
    let db = try Database(path: ":memory:")
    let fileID = try db.upsertFile(
        FileRecord(
            path: "sessions/M31/2026-01-01/lights/a.fit", size: 1024, mtime: 1_700_000_000,
            ext: "fit", kind: "fits", area: .sessions, target: "M31", sessionDate: "2026-01-01",
            role: .light, scannedAt: 1_700_000_100
        )
    )
    try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, gain: 100, offset: 50, instrume: "ASI2600MC"))

    let lights = try db.allFiles(includeMissing: false)
    var meta: [Int64: FITSMetaRecord] = [:]
    if let id = lights.first?.id, let m = try db.fitsMeta(fileID: id) { meta[id] = m }

    let profile = SensorProfileRecord(camera: "ASI2600MC", gain: 100, offset: 50, biasLevelADU: 501, measuredAt: 1_700_000_000)
    let missing = SensorProfiler.combosMissingProfile(lights: lights, meta: meta, profiles: [profile])
    #expect(missing.isEmpty)
}

@Test func sensorProfilerCombosMissingProfileTreatsProfileWithNilBiasLevelAsStillMissing() throws {
    let db = try Database(path: ":memory:")
    let fileID = try db.upsertFile(
        FileRecord(
            path: "sessions/M31/2026-01-01/lights/a.fit", size: 1024, mtime: 1_700_000_000,
            ext: "fit", kind: "fits", area: .sessions, target: "M31", sessionDate: "2026-01-01",
            role: .light, scannedAt: 1_700_000_100
        )
    )
    try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, gain: 100, offset: 50, instrume: "ASI2600MC"))

    let lights = try db.allFiles(includeMissing: false)
    var meta: [Int64: FITSMetaRecord] = [:]
    if let id = lights.first?.id, let m = try db.fitsMeta(fileID: id) { meta[id] = m }

    // A profile row exists for this exact combo, but its bias level was
    // never actually measured (e.g. a partial/failed measurement) -- still
    // "missing" from `SessionQuality`'s point of view.
    let incomplete = SensorProfileRecord(camera: "ASI2600MC", gain: 100, offset: 50, biasLevelADU: nil, measuredAt: 1_700_000_000)
    let missing = SensorProfiler.combosMissingProfile(lights: lights, meta: meta, profiles: [incomplete])
    #expect(missing.count == 1)
}
