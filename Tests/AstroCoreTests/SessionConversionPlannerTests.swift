import Foundation
import Testing
@testable import AstroCore

private let conversionScope = SessionConversionScope(target: "IC_1396", date: "2026-08-08")

private func conversionFile(
    _ path: String,
    id: Int64,
    size: Int64 = 1_000,
    mtime: Double = 100
) -> FileRecord {
    let info = PathClassifier.classify(relativePath: path)
    return FileRecord(
        id: id,
        path: path,
        size: size,
        mtime: mtime,
        ext: (path as NSString).pathExtension.lowercased(),
        kind: path.lowercased().hasSuffix(".fit") ? "fits" : "image",
        area: info.area,
        target: info.target,
        sessionDate: info.dateRaw,
        role: info.role,
        scannedAt: 101,
        inode: id,
        nlink: 1
    )
}

private func bayerMeta(fileID: Int64, exposure: Double?, filter: String? = nil) -> FITSMetaRecord {
    FITSMetaRecord(
        fileID: fileID,
        exptime: exposure,
        instrume: "ZWO ASI2600MC Pro",
        filter: filter,
        headerJSON: "{\"BAYERPAT\":\"RGGB\"}"
    )
}

private func ic1396ConversionFixture() -> (files: [FileRecord], meta: [Int64: FITSMetaRecord]) {
    var files: [FileRecord] = []
    var meta: [Int64: FITSMetaRecord] = [:]
    var id: Int64 = 1

    for index in 1...32 {
        let file = conversionFile(
            "sessions/IC_1396/2026-08-08/lights_osc/Light_OSC_\(index).fit",
            id: id
        )
        files.append(file)
        meta[id] = bayerMeta(fileID: id, exposure: 30)
        id += 1
    }
    for index in 1...3 {
        let file = conversionFile(
            "sessions/IC_1396/2026-08-08/lights/Light_120s_\(index).fit",
            id: id
        )
        files.append(file)
        meta[id] = bayerMeta(fileID: id, exposure: 120)
        id += 1
    }
    for index in 1...46 {
        let file = conversionFile(
            "sessions/IC_1396/2026-08-08/lights/Light_300s_\(index).fit",
            id: id
        )
        files.append(file)
        meta[id] = bayerMeta(fileID: id, exposure: 300)
        id += 1
    }
    for stackNumber in [2, 12] {
        let file = conversionFile(
            "sessions/IC_1396/2026-08-08/lights/Stacked\(stackNumber)_Mu_Cephei_300.0s.fit",
            id: id
        )
        files.append(file)
        meta[id] = bayerMeta(fileID: id, exposure: 300)
        id += 1
    }
    for (index, exposure) in [1.7, 1.7, 3.8, 3.8].enumerated() {
        let file = conversionFile(
            "sessions/IC_1396/2026-08-08/flats/Flat_\(index).fit",
            id: id
        )
        files.append(file)
        meta[id] = bayerMeta(fileID: id, exposure: exposure)
        id += 1
    }
    files.append(conversionFile("stacks/IC_1396/2026-08-08/IC1396_osc.fit", id: id))
    id += 1
    files.append(conversionFile("processed/IC_1396/2026-08-08/OSC/final.tif", id: id))
    return (files, meta)
}

@Test func plannerRejectsAnyFileOutsideExactTargetDateScope() {
    let wrongDate = conversionFile(
        "sessions/IC_1396/2026-08-09/lights/a.fit",
        id: 1
    )
    #expect(throws: AstroError.self) {
        try SessionConversionPlanner.plan(
            scope: conversionScope,
            files: [wrongDate],
            meta: [:],
            existingGroups: [],
            existingSources: [],
            assignments: [:],
            mode: .logicalOnly
        )
    }
}

