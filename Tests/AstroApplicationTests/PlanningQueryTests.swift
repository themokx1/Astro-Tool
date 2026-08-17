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

        // V2 UI/UX audit (2026-08-15) section 4, and the follow-up
        // localization plan's Task 2: `skyVerdict` is a structured
        // `SkyVerdictKind` (not a pre-built Hungarian sentence), so `.english`
        // is what PlanningView renders and a future locale renderer builds
        // its own sentence from these same numbers instead of re-parsing text.
        // The altitude is rounded to a whole degree by the time it reaches
        // the Hungarian sentence this parses (`SkyVerdict.tooLow`'s own
        // `%.0f`), so the structured value carries that same rounded number,
        // not `maxAltitudeDeg`'s full precision.
        #expect(ngc7000.skyVerdict == .goodTonight)
        #expect(ic1396.skyVerdict == .goodTonight)
        #expect(m42.skyVerdict == .lowAltitude(maxDeg: m42Alt.rounded()))
        #expect(ic434.skyVerdict == .lowAltitude(maxDeg: ic434Alt.rounded()))
    }

    @Test("Every recommendation's structured verdict is a known kind, never the unrecognized fallback")
    func everySkyVerdictParsesIntoAKnownKind() {
        let result = PlanningQuery.fixture(focalLength: 200, site: budapest, date: utc(2026, 8, 15))
            .recommendations()
        #expect(!result.isEmpty)
        for recommendation in result {
            if case .unrecognized(let raw) = recommendation.skyVerdict {
                Issue.record("\(recommendation.target.designation) produced an unrecognized verdict: \(raw)")
            }
        }
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

    // Most LBN/vdB/Sh2 entries carry no magnitude at all, so there is nothing
    // to estimate from. Substituting the reference surface brightness makes
    // the model hand back its own input: every one of those targets printed
    // "≈ 10,0 h — Fallback", which reads as an estimate but is just the
    // configured baseline echoed back. Same dishonesty as the four-digit
    // figures above, from the other direction.
    @Test("A target with no brightness data reports no estimate instead of echoing the reference hours")
    func targetWithoutBrightnessDataHasNoEstimate() {
        let noPhotometry = CatalogTarget(
            designation: "LBN 437", commonNameHU: nil,
            raDeg: 338.051, decDeg: 40.591, kind: .emissionNebula,
            sizeArcmin: nil, magnitude: nil
        )

        let estimate = PlanningQuery.integrationEstimate(
            target: noPhotometry, focalRatio: 5, systemEfficiency: 1,
            referenceHours: IntegrationTimeModel.referenceHours,
            referenceFocalRatio: 5, referenceSurfaceBrightness: IntegrationTimeModel.referenceSurfaceBrightness
        )

        #expect(estimate.hours == nil, "the reference baseline is an input, not an estimate")
        #expect(estimate.confidence == .fallback)
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

    // MARK: - Task W4-5: integration estimate vs. the bounds of the night
    //
    // Owner's bug report, 2026-08-17, Hungary: NGC 7000 showed "≈ 27,9 ó /
    // Becsült" right next to "6,1 óra látható" and the owner read this as
    // the integration estimate ignoring the night's bounds ("azt nézi
    // csak, mikor van fent a célpont, azt nem, hogy mettől meddig van
    // éjszaka"). Investigation: `IntegrationTimeModel.hours` never consults
    // time-of-night at all -- it is a pure photometric ratio against the
    // reference target (see its own doc comment), so it is a MULTI-NIGHT
    // total exposure budget, not a "tonight" figure, and `visibleHours`
    // (which feeds `photographableFactor`/`planningScore` already) is
    // already correctly bounded to astronomical night via
    // `DiscoveryPlanner.discover` -> `NightSweep.sweep` ->
    // `SunMoon.astronomicalTwilight`. There was no duplicate/broken
    // visibility predicate to converge; the actual gap was nothing tying
    // the two numbers together, which `integrationNightsAtTonightsPace`
    // fixes.

    @Test("Integration hours is a multi-night total; nights-needed divides it by tonight's own night-bounded visible hours, and the two stay exactly consistent")
    func integrationNightsUsesNightBoundedVisibleHours() throws {
        let ngc7000 = try #require(
            PlanningQuery.fixture(focalLength: 200, site: budapest, date: utc(2026, 8, 17))
                .recommendations()
                .first { $0.target.designation == "NGC 7000" }
        )

        let hours = try #require(ngc7000.integrationHours)
        let visible = try #require(ngc7000.visibleHours)
        let nights = try #require(ngc7000.integrationNightsAtTonightsPace)

        // `visibleHours` must already be tonight-bounded (astronomical
        // darkness is well under 24h at this latitude in August), and the
        // owner's own report puts it near 6.1h.
        #expect(visible > 0 && visible < 12, "tonight's visible hours must be bounded by astronomical darkness, not a full day")
        #expect(abs(visible - 6.1) < 1.0, "should land near the owner's own observed ~6.1h visible figure")

        // The identity that makes the new field trustworthy: nights * per-
        // night pace reconstructs the original total exactly.
        #expect(abs(nights * visible - hours) < 0.01)
        #expect(nights > 1, "NGC 7000's estimated total at this setup should take more than a single night")
    }

    @Test("A target below the altitude threshold all night has zero, not negative, visible hours -- and no nights-needed figure to divide by")
    func belowThresholdAllNightYieldsNoNightsFigure() throws {
        let result = PlanningQuery.fixture(focalLength: 200, site: budapest, date: utc(2026, 8, 15)).recommendations()
        let ic434 = try #require(result.first { $0.target.designation == "IC 434" })

        let visible = try #require(ic434.visibleHours)
        #expect(visible >= 0, "usable hours must never go negative")
        #expect(visible < 1, "a target that never clears the altitude threshold tonight should show effectively zero usable hours")
        #expect(ic434.integrationNightsAtTonightsPace == nil, "nights-needed is undefined with nothing usable to divide by")
    }

    @Test("A site/date with no astronomical night at all (high-latitude white night) yields an honest nil, not a divide-by-zero or full-day figure")
    func noAstronomicalNightYieldsNoNightsFigure() throws {
        // Same white-night fixture `Tests/AstroCoreTests/DiscoveryPlannerTests.swift`
        // and `Tests/AstroUITests/HomeStoreTests.swift` use: 65N never reaches
        // even nautical twilight in mid-June.
        let whiteNightSite = SiteRule(latitudeDeg: 65.0, longitudeDeg: 19.0)
        let result = PlanningQuery.fixture(focalLength: 200, site: whiteNightSite, date: utc(2026, 6, 21)).recommendations()

        let ngc7000 = try #require(result.first { $0.target.designation == "NGC 7000" })
        #expect(ngc7000.visibleHours == nil)
        #expect(ngc7000.integrationNightsAtTonightsPace == nil, "no dark window at all means no honest nights-needed figure, not a huge or negative one")
    }
}
