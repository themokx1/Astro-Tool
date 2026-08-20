import Foundation
import Testing
@testable import AstroCore

private let conversionScope = SessionConversionScope(target: "IC_1396", date: "2026-08-08")

/// V2 UI/UX audit (2026-08-15) section 4: pins the rest of the closed
/// vocabulary `SessionConversionPlanner.plan`/`resolving` generate that the
/// fixture-driven tests above don't happen to exercise -- the "Stack/
/// processed results" ambiguity and the manual-decision destination
/// conflict `resolving` raises -- directly against literal values, since
/// building a fixture that reaches each of them is unrelated to what those
/// tests are otherwise about.
@Suite("Conversion ambiguity/conflict English translation")
struct ConversionEnglishTranslationTests {
    @Test func artifactAmbiguityTranslatesToEnglish() {
        let ambiguity = ConversionAmbiguity(
            id: "artifacts",
            kind: .artifactAssignment,
            title: "Stack/processed eredmények kézi döntést kérnek",
            explanation: "A név és az útvonal több gyűjtéssel is összeegyeztethető.",
            affectedPaths: ["stacks/M31/2026-01-01/final.fit"],
            candidateGroupSlugs: ["osc-30s"]
        )
        #expect(ambiguity.titleEnglish == "Stack/processed results need a manual decision")
        #expect(ambiguity.explanationEnglish == "The name and path are consistent with more than one capture group.")
    }

    @Test func manualDecisionDestinationConflictTranslatesToEnglish() {
        let conflict = ConversionConflict(
            path: "sessions/M31/2026-01-01/captures/osc-30s/lights/a.fit",
            message: "A kézi döntés célútvonala már foglalt; a konverter nem ír felül fájlt."
        )
        #expect(
            conflict.messageEnglish
                == "The manual decision's destination path is already taken; the converter will not overwrite a file."
        )
    }

    @Test func unrecognizedTextPassesThroughRatherThanHidingInformation() {
        let ambiguity = ConversionAmbiguity(
            id: "x", kind: .mixedEvidence, title: "already English", explanation: "already English",
            affectedPaths: [], candidateGroupSlugs: []
        )
        #expect(ambiguity.titleEnglish == "already English")
        #expect(ambiguity.explanationEnglish == "already English")
        #expect(ConversionConflict(path: "p", message: "already English").messageEnglish == "already English")
    }
}

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

@Test func ic1396PreviewSeparatesEveryNominalExposureAndFlagsAmbiguousFlats() throws {
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

    #expect(plan.proposedGroups.count == 3)
    let osc = try #require(plan.detectedClusters.first { $0.proposedGroupSlug == "osc-30s" })
    #expect(osc.rawFramePaths.count == 32)
    #expect(osc.exposureBreakdown == ["30.0": 32])
    #expect(osc.artifactPaths.isEmpty)

    let shortNB = try #require(plan.detectedClusters.first { $0.proposedGroupSlug == "capture-120s" })
    #expect(shortNB.rawFramePaths.count == 3)
    #expect(shortNB.exposureBreakdown == ["120.0": 3])
    #expect(shortNB.artifactPaths.isEmpty)

    let longNB = try #require(plan.detectedClusters.first { $0.proposedGroupSlug == "capture-300s" })
    #expect(longNB.rawFramePaths.count == 46)
    #expect(longNB.exposureBreakdown == ["300.0": 46])
    #expect(longNB.artifactPaths.count == 2)
    #expect(longNB.artifactPaths.allSatisfy { $0.contains("/Stacked") })

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

    // V2 UI/UX audit (2026-08-15) section 4: `humanSummary` is the English
    // sibling `ConversionWorkspace` reads instead of `humanSummaryHU` -- same
    // counts, English wording.
    let humanSummary = try #require(plan.humanSummary)
    #expect(humanSummary.contains("81 raw exposure"))
    #expect(humanSummary.contains("2 Stacked"))
    #expect(!humanSummary.contains("nyers"))
    #expect(!humanSummary.contains("gyűjtési"))

    let flatAmbiguity = try #require(plan.ambiguities.first { $0.kind == .calibrationAssignment })
    #expect(flatAmbiguity.titleEnglish == "Which capture group these flat frames belong to is not clear")
    #expect(flatAmbiguity.explanationEnglish.contains("FITS header and path"))
    #expect(!flatAmbiguity.titleEnglish.contains("gyűjtése"))
    #expect(!flatAmbiguity.explanationEnglish.contains("fejléc"))
}

