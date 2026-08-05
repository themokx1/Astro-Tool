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

private func headerJSON(_ cards: [String: String]) -> String {
    let data = try! JSONEncoder().encode(cards)
    return String(data: data, encoding: .utf8)!
}

/// Same fixture shape as `PlannerTests`' own `PlannerFixture` -- a fresh
/// sqlite-backed `Database` with a helper to insert one session light
/// directly (bypassing the scanner entirely).
private struct MonthFixture {
    let dbDir: URL
    let db: Database
    var config = AstroConfig()

    static func make() throws -> MonthFixture {
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-planner-month-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        return MonthFixture(dbDir: dbDir, db: db)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbDir)
    }

    @discardableResult
    func addLight(target: String, date: String = "2026-08-10", extraCards: [String: String] = [:]) throws -> Int64 {
        let path = "sessions/\(target)/\(date)/lights/l_\(UUID().uuidString).fit"
        let id = try db.upsertFile(FileRecord(
            path: path, size: 0, mtime: 0, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light, scannedAt: 0
        ))
        var cards = extraCards
        cards["EXPTIME"] = cards["EXPTIME"] ?? "300"
        try db.upsertFITSMeta(FITSMetaRecord(fileID: id, exptime: 300, headerJSON: headerJSON(cards)))
        return id
    }
}

// MARK: - 1. Target always up + no Moon interference -> usable ≈ dark hours

/// At `lat == 47.5`, a target with `dec == 80` never dips below `80 + 47.5 -
/// 90 == 37.5°` altitude at LOWER culmination -- always above the default
/// 30° gate, any night, any hour. Its declination is also far outside the
/// Moon's own (~±28°, bounded by the ecliptic's obliquity) range, so the
/// separation from the Moon is always well over 40° regardless of lunar
/// phase or position -- the Moon can never veto this target. Its usable
/// overlap for the night should therefore equal the full dark window.
@Test func monthGivesAlwaysUpTargetUsableHoursCloseToDarkWindow() throws {
    var fixture = try MonthFixture.make()
    defer { fixture.cleanup() }
    let lat = 47.5, lon = 19.0
    fixture.config.site = SiteRule(latitudeDeg: lat, longitudeDeg: lon)

    let referenceDate = utc(2026, 8, 27)
    try fixture.addLight(target: "T_AlwaysUp", extraCards: ["CRVAL1": "10.0", "CRVAL2": "80.0"])

    let summaries = try Planner.month(from: referenceDate, nights: 1, db: fixture.db, config: fixture.config)
    let night = try #require(summaries.first)

    let expectedNight = SunMoon.astronomicalTwilight(nightOf: referenceDate, latDeg: lat, lonDeg: lon, timeZone: TimeZone.current)
    let dusk = try #require(expectedNight.duskUTC)
    let dawn = try #require(expectedNight.dawnUTC)
    let expectedDarkHours = dawn.timeIntervalSince(dusk) / 3600.0

    let best = try #require(night.bestTargets.first { $0.target == "T_AlwaysUp" })
    #expect(abs(best.usableHours - expectedDarkHours) < 0.5, "usable=\(best.usableHours) dark=\(expectedDarkHours)")
}

// MARK: - 2. Moon veto zeroes usable hours

/// Reuses `PlannerTests`' own full-moon derivation (2026-08-27, lat 47.5 /
/// lon 19.0): a target placed exactly at the Moon's own position for that
/// night's midpoint has ~0° separation and a highly illuminated Moon, so it
/// must be vetoed entirely -- absent from `bestTargets`, not merely reduced.
@Test func monthZeroesUsableHoursWhenMoonVetoesTheTarget() throws {
    var fixture = try MonthFixture.make()
    defer { fixture.cleanup() }
    let lat = 47.5, lon = 19.0
    fixture.config.site = SiteRule(latitudeDeg: lat, longitudeDeg: lon)

    let referenceDate = utc(2026, 8, 27)
    let night = SunMoon.astronomicalTwilight(nightOf: referenceDate, latDeg: lat, lonDeg: lon, timeZone: TimeZone.current)
    let dusk = try #require(night.duskUTC)
    let dawn = try #require(night.dawnUTC)
    let midNight = dusk.addingTimeInterval(dawn.timeIntervalSince(dusk) / 2)
    let moon = SunMoon.moonPosition(julianDay: JulianDate.julianDay(midNight))

    try fixture.addLight(target: "T_MoonNear", extraCards: [
        "CRVAL1": "\(moon.raDeg)", "CRVAL2": "\(moon.decDeg)",
    ])

    let summaries = try Planner.month(from: referenceDate, nights: 1, minAltitudeDeg: 10, db: fixture.db, config: fixture.config)
    let summary = try #require(summaries.first)

    #expect(!summary.bestTargets.contains { $0.target == "T_MoonNear" })
}

// MARK: - 3. 30 entries, sequential dates

@Test func monthReturnsThirtySequentialDates() throws {
    var fixture = try MonthFixture.make()
    defer { fixture.cleanup() }
    fixture.config.site = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)

    let referenceDate = utc(2026, 8, 1)
    let summaries = try Planner.month(from: referenceDate, db: fixture.db, config: fixture.config)

    #expect(summaries.count == 30)

    let calendar = Calendar(identifier: .gregorian)
    var expected = summaries[0].date
    for summary in summaries.dropFirst() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let previousDate = formatter.date(from: expected)!
        let nextExpected = calendar.date(byAdding: .day, value: 1, to: previousDate)!
        expected = formatter.string(from: nextExpected)
        #expect(summary.date == expected)
    }
}

// MARK: - 4. No site at all -> every night notes it, no crash

@Test func monthNotesMissingSiteWithoutCrashing() throws {
    let fixture = try MonthFixture.make()
    defer { fixture.cleanup() }
    // No site configured, and no light carries SITELAT/SITELONG -- site is
    // fully unresolvable.
    try fixture.addLight(target: "T1")

    let summaries = try Planner.month(from: utc(2026, 8, 1), nights: 3, db: fixture.db, config: fixture.config)

    #expect(summaries.count == 3)
    for summary in summaries {
        #expect(summary.note == "nincs site-koordináta")
        #expect(summary.astroDarkHours == nil)
        #expect(summary.bestTargets.isEmpty)
    }
}
