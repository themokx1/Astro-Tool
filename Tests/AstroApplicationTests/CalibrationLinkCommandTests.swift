@testable import AstroApplication
import AstroCore
import Foundation
import Testing

private func calibLinkCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func calibLinkHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(calibLinkCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// Mirrors `CalibrationQueryTests`' own `CalibQueryFixture` -- kept as a
/// second, independent copy (rather than shared) since Swift Testing
/// fixtures in this codebase are conventionally file-local; see that file's
/// doc comment for why the FITS header builder can't just be imported from
/// AstroCoreTests.
private struct CalibLinkFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> CalibLinkFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-link-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-link-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return CalibLinkFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func writeFITSLight(_ relativePath: String, exptime: Double?, setTemp: Double?) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        cards.append("END")
        try calibLinkHeaderData(cards).write(to: url)
    }

    func writeFITSMaster(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        cards.append("END")
        try calibLinkHeaderData(cards).write(to: url)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

@Suite("CalibrationLinkCommand")
struct CalibrationLinkCommandTests {
    @Test("Plan surfaces CalibLinker's own plan items unmodified")
    func planReturnsLinkerItems() throws {
        let fixture = try CalibLinkFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master2.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let command = CalibrationLinkCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .readOnly
        )
        let plan = try command.plan(target: "T1", date: "2026-01-10")

        #expect(plan.items.count == 2)
        #expect(plan.items.allSatisfy { $0.destDir == "sessions/T1/2026-01-10/darks" })
    }

    @Test("Apply in read-only mode throws before touching the filesystem")
    func applyReadOnlyThrows() throws {
        let fixture = try CalibLinkFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let command = CalibrationLinkCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .readOnly
        )
        let plan = try command.plan(target: "T1", date: "2026-01-10")

        #expect(throws: LibraryMutationError.readOnly) {
            _ = try command.apply(plan)
        }
        let destDir = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/darks")
        #expect(!FileManager.default.fileExists(atPath: destDir.path))
    }

    @Test("Apply in mutation-enabled mode links the files and returns a receipt")
    func applyMutationEnabledLinksFiles() throws {
        let fixture = try CalibLinkFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let command = CalibrationLinkCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .mutationEnabled
        )
        let plan = try command.plan(target: "T1", date: "2026-01-10")
        let receipt = try command.apply(plan)

        #expect(receipt.linked.count == 1)
        #expect(receipt.skipped.isEmpty)
        #expect(receipt.target == "T1")
        #expect(receipt.date == "2026-01-10")
        let destFile = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/darks/master1.fit")
        #expect(FileManager.default.fileExists(atPath: destFile.path))
    }

    @Test("A second apply of the same plan is idempotent -- files are reported skipped, never duplicated or errored")
    func secondApplyIsIdempotent() throws {
        let fixture = try CalibLinkFixture.make()
        defer { fixture.cleanup() }

        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let command = CalibrationLinkCommand(
            db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: .mutationEnabled
        )
        let plan = try command.plan(target: "T1", date: "2026-01-10")
        _ = try command.apply(plan)

        let secondReceipt = try command.apply(plan)

        #expect(secondReceipt.linked.isEmpty)
        #expect(secondReceipt.skipped.count == 1)
    }
}
