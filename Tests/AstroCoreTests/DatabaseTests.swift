import Foundation
import Testing
@testable import AstroCore

// MARK: - SQLiteDB (thin wrapper)

@Test func sqliteDBOpensInMemoryAndExecutesDDL() throws {
    let db = try SQLiteDB(path: ":memory:")
    try db.exec("CREATE TABLE t(a INTEGER, b TEXT);")
    try db.run("INSERT INTO t(a, b) VALUES (?, ?);", bind: [.int(1), .text("hello")])

    var seenA: Int64?
    var seenB: String?
    try db.query("SELECT a, b FROM t;") { row in
        seenA = row.int64(0)
        seenB = row.string(1)
    }

    #expect(seenA == 1)
    #expect(seenB == "hello")
}

@Test func sqliteDBLastInsertRowIDTracksAutoIncrement() throws {
    let db = try SQLiteDB(path: ":memory:")
    try db.exec("CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT);")
    try db.run("INSERT INTO t(a) VALUES (?);", bind: [.text("x")])
    let firstID = db.lastInsertRowID
    try db.run("INSERT INTO t(a) VALUES (?);", bind: [.text("y")])
    let secondID = db.lastInsertRowID

    #expect(firstID == 1)
    #expect(secondID == 2)
}

@Test func sqliteDBBindsNullAndRealAndBlob() throws {
    let db = try SQLiteDB(path: ":memory:")
    try db.exec("CREATE TABLE t(n TEXT, r REAL, blb BLOB);")
    let payload = Data([0x01, 0x02, 0x03])
    try db.run("INSERT INTO t(n, r, blb) VALUES (?, ?, ?);", bind: [.null, .real(3.5), .blob(payload)])

    var gotN: String? = "not-nil"
    var gotR: Double?
    var gotBlob: Data?
    try db.query("SELECT n, r, blb FROM t;") { row in
        gotN = row.string(0)
        gotR = row.double(1)
        gotBlob = row.blob(2)
    }

    #expect(gotN == nil)
    #expect(gotR == 3.5)
    #expect(gotBlob == payload)
}

@Test func sqliteDBThrowsDatabaseErrorOnBadSQL() throws {
    let db = try SQLiteDB(path: ":memory:")
    #expect(throws: AstroError.self) {
        try db.exec("NOT VALID SQL AT ALL;")
    }
}

@Test func sqliteDBEnablesWALModeForFileBackedDatabases() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-db-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("test.sqlite").path

    let db = try SQLiteDB(path: path)
    var mode: String?
    try db.query("PRAGMA journal_mode;") { row in
        mode = row.string(0)
    }
    #expect(mode?.lowercased() == "wal")
}

// MARK: - Database migration

@Test func migrateSetsSchemaVersionToThreeForFreshDatabase() throws {
    let database = try Database(path: ":memory:")

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 3)
}

@Test func migrateIsIdempotentAndDoesNotDuplicateVersionRow() throws {
    let database = try Database(path: ":memory:")

    var rowCount = 0
    try database.db.query("SELECT version FROM schema_version;") { _ in rowCount += 1 }
    #expect(rowCount == 1)
}

@Test func migrateCreatesAllExpectedTables() throws {
    let database = try Database(path: ":memory:")

    let expectedTables = ["schema_version", "files", "fits_meta", "ratings", "findings", "runs", "tags"]
    var found: Set<String> = []
    try database.db.query("SELECT name FROM sqlite_master WHERE type = 'table';") { row in
        if let name = row.string(0) { found.insert(name) }
    }
    for table in expectedTables {
        #expect(found.contains(table))
    }
}

