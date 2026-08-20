@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct LibraryHealthQueryTests {
    @Test("Health summary separates actionable calibration issues")
    func fixtureHealthSummary() async throws {
        let snapshot = try await LibraryHealthQuery.fixture().snapshot()

        #expect(snapshot.sessionCount == 1)
        #expect(snapshot.calibrationIssues == 2)
        #expect(snapshot.items.contains { $0.category == .flat && $0.severity == .warning })
        #expect(snapshot.isReadOnly)
    }

    @Test("Production health reads the external index without touching source files")
    func productionIndexSnapshot() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AstroHealth-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = LibraryIdentity(rootURL: root)
        let support = root.deletingLastPathComponent().appendingPathComponent("AstroHealthSupport-\(UUID())")
        let caches = root.deletingLastPathComponent().appendingPathComponent("AstroHealthCaches-\(UUID())")
        defer { try? FileManager.default.removeItem(at: support); try? FileManager.default.removeItem(at: caches) }
        let storage = try AppStoragePaths(applicationSupport: support, caches: caches, libraryID: identity, libraryRoot: root)
        try FileManager.default.createDirectory(at: storage.indexDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(path: storage.indexDatabase.path)
        try db.exec("CREATE TABLE files(path TEXT, target TEXT, session_date TEXT, role TEXT, area TEXT, missing INTEGER, content_hash TEXT, size INTEGER);")
        try db.exec("INSERT INTO files VALUES('light.fit','IC_1396','2026-08-08','light','sessions',0,'same',100);")
        try db.exec("INSERT INTO files VALUES('copy.fit','IC_1396','2026-08-08','light','sessions',0,'same',100);")
        try db.exec("INSERT INTO files VALUES('.DS_Store',NULL,NULL,'other','other',0,NULL,40);")

        let snapshot = try await LibraryHealthQuery(indexDatabaseForTesting: storage.indexDatabase).snapshot()
        #expect(snapshot.sessionCount == 1)
        #expect(snapshot.calibrationIssues == 2)
        #expect(snapshot.duplicateFiles == 1)
        #expect(snapshot.organizationIssues == 1)
        #expect(snapshot.items.contains { $0.category == .duplicates })
        #expect(snapshot.items.contains { $0.category == .organization })
        // V2 product/UX audit (2026-08-15) section 3(c) cheap fix: a
        // duplicate finding used to say "N identical files" with no path at
        // all -- there was no way to learn which files.
        let duplicate = try #require(snapshot.items.first { $0.category == .duplicates })
        #expect(duplicate.detail.contains("light.fit"))
        #expect(duplicate.detail.contains("copy.fit"))
        let flat = try #require(snapshot.items.first { $0.category == .flat })
        #expect(flat.target == "IC_1396")
        #expect(flat.sessionDate == "2026-08-08")
        #expect(snapshot.items.contains { $0.category == .dark && $0.sessionDate == "2026-08-08" })
        #expect(snapshot.isReadOnly)
        #expect(!flat.isAcknowledged)
    }

    @Test("Acknowledged findings are hidden by default and shown on request")
    func acknowledgedFindingsAreHiddenByDefault() async throws {
        let indexDatabase = try Self.makeIndexDatabase()
        let metadata = try MetadataStore.temporary()
        let query = LibraryHealthQuery(indexDatabaseForTesting: indexDatabase, metadata: metadata)
        let hiddenSnapshot = try await query.snapshot()
        let flatItem = try #require(hiddenSnapshot.items.first { $0.category == .flat })

        try await metadata.acknowledgeFindingGroup(category: flatItem.ackCategory, groupKey: flatItem.ackGroupKey, note: "known gap")

        let afterAck = try await query.snapshot()
        #expect(!afterAck.items.contains { $0.id == flatItem.id })

        let includingAcked = try await query.snapshot(includeAcknowledged: true)
        let ackedFlat = try #require(includingAcked.items.first { $0.id == flatItem.id })
        #expect(ackedFlat.isAcknowledged)

        try await metadata.revokeAcknowledgement(ackKey: MetadataStore.ackKey(category: flatItem.ackCategory, groupKey: flatItem.ackGroupKey))
        let afterRevoke = try await query.snapshot()
        #expect(afterRevoke.items.contains { $0.id == flatItem.id && !$0.isAcknowledged })
    }

    @Test("The snapshot surfaces recent audit-run summaries with new and resolved counts")
    func snapshotSurfacesAuditRunSummaries() async throws {
        let indexDatabase = try Self.makeIndexDatabase()
        let metadata = try MetadataStore.temporary()
        try await metadata.recordAuditRun(
            findingCount: 2, groupKeys: ["dark|A", "flat|B"],
            at: Date(timeIntervalSince1970: 1_786_400_000)
        )
        try await metadata.recordAuditRun(
            findingCount: 2, groupKeys: ["dark|A", "duplicate|C"],
            at: Date(timeIntervalSince1970: 1_786_500_000)
        )
        let query = LibraryHealthQuery(indexDatabaseForTesting: indexDatabase, metadata: metadata)

        let snapshot = try await query.snapshot()

        #expect(snapshot.auditRuns.count == 2)
        #expect(snapshot.auditRuns[0].findingCount == 2)
        #expect(snapshot.auditRuns[0].newCount == 1)
        #expect(snapshot.auditRuns[0].resolvedCount == 1)
        #expect(snapshot.auditRuns[1].newCount == 2)
        #expect(snapshot.auditRuns[1].resolvedCount == 0)
    }

    // V2 product/UX audit (2026-08-15) section 3(a), CRITICAL: `isReadOnly`
    // used to be hardcoded `true` no matter what -- Health always claimed
    // "Read only" even with write operations enabled elsewhere.

    @Test("isReadOnly reflects the access mode the caller passed, not a hardcoded value")
    func isReadOnlyReflectsAccessMode() async throws {
        let indexDatabase = try Self.makeIndexDatabase()

        let readOnly = try await LibraryHealthQuery(indexDatabaseForTesting: indexDatabase).snapshot()
        #expect(readOnly.isReadOnly)

        let writable = try await LibraryHealthQuery(indexDatabaseForTesting: indexDatabase, accessMode: .mutationEnabled).snapshot()
        #expect(!writable.isReadOnly)
    }

    // V2 product/UX audit (2026-08-15) section 3(b), CRITICAL: `readSnapshot`
    // never emitted a real integrity-mismatch finding at all -- a verify run
    // that found corruption produced a generic success toast and nothing
    // else, while Health kept showing its one hardcoded "healthy" item.

    @Test("A prior verify run's mismatch becomes a real, non-healthy integrity finding")
    func verifyMismatchBecomesIntegrityFinding() async throws {
        let indexDatabase = try Self.makeIndexDatabase()
        let db = try SQLiteDB(path: indexDatabase.path)
        try db.exec(
            """
            CREATE TABLE runs(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, started_at REAL NOT NULL, finished_at REAL, root TEXT NOT NULL, config_json TEXT);
            CREATE TABLE findings(id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, severity TEXT NOT NULL, category TEXT NOT NULL, path TEXT NOT NULL, message TEXT NOT NULL, suggestion_json TEXT);
            """
        )
        try db.exec("INSERT INTO runs(id, kind, started_at, finished_at, root) VALUES (1, 'verify', 100, 200, '/tmp');")
        try db.exec(
            "INSERT INTO findings(run_id, severity, category, path, message) VALUES (1, 'sure_error', 'content-changed', 'sessions/IC_1396/2026-08-08/lights/light.fit', 'a fájl tartalma megváltozott');"
        )

        let snapshot = try await LibraryHealthQuery(indexDatabaseForTesting: indexDatabase).snapshot()

        let mismatch = try #require(snapshot.items.first { $0.category == .integrity && $0.severity == .critical })
        #expect(mismatch.detail.contains("light.fit"))
        #expect(!snapshot.items.contains { $0.category == .integrity && $0.severity == .healthy })
    }

    @Test("No verify run yet keeps the reassuring healthy integrity item")
    func noVerifyRunKeepsHealthyIntegrityItem() async throws {
        let indexDatabase = try Self.makeIndexDatabase()

        let snapshot = try await LibraryHealthQuery(indexDatabaseForTesting: indexDatabase).snapshot()

        #expect(snapshot.items.contains { $0.category == .integrity && $0.severity == .healthy })
    }

    private static func makeIndexDatabase() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AstroHealth-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = LibraryIdentity(rootURL: root)
        let support = root.deletingLastPathComponent().appendingPathComponent("AstroHealthSupport-\(UUID())")
        let caches = root.deletingLastPathComponent().appendingPathComponent("AstroHealthCaches-\(UUID())")
        let storage = try AppStoragePaths(applicationSupport: support, caches: caches, libraryID: identity, libraryRoot: root)
        try FileManager.default.createDirectory(at: storage.indexDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(path: storage.indexDatabase.path)
        try db.exec("CREATE TABLE files(path TEXT, target TEXT, session_date TEXT, role TEXT, area TEXT, missing INTEGER, content_hash TEXT, size INTEGER);")
        try db.exec("INSERT INTO files VALUES('light.fit','IC_1396','2026-08-08','light','sessions',0,'same',100);")
        return storage.indexDatabase
    }
}
