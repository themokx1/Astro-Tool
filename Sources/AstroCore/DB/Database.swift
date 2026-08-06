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
    /// The filesystem inode number (`st_ino`), when known -- captured by the
    /// scanner via `FileManager.attributesOfItem(atPath:)[.systemFileNumber]`.
    /// `nil` for rows written before schema v3, or when the stat call
    /// failed. Two `FileRecord`s sharing the same non-nil `inode` are
    /// hardlinks to the same underlying data (same device implied, since the
    /// whole library lives on one volume) -- `FrameSet` uses this as its
    /// primary dedup key.
    public var inode: Int64?
    /// The filesystem hardlink count (`st_nlink`) at scan time, when known --
    /// captured alongside `inode` via `.referenceCount`. `nil` under the same
    /// conditions as `inode`. `nlink >= 2` is the signal that a file has at
    /// least one sibling hardlink somewhere (not necessarily tracked in this
    /// library, e.g. a link outside the scanned root).
    public var nlink: Int64?

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
        missing: Bool = false,
        inode: Int64? = nil,
        nlink: Int64? = nil
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
        self.inode = inode
        self.nlink = nlink
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
    /// Pixel size in microns (FITS `XPIXSZ`) -- schema v4, additive. Needed
    /// (together with `focallen`) to derive the arcsec/pixel scale for
    /// absolute FWHM measurements (`SessionQuality`). `nil` for files scanned
    /// before v4 whose `header_json` didn't carry the key, or non-FITS
    /// frames.
    public var xpixsz: Double?
    /// Camera e-/ADU gain (FITS `EGAIN`) -- schema v4, additive. Needed to
    /// convert a native background reading (ADU) into electrons for the
    /// absolute sky-background metric (`SessionQuality`).
    public var egain: Double?
    public var headerJSON: String?
    /// Plate-solved RA/Dec (degrees), schema v6, additive -- filled in by
    /// `PlateSolver` (R7-1) for frames whose ORIGINAL header carries no WCS
    /// solution at all (typically wide-field Canon CR3 lights, which have no
    /// `CRVAL1`/`CRVAL2`). Deliberately kept separate from `headerJSON`
    /// (never rewritten) so the original scanned header is never touched --
    /// `TargetCoordinates`/`FieldGeometry` fall back to these columns only
    /// when the header itself has no WCS. `nil` for every frame that hasn't
    /// been (successfully) plate-solved.
    public var solvedRA: Double?
    public var solvedDec: Double?
    /// Arcsec/pixel scale derived from the solved WCS `CD` matrix -- schema
    /// v6, additive. `nil` when not yet solved, or the solve didn't yield a
    /// full `CD` matrix.
    public var solvedScaleArcsec: Double?
    /// Field-rotation angle (degrees) derived from the solved WCS `CD`
    /// matrix -- schema v6, additive, same `nil` conditions as
    /// `solvedScaleArcsec`.
    public var solvedRotationDeg: Double?

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
        xpixsz: Double? = nil,
        egain: Double? = nil,
        headerJSON: String? = nil,
        solvedRA: Double? = nil,
        solvedDec: Double? = nil,
        solvedScaleArcsec: Double? = nil,
        solvedRotationDeg: Double? = nil
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
        self.xpixsz = xpixsz
        self.egain = egain
        self.headerJSON = headerJSON
        self.solvedRA = solvedRA
        self.solvedDec = solvedDec
        self.solvedScaleArcsec = solvedScaleArcsec
        self.solvedRotationDeg = solvedRotationDeg
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
    /// Per-Bayer-parity background medians -- schema v7, additive. Position
    /// `(row%2, col%2)` in the frame's pixel grid, NOT yet mapped to R/G/G/B
    /// (that mapping depends on the frame's `BAYERPAT` header and is done at
    /// the consumer level by `BayerMap.channelMedians`). `nil` for every
    /// frame rated before v7, and for a `.fz` frame whose `NativeStats` never
    /// ran (same "no native stats" condition as `background` itself).
    public var bg00: Double?
    public var bg01: Double?
    public var bg10: Double?
    public var bg11: Double?
    /// Where this rating's metrics came from -- schema v8, additive. `nil`
    /// means the original astrotool/Siril pipeline (`Rater.rate`, the only
    /// writer before v8); `"dss"` means `DSSIngest` harvested it from a
    /// DeepSkyStacker `<frame>.info.txt` sidecar instead. `DSSIngest` never
    /// overwrites a `nil`-source row with a `"dss"` one (see its own doc
    /// comment) -- a real Siril-measured rating always wins.
    public var source: String?

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
        inputSig: String,
        bg00: Double? = nil,
        bg01: Double? = nil,
        bg10: Double? = nil,
        bg11: Double? = nil,
        source: String? = nil
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
        self.bg00 = bg00
        self.bg01 = bg01
        self.bg10 = bg10
        self.bg11 = bg11
        self.source = source
    }

    /// Merges a partial re-measurement (`Rater`'s self-heal path, R7-B6)
    /// into this cached row: `nativeStats`/`metrics` fields that were
    /// actually recomputed this pass overwrite theirs, everything else
    /// (including whichever of `nativeStats`/`metrics` was `nil` because
    /// that half wasn't stale) is carried over from `self` UNCHANGED --
    /// this is what stops the self-heal from ever erasing a value a
    /// healthy earlier pass (or `DSSIngest`) already filled in.
    /// `sirilVersion`/`source` only change when `metrics` is non-nil (a
    /// fresh provider run that actually returned something); `ratedAt` and
    /// `inputSig` always advance to reflect this pass.
    func merging(
        nativeStats: NativeFrameStats?,
        metrics: StarMetrics?,
        sirilVersion: String?,
        inputSig: String
    ) -> RatingRecord {
        var result = self
        result.inputSig = inputSig
        result.ratedAt = Date().timeIntervalSince1970
        if let nativeStats {
            result.background = nativeStats.backgroundMedian
            result.saturatedFraction = nativeStats.saturatedFraction
            result.bg00 = nativeStats.backgroundMedian00
            result.bg01 = nativeStats.backgroundMedian01
            result.bg10 = nativeStats.backgroundMedian10
            result.bg11 = nativeStats.backgroundMedian11
        }
        if let metrics {
            result.fwhm = metrics.fwhm
            result.roundness = metrics.roundness
            result.starCount = metrics.starCount
            result.sirilVersion = sirilVersion
            result.source = nil
        }
        return result
    }
}

