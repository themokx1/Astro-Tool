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
            queryFactory: { _, metadata, _ in
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
            queryFactory: { _, metadata, _ in
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
            queryFactory: { _, metadata, _ in
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
            queryFactory: { _, metadata, _ in
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
        await host.settle()

        #expect(host.toasts.contains { $0.level == .success })
        #expect(store.snapshot?.auditRuns.count == 1)
        #expect((try? await fixture.metadata.auditRunHistory().count) == 1)
    }

    @Test("Running an audit with no library open notifies instead of crashing")
    func runAuditWithNoLibraryOpenNoOps() async throws {
        let store = LibraryHealthStore(
            metadataFactory: { _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled },
            queryFactory: { _, _, _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled },
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
            queryFactory: { _, metadata, _ in
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
        await host.settle()

        #expect(host.toasts.contains { $0.level == .success })
        #expect(store.lastVerifySummary?.checked == 1)
        #expect(store.lastVerifySummary?.ok == 1)
    }

    // V2 product/UX audit (2026-08-15) section 3(a), CRITICAL: `load` used to
    // ignore access mode entirely -- Health always reported "Read only".

    @Test("Loading with mutation-enabled access mode makes the snapshot report writable")
    func loadingWithMutationEnabledReportsWritable() async throws {
        let fixture = try Self.makeFixture()
        let store = LibraryHealthStore(
            metadataFactory: { _ in fixture.metadata },
            queryFactory: { _, metadata, accessMode in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata, accessMode: accessMode)
            }
        )

        await store.load(rootURL: fixture.root, accessMode: .mutationEnabled)

        #expect(store.accessMode == .mutationEnabled)
        #expect(store.snapshot?.isReadOnly == false)
    }

    // V2 product/UX audit (2026-08-15) section 3(b), CRITICAL: a verify run
    // that actually found a mismatch used to leave the findings table
    // showing only the generic "healthy" placeholder -- this proves the
    // mismatch this test manufactures becomes a real, visible finding after
    // the store refreshes.

    @Test("A detected mismatch on re-verify becomes a visible integrity finding in the snapshot")
    func detectedMismatchBecomesVisibleFinding() async throws {
        let fixture = try Self.makeFixture()
        let store = LibraryHealthStore(
            metadataFactory: { _ in fixture.metadata },
            queryFactory: { _, metadata, accessMode in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata, accessMode: accessMode)
            },
            auditCommandFactory: { _, metadata in
                AuditRunCommand(db: fixture.db, config: fixture.config, metadata: metadata)
            }
        )
        await store.load(rootURL: fixture.root)
        let host = OperationHost(center: OperationCenter())

        // Establish a baseline hash for the one tracked file first.
        await store.verifyIntegrity(
            options: VerifyRunOptions(sampleFraction: nil, fillMissingChecksums: true),
            rootURL: fixture.root,
            operationHost: host
        )
        await host.settle()
        #expect(!(store.snapshot?.items.contains { $0.category == .integrity && $0.severity != .healthy } ?? true))

        // Now change the file's content and size -- both its recorded size
        // and mtime will disagree with what's on disk, which
        // `FixityVerifier` classifies as `.modified`.
        let lightURL = fixture.root.appendingPathComponent("sessions/IC_1396/2026-08-08/lights/light.fit")
        try Data("a very different, much longer light frame payload".utf8).write(to: lightURL)

        await store.verifyIntegrity(
            options: VerifyRunOptions(sampleFraction: nil, fillMissingChecksums: false),
            rootURL: fixture.root,
            operationHost: host
        )
        await host.settle()

        let finding = try #require(store.snapshot?.items.first { $0.category == .integrity && $0.severity != .healthy })
        #expect(finding.detail.contains("light.fit"))
    }

    @Test("Verifying integrity with no library open notifies instead of crashing")
    func verifyIntegrityWithNoLibraryOpenNoOps() async throws {
        let store = LibraryHealthStore(
            metadataFactory: { _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled },
            queryFactory: { _, _, _ in throw LibraryHealthStoreTestFailure.shouldNotBeCalled },
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

    // MARK: - v5 library-switch fixes, item 3: this store used to open its
    // OWN `MetadataStore` in `load`/`runAudit`/`verifyIntegrity`. That is a
    // second (third, fourth) confined SQLite connection to a database
    // `AppModel.currentMetadataStore`'s own doc comment says "is meant to
    // have one owner at a time", competing with `ProjectsStore`'s with
    // nothing but `busy_timeout` between them.

    @Test("load reuses the window's already-open metadata store instead of opening its own")
    func loadPrefersTheSharedMetadataStore() async throws {
        let fixture = try Self.makeFixture()
        let calls = MetadataFactoryCallCounter()
        let store = LibraryHealthStore(
            metadataFactory: { _ in
                calls.count += 1
                return fixture.metadata
            },
            queryFactory: { _, metadata, _ in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata)
            }
        )
        let root = fixture.root.standardizedFileURL
        store.sharedMetadataProvider = { asked in asked == root ? fixture.metadata : nil }

        await store.load(rootURL: fixture.root)

        #expect(store.snapshot != nil)
        #expect(calls.count == 0, "the already-open connection must be reused, not a second one opened")
    }

    @Test("A root the shared provider does not own still falls back to this store's own factory")
    func loadFallsBackWhenNoSharedStoreIsOpenForThisRoot() async throws {
        let fixture = try Self.makeFixture()
        let calls = MetadataFactoryCallCounter()
        let store = LibraryHealthStore(
            metadataFactory: { _ in
                calls.count += 1
                return fixture.metadata
            },
            queryFactory: { _, metadata, _ in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata)
            }
        )
        // The window's store is open for some OTHER library -- exactly the
        // mid-switch state where reusing it would answer for the wrong root.
        store.sharedMetadataProvider = { _ in nil }

        await store.load(rootURL: fixture.root)

        #expect(store.snapshot != nil)
        #expect(calls.count == 1)
    }

    @Test("runAudit and verifyIntegrity reuse the shared metadata store too")
    func auditAndVerifyPreferTheSharedMetadataStore() async throws {
        let fixture = try Self.makeFixture()
        let calls = MetadataFactoryCallCounter()
        let store = LibraryHealthStore(
            metadataFactory: { _ in
                calls.count += 1
                return fixture.metadata
            },
            queryFactory: { _, metadata, _ in
                LibraryHealthQuery(indexDatabaseForTesting: fixture.indexDatabase, metadata: metadata)
            },
            auditCommandFactory: { _, metadata in
                AuditRunCommand(db: fixture.db, config: fixture.config, metadata: metadata)
            }
        )
        let root = fixture.root.standardizedFileURL
        store.sharedMetadataProvider = { asked in asked == root ? fixture.metadata : nil }
        let host = OperationHost(center: OperationCenter())

        await store.runAudit(mode: .full, rootURL: fixture.root, operationHost: host)
        await host.settle()
        await store.verifyIntegrity(
            options: VerifyRunOptions(sampleFraction: nil, fillMissingChecksums: true),
            rootURL: fixture.root,
            operationHost: host
        )
        await host.settle()

        #expect(store.snapshot?.auditRuns.count == 1)
        #expect(store.lastVerifySummary?.checked == 1)
        #expect(calls.count == 0)
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

/// Counts `LibraryHealthStore`'s own metadata-factory calls. A `@MainActor`
/// class rather than a captured `var`: the factory closure is
/// `@MainActor @Sendable`, so it can only capture something Sendable, and a
/// global-actor-isolated class is.
@MainActor
private final class MetadataFactoryCallCounter {
    var count = 0
}
