import AstroCore
import Foundation

/// One dated sample of a target's usable-night hours -- the season curve's
/// raw material. "Usable" here means darkness ∩ altitude (the exact
/// `DiscoveryRow.visibleHours` shape `DiscoveryPlanner.discover` already
/// computes for the Planning table's own "h visible" column) -- the Moon is
/// deliberately NOT folded in: it cycles roughly monthly, so weighting it
/// into a YEAR-shaped curve would just paint moon-phase noise on top of the
/// real seasonal signal, not sharpen it. `PlanningQuery`'s own per-night
/// integration/scoring estimates are the place Moon interference belongs;
/// this is a "when is the window open at all" curve, evaluated at
/// `minAltitudeDeg` and deliberately Moon-blind.
public struct SeasonWindowSample: Equatable, Sendable {
    public let date: Date
    public let visibleHours: Double

    public init(date: Date, visibleHours: Double) {
        self.date = date
        self.visibleHours = visibleHours
    }
}

/// One usable-season date range within the sampled year. `startDate` marks
/// the day the target first clears `SeasonWindowResult
/// .minVisibleHoursThreshold` coming out of the off-season trough;
/// `endDate` marks the last day it still does before falling back below it.
///
/// A season that straddles the calendar year boundary (e.g. "opens in
/// September, closes the following February") is represented as ONE range
/// whose `startDate` can sit LATER, in absolute `Date` terms, than its
/// `endDate` -- both are real sampled instants, just from the two ends of a
/// cyclical pattern flattened into a single linear array (`SeasonWindowQuery
/// .evaluate`'s own doc explains why). Callers should read only the
/// month/day of each -- `contains(_:calendar:)` already does exactly that,
/// circularly -- and never assume `startDate < endDate`.
public struct SeasonWindowRange: Equatable, Sendable {
    public let startDate: Date
    public let endDate: Date

    public init(startDate: Date, endDate: Date) {
        self.startDate = startDate
        self.endDate = endDate
    }

    /// Whether `date`'s month/day falls inside this range, ignoring year --
    /// handles the year-wraparound case documented above by comparing
    /// day-of-year ordinals circularly instead of comparing `Date`s
    /// directly.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        func ordinal(_ value: Date) -> Int { calendar.ordinality(of: .day, in: .year, for: value) ?? 0 }
        let start = ordinal(startDate), end = ordinal(endDate), target = ordinal(date)
        if start <= end {
            return target >= start && target <= end
        }
        return target >= start || target <= end
    }
}

/// A selected catalog target's YEAR-shaped visibility at one site -- when its
/// usable window opens, peaks, and closes -- so campaigns can be planned
/// ahead of time, not just tonight (the Season Window Finder pitch: "mikor
/// van az M31-szezon nálam"). See the type-level docs on
/// `SeasonWindowSample`/`SeasonWindowRange` for the Moon-blind and
/// wraparound conventions this carries.
public struct SeasonWindowResult: Equatable, Sendable {
    public let target: CatalogTarget
    public let minVisibleHoursThreshold: Double
    /// Usable-season ranges within the sampled year. Empty whenever
    /// `isCircumpolarYearRound` or `hasNoUsableSeason` is `true` -- both
    /// already say everything a range list could add.
    public let ranges: [SeasonWindowRange]
    public let peakDate: Date?
    public let peakVisibleHours: Double?
    /// One representative sample for each of the 12 months starting at the
    /// query's `referenceDate` -- deliberately coarser than (and independent
    /// of) the range/peak detection above, which samples every 5 then every
    /// 1 day; this is only material for a small chart, never a source of
    /// truth for the range or peak numbers themselves.
    public let monthlySamples: [SeasonWindowSample]
    /// `true` when even the yearly trough clears the threshold -- the target
    /// never truly leaves its usable window (a high-declination object from
    /// this latitude).
    public let isCircumpolarYearRound: Bool
    /// `true` when even the yearly peak never clears the threshold -- too far
    /// south to ever usefully rise here, or (same code path, no special
    /// casing needed) a site far enough north that its own dark window never
    /// opens long enough, for this whole practical year, to matter (a
    /// "white nights" summer).
    public let hasNoUsableSeason: Bool

