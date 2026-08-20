@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

@MainActor
@Suite("V2 Nights store")
struct NightsStoreTests {
    @Test("Opening a library exposes aggregated nights and honest integration")
    func opensAggregatedNights() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = [
            makeSeries(project: project.id, night: night.id, exposure: 30),
            makeSeries(project: project.id, night: night.id, exposure: 300),
        ]
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: series))
        let store = NightsStore(metadataFactory: { _ in metadata })

        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.nights.count == 1)
        #expect(store.nights[0].seriesCount == 2)
        #expect(store.nights[0].exposureSummary == "30 s, 300 s")
        #expect(store.nights[0].projectSummary == "IC 1396")
        store.selectMonth("2026-08")
        #expect(store.visibleNights.count == 1)
        #expect(store.availableMonths == ["2026-08"])
    }

    @Test("Nights loads the next thirty astronomical planning nights")
    func loadsPlanningCalendar() async throws {
        let metadata = try MetadataStore.temporary()
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        let forecast = [NightSummary(
            date: "2026-08-14", astroDarkHours: 5.2,
            moonIlluminationPercent: 8,
            bestTargets: [.init(target: "IC_1396", usableHours: 4.4)]
        )]
        let store = NightsStore(
            metadataFactory: { _ in metadata },
            calendarProvider: { selectedRoot in
                #expect(selectedRoot == root)
                return forecast
            }
        )

        try await store.open(rootURL: root)

        #expect(store.planningNights == forecast)
    }

    @Test("Nights defaults to newest-night-first and re-sorts visibleNights on demand")
    func sortsVisibleNightsByColumn() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let earlyNight = NightRecord(id: UUID(), localDate: "2026-07-01", timeZoneID: "Europe/Budapest")
        let lateNight = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        try await metadata.save(MetadataWriteBatch(
            projects: [project],
            nights: [earlyNight, lateNight],
            series: [
                makeSeries(project: project.id, night: earlyNight.id, exposure: 30),
                makeSeries(project: project.id, night: lateNight.id, exposure: 30),
            ]
        ))
        let store = NightsStore(metadataFactory: { _ in metadata })

        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        // V2 UI/UX audit (2026-08-14) systemic pattern S7: default is
        // newest-night-first -- the same order `NightsQuery.nights()`
        // already returned before this table became sortable.
        #expect(store.visibleNights.map(\.date) == ["2026-08-08", "2026-07-01"])

        store.setSortOrder([KeyPathComparator(\AstroUI.NightRow.date, order: .forward)])

        #expect(store.visibleNights.map(\.date) == ["2026-07-01", "2026-08-08"])
    }

    @Test("Planning rows default to soonest-first and re-sort on demand")
    func sortsPlanningRowsByColumn() async throws {
        let metadata = try MetadataStore.temporary()
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        let forecast = [
            NightSummary(date: "2026-08-14", astroDarkHours: 5.2, moonIlluminationPercent: 8, bestTargets: []),
            NightSummary(date: "2026-08-15", astroDarkHours: 5.4, moonIlluminationPercent: 12, bestTargets: []),
        ]
        let store = NightsStore(
            metadataFactory: { _ in metadata },
            calendarProvider: { _ in forecast }
        )

        try await store.open(rootURL: root)

        #expect(store.planningRows.map(\.summary.date) == ["2026-08-14", "2026-08-15"])

        store.setPlanningSortOrder([KeyPathComparator(\PlanningNightRow.summary.date, order: .reverse)])

        #expect(store.planningRows.map(\.summary.date) == ["2026-08-15", "2026-08-14"])
    }

    // V2 product/UX audit (2026-08-15) section 2.3, CRITICAL: `triageState`
    // used to flip to `.needsReview` from `excludedFrames > 0`, so rejecting
    // a bad frame during morning triage -- the correct thing to do --
    // permanently marked the night as needing review, with no way back. The
    // rule now keys off `undecidedFrames`: still-undecided frames mean the
    // night needs review; a night where every frame has a verdict does not,
    // even when some of those verdicts are rejections.

    @Test("A night with undecided frames needs review")
    func nightWithUndecidedFramesNeedsReview() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "M 31", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = makeSeries(project: project.id, night: night.id, exposure: 60)
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "a.fit", verdict: .accepted, logicallyExcluded: false),
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "b.fit", verdict: .undecided, logicallyExcluded: false),
        ]))
        let store = NightsStore(metadataFactory: { _ in metadata })

        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.nights[0].triageState == .needsReview)
    }

    @Test("A night where every frame is accepted-or-rejected does not need review, even with rejections")
    func fullyDecidedNightDoesNotNeedReview() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "M 31", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = makeSeries(project: project.id, night: night.id, exposure: 60)
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "a.fit", verdict: .accepted, logicallyExcluded: false),
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "b.fit", verdict: .rejected, logicallyExcluded: true),
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "c.fit", verdict: .rejected, logicallyExcluded: true),
        ]))
        let store = NightsStore(metadataFactory: { _ in metadata })

        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.nights[0].triageState == .ready)
    }

    @Test("A night with zero usable frames is empty, not needing review, even fully decided")
    func fullyRejectedNightIsEmpty() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "M 31", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = makeSeries(project: project.id, night: night.id, exposure: 60)
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "a.fit", verdict: .rejected, logicallyExcluded: true),
        ]))
        let store = NightsStore(metadataFactory: { _ in metadata })

        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.nights[0].triageState == .empty)
    }

    // MARK: - W4-3b (triage filter + Triage column collapse)

    @Test("The triage filter narrows visibleNights to the matching states and drops a selection the new filter excludes")
    func triageFilterNarrowsVisibleNights() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "M 31", phase: .collecting)
        let readyNight = NightRecord(id: UUID(), localDate: "2026-08-01", timeZoneID: "Europe/Budapest")
        let reviewNight = NightRecord(id: UUID(), localDate: "2026-08-02", timeZoneID: "Europe/Budapest")
        let readySeries = makeSeries(project: project.id, night: readyNight.id, exposure: 60)
        let reviewSeries = makeSeries(project: project.id, night: reviewNight.id, exposure: 60)
        try await metadata.save(MetadataWriteBatch(
            projects: [project], nights: [readyNight, reviewNight], series: [readySeries, reviewSeries]
        ))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: readySeries.id, relativePath: "a.fit", verdict: .accepted, logicallyExcluded: false),
            FrameDecisionRecord(id: UUID(), seriesID: reviewSeries.id, relativePath: "b.fit", verdict: .undecided, logicallyExcluded: false),
        ]))
        let store = NightsStore(metadataFactory: { _ in metadata })
        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        // Default: no filter applied, both nights visible, no single shared
        // state (one `.ready`, one `.needsReview`).
        #expect(store.triageFilter == .all)
        #expect(store.visibleNights.count == 2)
        #expect(store.uniformVisibleTriageState == nil)

        // Select the review night, then filter it out -- the selection must
        // not silently point at a row the table no longer shows (same rule
        // `selectMonth` already enforces).
        store.selectNight(reviewNight.id)
        store.setTriageFilter(.ready)
        #expect(store.visibleNights.map(\.id) == [readyNight.id])
        #expect(store.selectedNightID == nil)
        #expect(store.uniformVisibleTriageState == .ready)

        store.setTriageFilter(.needsReview)
        #expect(store.visibleNights.map(\.id) == [reviewNight.id])
        #expect(store.uniformVisibleTriageState == .needsReview)

        store.setTriageFilter(.all)
        #expect(store.visibleNights.count == 2)
        #expect(store.uniformVisibleTriageState == nil)
    }

    @Test("The needs-review filter bucket also matches nights with zero usable frames, the same way SidebarBadgeStore.nightsNeedingAttention already does")
    func triageFilterNeedsReviewIncludesEmptyNights() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "M 31", displayName: "M 31", phase: .collecting)
        let emptyNight = NightRecord(id: UUID(), localDate: "2026-08-03", timeZoneID: "Europe/Budapest")
        let series = makeSeries(project: project.id, night: emptyNight.id, exposure: 60)
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [emptyNight], series: [series]))
        try await metadata.save(MetadataWriteBatch(frameDecisions: [
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "a.fit", verdict: .rejected, logicallyExcluded: true),
        ]))
        let store = NightsStore(metadataFactory: { _ in metadata })
        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.nights[0].triageState == .empty)

        store.setTriageFilter(.needsReview)
        #expect(store.visibleNights.map(\.id) == [emptyNight.id])
        #expect(store.uniformVisibleTriageState == .empty)

        store.setTriageFilter(.ready)
        #expect(store.visibleNights.isEmpty)
        #expect(store.uniformVisibleTriageState == nil)
    }

    // MARK: - W4-2 (cloud forecast)

    @Test("Opening a library with weather enabled loads per-night cloud summaries")
    func opensNightWeather() async throws {
        let metadata = try MetadataStore.temporary()
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        let summaries: [String: DailyCloudSummary] = [
            "2026-08-14": DailyCloudSummary(date: "2026-08-14", minPercent: 5, maxPercent: 40, meanPercent: 20),
        ]
        let store = NightsStore(
            metadataFactory: { _ in metadata },
            calendarProvider: { _ in [] },
            weatherProvider: { selectedRoot in
                #expect(selectedRoot == root)
                return summaries
            }
        )

        try await store.open(rootURL: root)

        #expect(store.nightWeather == summaries)
    }

    @Test("No site configured (or weather off) leaves nightWeather empty, not an error")
    func opensWithoutWeatherLeavesNightWeatherEmpty() async throws {
        let metadata = try MetadataStore.temporary()
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        let store = NightsStore(
            metadataFactory: { _ in metadata },
            calendarProvider: { _ in [] },
            weatherProvider: { _ in nil }
        )

        try await store.open(rootURL: root)

        #expect(store.nightWeather.isEmpty)
    }

    @Test("A cloud forecast fetch failure does not fail the calendar load itself")
    func weatherFetchFailureDoesNotFailOpen() async throws {
        let metadata = try MetadataStore.temporary()
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        let forecast = [NightSummary(date: "2026-08-14", astroDarkHours: 5.2, moonIlluminationPercent: 8, bestTargets: [])]
        let store = NightsStore(
            metadataFactory: { _ in metadata },
            calendarProvider: { _ in forecast },
            weatherProvider: { _ in throw WeatherError.network }
        )

        try await store.open(rootURL: root)

        #expect(store.planningNights == forecast)
        #expect(store.nightWeather.isEmpty)
    }

    private func makeSeries(project: UUID, night: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(id: UUID(), projectID: project, nightID: night, setupID: nil,
            setupDescriptor: "ASI2600MC", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: exposure, filterName: "SV220", filterID: nil,
            gain: 100, offset: 50, binning: "1x1")
    }
}
