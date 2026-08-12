@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
@Suite("V2 Projects store")
struct ProjectsStoreTests {
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
}
