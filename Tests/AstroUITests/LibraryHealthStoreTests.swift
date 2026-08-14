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

    @Test("Acknowledging and revoking each fire onLibraryFindingsChanged so the sidebar badge can refresh")
    func acknowledgeAndRevokeFireLibraryFindingsChanged() async throws {
        let fixture = try Self.makeFixture()
        let store = LibraryHealthStore(
            metadataFactory: { _ in fixture.metadata },
            queryFactory: { _, metadata in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata)
            }
        )
        await store.load(rootURL: fixture.root)
        let flatItem = try #require(store.snapshot?.items.first { $0.category == .flat })
        var changeCount = 0
        store.onLibraryFindingsChanged = { changeCount += 1 }

        await store.acknowledge(flatItem, note: "known gap")
        #expect(changeCount == 1)

        await store.revokeAcknowledgement(flatItem)
        #expect(changeCount == 2)
    }

    @Test("Running a full audit records history and refreshes the snapshot with a success toast")
    func runAuditRecordsHistoryAndRefreshes() async throws {
        let fixture = try Self.makeFixture()
        let store = LibraryHealthStore(
            metadataFactory: { _ in fixture.metadata },
            queryFactory: { _, metadata in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata)
            },
            auditCommandFactory: { _, metadata in
                AuditRunCommand(db: fixture.db, config: fixture.config, metadata: metadata)
            }
        )
        await store.load(rootURL: fixture.root)
        #expect(store.snapshot?.auditRuns.isEmpty == true)
        let host = OperationHost(center: OperationCenter())

        await store.runAudit(mode: .full, rootURL: fixture.root, operationHost: host)
        try await waitUntil { host.activeOperations.isEmpty }

        #expect(host.toasts.contains { $0.level == .success })
        #expect(store.snapshot?.auditRuns.count == 1)
        #expect((try? await fixture.metadata.auditRunHistory().count) == 1)
    }

    @Test("Running an audit with no library open notifies instead of crashing")
    func runAuditWithNoLibraryOpenNoOps() async throws {
        let store = LibraryHealthStore(
            metadataFactory: { _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled },
            queryFactory: { _, _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled },
            auditCommandFactory: { _, _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled }
        )
        let host = OperationHost(center: OperationCenter())

        await store.runAudit(mode: .full, rootURL: nil, operationHost: host)

        #expect(host.activeOperations.isEmpty)
        #expect(host.toasts.contains { $0.level == .info })
    }

    @Test("Verifying integrity fills missing checksums and records the last summary")
    func verifyIntegrityFillsMissingChecksumsAndRecordsSummary() async throws {
        let fixture = try Self.makeFixture()
        let store = LibraryHealthStore(
            metadataFactory: { _ in fixture.metadata },
            queryFactory: { _, metadata in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata)
            },
            auditCommandFactory: { _, metadata in
                AuditRunCommand(db: fixture.db, config: fixture.config, metadata: metadata)
            }
        )
        await store.load(rootURL: fixture.root)
        let host = OperationHost(center: OperationCenter())

        await store.verifyIntegrity(
            options: VerifyRunOptions(sampleFraction: nil, fillMissingChecksums: true),
            rootURL: fixture.root,
            operationHost: host
        )
        try await waitUntil { host.activeOperations.isEmpty }

        #expect(host.toasts.contains { $0.level == .success })
        #expect(store.lastVerifySummary?.checked == 1)
        #expect(store.lastVerifySummary?.ok == 1)
    }

    @Test("Verifying integrity with no library open notifies instead of crashing")
    func verifyIntegrityWithNoLibraryOpenNoOps() async throws {
        let store = LibraryHealthStore(
            metadataFactory: { _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled },
            queryFactory: { _, _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled },
            auditCommandFactory: { _, _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled }
        )
        let host = OperationHost(center: OperationCenter())

        await store.verifyIntegrity(
            options: VerifyRunOptions(sampleFraction: nil, fillMissingChecksums: false),
            rootURL: nil,
            operationHost: host
        )

        #expect(host.activeOperations.isEmpty)
        #expect(host.toasts.contains { $0.level == .info })
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

    private struct Fixture {
        let root: URL
        let indexDatabase: URL
        let db: Database
        let config: AstroConfig
        let metadata: MetadataStore
    }

    /// Builds a real, scanned fixture library (via `LibraryScanner`, the same
    /// full `Database` schema production code uses) rather than a hand-rolled
    /// `files` table -- `AuditRunCommand` needs the real schema
    /// (`fits_meta`/`findings`/`runs`), and `LibraryHealthQuery`'s own raw SQL
    /// reads the exact same `files` columns either way.
    private static func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AstroHealthStore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = LibraryIdentity(rootURL: root)
        let support = root.deletingLastPathComponent().appendingPathComponent("AstroHealthStoreSupport-\(UUID())")
        let caches = root.deletingLastPathComponent().appendingPathComponent("AstroHealthStoreCaches-\(UUID())")
        let storage = try AppStoragePaths(applicationSupport: support, caches: caches, libraryID: identity, libraryRoot: root)
        try FileManager.default.createDirectory(at: storage.indexDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)

        var config = AstroConfig()
        config.rootPath = root.path
        let db = try Database(path: storage.indexDatabase.path)

        let lightURL = root.appendingPathComponent("sessions/IC_1396/2026-08-08/lights/light.fit")
        try FileManager.default.createDirectory(at: lightURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("light".utf8).write(to: lightURL)

        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()

        let metadata = try MetadataStore.temporary()
        return Fixture(root: root, indexDatabase: storage.indexDatabase, db: db, config: config, metadata: metadata)
    }
}

private enum LibraryHealthStoreTestFailure: Error, Equatable {
    case shouldNotBeCalled
}