@Test func ic1396PreviewSeparatesOSCAndUnknownFilteredCaptureAndFlagsAmbiguousFlats() throws {
    let fixture = ic1396ConversionFixture()
    let plan = try SessionConversionPlanner.plan(
        scope: conversionScope,
        files: fixture.files,
        meta: fixture.meta,
        existingGroups: [],
        existingSources: [],
        assignments: [:],
        mode: .logicalOnly
    )

    #expect(plan.proposedGroups.count == 2)
    let osc = try #require(plan.detectedClusters.first { $0.proposedGroupSlug == "osc-30s" })
    #expect(osc.rawFramePaths.count == 32)
    #expect(osc.exposureBreakdown == ["30.0": 32])
    #expect(osc.artifactPaths.isEmpty)

    let unknown = try #require(plan.detectedClusters.first { $0.proposedGroupSlug != "osc-30s" })
    #expect(unknown.rawFramePaths.count == 49)
    #expect(unknown.exposureBreakdown == ["120.0": 3, "300.0": 46])
    #expect(unknown.artifactPaths.count == 2)
    #expect(unknown.artifactPaths.allSatisfy { $0.contains("/Stacked") })

    #expect(plan.summary.rawFrameCount == 81)
    #expect(plan.summary.artifactCount == 4) // 2 Stacked + stack output + processed output
    #expect(plan.summary.integrationSeconds == 15_120)
    #expect(plan.moves.isEmpty)
    #expect(plan.ambiguities.contains { ambiguity in
        ambiguity.kind == .calibrationAssignment
            && ambiguity.affectedPaths.count == 4
            && ambiguity.isBlocking
    })
    #expect(plan.assignments.contains { $0.path.contains("IC1396_osc.fit") && $0.groupSlug == "osc-30s" })
    #expect(plan.assignments.contains { $0.path.contains("/OSC/final.tif") && $0.groupSlug == "osc-30s" })
    #expect(plan.humanSummaryHU.contains("81 nyers expozíció"))
    #expect(plan.humanSummaryHU.contains("2 Stacked"))
    #expect(!plan.canApply)
}

@Test func classicSingleCaptureSessionCanAssignItsFlatsWithoutAmbiguity() throws {
    let light = conversionFile("sessions/M31/2026-01-01/lights/a.fit", id: 1)
    let flat = conversionFile("sessions/M31/2026-01-01/flats/f.fit", id: 2)
    let scope = SessionConversionScope(target: "M31", date: "2026-01-01")
    let plan = try SessionConversionPlanner.plan(
        scope: scope,
        files: [light, flat],
        meta: [1: bayerMeta(fileID: 1, exposure: 60)],
        existingGroups: [],
        existingSources: [],
        assignments: [:],
        mode: .logicalOnly
    )

    #expect(plan.proposedGroups.count == 1)
    #expect(plan.ambiguities.isEmpty)
    #expect(plan.assignments.contains { $0.path == flat.path && $0.role == .flat })
    #expect(plan.canApply)
}

@Test func alreadyCanonicalSessionUsesExistingGroupAndPlansNoNewGroup() throws {
    let group = CaptureGroupRecord(
        id: 10,
        target: "M31",
        sessionDate: "2026-01-01",
        slug: "broadband",
        displayName: "OSC broadband",
        sensorMode: .osc,
        signalMode: .broadband
    )
    let file = conversionFile(
        "sessions/M31/2026-01-01/captures/broadband/lights/a.fit",
        id: 1
    )
    let plan = try SessionConversionPlanner.plan(
        scope: SessionConversionScope(target: "M31", date: "2026-01-01"),
        files: [file],
        meta: [1: bayerMeta(fileID: 1, exposure: 60)],
        existingGroups: [group],
        existingSources: [],
        assignments: [:],
        mode: .physical
    )

    #expect(plan.proposedGroups.isEmpty)
    #expect(plan.moves.isEmpty)
    #expect(plan.unchangedItems.contains { $0.path == file.path })
    #expect(plan.canApply)
}

@Test func physicalPlanListsExactMovesAndBlocksDestinationConflict() throws {
    let source = conversionFile("sessions/M31/2026-01-01/lights/a.fit", id: 1, size: 42)
    let scope = SessionConversionScope(target: "M31", date: "2026-01-01")
    let first = try SessionConversionPlanner.plan(
        scope: scope,
        files: [source],
        meta: [1: bayerMeta(fileID: 1, exposure: 60)],
        existingGroups: [],
        existingSources: [],
        assignments: [:],
        mode: .physical
    )
    let move = try #require(first.moves.first)
    #expect(move.sourceRelative == source.path)
    #expect(move.destinationRelative.hasSuffix("/lights/a.fit"))
    #expect(first.directoryCreations.count == 6)
    #expect(first.summary.bytesToMove == 42)

    let blocked = try SessionConversionPlanner.plan(
        scope: scope,
        files: [source],
        meta: [1: bayerMeta(fileID: 1, exposure: 60)],
        existingGroups: [],
        existingSources: [],
        assignments: [:],
        mode: .physical,
        occupiedPaths: [move.destinationRelative]
    )
    #expect(blocked.conflicts.contains { $0.path == move.destinationRelative })
    #expect(!blocked.canApply)
}

@Test func zeroFileSessionProducesStableEmptyPreview() throws {
    let plan = try SessionConversionPlanner.plan(
        scope: conversionScope,
        files: [],
        meta: [:],
        existingGroups: [],
        existingSources: [],
        assignments: [:],
        mode: .logicalOnly
    )
    #expect(plan.detectedClusters.isEmpty)
    #expect(plan.proposedGroups.isEmpty)
    #expect(plan.summary.rawFrameCount == 0)
    #expect(plan.sourceFingerprint.fileCount == 0)
    #expect(plan.canApply)
}
