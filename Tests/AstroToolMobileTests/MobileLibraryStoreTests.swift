import Foundation
import CryptoKit
import Testing
@testable import AstroToolMobile
@testable import AstroMobileDomain
@testable import AstroMobileTransport

@Test func securityScopeFalseStillAttemptsReadableIntakeWithoutStop() async throws {
    let calls = SecurityScopeCalls()
    let access = MobileSecurityScopedAccess(
        start: { _ in calls.starts += 1; return false },
        stop: { _ in calls.stops += 1 }
    )

    let result = try await access.perform(at: URL(fileURLWithPath: "/tmp/readable.astromobile")) { "copied" }

    #expect(result == "copied")
    #expect(calls.starts == 1)
    #expect(calls.stops == 0)
}

@Test func securityScopeTrueBalancesStopAfterReadableIntake() async throws {
    let calls = SecurityScopeCalls()
    let access = MobileSecurityScopedAccess(
        start: { _ in calls.starts += 1; return true },
        stop: { _ in calls.stops += 1 }
    )

    _ = try await access.perform(at: URL(fileURLWithPath: "/tmp/scoped.astromobile")) { "copied" }

    #expect(calls.starts == 1)
    #expect(calls.stops == 1)
}

@Test func intakeCopyFailureUsesVisibleLocalizedRecoveryKey() {
    #expect(MobileIntakeError.copyFailed.localizedKey == "AstroTool could not copy that mobile package safely. Send it from your Mac again and try once more.")
}

@Test func failedImportKeepsPreviousSnapshot() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let store = fixture.store

    await #expect(throws: MobilePackageError.self) {
        try await store.importCurrentStagedPackage(keyPayload: "astrotool-mobile-key:v1:bad")
    }

    #expect(await store.activeSnapshot?.revision == 1)
    #expect(await store.queuedChanges.isEmpty)
}

@Test func malformedPackageWithCanonicalKeyReachesTransportAndPreservesState() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let key = OneTimePackageKey()

    let payload = Data(repeating: 0, count: 28)
    let manifest = MobilePackageManifest(
        formatVersion: MobilePackageManifest.currentFormatVersion,
        packageID: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_700_000_100),
        encryptedByteCount: Int64(payload.count),
        ciphertextSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
        keyMode: .oneTimeQR,
        wrappedContentKeyBase64: Data(repeating: 0, count: 60).base64EncodedString()
    )
    try MobileJSON.encoder.encode(manifest).write(to: fixture.corruptPackageURL.appendingPathComponent("manifest.json"), options: .atomic)
    try payload.write(to: fixture.corruptPackageURL.appendingPathComponent(MobilePackageService.encryptedPayloadFileName), options: .atomic)
    _ = try await fixture.store.stagePackage(from: fixture.corruptPackageURL)

    await #expect(throws: MobilePackageError.authenticationFailed) {
        try await fixture.store.importCurrentStagedPackage(keyPayload: key.qrPayload)
    }

    #expect(await fixture.store.activeSnapshot?.revision == 1)
    #expect(await fixture.store.queuedChanges.isEmpty)
}

@Test func noteEditAppendsChangeWithoutMutatingSnapshot() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let store = fixture.store
    let before = await store.activeSnapshot

    try await store.editNote(id: "night-note", text: "Dew after midnight")

    #expect(await store.activeSnapshot == before)
    #expect(await store.activeSnapshot?.notes.first?.text != "Dew after midnight")
    #expect(await store.queuedChanges.count == 1)
    #expect(await store.deviceID != nil)
}

@Test func checklistToggleAppendsOnlyTypedChange() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let store = fixture.store

    try await store.toggleChecklistItem(briefingID: fixture.briefingID, itemID: "focus", isCompleted: true)

    let changes = await store.queuedChanges
    #expect(changes.count == 1)
    if case .checklistCompletion(let change) = changes[0] {
        #expect(change.itemID == "focus")
        #expect(change.isCompleted)
    } else {
        Issue.record("The queue accepted a change kind outside the checklist allowlist")
    }
}

