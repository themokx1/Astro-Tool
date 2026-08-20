import AstroCore
import Foundation

/// Wraps `SensorProfiler.measure` for V2's "Measure Sensors…" flow: same
/// read-tracked-BIAS/DARK-frames-write-to-the-index-database contract as
/// the classic workflow's own measurement button
/// (`AppState.measureSensorProfiles()`), plus a progress relay and
/// cooperative cancellation suited to running under `OperationHost`.
///
/// Unlike most V2 write commands (`CalibrationLinkCommand`,
/// `QuarantineApplyCommand`), this never gates on `LibraryAccessMode`: the
/// only thing it ever writes is this library's OWN external index database
/// (`sensor_profile`/`sensor_profile_history`), never a file inside the
/// image library itself -- the same reasoning the classic workflow's
/// measurement button already relies on, so read-only library mode does
/// not block it.
public struct SensorMeasurementCommand: Sendable {
    private let db: Database
    private let config: AstroConfig
    private let root: URL

    public init(db: Database, config: AstroConfig, root: URL) {
        self.db = db
        self.config = config
        self.root = root
    }

    public static func production(rootURL: URL) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        return Self(db: database, config: config, root: root)
    }

    /// Runs `SensorProfiler.measure`, forwarding each combo's own progress
    /// message to `progress` and checking `isCancelled` immediately before
    /// forwarding it -- i.e. BEFORE that next combo's reads/upsert ever
    /// start, never mid-combo. `SensorProfiler.measure` upserts each combo
    /// (and appends its history row) before moving to the next one, so
    /// stopping here can never leave a partially-written combo: every combo
    /// this call reported progress for by the time it throws is already
    /// safely on record.
    ///
    /// Throws `CancellationError` -- exactly what `OperationHost.run`'s own
    /// `catch is CancellationError` expects -- the moment `isCancelled`
    /// first reports `true`, rather than returning a partial result
    /// normally; callers that want "what got measured before cancelling"
    /// re-read it via `SensorProfilesQuery`/`Database.allSensorProfiles()`
    /// afterward, the same way any other cancelled operation is observed.
    @discardableResult
    public func run(
        progress: (@Sendable (String) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> [SensorProfileRecord] {
        try SensorProfiler.measure(db: db, config: config, root: root) { message in
            if let isCancelled, isCancelled() {
                throw CancellationError()
            }
            progress?(message)
        }
    }
}
