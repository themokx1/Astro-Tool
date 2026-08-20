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

// MARK: - W7-D: headerless OSC passband precedence
//
// The owner's real rig (ASI2600MC OSC through an SVBony SV220 duoband,
// driven by ASI Air) never writes a FITS `FILTER` header at all -- ASI Air
// simply doesn't know about a filter it never switches. Before this fix,
// `ScannedFrame.passband` treated "headerless" as "no filter used" and
// guessed `.broadband` for every one of those OSC frames, hiding the
// dual-band nature of a real, already-tagged (`captures/sv220_dual-band/`)
// session from FilterAdvisor and per-filter stats. These five tests pin the
// exact precedence `ScanWorkflowMaterializer.materialize` documents on
// `ScannedFrame.passband`: FITS header > capture group > capture slug >
// default setup > unfiltered/broadband guess.
@Suite("W7-D headerless OSC passband precedence")
struct HeaderlessOSCPassbandPrecedenceTests {
    private struct PrecedenceFixture {
        let container: URL
        let indexURL: URL
        let db: Database
    }

    private static func makeFixture() throws -> PrecedenceFixture {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-W7D-Materializer-\(UUID().uuidString)", isDirectory: true
        )
        let cache = container.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let indexURL = cache.appendingPathComponent("index.sqlite")
        let db = try Database(path: indexURL.path)
        return PrecedenceFixture(container: container, indexURL: indexURL, db: db)
    }

    /// Inserts one headerless (`filter: nil`) OSC light frame, optionally
    /// under a `captures/<slug>/` folder -- `slug: nil` reproduces a classic
    /// non-capture-aware session path.
    @discardableResult
    private static func insertHeaderlessOSCFrame(
        db: Database,
        target: String = "IC_1396_Elephants_Trunk_Nebula",
        sessionDate: String = "2026-08-08",
        slug: String?,
        index: Int = 1
    ) throws -> Int64 {
        let path = if let slug {
            "sessions/\(target)/\(sessionDate)/captures/\(slug)/lights/frame_\(index).fit"
        } else {
            "sessions/\(target)/\(sessionDate)/lights/frame_\(index).fit"
        }
        let fileID = try db.upsertFile(FileRecord(
            path: path, size: 1024, mtime: Double(index), ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: sessionDate, role: .light, scannedAt: 1
        ))
        try db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, exptime: 300, gain: 100, offset: 50,
            instrume: "ZWO ASI2600MC Pro", focallen: 261, filter: nil,
            headerJSON: "{\"BAYERPAT\":\"RGGB\",\"XBINNING\":1}"
        ))
        return fileID
    }

    @Test("A headerless OSC frame in an sv220_dual-band capture folder inherits dual-band from its capture group")
    func inheritsPassbandFromCaptureGroup() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try Self.insertHeaderlessOSCFrame(
            db: fixture.db, sessionDate: "2026-08-08", slug: "sv220_dual-band"
        )
        try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "sv220_dual-band", displayName: "SV220 dual-band",
            sensorMode: .osc, signalMode: .dualBand,
            filterManufacturer: "SVBONY", filterModel: "SV220"
        ))
        let metadata = try MetadataStore.temporary()

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first)
        #expect(series.passband == .dualBand)
    }

    // V3 5.4 (metadata fixer, CaptureResolver routing): before this
    // refactor, a raw FITS `FILTER` header value always outranked a capture
    // group's own declared signal mode here (this test used to assert
    // `.narrowband` for exactly this fixture). Routing through V1's
    // `CaptureResolver` intentionally FLIPS that precedence -- a capture
    // group is human-curated, first-class metadata; a raw FITS `FILTER`
    // string can simply be wrong or stale, and `CaptureResolver` (V1's own
    // mature engine, unchanged by this refactor) has always treated the
    // group as more authoritative than the header. This is the ONE
    // documented, intentional parity difference the refactor introduces --
    // see `ScanWorkflowMaterializerCaptureResolverParityTests` for the
    // full before/after picture, including the conflict this now surfaces.
    @Test("A capture group's declared signal mode now outranks a raw FITS FILTER header value (documented precedence flip)")
    func captureGroupOutranksFITSHeaderAfterResolverRouting() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let fileID = try Self.insertHeaderlessOSCFrame(
            db: fixture.db, sessionDate: "2026-08-08", slug: "sv220_dual-band"
        )
        // The group says dual-band, the (unusual but possible) header says
        // narrowband -- `CaptureResolver` now resolves this to the GROUP's
        // dual-band, with a conflict recorded internally (not surfaced by
        // `ScanWorkflowMaterializationSummary`, but visible via
        // `CaptureAssignmentQuery`/`CaptureResolver` directly).
        try fixture.db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, exptime: 300, gain: 100, offset: 50,
            instrume: "ZWO ASI2600MC Pro", focallen: 261, filter: "Ha",
            headerJSON: "{\"BAYERPAT\":\"RGGB\"}"
        ))
        try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "sv220_dual-band", displayName: "SV220 dual-band",
            sensorMode: .osc, signalMode: .dualBand
        ))
        let metadata = try MetadataStore.temporary()

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first)
        #expect(series.passband == .dualBand)
    }

    // The headline fix this refactor exists for: a manual per-file override
    // made through V1 (`file_capture_assignments`, e.g. via `AppState.
    // assignCaptureMetadata`/the CLI) used to be completely invisible to V2
    // -- the old chain never queried that table at all. It now wins over
    // BOTH the capture group and the FITS header, exactly as `CaptureResolver
    // .resolve` already guaranteed for V1 surfaces.
    @Test("A V1 manual per-file override is now visible to V2's series filter/passband, outranking both the capture group and the FITS header")
    func manualOverrideFromV1IsNowVisibleToV2() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let fileID = try Self.insertHeaderlessOSCFrame(
            db: fixture.db, sessionDate: "2026-08-08", slug: "sv220_dual-band"
        )
        try fixture.db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, exptime: 300, gain: 100, offset: 50,
            instrume: "ZWO ASI2600MC Pro", focallen: 261, filter: "Ha",
            headerJSON: "{\"BAYERPAT\":\"RGGB\"}"
        ))
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "sv220_dual-band", displayName: "SV220 dual-band",
            sensorMode: .osc, signalMode: .dualBand
        ))
        // The owner corrects this ONE frame by hand in V1: it's actually
        // narrowband (e.g. a filter swap mid-session the group's own default
        // doesn't reflect), with an explicit filter name.
        try fixture.db.upsertFileCaptureAssignment(FileCaptureAssignmentRecord(
            fileID: fileID, captureGroupID: groupID,
            signalModeOverride: .narrowband,
            filterNameOverride: "Ha 6nm",
            assignmentSource: "app", assignedAt: 1
        ))
        let metadata = try MetadataStore.temporary()

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first)
        #expect(series.passband == .narrowband)
        #expect(series.filterName == "Ha 6nm")
    }

    @Test("A headerless frame in a captures/ folder with no matching capture group still reads dual-band from the slug name")
    func inheritsPassbandFromCaptureSlugWhenNoGroupRowExists() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        // Deliberately no `upsertCaptureGroup` call: the folder was renamed
        // by hand, or the group was never created in the app.
        try Self.insertHeaderlessOSCFrame(
            db: fixture.db, sessionDate: "2026-08-08", slug: "sv220_dual-band"
        )
        let metadata = try MetadataStore.temporary()

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first)
        #expect(series.passband == .dualBand)
    }

    @Test("A headerless OSC frame outside any captures/ folder falls back to the default setup's configured filter")
    func fallsBackToDefaultSetupSignalMode() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try Self.insertHeaderlessOSCFrame(db: fixture.db, sessionDate: "2026-08-08", slug: nil)
        let metadata = try MetadataStore.temporary()
        let setup = ImagingSetupProfile(
            id: "asi2600mc", name: "ASI2600MC train", cameraName: "ZWO ASI2600MC Pro",
            cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.7,
            focalLengthMinMM: 261, focalLengthMaxMM: 261, defaultFocalLengthMM: 261,
            isDefault: true, defaultFilterSignalMode: .dualBand, defaultFilterName: "SV220"
        )

        _ = try await ScanWorkflowMaterializer.materialize(
            indexDatabase: fixture.indexURL, metadata: metadata, imagingSetups: [setup]
        )

        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first)
        #expect(series.passband == .dualBand)
    }

    @Test("With no header, capture group, slug, or setup default, a headerless OSC frame still guesses broadband")
    func absoluteFallbackStaysBroadbandForOSC() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try Self.insertHeaderlessOSCFrame(db: fixture.db, sessionDate: "2026-08-08", slug: nil)
        let metadata = try MetadataStore.temporary()

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first)
        #expect(series.passband == .broadband)
    }

    @Test("The default setup's filter fallback never applies to a mono frame")
    func setupDefaultNeverAppliesToMono() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let fileID = try fixture.db.upsertFile(FileRecord(
            path: "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/frame_1.fit",
            size: 1024, mtime: 1, ext: "fit", kind: "fits",
            area: .sessions, target: "IC_1396_Elephants_Trunk_Nebula",
            sessionDate: "2026-08-08", role: .light, scannedAt: 1
        ))
        // No BAYERPAT in the header JSON at all -- a mono frame.
        try fixture.db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, exptime: 300, gain: 100, offset: 50,
            instrume: "ZWO ASI2600MM Pro", focallen: 261, filter: nil,
            headerJSON: "{\"XBINNING\":1}"
        ))
        let metadata = try MetadataStore.temporary()
        let setup = ImagingSetupProfile(
            id: "asi2600mm", name: "ASI2600MM train", cameraName: "ZWO ASI2600MM Pro",
            cameraKind: .monochrome, sensorWidthMM: 23.5, sensorHeightMM: 15.7,
            focalLengthMinMM: 261, focalLengthMaxMM: 261, defaultFocalLengthMM: 261,
            isDefault: true, defaultFilterSignalMode: .dualBand
        )

        _ = try await ScanWorkflowMaterializer.materialize(
            indexDatabase: fixture.indexURL, metadata: metadata, imagingSetups: [setup]
        )

        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first)
        #expect(series.passband == .unfiltered)
    }
}

