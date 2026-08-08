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

@Test func migrateSetsSchemaVersionToLatestForFreshDatabase() throws {
    let database = try Database(path: ":memory:")

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 10)
}

@Test func migrateIsIdempotentAndDoesNotDuplicateVersionRow() throws {
    let database = try Database(path: ":memory:")

    var rowCount = 0
    try database.db.query("SELECT version FROM schema_version;") { _ in rowCount += 1 }
    #expect(rowCount == 1)
}

@Test func migrateCreatesAllExpectedTables() throws {
    let database = try Database(path: ":memory:")

    let expectedTables = [
        "schema_version", "files", "fits_meta", "ratings", "findings", "runs", "tags", "session_notes",
        "sensor_profile", "finding_acks", "sensor_profile_history",
    ]
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
    #expect(version == 10)

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
    #expect(version == 10)

    let files = try database.allFiles(includeMissing: true)
    #expect(files.count == 1)
    #expect(files.first?.target == "M31")
    #expect(files.first?.inode == nil)
    #expect(files.first?.nlink == nil)
}

/// Simulates an already-deployed v3 database (v1+v2+v3 schema, `schema_
/// version` stamped `3`) with one `fits_meta` row whose `header_json` carries
/// `XPIXSZ`/`EGAIN` cards (as `Scanner.fitsMetaRecord` always wrote, even
/// before those became dedicated columns), then opens it through
/// `Database(path:)` and verifies the v3->v4 upgrade both adds the new
/// columns AND backfills them from the existing `header_json` blob -- no
/// file I/O, no rescan required.
@Test func migrateUpgradesExistingV3DatabaseToV4BackfillingXpixszEgainFromHeaderJSON() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v3.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.exec(Database.schemaSQLv3)
        try raw.run("INSERT INTO schema_version(version) VALUES (3);")
        try raw.run(
            """
            INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing, inode, nlink)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text("sessions/M31/2026-01-01/lights/f1.fits"), .int(1024), .real(1_700_000_000),
                .text("fits"), .text("fits"), .text("sessions"), .text("M31"), .text("2026-01-01"),
                .text("light"), .null, .real(1_700_000_100), .int(0), .null, .null,
            ]
        )
        try raw.run(
            """
            INSERT INTO fits_meta(file_id, exptime, header_json)
            VALUES (1, 300.0, ?);
            """,
            bind: [.text(#"{"EXPTIME":"300.0","XPIXSZ":"3.76","EGAIN":"0.75"}"#)]
        )
        // A second row with no header_json at all -- must not crash the
        // backfill and must stay NULL in the new columns.
        try raw.run(
            """
            INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing, inode, nlink)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text("sessions/M31/2026-01-02/lights/f2.fits"), .int(1024), .real(1_700_000_000),
                .text("fits"), .text("fits"), .text("sessions"), .text("M31"), .text("2026-01-02"),
                .text("light"), .null, .real(1_700_000_100), .int(0), .null, .null,
            ]
        )
        try raw.run("INSERT INTO fits_meta(file_id, exptime) VALUES (2, 300.0);")
    }

    let database = try Database(path: path)

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 10)

    let fileID1 = try #require(try database.fileID(path: "sessions/M31/2026-01-01/lights/f1.fits"))
    let meta1 = try database.fitsMeta(fileID: fileID1)
    #expect(meta1?.xpixsz == 3.76)
    #expect(meta1?.egain == 0.75)
    #expect(meta1?.exptime == 300.0, "backfill must not disturb pre-existing columns")

    let fileID2 = try #require(try database.fileID(path: "sessions/M31/2026-01-02/lights/f2.fits"))
    let meta2 = try database.fitsMeta(fileID: fileID2)
    #expect(meta2?.xpixsz == nil)
    #expect(meta2?.egain == nil)
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
        xpixsz: 3.76,
        egain: 0.75,
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

/// D12: `resolveCoordinateInfo`/`runPlateSolveAll` used to call `fitsMeta`
/// once per file -- thousands of round trips for a big target. This batch
/// form must return the same data keyed by file id, chunked internally at
/// 500 ids/query so it also works past SQLite's default bound-parameter
/// limit.
@Test func fitsMetaBatchReturnsRecordsKeyedByFileID() throws {
    let database = try Database(path: ":memory:")
    let id1 = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/a.fits"))
    let id2 = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/b.fits"))
    let id3 = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/c.fits"))

    try database.upsertFITSMeta(FITSMetaRecord(fileID: id1, exptime: 120))
    try database.upsertFITSMeta(FITSMetaRecord(fileID: id2, exptime: 240, filter: "OIII"))
    // id3 intentionally left without a fits_meta row.

    let batch = try database.fitsMetaBatch(fileIDs: [id1, id2, id3])

    #expect(batch.count == 2)
    #expect(batch[id1]?.exptime == 120)
    #expect(batch[id2]?.exptime == 240)
    #expect(batch[id2]?.filter == "OIII")
    #expect(batch[id3] == nil)
}

@Test func fitsMetaBatchReturnsEmptyForEmptyInput() throws {
    let database = try Database(path: ":memory:")
    let batch = try database.fitsMetaBatch(fileIDs: [])
    #expect(batch.isEmpty)
}

@Test func fitsMetaBatchChunksPastFiveHundredIDs() throws {
    let database = try Database(path: ":memory:")
    var ids: [Int64] = []
    for i in 0..<1200 {
        let id = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/f\(i).fits"))
        try database.upsertFITSMeta(FITSMetaRecord(fileID: id, exptime: Double(i)))
        ids.append(id)
    }

    let batch = try database.fitsMetaBatch(fileIDs: ids)

    #expect(batch.count == 1200)
    #expect(batch[ids[0]]?.exptime == 0)
    #expect(batch[ids[1199]]?.exptime == 1199)
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

@Test func runSummaryRoundTripsMetadataAndUpdatedConfig() throws {
    let database = try Database(path: ":memory:")
    let runID = try database.beginRun(
        kind: "verify", root: "/Volumes/images/Astro", configJSON: "{\"phase\":\"started\"}"
    )

    let started = try #require(try database.runSummary(id: runID))
    #expect(started.id == runID)
    #expect(started.kind == "verify")
    #expect(started.root == "/Volumes/images/Astro")
    #expect(started.configJSON == "{\"phase\":\"started\"}")
    #expect(started.finishedAt == nil)

    try database.updateRunConfig(id: runID, configJSON: "{\"phase\":\"finished\"}")
    try database.finishRun(id: runID)

    let finished = try #require(try database.runSummary(id: runID))
    #expect(finished.configJSON == "{\"phase\":\"finished\"}")
    #expect(finished.finishedAt != nil)
    #expect(try database.runSummary(id: runID + 999) == nil)
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

@Test func lastRunDateReturnsNilWhenNoRunsOfThatKindExist() throws {
    let database = try Database(path: ":memory:")
    #expect(try database.lastRunDate(kind: "scan") == nil)

    // A run of a DIFFERENT kind must not be picked up.
    _ = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)
    #expect(try database.lastRunDate(kind: "scan") == nil)
}

@Test func lastRunDateReturnsTheMostRecentStartedAtForThatKind() throws {
    let database = try Database(path: ":memory:")
    let earlier = Date(timeIntervalSince1970: 1_000)
    let later = Date(timeIntervalSince1970: 2_000)

    // `beginRun` always stamps "now" -- insert the two rows directly so this
    // test controls `started_at` instead of racing the clock.
    try database.db.run(
        "INSERT INTO runs(kind, started_at, root) VALUES ('scan', ?, '/root');",
        bind: [.real(earlier.timeIntervalSince1970)]
    )
    try database.db.run(
        "INSERT INTO runs(kind, started_at, root) VALUES ('scan', ?, '/root');",
        bind: [.real(later.timeIntervalSince1970)]
    )

    #expect(try database.lastRunDate(kind: "scan") == later)
}

@Test func lastRunIDReturnsNilWhenNoRunsOfThatKindExist() throws {
    let database = try Database(path: ":memory:")
    #expect(try database.lastRunID(kind: "audit") == nil)

    // A run of a DIFFERENT kind must not be picked up.
    _ = try database.beginRun(kind: "scan", root: "/root", configJSON: nil)
    #expect(try database.lastRunID(kind: "audit") == nil)
}

@Test func lastRunIDReturnsTheMostRecentRunIDForThatKind() throws {
    let database = try Database(path: ":memory:")
    _ = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)
    let latest = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)

    #expect(try database.lastRunID(kind: "audit") == latest)
}

