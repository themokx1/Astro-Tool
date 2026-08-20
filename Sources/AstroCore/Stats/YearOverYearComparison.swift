import Foundation

/// Ideation #3 ("Ez a hónap tavalyhoz képest" -- "This month compared to
/// last year"): a small, always-fresh companion to `YearWrapped`'s
/// once-a-year "your story so far" card. Where `YearWrapped` looks back over
/// a whole (usually finished) year, this looks at the CURRENT calendar
/// month's sessions this year against the exact same calendar month last
/// year -- useful every single time you open Insights, not just in
/// December.
///
/// Deliberately reuses `TrendAnalytics.summarize` for every total it needs
/// (integration seconds, session count) rather than re-summing
/// `[TrendPoint]` a second time -- the exact "never re-sum" rule
/// `YearWrapped.swift`'s own doc comment calls out. The only genuinely NEW
/// math here is (1) slicing `points` down to this month/this year and the
/// same month/last year, and (2) picking each side's own single best-FWHM
/// point (a per-point `min`, not an aggregate `TrendAnalytics` already has a
/// slot for) -- the exact same "new math" shape `YearWrapped.bestFWHMNight`
/// already establishes for its own best-of-the-year pick.
public struct YearOverYearComparison: Sendable, Equatable {
    /// 1...12, the calendar month being compared (from `today` at
    /// `summarize` call time).
    public var month: Int
    public var thisYear: Int
    /// Always `thisYear - 1` -- kept as its own stored field (rather than a
    /// computed one) so a fixture can assert it directly without doing the
    /// subtraction itself.
    public var lastYear: Int
    public var thisYearIntegrationSeconds: Double
    public var lastYearIntegrationSeconds: Double
    public var thisYearSessionCount: Int
    public var lastYearSessionCount: Int
    /// `nil` unless BOTH months carry at least one measured FWHM session --
    /// see `bestFWHM(in:)`'s own doc comment for why a unit mismatch between
    /// the two sides also drops this to `nil` rather than comparing arcsec
    /// against raw pixels.
    public var bestFWHM: FWHMComparison?

    /// This year's total minus last year's -- positive means MORE
    /// integration this month than the same month last year.
    public var integrationSecondsDelta: Double { thisYearIntegrationSeconds - lastYearIntegrationSeconds }
    /// This year's count minus last year's -- positive means MORE sessions
    /// this month than the same month last year.
    public var sessionCountDelta: Int { thisYearSessionCount - lastYearSessionCount }

    public init(
        month: Int,
        thisYear: Int,
        lastYear: Int,
        thisYearIntegrationSeconds: Double,
        lastYearIntegrationSeconds: Double,
        thisYearSessionCount: Int,
        lastYearSessionCount: Int,
        bestFWHM: FWHMComparison?
    ) {
        self.month = month
        self.thisYear = thisYear
        self.lastYear = lastYear
        self.thisYearIntegrationSeconds = thisYearIntegrationSeconds
        self.lastYearIntegrationSeconds = lastYearIntegrationSeconds
        self.thisYearSessionCount = thisYearSessionCount
        self.lastYearSessionCount = lastYearSessionCount
        self.bestFWHM = bestFWHM
    }

    /// One measured FWHM value on each side of the comparison --
    /// `TrendPoint.fwhmValue`'s own "arcsec when derivable, else raw pixels"
    /// unit convention, copied verbatim (never recomputed) so this card's
    /// numbers always agree with what the Insights quality-trend chart
    /// would have plotted for the same points.
    public struct FWHMComparison: Sendable, Equatable {
        public var thisYearValue: Double
        public var lastYearValue: Double
        /// Whether BOTH sides are the px-fallback unit (never a mix -- see
        /// `bestFWHM(in:)`'s own doc comment for why a mismatched pair never
        /// reaches this type at all).
        public var isPixelFallback: Bool
        /// This year's value minus last year's -- for FWHM, lower is
        /// better, so a NEGATIVE delta means an improvement. Left as a raw
        /// signed number (never pre-labeled "better"/"worse") so the UI
        /// decides its own honest phrasing, same posture
        /// `integrationSecondsDelta`/`sessionCountDelta` already take above.
        public var delta: Double { thisYearValue - lastYearValue }

