import Foundation

/// Rounds a raw `exptime` reading to a "nice" nominal exposure length, so
/// float noise from the acquisition software (a real library shows exptime
/// 30.0 for 822 frames and 29.899999618523 for 91 more of what's clearly the
/// same nominal "30s" sub, plus 120.0/119.9 and 360.0/359.7 pairs) doesn't
/// split one real exposure group into several tiny ones -- which, for the
/// rating engine's z-scoring, silently collapses each split-off group's
/// `std` to ~0 and its z-scores to meaningless 0s.
///
/// The rule: whole-second rounding for exposures of 10s or longer (real
/// long exposures are essentially always integer seconds; the noise seen in
/// practice is well under 1s), and 0.1s rounding below 10s, where distinct
/// short exposures (e.g. 5.5s vs. 6.8s flats) must stay distinguishable
/// rather than being crushed together.
///
/// Used by `Rater`'s exposure-group scoring key, `StatsQueries`/
/// `SessionStatsQueries`'s `exposureBreakdown` keys, and `SessionTimeline`'s
/// auto gap-threshold calculation -- every place that needs "which exposure
/// bucket does this frame really belong to" rather than the raw float.
public enum NominalExposure {
    public static func nominal(_ exptime: Double) -> Double {
        if exptime >= 10 {
            return exptime.rounded()
        }
        return (exptime * 10).rounded() / 10
    }
}
