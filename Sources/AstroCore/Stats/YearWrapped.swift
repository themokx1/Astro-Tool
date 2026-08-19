import Foundation

/// Expert ideation reserve #9 ("Év-összegző Wrapped", wow 5/5): one
/// emotional, screenshot-worthy year card built entirely from numbers this
/// owner's own library already produces -- total integration, nights out,
/// the most-shot target, the best measured FWHM night, the biggest month,
/// total usable light-frame count, and which targets got their first-ever
/// light this year. Zero invented scoring; every figure here is a real
/// aggregate somebody could reconstruct by hand from `TrendPoint`s.
///
/// Deliberately reuses `TrendAnalytics.summarize` for everything it already
/// computes (integration totals, session counts, per-target and per-month
/// roll-ups) rather than re-summing `[TrendPoint]` a second time -- the
/// "never re-sum" rule this file's own spec calls out. The only genuinely
/// NEW math here is (1) picking the single best-FWHM point (a per-point
/// `min`, not an aggregate `TrendAnalytics` already has a slot for) and (2)
/// "first light this year", which needs each target's globally earliest
/// session -- a question `TrendAnalytics.summarize` never asks because it
/// only ever sees one already-scoped slice of points at a time.
public struct YearWrapped: Sendable, Equatable {
    public var year: Int
    /// `TrendDashboardSummary.integrationSeconds`, scoped to this year.
    public var totalIntegrationSeconds: Double
    /// `TrendDashboardSummary.sessionCount` -- target x date session pairs,
    /// same "one night, two targets, counts twice" convention every other
    /// session count in this app already uses.
    public var sessionCount: Int
    public var distinctTargetCount: Int
    /// The year's highest-integration target, `nil` only when `sessionCount
    /// == 0` (which itself means `summarize` returns `nil` for the whole
    /// year -- see that function's own doc comment).
    public var mostShotTarget: TrendTargetSummary?
    /// The single lowest (best) measured FWHM session this year, `nil` when
    /// not one session in the year carries a measured FWHM at all -- sparse-
    /// data honesty rather than a fabricated "best" over nothing measured.
    public var bestFWHMNight: BestFWHMNight?
    /// The year's highest-integration calendar month, from `TrendAnalytics.
    /// summarize`'s own per-month roll-up -- never a second monthly sum.
    public var biggestMonth: TrendMonthSummary?
    public var totalUsableFrameCount: Int
    /// Targets whose globally-earliest session (across every year on
    /// record, not just this one) falls within this year -- "first light"
    /// in the plain sense, sorted for a stable display order. A target
    /// begun the year before and merely continued this year does not
    /// appear here, even if this year happens to hold most of its sessions.
    public var firstLights: [String]

    public init(
        year: Int,
        totalIntegrationSeconds: Double,
        sessionCount: Int,
        distinctTargetCount: Int,
        mostShotTarget: TrendTargetSummary?,
        bestFWHMNight: BestFWHMNight?,
        biggestMonth: TrendMonthSummary?,
        totalUsableFrameCount: Int,
        firstLights: [String]
    ) {
        self.year = year
        self.totalIntegrationSeconds = totalIntegrationSeconds
        self.sessionCount = sessionCount
        self.distinctTargetCount = distinctTargetCount
        self.mostShotTarget = mostShotTarget
        self.bestFWHMNight = bestFWHMNight
        self.biggestMonth = biggestMonth
        self.totalUsableFrameCount = totalUsableFrameCount
        self.firstLights = firstLights
    }

    /// One session's measured FWHM, the night and target it belongs to --
    /// `TrendPoint.fwhmValue`'s own "arcsec when derivable, else raw pixels"
    /// unit convention, copied verbatim (never recomputed) so this card's
    /// number always agrees with what the Insights quality-trend chart would
    /// have plotted for the same point.
    public struct BestFWHMNight: Sendable, Equatable {
        public var target: String
        public var date: String
        public var value: Double
        public var isPixelFallback: Bool

        public init(target: String, date: String, value: Double, isPixelFallback: Bool) {
            self.target = target
            self.date = date
            self.value = value
            self.isPixelFallback = isPixelFallback
        }
    }

    /// Builds the year card from `points` -- expected to span every year on
    /// record (not pre-filtered to `year`), since `firstLights` needs each
    /// target's globally-earliest session to tell "first light this year"
    /// apart from "merely continued this year". Returns `nil` when the year
    /// holds no session at all: an empty year has no story to tell, and the
    /// UI drops the whole card rather than rendering a wall of honest
    /// zeroes.
    public static func summarize(points: [TrendPoint], year: Int) -> YearWrapped? {
        let prefix = "\(year)-"
        let yearPoints = points.filter { ($0.sessionStartDate ?? $0.date).hasPrefix(prefix) }
        guard !yearPoints.isEmpty else { return nil }

        let summary = TrendAnalytics.summarize(yearPoints)

        let bestFWHM = yearPoints
            .compactMap { point -> BestFWHMNight? in
                guard let fwhm = point.fwhmValue else { return nil }
                return BestFWHMNight(
                    target: point.target,
                    date: point.sessionStartDate ?? point.date,
                    value: fwhm.value,
                    isPixelFallback: fwhm.isPixelFallback
                )
            }
            .min { $0.value < $1.value }

        let biggestMonth = summary.months.max { $0.integrationSeconds < $1.integrationSeconds }

        // Every target's globally-earliest session date, over the FULL
        // (un-scoped) `points` -- not `yearPoints` -- so a target that
        // started the year before this one correctly fails the `hasPrefix`
        // check below even though it also has sessions inside this year.
        let earliestDateByTarget = Dictionary(grouping: points, by: \.target)
            .compactMapValues { targetPoints in
                targetPoints.map { $0.sessionStartDate ?? $0.date }.min()
            }
        let firstLights = earliestDateByTarget
            .filter { $0.value.hasPrefix(prefix) }
            .map(\.key)
            .sorted()

        return YearWrapped(
            year: year,
            totalIntegrationSeconds: summary.integrationSeconds,
            sessionCount: summary.sessionCount,
            distinctTargetCount: summary.targets.count,
            mostShotTarget: summary.targets.first,
            bestFWHMNight: bestFWHM,
            biggestMonth: biggestMonth,
            totalUsableFrameCount: summary.usableFrameCount,
            firstLights: firstLights
        )
    }
}
