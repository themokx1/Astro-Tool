@testable import AstroApplication
import Foundation
import Testing

struct ProjectsQueryTests {
    @Test("Catalog browsing works before a library or metadata store is open")
    func standaloneCatalogSearchSupportsLocalizedNames() {
        for term in ["IC1396", "Elephant's Trunk", "elefántormány"] {
            let matches = ProjectsQuery.searchCatalog(term)
            #expect(matches.first?.catalogID == "IC 1396")
            #expect(matches.first?.canonicalFolderName == "IC_1396_Elephants_Trunk_Nebula")
            #expect(matches.first?.existingProjectID == nil)
        }
    }

    @Test("Catalog number, English and Hungarian names resolve to the same existing project")
    func catalogSearchPreventsDuplicateElephantTrunkProjects() async throws {
        let store = try MetadataStore.temporary()
        let project = ProjectRecord(
            id: UUID(),
            catalogID: "IC 1396",
            displayName: "IC 1396 · Elefántormány-köd",
            phase: .collecting
        )
        try await store.save(project)
        let query = ProjectsQuery(metadata: store)

        for term in ["IC1396", "Elephant's Trunk", "elefántormány"] {
            let matches = try await query.searchCatalog(term)
            #expect(matches.first?.catalogID == "IC 1396")
            #expect(matches.first?.existingProjectID == project.id)
            #expect(matches.first?.canonicalFolderName == "IC_1396_Elephants_Trunk_Nebula")
        }
    }

    @Test("Project snapshot keeps child series scoped and explains the next action")
    func projectSnapshotExplainsNextAction() async throws {
        let store = try MetadataStore.temporary()
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        let other = ProjectRecord(
            id: UUID(), catalogID: "M 42", displayName: "Orion-köd", phase: .planned
        )
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        try await store.save(MetadataWriteBatch(projects: [project, other], nights: [night]))
        let ownSeries = series(projectID: project.id, nightID: night.id, exposure: 300)
        let foreignSeries = series(projectID: other.id, nightID: night.id, exposure: 30)
        try await store.save(MetadataWriteBatch(series: [ownSeries, foreignSeries]))

        let snapshot = try #require(try await ProjectsQuery(metadata: store).project(id: project.id))
        #expect(snapshot.series.map(\.id) == [ownSeries.id])
        // The UI is English; this advice used to render Hungarian on it.
        #expect(snapshot.nextAction.title == "Keep collecting")
        #expect(snapshot.canonicalFolderName == "IC_1396_Elephants_Trunk_Nebula")
    }

    @Test("Project detail groups series by night and reports usable integration")
    func projectDetailGroupsAcquisitionByNight() async throws {
        let store = try MetadataStore.temporary()
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        let firstNight = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let secondNight = NightRecord(id: UUID(), localDate: "2026-08-12", timeZoneID: "Europe/Budapest")
        let thirty = series(projectID: project.id, nightID: firstNight.id, exposure: 30)
        let threeHundred = series(projectID: project.id, nightID: secondNight.id, exposure: 300)
        try await store.save(MetadataWriteBatch(
            projects: [project], nights: [firstNight, secondNight], series: [thirty, threeHundred]
        ))
        try await store.save(MetadataWriteBatch(frameDecisions: [
            decision(seriesID: thirty.id, path: "30-1.fit", verdict: .accepted),
            decision(seriesID: thirty.id, path: "30-2.fit", verdict: .rejected, excluded: true),
            decision(seriesID: threeHundred.id, path: "300-1.fit", verdict: .undecided),
            decision(seriesID: threeHundred.id, path: "300-2.fit", verdict: .accepted)
        ]))

        let snapshot = try #require(try await ProjectsQuery(metadata: store).project(id: project.id))

        #expect(snapshot.nights.map(\.night.localDate) == ["2026-08-12", "2026-08-08"])
        #expect(snapshot.totalFrames == 4)
        #expect(snapshot.usableFrames == 3)
        #expect(snapshot.integrationSeconds == 630)
        #expect(snapshot.nights.first?.series.first?.filterName == "SV220")
        #expect(snapshot.nights.last?.series.first?.excludedFrames == 1)
    }

    private func series(projectID: UUID, nightID: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(
            id: UUID(), projectID: projectID, nightID: nightID,
            setupID: nil, setupDescriptor: "ASI2600MC · 261 mm",
            sensorMode: .osc, passband: .dualBand, exposureSeconds: exposure,
            filterName: "SV220", filterID: nil, gain: 100, offset: 50, binning: "1x1"
        )
    }

    private func decision(
        seriesID: UUID,
        path: String,
        verdict: FrameVerdict,
        excluded: Bool = false
    ) -> FrameDecisionRecord {
        FrameDecisionRecord(
            id: UUID(), seriesID: seriesID, relativePath: path,
            verdict: verdict, logicallyExcluded: excluded
        )
    }
}
