import Foundation

/// The Planning table's ranking, expressed the way the astrophotographer who
/// asked for it expressed it: how much of the frame a target fills (90% of the
/// short edge is the sweet spot), how long it is *actually* photographable
/// tonight, and how close the Moon is — the last mattering least.
///
/// Deliberately a pure, total function over plain numbers: no astronomy is
/// re-derived here (`DiscoveryPlanner` already did that), and nothing it
/// touches can fail, so the whole ranking is unit-testable without a sky.
///
/// Every factor is normalised to 0...1 and combined with fixed weights, so the
/// score is explainable in one sentence to the user — which the Score column's
/// ⓘ popover does.
public enum PlanningScore {
    /// Hours the target is usably above the horizon, relative to tonight's
    /// astronomical darkness. Weighted highest: a perfectly framed target you
    /// can only shoot for twenty minutes is not tonight's best target.
    public static let photographableWeight = 0.45
    /// How well the target fills the frame at this focal length.
    public static let frameFillWeight = 0.40
    /// Moon interference. Smallest weight, and further scaled by the Moon's
    /// phase — on a 13% Moon this is close to irrelevant.
    public static let moonWeight = 0.15

    /// The short-edge fill fraction that frames best. Below it the target is
    /// small in the frame; above it, it starts spilling out toward a mosaic.
    public static let idealFrameFill = 0.90

    /// Beyond this much separation the Moon is treated as out of the way even
    /// when full.
    public static let moonIrrelevantSeparationDeg = 90.0

    /// How much of tonight's darkness the target is actually usable for.
    /// Saturates at 1 — being up longer than the dark window is no extra
    /// credit. Returns 0 for an unknown window rather than guessing.
    public static func photographableFactor(visibleHours: Double?, darknessHours: Double) -> Double {
        guard let visibleHours, visibleHours > 0,
              darknessHours.isFinite, darknessHours > 0
        else { return 0 }
        return clamp(visibleHours / darknessHours)
    }

    /// Peaks at `idealFrameFill` and falls off on both sides: too small wastes
    /// the sensor, too large stops fitting in one frame.
    public static func frameFillFactor(frameCoverage: Double) -> Double {
        guard frameCoverage.isFinite, frameCoverage > 0 else { return 0 }
        if frameCoverage <= idealFrameFill {
            return clamp(frameCoverage / idealFrameFill)
        }
        // Falls to zero by the time the target is 1.5x the short edge, i.e.
        // squarely mosaic territory.
        let overflow = frameCoverage - idealFrameFill
        return clamp(1 - overflow / 0.6)
    }

    /// 1 means the Moon is no problem. The penalty is the product of how close
    /// the Moon is, how bright it is, and (W7-A audit fix) the fraction of
    /// the target's own visible window during which the Moon is actually
    /// above the horizon -- a thin crescent nearby costs almost nothing, a
    /// full Moon nearby costs a lot, and a Moon that has already SET for the
    /// whole window costs nothing at all, no matter how full or how close.
    ///
    /// `aboveHorizonFraction` defaults to `1` (Moon treated as up for the
    /// entire window) so every call site that hasn't yet been wired to pass
    /// the real, sampled fraction (`AstroCore`'s
    /// `NightSweep.moonAboveHorizonFraction`, evaluated across the target's
    /// own visible window -- see `Planner.buildPlan`'s identical fix) keeps
    /// its previous behavior unchanged. Passing the real fraction is the
    /// caller's responsibility; this function has no sky access of its own.
    public static func moonFactor(separationDeg: Double?, illuminationPercent: Double, aboveHorizonFraction: Double = 1) -> Double {
        guard let separationDeg, separationDeg.isFinite, separationDeg >= 0 else { return 1 }
        let illumination = clamp(illuminationPercent / 100)
        let proximity = clamp(1 - separationDeg / moonIrrelevantSeparationDeg)
        let fraction = clamp(aboveHorizonFraction)
        return clamp(1 - illumination * proximity * fraction)
    }

    /// The single 0...1 number the Planning table sorts by.
    public static func composite(
        frameCoverage: Double,
        visibleHours: Double?,
        darknessHours: Double,
        moonSeparationDeg: Double?,
        moonIlluminationPercent: Double,
        moonAboveHorizonFraction: Double = 1
    ) -> Double {
        let photographable = photographableFactor(visibleHours: visibleHours, darknessHours: darknessHours)
        let frameFill = frameFillFactor(frameCoverage: frameCoverage)
        let moon = moonFactor(
            separationDeg: moonSeparationDeg, illuminationPercent: moonIlluminationPercent,
            aboveHorizonFraction: moonAboveHorizonFraction
        )
        let total = photographable * photographableWeight
            + frameFill * frameFillWeight
            + moon * moonWeight
        return clamp(total)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
