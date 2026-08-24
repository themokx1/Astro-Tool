import Foundation
import Testing
@testable import AstroApplication
@testable import AstroMobileDomain
@testable import AstroMobileTransport

@Suite("Mobile return application coordinator")
struct MobileReturnApplicationCoordinatorTests {
    @Test("a published sent base can be claimed exactly once across store instances")
    func publishedBaseHasOneBoundClaimant() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("return-claim-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("sent.json")
        let snapshotID = UUID()
        let firstPackageID = UUID()
        let secondPackageID = UUID()
        let acknowledgementID = UUID()
        let first = MobileSentSnapshotIdentityStore(fileURL: fileURL)
        let second = MobileSentSnapshotIdentityStore(fileURL: fileURL)
        try first.reserve(snapshotID: snapshotID, acknowledgementIDs: [acknowledgementID])
        try first.markPublished(snapshotID: snapshotID)

        let claimed = try first.claimPublished(
            snapshotID: snapshotID,
            packageID: firstPackageID,
            sourceFingerprint: String(repeating: "a", count: 64)
        )

        #expect(claimed.acknowledgementIDs == [acknowledgementID])
        #expect(throws: MobileChangeImportError.snapshotMismatch) {
            try second.claimPublished(
                snapshotID: snapshotID,
                packageID: secondPackageID,
                sourceFingerprint: String(repeating: "b", count: 64)
            )
        }
        #expect(try second.claimPublished(
            snapshotID: snapshotID,
            packageID: firstPackageID,
            sourceFingerprint: String(repeating: "a", count: 64)
        ) == claimed)
    }

    @Test("failed publication removes its reservation instead of leaking capacity")
    func failedPublicationReleasesPendingRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("return-reservation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent.json"))
        let snapshotID = UUID()

        try store.reserve(snapshotID: snapshotID, acknowledgementIDs: [])
        try store.cancelPending(snapshotID: snapshotID)

        #expect(try store.loadRecords().isEmpty)
    }

    @Test("discarded public review cannot apply a copied value")
    func discardedReviewCannotApplyCopiedValue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("return-coordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let libraryID = PortableLibraryID(rawValue: UUID())
        let base = MobileLibrarySnapshot.empty(libraryID: libraryID)
        let service = MobilePackageService()
        let key = OneTimePackageKey()
        let source = root.appendingPathComponent("phone-return.astromobile", isDirectory: true)
        _ = try await service.export(
            MobilePackageEnvelope(purpose: .returnChanges, snapshot: base, baseSnapshotID: base.snapshotID, changes: [], acknowledgedChangeIDs: []),
            to: source,
            wrapping: key
        )
        let sent = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json"))
        try sent.reserve(snapshotID: base.snapshotID, acknowledgementIDs: [])
        try sent.markPublished(snapshotID: base.snapshotID)
        let coordinator = try MobileReturnApplicationCoordinator.production(
            rootURL: root,
            packageService: service,
            currentSnapshotProvider: { base }
        )

        let review = try await coordinator.preview(from: source, wrapping: key)
        let copiedReview = review
        await coordinator.discard(review)
        await #expect(throws: MobileChangeImportError.stalePreview) {
            try await coordinator.apply(copiedReview, resolutions: [:], confirmed: true)
        }
    }

    @Test("encrypted return mutates the real briefing store and the next forward package acknowledges it")
    func realReturnToImmediateForwardAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("return-e2e-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identityStore = PortableLibraryIdentityStore()
        let libraryID = try identityStore.preview(root: root).proposedID
        _ = try identityStore.loadOrCreate(root: root, confirmedID: libraryID)
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let briefingStore = NightBriefingRevisionStore(directory: paths.briefings)
        let briefingID = UUID()
        let noteID = "briefing-\(briefingID.uuidString.lowercased())"
        let original = try await briefingStore.create(NightBriefingDraft(
            id: briefingID,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "Mac note"
        ))
        let revisions = MobileSnapshotRevisionStore(
            fileURL: root.appendingPathComponent(".astro-tool/mobile-snapshot-revision.json")
        )
        @Sendable func snapshot(_ draft: NightBriefingDraft, revision: Int) -> MobileLibrarySnapshot {
            MobileLibrarySnapshot(
                schemaVersion: 1,
                libraryID: libraryID,
                snapshotID: UUID(),
                revision: revision,
                createdAt: draft.savedAt,
                projects: [],
                nights: [],
                captures: [],
                briefings: [.init(
                    id: draft.id,
                    revision: draft.revision,
                    savedAt: draft.savedAt,
                    nightDate: draft.nightDate,
                    readiness: "ready",
                    targets: [],
                    checklist: [],
                    noteID: noteID
                )],
                notes: [.init(
                    id: noteID,
                    scope: .briefing,
                    ownerID: briefingID.uuidString,
                    text: draft.notes,
                    baseRevision: draft.revision,
                    updatedAt: draft.savedAt,
                    isEditableOnPhone: true
                )]
            )
        }
        let firstRevision = try await revisions.next()
        let base = snapshot(original, revision: firstRevision)
        let service = MobilePackageService()
        let coordinator = try MobileReturnApplicationCoordinator.production(
            rootURL: root,
            packageService: service,
            currentSnapshotProvider: {
                let latest = try await briefingStore.latest(id: briefingID) ?? original
                return snapshot(latest, revision: try await revisions.current())
            }
        )
        let forwardURL = root.appendingPathComponent("forward.astromobile", isDirectory: true)
        _ = try await coordinator.publishForwardSnapshot(base, to: forwardURL, wrapping: OneTimePackageKey())

        let changeID = UUID()
        let returnURL = root.appendingPathComponent("return.astromobile", isDirectory: true)
        let returnKey = OneTimePackageKey()
        _ = try await service.export(
            MobilePackageEnvelope(
                purpose: .returnChanges,
                snapshot: base,
                baseSnapshotID: base.snapshotID,
                changes: [.noteRevision(.init(
                    changeID: changeID,
                    deviceID: UUID(),
                    noteID: noteID,
                    ownerID: briefingID.uuidString,
                    baseRevision: original.revision,
                    text: "Phone note",
                    createdAt: original.savedAt.addingTimeInterval(1)
                ))],
                acknowledgedChangeIDs: []
            ),
            to: returnURL,
            wrapping: returnKey
        )
        let review = try await coordinator.preview(from: returnURL, wrapping: returnKey)
        let receipt = try await coordinator.apply(review, resolutions: [:], confirmed: true)
        let changed = try #require(await briefingStore.latest(id: briefingID))

        #expect(changed.notes == "Phone note")
        #expect(receipt.appliedChangeIDs == [changeID])

        let secondRevision = try await revisions.next()
        let refreshed = snapshot(changed, revision: secondRevision)
        let acknowledgementURL = root.appendingPathComponent("ack-forward.astromobile", isDirectory: true)
        let acknowledgementKey = OneTimePackageKey()
        _ = try await coordinator.publishForwardSnapshot(refreshed, to: acknowledgementURL, wrapping: acknowledgementKey)
        let reader = MobilePackageService()
        let authenticated = try await reader.authenticatePreview(from: acknowledgementURL, wrapping: acknowledgementKey)
        let envelope = try #require(await reader.validatedEnvelope(token: authenticated.token))

        #expect(envelope.acknowledgedChangeIDs == [changeID])
        #expect(try MobileSentSnapshotIdentityStore(
            fileURL: root.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json")
        ).loadPublishedRecords().map(\.snapshotID) == [refreshed.snapshotID])
    }

    @Test("a failed apply releases its claim so a different package can claim the base")
    func failedApplyReleasesClaimForDifferentPackage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("return-release-other-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identityStore = PortableLibraryIdentityStore()
        let libraryID = try identityStore.preview(root: root).proposedID
        _ = try identityStore.loadOrCreate(root: root, confirmedID: libraryID)
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let briefingStore = NightBriefingRevisionStore(directory: paths.briefings)
        let briefingID = UUID()
        let noteID = "briefing-\(briefingID.uuidString.lowercased())"
        let original = try await briefingStore.create(NightBriefingDraft(
            id: briefingID,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "Mac note"
        ))
        let base = MobileLibrarySnapshot(
            schemaVersion: 1,
            libraryID: libraryID,
            snapshotID: UUID(),
            revision: 1,
            createdAt: original.savedAt,
            projects: [], nights: [], captures: [],
            briefings: [.init(id: briefingID, revision: original.revision, savedAt: original.savedAt, nightDate: nil, readiness: "ready", targets: [], checklist: [], noteID: noteID)],
            notes: [.init(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: original.notes, baseRevision: original.revision, updatedAt: original.savedAt, isEditableOnPhone: true)]
        )
        let service = MobilePackageService()
        let sentFileURL = root.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json")
        let sent = MobileSentSnapshotIdentityStore(fileURL: sentFileURL)
        try sent.reserve(snapshotID: base.snapshotID, acknowledgementIDs: [])
        try sent.markPublished(snapshotID: base.snapshotID)
        let coordinator = try MobileReturnApplicationCoordinator.production(
            rootURL: root,
            packageService: service,
            currentSnapshotProvider: { base }
        )
        let returnURL = root.appendingPathComponent("return.astromobile", isDirectory: true)
        let returnKey = OneTimePackageKey()
        _ = try await service.export(
            MobilePackageEnvelope(
                purpose: .returnChanges,
                snapshot: base,
                baseSnapshotID: base.snapshotID,
                changes: [.noteRevision(.init(changeID: UUID(), deviceID: UUID(), noteID: noteID, ownerID: briefingID.uuidString, baseRevision: original.revision, text: "Phone note", createdAt: original.savedAt.addingTimeInterval(1)))],
                acknowledgedChangeIDs: []
            ),
            to: returnURL,
            wrapping: returnKey
        )
        let review = try await coordinator.preview(from: returnURL, wrapping: returnKey)

        // confirmed: false makes the real importer's apply throw
        // `finalConfirmationRequired` immediately after the coordinator has
        // already claimed the base.
        await #expect(throws: MobileChangeImportError.finalConfirmationRequired) {
            try await coordinator.apply(review, resolutions: [:], confirmed: false)
        }

        // The base must not be permanently stuck as claimed: a wholly
        // different package can claim it now.
        let otherPackageID = UUID()
        let otherFingerprint = String(repeating: "c", count: 64)
        let reclaimed = try MobileSentSnapshotIdentityStore(fileURL: sentFileURL).claimPublished(
            snapshotID: base.snapshotID,
            packageID: otherPackageID,
            sourceFingerprint: otherFingerprint
        )
        #expect(reclaimed.claimedPackageID == otherPackageID)

        // Nothing was written to the domain store by the failed attempt.
        let stillOriginal = try #require(await briefingStore.latest(id: briefingID))
        #expect(stillOriginal.notes == "Mac note")
        #expect(stillOriginal.revision == original.revision)
    }

    @Test("a successful retry of the same package still works after a failed apply attempt")
    func sameProductPackageCanRetryAfterFailedApply() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("return-release-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identityStore = PortableLibraryIdentityStore()
        let libraryID = try identityStore.preview(root: root).proposedID
        _ = try identityStore.loadOrCreate(root: root, confirmedID: libraryID)
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let briefingStore = NightBriefingRevisionStore(directory: paths.briefings)
        let briefingID = UUID()
        let noteID = "briefing-\(briefingID.uuidString.lowercased())"
        let original = try await briefingStore.create(NightBriefingDraft(
            id: briefingID,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "Mac note"
        ))
        let base = MobileLibrarySnapshot(
            schemaVersion: 1,
            libraryID: libraryID,
            snapshotID: UUID(),
            revision: 1,
            createdAt: original.savedAt,
            projects: [], nights: [], captures: [],
            briefings: [.init(id: briefingID, revision: original.revision, savedAt: original.savedAt, nightDate: nil, readiness: "ready", targets: [], checklist: [], noteID: noteID)],
            notes: [.init(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: original.notes, baseRevision: original.revision, updatedAt: original.savedAt, isEditableOnPhone: true)]
        )
        let service = MobilePackageService()
        let sent = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json"))
        try sent.reserve(snapshotID: base.snapshotID, acknowledgementIDs: [])
        try sent.markPublished(snapshotID: base.snapshotID)
        let coordinator = try MobileReturnApplicationCoordinator.production(
            rootURL: root,
            packageService: service,
            currentSnapshotProvider: { base }
        )
        let changeID = UUID()
        let returnURL = root.appendingPathComponent("return.astromobile", isDirectory: true)
        let returnKey = OneTimePackageKey()
        _ = try await service.export(
            MobilePackageEnvelope(
                purpose: .returnChanges,
                snapshot: base,
                baseSnapshotID: base.snapshotID,
                changes: [.noteRevision(.init(changeID: changeID, deviceID: UUID(), noteID: noteID, ownerID: briefingID.uuidString, baseRevision: original.revision, text: "Phone note", createdAt: original.savedAt.addingTimeInterval(1)))],
                acknowledgedChangeIDs: []
            ),
            to: returnURL,
            wrapping: returnKey
        )
        let review = try await coordinator.preview(from: returnURL, wrapping: returnKey)

        await #expect(throws: MobileChangeImportError.finalConfirmationRequired) {
            try await coordinator.apply(review, resolutions: [:], confirmed: false)
        }

        // Retrying with the very same review (same package) still succeeds:
        // the release did not consume the package's capability or the
        // coordinator's session.
        let receipt = try await coordinator.apply(review, resolutions: [:], confirmed: true)
        #expect(receipt.appliedChangeIDs == [changeID])
        let changed = try #require(await briefingStore.latest(id: briefingID))
        #expect(changed.notes == "Phone note")
    }

    @Test("a successful apply that fails post-apply finalization keeps its claim; the same package can retry to a clean completion")
    func postApplyFinalizationFailureRetainsClaimAndSamePackageRetrySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("return-partial-finalize-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let identityStore = PortableLibraryIdentityStore()
        let libraryID = try identityStore.preview(root: root).proposedID
        _ = try identityStore.loadOrCreate(root: root, confirmedID: libraryID)
        let paths = try AppStoragePaths.production(libraryID: LibraryIdentity(rootURL: root), libraryRoot: root)
        let briefingStore = NightBriefingRevisionStore(directory: paths.briefings)
        let briefingID = UUID()
        let noteID = "briefing-\(briefingID.uuidString.lowercased())"
        let original = try await briefingStore.create(NightBriefingDraft(
            id: briefingID,
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "Mac note"
        ))
        let base = MobileLibrarySnapshot(
            schemaVersion: 1,
            libraryID: libraryID,
            snapshotID: UUID(),
            revision: 1,
            createdAt: original.savedAt,
            projects: [], nights: [], captures: [],
            briefings: [.init(id: briefingID, revision: original.revision, savedAt: original.savedAt, nightDate: nil, readiness: "ready", targets: [], checklist: [], noteID: noteID)],
            notes: [.init(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: original.notes, baseRevision: original.revision, updatedAt: original.savedAt, isEditableOnPhone: true)]
        )
        let service = MobilePackageService()
        let sentFileURL = root.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json")
        let sent = MobileSentSnapshotIdentityStore(fileURL: sentFileURL)
        // A non-empty acknowledgement set is required so the coordinator's
        // post-apply `acknowledgePhoneEvidence` call actually reaches the
        // (failing) ledger store instead of short-circuiting on an empty set.
        let acknowledgementID = UUID()
        try sent.reserve(snapshotID: base.snapshotID, acknowledgementIDs: [acknowledgementID])
        try sent.markPublished(snapshotID: base.snapshotID)
        // Real domain commands (via `.production`), but a ledger store that
        // fails only its 2nd `updateLedger` call. Call #1 is the importer's
        // own atomic persistence of the applied change markers inside
        // `importer.apply` (must succeed, so the note write really lands).
        // Call #2 is `acknowledgePhoneEvidence`, invoked by the coordinator
        // strictly after `importer.apply` has already returned a receipt -
        // this is the "successful domain apply, failing post-apply
        // finalization" seam the task asks for.
        let failingLedger = FailOnceLedgerStore(failingCallIndex: 2)
        let importer = try MobileChangeImporter.production(rootURL: root, recordStore: failingLedger)
        let coordinator = MobileReturnApplicationCoordinator(
            packageService: service,
            importer: importer,
            sentBases: sent,
            currentSnapshotProvider: { base }
        )
        let changeID = UUID()
        let returnURL = root.appendingPathComponent("return.astromobile", isDirectory: true)
        let returnKey = OneTimePackageKey()
        _ = try await service.export(
            MobilePackageEnvelope(
                purpose: .returnChanges,
                snapshot: base,
                baseSnapshotID: base.snapshotID,
                changes: [.noteRevision(.init(changeID: changeID, deviceID: UUID(), noteID: noteID, ownerID: briefingID.uuidString, baseRevision: original.revision, text: "Phone note", createdAt: original.savedAt.addingTimeInterval(1)))],
                acknowledgedChangeIDs: []
            ),
            to: returnURL,
            wrapping: returnKey
        )

        let review = try await coordinator.preview(from: returnURL, wrapping: returnKey)

        do {
            _ = try await coordinator.apply(review, resolutions: [:], confirmed: true)
            Issue.record("Expected the post-apply finalization to fail with partialReceipt")
        } catch MobileChangeImportError.partialReceipt(let receipt) {
            // The reviewed note change really landed before finalization
            // failed.
            #expect(receipt.appliedChangeIDs == [changeID])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Pin: only the importer.apply failure path (the earlier catch in
        // `MobileReturnApplicationCoordinator.apply`) releases the claim.
        // A failure in the later finalization stage must leave the base
        // `.claimed` for this exact package - not released back to
        // `.published`, and not consumed/removed.
        let recordsAfterFailure = try sent.loadRecords()
        let claimedRecord = try #require(recordsAfterFailure.first { $0.snapshotID == base.snapshotID })
        #expect(claimedRecord.state == .claimed)
        #expect(claimedRecord.claimedPackageID == review.packagePreview.packageID)
        #expect(claimedRecord.claimedSourceFingerprint == review.changePreview.sourceFingerprint)

        // The domain write is durable even though the coordinator reported
        // failure.
        let afterFailure = try #require(await briefingStore.latest(id: briefingID))
        #expect(afterFailure.notes == "Phone note")

        // Retrying the very same package (source + key) must still complete:
        // discard the stale session/capability, re-authenticate the exact
        // same on-disk package, and re-apply. The already-applied change is
        // now classified `alreadyApplied` (idempotent, no double domain
        // write), the durable claim is reused rather than re-created, and
        // this time finalization succeeds because the ledger store's single
        // scripted failure was already spent.
        await coordinator.discard(review)
        let retryReview = try await coordinator.preview(from: returnURL, wrapping: returnKey)
        #expect(retryReview.changePreview.applicable.isEmpty)
        let receipt = try await coordinator.apply(retryReview, resolutions: [:], confirmed: true)
        #expect(receipt.appliedChangeIDs.isEmpty)

        // The base is now fully retired: no leaked claim, no way to reuse it.
        let recordsAfterRetry = try sent.loadRecords()
        #expect(recordsAfterRetry.first { $0.snapshotID == base.snapshotID } == nil)

        // Still exactly the one note write from the original attempt.
        let finalNote = try #require(await briefingStore.latest(id: briefingID))
        #expect(finalNote.notes == "Phone note")
    }

    @Test("competing packages for one published base perform exactly one domain write")
    func competingBaseHasOneApplyingSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("return-compete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let libraryID = PortableLibraryID(rawValue: UUID())
        let briefingID = UUID()
        let noteID = "briefing-\(briefingID.uuidString.lowercased())"
        let base = MobileLibrarySnapshot(
            schemaVersion: 1,
            libraryID: libraryID,
            snapshotID: UUID(),
            revision: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projects: [], nights: [], captures: [],
            briefings: [.init(id: briefingID, revision: 1, savedAt: Date(timeIntervalSince1970: 1_700_000_000), nightDate: nil, readiness: "ready", targets: [], checklist: [], noteID: noteID)],
            notes: [.init(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: "Mac", baseRevision: 1, updatedAt: Date(timeIntervalSince1970: 1_700_000_000), isEditableOnPhone: true)]
        )
        let writes = LockedCounter()
        let importer = MobileChangeImporter(commands: .init(applyBatch: { batch in
            writes.increment()
            let ids: [UUID]
            switch batch {
            case .briefing(let value):
                ids = value.mutations.map { mutation in
                    switch mutation { case .checklist(let command): command.changeID; case .note(let command, _): command.changeID }
                }
            case .projectAnnotation(let value): ids = value.mutations.map { $0.0.changeID }
            }
            return .init(appliedChangeIDs: ids, resultingRevisions: Dictionary(uniqueKeysWithValues: ids.map { ($0.uuidString, 2) }))
        }))
        let sent = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent("sent.json"))
        try sent.reserve(snapshotID: base.snapshotID, acknowledgementIDs: [])
        try sent.markPublished(snapshotID: base.snapshotID)
        let service = MobilePackageService()
        let coordinator = MobileReturnApplicationCoordinator(
            packageService: service,
            importer: importer,
            sentBases: sent,
            currentSnapshotProvider: { base }
        )
        func makeChange(_ text: String) -> MobileChange {
            .noteRevision(.init(changeID: UUID(), deviceID: UUID(), noteID: noteID, ownerID: briefingID.uuidString, baseRevision: 1, text: text, createdAt: Date(timeIntervalSince1970: 1_700_000_001)))
        }
        let firstURL = root.appendingPathComponent("first.astromobile", isDirectory: true)
        let secondURL = root.appendingPathComponent("second.astromobile", isDirectory: true)
        let firstKey = OneTimePackageKey()
        let secondKey = OneTimePackageKey()
        _ = try await service.export(MobilePackageEnvelope(purpose: .returnChanges, snapshot: base, baseSnapshotID: base.snapshotID, changes: [makeChange("First")], acknowledgedChangeIDs: []), to: firstURL, wrapping: firstKey)
        _ = try await service.export(MobilePackageEnvelope(purpose: .returnChanges, snapshot: base, baseSnapshotID: base.snapshotID, changes: [makeChange("Second")], acknowledgedChangeIDs: []), to: secondURL, wrapping: secondKey)
        let firstReview = try await coordinator.preview(from: firstURL, wrapping: firstKey)
        let secondReview = try await coordinator.preview(from: secondURL, wrapping: secondKey)

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            group.addTask { do { _ = try await coordinator.apply(firstReview, resolutions: [:], confirmed: true); return true } catch { return false } }
            group.addTask { do { _ = try await coordinator.apply(secondReview, resolutions: [:], confirmed: true); return true } catch { return false } }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }

        #expect(successes == 1)
        #expect(writes.value == 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

