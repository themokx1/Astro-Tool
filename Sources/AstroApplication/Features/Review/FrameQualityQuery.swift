import AstroCore
import Foundation

/// One frame's measured quality, projected for the V2 review table. Every
/// measured field is `nil` -- never `0` -- when the frame hasn't been rated
/// yet (no `ratings` row) or the underlying frame was never even scanned (no
/// `files` row for `relativePath` at all): a `0` would read as "measured
/// zero", which is a real (if unusual) value for some of these metrics
/// (`saturatedFraction`), so only an explicit `nil` can mean "not measured".
public struct FrameQualityMetrics: Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let fwhm: Double?
    public let roundness: Double?
    public let starCount: Int?
    public let background: Double?
    public let saturatedFraction: Double?
    public let score: Double?
    /// `score < -config.rating.outlierZScore`, the same threshold
    /// `Rater.cachedScores` itself uses to recompute `isOutlier` from a
    /// persisted score -- `nil` exactly when `score` itself is `nil` (an
    /// unrated frame is neither an outlier nor a non-outlier, it's simply
    /// unmeasured).
    public let isOutlier: Bool?
    /// This frame's `score` ranked against every OTHER rated frame's score
    /// anywhere in this library (`LibraryPercentiles.evaluate`, higher is
    /// better -- `Rater`'s own scoring convention). `nil` when this frame has
    /// no score to rank at all.
    public let libraryPercentile: LibraryPercentileResult?
    /// The resolved capture-group slug (`CaptureResolver.resolve(file:meta:)
    /// .slug`), e.g. `"osc"`/`"ha"` -- lets the review table's "Capture
    /// group" filter narrow a series down the same way V1's `QualitySegment`
    /// "Gyűjtés" menu narrows by capture slug within a session. `nil` when
    /// the frame has no resolvable capture group at all (never assigned,
    /// never inferred from its path).
    public let captureSlug: String?

    public init(
        relativePath: String,
        fwhm: Double?,
        roundness: Double?,
        starCount: Int?,
        background: Double?,
        saturatedFraction: Double?,
        score: Double?,
        isOutlier: Bool?,
        libraryPercentile: LibraryPercentileResult?,
        captureSlug: String? = nil
    ) {
        self.relativePath = relativePath
        self.fwhm = fwhm
        self.roundness = roundness
        self.starCount = starCount
        self.background = background
        self.saturatedFraction = saturatedFraction
        self.score = score
        self.isOutlier = isOutlier
        self.libraryPercentile = libraryPercentile
        self.captureSlug = captureSlug
    }
}

/// Read-only projection of `Rater`'s persisted output (`ratings`/`files`) for
/// V2's Review workspace -- never runs a measurement itself (see
/// `FrameRatingCommand` for that), only reads back whatever's already on
/// record, the same "engine result passed straight through" stance
/// `CalibrationQuery` already documents for itself.
public struct FrameQualityQuery: Sendable {
    private let db: Database
    private let config: AstroConfig

    public init(db: Database, config: AstroConfig) {
        self.db = db
        self.config = config
    }

    public static func production(rootURL: URL) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        return Self(db: database, config: config)
    }

    /// One `FrameQualityMetrics` per entry of `relativePaths`, in the exact
    /// order given (matches `ReviewSeriesSnapshot.decisions`' own order, so
    /// callers can zip the two arrays directly). A path with no matching
    /// `files` row, or one whose `ratings` row has no `score` yet, comes back
    /// with every measured field `nil`.
    public func metrics(relativePaths: [String]) throws -> [FrameQualityMetrics] {
        guard !relativePaths.isEmpty else { return [] }

        // The library-wide score distribution this call's percentiles are
        // ranked against -- computed once per call (not once per requested
        // frame), same "whole library, freshly, no persisted baseline"
        // stance `LibraryPercentiles.libraryFWHMArcsecValues` already
        // documents for its own distribution.
        let allRatedScores = try libraryScores()
        // Loaded once per call, same as `Rater.rate` itself -- see
        // `CaptureResolver.load`'s own doc comment on why one preloaded
        // snapshot beats an N+1 query per frame.
        let captureResolver = try CaptureResolver.load(db: db)

        var results: [FrameQualityMetrics] = []
        results.reserveCapacity(relativePaths.count)

        for relativePath in relativePaths {
            guard let file = try db.file(path: relativePath), let fileID = file.id else {
                results.append(Self.empty(relativePath: relativePath))
                continue
            }
            let meta = try db.fitsMeta(fileID: fileID)
            let captureSlug = captureResolver.resolve(file: file, meta: meta).slug

            guard let rating = try db.rating(fileID: fileID), let score = rating.score else {
                results.append(Self.empty(relativePath: relativePath, captureSlug: captureSlug))
                continue
            }

            let percentile = LibraryPercentiles.evaluate(
                value: score, allValues: allRatedScores, higherIsBetter: true
            )

            results.append(FrameQualityMetrics(
                relativePath: relativePath,
                fwhm: rating.fwhm,
                roundness: rating.roundness,
                starCount: rating.starCount,
                background: rating.background,
                saturatedFraction: rating.saturatedFraction,
                score: score,
                isOutlier: score < -config.rating.outlierZScore,
                libraryPercentile: percentile,
                captureSlug: captureSlug
            ))
        }
        return results
    }

    private static func empty(relativePath: String, captureSlug: String? = nil) -> FrameQualityMetrics {
        FrameQualityMetrics(
            relativePath: relativePath, fwhm: nil, roundness: nil, starCount: nil,
            background: nil, saturatedFraction: nil, score: nil, isOutlier: nil,
            libraryPercentile: nil, captureSlug: captureSlug
        )
    }

    /// Every non-`nil` `ratings.score` in the whole library, regardless of
    /// target/date/role beyond `allFiles`'s own non-missing filter --
    /// deliberately not scoped to the frames being requested, since a
    /// percentile is only meaningful ranked against the FULL distribution.
    private func libraryScores() throws -> [Double] {
        let fileIDs = try db.allFiles(includeMissing: false).compactMap(\.id)
        let ratings = try db.ratingsBatch(fileIDs: fileIDs)
        return ratings.values.compactMap(\.score)
    }
}