@Test func completedRunQueriesIgnoreANewerInterruptedRun() throws {
    let database = try Database(path: ":memory:")
    let completed = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)
    try database.finishRun(id: completed)
    let interrupted = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)

    #expect(try database.lastCompletedRunID(kind: "audit") == completed)
    #expect(try database.previousCompletedRunID(before: interrupted, kind: "audit") == completed)
}

// MARK: - Database: previousRunID (R11-T8/F6)

@Test func previousRunIDReturnsNilWhenTheGivenRunIsTheOnlyOneOfItsKind() throws {
    let database = try Database(path: ":memory:")
    let onlyRun = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)

    #expect(try database.previousRunID(before: onlyRun, kind: "audit") == nil)
}

@Test func previousRunIDReturnsTheRunImmediatelyBeforeTheGivenOne() throws {
    let database = try Database(path: ":memory:")

    // Explicit `started_at` values (same technique as
    // `lastRunDateReturnsTheMostRecentStartedAtForThatKind`) so this test
    // doesn't race the clock across three back-to-back `beginRun` calls.
    try database.db.run(
        "INSERT INTO runs(id, kind, started_at, root) VALUES (1, 'audit', 1000, '/root');"
    )
    try database.db.run(
        "INSERT INTO runs(id, kind, started_at, root) VALUES (2, 'audit', 2000, '/root');"
    )
    try database.db.run(
        "INSERT INTO runs(id, kind, started_at, root) VALUES (3, 'audit', 3000, '/root');"
    )

    #expect(try database.previousRunID(before: 3, kind: "audit") == 2)
    #expect(try database.previousRunID(before: 2, kind: "audit") == 1)
    #expect(try database.previousRunID(before: 1, kind: "audit") == nil)
}

@Test func previousRunIDIgnoresRunsOfADifferentKind() throws {
    let database = try Database(path: ":memory:")

    try database.db.run(
        "INSERT INTO runs(id, kind, started_at, root) VALUES (1, 'scan', 1000, '/root');"
    )
    try database.db.run(
        "INSERT INTO runs(id, kind, started_at, root) VALUES (2, 'audit', 2000, '/root');"
    )

    // The scan run started before the audit run, but it's the wrong kind --
    // there's no PREVIOUS audit run to find.
    #expect(try database.previousRunID(before: 2, kind: "audit") == nil)
}

@Test func previousRunIDReturnsNilWhenTheAnchorRunIDDoesNotExist() throws {
    let database = try Database(path: ":memory:")
    _ = try database.beginRun(kind: "audit", root: "/root", configJSON: nil)

    #expect(try database.previousRunID(before: 999_999, kind: "audit") == nil)
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

// MARK: - Database: hasAnyRating (R11-T12/F12)

@Test func hasAnyRatingIsFalseForAFreshDatabase() throws {
    let database = try Database(path: ":memory:")
    #expect(try database.hasAnyRating() == false)
}

@Test func hasAnyRatingIsTrueOnceAnyFrameHasBeenRated() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    try database.upsertRating(sampleRating(fileID: fileID))
    #expect(try database.hasAnyRating() == true)
}

// MARK: - Database: ratingsBatch (N6, R9 round 3)

@Test func ratingsBatchReturnsRecordsKeyedByFileID() throws {
    let database = try Database(path: ":memory:")
    let id1 = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/a.fits"))
    let id2 = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/b.fits"))
    let id3 = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/c.fits"))

    try database.upsertRating(sampleRating(fileID: id1))
    var second = sampleRating(fileID: id2)
    second.score = 0.42
    try database.upsertRating(second)
    // id3 intentionally left without a ratings row.

    let batch = try database.ratingsBatch(fileIDs: [id1, id2, id3])

    #expect(batch.count == 2)
    #expect(batch[id1]?.score == 0.87)
    #expect(batch[id2]?.score == 0.42)
    #expect(batch[id3] == nil)
}

@Test func ratingsBatchReturnsEmptyForEmptyInput() throws {
    let database = try Database(path: ":memory:")
    let batch = try database.ratingsBatch(fileIDs: [])
    #expect(batch.isEmpty)
}

@Test func ratingsBatchChunksPastFiveHundredIDs() throws {
    let database = try Database(path: ":memory:")
    var ids: [Int64] = []
    for i in 0..<1200 {
        let id = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/f\(i).fits"))
        var rating = sampleRating(fileID: id)
        rating.score = Double(i)
        try database.upsertRating(rating)
        ids.append(id)
    }

    let batch = try database.ratingsBatch(fileIDs: ids)

    #expect(batch.count == 1200)
    #expect(batch[ids[0]]?.score == 0)
    #expect(batch[ids[1199]]?.score == 1199)
}

@Test func upsertRatingRoundTripsPerBayerBackgroundColumns() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    var rating = sampleRating(fileID: fileID)
    rating.bg00 = 514.0
    rating.bg01 = 508.0
    rating.bg10 = 509.0
    rating.bg11 = 506.0

    try database.upsertRating(rating)

    let fetched = try database.rating(fileID: fileID)
    #expect(fetched?.bg00 == 514.0)
    #expect(fetched?.bg01 == 508.0)
    #expect(fetched?.bg10 == 509.0)
    #expect(fetched?.bg11 == 506.0)
}

// MARK: - Database: sensor_profile

private func sampleSensorProfile(
    camera: String = "ASI2600MC",
    gain: Double? = 100,
    offset: Double? = 50
) -> SensorProfileRecord {
    SensorProfileRecord(
        camera: camera,
        gain: gain,
        offset: offset,
        biasLevelADU: 501,
        readNoiseE: 1.30,
        darkRateEPerS: 0.0,
        darkTempC: -10.0,
        egain: 0.242863,
        measuredAt: 1_700_000_000,
        frameCount: 2
    )
}

@Test func upsertSensorProfileInsertsAndReadsBack() throws {
    let database = try Database(path: ":memory:")
    let profile = sampleSensorProfile()
    try database.upsertSensorProfile(profile)

    let fetched = try database.sensorProfile(camera: "ASI2600MC", gain: 100, offset: 50)
    #expect(fetched == profile)
}

@Test func sensorProfileReturnsNilForUnknownCombo() throws {
    let database = try Database(path: ":memory:")
    #expect(try database.sensorProfile(camera: "ASI2600MC", gain: 100, offset: 50) == nil)
}

