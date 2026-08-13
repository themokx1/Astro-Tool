@testable import AstroUI
@testable import AstroApplication
import AstroCore
import Foundation
import Testing

@MainActor
@Suite("V2 Library Health store")
struct LibraryHealthStoreTests {
    @Test("Loading a library populates the health snapshot")
    func loadingPopulatesSnapshot() async throws {
        let fixture = try Self.makeFixture()
        let store = LibraryHealthStore(
            metadataFactory: { _ in fixture.metadata },
            queryFactory: { _, metadata in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata)
            }
        )

        await store.load(rootURL: fixture.root)

        #expect(store.snapshot != nil)
        #expect(store.snapshot?.items.contains { $0.category == .flat } == true)
        #expect(store.errorMessage == nil)
    }

    @Test("Acknowledging a finding hides it by default and the toggle reveals it")
    func acknowledgeHidesAndToggleReveals() async throws {
        let fixture = try Self.makeFixture()
        let store = LibraryHealthStore(
            metadataFactory: { _ in fixture.metadata },
            queryFactory: { _, metadata in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata)
            }
        )
        await store.load(rootURL: fixture.root)
        let flatItem = try #require(store.snapshot?.items.first { $0.category == .flat })

        await store.acknowledge(flatItem, note: "known gap")

        #expect(store.snapshot?.items.contains { $0.id == flatItem.id } == false)

        await store.setShowAcknowledged(true)
        let ackedItem = try #require(store.snapshot?.items.first { $0.id == flatItem.id })
        #expect(ackedItem.isAcknowledged)

        await store.revokeAcknowledgement(flatItem)
        await store.setShowAcknowledged(false)
        let revoked = try #require(store.snapshot?.items.first { $0.id == flatItem.id })
        #expect(!revoked.isAcknowledged)
    }

    private struct Fixture {
        let root: URL
        let indexDatabase: URL
        let metadata: MetadataStore
    }

    private static func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AstroHealthStore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = LibraryIdentity(rootURL: root)
        let support = root.deletingLastPathComponent().appendingPathComponent("AstroHealthStoreSupport-\(UUID())")
        let caches = root.deletingLastPathComponent().appendingPathComponent("AstroHealthStoreCaches-\(UUID())")
        let storage = try AppStoragePaths(applicationSupport: support, caches: caches, libraryID: identity, libraryRoot: root)
        try FileManager.default.createDirectory(at: storage.indexDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(path: storage.indexDatabase.path)
        try db.exec("CREATE TABLE files(path TEXT, target TEXT, session_date TEXT, role TEXT, area TEXT, missing INTEGER, content_hash TEXT, size INTEGER);")
        try db.exec("INSERT INTO files VALUES('light.fit','IC_1396','2026-08-08','light','sessions',0,'same',100);")
        let metadata = try MetadataStore.temporary()
        return Fixture(root: root, indexDatabase: storage.indexDatabase, metadata: metadata)
    }
}
