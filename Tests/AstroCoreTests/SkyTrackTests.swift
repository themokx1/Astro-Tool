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

/// Parses `Planner`'s own `culminationUTC` ISO format (its private
/// `isoString(_:)` -- `"yyyy-MM-dd'T'HH:mm:ss'Z'"`, UTC) so the culmination
/// cross-check test can compare it against a `SkyTrackPoint.time`.
private func parseISO(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.date(from: string)!
}

/// Same fixture shape as `PlannerTests`' own `PlannerFixture` -- a fresh
/// sqlite-backed `Database` with a helper to insert one session light
/// directly (bypassing the scanner entirely), needed only for the
/// `Planner.plan` culmination cross-check test below.
private struct SkyTrackFixture {
    let dbDir: URL
    let db: Database
    var config = AstroConfig()

    static func make() throws -> SkyTrackFixture {
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-skytrack-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        return SkyTrackFixture(dbDir: dbDir, db: db)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbDir)
    }

    @discardableResult
    func addLight(target: String, date: String = "2026-01-15", extraCards: [String: String] = [:]) throws -> Int64 {
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

// MARK: - Mid-latitude winter night: non-empty track, culmination cross-check, marker order

/// Budapest, mid-January -- comfortably has real astronomical night, so both
/// `astroDuskUTC`/`astroDawnUTC` AND the wider nautical pair should resolve.
/// RA is derived (not a magic number) so the target's transit lands right at
/// local midnight regardless of the exact date's sidereal-time offset: hour
/// angle == 0 at transit means RA == LST at that instant.
@Test func altitudeTrackPeakMatchesPlannerCulminationAtMidLatitudeWinterNight() throws {
    let lat = 47.5, lon = 19.04
    let referenceDate = utc(2026, 1, 15)
    let timeZone = TimeZone(identifier: "Europe/Budapest")!

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    // "Night of referenceDate" spans local noon(referenceDate) to local
    // noon(referenceDate + 1) (same windowing `SunMoon.astronomicalTwilight`
    // uses) -- the midnight INSIDE that span is startOfDay + 24h, not + 12h
    // (which would land on local noon of referenceDate itself).
    let localMidnight = calendar.date(byAdding: .hour, value: 24, to: calendar.startOfDay(for: referenceDate))!
    let midnightJD = JulianDate.julianDay(localMidnight)
    let raDeg = SiderealTime.lstHours(julianDay: midnightJD, longitudeDeg: lon) * 15.0
    let decDeg = lat // dec == lat -> transits near zenith, comfortably above any altitude gate

    let track = SkyTrack.altitudeTrack(raDeg: raDeg, decDeg: decDeg, nightOf: referenceDate, latDeg: lat, lonDeg: lon)
    #expect(!track.isEmpty)

    let peak = try #require(track.max(by: { $0.altitudeDeg < $1.altitudeDeg }))
    #expect(peak.altitudeDeg > 80, "expected a near-zenith transit, got \(peak.altitudeDeg)")

    // Cross-check against Planner.plan's own culmination for the identical
    // target/site/date -- the DB-backed path this new API must not silently
    // diverge from.
    var fixture = try SkyTrackFixture.make()
    defer { fixture.cleanup() }
    fixture.config.site = SiteRule(latitudeDeg: lat, longitudeDeg: lon)
    try fixture.addLight(target: "T_SkyTrack", extraCards: ["CRVAL1": "\(raDeg)", "CRVAL2": "\(decDeg)"])

    let plans = try Planner.plan(date: referenceDate, db: fixture.db, config: fixture.config)
    let plan = try #require(plans.first { $0.target == "T_SkyTrack" })
    let culminationUTC = try #require(plan.culminationUTC)
    let culmination = parseISO(culminationUTC)

    let diff = abs(peak.time.timeIntervalSince(culmination))
    #expect(diff < 10 * 60, "track peak at \(peak.time) vs Planner culmination \(culmination), diff=\(diff)s")

    // Night window markers: real astronomical night at 47.5N in mid-January
    // -> both pairs resolve, dusk strictly before dawn.
    let markers = SkyTrack.nightWindowMarkers(nightOf: referenceDate, latDeg: lat, lonDeg: lon)
    let astroDusk = try #require(markers.astroDuskUTC)
    let astroDawn = try #require(markers.astroDawnUTC)
    #expect(astroDusk < astroDawn)
    let nauticalDusk = try #require(markers.nauticalDuskUTC)
    let nauticalDawn = try #require(markers.nauticalDawnUTC)
    #expect(nauticalDusk < nauticalDawn)

    // The track's own window is sized to the WIDER nautical bound (+/- 1h),
    // so it must start at/before astronomical dusk and end at/after
    // astronomical dawn -- never narrower than the astro-night shading.
    #expect(track.first!.time <= astroDusk)
    #expect(track.last!.time >= astroDawn)
}

// MARK: - Moon track: range-bounded and matches a direct AltAz computation

@Test func moonAltitudeTrackStaysInRangeAndMatchesDirectComputation() throws {
    let lat = 47.5, lon = 19.04
    let referenceDate = utc(2026, 1, 15)

    let track = SkyTrack.moonAltitudeTrack(nightOf: referenceDate, latDeg: lat, lonDeg: lon)
    #expect(!track.isEmpty)

    for point in track {
        #expect(point.altitudeDeg >= -90 && point.altitudeDeg <= 90)

        // Recompute independently via the same primitives `SunMoon`/`AltAz`
        // expose -- must match to within floating-point noise, since it's
        // the identical formula chain evaluated at the identical instant.
        let jd = JulianDate.julianDay(point.time)
        let moon = SunMoon.moonPosition(julianDay: jd)
        let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: lon)
        let expectedAlt = AltAz.position(raDeg: moon.raDeg, decDeg: moon.decDeg, lstHours: lst, latDeg: lat).altitudeDeg
        #expect(abs(point.altitudeDeg - expectedAlt) < 1.0, "at \(point.time): track=\(point.altitudeDeg) direct=\(expectedAlt)")
    }
}

