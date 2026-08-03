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

@Test func julianDayAtJ2000EpochIsExact() {
    let jd = JulianDate.julianDay(utc(2000, 1, 1, 12, 0, 0))
    #expect(jd == 2451545.0)
}

@Test func julianDayAtUnixEpochIsExact() {
    let jd = JulianDate.julianDay(Date(timeIntervalSince1970: 0))
    #expect(jd == 2440587.5)
}

@Test func julianDayRoundTripsThroughDate() {
    let original = utc(2026, 8, 3, 21, 45, 30)
    let jd = JulianDate.julianDay(original)
    let restored = JulianDate.date(fromJulianDay: jd)
    #expect(abs(restored.timeIntervalSince(original)) < 0.001)
}

@Test func julianDayIncreasesByOneDayPerDay() {
    let jd1 = JulianDate.julianDay(utc(2026, 8, 3, 0, 0, 0))
    let jd2 = JulianDate.julianDay(utc(2026, 8, 4, 0, 0, 0))
    #expect(abs((jd2 - jd1) - 1.0) < 1e-9)
}
