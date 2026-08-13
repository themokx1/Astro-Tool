@testable import AstroApplication
import AstroCore
import Foundation
import Testing

// MARK: - Fixture helpers

/// Pads a FITS card line to 80 characters and builds real pixel content --
/// `SensorProfiler.measure` reads actual pixel bytes (median/read-noise/
/// dark-rate all come from `NativeStats.centralCropPixels`), unlike
/// `CalibrationQueryTests.swift`'s header-only fixtures, which only need
/// metadata to be scanned. Duplicated here (not shared) for the same
/// reason `CalibrationQueryTests.swift` duplicates its own card helper --
/// AstroApplicationTests cannot import AstroCoreTests' file-private
/// `SensorProfileTests.swift` helpers.
private func sensorCommandCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func sensorCommandHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(sensorCommandCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

private func sensorCommandBuildFITS(width: Int, height: Int, pixels: [Int]) -> Data {
    precondition(pixels.count == width * height)
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
        "END",
    ]
    var data = sensorCommandHeaderData(cards)
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

/// An 8x8 checkerboard -- any even-area crop contains exactly half of each
/// value, so `NativeStats.centralCropPixels`'s central-50% 4x4 crop has a
/// deterministic median regardless of which frame this is. Mirrors
/// `Tests/AstroCoreTests/SensorProfileTests.swift`'s own helper of the same
/// shape.
private func sensorCommandCheckerboard(base: Int, delta: Int) -> Data {
    var pixels = [Int](repeating: 0, count: 64)
    for row in 0..<8 {
        for col in 0..<8 {
            pixels[row * 8 + col] = (row + col) % 2 == 0 ? base + delta : base - delta
        }
    }
    return sensorCommandBuildFITS(width: 8, height: 8, pixels: pixels)
}

/// A simple thread-safe counter -- `progress`/`isCancelled` are `@Sendable`
/// closures, so a plain captured `var` cannot be mutated/read from them.
/// Mirrors `SensorProfileTests.swift`'s own `Recorder` helper.
private final class SensorCommandCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func increment() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}

private struct SensorCommandFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> Self {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-command-tests-\(UUID().uuidString)", isDirectory: true)
        let libraryDir = base.appendingPathComponent("library", isDirectory: true)
        let dbDir = base.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("astrotool.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return Self(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir.deletingLastPathComponent())
    }

    @discardableResult
    func addBiasFrame(
        relativePath: String, camera: String, gain: Double, offset: Double, data: Data
    ) throws -> Int64 {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let record = FileRecord(
            path: relativePath, size: Int64(data.count), mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .calibration, role: .bias, scannedAt: Date().timeIntervalSince1970
        )
        let fileID = try db.upsertFile(record)
        try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, gain: gain, offset: offset, instrume: camera, egain: 1.0))
        return fileID
    }
}

@Suite("SensorMeasurementCommand")
struct SensorMeasurementCommandTests {
    @Test("Running the command measures every combo, upserts into the database, and reports progress")
    func measuresUpsertsAndReportsProgress() throws {
        let fixture = try SensorCommandFixture.make()
        defer { fixture.cleanup() }
        try fixture.addBiasFrame(
            relativePath: "calibration_library/biases/a1.fit", camera: "CamA", gain: 100, offset: 50,
            data: sensorCommandCheckerboard(base: 500, delta: 5)
        )

        let command = SensorMeasurementCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        let counter = SensorCommandCounter()
        let results = try command.run(progress: { _ in counter.increment() })

        #expect(results.count == 1)
        #expect(results.first?.camera == "CamA")
        #expect(counter.count > 0)
        let stored = try fixture.db.allSensorProfiles()
        #expect(stored.count == 1)
    }

    @Test("Cooperative cancellation stops the run between combos, leaving already-measured combos upserted")
    func cancellationStopsBetweenCombos() throws {
        let fixture = try SensorCommandFixture.make()
        defer { fixture.cleanup() }
        // `SensorProfiler.measure` sorts combos by camera name -- CamA is
        // measured (and upserted) before CamB's turn is ever reached.
        try fixture.addBiasFrame(
            relativePath: "calibration_library/biases/a1.fit", camera: "CamA", gain: 100, offset: 50,
            data: sensorCommandCheckerboard(base: 500, delta: 5)
        )
        try fixture.addBiasFrame(
            relativePath: "calibration_library/biases/b1.fit", camera: "CamB", gain: 200, offset: 60,
            data: sensorCommandCheckerboard(base: 600, delta: 5)
        )

        let command = SensorMeasurementCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        let counter = SensorCommandCounter()
        do {
            _ = try command.run(
                progress: { _ in counter.increment() },
                isCancelled: { counter.count >= 1 }
            )
            Issue.record("Expected cancellation to throw CancellationError")
        } catch is CancellationError {
            // expected
        }

        #expect(counter.count == 1)
        let stored = try fixture.db.allSensorProfiles()
        #expect(stored.count == 1)
        #expect(stored.first?.camera == "CamA")
    }

    @Test("With no isCancelled closure supplied, the run always completes every combo")
    func noCancellationClosureRunsToCompletion() throws {
        let fixture = try SensorCommandFixture.make()
        defer { fixture.cleanup() }
        try fixture.addBiasFrame(
            relativePath: "calibration_library/biases/a1.fit", camera: "CamA", gain: 100, offset: 50,
            data: sensorCommandCheckerboard(base: 500, delta: 5)
        )
        try fixture.addBiasFrame(
            relativePath: "calibration_library/biases/b1.fit", camera: "CamB", gain: 200, offset: 60,
            data: sensorCommandCheckerboard(base: 600, delta: 5)
        )

        let command = SensorMeasurementCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        let results = try command.run()

        #expect(results.count == 2)
        let stored = try fixture.db.allSensorProfiles()
        #expect(stored.count == 2)
    }
}
