import Foundation
import Testing
@testable import AstroApplication
@testable import AstroMobileDomain

@Suite("Mobile return change importer")
struct MobileChangeImporterTests {
    @Test("matching checklist and note revisions are previewed as applicable")
    func matchingRevisionsAreApplicable() throws {
        let fixture = Fixture()
        let importer = MobileChangeImporter()

        let preview = try importer.preview(
            envelope: fixture.envelope(changes: [fixture.checklistChange(), fixture.noteChange()]),
            expectedLibraryID: fixture.libraryID,
            currentSnapshot: fixture.snapshot,
            sourcePackageID: fixture.packageID
        )

        #expect(preview.applicable.count == 2)
        #expect(preview.conflicts.isEmpty)
        #expect(preview.rejected.isEmpty)
    }

    @Test("return preview binds the sent base snapshot while comparing against a fresh Mac snapshot")
    func baseIdentityIsSeparateFromCurrentSnapshot() throws {
        let fixture = Fixture()
        let sent = fixture.envelope(changes: [fixture.checklistChange()])
        let fresh = MobileLibrarySnapshot(schemaVersion: 1, libraryID: fixture.libraryID, snapshotID: UUID(), revision: 8, createdAt: fixture.date.addingTimeInterval(20), projects: sent.snapshot!.projects, nights: sent.snapshot!.nights, captures: sent.snapshot!.captures, briefings: sent.snapshot!.briefings, notes: sent.snapshot!.notes)
        let preview = try MobileChangeImporter().preview(envelope: sent, expectedLibraryID: fixture.libraryID, expectedBaseSnapshotID: sent.snapshot!.snapshotID, currentSnapshot: fresh, sourcePackageID: fixture.packageID)
        #expect(preview.applicable.count == 1)
    }

    @Test("Mac edits become typed conflicts and default note resolution keeps both")
    func conflictsExposeBothValues() throws {
        let fixture = Fixture(macChecklistRevision: 4, macNoteRevision: 4)
        let importer = MobileChangeImporter()
        let preview = try importer.preview(
            envelope: fixture.envelope(changes: [fixture.checklistChange(), fixture.noteChange()]),
            expectedLibraryID: fixture.libraryID,
            currentSnapshot: fixture.snapshot,
            sourcePackageID: fixture.packageID
        )

        #expect(preview.applicable.isEmpty)
        #expect(preview.conflicts.count == 2)
        #expect(preview.conflicts.contains { $0.recommendedResolution == .keepBothAsFieldNote })
        #expect(preview.conflicts.contains { $0.phoneChecklistCompletion == true && $0.macChecklistCompletion == false })
        #expect(preview.conflicts.contains { $0.phoneText == "Phone note" && $0.macText == "Mac note" })
    }

    @Test("empty phone note is rejected and never becomes deletion")
    func emptyPhoneNoteRejected() throws {
        let fixture = Fixture()
        let empty = fixture.noteChange(text: "  \n")
        let preview = try MobileChangeImporter().preview(
            envelope: fixture.envelope(changes: [empty]),
            expectedLibraryID: fixture.libraryID,
            currentSnapshot: fixture.snapshot,
            sourcePackageID: fixture.packageID
        )

        #expect(preview.applicable.isEmpty)
        #expect(preview.rejected.first?.reason == .noTextToImport)
    }

    @Test("duplicate, unknown, and cross-device changes are rejected before commands")
    func malformedTargetsAreRejectedWithoutCommandAccess() throws {
        let fixture = Fixture()
        let first = fixture.checklistChange()
        let duplicate = fixture.checklistChange(id: first.changeID)
        let unknown = fixture.checklistChange(itemID: "missing")
        let otherDevice = fixture.noteChange(deviceID: UUID())
        let commands = CommandCounter()
        let importer = MobileChangeImporter(commands: countingCommands(commands))

        #expect(throws: MobileChangeImportError.crossDeviceQueue) {
            try importer.preview(
                envelope: fixture.envelope(changes: [first, duplicate, unknown, otherDevice]),
                expectedLibraryID: fixture.libraryID,
                currentSnapshot: fixture.snapshot,
                sourcePackageID: fixture.packageID
            )
        }

