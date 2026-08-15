@testable import AstroApplication
@testable import AstroUI
import AstroCore
import Foundation
import Testing

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: `InsightsStore` used to
/// be a `private final class` embedded in `InsightsView.swift` that
/// resolved `InsightsQuery.production` directly inside `load` -- there was
/// no way to load it against anything but a real on-disk library, so this
/// whole screen had zero unit-test surface. This is that surface.
@MainActor
@Suite("V2 Insights store")
struct InsightsStoreTests {
    private static func makeIndex() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
        CREATE TABLE files(id INTEGER PRIMARY KEY, area TEXT, target TEXT, session_date TEXT, role TEXT, missing INTEGER);
        CREATE TABLE fits_meta(file_id INTEGER PRIMARY KEY, exptime REAL, filter TEXT, instrume TEXT, focallen REAL);
        INSERT INTO files VALUES(1,'sessions','IC1396','2026-08-08','light',0);
        INSERT INTO files VALUES(2,'sessions','IC1396','2026-08-08','light',0);
        INSERT INTO fits_meta VALUES(1,300,'SV220','ASI2600MC',261);
        INSERT INTO fits_meta VALUES(2,300,'SV220','ASI2600MC',261);
        """)
        return index
    }

    @Test("Loading a library populates the insights snapshot")
    func loadingPopulatesSnapshot() async throws {
        let index = try Self.makeIndex()
        let store = InsightsStore(queryFactory: { _ in InsightsQuery(indexDatabaseForTesting: index) })

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.snapshot?.frameCount == 2)
        #expect(store.snapshot?.targetCount == 1)
        #expect(store.errorMessage == nil)
    }

    @Test("A nil root clears the snapshot instead of loading anything")
    func nilRootClearsSnapshot() async throws {
        let index = try Self.makeIndex()
        let store = InsightsStore(queryFactory: { _ in InsightsQuery(indexDatabaseForTesting: index) })
        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(store.snapshot != nil)

        await store.load(rootURL: nil)

        #expect(store.snapshot == nil)
    }

    @Test("A load failure surfaces its error message rather than throwing past the view")
    func loadFailureSurfacesError() async throws {
        struct BoomError: Error {}
        let store = InsightsStore(queryFactory: { _ in throw BoomError() })

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.snapshot == nil)
        #expect(store.errorMessage != nil)
    }
}
