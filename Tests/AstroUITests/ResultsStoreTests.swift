@testable import AstroUI
import AstroApplication
import Foundation
import Testing

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: `ResultsStore` used to
/// be a `private final class` embedded in `ResultsView.swift` that resolved
/// `ProjectsStore.productionMetadata` directly inside `load` -- there was no
/// way to load it against anything but a real on-disk library, so this
/// whole screen had zero unit-test surface. This is that surface.
@MainActor
@Suite("V2 Results store")
struct ResultsStoreTests {
    @Test("Loading a project populates its result lineage and canonical folder name")
    func loadingPopulatesSnapshot() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .processing)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night]))
        let result = ResultRecord(
            id: UUID(), projectID: project.id, parentResultID: nil, kind: .stack, role: .final,
            relativePath: "stacks/IC1396/final.fit", createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            softwareName: "Siril", softwareVersion: "1.2"
        )
        try await metadata.save(result)
        let store = ResultsStore(metadataFactory: { _ in metadata })

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), projectID: project.id)

        #expect(store.snapshot?.results.map(\.id) == [result.id])
        #expect(store.canonicalFolderName != nil)
        #expect(store.errorMessage == nil)
    }

    @Test("Results default to most-recent-first and re-sort on demand")
    func sortsResultsByColumn() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .processing)
        try await metadata.save(MetadataWriteBatch(projects: [project]))
        let older = ResultRecord(
            id: UUID(), projectID: project.id, parentResultID: nil, kind: .stack, role: .intermediate,
            relativePath: "stacks/IC1396/older.fit", createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            softwareName: "Siril", softwareVersion: "1.2"
        )
        let newer = ResultRecord(
            id: UUID(), projectID: project.id, parentResultID: nil, kind: .stack, role: .final,
            relativePath: "stacks/IC1396/newer.fit", createdAt: Date(timeIntervalSince1970: 1_786_100_000),
            softwareName: "Siril", softwareVersion: "1.2"
        )
        try await metadata.save(older)
        try await metadata.save(newer)
        let store = ResultsStore(metadataFactory: { _ in metadata })

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), projectID: project.id)

        #expect(store.results.map(\.id) == [newer.id, older.id])

        store.setSortOrder([KeyPathComparator(\ResultLineageSnapshot.createdAt, order: .forward)])

        #expect(store.results.map(\.id) == [older.id, newer.id])
    }

    @Test("A load failure surfaces its error message rather than throwing past the view")
    func loadFailureSurfacesError() async throws {
        struct BoomError: Error {}
        let store = ResultsStore(metadataFactory: { _ in throw BoomError() })

        await store.load(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()), projectID: UUID())

        #expect(store.snapshot == nil)
        #expect(store.errorMessage != nil)
    }
}
