import Foundation

/// Shared exposure-group key + z-score math, used both by `Rater`'s actual
/// scoring pass (`Rater.score`/`scoreGroup`) and by `OutlierBreakdown`'s
/// query-time re-derivation of *why* one frame scored low on a given metric
/// (R11-T7/F4). Pulled out of `Rater` (which used to keep an identical copy
/// `private` to itself) so the two can never silently drift apart -- the
/// popover's "z = -2.4" is computed by the EXACT same grouping + formula
/// that produced the frame's actual `score`/`isOutlier`, not a look-alike
/// approximation recomputed from scratch.
enum RatingGroupMath {
    /// Mean/std/median over one metric's values within one exposure group.
    /// `median` is additive (over what `Rater`'s original private
    /// `MetricStats` carried) -- purely a display anchor for
    /// `OutlierBreakdown` ("session-medián 2.9 px"), never fed into the
    /// z-score itself, which stays mean/std-based so it matches `Rater`'s
    /// actual scoring formula exactly.
    struct MetricStats {
        var mean: Double
        var std: Double
        var median: Double
    }

    /// Which exposure group a frame belongs to for scoring purposes: the
    /// frame's session date (so scoring/explaining a whole target across
    /// many nights never pools different nights' sky conditions into one
    /// z-score population) crossed with its nominal exptime (`NominalExposure`,
    /// which absorbs float noise like 29.9s vs. 30.0s) -- or
    /// `nominalTenths == nil` for every frame with no `exptime` at all, one
    /// single shared group per date (not one singleton group each, which
    /// would force every such frame's z-score to 0).
    struct GroupKey: Hashable {
        var sessionDate: String?
        var nominalTenths: Int?
    }

    static func groupKey(sessionDate: String?, exptime: Double?) -> GroupKey {
        guard let exptime else { return GroupKey(sessionDate: sessionDate, nominalTenths: nil) }
        let nominal = NominalExposure.nominal(exptime)
        return GroupKey(sessionDate: sessionDate, nominalTenths: Int((nominal * 10).rounded()))
    }

    /// Mean/std/median over whichever frames in the group have a value for
    /// this metric. `std == 0` (a single sample, or every value identical)
    /// is the div-by-zero guard `zScore` checks for.
    static func metricStats(_ values: [Double]) -> MetricStats {
        guard !values.isEmpty else { return MetricStats(mean: 0, std: 0, median: 0) }
        guard values.count > 1 else { return MetricStats(mean: values[0], std: 0, median: values[0]) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return MetricStats(mean: mean, std: variance.squareRoot(), median: median)
    }

    static func zScore(_ value: Double, stats: MetricStats) -> Double {
        guard stats.std > 0 else { return 0 }
        return (value - stats.mean) / stats.std
    }
}

/// Per-metric breakdown of why one frame was flagged `isOutlier` by `Rater`
/// -- R11-T7 (F4), the "Kiugró-híd" bridging the machine's z-score outlier
/// flag to the user's own accept/reject verdict. `Rater.scoreGroup` already
/// knows this at scoring time (each metric's oriented z-score directly feeds
/// `finalScore`), but only the combined `score`/`isOutlier` survive onto
/// `FrameScore`. This type re-derives the per-metric view -- option (a) from
/// the R11-T7 ticket, chosen over persisting z-scores as new DB columns
/// because the raw data needed (`FrameScore.metrics`/`background`/`exptime`/
/// `path`) is already sitting in memory by the time a user opens the
/// "Kiugró" popover or the CLI re-serializes `rate --json`: no new schema,
/// no re-run of `Rater.rate`, no extra DB round-trip.
public struct OutlierBreakdown: Codable, Sendable, Equatable {
    /// `Hashable` (on top of `Codable`/`CaseIterable`) so SwiftUI's
    /// `ForEach(breakdown.entries, id: \.metric)` (the ⚠️ popover,
    /// `QualitySegment.swift`) can key its rows by this enum directly.
    public enum Metric: String, Codable, Sendable, CaseIterable, Hashable {
        case fwhm, roundness, starCount, background

        public var displayName: String {
            switch self {
            case .fwhm: return "FWHM"
            case .roundness: return "Kerekség"
            case .starCount: return "Csillagszám"
            case .background: return "Háttér"
            }
        }
    }

    /// One metric's contribution to this frame's score. `zScore` is
    /// ORIENTED the same way `Rater.scoreGroup` orients it before
    /// weighting -- negative always means "this metric is dragging the
    /// frame's score down", regardless of whether the raw metric's own
    /// direction is higher-is-better (roundness, starCount) or
    /// lower-is-better (fwhm, background). `value`/`groupMedian` are the RAW
    /// (un-oriented) metric values, e.g. "FWHM 4.2 px -- session-medián 2.9
    /// px".
    public struct MetricEntry: Codable, Sendable, Equatable {
        public var metric: Metric
        public var value: Double
        public var groupMedian: Double
        public var zScore: Double

