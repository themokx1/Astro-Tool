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

    private func makeSeries(project: UUID, night: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(id: UUID(), projectID: project, nightID: night, setupID: nil,
            setupDescriptor: "ASI2600MC", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: exposure, filterName: "SV220", filterID: nil,
            gain: 100, offset: 50, binning: "1x1")
    }
}
