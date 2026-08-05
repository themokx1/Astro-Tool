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

/// Fresh sqlite-backed `Database` with helpers to insert a session light
/// directly (bypassing the scanner/filesystem entirely -- Planner only ever
/// reads through `Database`, so this is all a Planner test needs).
private struct PlannerFixture {
    let dbDir: URL
    let db: Database
    var config = AstroConfig()

    static func make() throws -> PlannerFixture {
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-planner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        return PlannerFixture(dbDir: dbDir, db: db)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Inserts one session light for `target` with the given header cards.
    @discardableResult
    func addLight(
        target: String,
        date: String = "2026-08-10",
        exptime: Double = 300,
        extraCards: [String: String] = [:],
        fileSuffix: String = "1"
    ) throws -> Int64 {
        let path = "sessions/\(target)/\(date)/lights/l\(fileSuffix)_\(UUID().uuidString).fit"
        let id = try db.upsertFile(FileRecord(
            path: path, size: 0, mtime: 0, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light, scannedAt: 0
        ))
        var cards = extraCards
        cards["EXPTIME"] = cards["EXPTIME"] ?? "\(exptime)"
        try db.upsertFITSMeta(FITSMetaRecord(fileID: id, exptime: exptime, headerJSON: headerJSON(cards)))
        return id
    }
}

// MARK: - R7-B7: displayName

@Test func plannerResolvesDisplayNameFromTargetFolderName() throws {
    let fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLight(target: "M42_Orion_wide_field", extraCards: [:])

    let plans = try Planner.plan(db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "M42_Orion_wide_field" })
    #expect(plan.displayName == "M 42 · Orion-köd")
}

// MARK: - No coordinate

@Test func plannerMarksTargetWithNoResolvableCoordinateAsNoCoordinate() throws {
    let fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLight(target: "T_NoCoord", extraCards: [:])

    let plans = try Planner.plan(db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_NoCoord" })
    #expect(plan.verdict == "nincs koordináta")
    #expect(plan.raDeg == nil)
    #expect(plan.maxAltitudeDeg == nil)
}

// MARK: - No site anywhere

@Test func plannerMarksEveryTargetAsNoCoordinateWhenSiteIsUnresolvable() throws {
    let fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }

    // Coordinate present, but no SITELAT/SITELONG anywhere and no
    // config.site -- there's nowhere to compute alt/az from.
    try fixture.addLight(target: "T_NoSite", extraCards: ["CRVAL1": "83.6", "CRVAL2": "22.0"])

    let plans = try Planner.plan(db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_NoSite" })
    #expect(plan.verdict == "nincs koordináta")
    #expect(plan.raDeg != nil) // the target's own coordinate WAS resolved
}

// MARK: - Low altitude

@Test func plannerMarksPermanentlyLowTargetAsAlacsony() throws {
    var fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }
    fixture.config.site = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)

    // dec = -80 at lat 47.5 never comes close to minAlt (max possible
    // altitude is 90 - |47.5 - (-80)| = -37.5, i.e. always below the
    // horizon).
    try fixture.addLight(target: "T_Low", extraCards: ["CRVAL1": "10.0", "CRVAL2": "-80.0"])

    let plans = try Planner.plan(db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_Low" })
    #expect(plan.verdict.hasPrefix("alacsony"))
    #expect((plan.maxAltitudeDeg ?? 100) < 30)
}

// MARK: - Culmination / max altitude for a good target

@Test func plannerComputesHighMaxAltitudeWhenDeclinationMatchesLatitude() throws {
    var fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }
    fixture.config.site = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)

    // dec == site latitude -> transits at zenith whenever the transit
    // falls inside the scanned night. RA picked so transit time (roughly
    // opposite the Sun in August) lands inside the night window.
    try fixture.addLight(target: "T_High", extraCards: ["CRVAL1": "350.0", "CRVAL2": "47.5"])

    let plans = try Planner.plan(date: utc(2026, 8, 10), db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_High" })
    #expect((plan.maxAltitudeDeg ?? 0) > 80)
    #expect(plan.culminationUTC != nil)
    #expect(plan.culminationLocal != nil)
    #expect(plan.verdict == "ma jó" || plan.verdict.hasPrefix("Hold zavar"))
}

// MARK: - Goal tag -> missing hours

