@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
@Suite("V2 Projects store")
struct ProjectsStoreTests {
    @Test("Project goal and notes save through the selected project workspace")
    func projectAnnotationEditing() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        try await metadata.save(project)
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        try await store.selectProject(project.id)

        try await store.saveSelectedProjectAnnotation(goalHours: 14, notes: "More dual-band data")

        #expect(store.selectedProjectAnnotation?.integrationGoalHours == 14)
        #expect(store.selectedProjectAnnotation?.notes == "More dual-band data")
        #expect(try await metadata.projectAnnotation(projectID: project.id) == store.selectedProjectAnnotation)
    }

    @Test("Opening a library loads projects and canonical creation refreshes the list")
    func createPersistsAndRefreshes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-ProjectsStore-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try MetadataStore.temporary()
        let store = ProjectsStore(metadataFactory: { _ in metadata })

        try await store.open(rootURL: root)
        let match = try #require(ProjectsQuery.searchCatalog("elefántormány").first)
        let created = try await store.createProject(from: match)

        #expect(created.catalogID == "IC 1396")
        #expect(store.projects == [created])
        #expect(try await metadata.project(id: created.id) == created)
    }

    @Test("Creating the same catalog target twice returns the existing project")
    func duplicateCatalogCreationIsIdempotent() async throws {
        let metadata = try MetadataStore.temporary()
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        try await store.open(rootURL: root)
        let match = try #require(ProjectsQuery.searchCatalog("IC 1396").first)

        let first = try await store.createProject(from: match)
        let second = try await store.createProject(from: match)

        #expect(first.id == second.id)
        #expect(store.projects.count == 1)
    }

    @Test("Selecting a project loads its complete acquisition detail")
    func selectionLoadsProjectDetail() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        try await metadata.save(project)
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        try await store.open(rootURL: root)

        try await store.selectProject(project.id)

        #expect(store.selectedProjectID == project.id)
        #expect(store.selectedProject?.project == project)
        #expect(store.errorMessage == nil)
    }

    @Test("Project workspace rows aggregate acquisition facts and survive reload selection")
    func workspaceRowsAndStableSelection() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = SeriesRecord(
            id: UUID(), projectID: project.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC · 261 mm", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil, gain: 100, offset: 50, binning: "1x1"
        )
        let frames = (0..<3).map { index in
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "light/\(index).fit", verdict: index == 2 ? .rejected : .accepted, logicallyExcluded: index == 2)
        }
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series], frameDecisions: frames))
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())

        try await store.open(rootURL: root)
        let row = try #require(store.workspaceRows.first)
        #expect(row.nightCount == 1)
        #expect(row.usableFrames == 2)
        #expect(row.excludedFrames == 1)
        #expect(row.integrationSeconds == 600)
        #expect(row.latestNight == "2026-08-08")
        try await store.selectProject(project.id)
        try await store.open(rootURL: root)
        #expect(store.selectedProjectID == project.id)
    }

    @Test("Project search matches catalog name, filter and setup metadata")
    func projectSearchUsesWorkflowMetadata() async throws {
        let metadata = try MetadataStore.temporary()
        let elephant = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let orion = ProjectRecord(id: UUID(), catalogID: "M 42", displayName: "Orion-köd", phase: .processing)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let filtered = SeriesRecord(
            id: UUID(), projectID: elephant.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC · 261 mm", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil, gain: 100, offset: 50, binning: "1x1"
        )
        try await metadata.save(MetadataWriteBatch(projects: [elephant, orion], nights: [night], series: [filtered]))
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(try await store.search("SV220").map(\.id) == [elephant.id])
        #expect(try await store.search("processing").map(\.id) == [orion.id])
        #expect(try await store.search("IC1396").map(\.id) == [elephant.id])
    }
}
