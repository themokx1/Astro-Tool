import Foundation
import Testing
@testable import AstroToolMobile
@testable import AstroMobileDomain
@testable import AstroMobileTransport

@Test func failedImportKeepsPreviousSnapshot() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let store = fixture.store

    await #expect(throws: MobilePackageError.self) {
        try await store.importPackage(from: fixture.corruptPackageURL, keyPayload: "astrotool-mobile-key:v1:bad")
    }

    #expect(await store.activeSnapshot?.revision == 1)
    #expect(await store.queuedChanges.isEmpty)
}

@Test func malformedPackageWithCanonicalKeyReachesTransportAndPreservesState() async throws {
    let fixture = try MobileStoreFixture(snapshotRevision: 1)
    let key = OneTimePackageKey()

    await #expect(throws: MobilePackageError.self) {
        try await fixture.store.importPackage(from: fixture.corruptPackageURL, keyPayload: key.qrPayload)
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
    try await fixture.store.importPackage(from: staged, key: key, removeStagedSource: true)

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
        try await fixture.store.importPackage(from: staged, key: OneTimePackageKey(), removeStagedSource: true)
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
        try await fixture.store.importPackage(from: staged, key: key)
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
        try await store.importPackage(from: staged, key: key)
    }
    #expect(await store.activeSnapshot?.revision == 1)
    #expect(FileManager.default.fileExists(atPath: staged.path))

    try await store.importPackage(from: staged, key: key, removeStagedSource: true)
    #expect(await store.activeSnapshot?.revision == 2)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
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
    try await fixture.store.importPackage(from: staged, key: key, removeStagedSource: true)

    #expect(await fixture.store.activeSnapshot?.revision == 2)
    #expect(await fixture.store.queuedChanges == queueBefore)
}

@Test func persistedSnapshotRejectsDuplicateTargetsSectionsAndNestedExplosion() async throws {
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
