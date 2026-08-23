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

    @Test("A planning seed preserves date, site, setup, and selected target")
    func startsFromPlanningContext() {
        let date = Date(timeIntervalSince1970: 1_786_738_400)
        let target = BriefingTargetBlock(
            name: "M 42",
            role: .primary,
            start: date.addingTimeInterval(3_600),
            end: date.addingTimeInterval(7_200),
            astronomicalStart: date,
            astronomicalEnd: date.addingTimeInterval(28_800)
        )
        let seed = NightBriefingSeed(
            date: date,
            site: .init(id: "47.5,19.0", name: "47.500°, 19.000°"),
            setup: .init(id: "rig", name: "RedCat 51"),
            target: target
        )

        let store = NightBriefingStore(
            now: date,
            seed: seed
        )

        #expect(store.hasStarted)
        #expect(store.draft.nightDate == date)
        #expect(store.draft.site == seed.site)
        #expect(store.draft.setup == seed.setup)
        #expect(store.draft.targets == [target])
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

    @Test("A beginner can add a personal checklist item")
    func addsCustomChecklistItem() {
        let store = NightBriefingStore(now: Date(timeIntervalSince1970: 1_700_000_000))
        store.startTonight()

        store.addCustomChecklistItem(title: "Piros fejlámpa")

        let custom = store.draft.checklist.flatMap(\.items).last
        #expect(custom?.title == "Piros fejlámpa")
        #expect(custom?.isBuiltIn == false)
        #expect(custom?.isVisible == true)
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

    @Test("Saving an unchanged draft does not create a duplicate revision")
    func unchangedSaveIsANoOp() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NightBriefingStore(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            revisionStore: NightBriefingRevisionStore(directory: folder)
        )
        store.startTonight()

        try await store.saveRevision()
        try await store.saveRevision()

        #expect(store.draft.revision == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }

    @Test("Edits autosave as a new immutable revision")
    func autosavesEdits() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NightBriefingStore(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            revisionStore: NightBriefingRevisionStore(directory: folder),
            autosaveDelay: .milliseconds(10)
        )
        store.startTonight()
        store.draft.notes = "Automatikusan megőrzendő"

        await store.flushAutosave()

        #expect(store.draft.revision == 1)
        #expect(store.recentDrafts.first?.notes == "Automatikusan megőrzendő")
    }

    @Test("Save and preview failures stay visible and preview can be retried")
    func surfacesFailuresAndRetriesPreview() async throws {
        let fileInsteadOfFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: fileInsteadOfFolder)
        defer { try? FileManager.default.removeItem(at: fileInsteadOfFolder) }
        let exporter = FlakyPDFExporter()
        let store = NightBriefingStore(
            now: Date(timeIntervalSince1970: 1_700_000_000),
            revisionStore: NightBriefingRevisionStore(directory: fileInsteadOfFolder),
            pdfExporter: exporter
        )
        store.startTonight()

        await store.saveRevisionShowingErrors()
        #expect(store.errorMessage != nil)

        await store.makePreview()
        #expect(store.previewError != nil)
        await store.makePreview()
        #expect(store.previewPDF == Data("pdf".utf8))
        #expect(store.previewError == nil)
    }
}

@MainActor
private final class FlakyPDFExporter: NightBriefingPDFExporting {
    private var calls = 0

    func pdfData(html: String) async throws -> Data {
        calls += 1
        if calls == 1 { throw CocoaError(.fileWriteUnknown) }
        return Data("pdf".utf8)
    }
}
