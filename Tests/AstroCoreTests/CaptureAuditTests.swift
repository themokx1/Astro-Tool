import Foundation
import Testing
@testable import AstroCore

private func captureAuditContext(
    files: [FileRecord],
    meta: [Int64: FITSMetaRecord] = [:],
    groups: [CaptureGroupRecord] = [],
    sources: [CaptureSourceRecord] = [],
    assignments: [FileCaptureAssignmentRecord] = []
) -> AuditContext {
    AuditContext(
        config: AstroConfig(), files: files, directories: [], fitsMetaByFileID: meta,
        captureGroups: groups, captureSources: sources,
        fileCaptureAssignments: Dictionary(uniqueKeysWithValues: assignments.map { ($0.fileID, $0) })
    )
}

private func auditFile(
    id: Int64, path: String, role: FrameRole, area: LibraryArea = .sessions
) -> FileRecord {
    FileRecord(
        id: id, path: path, size: 100, mtime: 1, ext: "fit", kind: "fits",
        area: area, target: "IC_1396", sessionDate: "2026-08-08", role: role,
        scannedAt: 2
    )
}

@Test func captureAuditFlagsUnassignedLightsAndAmbiguousFlatsOnlyInExplicitMixedSessions() {
    let groups = [
        CaptureGroupRecord(
            id: 1, target: "IC_1396", sessionDate: "2026-08-08", slug: "osc",
            displayName: "OSC", sensorMode: .osc, signalMode: .broadband
        ),
        CaptureGroupRecord(
            id: 2, target: "IC_1396", sessionDate: "2026-08-08", slug: "sv220",
            displayName: "SV220", sensorMode: .osc, signalMode: .dualBand,
            filterManufacturer: "SVBONY", filterModel: "SV220"
        ),
    ]
    let context = captureAuditContext(
        files: [
            auditFile(id: 10, path: "sessions/IC_1396/2026-08-08/lights/unassigned.fit", role: .light),
            auditFile(id: 11, path: "sessions/IC_1396/2026-08-08/flats/flat.fit", role: .flat),
        ],
        groups: groups
    )

    let findings = CaptureClassificationRule().evaluate(context)

    #expect(findings.contains { $0.category == "capture-unassigned-light" && $0.path.hasSuffix("unassigned.fit") })
    #expect(findings.contains { $0.category == "capture-ambiguous-flat" && $0.path.hasSuffix("flat.fit") })
    #expect(findings.allSatisfy { $0.suggestion == nil })
}

@Test func captureAuditFlagsNarrowbandGroupWithoutAnExactFilter() {
    let group = CaptureGroupRecord(
        id: 1, target: "IC_1396", sessionDate: "2026-08-08", slug: "nb",
        displayName: "NB gyűjtés", sensorMode: .osc, signalMode: .narrowband
    )

    let findings = CaptureClassificationRule().evaluate(
        captureAuditContext(files: [], groups: [group])
    )

    #expect(findings.contains { $0.category == "capture-missing-filter" && $0.path.contains("/captures/nb") })
}

@Test func captureAuditExplainsResolvedHeaderConflictAndNeverMovesAnything() {
    let group = CaptureGroupRecord(
        id: 1, target: "IC_1396", sessionDate: "2026-08-08", slug: "sv220",
        displayName: "SV220", sensorMode: .osc, signalMode: .dualBand,
        filterManufacturer: "SVBONY", filterModel: "SV220"
    )
    let file = auditFile(
        id: 10,
        path: "sessions/IC_1396/2026-08-08/captures/sv220/lights/a.fit",
        role: .light
    )
    let findings = CaptureClassificationRule().evaluate(
        captureAuditContext(files: [file], meta: [10: FITSMetaRecord(fileID: 10, filter: "UV/IR")], groups: [group])
    )

    let conflict = findings.first { $0.category == "capture-metadata-conflict" }
    #expect(conflict?.message.contains("FITS FILTER") == true)
    #expect(conflict?.suggestion == nil)
}

@Test func classicImplicitSessionDoesNotReceiveCaptureNoise() {
    let file = auditFile(
        id: 10, path: "sessions/IC_1396/2026-08-08/lights/a.fit", role: .light
    )
    #expect(CaptureClassificationRule().evaluate(captureAuditContext(files: [file])).isEmpty)
}
