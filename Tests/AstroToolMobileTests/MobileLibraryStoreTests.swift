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

private final class MobileStoreFixture {
    let rootURL: URL
    let corruptPackageURL: URL
    let briefingID: UUID
    let store: MobileLibraryStore

    init(snapshotRevision: Int) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("AstroToolMobileStore-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let projectID = UUID()
        let nightID = UUID()
        briefingID = UUID()
        let noteID = "night-note"
        let snapshot = MobileLibrarySnapshot(
            schemaVersion: MobileLibrarySnapshot.currentSchemaVersion,
            libraryID: PortableLibraryID(rawValue: UUID()),
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
                checklist: [MobileChecklistSection(id: "basics", title: "Basics", items: [MobileChecklistItem(id: "focus", title: "Focus", explanation: nil, isCompleted: false, baseRevision: 0)])],
                noteID: noteID
            )],
            notes: [MobileNote(id: noteID, scope: .briefing, ownerID: briefingID.uuidString, text: "", baseRevision: 0, updatedAt: Date(timeIntervalSince1970: 1_700_000_002), isEditableOnPhone: true)]
        )

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
