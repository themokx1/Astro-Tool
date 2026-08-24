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
        #expect(preview.rejected.isEmpty)
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
        #expect(!preview.rejected.contains { $0.changeID == collidingID })
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

    @Test("partial receipts contain only domain mutations proven durable")
    func partialReceiptExcludesSpeculativeResolutions() async throws {
        let fixture = Fixture()
        let projectID = UUID()
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
            schemaVersion: fixture.snapshot.schemaVersion,
            libraryID: fixture.libraryID,
            snapshotID: fixture.snapshot.snapshotID,
            revision: fixture.snapshot.revision,
            createdAt: fixture.snapshot.createdAt,
            projects: [], nights: [], captures: [],
            briefings: fixture.snapshot.briefings,
            notes: fixture.snapshot.notes + [projectNote]
        )
        let durableID = UUID()
        let supersededID = UUID()
        let failingID = UUID()
        let changes: [MobileChange] = [
            .noteRevision(.init(changeID: durableID, deviceID: fixture.deviceID, noteID: projectNote.id, ownerID: projectID.uuidString, baseRevision: 2, text: "Project phone", createdAt: fixture.date.addingTimeInterval(1))),
            .noteRevision(.init(changeID: supersededID, deviceID: fixture.deviceID, noteID: fixture.noteID, ownerID: fixture.ownerID, baseRevision: 2, text: "Old phone", createdAt: fixture.date.addingTimeInterval(2))),
            .noteRevision(.init(changeID: failingID, deviceID: fixture.deviceID, noteID: fixture.noteID, ownerID: fixture.ownerID, baseRevision: 2, text: "New phone", createdAt: fixture.date.addingTimeInterval(3))),
        ]
        let envelope = MobilePackageEnvelope(purpose: .returnChanges, snapshot: snapshot, baseSnapshotID: snapshot.snapshotID, changes: changes, acknowledgedChangeIDs: [])
        let calls = CommandCounter()
        let importer = MobileChangeImporter(commands: .init(applyBatch: { batch in
            calls.value += 1
            let ids: [UUID]
            switch batch {
            case .briefing(let value):
                ids = value.mutations.map {
                    switch $0 { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
                }
            case .projectAnnotation(let value): ids = value.mutations.map { $0.0.changeID }
            }
            if calls.value == 2 { throw MobileChangeImportError.commandFailed(ids[0]) }
            return .init(appliedChangeIDs: ids, resultingRevisions: Dictionary(uniqueKeysWithValues: ids.map { ($0.uuidString, 3) }))
        }))
        let preview = try importer.preview(envelope: envelope, expectedLibraryID: fixture.libraryID, currentSnapshot: snapshot, sourcePackageID: fixture.packageID)

        do {
            _ = try await importer.apply(preview: preview, envelope: envelope, currentSnapshot: snapshot, resolutions: [:], confirmed: true)
            Issue.record("The second domain batch unexpectedly succeeded")
        } catch MobileChangeImportError.partialReceipt(let partial) {
            #expect(partial.appliedChangeIDs == [durableID])
            #expect(partial.resolvedChangeIDs.isEmpty)
            #expect(!partial.resolvedChangeIDs.contains(supersededID))
        }
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

    @Test("receipt persistence accepts the exact 1 MiB edge and rejects one byte beyond it")
    func receiptLedgerUsesExactEncodedByteBoundary() throws {
        let fixture = Fixture()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-ledger-boundary-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: fileURL.appendingPathExtension("lock"))
        }
        let store = MobileChangeReceiptStore(fileURL: fileURL)
        let makeLedger: (String) -> MobileChangeApplicationLedger = { fingerprint in
            MobileChangeApplicationLedger(
                libraryID: fixture.libraryID,
                records: [MobileChangeApplicationRecord(
                    libraryID: fixture.libraryID,
                    sourcePackageID: fixture.packageID,
                    sourceFingerprint: fingerprint,
                    appliedChangeIDs: [],
                    resultingRevisions: [:],
                    recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )]
            )
        }
        let maximumBytes = 1_048_576
        let emptyBytes = try MobileJSON.encoder.encode(makeLedger("")).count
        let exact = makeLedger(String(repeating: "f", count: maximumBytes - emptyBytes))
        let exactData = try MobileJSON.encoder.encode(exact)
        #expect(exactData.count == maximumBytes)

        try store.save(exact)
        #expect(try Data(contentsOf: fileURL).count == maximumBytes)
        #expect(try store.load() == exact)

        let oversized = makeLedger(String(repeating: "f", count: maximumBytes - emptyBytes + 1))
        #expect(throws: MobileChangeImportError.limitsExceeded) {
            try store.save(oversized)
        }
        #expect(try Data(contentsOf: fileURL) == exactData)

        try (exactData + Data("x".utf8)).write(to: fileURL, options: .atomic)
        #expect(throws: MobileChangeImportError.receiptFailed) {
            _ = try store.load()
        }
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

    @Test("malformed revision keys in the acknowledgement ledger fail closed")
    func malformedLedgerRevisionKeyFailsClosed() throws {
        let fixture = Fixture()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-ledger-malformed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let valid = MobileChangeApplicationLedger(
            libraryID: fixture.libraryID,
            appliedChangeIDs: [UUID()],
            resultingRevisions: [:]
        )
        let encoded = try MobileJSON.encoder.encode(valid)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["resultingRevisions"] = ["not-a-uuid": 1]
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
        let importer = MobileChangeImporter(recordStore: MobileChangeReceiptStore(fileURL: fileURL))

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
        let original = try await revisions.create(NightBriefingDraft(
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

    @Test("production briefing batch rejects a field-note append that would push accumulated notes over the bound")
    func productionBriefingBatchRejectsAccumulatedNotesOverBound() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let briefingID = UUID()
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let revisions = NightBriefingRevisionStore(directory: paths.briefings)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_100)
        // Comfortably near the 1 MiB accumulated-notes bound; the field-note
        // wrapper plus the appended text below pushes it well over, no
        // matter how the locale formats the timestamp in the wrapper.
        let nearLimitNotes = String(repeating: "m", count: 1_048_576 - 50)
        let original = try await revisions.create(NightBriefingDraft(
            id: briefingID,
            savedAt: savedAt,
            notes: nearLimitNotes
        ))
        let changeID = UUID()
        let commands = try MobileChangeCommands.production(rootURL: root)

        await #expect(throws: MobileChangeImportError.limitsExceeded) {
            _ = try await commands.applyBatch(.briefing(.init(
                briefingID: briefingID,
                expectedRevision: original.revision,
                mutations: [.note(.init(
                    changeID: changeID,
                    noteID: "briefing-\(briefingID.uuidString.lowercased())",
                    ownerID: briefingID.uuidString,
                    text: String(repeating: "x", count: 500),
                    expectedRevision: original.revision,
                    resultingRevision: original.revision + 1,
                    createdAt: savedAt.addingTimeInterval(10)
                ), .appendFieldNote)]
            )))
        }

        let latest = try #require(await revisions.latest(id: briefingID))
        #expect(latest.revision == original.revision)
        #expect(latest.notes == nearLimitNotes)
        #expect(!latest.mobileChangeIDs.contains(changeID))
    }

    @Test("production briefing batch accepts a resulting notes text exactly at the accumulated bound")
    func productionBriefingBatchAcceptsExactAccumulatedNotesBound() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let briefingID = UUID()
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let revisions = NightBriefingRevisionStore(directory: paths.briefings)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let original = try await revisions.create(NightBriefingDraft(
            id: briefingID,
            savedAt: savedAt,
            notes: "Mac note"
        ))
        let changeID = UUID()
        let exactlyAtBound = String(repeating: "n", count: 1_048_576)
        let commands = try MobileChangeCommands.production(rootURL: root)

        _ = try await commands.applyBatch(.briefing(.init(
            briefingID: briefingID,
            expectedRevision: original.revision,
            mutations: [.note(.init(
                changeID: changeID,
                noteID: "briefing-\(briefingID.uuidString.lowercased())",
                ownerID: briefingID.uuidString,
                text: exactlyAtBound,
                expectedRevision: original.revision,
                resultingRevision: original.revision + 1,
                createdAt: savedAt.addingTimeInterval(10)
            ), .replace)]
        )))

        let latest = try #require(await revisions.latest(id: briefingID))
        #expect(latest.notes.utf8.count == 1_048_576)
        #expect(latest.mobileChangeIDs == [changeID])
    }

    @Test("same-ID concurrent production retries create one briefing revision and one field note")
    func concurrentProductionRetriesAreIdempotent() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let briefingID = UUID()
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let revisions = NightBriefingRevisionStore(directory: paths.briefings)
        let original = try await revisions.create(NightBriefingDraft(
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

    @Test("one root-wide change ID cannot be claimed concurrently by different owners")
    func concurrentCrossOwnerCollisionHasOneWinner() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let briefings = NightBriefingRevisionStore(directory: paths.briefings)
        let metadata = try MetadataStore(storagePaths: paths)
        let briefingID = UUID()
        let projectID = UUID()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let briefing = try await briefings.create(NightBriefingDraft(id: briefingID, savedAt: baseline, notes: "Mac brief"))
        try await metadata.save(ProjectRecord(id: projectID, catalogID: "m31", displayName: "M31", phase: .planned))
        try await metadata.createProjectAnnotation(ProjectAnnotationRecord(projectID: projectID, integrationGoalHours: nil, notes: "Mac project", updatedAt: baseline))
        let changeID = UUID()
        let briefingBatch = MobileChangeDomainBatch.briefing(.init(
            briefingID: briefingID,
            expectedRevision: briefing.revision,
            mutations: [.note(.init(
                changeID: changeID,
                deviceID: UUID(),
                noteID: "briefing-\(briefingID.uuidString.lowercased())",
                ownerID: briefingID.uuidString,
                phoneBaseRevision: 1,
                text: "Phone brief",
                expectedRevision: 1,
                resultingRevision: 2,
                createdAt: baseline.addingTimeInterval(1)
            ), .replace)]
        ))
        let projectBatch = MobileChangeDomainBatch.projectAnnotation(.init(
            projectID: projectID,
            expectedRevision: 0,
            mutations: [(.init(
                changeID: changeID,
                deviceID: UUID(),
                noteID: "project-\(projectID.uuidString.lowercased())",
                ownerID: projectID.uuidString,
                phoneBaseRevision: 0,
                text: "Phone project",
                expectedRevision: 0,
                resultingRevision: 1,
                createdAt: baseline.addingTimeInterval(2)
            ), .replace)]
        ))
        let first = try MobileChangeCommands.production(rootURL: root)
        let second = try MobileChangeCommands.production(rootURL: root)

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            group.addTask { do { _ = try await first.applyBatch(briefingBatch); return true } catch { return false } }
            group.addTask { do { _ = try await second.applyBatch(projectBatch); return true } catch { return false } }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        let finalBriefing = try #require(await briefings.latest(id: briefingID))
        let finalProject = try #require(await metadata.projectAnnotation(projectID: projectID))

        #expect(successes == 1)
        #expect((finalBriefing.notes == "Phone brief") != (finalProject.notes == "Phone project"))
    }

    @Test("a retry after later Mac revisions returns the marker's exact durable result")
    func retryReturnsMarkerRevision() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let revisions = NightBriefingRevisionStore(directory: paths.briefings)
        let briefingID = UUID()
        let deviceID = UUID()
        let changeID = UUID()
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try await revisions.create(NightBriefingDraft(id: briefingID, savedAt: baseline, notes: "Mac"))
        let commands = try MobileChangeCommands.production(rootURL: root)
        func batch(expected: Int) -> MobileChangeDomainBatch {
            .briefing(.init(
                briefingID: briefingID,
                expectedRevision: expected,
                mutations: [.note(.init(
                    changeID: changeID,
                    deviceID: deviceID,
                    noteID: "briefing-\(briefingID.uuidString.lowercased())",
                    ownerID: briefingID.uuidString,
                    phoneBaseRevision: original.revision,
                    text: "Phone",
                    expectedRevision: expected,
                    resultingRevision: expected + 1,
                    createdAt: baseline.addingTimeInterval(1)
                ), .replace)]
            ))
        }

        let first = try await commands.applyBatch(batch(expected: original.revision))
        var later = try #require(await revisions.latest(id: briefingID))
        later.notes = "Later Mac edit"
        later = try await revisions.saveIfLatest(later, expectedRevision: later.revision)
        let retried = try await commands.applyBatch(batch(expected: later.revision))

        #expect(first.resultingRevisions[changeID.uuidString] == original.revision + 1)
        #expect(retried.resultingRevisions[changeID.uuidString] == original.revision + 1)
        #expect(try await revisions.latest(id: briefingID)?.revision == later.revision)
    }

    @Test("duplicate embedded markers fail with typed corruption")
    func duplicateEmbeddedMarkersFailClosed() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let revisions = NightBriefingRevisionStore(directory: paths.briefings)
        let briefingID = UUID()
        let markerID = UUID()
        let marker = MobileChangeMarker(
            changeID: markerID,
            ownerID: "briefing:\(briefingID.uuidString.lowercased())",
            payloadFingerprint: String(repeating: "a", count: 64),
            resultingRevision: 1
        )
        // Seeding a durable revision with duplicate embedded markers is
        // deliberately corrupt fixture state used only to exercise the
        // bridge's own marker validation on read; the public `create` no
        // longer accepts any mobile evidence, so this uses the
        // package-internal bridge-writing path directly.
        _ = try await revisions.saveIfLatestRecordingMobileEvidence(NightBriefingDraft(
            id: briefingID,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "Corrupt",
            mobileChangeIDs: [markerID],
            mobileChangeMarkers: [marker, marker]
        ), expectedRevision: 0)
        let commands = try MobileChangeCommands.production(rootURL: root)
        let newID = UUID()
        let batch = MobileChangeDomainBatch.briefing(.init(
            briefingID: briefingID,
            expectedRevision: 1,
            mutations: [.note(.init(
                changeID: newID,
                noteID: "briefing-\(briefingID.uuidString.lowercased())",
                ownerID: briefingID.uuidString,
                text: "New",
                expectedRevision: 1,
                resultingRevision: 2,
                createdAt: Date(timeIntervalSince1970: 1_700_000_001)
            ), .replace)]
        ))

        await #expect(throws: MobileChangeImportError.corruptDomainMarkers) {
            _ = try await commands.applyBatch(batch)
        }
    }

    @Test("field-note retry after receipt failure finds the immutable domain marker")
    func fieldNoteReceiptRetryDoesNotRepeatMutation() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let revisions = NightBriefingRevisionStore(directory: paths.briefings)
        let libraryID = PortableLibraryID(rawValue: UUID())
        let briefingID = UUID()
        let noteID = "briefing-\(briefingID.uuidString.lowercased())"
        let original = try await revisions.create(NightBriefingDraft(id: briefingID, savedAt: Date(timeIntervalSince1970: 1_700_000_000), notes: "Base"))
        var macEdit = original
        macEdit.notes = "Mac edit"
        macEdit.savedAt = original.savedAt.addingTimeInterval(1)
        let currentDraft = try await revisions.saveIfLatest(macEdit, expectedRevision: original.revision)
        func snapshot(_ draft: NightBriefingDraft) -> MobileLibrarySnapshot {
            .init(
                schemaVersion: 1, libraryID: libraryID, snapshotID: UUID(), revision: draft.revision, createdAt: draft.savedAt,
                projects: [], nights: [], captures: [],
                briefings: [.init(id: briefingID, revision: draft.revision, savedAt: draft.savedAt, nightDate: nil, readiness: "ready", targets: [], checklist: [], noteID: noteID)],
                notes: [.init(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: draft.notes, baseRevision: draft.revision, updatedAt: draft.savedAt, isEditableOnPhone: true)]
            )
        }
        let sentBase = snapshot(original)
        let changeID = UUID()
        let envelope = MobilePackageEnvelope(
            purpose: .returnChanges,
            snapshot: sentBase,
            baseSnapshotID: sentBase.snapshotID,
            changes: [.noteRevision(.init(
                changeID: changeID,
                deviceID: UUID(),
                noteID: noteID,
                ownerID: briefingID.uuidString,
                baseRevision: original.revision,
                text: "Phone field note",
                createdAt: currentDraft.savedAt.addingTimeInterval(1)
            ))],
            acknowledgedChangeIDs: []
        )
        let receiptStore = FailFirstSaveRecordStore()
        let importer = try MobileChangeImporter.production(rootURL: root, recordStore: receiptStore)
        let firstCurrent = snapshot(currentDraft)
        let firstPreview = try importer.preview(envelope: envelope, expectedLibraryID: libraryID, expectedBaseSnapshotID: sentBase.snapshotID, currentSnapshot: firstCurrent, sourcePackageID: UUID())
        let conflictID = try #require(firstPreview.conflicts.first?.changeID)

        await #expect(throws: MobileChangeImportError.self) {
            _ = try await importer.apply(preview: firstPreview, envelope: envelope, currentSnapshot: firstCurrent, resolutions: [conflictID: .keepBothAsFieldNote], confirmed: true)
        }
        let afterFailure = try #require(await revisions.latest(id: briefingID))
        #expect(afterFailure.notes.components(separatedBy: "— Phone field note —").count == 2)

        let retryCurrent = snapshot(afterFailure)
        let retryPreview = try importer.preview(envelope: envelope, expectedLibraryID: libraryID, expectedBaseSnapshotID: sentBase.snapshotID, currentSnapshot: retryCurrent, sourcePackageID: firstPreview.sourcePackageID)
        let receipt = try await importer.apply(preview: retryPreview, envelope: envelope, currentSnapshot: retryCurrent, resolutions: [changeID: .keepBothAsFieldNote], confirmed: true)
        let afterRetry = try #require(await revisions.latest(id: briefingID))

        #expect(receipt.appliedChangeIDs == [changeID])
        #expect(afterRetry.revision == afterFailure.revision)
        #expect(afterRetry.notes.components(separatedBy: "— Phone field note —").count == 2)
    }

    @Test("project annotation batch uses compare-and-set and retains a monotonic revision")
    func projectAnnotationBatchUsesCAS() async throws {
        let store = try MetadataStore.temporary()
        let projectID = UUID()
        try await store.save(ProjectRecord(id: projectID, catalogID: "m31", displayName: "M31", phase: .planned))
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.createProjectAnnotation(ProjectAnnotationRecord(projectID: projectID, integrationGoalHours: nil, notes: "Mac", updatedAt: baseline))
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

        _ = try await store.saveProjectAnnotation(
            ProjectAnnotationRecord(projectID: projectID, integrationGoalHours: nil, notes: "Mac edit", updatedAt: baseline, revision: applied.revision),
            expectedRevision: applied.revision
        )
        #expect(try await store.projectAnnotation(projectID: projectID)?.revision == 2)
    }
}

private final class CommandCounter: @unchecked Sendable {
    var value = 0
    var batches: [MobileChangeDomainBatch] = []
}

private final class FailFirstSaveRecordStore: MobileChangeApplicationRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: MobileChangeApplicationLedger?
    private var shouldFail = true

    func load() throws -> MobileChangeApplicationLedger? {
        lock.withLock { ledger }
    }

    func save(_ ledger: MobileChangeApplicationLedger) throws {
        try lock.withLock {
            if shouldFail {
                shouldFail = false
                throw MobileChangeImportError.receiptFailed
            }
            self.ledger = ledger
        }
    }
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
