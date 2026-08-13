@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
@Suite("V2 Review store")
struct ReviewStoreTests {
    @Test("Opening review selects the first exposure series and keeps distinct captures")
    func openSelectsFirstSeries() async throws {
        let fixture = try await ReviewStoreFixture.make()
        let store = ReviewStore(metadataFactory: { _ in fixture.metadata })

        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)

        #expect(store.snapshot?.series.map(\.series.exposureSeconds) == [30, 120, 300])
        #expect(store.selectedSeriesID == fixture.series[0].id)
        #expect(store.selectedSeries?.series.exposureSeconds == 30)
    }

    @Test("A bulk reject refreshes series counts and logical exclusion")
    func bulkRejectRefreshesSnapshot() async throws {
        let fixture = try await ReviewStoreFixture.make()
        let store = ReviewStore(metadataFactory: { _ in fixture.metadata })
        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)
        store.selectSeries(fixture.series[2].id)

        try await store.setVerdict(
            relativePaths: ["lights/SV220_001.fit", "lights/SV220_002.fit"],
            verdict: .rejected
        )

        #expect(store.selectedSeries?.rejectedCount == 2)
        #expect(store.selectedSeries?.decisions.allSatisfy(\.logicallyExcluded) == true)
        #expect(store.selectedSeriesID == fixture.series[2].id)
    }

    @Test("An equipment filter can be assigned inline to the selected series")
    func assignFilterInline() async throws {
        let fixture = try await ReviewStoreFixture.make()
        let store = ReviewStore(metadataFactory: { _ in fixture.metadata })
        try await store.open(rootURL: fixture.root, projectID: fixture.project.id)
        let filter = EquipmentFilter(id: UUID(), manufacturer: "SVBONY", model: "SV220", passband: .dualBand)

        try await store.assignFilter(filter)

        #expect(store.selectedSeries?.series.filterName == "SVBONY SV220")
        #expect(store.selectedSeries?.series.passband == .dualBand)
        #expect(store.selectedSeries?.series.filterID == filter.id.uuidString.lowercased())
    }
}

private struct ReviewStoreFixture {
    let root: URL
    let metadata: MetadataStore
    let project: ProjectRecord
    let series: [SeriesRecord]

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-ReviewStore-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = [30.0, 120.0, 300.0].map { exposure in
            SeriesRecord(
                id: UUID(), projectID: project.id, nightID: night.id,
                setupID: "asi2600mc-261", setupDescriptor: "ASI2600MC · 261 mm",
                sensorMode: .osc, passband: exposure == 30 ? .broadband : .dualBand,
                exposureSeconds: exposure, filterName: exposure == 30 ? nil : "SV220",
                filterID: exposure == 30 ? nil : "svbony-sv220",
                gain: 100, offset: 50, binning: "1x1"
            )
        }
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: series))
        return Self(root: root, metadata: metadata, project: project, series: series)
    }
}
