@testable import AstroApplication
import AstroCore
import Foundation
import Testing

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute
    return calendar.date(from: comps)!
}

/// Same Budapest fixture `Tests/AstroCoreTests/DiscoveryPlannerTests.swift`
/// uses -- ~47.5N/19E is the latitude the user's own ground-truth CLI run
/// (see the bug report this file's anchor test pins) was taken from.
private let budapest = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)

struct PlanningQueryTests {
    @Test("Tiny objects rank behind composition-sized targets at 200 mm, among tonight's actually-visible targets")
    func tinyObjectsRankBehindUsefulCompositions() {
        let result = PlanningQuery.fixture(focalLength: 200, site: budapest, date: utc(2026, 8, 4))
            .recommendations()
            .filter { !$0.isLowAltitude }

        #expect(result.first?.frameCoverage ?? 0 > result.last?.frameCoverage ?? 0)
        #expect(result.last?.fit == .tooSmall)
        #expect(result.first?.compositionScore ?? 0 > result.last?.compositionScore ?? 0)
    }

    @Test("Planning exposes honest source and confidence for goal time")
    func recommendationExplainsItsEstimate() throws {
        // M 57 (Ring Nebula) -- small and bright enough that its estimated
        // surface brightness stays comfortably inside
        // `IntegrationTimeModel.maxPlausibleHours`, unlike the large,
        // faint-extended targets Task 2's tests below are about.
        let ring = try #require(
            PlanningQuery.fixture(focalLength: 200, site: budapest, date: utc(2026, 8, 4))
                .recommendations()
                .first { $0.target.designation == "M 57" }
        )

        let hours = try #require(ring.integrationHours)
        #expect(hours > 0)
        #expect(!ring.integrationSource.isEmpty)
        #expect(ring.integrationConfidence != .unknown)
    }

    @Test("No resolved site means no invented ranking")
    func noSiteMeansNoRanking() {
        let result = PlanningQuery.fixture(focalLength: 200).recommendations()
        #expect(result.isEmpty)
    }

    // MARK: - Anchor test: 2026-08-15, Budapest -- the user's own bug report
    //
    // Ground truth, `astrotool plan --root /Volumes/images/Astro` against
    // the user's real library, same night: IC 1396 (max alt 78 deg) and
    // NGC 7000 (max alt 88 deg) are "ma jó"; M 42 (max alt 7 deg) and
    // NGC 2237 (max alt 5 deg) are "alacsony" -- deep in evening/dawn
    // twilight, Orion and Monoceros barely clear the horizon in mid-August.
    // The Planning page listed IC 434 (in the same low patch of sky as M 42)
    // as "Good framing, ~4.4 h" -- exactly the bug this file's rebuild of
    // `PlanningQuery` fixes: ranking must come from the same sky engine
    // (`DiscoveryPlanner.discover`) the CLI itself uses, not from framing
    // fit alone.

    @Test("2026-08-15 from Budapest: Orion-region targets are demoted as low-altitude while northern nebulae rank as good, ahead of them")
    func groundTruthAugust15FromBudapest() throws {
        let result = PlanningQuery.fixture(focalLength: 200, site: budapest, date: utc(2026, 8, 15))
            .recommendations()
        let byDesignation = Dictionary(uniqueKeysWithValues: result.map { ($0.target.designation, $0) })

        let ic434 = try #require(byDesignation["IC 434"])
        let m42 = try #require(byDesignation["M 42"])
        let ngc7000 = try #require(byDesignation["NGC 7000"])
        let ic1396 = try #require(byDesignation["IC 1396"])

        let ic434Alt: Double = ic434.maxAltitudeDeg ?? -1
        let m42Alt: Double = m42.maxAltitudeDeg ?? -1
        let ngc7000Alt: Double = ngc7000.maxAltitudeDeg ?? -1
        let ic1396Alt: Double = ic1396.maxAltitudeDeg ?? -1
        #expect(ic434.isLowAltitude, "IC 434 max alt \(ic434Alt) should be below the imaging threshold in mid-August")
        #expect(m42.isLowAltitude, "M 42 max alt \(m42Alt) should be below the imaging threshold in mid-August")
        #expect(!ngc7000.isLowAltitude, "NGC 7000 max alt \(ngc7000Alt) should clear the imaging threshold")
        #expect(!ic1396.isLowAltitude, "IC 1396 max alt \(ic1396Alt) should clear the imaging threshold")

        let ic434Index = try #require(result.firstIndex { $0.target.designation == "IC 434" })
        let m42Index = try #require(result.firstIndex { $0.target.designation == "M 42" })
        let ngc7000Index = try #require(result.firstIndex { $0.target.designation == "NGC 7000" })
        let ic1396Index = try #require(result.firstIndex { $0.target.designation == "IC 1396" })

        #expect(ngc7000Index < ic434Index, "a genuinely well-placed target must rank ahead of a low-altitude one regardless of framing")
        #expect(ngc7000Index < m42Index)
        #expect(ic1396Index < ic434Index)
        #expect(ic1396Index < m42Index)
    }

    // MARK: - Task 2: honest integration estimates

    @Test("A large, faint extended target (the Pelican Nebula's shape) is reported as beyond the model's range, not a precise four-digit hour count")
    func largeFaintExtendedTargetIsBeyondModelRange() {
        let pelicanShaped = CatalogTarget(
            designation: "TEST Large Faint Nebula", commonNameHU: nil,
            raDeg: 0, decDeg: 0, kind: .emissionNebula, sizeArcmin: 60, magnitude: 8.0
        )

        let estimate = PlanningQuery.integrationEstimate(
            target: pelicanShaped, focalRatio: 5, systemEfficiency: 1,
            referenceHours: IntegrationTimeModel.referenceHours,
            referenceFocalRatio: 5, referenceSurfaceBrightness: IntegrationTimeModel.referenceSurfaceBrightness
        )

        #expect(estimate.hours == nil, "must not print a precise hour figure beyond the model's validity range")
        #expect(estimate.confidence == .unknown)
        #expect(!estimate.source.isEmpty)
    }

    @Test("A normal-sized target still produces a sane, precise estimate")
    func normalTargetStaysWithinModelRange() throws {
        let normal = CatalogTarget(
            designation: "TEST Normal Nebula", commonNameHU: nil,
            raDeg: 0, decDeg: 0, kind: .emissionNebula, sizeArcmin: 12, magnitude: 7.0
        )

        let estimate = PlanningQuery.integrationEstimate(
            target: normal, focalRatio: 5, systemEfficiency: 1,
            referenceHours: IntegrationTimeModel.referenceHours,
            referenceFocalRatio: 5, referenceSurfaceBrightness: IntegrationTimeModel.referenceSurfaceBrightness
        )

        let hours = try #require(estimate.hours)
        #expect(hours > 0)
        #expect(hours <= IntegrationTimeModel.maxPlausibleHours)
        #expect(estimate.confidence != .unknown)
    }
}