        let preview = try importer.preview(
            envelope: fixture.envelope(changes: [first, duplicate, unknown]),
            expectedLibraryID: fixture.libraryID,
            currentSnapshot: fixture.snapshot,
            sourcePackageID: fixture.packageID
        )

        #expect(preview.duplicates == [first.changeID])
        #expect(preview.rejected.contains { $0.reason == .unknownTarget })
        #expect(commands.value == 0)
    }

    @Test("a duplicate change ID collision rejects every colliding record before apply")
    func duplicateCollisionCannotApplyFirstRecord() throws {
        let fixture = Fixture()
        let first = fixture.noteChange(id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!, text: "first")
        let second = fixture.noteChange(id: first.changeID, text: "second")
        let preview = try MobileChangeImporter().preview(envelope: fixture.envelope(changes: [first, second]), expectedLibraryID: fixture.libraryID, currentSnapshot: fixture.snapshot, sourcePackageID: fixture.packageID)
        #expect(preview.applicable.isEmpty)
        #expect(preview.conflicts.isEmpty)
        #expect(preview.duplicates == [first.changeID])
        #expect(preview.rejected.allSatisfy { $0.reason == .duplicateChangeID })
    }

    @Test("a colliding ID is rejected even when a newer edit supersedes its target")
    func supersessionNeverHidesDuplicateCollision() throws {
        let fixture = Fixture()
        let collidingID = UUID(uuidString: "00000000-0000-0000-0000-000000000088")!
        let first = fixture.noteChange(id: collidingID, text: "first")
        let duplicate = fixture.noteChange(id: collidingID, text: "duplicate")
        let newer = fixture.noteChange(id: UUID(uuidString: "00000000-0000-0000-0000-000000000089")!, text: "newer")
        let preview = try MobileChangeImporter().preview(
            envelope: fixture.envelope(changes: [first, duplicate, newer]),
            expectedLibraryID: fixture.libraryID,
            currentSnapshot: fixture.snapshot,
            sourcePackageID: fixture.packageID
        )

        #expect(preview.duplicates == [collidingID])
        #expect(preview.rejected.contains { $0.changeID == collidingID && $0.reason == .duplicateChangeID })
        #expect(!preview.alreadyApplied.contains(collidingID))
    }

    @Test("duplicate collisions are removed before effective chronology is calculated")
    func collisionCannotSupersedeAnOtherwiseValidEarlierChange() throws {
        let fixture = Fixture()
        let validID = UUID()
        let valid = fixture.noteChange(id: validID, text: "valid earlier")
        let collisionID = UUID()
        let duplicateOne = fixture.noteChange(id: collisionID, text: "duplicate newer one")
        let duplicateTwo = fixture.noteChange(id: collisionID, text: "duplicate newer two")
        let preview = try MobileChangeImporter().preview(
            envelope: fixture.envelope(changes: [valid, duplicateOne, duplicateTwo]),
            expectedLibraryID: fixture.libraryID,
            currentSnapshot: fixture.snapshot,
            sourcePackageID: fixture.packageID
        )

        #expect(preview.applicable.map(\.changeID) == [validID])
        #expect(preview.duplicates == [collisionID])
        #expect(!preview.superseded.contains(validID))
    }

    @Test("apply requires explicit confirmation and records the narrow command receipt")
    func applyIsSecondPhase() async throws {
        let fixture = Fixture()
        let calls = CommandCounter()
        let importer = MobileChangeImporter(commands: countingCommands(calls))
        let envelope = fixture.envelope(changes: [fixture.checklistChange(), fixture.noteChange()])
        let preview = try importer.preview(envelope: envelope, expectedLibraryID: fixture.libraryID, currentSnapshot: fixture.snapshot, sourcePackageID: fixture.packageID)

        await #expect(throws: MobileChangeImportError.finalConfirmationRequired) {
            try await importer.apply(preview: preview, envelope: envelope, currentSnapshot: fixture.snapshot, resolutions: [:], confirmed: false)
        }
        #expect(calls.value == 0)
        let receipt = try await importer.apply(preview: preview, envelope: envelope, currentSnapshot: fixture.snapshot, resolutions: [:], confirmed: true)
        #expect(receipt.appliedChangeIDs.count == 2)
        #expect(calls.value == 1)
    }

    @Test("each conflict resolution has explicit, narrow semantics and replay is idempotent")
    func resolutionsAndReplay() async throws {
        let fixture = Fixture(macChecklistRevision: 4, macNoteRevision: 4)
        let note = fixture.noteChange()
        let checklist = fixture.checklistChange()
        let envelope = fixture.envelope(changes: [checklist, note])
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mobile-return-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recordStore = MobileChangeReceiptStore(fileURL: fileURL)
        let calls = CommandCounter()
        let importer = MobileChangeImporter(commands: countingCommands(calls), recordStore: recordStore)
        let preview = try importer.preview(envelope: envelope, expectedLibraryID: fixture.libraryID, currentSnapshot: fixture.snapshot, sourcePackageID: fixture.packageID)
        let ids = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.kind, $0.changeID) })
        _ = try await importer.apply(preview: preview, envelope: envelope, currentSnapshot: fixture.snapshot, resolutions: [ids[.checklist]!: .keepMac, ids[.note]!: .keepBothAsFieldNote], confirmed: true)
        #expect(calls.value == 1)

        let relaunched = MobileChangeImporter(recordStore: recordStore)
        let replay = try relaunched.preview(envelope: envelope, expectedLibraryID: fixture.libraryID, currentSnapshot: fixture.snapshot, sourcePackageID: fixture.packageID)
        #expect(Set(replay.alreadyApplied) == Set([ids[.note]!, ids[.checklist]!]))
    }

    @Test("multiple phone edits preserve chronology and apply only the effective latest value")
    func chronologyUsesLatestEffectiveValue() throws {
        let fixture = Fixture()
        let first = fixture.noteChange(id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!, text: "first")
        let second = fixture.noteChange(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, text: "second")
        let preview = try MobileChangeImporter().preview(envelope: fixture.envelope(changes: [second, first]), expectedLibraryID: fixture.libraryID, currentSnapshot: fixture.snapshot, sourcePackageID: fixture.packageID)
        #expect(preview.applicable.count == 1)
        #expect(preview.superseded == [first.changeID])
        #expect(preview.applicable.first?.noteText == "second")
    }

    @Test("atomic owner batches retain global phone chronology by first change")
    func batchesFollowPhoneChronologyAcrossOwners() async throws {
        let fixture = Fixture()
        let projectID = UUID()
        let source = fixture.snapshot
        let projectNote = MobileNote(
            id: "project-\(projectID.uuidString.lowercased())",
            scope: .project,
            ownerID: projectID.uuidString,
            text: "Mac project note",
            baseRevision: 2,
            updatedAt: fixture.date,
            isEditableOnPhone: true
        )
        let snapshot = MobileLibrarySnapshot(
            schemaVersion: source.schemaVersion,
            libraryID: source.libraryID,
            snapshotID: source.snapshotID,
            revision: source.revision,
            createdAt: source.createdAt,
            projects: source.projects,
            nights: source.nights,
            captures: source.captures,
            briefings: source.briefings,
            notes: source.notes + [projectNote]
        )
        let earlierProjectChange = MobileChange.noteRevision(.init(
            changeID: UUID(),
            deviceID: fixture.deviceID,
            noteID: projectNote.id,
            ownerID: projectID.uuidString,
            baseRevision: 2,
            text: "Phone project note",
            createdAt: fixture.date.addingTimeInterval(1)
        ))
        let laterBriefingChange = fixture.checklistChange()
        let envelope = MobilePackageEnvelope(
            purpose: .returnChanges,
            snapshot: snapshot,
            baseSnapshotID: snapshot.snapshotID,
            changes: [laterBriefingChange, earlierProjectChange],
            acknowledgedChangeIDs: []
        )
        let calls = CommandCounter()
        let importer = MobileChangeImporter(commands: countingCommands(calls))
        let preview = try importer.preview(envelope: envelope, expectedLibraryID: fixture.libraryID, currentSnapshot: snapshot, sourcePackageID: fixture.packageID)

        _ = try await importer.apply(preview: preview, envelope: envelope, currentSnapshot: snapshot, resolutions: [:], confirmed: true)

        #expect(calls.batches.count == 2)
        #expect(calls.batches.first?.isProjectAnnotationBatch == true)
    }

    @Test("production defaults fail closed when persistence commands are not configured")
    func missingCommandsNeverClaimSuccess() async throws {
        let fixture = Fixture()
        let importer = MobileChangeImporter()
        let envelope = fixture.envelope(changes: [fixture.checklistChange()])
        let preview = try importer.preview(envelope: envelope, expectedLibraryID: fixture.libraryID, currentSnapshot: fixture.snapshot, sourcePackageID: fixture.packageID)
        await #expect(throws: MobileChangeImportError.configurationMissing) {
            try await importer.apply(preview: preview, envelope: envelope, currentSnapshot: fixture.snapshot, resolutions: [:], confirmed: true)
        }
    }

    @Test("an acknowledgement ID is never both applied and resolved")
    func acknowledgementClassesAreDisjoint() {
        let fixture = Fixture()
        let changeID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

        let ledger = MobileChangeApplicationLedger(
            libraryID: fixture.libraryID,
            appliedChangeIDs: [changeID],
            resolvedChangeIDs: [changeID]
        )

        #expect(ledger.appliedChangeIDs == [changeID])
        #expect(ledger.resolvedChangeIDs.isEmpty)
        #expect(Set(ledger.appliedChangeIDs + ledger.resolvedChangeIDs).count == 1)

        let receipt = MobileChangeApplicationRecord(
            libraryID: fixture.libraryID,
            sourcePackageID: fixture.packageID,
            sourceFingerprint: "test",
            appliedChangeIDs: [changeID],
            resolvedChangeIDs: [changeID],
            resultingRevisions: [:]
        )
        #expect(receipt.appliedChangeIDs == [changeID])
        #expect(receipt.resolvedChangeIDs.isEmpty)
    }

    @Test("two windows prune acknowledgement evidence without restoring each other's IDs")
    func acknowledgementPruningReloadsBeforeEveryMutation() throws {
        let fixture = Fixture()
        let firstID = UUID()
        let secondID = UUID()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let firstStore = MobileChangeReceiptStore(fileURL: fileURL)
        let secondStore = MobileChangeReceiptStore(fileURL: fileURL)
        try firstStore.save(.init(
            libraryID: fixture.libraryID,
            appliedChangeIDs: [firstID, secondID]
        ))
        let firstWindow = MobileChangeImporter(recordStore: firstStore)
        let secondWindow = MobileChangeImporter(recordStore: secondStore)

        try firstWindow.acknowledgePhoneEvidence([firstID])
        try secondWindow.acknowledgePhoneEvidence([secondID])

        #expect(try firstStore.load()?.appliedChangeIDs.isEmpty == true)
    }

    @Test("a receipt ledger from another library fails closed before preview")
    func foreignReceiptLedgerFailsClosed() throws {
        let fixture = Fixture()
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mobile-return-foreign-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = MobileChangeReceiptStore(fileURL: fileURL)
        try store.save(.init(libraryID: PortableLibraryID(rawValue: UUID())))
        let importer = MobileChangeImporter(recordStore: store)

        #expect(throws: MobileChangeImportError.receiptFailed) {
            try importer.preview(
                envelope: fixture.envelope(changes: [fixture.checklistChange()]),
                expectedLibraryID: fixture.libraryID,
                currentSnapshot: fixture.snapshot,
                sourcePackageID: fixture.packageID
            )
        }
    }

    @Test("production briefing batch saves edits and mobile IDs in one revision")
    func productionBriefingBatchIsAtomic() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let briefingID = UUID()
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let revisions = NightBriefingRevisionStore(directory: paths.briefings)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let original = try await revisions.save(NightBriefingDraft(
            id: briefingID,
            savedAt: savedAt,
            checklist: [.init(id: "setup", title: "Setup", items: [.init(id: "focus", title: "Focus", isVisible: true, isBuiltIn: false)])],
            notes: "Mac note"
        ))
        let checklistID = UUID()
        let noteID = UUID()
        let commands = try MobileChangeCommands.production(rootURL: root)
        let result = try await commands.applyBatch(.briefing(.init(
            briefingID: briefingID,
            expectedRevision: original.revision,
            mutations: [
                .checklist(.init(changeID: checklistID, briefingID: briefingID, itemID: "focus", isCompleted: true, expectedRevision: original.revision, resultingRevision: original.revision + 1, createdAt: savedAt.addingTimeInterval(-10))),
                .note(.init(changeID: noteID, noteID: "briefing-\(briefingID.uuidString.lowercased())", ownerID: briefingID.uuidString, text: "Phone note", expectedRevision: original.revision, resultingRevision: original.revision + 1, createdAt: savedAt.addingTimeInterval(10)), .appendFieldNote),
            ]
        )))
        let latest = try #require(await revisions.latest(id: briefingID))

        #expect(latest.revision == original.revision + 1)
        #expect(latest.checklist[0].items[0].isCompleted)
        #expect(latest.notes.contains("Phone note"))
        #expect(latest.savedAt == savedAt.addingTimeInterval(10))
        #expect(Set(latest.mobileChangeIDs) == Set([checklistID, noteID]))
        #expect(Set(result.appliedChangeIDs) == Set([checklistID, noteID]))
    }

    @Test("same-ID concurrent production retries create one briefing revision and one field note")
    func concurrentProductionRetriesAreIdempotent() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let briefingID = UUID()
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let revisions = NightBriefingRevisionStore(directory: paths.briefings)
        let original = try await revisions.save(NightBriefingDraft(
            id: briefingID,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            checklist: [.init(id: "setup", title: "Setup", items: [.init(id: "focus", title: "Focus", isVisible: true, isBuiltIn: false)])],
            notes: "Mac note"
        ))
        let changeID = UUID()
        let batch = MobileChangeDomainBatch.briefing(.init(
            briefingID: briefingID,
            expectedRevision: original.revision,
            mutations: [.note(.init(
                changeID: changeID,
                noteID: "briefing-\(briefingID.uuidString.lowercased())",
                ownerID: briefingID.uuidString,
                text: "Phone field note",
                expectedRevision: original.revision,
                resultingRevision: original.revision + 1,
                createdAt: original.savedAt.addingTimeInterval(10)
            ), .appendFieldNote)]
        ))
        let first = try MobileChangeCommands.production(rootURL: root)
        let second = try MobileChangeCommands.production(rootURL: root)

        async let firstResult = first.applyBatch(batch)
        async let secondResult = second.applyBatch(batch)
        let results = try await [firstResult, secondResult]
        let latest = try #require(await revisions.latest(id: briefingID))

        #expect(latest.revision == original.revision + 1)
        #expect(latest.notes.components(separatedBy: "— Phone field note —").count == 2)
        #expect(latest.mobileChangeIDs == [changeID])
        #expect(results.allSatisfy { $0.appliedChangeIDs == [changeID] })
        #expect(Set(results.compactMap { $0.resultingRevisions[changeID.uuidString] }) == Set([latest.revision]))
    }

    @Test("project annotation batch uses compare-and-set and retains a monotonic revision")
    func projectAnnotationBatchUsesCAS() async throws {
        let store = try MetadataStore.temporary()
        let projectID = UUID()
        try await store.save(ProjectRecord(id: projectID, catalogID: "m31", displayName: "M31", phase: .planned))
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.save(ProjectAnnotationRecord(projectID: projectID, integrationGoalHours: nil, notes: "Mac", updatedAt: baseline))
        let changeID = UUID()
        let result = try await store.applyMobileProjectAnnotationBatch(.init(
            projectID: projectID,
            expectedRevision: 0,
            mutations: [(.init(changeID: changeID, noteID: "project-\(projectID.uuidString.lowercased())", ownerID: projectID.uuidString, text: "Phone", expectedRevision: 0, resultingRevision: 1, createdAt: baseline.addingTimeInterval(10)), .appendFieldNote)]
        ))
        let applied = try #require(await store.projectAnnotation(projectID: projectID))
        #expect(applied.revision == 1)
        #expect(applied.mobileChangeIDs == [changeID])
        #expect(applied.notes.contains("Phone"))
        #expect(result.resultingRevisions[changeID.uuidString] == 1)

        try await store.save(ProjectAnnotationRecord(projectID: projectID, integrationGoalHours: nil, notes: "Mac edit", updatedAt: baseline, revision: 0))
        #expect(try await store.projectAnnotation(projectID: projectID)?.revision == 2)
    }
}

