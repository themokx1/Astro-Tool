import Foundation
import Testing
@testable import AstroCore

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute; comps.second = second
    return calendar.date(from: comps)!
}

/// W7-A audit: the forward planner's Moon-interference math (`Planner.
/// buildPlan`'s verdict/score, `Planner.month`'s usable-hours veto,
/// `DiscoveryPlanner.discover`'s own score) never checked whether the Moon
/// was even above the horizon during the target's own visible window --
/// verified independently against pyephem: on 2026-08-18 the Moon sits at
/// -28.8 deg at the dark-window midpoint, yet the OLD illum x separation-only
/// penalty applied as if it were up. It also cliffed sharply at its illum/
/// separation thresholds (59%@41 deg kept full hours/no penalty, 61%@39 deg
/// zeroed/fully penalized) instead of degrading continuously.
///
/// `SkyScore.moonFactor` is the single function now shared between
/// `Planner.score`'s per-target ranking penalty and `Planner.month`'s
/// usable-hours scaling (and `DiscoveryPlanner.discover`'s own score) --
/// this file is the independent-check-style test set the audit asked for,
/// covering the three fixed scenarios by name: (a) Moon below horizon the
/// whole window, (b) Moon up half the window, (c) Moon up the whole window
/// straddling the old cliff boundary.
struct SkyScoreMoonFactorTests {
    // MARK: - (a) Moon below horizon the whole window -> no penalty, no veto

    @Test func moonFactorIsNeutralWhenTheMoonIsBelowHorizonTheEntireWindow() {
        // Full Moon, sitting exactly on the target -- the worst possible
        // illumination/separation combination -- but `aboveHorizonFraction:
        // 0` says it never rose during the target's own visible window.
        let factor = SkyScore.moonFactor(separationDeg: 0, illuminationPercent: 100, aboveHorizonFraction: 0)
        #expect(factor == 1, "a Moon that never rises during the window cannot brighten it, however full or however close")
    }

    // MARK: - (b) Moon up half the window -> penalty about half the full-exposure penalty

    @Test func moonFactorPenaltyScalesWithAboveHorizonFraction() {
        let fullExposure = SkyScore.moonFactor(separationDeg: 0, illuminationPercent: 100, aboveHorizonFraction: 1)
        let halfExposure = SkyScore.moonFactor(separationDeg: 0, illuminationPercent: 100, aboveHorizonFraction: 0.5)
        // Full exposure at 100% illum / 0 deg separation is the documented
        // total-penalty limit: factor all the way down to 0.
        #expect(abs(fullExposure - 0) < 0.000_001)
        // Half the window exposed to the same Moon halves the DEFICIT from
        // 1 (not the resulting factor itself) -- i.e. exactly halfway
        // between "no penalty" (1) and the full-exposure penalty (0).
        #expect(abs(halfExposure - 0.5) < 0.000_001)
    }

    // MARK: - (c) Moon up the whole window, straddling the old cliff -- continuous, not a jump

    @Test func moonFactorIsContinuousAcrossTheOldBinaryCliffBoundary() {
        // The retired veto fired at `illum > 60 && sep < 40`. These two
        // points sit on opposite sides of that exact boundary: 59%@41 deg
        // used to keep the OLD binary factor at a clean 1.0 (no penalty at
        // all); 61%@39 deg used to drop it straight to 0.2. The new
        // continuous function must place them close together instead.
        let justBelowOldThreshold = SkyScore.moonFactor(separationDeg: 41, illuminationPercent: 59, aboveHorizonFraction: 1)
        let justAboveOldThreshold = SkyScore.moonFactor(separationDeg: 39, illuminationPercent: 61, aboveHorizonFraction: 1)
        #expect(
            abs(justBelowOldThreshold - justAboveOldThreshold) < 0.05,
            "justBelow=\(justBelowOldThreshold) justAbove=\(justAboveOldThreshold) -- must not cliff"
        )
        // Both represent a real but partial penalty now, not the old
        // all-or-nothing 1.0-or-0.2 values.
        for factor in [justBelowOldThreshold, justAboveOldThreshold] {
            #expect(factor > 0.2 && factor < 1, "factor=\(factor) should be a continuous partial penalty, not the old cliff values")
        }
    }

    @Test func moonFactorReachesExactlyZeroOnlyAtTheDocumentedFullExposureLimit() {
        let atTheLimit = SkyScore.moonFactor(separationDeg: 0, illuminationPercent: 100, aboveHorizonFraction: 1)
        #expect(atTheLimit == 0)
        // Anything short of the exact limit stays strictly positive --
        // "hours go to zero" is a limit, never a step.
        #expect(SkyScore.moonFactor(separationDeg: 0.5, illuminationPercent: 100, aboveHorizonFraction: 1) > 0)
        #expect(SkyScore.moonFactor(separationDeg: 0, illuminationPercent: 99.9, aboveHorizonFraction: 1) > 0)
        #expect(SkyScore.moonFactor(separationDeg: 0, illuminationPercent: 100, aboveHorizonFraction: 0.999) > 0)
    }

    @Test func moonFactorIsAlwaysInUnitRangeAcrossExtremeInputs() {
        for sep in [-10.0, 0, 45, 90, 200] {
            for illum in [-5.0, 0, 50, 100, 150] {
                for fraction in [-1.0, 0, 0.5, 1, 2] {
                    let factor = SkyScore.moonFactor(separationDeg: sep, illuminationPercent: illum, aboveHorizonFraction: fraction)
                    #expect(factor >= 0 && factor <= 1, "sep=\(sep) illum=\(illum) fraction=\(fraction) -> \(factor)")
                }
            }
        }
    }
}