@Test func upsertSensorProfileKeyedByCameraGainOffsetOverwritesOnRemeasure() throws {
    let database = try Database(path: ":memory:")
    try database.upsertSensorProfile(sampleSensorProfile())

    var updated = sampleSensorProfile()
    updated.biasLevelADU = 505
    updated.readNoiseE = 1.35
    updated.measuredAt = 1_700_000_999
    try database.upsertSensorProfile(updated)

    let fetched = try database.sensorProfile(camera: "ASI2600MC", gain: 100, offset: 50)
    #expect(fetched?.biasLevelADU == 505)
    #expect(fetched?.readNoiseE == 1.35)

    // Still exactly one row for this combo.
    var count = 0
    try database.db.query(
        "SELECT camera FROM sensor_profile WHERE camera = ? AND gain = ? AND offset = ?;",
        bind: [.text("ASI2600MC"), .real(100), .real(50)]
    ) { _ in count += 1 }
    #expect(count == 1)
}

@Test func upsertSensorProfileDistinguishesDifferentGainOffsetCombosForSameCamera() throws {
    let database = try Database(path: ":memory:")
    try database.upsertSensorProfile(sampleSensorProfile(gain: 100, offset: 50))
    try database.upsertSensorProfile(sampleSensorProfile(gain: 0, offset: 30))

    let all = try database.allSensorProfiles()
    #expect(all.count == 2)
    #expect(try database.sensorProfile(camera: "ASI2600MC", gain: 0, offset: 30)?.biasLevelADU == 501)
}

@Test func allSensorProfilesReturnsEmptyArrayWhenNoneMeasured() throws {
    let database = try Database(path: ":memory:")
    #expect(try database.allSensorProfiles().isEmpty)
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

// MARK: - session_notes (schema v5, R6-4)

/// Simulates an already-deployed v4 database (v1..v4 schema, `schema_
/// version` stamped `4`) via a raw `SQLiteDB` connection, then opens it
/// through `Database(path:)` and verifies the upgrade advances to v5 and
/// creates the new `session_notes` table without disturbing existing rows.
@Test func migrateUpgradesExistingV4DatabaseToV5AddingSessionNotesTable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v4-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v4.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.exec(Database.schemaSQLv3)
        try raw.exec(Database.schemaSQLv4)
        try raw.run("INSERT INTO schema_version(version) VALUES (4);")
        try raw.run(
            """
            INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing, inode, nlink)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text("sessions/M31/2026-01-01/lights/f1.fits"), .int(1024), .real(1_700_000_000),
                .text("fits"), .text("fits"), .text("sessions"), .text("M31"), .text("2026-01-01"),
                .text("light"), .null, .real(1_700_000_100), .int(0), .null, .null,
            ]
        )
    }

    let database = try Database(path: path)

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 10)

    let files = try database.allFiles(includeMissing: true)
    #expect(files.count == 1, "the v4 row must survive the upgrade untouched")
    #expect(files.first?.target == "M31")

    // Fresh table, usable via the DAO immediately after the upgrade.
    try database.upsertSessionNotes(target: "M31", date: "2026-01-01", notes: ["Camera": "ASI2600MC"])
    #expect(try database.sessionNotes(target: "M31", date: "2026-01-01") == ["Camera": "ASI2600MC"])
}

// MARK: - solved_* columns (schema v6, R7-1)

/// Simulates an already-deployed v5 database (v1..v5 schema, `schema_
/// version` stamped `5`) via a raw `SQLiteDB` connection, then opens it
/// through `Database(path:)` and verifies the upgrade advances to v6, adds
/// the new `solved_*` columns (NULL for the pre-existing row, same
/// `ALTER TABLE ADD COLUMN` convention as every earlier additive migration),
/// and that `updateSolvedWCS` is immediately usable via the DAO afterward.
@Test func migrateUpgradesExistingV5DatabaseToV6AddingSolvedColumns() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v5-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v5.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.exec(Database.schemaSQLv3)
        try raw.exec(Database.schemaSQLv4)
        try raw.exec(Database.schemaSQLv5)
        try raw.run("INSERT INTO schema_version(version) VALUES (5);")
        try raw.run(
            """
            INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing, inode, nlink)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text("sessions/M45_Pleiades/2026-01-01/lights/f1.cr3"), .int(1024), .real(1_700_000_000),
                .text("cr3"), .text("raw"), .text("sessions"), .text("M45_Pleiades"), .text("2026-01-01"),
                .text("light"), .null, .real(1_700_000_100), .int(0), .null, .null,
            ]
        )
        try raw.run("INSERT INTO fits_meta(file_id, exptime) VALUES (1, 30.0);")
    }

    let database = try Database(path: path)

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 10)

    let fileID = try #require(try database.fileID(path: "sessions/M45_Pleiades/2026-01-01/lights/f1.cr3"))
    let metaBeforeSolve = try database.fitsMeta(fileID: fileID)
    #expect(metaBeforeSolve?.solvedRA == nil, "ALTER TABLE ADD COLUMN never backfills pre-existing rows")
    #expect(metaBeforeSolve?.solvedDec == nil)
    #expect(metaBeforeSolve?.exptime == 30.0, "the v5 row's pre-existing columns must survive the upgrade untouched")

    try database.updateSolvedWCS(fileID: fileID, ra: 56.75, dec: 24.1, scale: 1.2, rotation: 15.0)
    let metaAfterSolve = try database.fitsMeta(fileID: fileID)
    #expect(metaAfterSolve?.solvedRA == 56.75)
    #expect(metaAfterSolve?.solvedDec == 24.1)
    #expect(metaAfterSolve?.solvedScaleArcsec == 1.2)
    #expect(metaAfterSolve?.solvedRotationDeg == 15.0)
}

@Test func migrateUpgradesExistingV6DatabaseToV7AddingBayerColumnsAndSensorProfileTable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v6-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v6.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.exec(Database.schemaSQLv3)
        try raw.exec(Database.schemaSQLv4)
        try raw.exec(Database.schemaSQLv5)
        try raw.exec(Database.schemaSQLv6)
        try raw.run("INSERT INTO schema_version(version) VALUES (6);")
        try raw.run(
            """
            INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing, inode, nlink)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text("sessions/M31/2026-01-01/lights/f1.fits"), .int(1024), .real(1_700_000_000),
                .text("fits"), .text("fits"), .text("sessions"), .text("M31"), .text("2026-01-01"),
                .text("light"), .null, .real(1_700_000_100), .int(0), .null, .null,
            ]
        )
        try raw.run(
            "INSERT INTO ratings(file_id, background, rated_at, input_sig) VALUES (1, 100.0, ?, ?);",
            bind: [.real(1_700_000_200), .text("sig-1")]
        )
    }

    let database = try Database(path: path)

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 10)

    let fileID = try #require(try database.fileID(path: "sessions/M31/2026-01-01/lights/f1.fits"))
    let rating = try database.rating(fileID: fileID)
    #expect(rating?.background == 100.0, "the v6 row's pre-existing columns must survive the upgrade untouched")
    #expect(rating?.bg00 == nil, "ALTER TABLE ADD COLUMN never backfills pre-existing rows")
    #expect(rating?.bg01 == nil)
    #expect(rating?.bg10 == nil)
    #expect(rating?.bg11 == nil)

    // sensor_profile table exists and is usable after the same migration.
    #expect(try database.allSensorProfiles().isEmpty)
    try database.upsertSensorProfile(
        SensorProfileRecord(camera: "ASI2600MC", gain: 100, offset: 50, biasLevelADU: 501, measuredAt: 1_700_000_300)
    )
    #expect(try database.sensorProfile(camera: "ASI2600MC", gain: 100, offset: 50)?.biasLevelADU == 501)
}

// MARK: - ratings.source + user_verdicts (schema v8, R7-B2)

@Test func migrateUpgradesExistingV7DatabaseToV8AddingSourceColumnAndUserVerdictsTable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v7-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v7.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.exec(Database.schemaSQLv3)
        try raw.exec(Database.schemaSQLv4)
        try raw.exec(Database.schemaSQLv5)
        try raw.exec(Database.schemaSQLv6)
        try raw.exec(Database.schemaSQLv7)
        try raw.run("INSERT INTO schema_version(version) VALUES (7);")
        try raw.run(
            """
            INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing, inode, nlink)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bind: [
                .text("sessions/M31/2026-01-01/lights/f1.fits"), .int(1024), .real(1_700_000_000),
                .text("fits"), .text("fits"), .text("sessions"), .text("M31"), .text("2026-01-01"),
                .text("light"), .null, .real(1_700_000_100), .int(0), .null, .null,
            ]
        )
        try raw.run(
            "INSERT INTO ratings(file_id, background, rated_at, input_sig) VALUES (1, 100.0, ?, ?);",
            bind: [.real(1_700_000_200), .text("sig-1")]
        )
    }

    let database = try Database(path: path)

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 10)

    let fileID = try #require(try database.fileID(path: "sessions/M31/2026-01-01/lights/f1.fits"))
    let rating = try database.rating(fileID: fileID)
    #expect(rating?.background == 100.0, "the v7 row's pre-existing columns must survive the upgrade untouched")
    #expect(rating?.source == nil, "ALTER TABLE ADD COLUMN never backfills pre-existing rows")

    // user_verdicts table exists and is usable after the same migration.
    #expect(try database.userVerdict(fileID: fileID) == nil)
    try database.upsertUserVerdict(UserVerdictRecord(fileID: fileID, accepted: true, source: "dssfilelist", recordedAt: 1_700_000_300))
    #expect(try database.userVerdict(fileID: fileID)?.accepted == true)
}

