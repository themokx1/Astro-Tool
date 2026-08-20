import AstroCore
import Foundation

/// One frame the Morning Triage Digest can explain and select -- built
/// directly from data the V2 review pipeline already loaded
/// (`FrameDecisionRecord.id`/`.relativePath` plus `ReviewStore.quality(for:)`
/// / `FrameQualityQuery.metrics(relativePaths:)`'s own `FrameQualityMetrics`),
/// never a second read from disk or the database.
public struct TriageDigestFrame: Equatable, Sendable {
    public let id: UUID
    public let relativePath: String
    public let quality: FrameQualityMetrics?

    public init(id: UUID, relativePath: String, quality: FrameQualityMetrics?) {
        self.id = id
        self.relativePath = relativePath
        self.quality = quality
    }
}

/// One line of the digest: how many of this session's outlier frames share
/// the same dominant cause (`OutlierBreakdown.dominantMetric`).
public struct TriageDigestCause: Equatable, Sendable {
    public let metric: OutlierBreakdown.Metric
    public let count: Int
}

/// Morning Triage Digest (expert ideation spec #1, "the owner triages ~2800
/// lights"): rolls up WHY each frame in one already-open review session
/// scored low, one line per dominant metric, and lets the caller select
/// every frame sharing one cause in a single click. Selection only -- it
/// never writes a verdict itself; the caller still drives whatever it
/// selects through the review workspace's existing accept/reject flow.
///
/// Deliberately never re-derives the z-score math: `OutlierBreakdown
/// .breakdowns(for:)` (`Sources/AstroCore/Rate/OutlierBreakdown.swift`) is
/// the one place that owns it, shared with `Rater`'s own scoring pass, so
/// re-implementing an approximation here could silently drift from what the
/// frame actually scored. This query is always constructed from ONE
/// already-selected session's frames (one `ReviewSeriesSnapshot`'s
/// decisions -- a series is one fixed exposure/filter/setup within one
/// night, see `ReviewQuery`'s own doc comment), so every synthetic
/// `FrameScore` fed to `breakdowns(for:)` below carries the SAME fixed
/// `Self.sharedCohort` rather than one derived per frame: it forces every
/// frame in `frames` into exactly one shared z-score population, which is
/// already what "one session" means at this call site, without this layer
/// needing to know anything about `Rater`'s own session-date/exptime path
/// parsing (V2's `relativePath`s don't even follow the V1 `sessions/<target>
/// /<date>/...` convention `OutlierBreakdown.sessionDate(ofPath:)` parses).
public struct TriageDigestQuery: Sendable {
    /// Any single fixed value works here -- only its role as "the same
    /// cohort for every frame passed to this call" matters, never the value
    /// itself entering any comparison.
    private static let sharedCohort = RatingCohortDescriptor(sessionDate: "triage-digest")

    /// Non-empty cause lines, sorted by frame count descending (the digest
    /// card's own "6x focus slip, 2x cloud/haze" ordering -- worst-explained
    /// cause first).
    public let causes: [TriageDigestCause]
    private let frameIDsByCause: [OutlierBreakdown.Metric: [UUID]]

    /// Frames this session hedges as "possible satellite trail -- check"
    /// (expert ideation #8, `SatelliteStreakHeuristic`) -- deliberately a
    /// SEPARATE line from `causes` above, never merged into them: this is
    /// never a verdict, just a suggestion to look closer, and it can catch
    /// frames `causes` never would (a streak's inflated `starCount` can
    /// push a frame's overall `score` UP, so it may never even trip the
    /// ordinary `isOutlier` flag that `causes` requires -- see the
    /// heuristic's own doc comment). Runs over every frame handed to this
    /// query, not just the outlier subset, for exactly that reason.
    private let possibleStreakFrameIDs: [UUID]

    /// `true` when `frames` contains no flagged outlier AND no possible
    /// streak -- the spec's own empty state: a caller checks this before
    /// ever rendering the digest card, rather than rendering an
    /// all-zero card.
    public var isEmpty: Bool { causes.isEmpty && possibleStreakFrameIDs.isEmpty }

    public var totalOutlierCount: Int { causes.reduce(0) { $0 + $1.count } }

    /// `true` exactly when the hedged "possible satellite trail" line has
    /// something to show -- a caller checks this before rendering that
    /// line, matching the "absent entirely at zero hits" spec.
    public var hasPossibleStreak: Bool { !possibleStreakFrameIDs.isEmpty }

    public var possibleStreakCount: Int { possibleStreakFrameIDs.count }

    public init(frames: [TriageDigestFrame]) {
        var scoreByID: [UUID: FrameScore] = [:]
        scoreByID.reserveCapacity(frames.count)
        for frame in frames {
            guard let quality = frame.quality else { continue }
            let metrics: StarMetrics? = {
                guard let fwhm = quality.fwhm, let starCount = quality.starCount else { return nil }
                return StarMetrics(fwhm: fwhm, roundness: quality.roundness, starCount: starCount)
            }()
            scoreByID[frame.id] = FrameScore(
                path: frame.relativePath,
                score: quality.score ?? 0,
                isOutlier: quality.isOutlier ?? false,
                metrics: metrics,
                background: quality.background,
                cohort: Self.sharedCohort
            )
        }

        // Computed over the FULL population handed to this query (not just
        // the outlier subset below) -- an accurate mean/std/median needs
        // every frame that has a value for a metric, exactly like
        // `Rater.cachedScores`'s own call to this same function.
        let breakdownsByPath = OutlierBreakdown.breakdowns(for: Array(scoreByID.values))

        var idsByCause: [OutlierBreakdown.Metric: [UUID]] = [:]
        for (id, score) in scoreByID {
            guard score.isOutlier, let metric = breakdownsByPath[score.path]?.dominantMetric else { continue }
            idsByCause[metric, default: []].append(id)
        }
        self.frameIDsByCause = idsByCause
        self.causes = OutlierBreakdown.Metric.allCases
            .compactMap { metric in idsByCause[metric].map { TriageDigestCause(metric: metric, count: $0.count) } }
            .sorted { $0.count > $1.count }

        let streakPaths = SatelliteStreakHeuristic.flaggedPaths(for: Array(scoreByID.values))
        self.possibleStreakFrameIDs = scoreByID
            .filter { streakPaths.contains($0.value.path) }
            .map(\.key)
    }

    /// Every outlier frame in this session whose dominant metric is
    /// `metric` -- the digest card's "Select frames" button per cause row.
    public func selectFrames(forCause metric: OutlierBreakdown.Metric) -> [UUID] {
        frameIDsByCause[metric] ?? []
    }

    /// Every frame this session hedges as a possible satellite trail --
    /// the digest card's own separately-styled "select" button. Selection
    /// only, exactly like `selectFrames(forCause:)`: never a verdict, never
    /// an auto-reject.
    public func selectPossibleStreakFrames() -> [UUID] {
        possibleStreakFrameIDs
    }
}
