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
    /// Fraction (0...1) of `allValues` this value is STRICTLY better than,
    /// direction-aware (`higherIsBetter`) -- `1.0` means "better than every
    /// other session", `0.0` means "nobody else is worse".
    public var betterThanFraction: Double
    /// The distribution's own median (same unit as the evaluated value) --
    /// e.g. "a könyvtárad mediánja 3,1″" reads this straight off.
    public var medianValue: Double

    public init(band: PercentileBand, betterThanFraction: Double, medianValue: Double) {
        self.band = band
        self.betterThanFraction = betterThanFraction
        self.medianValue = medianValue
    }
}

/// Percentile-band computation for the library's OWN metric distributions
/// (R11-T12/F11(e)) -- a pure function, no `Database` access: callers
/// (`NightsPage`, `SessionsSegment`) already have the values in hand
/// (`NightRow.medianFWHMArcsec`/`dutyCyclePercent`) and just need them
/// ranked against each other. Recomputed fresh every call (no persisted
/// baseline that could go stale as new sessions arrive).
public enum LibraryPercentiles {
    /// Below this many comparable values, no band is computed at all --
    /// painting a color off 2-3 sessions would be noise, not a real
    /// distribution (spec: "kevés adatnál (<6 session) NINCS színezés").
    public static let minimumSampleSize = 6

    /// `allValues` is the library's FULL distribution for the metric in
    /// question -- already filtered by the caller to whatever's comparable
    /// (e.g. arcsec-only FWHM values, never mixed with a pixel-scale
    /// fallback; see `NightsPage.fwhmPercentile`'s own call site). `value`
    /// need not itself be a member, though in practice it always is (the
    /// caller's own row). `higherIsBetter` picks the metric's direction:
    /// `false` for FWHM (a smaller value is a sharper image), `true` for
    /// duty-cycle/"Hatékonyság" (a bigger percentage is better). Returns
    /// `nil` below `minimumSampleSize`.
    public static func evaluate(value: Double, allValues: [Double], higherIsBetter: Bool) -> LibraryPercentileResult? {
        guard allValues.count >= minimumSampleSize else { return nil }

        let median = medianOf(allValues.sorted())
        let betterCount = allValues.count { higherIsBetter ? $0 < value : $0 > value }
        let betterThanFraction = Double(betterCount) / Double(allValues.count)

        let band: PercentileBand
        if betterThanFraction >= 2.0 / 3.0 {
            band = .best
        } else if betterThanFraction >= 1.0 / 3.0 {
            band = .middle
        } else {
            band = .worst
        }

        return LibraryPercentileResult(band: band, betterThanFraction: betterThanFraction, medianValue: median)
    }

    private static func medianOf(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