@Test func upsertRatingRoundTripsSourceColumn() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    var rating = sampleRating(fileID: fileID)
    rating.source = "dss"

    try database.upsertRating(rating)

    let fetched = try database.rating(fileID: fileID)
    #expect(fetched?.source == "dss")
}

@Test func upsertUserVerdictInsertsAndReadsBack() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    let verdict = UserVerdictRecord(fileID: fileID, accepted: true, source: "dssfilelist", recordedAt: 1_700_000_000)

    try database.upsertUserVerdict(verdict)

    #expect(try database.userVerdict(fileID: fileID) == verdict)
}

@Test func userVerdictReturnsNilWhenAbsent() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    #expect(try database.userVerdict(fileID: fileID) == nil)
}

@Test func upsertUserVerdictKeyedByFileIDOverwritesOnReingest() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())

    try database.upsertUserVerdict(UserVerdictRecord(fileID: fileID, accepted: true, source: "dssfilelist", recordedAt: 1_700_000_000))
    try database.upsertUserVerdict(UserVerdictRecord(fileID: fileID, accepted: false, source: "dssfilelist", recordedAt: 1_700_000_500))

    #expect(try database.userVerdict(fileID: fileID)?.accepted == false)

    var count = 0
    try database.db.query("SELECT file_id FROM user_verdicts WHERE file_id = ?;", bind: [.int(fileID)]) { _ in count += 1 }
    #expect(count == 1)
}

@Test func acceptedCountsTalliesVerdictsForOneTargetSessionOnly() throws {
    let database = try Database(path: ":memory:")
    func file(_ path: String, sessionDate: String) -> FileRecord {
        var record = sampleFile(path: path)
        record.sessionDate = sessionDate
        return record
    }
    let f1 = try database.upsertFile(file("sessions/M31/2026-01-01/lights/f1.fits", sessionDate: "2026-01-01"))
    let f2 = try database.upsertFile(file("sessions/M31/2026-01-01/lights/f2.fits", sessionDate: "2026-01-01"))
    let f3 = try database.upsertFile(file("sessions/M31/2026-02-02/lights/f3.fits", sessionDate: "2026-02-02"))

    try database.upsertUserVerdict(UserVerdictRecord(fileID: f1, accepted: true, source: "dssfilelist", recordedAt: 1))
    try database.upsertUserVerdict(UserVerdictRecord(fileID: f2, accepted: false, source: "dssfilelist", recordedAt: 1))
    // Different session date for the same target -- must not be counted.
    try database.upsertUserVerdict(UserVerdictRecord(fileID: f3, accepted: true, source: "dssfilelist", recordedAt: 1))

    let counts = try database.acceptedCounts(target: "M31", date: "2026-01-01")
    #expect(counts.accepted == 1)
    #expect(counts.rejected == 1)
}

@Test func acceptedCountsReturnsZeroZeroWhenNoVerdictsRecorded() throws {
    let database = try Database(path: ":memory:")
    let counts = try database.acceptedCounts(target: "NoSuchTarget", date: "2026-01-01")
    #expect(counts.accepted == 0)
    #expect(counts.rejected == 0)
}

// MARK: - Database: userVerdicts(forFileIDs:) / setUserVerdict / clearUserVerdict (R10-B1)

@Test func userVerdictsForFileIDsReturnsAcceptedFlagsKeyedByFileID() throws {
    let database = try Database(path: ":memory:")
    let id1 = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/a.fits"))
    let id2 = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/b.fits"))
    let id3 = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/c.fits"))

    try database.upsertUserVerdict(UserVerdictRecord(fileID: id1, accepted: true, source: "app", recordedAt: 1))
    try database.upsertUserVerdict(UserVerdictRecord(fileID: id2, accepted: false, source: "app", recordedAt: 1))
    // id3 intentionally left without a verdict.

    let verdicts = try database.userVerdicts(forFileIDs: [id1, id2, id3])

    #expect(verdicts.count == 2)
    #expect(verdicts[id1] == true)
    #expect(verdicts[id2] == false)
    #expect(verdicts[id3] == nil)
}

@Test func userVerdictsForFileIDsReturnsEmptyForEmptyInput() throws {
    let database = try Database(path: ":memory:")
    let verdicts = try database.userVerdicts(forFileIDs: [])
    #expect(verdicts.isEmpty)
}

@Test func userVerdictsForFileIDsChunksPastFiveHundredIDs() throws {
    let database = try Database(path: ":memory:")
    var ids: [Int64] = []
    for i in 0..<1200 {
        let id = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/f\(i).fits"))
        try database.upsertUserVerdict(UserVerdictRecord(fileID: id, accepted: i % 2 == 0, source: "app", recordedAt: 1))
        ids.append(id)
    }

    let verdicts = try database.userVerdicts(forFileIDs: ids)

    #expect(verdicts.count == 1200)
    #expect(verdicts[ids[0]] == true)
    #expect(verdicts[ids[1]] == false)
    #expect(verdicts[ids[1199]] == false)
}

@Test func setUserVerdictInsertsWithGivenSourceAndIsReadableViaUserVerdict() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())

    try database.setUserVerdict(fileID: fileID, accepted: true, source: "app")

    let fetched = try database.userVerdict(fileID: fileID)
    #expect(fetched?.accepted == true)
    #expect(fetched?.source == "app")
}

@Test func setUserVerdictOverwritesAPriorVerdictInPlace() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())

    try database.setUserVerdict(fileID: fileID, accepted: true, source: "app")
    try database.setUserVerdict(fileID: fileID, accepted: false, source: "app")

    #expect(try database.userVerdict(fileID: fileID)?.accepted == false)

    var count = 0
    try database.db.query("SELECT file_id FROM user_verdicts WHERE file_id = ?;", bind: [.int(fileID)]) { _ in count += 1 }
    #expect(count == 1)
}

