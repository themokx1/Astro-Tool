@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Pins `TargetHistoryTimeline.build`'s pure compose rules -- expert
/// ideation #4 ("Célpont-történet idővonal"). Every case here hands the
/// function plain, already-fetched `TrendPoint`/`StackGroup` fixtures (the
/// exact shapes `TrendQueries.points`/`StackDiscovery.groupedStacks`
/// themselves produce) -- no database, no filesystem, matching
/// `AnniversaryQueryTests`'s own "pure function, plain fixtures" shape for
/// the sibling engine this one was modeled after.
struct TargetHistoryTimelineTests {
    @Test("A target with no recorded sessions at all has no history yet")
    func emptyTargetReturnsNil() {
        let events = TargetHistoryTimeline.build(sessions: [], stackGroups: [])
        #expect(events == nil)
    }

    @Test("A single session with no stacks produces exactly one first-light entry -- nothing fabricated")
    func singleSessionNoStacksProducesOnlyFirstLight() {
        let events = TargetHistoryTimeline.build(
            sessions: [point(date: "2026-03-01", integrationSeconds: 3600)],
            stackGroups: []
        )

        #expect(events?.count == 1)
        #expect(events?.first?.date == "2026-03-01")
        #expect(events?.first?.kind == .firstLight)
    }

    @Test("The earliest session becomes the first-light event, regardless of input order")
    func earliestSessionIsFirstLightRegardlessOfInputOrder() {
        let events = TargetHistoryTimeline.build(
            sessions: [
                point(date: "2026-05-10", integrationSeconds: 1800),
                point(date: "2026-01-02", integrationSeconds: 3600),
                point(date: "2026-03-15", integrationSeconds: 2400),
            ],
            stackGroups: []
        )

        #expect(events?.first?.date == "2026-01-02")
        #expect(events?.first?.kind == .firstLight)
    }

    @Test("Events are chronological, oldest first (newest last)")
    func eventsAreChronologicallyOrdered() {
        let events = TargetHistoryTimeline.build(
            sessions: [
                point(date: "2026-05-10", integrationSeconds: 1800),
                point(date: "2026-01-02", integrationSeconds: 3600),
                point(date: "2026-03-15", integrationSeconds: 2400),
            ],
            stackGroups: []
        )

        #expect(events?.map(\.date) == ["2026-01-02", "2026-03-15", "2026-05-10"])
    }

    @Test("Every non-first session becomes its own session event, carrying integration and best FWHM")
    func nonFirstSessionsCarryIntegrationAndFWHM() {
        let events = TargetHistoryTimeline.build(
            sessions: [
                point(date: "2026-01-02", integrationSeconds: 3600),
                point(date: "2026-02-05", integrationSeconds: 5400, fwhmArcsec: 3.4),
            ],
            stackGroups: []
        )

        #expect(events?.count == 2)
        #expect(events?.last?.date == "2026-02-05")
        #expect(events?.last?.kind == .session(integrationSeconds: 5400, fwhmArcsec: 3.4, fwhmPixels: nil))
    }

    @Test("A session never rated at all carries nil for both FWHM fields, never a fabricated number")
    func unratedSessionCarriesNoFWHM() {
        let events = TargetHistoryTimeline.build(
            sessions: [
                point(date: "2026-01-02", integrationSeconds: 3600),
                point(date: "2026-02-05", integrationSeconds: 5400),
            ],
            stackGroups: []
        )

        #expect(events?.last?.kind == .session(integrationSeconds: 5400, fwhmArcsec: nil, fwhmPixels: nil))
    }

    @Test("A pixel-fallback FWHM (no resolvable arcsec scale) is carried as pixels, never duplicated into both fields")
    func pixelFallbackFWHMCarriesOnlyPixels() {
        let events = TargetHistoryTimeline.build(
            sessions: [
                point(date: "2026-01-02", integrationSeconds: 3600),
                point(date: "2026-02-05", integrationSeconds: 5400, fwhmPixels: 3.1),
            ],
            stackGroups: []
        )

        #expect(events?.last?.kind == .session(integrationSeconds: 5400, fwhmArcsec: nil, fwhmPixels: 3.1))
    }

    @Test("Stack families fold onto the date their own base file's sessionDate names")
    func stackFamiliesFoldIntoTheirOwnDate() {
        let events = TargetHistoryTimeline.build(
            sessions: [point(date: "2026-01-02", integrationSeconds: 3600)],
            stackGroups: [stackGroup(baseName: "NGC_7000_106x120sec_12720s_stacked.fit", sessionDate: "2026-01-02")]
        )

        #expect(events?.count == 2)
        #expect(events?.last?.date == "2026-01-02")
        #expect(events?.last?.kind == .stacksProduced(fileNames: ["NGC_7000_106x120sec_12720s_stacked.fit"]))
    }

    @Test("Multiple stack families sharing the same date fold into ONE event carrying every name")
    func multipleStackFamiliesOnSameDateFoldIntoOneEvent() {
        let events = TargetHistoryTimeline.build(
            sessions: [point(date: "2026-01-02", integrationSeconds: 3600)],
            stackGroups: [
                stackGroup(baseName: "a_stacked.fit", sessionDate: "2026-01-02"),
                stackGroup(baseName: "b_stacked.fit", sessionDate: "2026-01-02"),
                stackGroup(baseName: "c_stacked.fit", sessionDate: "2026-01-02"),
            ]
        )

        let stackEvents = events?.filter {
            if case .stacksProduced = $0.kind { return true }
            return false
        }
        #expect(stackEvents?.count == 1)
        #expect(stackEvents?.first?.kind == .stacksProduced(fileNames: ["a_stacked.fit", "b_stacked.fit", "c_stacked.fit"]))
    }

    @Test("A stack family with no derivable sessionDate is skipped rather than given a fabricated date")
    func stackFamilyWithNoSessionDateIsSkipped() {
        let events = TargetHistoryTimeline.build(
            sessions: [point(date: "2026-01-02", integrationSeconds: 3600)],
            stackGroups: [stackGroup(baseName: "result_final.tif", sessionDate: nil)]
        )

        #expect(events?.count == 1)
    }

    @Test("No stack families at all: no stack event appears, only the session/first-light events")
    func noStacksOmitsStackEvents() {
        let events = TargetHistoryTimeline.build(
            sessions: [
                point(date: "2026-01-02", integrationSeconds: 3600),
                point(date: "2026-02-05", integrationSeconds: 5400),
            ],
            stackGroups: []
        )

        #expect(events?.count == 2)
        #expect(events?.allSatisfy {
            if case .stacksProduced = $0.kind { return false }
            return true
        } == true)
    }

    // MARK: - Fixtures

    private func point(
        date: String,
        integrationSeconds: Double,
        fwhmArcsec: Double? = nil,
        fwhmPixels: Double? = nil
    ) -> TrendPoint {
        TrendPoint(
            target: "NGC_7000",
            date: date,
            sessionStartDate: date,
            medianFWHMArcsec: fwhmArcsec,
            medianFWHMPixels: fwhmPixels,
            integrationSeconds: integrationSeconds
        )
    }

    private func stackGroup(baseName: String, sessionDate: String?) -> StackGroup {
        StackGroup(
            stem: baseName,
            base: StackFile(
                path: "stacks/NGC_7000/\(baseName)",
                target: "NGC_7000",
                sessionDate: sessionDate,
                sizeBytes: 123_456,
                kind: "stack",
                matchSource: "mappa"
            ),
            variants: []
        )
    }
}
