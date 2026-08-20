@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// V3 5.4 (metadata fixer). Behavior-pinning proof for the
/// `ScanWorkflowMaterializer` → `CaptureResolver` routing refactor: this
/// suite exists to make every intentional output difference from the old
/// ad hoc "W7-D" raw-SQL precedence chain explicit and tested, rather than
/// discovered later as a silent regression. `ScanWorkflowMaterializerTests`
/// (`HeaderlessOSCPassbandPrecedenceTests` in particular) already pins every
/// case where the two chains AGREE; this file is only the cases where they
/// don't, plus the headline capability the refactor exists to deliver.
///
/// Summary of the parity finding:
/// 1. INTENTIONAL FLIP -- a capture group's declared signal mode now
///    outranks a raw FITS `FILTER` header value (previously the reverse).
///    `CaptureResolver`'s precedence (manual override > capture group >
///    FITS header) is V1's own established, unchanged engine; V2 used to
///    invert levels 1 and 2 of that chain.
/// 2. NEW CAPABILITY -- a manual per-file override recorded in
///    `file_capture_assignments` (V1's `AppState.assignCaptureMetadata`/CLI
///    write path) is now visible to V2 at all. It was structurally
///    impossible to see before: the old chain never queried that table.
/// 3. MINOR WIDENING -- `CaptureResolver`'s FITS-header filter-text
///    classification recognizes an explicit broadband marker vocabulary
///    ("uv/ir", "cls", "l-pro", ...) that the old inline classifier lacked
///    entirely; a broadband filter name used to fall through to `.other`
///    and now correctly resolves to `.broadband`.
/// Every other case (capture-slug text fallback, default-setup fallback,
/// mono/OSC absolute fallback, focal-length jitter bucketing, series
/// relinking) is unchanged -- see `ScanWorkflowMaterializerTests`.
@Suite("ScanWorkflowMaterializer <-> CaptureResolver parity")
struct ScanWorkflowMaterializerCaptureResolverParityTests {
    private static func makeFixture() throws -> (container: URL, indexURL: URL, db: Database) {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-ResolverParity-\(UUID().uuidString)", isDirectory: true
        )
        let cache = container.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let indexURL = cache.appendingPathComponent("index.sqlite")
        let db = try Database(path: indexURL.path)
        return (container, indexURL, db)
    }

    @discardableResult
    private static func insertLight(
        db: Database,
        target: String = "IC_1396_Elephants_Trunk_Nebula",
        sessionDate: String = "2026-08-08",
        path suffix: String = "frame_1.fit",
        filter: String?,
        bayerPattern: String? = "RGGB"
    ) throws -> Int64 {
        let path = "sessions/\(target)/\(sessionDate)/lights/\(suffix)"
        let fileID = try db.upsertFile(FileRecord(
            path: path, size: 1024, mtime: 1, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: sessionDate, role: .light, scannedAt: 1
        ))
        let headerJSON = bayerPattern.map { "{\"BAYERPAT\":\"\($0)\"}" }
        try db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, exptime: 300, gain: 100, offset: 50,
            instrume: "ZWO ASI2600MC Pro", focallen: 261, filter: filter,
            headerJSON: headerJSON
        ))
        return fileID
    }

    // MARK: - 1. Documented precedence flip

    @Test("Parity finding 1: a capture group's dual-band now beats a conflicting FITS Ha header (was the reverse)")
    func captureGroupBeatsConflictingFITSHeader() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "sv220-nb", displayName: "SV220 dual-band",
            sensorMode: .osc, signalMode: .dualBand
        ))
        // The frame lives under the group's own captures/<slug>/ folder so
        // the resolver's canonical-group path match applies -- the FITS
        // header explicitly disagrees (Ha, narrowband).
        let fileID = try fixture.db.upsertFile(FileRecord(
            path: "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/captures/sv220-nb/lights/frame_1.fit",
            size: 1024, mtime: 2, ext: "fit", kind: "fits",
            area: .sessions, target: "IC_1396_Elephants_Trunk_Nebula",
            sessionDate: "2026-08-08", role: .light, scannedAt: 1
        ))
        try fixture.db.upsertFITSMeta(FITSMetaRecord(
            fileID: fileID, exptime: 300, gain: 100, offset: 50,
            instrume: "ZWO ASI2600MC Pro", focallen: 261, filter: "Ha",
            headerJSON: "{\"BAYERPAT\":\"RGGB\"}"
        ))
        let metadata = try MetadataStore.temporary()

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let series = try await metadata.series(projectID: project.id)
        #expect(series.contains { $0.passband == .dualBand }, "the group-owned capture slug frame must resolve to the GROUP's dual-band, not the header's Ha")
    }

    // MARK: - 2. New capability: V1 override visibility

    @Test("Parity finding 2: a V1 manual override with a filter name override is visible in V2's series filterName")
    func v1OverrideVisibleInV2FilterName() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let fileID = try Self.insertLight(db: fixture.db, filter: nil, bayerPattern: nil)
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night", sensorMode: .unknown, signalMode: .unknown
        ))
        try fixture.db.upsertFileCaptureAssignment(FileCaptureAssignmentRecord(
            fileID: fileID, captureGroupID: groupID,
            signalModeOverride: .dualBand,
            filterManufacturerOverride: "Optolong", filterModelOverride: "L-eXtreme",
            assignmentSource: "app", assignedAt: 1
        ))
        let metadata = try MetadataStore.temporary()

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first)
        #expect(series.passband == .dualBand)
        #expect(series.filterName == "Optolong L-eXtreme")
    }

    @Test("Parity finding 2 (revocable): clearing the V1 assignment afterwards makes V2 fall back to the group's own declared value again")
    func clearingAssignmentRevertsV2ToGroupValue() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        // The frame lives under the group's OWN captures/<slug>/ folder, so
        // `CaptureResolver` can still resolve it to that group via the
        // canonical path match once the assignment is cleared -- unlike an
        // assignment-only linkage, which (correctly) disappears entirely
        // once the assignment is gone.
        let fileID = try fixture.db.upsertFile(FileRecord(
            path: "sessions/IC_1396_Elephants_Trunk_Nebula/2026-08-08/captures/canon-night/lights/frame_1.fit",
            size: 1024, mtime: 1, ext: "fit", kind: "fits",
            area: .sessions, target: "IC_1396_Elephants_Trunk_Nebula",
            sessionDate: "2026-08-08", role: .light, scannedAt: 1
        ))
        try fixture.db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: 300))
        let groupID = try fixture.db.upsertCaptureGroup(CaptureGroupRecord(
            target: "IC_1396_Elephants_Trunk_Nebula", sessionDate: "2026-08-08",
            slug: "canon-night", displayName: "Canon night",
            sensorMode: .unknown, signalMode: .narrowband, filterName: "Ha"
        ))
        try fixture.db.upsertFileCaptureAssignment(FileCaptureAssignmentRecord(
            fileID: fileID, captureGroupID: groupID, signalModeOverride: .dualBand,
            filterNameOverride: "L-eXtreme", assignmentSource: "app", assignedAt: 1
        ))
        let metadata = try MetadataStore.temporary()
        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)
        let project = try #require(try await metadata.projects().first)
        #expect(try await metadata.series(projectID: project.id).first?.passband == .dualBand)

        try fixture.db.clearFileCaptureAssignment(fileID: fileID)
        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let seriesAfterClear = try #require(try await metadata.series(projectID: project.id).first { $0.passband == .narrowband })
        #expect(seriesAfterClear.filterName == "Ha")
    }

    // MARK: - 3. Minor widening: broadband marker vocabulary

    @Test("Parity finding 3: an explicit broadband FITS filter name now resolves to .broadband instead of the old .other fallback")
    func broadbandFilterTextNowClassifiesAsBroadband() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try Self.insertLight(db: fixture.db, filter: "UV/IR Cut", bayerPattern: "RGGB")
        let metadata = try MetadataStore.temporary()

        _ = try await ScanWorkflowMaterializer.materialize(indexDatabase: fixture.indexURL, metadata: metadata)

        let project = try #require(try await metadata.projects().first)
        let series = try #require(try await metadata.series(projectID: project.id).first)
        #expect(series.passband == .broadband, "CaptureResolver's broadband marker vocabulary now classifies this correctly; the old inline classifier had no broadband bucket at all and fell back to .other")
    }
}