@Test func alreadyConvertedMixedExposureGroupIsRepairableWithoutLosingCaptureMetadata() throws {
    let fixture = ic1396ConversionFixture()
    let osc = CaptureGroupRecord(
        id: 41,
        target: conversionScope.target,
        sessionDate: conversionScope.date,
        slug: "osc-30s",
        displayName: "OSC 30 s",
        sensorMode: .osc,
        signalMode: .broadband
    )
    let mixed = CaptureGroupRecord(
        id: 42,
        target: conversionScope.target,
        sessionDate: conversionScope.date,
        slug: "capture-120s-300s",
        displayName: "Elephant HDR · 120 s/300 s",
        sensorMode: .osc,
        signalMode: .dualBand,
        filterModel: "SV220"
    )
    let assignmentPairs: [(Int64, FileCaptureAssignmentRecord)] = fixture.files.compactMap { file in
        guard let id = file.id, file.area == .sessions, file.role == .light else { return nil }
        let groupID: Int64 = file.path.contains("/lights_osc/") ? 41 : 42
        return (id, FileCaptureAssignmentRecord(fileID: id, captureGroupID: groupID))
    }
    let assignments: [Int64: FileCaptureAssignmentRecord] = Dictionary(uniqueKeysWithValues: assignmentPairs)
    let sources = [
        CaptureSourceRecord(
            captureGroupID: 41,
            relativePath: "sessions/IC_1396/2026-08-08/lights_osc",
            role: .light
        ),
        CaptureSourceRecord(
            captureGroupID: 42,
            relativePath: "sessions/IC_1396/2026-08-08/lights",
            role: .light
        ),
    ]

    let plan = try SessionConversionPlanner.plan(
        scope: conversionScope,
        files: fixture.files,
        meta: fixture.meta,
        existingGroups: [osc, mixed],
        existingSources: sources,
        assignments: assignments,
        mode: .logicalOnly
    )

    #expect(plan.detectedClusters.count == 3)
    #expect(plan.proposedGroups.count == 2)
    let retained = try #require(plan.proposedGroups.first { $0.draft.slug == mixed.slug })
    #expect(retained.draft.displayName.hasPrefix("Elephant HDR"))
    #expect(retained.draft.displayName.hasSuffix("300 s"))
    #expect(retained.draft.sensorMode == SensorMode.osc)
    #expect(retained.draft.signalMode == SignalMode.dualBand)
    #expect(retained.draft.filterModel == "SV220")

    let separated = try #require(plan.proposedGroups.first { $0.draft.slug == "capture-120s" })
    #expect(separated.draft.displayName.hasPrefix("Elephant HDR"))
    #expect(separated.draft.displayName.hasSuffix("120 s"))
    #expect(separated.draft.sensorMode == SensorMode.osc)
    #expect(separated.draft.signalMode == SignalMode.dualBand)
    #expect(separated.draft.filterModel == "SV220")
    #expect(plan.proposedGroups.allSatisfy { $0.sourceMappings.isEmpty })
    #expect(plan.sourceRemovals == [
        ConversionSourceRemoval(
            relativePath: "sessions/IC_1396/2026-08-08/lights",
            role: .light,
            expectedGroupID: 42,
            reason: "A forrásmappa több expozíciós gyűjtést tartalmaz; az egzakt fájlhozzárendelés veszi át a helyét."
        ),
    ])
    let separatedLightCount = plan.assignments.filter {
        $0.role == FrameRole.light && $0.groupSlug == "capture-120s"
    }.count
    let retainedLightCount = plan.assignments.filter {
        $0.role == FrameRole.light && $0.groupSlug == mixed.slug
    }.count
    #expect(separatedLightCount == 3)
    #expect(retainedLightCount == 46)
    #expect(plan.moves.isEmpty)
}

