@testable import AstroApplication
import Foundation
import Testing

struct NightsQueryTests {
    @Test("One civil night aggregates projects and capture series")
    func aggregatesProjectsAndSeries() async throws {
        let metadata = try MetadataStore.temporary()
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let ic1396 = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let m42 = ProjectRecord(id: UUID(), catalogID: "M 42", displayName: "Orion-köd", phase: .collecting)
        let series = [makeSeries(project: ic1396.id, night: night.id, exposure: 30), makeSeries(project: m42.id, night: night.id, exposure: 120)]
        try await metadata.save(MetadataWriteBatch(projects: [ic1396, m42], nights: [night], series: series))

        let rows = try await NightsQuery(metadata: metadata).nights()

        #expect(rows.count == 1)
        #expect(rows[0].projects.map(\.catalogID) == ["IC 1396", "M 42"])
        #expect(rows[0].series.map(\.exposureSeconds) == [30, 120])
    }

    private func makeSeries(project: UUID, night: UUID, exposure: Double) -> SeriesRecord {
        SeriesRecord(id: UUID(), projectID: project, nightID: night, setupID: nil,
            setupDescriptor: "Test", sensorMode: .osc, passband: .broadband,
            exposureSeconds: exposure, filterName: nil, filterID: nil, gain: nil,
            offset: nil, binning: "1x1")
    }
}