/// A `MobileChangeApplicationRecordStore` that persists normally except on
/// one scripted `updateLedger` call (1-indexed across the store's lifetime),
/// which fails outright. Used to simulate a ledger-write failure strictly
/// after `importer.apply`'s own successful persistence, isolating the
/// coordinator's separate post-apply finalization failure path.
private final class FailOnceLedgerStore: MobileChangeApplicationRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: MobileChangeApplicationLedger?
    private var callCount = 0
    private let failingCallIndex: Int

    init(failingCallIndex: Int) {
        self.failingCallIndex = failingCallIndex
    }

    func load() throws -> MobileChangeApplicationLedger? {
        lock.withLock { ledger }
    }

    func save(_ ledger: MobileChangeApplicationLedger) throws {
        lock.withLock { self.ledger = ledger }
    }

    func updateLedger(
        _ mutation: (MobileChangeApplicationLedger?) throws -> MobileChangeApplicationLedger?
    ) throws {
        let (currentCall, current): (Int, MobileChangeApplicationLedger?) = lock.withLock {
            callCount += 1
            return (callCount, ledger)
        }
        guard currentCall != failingCallIndex else {
            throw MobileChangeImportError.receiptFailed
        }
        if let next = try mutation(current) {
            lock.withLock { ledger = next }
        }
    }
}

private extension MobileLibrarySnapshot {
    static func empty(libraryID: PortableLibraryID) -> MobileLibrarySnapshot {
        .init(
            schemaVersion: 1,
            libraryID: libraryID,
            snapshotID: UUID(),
            revision: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projects: [], nights: [], captures: [], briefings: [], notes: []
        )
    }
}