    public init(
        target: CatalogTarget,
        minVisibleHoursThreshold: Double,
        ranges: [SeasonWindowRange],
        peakDate: Date?,
        peakVisibleHours: Double?,
        monthlySamples: [SeasonWindowSample],
        isCircumpolarYearRound: Bool,
        hasNoUsableSeason: Bool
    ) {
        self.target = target
        self.minVisibleHoursThreshold = minVisibleHoursThreshold
        self.ranges = ranges
        self.peakDate = peakDate
        self.peakVisibleHours = peakVisibleHours
        self.monthlySamples = monthlySamples
        self.isCircumpolarYearRound = isCircumpolarYearRound
        self.hasNoUsableSeason = hasNoUsableSeason
    }
}

/// "When is my [target]'s season, here?" -- sweeps `DiscoveryPlanner.discover`
/// (the SAME per-night darkness∩altitude engine the Planning table and
/// `SkyPathQuery` already trust, called for exactly ONE target per sample;
/// `NightSweep` itself is internal to `AstroCore` and unreachable from this
/// module, same reason `SkyPathQuery` doesn't call it either) across roughly
/// the next year at `site`, then reduces that curve to open/peak/close dates.
///
/// Pure and DB-free, like `SkyPathQuery`: everything it needs is a
/// `CatalogTarget` and a `SiteRule`, both plain caller-supplied inputs. Never
/// call this for more than one target at a time from a view's `body` --
/// callers own the "computed on demand for the selected target only, off the
/// main actor, cached per (target, site) for the session" contract
/// (`PlanningStore`/`SavedTargetsStore`).
public enum SeasonWindowQuery {
    /// A season is "usable" once a night's darkness∩altitude window reaches
    /// this many hours -- short of a full imaging night, but already
    /// meaningful, the same bar `SkyScore.visibilityFactor` treats as
    /// non-trivial credit well below its own 4h "full credit" ceiling.
    public static let defaultMinVisibleHours: Double = 2.0

    /// ~5 days: resolves the year's shape (a season boundary can only be
    /// found to within one stride) cheaply. Both the boundaries and the peak
    /// are refined to daily resolution afterward (the `refine...` helpers
    /// below), so this coarse stride never dictates the final reported
    /// dates -- only how many extra days of daily refinement each one costs.
    static let sampleStepDays = 5
    /// 73 x 5 = 365 -- one full annual cycle.
    static let sampleCount = 73