        public init(thisYearValue: Double, lastYearValue: Double, isPixelFallback: Bool) {
            self.thisYearValue = thisYearValue
            self.lastYearValue = lastYearValue
            self.isPixelFallback = isPixelFallback
        }
    }

    /// Builds the comparison from `points` -- expected to span every year on
    /// record (not pre-filtered), since both this month and the same month
    /// last year need to be sliced out of it. `today`/`calendar` default to
    /// the real wall clock in production and are overridden by tests for
    /// determinism, same `today: Date = Date()` convention
    /// `AnniversaryQuery.anniversaries(projects:today:calendar:)`
    /// (`AstroApplication`) already establishes for "what does the
    /// calendar say right now" pure functions.
    ///
    /// Returns `nil` only when the same calendar month LAST year holds no
    /// session at all -- there is nothing to compare against yet (a fresh
    /// library's very first August, say). This year's own side is allowed
    /// to be empty (e.g. the month just started and nothing has been shot
    /// yet) without suppressing the card: "0 h so far vs 4.2 h last August"
    /// is still an honest, useful comparison, not a wall of zeroes.
    public static func summarize(
        points: [TrendPoint],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> YearOverYearComparison? {
        let components = calendar.dateComponents([.year, .month], from: today)
        guard let thisYear = components.year, let month = components.month else { return nil }
        let lastYear = thisYear - 1

        let thisPrefix = String(format: "%04d-%02d-", thisYear, month)
        let lastPrefix = String(format: "%04d-%02d-", lastYear, month)
        let thisPoints = points.filter { ($0.sessionStartDate ?? $0.date).hasPrefix(thisPrefix) }
        let lastPoints = points.filter { ($0.sessionStartDate ?? $0.date).hasPrefix(lastPrefix) }
        guard !lastPoints.isEmpty else { return nil }

        let thisSummary = TrendAnalytics.summarize(thisPoints)
        let lastSummary = TrendAnalytics.summarize(lastPoints)

        return YearOverYearComparison(
            month: month,
            thisYear: thisYear,
            lastYear: lastYear,
            thisYearIntegrationSeconds: thisSummary.integrationSeconds,
            lastYearIntegrationSeconds: lastSummary.integrationSeconds,
            thisYearSessionCount: thisSummary.sessionCount,
            lastYearSessionCount: lastSummary.sessionCount,
            bestFWHM: bestFWHM(thisPoints: thisPoints, lastPoints: lastPoints)
        )
    }

    /// Each side's own single lowest (best) measured FWHM point, kept as a
    /// pair ONLY when both sides have one AND they agree on unit
    /// (`isPixelFallback` equal on both) -- subtracting an arcsec reading
    /// from a raw-pixel one would be a physically meaningless number
    /// dressed up as a delta, so a unit mismatch drops this row exactly
    /// like an outright-missing measurement does, rather than silently
    /// comparing across units.
    private static func bestFWHM(
        thisPoints: [TrendPoint],
        lastPoints: [TrendPoint]
    ) -> FWHMComparison? {
        guard
            let thisBest = thisPoints.compactMap(\.fwhmValue).min(by: { $0.value < $1.value }),
            let lastBest = lastPoints.compactMap(\.fwhmValue).min(by: { $0.value < $1.value }),
            thisBest.isPixelFallback == lastBest.isPixelFallback
        else { return nil }

        return FWHMComparison(
            thisYearValue: thisBest.value,
            lastYearValue: lastBest.value,
            isPixelFallback: thisBest.isPixelFallback
        )
    }
}
