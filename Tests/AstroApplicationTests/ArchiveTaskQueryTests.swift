@testable import AstroApplication
import AstroCore
import Foundation
import Testing

struct ArchiveTaskQueryTests {
    private static func makeIndexDatabase(withFindings: Bool = true) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArchiveTasks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("index.sqlite")
        let db = try SQLiteDB(path: path.path)
        try db.exec("""
            CREATE TABLE files(path TEXT, size INTEGER, target TEXT,
                               session_date TEXT, role TEXT, area TEXT, missing INTEGER);
            CREATE TABLE runs(id INTEGER PRIMARY KEY, kind TEXT, started_at REAL);
            CREATE TABLE findings(id INTEGER PRIMARY KEY, run_id INTEGER, severity TEXT,
                                  category TEXT, path TEXT, message TEXT);
            """)
        try db.exec("""
            INSERT INTO files VALUES
              ('r_pp_a.fit', 1000, 'M42', '2026-01-05', 'other', 'sessions', 0),
              ('r_pp_b.fit', 2000, 'M42', '2026-01-05', 'other', 'sessions', 0),
              ('dupe.fit',    500, 'M42', '2026-01-05', 'dark',  'calibration', 0),
              ('flats/x.tif', 300, 'C2025', '2026-04-18', 'other', 'sessions', 0);
            """)
        try db.exec("INSERT INTO runs VALUES(1,'scan',1000.0),(2,'audit',2000.0);")
        if withFindings {
            try db.exec("""
                INSERT INTO findings VALUES
                  (1, 2, 'suspicious', 'residue', 'r_pp_a.fit', 'leftover'),
                  (2, 2, 'suspicious', 'residue', 'r_pp_b.fit', 'leftover'),
                  (3, 2, 'suspicious', 'duplicate-content', 'dupe.fit', 'copy'),
                  (4, 2, 'sure_error', 'calib-in-wrong-dir', 'flats/x.tif', 'not a flat');
                """)
        }
        return path
    }

    @Test("Findings collapse into one card per kind, never one row per finding")
    func findingsCollapseIntoCards() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()

        #expect(tasks.count == 3)
        let intermediates = try #require(tasks.first { $0.kind == .intermediateFiles })
        #expect(intermediates.affectedFileCount == 2)
        #expect(intermediates.bytes == 3000)
        #expect(intermediates.severity == .reclaim)
        #expect(intermediates.evidencePaths == ["r_pp_a.fit", "r_pp_b.fit"])

        let duplicates = try #require(tasks.first { $0.kind == .duplicateContent })
        #expect(duplicates.bytes == 500)

        let misplaced = try #require(tasks.first { $0.kind == .misplacedCalibration })
        #expect(misplaced.severity == .error)
        #expect(misplaced.action == .revealInFinder(path: "flats/x.tif"))
    }

    @Test("Cards are ordered errors first, then by reclaimable size")
    func cardsAreOrderedBySeverityThenSize() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()

        #expect(tasks.map(\.kind) == [.misplacedCalibration, .intermediateFiles, .duplicateContent])
    }

    @Test("At most three evidence paths are carried, however many findings there are")
    func evidenceIsCappedAtThree() async throws {
        let index = try Self.makeIndexDatabase()
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
            INSERT INTO files VALUES('r_pp_c.fit', 10, 'M42', '2026-01-05', 'other', 'sessions', 0),
                                    ('r_pp_d.fit', 10, 'M42', '2026-01-05', 'other', 'sessions', 0);
            INSERT INTO findings VALUES(5, 2, 'suspicious', 'residue', 'r_pp_c.fit', 'leftover'),
                                       (6, 2, 'suspicious', 'residue', 'r_pp_d.fit', 'leftover');
            """)

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()
        let intermediates = try #require(tasks.first { $0.kind == .intermediateFiles })
        #expect(intermediates.affectedFileCount == 4)
        #expect(intermediates.evidencePaths.count == 3)
    }

    @Test("A library that was never audited gets exactly one honest card")
    func neverAuditedProducesTheAuditCard() async throws {
        let index = try Self.makeIndexDatabase(withFindings: false)
        let db = try SQLiteDB(path: index.path)
        try db.exec("DELETE FROM runs WHERE kind = 'audit';")

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()
        #expect(tasks.map(\.kind) == [.auditNeverRun])
        #expect(tasks[0].severity == .info)
        #expect(tasks[0].action == .runAudit)
    }

    @Test("An audited, clean library produces no cards at all")
    func cleanLibraryProducesNoCards() async throws {
        let index = try Self.makeIndexDatabase(withFindings: false)
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()
        #expect(tasks.isEmpty)
    }

    @Test("Acknowledged groups are dropped from the cards")
    func acknowledgedGroupsAreDropped() async throws {
        let index = try Self.makeIndexDatabase()
        let metadata = try MetadataStore.temporary()
        try await metadata.acknowledgeFindingGroup(
            category: "archive-task", groupKey: ArchiveTaskKind.duplicateContent.rawValue, note: nil
        )

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index, metadata: metadata).tasks()
        #expect(!tasks.contains { $0.kind == .duplicateContent })
        #expect(tasks.contains { $0.kind == .intermediateFiles })
    }

    @Test("Every produced card carries an executable action")
    func everyCardIsActionable() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).tasks()
        #expect(!tasks.isEmpty)
        for task in tasks {
            #expect(task.action != .unavailable, "\(task.kind) produced a card with no action")
        }
    }
}
