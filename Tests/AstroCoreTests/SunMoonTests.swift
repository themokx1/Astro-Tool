import Foundation
import Testing
@testable import AstroCore

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute; comps.second = second
    return calendar.date(from: comps)!
}

// MARK: - Sun

/// Meeus Ch. 25 low-precision solar dec should read ~0 deg at the March
/// equinox. 2026-03-20T12:00Z is within half a day of the actual 2026
/// March equinox instant, and solar declination moves ~0.4 deg/day there,
/// so ±0.7 deg is a comfortable, non-tautological tolerance.
@Test func sunDeclinationNearZeroAtMarchEquinox2026() {
    let jd = JulianDate.julianDay(utc(2026, 3, 20, 12, 0, 0))
    let sun = SunMoon.sunPosition(julianDay: jd)
    #expect(abs(sun.decDeg) < 0.7)
}

@Test func sunAltitudeIsHighestNearLocalNoonAtTheEquator() {
    let date = utc(2026, 3, 20, 12, 0, 0)
    let noonAlt = SunMoon.sunAltitude(date: date, latDeg: 0, lonDeg: 0)
    let midnightAlt = SunMoon.sunAltitude(date: date.addingTimeInterval(12 * 3600), latDeg: 0, lonDeg: 0)
    #expect(noonAlt > 80) // near-zenith at the equator on an equinox noon
    #expect(midnightAlt < -80) // opposite side of the sky at local midnight
}

// MARK: - Angular separation

@Test func separationBetweenEquatorPointsNinetyDegreesApartIsNinety() {
    let sep = SunMoon.angularSeparationDeg(ra1: 0, dec1: 0, ra2: 90, dec2: 0)
    #expect(abs(sep - 90) < 1e-9)
}

@Test func separationFromCelestialPoleEqualsNinetyMinusDeclination() {
    for dec in [-60.0, -10.0, 0.0, 25.0, 70.0] {
        let sep = SunMoon.angularSeparationDeg(ra1: 0, dec1: 90, ra2: 123.0, dec2: dec)
        #expect(abs(sep - (90 - dec)) < 1e-9)
    }
}

@Test func separationIsZeroForIdenticalCoordinates() {
    let sep = SunMoon.angularSeparationDeg(ra1: 45, dec1: 30, ra2: 45, dec2: 30)
    #expect(sep < 1e-9)
}

// MARK: - Moon phase, verified via the phase formula's own k-cycle
// (Meeus Eq. 49.1 "mean new moon"), rather than trusting externally
// quoted calendar dates for 2026's new/full moons.

/// Mean time of the k-th new moon (k integer) or, for `k + 0.5`, the
/// following full moon -- Meeus Eq. 49.1, without the ~24 additional
/// periodic correction terms (Meeus's fuller Eq. 49 table) that refine
/// mean conjunction to the true instant. The residual error this leaves
/// (up to several hours) still keeps the elongation within a couple of
/// degrees of exactly 0/180 -- comfortably inside the >97%/<3%
/// illumination thresholds these tests check.
private func meanPhaseJD(k: Double) -> Double {
    let T = k / 1236.85
    return 2451550.09766 + 29.530588861 * k + 0.00015437 * T * T
        - 0.000000150 * T * T * T + 0.00000000073 * T * T * T * T
}

/// `k` for the new moon nearest `year` (fractional, e.g. 2026.6 for
/// roughly August 2026) per Meeus's own k-cycle convention.
private func kForNewMoon(nearYear year: Double) -> Double {
    ((year - 2000) * 12.3685).rounded()
}

@Test func moonIlluminationNearZeroAtOwnFormulasNewMoonInstant() {
    let k = kForNewMoon(nearYear: 2026.6)
    let jd = meanPhaseJD(k: k)
    let illum = SunMoon.moonIlluminationPercent(julianDay: jd)
    #expect(illum < 3.0, "illum=\(illum) at JD=\(jd) (\(JulianDate.date(fromJulianDay: jd)))")
}

@Test func moonIlluminationNearFullAtOwnFormulasFullMoonInstant() {
    let k = kForNewMoon(nearYear: 2026.6)
    let jd = meanPhaseJD(k: k + 0.5)
    let illum = SunMoon.moonIlluminationPercent(julianDay: jd)
    #expect(illum > 97.0, "illum=\(illum) at JD=\(jd) (\(JulianDate.date(fromJulianDay: jd)))")
}

@Test func moonIlluminationWaxesMonotonicallyFromNewToFullMoon() {
    let k = kForNewMoon(nearYear: 2026.6)
    let jdNew = meanPhaseJD(k: k)
    let jdFull = meanPhaseJD(k: k + 0.5)

    var previous = -1.0
    var sawIncrease = false
    for step in 0...20 {
        let jd = jdNew + (jdFull - jdNew) * Double(step) / 20.0
        let illum = SunMoon.moonIlluminationPercent(julianDay: jd)
        #expect(illum >= previous - 0.001, "illumination dipped at step \(step): \(illum) < \(previous)")
        if illum > previous { sawIncrease = true }
        previous = illum
    }
    #expect(sawIncrease)
}

/// Multiple k-cycles across the year, not just the one nearest the user's
/// quoted 2026-08 dates -- guards against the single-cycle test above
/// having picked a coincidentally-favorable `k`.
@Test func moonIlluminationExtremesHoldAcrossSeveralCyclesIn2026() {
    for kOffset in -3...3 {
        let k = kForNewMoon(nearYear: 2026.5) + Double(kOffset)
        let newIllum = SunMoon.moonIlluminationPercent(julianDay: meanPhaseJD(k: k))
        let fullIllum = SunMoon.moonIlluminationPercent(julianDay: meanPhaseJD(k: k + 0.5))
        #expect(newIllum < 3.0, "cycle \(k): new moon illum \(newIllum)")
        #expect(fullIllum > 97.0, "cycle \(k): full moon illum \(fullIllum)")
    }
}

// MARK: - Twilight

@Test func astronomicalTwilightFindsDuskBeforeDawnAtMidLatitude() {
    // Budapest-ish, mid-winter -- comfortably has real astronomical night.
    let result = SunMoon.astronomicalTwilight(
        nightOf: utc(2026, 1, 15, 0, 0, 0),
        latDeg: 47.5, lonDeg: 19.0,
        timeZone: TimeZone(identifier: "Europe/Budapest")!
    )
    let dusk = try! #require(result.duskUTC)
    let dawn = try! #require(result.dawnUTC)
    #expect(dusk < dawn)
    #expect(!result.usedNauticalFallback)

    // Sun should actually be at/near -18 deg at both crossings.
    let duskAlt = SunMoon.sunAltitude(date: dusk, latDeg: 47.5, lonDeg: 19.0)
    let dawnAlt = SunMoon.sunAltitude(date: dawn, latDeg: 47.5, lonDeg: 19.0)
    #expect(abs(duskAlt - (-18)) < 0.5)
    #expect(abs(dawnAlt - (-18)) < 0.5)
}

@Test func astronomicalTwilightFallsBackToNauticalAtHighSummerLatitude() {
    // Far north in midsummer: the Sun never reaches -18 deg.
    let result = SunMoon.astronomicalTwilight(
        nightOf: utc(2026, 6, 21, 0, 0, 0),
        latDeg: 65.0, lonDeg: 19.0,
        timeZone: TimeZone(identifier: "Europe/Helsinki")!
    )
    #expect(result.usedNauticalFallback)
}
