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

private let budapest = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)

// MARK: - Winter Budapest night: M42 discoverable with a sane verdict

@Test func discoverFindsM42WellPlacedOnAWinterBudapestNightWithASaneVerdict() throws {
    let rows = DiscoveryPlanner.discover(date: utc(2026, 12, 15), site: budapest)
    let m42 = try #require(rows.first { $0.target.designation == "M 42" })

    #expect((m42.maxAltitudeDeg ?? 0) > 30)
    #expect((m42.visibleHours ?? 0) > 1)
    #expect(m42.culminationLocal != nil)
    // Moon phase varies by date and isn't what this test is about -- either
    // "genuinely good" or "good but for the Moon" is a sane outcome, same
    // acceptance PlannerTests itself uses for its analogous high-altitude case.
    #expect(m42.verdict == "ma jó" || m42.verdict.hasPrefix("Hold zavar"), "unexpected verdict: \(m42.verdict)")
    #expect(m42.score > 0)
}

// MARK: - Far-southern object gets a low max altitude regardless of the night

@Test func discoverGivesLowMaxAltitudeForAFarSouthernObjectFromABudapestLatitude() throws {
    // M 7 (Ptolemy Cluster, dec ~-34.79) plays the same role the task's own
    // example (NGC 253, dec ~-25) does: from 47.5N, a steeply southern
    // object's geometric culmination cap is `90 - |lat - dec|` regardless of
    // which night you pick -- here ~7.7 deg, nowhere near a usable altitude.
    // Checking the sampled max against that theoretical cap (rather than a
    // fixed empirical number for one specific date) keeps this test valid
    // for any date, since a night's sampled max can only be <= the true cap.
    let rows = DiscoveryPlanner.discover(date: utc(2026, 8, 4), site: budapest)
    let m7 = try #require(rows.first { $0.target.designation == "M 7" })

    let theoreticalCapDeg = 90 - abs(47.5 - (-34.793))
    let maxAlt = try #require(m7.maxAltitudeDeg)
    #expect(maxAlt <= theoreticalCapDeg + 0.5, "maxAlt=\(maxAlt) exceeds theoretical cap \(theoreticalCapDeg)")
    #expect(maxAlt < 30)
    #expect(m7.verdict.hasPrefix("alacsony"), "unexpected verdict: \(m7.verdict)")
}

// MARK: - alreadyInLibrary flag honored (flagged, not filtered)

@Test func discoverFlagsAlreadyInLibraryWhenDesignationMatchesWithoutFilteringAnythingOut() throws {
    let rows = DiscoveryPlanner.discover(date: utc(2026, 12, 15), site: budapest, existingDesignations: ["M 42"])
    let m42 = try #require(rows.first { $0.target.designation == "M 42" })
    let m31 = try #require(rows.first { $0.target.designation == "M 31" })

    #expect(m42.alreadyInLibrary == true)
    #expect(m31.alreadyInLibrary == false)
    #expect(rows.count == TargetCatalog.all.count, "alreadyInLibrary must flag rows, never filter them out")
}

@Test func existingDesignationsMapsLibraryTargetStatsToResolvedCatalogDesignations() {
    func stats(target: String) -> TargetStats {
        TargetStats(
            target: target, isWideField: true, totalIntegrationSeconds: 3600,
            sessionDates: [], exposureBreakdown: [:], lastSessionDate: nil, cameras: [], filters: []
        )
    }
    let designations = DiscoveryPlanner.existingDesignations(stats: [
        stats(target: "M42_Orion_wide_field"),
        stats(target: "NGC_7000_North_American_Nebula"),
        // No recognizable catalog designation at all -- contributes nothing.
        stats(target: "My_Backyard_Panorama"),
    ])
    #expect(designations == ["M 42", "NGC 7000"])
}

// MARK: - FOV fit labels: small vs. huge object against a 2x1.3 deg FOV

@Test func fovFitLabelsDiscriminateASmallObjectFromAHugeOneAgainstTheSameFOV() throws {
    let rows = DiscoveryPlanner.discover(date: utc(2026, 8, 4), site: budapest, setupFOVDeg: (width: 2.0, height: 1.3))

    // M 57 (Ring Nebula, ~3.8' major axis) sits comfortably inside a
    // 2x1.3 deg (120' x 78') frame; M 31 (Andromeda, ~190' major axis) is
    // bigger than even the LONG side of that same frame, so the two real
    // objects land on clearly different labels.
    let m57 = try #require(rows.first { $0.target.designation == "M 57" })
    let m31 = try #require(rows.first { $0.target.designation == "M 31" })
    #expect(m57.fovFitLabel == "befér", "M57 size=\(m57.target.sizeArcmin ?? -1)")
    #expect(m31.fovFitLabel == "mozaik kellene", "M31 size=\(m31.target.sizeArcmin ?? -1)")
}