/// The user's own accept/reject decision for one light frame -- schema v8.
/// One row per `files.id`, harvested by `DSSIngest` from a DeepSkyStacker
/// `.dssfilelist`'s `CHECKED` column (`source == "dssfilelist"`). Kept as a
/// separate table from `ratings` (rather than another rating column)
/// because it's not a measured metric at all -- it's the user's own
/// judgment call, worth preserving even for a frame `DSSIngest` never finds
/// an `.info.txt` for.
public struct UserVerdictRecord: Codable, Equatable, Sendable {
    public var fileID: Int64
    public var accepted: Bool
    public var source: String
    public var recordedAt: Double

    public init(fileID: Int64, accepted: Bool, source: String, recordedAt: Double) {
        self.fileID = fileID
        self.accepted = accepted
        self.source = source
        self.recordedAt = recordedAt
    }
}

/// Measured sensor characterization for one `(camera, gain, offset)`
/// combo -- schema v7. Populated by `SensorProfiler.measure`, consumed by
/// `SessionQuality` (bias-pedestal subtraction) and the `astrotool sensor`
/// CLI command. Every measured field is `Optional` because each is only
/// derivable from a specific frame availability (bias level needs 1+ bias
/// frames, read noise needs 2+, dark rate needs a matching dark) -- a
/// combo with only a single bias frame still gets a row, just with
/// `readNoiseE`/`darkRateEPerS` left `nil` rather than a fabricated value.
public struct SensorProfileRecord: Codable, Equatable, Sendable {
    public var camera: String
    public var gain: Double?
    public var offset: Double?
    public var biasLevelADU: Double?
    public var readNoiseE: Double?
    public var darkRateEPerS: Double?
    public var darkTempC: Double?
    public var egain: Double?
    public var measuredAt: Double
    public var frameCount: Int?