/// Simulates a real, already-deployed v1 database (schema created straight
/// from `Database.schemaSQLv1`, `schema_version` stamped `1`, one file row
/// inserted) via a raw `SQLiteDB` connection, then opens it through
/// `Database(path:)` -- the production upgrade path -- and verifies the v1
/// data survived, the version advanced to 2, and the new `tags` table
/// exists. This is the regression guard for "incremental migration must not
/// touch real v1 data".
@Test func migrateUpgradesExistingV1DatabaseToV2PreservingData() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v1.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.run("INSERT INTO schema_version(version) VALUES (1);")
        try raw.run(
            """
            INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text("sessions/M31/2026-01-01/lights/f1.fits"), .int(1024), .real(1_700_000_000),
                .text("fits"), .text("fits"), .text("sessions"), .text("M31"), .text("2026-01-01"),
                .text("light"), .null, .real(1_700_000_100), .int(0),
            ]
        )
    }

    let database = try Database(path: path)

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 3)

    let files = try database.allFiles(includeMissing: true)
    #expect(files.count == 1)
    #expect(files.first?.target == "M31")
    #expect(files.first?.path == "sessions/M31/2026-01-01/lights/f1.fits")
    #expect(files.first?.inode == nil)
    #expect(files.first?.nlink == nil)

    var tagsTableExists = false
    try database.db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'tags';") { _ in
        tagsTableExists = true
    }
    #expect(tagsTableExists)
}

/// Simulates an already-deployed v2 database (v1 schema + `schemaSQLv2`'s
/// `tags` table, `schema_version` stamped `2`, one file row inserted) via a
/// raw `SQLiteDB` connection, then opens it through `Database(path:)` and
/// verifies the v2 data survived, the version advanced to 3, and the new
/// `inode`/`nlink` columns exist (as `NULL` for the pre-existing row, since
/// `ALTER TABLE ADD COLUMN` never backfills existing rows).
@Test func migrateUpgradesExistingV2DatabaseToV3PreservingData() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v2.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.run("INSERT INTO schema_version(version) VALUES (2);")
        try raw.run(
            """
            INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text("sessions/M31/2026-01-01/lights/f1.fits"), .int(1024), .real(1_700_000_000),
                .text("fits"), .text("fits"), .text("sessions"), .text("M31"), .text("2026-01-01"),
                .text("light"), .null, .real(1_700_000_100), .int(0),
            ]
        )
    }

    let database = try Database(path: path)

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 3)

    let files = try database.allFiles(includeMissing: true)
    #expect(files.count == 1)
    #expect(files.first?.target == "M31")
    #expect(files.first?.inode == nil)
    #expect(files.first?.nlink == nil)
}

@Test func backfillInodeSetsOnlyInodeAndNlinkColumns() throws {
    let database = try Database(path: ":memory:")
    let id = try database.upsertFile(
        FileRecord(
            path: "sessions/M31/2026-01-01/lights/f1.fits", size: 10, mtime: 1, ext: "fits", kind: "fits",
            area: .sessions, target: "M31", sessionDate: "2026-01-01", role: .light, scannedAt: 1
        )
    )

    try database.backfillInode(id: id, inode: 12345, nlink: 2)

    let record = try #require(try database.file(path: "sessions/M31/2026-01-01/lights/f1.fits"))
    #expect(record.inode == 12345)
    #expect(record.nlink == 2)
    #expect(record.size == 10)
}

// MARK: - Database: files

private func sampleFile(path: String = "sessions/M31/2026-01-01/lights/f1.fits") -> FileRecord {
    FileRecord(
        path: path,
        size: 1024,
        mtime: 1_700_000_000,
        ext: "fits",
        kind: "fits",
        area: .sessions,
        target: "M31",
        sessionDate: "2026-01-01",
        role: .light,
        scannedAt: 1_700_000_100
    )
}

@Test func upsertFileInsertsAndReadsBackByPath() throws {
    let database = try Database(path: ":memory:")
    let record = sampleFile()

    let id = try database.upsertFile(record)
    #expect(id > 0)

    let fetched = try database.file(path: record.path)
    #expect(fetched != nil)
    #expect(fetched?.id == id)
    #expect(fetched?.path == record.path)
    #expect(fetched?.size == record.size)
    #expect(fetched?.mtime == record.mtime)
    #expect(fetched?.ext == record.ext)
    #expect(fetched?.kind == record.kind)
    #expect(fetched?.area == record.area)
    #expect(fetched?.target == record.target)
    #expect(fetched?.sessionDate == record.sessionDate)
    #expect(fetched?.role == record.role)
    #expect(fetched?.contentHash == record.contentHash)
    #expect(fetched?.scannedAt == record.scannedAt)
    #expect(fetched?.missing == record.missing)
}

