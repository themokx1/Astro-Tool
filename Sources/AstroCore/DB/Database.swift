import Foundation

// MARK: - Record types

/// A scanned filesystem entry, root-relative to the library. One row per
/// path in `files`; the scanner upserts these, everything else reads them.
public struct FileRecord: Codable, Equatable, Sendable {
    public var id: Int64?
    public var path: String
    public var size: Int64
    public var mtime: Double
    public var ext: String
    public var kind: String
    public var area: LibraryArea
    public var target: String?
    public var sessionDate: String?
    public var role: FrameRole
    public var contentHash: String?
    public var scannedAt: Double
    public var missing: Bool

    public init(
        id: Int64? = nil,
        path: String,
        size: Int64,
        mtime: Double,
        ext: String,
        kind: String,
        area: LibraryArea,
        target: String? = nil,
        sessionDate: String? = nil,
        role: FrameRole,
        contentHash: String? = nil,
        scannedAt: Double,
        missing: Bool = false
    ) {
        self.id = id
        self.path = path
        self.size = size
        self.mtime = mtime
        self.ext = ext
        self.kind = kind
        self.area = area
        self.target = target
        self.sessionDate = sessionDate
        self.role = role
        self.contentHash = contentHash
        self.scannedAt = scannedAt
        self.missing = missing
    }
}

/// FITS header fields extracted for a given file, one row per `files.id`.
public struct FITSMetaRecord: Codable, Equatable, Sendable {
    public var fileID: Int64
    public var exptime: Double?
    public var gain: Double?
    public var offset: Double?
    public var setTemp: Double?
    public var ccdTemp: Double?
    public var instrume: String?
    public var focallen: Double?
    public var filter: String?
    public var dateObs: String?
    public var imagetyp: String?
    public var naxis1: Int?
    public var naxis2: Int?
    public var headerJSON: String?

    public init(
        fileID: Int64,
        exptime: Double? = nil,
        gain: Double? = nil,
        offset: Double? = nil,
        setTemp: Double? = nil,
        ccdTemp: Double? = nil,
        instrume: String? = nil,
        focallen: Double? = nil,
        filter: String? = nil,
        dateObs: String? = nil,
        imagetyp: String? = nil,
        naxis1: Int? = nil,
        naxis2: Int? = nil,
        headerJSON: String? = nil
    ) {
        self.fileID = fileID
        self.exptime = exptime
        self.gain = gain
        self.offset = offset
        self.setTemp = setTemp
        self.ccdTemp = ccdTemp
        self.instrume = instrume
        self.focallen = focallen
        self.filter = filter
        self.dateObs = dateObs
        self.imagetyp = imagetyp
        self.naxis1 = naxis1
        self.naxis2 = naxis2
        self.headerJSON = headerJSON
    }
}

/// A free-form tag on either a target (`sessionDate == nil`) or one of its
/// sessions (`sessionDate` set to that session's raw date-dir name). `kind`
/// is always re-derived from `sessionDate`'s nil-ness by `Database`'s tag
/// methods -- never trust a caller-supplied `kind` that might disagree with
/// it.
public struct TagRecord: Codable, Equatable, Sendable {
    public var kind: String        // "target" | "session"
    public var target: String
    public var sessionDate: String?
    public var tag: String

    public init(kind: String, target: String, sessionDate: String?, tag: String) {
        self.kind = kind
        self.target = target
        self.sessionDate = sessionDate
        self.tag = tag
    }
}

/// A frame-quality rating, one row per `files.id`. `inputSig` fingerprints
/// the inputs the score was computed from, so a re-rate with an unchanged
/// signature can be recognized as redundant by callers.
public struct RatingRecord: Codable, Equatable, Sendable {
    public var fileID: Int64
    public var fwhm: Double?
    public var roundness: Double?
    public var starCount: Int?
    public var background: Double?
    public var saturatedFraction: Double?
    public var score: Double?
    public var ratedAt: Double
    public var sirilVersion: String?
    public var inputSig: String