    /// Sweeps `target`'s season at `site`. `nil` when the site itself doesn't
    /// resolve (no lat/lon) -- same "no site, nothing invented" honesty
    /// `SkyPathQuery.samples` already documents for its own `nil` case.
    ///
    /// Two coarse passes, not one: the first locates the year's deepest
    /// off-season trough; the second re-anchors right after it and does the
    /// real run detection. Anchoring there guarantees no usable run can ever
    /// straddle the sampled array's own start/end boundary -- the
    /// alternative (sampling cold from `referenceDate`, whatever phase of
    /// the season that happens to catch) would need circular run-merging
    /// AND produce a range whose `startDate` sits chronologically after its
    /// `endDate` for any season that happens to wrap the SAMPLING window's
    /// edge, on top of the calendar year's own wraparound `SeasonWindowRange`
    /// already has to represent. One wraparound convention is enough to
    /// document and test, not two.
    public static func evaluate(
        target: CatalogTarget,
        site: SiteRule,
        minAltitudeDeg: Double = PlanningQuery.defaultMinAltitudeDeg,
        minVisibleHours: Double = defaultMinVisibleHours,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> SeasonWindowResult? {
        guard site.latitudeDeg != nil, site.longitudeDeg != nil else { return nil }

        let troughPass = sweepSamples(
            target: target, site: site, minAltitudeDeg: minAltitudeDeg, start: referenceDate, calendar: calendar
        )
        guard !troughPass.isEmpty, let trough = troughPass.min(by: { $0.visibleHours < $1.visibleHours }) else { return nil }
        let overallPeakHours = troughPass.map(\.visibleHours).max() ?? 0

        let monthly = monthlySamples(
            target: target, site: site, minAltitudeDeg: minAltitudeDeg, referenceDate: referenceDate, calendar: calendar
        )

        // Even the deepest trough clears the bar -- this target never
        // leaves its usable window from this site (a high-declination
        // object, effectively circumpolar at this altitude threshold).
        if trough.visibleHours >= minVisibleHours {
            let coarsePeak = troughPass.max(by: { $0.visibleHours < $1.visibleHours })
            let peak = coarsePeak.map {
                refinePeak(target: target, site: site, minAltitudeDeg: minAltitudeDeg, around: $0.date, calendar: calendar)
            }
            return SeasonWindowResult(
                target: target, minVisibleHoursThreshold: minVisibleHours,
                ranges: [], peakDate: peak?.date, peakVisibleHours: peak?.visibleHours,
                monthlySamples: monthly, isCircumpolarYearRound: true, hasNoUsableSeason: false
            )
        }

        // Even the yearly peak never clears the bar -- too far south to
        // usefully rise here (or the dark window itself never opens long
        // enough), for this whole practical year.
        if overallPeakHours < minVisibleHours {
            return SeasonWindowResult(
                target: target, minVisibleHoursThreshold: minVisibleHours,
                ranges: [], peakDate: nil, peakVisibleHours: nil,
                monthlySamples: monthly, isCircumpolarYearRound: false, hasNoUsableSeason: true
            )
        }

        // Real detection pass, anchored right after the trough (see this
        // function's own doc for why).
        let anchor = calendar.date(byAdding: .day, value: 1, to: trough.date) ?? trough.date
        let samples = sweepSamples(target: target, site: site, minAltitudeDeg: minAltitudeDeg, start: anchor, calendar: calendar)
        guard !samples.isEmpty else { return nil }

        var rawRuns: [(start: Int, end: Int)] = []
        var runStart: Int?
        for (index, sample) in samples.enumerated() {
            let usable = sample.visibleHours >= minVisibleHours
            if usable, runStart == nil { runStart = index }
            if !usable, let start = runStart {
                rawRuns.append((start, index - 1))
                runStart = nil
            }
        }
        if let start = runStart { rawRuns.append((start, samples.count - 1)) }

        let ranges: [SeasonWindowRange] = rawRuns.map { run in
            let openBefore = run.start > 0
                ? samples[run.start - 1].date
                : calendar.date(byAdding: .day, value: -sampleStepDays, to: samples[run.start].date) ?? samples[run.start].date
            let openStart = refineOpening(
                target: target, site: site, minAltitudeDeg: minAltitudeDeg, minVisibleHours: minVisibleHours,
                notUsableDate: openBefore, usableDate: samples[run.start].date, calendar: calendar
            )
            let closeAfter = run.end < samples.count - 1
                ? samples[run.end + 1].date
                : calendar.date(byAdding: .day, value: sampleStepDays, to: samples[run.end].date) ?? samples[run.end].date
            let closeEnd = refineClosing(
                target: target, site: site, minAltitudeDeg: minAltitudeDeg, minVisibleHours: minVisibleHours,
                usableDate: samples[run.end].date, notUsableDate: closeAfter, calendar: calendar
            )
            return SeasonWindowRange(startDate: openStart, endDate: closeEnd)
        }

        let peak = samples.max(by: { $0.visibleHours < $1.visibleHours }).map {
            refinePeak(target: target, site: site, minAltitudeDeg: minAltitudeDeg, around: $0.date, calendar: calendar)
        }

        return SeasonWindowResult(
            target: target, minVisibleHoursThreshold: minVisibleHours,
            ranges: ranges, peakDate: peak?.date, peakVisibleHours: peak?.visibleHours,
            monthlySamples: monthly, isCircumpolarYearRound: false, hasNoUsableSeason: false
        )
    }

    // MARK: - Sampling

    private static func visibleHours(target: CatalogTarget, site: SiteRule, date: Date, minAltitudeDeg: Double) -> Double {
        DiscoveryPlanner.discover(date: date, site: site, minAltitudeDeg: minAltitudeDeg, targets: [target]).first?.visibleHours ?? 0
    }

    private static func sweepSamples(
        target: CatalogTarget, site: SiteRule, minAltitudeDeg: Double, start: Date, calendar: Calendar
    ) -> [SeasonWindowSample] {
        (0..<sampleCount).compactMap { step in
            guard let date = calendar.date(byAdding: .day, value: step * sampleStepDays, to: start) else { return nil }
            return SeasonWindowSample(
                date: date, visibleHours: visibleHours(target: target, site: site, date: date, minAltitudeDeg: minAltitudeDeg)
            )
        }
    }

    /// One representative sample for each of the next 12 months from
    /// `referenceDate`, at the 15th of each -- for `SeasonWindowResult
    /// .monthlySamples`'s small chart only, deliberately independent of the
    /// two-pass trough/season detection above.
    private static func monthlySamples(
        target: CatalogTarget, site: SiteRule, minAltitudeDeg: Double, referenceDate: Date, calendar: Calendar
    ) -> [SeasonWindowSample] {
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: referenceDate)) else { return [] }
        return (0..<12).compactMap { offset -> SeasonWindowSample? in
            guard let monthStart = calendar.date(byAdding: .month, value: offset, to: startOfMonth) else { return nil }
            var comps = calendar.dateComponents([.year, .month], from: monthStart)
            comps.day = 15
            guard let midMonth = calendar.date(from: comps) else { return nil }
            return SeasonWindowSample(
                date: midMonth, visibleHours: visibleHours(target: target, site: site, date: midMonth, minAltitudeDeg: minAltitudeDeg)
            )
        }
    }

    // MARK: - Daily refinement

    /// Scans forward, day by day, from just after `notUsableDate` up to
    /// `usableDate`, and returns the FIRST day that clears the threshold --
    /// the season's real opening day, to within one calendar day, rather
    /// than the coarse pass's own `sampleStepDays`-wide uncertainty.
    private static func refineOpening(
        target: CatalogTarget, site: SiteRule, minAltitudeDeg: Double, minVisibleHours: Double,
        notUsableDate: Date, usableDate: Date, calendar: Calendar
    ) -> Date {
        var day = calendar.date(byAdding: .day, value: 1, to: notUsableDate) ?? usableDate
        while day < usableDate {
            if visibleHours(target: target, site: site, date: day, minAltitudeDeg: minAltitudeDeg) >= minVisibleHours {
                return day
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return usableDate
    }

    /// Scans forward, day by day, from `usableDate` toward `notUsableDate`,
    /// and returns the LAST day that still clears the threshold -- the
    /// season's real closing day.
    private static func refineClosing(
        target: CatalogTarget, site: SiteRule, minAltitudeDeg: Double, minVisibleHours: Double,
        usableDate: Date, notUsableDate: Date, calendar: Calendar
    ) -> Date {
        var lastUsable = usableDate
        var day = calendar.date(byAdding: .day, value: 1, to: usableDate) ?? notUsableDate
        while day < notUsableDate {
            guard visibleHours(target: target, site: site, date: day, minAltitudeDeg: minAltitudeDeg) >= minVisibleHours else { break }
            lastUsable = day
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return lastUsable
    }

    /// Scans daily within `sampleStepDays` either side of a coarse peak
    /// sample and returns the day/hours pair with the highest visible hours
    /// found -- refines the peak to daily resolution the same way the
    /// season boundaries are refined above.
    private static func refinePeak(
        target: CatalogTarget, site: SiteRule, minAltitudeDeg: Double, around coarseDate: Date, calendar: Calendar
    ) -> (date: Date, visibleHours: Double) {
        var best = (
            date: coarseDate,
            visibleHours: visibleHours(target: target, site: site, date: coarseDate, minAltitudeDeg: minAltitudeDeg)
        )
        guard let windowStart = calendar.date(byAdding: .day, value: -sampleStepDays, to: coarseDate) else { return best }
        var day = windowStart
        for _ in 0...(2 * sampleStepDays) {
            let hours = visibleHours(target: target, site: site, date: day, minAltitudeDeg: minAltitudeDeg)
            if hours > best.visibleHours { best = (day, hours) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return best
    }
}
