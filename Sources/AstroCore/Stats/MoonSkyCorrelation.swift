import Foundation

/// Correlates each session's own measured sky background
/// (`TrendPoint.backgroundEPerSecPerArcsec2`, `SessionQuality`'s bias-
/// corrected e-/s/arcsec2 figure) with the Moon's illumination fraction on
/// that session's date (`SunMoon.moonIlluminationPercent`) -- a personal
/// SQM history nobody but this owner's own rated sessions could ever give
/// him: "how much brighter does MY sky actually read near full Moon than
/// under a dark one." Pure over `[TrendPoint]` -- reads no `Database`,
/// touches no filesystem, and (deliberately) never converts to mag/arcsec2
/// itself; that conversion's zero-point assumption lives in
/// `MeasuredSkyQuery.magnitudePerArcsec2(fromEPerSecPerArcsec2:)`
/// (`AstroApplication`, which this Core-layer type cannot import), so a
/// caller in that layer applies it per bucket instead of it being copied
/// here.
public enum MoonSkyCorrelation {
    /// The four illumination bands sessions are grouped into -- half-open
    /// on the low end of each band except `veryDark`'s own (which starts at
    /// 0%), so every value in `0...100` falls in EXACTLY one band: `25.0`
    /// itself lands in `.dark`, `50.0` in `.bright`, `75.0` in `.veryBright`.
    public enum IlluminationBand: Int, Sendable, CaseIterable, Equatable, Comparable, Identifiable {
        /// <25% illuminated -- the darkest skies a session can be shot
        /// under, and the natural "best case" reference for the headline
        /// ratio.
        case veryDark
        /// 25...<50% illuminated.
        case dark
        /// 50...<75% illuminated.
        case bright
        /// >=75% illuminated -- near-full Moon, the natural "worst case"
        /// reference for the headline ratio.
        case veryBright

        public var id: Int { rawValue }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The band `percent` (expected `0...100`, but never crashes on an
        /// out-of-range input -- anything below 0 still reads as
        /// `.veryDark`, anything at/above 75 as `.veryBright`) falls into.
        public static func containing(_ percent: Double) -> Self {
            switch percent {
            case ..<25: return .veryDark
            case ..<50: return .dark
            case ..<75: return .bright
            default: return .veryBright
            }
        }
    }

    /// One illumination band's aggregate over the measured sessions that
    /// fell into it.
    public struct Bucket: Sendable, Equatable, Identifiable {
        public var band: IlluminationBand
        public var sampleCount: Int
        /// Median `TrendPoint.backgroundEPerSecPerArcsec2` over this band's
        /// sessions -- `nil` only when `sampleCount == 0`. Computed
        /// regardless of `isLowConfidence`: Core stays honest about what it
        /// measured, and it is the CALLER's job (the "never a solid number
        /// on kevés adat" UI rule) to withhold a low-confidence figure from
        /// display, not Core's job to withhold the figure from existing.
        public var medianBackgroundEPerSecPerArcsec2: Double?
        /// `true` when `sampleCount < MoonSkyCorrelation.minimumSampleCount`
        /// -- too few measured sessions for the median above to be a stable
        /// figure.
        public var isLowConfidence: Bool
        public var id: Int { band.rawValue }

        public init(
            band: IlluminationBand,
            sampleCount: Int,
            medianBackgroundEPerSecPerArcsec2: Double?,
            isLowConfidence: Bool
        ) {
            self.band = band
            self.sampleCount = sampleCount
            self.medianBackgroundEPerSecPerArcsec2 = medianBackgroundEPerSecPerArcsec2
            self.isLowConfidence = isLowConfidence
        }
    }

    /// One bucket per `IlluminationBand` (always four, in band order) plus
    /// the headline "brightest measured sky vs. darkest measured sky"
    /// ratio.
    public struct Result: Sendable, Equatable {
        public var buckets: [Bucket]
        /// `.veryBright`'s median background divided by `.veryDark`'s --
        /// "your sky reads about N times brighter near full Moon than under
        /// a dark one." `nil` unless BOTH extreme bands individually clear
        /// `minimumSampleCount` -- a lopsided sample (one dark night against
        /// twenty bright ones, or the reverse) must never manufacture a
        /// ratio that looks as trustworthy as a balanced one.
        public var headlineRatio: Double?
        /// Count of bands with at least `minimumSampleCount` measured
        /// sessions -- callers collapse the whole section to an honest
        /// empty-state hint when this is below 2 (fewer than two bands ever
        /// reach a trustworthy count, so there's nothing meaningful left to
        /// compare).
        public var usableBucketCount: Int