    public init(
        fileID: Int64,
        fwhm: Double? = nil,
        roundness: Double? = nil,
        starCount: Int? = nil,
        background: Double? = nil,
        saturatedFraction: Double? = nil,
        score: Double? = nil,
        ratedAt: Double,
        sirilVersion: String? = nil,
        inputSig: String
    ) {
        self.fileID = fileID
        self.fwhm = fwhm
        self.roundness = roundness
        self.starCount = starCount
        self.background = background
        self.saturatedFraction = saturatedFraction
        self.score = score
        self.ratedAt = ratedAt
        self.sirilVersion = sirilVersion
        self.inputSig = inputSig
    }
}

// MARK: - Database

/// The single source of truth for a scanned library: schema owner and DAO
/// layer over `SQLiteDB`. The scanner fills `files`/`fits_meta`; audit,
/// stats, calibration, and rating all read from here.
///
/// Access is serialized with an internal lock so the class can be shared
/// across concurrent callers (e.g. a background scan and a UI read) even
/// though the underlying sqlite connection is not itself thread-safe for
/// concurrent statement execution. Marked `@unchecked Sendable` because the
/// compiler cannot see through the lock to verify this.
public final class Database: @unchecked Sendable {
    // Internal (not private) so tests in this module can verify migration
    // and DAO behavior directly against the underlying connection via
    // `@testable import`.
    let db: SQLiteDB
    private let lock = NSLock()

    // Internal (not private) so migration tests can exec this exact string
    // directly against a raw `SQLiteDB` to simulate an existing v1 database,
    // then verify `Database(path:)` upgrades it in place without touching
    // the data it already has.
    static let schemaSQLv1 = """
    CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS files(
      id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL, size INTEGER NOT NULL,
      mtime REAL NOT NULL, ext TEXT NOT NULL, kind TEXT NOT NULL,
      area TEXT NOT NULL, target TEXT, session_date TEXT, role TEXT NOT NULL,
      content_hash TEXT, scanned_at REAL NOT NULL, missing INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS idx_files_target ON files(target);
    CREATE TABLE IF NOT EXISTS fits_meta(
      file_id INTEGER PRIMARY KEY REFERENCES files(id), exptime REAL, gain REAL,
      "offset" REAL, set_temp REAL, ccd_temp REAL, instrume TEXT, focallen REAL,
      filter TEXT, date_obs TEXT, imagetyp TEXT, naxis1 INTEGER, naxis2 INTEGER,
      header_json TEXT);
    CREATE TABLE IF NOT EXISTS ratings(
      file_id INTEGER PRIMARY KEY REFERENCES files(id), fwhm REAL, roundness REAL,
      star_count INTEGER, background REAL, saturated_fraction REAL, score REAL,
      rated_at REAL, siril_version TEXT, input_sig TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS findings(
      id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL, severity TEXT NOT NULL,
      category TEXT NOT NULL, path TEXT NOT NULL, message TEXT NOT NULL,
      suggestion_json TEXT);
    CREATE TABLE IF NOT EXISTS runs(
      id INTEGER PRIMARY KEY, kind TEXT NOT NULL, started_at REAL NOT NULL,
      finished_at REAL, root TEXT NOT NULL, config_json TEXT);
    """

    private static let schemaSQLv2 = """
    CREATE TABLE IF NOT EXISTS tags(
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      target TEXT NOT NULL,
      session_date TEXT,
      tag TEXT NOT NULL,
      UNIQUE(kind, target, session_date, tag));
    """

    public init(path: String) throws {
        self.db = try SQLiteDB(path: path)
        try migrate()
    }