@Test func relaunchRecoversSnapshotQueueAndDeviceID() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let first = fixture.store
    try await first.editNote(id: "night-note", text: "Field note")
    let deviceID = await first.deviceID

    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.activeSnapshot?.revision == 1)
    #expect(await relaunched.queuedChanges.count == 1)
    #expect(await relaunched.deviceID == deviceID)
}

@Test func corruptDeviceIdentityLocksWritesWithoutReplacingBytes() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let deviceURL = fixture.rootURL.appendingPathComponent("device-id")
    let corrupt = Data("not-a-device".utf8)
    try corrupt.write(to: deviceURL, options: .atomic)
    let store = MobileLibraryStore(applicationSupportURL: fixture.rootURL)

    #expect(await store.recoveryState == .invalidDeviceID)
    do {
        try await store.editNote(id: "night-note", text: "blocked")
        Issue.record("A corrupt device identity did not lock writes")
    } catch let error as MobileLibraryStoreError {
        #expect(error == .recoveryRequired)
    }
    #expect(try Data(contentsOf: deviceURL) == corrupt)
}

@Test func foreignDeviceQueueLocksRecoveryWithoutReplacingSnapshot() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try await fixture.store.editNote(id: "night-note", text: "well-formed queued edit")
    let stateURL = fixture.rootURL.appendingPathComponent("state.json")
    var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    // Keep the queued record intact but bind the authoritative state to a
    // different installation identity. Reload must reject the queue rather
    // than silently accepting edits from another phone.
    state["deviceID"] = UUID().uuidString
    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL, options: .atomic)

    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)

    #expect(await relaunched.recoveryState == .invalidQueue)
    #expect(await relaunched.activeSnapshot?.revision == 1)
    #expect(await relaunched.queuedChanges.isEmpty)
}

@Test func pendingDurabilityJournalSurvivesRelaunchAsVisibleWarning() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let journalURL = fixture.rootURL.appendingPathComponent(".state-durability")
    let stateData = try Data(contentsOf: fixture.rootURL.appendingPathComponent("state.json"))
    let record = MobileDurabilityJournalRecord(version: MobileDurabilityJournalRecord.currentVersion, phase: .pending, priorStateSHA256: journalHash(stateData), intendedStateSHA256: String(repeating: "a", count: 64), operationID: UUID())
    try MobileJSON.encoder.encode(record).write(to: journalURL, options: .atomic)

    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)

    #expect(await relaunched.durabilityAttemptWarning)
    #expect(!(await relaunched.durabilityWarning))
    #expect(!(await relaunched.durabilityAmbiguousWarning))
    #expect(await relaunched.activeSnapshot?.revision == 1)
}

@Test func validPendingJournalWithNeitherStateHashIsAmbiguousAndNotRetryable() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let stateData = try Data(contentsOf: fixture.rootURL.appendingPathComponent("state.json"))
    let record = MobileDurabilityJournalRecord(version: MobileDurabilityJournalRecord.currentVersion, phase: .pending, priorStateSHA256: String(repeating: "a", count: 64), intendedStateSHA256: String(repeating: "b", count: 64), operationID: UUID())
    try MobileJSON.encoder.encode(record).write(to: fixture.rootURL.appendingPathComponent(".state-durability"), options: .atomic)

    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)

    #expect(journalHash(stateData) != record.priorStateSHA256)
    #expect(journalHash(stateData) != record.intendedStateSHA256)
    #expect(await relaunched.durabilityAmbiguousWarning)
    #expect(!(await relaunched.durabilityAttemptWarning))
    #expect(!(await relaunched.durabilityWarning))
}

@Test func crashWindowJournalWithNewStateShowsSavedWarning() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let stateURL = fixture.rootURL.appendingPathComponent("state.json")
    let oldData = try Data(contentsOf: stateURL)
    var object = try JSONSerialization.jsonObject(with: oldData) as! [String: Any]
    object["durabilityWarning"] = false
    let newData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let record = MobileDurabilityJournalRecord(version: MobileDurabilityJournalRecord.currentVersion, phase: .pending, priorStateSHA256: journalHash(oldData), intendedStateSHA256: journalHash(newData), operationID: UUID())
    try newData.write(to: stateURL, options: .atomic)
    try MobileJSON.encoder.encode(record).write(to: fixture.rootURL.appendingPathComponent(".state-durability"), options: .atomic)

    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)

    #expect(await relaunched.durabilityWarning)
    #expect(!(await relaunched.durabilityAttemptWarning))
    #expect(!(await relaunched.durabilityAmbiguousWarning))
}

