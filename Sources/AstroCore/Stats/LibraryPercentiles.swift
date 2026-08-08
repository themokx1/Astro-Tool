import Foundation

/// Which third of the library's own distribution one value falls into --
/// backs the `NightsPage`/`SessionsSegment` FWHM″/Hatékonyság percentile
/// color dots (R11-T12/F11(e)). Always measured against THIS library's own
/// session values -- there is no absolute/external "good FWHM" scale, since
/// that depends entirely on the setup, sky, and seeing this library was shot
/// under.
public enum PercentileBand: String, Sendable, Equatable {
    case best
    case middle
    case worst
}

/// One value's standing within its library-wide distribution -- `band`
/// drives the color dot, `betterThanFraction`/`medianValue` back the
/// tooltip sentence ("A könyvtárad mediánja 3,1″ — ez a session a jobbik
/// 25%-ban").
public struct LibraryPercentileResult: Sendable, Equatable {
    public var band: PercentileBand
    /// Direction-aware midrank fraction (0...1) describing how much of the
    /// distribution lies behind this value. Ties share the average of their
    /// occupied positions, so they cannot land in different bands.
    public var betterThanFraction: Double
    /// The distribution's own median (same unit as the evaluated value) --
    /// e.g. "a könyvtárad mediánja 3,1″" reads this straight off.
    public var medianValue: Double
    /// Best-to-worst midrank on a 0...100 scale. Equal values always share
    /// the same value, even when a tie crosses a third boundary.
    public var percentile: Int
    public var sampleCount: Int
    public var isLowSample: Bool

    public init(
        band: PercentileBand, betterThanFraction: Double, medianValue: Double,
        percentile: Int, sampleCount: Int, isLowSample: Bool
    ) {
        self.band = band
        self.betterThanFraction = betterThanFraction
        self.medianValue = medianValue
        self.percentile = percentile
        self.sampleCount = sampleCount
        self.isLowSample = isLowSample
    }
}

/// Percentile-band computation for the library's OWN metric distributions
/// (R11-T12/F11(e)) -- a pure function, no `Database` access: callers
/// (`NightsPage`, `SessionsSegment`) already have the values in hand
/// (`NightRow.medianFWHMArcsec`/`dutyCyclePercent`) and just need them
/// ranked against each other. Recomputed fresh every call (no persisted
/// baseline that could go stale as new sessions arrive).
public enum LibraryPercentiles {
    /// Below this many comparable values, callers suppress the band color
    /// and render a neutral low-sample marker instead -- painting a quality
    /// color off 2-3 sessions would be noise, not a real distribution.
    public static let minimumSampleSize = 6

    /// `allValues` is the library's FULL distribution for the metric in
    /// question -- already filtered by the caller to whatever's comparable
    /// (e.g. arcsec-only FWHM values, never mixed with a pixel-scale
    /// fallback; see `NightsPage.fwhmPercentile`'s own call site). `value`
    /// need not itself be a member, though in practice it always is (the
    /// caller's own row). `higherIsBetter` picks the metric's direction:
    /// `false` for FWHM (a smaller value is a sharper image), `true` for
    /// duty-cycle/"Hatékonyság" (a bigger percentage is better). Returns
    /// `nil` only for an empty distribution. Smaller samples return a
    /// neutral, explicitly marked low-sample result instead of hiding why
    /// no confident color classification is available.
    public static func evaluate(value: Double, allValues: [Double], higherIsBetter: Bool) -> LibraryPercentileResult? {
        guard !allValues.isEmpty else { return nil }

        let median = medianOf(allValues.sorted())
        let bestFirst = allValues.sorted { higherIsBetter ? $0 > $1 : $0 < $1 }
        let equalIndices = bestFirst.indices.filter { bestFirst[$0] == value }
        let insertion = bestFirst.firstIndex { higherIsBetter ? $0 < value : $0 > value } ?? bestFirst.count
        let midrank: Double
        if let first = equalIndices.first, let last = equalIndices.last {
            midrank = Double(first + last) / 2
        } else {
            midrank = Double(insertion)
        }
        let denominator = max(1, bestFirst.count - 1)
        let percentile = Int((midrank / Double(denominator) * 100).rounded())
        let maxRank = Double(max(0, bestFirst.count - 1))
        let clampedRank = min(midrank, maxRank)
        let betterThanFraction = (maxRank - clampedRank) / Double(bestFirst.count)

        let band: PercentileBand
        if betterThanFraction >= 2.0 / 3.0 {
            band = .best
        } else if betterThanFraction >= 1.0 / 3.0 {
            band = .middle
        } else {
            band = .worst
        }

        return LibraryPercentileResult(
            band: band,
            betterThanFraction: betterThanFraction,
            medianValue: median,
            percentile: percentile,
            sampleCount: allValues.count,
            isLowSample: allValues.count < minimumSampleSize
        )
    }

    private static func medianOf(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// R11-T17: the library's FULL `medianFWHMArcsec` distribution, computed
    /// as cheaply as possible -- for a caller (`AppState.loadTargetDetail`)
    /// that wants THIS type's own input for a target-detail page, before the
    /// user has ever visited "Éjszakák" (`AppState.nights`, which
    /// `NightsPage.loadNights()` alone populates -- see that property's own
    /// doc comment). `NightsQueries.allNights` -- the query that DOES fill
    /// `nights` -- ALSO computes `SessionTimeline`, `FilterBreakdownQueries
    /// .breakdown`, tags/`displayName`, and (once multi-site is configured)
    /// per-session site resolution for every single session it touches, none
    /// of which this dot needs; this walks only `SessionQuality.summaries`
    /// per target (itself one of `allNights`' own two heaviest steps, so
    /// this is a strict, real subset of that work, not a duplicate of all of
    /// it) and keeps just the one field this whole type ever asks of a
    /// session's data. Read-only, never touches the filesystem, no ordering
    /// guarantee (`evaluate` sorts its own copy).
    public static func libraryFWHMArcsecValues(db: Database, config: AstroConfig) throws -> [Double] {
        let targets = Set(try db.allSessionPairs().map(\.target))
        var values: [Double] = []
        for target in targets {
            let summaries = try SessionQuality.summaries(target: target, db: db, config: config)
            values.append(contentsOf: summaries.compactMap(\.medianFWHMArcsec))
        }
        return values
    }
}
