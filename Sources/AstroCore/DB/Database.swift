import Foundation

extension Array {
    /// Splits into consecutive slices of at most `size` elements each --
    /// used to keep `WHERE x IN (...)` queries under SQLite's bound-parameter
    /// limit (default 999) for batch lookups like `fitsMetaBatch`.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Record types

/// Persisted metadata for one row in `runs`. Keeping this query result in
/// AstroCore lets the app restore operation-specific state after relaunch
/// without reaching into SQLite directly.
public struct RunSummary: Equatable, Sendable {
    public let id: Int64
    public let kind: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let root: String
    public let configJSON: String?

    public init(
        id: Int64,
        kind: String,
        startedAt: Date,
        finishedAt: Date?,
        root: String,
        configJSON: String?
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.root = root
        self.configJSON = configJSON
    }
}

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
    /// `SensorProfiler.estimatorVersion` at the moment this (latest)
    /// measurement was taken -- schema v10, additive (R11-T10/F8). `nil`
    /// for every row that predates this column (an existing v9 database's
    /// `sensor_profile` rows migrate with `NULL` here, deliberately never a
    /// guessed version) as well as for a row a pre-v10 code path might still
    /// write. `SensorPage`'s staleness warning treats `nil` the same as "too
    /// old": less than `SensorProfiler.estimatorVersion`.
    public var estimatorVersion: Int?

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
        frameCount: Int? = nil,
        estimatorVersion: Int? = nil
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
        self.estimatorVersion = estimatorVersion
    }

    /// `true` when this profile's measurement predates the current
    /// `SensorProfiler.estimatorVersion` -- schema-version generalization
    /// (R11-T10/F8) of what used to be a hardcoded fix-date check in
    /// `SensorPage`. `nil` (unknown/pre-versioning) counts as stale too.
    public var isEstimatorStale: Bool {
        guard let estimatorVersion else { return true }
        return estimatorVersion < SensorProfiler.estimatorVersion
    }
}

/// One APPEND-ONLY measurement of a `(camera, gain, offset)` combo's sensor
/// characteristics -- schema v10 (R11-T10/F8). Unlike `sensor_profile`
/// (which `SensorProfiler.measure` upserts in place, always holding just the
/// LATEST measurement per combo), a row here is never updated or replaced:
/// every `SensorProfiler.measure` run appends one NEW row per combo it
/// measures, so a user who re-measures (fresh bias/dark frames, or after an
/// estimator fix) can see how the numbers moved over time, not just "the
/// last one wins". `estimatorVersion` records `SensorProfiler
/// .estimatorVersion` at the moment of THIS measurement -- `nil` for rows
/// backfilled from a pre-v10 `sensor_profile` row during migration (an
/// honest "unknown, pre-versioning estimator" marker, never a guessed
/// version number).
public struct SensorProfileHistoryRecord: Codable, Equatable, Sendable {
    public var id: Int64?
    public var camera: String
    public var gain: Double?
    public var offset: Double?
    public var biasLevelADU: Double?
    public var readNoiseE: Double?
    public var darkRateEPerS: Double?
    public var darkTempC: Double?
    public var egain: Double?
    public var measuredAt: Double
    public var estimatorVersion: Int?

    public init(
        id: Int64? = nil,
        camera: String,
        gain: Double? = nil,
        offset: Double? = nil,
        biasLevelADU: Double? = nil,
        readNoiseE: Double? = nil,
        darkRateEPerS: Double? = nil,
        darkTempC: Double? = nil,
        egain: Double? = nil,
        measuredAt: Double,
        estimatorVersion: Int? = nil
    ) {
        self.id = id
        self.camera = camera
        self.gain = gain
        self.offset = offset
        self.biasLevelADU = biasLevelADU
        self.readNoiseE = readNoiseE
        self.darkRateEPerS = darkRateEPerS
        self.darkTempC = darkTempC
        self.egain = egain
        self.measuredAt = measuredAt
        self.estimatorVersion = estimatorVersion
    }
}

/// One acknowledged finding-group row (`finding_acks`, R9-T2/B5) -- the ack
/// DAO's fuller read type, added for `astrotool ack list` (R10-B8). The app
/// only ever needs `ackedKeys()`'s lighter `Set<String>` membership test, so
/// this is purely additive, not a replacement for it.
public struct FindingAckRecord: Codable, Equatable, Sendable {
    public var category: String
    public var groupKey: String
    /// `Date().timeIntervalSince1970` at the moment this group was acked
    /// (or last re-acked) -- same epoch-seconds convention every other
    /// `*At`/`*edAt` column in this schema uses.
    public var ackedAt: Double
    public var note: String?

    public init(category: String, groupKey: String, ackedAt: Double, note: String? = nil) {
        self.category = category
        self.groupKey = groupKey
        self.ackedAt = ackedAt
        self.note = note
    }
}

/// The sidebar's ⌘F -> `SearchResultsPage` result set (R9-T6/B3):
/// `Database.searchAll`'s four sections. See that method's doc comment for
/// exactly what does and doesn't match, and why `notes` never sees notes
/// written via the T6 note editor (`SessionNoteStore`) on its own.
public struct SearchResults: Sendable {
    public var targets: [(target: String, displayName: String)]
    public var sessions: [(target: String, date: String)]
    public var files: [(path: String, kind: String, sizeBytes: Int64)]
    /// True count of `files` `LIKE`-matches before the cap `searchAll`
    /// applies to the `files` array itself.
    public var totalFileMatches: Int
    public var notes: [(target: String, date: String, key: String, value: String)]

    public init(
        targets: [(target: String, displayName: String)] = [],
        sessions: [(target: String, date: String)] = [],
        files: [(path: String, kind: String, sizeBytes: Int64)] = [],
        totalFileMatches: Int = 0,
        notes: [(target: String, date: String, key: String, value: String)] = []
    ) {
        self.targets = targets
        self.sessions = sessions
        self.files = files
        self.totalFileMatches = totalFileMatches
        self.notes = notes
    }

    /// `true` when every section is empty -- `SearchResultsPage`'s
    /// `ContentUnavailableView.search` gate.
    public var isEmpty: Bool {
        targets.isEmpty && sessions.isEmpty && files.isEmpty && notes.isEmpty
    }
}

/// Manual `Encodable` conformance (R10-B8, `astrotool search --all --json`)
/// -- tuples can never conform to `Encodable` themselves, and the stored
/// properties above must stay tuples: `SearchResultsPage` (`AstroToolApp`,
/// out of scope for this change) types its row-builder functions against
/// those exact tuple shapes (e.g. `targetRow(_ hit: (target: String,
/// displayName: String))`), so swapping them for nominal DTOs would break
/// the app's call sites. Encoding each section through a private one-off DTO
/// sidesteps that entirely -- `SearchResults` itself gains `--json` support
/// with no change to how the app already reads it. `Decodable` is
/// deliberately not added alongside: nothing anywhere reconstructs a
/// `SearchResults` from JSON, only `astrotool search --all --json` ever
/// produces one.
extension SearchResults: Encodable {
    private enum CodingKeys: String, CodingKey {
        case targets, sessions, files, totalFileMatches, notes
    }

