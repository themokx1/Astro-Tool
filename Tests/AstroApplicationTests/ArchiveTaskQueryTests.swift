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
              ('flats/x.tif', 300, 'C2025', '2026-04-18', 'other', 'sessions', 0),
              ('rot.fit',     700, 'M42', '2026-01-05', 'light', 'sessions', 0),
              ('unread.fit',   50, 'M42', '2026-01-05', 'light', 'sessions', 0),
              ('edited.fit',   60, 'M42', '2026-01-05', 'light', 'sessions', 0);
            """)
        try db.exec("INSERT INTO runs VALUES(1,'scan',1000.0),(2,'audit',2000.0),(3,'verify',3000.0);")
        if withFindings {
            try db.exec("""
                INSERT INTO findings VALUES
                  (1, 2, 'suspicious', 'residue', 'r_pp_a.fit', 'leftover'),
                  (2, 2, 'suspicious', 'residue', 'r_pp_b.fit', 'leftover'),
                  (3, 2, 'suspicious', 'duplicate-content', 'dupe.fit', 'copy'),
                  (4, 2, 'sure_error', 'calib-in-wrong-dir', 'flats/x.tif', 'not a flat');
                """)
            try db.exec("""
                INSERT INTO findings VALUES
                  (10, 3, 'sure_error', 'content-changed',   'rot.fit',    'bitrot'),
                  (11, 3, 'suspicious', 'verify-read-error', 'unread.fit', 'unreadable'),
                  (12, 3, 'probably_intentional', 'modified', 'edited.fit', 'edited on purpose');
                """)
        }
        return path
    }

    @Test("Findings collapse into one card per kind, never one row per finding")
    func findingsCollapseIntoCards() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks

        #expect(tasks.count == 5)
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
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks

        #expect(tasks.map(\.kind) == [
            .corruption, .misplacedCalibration, .intermediateFiles, .duplicateContent, .unverified,
        ])
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

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks
        let intermediates = try #require(tasks.first { $0.kind == .intermediateFiles })
        #expect(intermediates.affectedFileCount == 4)
        #expect(intermediates.evidencePaths.count == 3)
    }

    @Test("A library that was never audited gets exactly one honest card")
    func neverAuditedProducesTheAuditCard() async throws {
        let index = try Self.makeIndexDatabase(withFindings: false)
        let db = try SQLiteDB(path: index.path)
        try db.exec("DELETE FROM runs WHERE kind = 'audit';")

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks
        #expect(tasks.map(\.kind) == [.auditNeverRun])
        #expect(tasks[0].severity == .info)
        #expect(tasks[0].action == .runAudit)
    }

    @Test("An audited, clean library produces no cards at all")
    func cleanLibraryProducesNoCards() async throws {
        let index = try Self.makeIndexDatabase(withFindings: false)
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks
        #expect(tasks.isEmpty)
    }

    @Test("Acknowledged groups are dropped from the cards")
    func acknowledgedGroupsAreDropped() async throws {
        let index = try Self.makeIndexDatabase()
        let metadata = try MetadataStore.temporary()
        try await metadata.acknowledgeFindingGroup(
            category: "archive-task", groupKey: ArchiveTaskKind.duplicateContent.rawValue, note: nil
        )

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index, metadata: metadata).summary().tasks
        #expect(!tasks.contains { $0.kind == .duplicateContent })
        #expect(tasks.contains { $0.kind == .intermediateFiles })
    }

    @Test("Every produced card carries an executable action")
    func everyCardIsActionable() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks
        #expect(!tasks.isEmpty)
        for task in tasks {
            #expect(task.action != .unavailable, "\(task.kind) produced a card with no action")
        }
    }

    @Test("Corruption from the latest verify run becomes its own card")
    func corruptionFromVerifyRunBecomesACard() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks

        let corruption = try #require(tasks.first { $0.kind == .corruption })
        #expect(corruption.severity == .error)
        #expect(corruption.affectedFileCount == 1)
        #expect(corruption.bytes == 700)
        #expect(corruption.evidencePaths == ["rot.fit"])
        #expect(corruption.action == .revealInFinder(path: "rot.fit"))
    }

    @Test("A file that could not be read is reported as unconfirmed, not as corruption")
    func unreadableFileIsNotReportedAsCorruption() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks

        let unconfirmed = try #require(tasks.first { $0.kind == .unverified })
        #expect(unconfirmed.severity == .attention)
        #expect(unconfirmed.evidencePaths == ["unread.fit"])
        #expect(!(try #require(tasks.first { $0.kind == .corruption }).evidencePaths.contains("unread.fit")))
    }

    @Test("A deliberately edited file raises nothing at all")
    func deliberatelyModifiedFileRaisesNothing() async throws {
        let index = try Self.makeIndexDatabase()
        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks

        #expect(!tasks.contains { $0.evidencePaths.contains("edited.fit") },
                "'modified' means the user changed the file on purpose -- alarming about it teaches the user to ignore cards")
    }

    @Test("Audit and verify findings are read from their own latest runs, independently")
    func auditAndVerifyRunsAreReadIndependently() async throws {
        let index = try Self.makeIndexDatabase()
        let db = try SQLiteDB(path: index.path)
        // A newer audit run must not hide the older verify run's findings.
        try db.exec("INSERT INTO runs VALUES(4,'audit',4000.0);")
        try db.exec("INSERT INTO findings VALUES(13, 4, 'suspicious', 'residue', 'r_pp_a.fit', 'leftover');")

        let tasks = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary().tasks
        #expect(tasks.contains { $0.kind == .corruption }, "the verify run's findings survive a newer audit run")
        let intermediates = try #require(tasks.first { $0.kind == .intermediateFiles })
        #expect(intermediates.affectedFileCount == 1, "only the LATEST audit run's residue counts")
    }

    // MARK: - Uncovered findings

    @Test("A finding whose category maps to no ArchiveTaskKind lands in uncovered, and produces no card")
    func unmappedCategoryLandsInUncovered() async throws {
        // The standard fixture's 'edited.fit' finding uses category 'modified',
        // deliberately distinct from '.unverified's "modified-in-place" -- it
        // maps to no ArchiveTaskKind at all.
        let index = try Self.makeIndexDatabase()
        let summary = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary()

        #expect(!summary.uncovered.isEmpty)
        #expect(summary.uncovered.count == 1)
        #expect(summary.uncovered.bytes == 60)
        #expect(summary.uncovered.categories == ["modified": 1])
        #expect(!summary.tasks.contains { $0.evidencePaths.contains("edited.fit") })
    }

    @Test("uncovered is empty when every finding's category maps to a card")
    func uncoveredIsEmptyWhenAllFindingsAreMapped() async throws {
        let index = try Self.makeIndexDatabase(withFindings: false)
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
            INSERT INTO findings VALUES
              (1, 2, 'suspicious', 'residue', 'r_pp_a.fit', 'leftover'),
              (2, 2, 'suspicious', 'duplicate-content', 'dupe.fit', 'copy');
            """)

        let summary = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary()
        #expect(summary.uncovered.isEmpty)
        #expect(summary.uncovered == .none)
    }

    @Test("The uncovered breakdown reports counts and bytes per unmapped category")
    func uncoveredBreakdownIsPerCategory() async throws {
        let index = try Self.makeIndexDatabase()
        let db = try SQLiteDB(path: index.path)
        try db.exec("""
            INSERT INTO files VALUES
              ('leftover1.fit', 100, 'M42', '2026-01-05', 'other', 'sessions', 0),
              ('leftover2.fit', 200, 'M42', '2026-01-05', 'other', 'sessions', 0);
            INSERT INTO findings VALUES
              (30, 2, 'suspicious', 'capture-unassigned-artifact', 'leftover1.fit', 'n/a'),
              (31, 2, 'suspicious', 'capture-unassigned-artifact', 'leftover2.fit', 'n/a');
            """)

        let summary = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary()
        #expect(summary.uncovered.categories["capture-unassigned-artifact"] == 2)
        #expect(summary.uncovered.categories["modified"] == 1,
                "the standard fixture's one unmapped 'modified' finding lands here too")
        #expect(summary.uncovered.count == 3)
        #expect(summary.uncovered.bytes == 100 + 200 + 60)
    }

    @Test("A card suppressed by acknowledgement or the actionability gate is not counted as uncovered")
    func suppressedCardsAreNotConflatedWithUncovered() async throws {
        let index = try Self.makeIndexDatabase()
        let db = try SQLiteDB(path: index.path)
        // A mapped category (brokenNames), but with no usable path -- the
        // actionability gate drops the card. That is suppression, not an
        // uncovered category, because the category DID map to a kind.
        try db.exec("""
            INSERT INTO findings VALUES
              (20, 2, 'sure_error', 'placeholder-name', '', 'no path to open');
            """)
        let metadata = try MetadataStore.temporary()
        try await metadata.acknowledgeFindingGroup(
            category: "archive-task", groupKey: ArchiveTaskKind.duplicateContent.rawValue, note: nil
        )

        let summary = try await ArchiveTaskQuery(indexDatabaseForTesting: index, metadata: metadata).summary()

        #expect(!summary.tasks.contains { $0.kind == .duplicateContent }, "acknowledged card is suppressed")
        #expect(!summary.tasks.contains { $0.kind == .brokenNames }, "actionability-gated card is suppressed")
        #expect(summary.uncovered.categories["duplicate-content"] == nil,
                "an acknowledged finding is suppressed, not uncovered")
        #expect(summary.uncovered.categories["placeholder-name"] == nil,
                "an actionability-gated finding is suppressed, not uncovered")
    }

    @Test("A library that was never audited reports no uncovered findings")
    func neverAuditedReportsNoUncoveredFindings() async throws {
        let index = try Self.makeIndexDatabase(withFindings: false)
        let db = try SQLiteDB(path: index.path)
        try db.exec("DELETE FROM runs WHERE kind = 'audit';")

        let summary = try await ArchiveTaskQuery(indexDatabaseForTesting: index).summary()
        #expect(summary.uncovered == .none)
    }
}
