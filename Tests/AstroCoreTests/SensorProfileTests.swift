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
