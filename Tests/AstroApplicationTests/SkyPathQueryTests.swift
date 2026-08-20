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

/// Same Budapest fixture `PlanningQueryTests`/`DiscoveryPlannerTests` use.
private let budapest = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)
private let fixedNight = utc(2026, 8, 15)

struct SkyPathQueryTests {
    @Test("Samples span dusk to dawn and the peak matches DiscoveryPlanner's own max altitude for the same target/night")
    func samplesSpanTheDarkWindowAndAgreeWithDiscoveryPlanner() throws {
        let target = try #require(TargetCatalog.all.first { $0.designation == "M 31" })

        let result = try #require(SkyPathQuery.samples(target: target, site: budapest, date: fixedNight))

        // Spans dusk to dawn -- first/last sample fall inside the window,
        // with at most one step's slack past the edges.
        #expect(result.samples.first!.time >= result.duskUTC)
        #expect(result.samples.last!.time <= result.dawnUTC.addingTimeInterval(5 * 60))
        #expect(result.samples.count > 1)

        // The reported max altitude is sourced from `DiscoveryPlanner.discover`
        // directly, not re-derived from this chart's own coarser grid -- so
        // it must agree EXACTLY with what that engine reports for the same
        // target/night (same call the Planning table's own "max alt" column
        // uses).
        let discoveryRows = DiscoveryPlanner.discover(date: fixedNight, site: budapest)
        let expected = try #require(discoveryRows.first { $0.target.designation == target.designation }?.maxAltitudeDeg)
        #expect(result.maxAltitudeDeg == expected)

        // The peak sample sits at (or extremely close to) culmination -- at
        // 5-minute resolution the sampled max can only be a hair below the
        // true instantaneous peak.
        let peakSample = try #require(result.samples.max(by: { $0.altitudeDeg < $1.altitudeDeg }))
        #expect(abs(peakSample.altitudeDeg - result.maxAltitudeDeg) < 0.5)
        #expect(result.culminationTime == peakSample.time)
    }

    @Test("The imaging-altitude threshold carried on the result matches the query's own input")
    func thresholdMatchesInput() throws {
        let target = try #require(TargetCatalog.all.first { $0.designation == "M 42" })

        let result = try #require(
            SkyPathQuery.samples(target: target, site: budapest, date: fixedNight, minAltitudeDeg: 25)
        )

        #expect(result.minAltitudeDeg == 25)
    }

    @Test("An unresolved site returns no sky path rather than an invented one")
    func unresolvedSiteReturnsNil() throws {
        let target = try #require(TargetCatalog.all.first { $0.designation == "M 31" })
        let noSite = SiteRule(latitudeDeg: nil, longitudeDeg: nil)

        #expect(SkyPathQuery.samples(target: target, site: noSite, date: fixedNight) == nil)
    }
}

/// The owner reported: a downloaded LBN/Sh2 target shows "88° max. magasság"
/// in the Planning table, yet the sky-path chart underneath says the altitude
/// sweep could not be computed. Cause: this query let `DiscoveryPlanner`
/// default to the built-in 217-object catalog, so any target that came from
/// the SIMBAD/VizieR download was simply not found — the same defect already
/// fixed once in `PlanningQuery`, present a second time here.
@Suite("Sky path works for targets outside the built-in catalog")
struct SkyPathExtendedCatalogTests {
    @Test("A target that is not in the built-in catalog still gets a sky path")
    func extendedCatalogTargetHasSkyPath() throws {
        // Sh2-117 / LBN 437 territory: Lacerta-Cygnus, high from Budapest in
        // mid-August, and deliberately NOT a member of TargetCatalog.all.
        let downloaded = CatalogTarget(
            designation: "LBN 437", commonNameHU: nil,
            raDeg: 338.051, decDeg: 40.591, kind: .emissionNebula,
            sizeArcmin: 20, magnitude: nil
        )
        #expect(
            !TargetCatalog.all.contains { $0.designation == downloaded.designation },
            "fixture must genuinely be outside the built-in catalog for this test to mean anything"
        )

        let result = try #require(
            SkyPathQuery.samples(target: downloaded, site: budapest, date: fixedNight),
            "a downloaded target must get a sky path, not a 'could not be computed' state"
        )
        #expect(!result.samples.isEmpty)
        #expect(result.maxAltitudeDeg > 0)
    }
}