@Test func setUserVerdictCanOverwriteADSSImportedVerdictWithAnAppOne() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    try database.upsertUserVerdict(UserVerdictRecord(fileID: fileID, accepted: false, source: "dssfilelist", recordedAt: 1))

    try database.setUserVerdict(fileID: fileID, accepted: true, source: "app")

    let fetched = try database.userVerdict(fileID: fileID)
    #expect(fetched?.accepted == true)
    #expect(fetched?.source == "app")
}

@Test func clearUserVerdictRemovesTheRow() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    try database.setUserVerdict(fileID: fileID, accepted: true, source: "app")

    try database.clearUserVerdict(fileID: fileID)

    #expect(try database.userVerdict(fileID: fileID) == nil)
}

@Test func clearUserVerdictOnAFileWithNoVerdictIsANoOp() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    try database.clearUserVerdict(fileID: fileID)
    #expect(try database.userVerdict(fileID: fileID) == nil)
}

@Test func hasTrackedFileWithSuffixFindsAMatchingNonMissingFileOnly() throws {
    let database = try Database(path: ":memory:")
    #expect(try database.hasTrackedFileWithSuffix(".dssfilelist") == false)

    var record = sampleFile(path: "sessions/M31/2026-01-01/session.dssfilelist")
    record.kind = "other"
    _ = try database.upsertFile(record)
    #expect(try database.hasTrackedFileWithSuffix(".dssfilelist") == true)
}

@Test func updateSolvedWCSDoesNotDisturbHeaderJSONOrOtherColumns() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    try database.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: 60, headerJSON: "{\"NAXIS\":2}"))

    try database.updateSolvedWCS(fileID: fileID, ra: 10.5, dec: -5.25, scale: 2.0, rotation: 45.0)

    let fetched = try database.fitsMeta(fileID: fileID)
    #expect(fetched?.solvedRA == 10.5)
    #expect(fetched?.solvedDec == -5.25)
    #expect(fetched?.solvedScaleArcsec == 2.0)
    #expect(fetched?.solvedRotationDeg == 45.0)
    #expect(fetched?.exptime == 60, "updateSolvedWCS must not touch unrelated columns")
    #expect(fetched?.headerJSON == "{\"NAXIS\":2}", "the original scanned header must never be rewritten by a solve")
}

/// Regression guard for the exact bug `updateSolvedWCS` exists to avoid: a
/// plain `upsertFITSMeta` call (what a rescan does) must never wipe out a
/// previously persisted solved coordinate, since a scanner-built
/// `FITSMetaRecord` never carries one (it always defaults to `nil`).
@Test func rescanUpsertFITSMetaDoesNotWipeOutPreviouslySolvedCoordinates() throws {
    let database = try Database(path: ":memory:")
    let fileID = try database.upsertFile(sampleFile())
    try database.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: 60))
    try database.updateSolvedWCS(fileID: fileID, ra: 10.5, dec: -5.25, scale: 2.0, rotation: 45.0)

    // Simulates a rescan: the scanner re-upserts fits_meta with a freshly
    // built record that (correctly) knows nothing about solved_ra/dec.
    try database.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: 60, filter: "L"))

    let fetched = try database.fitsMeta(fileID: fileID)
    #expect(fetched?.solvedRA == 10.5, "a rescan must never erase a previously solved coordinate")
    #expect(fetched?.solvedDec == -5.25)
    #expect(fetched?.filter == "L")
}

@Test func upsertSessionNotesReplacesAllPriorNotesForThatSession() throws {
    let database = try Database(path: ":memory:")
    try database.upsertSessionNotes(
        target: "M31", date: "2026-01-01",
        notes: ["Camera": "ASI2600MC", "Filter": "L-eXtreme"]
    )
    #expect(try database.sessionNotes(target: "M31", date: "2026-01-01").count == 2)

    // A second call with a DIFFERENT set of keys must fully replace the
    // first -- "Filter" must be gone, not merged.
    try database.upsertSessionNotes(target: "M31", date: "2026-01-01", notes: ["Camera": "ASI2600MM Pro"])

    let notes = try database.sessionNotes(target: "M31", date: "2026-01-01")
    #expect(notes == ["Camera": "ASI2600MM Pro"])
}

@Test func sessionNotesIsScopedToItsOwnTargetAndDate() throws {
    let database = try Database(path: ":memory:")
    try database.upsertSessionNotes(target: "M31", date: "2026-01-01", notes: ["Bortle": "4"])
    try database.upsertSessionNotes(target: "M31", date: "2026-01-02", notes: ["Bortle": "5"])
    try database.upsertSessionNotes(target: "M42", date: "2026-01-01", notes: ["Bortle": "6"])

    #expect(try database.sessionNotes(target: "M31", date: "2026-01-01") == ["Bortle": "4"])
    #expect(try database.sessionNotes(target: "M31", date: "2026-01-02") == ["Bortle": "5"])
    #expect(try database.sessionNotes(target: "M42", date: "2026-01-01") == ["Bortle": "6"])
}

@Test func sessionNotesReturnsEmptyDictionaryWhenNoneStored() throws {
    let database = try Database(path: ":memory:")
    #expect(try database.sessionNotes(target: "M31", date: "2026-01-01") == [:])
}

@Test func searchNotesMatchesKeyOrValueCaseInsensitively() throws {
    let database = try Database(path: ":memory:")
    try database.upsertSessionNotes(
        target: "M31", date: "2026-01-01",
        notes: ["Location/Bortle": "falu, 4", "SQM": "20.8", "Notes/issues": "some dew on the corrector"]
    )
    try database.upsertSessionNotes(
        target: "M42", date: "2026-02-02",
        notes: ["Notes/issues": "no problems tonight"]
    )

    let byValue = try database.searchNotes(query: "DEW")
    #expect(byValue.count == 1)
    #expect(byValue.first?.target == "M31")
    #expect(byValue.first?.key == "Notes/issues")

    let byKey = try database.searchNotes(query: "bortle")
    #expect(byKey.count == 1)
    #expect(byKey.first?.value == "falu, 4")

    #expect(try database.searchNotes(query: "nonexistent-term").isEmpty)
}

// MARK: - searchAll (R9-T6/B3 global search)

private func sessionFile(
    path: String, target: String?, sessionDate: String?, area: LibraryArea = .sessions
) -> FileRecord {
    FileRecord(
        path: path, size: 1024, mtime: 1_700_000_000, ext: "fits", kind: "fits",
        area: area, target: target, sessionDate: sessionDate, role: .light, scannedAt: 1_700_000_100
    )
}

@Test func searchAllMatchesTargetsByFolderNameOrResolvedDisplayNameOrTag() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertFile(sessionFile(
        path: "sessions/NGC_2237/2026-01-01/lights/f1.fits", target: "NGC_2237", sessionDate: "2026-01-01"
    ))
    _ = try database.upsertFile(sessionFile(
        path: "sessions/M31/2026-01-01/lights/f1.fits", target: "M31", sessionDate: "2026-01-01"
    ))
    try database.addTag(TagRecord(kind: "target", target: "M31", sessionDate: nil, tag: "widefield"))

    // Bare folder-name match.
    let byTarget = try database.searchAll(query: "2237")
    #expect(byTarget.targets.map(\.target) == ["NGC_2237"])
    #expect(byTarget.targets.first?.displayName.contains("2237") == true)

    // Resolved catalog display-name match (NGC 2237 -> "Rozetta-köd" in
    // `CatalogNames`) -- the folder name itself has no "rozetta" substring.
    let byDisplayName = try database.searchAll(query: "rozetta")
    #expect(byDisplayName.targets.map(\.target) == ["NGC_2237"])

    // Target-level tag match.
    let byTag = try database.searchAll(query: "widefield")
    #expect(byTag.targets.map(\.target) == ["M31"])
}