// MARK: - W7-C: ASI Air plate-solve FOCALLEN jitter must not fragment one rig
//
// The owner's real ASI2600MC Pro rig has ASI Air rewriting FOCALLEN by a few
// percent across nights as its plate-solve refines it (255/256/261/262 mm
// verified as one physical rig). Before this fix, the V2 series builder's
// `setupDescriptor` embedded the raw, un-bucketed focal length, so this one
// rig split into a distinct "series-setup" per jittered night -- exactly the
// "133mm; 134mm; 135mm" project-header symptom the W7-C audit found.
@Suite("W7-C focal-length jitter unification")
struct FocalLengthJitterMaterializerTests {
    private static func insertJitteredLight(
        db: Database, target: String, sessionDate: String, name: String, focallen: Double
    ) throws {
        let path = "sessions/\(target)/\(sessionDate)/lights/\(name).fit"
        let fileID = try db.upsertFile(FileRecord(
            path: path, size: 1024, mtime: 1, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: sessionDate, role: .light, scannedAt: 1
        ))
        try db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, exptime: 300, gain: 100, offset: 50,
            instrume: "ZWO ASI2600MC Pro", focallen: focallen, filter: "SV220",
            headerJSON: "{\"BAYERPAT\":\"RGGB\",\"XBINNING\":1}"
        ))
    }

    @Test("Four nights of ASI-Air plate-solve jitter (255/256/261/262 mm) become ONE series, not four")
    func jitteredFocalLengthsAcrossNightsCollapseToOneSeries() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-W7C-Materializer-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let cache = container.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let indexURL = cache.appendingPathComponent("index.sqlite")
        let db = try Database(path: indexURL.path)

        let target = "IC_1396_Elephants_Trunk_Nebula"
        for (date, focallen) in [
            ("2026-08-01", 255.0), ("2026-08-02", 256.0), ("2026-08-03", 261.0), ("2026-08-04", 262.0),
        ] {
            try Self.insertJitteredLight(db: db, target: target, sessionDate: date, name: "a", focallen: focallen)
        }
        let metadata = try MetadataStore.temporary()

        let summary = try await ScanWorkflowMaterializer.materialize(indexDatabase: indexURL, metadata: metadata)

        #expect(summary.frames == 4)
        #expect(summary.nights == 4)
        let project = try #require(try await metadata.projects().first)
        let series = try await metadata.series(projectID: project.id)
        #expect(series.count == 4, "one series per night is still expected -- the fix is about the SETUP, not the night grouping")
        #expect(Set(series.map(\.setupDescriptor)).count == 1, "255/256/261/262 mm are one physical rig -- must be ONE setup descriptor across all four nights")
    }

    @Test("A genuinely different optical train (135 mm vs 261 mm) still gets its own series-setup")
    func genuinelyDifferentFocalLengthStaysItsOwnSetup() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-W7C-Materializer-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: container) }
        let cache = container.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let indexURL = cache.appendingPathComponent("index.sqlite")
        let db = try Database(path: indexURL.path)

        let target = "IC_1396_Elephants_Trunk_Nebula"
        try Self.insertJitteredLight(db: db, target: target, sessionDate: "2026-08-01", name: "a", focallen: 261)
        try Self.insertJitteredLight(db: db, target: target, sessionDate: "2026-08-02", name: "a", focallen: 135)
        let metadata = try MetadataStore.temporary()

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let series = try await metadata.series(projectID: project.id)
        #expect(Set(series.map(\.setupDescriptor)).count == 2, "a 261 mm night and a 135 mm night are different optics -- must stay two setups")
    }
}