/// `NightSweep.moonAboveHorizonFraction` -- the shared Moon-altitude sampler
/// `SkyScore.moonFactor`'s altitude weighting draws on, and the SAME loop
/// (`NightSweep.moonAltitudeSamples`) `Planner.moonEventLabel` (the "Hold"
/// tile's rise/set wording) now walks too, rather than each keeping a
/// private copy that could silently drift from the other.
struct NightSweepMoonAboveHorizonFractionTests {
    @Test func fractionIsNilForAnEmptyWindow() {
        let now = Date()
        let fraction = NightSweep.moonAboveHorizonFraction(
            latDeg: 47.5, lonDeg: 19.0, startUTC: now.addingTimeInterval(100), endUTC: now
        )
        #expect(fraction == nil)
    }

    @Test func fractionMatchesADirectAltitudeCheckOverAShortWindow() throws {
        let lat = 47.5, lon = 19.0
        let referenceDate = utc(2026, 8, 27)
        let night = SunMoon.astronomicalTwilight(nightOf: referenceDate, latDeg: lat, lonDeg: lon, timeZone: TimeZone(identifier: "UTC")!)
        let dusk = try #require(night.duskUTC)
        let dawn = try #require(night.dawnUTC)
        let midNight = dusk.addingTimeInterval(dawn.timeIntervalSince(dusk) / 2)

        // Ground truth: the Moon's own altitude at the window's midpoint,
        // computed directly from the same primitives `moonAboveHorizonFraction`
        // uses internally -- independent of that function's own loop.
        let midJD = JulianDate.julianDay(midNight)
        let moon = SunMoon.moonPosition(julianDay: midJD)
        let lst = SiderealTime.lstHours(julianDay: midJD, longitudeDeg: lon)
        let altAtMidpoint = AltAz.position(raDeg: moon.raDeg, decDeg: moon.decDeg, lstHours: lst, latDeg: lat).altitudeDeg

        // A 20-minute window centered on the midpoint -- the Moon moves only
        // a fraction of a degree in +/-10 minutes, so unless the midpoint sits
        // within a few degrees of the horizon, it does not cross during this
        // short a window.
        let start = midNight.addingTimeInterval(-600)
        let end = midNight.addingTimeInterval(600)
        let fraction = try #require(NightSweep.moonAboveHorizonFraction(latDeg: lat, lonDeg: lon, startUTC: start, endUTC: end, stepMinutes: 5))

        if altAtMidpoint > 5 {
            #expect(fraction == 1, "moon altitude at midpoint=\(altAtMidpoint) -- expected the whole short window above horizon")
        } else if altAtMidpoint < -5 {
            #expect(fraction == 0, "moon altitude at midpoint=\(altAtMidpoint) -- expected the whole short window below horizon")
        }
        // Within +/-5 deg of the horizon: too close to a crossing for this
        // short window to make a confident assertion either way -- no crash
        // is itself the coverage this branch needs.
    }

    @Test func fractionIsAnHonestRecountOfTheUnderlyingAltitudeSamples() throws {
        // Contract test, not a hardcoded ephemeris expectation: whatever
        // this specific night's Moon altitude actually is, the fraction
        // `moonAboveHorizonFraction` reports must equal a direct recount of
        // `moonAltitudeSamples`' own samples over the identical window.
        let lat = 70.0, lon = 19.0
        let start = utc(2026, 6, 21, 0, 0, 0)
        let end = utc(2026, 6, 21, 1, 0, 0)
        let samples = NightSweep.moonAltitudeSamples(latDeg: lat, lonDeg: lon, startUTC: start, endUTC: end, stepMinutes: 10)
        #expect(!samples.isEmpty)
        let fraction = try #require(NightSweep.moonAboveHorizonFraction(latDeg: lat, lonDeg: lon, startUTC: start, endUTC: end, stepMinutes: 10))
        let recount = Double(samples.filter { $0.altitudeDeg >= 0 }.count) / Double(samples.count)
        #expect(abs(fraction - recount) < 0.000_001)
    }
}

