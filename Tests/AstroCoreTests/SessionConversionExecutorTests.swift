import Foundation
import Testing
@testable import AstroCore

private struct ExecutorFixture {
    let root: URL
    let db: Database
    let config: AstroConfig

    static func make(frameCount: Int = 1) throws -> ExecutorFixture {
        try make(exposures: Array(repeating: 60, count: frameCount))
    }

    static func make(exposures: [Double]) throws -> ExecutorFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-conversion-executor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lights = root.appendingPathComponent("sessions/M31/2026-01-01/lights", isDirectory: true)
        try FileManager.default.createDirectory(at: lights, withIntermediateDirectories: true)
        for (offset, exposure) in exposures.enumerated() {
            try buildHeaderData([
                "SIMPLE  =                    T",
                "BITPIX  =                   16",
                "NAXIS   =                    2",
                "EXPTIME = \(exposure)",
                "BAYERPAT= 'RGGB'",
                "END",
            ]).write(to: lights.appendingPathComponent("light\(offset + 1).fit"))
        }
        let db = try Database(path: root.appendingPathComponent("index.sqlite").path)
        var config = AstroConfig()
        config.rootPath = root.path
        _ = try LibraryScanner(config: config, db: db).scan()
        return ExecutorFixture(root: root, db: db, config: config)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func plan(mode: SessionConversionMode) throws -> SessionConversionPlan {
        try SessionConversionPlanner.plan(
            target: "M31",
            date: "2026-01-01",
            db: db,
            config: config,
            mode: mode
        )
    }
}

@Test func existingMixedGroupSplitApplyAndRollbackRestoresOriginalMetadataAndAssignments() throws {
    let fixture = try ExecutorFixture.make(exposures: [120, 300, 300])
    defer { fixture.cleanup() }
    let mixedGroupID = try fixture.db.upsertCaptureGroup(
        CaptureGroupRecord(
            target: "M31",
            sessionDate: "2026-01-01",
            slug: "capture-120s-300s",
            displayName: "OSC · filter ismeretlen · 120 s/300 s",
            sensorMode: .osc,
            signalMode: .dualBand,
            filterModel: "SV220"
        )
    )
    _ = try fixture.db.upsertCaptureSource(
        CaptureSourceRecord(
            captureGroupID: mixedGroupID,
            relativePath: "sessions/M31/2026-01-01/lights",
            role: .light
        )
    )
    for file in try fixture.db.allFiles(includeMissing: false) where file.role == .light {
        let fileID = try #require(file.id)
        try fixture.db.upsertFileCaptureAssignment(
            FileCaptureAssignmentRecord(fileID: fileID, captureGroupID: mixedGroupID)
        )
    }

    let plan = try fixture.plan(mode: .logicalOnly)
    let retained = try #require(plan.proposedGroups.first { $0.existingGroupID == mixedGroupID })
    #expect(retained.draft.slug == "capture-120s-300s")
    #expect(retained.draft.displayName.hasSuffix("300 s"))
    let separated = try #require(plan.proposedGroups.first { $0.existingGroupID == nil })
    #expect(separated.draft.slug == "capture-120s")
    #expect(separated.draft.filterModel == "SV220")

    let receipt = try SessionConversionExecutor.apply(plan: plan, root: fixture.root, db: fixture.db)
    let appliedGroups = try fixture.db.captureGroups(target: "M31", date: "2026-01-01")
    #expect(appliedGroups.count == 2)
    #expect(appliedGroups.first { $0.id == mixedGroupID }?.displayName.hasSuffix("300 s") == true)
    let separatedID = try #require(appliedGroups.first { $0.slug == "capture-120s" }?.id)
    let appliedAssignments = try fixture.db.allFileCaptureAssignments()
    #expect(appliedAssignments.values.filter { $0.captureGroupID == separatedID }.count == 1)
    #expect(appliedAssignments.values.filter { $0.captureGroupID == mixedGroupID }.count == 2)
    #expect(try fixture.db.allCaptureSources().contains { $0.relativePath == "sessions/M31/2026-01-01/lights" } == false)

    _ = try SessionConversionExecutor.rollback(receipt: receipt, root: fixture.root, db: fixture.db)
    let restoredGroups = try fixture.db.captureGroups(target: "M31", date: "2026-01-01")
    #expect(restoredGroups.count == 1)
    #expect(restoredGroups[0].id == mixedGroupID)
    #expect(restoredGroups[0].displayName == "OSC · filter ismeretlen · 120 s/300 s")
    #expect(try fixture.db.allFileCaptureAssignments().values.allSatisfy { $0.captureGroupID == mixedGroupID })
    #expect(try fixture.db.allCaptureSources().contains { source in
        source.relativePath == "sessions/M31/2026-01-01/lights"
            && source.captureGroupID == mixedGroupID
    })
}

