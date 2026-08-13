@testable import AstroApplication
import Foundation
import Testing

struct ReviewQueryTests {
    @Test("IC 1396 keeps 5, 30, 120 and 300 second series separate")
    func ic1396SeriesRemainSeparate() async throws {
        let fixture = try await ReviewFixture.make()
        let snapshot = try await ReviewQuery(metadata: fixture.metadata).project(fixture.project.id)

        #expect(snapshot.series.map(\.series.exposureSeconds) == [5, 30, 120, 300])
        #expect(snapshot.series.first { $0.series.exposureSeconds == 120 }?.series.filterName == "SV220")
        #expect(snapshot.series.first { $0.series.exposureSeconds == 300 }?.series.filterName == "SV220")
    }

    @Test("Rejecting a frame is logical metadata and never moves the source file")
    func rejectPreservesLibraryManifest() async throws {
        let fixture = try await ReviewFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try await LibraryManifest.capture(root: fixture.root)
        let commands = ReviewCommands(metadata: fixture.metadata)

        let decision = try await commands.setVerdict(
            seriesID: fixture.series[0].id,
            relativePath: "IC_1396/2026-08-08/lights/frame.fit",
            verdict: .rejected
        )

        #expect(decision.logicallyExcluded)
        #expect(try await LibraryManifest.capture(root: fixture.root) == before)
        #expect(try await fixture.metadata.frameDecision(id: decision.id) == decision)
    }
}

private struct ReviewFixture {
    let root: URL
    let metadata: MetadataStore
    let project: ProjectRecord
    let series: [SeriesRecord]

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-Review-\(UUID().uuidString)", isDirectory: true
        )
        let lights = root.appendingPathComponent("IC_1396/2026-08-08/lights", isDirectory: true)
        try FileManager.default.createDirectory(at: lights, withIntermediateDirectories: true)
        try Data("frame".utf8).write(to: lights.appendingPathComponent("frame.fit"))
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let exposures: [(Double, String?)] = [(5, nil), (30, nil), (120, "SV220"), (300, "SV220")]
        let series = exposures.map { exposure, filter in
            SeriesRecord(id: UUID(), projectID: project.id, nightID: night.id,
                setupID: "asi2600mc-261", setupDescriptor: "ASI2600MC · 261 mm",
                sensorMode: .osc, passband: filter == nil ? .broadband : .dualBand,
                exposureSeconds: exposure, filterName: filter, filterID: nil,
                gain: 100, offset: 50, binning: "1x1")
        }
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: series))
        return Self(root: root, metadata: metadata, project: project, series: series)
    }
}
