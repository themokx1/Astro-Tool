import Foundation

/// A hedged, NEVER-a-verdict proxy for "this frame might contain a
/// satellite/plane streak" (expert ideation #8). A streak crossing the
/// frame fools the star detector into counting many spurious point sources
/// along its bright edge -- `starCount` spikes well above what this
/// exposure group's other frames show -- WHILE the same detector's own
/// shape/sharpness read on the frame (`fwhm`/`roundness`) gets thrown off
/// at the same time, contaminated by the streak's own (non-stellar)
/// geometry, unlike an ordinary "clearer sky, more real stars" night, which
/// would leave `fwhm`/`roundness` sitting right where every other frame in
/// the group does.
///
/// Deliberately reuses `RatingGroupMath`'s own group-key/mean/std/z-score
/// formulas -- the SAME ones `OutlierBreakdown` and `Rater.scoreGroup`
/// already use -- rather than a second z-score implementation that could
/// silently drift from what a frame's real score was computed from.
///
/// # Thresholds (tuned so a normal frame never trips this)
/// - `starCountZ >= +2.5`: a streak's spurious detections can only ever ADD
///   candidate "stars", never remove real ones, so the spike is
///   one-directional and has to be a clear outlier -- an ordinary night's
///   `starCount` wobble (thinner haze, a slightly darker sky, drift near
///   the group's edge) routinely moves a point or so and must not qualify.
/// - AND (`|fwhmZ| >= +1` OR `|roundnessZ| >= +1`): checked in ABSOLUTE
///   VALUE, not a fixed sign. Whether a streak pushes the frame's
///   aggregate `fwhm`/`roundness` up or down depends on exactly which
///   (real vs. streak-shaped) sources the star detector's own averaging
///   happens to land on -- a hedge that only cares whether the shape
///   metrics moved away from the group's usual value AT ALL, rather than
///   committing to one direction, catches the real cases without modeling
///   Siril's internal star-selection. `+1` sigma alone is common by chance
///   (~1/3 of a normal population sits past 1 sigma on SOME frame in a
///   session), which is why this half is never checked alone -- it only
///   has to line up WITH the `starCount` spike, never carry the signal by
///   itself.
///
/// # Why false-positive rate matters more than catch rate here
/// This never rejects a frame by itself -- it only adds one hedged,
/// separately-selectable line to the Morning Triage Digest ("possible
/// satellite trail -- check"), never merged into the digest's confident
/// causes. Missing a real streak just means the owner's normal per-frame
/// review still catches it, same as before this heuristic existed. A FALSE
/// alarm, though, trains the owner to ignore the hedge line entirely, which
/// is strictly worse than not showing it -- so both threshold pieces above
/// are picked deliberately narrower than either signal alone, requiring an
/// extreme, one-directional `starCount` spike AND a simultaneous shape
/// disturbance together, rather than tuned to catch every real streak.
public enum SatelliteStreakHeuristic {
    public static let starCountZThreshold = 2.5
    public static let shapeZThreshold = 1.0

    /// The pure predicate -- one frame's already-computed raw (un-oriented)
    /// per-group z-scores in, one hedged yes/no out. `nil` inputs simply
    /// can't trip their half of the check (a frame missing a metric
    /// entirely, or a group too small for `RatingGroupMath.metricStats` to
    /// produce a non-zero std).
    public static func isPossibleStreak(starCountZ: Double?, fwhmZ: Double?, roundnessZ: Double?) -> Bool {
        guard let starCountZ, starCountZ >= starCountZThreshold else { return false }
        let fwhmTripped = fwhmZ.map { abs($0) >= shapeZThreshold } ?? false
        let roundnessTripped = roundnessZ.map { abs($0) >= shapeZThreshold } ?? false
        return fwhmTripped || roundnessTripped
    }

    /// Flags every frame in `frames` using the SAME per-group values
    /// `OutlierBreakdown.breakdowns(for:)` builds (session-date x
    /// nominal-exptime x cohort grouping, mean/std per metric within that
    /// group) -- never a second implementation of that grouping or the
    /// z-score formula. Runs over ALL frames, not just `isOutlier` ones:
    /// an inflated `starCount` can push a streak-contaminated frame's
    /// overall `score` UP (higher `starCount` is "better" in `Rater`'s own
    /// weighting), so a real streak can hide inside a frame that never
    /// trips the ordinary outlier flag at all.
    public static func flaggedPaths(for frames: [FrameScore]) -> Set<String> {
        var groups: [RatingGroupMath.GroupKey: [FrameScore]] = [:]
        for frame in frames {
            let key = RatingGroupMath.groupKey(
                sessionDate: OutlierBreakdown.sessionDate(ofPath: frame.path),
                exptime: frame.exptime,
                cohort: frame.cohort
            )
            groups[key, default: []].append(frame)
        }

        var flagged: Set<String> = []
        for groupFrames in groups.values {
            let fwhmStats = RatingGroupMath.metricStats(groupFrames.compactMap { $0.metrics?.fwhm })
            let roundnessStats = RatingGroupMath.metricStats(groupFrames.compactMap { $0.metrics?.roundness })
            let starCountStats = RatingGroupMath.metricStats(groupFrames.compactMap { ($0.metrics?.starCount).map(Double.init) })

            for frame in groupFrames {
                let starCountZ = (frame.metrics?.starCount).map { RatingGroupMath.zScore(Double($0), stats: starCountStats) }
                let fwhmZ = (frame.metrics?.fwhm).map { RatingGroupMath.zScore($0, stats: fwhmStats) }
                let roundnessZ = frame.metrics?.roundness.map { RatingGroupMath.zScore($0, stats: roundnessStats) }
                if isPossibleStreak(starCountZ: starCountZ, fwhmZ: fwhmZ, roundnessZ: roundnessZ) {
                    flagged.insert(frame.path)
                }
            }
        }
        return flagged
    }
}
