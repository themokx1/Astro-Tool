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
        let importer = MobileChangeImporter(commands: .init(
            saveChecklist: { command in commands.value += 1; return command.resultingRevision },
            saveNote: { command in commands.value += 1; return command.resultingRevision },
            addFieldNote: { _ in commands.value += 1; return nil }
        ))

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

    @Test("apply requires explicit confirmation and records the narrow command receipt")
    func applyIsSecondPhase() async throws {
        let fixture = Fixture()
        let calls = CommandCounter()
        let importer = MobileChangeImporter(commands: .init(
            saveChecklist: { command in calls.value += 1; return command.resultingRevision },
            saveNote: { command in calls.value += 1; return command.resultingRevision },
            addFieldNote: { _ in calls.value += 1; return nil }
        ))
        let envelope = fixture.envelope(changes: [fixture.checklistChange(), fixture.noteChange()])
        let preview = try importer.preview(envelope: envelope, expectedLibraryID: fixture.libraryID, currentSnapshot: fixture.snapshot, sourcePackageID: fixture.packageID)

        await #expect(throws: MobileChangeImportError.finalConfirmationRequired) {
            try await importer.apply(preview: preview, envelope: envelope, currentSnapshot: fixture.snapshot, resolutions: [:], confirmed: false)
        }
        #expect(calls.value == 0)
        let receipt = try await importer.apply(preview: preview, envelope: envelope, currentSnapshot: fixture.snapshot, resolutions: [:], confirmed: true)
        #expect(receipt.appliedChangeIDs.count == 2)
        #expect(calls.value == 2)
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
        let importer = MobileChangeImporter(commands: .init(
            saveChecklist: { command in calls.value += 1; return command.resultingRevision },
            saveNote: { command in calls.value += 1; return command.resultingRevision },
            addFieldNote: { _ in calls.value += 1; return nil }
        ), recordStore: recordStore)
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
}

private final class CommandCounter: @unchecked Sendable {
    var value = 0
}

private struct Fixture {
    let libraryID = PortableLibraryID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let briefingID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let itemID = "focus"
    let noteID = "briefing-note"
    let ownerID = "briefing-owner"
    let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let packageID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let macChecklistRevision: Int
    let macNoteRevision: Int

    init(macChecklistRevision: Int = 2, macNoteRevision: Int = 2) {
        self.macChecklistRevision = macChecklistRevision
        self.macNoteRevision = macNoteRevision
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