@Test func corruptJournalShowsAmbiguousRecoveryWarning() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try Data("not-json".utf8).write(to: fixture.rootURL.appendingPathComponent(".state-durability"), options: .atomic)

    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)

    #expect(!(await relaunched.durabilityWarning))
    #expect(!(await relaunched.durabilityAttemptWarning))
    #expect(await relaunched.durabilityAmbiguousWarning)
}

@Test func missingJournalShowsAmbiguousRecoveryWarning() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try FileManager.default.removeItem(at: fixture.rootURL.appendingPathComponent(".state-durability"))

    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)

    #expect(await relaunched.durabilityAmbiguousWarning)
}

@Test func migrationWritesInitialClearRecordBoundToState() throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let stateData = try Data(contentsOf: fixture.rootURL.appendingPathComponent("state.json"))
    let record = try readJournal(fixture)

    #expect(record.version == MobileDurabilityJournalRecord.currentVersion)
    #expect(record.phase == .clear)
    #expect(record.priorStateSHA256 == nil)
    #expect(record.intendedStateSHA256 == journalHash(stateData))
}

@Test func uncertainInitialMigrationPendingFollowedByClearDoesNotLeaveStaleWarning() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try FileManager.default.removeItem(at: fixture.rootURL.appendingPathComponent("state.json"))
    try FileManager.default.removeItem(at: fixture.rootURL.appendingPathComponent(".state-durability"))

    let store = MobileLibraryStore(
        applicationSupportURL: fixture.rootURL,
        packageService: MobilePackageService(),
        testingBeforeStateCommit: {},
        testingDurability: { phase in phase == .pending ? .uncertain : .proceed }
    )

    #expect(await store.activeSnapshot?.revision == 1)
    #expect(!(await store.durabilityWarning))
    #expect(!(await store.durabilityAttemptWarning))
    #expect(!(await store.durabilityAmbiguousWarning))
    #expect(try readJournal(fixture).phase == .clear)
}

@Test func reloadClearsStaleDurabilityFlagsAfterConfirmedClearRecord() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let stateData = try Data(contentsOf: fixture.rootURL.appendingPathComponent("state.json"))
    let pending = MobileDurabilityJournalRecord(version: MobileDurabilityJournalRecord.currentVersion, phase: .pending, priorStateSHA256: journalHash(stateData), intendedStateSHA256: String(repeating: "b", count: 64), operationID: UUID())
    let journalURL = fixture.rootURL.appendingPathComponent(".state-durability")
    try MobileJSON.encoder.encode(pending).write(to: journalURL, options: .atomic)
    await fixture.store.reload()
    #expect(await fixture.store.durabilityAttemptWarning)

    let clear = MobileDurabilityJournalRecord(version: MobileDurabilityJournalRecord.currentVersion, phase: .clear, priorStateSHA256: journalHash(stateData), intendedStateSHA256: journalHash(stateData), operationID: pending.operationID)
    try MobileJSON.encoder.encode(clear).write(to: journalURL, options: .atomic)
    await fixture.store.reload()

    #expect(!(await fixture.store.durabilityWarning))
    #expect(!(await fixture.store.durabilityAttemptWarning))
    #expect(!(await fixture.store.durabilityAmbiguousWarning))
}

@Test func pendingJournalSyncFailurePreventsStateReplacement() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let stateURL = fixture.rootURL.appendingPathComponent("state.json")
    let before = try Data(contentsOf: stateURL)
    let store = MobileLibraryStore(
        applicationSupportURL: fixture.rootURL,
        packageService: MobilePackageService(),
        testingBeforeStateCommit: {},
        testingDurability: { phase in phase == .pending ? .uncertain : .proceed }
    )

    await #expect(throws: MobileLibraryStoreError.persistenceFailed) {
        try await store.editNote(id: "night-note", text: "pending sync must block")
    }

    #expect(try Data(contentsOf: stateURL) == before)
    #expect(await store.activeSnapshot?.revision == 1)
    #expect(await store.queuedChanges.isEmpty)
    #expect(!(await store.durabilityWarning))
    #expect(await store.durabilityAttemptWarning)
    #expect(try readJournal(fixture).phase == .attempted)
}