    private struct TargetHit: Encodable { let target: String; let displayName: String }
    private struct SessionHit: Encodable { let target: String; let date: String }
    private struct FileHit: Encodable { let path: String; let kind: String; let sizeBytes: Int64 }
    private struct NoteHit: Encodable { let target: String; let date: String; let key: String; let value: String }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targets.map { TargetHit(target: $0.target, displayName: $0.displayName) }, forKey: .targets)
        try container.encode(sessions.map { SessionHit(target: $0.target, date: $0.date) }, forKey: .sessions)
        try container.encode(files.map { FileHit(path: $0.path, kind: $0.kind, sizeBytes: $0.sizeBytes) }, forKey: .files)
        try container.encode(totalFileMatches, forKey: .totalFileMatches)
        try container.encode(notes.map { NoteHit(target: $0.target, date: $0.date, key: $0.key, value: $0.value) }, forKey: .notes)
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

    // Internal (not private) for the same reason as the earlier schemaSQLv*
    // constants: migration tests apply this directly to a raw `SQLiteDB` to
    // simulate an existing v8 database before verifying `Database(path:)`
    // upgrades it in place. R9-T2/B5: acknowledged audit-finding groups.
    // `ack_key` is `"<category>|<groupKey>"` (`FindingGrouper`'s own group
    // key) rather than `findings.id` -- the whole point is that an ack
    // survives a re-audit, which assigns every finding a brand-new id.
    static let schemaSQLv9 = """
    CREATE TABLE IF NOT EXISTS finding_acks(
      ack_key TEXT PRIMARY KEY,
      category TEXT NOT NULL,
      group_key TEXT NOT NULL,
      acked_at REAL NOT NULL,
      note TEXT);
    """

    // Internal (not private) for the same reason as the earlier schemaSQLv*
    // constants: migration tests apply this directly to a raw `SQLiteDB` to
    // simulate an existing v9 database before verifying `Database(path:)`
    // upgrades it in place. R11-T10/F8: `sensor_profile` gains
    // `estimator_version` (additive column, `NULL` for every pre-existing
    // row -- never guessed, see `SensorProfileRecord.estimatorVersion`'s own
    // doc comment) alongside a brand-new APPEND-ONLY `sensor_profile_history`
    // table that records every measurement, not just the latest one.
    static let schemaSQLv10 = """
    ALTER TABLE sensor_profile ADD COLUMN estimator_version INTEGER;
    CREATE TABLE IF NOT EXISTS sensor_profile_history(
      id INTEGER PRIMARY KEY,
      camera TEXT NOT NULL, gain REAL, offset REAL,
      bias_level_adu REAL, read_noise_e REAL, dark_rate_e_per_s REAL, dark_temp_c REAL,
      egain REAL, measured_at REAL NOT NULL, estimator_version INTEGER);
    CREATE INDEX IF NOT EXISTS idx_sensor_profile_history_combo ON sensor_profile_history(camera, gain, offset);
    """

    /// Capture groups are additive tool metadata: they describe how files
    /// in one target/date session belong together without modifying their
    /// raw headers. Sources map whole folder prefixes; assignments handle
    /// exceptional or mixed legacy folders at file granularity.
    static let schemaSQLv11 = """
    CREATE TABLE IF NOT EXISTS capture_groups(
      id INTEGER PRIMARY KEY,
      target TEXT NOT NULL,
      session_date TEXT NOT NULL,
      slug TEXT NOT NULL,
      display_name TEXT NOT NULL,
      sensor_mode TEXT NOT NULL DEFAULT 'unknown',
      signal_mode TEXT NOT NULL DEFAULT 'unknown',
      filter_manufacturer TEXT,
      filter_model TEXT,
      filter_name TEXT,
      notes TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      UNIQUE(target, session_date, slug));
    CREATE INDEX IF NOT EXISTS idx_capture_groups_session ON capture_groups(target, session_date);

    CREATE TABLE IF NOT EXISTS capture_sources(
      id INTEGER PRIMARY KEY,
      capture_group_id INTEGER NOT NULL REFERENCES capture_groups(id),
      relative_path TEXT NOT NULL UNIQUE,
      role TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_capture_sources_group ON capture_sources(capture_group_id);

    CREATE TABLE IF NOT EXISTS file_capture_assignments(
      file_id INTEGER PRIMARY KEY REFERENCES files(id),
      capture_group_id INTEGER NOT NULL REFERENCES capture_groups(id),
      sensor_mode_override TEXT,
      signal_mode_override TEXT,
      filter_manufacturer_override TEXT,
      filter_model_override TEXT,
      filter_name_override TEXT,
      assignment_source TEXT NOT NULL,
      assigned_at REAL NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_file_capture_assignments_group ON file_capture_assignments(capture_group_id);
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

        if version < 9 {
            try db.exec(Self.schemaSQLv9)
            try db.run("UPDATE schema_version SET version = ?;", bind: [.int(9)])
            version = 9
        }

        if version < 10 {
            try db.exec("BEGIN IMMEDIATE;")
            do {
                if try !columnExists(table: "sensor_profile", column: "estimator_version") {
                    try db.exec("ALTER TABLE sensor_profile ADD COLUMN estimator_version INTEGER;")
                }
                if try !tableExists("sensor_profile_history") {
                    try db.exec(
                        """
                        CREATE TABLE sensor_profile_history(
                          id INTEGER PRIMARY KEY,
                          camera TEXT NOT NULL, gain REAL, offset REAL,
                          bias_level_adu REAL, read_noise_e REAL, dark_rate_e_per_s REAL, dark_temp_c REAL,
                          egain REAL, measured_at REAL NOT NULL, estimator_version INTEGER);
                        """
                    )
                }
                try db.exec("CREATE INDEX IF NOT EXISTS idx_sensor_profile_history_combo ON sensor_profile_history(camera, gain, offset);")
                try backfillSensorProfileHistoryFromExistingProfiles()
                // Version stamp is deliberately last: every visible v10
                // schema/data step must have succeeded before this changes.
                try db.run("UPDATE schema_version SET version = ?;", bind: [.int(10)])
                try db.exec("COMMIT;")
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
            }
            version = 10
        }

        if version < 11 {
            try db.exec("BEGIN IMMEDIATE;")
            do {
                try db.exec(Self.schemaSQLv11)
                try db.run("UPDATE schema_version SET version = ?;", bind: [.int(11)])
                try db.exec("COMMIT;")
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
            }
            version = 11
        }
    }

    private func tableExists(_ name: String) throws -> Bool {
        var exists = false
        try db.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            bind: [.text(name)]
        ) { _ in exists = true }
        return exists
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        var exists = false
        try db.query("PRAGMA table_info(\(table));") { row in
            if row.string(1) == column { exists = true }
        }
        return exists
    }

    /// One-time v9->v10 upgrade step: seeds `sensor_profile_history` with
    /// one row per EXISTING `sensor_profile` row, so a profile measured
    /// before this migration still shows up as the earliest point in its own
    /// history list/sparkline rather than the history starting completely
    /// empty until the next re-measure. `estimatorVersion` is left `NULL`
    /// (never invented) for these backfilled rows, matching the `NULL`
    /// `sensor_profile.estimator_version` the `ALTER TABLE` above just gave
    /// that same row -- both say "unknown, pre-versioning estimator", never
    /// a guessed version number.
    private func backfillSensorProfileHistoryFromExistingProfiles() throws {
        var rows: [SensorProfileRecord] = []
        try db.query("SELECT \(Self.sensorProfileColumns) FROM sensor_profile;") { row in
            rows.append(Self.sensorProfileRecord(from: row))
        }

        for r in rows {
            var alreadyBackfilled = false
            try db.query(
                """
                SELECT 1 FROM sensor_profile_history
                WHERE camera = ? AND gain IS ? AND offset IS ? AND measured_at = ?
                LIMIT 1;
                """,
                bind: [
                    .text(r.camera), r.gain.map(SQLiteValue.real) ?? .null,
                    r.offset.map(SQLiteValue.real) ?? .null, .real(r.measuredAt),
                ]
            ) { _ in alreadyBackfilled = true }
            if alreadyBackfilled { continue }
            try db.run(
                """
                INSERT INTO sensor_profile_history(camera, gain, offset, bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain, measured_at, estimator_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL);
                """,
                bind: [
                    .text(r.camera), r.gain.map(SQLiteValue.real) ?? .null, r.offset.map(SQLiteValue.real) ?? .null,
                    r.biasLevelADU.map(SQLiteValue.real) ?? .null, r.readNoiseE.map(SQLiteValue.real) ?? .null,
                    r.darkRateEPerS.map(SQLiteValue.real) ?? .null, r.darkTempC.map(SQLiteValue.real) ?? .null,
                    r.egain.map(SQLiteValue.real) ?? .null, .real(r.measuredAt),
                ]
            )
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

    // MARK: capture groups (schema v11)

    /// Inserts a capture group, or updates the editable fields of the row
    /// with the same `(target, sessionDate, slug)`. The original creation
    /// timestamp and stable id survive an upsert.
    @discardableResult
    public func upsertCaptureGroup(_ record: CaptureGroupRecord) throws -> Int64 {
        try withLock {
            try db.run(
                """
                INSERT INTO capture_groups(
                  target, session_date, slug, display_name, sensor_mode, signal_mode,
                  filter_manufacturer, filter_model, filter_name, notes, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(target, session_date, slug) DO UPDATE SET
                  display_name = excluded.display_name,
                  sensor_mode = excluded.sensor_mode,
                  signal_mode = excluded.signal_mode,
                  filter_manufacturer = excluded.filter_manufacturer,
                  filter_model = excluded.filter_model,
                  filter_name = excluded.filter_name,
                  notes = excluded.notes,
                  updated_at = excluded.updated_at;
                """,
                bind: [
                    .text(record.target), .text(record.sessionDate), .text(record.slug),
                    .text(record.displayName), .text(record.sensorMode.rawValue), .text(record.signalMode.rawValue),
                    record.filterManufacturer.map(SQLiteValue.text) ?? .null,
                    record.filterModel.map(SQLiteValue.text) ?? .null,
                    record.filterName.map(SQLiteValue.text) ?? .null,
                    record.notes.map(SQLiteValue.text) ?? .null,
                    .real(record.createdAt), .real(record.updatedAt),
                ]
            )

            var id: Int64?
            try db.query(
                "SELECT id FROM capture_groups WHERE target = ? AND session_date = ? AND slug = ?;",
                bind: [.text(record.target), .text(record.sessionDate), .text(record.slug)]
            ) { id = $0.int64(0) }
            guard let id else {
                throw AstroError.databaseError("upsertCaptureGroup: no row after upsert")
            }
            return id
        }
    }

    public func captureGroup(id: Int64) throws -> CaptureGroupRecord? {
        try withLock {
            var result: CaptureGroupRecord?
            try db.query(
                "SELECT \(Self.captureGroupColumns) FROM capture_groups WHERE id = ?;",
                bind: [.int(id)]
            ) { result = Self.captureGroupRecord(from: $0) }
            return result
        }
    }

    public func captureGroup(target: String, date: String, slug: String) throws -> CaptureGroupRecord? {
        try withLock {
            var result: CaptureGroupRecord?
            try db.query(
                "SELECT \(Self.captureGroupColumns) FROM capture_groups WHERE target = ? AND session_date = ? AND slug = ?;",
                bind: [.text(target), .text(date), .text(slug)]
            ) { result = Self.captureGroupRecord(from: $0) }
            return result
        }
    }

    public func captureGroups(target: String, date: String) throws -> [CaptureGroupRecord] {
        try withLock {
            var result: [CaptureGroupRecord] = []
            try db.query(
                "SELECT \(Self.captureGroupColumns) FROM capture_groups WHERE target = ? AND session_date = ? ORDER BY display_name COLLATE NOCASE, slug;",
                bind: [.text(target), .text(date)]
            ) { result.append(Self.captureGroupRecord(from: $0)) }
            return result
        }
    }

    public func allCaptureGroups() throws -> [CaptureGroupRecord] {
        try withLock {
            var result: [CaptureGroupRecord] = []
            try db.query(
                "SELECT \(Self.captureGroupColumns) FROM capture_groups ORDER BY target, session_date, display_name COLLATE NOCASE, slug;"
            ) { result.append(Self.captureGroupRecord(from: $0)) }
            return result
        }
    }

    private static let captureGroupColumns = """
    id, target, session_date, slug, display_name, sensor_mode, signal_mode,
    filter_manufacturer, filter_model, filter_name, notes, created_at, updated_at
    """

    private static func captureGroupRecord(from row: SQLiteRow) -> CaptureGroupRecord {
        CaptureGroupRecord(
            id: row.int64(0),
            target: row.string(1) ?? "",
            sessionDate: row.string(2) ?? "",
            slug: row.string(3) ?? "",
            displayName: row.string(4) ?? "",
            sensorMode: row.string(5).flatMap(SensorMode.init(rawValue:)) ?? .unknown,
            signalMode: row.string(6).flatMap(SignalMode.init(rawValue:)) ?? .unknown,
            filterManufacturer: row.string(7),
            filterModel: row.string(8),
            filterName: row.string(9),
            notes: row.string(10),
            createdAt: row.double(11) ?? 0,
            updatedAt: row.double(12) ?? 0
        )
    }

    /// Adds one folder-prefix mapping. A path already mapped to the same
    /// group is updated idempotently; mapping it to a different group is an
    /// explicit conflict rather than silently stealing the source.
    @discardableResult
    public func upsertCaptureSource(_ record: CaptureSourceRecord) throws -> Int64 {
        try withLock {
            var existingID: Int64?
            var existingGroupID: Int64?
            try db.query(
                "SELECT id, capture_group_id FROM capture_sources WHERE relative_path = ?;",
                bind: [.text(record.relativePath)]
            ) { row in
                existingID = row.int64(0)
                existingGroupID = row.int64(1)
            }
            if let existingID, let existingGroupID {
                guard existingGroupID == record.captureGroupID else {
                    throw AstroError.invalidInput(
                        "capture source \"\(record.relativePath)\" already belongs to group \(existingGroupID)"
                    )
                }
                try db.run(
                    "UPDATE capture_sources SET role = ? WHERE id = ?;",
                    bind: [.text(record.role.rawValue), .int(existingID)]
                )
                return existingID
            }

            guard try captureGroupExistsUnlocked(record.captureGroupID) else {
                throw AstroError.invalidInput("unknown capture group id \(record.captureGroupID)")
            }
            try db.run(
                "INSERT INTO capture_sources(capture_group_id, relative_path, role) VALUES (?, ?, ?);",
                bind: [.int(record.captureGroupID), .text(record.relativePath), .text(record.role.rawValue)]
            )
            return db.lastInsertRowID
        }
    }

    public func captureSources(groupID: Int64) throws -> [CaptureSourceRecord] {
        try withLock {
            var result: [CaptureSourceRecord] = []
            try db.query(
                "SELECT id, capture_group_id, relative_path, role FROM capture_sources WHERE capture_group_id = ? ORDER BY relative_path;",
                bind: [.int(groupID)]
            ) { result.append(Self.captureSourceRecord(from: $0)) }
            return result
        }
    }

    public func allCaptureSources() throws -> [CaptureSourceRecord] {
        try withLock {
            var result: [CaptureSourceRecord] = []
            try db.query(
                "SELECT id, capture_group_id, relative_path, role FROM capture_sources ORDER BY relative_path;"
            ) { result.append(Self.captureSourceRecord(from: $0)) }
            return result
        }
    }

    private static func captureSourceRecord(from row: SQLiteRow) -> CaptureSourceRecord {
        CaptureSourceRecord(
            id: row.int64(0),
            captureGroupID: row.int64(1) ?? 0,
            relativePath: row.string(2) ?? "",
            role: row.string(3).flatMap(FrameRole.init(rawValue:)) ?? .other
        )
    }

    public func upsertFileCaptureAssignment(_ record: FileCaptureAssignmentRecord) throws {
        try withLock {
            guard try captureGroupExistsUnlocked(record.captureGroupID) else {
                throw AstroError.invalidInput("unknown capture group id \(record.captureGroupID)")
            }
            var fileExists = false
            try db.query("SELECT 1 FROM files WHERE id = ? LIMIT 1;", bind: [.int(record.fileID)]) { _ in
                fileExists = true
            }
            guard fileExists else {
                throw AstroError.invalidInput("unknown file id \(record.fileID)")
            }

            try db.run(
                """
                INSERT INTO file_capture_assignments(
                  file_id, capture_group_id, sensor_mode_override, signal_mode_override,
                  filter_manufacturer_override, filter_model_override, filter_name_override,
                  assignment_source, assigned_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET
                  capture_group_id = excluded.capture_group_id,
                  sensor_mode_override = excluded.sensor_mode_override,
                  signal_mode_override = excluded.signal_mode_override,
                  filter_manufacturer_override = excluded.filter_manufacturer_override,
                  filter_model_override = excluded.filter_model_override,
                  filter_name_override = excluded.filter_name_override,
                  assignment_source = excluded.assignment_source,
                  assigned_at = excluded.assigned_at;
                """,
                bind: [
                    .int(record.fileID), .int(record.captureGroupID),
                    record.sensorModeOverride.map { .text($0.rawValue) } ?? .null,
                    record.signalModeOverride.map { .text($0.rawValue) } ?? .null,
                    record.filterManufacturerOverride.map(SQLiteValue.text) ?? .null,
                    record.filterModelOverride.map(SQLiteValue.text) ?? .null,
                    record.filterNameOverride.map(SQLiteValue.text) ?? .null,
                    .text(record.assignmentSource), .real(record.assignedAt),
                ]
            )
        }
    }

    public func fileCaptureAssignment(fileID: Int64) throws -> FileCaptureAssignmentRecord? {
        try withLock {
            var result: FileCaptureAssignmentRecord?
            try db.query(
                "SELECT \(Self.fileCaptureAssignmentColumns) FROM file_capture_assignments WHERE file_id = ?;",
                bind: [.int(fileID)]
            ) { result = Self.fileCaptureAssignmentRecord(from: $0) }
            return result
        }
    }

    public func fileCaptureAssignments(fileIDs: [Int64]) throws -> [Int64: FileCaptureAssignmentRecord] {
        guard !fileIDs.isEmpty else { return [:] }
        return try withLock {
            var result: [Int64: FileCaptureAssignmentRecord] = [:]
            for chunk in fileIDs.chunked(into: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try db.query(
                    "SELECT \(Self.fileCaptureAssignmentColumns) FROM file_capture_assignments WHERE file_id IN (\(placeholders));",
                    bind: chunk.map(SQLiteValue.int)
                ) { row in
                    let record = Self.fileCaptureAssignmentRecord(from: row)
                    result[record.fileID] = record
                }
            }
            return result
        }
    }

    public func allFileCaptureAssignments() throws -> [Int64: FileCaptureAssignmentRecord] {
        try withLock {
            var result: [Int64: FileCaptureAssignmentRecord] = [:]
            try db.query("SELECT \(Self.fileCaptureAssignmentColumns) FROM file_capture_assignments;") { row in
                let record = Self.fileCaptureAssignmentRecord(from: row)
                result[record.fileID] = record
            }
            return result
        }
    }

    public func clearFileCaptureAssignment(fileID: Int64) throws {
        try withLock {
            try db.run("DELETE FROM file_capture_assignments WHERE file_id = ?;", bind: [.int(fileID)])
        }
    }

    private static let fileCaptureAssignmentColumns = """
    file_id, capture_group_id, sensor_mode_override, signal_mode_override,
    filter_manufacturer_override, filter_model_override, filter_name_override,
    assignment_source, assigned_at
    """

    private static func fileCaptureAssignmentRecord(from row: SQLiteRow) -> FileCaptureAssignmentRecord {
        FileCaptureAssignmentRecord(
            fileID: row.int64(0) ?? 0,
            captureGroupID: row.int64(1) ?? 0,
            sensorModeOverride: row.string(2).flatMap(SensorMode.init(rawValue:)),
            signalModeOverride: row.string(3).flatMap(SignalMode.init(rawValue:)),
            filterManufacturerOverride: row.string(4),
            filterModelOverride: row.string(5),
            filterNameOverride: row.string(6),
            assignmentSource: row.string(7) ?? "",
            assignedAt: row.double(8) ?? 0
        )
    }

    /// Removes one group and only its tool-owned mapping/assignment rows.
    /// The indexed `files` rows and every library file remain untouched.
    public func deleteCaptureGroup(id: Int64) throws {
        try withLock {
            try db.exec("BEGIN IMMEDIATE;")
            do {
                try db.run("DELETE FROM file_capture_assignments WHERE capture_group_id = ?;", bind: [.int(id)])
                try db.run("DELETE FROM capture_sources WHERE capture_group_id = ?;", bind: [.int(id)])
                try db.run("DELETE FROM capture_groups WHERE id = ?;", bind: [.int(id)])
                try db.exec("COMMIT;")
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
            }
        }
    }

    private func captureGroupExistsUnlocked(_ id: Int64) throws -> Bool {
        var exists = false
        try db.query("SELECT 1 FROM capture_groups WHERE id = ? LIMIT 1;", bind: [.int(id)]) { _ in
            exists = true
        }
        return exists
    }

    /// Applies all metadata mutations for one session conversion in a
    /// single SQLite transaction and returns the exact prior state required
    /// for rollback. No filesystem operation occurs here.
    func applySessionConversionMetadata(
        plan: SessionConversionPlan,
        now: Double
    ) throws -> ConversionMetadataBackup {
        try withLock {
            try db.exec("BEGIN IMMEDIATE;")
            do {
                var backup = ConversionMetadataBackup()
                var groupIDsBySlug: [String: Int64] = [:]

                try db.query(
                    "SELECT id, slug FROM capture_groups WHERE target = ? AND session_date = ?;",
                    bind: [.text(plan.scope.target), .text(plan.scope.date)]
                ) { row in
                    if let id = row.int64(0), let slug = row.string(1) {
                        groupIDsBySlug[slug] = id
                    }
                }

                for removal in plan.sourceRemovals ?? [] {
                    let requiredPrefix = "sessions/\(plan.scope.target)/\(plan.scope.date)/"
                    guard removal.relativePath.hasPrefix(requiredPrefix) else {
                        throw AstroError.invalidInput(
                            "Az eltávolítandó forrásmappa kívül esik a konverzió sessionjén: \(removal.relativePath)"
                        )
                    }
                    var previous: CaptureSourceRecord?
                    try db.query(
                        "SELECT id, capture_group_id, relative_path, role FROM capture_sources WHERE relative_path = ?;",
                        bind: [.text(removal.relativePath)]
                    ) { previous = Self.captureSourceRecord(from: $0) }
                    guard let previous else { continue }
                    guard previous.captureGroupID == removal.expectedGroupID,
                          previous.role == removal.role
                    else {
                        throw AstroError.invalidInput(
                            "A(z) \(removal.relativePath) forrás-hozzárendelése megváltozott az előnézet óta."
                        )
                    }
                    backup.sourceBackups.append(
                        ConversionSourceBackup(relativePath: removal.relativePath, previous: previous)
                    )
                    try db.run(
                        "DELETE FROM capture_sources WHERE relative_path = ?;",
                        bind: [.text(removal.relativePath)]
                    )
                }

                for proposed in plan.proposedGroups {
                    let draft = proposed.draft
                    if let existingGroupID = proposed.existingGroupID {
                        guard groupIDsBySlug[draft.slug] == existingGroupID else {
                            throw AstroError.invalidInput(
                                "A(z) \(draft.slug) meglévő gyűjtés azonossága megváltozott az előnézet óta."
                            )
                        }
                        var previous: CaptureGroupRecord?
                        try db.query(
                            "SELECT \(Self.captureGroupColumns) FROM capture_groups WHERE id = ?;",
                            bind: [.int(existingGroupID)]
                        ) { previous = Self.captureGroupRecord(from: $0) }
                        guard let previous,
                              previous.target == plan.scope.target,
                              previous.sessionDate == plan.scope.date,
                              previous.slug == draft.slug
                        else {
                            throw AstroError.invalidInput(
                                "A frissítendő gyűjtés már nem része a kiválasztott sessionnek."
                            )
                        }
                        backup.updatedGroupBackups?.append(previous)
                        try db.run(
                            """
                            UPDATE capture_groups SET
                              display_name = ?, sensor_mode = ?, signal_mode = ?,
                              filter_manufacturer = ?, filter_model = ?, filter_name = ?,
                              notes = ?, updated_at = ?
                            WHERE id = ?;
                            """,
                            bind: [
                                .text(draft.displayName), .text(draft.sensorMode.rawValue),
                                .text(draft.signalMode.rawValue),
                                draft.filterManufacturer.map(SQLiteValue.text) ?? .null,
                                draft.filterModel.map(SQLiteValue.text) ?? .null,
                                draft.filterName.map(SQLiteValue.text) ?? .null,
                                draft.notes.map(SQLiteValue.text) ?? .null,
                                .real(now), .int(existingGroupID),
                            ]
                        )
                        continue
                    }
                    guard groupIDsBySlug[draft.slug] == nil else {
                        throw AstroError.invalidInput(
                            "A(z) \(draft.slug) gyűjtés az előnézet óta már létrejött. Készíts új tervet."
                        )
                    }
                    try db.run(
                        """
                        INSERT INTO capture_groups(
                          target, session_date, slug, display_name, sensor_mode, signal_mode,
                          filter_manufacturer, filter_model, filter_name, notes, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                        bind: [
                            .text(plan.scope.target), .text(plan.scope.date), .text(draft.slug),
                            .text(draft.displayName), .text(draft.sensorMode.rawValue), .text(draft.signalMode.rawValue),
                            draft.filterManufacturer.map(SQLiteValue.text) ?? .null,
                            draft.filterModel.map(SQLiteValue.text) ?? .null,
                            draft.filterName.map(SQLiteValue.text) ?? .null,
                            draft.notes.map(SQLiteValue.text) ?? .null,
                            .real(now), .real(now),
                        ]
                    )
                    let id = db.lastInsertRowID
                    groupIDsBySlug[draft.slug] = id
                    backup.createdGroupIDs.append(id)
                    backup.createdGroupSlugs.append(draft.slug)
                }

                for proposed in plan.proposedGroups {
                    guard let groupID = groupIDsBySlug[proposed.draft.slug] else {
                        throw AstroError.databaseError("Hiányzó gyűjtésazonosító: \(proposed.draft.slug)")
                    }
                    for mapping in proposed.sourceMappings {
                        let requiredPrefix = "sessions/\(plan.scope.target)/\(plan.scope.date)/"
                        guard mapping.relativePath.hasPrefix(requiredPrefix) else {
                            throw AstroError.invalidInput(
                                "A forrásmappa kívül esik a konverzió sessionjén: \(mapping.relativePath)"
                            )
                        }
                        var previous: CaptureSourceRecord?
                        try db.query(
                            "SELECT id, capture_group_id, relative_path, role FROM capture_sources WHERE relative_path = ?;",
                            bind: [.text(mapping.relativePath)]
                        ) { previous = Self.captureSourceRecord(from: $0) }
                        if let previous {
                            guard previous.captureGroupID == groupID else {
                                throw AstroError.invalidInput(
                                    "A(z) \(mapping.relativePath) forrás már másik gyűjtéshez tartozik."
                                )
                            }
                            continue
                        }
                        backup.sourceBackups.append(
                            ConversionSourceBackup(relativePath: mapping.relativePath, previous: nil)
                        )
                        try db.run(
                            "INSERT INTO capture_sources(capture_group_id, relative_path, role) VALUES (?, ?, ?);",
                            bind: [.int(groupID), .text(mapping.relativePath), .text(mapping.role.rawValue)]
                        )
                    }
                }

                var backedUpFileIDs = Set<Int64>()
                for assignment in plan.assignments {
                    guard let fileID = assignment.fileID else {
                        throw AstroError.invalidInput(
                            "A fájl nincs indexelve, ezért nem rendelhető biztonságosan gyűjtéshez: \(assignment.path)"
                        )
                    }
                    guard let groupID = groupIDsBySlug[assignment.groupSlug] else {
                        throw AstroError.invalidInput("Ismeretlen célgyűjtés: \(assignment.groupSlug)")
                    }
                    var indexedPath: String?
                    var target: String?
                    var date: String?
                    try db.query(
                        "SELECT path, target, session_date FROM files WHERE id = ? AND missing = 0;",
                        bind: [.int(fileID)]
                    ) { row in
                        indexedPath = row.string(0)
                        target = row.string(1)
                        date = row.string(2)
                    }
                    guard indexedPath == assignment.path,
                          target == plan.scope.target,
                          date == plan.scope.date
                    else {
                        throw AstroError.invalidInput(
                            "A fájl indexbejegyzése megváltozott az előnézet óta: \(assignment.path)"
                        )
                    }

                    if backedUpFileIDs.insert(fileID).inserted {
                        var previous: FileCaptureAssignmentRecord?
                        try db.query(
                            "SELECT \(Self.fileCaptureAssignmentColumns) FROM file_capture_assignments WHERE file_id = ?;",
                            bind: [.int(fileID)]
                        ) { previous = Self.fileCaptureAssignmentRecord(from: $0) }
                        backup.assignmentBackups.append(
                            ConversionAssignmentBackup(fileID: fileID, previous: previous)
                        )
                    }
                    try db.run(
                        """
                        INSERT INTO file_capture_assignments(
                          file_id, capture_group_id, sensor_mode_override, signal_mode_override,
                          filter_manufacturer_override, filter_model_override, filter_name_override,
                          assignment_source, assigned_at)
                        VALUES (?, ?, NULL, NULL, NULL, NULL, NULL, ?, ?)
                        ON CONFLICT(file_id) DO UPDATE SET
                          capture_group_id = excluded.capture_group_id,
                          sensor_mode_override = NULL,
                          signal_mode_override = NULL,
                          filter_manufacturer_override = NULL,
                          filter_model_override = NULL,
                          filter_name_override = NULL,
                          assignment_source = excluded.assignment_source,
                          assigned_at = excluded.assigned_at;
                        """,
                        bind: [
                            .int(fileID), .int(groupID),
                            .text("session-converter:\(plan.id)"), .real(now),
                        ]
                    )
                }

                try db.exec("COMMIT;")
                return backup
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Restores metadata captured by `applySessionConversionMetadata` in one
    /// transaction. Created filesystem directories are intentionally not
    /// removed; they are harmless and may contain later user files.
    func rollbackSessionConversionMetadata(_ backup: ConversionMetadataBackup) throws {
        try withLock {
            try db.exec("BEGIN IMMEDIATE;")
            do {
                for groupID in backup.createdGroupIDs {
                    try db.run(
                        "DELETE FROM file_capture_assignments WHERE capture_group_id = ?;",
                        bind: [.int(groupID)]
                    )
                    try db.run("DELETE FROM capture_sources WHERE capture_group_id = ?;", bind: [.int(groupID)])
                    try db.run("DELETE FROM capture_groups WHERE id = ?;", bind: [.int(groupID)])
                }

                for sourceBackup in backup.sourceBackups {
                    if let previous = sourceBackup.previous {
                        try db.run(
                            """
                            INSERT INTO capture_sources(capture_group_id, relative_path, role)
                            VALUES (?, ?, ?)
                            ON CONFLICT(relative_path) DO UPDATE SET
                              capture_group_id = excluded.capture_group_id,
                              role = excluded.role;
                            """,
                            bind: [
                                .int(previous.captureGroupID), .text(previous.relativePath),
                                .text(previous.role.rawValue),
                            ]
                        )
                    } else {
                        try db.run(
                            "DELETE FROM capture_sources WHERE relative_path = ?;",
                            bind: [.text(sourceBackup.relativePath)]
                        )
                    }
                }

                for assignmentBackup in backup.assignmentBackups {
                    if let previous = assignmentBackup.previous {
                        try db.run(
                            """
                            INSERT INTO file_capture_assignments(
                              file_id, capture_group_id, sensor_mode_override, signal_mode_override,
                              filter_manufacturer_override, filter_model_override, filter_name_override,
                              assignment_source, assigned_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            ON CONFLICT(file_id) DO UPDATE SET
                              capture_group_id = excluded.capture_group_id,
                              sensor_mode_override = excluded.sensor_mode_override,
                              signal_mode_override = excluded.signal_mode_override,
                              filter_manufacturer_override = excluded.filter_manufacturer_override,
                              filter_model_override = excluded.filter_model_override,
                              filter_name_override = excluded.filter_name_override,
                              assignment_source = excluded.assignment_source,
                              assigned_at = excluded.assigned_at;
                            """,
                            bind: [
                                .int(previous.fileID), .int(previous.captureGroupID),
                                previous.sensorModeOverride.map { .text($0.rawValue) } ?? .null,
                                previous.signalModeOverride.map { .text($0.rawValue) } ?? .null,
                                previous.filterManufacturerOverride.map(SQLiteValue.text) ?? .null,
                                previous.filterModelOverride.map(SQLiteValue.text) ?? .null,
                                previous.filterNameOverride.map(SQLiteValue.text) ?? .null,
                                .text(previous.assignmentSource), .real(previous.assignedAt),
                            ]
                        )
                    } else {
                        try db.run(
                            "DELETE FROM file_capture_assignments WHERE file_id = ?;",
                            bind: [.int(assignmentBackup.fileID)]
                        )
                    }
                }

                for previous in backup.updatedGroupBackups ?? [] {
                    guard let id = previous.id else { continue }
                    try db.run(
                        """
                        UPDATE capture_groups SET
                          target = ?, session_date = ?, slug = ?, display_name = ?,
                          sensor_mode = ?, signal_mode = ?, filter_manufacturer = ?,
                          filter_model = ?, filter_name = ?, notes = ?,
                          created_at = ?, updated_at = ?
                        WHERE id = ?;
                        """,
                        bind: [
                            .text(previous.target), .text(previous.sessionDate), .text(previous.slug),
                            .text(previous.displayName), .text(previous.sensorMode.rawValue),
                            .text(previous.signalMode.rawValue),
                            previous.filterManufacturer.map(SQLiteValue.text) ?? .null,
                            previous.filterModel.map(SQLiteValue.text) ?? .null,
                            previous.filterName.map(SQLiteValue.text) ?? .null,
                            previous.notes.map(SQLiteValue.text) ?? .null,
                            .real(previous.createdAt), .real(previous.updatedAt), .int(id),
                        ]
                    )
                }
                try db.exec("COMMIT;")
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
            }
        }
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

    private static let fitsMetaColumns = """
    file_id, exptime, gain, "offset", set_temp, ccd_temp, instrume, focallen, filter, date_obs, imagetyp, naxis1, naxis2, xpixsz, egain, header_json, solved_ra, solved_dec, solved_scale_arcsec, solved_rotation_deg
    """

    private static func fitsMetaRecord(from row: SQLiteRow) -> FITSMetaRecord {
        FITSMetaRecord(
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

    public func fitsMeta(fileID: Int64) throws -> FITSMetaRecord? {
        try withLock {
            var record: FITSMetaRecord?
            try db.query(
                "SELECT \(Self.fitsMetaColumns) FROM fits_meta WHERE file_id = ?;",
                bind: [.int(fileID)]
            ) { row in
                record = Self.fitsMetaRecord(from: row)
            }
            return record
        }
    }

    /// D12: batch form of `fitsMeta`, used by call sites that used to fetch
    /// per-file in a loop (target-page open, plate-solve-all) -- one query
    /// per 500 ids instead of one query per file. Missing ids are simply
    /// absent from the returned dictionary (same "no row" semantics as the
    /// single-file form returning `nil`).
    public func fitsMetaBatch(fileIDs: [Int64]) throws -> [Int64: FITSMetaRecord] {
        guard !fileIDs.isEmpty else { return [:] }
        return try withLock {
            var result: [Int64: FITSMetaRecord] = [:]
            for chunk in fileIDs.chunked(into: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try db.query(
                    "SELECT \(Self.fitsMetaColumns) FROM fits_meta WHERE file_id IN (\(placeholders));",
                    bind: chunk.map(SQLiteValue.int)
                ) { row in
                    let record = Self.fitsMetaRecord(from: row)
                    result[record.fileID] = record
                }
            }
            return result
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

    /// Replaces the operation-specific metadata envelope after a run has
    /// produced its final summary. This updates only Astro Tool's database;
    /// it never touches any library file.
    public func updateRunConfig(id: Int64, configJSON: String?) throws {
        try withLock {
            try db.run(
                "UPDATE runs SET config_json = ? WHERE id = ?;",
                bind: [configJSON.map(SQLiteValue.text) ?? .null, .int(id)]
            )
        }
    }

    /// Full persisted metadata for one run id, or `nil` when it does not
    /// exist. Used for restoring verify summaries and audit settings.
    public func runSummary(id: Int64) throws -> RunSummary? {
        try withLock {
            var result: RunSummary?
            try db.query(
                "SELECT id, kind, started_at, finished_at, root, config_json FROM runs WHERE id = ? LIMIT 1;",
                bind: [.int(id)]
            ) { row in
                result = RunSummary(
                    id: row.int64(0) ?? 0,
                    kind: row.string(1) ?? "",
                    startedAt: Date(timeIntervalSince1970: row.double(2) ?? 0),
                    finishedAt: row.double(3).map(Date.init(timeIntervalSince1970:)),
                    root: row.string(4) ?? "",
                    configJSON: row.string(5)
                )
            }
            return result
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

    /// The `id` of the most recent `runs` row of the given `kind`
    /// (e.g. `"scan"`, `"audit"`), or `nil` if none exist yet -- mirrors
    /// `lastRunDate(kind:)` but returns the row id rather than its
    /// timestamp, so a caller (`AppState.openRoot`, R9-D1) can restore
    /// `findings(runID:)` for the last completed audit across launches,
    /// without re-running the audit.
    public func lastRunID(kind: String) throws -> Int64? {
        try withLock {
            var id: Int64?
            try db.query(
                "SELECT id FROM runs WHERE kind = ? ORDER BY started_at DESC LIMIT 1;",
                bind: [.text(kind)]
            ) { row in
                id = row.int64(0)
            }
            return id
        }
    }

    /// Most recent successfully finished run of `kind`. Restoration paths
    /// use this instead of `lastRunID` so a process crash cannot promote a
    /// partial run to the latest trusted result.
    public func lastCompletedRunID(kind: String) throws -> Int64? {
        try withLock {
            var id: Int64?
            try db.query(
                "SELECT id FROM runs WHERE kind = ? AND finished_at IS NOT NULL ORDER BY started_at DESC LIMIT 1;",
                bind: [.text(kind)]
            ) { row in
                id = row.int64(0)
            }
            return id
        }
    }

    /// The `id` of the most recent `runs` row of the given `kind` that
    /// started strictly before `runID`'s own `started_at`, or `nil` if
    /// `runID` is the first run of that kind (or doesn't exist). R11-T8/F6:
    /// lets a caller that already has a just-created (or previously
    /// restored) run id look up "the run before this one" to diff against,
    /// symmetric whether called right after `AuditEngine.run` (using its
    /// returned `runID`) or on app relaunch (using the restored
    /// `lastRunID(kind:)`) -- both end up asking the same question, "what
    /// ran immediately before this run id".
    public func previousRunID(before runID: Int64, kind: String) throws -> Int64? {
        try withLock {
            var id: Int64?
            try db.query(
                """
                SELECT id FROM runs
                WHERE kind = ? AND started_at < (SELECT started_at FROM runs WHERE id = ?)
                ORDER BY started_at DESC LIMIT 1;
                """,
                bind: [.text(kind), .int(runID)]
            ) { row in
                id = row.int64(0)
            }
            return id
        }
    }

    /// Completed counterpart of `previousRunID`, used for trustworthy audit
    /// diffs when an interrupted run row exists between two finished runs.
    public func previousCompletedRunID(before runID: Int64, kind: String) throws -> Int64? {
        try withLock {
            var id: Int64?
            try db.query(
                """
                SELECT id FROM runs
                WHERE kind = ? AND finished_at IS NOT NULL
                  AND started_at < (SELECT started_at FROM runs WHERE id = ?)
                ORDER BY started_at DESC LIMIT 1;
                """,
                bind: [.text(kind), .int(runID)]
            ) { row in
                id = row.int64(0)
            }
            return id
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

    private static let ratingColumns =
        "file_id, fwhm, roundness, star_count, background, saturated_fraction, score, rated_at, siril_version, input_sig, bg_00, bg_01, bg_10, bg_11, source"

    private static func ratingRecord(from row: SQLiteRow) -> RatingRecord {
        RatingRecord(
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

    public func rating(fileID: Int64) throws -> RatingRecord? {
        try withLock {
            var record: RatingRecord?
            try db.query(
                "SELECT \(Self.ratingColumns) FROM ratings WHERE file_id = ?;",
                bind: [.int(fileID)]
            ) { row in
                record = Self.ratingRecord(from: row)
            }
            return record
        }
    }

    /// `true` once at least one frame anywhere in the library has ever been
    /// rated -- backs the "Első lépések" checklist's "Volt már pontozás?"
    /// step (R11-T12/F12). A cheap existence probe (`LIMIT 1`), never a
    /// `COUNT(*)` over the whole table.
    public func hasAnyRating() throws -> Bool {
        try withLock {
            var found = false
            try db.query("SELECT 1 FROM ratings LIMIT 1;") { _ in found = true }
            return found
        }
    }

    /// N6 (R9 round 3): batch form of `rating(fileID:)`, used by
    /// `Rater.cachedScores` (which used to fetch one `rating` + one
    /// `fitsMeta` row PER FRAME in a loop -- ~18k queries on a real
    /// library's target). One query per 500 ids instead, same chunking
    /// convention as `fitsMetaBatch`. Missing ids are simply absent from the
    /// returned dictionary (same "no row" semantics as the single-file form
    /// returning `nil`).
    public func ratingsBatch(fileIDs: [Int64]) throws -> [Int64: RatingRecord] {
        guard !fileIDs.isEmpty else { return [:] }
        return try withLock {
            var result: [Int64: RatingRecord] = [:]
            for chunk in fileIDs.chunked(into: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try db.query(
                    "SELECT \(Self.ratingColumns) FROM ratings WHERE file_id IN (\(placeholders));",
                    bind: chunk.map(SQLiteValue.int)
                ) { row in
                    let record = Self.ratingRecord(from: row)
                    result[record.fileID] = record
                }
            }
            return result
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

    /// Batch form of `userVerdict(fileID:)`, just the `accepted` flag
    /// (without `source`/`recordedAt`) keyed by file id -- what
    /// `AppState.loadFrameScores`/`runRate` (R10-B1) need to populate the
    /// Minőség segment's "Saját döntés" column and the `FrameReviewSheet`
    /// blink sheet for a whole target's worth of frames without one query
    /// per frame. Same "one query per 500 ids" chunking `ratingsBatch`/
    /// `fitsMetaBatch` already use; a file with no recorded verdict is
    /// simply absent from the result, same "no row" semantics as every
    /// other batch lookup in this file.
    public func userVerdicts(forFileIDs fileIDs: [Int64]) throws -> [Int64: Bool] {
        guard !fileIDs.isEmpty else { return [:] }
        return try withLock {
            var result: [Int64: Bool] = [:]
            for chunk in fileIDs.chunked(into: 500) {
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                try db.query(
                    "SELECT file_id, accepted FROM user_verdicts WHERE file_id IN (\(placeholders));",
                    bind: chunk.map(SQLiteValue.int)
                ) { row in
                    guard let fileID = row.int64(0) else { return }
                    result[fileID] = (row.int64(1) ?? 0) != 0
                }
            }
            return result
        }
    }

    /// Records (or overwrites) one file's manual accept/reject verdict --
    /// R10-B1: `QualitySegment`'s frame context menu and `FrameReviewSheet`'s
    /// A/X keys, both always passing `source == "app"` to distinguish a
    /// verdict recorded IN this app from one `DSSIngest` harvested from a
    /// `.dssfilelist` (`source == "dssfilelist"`) -- `StackList.select`
    /// treats the two identically (any `accepted == false` row hard-drops
    /// the frame regardless of score), this is provenance only. A thin
    /// wrapper over `upsertUserVerdict` so call sites never build a
    /// `UserVerdictRecord`/stamp `recordedAt` themselves.
    public func setUserVerdict(fileID: Int64, accepted: Bool, source: String) throws {
        try upsertUserVerdict(
            UserVerdictRecord(fileID: fileID, accepted: accepted, source: source, recordedAt: Date().timeIntervalSince1970)
        )
    }

    /// Clears a file's verdict entirely -- the blink sheet's "Döntés
    /// törlése" / `U` key (R10-B1). A plain `DELETE` rather than a
    /// tri-state column: once cleared, `userVerdict(fileID:)` goes back to
    /// `nil`, indistinguishable from "never recorded" -- exactly what
    /// `StackList.select`'s own `userVerdict(fileID:) == nil` branch
    /// already treats as "no opinion, don't drop". A no-op if no verdict
    /// was recorded for this file.
    public func clearUserVerdict(fileID: Int64) throws {
        try withLock {
            try db.run("DELETE FROM user_verdicts WHERE file_id = ?;", bind: [.int(fileID)])
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
                INSERT INTO sensor_profile(camera, gain, offset, bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain, measured_at, frame_count, estimator_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(camera, gain, offset) DO UPDATE SET
                  bias_level_adu = excluded.bias_level_adu, read_noise_e = excluded.read_noise_e,
                  dark_rate_e_per_s = excluded.dark_rate_e_per_s, dark_temp_c = excluded.dark_temp_c,
                  egain = excluded.egain, measured_at = excluded.measured_at, frame_count = excluded.frame_count,
                  estimator_version = excluded.estimator_version;
                """,
                bind: [
                    .text(r.camera), r.gain.map(SQLiteValue.real) ?? .null, r.offset.map(SQLiteValue.real) ?? .null,
                    r.biasLevelADU.map(SQLiteValue.real) ?? .null, r.readNoiseE.map(SQLiteValue.real) ?? .null,
                    r.darkRateEPerS.map(SQLiteValue.real) ?? .null, r.darkTempC.map(SQLiteValue.real) ?? .null,
                    r.egain.map(SQLiteValue.real) ?? .null, .real(r.measuredAt),
                    r.frameCount.map { SQLiteValue.int(Int64($0)) } ?? .null,
                    r.estimatorVersion.map { SQLiteValue.int(Int64($0)) } ?? .null,
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
                "SELECT \(Self.sensorProfileColumns) FROM sensor_profile WHERE camera = ? AND gain IS ? AND offset IS ?;",
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
            try db.query("SELECT \(Self.sensorProfileColumns) FROM sensor_profile ORDER BY camera, gain, offset;") { row in
                results.append(Self.sensorProfileRecord(from: row))
            }
            return results
        }
    }

    /// Shared column list for every `sensor_profile` SELECT -- also reused
    /// (R11-T10/F8) by the v9->v10 migration's own backfill query, so the
    /// migration and the ordinary DAO reads can never quietly drift apart on
    /// column order.
    private static let sensorProfileColumns =
        "camera, gain, offset, bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain, measured_at, frame_count, estimator_version"

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
            frameCount: row.int64(9).map(Int.init),
            estimatorVersion: row.int64(10).map(Int.init)
        )
    }

    // MARK: sensor_profile_history (R11-T10/F8)

    /// Appends one measurement row -- always an `INSERT`, never an upsert:
    /// this table exists specifically so a re-measure doesn't erase what
    /// came before it (that's what `sensor_profile` itself is for).
    public func insertSensorProfileHistory(_ r: SensorProfileHistoryRecord) throws {
        try withLock {
            try db.run(
                """
                INSERT INTO sensor_profile_history(camera, gain, offset, bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain, measured_at, estimator_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bind: [
                    .text(r.camera), r.gain.map(SQLiteValue.real) ?? .null, r.offset.map(SQLiteValue.real) ?? .null,
                    r.biasLevelADU.map(SQLiteValue.real) ?? .null, r.readNoiseE.map(SQLiteValue.real) ?? .null,
                    r.darkRateEPerS.map(SQLiteValue.real) ?? .null, r.darkTempC.map(SQLiteValue.real) ?? .null,
                    r.egain.map(SQLiteValue.real) ?? .null, .real(r.measuredAt),
                    r.estimatorVersion.map { SQLiteValue.int(Int64($0)) } ?? .null,
                ]
            )
        }
    }

    /// Every history row for an EXACT `(camera, gain, offset)` combo,
    /// ascending by `measured_at` (oldest first -- a plain time series, same
    /// "chronological, not browsing-order" convention `TrendQueries.points`
    /// uses) -- backs `SensorPage`'s per-profile history/sparkline
    /// disclosure and `astrotool sensor --history`.
    public func sensorProfileHistory(camera: String, gain: Double?, offset: Double?) throws -> [SensorProfileHistoryRecord] {
        try withLock {
            var results: [SensorProfileHistoryRecord] = []
            try db.query(
                """
                SELECT id, camera, gain, offset, bias_level_adu, read_noise_e, dark_rate_e_per_s, dark_temp_c, egain, measured_at, estimator_version
                FROM sensor_profile_history WHERE camera = ? AND gain IS ? AND offset IS ? ORDER BY measured_at ASC;
                """,
                bind: [.text(camera), gain.map(SQLiteValue.real) ?? .null, offset.map(SQLiteValue.real) ?? .null]
            ) { row in
                results.append(
                    SensorProfileHistoryRecord(
                        id: row.int64(0),
                        camera: row.string(1) ?? "",
                        gain: row.double(2),
                        offset: row.double(3),
                        biasLevelADU: row.double(4),
                        readNoiseE: row.double(5),
                        darkRateEPerS: row.double(6),
                        darkTempC: row.double(7),
                        egain: row.double(8),
                        measuredAt: row.double(9) ?? 0,
                        estimatorVersion: row.int64(10).map(Int.init)
                    )
                )
            }
            return results
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

    /// Replaces the complete current overall/per-filter goal set for one
    /// target as a single locked SQLite transaction. Both discovery of the
    /// old goal tags and their replacement happen after `BEGIN`, so two
    /// overlapping saves cannot each act on a stale pre-transaction snapshot
    /// and accidentally merge their independently desired sets.
    public func replaceTargetGoalTagsAtomically(target: String, with newGoalTags: [String]) throws {
        let additions = try Set(newGoalTags.map(Self.validatedTag)).sorted()
        for tag in additions where !GoalTag.isOverallGoalTag(tag) && GoalTag.parseFilterGoals(tags: [tag]).isEmpty {
            throw AstroError.invalidInput("not a goal tag: \(tag)")
        }

        try withLock {
            try db.exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                var existingGoalTags: [String] = []
                try db.query(
                    "SELECT tag FROM tags WHERE target = ? AND session_date IS NULL;",
                    bind: [.text(target)]
                ) { row in
                    guard let tag = row.string(0) else { return }
                    if GoalTag.isOverallGoalTag(tag) || !GoalTag.parseFilterGoals(tags: [tag]).isEmpty {
                        existingGoalTags.append(tag)
                    }
                }
                for tag in existingGoalTags {
                    try db.run(
                        "DELETE FROM tags WHERE target = ? AND session_date IS NULL AND tag = ?;",
                        bind: [.text(target), .text(tag)]
                    )
                }
                for tag in additions {
                    var exists = false
                    try Self.queryTagRows(db, target: target, sessionDate: nil, tag: tag) { _ in
                        exists = true
                    }
                    if !exists {
                        try db.run(
                            "INSERT INTO tags(kind, target, session_date, tag) VALUES (?, ?, NULL, ?);",
                            bind: [.text("target"), .text(target), .text(tag)]
                        )
                    }
                }
                try db.exec("COMMIT;")
            } catch {
                try? db.exec("ROLLBACK;")
                throw error
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

    // MARK: - Global search (R9-T6/B3)

    /// Cap on how many `files` rows `searchAll` returns in one call --
    /// `totalFileMatches` still reports the true (uncapped) count, the same
    /// "cap the list, keep the honest total" shape the Audit page's cleanup
    /// summaries already use. A library like the real one this app was
    /// built against (14 675 files) could otherwise hand the UI thousands of
    /// rows for a common substring.
    public static let searchFileCap = 50

    /// Escapes `%`/`_`/`\` in a raw user query so it can be embedded in a
    /// `LIKE ? ESCAPE '\'` pattern without those characters acting as SQL
    /// wildcards -- a literal `%` the user actually typed (e.g. searching
    /// for a gain readout like `"50%"`) must search for that literal
    /// substring, not silently become "match anything".
    private static func likeEscape(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        for ch in raw {
            if ch == "\\" || ch == "%" || ch == "_" { result.append("\\") }
            result.append(ch)
        }
        return result
    }

    private static func likePattern(_ raw: String) -> String {
        "%" + likeEscape(raw) + "%"
    }

    /// The sidebar's ⌘F -> `SearchResultsPage` query (spec B3): one pass
    /// each over targets (folder name, `TargetNameResolver`-computed
    /// display name, and target-level tags), session date-dirs (target or
    /// date substring), tracked (non-missing) files (`path`), and
    /// README-sourced session notes (exactly `searchNotes`, unchanged).
    ///
    /// `displayName` is never persisted anywhere (`TargetNameResolver` is a
    /// pure function of the folder name) so the targets section is matched
    /// in Swift, not SQL, after fetching every distinct target once; the
    /// other three sections stay plain parameterized `LIKE` queries, same
    /// convention `searchNotes`/`hasTrackedFileWithSuffix` already use.
    ///
    /// A blank (all-whitespace) `query` returns every section empty rather
    /// than matching the whole library. This method has NO knowledge of
    /// user-entered session notes written by the T6 note editor under
    /// `.astro_tool/notes/` (`SessionNoteStore`) -- that store lives outside
    /// the database entirely, on purpose (see `SessionNoteStore`'s own doc
    /// comment); a caller that wants those unioned into a search too (the
    /// CLI's `search` command, the app's global search) has the library
    /// root on hand and calls `SessionNoteStore.search` itself, then merges.
    public func searchAll(query: String, limit: Int = Database.searchFileCap) throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchResults() }

        let (targets, sessions, files, totalFileMatches) = try withLock {
            () -> (
                [(target: String, displayName: String)],
                [(target: String, date: String)],
                [(path: String, kind: String, sizeBytes: Int64)],
                Int
            ) in
            let pattern = Self.likePattern(trimmed)

            // Targets: folder name / computed display name / target-level tags.
            var tagsByTarget: [String: [String]] = [:]
            try db.query("SELECT target, tag FROM tags WHERE kind = 'target';") { row in
                guard let target = row.string(0), let tag = row.string(1) else { return }
                tagsByTarget[target, default: []].append(tag)
            }
            var allTargets: [String] = []
            try db.query("SELECT DISTINCT target FROM files WHERE target IS NOT NULL ORDER BY target;") { row in
                if let target = row.string(0) { allTargets.append(target) }
            }
            var targetHits: [(target: String, displayName: String)] = []
            for target in allTargets {
                let displayName = TargetNameResolver.resolve(folderName: target).displayName
                let tagMatch = (tagsByTarget[target] ?? []).contains {
                    $0.range(of: trimmed, options: .caseInsensitive) != nil
                }
                if target.range(of: trimmed, options: .caseInsensitive) != nil
                    || displayName.range(of: trimmed, options: .caseInsensitive) != nil
                    || tagMatch
                {
                    targetHits.append((target, displayName))
                }
            }

            // Sessions: distinct (target, session_date) under sessions/ --
            // `area = 'sessions'` excludes calibration-library files, which
            // never carry a session_date but would otherwise NULL-match
            // nothing usefully anyway.
            var sessionHits: [(target: String, date: String)] = []
            try db.query(
                """
                SELECT DISTINCT target, session_date FROM files
                WHERE area = 'sessions' AND target IS NOT NULL AND session_date IS NOT NULL
                  AND (target LIKE ? ESCAPE '\\' OR session_date LIKE ? ESCAPE '\\')
                ORDER BY target, session_date;
                """,
                bind: [.text(pattern), .text(pattern)]
            ) { row in
                guard let target = row.string(0), let date = row.string(1) else { return }
                sessionHits.append((target, date))
            }

            // Files: path LIKE, capped at `limit`, with the honest total.
            var totalFileMatches = 0
            try db.query(
                "SELECT COUNT(*) FROM files WHERE missing = 0 AND path LIKE ? ESCAPE '\\';",
                bind: [.text(pattern)]
            ) { row in totalFileMatches = Int(row.int64(0) ?? 0) }

            var fileHits: [(path: String, kind: String, sizeBytes: Int64)] = []
            try db.query(
                "SELECT path, kind, size FROM files WHERE missing = 0 AND path LIKE ? ESCAPE '\\' ORDER BY path LIMIT ?;",
                bind: [.text(pattern), .int(Int64(limit))]
            ) { row in
                guard let path = row.string(0), let kind = row.string(1) else { return }
                fileHits.append((path, kind, row.int64(2) ?? 0))
            }

            return (targetHits, sessionHits, fileHits, totalFileMatches)
        }

        // `searchNotes` takes its own lock -- called outside `withLock`
        // above so this method never nests a non-reentrant `NSLock`.
        let notes = try searchNotes(query: trimmed)

        return SearchResults(targets: targets, sessions: sessions, files: files, totalFileMatches: totalFileMatches, notes: notes)
    }

    /// Every distinct `(target, session_date)` pair on record under
    /// `sessions/` -- the candidate list a caller checks
    /// `SessionNoteStore.search` against, since that store only ever probes
    /// a filename it can predict from an already-known pair, never
    /// enumerates `.astro_tool/notes/` itself. Shared by the CLI's `search`
    /// command and the app's global search, so both union in store-written
    /// notes the exact same way.
    public func allSessionPairs() throws -> [(target: String, date: String)] {
        try withLock {
            var result: [(target: String, date: String)] = []
            try db.query(
                """
                SELECT DISTINCT target, session_date FROM files
                WHERE area = 'sessions' AND target IS NOT NULL AND session_date IS NOT NULL;
                """
            ) { row in
                guard let target = row.string(0), let date = row.string(1) else { return }
                result.append((target, date))
            }
            return result
        }
    }

    // MARK: - finding_acks (R9-T2/B5)

    /// The stable key one ack row is addressed by: `(category, groupKey)`,
    /// matching `FindingGrouper.Key`'s pair of the same name -- deliberately
    /// NOT `findings.id`, so an ack survives a later audit run that
    /// re-discovers the same logical group under brand-new finding rows.
    public static func ackKey(category: String, groupKey: String) -> String {
        "\(category)|\(groupKey)"
    }

    /// Marks one finding group as acknowledged ("rendben van, ismerem, nem
    /// hiba") -- upserts on `ack_key` so re-acking (e.g. to change `note`)
    /// never duplicates the row.
    public func ackFindingGroup(category: String, groupKey: String, note: String? = nil) throws {
        let key = Self.ackKey(category: category, groupKey: groupKey)
        try withLock {
            try db.run(
                """
                INSERT INTO finding_acks(ack_key, category, group_key, acked_at, note) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(ack_key) DO UPDATE SET acked_at = excluded.acked_at, note = excluded.note;
                """,
                bind: [
                    .text(key), .text(category), .text(groupKey), .real(Date().timeIntervalSince1970),
                    note.map(SQLiteValue.text) ?? .null,
                ]
            )
        }
    }

    /// Reverses `ackFindingGroup` -- a no-op if the group was never acked.
    public func unackFindingGroup(category: String, groupKey: String) throws {
        let key = Self.ackKey(category: category, groupKey: groupKey)
        try withLock {
            try db.run("DELETE FROM finding_acks WHERE ack_key = ?;", bind: [.text(key)])
        }
    }

    /// Every currently-acked group's key, for the app layer to filter
    /// `FindingGrouper.group(...)` output against (hide by default, dim when
    /// shown) and to exclude from the sidebar's sure-error badge count.
    public func ackedKeys() throws -> Set<String> {
        try withLock {
            var result: Set<String> = []
            try db.query("SELECT ack_key FROM finding_acks;") { row in
                if let key = row.string(0) { result.insert(key) }
            }
            return result
        }
    }

    /// Every acknowledged finding-group row, newest ack first -- `ackedKeys`'s
    /// fuller sibling for a caller that needs the `(category, groupKey)` pair,
    /// timestamp, and note, not just set membership (R10-B8, `astrotool ack
    /// list`).
    public func allAcks() throws -> [FindingAckRecord] {
        try withLock {
            var result: [FindingAckRecord] = []
            try db.query(
                "SELECT category, group_key, acked_at, note FROM finding_acks ORDER BY acked_at DESC;"
            ) { row in
                guard let category = row.string(0), let groupKey = row.string(1), let ackedAt = row.double(2)
                else { return }
                result.append(FindingAckRecord(category: category, groupKey: groupKey, ackedAt: ackedAt, note: row.string(3)))
            }
            return result
        }
    }

    // MARK: - findings retention (B20)

    /// Deletes `findings` rows belonging to any `kind`-kind run except the
    /// most recent `keepRuns` -- the `runs` rows themselves are left alone
    /// (only their child findings are pruned), and runs of any OTHER kind
    /// (and their findings, if they ever have any) are never touched.
    ///
    /// This is the app's OWN `.astro_tool` database, not the image library
    /// the iron rule protects -- deleting rows here is ordinary DAO
    /// housekeeping, the same class of operation as `markMissing`'s UPDATE or
    /// `removeTag`'s DELETE elsewhere in this file. Called once at the end of
    /// every `AuditEngine.run` (kind `"audit"`, the original B20 call site)
    /// and every `FixityVerifier.run` (kind `"verify"`, R11-T14) so neither
    /// table grows unbounded; `kind` defaults to `"audit"` so that original
    /// call site (and every existing test) is unaffected by this parameter's
    /// addition.
    public func pruneFindings(keepRuns: Int = 3, kind: String = "audit") throws {
        try withLock {
            try db.run(
                """
                DELETE FROM findings WHERE run_id IN (
                  SELECT id FROM runs WHERE kind = ?
                  AND id NOT IN (
                    SELECT id FROM runs WHERE kind = ? ORDER BY started_at DESC LIMIT ?
                  )
                );
                """,
                bind: [.text(kind), .text(kind), .int(Int64(keepRuns))]
            )
        }
    }

    /// Cheap denominator for fixity coverage: every tracked, non-missing
    /// file in the requested target/path scope, regardless of whether it
    /// already has a cached content hash.
    public func countTrackedFiles(target: String? = nil, pathPrefix: String? = nil) throws -> Int {
        try withLock {
            var sql = "SELECT COUNT(*) FROM files WHERE missing = 0"
            var bind: [SQLiteValue] = []
            if let target {
                sql += " AND target = ?"
                bind.append(.text(target))
            }
            if let pathPrefix {
                sql += " AND (path = ? OR instr(path, ?) = 1)"
                bind.append(.text(pathPrefix))
                bind.append(.text(pathPrefix + "/"))
            }
            sql += ";"

            var count = 0
            try db.query(sql, bind: bind) { row in
                count = Int(row.int64(0) ?? 0)
            }
            return count
        }
    }

    /// Cheap `COUNT(*)` of files `FixityVerifier.eligibleFiles(...)` would
    /// actually re-hash for the given scope -- tracked (non-missing) files
    /// that already have a cached `content_hash`, optionally narrowed to one
    /// `target` and/or one root-relative `pathPrefix` subtree (matching the
    /// file itself or anything nested under it, same convention as
    /// `markMissing(underSubpath:)`).
    ///
    /// A dedicated COUNT query rather than `allFiles(...).filter(...).count`
    /// (which `FixityVerifier` itself uses for the real run, since it needs
    /// the full `FileRecord`s anyway) because this backs a synchronous UI
    /// estimate -- the app's "Integritás-ellenőrzés…" confirmation sheet's
    /// "N fájl" figure -- that must stay fast even on a library with tens of
    /// thousands of files, where materializing every `FileRecord` just to
    /// throw away everything except a count would be wasteful. Same
    /// reasoning as `hasTrackedFileWithSuffix`'s own doc comment.
    public func countHashedFiles(target: String? = nil, pathPrefix: String? = nil) throws -> Int {
        try withLock {
            var sql = "SELECT COUNT(*) FROM files WHERE missing = 0 AND content_hash IS NOT NULL"
            var bind: [SQLiteValue] = []
            if let target {
                sql += " AND target = ?"
                bind.append(.text(target))
            }
            if let pathPrefix {
                sql += " AND (path = ? OR instr(path, ?) = 1)"
                bind.append(.text(pathPrefix))
                bind.append(.text(pathPrefix + "/"))
            }
            sql += ";"

            var count = 0
            try db.query(sql, bind: bind) { row in
                count = Int(row.int64(0) ?? 0)
            }
            return count
        }
    }
}
