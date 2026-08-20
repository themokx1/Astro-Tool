import AstroCore
import Foundation

/// Wraps the V1 session-conversion engine (`SessionConversionPlanner` +
/// `SessionConversionExecutor` in `AstroCore`) for V2: `plan(target:date:mode:)`
/// and `resolvingAmbiguity`/`editingGroup` are pure, read-only preview
/// operations always available regardless of `accessMode`; `apply(_:)` and
/// `rollback(_:)` are the only two calls that touch the filesystem, and both
/// throw `LibraryMutationError.readOnly` before doing so unless
/// `accessMode == .mutationEnabled` -- mirrors `CalibrationLinkCommand`'s own
/// gate. Never re-implements the planner's clustering/ambiguity logic or the
/// executor's move/rollback/receipt logic; this command only opens the
/// engine against this library's database and root, and forwards to it.
public struct SessionConversionCommand: Sendable {
    private let db: Database
    private let config: AstroConfig
    private let root: URL
    private let accessMode: LibraryAccessMode

    public init(db: Database, config: AstroConfig, root: URL, accessMode: LibraryAccessMode) {
        self.db = db
        self.config = config
        self.root = root
        self.accessMode = accessMode
    }

    public static func production(rootURL: URL, accessMode: LibraryAccessMode) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = rootURL.path
        return Self(db: database, config: config, root: rootURL, accessMode: accessMode)
    }

    /// Builds a fresh preview for one exact target/date scope -- always
    /// available, even in read-only mode; nothing is written by this call.
    /// `SessionConversionPlanner.plan` itself refreshes the three affected
    /// branches (sessions/stacks/processed) before fingerprinting, so the
    /// returned plan's `sourceFingerprint` reflects the library as it is
    /// right now.
    public func plan(target: String, date: String, mode: SessionConversionMode) throws -> SessionConversionPlan {
        try SessionConversionPlanner.plan(target: target, date: date, db: db, config: config, mode: mode)
    }

    /// Records one human decision for a blocking ambiguity -- pure plan
    /// transformation via `SessionConversionPlanner.resolving`, no database or
    /// filesystem access. Always available regardless of `accessMode`.
    public func resolvingAmbiguity(
        id ambiguityID: String,
        withGroupSlug groupSlug: String,
        in plan: SessionConversionPlan
    ) throws -> SessionConversionPlan {
        let files = try scopedFiles(for: plan.scope)
        return try SessionConversionPlanner.resolving(
            ambiguityID: ambiguityID, withGroupSlug: groupSlug, in: plan, files: files
        )
    }

    /// Overwrites one proposed group's editable fields (display name, sensor
    /// mode, signal mode, filter) in place on the plan -- the same in-memory
    /// mutation V1's `SessionConversionSheet` applies directly to
    /// `sessionConversionPlan.proposedGroups[index].draft` before the user
    /// applies. The group's `slug` (and therefore every move/assignment that
    /// references it) is never touched here -- only the metadata the executor
    /// later writes onto the `capture_groups` row changes. Throws if `slug`
    /// no longer names a proposed group in `plan` (e.g. an ambiguity
    /// resolution removed it).
    public func editingGroup(
        slug: String,
        displayName: String,
        sensorMode: SensorMode,
        signalMode: SignalMode,
        filterManufacturer: String?,
        filterModel: String?,
        filterName: String?,
        in plan: SessionConversionPlan
    ) throws -> SessionConversionPlan {
        var updated = plan
        guard let index = updated.proposedGroups.firstIndex(where: { $0.draft.slug == slug }) else {
            throw AstroError.invalidInput("A(z) \(slug) gyűjtés már nincs a tervben.")
        }
        updated.proposedGroups[index].draft.displayName = displayName
        updated.proposedGroups[index].draft.sensorMode = sensorMode
        updated.proposedGroups[index].draft.signalMode = signalMode
        updated.proposedGroups[index].draft.filterManufacturer = filterManufacturer
        updated.proposedGroups[index].draft.filterModel = filterModel
        updated.proposedGroups[index].draft.filterName = filterName
        return updated
    }

    /// Applies a previously-previewed `plan` through
    /// `SessionConversionExecutor.apply` -- the sole physical mover; this
    /// command invents no move logic of its own. Throws
    /// `LibraryMutationError.readOnly` immediately, before any filesystem or
    /// database access, unless `accessMode == .mutationEnabled`. In
    /// `.logicalOnly` mode the executor moves no files, only capture
    /// metadata; in `.physical` mode it moves exactly `plan.moves` and
    /// returns the receipt needed for `rollback(_:)`. A stale or already-
    /// applied plan is rejected by the executor/database's own guards
    /// (source fingerprint mismatch, or a proposed group's slug already
    /// existing) -- this command surfaces those errors unchanged.
    @discardableResult
    public func apply(_ plan: SessionConversionPlan) throws -> SessionConversionReceipt {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        return try SessionConversionExecutor.apply(plan: plan, root: root, db: db)
    }

    /// Restores everything one applied `receipt` changed -- both the moved
    /// files (physical mode) and the capture metadata -- through
    /// `SessionConversionExecutor.rollback`. Same read-only gate as `apply`.
    /// The executor itself rejects rolling back a receipt that is not
    /// currently `.applied` (e.g. already rolled back).
    @discardableResult
    public func rollback(_ receipt: SessionConversionReceipt) throws -> SessionConversionReceipt {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        return try SessionConversionExecutor.rollback(receipt: receipt, root: root, db: db)
    }

    /// The same target/date/area filter `SessionConversionPlanner.plan`
    /// applies internally, re-derived here only so `resolvingAmbiguity` can
    /// hand the planner the current file list for the scope without
    /// re-running a whole new plan.
    private func scopedFiles(for scope: SessionConversionScope) throws -> [FileRecord] {
        try db.allFiles(includeMissing: false).filter { file in
            file.target == scope.target && file.sessionDate == scope.date
                && (file.area == .sessions || file.area == .stacks || file.area == .processed)
        }
    }
}
