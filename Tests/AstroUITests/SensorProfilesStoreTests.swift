@testable import AstroApplication
@testable import AstroUI
import AstroCore
import Foundation
import Testing

// MARK: - Fixture helpers

/// Real pixel-bearing FITS builder -- `SensorMeasurementCommand` (via
/// `SensorProfiler.measure`) reads actual pixel bytes, unlike most
/// AstroUITests store fixtures, which only need scannable metadata.
/// Duplicated from `Tests/AstroApplicationTests/SensorMeasurementCommandTests.swift`
/// rather than shared, for the same reason that file's own doc comment
/// gives for not sharing `SensorProfileTests.swift`'s helpers: no shared,
/// non-file-private test target to import it from.
private func sensorStoreCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func sensorStoreHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(sensorStoreCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

private func sensorStoreBuildFITS(width: Int, height: Int, pixels: [Int]) -> Data {
    precondition(pixels.count == width * height)
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
        "END",
    ]
    var data = sensorStoreHeaderData(cards)
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

private func sensorStoreCheckerboard(base: Int, delta: Int) -> Data {
    var pixels = [Int](repeating: 0, count: 64)
    for row in 0..<8 {
        for col in 0..<8 {
            pixels[row * 8 + col] = (row + col) % 2 == 0 ? base + delta : base - delta
        }
    }
    return sensorStoreBuildFITS(width: 8, height: 8, pixels: pixels)
}

@MainActor
private struct SensorStoreFixture {
    let libraryDir: URL
    let indexDatabase: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> Self {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensor-store-tests-\(UUID().uuidString)", isDirectory: true)
        let libraryDir = base.appendingPathComponent("library", isDirectory: true)
        let dbDir = base.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let indexDatabase = dbDir.appendingPathComponent("index.sqlite")
        let db = try Database(path: indexDatabase.path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return Self(libraryDir: libraryDir, indexDatabase: indexDatabase, db: db, config: config)
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

    func store() -> SensorProfilesStore {
        SensorProfilesStore(
            queryFactory: { _ in SensorProfilesQuery(indexDatabase: indexDatabase) },
            commandFactory: { _ in SensorMeasurementCommand(db: db, config: config, root: libraryDir) }
        )
    }
}

@MainActor
@Suite("SensorProfilesStore")
struct SensorProfilesStoreTests {
    @Test("Loading reads the snapshot through the injected query factory")
    func loadReadsSnapshot() async throws {
        let fixture = try SensorStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.addBiasFrame(
            relativePath: "calibration_library/biases/a1.fit", camera: "CamA", gain: 100, offset: 50,
            data: sensorStoreCheckerboard(base: 500, delta: 5)
        )
        // Pre-measure directly so `load` has something to read.
        _ = try SensorProfiler.measure(db: fixture.db, config: fixture.config, root: fixture.libraryDir)
        let store = fixture.store()

        await store.load(rootURL: fixture.libraryDir)

        #expect(store.snapshot?.profiles.count == 1)
        #expect(store.errorMessage == nil)
    }

    @Test("Measuring runs through OperationHost, upserts real profiles, refreshes the snapshot, and toasts success")
    func measureRunsThroughOperationHostAndRefreshes() async throws {
        let fixture = try SensorStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.addBiasFrame(
            relativePath: "calibration_library/biases/a1.fit", camera: "CamA", gain: 100, offset: 50,
            data: sensorStoreCheckerboard(base: 500, delta: 5)
        )
        let store = fixture.store()
        await store.load(rootURL: fixture.libraryDir)
        #expect(store.snapshot?.profiles.isEmpty == true)
        let host = OperationHost(center: OperationCenter())

        await store.measure(operationHost: host)
        await host.settle()

        #expect(store.snapshot?.profiles.count == 1)
        #expect(store.snapshot?.profiles.first?.camera == "CamA")
        #expect(host.toasts.contains { $0.level == .success })
        #expect(host.recentOutcomes.contains {
            $0.kind == .sensorMeasurement(library: fixture.libraryDir.lastPathComponent) && $0.phase == .succeeded
        })
    }

    @Test("A measurement already in flight cannot be started a second time")
    func overlappingMeasurementIsRejected() async throws {
        let fixture = try SensorStoreFixture.make()
        defer { fixture.cleanup() }
        // Enough combos to give the background run real (if brief) work,
        // so the first operation is still registered when the second call's
        // synchronous guard check runs immediately afterward.
        for index in 0..<40 {
            try fixture.addBiasFrame(
                relativePath: "calibration_library/biases/cam\(index).fit", camera: "Cam\(index)",
                gain: 100, offset: 50, data: sensorStoreCheckerboard(base: 500 + index, delta: 5)
            )
        }
        let store = fixture.store()
        await store.load(rootURL: fixture.libraryDir)
        let host = OperationHost(center: OperationCenter())

        await store.measure(operationHost: host)
        await store.measure(operationHost: host)

        #expect(host.toasts.contains { $0.level == .info && $0.message.contains("already running") })
        await host.settle()
    }

    @Test("Measuring with no library loaded notifies instead of crashing")
    func measureWithNoLibraryLoadedNoOps() async throws {
        let store = SensorProfilesStore(
            queryFactory: { _ in throw SensorStoreTestFailure.shouldNotBeCalled },
            commandFactory: { _ in throw SensorStoreTestFailure.shouldNotBeCalled }
        )
        let host = OperationHost(center: OperationCenter())

        await store.measure(operationHost: host)

        #expect(host.activeOperations.isEmpty)
        #expect(host.toasts.contains { $0.level == .info })
    }

    @Test("Cancelling a measurement never surfaces as a failure toast")
    func cancellingMeasurementNeverReportsFailure() async throws {
        let fixture = try SensorStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.addBiasFrame(
            relativePath: "calibration_library/biases/a1.fit", camera: "CamA", gain: 100, offset: 50,
            data: sensorStoreCheckerboard(base: 500, delta: 5)
        )
        let store = fixture.store()
        await store.load(rootURL: fixture.libraryDir)
        let host = OperationHost(center: OperationCenter())

        await store.measure(operationHost: host)
        if let id = host.activeOperations.first?.id {
            _ = await host.cancel(id: id)
        }
        await host.settle()

        #expect(!host.toasts.contains { $0.level == .failure })
        #expect(!host.recentOutcomes.contains { $0.phase == .failed })
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("Condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum SensorStoreTestFailure: Error, Equatable {
    case shouldNotBeCalled
}