@Test func preV0152MetadataBackupJSONStillDecodesWithoutUpdatedGroups() throws {
    let data = Data(
        #"{"createdGroupIDs":[],"createdGroupSlugs":[],"assignmentBackups":[],"sourceBackups":[]}"#.utf8
    )

    let backup = try JSONDecoder().decode(ConversionMetadataBackup.self, from: data)

    #expect(backup.updatedGroupBackups == nil)
}

@Test func logicalApplyPersistsMetadataPlanAndReceiptWithoutMovingLibraryFiles() throws {
    let fixture = try ExecutorFixture.make()
    defer { fixture.cleanup() }
    let plan = try fixture.plan(mode: .logicalOnly)
    let source = fixture.root.appendingPathComponent("sessions/M31/2026-01-01/lights/light1.fit")

    let receipt = try SessionConversionExecutor.apply(
        plan: plan,
        root: fixture.root,
        db: fixture.db,
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(receipt.status == .applied)
    #expect(receipt.mode == .logicalOnly)
    #expect(receipt.moves.isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").count == 1)
    let fileID = try #require(try fixture.db.fileID(path: "sessions/M31/2026-01-01/lights/light1.fit"))
    #expect(try fixture.db.fileCaptureAssignment(fileID: fileID) != nil)
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(receipt.planRelativePath).path))
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(receipt.receiptRelativePath).path))
}

@Test func physicalApplyMovesExactFilesAndExplicitRollbackRestoresThem() throws {
    let fixture = try ExecutorFixture.make()
    defer { fixture.cleanup() }
    let plan = try fixture.plan(mode: .physical)
    let move = try #require(plan.moves.first)
    let source = fixture.root.appendingPathComponent(move.sourceRelative)
    let destination = fixture.root.appendingPathComponent(move.destinationRelative)

    let receipt = try SessionConversionExecutor.apply(plan: plan, root: fixture.root, db: fixture.db)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(receipt.moves == plan.moves)

    let rolledBack = try SessionConversionExecutor.rollback(
        receipt: receipt,
        root: fixture.root,
        db: fixture.db,
        now: Date(timeIntervalSince1970: 2_000)
    )
    #expect(rolledBack.status == .rolledBack)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").isEmpty)
}

@Test func physicalApplyPreflightBlocksDestinationConflictBeforeFirstMove() throws {
    let fixture = try ExecutorFixture.make(frameCount: 2)
    defer { fixture.cleanup() }
    let plan = try fixture.plan(mode: .physical)
    let conflictingMove = try #require(plan.moves.last)
    let conflictURL = fixture.root.appendingPathComponent(conflictingMove.destinationRelative)
    try FileManager.default.createDirectory(at: conflictURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("existing".utf8).write(to: conflictURL)

    #expect(throws: AstroError.self) {
        try SessionConversionExecutor.apply(plan: plan, root: fixture.root, db: fixture.db)
    }
    for move in plan.moves {
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(move.sourceRelative).path))
    }
    #expect(try Data(contentsOf: conflictURL) == Data("existing".utf8))
    #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").isEmpty)
}

@Test func applyRejectsStaleSourceFingerprint() throws {
    let fixture = try ExecutorFixture.make()
    defer { fixture.cleanup() }
    let plan = try fixture.plan(mode: .logicalOnly)
    let source = fixture.root.appendingPathComponent("sessions/M31/2026-01-01/lights/light1.fit")
    let handle = try FileHandle(forWritingTo: source)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("changed".utf8))
    try handle.close()

    #expect(throws: AstroError.self) {
        try SessionConversionExecutor.apply(plan: plan, root: fixture.root, db: fixture.db)
    }
    #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").isEmpty)
}

