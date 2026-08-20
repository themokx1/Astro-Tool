@testable import AstroApplication
import Foundation
import Testing

/// The ranking an experienced astrophotographer asked for, in their own terms:
/// "how much of the frame it fills (90% is best), how long it is actually
/// photographable, and how close the Moon is (that matters less)" -- one score
/// to sort by, with each component also visible and sortable on its own.
struct PlanningScoreTests {
    @Test("The three weights are the agreed 45/40/15 split and sum to one")
    func weightsAreTheAgreedSplit() {
        #expect(PlanningScore.photographableWeight == 0.45)
        #expect(PlanningScore.frameFillWeight == 0.40)
        #expect(PlanningScore.moonWeight == 0.15)
        let total = PlanningScore.photographableWeight
            + PlanningScore.frameFillWeight
            + PlanningScore.moonWeight
        #expect(abs(total - 1) < 0.000_001)
    }

    @Test("Frame fill peaks at 90 percent of the short edge")
    func frameFillPeaksAtNinetyPercent() {
        let ideal = PlanningScore.frameFillFactor(frameCoverage: 0.90)
        #expect(abs(ideal - 1) < 0.000_001)
        // Too small to be worth the focal length.
        #expect(PlanningScore.frameFillFactor(frameCoverage: 0.40) < ideal)
        #expect(PlanningScore.frameFillFactor(frameCoverage: 0.10) < PlanningScore.frameFillFactor(frameCoverage: 0.40))
        // Overflowing the frame, heading into mosaic territory.
        #expect(PlanningScore.frameFillFactor(frameCoverage: 1.30) < ideal)
        #expect(PlanningScore.frameFillFactor(frameCoverage: 1.80) < PlanningScore.frameFillFactor(frameCoverage: 1.30))
        // Always a usable 0...1 factor.
        for coverage in [0.0, 0.5, 0.9, 1.0, 2.0, 5.0] {
            let factor = PlanningScore.frameFillFactor(frameCoverage: coverage)
            #expect(factor >= 0 && factor <= 1)
        }
    }

    @Test("Photographable time rewards more usable darkness")
    func photographableTimeRewardsLongerWindows() {
        let short = PlanningScore.photographableFactor(visibleHours: 1, darknessHours: 6)
        let long = PlanningScore.photographableFactor(visibleHours: 5, darknessHours: 6)
        #expect(long > short)
        // A target up for the whole dark window saturates at 1.
        #expect(abs(PlanningScore.photographableFactor(visibleHours: 6, darknessHours: 6) - 1) < 0.000_001)
        // Never above 1 even if the engine reports a longer window than the
        // darkness we computed, and never negative.
        #expect(PlanningScore.photographableFactor(visibleHours: 9, darknessHours: 6) <= 1)
        #expect(PlanningScore.photographableFactor(visibleHours: nil, darknessHours: 6) == 0)
        // A degenerate night (no darkness at all) must not divide by zero.
        let polarDay = PlanningScore.photographableFactor(visibleHours: 0, darknessHours: 0)
        #expect(polarDay.isFinite)
    }

    @Test("The Moon barely matters when it is dark and matters when it is full")
    func moonPenaltyIsWeightedByIllumination() {
        // The night the user reported: a 13% Moon. Proximity should be close
        // to irrelevant -- that is exactly why this factor carries the
        // smallest weight.
        let thinMoonClose = PlanningScore.moonFactor(separationDeg: 20, illuminationPercent: 13)
        let thinMoonFar = PlanningScore.moonFactor(separationDeg: 120, illuminationPercent: 13)
        #expect(thinMoonFar - thinMoonClose < 0.2)

        // Near full Moon, sitting right next to it is genuinely bad.
        let fullMoonClose = PlanningScore.moonFactor(separationDeg: 20, illuminationPercent: 95)
        let fullMoonFar = PlanningScore.moonFactor(separationDeg: 120, illuminationPercent: 95)
        #expect(fullMoonFar - fullMoonClose > 0.5)
        #expect(fullMoonClose < thinMoonClose)

        // Unknown separation must not invent a penalty or a bonus.
        let unknown = PlanningScore.moonFactor(separationDeg: nil, illuminationPercent: 95)
        #expect(unknown >= 0 && unknown <= 1)
    }

    @Test("W7-A: a Moon below the horizon for the whole visible window is no problem, however full or however close")
    func moonFactorIsNeutralWhenTheMoonNeverRisesDuringTheWindow() {
        // Full Moon, sitting right on top of the target -- the worst
        // possible illumination/separation -- but it never rose during the
        // target's own visible window.
        let factor = PlanningScore.moonFactor(separationDeg: 0, illuminationPercent: 100, aboveHorizonFraction: 0)
        #expect(factor == 1)
    }

    @Test("W7-A: aboveHorizonFraction defaults to 1 -- existing call sites keep their prior behavior unchanged")
    func moonFactorDefaultsToTreatingTheMoonAsUpForTheWholeWindow() {
        let withDefault = PlanningScore.moonFactor(separationDeg: 20, illuminationPercent: 60)
        let explicitFullExposure = PlanningScore.moonFactor(separationDeg: 20, illuminationPercent: 60, aboveHorizonFraction: 1)
        #expect(withDefault == explicitFullExposure)
    }

    @Test("W7-A: the penalty scales continuously with how much of the window the Moon is actually up for")
    func moonFactorPenaltyScalesWithAboveHorizonFraction() {
        let fullExposure = PlanningScore.moonFactor(separationDeg: 0, illuminationPercent: 100, aboveHorizonFraction: 1)
        let halfExposure = PlanningScore.moonFactor(separationDeg: 0, illuminationPercent: 100, aboveHorizonFraction: 0.5)
        #expect(abs(fullExposure - 0) < 0.000_001)
        #expect(abs(halfExposure - 0.5) < 0.000_001)
    }

    @Test("The composite score ranks a well-placed target above a poorly placed one")
    func compositeRanksSensibly() {
        // NGC 7000 on the reported night: high, up all night, Moon far away.
        let good = PlanningScore.composite(
            frameCoverage: 0.88, visibleHours: 5.9, darknessHours: 5.9,
            moonSeparationDeg: 122, moonIlluminationPercent: 13
        )
        // A target that frames just as well but is only up briefly.
        let brief = PlanningScore.composite(
            frameCoverage: 0.88, visibleHours: 0.5, darknessHours: 5.9,
            moonSeparationDeg: 122, moonIlluminationPercent: 13
        )
        // A target up all night that barely fills the frame.
        let tiny = PlanningScore.composite(
            frameCoverage: 0.08, visibleHours: 5.9, darknessHours: 5.9,
            moonSeparationDeg: 122, moonIlluminationPercent: 13
        )
        #expect(good > brief)
        #expect(good > tiny)
        // Time is weighted above framing, so losing almost all the night
        // costs more than losing most of the frame fill.
        #expect(brief < tiny)
        for score in [good, brief, tiny] {
            #expect(score >= 0 && score <= 1)
        }
    }

    @Test("The composite score is total: missing sky data never produces NaN")
    func compositeIsTotal() {
        let score = PlanningScore.composite(
            frameCoverage: 0.5, visibleHours: nil, darknessHours: 0,
            moonSeparationDeg: nil, moonIlluminationPercent: 0
        )
        #expect(score.isFinite)
        #expect(score >= 0 && score <= 1)
    }
}
