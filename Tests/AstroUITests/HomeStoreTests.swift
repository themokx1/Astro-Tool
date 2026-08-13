@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

@MainActor
struct HomeStoreTests {
    @Test("Opening a real library replaces the empty home with useful project context")
    func configuredLibraryProducesHomeSummary() {
        let store = HomeStore()
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )

        store.configure(libraryName: "Astro", projects: [project], nightCount: 16)

        #expect(store.snapshot.libraryName == "Astro")
        #expect(store.snapshot.projectCount == 1)
        #expect(store.snapshot.nightCount == 16)
        #expect(store.snapshot.nextProject == project)
    }

    @Test("Home ranks real tonight plans and links them to V2 projects")
    func homeShowsAstronomicalTonightRecommendations() async throws {
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        let metadata = try MetadataStore.temporary()
        try await metadata.save(project)
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: "/Volumes/Test/Astro", isDirectory: true)
        try await projects.open(rootURL: root)
        let store = HomeStore(tonightProvider: { selectedRoot in
            #expect(selectedRoot == root)
            return [TargetPlan(
                target: "IC_1396", displayName: "Elefántormány-köd",
                usableIntegrationSeconds: 7200, goalSeconds: 36_000,
                culminationLocal: "01:14", maxAltitudeDeg: 79,
                visibleWindowLocal: "22:10–03:36", visibleHours: 5.5,
                moonIlluminationPercent: 11, moonSeparationDeg: 87,
                verdict: "ma jó", score: 0.92
            )]
        })

        await store.configure(
            libraryName: "Astro", rootURL: root,
            projectsStore: projects, nightCount: 1
        )

        #expect(store.snapshot.tonightRecommendations.count == 1)
        #expect(store.snapshot.tonightRecommendations[0].projectID == project.id)
        #expect(store.snapshot.tonightRecommendations[0].visibleWindow == "22:10–03:36")
        #expect(store.snapshot.tonightRecommendations[0].verdict == "ma jó")
    }

    @Test("Home prioritizes the least collected active project")
    func homeRecommendationUsesAcquisitionProgress() async throws {
        let metadata = try MetadataStore.temporary()
        let rich = ProjectRecord(id: UUID(), catalogID: "M 42", displayName: "Orion-köd", phase: .collecting)
        let lean = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let richSeries = makeSeries(project: rich.id, night: night.id, exposure: 300)
        let leanSeries = makeSeries(project: lean.id, night: night.id, exposure: 30)
        try await metadata.save(MetadataWriteBatch(projects: [rich, lean], nights: [night], series: [richSeries, leanSeries]))
        try await metadata.save(MetadataWriteBatch(frameDecisions:
            (0..<10).map { FrameDecisionRecord(id: UUID(), seriesID: richSeries.id, relativePath: "r\($0).fit", verdict: .accepted, logicallyExcluded: false) }
            + [FrameDecisionRecord(id: UUID(), seriesID: leanSeries.id, relativePath: "l.fit", verdict: .accepted, logicallyExcluded: false)]
        ))
        let projects = ProjectsStore(metadataFactory: { _ in metadata })
        try await projects.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        let store = HomeStore()

        await store.configure(libraryName: "Astro", projectsStore: projects, nightCount: 1)

        #expect(store.snapshot.nextProject == lean)
        #expect(store.snapshot.nextProjectIntegrationSeconds == 30)
    }

    private func makeSeries(project: UUID, night: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(id: UUID(), projectID: project, nightID: night, setupID: nil,
            setupDescriptor: "Test", sensorMode: .osc, passband: .broadband,
            exposureSeconds: exposure, filterName: nil, filterID: nil, gain: nil,
            offset: nil, binning: "1x1")
    }
}