@Test func fileIDReturnsNilForUnknownPath() throws {
    let database = try Database(path: ":memory:")
    #expect(try database.fileID(path: "does/not/exist.fits") == nil)
    #expect(try database.file(path: "does/not/exist.fits") == nil)
}

@Test func upsertFileByPathUpdatesRatherThanDuplicates() throws {
    let database = try Database(path: ":memory:")
    var record = sampleFile()

    let firstID = try database.upsertFile(record)

    record.size = 2048
    record.contentHash = "deadbeef"
    let secondID = try database.upsertFile(record)

    #expect(firstID == secondID)

    let all = try database.allFiles(includeMissing: true)
    #expect(all.count == 1)

    let fetched = try database.file(path: record.path)
    #expect(fetched?.size == 2048)
    #expect(fetched?.contentHash == "deadbeef")
}

@Test func allFilesIncludeMissingFalseFiltersOutMissingRows() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/a.fits"))
    _ = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/b.fits"))

    try database.markMissing(pathsNotIn: ["sessions/M31/2026-01-01/lights/b.fits"], underSubpath: nil)

    let visible = try database.allFiles(includeMissing: false)
    #expect(visible.count == 1)
    #expect(visible.first?.path == "sessions/M31/2026-01-01/lights/b.fits")

    let everything = try database.allFiles(includeMissing: true)
    #expect(everything.count == 2)
}

@Test func markMissingRespectsUnderSubpathScope() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/a.fits"))
    _ = try database.upsertFile(sampleFile(path: "sessions/M42/2026-01-02/lights/b.fits"))

    // Nothing present anywhere, but only M31 subtree should be affected.
    try database.markMissing(pathsNotIn: [], underSubpath: "sessions/M31")

    let m31 = try database.file(path: "sessions/M31/2026-01-01/lights/a.fits")
    let m42 = try database.file(path: "sessions/M42/2026-01-02/lights/b.fits")

    #expect(m31?.missing == true)
    #expect(m42?.missing == false)
}

@Test func markMissingDoesNotAffectAlreadyMissingFilesAgainAndCanBeCalledRepeatedly() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/a.fits"))

    try database.markMissing(pathsNotIn: [], underSubpath: nil)
    try database.markMissing(pathsNotIn: [], underSubpath: nil)

    let f = try database.file(path: "sessions/M31/2026-01-01/lights/a.fits")
    #expect(f?.missing == true)
}

// MARK: - Database: fits_meta

@Test func upsertAndFetchFITSMetaRoundTrips() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())

    let meta = FITSMetaRecord(
        fileID: fileID,
        exptime: 300.0,
        gain: 100,
        offset: 10,
        setTemp: -10,
        ccdTemp: -9.8,
        instrume: "ZWO ASI2600MM",
        focallen: 750,
        filter: "Ha",
        dateObs: "2026-01-01T22:00:00",
        imagetyp: "LIGHT",
        naxis1: 6248,
        naxis2: 4176,
        headerJSON: "{\"NAXIS\":2}"
    )
    try database.upsertFITSMeta(meta)

    let fetched = try database.fitsMeta(fileID: fileID)
    #expect(fetched == meta)
}

@Test func fitsMetaReturnsNilWhenAbsent() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    #expect(try database.fitsMeta(fileID: fileID) == nil)
}

@Test func upsertFITSMetaUpdatesExistingRow() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())

    try database.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: 120))
    try database.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: 240, filter: "OIII"))

    let fetched = try database.fitsMeta(fileID: fileID)
    #expect(fetched?.exptime == 240)
    #expect(fetched?.filter == "OIII")
}

