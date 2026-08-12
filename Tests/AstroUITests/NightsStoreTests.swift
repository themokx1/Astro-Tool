@testable import AstroUI
import AstroApplication
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
    }

    private func makeSeries(project: UUID, night: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(id: UUID(), projectID: project, nightID: night, setupID: nil,
            setupDescriptor: "ASI2600MC", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: exposure, filterName: "SV220", filterID: nil,
            gain: 100, offset: 50, binning: "1x1")
    }
}