// MARK: - W7-G: a rescan that changes a series' derived identity must not
// orphan the owner's triage decisions
//
// W7-D (filter inheritance) and W7-C (focal-length bucketing) both
// deliberately change what `setupDescriptor`/`passband` derive to for most
// existing series. `ScanWorkflowMaterializer` upserts series by a stable ID
// derived from `SeriesKey.identity`, which embeds those derived fields -- so
// the very next Beolvasás after either fix ships mints a NEW series id for
// the same physical frames, while `FrameDecisionRecord` stays keyed to the
// OLD series id. Before the relink fix below, this either orphans the
// decision (unreachable from the new series) or, worse, crashes the whole
// scan outright: `frame_decisions.relative_path` is globally `UNIQUE`, so
// inserting a fresh placeholder decision for a path that already has one
// under the old, now-abandoned series id violates that constraint and rolls
// back the entire materialize transaction -- losing every project, night,
// series and decision the scan would otherwise have written, not just the
// one row.
@Suite("W7-G rescan identity change relinks triage decisions")
struct RescanIdentityChangeRelinkTests {
    private static func makeFixture() throws -> (container: URL, indexURL: URL, db: Database) {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-W7G-Materializer-\(UUID().uuidString)", isDirectory: true
        )
        let cache = container.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let indexURL = cache.appendingPathComponent("index.sqlite")
        let db = try Database(path: indexURL.path)
        return (container, indexURL, db)
    }

    private static let path = "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/frame_1.fit"

    @discardableResult
    private static func upsertFrame(db: Database, filter: String?) throws -> Int64 {
        let fileID = try db.upsertFile(FileRecord(
            path: path, size: 1024, mtime: 1, ext: "fit", kind: "fits",
            area: .sessions, target: "IC_1396_Elephants_Trunk_Nebula",
            sessionDate: "2026-08-08", role: .light, scannedAt: 1
        ))
        try db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, exptime: 300, gain: 100, offset: 50,
            instrume: "ZWO ASI2600MC Pro", focallen: 261, filter: filter,
            headerJSON: "{\"BAYERPAT\":\"RGGB\",\"XBINNING\":1}"
        ))
        return fileID
    }

    @Test("A rescan that changes the derived setup/passband relinks the owner's existing accept decision onto the new series, instead of orphaning it or crashing the scan")
    func rescanRelinksDecisionAfterDerivationChange() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        // First scan: headerless -- guessed broadband (OSC, no captures/ slug,
        // no setup default).
        try Self.upsertFrame(db: fixture.db, filter: nil)
        let metadata = try MetadataStore.temporary()
        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let firstSeries = try #require(try await metadata.series(projectID: project.id).first)
        let firstDecision = try #require(try await metadata.frameDecisions(seriesID: firstSeries.id).first)
        #expect(firstDecision.relativePath == Self.path)
        // The owner triages the frame BEFORE the next rescan.
        try await metadata.save(FrameDecisionRecord(
            id: firstDecision.id, seriesID: firstSeries.id, relativePath: firstDecision.relativePath,
            verdict: .accepted, logicallyExcluded: false
        ))

        // A FILTER value now resolves for the same physical frame (the real
        // W7-D/W7-C trigger is a derivation-input change, not a header edit,
        // but any change that shifts `SeriesKey.identity` reproduces the
        // exact same hazard) -- passband/`setupDescriptor` inputs shift, so
        // the series this frame belongs to gets a brand-new stable id.
        try Self.upsertFrame(db: fixture.db, filter: "Ha")

        let summary = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        #expect(summary.frames == 1)
        let newSeries = try #require(try await metadata.series(projectID: project.id).first { $0.passband == .narrowband })
        #expect(newSeries.id != firstSeries.id, "the derivation change must actually mint a new series id, or this test isn't exercising the hazard")
        let relinked = try #require(try await metadata.frameDecisions(seriesID: newSeries.id).first { $0.relativePath == Self.path })
        #expect(relinked.id == firstDecision.id, "the SAME decision row must move, not a fresh placeholder alongside it")
        #expect(relinked.verdict == .accepted, "the owner's accept must survive the rescan")
        #expect(relinked.logicallyExcluded == false)
        #expect(
            try await metadata.series(id: firstSeries.id) == nil,
            "the old series is now fully empty (its one frame relinked away) -- it must be garbage-collected, not left as a dangling husk"
        )
    }

    @Test("A partial split -- only SOME of a series' frames get a new descriptor -- relinks each decision to ITS OWN new series and keeps the old series alive for what's left behind")
    func partialSplitFollowsEachFileToItsOwnSeries() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let movingPath = Self.path
        let stayingPath = "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/lights/frame_2.fit"
        try Self.upsertFrame(db: fixture.db, filter: nil)
        try fixture.db.upsertFITSMeta(FITSMetaRecord(
            fileID: try fixture.db.upsertFile(FileRecord(
                path: stayingPath, size: 1024, mtime: 2, ext: "fit", kind: "fits",
                area: .sessions, target: "IC_1396_Elephants_Trunk_Nebula",
                sessionDate: "2026-08-08", role: .light, scannedAt: 1
            )),
            exptime: 300, gain: 100, offset: 50,
            instrume: "ZWO ASI2600MC Pro", focallen: 261, filter: nil,
            headerJSON: "{\"BAYERPAT\":\"RGGB\",\"XBINNING\":1}"
        ))
        let metadata = try MetadataStore.temporary()
        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let originalSeries = try #require(try await metadata.series(projectID: project.id).first)
        let movingDecision = try #require(
            try await metadata.frameDecisions(seriesID: originalSeries.id).first { $0.relativePath == movingPath }
        )
        let stayingDecision = try #require(
            try await metadata.frameDecisions(seriesID: originalSeries.id).first { $0.relativePath == stayingPath }
        )
        try await metadata.save(FrameDecisionRecord(
            id: movingDecision.id, seriesID: originalSeries.id, relativePath: movingPath,
            verdict: .accepted, logicallyExcluded: false
        ))
        try await metadata.save(FrameDecisionRecord(
            id: stayingDecision.id, seriesID: originalSeries.id, relativePath: stayingPath,
            verdict: .rejected, logicallyExcluded: true
        ))

        // Only the first frame's derivation changes -- the second keeps its
        // original (headerless, broadband-guessed) identity untouched, so
        // the original series survives this rescan with exactly one frame
        // still legitimately in it.
        try Self.upsertFrame(db: fixture.db, filter: "Ha")

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let survivingOriginal = try #require(try await metadata.series(id: originalSeries.id))
        let survivingDecisions = try await metadata.frameDecisions(seriesID: survivingOriginal.id)
        #expect(survivingDecisions.map(\.relativePath) == [stayingPath])
        #expect(survivingDecisions.first?.verdict == .rejected, "the frame that never moved keeps its own decision, untouched")

        let newSeries = try #require(try await metadata.series(projectID: project.id).first { $0.id != originalSeries.id })
        let movedDecision = try #require(
            try await metadata.frameDecisions(seriesID: newSeries.id).first { $0.relativePath == movingPath }
        )
        #expect(movedDecision.id == movingDecision.id)
        #expect(movedDecision.verdict == .accepted, "the frame that moved keeps ITS OWN decision, following it to the new series")
    }

    @Test("Rescanning twice in a row with no further change is a true no-op")
    func secondConsecutiveRescanIsANoOp() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try Self.upsertFrame(db: fixture.db, filter: nil)
        let metadata = try MetadataStore.temporary()
        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)
        let project = try #require(try await metadata.projects().first)
        let firstSeries = try #require(try await metadata.series(projectID: project.id).first)
        let firstDecision = try #require(try await metadata.frameDecisions(seriesID: firstSeries.id).first)
        try await metadata.save(FrameDecisionRecord(
            id: firstDecision.id, seriesID: firstSeries.id, relativePath: firstDecision.relativePath,
            verdict: .accepted, logicallyExcluded: false
        ))
        try Self.upsertFrame(db: fixture.db, filter: "Ha")
        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)
        let afterFirstRescan = try await metadata.series(projectID: project.id)
        let afterFirstDecisions = try await metadata.allFrameDecisions()

        // A THIRD materialize call, with nothing changed on disk or in the
        // index since the second -- must leave everything exactly as it is:
        // no new series minted, the already-relinked decision untouched, and
        // the already-deleted orphan does not somehow reappear.
        let summary = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        #expect(summary.frames == 1)
        #expect(try await metadata.series(projectID: project.id) == afterFirstRescan)
        #expect(try await metadata.allFrameDecisions() == afterFirstDecisions)
        #expect(try await metadata.series(id: firstSeries.id) == nil, "the orphan stays deleted -- it must not be resurrected by a later no-op rescan")
    }

    @Test("A decision's relative_path never ends up duplicated across repeated derivation-changing rescans")
    func relativePathNeverDuplicatesAcrossRepeatedRescans() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let metadata = try MetadataStore.temporary()
        // `frame_decisions.relative_path` is globally UNIQUE in the schema,
        // so there is exactly one legitimate row per path at any moment --
        // the "collision" the relink pass must avoid is ever trying to
        // INSERT a second row for a path that already has one (which is
        // exactly what crashed the whole scan before this fix). The rule
        // this pass follows is: always UPDATE that one row's `seriesID` in
        // place rather than mint a new id, so a duplicate is structurally
        // impossible rather than merely avoided by luck. Cycling the same
        // frame's derivation back and forth across several rescans is the
        // stress case that would surface a regression here.
        for filter in [nil, "Ha", "OIII", nil, "Ha"] {
            try Self.upsertFrame(db: fixture.db, filter: filter)
            _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)
            let decisionsForPath = try await metadata.allFrameDecisions().filter { $0.relativePath == Self.path }
            #expect(decisionsForPath.count == 1, "exactly one decision row must exist for \(Self.path) after filter=\(filter ?? "nil")")
        }
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