        public init(metric: Metric, value: Double, groupMedian: Double, zScore: Double) {
            self.metric = metric
            self.value = value
            self.groupMedian = groupMedian
            self.zScore = zScore
        }
    }

    public var entries: [MetricEntry]

    public init(entries: [MetricEntry]) {
        self.entries = entries
    }

    /// The metric contributing the MOST negative (worst) oriented z-score
    /// -- `nil` only when `entries` is empty (a frame with no metric value
    /// at all, e.g. neither Siril metrics nor readable native stats).
    public var dominantMetric: Metric? {
        entries.min(by: { $0.zScore < $1.zScore })?.metric
    }

    /// A short, hedged guess at what kind of problem the dominant metric
    /// usually points to -- the popover's closing sentence (F4 spec):
    /// FWHM-dominant points at focus/wind/cloud, roundness at guiding/wind,
    /// starCount/background (both symptoms of something dimming or
    /// obscuring the sky) at cloud/haze.
    public var likelyCauseText: String? {
        guard let dominantMetric else { return nil }
        switch dominantMetric {
        case .fwhm:
            return "valószínű ok: fókuszcsúszás, szél vagy felhő"
        case .roundness:
            return "valószínű ok: vezetési hiba vagy szél"
        case .starCount, .background:
            return "valószínű ok: felhő vagy párásodás"
        }
    }

    // MARK: - Computing breakdowns for a batch of already-scored frames

    /// Groups `frames` the exact same way `Rater.score` does (session date
    /// crossed with nominal exptime, parsed from each frame's own `path` --
    /// see `sessionDate(ofPath:)`), then builds one `OutlierBreakdown` per
    /// frame from that group's own mean/std/median per metric. Frames with
    /// no parseable session date (shouldn't happen for a real
    /// `sessions/<target>/<date>/...` path, but the same defensive
    /// "however many components there are" stance `Rater.sessionSubdir`
    /// already takes) fall into one shared `nil`-date group rather than
    /// being dropped.
    public static func breakdowns(for frames: [FrameScore]) -> [String: OutlierBreakdown] {
        var groups: [RatingGroupMath.GroupKey: [FrameScore]] = [:]
        for frame in frames {
            let key = RatingGroupMath.groupKey(sessionDate: sessionDate(ofPath: frame.path), exptime: frame.exptime)
            groups[key, default: []].append(frame)
        }

        var results: [String: OutlierBreakdown] = [:]
        for groupFrames in groups.values {
            let fwhmStats = RatingGroupMath.metricStats(groupFrames.compactMap { $0.metrics?.fwhm })
            let roundnessStats = RatingGroupMath.metricStats(groupFrames.compactMap { $0.metrics?.roundness })
            let starCountStats = RatingGroupMath.metricStats(groupFrames.compactMap { ($0.metrics?.starCount).map(Double.init) })
            let backgroundStats = RatingGroupMath.metricStats(groupFrames.compactMap(\.background))

            for frame in groupFrames {
                var entries: [MetricEntry] = []
                if let fwhm = frame.metrics?.fwhm {
                    entries.append(MetricEntry(
                        metric: .fwhm, value: fwhm, groupMedian: fwhmStats.median,
                        zScore: -RatingGroupMath.zScore(fwhm, stats: fwhmStats) // lower fwhm is better
                    ))
                }
                if let roundness = frame.metrics?.roundness {
                    entries.append(MetricEntry(
                        metric: .roundness, value: roundness, groupMedian: roundnessStats.median,
                        zScore: RatingGroupMath.zScore(roundness, stats: roundnessStats) // higher is better
                    ))
                }
                if let starCount = frame.metrics?.starCount {
                    entries.append(MetricEntry(
                        metric: .starCount, value: Double(starCount), groupMedian: starCountStats.median,
                        zScore: RatingGroupMath.zScore(Double(starCount), stats: starCountStats) // higher is better
                    ))
                }
                if let background = frame.background {
                    entries.append(MetricEntry(
                        metric: .background, value: background, groupMedian: backgroundStats.median,
                        zScore: -RatingGroupMath.zScore(background, stats: backgroundStats) // lower is better
                    ))
                }
                results[frame.path] = OutlierBreakdown(entries: entries)
            }
        }
        return results
    }

    /// The `<date>` component of a `sessions/<target>/<date>/…` path -- the
    /// same positional convention `Rater.sessionSubdir(path:)` reads ITS OWN
    /// result from, one component earlier (mirrors `QualitySegment`'s
    /// private `sessionDate(ofPath:)` in the app layer, which needs the
    /// identical parse for its own date-filter but can't reach into this
    /// package-internal helper from outside the module).
    static func sessionDate(ofPath path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2 else { return nil }
        return String(components[2])
    }
}