@Test func preRenameStateWriteFailureClearsPendingWithoutSavedWarning() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let stateURL = fixture.rootURL.appendingPathComponent("state.json")
    let before = try Data(contentsOf: stateURL)
    let store = MobileLibraryStore(
        applicationSupportURL: fixture.rootURL,
        packageService: MobilePackageService(),
        testingBeforeStateCommit: {},
        testingDurability: { phase in phase == .state ? .fail : .proceed }
    )

    await #expect(throws: MobileLibraryStoreError.persistenceFailed) {
        try await store.editNote(id: "night-note", text: "state write must fail")
    }

    #expect(try Data(contentsOf: stateURL) == before)
    #expect(!(await store.durabilityWarning))
    #expect(!(await store.durabilityAttemptWarning))
    #expect(try readJournal(fixture).phase == .clear)
}

@Test func clearJournalSyncUncertaintyRemainsConservative() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let store = MobileLibraryStore(
        applicationSupportURL: fixture.rootURL,
        packageService: MobilePackageService(),
        testingBeforeStateCommit: {},
        testingDurability: { phase in phase == .clear ? .uncertain : .proceed }
    )

    try await store.editNote(id: "night-note", text: "clear uncertainty")

    #expect(await store.activeSnapshot?.revision == 1)
    #expect(await store.durabilityWarning)
    #expect(!(await store.durabilityAttemptWarning))
    #expect(try readJournal(fixture).phase == .uncertain)
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.durabilityWarning)
}

@Test func parentSyncUncertaintyLeavesUncertainJournalAndWarningAfterRelaunch() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let sync = ParentSyncFailure(failuresRemaining: 1)
    let store = MobileLibraryStore(
        applicationSupportURL: fixture.rootURL,
        packageService: MobilePackageService(),
        testingBeforeStateCommit: {},
        testingParentDirectorySync: { sync.check() }
    )

    try await store.editNote(id: "night-note", text: "Needs durable warning")

    #expect(await store.durabilityWarning)
    #expect(try readJournal(fixture).phase == .uncertain)
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.durabilityWarning)
    #expect(await relaunched.activeSnapshot?.revision == 1)
}

@Test func queuedChecklistValueIsEffectiveForLaterToggle() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let store = fixture.store
    try await store.toggleChecklistItem(briefingID: fixture.briefingID, itemID: "focus", isCompleted: true)
    try await store.toggleChecklistItem(briefingID: fixture.briefingID, itemID: "focus", isCompleted: false)

    #expect(await store.queuedChanges.count == 2)
    do {
        try await store.toggleChecklistItem(briefingID: fixture.briefingID, itemID: "focus", isCompleted: false)
        Issue.record("An effective queued checklist value was not treated as a no-op")
    } catch let error as MobileLibraryStoreError {
        #expect(error == .noOpChange)
    }
}

@Test func validImportCommitsSnapshotAndReceiptAcrossRelaunch() async throws {
    let libraryID = UUID()
    let fixture = try MobileStoreFixture(snapshotRevision: 1, libraryID: libraryID)
    let sourceFixture = try MobileStoreFixture(snapshotRevision: 2, libraryID: libraryID)
    let key = OneTimePackageKey()
    let packageURL = fixture.rootURL.appendingPathComponent("valid.astromobile", isDirectory: true)
    let envelope = MobilePackageEnvelope(snapshot: sourceFixture.snapshot, changes: [], acknowledgedChangeIDs: [])
    _ = try await MobilePackageService().export(envelope, to: packageURL, wrapping: key)

    let staged = try await fixture.store.stagePackage(from: packageURL)
    try await fixture.store.importCurrentStagedPackage(key: key)

    #expect(await fixture.store.activeSnapshot?.revision == 2)
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.activeSnapshot?.revision == 2)
    #expect(await relaunched.recoveryState == .ready)
}

