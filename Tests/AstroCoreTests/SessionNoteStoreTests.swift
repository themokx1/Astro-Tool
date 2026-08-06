import Foundation
import Testing
@testable import AstroCore

private func makeTempRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-session-note-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func saveThenLoadRoundTripsNotes() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writeGuard = WriteGuard(root: root)

    // Note: `ReadmeNotesParser`'s key pattern is ASCII-only (matches the
    // real template's own key shapes, e.g. "Location/Bortle") -- an
    // accented KEY like "Megjegyzés" wouldn't round-trip, so this test
    // (deliberately) keeps keys plain ASCII while letting VALUES carry
    // Hungarian text freely.
    try SessionNoteStore.save(
        target: "M31", date: "2026-01-01",
        notes: [("Bortle", "5"), ("SQM", "20.8"), ("Notes", "kicsit párás")],
        using: writeGuard
    )

    let loaded = SessionNoteStore.load(target: "M31", date: "2026-01-01", root: root)
    #expect(loaded == ["Bortle": "5", "SQM": "20.8", "Notes": "kicsit párás"])
}

@Test func loadReturnsEmptyDictionaryWhenNeverSaved() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(SessionNoteStore.load(target: "M31", date: "2026-01-01", root: root) == [:])
}

@Test func saveDropsBlankKeysAndValues() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writeGuard = WriteGuard(root: root)

    try SessionNoteStore.save(
        target: "M31", date: "2026-01-01",
        notes: [("Bortle", "5"), ("Szél", "   "), ("", "orphan value")],
        using: writeGuard
    )

    #expect(SessionNoteStore.load(target: "M31", date: "2026-01-01", root: root) == ["Bortle": "5"])
}

@Test func saveOverwritesPriorContentEntirely() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writeGuard = WriteGuard(root: root)

    try SessionNoteStore.save(target: "M31", date: "2026-01-01", notes: [("Bortle", "5"), ("SQM", "20.8")], using: writeGuard)
    try SessionNoteStore.save(target: "M31", date: "2026-01-01", notes: [("Bortle", "4")], using: writeGuard)

    #expect(SessionNoteStore.load(target: "M31", date: "2026-01-01", root: root) == ["Bortle": "4"])
}

/// The exact filename shape the spec requires:
/// `.astro_tool/notes/<sanitized-target>-<date>.txt`, with the target run
/// through the same `Sanitizer` every other on-disk-derived target name in
/// this tool uses.
@Test func relativePathSanitizesTargetAndKeepsDateVerbatim() {
    #expect(SessionNoteStore.relativePath(target: "NGC 7000", date: "2026-01-01") == "notes/NGC_7000-2026-01-01.txt")
}

/// The iron rule, directly asserted: saving a note must never create,
/// modify, or even touch a session's own `README.txt` -- it lands entirely
/// under `.astro_tool/notes/`, a completely different file.
@Test func saveNeverTouchesReadmeTxt() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let readmeURL = root.appendingPathComponent("sessions/M31/2026-01-01/README.txt")
    try FileManager.default.createDirectory(at: readmeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let originalContent = "Target folder: M31\nDate: 2026-01-01\n"
    try originalContent.write(to: readmeURL, atomically: true, encoding: .utf8)
    let originalAttributes = try FileManager.default.attributesOfItem(atPath: readmeURL.path)
    let originalModDate = originalAttributes[.modificationDate] as? Date

    try SessionNoteStore.save(target: "M31", date: "2026-01-01", notes: [("Bortle", "5")], using: WriteGuard(root: root))

    let contentAfter = try String(contentsOf: readmeURL, encoding: .utf8)
    #expect(contentAfter == originalContent, "README.txt must stay bit-identical after a note-editor save")
    let attributesAfter = try FileManager.default.attributesOfItem(atPath: readmeURL.path)
    #expect((attributesAfter[.modificationDate] as? Date) == originalModDate, "README.txt must not even be re-touched")

    // The note landed under .astro_tool/notes/, a sibling file entirely.
    let noteURL = root.appendingPathComponent(".astro_tool/notes/M31-2026-01-01.txt")
    #expect(FileManager.default.fileExists(atPath: noteURL.path))
}

@Test func searchFindsMatchingKeyOrValueAcrossMultipleSessions() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writeGuard = WriteGuard(root: root)

    try SessionNoteStore.save(target: "M31", date: "2026-01-01", notes: [("Bortle", "5")], using: writeGuard)
    try SessionNoteStore.save(target: "M42", date: "2026-02-02", notes: [("Notes", "kissé Bortle-szennyezett égbolt")], using: writeGuard)
    try SessionNoteStore.save(target: "M42", date: "2026-02-03", notes: [("SQM", "21.1")], using: writeGuard)

    let hits = SessionNoteStore.search(
        query: "bortle", root: root,
        sessions: [("M31", "2026-01-01"), ("M42", "2026-02-02"), ("M42", "2026-02-03")]
    )
    #expect(hits.count == 2)
    #expect(hits.map(\.target).sorted() == ["M31", "M42"])
}

@Test func searchReturnsEmptyForBlankQuery() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try SessionNoteStore.save(target: "M31", date: "2026-01-01", notes: [("Bortle", "5")], using: WriteGuard(root: root))

    #expect(SessionNoteStore.search(query: "  ", root: root, sessions: [("M31", "2026-01-01")]).isEmpty)
}