@Test func searchAllMatchesSessionsByTargetOrDate() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertFile(sessionFile(
        path: "sessions/M31/2026-03-15/lights/f1.fits", target: "M31", sessionDate: "2026-03-15"
    ))
    _ = try database.upsertFile(sessionFile(
        path: "calibration_library/darks/d1.fits", target: nil, sessionDate: nil, area: .calibration
    ))

    let byDate = try database.searchAll(query: "2026-03-15")
    #expect(byDate.sessions.map(\.target) == ["M31"])
    #expect(byDate.sessions.map(\.date) == ["2026-03-15"])

    // Calibration-library files (no session_date) must never surface as a
    // session hit even though their target/date columns are both NULL.
    #expect(try database.searchAll(query: "calibration_library").sessions.isEmpty)
}

@Test func searchAllCapsFileHitsButReportsTheHonestTotal() throws {
    let database = try Database(path: ":memory:")
    for i in 0..<(Database.searchFileCap + 7) {
        _ = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/frame\(i).fits"))
    }

    let results = try database.searchAll(query: "frame")
    #expect(results.files.count == Database.searchFileCap)
    #expect(results.totalFileMatches == Database.searchFileCap + 7)
    #expect(results.files.allSatisfy { $0.kind == "fits" })
}

@Test func searchAllNotesSectionReusesSearchNotes() throws {
    let database = try Database(path: ":memory:")
    try database.upsertSessionNotes(target: "M31", date: "2026-01-01", notes: ["Bortle": "5"])

    let results = try database.searchAll(query: "bortle")
    #expect(results.notes.count == 1)
    #expect(results.notes.first?.target == "M31")
    #expect(results.notes.first?.value == "5")
}

@Test func searchAllReturnsEmptyResultsForBlankQuery() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertFile(sampleFile())
    try database.upsertSessionNotes(target: "M31", date: "2026-01-01", notes: ["Bortle": "5"])

    let results = try database.searchAll(query: "   ")
    #expect(results.targets.isEmpty)
    #expect(results.sessions.isEmpty)
    #expect(results.files.isEmpty)
    #expect(results.notes.isEmpty)
    #expect(results.totalFileMatches == 0)
}

/// A literal `%`/`_` typed by the user must search for that literal
/// character, not act as a SQL `LIKE` wildcard -- otherwise a query like
/// `"50%"` would match every path in the library instead of only ones that
/// actually contain the text `"50%"`.
@Test func allSessionPairsReturnsDistinctTargetDatePairsExcludingCalibration() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertFile(sessionFile(
        path: "sessions/M31/2026-01-01/lights/f1.fits", target: "M31", sessionDate: "2026-01-01"
    ))
    _ = try database.upsertFile(sessionFile(
        path: "sessions/M31/2026-01-01/lights/f2.fits", target: "M31", sessionDate: "2026-01-01"
    ))
    _ = try database.upsertFile(sessionFile(
        path: "sessions/M42/2026-02-02/lights/f1.fits", target: "M42", sessionDate: "2026-02-02"
    ))
    _ = try database.upsertFile(sessionFile(
        path: "calibration_library/darks/d1.fits", target: nil, sessionDate: nil, area: .calibration
    ))

    let pairs = try database.allSessionPairs()
    #expect(Set(pairs.map { "\($0.target)|\($0.date)" }) == ["M31|2026-01-01", "M42|2026-02-02"])
}

@Test func searchAllTreatsPercentAndUnderscoreInQueryLiterally() throws {
    let database = try Database(path: ":memory:")
    _ = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/gain50%.fits"))
    _ = try database.upsertFile(sampleFile(path: "sessions/M31/2026-01-01/lights/other.fits"))

    let results = try database.searchAll(query: "50%")
    #expect(results.files.map(\.path) == ["sessions/M31/2026-01-01/lights/gain50%.fits"])
    #expect(results.totalFileMatches == 1)
}

// MARK: - finding_acks (schema v9, R9-T2/B5)

/// Simulates a real, already-deployed v8 database (every earlier schema step
/// applied directly via the raw `SQLiteDB`, `schema_version` stamped `8`)
/// then opens it through `Database(path:)` -- the production upgrade path --
/// and verifies the version advances to 9 and the new `finding_acks` table
/// exists and is usable, mirroring the v7->v8 migration test above.
@Test func migrateUpgradesExistingV8DatabaseToV9AddingFindingAcksTable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v8-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v8.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.exec(Database.schemaSQLv3)
        try raw.exec(Database.schemaSQLv4)
        try raw.exec(Database.schemaSQLv5)
        try raw.exec(Database.schemaSQLv6)
        try raw.exec(Database.schemaSQLv7)
        try raw.exec(Database.schemaSQLv8)
        try raw.run("INSERT INTO schema_version(version) VALUES (8);")
    }

    let database = try Database(path: path)

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 10)

    // finding_acks table exists and is usable after the same migration.
    #expect(try database.ackedKeys().isEmpty)
    try database.ackFindingGroup(category: "residue", groupKey: "*.seq", note: "known Siril leftovers")
    #expect(try database.ackedKeys() == ["residue|*.seq"])
}

// MARK: - v9 -> v10 (R11-T10/F8: sensor_profile_history + estimator_version)

@Test func migrateUpgradesExistingV9DatabaseToV10AddingSensorProfileHistoryTable() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v9-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v9.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.exec(Database.schemaSQLv3)
        try raw.exec(Database.schemaSQLv4)
        try raw.exec(Database.schemaSQLv5)
        try raw.exec(Database.schemaSQLv6)
        try raw.exec(Database.schemaSQLv7)
        try raw.exec(Database.schemaSQLv8)
        try raw.exec(Database.schemaSQLv9)
        try raw.run("INSERT INTO schema_version(version) VALUES (9);")
    }

    // A real v9 database opens without error and upgrades in place.
    let database = try Database(path: path)

    var version: Int64 = -1
    try database.db.query("SELECT version FROM schema_version LIMIT 1;") { row in
        version = row.int64(0) ?? -1
    }
    #expect(version == 10)

    // sensor_profile_history exists and is usable after the same migration.
    #expect(try database.sensorProfileHistory(camera: "ASI2600MC", gain: 100, offset: 50).isEmpty)
    try database.insertSensorProfileHistory(
        SensorProfileHistoryRecord(camera: "ASI2600MC", gain: 100, offset: 50, biasLevelADU: 501, measuredAt: 1_700_000_000, estimatorVersion: 2)
    )
    #expect(try database.sensorProfileHistory(camera: "ASI2600MC", gain: 100, offset: 50).count == 1)

    // sensor_profile itself is still readable/writable (existing data
    // untouched), and its new estimator_version column round-trips too.
    try database.upsertSensorProfile(
        SensorProfileRecord(camera: "ASI2600MC", gain: 100, offset: 50, biasLevelADU: 501, measuredAt: 1_700_000_000, estimatorVersion: 2)
    )
    let profile = try #require(try database.sensorProfile(camera: "ASI2600MC", gain: 100, offset: 50))
    #expect(profile.estimatorVersion == 2)
}

