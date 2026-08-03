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

/// `hours` (fractional) -> total seconds, for tolerance comparisons against
/// published `HhMMmSS.ssss s`-style reference values.
private func hoursToSeconds(_ hours: Double) -> Double { hours * 3600.0 }

/// Second, independent implementation of GMST: compute theta0 (GMST at 0h
/// UT of the same calendar date) via the IAU 1982 seconds-form polynomial,
/// then add elapsed UT scaled by the sidereal/solar rate. Used only to
/// cross-check `SiderealTime.gmstHours` (the Meeus Eq. 12.4 "full poly"
/// form) against a structurally different derivation of the same
/// quantity -- if both have the same bug they'd still agree, but a
/// transcription slip in either one is very unlikely to cancel out.
private func gmstHoursViaElapsed(julianDay jd: Double) -> Double {
    let jd0 = (jd - 0.5).rounded(.down) + 0.5 // JD at 0h UT of this date
    let Tu = (jd0 - 2451545.0) / 36525.0
    let theta0Seconds = 24110.54841
        + 8640184.812866 * Tu
        + 0.093104 * Tu * Tu
        - 0.0000062 * Tu * Tu * Tu
    var theta0Hours = (theta0Seconds / 3600.0).truncatingRemainder(dividingBy: 24.0)
    if theta0Hours < 0 { theta0Hours += 24.0 }

    let utHours = (jd - jd0) * 24.0
    let siderealRate = 1.00273790935
    var gmst = (theta0Hours + utHours * siderealRate).truncatingRemainder(dividingBy: 24.0)
    if gmst < 0 { gmst += 24.0 }
    return gmst
}

// MARK: - vs. published (Meeus worked examples)

/// Meeus, *Astronomical Algorithms* 2nd ed., Example 12.a: at
/// 1987-04-10T00:00:00Z, GMST = 13h10m46.3668s. This is THE textbook
/// worked example the IAU 1982 GMST polynomial is checked against --
/// about as authoritative a "published reference value" as exists for
/// this formula.
@Test func gmstMatchesMeeusWorkedExample12a() {
    let jd = JulianDate.julianDay(utc(1987, 4, 10, 0, 0, 0))
    let gmst = SiderealTime.gmstHours(julianDay: jd)
    let expectedHours = 13.0 + 10.0 / 60.0 + 46.3668 / 3600.0
    #expect(abs(hoursToSeconds(gmst) - hoursToSeconds(expectedHours)) < 0.01)
}

/// Meeus Example 12.b: same date, 19h21m00s UT -> GMST = 8h34m57.0896s
/// (wrapped past 24h). Exercises the polynomial away from 0h UT.
@Test func gmstMatchesMeeusWorkedExample12b() {
    let jd = JulianDate.julianDay(utc(1987, 4, 10, 19, 21, 0))
    let gmst = SiderealTime.gmstHours(julianDay: jd)
    let expectedHours = 8.0 + 34.0 / 60.0 + 57.0896 / 3600.0
    #expect(abs(hoursToSeconds(gmst) - hoursToSeconds(expectedHours)) < 0.01)
}

// MARK: - cross-check: poly vs from-JD0h+elapsed

@Test func gmstPolyAgreesWithElapsedFormulaAt2004Epoch() {
    let jd = JulianDate.julianDay(utc(2004, 4, 6, 0, 0, 0))
    let poly = SiderealTime.gmstHours(julianDay: jd)
    let elapsed = gmstHoursViaElapsed(julianDay: jd)
    #expect(abs(hoursToSeconds(poly) - hoursToSeconds(elapsed)) < 0.1)
}

@Test func gmstPolyAgreesWithElapsedFormulaAtModernEpoch() {
    let jd = JulianDate.julianDay(utc(2026, 8, 3, 21, 30, 0))
    let poly = SiderealTime.gmstHours(julianDay: jd)
    let elapsed = gmstHoursViaElapsed(julianDay: jd)
    #expect(abs(hoursToSeconds(poly) - hoursToSeconds(elapsed)) < 0.1)
}

// MARK: - LST

@Test func lstAtZeroLongitudeEqualsGMST() {
    let jd = JulianDate.julianDay(utc(2026, 3, 20, 12, 0, 0))
    let gmst = SiderealTime.gmstHours(julianDay: jd)
    let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: 0)
    #expect(abs(lst - gmst) < 1e-9)
}

@Test func lstAdvancesByLongitudeOverFifteenDegreesPerHour() {
    let jd = JulianDate.julianDay(utc(2026, 3, 20, 12, 0, 0))
    let lstEast = SiderealTime.lstHours(julianDay: jd, longitudeDeg: 15)
    let lstZero = SiderealTime.lstHours(julianDay: jd, longitudeDeg: 0)
    var delta = lstEast - lstZero
    if delta < 0 { delta += 24 }
    #expect(abs(delta - 1.0) < 1e-9)
}

@Test func lstIsAlwaysNormalizedToZeroTwentyFourRange() {
    for hour in stride(from: 0, to: 24, by: 3) {
        let jd = JulianDate.julianDay(utc(2026, 1, 1, hour))
        let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: -179)
        #expect(lst >= 0 && lst < 24)
        let gmst = SiderealTime.gmstHours(julianDay: jd)
        #expect(gmst >= 0 && gmst < 24)
    }
}
