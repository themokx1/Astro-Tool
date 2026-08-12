@testable import AstroApplication
import Foundation
import Testing

struct ProjectsQueryTests {
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
        #expect(snapshot.nextAction.title == "Folytasd a gyűjtést")
        #expect(snapshot.canonicalFolderName == "IC_1396_Elephants_Trunk_Nebula")
    }

    private func series(projectID: UUID, nightID: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(
            id: UUID(), projectID: projectID, nightID: nightID,
            setupID: nil, setupDescriptor: "ASI2600MC · 261 mm",
            sensorMode: .osc, passband: .dualBand, exposureSeconds: exposure,
            filterName: "SV220", filterID: nil, gain: 100, offset: 50, binning: "1x1"
        )
    }
}