@Test func plannerRefreshesItsExactScopeBeforeFingerprinting() throws {
    let fixture = try ExecutorFixture.make(frameCount: 2)
    defer { fixture.cleanup() }
    let lights = fixture.root.appendingPathComponent("sessions/M31/2026-01-01/lights")
    try FileManager.default.removeItem(at: lights.appendingPathComponent("light2.fit"))
    let handle = try FileHandle(forWritingTo: lights.appendingPathComponent("light1.fit"))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("changed-before-plan".utf8))
    try handle.close()

    let plan = try fixture.plan(mode: .logicalOnly)
    #expect(plan.sourceFingerprint.fileCount == 1)
    #expect(try SessionConversionExecutor.apply(plan: plan, root: fixture.root, db: fixture.db).status == .applied)
}

@Test func midApplyFailureAutomaticallyRollsBackMovesAndMetadata() throws {
    let fixture = try ExecutorFixture.make(frameCount: 2)
    defer { fixture.cleanup() }
    let plan = try fixture.plan(mode: .physical)

    #expect(throws: AstroError.self) {
        try SessionConversionExecutor.apply(
            plan: plan,
            root: fixture.root,
            db: fixture.db,
            failureAfterMoves: 1
        )
    }
    for move in plan.moves {
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(move.sourceRelative).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(move.destinationRelative).path))
    }
    #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").isEmpty)
}

@Test func explicitRollbackPreflightBlocksWhenOriginalSourcePathWasReoccupied() throws {
    let fixture = try ExecutorFixture.make()
    defer { fixture.cleanup() }
    let receipt = try SessionConversionExecutor.apply(
        plan: fixture.plan(mode: .physical),
        root: fixture.root,
        db: fixture.db
    )
    let move = try #require(receipt.moves.first)
    let source = fixture.root.appendingPathComponent(move.sourceRelative)
    let destination = fixture.root.appendingPathComponent(move.destinationRelative)
    try Data("new unrelated file".utf8).write(to: source)

    #expect(throws: AstroError.self) {
        try SessionConversionExecutor.rollback(receipt: receipt, root: fixture.root, db: fixture.db)
    }
    #expect(try Data(contentsOf: source) == Data("new unrelated file".utf8))
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(try fixture.db.captureGroups(target: "M31", date: "2026-01-01").count == 1)
}

/// The conversion's metadata mutations belong to a file-MOVING workflow and
/// must stay atomic on their own. When the library scanner already holds its
/// batched-write transaction on the same `Database`, joining it would hand
/// the conversion's half-applied writes to an owner that commits even on
/// error (`LibraryScanner.scan` deliberately commits what it has), so a
/// failed apply would leave orphan capture groups and mappings behind.
@Test func aFailedMetadataApplyInsideAScanTransactionRollsBackOnlyItsOwnWrites() throws {
    let fixture = try ExecutorFixture.make(exposures: [120, 300])
    defer { fixture.cleanup() }
    var plan = try fixture.plan(mode: .logicalOnly)
    let slug = try #require(plan.proposedGroups.first?.draft.slug)
    // An assignment for a file that is not indexed -- rejected in the LAST
    // loop of the apply, after the capture groups have already been written.
    plan.assignments.append(
        ConversionAssignment(
            fileID: nil,
            path: "sessions/M31/2026-01-01/lights/ghost.fit",
            role: .light,
            groupSlug: slug,
            reason: "test"
        )
    )

    // Stand in for the scanner's own batched-write transaction.
    try fixture.db.beginTransaction()
    #expect(throws: AstroError.self) {
        _ = try fixture.db.applySessionConversionMetadata(plan: plan, now: 1_000)
    }
    // The transaction owner commits what it has even after an error, exactly
    // as `LibraryScanner.scan` does.
    try fixture.db.commitTransaction()

    #expect(
        try fixture.db.captureGroups(target: "M31", date: "2026-01-01").isEmpty,
        "a half-applied conversion must not be carried into the scan transaction's commit"
    )
    #expect(try fixture.db.allCaptureSources().isEmpty)
}