/// The migration's own backfill: an EXISTING (pre-v10) `sensor_profile` row
/// must show up as a history entry too, with `estimatorVersion` left `nil`
/// (never invented) -- otherwise a profile measured before this migration
/// would show an empty history/sparkline until the next re-measure, even
/// though `sensor_profile` itself already has a real row for it.
@Test func migrateV9ToV10BackfillsSensorProfileHistoryFromExistingSensorProfileRow() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-migrate-v9-backfill-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("v9.sqlite").path

    do {
        let raw = try SQLiteDB(path: path)
        try raw.exec(Database.schemaSQLv1)
        try raw.exec(Database.schemaSQLv2)
        try raw.exec(Database.schemaSQLv3)
        try raw.exec(Database.schemaSQLv4)
        try raw.exec(Database.schemaSQLv5)
        try raw.exec(Database.schemaSQLv6)
        try raw.exec(Database.schemaSQLv7)
        try raw.exec(Database.schemaSQLv8)
        try raw.exec(Database.schemaSQLv9)
        try raw.run("INSERT INTO schema_version(version) VALUES (9);")
        // A real pre-v10 measurement, written directly against the v7
        // `sensor_profile` schema (no `estimator_version` column exists yet
        // at this point).
        try raw.run(
            """
            INSERT INTO sensor_profile(camera, gain, offset, bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain, measured_at, frame_count)
            VALUES ('ASI2600MC', 100, 50, 501, 1.30, 0.0012, -10.0, 0.242863, 1650000000, 2);
            """
        )
    }

    let database = try Database(path: path)

    let history = try database.sensorProfileHistory(camera: "ASI2600MC", gain: 100, offset: 50)
    #expect(history.count == 1)
    let backfilled = try #require(history.first)
    #expect(backfilled.estimatorVersion == nil)
    #expect(backfilled.biasLevelADU == 501)
    #expect(backfilled.readNoiseE == 1.30)
    #expect(backfilled.measuredAt == 1_650_000_000)

    // The "latest view" row's own new column is NULL too -- never guessed.
    let profile = try #require(try database.sensorProfile(camera: "ASI2600MC", gain: 100, offset: 50))
    #expect(profile.estimatorVersion == nil)
}

@Test func insertSensorProfileHistoryThenQueryReturnsAscendingByMeasuredAt() throws {
    let database = try Database(path: ":memory:")
    try database.insertSensorProfileHistory(
        SensorProfileHistoryRecord(camera: "ASI2600MC", gain: 100, offset: 50, biasLevelADU: 510, measuredAt: 1_700_000_200, estimatorVersion: 2)
    )
    try database.insertSensorProfileHistory(
        SensorProfileHistoryRecord(camera: "ASI2600MC", gain: 100, offset: 50, biasLevelADU: 501, measuredAt: 1_700_000_000, estimatorVersion: nil)
    )

    let history = try database.sensorProfileHistory(camera: "ASI2600MC", gain: 100, offset: 50)
    #expect(history.map(\.measuredAt) == [1_700_000_000, 1_700_000_200])
    #expect(history.map(\.biasLevelADU) == [501, 510])
    #expect(history.map(\.estimatorVersion) == [nil, 2])
}

@Test func sensorProfileHistoryReturnsEmptyForUnknownCombo() throws {
    let database = try Database(path: ":memory:")
    #expect(try database.sensorProfileHistory(camera: "NoSuchCam", gain: nil, offset: nil).isEmpty)
}

@Test func sensorProfileHistoryIsScopedToItsExactComboOnly() throws {
    let database = try Database(path: ":memory:")
    try database.insertSensorProfileHistory(
        SensorProfileHistoryRecord(camera: "ASI2600MC", gain: 100, offset: 50, measuredAt: 1_700_000_000)
    )
    try database.insertSensorProfileHistory(
        SensorProfileHistoryRecord(camera: "ASI2600MC", gain: 200, offset: 50, measuredAt: 1_700_000_000)
    )

    #expect(try database.sensorProfileHistory(camera: "ASI2600MC", gain: 100, offset: 50).count == 1)
    #expect(try database.sensorProfileHistory(camera: "ASI2600MC", gain: 200, offset: 50).count == 1)
}

@Test func ackFindingGroupThenUnackRoundTrips() throws {
    let database = try Database(path: ":memory:")

    #expect(try database.ackedKeys().isEmpty)

    try database.ackFindingGroup(category: "residue", groupKey: ".DS_Store")
    #expect(try database.ackedKeys() == ["residue|.DS_Store"])

    try database.unackFindingGroup(category: "residue", groupKey: ".DS_Store")
    #expect(try database.ackedKeys().isEmpty)
}

/// The ack key is `(category, groupKey)` -- deliberately NOT `findings.id` --
/// so it survives a fresh audit run inserting a brand-new set of `findings`
/// rows (with brand-new ids) that happen to reduce to the same group.
@Test func ackFindingGroupKeySurvivesReinsertOfFindingsWithNewIDs() throws {
    let database = try Database(path: ":memory:")

    try database.ackFindingGroup(category: "residue", groupKey: "*.seq")

    let runID1 = try database.beginRun(kind: "audit", root: "/lib", configJSON: nil)
    try database.insertFinding(runID: runID1, Finding(severity: .suspicious, category: "residue", path: "a.seq", message: "m"))
    try database.finishRun(id: runID1)

    // A second, independent audit run re-discovers the same logical group
    // under brand-new finding ids.
    let runID2 = try database.beginRun(kind: "audit", root: "/lib", configJSON: nil)
    try database.insertFinding(runID: runID2, Finding(severity: .suspicious, category: "residue", path: "b.seq", message: "m"))
    try database.finishRun(id: runID2)

    #expect(try database.ackedKeys().contains("residue|*.seq"))
}

@Test func ackFindingGroupUpsertsRatherThanDuplicating() throws {
    let database = try Database(path: ":memory:")

    try database.ackFindingGroup(category: "residue", groupKey: "*.seq", note: "first")
    try database.ackFindingGroup(category: "residue", groupKey: "*.seq", note: "second")

    var rowCount = 0
    try database.db.query("SELECT ack_key FROM finding_acks;") { _ in rowCount += 1 }
    #expect(rowCount == 1)
}

// MARK: - pruneFindings (B20 retention)

/// The app's OWN `.astro_tool` database, not the image library the iron rule
/// protects -- deleting rows here (via `pruneFindings`) is ordinary DAO
/// housekeeping, same class as `markMissing`'s UPDATE or `removeTag`'s
/// DELETE elsewhere in this file.
@Test func pruneFindingsKeepsOnlyNewestAuditRunsFindings() throws {
    let database = try Database(path: ":memory:")

    var runIDs: [Int64] = []
    for i in 0..<5 {
        let runID = try database.beginRun(kind: "audit", root: "/lib", configJSON: nil)
        try database.insertFinding(runID: runID, Finding(severity: .suspicious, category: "residue", path: "run\(i).seq", message: "m"))
        try database.finishRun(id: runID)
        runIDs.append(runID)
    }

    try database.pruneFindings(keepRuns: 3)

    let keptRunIDs = Set(runIDs.suffix(3))
    var seenRunIDs: Set<Int64> = []
    try database.db.query("SELECT run_id FROM findings;") { row in
        if let id = row.int64(0) { seenRunIDs.insert(id) }
    }
    #expect(seenRunIDs == keptRunIDs)

    // The `runs` rows themselves are never deleted, only their findings.
    var runRowCount = 0
    try database.db.query("SELECT id FROM runs;") { _ in runRowCount += 1 }
    #expect(runRowCount == 5)
}