// MARK: - Database: runs & findings

@Test func beginRunFinishRunAndInsertFindingRoundTrip() throws {
    let database = try Database(path: ":memory:")
    let runID = try database.beginRun(kind: "audit", root: "/Volumes/images/Astro", configJSON: "{}")
    #expect(runID > 0)

    let finding = Finding(
        severity: .suspicious,
        category: "placeholder-name",
        path: "sessions/M31/2026-01-01/lights/img_001.fits",
        message: "looks like a default camera filename",
        suggestion: .rename(from: "img_001.fits", to: "M31_2026-01-01_001.fits")
    )
    try database.insertFinding(runID: runID, finding)

    let findings = try database.findings(runID: runID)
    #expect(findings == [finding])

    try database.finishRun(id: runID)
}

@Test func findingsFiltersByRunID() throws {
    let database = try Database(path: ":memory:")
    let run1 = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)
    let run2 = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)

    let f1 = Finding(severity: .sureError, category: "orphan-calib-dir", path: "a", message: "m1")
    let f2 = Finding(severity: .probablyIntentional, category: "other", path: "b", message: "m2")

    try database.insertFinding(runID: run1, f1)
    try database.insertFinding(runID: run2, f2)

    #expect(try database.findings(runID: run1) == [f1])
    #expect(try database.findings(runID: run2) == [f2])
}

@Test func insertFindingWithNoSuggestionRoundTrips() throws {
    let database = try Database(path: ":memory:")
    let runID = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)
    let finding = Finding(severity: .suspicious, category: "cat", path: "p", message: "m")
    try database.insertFinding(runID: runID, finding)

    let fetched = try database.findings(runID: runID)
    #expect(fetched == [finding])
    #expect(fetched.first?.suggestion == nil)
}

// MARK: - Database: ratings

private func sampleRating(fileID: Int64, inputSig: String = "sig-1") -> RatingRecord {
    RatingRecord(
        fileID: fileID,
        fwhm: 2.4,
        roundness: 0.92,
        starCount: 850,
        background: 120.5,
        saturatedFraction: 0.001,
        score: 0.87,
        ratedAt: 1_700_000_200,
        sirilVersion: "1.2.0",
        inputSig: inputSig
    )
}

@Test func upsertRatingInsertsAndReadsBack() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    let rating = sampleRating(fileID: fileID)

    try database.upsertRating(rating)

    let fetched = try database.rating(fileID: fileID)
    #expect(fetched == rating)
}

@Test func upsertRatingKeyedByInputSigOverwritesOnRerate() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())

    try database.upsertRating(sampleRating(fileID: fileID, inputSig: "sig-1"))
    let updated = sampleRating(fileID: fileID, inputSig: "sig-2")
    var changed = updated
    changed.score = 0.42
    try database.upsertRating(changed)

    let fetched = try database.rating(fileID: fileID)
    #expect(fetched?.inputSig == "sig-2")
    #expect(fetched?.score == 0.42)

    // still exactly one rating row for this file
    var count = 0
    try database.db.query("SELECT file_id FROM ratings WHERE file_id = ?;", bind: [.int(fileID)]) { _ in count += 1 }
    #expect(count == 1)
}

@Test func ratingReturnsNilWhenAbsent() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    #expect(try database.rating(fileID: fileID) == nil)
}

// MARK: - Database: tags

@Test func addTargetLevelTagThenListsIt() throws {
    let database = try Database(path: ":memory:")
    try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"))

    #expect(try database.tags(target: "M31", sessionDate: nil) == ["favorite"])
}

@Test func addSessionLevelTagIsScopedToThatDateOnly() throws {
    let database = try Database(path: ":memory:")
    try database.addTag(TagRecord(kind: "session", target: "M31", sessionDate: "2026-01-01", tag: "clouds"))

    #expect(try database.tags(target: "M31", sessionDate: "2026-01-01") == ["clouds"])
    #expect(try database.tags(target: "M31", sessionDate: nil) == [])
    #expect(try database.tags(target: "M31", sessionDate: "2026-01-02") == [])
}

