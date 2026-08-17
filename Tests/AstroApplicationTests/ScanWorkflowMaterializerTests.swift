@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// File-local FITS header fixture -- mirrors `SessionConversionCommandTests`'
/// own `sessionConversionHeaderData` (this codebase's convention: each test
/// file keeps its own copy rather than sharing one).
private func scanWorkflowMaterializerTestFITSCard(_ s: String) -> String {
    s + String(repeating: " ", count: 80 - s.count)
}

private func scanWorkflowMaterializerTestFITSData(_ cards: [String]) -> Data {
    var text = cards.map(scanWorkflowMaterializerTestFITSCard).joined()
    let remainder = text.count % 2880
    if remainder != 0 {
        text += String(repeating: " ", count: 2880 - remainder)
    }
    return Data(text.utf8)
}

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

    @Test("Real-world session suffixes map to civil nights and non-date folders are ignored")
    func normalizesSessionFolderDates() async throws {
        let fixture = try MaterializerFixture.make(sessionDates: [
            "2026-05-24-2",
            "2026-03-15-OSC",
            "2026-03-15_hibas",
            "2026-02-25_2026-03-15",
            "light_frame_rating_report_assets",
        ])
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let metadata = try MetadataStore.temporary()

        let summary = try await ScanWorkflowMaterializer.materialize(
            indexDatabase: fixture.indexURL,
            metadata: metadata
        )

        #expect(summary.frames == 4)
        #expect(summary.nights == 3)
        #expect(Set(try await metadata.nights().map(\.localDate)) == [
            "2026-02-25", "2026-03-15", "2026-05-24",
        ])
    }

    @Test("Sidecars and exposureless intermediates do not become capture series")
    func ignoresFramesWithoutPositiveExposure() async throws {
        let fixture = try MaterializerFixture.make(
            sessionDates: ["2026-06-01"],
            exposure: 0
        )
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let metadata = try MetadataStore.temporary()

        let summary = try await ScanWorkflowMaterializer.materialize(
            indexDatabase: fixture.indexURL,
            metadata: metadata
        )

        #expect(summary == ScanWorkflowMaterializationSummary(
            projects: 0, nights: 0, series: 0, frames: 0
        ))
        #expect(try await metadata.projects().isEmpty)
        #expect(try await metadata.nights().isEmpty)
    }

    /// W3-10: end-to-end proof for the "New Session" sheet's own receipt
    /// message ("the session will appear once the first light frames are
    /// scanned into it") -- unlike every other fixture in this file (which
    /// inserts rows straight into the scan index DB), this one runs the
    /// REAL pipeline a user would actually trigger: `SessionCreator.create`
    /// makes the on-disk folder skeleton with zero files in it, a REAL
    /// `LibraryScanner.scan()` indexes that root exactly as a rescan would,
    /// and `ScanWorkflowMaterializer.materialize` reads that real index. An
    /// empty session must not fabricate a project/night/series/frame row
    /// from folder existence alone.
    @Test("A freshly created, still-empty session produces no project or night until real frames are scanned")
    func emptySessionProducesNothingUntilFramesExist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroTool-EmptySessionMaterializer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SessionCreator.create(root: root, catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-11")

        var config = AstroConfig()
        config.rootPath = root.path
        let indexURL = root.appendingPathComponent(".astro_tool/scan-index.sqlite")
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scanDB = try Database(path: indexURL.path)
        _ = try LibraryScanner(config: config, db: scanDB).scan()

        let metadata = try MetadataStore.temporary()
        let summary = try await ScanWorkflowMaterializer.materialize(indexDatabase: indexURL, metadata: metadata)

        #expect(summary == ScanWorkflowMaterializationSummary(projects: 0, nights: 0, series: 0, frames: 0))
        #expect(try await metadata.projects().isEmpty)
        #expect(try await metadata.nights().isEmpty)

        // Now drop a real light frame into the empty session and rescan --
        // the same folder DOES appear once real content exists, proving
        // this isn't a permanent blind spot, only an honest "not yet".
        let lightsDir = root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-11/lights")
        try scanWorkflowMaterializerTestFITSData([
            "SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2",
            "EXPTIME = 60", "IMAGETYP= 'LIGHT'", "END",
        ]).write(to: lightsDir.appendingPathComponent("light1.fit"))
        _ = try LibraryScanner(config: config, db: scanDB).scan()
        let secondSummary = try await ScanWorkflowMaterializer.materialize(indexDatabase: indexURL, metadata: metadata)

        #expect(secondSummary.projects == 1)
        #expect(secondSummary.nights == 1)
        #expect(try await metadata.nights().first?.localDate == "2026-08-11")
    }

    // MARK: - Scan completion freshness (wave 6 Task 15)

    @Test("A successful materialize records that V2 just looked at the library")
    func successfulMaterializeRecordsScanCompletion() async throws {
        let fixture = try MaterializerFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let metadata = try MetadataStore.temporary()
        #expect(try await metadata.lastScanCompletedAt() == nil)

        let before = Date()
        _ = try await ScanWorkflowMaterializer.materialize(
            indexDatabase: fixture.indexURL,
            metadata: metadata
        )
        let after = Date()

        let recorded = try await #require(metadata.lastScanCompletedAt())
        #expect(recorded >= before.addingTimeInterval(-1))
        #expect(recorded <= after.addingTimeInterval(1))
    }

    @Test("A materialize that never reaches the library index does not record a scan completion")
    func failedMaterializeDoesNotRecordScanCompletion() async throws {
        let metadata = try MetadataStore.temporary()
        let missingIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroTool-Materializer-Missing-\(UUID().uuidString).sqlite")

        await #expect(throws: (any Error).self) {
            _ = try await ScanWorkflowMaterializer.materialize(
                indexDatabase: missingIndex,
                metadata: metadata
            )
        }

        #expect(try await metadata.lastScanCompletedAt() == nil)
    }
}

private struct MaterializerFixture {
    let container: URL
    let root: URL
    let indexURL: URL

    static func make() throws -> Self {
        try make(sessionDates: nil)
    }

    static func make(sessionDates: [String]?, exposure customExposure: Double = 30) throws -> Self {
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
        let frames: [(Int, Double, String?, String)] = if let sessionDates {
            sessionDates.enumerated().map { index, date in (index + 1, customExposure, nil, date) }
        } else {
            [
                (1, 30.0, nil, "2026-08-08"),
                (2, 120.0, "SV220", "2026-08-08"),
                (3, 300.0, "SV220", "2026-08-08"),
                (4, 300.0, "SV220", "2026-08-08"),
            ]
        }
        for (index, exposure, filter, sessionDate) in frames {
            let path = "sessions/IC_1396_Elephants_Trunk_Nebula/\(sessionDate)/lights/frame_\(index).fit"
            let fileID = try db.upsertFile(FileRecord(
                path: path, size: 1024, mtime: Double(index), ext: "fit", kind: "fits",
                area: .sessions, target: "IC_1396_Elephants_Trunk_Nebula",
                sessionDate: sessionDate, role: .light, scannedAt: 1
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