    public init(
        camera: String,
        gain: Double? = nil,
        offset: Double? = nil,
        biasLevelADU: Double? = nil,
        readNoiseE: Double? = nil,
        darkRateEPerS: Double? = nil,
        darkTempC: Double? = nil,
        egain: Double? = nil,
        measuredAt: Double,
        frameCount: Int? = nil
    ) {
        self.camera = camera
        self.gain = gain
        self.offset = offset
        self.biasLevelADU = biasLevelADU
        self.readNoiseE = readNoiseE
        self.darkRateEPerS = darkRateEPerS
        self.darkTempC = darkTempC
        self.egain = egain
        self.measuredAt = measuredAt
        self.frameCount = frameCount
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

    // Internal (not private) for the same reason as `schemaSQLv1` -- the v2→v3
    // migration test applies this directly to a raw `SQLiteDB`.
    static let schemaSQLv2 = """
    CREATE TABLE IF NOT EXISTS tags(
      id INTEGER PRIMARY KEY,
      kind TEXT NOT NULL,
      target TEXT NOT NULL,
      session_date TEXT,
      tag TEXT NOT NULL,
      UNIQUE(kind, target, session_date, tag));
    """

    // Internal (not private) for the same reason as `schemaSQLv1`: migration
    // tests apply this directly to a raw `SQLiteDB` to simulate an existing
    // v2 database before verifying `Database(path:)` upgrades it in place.
    static let schemaSQLv3 = """
    ALTER TABLE files ADD COLUMN inode INTEGER;
    ALTER TABLE files ADD COLUMN nlink INTEGER;
    """

    // Internal (not private) for the same reason as the earlier schemaSQLv*
    // constants: migration tests apply this directly to a raw `SQLiteDB` to
    // simulate an existing v3 database before verifying `Database(path:)`
    // upgrades it in place.
    static let schemaSQLv4 = """
    ALTER TABLE fits_meta ADD COLUMN xpixsz REAL;
    ALTER TABLE fits_meta ADD COLUMN egain REAL;
    """

    // Internal (not private) for the same reason as the earlier schemaSQLv*
    // constants: migration tests apply this directly to a raw `SQLiteDB` to
    // simulate an existing v4 database before verifying `Database(path:)`
    // upgrades it in place.
    static let schemaSQLv5 = """
    CREATE TABLE IF NOT EXISTS session_notes(
      target TEXT NOT NULL,
      session_date TEXT NOT NULL,
      key TEXT NOT NULL,
      value TEXT NOT NULL,
      PRIMARY KEY(target, session_date, key));
    """

    // Internal (not private) for the same reason as the earlier schemaSQLv*
    // constants: migration tests apply this directly to a raw `SQLiteDB` to
    // simulate an existing v5 database before verifying `Database(path:)`
    // upgrades it in place. R7-1 (`PlateSolver`): plate-solved RA/Dec/scale/
    // rotation, additive columns never touched by `upsertFITSMeta`'s
    // ON-CONFLICT update -- only `updateSolvedWCS` ever writes them, so a
    // later rescan of the same file can never wipe out a solved coordinate.
    static let schemaSQLv6 = """
    ALTER TABLE fits_meta ADD COLUMN solved_ra REAL;
    ALTER TABLE fits_meta ADD COLUMN solved_dec REAL;
    ALTER TABLE fits_meta ADD COLUMN solved_scale_arcsec REAL;
    ALTER TABLE fits_meta ADD COLUMN solved_rotation_deg REAL;
    """

    // Internal (not private) for the same reason as the earlier schemaSQLv*
    // constants: migration tests apply this directly to a raw `SQLiteDB` to
    // simulate an existing v6 database before verifying `Database(path:)`
    // upgrades it in place. R7-B1: per-Bayer-parity background medians
    // (additive `ratings` columns, never touched by pre-v7 code) + the new
    // `sensor_profile` table (measured bias level/read noise/dark rate per
    // `(camera, gain, offset)` -- see `SensorProfiler`).
    static let schemaSQLv7 = """
    ALTER TABLE ratings ADD COLUMN bg_00 REAL;
    ALTER TABLE ratings ADD COLUMN bg_01 REAL;
    ALTER TABLE ratings ADD COLUMN bg_10 REAL;
    ALTER TABLE ratings ADD COLUMN bg_11 REAL;
    CREATE TABLE IF NOT EXISTS sensor_profile(
      camera TEXT NOT NULL, gain REAL, offset REAL,
      bias_level_adu REAL, read_noise_e REAL, dark_rate_e_per_s REAL, dark_temp_c REAL,
      egain REAL, measured_at REAL NOT NULL, frame_count INTEGER,
      PRIMARY KEY(camera, gain, offset));
    """

    // Internal (not private) for the same reason as the earlier schemaSQLv*
    // constants: migration tests apply this directly to a raw `SQLiteDB` to
    // simulate an existing v7 database before verifying `Database(path:)`
    // upgrades it in place. R7-B2 (`DSSIngest`): harvests star metrics and
    // the user's own accept/reject decisions that already sit in the
    // library as DeepSkyStacker `<frame>.info.txt` sidecars and
    // `.dssfilelist` files. `ratings.source` (additive, never touched by
    // pre-v8 code) distinguishes a `DSSIngest`-written row (`"dss"`) from
    // the original astrotool/Siril pipeline (`NULL`) so a later `DSSIngest`
    // run never clobbers a real Siril-measured rating. `user_verdicts` is a
    // brand-new table -- the user's own judgment call, not a measured
    // metric, so it's kept separate from `ratings` entirely.
    static let schemaSQLv8 = """
    ALTER TABLE ratings ADD COLUMN source TEXT;
    CREATE TABLE IF NOT EXISTS user_verdicts(
      file_id INTEGER PRIMARY KEY REFERENCES files(id),
      accepted INTEGER NOT NULL,
      source TEXT NOT NULL,
      recorded_at REAL NOT NULL);
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

        if version < 3 {
            try db.exec(Self.schemaSQLv3)
            try db.run("UPDATE schema_version SET version = ?;", bind: [.int(3)])
            version = 3
        }

        if version < 4 {
            try db.exec(Self.schemaSQLv4)
            try backfillXpixszEgainFromHeaderJSON()
            try db.run("UPDATE schema_version SET version = ?;", bind: [.int(4)])
            version = 4
        }

        if version < 5 {
            try db.exec(Self.schemaSQLv5)
            try db.run("UPDATE schema_version SET version = ?;", bind: [.int(5)])
            version = 5
        }

        if version < 6 {
            try db.exec(Self.schemaSQLv6)
            try db.run("UPDATE schema_version SET version = ?;", bind: [.int(6)])
            version = 6
        }

        if version < 7 {
            try db.exec(Self.schemaSQLv7)
            try db.run("UPDATE schema_version SET version = ?;", bind: [.int(7)])
            version = 7
        }

        if version < 8 {
            try db.exec(Self.schemaSQLv8)
            try db.run("UPDATE schema_version SET version = ?;", bind: [.int(8)])
            version = 8
        }
    }

    /// One-time v3->v4 upgrade step: `xpixsz`/`egain` are new dedicated
    /// columns, but every FITS file scanned before v4 already has the same
    /// values sitting in its `header_json` blob (the full raw card dump) --
    /// no file I/O needed, just parse what's already in the database. Rows
    /// with no `header_json` (non-FITS frames, or a pre-v4 row whose header
    /// simply lacked both keys) are left with `NULL` in the new columns,
    /// same as `ALTER TABLE ADD COLUMN`'s default for every row.
    private func backfillXpixszEgainFromHeaderJSON() throws {
        var rows: [(fileID: Int64, headerJSON: String)] = []
        try db.query("SELECT file_id, header_json FROM fits_meta WHERE header_json IS NOT NULL;") { row in
            guard let fileID = row.int64(0), let json = row.string(1) else { return }
            rows.append((fileID, json))
        }

        for (fileID, json) in rows {
            guard let data = json.data(using: .utf8),
                  let cards = try? JSONDecoder().decode([String: String].self, from: data)
            else { continue }

            let xpixsz = cards["XPIXSZ"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let egain = cards["EGAIN"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard xpixsz != nil || egain != nil else { continue }

            try db.run(
                "UPDATE fits_meta SET xpixsz = COALESCE(?, xpixsz), egain = COALESCE(?, egain) WHERE file_id = ?;",
                bind: [xpixsz.map(SQLiteValue.real) ?? .null, egain.map(SQLiteValue.real) ?? .null, .int(fileID)]
            )
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
                INSERT INTO files(path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing, inode, nlink)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                  size = excluded.size, mtime = excluded.mtime, ext = excluded.ext,
                  kind = excluded.kind, area = excluded.area, target = excluded.target,
                  session_date = excluded.session_date, role = excluded.role,
                  content_hash = excluded.content_hash, scanned_at = excluded.scanned_at,
                  missing = excluded.missing, inode = excluded.inode, nlink = excluded.nlink;
                """,
                bind: [
                    .text(r.path), .int(r.size), .real(r.mtime), .text(r.ext), .text(r.kind),
                    .text(r.area.rawValue), r.target.map(SQLiteValue.text) ?? .null,
                    r.sessionDate.map(SQLiteValue.text) ?? .null, .text(r.role.rawValue),
                    r.contentHash.map(SQLiteValue.text) ?? .null, .real(r.scannedAt),
                    .int(r.missing ? 1 : 0),
                    r.inode.map(SQLiteValue.int) ?? .null, r.nlink.map(SQLiteValue.int) ?? .null,
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

    /// Whether any tracked (non-missing) file's path ends with `suffix` --
    /// a single indexed-`LIKE`-free existence probe, cheaper than loading
    /// `allFiles` just to answer a yes/no question. Used by the app to gate
    /// the "DSS-adatok beolvasása" quick button on whether any
    /// `.dssfilelist` is actually in the library (R7-B2).
    public func hasTrackedFileWithSuffix(_ suffix: String) throws -> Bool {
        try withLock {
            var found = false
            try db.query(
                "SELECT 1 FROM files WHERE missing = 0 AND path LIKE ? LIMIT 1;",
                bind: [.text("%" + suffix)]
            ) { _ in found = true }
            return found
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
    SELECT id, path, size, mtime, ext, kind, area, target, session_date, role, content_hash, scanned_at, missing, inode, nlink FROM files
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
            missing: (row.int64(12) ?? 0) != 0,
            inode: row.int64(13),
            nlink: row.int64(14)
        )
    }

    /// Backfills `inode`/`nlink` for one existing row without touching any
    /// other column -- used by the scanner's unchanged-file healing pass so
    /// a row scanned before schema v3 (or one whose stat call failed) picks
    /// up real values on a later rescan without a full re-upsert (which
    /// would also bump `scanned_at` and disturb the "no row churn on an
    /// unchanged file" contract other callers rely on).
    public func backfillInode(id: Int64, inode: Int64?, nlink: Int64?) throws {
        try withLock {
            try db.run(
                "UPDATE files SET inode = ?, nlink = ? WHERE id = ?;",
                bind: [inode.map(SQLiteValue.int) ?? .null, nlink.map(SQLiteValue.int) ?? .null, .int(id)]
            )
        }
    }

    // MARK: fits_meta

    public func upsertFITSMeta(_ r: FITSMetaRecord) throws {
        try withLock {
            try db.run(
                """
                INSERT INTO fits_meta(file_id, exptime, gain, "offset", set_temp, ccd_temp, instrume, focallen, filter, date_obs, imagetyp, naxis1, naxis2, xpixsz, egain, header_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET
                  exptime = excluded.exptime, gain = excluded.gain, "offset" = excluded."offset",
                  set_temp = excluded.set_temp, ccd_temp = excluded.ccd_temp, instrume = excluded.instrume,
                  focallen = excluded.focallen, filter = excluded.filter, date_obs = excluded.date_obs,
                  imagetyp = excluded.imagetyp, naxis1 = excluded.naxis1, naxis2 = excluded.naxis2,
                  xpixsz = excluded.xpixsz, egain = excluded.egain,
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
                    r.xpixsz.map(SQLiteValue.real) ?? .null, r.egain.map(SQLiteValue.real) ?? .null,
                    r.headerJSON.map(SQLiteValue.text) ?? .null,
                ]
            )
        }
    }

    /// Persists a `PlateSolver` result's WCS solution for one file, WITHOUT
    /// touching any other `fits_meta` column (in particular `header_json`,
    /// the original scanned header, which must never be rewritten). A plain
    /// targeted `UPDATE` rather than routing through `upsertFITSMeta` -- that
    /// call's `ON CONFLICT` clause sets every column from the caller's
    /// record, so a scanner-built `FITSMetaRecord` (which never carries a
    /// solved coordinate) would silently null these back out on the very
    /// next rescan. No-op (affects zero rows) if `fileID` has no `fits_meta`
    /// row yet -- callers only ever call this for files already scanned.
    public func updateSolvedWCS(fileID: Int64, ra: Double?, dec: Double?, scale: Double?, rotation: Double?) throws {
        try withLock {
            try db.run(
                """
                UPDATE fits_meta
                SET solved_ra = ?, solved_dec = ?, solved_scale_arcsec = ?, solved_rotation_deg = ?
                WHERE file_id = ?;
                """,
                bind: [
                    ra.map(SQLiteValue.real) ?? .null, dec.map(SQLiteValue.real) ?? .null,
                    scale.map(SQLiteValue.real) ?? .null, rotation.map(SQLiteValue.real) ?? .null,
                    .int(fileID),
                ]
            )
        }
    }

    public func fitsMeta(fileID: Int64) throws -> FITSMetaRecord? {
        try withLock {
            var record: FITSMetaRecord?
            try db.query(
                """
                SELECT file_id, exptime, gain, "offset", set_temp, ccd_temp, instrume, focallen, filter, date_obs, imagetyp, naxis1, naxis2, xpixsz, egain, header_json, solved_ra, solved_dec, solved_scale_arcsec, solved_rotation_deg
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
                    xpixsz: row.double(13),
                    egain: row.double(14),
                    headerJSON: row.string(15),
                    solvedRA: row.double(16),
                    solvedDec: row.double(17),
                    solvedScaleArcsec: row.double(18),
                    solvedRotationDeg: row.double(19)
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

    /// The `started_at` of the most recent `runs` row of the given `kind`
    /// (e.g. `"scan"`, `"audit"`), or `nil` if none exist yet -- the app
    /// layer's "has this root ever been scanned" signal (R9-T1's first-run
    /// flow) and its toolbar "Utolsó: <relatív idő>" caption, both spanning
    /// launches since it's read from disk rather than in-memory state.
    public func lastRunDate(kind: String) throws -> Date? {
        try withLock {
            var timestamp: Double?
            try db.query(
                "SELECT started_at FROM runs WHERE kind = ? ORDER BY started_at DESC LIMIT 1;",
                bind: [.text(kind)]
            ) { row in
                timestamp = row.double(0)
            }
            return timestamp.map(Date.init(timeIntervalSince1970:))
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
                INSERT INTO ratings(file_id, fwhm, roundness, star_count, background, saturated_fraction, score, rated_at, siril_version, input_sig, bg_00, bg_01, bg_10, bg_11, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET
                  fwhm = excluded.fwhm, roundness = excluded.roundness, star_count = excluded.star_count,
                  background = excluded.background, saturated_fraction = excluded.saturated_fraction,
                  score = excluded.score, rated_at = excluded.rated_at, siril_version = excluded.siril_version,
                  input_sig = excluded.input_sig, bg_00 = excluded.bg_00, bg_01 = excluded.bg_01,
                  bg_10 = excluded.bg_10, bg_11 = excluded.bg_11, source = excluded.source;
                """,
                bind: [
                    .int(r.fileID), r.fwhm.map(SQLiteValue.real) ?? .null, r.roundness.map(SQLiteValue.real) ?? .null,
                    r.starCount.map { SQLiteValue.int(Int64($0)) } ?? .null, r.background.map(SQLiteValue.real) ?? .null,
                    r.saturatedFraction.map(SQLiteValue.real) ?? .null, r.score.map(SQLiteValue.real) ?? .null,
                    .real(r.ratedAt), r.sirilVersion.map(SQLiteValue.text) ?? .null, .text(r.inputSig),
                    r.bg00.map(SQLiteValue.real) ?? .null, r.bg01.map(SQLiteValue.real) ?? .null,
                    r.bg10.map(SQLiteValue.real) ?? .null, r.bg11.map(SQLiteValue.real) ?? .null,
                    r.source.map(SQLiteValue.text) ?? .null,
                ]
            )
        }
    }

    public func rating(fileID: Int64) throws -> RatingRecord? {
        try withLock {
            var record: RatingRecord?
            try db.query(
                """
                SELECT file_id, fwhm, roundness, star_count, background, saturated_fraction, score, rated_at, siril_version, input_sig, bg_00, bg_01, bg_10, bg_11, source
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
                    inputSig: row.string(9) ?? "",
                    bg00: row.double(10),
                    bg01: row.double(11),
                    bg10: row.double(12),
                    bg11: row.double(13),
                    source: row.string(14)
                )
            }
            return record
        }
    }

    // MARK: user_verdicts (R7-B2)

    /// Upserts one file's accept/reject verdict. `ON CONFLICT` targets the
    /// primary key (`file_id`) -- a re-ingest of the same `.dssfilelist`
    /// (or a different one covering the same frame) replaces the prior
    /// verdict in place rather than accumulating duplicate rows.
    public func upsertUserVerdict(_ v: UserVerdictRecord) throws {
        try withLock {
            try db.run(
                """
                INSERT INTO user_verdicts(file_id, accepted, source, recorded_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET
                  accepted = excluded.accepted, source = excluded.source, recorded_at = excluded.recorded_at;
                """,
                bind: [.int(v.fileID), .int(v.accepted ? 1 : 0), .text(v.source), .real(v.recordedAt)]
            )
        }
    }

    /// The recorded verdict for one file, `nil` if none was ever ingested.
    public func userVerdict(fileID: Int64) throws -> UserVerdictRecord? {
        try withLock {
            var record: UserVerdictRecord?
            try db.query(
                "SELECT file_id, accepted, source, recorded_at FROM user_verdicts WHERE file_id = ?;",
                bind: [.int(fileID)]
            ) { row in
                record = UserVerdictRecord(
                    fileID: row.int64(0) ?? 0,
                    accepted: (row.int64(1) ?? 0) != 0,
                    source: row.string(2) ?? "",
                    recordedAt: row.double(3) ?? 0
                )
            }
            return record
        }
    }

    /// Counts of accepted/rejected verdicts among LIGHT frames of one
    /// target's session -- joined through `files` so the caller never needs
    /// to resolve file IDs itself. `(0, 0)` when the session has no
    /// recorded verdicts at all (e.g. never DSS-ingested).
    public func acceptedCounts(target: String, date: String) throws -> (accepted: Int, rejected: Int) {
        try withLock {
            var accepted = 0
            var rejected = 0
            try db.query(
                """
                SELECT uv.accepted FROM user_verdicts uv
                JOIN files f ON f.id = uv.file_id
                WHERE f.target = ? AND f.session_date = ?;
                """,
                bind: [.text(target), .text(date)]
            ) { row in
                if (row.int64(0) ?? 0) != 0 { accepted += 1 } else { rejected += 1 }
            }
            return (accepted, rejected)
        }
    }

    // MARK: sensor_profile (R7-B1)

    /// Upserts one `(camera, gain, offset)` combo's measured profile.
    /// `ON CONFLICT` targets the composite primary key -- a re-measure
    /// (e.g. after taking fresh bias frames) replaces every measured column
    /// in place rather than accumulating duplicate rows. Note SQLite's
    /// uniqueness on a composite key never fires when `gain`/`offset` is
    /// `NULL` on both sides (`NULL` is never `= NULL`); every real camera
    /// this targets (ASI-class) always reports both, so this is a
    /// theoretical gap, not a practical one.
    public func upsertSensorProfile(_ r: SensorProfileRecord) throws {
        try withLock {
            try db.run(
                """
                INSERT INTO sensor_profile(camera, gain, offset, bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain, measured_at, frame_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(camera, gain, offset) DO UPDATE SET
                  bias_level_adu = excluded.bias_level_adu, read_noise_e = excluded.read_noise_e,
                  dark_rate_e_per_s = excluded.dark_rate_e_per_s, dark_temp_c = excluded.dark_temp_c,
                  egain = excluded.egain, measured_at = excluded.measured_at, frame_count = excluded.frame_count;
                """,
                bind: [
                    .text(r.camera), r.gain.map(SQLiteValue.real) ?? .null, r.offset.map(SQLiteValue.real) ?? .null,
                    r.biasLevelADU.map(SQLiteValue.real) ?? .null, r.readNoiseE.map(SQLiteValue.real) ?? .null,
                    r.darkRateEPerS.map(SQLiteValue.real) ?? .null, r.darkTempC.map(SQLiteValue.real) ?? .null,
                    r.egain.map(SQLiteValue.real) ?? .null, .real(r.measuredAt),
                    r.frameCount.map { SQLiteValue.int(Int64($0)) } ?? .null,
                ]
            )
        }
    }

    /// The measured profile for an EXACT `(camera, gain, offset)` match --
    /// `IS` (SQLite's null-safe equality) rather than `=` so a combo with a
    /// `NULL` gain/offset can still be looked up consistently. `nil` when no
    /// profile has been measured for this exact combo -- callers (in
    /// particular `SessionQuality`) must never fall back to a different
    /// gain/offset's profile; see this method's call sites for why.
    public func sensorProfile(camera: String, gain: Double?, offset: Double?) throws -> SensorProfileRecord? {
        try withLock {
            var record: SensorProfileRecord?
            try db.query(
                """
                SELECT camera, gain, offset, bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain, measured_at, frame_count
                FROM sensor_profile WHERE camera = ? AND gain IS ? AND offset IS ?;
                """,
                bind: [.text(camera), gain.map(SQLiteValue.real) ?? .null, offset.map(SQLiteValue.real) ?? .null]
            ) { row in
                record = Self.sensorProfileRecord(from: row)
            }
            return record
        }
    }

    /// Every measured sensor profile on record, sorted by camera then gain
    /// then offset -- backs `astrotool sensor` (no `--measure`) and the
    /// app's read-only "Szenzor-profilok" list.
    public func allSensorProfiles() throws -> [SensorProfileRecord] {
        try withLock {
            var results: [SensorProfileRecord] = []
            try db.query(
                """
                SELECT camera, gain, offset, bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain, measured_at, frame_count
                FROM sensor_profile ORDER BY camera, gain, offset;
                """
            ) { row in
                results.append(Self.sensorProfileRecord(from: row))
            }
            return results
        }
    }

    private static func sensorProfileRecord(from row: SQLiteRow) -> SensorProfileRecord {
        SensorProfileRecord(
            camera: row.string(0) ?? "",
            gain: row.double(1),
            offset: row.double(2),
            biasLevelADU: row.double(3),
            readNoiseE: row.double(4),
            darkRateEPerS: row.double(5),
            darkTempC: row.double(6),
            egain: row.double(7),
            measuredAt: row.double(8) ?? 0,
            frameCount: row.int64(9).map(Int.init)
        )
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

    // MARK: session_notes (R6-4)

    /// Replaces EVERY note stored for `(target, date)` with `notes` --
    /// delete-then-insert within the same locked section, so a caller never
    /// observes a partial (some-old-some-new) state. This is the class's own
    /// `.astro_tool` database, not the image library the iron rule protects
    /// -- deleting rows here is ordinary DAO housekeeping, same as
    /// `markMissing`'s `UPDATE` or `removeTag`'s `DELETE` elsewhere in this
    /// file. Called by the scanner every time a session's `README.txt` is
    /// scanned as NEW or CHANGED (see `LibraryScanner.captureReadmeNotes`),
    /// so a line the user deleted from the file doesn't linger in the
    /// database forever.
    public func upsertSessionNotes(target: String, date: String, notes: [String: String]) throws {
        try withLock {
            try db.run(
                "DELETE FROM session_notes WHERE target = ? AND session_date = ?;",
                bind: [.text(target), .text(date)]
            )
            for (key, value) in notes {
                try db.run(
                    "INSERT INTO session_notes(target, session_date, key, value) VALUES (?, ?, ?, ?);",
                    bind: [.text(target), .text(date), .text(key), .text(value)]
                )
            }
        }
    }

    /// Every note on record for one session, `[:]` when none exist.
    public func sessionNotes(target: String, date: String) throws -> [String: String] {
        try withLock {
            var result: [String: String] = [:]
            try db.query(
                "SELECT key, value FROM session_notes WHERE target = ? AND session_date = ?;",
                bind: [.text(target), .text(date)]
            ) { row in
                guard let key = row.string(0), let value = row.string(1) else { return }
                result[key] = value
            }
            return result
        }
    }

    /// Every `(target, date, key, value)` row whose `key` or `value`
    /// contains `query` -- backs `astrotool search`. Plain SQL `LIKE`,
    /// which SQLite already matches case-insensitively for ASCII text with
    /// no extra `COLLATE` needed; `query` is wrapped in `%...%` wildcards so
    /// a bare substring (not a full LIKE pattern) is what the caller hands
    /// in. Sorted by target, then date, then key for a stable, readable
    /// grouping at the CLI layer.
    public func searchNotes(query: String) throws -> [(target: String, date: String, key: String, value: String)] {
        try withLock {
            var result: [(target: String, date: String, key: String, value: String)] = []
            let pattern = "%" + query + "%"
            try db.query(
                """
                SELECT target, session_date, key, value FROM session_notes
                WHERE key LIKE ? OR value LIKE ?
                ORDER BY target, session_date, key;
                """,
                bind: [.text(pattern), .text(pattern)]
            ) { row in
                guard let target = row.string(0), let date = row.string(1),
                      let key = row.string(2), let value = row.string(3)
                else { return }
                result.append((target, date, key, value))
            }
            return result
        }
    }
}
