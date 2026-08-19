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
/// and `Tests/AstroApplicationTests/PlanningQueryTests.swift` both use.
private let budapest = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)
/// Same night `DiscoveryPlannerTests`'s own FOV-fit tests use.
private let fixtureDate = utc(2026, 8, 4)

/// APS-C sensor at 200 mm -- FOV ≈ 6.7° × 4.5°, the EXACT setup
/// `DiscoveryPlannerTests.discoveryOverallScoreIncludesCompositionWhenFOVIsKnown`
/// confirms gives M 31 a "jó kitöltés" (`.good`) label.
private let wideRig = ImagingSetupProfile(
    id: "wide-rig", name: "APS-C astro · 200 mm", cameraName: "APS-C astro",
    cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.6,
    focalLengthMinMM: 100, focalLengthMaxMM: 400, defaultFocalLengthMM: 200,
    fNumber: 5, relativeEfficiency: 1, isDefault: true
)
/// Same sensor at 673 mm -- FOV ≈ 2.0° × 1.3°, the EXACT setup
/// `DiscoveryPlannerTests.fovFitLabelsDiscriminateASmallObjectFromAHugeOneAgainstTheSameFOV`
/// confirms gives M 31 a "mozaik kellene" (`.mosaic`) label: M 31 (~192' major
/// axis) no longer fits even the long edge of this narrower frame.
private let narrowRig = ImagingSetupProfile(
    id: "narrow-rig", name: "Big reflector · 673 mm", cameraName: "Big reflector",
    cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.6,
    focalLengthMinMM: 600, focalLengthMaxMM: 800, defaultFocalLengthMM: 673,
    fNumber: 8, relativeEfficiency: 1, isDefault: false
)

struct RigCompareQueryTests {
    @Test("A target too wide for the narrow rig's long focal length needs a mosaic there, while the wide rig frames it well")
    func wideTargetNeedsMosaicOnTheLongFocalRig() throws {
        let result = try #require(RigCompareQuery.compare(
            selectedSetupID: wideRig.id,
            setups: [wideRig, narrowRig],
            focalLengthMM: 200,
            site: budapest,
            date: fixtureDate
        ))

        let m31 = try #require(result["M 31"])
        #expect(m31.primaryFit == .good)
        #expect(m31.otherFit == .mosaic)
    }

    @Test("Fewer than two saved setups means no invented comparison")
    func fewerThanTwoSetupsMeansNilComparison() {
        let result = RigCompareQuery.compare(
            selectedSetupID: wideRig.id,
            setups: [wideRig],
            focalLengthMM: 200,
            site: budapest,
            date: fixtureDate
        )
        #expect(result == nil)
    }

    @Test("An empty setups list means no invented comparison")
    func emptySetupsMeansNilComparison() {
        let result = RigCompareQuery.compare(
            selectedSetupID: wideRig.id,
            setups: [],
            focalLengthMM: 200,
            site: budapest,
            date: fixtureDate
        )
        #expect(result == nil)
    }

    @Test("A selected ID matching none of the saved setups means no invented comparison")
    func unresolvedSelectedIDMeansNilComparison() {
        let result = RigCompareQuery.compare(
            selectedSetupID: "does-not-exist",
            setups: [wideRig, narrowRig],
            focalLengthMM: 200,
            site: budapest,
            date: fixtureDate
        )
        #expect(result == nil)
    }

    @Test("Every row is keyed by its own designation, matching neither rig's fit to the wrong target")
    func zipIntegrityMatchesEachRowToItsOwnDesignation() throws {
        let result = try #require(RigCompareQuery.compare(
            selectedSetupID: wideRig.id,
            setups: [wideRig, narrowRig],
            focalLengthMM: 200,
            site: budapest,
            date: fixtureDate
        ))

        // The zip must cover the whole catalog, one row per designation, and
        // every row's own key must match the designation it carries -- a
        // cross-wiring bug (e.g. rows shifted by one during the zip) would
        // break this invariant even if individual fits happened to look
        // plausible.
        #expect(result.count == TargetCatalog.all.count)
        for (designation, row) in result {
            #expect(row.designation == designation)
        }

        // M 57 (Ring Nebula, ~3.8' major axis) is a speck against EITHER
        // rig's frame -- its own fit must never accidentally pick up M 31's
        // mosaic/good verdict through a misaligned zip.
        let m57 = try #require(result["M 57"])
        #expect(m57.primaryFit == .tooSmall)
        #expect(m57.otherFit == .tooSmall)

        // M 31 must keep ITS OWN two fits distinct and in the right slots --
        // not swapped, and not both collapsed to one rig's value.
        let m31 = try #require(result["M 31"])
        #expect(m31.primaryFit != m31.otherFit)
        #expect(m31.primaryFit == .good)
        #expect(m31.otherFit == .mosaic)
    }

    @Test("Swapping which setup is selected swaps which side of the comparison each fit lands on")
    func swappingSelectedSetupSwapsSides() throws {
        let asWideSelected = try #require(RigCompareQuery.compare(
            selectedSetupID: wideRig.id,
            setups: [wideRig, narrowRig],
            focalLengthMM: 200,
            site: budapest,
            date: fixtureDate
        ))
        let asNarrowSelected = try #require(RigCompareQuery.compare(
            selectedSetupID: narrowRig.id,
            setups: [wideRig, narrowRig],
            focalLengthMM: 673,
            site: budapest,
            date: fixtureDate
        ))

        let m31Wide = try #require(asWideSelected["M 31"])
        let m31Narrow = try #require(asNarrowSelected["M 31"])
        #expect(m31Wide.primaryFit == m31Narrow.otherFit)
        #expect(m31Wide.otherFit == m31Narrow.primaryFit)
    }
}
