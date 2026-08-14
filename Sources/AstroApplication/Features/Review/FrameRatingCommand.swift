import AstroCore
import Foundation

/// The two ways V1's "Keretek pontozása" menu can rate a session's frames
/// (`QualitySegment`'s control bar, `AppState.runRate`) -- V2 exposes the
/// same two, nothing more: a primary-action full re-measure (native stats
/// plus Siril star metrics, forcing every frame to be recomputed even if
/// cached) and an explicit native-only fallback that never touches Siril at
/// all, even when one is configured.
public enum FrameRatingMode: String, Equatable, Sendable, CaseIterable {
    case fullReMeasure
    case nativeOnly
}

public enum FrameRatingCommandError: Error, Equatable, Sendable, LocalizedError {
    /// None of the requested `relativePaths` matched a scanned, targeted
    /// light frame in the index DB -- there is no session to rate at all.
    case noMatchingFrames
    /// `.fullReMeasure` was requested but `SirilCLI(path:)` could not be
    /// constructed at `config.rating.sirilPath` -- `.nativeOnly` always
    /// works regardless of this.
    case sirilUnavailable(path: String)

    public var errorDescription: String? {
        switch self {
        case .noMatchingFrames:
            return "None of the selected frames are indexed in this library yet."
        case let .sirilUnavailable(path):
            return "Siril isn't available at \(path). Use \"Native only\" or fix the Siril path in Settings."
        }
    }
}

/// Wraps `Rater.rate` for V2's "Rate Frames…" flow: given ANY subset of a
/// review session's frame paths, resolves that session's own target/date
/// scope from the first path that's actually indexed, then rates the WHOLE
/// session through it -- exactly the session-wide scope
/// `Rater.rate(target:date:)`/V1's `QualitySegment` control bar already use,
/// never just the hand-picked subset (z-scoring needs every sibling frame in
/// the same exposure cohort to mean anything). Progress and cooperative
/// cancellation follow `SensorMeasurementCommand`'s own shape: `progress` is
/// called once per frame, immediately checking `isCancelled` before
/// forwarding it, so a cancellation always lands BETWEEN two frames -- never
/// mid-frame -- with every frame reported so far already durably upserted by
/// `Rater` itself.
public struct FrameRatingCommand: Sendable {
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

    /// Rates the session that `relativePaths` belong to. `force` is implied
    /// by `mode` (`.fullReMeasure` forces every frame; `.nativeOnly` respects
    /// the usual cache). Throws `FrameRatingCommandError.noMatchingFrames`
    /// when nothing in `relativePaths` resolves to a known, targeted light
    /// frame, and `FrameRatingCommandError.sirilUnavailable` when
    /// `.fullReMeasure` is requested but no working Siril binary is
    /// configured -- `.nativeOnly` never throws for that reason.
    @discardableResult
    public func run(
        relativePaths: [String],
        mode: FrameRatingMode,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> [FrameScore] {
        guard let anchor = try firstKnownFrame(among: relativePaths) else {
            throw FrameRatingCommandError.noMatchingFrames
        }

        let provider: StarMetricsProvider?
        switch mode {
        case .nativeOnly:
            provider = nil
        case .fullReMeasure:
            guard let siril = try? SirilCLI(path: config.rating.sirilPath) else {
                throw FrameRatingCommandError.sirilUnavailable(path: config.rating.sirilPath)
            }
            provider = siril
        }

        let rater = Rater(db: db, config: config, provider: provider)
        return try rater.rate(
            target: anchor.target,
            date: anchor.sessionDate,
            force: mode == .fullReMeasure,
            progress: { done, total in
                if let isCancelled, isCancelled() {
                    throw CancellationError()
                }
                progress?(done, total)
            }
        )
    }

    /// The first `relativePaths` entry that resolves to a scanned light
    /// frame with a known target -- its `(target, sessionDate)` is the
    /// session scope the whole run rates, regardless of how many (or few) of
    /// the OTHER requested paths also happen to match.
    private func firstKnownFrame(among relativePaths: [String]) throws -> (target: String, sessionDate: String?)? {
        for path in relativePaths {
            if let file = try db.file(path: path), let target = file.target {
                return (target, file.sessionDate)
            }
        }
        return nil
    }
}
