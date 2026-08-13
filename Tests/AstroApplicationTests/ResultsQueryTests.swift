@testable import AstroApplication
import Foundation
import Testing

struct ResultsQueryTests {
    @Test("Result lineage names input series, calibration assets, software and parent")
    func fixtureLineageIsComplete() async throws {
        let snapshot = try await ResultsQuery.fixture().snapshot(projectID: .fixtureProject)
        let final = try #require(snapshot.results.first { $0.role == .final })

        #expect(!final.inputSeriesIDs.isEmpty)
        #expect(!final.calibrationAssets.isEmpty)
        #expect(final.softwareVersion != nil)
        #expect(final.parentResultID != nil)
        #expect(snapshot.publishableResultID == final.id)
    }

    @Test("Production results preserve parent and typed lineage from metadata")
    func metadataLineage() async throws {
        let store = try MetadataStore.temporary()
        let project = ProjectRecord(id: .fixtureProject, catalogID: "IC 1396", displayName: "Elephant's Trunk", phase: .processing)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = SeriesRecord(
            id: UUID(), projectID: project.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC · 261 mm", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil,
            gain: 100, offset: 50, binning: "1x1"
        )
        let parent = ResultRecord(id: UUID(), projectID: project.id, parentResultID: nil, kind: .stack, role: .intermediate, relativePath: "stacks/master.fit", createdAt: .now, softwareName: "Siril", softwareVersion: "1.4")
        let final = ResultRecord(id: UUID(), projectID: project.id, parentResultID: parent.id, kind: .processingVariant, role: .final, relativePath: "processed/final.fit", createdAt: .now, softwareName: "PixInsight", softwareVersion: "1.9")
        try await store.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series], results: [parent, final], lineageEdges: [
            .init(id: UUID(), resultID: parent.id, sourceKind: .series, sourceID: series.id),
            .init(id: UUID(), resultID: final.id, sourceKind: .result, sourceID: parent.id),
        ]))

        let snapshot = try await ResultsQuery(metadata: store).snapshot(projectID: project.id)
        let detail = try #require(snapshot.results.first { $0.id == final.id })
        #expect(detail.parentResultID == parent.id)
        #expect(detail.sourceResultIDs == [parent.id])
        #expect(snapshot.results.count == 2)
    }
}

private extension UUID {
    static let fixtureProject = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
}
