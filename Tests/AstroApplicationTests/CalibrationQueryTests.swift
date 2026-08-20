@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Pads a FITS card line to 80 characters -- mirrors
/// `Tests/AstroCoreTests/FITSTestBuilder.swift`'s helper of the same shape;
/// duplicated here because AstroApplicationTests cannot import
/// AstroCoreTests' file-private test target.
private func calibQueryCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func calibQueryHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(calibQueryCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// A fresh fixture library + fresh sqlite-backed `Database`, mirroring
/// `Tests/AstroCoreTests/CalibTests.swift`'s own `CalibFixture` -- kept
/// minimal (this test file only needs coverage/master-inventory/mismatch
/// projections, not the full coverage-matching matrix already exercised
/// there).
private struct CalibQueryFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> CalibQueryFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-query-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-query-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return CalibQueryFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func writeFITSLight(
        _ relativePath: String,
        exptime: Double?,
        setTemp: Double?,
        gain: Double? = nil,
        dateObs: String? = nil
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        if let gain { cards.append("GAIN    =                \(gain)") }
        if let dateObs { cards.append("DATE-OBS= '\(dateObs)'") }
        cards.append("END")
        try calibQueryHeaderData(cards).write(to: url)
    }

    func writeFITSMaster(
        _ relativePath: String,
        gain: Double? = nil,
        dateObs: String? = nil
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let gain { cards.append("GAIN    =                \(gain)") }
        if let dateObs { cards.append("DATE-OBS= '\(dateObs)'") }
        cards.append("END")
        try calibQueryHeaderData(cards).write(to: url)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

@Suite("CalibrationQuery")
struct CalibrationQueryTests {
    @Test("Coverage reports the sessions that still need a dark master")
    func coverageReportsSessionsMissingAMaster() throws {
        let fixture = try CalibQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let query = CalibrationQuery(db: fixture.db, config: fixture.config)
        let needs = try query.coverage()

        let need = try #require(needs.first)
        #expect(need.matchedMasterPath == nil)
        #expect(need.sessions == [.init(target: "T1", date: "2026-01-10")])
    }

    @Test("Coverage matches a session against an existing dark master")
    func coverageMatchesExistingMaster() throws {
        let fixture = try CalibQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let query = CalibrationQuery(db: fixture.db, config: fixture.config)
        let needs = try query.coverage()

        let need = try #require(needs.first)
        #expect(need.matchedMasterPath == "calibration_library/darks/300sec_-10deg")
    }

    @Test("Master inventory projects path, temperature, age, and staleness from CalibHealth")
    func masterInventoryProjectsHealthFields() throws {
        let fixture = try CalibQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master.fit")
        try fixture.scan()
        // Backdate well past the default 12-month staleness threshold.
        let masterURL = fixture.libraryDir.appendingPathComponent("calibration_library/darks/300sec_-10deg/master.fit")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-400 * 86400)],
            ofItemAtPath: masterURL.path
        )
        try fixture.scan()

        let query = CalibrationQuery(db: fixture.db, config: fixture.config)
        let masters = try query.masterInventory()

        let master = try #require(masters.first { $0.path == "calibration_library/darks/300sec_-10deg" })
        #expect(master.kind == .dark)
        #expect(master.isStale == true)
        #expect(master.ageDays != nil)
        #expect(master.frameCount == 1)
    }

    @Test("Mismatch reasons surface a gain conflict between a session and its would-be library dark")
    func mismatchReasonsSurfaceGainConflict() throws {
        let fixture = try CalibQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master.fit", gain: 0)
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0, gain: 100)
        try fixture.scan()

        let query = CalibrationQuery(db: fixture.db, config: fixture.config)
        let reasons = try query.mismatchReasons(target: "T1", date: "2026-01-10")

        #expect(!reasons.isEmpty)
        #expect(reasons.contains { $0.contains("gain") })
    }

    @Test("An unknown session throws pathNotFound rather than silently returning empty reasons")
    func mismatchReasonsThrowsForUnknownSession() throws {
        let fixture = try CalibQueryFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let query = CalibrationQuery(db: fixture.db, config: fixture.config)
        #expect(throws: AstroError.self) {
            _ = try query.mismatchReasons(target: "Nope", date: "2026-01-10")
        }
    }
}