@Test func plannerParsesGoalTagIntoGoalSeconds() throws {
    var fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }
    fixture.config.site = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)

    try fixture.addLight(target: "T_Goal", exptime: 3600, extraCards: ["CRVAL1": "350.0", "CRVAL2": "47.5"])
    try fixture.db.addTag(TagRecord(kind: "target", target: "T_Goal", sessionDate: nil, tag: "goal:6h"))

    let plans = try Planner.plan(date: utc(2026, 8, 10), db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_Goal" })
    #expect(plan.goalSeconds == 6.0 * 3600)
    #expect(plan.usableIntegrationSeconds == 3600)
}

@Test func plannerLeavesGoalSecondsNilWithoutGoalTag() throws {
    var fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }
    fixture.config.site = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)
    try fixture.addLight(target: "T_NoGoal", extraCards: ["CRVAL1": "350.0", "CRVAL2": "47.5"])

    let plans = try Planner.plan(date: utc(2026, 8, 10), db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_NoGoal" })
    #expect(plan.goalSeconds == nil)
}

@Test func plannerParsesGoalTagWithFractionalHoursLeniently() throws {
    var fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }
    fixture.config.site = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)
    try fixture.addLight(target: "T_GoalFrac", extraCards: ["CRVAL1": "350.0", "CRVAL2": "47.5"])
    try fixture.db.addTag(TagRecord(kind: "target", target: "T_GoalFrac", sessionDate: nil, tag: "goal:6.5h"))

    let plans = try Planner.plan(date: utc(2026, 8, 10), db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_GoalFrac" })
    #expect(plan.goalSeconds == 6.5 * 3600)
}

// MARK: - Site derivation from SITELAT/SITELONG when config.site is unset

@Test func plannerDerivesSiteFromLibraryHeadersWhenConfigSiteUnset() throws {
    let fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }
    // config.site left at defaults (nil, nil).

    try fixture.addLight(target: "T_DerivedSite", extraCards: [
        "CRVAL1": "350.0", "CRVAL2": "47.5", "SITELAT": "47.5", "SITELONG": "19.0",
    ])

    let plans = try Planner.plan(date: utc(2026, 8, 10), db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_DerivedSite" })
    #expect(plan.verdict != "nincs koordináta")
    #expect(plan.maxAltitudeDeg != nil)
}

// MARK: - Moon interference

/// Places the target's coordinate exactly at the Moon's own position for
/// the middle of the scanned night, near a (self-derived, see
/// `SunMoonTests`) full-moon date -- illumination is high and separation is
/// ~0, so the verdict must call out lunar interference regardless of the
/// exact wording's numbers.
@Test func plannerFlagsMoonInterferenceWhenTargetSitsNearAHighlyIlluminatedMoon() throws {
    var fixture = try PlannerFixture.make()
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

    // minAltitudeDeg relaxed to 10: the Moon's declination this particular
    // night keeps its max altitude at this latitude only modestly above
    // the horizon (see PlannerTests' derivation notes) -- this test is
    // about the Moon verdict, not the altitude gate.
    let plans = try Planner.plan(date: referenceDate, minAltitudeDeg: 10, db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_MoonNear" })
    #expect(plan.verdict.hasPrefix("Hold zavar"), "verdict=\(plan.verdict) illum=\(plan.moonIlluminationPercent ?? -1) sep=\(plan.moonSeparationDeg ?? -1) maxAlt=\(plan.maxAltitudeDeg ?? -1)")
    #expect((plan.moonIlluminationPercent ?? 0) > 60)
    #expect((plan.moonSeparationDeg ?? 999) < 40)
}

// MARK: - Sorting

@Test func plannerSortsDescendingByScore() throws {
    var fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }
    fixture.config.site = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)

    // Good visibility, big remaining need.
    try fixture.addLight(target: "T_NeedsMore", exptime: 60, extraCards: ["CRVAL1": "350.0", "CRVAL2": "47.5"])
    try fixture.db.addTag(TagRecord(kind: "target", target: "T_NeedsMore", sessionDate: nil, tag: "goal:20h"))

    // No coordinate at all -> score 0, must sort last.
    try fixture.addLight(target: "T_Unreachable", extraCards: [:])

    let plans = try Planner.plan(date: utc(2026, 8, 10), db: fixture.db, config: fixture.config)
    let needsMoreIndex = try #require(plans.firstIndex { $0.target == "T_NeedsMore" })
    let unreachableIndex = try #require(plans.firstIndex { $0.target == "T_Unreachable" })
    #expect(needsMoreIndex < unreachableIndex)
    #expect(plans[unreachableIndex].score == 0)

    for i in 1..<plans.count {
        #expect(plans[i - 1].score >= plans[i].score)
    }
}
