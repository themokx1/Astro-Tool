import AstroCore
import Foundation

/// Outcome of a successful `CalibrationLinkCommand.apply` -- which session
/// this was for, and `WriteGuard`'s own `LinkResult` (linked vs. already-
/// present-so-skipped destinations), unchanged.
public struct CalibrationLinkReceipt: Equatable, Sendable {
    public let target: String
    public let date: String
    public let linked: [String]
    public let skipped: [String]

    public init(target: String, date: String, linked: [String], skipped: [String]) {
        self.target = target
        self.date = date
        self.linked = linked
        self.skipped = skipped
    }
}

/// Computes and applies calibration-library link plans (`CalibLinker.plan`/
/// `CalibLinker.apply`) for one session. `plan(target:date:)` is read-only
/// and always available; `apply(_:)` is gated on `accessMode` -- it throws
/// `LibraryMutationError.readOnly` in `.readOnly` mode and otherwise walks
/// the plan through `WriteGuard.linkCalibrationFile` (via `CalibLinker.apply`),
/// the same single filesystem-writing path every other write in AstroCore
/// uses. Never bypasses `WriteGuard` and never re-derives its matching
/// logic.
public struct CalibrationLinkCommand: Sendable {
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

    /// Builds the link preview for `target`/`date` -- always available,
    /// even in read-only mode; nothing is written by this call.
    public func plan(target: String, date: String) throws -> CalibLinkPlan {
        try CalibLinker.plan(target: target, date: date, db: db, config: config)
    }

    /// Applies a previously-previewed `plan`. Throws
    /// `LibraryMutationError.readOnly` immediately (before any filesystem
    /// access) unless `accessMode == .mutationEnabled`. Idempotent per
    /// `WriteGuard.linkCalibrationFile`'s own semantics: a destination that
    /// already exists is reported in the receipt's `skipped` list rather
    /// than re-linked or erroring.
    @discardableResult
    public func apply(_ plan: CalibLinkPlan) throws -> CalibrationLinkReceipt {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        let writeGuard = WriteGuard(root: root)
        let result = try CalibLinker.apply(plan, root: root, using: writeGuard)
        return CalibrationLinkReceipt(target: plan.target, date: plan.date, linked: result.linked, skipped: result.skipped)
    }
}
