@testable import AstroApplication
import AstroCore
import Foundation
import Testing

@Suite("Scan workflow materializer")
struct ScanWorkflowMaterializerTests {
    @Test("A scanned IC 1396 night becomes project, night, distinct series and review frames")
    func materializesTypedWorkflow() async throws {
        let fixture = try MaterializerFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let metadata = try MetadataStore.temporary()
        let before = try await LibraryManifest.capture(root: fixture.root)

        let summary = try await ScanWorkflowMaterializer.materialize(
            indexDatabase: fixture.indexURL,
            metadata: metadata
        )

        let project = try #require(try await metadata.projects().first)
        let series = try await metadata.series(projectID: project.id)
        #expect(project.catalogID == "IC 1396")
        #expect(series.map(\.exposureSeconds).sorted() == [30, 120, 300])
        #expect(series.first { $0.exposureSeconds == 120 }?.filterName == "SV220")
        #expect(series.first { $0.exposureSeconds == 300 }?.passband == .dualBand)
        #expect(try await metadata.frameDecisions(seriesID: series[0].id).count > 0)
        #expect(summary.frames == 4)
        #expect(try await LibraryManifest.capture(root: fixture.root) == before)
    }

    @Test("Refreshing the scan preserves a human frame verdict")
    func refreshPreservesVerdict() async throws {
        let fixture = try MaterializerFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let metadata = try MetadataStore.temporary()
        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)
        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first { $0.exposureSeconds == 300 })
        let decision = try #require(try await metadata.frameDecisions(seriesID: series.id).first)
        try await metadata.save(FrameDecisionRecord(
            id: decision.id, seriesID: series.id, relativePath: decision.relativePath,
            verdict: .rejected, logicallyExcluded: true
        ))

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        #expect(try await metadata.frameDecision(id: decision.id)?.verdict == .rejected)
    }
}

private struct MaterializerFixture {
    let container: URL
    let root: URL
    let indexURL: URL

    static func make() throws -> Self {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-Materializer-\(UUID().uuidString)", isDirectory: true
        )
        let root = container.appendingPathComponent("library", isDirectory: true)
        let cache = container.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("source image bytes".utf8).write(to: root.appendingPathComponent("source.fit"))
        let indexURL = cache.appendingPathComponent("index.sqlite")
        let db = try Database(path: indexURL.path)
        for (index, exposure, filter) in [
            (1, 30.0, nil), (2, 120.0, "SV220"), (3, 300.0, "SV220"), (4, 300.0, "SV220")
        ] {
            let path = "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/frame_\(index).fit"
            let fileID = try db.upsertFile(FileRecord(
                path: path, size: 1024, mtime: Double(index), ext: "fit", kind: "fits",
                area: .sessions, target: "IC_1396_Elephants_Trunk_Nebula",
                sessionDate: "2026-08-08", role: .light, scannedAt: 1
            ))
            try db.upsertFITSMeta(FITSMetaRecord(
                fileID: fileID, exptime: exposure, gain: 100, offset: 50,
                instrume: "ZWO ASI2600MC Pro", focallen: 261, filter: filter,
                headerJSON: "{\"BAYERPAT\":\"RGGB\",\"XBINNING\":1}"
            ))
        }
        return Self(container: container, root: root, indexURL: indexURL)
    }
}