/// `NightSweepResult.isGenuineCulmination` -- see that field's own doc
/// comment. A target still climbing at dawn (or already past its peak at
/// dusk) never had its true meridian transit sampled at all; the recorded
/// `culminationUTC` is only "the edge of the window we happened to scan".
struct NightSweepCulminationGenuinenessTests {
    private let lat = 47.5
    private let lon = 19.0

    @Test func culminationIsNotGenuineWhenTheTargetIsStillRisingAtDawn() throws {
        let referenceDate = utc(2026, 8, 27)
        let night = SunMoon.astronomicalTwilight(nightOf: referenceDate, latDeg: lat, lonDeg: lon, timeZone: TimeZone(identifier: "UTC")!)
        let dusk = try #require(night.duskUTC)
        let dawn = try #require(night.dawnUTC)

        // RA chosen so the target's meridian transit (hour angle 0) falls
        // EXACTLY at dawn -- it is still climbing for the entire window, so
        // whatever the sweep records as "culmination" is really just "the
        // last instant we looked", not a genuine transit.
        let dawnJD = JulianDate.julianDay(dawn)
        let lstAtDawn = SiderealTime.lstHours(julianDay: dawnJD, longitudeDeg: lon)
        let raDeg = lstAtDawn * 15.0

        // dec 20 deg: at lat 47.5 this rises and sets (not circumpolar --
        // lower culmination is 47.5+20-90 = -22.5 deg) so there is exactly
        // one transit per sidereal day, comfortably outside this window.
        let result = NightSweep.sweep(
            raDeg: raDeg, decDeg: 20, latDeg: lat, lonDeg: lon,
            duskUTC: dusk, dawnUTC: dawn, minAltitudeDeg: -90, stepMinutes: 2
        )
        #expect(result.culminationUTC != nil)
        #expect(result.isGenuineCulmination == false, "the target transits exactly at dawn -- the window never sampled a real peak")
    }

    @Test func culminationIsNotGenuineWhenTheTargetIsAlreadyFallingAtDusk() throws {
        let referenceDate = utc(2026, 8, 27)
        let night = SunMoon.astronomicalTwilight(nightOf: referenceDate, latDeg: lat, lonDeg: lon, timeZone: TimeZone(identifier: "UTC")!)
        let dusk = try #require(night.duskUTC)
        let dawn = try #require(night.dawnUTC)

        // Mirror image: RA chosen so the transit falls EXACTLY at dusk --
        // the target is already past its peak for the entire window.
        let duskJD = JulianDate.julianDay(dusk)
        let lstAtDusk = SiderealTime.lstHours(julianDay: duskJD, longitudeDeg: lon)
        let raDeg = lstAtDusk * 15.0

        let result = NightSweep.sweep(
            raDeg: raDeg, decDeg: 20, latDeg: lat, lonDeg: lon,
            duskUTC: dusk, dawnUTC: dawn, minAltitudeDeg: -90, stepMinutes: 2
        )
        #expect(result.culminationUTC != nil)
        #expect(result.isGenuineCulmination == false, "the target transited exactly at dusk -- the window never sampled a real peak")
    }

    @Test func culminationIsGenuineWhenTheTargetTransitsInsideTheWindow() throws {
        let referenceDate = utc(2026, 8, 27)
        let night = SunMoon.astronomicalTwilight(nightOf: referenceDate, latDeg: lat, lonDeg: lon, timeZone: TimeZone(identifier: "UTC")!)
        let dusk = try #require(night.duskUTC)
        let dawn = try #require(night.dawnUTC)
        let midNight = dusk.addingTimeInterval(dawn.timeIntervalSince(dusk) / 2)

        // RA chosen so the transit falls at the window's own midpoint --
        // squarely inside, hours away from either edge.
        let midJD = JulianDate.julianDay(midNight)
        let lstAtMidpoint = SiderealTime.lstHours(julianDay: midJD, longitudeDeg: lon)
        let raDeg = lstAtMidpoint * 15.0

        let result = NightSweep.sweep(
            raDeg: raDeg, decDeg: 20, latDeg: lat, lonDeg: lon,
            duskUTC: dusk, dawnUTC: dawn, minAltitudeDeg: -90, stepMinutes: 2
        )
        #expect(result.culminationUTC != nil)
        #expect(result.isGenuineCulmination == true, "the target transits squarely inside the window")
        // Sanity: the recorded culmination should land close to the
        // midpoint we engineered it to transit at.
        let culmination = try #require(result.culminationUTC)
        #expect(abs(culmination.timeIntervalSince(midNight)) < 300, "culmination=\(culmination) expected near midpoint=\(midNight)")
    }
}