private final class CommandCounter: @unchecked Sendable {
    var value = 0
    var batches: [MobileChangeDomainBatch] = []
}

private func countingCommands(_ counter: CommandCounter) -> MobileChangeCommands {
    MobileChangeCommands(applyBatch: { batch in
        counter.value += 1
        counter.batches.append(batch)
        let ids: [UUID]
        switch batch {
        case .briefing(let briefing):
            ids = briefing.mutations.map {
                switch $0 { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
            }
        case .projectAnnotation(let project): ids = project.mutations.map { $0.0.changeID }
        }
        let revision: Int
        switch batch {
        case .briefing(let briefing): revision = briefing.expectedRevision + 1
        case .projectAnnotation(let project): revision = project.expectedRevision + 1
        }
        return MobileChangeDomainBatchResult(
            appliedChangeIDs: ids,
            resultingRevisions: Dictionary(uniqueKeysWithValues: ids.map { ($0.uuidString, revision) })
        )
    })
}

private struct Fixture {
    let libraryID = PortableLibraryID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let briefingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let itemID = "focus"
    let noteID: String
    let ownerID: String
    let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let packageID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let macChecklistRevision: Int
    let macNoteRevision: Int

    init(macChecklistRevision: Int = 2, macNoteRevision: Int = 2) {
        self.macChecklistRevision = macChecklistRevision
        self.macNoteRevision = macNoteRevision
        self.noteID = "briefing-\(briefingID.uuidString.lowercased())"
        self.ownerID = briefingID.uuidString
    }

    var snapshot: MobileLibrarySnapshot {
        MobileLibrarySnapshot(
            schemaVersion: 1, libraryID: libraryID, snapshotID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, revision: 7,
            createdAt: date, projects: [], nights: [], captures: [],
            briefings: [MobileBriefing(id: briefingID, revision: macChecklistRevision, savedAt: date.addingTimeInterval(5), nightDate: nil, readiness: "ready", targets: [], checklist: [MobileChecklistSection(id: "setup", title: "Setup", items: [MobileChecklistItem(id: itemID, title: "Focus", explanation: nil, isCompleted: false, baseRevision: macChecklistRevision)])], noteID: noteID)],
            notes: [MobileNote(id: noteID, scope: .briefing, ownerID: ownerID, text: "Mac note", baseRevision: macNoteRevision, updatedAt: date.addingTimeInterval(6), isEditableOnPhone: true)]
        )
    }

    func envelope(changes: [MobileChange]) -> MobilePackageEnvelope {
        MobilePackageEnvelope(purpose: .returnChanges, snapshot: snapshot, baseSnapshotID: snapshot.snapshotID, changes: changes, acknowledgedChangeIDs: [])
    }

    func checklistChange(id: UUID = UUID(), itemID: String? = nil, deviceID: UUID? = nil) -> MobileChange {
        .checklistCompletion(ChecklistCompletionChange(changeID: id, deviceID: deviceID ?? self.deviceID, briefingID: briefingID, itemID: itemID ?? self.itemID, baseRevision: 2, isCompleted: true, createdAt: date.addingTimeInterval(10)))
    }

    func noteChange(id: UUID = UUID(), text: String = "Phone note", deviceID: UUID? = nil) -> MobileChange {
        .noteRevision(NoteRevisionChange(changeID: id, deviceID: deviceID ?? self.deviceID, noteID: noteID, ownerID: ownerID, baseRevision: 2, text: text, createdAt: date.addingTimeInterval(11)))
    }
}

private extension MobileChange {
    var changeID: UUID {
        switch self {
        case .checklistCompletion(let value): value.changeID
        case .noteRevision(let value): value.changeID
        }
    }

    var noteText: String? {
        guard case .noteRevision(let value) = self else { return nil }
        return value.text
    }
}

private extension MobileChangeDomainBatch {
    var isProjectAnnotationBatch: Bool {
        if case .projectAnnotation = self { return true }
        return false
    }
}
