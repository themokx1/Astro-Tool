@testable import AstroCore
import Foundation
import Testing

/// "Esetleg műholdcsík -- ellenőrizd" (expert ideation #8): a hedged proxy,
/// never a verdict. `SatelliteStreakHeuristic.isPossibleStreak` is the pure
/// predicate over one frame's already-computed raw z-scores; `flaggedPaths
/// (for:)` re-derives those z-scores from a batch of `FrameScore`s using
/// the SAME `RatingGroupMath` grouping/stats `OutlierBreakdown` itself uses
/// (never a second z-score implementation). The false-positive test matters
/// more than the catch rate here (see the heuristic's own doc comment): a
/// normal frame's z-scores must never trip the combined threshold.
struct SatelliteStreakHeuristicTests {
    // MARK: - Pure predicate

    @Test("Flags when starCount spikes AND fwhm also moves")
    func bothThresholdsFlags() {
        #expect(SatelliteStreakHeuristic.isPossibleStreak(starCountZ: 3.0, fwhmZ: 1.5, roundnessZ: 0.1))
    }

    @Test("Flags when starCount spikes AND roundness also moves (fwhm absent)")
    func starCountAndRoundnessFlagsWithoutFwhm() {
        #expect(SatelliteStreakHeuristic.isPossibleStreak(starCountZ: 2.6, fwhmZ: nil, roundnessZ: -1.2))
    }

    @Test("A high starCount alone -- shape metrics near normal -- does NOT flag")
    func starCountAloneDoesNotFlag() {
        #expect(!SatelliteStreakHeuristic.isPossibleStreak(starCountZ: 3.0, fwhmZ: 0.2, roundnessZ: 0.1))
    }

    @Test("A high starCount alone -- shape metrics entirely absent -- does NOT flag")
    func starCountAloneWithNoShapeDataDoesNotFlag() {
        #expect(!SatelliteStreakHeuristic.isPossibleStreak(starCountZ: 4.0, fwhmZ: nil, roundnessZ: nil))
    }

    @Test("Shape metrics moving alone -- starCount not elevated -- does NOT flag")
    func shapeMovementAloneDoesNotFlag() {
        #expect(!SatelliteStreakHeuristic.isPossibleStreak(starCountZ: 0.4, fwhmZ: 2.5, roundnessZ: 2.5))
    }

    @Test("starCount below threshold never flags regardless of shape movement")
    func belowStarCountThresholdNeverFlags() {
        #expect(!SatelliteStreakHeuristic.isPossibleStreak(starCountZ: 2.4, fwhmZ: 5.0, roundnessZ: 5.0))
    }

    @Test("Normal-range z-scores never flag, across a grid of plausible normal-frame values")
    func normalFrameGridNeverFlags() {
        // A grid, not a single sample: `starCountZ` stays strictly below
        // this heuristic's own +2.5 spike threshold, and both shape
        // z-scores stay strictly below its own +1 "moved at all"
        // threshold -- exactly the boundary a real, non-streaked frame's
        // ordinary night-to-night noise should never cross. If any point
        // on this grid trips the predicate, the two thresholds aren't
        // actually independent the way the doc comment claims.
        let starCountRange = stride(from: -2.4, through: 2.4, by: 0.3)
        let shapeRange = stride(from: -0.9, through: 0.9, by: 0.3)
        for starCountZ in starCountRange {
            for fwhmZ in shapeRange {
                for roundnessZ in shapeRange {
                    #expect(
                        !SatelliteStreakHeuristic.isPossibleStreak(starCountZ: starCountZ, fwhmZ: fwhmZ, roundnessZ: roundnessZ),
                        "tripped at starCountZ=\(starCountZ) fwhmZ=\(fwhmZ) roundnessZ=\(roundnessZ)"
                    )
                }
            }
        }
    }

    // MARK: - Batch re-derivation over FrameScore, sharing RatingGroupMath

    private static let cohort = RatingCohortDescriptor(sessionDate: "streak-test")

    private static func score(path: String, fwhm: Double?, roundness: Double?, starCount: Int?) -> FrameScore {
        let metrics: StarMetrics? = {
            guard let fwhm, let starCount else { return nil }
            return StarMetrics(fwhm: fwhm, roundness: roundness, starCount: starCount)
        }()
        return FrameScore(path: path, score: 0, isOutlier: false, metrics: metrics, background: nil, cohort: cohort)
    }

    @Test("flaggedPaths re-derives the exact same combined threshold from a batch of frames")
    func flaggedPathsMatchesPredicate() {
        // Eight baseline frames with tight, identical metrics, plus one
        // frame with a starCount far above the group and an fwhm also far
        // from the group's own value -- the "both thresholds" case, this
        // time built from raw FrameScores instead of hand-fed z-scores. (A
        // single outlier's z-score against `n` identical baseline values is
        // capped at sqrt(n-1) as the outlier's magnitude grows, so `n == 8`
        // baseline frames -- sqrt(8) ≈ 2.83 -- clears the +2.5 threshold
        // with real headroom regardless of exactly how large the spike is.)
        var frames: [FrameScore] = (0..<8).map {
            Self.score(path: "baseline-\($0)", fwhm: 3.0, roundness: 0.9, starCount: 50)
        }
        frames.append(Self.score(path: "streak", fwhm: 9.0, roundness: 0.9, starCount: 1000))

        let flagged = SatelliteStreakHeuristic.flaggedPaths(for: frames)

        #expect(flagged == ["streak"])
    }

    @Test("flaggedPaths does not flag a frame whose starCount alone is high")
    func flaggedPathsExcludesStarCountOnlySpike() {
        // A slight (real-world-like) jitter on the baseline fwhm/roundness
        // values, NOT exact repeats -- nine identical `Double` literals
        // divided back through a mean/variance pass can itself introduce
        // ~1e-16 floating-point noise into an intended-exactly-zero std,
        // which would make the very next division amplify that noise into
        // a spurious z-score. Real measured frames never land on the exact
        // same bit pattern anyway, so this jitter is the representative
        // case, not a workaround.
        var frames: [FrameScore] = (0..<8).map { i in
            Self.score(
                path: "baseline-\(i)",
                fwhm: 3.0 + Double((i % 3) - 1) * 0.05,
                roundness: 0.9 + Double((i % 3) - 1) * 0.01,
                starCount: 50
            )
        }
        // Only starCount moves; fwhm/roundness stay well inside the
        // group's own normal spread, so this must not trip the hedge.
        frames.append(Self.score(path: "more-stars", fwhm: 3.0, roundness: 0.9, starCount: 1000))

        let flagged = SatelliteStreakHeuristic.flaggedPaths(for: frames)

        #expect(flagged.isEmpty)
    }

    @Test("flaggedPaths is empty for an all-normal batch")
    func flaggedPathsEmptyForNormalBatch() {
        let frames: [FrameScore] = [
            Self.score(path: "a", fwhm: 3.0, roundness: 0.9, starCount: 48),
            Self.score(path: "b", fwhm: 3.1, roundness: 0.88, starCount: 50),
            Self.score(path: "c", fwhm: 2.9, roundness: 0.91, starCount: 52),
            Self.score(path: "d", fwhm: 3.05, roundness: 0.89, starCount: 49),
        ]

        #expect(SatelliteStreakHeuristic.flaggedPaths(for: frames).isEmpty)
    }
}