@Test func pruneFindingsLeavesOtherRunKindsUntouched() throws {
    let database = try Database(path: ":memory:")

    // A non-"audit" run with its own findings row (hypothetical -- only
    // AuditEngine writes findings in practice, but the DAO-level contract
    // must not assume that) must never be touched by an audit-scoped prune.
    let scanRunID = try database.beginRun(kind: "scan", root: "/lib", configJSON: nil)
    try database.insertFinding(runID: scanRunID, Finding(severity: .suspicious, category: "residue", path: "scan.seq", message: "m"))
    try database.finishRun(id: scanRunID)

    for i in 0..<4 {
        let runID = try database.beginRun(kind: "audit", root: "/lib", configJSON: nil)
        try database.insertFinding(runID: runID, Finding(severity: .suspicious, category: "residue", path: "run\(i).seq", message: "m"))
        try database.finishRun(id: runID)
    }

    try database.pruneFindings(keepRuns: 3)

    var scanFindingCount = 0
    try database.db.query("SELECT run_id FROM findings WHERE run_id = ?;", bind: [.int(scanRunID)]) { _ in scanFindingCount += 1 }
    #expect(scanFindingCount == 1)
}

@Test func pruneFindingsIsIdempotent() throws {
    let database = try Database(path: ":memory:")

    for i in 0..<5 {
        let runID = try database.beginRun(kind: "audit", root: "/lib", configJSON: nil)
        try database.insertFinding(runID: runID, Finding(severity: .suspicious, category: "residue", path: "run\(i).seq", message: "m"))
        try database.finishRun(id: runID)
    }

    try database.pruneFindings(keepRuns: 3)
    var countAfterFirstPrune = 0
    try database.db.query("SELECT run_id FROM findings;") { _ in countAfterFirstPrune += 1 }

    try database.pruneFindings(keepRuns: 3)
    var countAfterSecondPrune = 0
    try database.db.query("SELECT run_id FROM findings;") { _ in countAfterSecondPrune += 1 }

    #expect(countAfterFirstPrune == 3)
    #expect(countAfterSecondPrune == 3)
}

/// R11-T14/F9: `pruneFindings`'s `kind` parameter (additive, defaults to
/// `"audit"` so every test/call site above this one is unaffected) lets
/// `FixityVerifier.run` prune its own `"verify"`-kind findings independently
/// of `"audit"`'s -- pruning one kind must never touch the other's rows.
@Test func pruneFindingsWithExplicitKindOnlyPrunesThatKind() throws {
    let database = try Database(path: ":memory:")

    var verifyRunIDs: [Int64] = []
    for i in 0..<5 {
        let runID = try database.beginRun(kind: "verify", root: "/lib", configJSON: nil)
        try database.insertFinding(runID: runID, Finding(severity: .sureError, category: "content-changed", path: "f\(i).fit", message: "m"))
        try database.finishRun(id: runID)
        verifyRunIDs.append(runID)
    }

    let auditRunID = try database.beginRun(kind: "audit", root: "/lib", configJSON: nil)
    try database.insertFinding(runID: auditRunID, Finding(severity: .suspicious, category: "residue", path: "a.seq", message: "m"))
    try database.finishRun(id: auditRunID)

    try database.pruneFindings(keepRuns: 3, kind: "verify")

    var seenRunIDs: Set<Int64> = []
    try database.db.query("SELECT run_id FROM findings;") { row in
        if let id = row.int64(0) { seenRunIDs.insert(id) }
    }
    // Only the 3 newest "verify" runs' findings survive, PLUS the untouched
    // "audit" one.
    #expect(seenRunIDs == Set(verifyRunIDs.suffix(3) + [auditRunID]))
}

@Test func pruneFindingsDefaultKindStillOnlyPrunesAudit() throws {
    let database = try Database(path: ":memory:")

    let verifyRunID = try database.beginRun(kind: "verify", root: "/lib", configJSON: nil)
    try database.insertFinding(runID: verifyRunID, Finding(severity: .sureError, category: "content-changed", path: "f.fit", message: "m"))
    try database.finishRun(id: verifyRunID)

    for i in 0..<4 {
        let runID = try database.beginRun(kind: "audit", root: "/lib", configJSON: nil)
        try database.insertFinding(runID: runID, Finding(severity: .suspicious, category: "residue", path: "run\(i).seq", message: "m"))
        try database.finishRun(id: runID)
    }

    // No explicit `kind:` -- must default to "audit", exactly as it did
    // before this parameter existed.
    try database.pruneFindings(keepRuns: 3)

    var verifyFindingCount = 0
    try database.db.query("SELECT run_id FROM findings WHERE run_id = ?;", bind: [.int(verifyRunID)]) { _ in verifyFindingCount += 1 }
    #expect(verifyFindingCount == 1)
}

// MARK: - countHashedFiles (R11-T14/F9)

@Test func countHashedFilesCountsOnlyNonMissingFilesWithACachedHash() throws {
    let database = try Database(path: ":memory:")

    var hashedA = sampleFile(path: "a.fit")
    hashedA.contentHash = "h1"
    try database.upsertFile(hashedA)

    var hashedB = sampleFile(path: "b.fit")
    hashedB.contentHash = "h2"
    try database.upsertFile(hashedB)

    // No cached hash -- excluded.
    try database.upsertFile(sampleFile(path: "c.fit"))

    // Missing -- excluded even though it has a cached hash.
    var missingButHashed = sampleFile(path: "d.fit")
    missingButHashed.contentHash = "h4"
    missingButHashed.missing = true
    try database.upsertFile(missingButHashed)

    #expect(try database.countHashedFiles() == 2)
}

@Test func countHashedFilesScopesToTargetAndPathPrefix() throws {
    let database = try Database(path: ":memory:")

    var m31Light = sampleFile(path: "sessions/M31/2026-01-01/lights/a.fit")
    m31Light.target = "M31"
    m31Light.contentHash = "h1"
    try database.upsertFile(m31Light)

    var m42Light = sampleFile(path: "sessions/M42/2026-01-02/lights/b.fit")
    m42Light.target = "M42"
    m42Light.contentHash = "h2"
    try database.upsertFile(m42Light)

    var m42Flat = sampleFile(path: "sessions/M42/2026-01-02/flats/c.fit")
    m42Flat.target = "M42"
    m42Flat.contentHash = "h3"
    try database.upsertFile(m42Flat)

    #expect(try database.countHashedFiles(target: "M42") == 2)
    #expect(try database.countHashedFiles(pathPrefix: "sessions/M42/2026-01-02/lights") == 1)
    #expect(try database.countHashedFiles(target: "M42", pathPrefix: "sessions/M42/2026-01-02/flats") == 1)
}

@Test func fixityCountsTreatPathPrefixWildcardsAndCaseLiterally() throws {
    let database = try Database(path: ":memory:")
    for path in [
        "sessions/M_1/night/a.fit",
        "sessions/MX1/night/b.fit",
        "sessions/M%2/night/c.fit",
        "sessions/MX2/night/d.fit",
        "sessions/m_1/night/e.fit",
    ] {
        var record = sampleFile(path: path)
        record.contentHash = "hash"
        try database.upsertFile(record)
    }

    #expect(try database.countTrackedFiles(pathPrefix: "sessions/M_1") == 1)
    #expect(try database.countHashedFiles(pathPrefix: "sessions/M_1") == 1)
    #expect(try database.countTrackedFiles(pathPrefix: "sessions/M%2") == 1)
    #expect(try database.countHashedFiles(pathPrefix: "sessions/M%2") == 1)
}
