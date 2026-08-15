@testable import AstroApplication
@testable import AstroUI
import AstroCore
import Foundation
import Testing

private func calibStoreCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func calibStoreHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(calibStoreCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// A minimal on-disk library + scanned `Database`, built the same way as
/// `CalibrationQueryTests`' own fixture, so `CalibrationStore` can be loaded
/// against real coverage/master-inventory data via injected factories.
@MainActor
private struct CalibStoreFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> CalibStoreFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-store-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("calib-store-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return CalibStoreFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
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
        try calibStoreHeaderData(cards).write(to: url)
    }

    func writeFITSMaster(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2", "END"]
        try calibStoreHeaderData(cards).write(to: url)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

@MainActor
@Suite("V2 Calibration store")
struct CalibrationStoreTests {
    @Test("Loading a library populates coverage and master inventory")
    func loadingPopulatesCoverageAndMasters() async throws {
        let fixture = try CalibStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let store = CalibrationStore(
            queryFactory: { _ in CalibrationQuery(db: fixture.db, config: fixture.config) },
            commandFactory: { _, accessMode in
                CalibrationLinkCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: accessMode)
            }
        )

        await store.load(rootURL: fixture.libraryDir)

        #expect(store.errorMessage == nil)
        #expect(!store.coverage.isEmpty)
        #expect(store.masters.contains { $0.path == "calibration_library/darks/300sec_-10deg" })
    }

    @Test("Masters default to path-ascending and re-sort on demand")
    func sortsMastersByColumn() async throws {
        let fixture = try CalibStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSMaster("calibration_library/darks/100sec_-5deg/master2.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let store = CalibrationStore(
            queryFactory: { _ in CalibrationQuery(db: fixture.db, config: fixture.config) },
            commandFactory: { _, accessMode in
                CalibrationLinkCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: accessMode)
            }
        )

        await store.load(rootURL: fixture.libraryDir)

        #expect(store.masters.map(\.path) == [
            "calibration_library/darks/100sec_-5deg", "calibration_library/darks/300sec_-10deg",
        ])

        store.setMastersSortOrder([KeyPathComparator(\CalibrationMasterInfo.path, order: .reverse)])

        #expect(store.masters.map(\.path) == [
            "calibration_library/darks/300sec_-10deg", "calibration_library/darks/100sec_-5deg",
        ])
    }

    @Test("Preparing a link plan populates linkPlan without requiring write access")
    func preparingPlanWorksReadOnly() async throws {
        let fixture = try CalibStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let store = CalibrationStore(
            queryFactory: { _ in CalibrationQuery(db: fixture.db, config: fixture.config) },
            commandFactory: { _, accessMode in
                CalibrationLinkCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: accessMode)
            }
        )
        await store.load(rootURL: fixture.libraryDir, accessMode: .readOnly)

        await store.preparePlan(target: "T1", date: "2026-01-10")

        #expect(store.linkPlan != nil)
        #expect(store.linkPlan?.items.count == 1)
    }

    @Test("Applying a plan in read-only mode is rejected with an explanatory message and links nothing")
    func applyingPlanReadOnlyIsRejected() async throws {
        let fixture = try CalibStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let store = CalibrationStore(
            queryFactory: { _ in CalibrationQuery(db: fixture.db, config: fixture.config) },
            commandFactory: { _, accessMode in
                CalibrationLinkCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: accessMode)
            }
        )
        await store.load(rootURL: fixture.libraryDir, accessMode: .readOnly)
        await store.preparePlan(target: "T1", date: "2026-01-10")

        await store.applyPlan()

        #expect(store.lastReceipt == nil)
        #expect(store.planErrorMessage != nil)
        let destDir = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/darks")
        #expect(!FileManager.default.fileExists(atPath: destDir.path))
    }

    @Test("Applying a plan in mutation-enabled mode links files and refreshes the master inventory")
    func applyingPlanMutationEnabledLinksAndRefreshes() async throws {
        let fixture = try CalibStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let store = CalibrationStore(
            queryFactory: { _ in CalibrationQuery(db: fixture.db, config: fixture.config) },
            commandFactory: { _, accessMode in
                CalibrationLinkCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: accessMode)
            }
        )
        await store.load(rootURL: fixture.libraryDir, accessMode: .mutationEnabled)
        await store.preparePlan(target: "T1", date: "2026-01-10")

        await store.applyPlan()

        #expect(store.lastReceipt?.linked.count == 1)
        #expect(store.planErrorMessage == nil)
        let destFile = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/darks/master1.fit")
        #expect(FileManager.default.fileExists(atPath: destFile.path))
    }

    @Test("A successful apply fires onLibraryFindingsChanged so the sidebar badge can refresh")
    func applyingPlanFiresLibraryFindingsChanged() async throws {
        let fixture = try CalibStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let store = CalibrationStore(
            queryFactory: { _ in CalibrationQuery(db: fixture.db, config: fixture.config) },
            commandFactory: { _, accessMode in
                CalibrationLinkCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: accessMode)
            }
        )
        await store.load(rootURL: fixture.libraryDir, accessMode: .mutationEnabled)
        await store.preparePlan(target: "T1", date: "2026-01-10")
        var changeCount = 0
        store.onLibraryFindingsChanged = { changeCount += 1 }

        await store.applyPlan()

        #expect(changeCount == 1)
    }

    @Test("A read-only-rejected apply does not fire onLibraryFindingsChanged")
    func readOnlyRejectedApplyDoesNotFireLibraryFindingsChanged() async throws {
        let fixture = try CalibStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.writeFITSMaster("calibration_library/darks/300sec_-10deg/master1.fit")
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
        try fixture.scan()

        let store = CalibrationStore(
            queryFactory: { _ in CalibrationQuery(db: fixture.db, config: fixture.config) },
            commandFactory: { _, accessMode in
                CalibrationLinkCommand(db: fixture.db, config: fixture.config, root: fixture.libraryDir, accessMode: accessMode)
            }
        )
        await store.load(rootURL: fixture.libraryDir, accessMode: .readOnly)
        await store.preparePlan(target: "T1", date: "2026-01-10")
        var changeCount = 0
        store.onLibraryFindingsChanged = { changeCount += 1 }

        await store.applyPlan()

        #expect(changeCount == 0)
    }
}