        public init(buckets: [Bucket], headlineRatio: Double?, usableBucketCount: Int) {
            self.buckets = buckets
            self.headlineRatio = headlineRatio
            self.usableBucketCount = usableBucketCount
        }
    }

    /// Below this many measured sessions in a band, its median is not
    /// stable enough to present as a real number -- the same conservatism
    /// `MeasuredSkyQuery.minimumSessionCount` (`AstroApplication`) already
    /// applies to its own single-figure-from-many-sessions reading. Kept as
    /// an independent constant (this Core-layer type cannot import that
    /// one) but intentionally set to the identical value.
    public static let minimumSampleCount = 3

    /// Buckets every `points` entry that carries BOTH a usable measured
    /// background AND a parseable `sessionStartDate` by the Moon's
    /// illumination fraction at that date's local noon (UTC). A point
    /// missing either contributes nothing: an un-rated session has no
    /// background to bucket, and a date-dir that never parsed as a real
    /// calendar date (`TrendPoint.sessionStartDate == nil`) has no date to
    /// look the Moon up for -- same "excluded from date-keyed math"
    /// convention `TrendQueries.matchesRange` already applies to that case.
    public static func buckets(points: [TrendPoint]) -> Result {
        var backgroundsByBand: [IlluminationBand: [Double]] = [:]
        for point in points {
            guard let background = point.backgroundEPerSecPerArcsec2,
                  background.isFinite, background > 0,
                  let illumination = illuminationPercent(for: point)
            else { continue }
            let band = IlluminationBand.containing(illumination)
            backgroundsByBand[band, default: []].append(background)
        }

        let buckets = IlluminationBand.allCases.map { band -> Bucket in
            let values = backgroundsByBand[band] ?? []
            return Bucket(
                band: band,
                sampleCount: values.count,
                medianBackgroundEPerSecPerArcsec2: median(values),
                isLowConfidence: values.count < minimumSampleCount
            )
        }

        let byBand = Dictionary(uniqueKeysWithValues: buckets.map { ($0.band, $0) })
        var headlineRatio: Double?
        if let veryDark = byBand[.veryDark], let veryBright = byBand[.veryBright],
           !veryDark.isLowConfidence, !veryBright.isLowConfidence,
           let darkMedian = veryDark.medianBackgroundEPerSecPerArcsec2, darkMedian > 0,
           let brightMedian = veryBright.medianBackgroundEPerSecPerArcsec2
        {
            headlineRatio = brightMedian / darkMedian
        }

        return Result(
            buckets: buckets,
            headlineRatio: headlineRatio,
            usableBucketCount: buckets.filter { !$0.isLowConfidence }.count
        )
    }

    /// The Moon's illumination percent at `point`'s own session date, local
    /// noon UTC. Coarse -- a session usually spans two calendar days
    /// straddling local midnight, and there is no observation-window
    /// timestamp on a `TrendPoint` to center on more precisely (unlike
    /// `NightReport`'s own moon geometry, which has the actual
    /// `windowStart`/`windowEnd` to average) -- but honest about what a
    /// `TrendPoint` actually carries: a calendar date, not an instant. The
    /// Moon's illumination changes by at most a few percent within one day,
    /// which is well inside this function's own 25-point-wide bands.
    /// `nil` when `sessionStartDate` doesn't parse.
    private static func illuminationPercent(for point: TrendPoint) -> Double? {
        guard let sessionStartDate = point.sessionStartDate,
              let date = ymdFormatter.date(from: sessionStartDate)
        else { return nil }
        let localNoon = date.addingTimeInterval(12 * 3600)
        return SunMoon.moonIlluminationPercent(julianDay: JulianDate.julianDay(localNoon))
    }

    /// `YYYY-MM-DD`, UTC -- same convention as `TrendQueries.ymdFormatter`
    /// (duplicated rather than shared: that one is `private` to
    /// `TrendQueries`, and every other Stats file in this codebase already
    /// keeps its own small formatter/median helpers rather than factoring
    /// them into a shared utility).
    private static let ymdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 { return (sorted[mid - 1] + sorted[mid]) / 2 }
        return sorted[mid]
    }
}
