@testable import AstroApplication
@testable import AstroUI
import AstroCore
import Foundation
import Testing

/// Pads a FITS card line to 80 characters, block-pads to 2880 -- mirrors
/// `CalibrationStoreTests.swift`/`ConversionWorkspaceTests.swift`'s helpers
/// of the same shape; duplicated here for the same reason they duplicate it
/// (this test target cannot import another target's file-private helper).
private func insightsStoreCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func insightsStoreHeaderData(_ cards: [String]) -> Data {
    var text = cards.map(insightsStoreCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: `InsightsStore` used to
/// be a `private final class` embedded in `InsightsView.swift` that
/// resolved `InsightsQuery.production` directly inside `load` -- there was
/// no way to load it against anything but a real on-disk library, so this
/// whole screen had zero unit-test surface. This is that surface.
///
/// Owner feedback wave 3, Task 2: `InsightsQuery` now runs its totals
/// through `Database.allFiles`/`fitsMetaBatch` + `FrameSet.lightBuckets`
/// (real dedup, matching `StatsQueries`), which needs real `path`/`inode`
/// columns a hand-rolled ad hoc `files` table never had -- so this fixture
/// scans real files with `LibraryScanner`, same convention as
/// `LibraryHealthStoreTests.makeFixture()`.
@MainActor
@Suite("V2 Insights store")
struct InsightsStoreTests {
    private struct Fixture {
        let libraryDir: URL
        let dbDir: URL
        let indexURL: URL
        let db: Database
        var config: AstroConfig
    }

    private static func makeFixture() throws -> Fixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insights-store-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insights-store-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let indexURL = dbDir.appendingPathComponent("test.sqlite")
        let db = try Database(path: indexURL.path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path

        // Two distinct (non-duplicate) IC1396 lights sharing a session/setup.
        for name in ["l1.fit", "l2.fit"] {
            let url = libraryDir.appendingPathComponent("sessions/IC1396/2026-08-08/lights/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try insightsStoreHeaderData([
                "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
                "EXPTIME =                300.0", "FILTER  = 'SV220'", "INSTRUME= 'ASI2600MC'", "FOCALLEN=                261.0",
                "END",
            ]).write(to: url)
        }

        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()

        return Fixture(libraryDir: libraryDir, dbDir: dbDir, indexURL: indexURL, db: db, config: config)
    }

    private nonisolated static func query(_ fixture: Fixture) -> InsightsQuery {
        let db = fixture.db
        let config = fixture.config
        return InsightsQuery(
            indexDatabaseForTesting: fixture.indexURL,
            captureTrendPointsForTesting: { [] },
            libraryForTesting: {
                let files = try db.allFiles(includeMissing: false)
                let meta = try db.fitsMetaBatch(fileIDs: files.compactMap(\.id))
                return (files, meta, config)
            }
        )
    }

    @Test("Loading a library populates the insights snapshot")
    func loadingPopulatesSnapshot() async throws {
        let fixture = try Self.makeFixture()
        let store = InsightsStore(queryFactory: { _ in Self.query(fixture) })

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.snapshot?.frameCount == 2)
        #expect(store.snapshot?.targetCount == 1)
        #expect(store.errorMessage == nil)
    }

    @Test("A nil root clears the snapshot instead of loading anything")
    func nilRootClearsSnapshot() async throws {
        let fixture = try Self.makeFixture()
        let store = InsightsStore(queryFactory: { _ in Self.query(fixture) })
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

    // MARK: - W7-E workflow #1 (rating gate, matching Insights hint)

    @Test("Loading a library also surfaces the same unrated-nights count Home's own rating-gate card reads")
    func loadingSurfacesTheRatingGapCount() async throws {
        let fixture = try Self.makeFixture()
        let store = InsightsStore(
            queryFactory: { _ in Self.query(fixture) },
            ratingGapProvider: { _ in 4 }
        )

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.unratedNightCount == 4)
    }

    @Test("A nil root clears the rating-gap count along with the snapshot")
    func nilRootClearsRatingGapCount() async throws {
        let fixture = try Self.makeFixture()
        let store = InsightsStore(
            queryFactory: { _ in Self.query(fixture) },
            ratingGapProvider: { _ in 4 }
        )
        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        #expect(store.unratedNightCount == 4)

        await store.load(rootURL: nil)

        #expect(store.unratedNightCount == 0)
    }

    @Test("A rating-gap read failure reports an honest zero, never blocking the trends themselves")
    func ratingGapFailureFallsBackToZero() async throws {
        struct BoomError: Error {}
        let fixture = try Self.makeFixture()
        let store = InsightsStore(
            queryFactory: { _ in Self.query(fixture) },
            ratingGapProvider: { _ in throw BoomError() }
        )

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.unratedNightCount == 0)
        #expect(store.snapshot != nil)
        #expect(store.errorMessage == nil)
    }
}
