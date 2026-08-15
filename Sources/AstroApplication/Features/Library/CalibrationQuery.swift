import AstroCore
import Foundation

/// One master-dark directory, projected for display: path, kind (always
/// `.dark` today -- `CalibHealth.report`'s own `darkMasters` only ever
/// inventories `calibration_library/darks/`, see its doc comment), a
/// representative temperature, age, and staleness. Every field here is
/// sourced straight from `DarkMasterHealth` rather than recomputed --
/// age/staleness/temperature-median math stays the engine's alone.
public struct CalibrationMasterInfo: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: FrameRole
    /// Median `CCD-TEMP` across the master's files (`DarkMasterHealth.tempMedian`), `nil` when none had one.
    public let temperatureCelsius: Double?
    public let ageDays: Int?
    public let isStale: Bool
    public let frameCount: Int
    /// `true` when no current light-combo needs this master (`DarkMasterHealth.isUnused`).
    public let isUnused: Bool
    /// Hungarian warnings from `CalibHealth`, e.g. `["instabil hőmérséklet"]`.
    public let warnings: [String]

    public init(
        path: String,
        kind: FrameRole,
        temperatureCelsius: Double?,
        ageDays: Int?,
        isStale: Bool,
        frameCount: Int,
        isUnused: Bool,
        warnings: [String]
    ) {
        self.path = path
        self.kind = kind
        self.temperatureCelsius = temperatureCelsius
        self.ageDays = ageDays
        self.isStale = isStale
        self.frameCount = frameCount
        self.isUnused = isUnused
        self.warnings = warnings
    }

    // MARK: Sort keys
    //
    // `KeyPathComparator` needs a non-optional `Comparable` value; these
    // give the V2 Calibration workspace's masters table one for each of its
    // otherwise-optional or composite columns.

    public var temperatureSortKey: Double { temperatureCelsius ?? -.infinity }
    public var ageDaysSortKey: Int { ageDays ?? -1 }
    /// Matches `CalibrationView.masterStatus`'s own precedence (stale, then
    /// unused, then OK) so sorting this column groups rows the same way
    /// that view's own status label already reads.
    public var statusSortKey: Int {
        if isStale { return 2 }
        if isUnused { return 1 }
        return 0
    }
}

/// Read-only projections over the calibration engines (`CalibAnalyzer`,
/// `SessionMatcher`, `CalibHealth`) for the V2 calibration workspace. This
/// type never re-derives matching, staleness, or aggregation logic -- every
/// value returned here is either an engine result passed straight through
/// or a thin relabeling of one.
public struct CalibrationQuery: Sendable {
    private let db: Database
    private let config: AstroConfig

    public init(db: Database, config: AstroConfig) {
        self.db = db
        self.config = config
    }

    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = rootURL.path
        return Self(db: database, config: config)
    }

    /// Per-combo dark coverage needs (`CalibAnalyzer.coverage`), each
    /// carrying the sessions it applies to.
    public func coverage(now: Date = Date()) throws -> [CalibNeed] {
        try CalibAnalyzer.coverage(db: db, config: config, now: now)
    }

    /// Per-filter flat coverage across the whole library
    /// (`CalibAnalyzer.flatCoverage`).
    public func flatCoverage() throws -> [CalibNeed] {
        try CalibAnalyzer.flatCoverage(db: db, config: config)
    }

    /// Master-dark inventory, projected from `CalibHealth.report`'s own
    /// `darkMasters` -- age/staleness/temperature-median are already
    /// computed there, never recomputed here.
    public func masterInventory(now: Date = Date()) throws -> [CalibrationMasterInfo] {
        let report = try CalibHealth.report(db: db, config: config, now: now)
        return report.darkMasters.map { health in
            CalibrationMasterInfo(
                path: health.path,
                kind: .dark,
                temperatureCelsius: health.tempMedian,
                ageDays: health.ageDays,
                isStale: health.isStale,
                frameCount: health.frameCount,
                isUnused: health.isUnused,
                warnings: health.warnings
            )
        }
    }

    /// The full calibration-health report (flat discipline, bias groups,
    /// dark-master health) -- for anything the calibration workspace wants
    /// to surface beyond the master inventory alone.
    public func healthReport(now: Date = Date()) throws -> CalibHealthReport {
        try CalibHealth.report(db: db, config: config, now: now)
    }

    /// Hungarian mismatch-reason strings (gain/offset/binning/camera) for
    /// why `target`/`date` has no usable library-dark fallback -- straight
    /// from `SessionMatcher.match`, never re-derived. Throws
    /// `AstroError.pathNotFound` when the session doesn't exist, same as
    /// `SessionMatcher.match` itself.
    public func mismatchReasons(target: String, date: String) throws -> [String] {
        try SessionMatcher.match(target: target, date: date, db: db, config: config).libraryDarkMismatchReasons
    }
}