// MARK: - White night: astro markers nil, track still usable

/// 60N at the June solstice: the Sun's lower culmination (local midnight)
/// altitude is only a few degrees below the horizon there -- astronomical
/// (-18 deg) twilight never happens, and depending on exactly how deep,
/// nautical (-12 deg) may not either. Either way `nightWindowMarkers` must
/// report the astro pair as `nil`, and both tracks must still return a
/// non-empty, usable series (nautical-bounded or clamped-noon-to-noon --
/// whichever the sweep resolves to).
@Test func whiteNightAtHighSummerLatitudeLeavesAstroMarkersNilButStillProducesTracks() throws {
    let lat = 60.0, lon = 19.0
    let referenceDate = utc(2026, 6, 21)

    let markers = SkyTrack.nightWindowMarkers(nightOf: referenceDate, latDeg: lat, lonDeg: lon)
    #expect(markers.astroDuskUTC == nil)
    #expect(markers.astroDawnUTC == nil)
    // Nautical crossings are found on the exact same sweep the astro ones
    // are checked against -- dusk/dawn must resolve together or not at all.
    #expect((markers.nauticalDuskUTC == nil) == (markers.nauticalDawnUTC == nil))
    if let nauticalDusk = markers.nauticalDuskUTC, let nauticalDawn = markers.nauticalDawnUTC {
        #expect(nauticalDusk < nauticalDawn)
    }

    let altTrack = SkyTrack.altitudeTrack(raDeg: 180, decDeg: 40, nightOf: referenceDate, latDeg: lat, lonDeg: lon)
    #expect(!altTrack.isEmpty)
    let moonTrack = SkyTrack.moonAltitudeTrack(nightOf: referenceDate, latDeg: lat, lonDeg: lon)
    #expect(!moonTrack.isEmpty)
}

// MARK: - stepMinutes respected

/// Budapest winter night again (a well-understood, nautically-bounded
/// window) -- the sample count should match `windowSeconds / stepSeconds`
/// (+1 for the inclusive endpoints) within a couple of samples, for a few
/// different `stepMinutes` values.
@Test func altitudeTrackSampleCountMatchesRequestedStepMinutes() throws {
    let lat = 47.5, lon = 19.04
    let referenceDate = utc(2026, 1, 15)

    let markers = SkyTrack.nightWindowMarkers(nightOf: referenceDate, latDeg: lat, lonDeg: lon)
    let nauticalDusk = try #require(markers.nauticalDuskUTC)
    let nauticalDawn = try #require(markers.nauticalDawnUTC)
    let windowSeconds = (nauticalDawn.addingTimeInterval(3600)).timeIntervalSince(nauticalDusk.addingTimeInterval(-3600))

    for stepMinutes in [1, 5, 10, 30] {
        let track = SkyTrack.altitudeTrack(raDeg: 45, decDeg: 20, nightOf: referenceDate, latDeg: lat, lonDeg: lon, stepMinutes: stepMinutes)
        let expectedCount = Int(windowSeconds / Double(stepMinutes * 60)) + 1
        #expect(abs(track.count - expectedCount) <= 2, "stepMinutes=\(stepMinutes): got \(track.count), expected ~\(expectedCount)")
    }
}
