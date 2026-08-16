@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct ArchiveMapQueryTests {
    /// Builds a throwaway index database with the exact column set
    /// `ArchiveMapQuery` reads, plus the `runs`/`findings` tables the
    /// reclaim and freshness queries need.
    private static func makeIndexDatabase(includeAuditTables: Bool = true) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveMap-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: path.path)
        try db.exec("""
            CREATE TABLE files(path TEXT, size INTEGER, target TEXT,
                               session_date TEXT, role TEXT, area TEXT, missing INTEGER);
            """)
        // NGC 7000: 2 nights, 300 bytes of light, 100 of stack, 100 of flat.
        try db.exec("""
            INSERT INTO files VALUES
              ('a.fit', 200, 'NGC_7000', '2026-08-01', 'light',  'sessions', 0),
              ('b.fit', 100, 'NGC_7000', '2026-08-02', 'light',  'sessions', 0),
              ('c.tif', 100, 'NGC_7000', '2026-08-02', 'stack',  'stacks',   0),
              ('d.fit', 100, 'NGC_7000', '2026-08-01', 'flat',   'sessions', 0),
              ('e.fit', 400, 'M42',      '2026-01-05', 'stack',  'stacks',   0),
              ('gone.fit', 9999, 'M42',  '2026-01-05', 'light',  'sessions', 1);
            """)
        // Two files the scanner could not attribute to any target -- the
        // shared calibration store. 500 bytes total, of which 250 (d2) is
        // flagged as a duplicate by the audit below.
        try db.exec("""
            INSERT INTO files VALUES
              ('calibration_library/darks/d1.fit', 250, NULL, NULL, 'dark', 'calibration', 0),
              ('calibration_library/darks/d2.fit', 250, NULL, NULL, 'dark', 'calibration', 0);
            """)
        if includeAuditTables {
            try db.exec("""
                CREATE TABLE runs(id INTEGER PRIMARY KEY, kind TEXT, started_at REAL);
                CREATE TABLE findings(id INTEGER PRIMARY KEY, run_id INTEGER, severity TEXT,
                                      category TEXT, path TEXT, message TEXT);
                """)
            try db.exec("INSERT INTO runs VALUES(1,'scan',1000.0),(2,'audit',2000.0);")
            try db.exec("""
                INSERT INTO findings VALUES
                  (1, 2, 'suspicious', 'residue', 'c.tif', 'leftover'),
                  (2, 2, 'suspicious', 'duplicate-content', 'e.fit', 'copy');
                """)
            try db.exec("""
                INSERT INTO findings VALUES
                  (3, 2, 'suspicious', 'duplicate-content', 'calibration_library/darks/d2.fit', 'copy');
                """)
        }
        return path
    }

    @Test("The snapshot totals only non-missing files and groups them by class")
    func totalsExcludeMissingFiles() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.totalBytes == 1400)
        #expect(snapshot.fileCount == 7)
        #expect(snapshot.targetCount == 2)
        #expect(snapshot.nightCount == 3)

        let light = try #require(snapshot.slices.first { $0.archiveClass == .light })
        #expect(light.bytes == 300)
        #expect(light.fileCount == 2)
        let stack = try #require(snapshot.slices.first { $0.archiveClass == .stack })
        #expect(stack.bytes == 500)
        // NGC_7000's flat (100) plus the untargeted darks (500) = 600.
        #expect(snapshot.slices.contains { $0.archiveClass == .calibration && $0.bytes == 600 })
        #expect(!snapshot.slices.contains { $0.archiveClass == .processed },
                "a class with no bytes produces no slice at all")
    }

    @Test("Target rows are sorted by size and carry their own night and class breakdown")
    func targetRowsAreSortedBySize() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        // NGC_7000 (500 bytes) and the untargeted bucket (500 bytes) tie;
        // the tiebreaker is ascending id, and "/untargeted" sorts before
        // "NGC_7000" because '/' precedes 'N' in ASCII.
        #expect(snapshot.rows.map(\.id) == ["/untargeted", "NGC_7000", "M42"])
        let ngc = try #require(snapshot.rows.first { $0.id == "NGC_7000" })
        #expect(ngc.totalBytes == 500)
        #expect(ngc.nightCount == 2)
        #expect(ngc.fileCount == 4)
        #expect(ngc.displayName == "NGC 7000")
        #expect(ngc.slices.map(\.archiveClass) == [.light, .stack, .calibration],
                "slices come back in ArchiveClass.displayOrder, dropping empty classes")
    }

    @Test("Reclaimable bytes come from the latest audit run's residue and duplicates")
    func reclaimableComesFromLatestAudit() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.reclaimableBytes == 750)
        #expect(snapshot.reclaimableFiles == 3)
        let m42 = try #require(snapshot.rows.first { $0.id == "M42" })
        #expect(m42.reclaimableBytes == 400)
        let ngc = try #require(snapshot.rows.first { $0.id == "NGC_7000" })
        #expect(ngc.reclaimableBytes == 100)
        let untargeted = try #require(snapshot.rows.first { $0.isUntargeted })
        #expect(untargeted.reclaimableBytes == 250)
    }

    @Test("A library whose index has no audit tables still renders a map")
    func missingAuditTablesStillProducesAMap() async throws {
        let index = try Self.makeIndexDatabase(includeAuditTables: false)
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.totalBytes == 1400)
        #expect(snapshot.reclaimableBytes == 0)
        #expect(snapshot.lastAuditAt == nil)
        #expect(!snapshot.isAuditStale, "no audit at all is not staleness -- it is its own state")
    }

    @Test("Files that belong to no target get their own row instead of vanishing")
    func untargetedFilesGetTheirOwnRow() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        let untargeted = try #require(snapshot.rows.first { $0.isUntargeted })
        #expect(untargeted.target == nil)
        #expect(untargeted.displayName == nil,
                "the untargeted row's name is translatable UI prose -- the view supplies it, not this query")
        #expect(untargeted.totalBytes == 500)
        #expect(untargeted.fileCount == 2)
        #expect(untargeted.nightCount == 0)
        #expect(untargeted.reclaimableBytes == 250)
        #expect(untargeted.slices.map(\.archiveClass) == [.calibration])
    }

    @Test("The header total is the whole library, and the rows add up to it")
    func rowsAddUpToTheHeaderTotal() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.totalBytes == 1400)
        #expect(snapshot.rows.reduce(0) { $0 + $1.totalBytes } == snapshot.totalBytes,
                "a byte in the library must appear in exactly one row")
        #expect(snapshot.fileCount == 7)
        #expect(snapshot.slices.reduce(0) { $0 + $1.bytes } == snapshot.totalBytes,
                "the strip must cover the same bytes the header claims")
    }

    @Test("Reclaimable totals reconcile between the header and the rows")
    func reclaimReconcilesBetweenHeaderAndRows() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.rows.reduce(0) { $0 + $1.reclaimableBytes } == snapshot.reclaimableBytes,
                "the rail's numerator must be the sum of what the rows show")
    }

    @Test("targetCount counts real targets, not the untargeted bucket")
    func targetCountExcludesTheUntargetedRow() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()
        #expect(snapshot.targetCount == 2)
        #expect(snapshot.rows.count == 3)
    }

    @Test("An audit older than the last scan is reported as stale")
    func auditOlderThanScanIsStale() async throws {
        // The audit row in `makeIndexDatabase` is stamped 2000.0 (epoch
        // seconds). V2 never writes a `scan` row to `runs` -- only
        // `MetadataStore.recordScanCompleted` marks a scan as done, so that
        // is what this test must go through to prove what the product
        // actually does (wave 6 Task 15).
        let index = try Self.makeIndexDatabase()
        let metadata = try MetadataStore.temporary()
        try await metadata.recordScanCompleted(at: Date(timeIntervalSince1970: 3000.0))

        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index, metadata: metadata).snapshot()
        #expect(snapshot.isAuditStale)
    }

    @Test("lastScanAt comes from the metadata store, even with no scan row in runs at all")
    func lastScanAtComesFromMetadataWithoutARunsScanRow() async throws {
        // Pins the bug this task fixes: a real library's `runs` table never
        // has a `scan` row (only `AuditEngine`/`FixityVerifier`/V1's
        // `AppState` write it), so `lastScanAt` must come from
        // `MetadataStore`, not `runs`.
        let index = try Self.makeIndexDatabase()
        let db = try SQLiteDB(path: index.path)
        try db.exec("DELETE FROM runs WHERE kind = 'scan';")
        let metadata = try MetadataStore.temporary()
        let completedAt = Date(timeIntervalSince1970: 5000.0)
        try await metadata.recordScanCompleted(at: completedAt)

        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index, metadata: metadata).snapshot()

        #expect(snapshot.lastScanAt != nil)
        #expect(abs((snapshot.lastScanAt ?? .distantPast).timeIntervalSince1970 - completedAt.timeIntervalSince1970) < 1)
    }

    @Test("lastScanAt is nil when there is no metadata store at all")
    func lastScanAtIsNilWithoutAMetadataStore() async throws {
        let index = try Self.makeIndexDatabase()

        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()

        #expect(snapshot.lastScanAt == nil)
    }

    @Test("lastVerifyAt is nil when the library has never had a verify run -- the ordinary case")
    func lastVerifyAtIsNilWithoutAVerifyRun() async throws {
        let index = try Self.makeIndexDatabase()
        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()
        #expect(snapshot.lastVerifyAt == nil)
    }

    @Test("lastVerifyAt reports the latest verify run's date once one exists")
    func lastVerifyAtReportsTheLatestVerifyRun() async throws {
        let index = try Self.makeIndexDatabase()
        let db = try SQLiteDB(path: index.path)
        try db.exec("INSERT INTO runs VALUES(4,'verify',4000.0);")

        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: index).snapshot()
        #expect(snapshot.lastVerifyAt == Date(timeIntervalSince1970: 4000))
    }

    @Test("An empty library produces an empty, non-throwing snapshot")
    func emptyLibrary() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveMapEmpty-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: path.path)
        try db.exec("""
            CREATE TABLE files(path TEXT, size INTEGER, target TEXT,
                               session_date TEXT, role TEXT, area TEXT, missing INTEGER);
            """)

        let snapshot = try await ArchiveMapQuery(indexDatabaseForTesting: path).snapshot()
        #expect(snapshot.totalBytes == 0)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.slices.isEmpty)
    }
}
