import AstroApplication
@testable import AstroUI
import Foundation
import Testing

@MainActor
@Suite("Night briefing editor store")
struct NightBriefingStoreTests {
    @Test("A new tonight briefing starts on basics without invented targets")
    func startsHonestly() {
        let store = NightBriefingStore(now: Date(timeIntervalSince1970: 1_700_000_000))

        store.startTonight()

        #expect(store.currentStep == .basics)
        #expect(store.draft.nightDate != nil)
        #expect(store.draft.targets.isEmpty)
    }

    @Test("Adding a target creates one editable primary block")
    func addsTarget() {
        let store = NightBriefingStore(now: Date(timeIntervalSince1970: 1_700_000_000))
        store.startTonight()

        store.addTarget()

        #expect(store.draft.targets.count == 1)
        #expect(store.draft.targets[0].role == .primary)
        #expect(store.draft.targets[0].name.isEmpty)
        #expect(store.draft.targets[0].end > store.draft.targets[0].start)
    }

    @Test("Saving appends revisions and exposes the newest copy")
    func savesImmutableRevisions() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let revisionStore = NightBriefingRevisionStore(directory: folder)
        let store = NightBriefingStore(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            revisionStore: revisionStore
        )
        store.startTonight()

        try await store.saveRevision()
        store.draft.notes = "Második változat"
        try await store.saveRevision()

        #expect(store.draft.revision == 2)
        #expect(store.recentDrafts.first?.revision == 2)
        #expect(store.recentDrafts.first?.notes == "Második változat")
    }
}