@Test func addTagTwiceStaysIdempotent() throws {
    let database = try Database(path: ":memory:")
    try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"))
    try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"))

    #expect(try database.tags(target: "M31", sessionDate: nil) == ["favorite"])

    var count = 0
    try database.db.query("SELECT id FROM tags;") { _ in count += 1 }
    #expect(count == 1)
}

/// Regression guard: SQL `NULL` is never equal to `NULL`, so two
/// target-level tag rows (`session_date IS NULL`) would NOT collide on the
/// table's `UNIQUE(kind, target, session_date, tag)` index the way two
/// session-level rows with the same date would. `addTag` must not rely on
/// that index alone for idempotency.
@Test func addTargetLevelTagTwiceDoesNotDuplicateDespiteNullSessionDate() throws {
    let database = try Database(path: ":memory:")
    for _ in 0..<3 {
        try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"))
    }

    var count = 0
    try database.db.query(
        "SELECT id FROM tags WHERE target = ? AND session_date IS NULL AND tag = ?;",
        bind: [.text("M31"), .text("favorite")]
    ) { _ in count += 1 }
    #expect(count == 1)
}

@Test func addTagRejectsEmptyOrWhitespaceOnlyTag() throws {
    let database = try Database(path: ":memory:")
    #expect(throws: AstroError.self) {
        try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "   "))
    }
    #expect(throws: AstroError.self) {
        try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: ""))
    }
}

@Test func addTagTrimsWhitespaceAroundTagText() throws {
    let database = try Database(path: ":memory:")
    try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "  favorite  "))
    #expect(try database.tags(target: "M31", sessionDate: nil) == ["favorite"])
}

@Test func addTagDerivesKindFromSessionDateIgnoringCallerSuppliedKind() throws {
    let database = try Database(path: ":memory:")
    // Caller passes a lying `kind` -- Database must ignore it and derive
    // the real kind from `sessionDate`'s nil-ness.
    try database.addTag(TagRecord(kind: "session", target: "M31", sessionDate: nil, tag: "favorite"))

    let all = try database.allTags()
    #expect(all == [TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite")])
}

@Test func removeTagDeletesOnlyTheMatchingRow() throws {
    let database = try Database(path: ":memory:")
    try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"))
    try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "wide"))

    try database.removeTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"))

    #expect(try database.tags(target: "M31", sessionDate: nil) == ["wide"])
}

@Test func removeTagOnAbsentTagIsANoOp() throws {
    let database = try Database(path: ":memory:")
    try database.removeTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"))
    #expect(try database.tags(target: "M31", sessionDate: nil) == [])
}

@Test func allTagsReturnsEveryRowSortedByTargetThenDateThenTag() throws {
    let database = try Database(path: ":memory:")
    try database.addTag(TagRecord(kind: "target", target: "M42", sessionDate: nil, tag: "wide"))
    try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"))
    try database.addTag(TagRecord(kind: "session", target: "M31", sessionDate: "2026-01-01", tag: "clouds"))

    let all = try database.allTags()
    #expect(all == [
        TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"),
        TagRecord(kind: "session", target: "M31", sessionDate: "2026-01-01", tag: "clouds"),
        TagRecord(kind: "target", target: "M42", sessionDate: nil, tag: "wide"),
    ])
}

@Test func targetsWithTagReturnsOnlyTargetLevelMatchesSorted() throws {
    let database = try Database(path: ":memory:")
    try database.addTag(TagRecord(kind: "target", target: "M42", sessionDate: nil, tag: "favorite"))
    try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "favorite"))
    // Session-level tag with the same text must NOT count.
    try database.addTag(TagRecord(kind: "session", target: "M1", sessionDate: "2026-01-01", tag: "favorite"))

    #expect(try database.targetsWithTag("favorite") == ["M31", "M42"])
    #expect(try database.targetsWithTag("nonexistent") == [])
}