@Test func validPackageWithWrongKeyDoesNotReachCommit() async throws {
    let libraryID = UUID()
    let fixture = try MobileStoreFixture(snapshotRevision: 1, libraryID: libraryID)
    let sourceFixture = try MobileStoreFixture(snapshotRevision: 2, libraryID: libraryID)
    let packageKey = OneTimePackageKey()
    let packageURL = fixture.rootURL.appendingPathComponent("wrong-key.astromobile", isDirectory: true)
    let envelope = MobilePackageEnvelope(snapshot: sourceFixture.snapshot, changes: [], acknowledgedChangeIDs: [])
    _ = try await MobilePackageService().export(envelope, to: packageURL, wrapping: packageKey)
    let staged = try await fixture.store.stagePackage(from: packageURL)

    await #expect(throws: MobilePackageError.authenticationFailed) {
        try await fixture.store.importCurrentStagedPackage(key: OneTimePackageKey())
    }
    #expect(await fixture.store.activeSnapshot?.revision == 1)
    #expect(await fixture.store.queuedChanges.isEmpty)
}

@Test func absurdRevisionIsRejectedWithoutOverflow() async throws {
    let libraryID = UUID()
    let fixture = try MobileStoreFixture(snapshotRevision: 1, libraryID: libraryID)
    let sourceFixture = try MobileStoreFixture(snapshotRevision: Int.max, libraryID: libraryID)
    let key = OneTimePackageKey()
    let packageURL = fixture.rootURL.appendingPathComponent("absurd-revision.astromobile", isDirectory: true)
    _ = try await MobilePackageService().export(
        MobilePackageEnvelope(snapshot: sourceFixture.snapshot, changes: [], acknowledgedChangeIDs: []),
        to: packageURL,
        wrapping: key
    )
    let staged = try await fixture.store.stagePackage(from: packageURL)

    await #expect(throws: MobileLibraryStoreError.revisionNotMonotonic) {
        try await fixture.store.importCurrentStagedPackage(key: key)
    }
    #expect(await fixture.store.activeSnapshot?.revision == 1)
}

@Test func stateWriteFailureLeavesAuthenticatedPreviewRetryable() async throws {
    let libraryID = UUID()
    let fixture = try MobileStoreFixture(snapshotRevision: 1, libraryID: libraryID)
    let sourceFixture = try MobileStoreFixture(snapshotRevision: 2, libraryID: libraryID)
    let key = OneTimePackageKey()
    let packageURL = fixture.rootURL.appendingPathComponent("retry.astromobile", isDirectory: true)
    _ = try await MobilePackageService().export(
        MobilePackageEnvelope(snapshot: sourceFixture.snapshot, changes: [], acknowledgedChangeIDs: []),
        to: packageURL,
        wrapping: key
    )
    let failure = StateCommitFailure(failuresRemaining: 1)
    let store = MobileLibraryStore(
        applicationSupportURL: fixture.rootURL,
        packageService: MobilePackageService(),
        testingBeforeStateCommit: { try failure.check() }
    )
    let staged = try await store.stagePackage(from: packageURL)

    await #expect(throws: MobileLibraryStoreError.persistenceFailed) {
        try await store.importCurrentStagedPackage(key: key)
    }
    #expect(await store.activeSnapshot?.revision == 1)
    #expect(FileManager.default.fileExists(atPath: staged.path))

    try await store.importCurrentStagedPackage(key: key)
    #expect(await store.activeSnapshot?.revision == 2)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
}

