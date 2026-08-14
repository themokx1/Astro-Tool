@testable import AstroApplication
@testable import AstroUI
import AstroCore
import Foundation
import Testing

/// A minimal on-disk library + index DB -- `NightNoteStore` only ever needs
/// `NightNotesCommand`'s own two dependencies (a `Database` and a library
/// root), so this fixture skips the FITS-header machinery
/// `CalibStoreFixture`/`CalibLinkFixture` need for their own scans.
@MainActor
private struct NightNoteStoreFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database

    static func make() throws -> NightNoteStoreFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-note-store-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-note-store-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        return NightNoteStoreFixture(libraryDir: libraryDir, dbDir: dbDir, db: db)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func makeStore() -> NightNoteStore {
        NightNoteStore(commandFactory: { _, accessMode in
            NightNotesCommand(db: db, root: libraryDir, accessMode: accessMode)
        })
    }
}

@MainActor
@Suite("V2 Night note store")
struct NightNoteStoreTests {
    @Test("Loading a never-edited session prefills every template key blank, and surfaces README notes separately")
    func loadingPrefillsTemplateBlank() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.db.upsertSessionNotes(target: "M31", date: "2026-01-10", notes: ["Camera": "ASI2600MM"])

        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .mutationEnabled)

        #expect(store.errorMessage == nil)
        #expect(NightNoteStore.templateKeys.allSatisfy { store.value(for: $0).isEmpty })
        #expect(store.customKeys.isEmpty)
        #expect(store.readmeNotes == ["Camera": "ASI2600MM"])
    }

    @Test("Loading a previously-saved session prefills template fields and recovers custom keys")
    func loadingRecoversPriorSaveAndCustomKeys() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        let seed = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .mutationEnabled)
        try seed.save(target: "M31", date: "2026-01-10", notes: [("Bortle", "5"), ("Rig", "Newton 200/800")])

        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .mutationEnabled)

        #expect(store.value(for: "Bortle") == "5")
        #expect(store.customKeys == ["Rig"])
        #expect(store.value(for: "Rig") == "Newton 200/800")
    }

    @Test("Editing a template field updates its value")
    func settingValueUpdatesField() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .mutationEnabled)

        store.setValue("5", for: "Bortle")

        #expect(store.value(for: "Bortle") == "5")
    }

    @Test("Adding a valid custom key succeeds and it becomes editable")
    func addingValidCustomKeySucceeds() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .mutationEnabled)

        let added = store.addCustomKey("Rig", value: "Newton 200/800")

        #expect(added)
        #expect(store.customKeys == ["Rig"])
        #expect(store.value(for: "Rig") == "Newton 200/800")
        #expect(store.customKeyErrorMessage == nil)
    }

    @Test("Adding a blank custom key is rejected without a fuss")
    func addingBlankCustomKeyFails() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .mutationEnabled)

        let added = store.addCustomKey("   ", value: "x")

        #expect(!added)
        #expect(store.customKeys.isEmpty)
    }

    @Test("Adding a key that duplicates an existing editable key is rejected")
    func addingDuplicateKeyFails() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .mutationEnabled)

        let added = store.addCustomKey("Bortle", value: "9")

        #expect(!added)
        #expect(store.customKeys.isEmpty)
    }

    @Test("Adding an invalid custom key is rejected up front with an explanatory message, matching the save-time rule")
    func addingInvalidCustomKeyFails() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .mutationEnabled)

        let added = store.addCustomKey("Bad:Key", value: "x")

        #expect(!added)
        #expect(store.customKeys.isEmpty)
        #expect(store.customKeyErrorMessage != nil)
    }

    @Test("Saving in mutation-enabled mode writes through the command and refreshes state")
    func savingWritesThroughCommand() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .mutationEnabled)
        store.setValue("5", for: "Bortle")

        let saved = await store.save()

        #expect(saved)
        #expect(store.errorMessage == nil)
        let readBack = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .readOnly)
            .storeNotes(target: "M31", date: "2026-01-10")
        #expect(readBack == ["Bortle": "5"])
    }

    @Test("Saving in read-only mode fails with an explanatory error and writes nothing")
    func savingReadOnlyFails() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .readOnly)
        store.setValue("5", for: "Bortle")

        let saved = await store.save()

        #expect(!saved)
        #expect(store.errorMessage != nil)
        let readBack = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .readOnly)
            .storeNotes(target: "M31", date: "2026-01-10")
        #expect(readBack.isEmpty)
    }

    @Test("A README value that conflicts with the app's own stored value for the same key is surfaced")
    func conflictsAreSurfaced() async throws {
        let fixture = try NightNoteStoreFixture.make()
        defer { fixture.cleanup() }
        try fixture.db.upsertSessionNotes(target: "M31", date: "2026-01-10", notes: ["Bortle": "3"])
        let store = fixture.makeStore()
        await store.load(rootURL: fixture.libraryDir, target: "M31", date: "2026-01-10", accessMode: .mutationEnabled)
        store.setValue("5", for: "Bortle")

        #expect(store.conflicts["Bortle"]?.readmeValue == "3")
        #expect(store.conflicts["Bortle"]?.appValue == "5")
    }
}