@Test func fovFitLabelFlagsAnObjectTooSmallForTheFrame() {
    // The third label needs an object under 3% of the frame's SHORT
    // dimension (78' x 3% = 2.34') -- no Messier object is quite that tiny
    // against this particular FOV, so this exercises the (internal, same-
    // module) helper directly with a synthetic size rather than hunting for
    // a real catalog entry small enough.
    let label = DiscoveryPlanner.fovFitLabel(sizeArcmin: 1.0, setupFOVDeg: (width: 2.0, height: 1.3))
    #expect(label == "túl kicsi a képmezőhöz")
}

@Test func fovFitLabelIsNilWithoutAKnownSizeOrAKnownFOV() {
    #expect(DiscoveryPlanner.fovFitLabel(sizeArcmin: nil, setupFOVDeg: (width: 2.0, height: 1.3)) == nil)
    #expect(DiscoveryPlanner.fovFitLabel(sizeArcmin: 10.0, setupFOVDeg: nil) == nil)
}

@Test func discoverLeavesFovFitLabelNilForEveryRowWhenNoSetupFOVIsSupplied() {
    let rows = DiscoveryPlanner.discover(date: utc(2026, 12, 15), site: budapest)
    #expect(rows.allSatisfy { $0.fovFitLabel == nil })
}

// MARK: - Moon interference verdict shape matches Planner's vocabulary

@Test func discoverProducesAMoonInterferenceVerdictInPlannersOwnVocabularyForARealAlignment() throws {
    // 2026-08-04 at this site: the Moon (computed via the exact same
    // `SunMoon`/`NightSweep.midnightMoon` primitives `Planner.plan` itself
    // uses) sits ~0.9 deg from M 74 and is ~63% illuminated -- both sides of
    // the "Hold zavar" gate (separation < 40 deg AND illumination > 60%).
    let rows = DiscoveryPlanner.discover(date: utc(2026, 8, 4), site: budapest)
    let m74 = try #require(rows.first { $0.target.designation == "M 74" })

    #expect(m74.verdict.hasPrefix("Hold zavar"), "unexpected verdict: \(m74.verdict)")
    #expect((m74.moonSeparationDeg ?? 999) < 40)
    #expect((m74.visibleHours ?? 0) > 0.5, "must clear the visibility gate for the Moon verdict to even be reachable")
    #expect(m74.score < 0.5, "the 0.2x moon penalty should have suppressed the score well below a clean, unpenalized row")
}

// MARK: - No resolvable site / no dark window -- same fallback shape as Planner

@Test func discoverGivesEveryRowNoCoordinateVerdictAndZeroScoreWithoutAResolvableSite() {
    let rows = DiscoveryPlanner.discover(date: utc(2026, 8, 4), site: SiteRule())

    #expect(rows.count == TargetCatalog.all.count)
    #expect(rows.allSatisfy { $0.verdict == "nincs koordináta" })
    #expect(rows.allSatisfy { $0.score == 0 })
    #expect(rows.allSatisfy { $0.maxAltitudeDeg == nil && $0.visibleHours == nil && $0.moonSeparationDeg == nil })
}

@Test func discoverGivesEveryRowNoCoordinateVerdictInHighSummerWhiteNights() {
    // Same "fehér éjszaka" condition `Planner`/`NightSummary`/`NightInfo`
    // all document: 65N in mid-June never reaches even nautical twilight.
    let site = SiteRule(latitudeDeg: 65.0, longitudeDeg: 19.0)
    let rows = DiscoveryPlanner.discover(date: utc(2026, 6, 21), site: site)

    #expect(rows.allSatisfy { $0.verdict == "nincs koordináta" })
    #expect(rows.allSatisfy { $0.score == 0 })
}

// MARK: - Sorting

@Test func discoverSortsRowsByScoreDescending() {
    let rows = DiscoveryPlanner.discover(date: utc(2026, 12, 15), site: budapest)
    #expect(rows.count == TargetCatalog.all.count)
    for i in 1..<rows.count {
        #expect(rows[i - 1].score >= rows[i].score)
    }
}