@Test func replacingStagedSourceDiscardsPendingAuthenticationAndUsesCurrentOwnedStage() async throws {
    let libraryID = UUID()
    let fixture = try MobileStoreFixture(snapshotRevision: 1, libraryID: libraryID)
    let keyA = OneTimePackageKey()
    let keyB = OneTimePackageKey()
    let sourceA = fixture.rootURL.appendingPathComponent("source-a.astromobile", isDirectory: true)
    let sourceB = fixture.rootURL.appendingPathComponent("source-b.astromobile", isDirectory: true)
    let incomingA = try MobileStoreFixture(snapshotRevision: 2, libraryID: libraryID)
    let incomingB = try MobileStoreFixture(snapshotRevision: 3, libraryID: libraryID)
    _ = try await MobilePackageService().export(MobilePackageEnvelope(snapshot: incomingA.snapshot, changes: [], acknowledgedChangeIDs: []), to: sourceA, wrapping: keyA)
    _ = try await MobilePackageService().export(MobilePackageEnvelope(snapshot: incomingB.snapshot, changes: [], acknowledgedChangeIDs: []), to: sourceB, wrapping: keyB)
    let failure = StateCommitFailure(failuresRemaining: 1)
    let store = MobileLibraryStore(applicationSupportURL: fixture.rootURL, packageService: MobilePackageService(), testingBeforeStateCommit: { try failure.check() })
    _ = try await store.stagePackage(from: sourceA)

    await #expect(throws: MobileLibraryStoreError.persistenceFailed) { try await store.importCurrentStagedPackage(key: keyA) }
    let stagedA = await store.stagedPackageURL
    #expect(stagedA != nil)
    _ = try await store.stagePackage(from: sourceB)
    #expect(await store.stagedPackageURL != stagedA)
    try await store.importCurrentStagedPackage(key: keyB)

    #expect(await store.activeSnapshot?.revision == 3)
    #expect(await store.stagedPackageURL == nil)
}

@Test func corruptFingerprintReceiptLocksImportsButPreservesSnapshot() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let stateURL = fixture.rootURL.appendingPathComponent("state.json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    object["keyFingerprints"] = ["orphan": UUID().uuidString]
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: stateURL, options: .atomic)

    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.recoveryState == .invalidReceipts)
    #expect(await relaunched.activeSnapshot?.revision == 1)
    do {
        try await relaunched.editNote(id: "night-note", text: "blocked")
        Issue.record("Corrupt fingerprint receipt did not lock mutations")
    } catch let error as MobileLibraryStoreError {
        #expect(error == .recoveryRequired)
    }
}

@Test func importingNewSnapshotPreservesQueuedChangesForRemovedRecords() async throws {
    let libraryID = UUID()
    let fixture = try MobileStoreFixture(snapshotRevision: 1, libraryID: libraryID)
    try await fixture.store.editNote(id: "night-note", text: "Keep this field note")
    try await fixture.store.toggleChecklistItem(briefingID: fixture.briefingID, itemID: "focus", isCompleted: true)
    let queueBefore = await fixture.store.queuedChanges

    // The Mac may legitimately replace briefing records while the phone is
    // offline. Those edits remain return-package conflict candidates, not
    // malformed local state.
    let incoming = try MobileStoreFixture(
        snapshotRevision: 2,
        libraryID: libraryID,
        noteID: "replacement-note",
        checklistItemID: "replacement-focus"
    )
    let key = OneTimePackageKey()
    let packageURL = fixture.rootURL.appendingPathComponent("replacement.astromobile", isDirectory: true)
    _ = try await MobilePackageService().export(
        MobilePackageEnvelope(snapshot: incoming.snapshot, changes: [], acknowledgedChangeIDs: []),
        to: packageURL,
        wrapping: key
    )

    let staged = try await fixture.store.stagePackage(from: packageURL)
    try await fixture.store.importCurrentStagedPackage(key: key)

    #expect(await fixture.store.activeSnapshot?.revision == 2)
    #expect(await fixture.store.queuedChanges == queueBefore)
}

@Test func persistedSnapshotRejectsDuplicateTargets() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let stateURL = fixture.rootURL.appendingPathComponent("state.json")
    var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    var snapshot = state["snapshot"] as! [String: Any]
    var briefings = snapshot["briefings"] as! [[String: Any]]
    var briefing = briefings[0]
    let targetID = UUID().uuidString
    briefing["targets"] = [
        ["id": targetID, "name": "M31", "role": "primary", "start": "2026-08-23T00:00:00.00000000000000000Z", "end": "2026-08-23T01:00:00.00000000000000000Z", "warnings": []],
        ["id": targetID, "name": "M42", "role": "secondary", "start": "2026-08-23T00:00:00.00000000000000000Z", "end": "2026-08-23T01:00:00.00000000000000000Z", "warnings": []]
    ]
    briefings[0] = briefing
    snapshot["briefings"] = briefings
    state["snapshot"] = snapshot
    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL, options: .atomic)

    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.recoveryState == .invalidSnapshot)
}