    /// Brings the database up to the current schema version, one version
    /// step at a time, so a real deployed v1 database upgrades in place
    /// without losing its existing rows, while a brand-new database walks
    /// straight through every step. A no-op step is skipped once its
    /// version has already been reached (re-opening an up-to-date database
    /// runs no DDL at all).
    private func migrate() throws {
        var version: Int64 = 0
        do {
            try db.query("SELECT version FROM schema_version LIMIT 1;") { row in
                version = row.int64(0) ?? 0
            }
        } catch {
            // schema_version doesn't exist yet on a brand-new database.
            version = 0
        }

        if version < 1 {
            try db.exec(Self.schemaSQLv1)
            try db.run("INSERT INTO schema_version(version) VALUES (?);", bind: [.int(1)])
            version = 1
        }

        if version < 2 {
            try db.exec(Self.schemaSQLv2)
            try db.run("UPDATE schema_version SET version = ?;", bind: [.int(2)])
            version = 2
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: files

    @discardableResult
    public func upsertFile(_ r: FileRecord) throws -> Int64 {
        try withLock {
            try db.run(
                """
                INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                  size = excluded.size, mtime = excluded.mtime, ext = excluded.ext,
                  kind = excluded.kind, area = excluded.area, target = excluded.target,
                  session_date = excluded.session_date, role = excluded.role,
                  content_hash = excluded.content_hash, scanned_at = excluded.scanned_at,
                  missing = excluded.missing;
                """,
                bind: [
                    .text(r.path), .int(r.size), .real(r.mtime), .text(r.ext), .text(r.kind),
                    .text(r.area.rawValue), r.target.map(SQLiteValue.text) ?? .null,
                    r.sessionDate.map(SQLiteValue.text) ?? .null, .text(r.role.rawValue),
                    r.contentHash.map(SQLiteValue.text) ?? .null, .real(r.scannedAt),
                    .int(r.missing ? 1 : 0),
                ]
            )

            var id: Int64?
            try db.query("SELECT id FROM files WHERE path = ?;", bind: [.text(r.path)]) { row in
                id = row.int64(0)
            }
            guard let id else {
                throw AstroError.databaseError("upsertFile: no row for path after upsert")
            }
            return id
        }
    }

    public func fileID(path: String) throws -> Int64? {
        try withLock {
            var id: Int64?
            try db.query("SELECT id FROM files WHERE path = ?;", bind: [.text(path)]) { row in
                id = row.int64(0)
            }
            return id
        }
    }

    public func file(path: String) throws -> FileRecord? {
        try withLock {
            var record: FileRecord?
            try db.query(Self.fileSelectSQL + " WHERE path = ?;", bind: [.text(path)]) { row in
                record = Self.fileRecord(from: row)
            }
            return record
        }
    }

    public func allFiles(includeMissing: Bool) throws -> [FileRecord] {
        try withLock {
            var records: [FileRecord] = []
            let sql = includeMissing ? Self.fileSelectSQL + ";" : Self.fileSelectSQL + " WHERE missing = 0;"
            try db.query(sql) { row in
                records.append(Self.fileRecord(from: row))
            }
            return records
        }
    }

    /// Marks tracked (non-missing) files as missing when their path is not
    /// in `present`. When `underSubpath` is given, only paths equal to it or
    /// nested under `<underSubpath>/` are considered. `excludingPrefixes`
    /// carves out paths equal to, or nested under, any of those prefixes --
    /// used by the scanner to protect files under a directory it couldn't
    /// read this scan (e.g. an EPERM'd subtree) from being wrongly flagged
    /// missing just because they weren't seen.
    public func markMissing(pathsNotIn present: Set<String>, underSubpath: String?, excludingPrefixes: [String] = []) throws {
        try withLock {
            var sql = "SELECT path FROM files WHERE missing = 0"
            var bind: [SQLiteValue] = []
            if let underSubpath {
                sql += " AND (path = ? OR path LIKE ?)"
                bind.append(.text(underSubpath))
                bind.append(.text(underSubpath + "/%"))
            }
            sql += ";"

            var toMark: [String] = []
            try db.query(sql, bind: bind) { row in
                guard let path = row.string(0), !present.contains(path) else { return }
                guard !Self.isUnder(path, anyOf: excludingPrefixes) else { return }
                toMark.append(path)
            }

            for path in toMark {
                try db.run("UPDATE files SET missing = 1 WHERE path = ?;", bind: [.text(path)])
            }
        }
    }

    private static func isUnder(_ path: String, anyOf prefixes: [String]) -> Bool {
        prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static let fileSelectSQL = """
    SELECT id, path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing FROM files
    """

    private static func fileRecord(from row: SQLiteRow) -> FileRecord {
        FileRecord(
            id: row.int64(0),
            path: row.string(1) ?? "",
            size: row.int64(2) ?? 0,
            mtime: row.double(3) ?? 0,
            ext: row.string(4) ?? "",
            kind: row.string(5) ?? "",
            area: row.string(6).flatMap(LibraryArea.init(rawValue:)) ?? .other,
            target: row.string(7),
            sessionDate: row.string(8),
            role: row.string(9).flatMap(FrameRole.init(rawValue:)) ?? .other,
            contentHash: row.string(10),
            scannedAt: row.double(11) ?? 0,
            missing: (row.int64(12) ?? 0) != 0
        )
    }

    // MARK: fits_meta

    public func upsertFITSMeta(_ r: FITSMetaRecord) throws {
        try withLock {
            try db.run(
                """
                INSERT INTO fits_meta(file_id, exptime, gain, "offset", set_temp, ccd_temp, instrume, focallen, filter, date_obs, imagetyp, naxis1, naxis2, header_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET
                  exptime = excluded.exptime, gain = excluded.gain, "offset" = excluded."offset",
                  set_temp = excluded.set_temp, ccd_temp = excluded.ccd_temp, instrume = excluded.instrume,
                  focallen = excluded.focallen, filter = excluded.filter, date_obs = excluded.date_obs,
                  imagetyp = excluded.imagetyp, naxis1 = excluded.naxis1, naxis2 = excluded.naxis2,
                  header_json = excluded.header_json;
                """,
                bind: [
                    .int(r.fileID), r.exptime.map(SQLiteValue.real) ?? .null, r.gain.map(SQLiteValue.real) ?? .null,
                    r.offset.map(SQLiteValue.real) ?? .null, r.setTemp.map(SQLiteValue.real) ?? .null,
                    r.ccdTemp.map(SQLiteValue.real) ?? .null, r.instrume.map(SQLiteValue.text) ?? .null,
                    r.focallen.map(SQLiteValue.real) ?? .null, r.filter.map(SQLiteValue.text) ?? .null,
                    r.dateObs.map(SQLiteValue.text) ?? .null, r.imagetyp.map(SQLiteValue.text) ?? .null,
                    r.naxis1.map { SQLiteValue.int(Int64($0)) } ?? .null,
                    r.naxis2.map { SQLiteValue.int(Int64($0)) } ?? .null,
                    r.headerJSON.map(SQLiteValue.text) ?? .null,
                ]
            )
        }
    }

    public func fitsMeta(fileID: Int64) throws -> FITSMetaRecord? {
        try withLock {
            var record: FITSMetaRecord?
            try db.query(
                """
                SELECT file_id, exptime, gain, "offset", set_temp, ccd_temp, instrume, focallen, filter, date_obs, imagetyp, naxis1, naxis2, header_json
                FROM fits_meta WHERE file_id = ?;
                """,
                bind: [.int(fileID)]
            ) { row in
                record = FITSMetaRecord(
                    fileID: row.int64(0) ?? 0,
                    exptime: row.double(1),
                    gain: row.double(2),
                    offset: row.double(3),
                    setTemp: row.double(4),
                    ccdTemp: row.double(5),
                    instrume: row.string(6),
                    focallen: row.double(7),
                    filter: row.string(8),
                    dateObs: row.string(9),
                    imagetyp: row.string(10),
                    naxis1: row.int64(11).map(Int.init),
                    naxis2: row.int64(12).map(Int.init),
                    headerJSON: row.string(13)
                )
            }
            return record
        }
    }

    // MARK: runs & findings

    public func beginRun(kind: String, root: String, configJSON: String?) throws -> Int64 {
        try withLock {
            try db.run(
                "INSERT INTO runs(kind, started_at, root, config_json) VALUES (?, ?, ?, ?);",
                bind: [.text(kind), .real(Date().timeIntervalSince1970), .text(root), configJSON.map(SQLiteValue.text) ?? .null]
            )
            return db.lastInsertRowID
        }
    }

    public func finishRun(id: Int64) throws {
        try withLock {
            try db.run(
                "UPDATE runs SET finished_at = ? WHERE id = ?;",
                bind: [.real(Date().timeIntervalSince1970), .int(id)]
            )
        }
    }

    public func insertFinding(runID: Int64, _ f: Finding) throws {
        let suggestionJSON: String?
        if let suggestion = f.suggestion {
            let data = try JSONEncoder().encode(suggestion)
            suggestionJSON = String(data: data, encoding: .utf8)
        } else {
            suggestionJSON = nil
        }

        try withLock {
            try db.run(
                "INSERT INTO findings(run_id, severity, category, path, message, suggestion_json) VALUES (?, ?, ?, ?, ?, ?);",
                bind: [
                    .int(runID), .text(f.severity.rawValue), .text(f.category), .text(f.path), .text(f.message),
                    suggestionJSON.map(SQLiteValue.text) ?? .null,
                ]
            )
        }
    }

    public func findings(runID: Int64) throws -> [Finding] {
        try withLock {
            var results: [Finding] = []
            var decodeError: Error?
            try db.query(
                "SELECT severity, category, path, message, suggestion_json FROM findings WHERE run_id = ?;",
                bind: [.int(runID)]
            ) { row in
                guard let severityRaw = row.string(0), let severity = Severity(rawValue: severityRaw) else {
                    throw AstroError.databaseError("findings: invalid severity value")
                }
                var suggestion: SuggestedAction?
                if let json = row.string(4), let data = json.data(using: .utf8) {
                    do {
                        suggestion = try JSONDecoder().decode(SuggestedAction.self, from: data)
                    } catch {
                        decodeError = error
                    }
                }
                results.append(
                    Finding(
                        severity: severity,
                        category: row.string(1) ?? "",
                        path: row.string(2) ?? "",
                        message: row.string(3) ?? "",
                        suggestion: suggestion
                    )
                )
            }
            if let decodeError { throw decodeError }
            return results
        }
    }

    // MARK: ratings

    public func upsertRating(_ r: RatingRecord) throws {
        try withLock {
            try db.run(
                """
                INSERT INTO ratings(file_id, fwhm, roundness, star_count, background, saturated_fraction, score, rated_at, siril_version, input_sig)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET
                  fwhm = excluded.fwhm, roundness = excluded.roundness, star_count = excluded.star_count,
                  background = excluded.background, saturated_fraction = excluded.saturated_fraction,
                  score = excluded.score, rated_at = excluded.rated_at, siril_version = excluded.siril_version,
                  input_sig = excluded.input_sig;
                """,
                bind: [
                    .int(r.fileID), r.fwhm.map(SQLiteValue.real) ?? .null, r.roundness.map(SQLiteValue.real) ?? .null,
                    r.starCount.map { SQLiteValue.int(Int64($0)) } ?? .null, r.background.map(SQLiteValue.real) ?? .null,
                    r.saturatedFraction.map(SQLiteValue.real) ?? .null, r.score.map(SQLiteValue.real) ?? .null,
                    .real(r.ratedAt), r.sirilVersion.map(SQLiteValue.text) ?? .null, .text(r.inputSig),
                ]
            )
        }
    }

    public func rating(fileID: Int64) throws -> RatingRecord? {
        try withLock {
            var record: RatingRecord?
            try db.query(
                """
                SELECT file_id, fwhm, roundness, star_count, background, saturated_fraction, score, rated_at, siril_version, input_sig
                FROM ratings WHERE file_id = ?;
                """,
                bind: [.int(fileID)]
            ) { row in
                record = RatingRecord(
                    fileID: row.int64(0) ?? 0,
                    fwhm: row.double(1),
                    roundness: row.double(2),
                    starCount: row.int64(3).map(Int.init),
                    background: row.double(4),
                    saturatedFraction: row.double(5),
                    score: row.double(6),
                    ratedAt: row.double(7) ?? 0,
                    sirilVersion: row.string(8),
                    inputSig: row.string(9) ?? ""
                )
            }
            return record
        }
    }

    // MARK: tags

    /// Adds a free-form tag to a target (`t.sessionDate == nil`) or one of
    /// its sessions. `kind` is always re-derived from `t.sessionDate`'s
    /// nil-ness -- `t.kind` is ignored, so a caller can never desync the two.
    /// Idempotent: adding the same (kind, target, sessionDate, tag) twice
    /// leaves exactly one row. This is enforced with an explicit existence
    /// check rather than relying on the table's `UNIQUE` constraint plus
    /// `INSERT OR IGNORE`, because SQL `NULL` is never equal to `NULL` in a
    /// `UNIQUE` index -- two target-level tags (`session_date IS NULL`)
    /// would NOT collide there and `INSERT OR IGNORE` would happily insert a
    /// duplicate row.
    public func addTag(_ t: TagRecord) throws {
        let tag = try Self.validatedTag(t.tag)
        let kind = Self.kind(forSessionDate: t.sessionDate)

        try withLock {
            var exists = false
            try Self.queryTagRows(db, target: t.target, sessionDate: t.sessionDate, tag: tag) { _ in
                exists = true
            }
            guard !exists else { return }
            try db.run(
                "INSERT INTO tags(kind, target, session_date, tag) VALUES (?, ?, ?, ?);",
                bind: [.text(kind), .text(t.target), t.sessionDate.map(SQLiteValue.text) ?? .null, .text(tag)]
            )
        }
    }

    /// Removes a tag; a no-op if it wasn't present.
    public func removeTag(_ t: TagRecord) throws {
        let tag = try Self.validatedTag(t.tag)

        try withLock {
            if let sessionDate = t.sessionDate {
                try db.run(
                    "DELETE FROM tags WHERE target = ? AND session_date = ? AND tag = ?;",
                    bind: [.text(t.target), .text(sessionDate), .text(tag)]
                )
            } else {
                try db.run(
                    "DELETE FROM tags WHERE target = ? AND session_date IS NULL AND tag = ?;",
                    bind: [.text(t.target), .text(tag)]
                )
            }
        }
    }

    /// The tags on one target (`sessionDate == nil`) or one of its sessions,
    /// sorted alphabetically.
    public func tags(target: String, sessionDate: String?) throws -> [String] {
        try withLock {
            var result: [String] = []
            if let sessionDate {
                try db.query(
                    "SELECT tag FROM tags WHERE target = ? AND session_date = ? ORDER BY tag;",
                    bind: [.text(target), .text(sessionDate)]
                ) { row in if let tag = row.string(0) { result.append(tag) } }
            } else {
                try db.query(
                    "SELECT tag FROM tags WHERE target = ? AND session_date IS NULL ORDER BY tag;",
                    bind: [.text(target)]
                ) { row in if let tag = row.string(0) { result.append(tag) } }
            }
            return result
        }
    }

    /// Every tag on record, sorted by target, then session date, then tag.
    public func allTags() throws -> [TagRecord] {
        try withLock {
            var result: [TagRecord] = []
            try db.query(
                "SELECT kind, target, session_date, tag FROM tags ORDER BY target, session_date, tag;"
            ) { row in
                result.append(
                    TagRecord(
                        kind: row.string(0) ?? "",
                        target: row.string(1) ?? "",
                        sessionDate: row.string(2),
                        tag: row.string(3) ?? ""
                    )
                )
            }
            return result
        }
    }

    /// Every target carrying `tag` as a target-level tag (session-level tags
    /// don't count), sorted by name -- backs `stats --tag`.
    public func targetsWithTag(_ tag: String) throws -> [String] {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        return try withLock {
            var result: [String] = []
            try db.query(
                "SELECT DISTINCT target FROM tags WHERE kind = 'target' AND tag = ? ORDER BY target;",
                bind: [.text(trimmed)]
            ) { row in if let target = row.string(0) { result.append(target) } }
            return result
        }
    }

    private static func kind(forSessionDate sessionDate: String?) -> String {
        sessionDate == nil ? "target" : "session"
    }

    private static func validatedTag(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AstroError.invalidInput("tag cannot be empty")
        }
        return trimmed
    }

    /// Runs `row` for every existing tag row matching `(target, sessionDate,
    /// tag)` -- shared by `addTag`'s existence check. Must be called with
    /// `lock` already held.
    private static func queryTagRows(
        _ db: SQLiteDB,
        target: String,
        sessionDate: String?,
        tag: String,
        row: (SQLiteRow) throws -> Void
    ) throws {
        if let sessionDate {
            try db.query(
                "SELECT 1 FROM tags WHERE target = ? AND session_date = ? AND tag = ?;",
                bind: [.text(target), .text(sessionDate), .text(tag)],
                row: row
            )
        } else {
            try db.query(
                "SELECT 1 FROM tags WHERE target = ? AND session_date IS NULL AND tag = ?;",
                bind: [.text(target), .text(tag)],
                row: row
            )
        }
    }
}