@Test func exposureSplitUsesNominalBucketsInsteadOfRawFloatNoise() throws {
    let files = [
        conversionFile("sessions/M31/2026-01-01/lights/a.fit", id: 1),
        conversionFile("sessions/M31/2026-01-01/lights/b.fit", id: 2),
        conversionFile("sessions/M31/2026-01-01/lights/c.fit", id: 3),
    ]
    let plan = try SessionConversionPlanner.plan(
        scope: SessionConversionScope(target: "M31", date: "2026-01-01"),
        files: files,
        meta: [
            1: bayerMeta(fileID: 1, exposure: 119.9),
            2: bayerMeta(fileID: 2, exposure: 120),
            3: bayerMeta(fileID: 3, exposure: 300),
        ],
        existingGroups: [],
        existingSources: [],
        assignments: [:],
        mode: .logicalOnly
    )

    #expect(plan.detectedClusters.count == 2)
    #expect(plan.detectedClusters.first { $0.proposedGroupSlug == "capture-120s" }?.rawFramePaths.count == 2)
    #expect(plan.detectedClusters.first { $0.proposedGroupSlug == "capture-300s" }?.rawFramePaths.count == 1)
}

@Test func ambiguityDecisionProducesAnApplyableExactPlan() throws {
    let fixture = ic1396ConversionFixture()
    let preview = try SessionConversionPlanner.plan(
        scope: conversionScope,
        files: fixture.files,
        meta: fixture.meta,
        existingGroups: [],
        existingSources: [],
        assignments: [:],
        mode: .physical
    )
    let ambiguity = try #require(preview.ambiguities.first { $0.kind == .calibrationAssignment })
    let slug = try #require(ambiguity.candidateGroupSlugs.first)

    let resolved = try SessionConversionPlanner.resolving(
        ambiguityID: ambiguity.id,
        withGroupSlug: slug,
        in: preview,
        files: fixture.files
    )

    #expect(resolved.ambiguities.contains { $0.id == ambiguity.id } == false)
    #expect(ambiguity.affectedPaths.allSatisfy { path in
        resolved.assignments.contains { $0.path == path && $0.groupSlug == slug }
    })
    #expect(ambiguity.affectedPaths.allSatisfy { path in
        resolved.moves.contains { $0.sourceRelative == path && $0.groupSlug == slug }
    })
    #expect(resolved.summary.fileAssignmentCount == resolved.assignments.count)
    #expect(resolved.summary.moveCount == resolved.moves.count)
    #expect(resolved.canApply)

    // The English `humanSummary` gets the same "manual decision recorded"
    // tail `humanSummaryHU` does, in English.
    let resolvedSummary = try #require(resolved.humanSummary)
    #expect(resolvedSummary.contains("Manual decision recorded"))
    #expect(resolvedSummary.contains("\(ambiguity.affectedPaths.count) file"))
    #expect(!resolvedSummary.contains("Kézi döntés"))
}

@Test func converterNeverTreatsFinderResidueOrPresetJSONAsCaptureData() throws {
    let light = conversionFile("sessions/M31/2026-01-01/lights/a.fit", id: 1)
    let lightDSStore = conversionFile("sessions/M31/2026-01-01/lights/.DS_Store", id: 2)
    let flatDSStore = conversionFile("sessions/M31/2026-01-01/flats/.DS_Store", id: 3)
    let stackDSStore = conversionFile("stacks/M31/2026-01-01/.DS_Store", id: 4)
    let preset = conversionFile("stacks/M31/2026-01-01/presets/example.json", id: 5)
    let plan = try SessionConversionPlanner.plan(
        scope: SessionConversionScope(target: "M31", date: "2026-01-01"),
        files: [light, lightDSStore, flatDSStore, stackDSStore, preset],
        meta: [1: bayerMeta(fileID: 1, exposure: 60)],
        existingGroups: [],
        existingSources: [],
        assignments: [:],
        mode: .logicalOnly
    )

    #expect(plan.summary.rawFrameCount == 1)
    #expect(plan.summary.artifactCount == 0)
    #expect(plan.summary.calibrationFrameCount == 0)
    #expect(plan.ambiguities.isEmpty)
    #expect(plan.assignments.map(\.path) == [light.path])
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

    // V2 UI/UX audit (2026-08-15) section 4: `messageEnglish` is the English
    // sibling `ConversionWorkspace` reads instead of `message` (kept
    // Hungarian for V1/CLI).
    let conflict = try #require(blocked.conflicts.first { $0.path == move.destinationRelative })
    #expect(conflict.messageEnglish == "The destination path is already taken; the converter will not overwrite a file.")
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
    #expect(plan.humanSummaryHU == "A kiválasztott sessionben nincs konvertálható fájl.")
    #expect(plan.humanSummary == "The selected session has no convertible files.")
}