@Test func persistedSnapshotRejectsDuplicateSections() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try mutatePersistedSnapshot(fixture) { briefing in
        briefing["checklist"] = [sectionJSON(id: "same-section"), sectionJSON(id: "same-section")]
    }
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.recoveryState == .invalidSnapshot)
}

@Test func persistedSnapshotRejectsDuplicateItemsAcrossSections() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try mutatePersistedSnapshot(fixture) { briefing in
        briefing["checklist"] = [
            sectionJSON(id: "section-a", items: [itemJSON(id: "same-item")]),
            sectionJSON(id: "section-b", items: [itemJSON(id: "same-item")])
        ]
    }
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.recoveryState == .invalidSnapshot)
}

@Test func persistedSnapshotRejectsOversizedTargets() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try mutatePersistedSnapshot(fixture) { briefing in
        briefing["targets"] = (0...MobilePackageService.maximumCollectionCount).map { targetJSON(id: "target-\($0)") }
    }
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.recoveryState == .invalidSnapshot)
}

@Test func persistedSnapshotRejectsOversizedSections() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try mutatePersistedSnapshot(fixture) { briefing in
        briefing["checklist"] = (0...MobilePackageService.maximumCollectionCount).map { sectionJSON(id: "section-\($0)") }
    }
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.recoveryState == .invalidSnapshot)
}

@Test func persistedSnapshotRejectsOversizedItems() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try mutatePersistedSnapshot(fixture) { briefing in
        briefing["checklist"] = [sectionJSON(id: "section", items: (0...MobilePackageService.maximumCollectionCount).map { itemJSON(id: "item-\($0)") })]
    }
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.recoveryState == .invalidSnapshot)
}

@Test func persistedSnapshotRejectsOversizedWarnings() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try mutatePersistedSnapshot(fixture) { briefing in
        briefing["targets"] = [targetJSON(id: "target", warnings: (0...MobilePackageService.maximumCollectionCount).map { "warning-\($0)" })]
    }
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.recoveryState == .invalidSnapshot)
}

@Test func persistedSnapshotRejectsOversizedAggregate() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    try mutatePersistedSnapshotRoot(fixture) { snapshot in
        snapshot["projects"] = (0..<MobilePackageService.maximumCollectionCount).map { ["id": UUID().uuidString, "displayName": "M\($0)", "catalogID": "M\($0)", "phase": "ready", "integrationSeconds": 0, "goalHours": NSNull()] }
        snapshot["nights"] = (0..<MobilePackageService.maximumCollectionCount).map { ["id": UUID().uuidString, "localDate": "2026-08-23", "timeZoneID": "Europe/Budapest"] }
    }
    let relaunched = MobileLibraryStore(applicationSupportURL: fixture.rootURL)
    #expect(await relaunched.recoveryState == .invalidSnapshot)
}

private func mutatePersistedSnapshotRoot(_ fixture: MobileStoreFixture, _ mutate: (inout [String: Any]) -> Void) throws {
    let stateURL = fixture.rootURL.appendingPathComponent("state.json")
    var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    var snapshot = state["snapshot"] as! [String: Any]
    var briefings = snapshot["briefings"] as! [[String: Any]]
    mutate(&snapshot)
    var briefing = briefings[0]
    briefing["targets"] = (0..<MobilePackageService.maximumCollectionCount).map { targetJSON(id: "target-\($0)") }
    briefing["checklist"] = (0..<MobilePackageService.maximumCollectionCount).map { sectionJSON(id: "section-\($0)", items: [itemJSON(id: "item-\($0)")]) }
    briefings[0] = briefing
    snapshot["briefings"] = briefings
    state["snapshot"] = snapshot
    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL, options: .atomic)
}

