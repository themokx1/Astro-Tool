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

// MARK: - Comet verdict (session-derived coordinate is stale by "tonight")

/// A comet folder's coordinate comes from whenever those frames were shot
/// (possibly months ago) -- `plan` must never compute a real altitude/Moon
/// "ma jó" verdict from it, regardless of how favorably it would otherwise
/// place relative to the site/night.
@Test func plannerGivesCometAnHonestStaleCoordinateVerdictInsteadOfMaJo() throws {
    var fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }
    fixture.config.site = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)

    // Same "transits at zenith" coordinate as the high-altitude test above
    // -- would otherwise score well and read "ma jó".
    try fixture.addLight(target: "C2025_R3_Panstarrs", extraCards: ["CRVAL1": "350.0", "CRVAL2": "47.5"])

    let plans = try Planner.plan(date: utc(2026, 8, 10), db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "C2025_R3_Panstarrs" })
    #expect(plan.verdict == "üstökös — a tárolt koordináta a felvétel idejéből való, ma már nem érvényes")
    #expect(plan.score == 0)
    #expect(plan.culminationUTC == nil)
    #expect(plan.visibleHours == nil)
    #expect(plan.moonSeparationDeg == nil)
}

// MARK: - Duplicate displayName disambiguation

/// The comet's normal and `_Wide` folder variants both resolve to the same
/// `"C/2025 R3"` designation -- indistinguishable in the plan table/"Ma
/// este" box unless `plan` disambiguates their `displayName`s itself.
@Test func plannerDisambiguatesCollidingDisplayNamesWithFolderSuffix() throws {
    let fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLight(target: "C2025_R3_Panstarrs", extraCards: [:])
    try fixture.addLight(target: "C2025_R3_Panstarrs_Wide", extraCards: [:])

    let plans = try Planner.plan(db: fixture.db, config: fixture.config)
    let plain = try #require(plans.first { $0.target == "C2025_R3_Panstarrs" })
    let wide = try #require(plans.first { $0.target == "C2025_R3_Panstarrs_Wide" })

    #expect(plain.displayName != wide.displayName)
    #expect(plain.displayName == "C/2025 R3 (Panstarrs)")
    #expect(wide.displayName == "C/2025 R3 (Panstarrs_Wide)")
}

/// Targets whose displayNames don't collide must come back unchanged --
/// the dedup post-pass is a no-op outside an actual collision.
@Test func plannerLeavesNonCollidingDisplayNamesUnchanged() throws {
    let fixture = try PlannerFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLight(target: "M42_Orion_wide_field", extraCards: [:])
    try fixture.addLight(target: "NGC_7000_North_American_Nebula", extraCards: [:])

    let plans = try Planner.plan(db: fixture.db, config: fixture.config)
    let m42 = try #require(plans.first { $0.target == "M42_Orion_wide_field" })
    let ngc7000 = try #require(plans.first { $0.target == "NGC_7000_North_American_Nebula" })

    #expect(m42.displayName == "M 42 · Orion-köd")
    #expect(ngc7000.displayName == "NGC 7000 · Észak-Amerika-köd")
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

// MARK: - R9-T4: nightInfo (dark hours / Moon rise-set for the "Ma este" tiles)

@Test func nightInfoReportsNilDarkHoursAndNoMoonEventWithoutASite() throws {
    let info = Planner.nightInfo(date: utc(2026, 8, 10), site: SiteRule())
    #expect(info.darkHours == nil)
    #expect(info.note != nil)
    #expect(info.moonEventLabel == nil)
    #expect(info.moonIlluminationPercent >= 0 && info.moonIlluminationPercent <= 100)
}

@Test func nightInfoComputesPlausibleDarkHoursAndAMoonEventLabelForAResolvedSite() throws {
    let site = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)
    let info = Planner.nightInfo(date: utc(2026, 8, 10), site: site)

    // Mid-August at 47.5N reaches real astronomical twilight -- a plausible
    // multi-hour dark window, not the nautical-fallback/white-night `nil`.
    let darkHours = try #require(info.darkHours)
    #expect(darkHours > 0 && darkHours < 12)
    #expect(info.note == nil)

    // Exactly one of the four documented shapes, regardless of the exact
    // rise/set time (which depends on the Moon's phase on this date).
    let label = try #require(info.moonEventLabel)
    let isRiseOrSet = label.hasPrefix("felkel ") || label.hasPrefix("nyugszik ")
    let isAllNight = label == "egész éjjel fent" || label == "egész éjjel lent"
    #expect(isRiseOrSet || isAllNight, "unexpected moonEventLabel: \(label)")
}

@Test func nightInfoFallsBackToNilDarkHoursInHighSummerWhiteNights() throws {
    // 65N in mid-June: the Sun never reaches -18° (often not even -12°) --
    // `astroDarkHours` must come back `nil` with an explanatory note, same
    // "fehér éjszaka" fallback `NightSummary`/`plan` already document.
    let site = SiteRule(latitudeDeg: 65.0, longitudeDeg: 19.0)
    let info = Planner.nightInfo(date: utc(2026, 6, 21), site: site)
    #expect(info.darkHours == nil)
    #expect(info.note != nil)
}
