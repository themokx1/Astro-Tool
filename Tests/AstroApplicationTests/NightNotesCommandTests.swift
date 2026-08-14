@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Fixture mirrors `CalibrationLinkCommandTests`' own shape: an isolated
/// temp library dir plus a temp-dir index DB, kept as a file-local copy per
/// this codebase's convention rather than a shared helper.
private struct NightNotesFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database

    static func make() throws -> NightNotesFixture {
        let libraryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-notes-tests-lib-\(UUID().uuidString)", isDirectory: true)
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-notes-tests-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        return NightNotesFixture(libraryDir: libraryDir, dbDir: dbDir, db: db)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }
}

@Suite("NightNotesCommand")
struct NightNotesCommandTests {
    @Test("Save in mutation-enabled mode writes via SessionNoteStore, and read-back matches")
    func saveThenLoadRoundTrips() throws {
        let fixture = try NightNotesFixture.make()
        defer { fixture.cleanup() }

        let command = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .mutationEnabled)
        #expect(command.storeNotes(target: "M31", date: "2026-01-10") == [:])

        try command.save(
            target: "M31", date: "2026-01-10",
            notes: [("Bortle", "5"), ("SQM", "20.8"), ("Notes", "kicsit párás")]
        )

        #expect(command.storeNotes(target: "M31", date: "2026-01-10") == [
            "Bortle": "5", "SQM": "20.8", "Notes": "kicsit párás",
        ])
    }

    @Test("Save produces the exact V1-compatible on-disk format SessionNoteStore itself writes")
    func saveMatchesCoreEngineOutputByteForByte() throws {
        let fixture = try NightNotesFixture.make()
        defer { fixture.cleanup() }

        let notes: [(String, String)] = [("Bortle", "5"), ("SQM", "20.8")]
        let command = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .mutationEnabled)
        try command.save(target: "M31", date: "2026-01-10", notes: notes)

        let noteURL = fixture.libraryDir.appendingPathComponent(".astro_tool/notes/M31-2026-01-10.txt")
        let writtenByCommand = try String(contentsOf: noteURL, encoding: .utf8)

        // Reference: exactly what the core engine (`SessionNoteStore`) itself
        // would produce for the same input, in a sibling location, using its
        // own `WriteGuard` -- the command must never re-derive this format.
        let referenceRoot = fixture.libraryDir.appendingPathComponent("reference-root")
        try FileManager.default.createDirectory(at: referenceRoot, withIntermediateDirectories: true)
        try SessionNoteStore.save(target: "M31", date: "2026-01-10", notes: notes, using: WriteGuard(root: referenceRoot))
        let referenceURL = referenceRoot.appendingPathComponent(".astro_tool/notes/M31-2026-01-10.txt")
        let writtenByEngine = try String(contentsOf: referenceURL, encoding: .utf8)

        #expect(writtenByCommand == writtenByEngine)
    }

    @Test("Save in read-only mode throws before touching the filesystem")
    func saveReadOnlyThrows() throws {
        let fixture = try NightNotesFixture.make()
        defer { fixture.cleanup() }

        let command = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .readOnly)

        #expect(throws: LibraryMutationError.readOnly) {
            try command.save(target: "M31", date: "2026-01-10", notes: [("Bortle", "5")])
        }
        let noteURL = fixture.libraryDir.appendingPathComponent(".astro_tool/notes/M31-2026-01-10.txt")
        #expect(!FileManager.default.fileExists(atPath: noteURL.path))
    }

    @Test("An invalid key is rejected with a typed error, and nothing is written")
    func saveRejectsInvalidKey() throws {
        let fixture = try NightNotesFixture.make()
        defer { fixture.cleanup() }

        let command = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .mutationEnabled)

        #expect(throws: NightNotesCommandError.invalidKey("Bad:Key")) {
            try command.save(target: "M31", date: "2026-01-10", notes: [("Bad:Key", "value")])
        }
        let noteURL = fixture.libraryDir.appendingPathComponent(".astro_tool/notes/M31-2026-01-10.txt")
        #expect(!FileManager.default.fileExists(atPath: noteURL.path))
    }

    @Test("A blank key alongside otherwise-valid rows is silently dropped, not rejected")
    func saveIgnoresBlankKeys() throws {
        let fixture = try NightNotesFixture.make()
        defer { fixture.cleanup() }

        let command = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .mutationEnabled)
        try command.save(target: "M31", date: "2026-01-10", notes: [("Bortle", "5"), ("   ", "orphan")])

        #expect(command.storeNotes(target: "M31", date: "2026-01-10") == ["Bortle": "5"])
    }

    @Test("readmeNotes reads the scanner's own README-sourced session_notes table, never the note-editor store")
    func readmeNotesReadsDatabaseOnly() throws {
        let fixture = try NightNotesFixture.make()
        defer { fixture.cleanup() }

        try fixture.db.upsertSessionNotes(target: "M31", date: "2026-01-10", notes: ["Camera": "ASI2600MM"])
        let command = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .mutationEnabled)

        #expect(try command.readmeNotes(target: "M31", date: "2026-01-10") == ["Camera": "ASI2600MM"])
        // The note-editor store stays untouched by a README-sourced row.
        #expect(command.storeNotes(target: "M31", date: "2026-01-10") == [:])
    }

    @Test("Saving a note never touches that session's own README.txt")
    func saveNeverTouchesReadme() throws {
        let fixture = try NightNotesFixture.make()
        defer { fixture.cleanup() }

        let readmeURL = fixture.libraryDir.appendingPathComponent("sessions/M31/2026-01-10/README.txt")
        try FileManager.default.createDirectory(at: readmeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalContent = "Target folder: M31\nDate: 2026-01-10\n"
        try originalContent.write(to: readmeURL, atomically: true, encoding: .utf8)

        let command = NightNotesCommand(db: fixture.db, root: fixture.libraryDir, accessMode: .mutationEnabled)
        try command.save(target: "M31", date: "2026-01-10", notes: [("Bortle", "5")])

        let contentAfter = try String(contentsOf: readmeURL, encoding: .utf8)
        #expect(contentAfter == originalContent)
    }
}