private func mutatePersistedSnapshot(_ fixture: MobileStoreFixture, _ mutate: (inout [String: Any]) -> Void) throws {
    let stateURL = fixture.rootURL.appendingPathComponent("state.json")
    var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    var snapshot = state["snapshot"] as! [String: Any]
    var briefings = snapshot["briefings"] as! [[String: Any]]
    mutate(&briefings[0])
    snapshot["briefings"] = briefings
    state["snapshot"] = snapshot
    try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: stateURL, options: .atomic)
}

private func targetJSON(id: String, warnings: [String] = []) -> [String: Any] {
    ["id": id, "name": "M31", "role": "primary", "start": "2026-08-23T00:00:00.000Z", "end": "2026-08-23T01:00:00.000Z", "warnings": warnings]
}

private func sectionJSON(id: String, items: [[String: Any]] = []) -> [String: Any] {
    ["id": id, "title": "Basics", "items": items]
}

private func itemJSON(id: String) -> [String: Any] {
    ["id": id, "title": "Focus", "explanation": NSNull(), "isCompleted": false, "baseRevision": 0]
}

private func journalHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func readJournal(_ fixture: MobileStoreFixture) throws -> MobileDurabilityJournalRecord {
    try MobileJSON.decoder.decode(MobileDurabilityJournalRecord.self, from: Data(contentsOf: fixture.rootURL.appendingPathComponent(".state-durability")))
}

private final class MobileStoreFixture {
    let rootURL: URL
    let corruptPackageURL: URL
    let briefingID: UUID
    let snapshot: MobileLibrarySnapshot
    let store: MobileLibraryStore

    init(snapshotRevision: Int, libraryID: UUID? = nil, noteID: String = "night-note", checklistItemID: String = "focus") throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("AstroToolMobileStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let projectID = UUID()
        let nightID = UUID()
        briefingID = UUID()
        let snapshot = MobileLibrarySnapshot(
            schemaVersion: MobileLibrarySnapshot.currentSchemaVersion,
            libraryID: PortableLibraryID(rawValue: libraryID ?? UUID()),
            snapshotID: UUID(),
            revision: snapshotRevision,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projects: [MobileProject(id: projectID, displayName: "M31", catalogID: "M31", phase: "ready", integrationSeconds: 60, goalHours: nil)],
            nights: [MobileNight(id: nightID, localDate: "2026-08-23", timeZoneID: "Europe/Budapest")],
            captures: [],
            briefings: [MobileBriefing(
                id: briefingID,
                revision: 1,
                savedAt: Date(timeIntervalSince1970: 1_700_000_001),
                nightDate: nil,
                readiness: "ready",
                targets: [],
                checklist: [MobileChecklistSection(id: "basics", title: "Basics", items: [MobileChecklistItem(id: checklistItemID, title: "Focus", explanation: nil, isCompleted: false, baseRevision: 0)])],
                noteID: noteID
            )],
            notes: [MobileNote(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: "", baseRevision: 0, updatedAt: Date(timeIntervalSince1970: 1_700_000_002), isEditableOnPhone: true)]
        )
        self.snapshot = snapshot

        let activeDirectory = rootURL.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDirectory, withIntermediateDirectories: true)
        try MobileJSON.encoder.encode(snapshot).write(to: activeDirectory.appendingPathComponent("snapshot.json"), options: .atomic)
        corruptPackageURL = rootURL.appendingPathComponent("corrupt.astromobile", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptPackageURL, withIntermediateDirectories: true)
        try Data("truncated".utf8).write(to: corruptPackageURL.appendingPathComponent("manifest.json"))
        store = MobileLibraryStore(applicationSupportURL: rootURL)
    }

    deinit { try? FileManager.default.removeItem(at: rootURL) }
}

private final class StateCommitFailure: @unchecked Sendable {
    private var failuresRemaining: Int

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func check() throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw MobileLibraryStoreError.persistenceFailed
        }
    }
}

private final class SecurityScopeCalls: @unchecked Sendable {
    var starts = 0
    var stops = 0
}

private final class ParentSyncFailure: @unchecked Sendable {
    private var failuresRemaining: Int

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func check() -> Bool {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            return false
        }
        return true
    }
}
