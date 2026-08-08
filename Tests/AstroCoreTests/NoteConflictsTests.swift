import Foundation
import Testing
@testable import AstroCore

/// `NoteConflicts.detect` is a pure function over two plain dictionaries --
/// no `Database`/filesystem needed, unlike `SessionNoteStore`'s or
/// `SessionStatsQueries`'s own tests.

@Test func detectReturnsEmptyWhenNoKeyOverlapsAtAll() {
    let conflicts = NoteConflicts.detect(
        appNotes: ["Bortle": "5"],
        readmeNotes: ["Camera": "ASI2600MC"]
    )
    #expect(conflicts.isEmpty)
}

@Test func detectReturnsEmptyWhenOverlappingKeysAgree() {
    let conflicts = NoteConflicts.detect(
        appNotes: ["Bortle": "5", "SQM": "20.8"],
        readmeNotes: ["Bortle": "5"]
    )
    #expect(conflicts.isEmpty)
}

@Test func detectFlagsSameKeyWithDifferingTrimmedValues() throws {
    let conflicts = NoteConflicts.detect(
        appNotes: ["Bortle": "5"],
        readmeNotes: ["Bortle": "7"]
    )
    #expect(conflicts.count == 1)
    let conflict = try #require(conflicts["Bortle"])
    #expect(conflict.appValue == "5")
    #expect(conflict.readmeValue == "7")
}

/// Whitespace-only differences don't count -- both sides are trimmed before
/// comparison.
@Test func detectIgnoresPureWhitespaceDifferences() {
    let conflicts = NoteConflicts.detect(
        appNotes: ["Bortle": "  5  "],
        readmeNotes: ["Bortle": "5"]
    )
    #expect(conflicts.isEmpty)
}

/// Key matching is case-insensitive -- an app-store "SQM" and a README
/// "sqm" line are the SAME key for conflict purposes.
@Test func detectMatchesKeysCaseInsensitively() {
    let conflicts = NoteConflicts.detect(
        appNotes: ["sqm": "20.8"],
        readmeNotes: ["SQM": "21.2"]
    )
    #expect(conflicts.count == 1)
    // Keyed by the APP side's exact-case key -- callers look this up by
    // whatever key text they themselves are iterating (e.g.
    // `SessionNoteSheet.editableKeys`).
    #expect(conflicts["sqm"]?.appValue == "20.8")
    #expect(conflicts["sqm"]?.readmeValue == "21.2")
}

/// A key present on only one side (README-only, or app-store-only) is never
/// a conflict -- that's just "not filled in over there", exactly what the
/// existing README-wins merge already handles.
@Test func detectIgnoresKeysPresentOnOnlyOneSide() {
    let conflicts = NoteConflicts.detect(
        appNotes: ["Bortle": "5"],
        readmeNotes: ["Camera": "ASI2600MC", "SQM": "20.8"]
    )
    #expect(conflicts.isEmpty)
}

/// A blank (or whitespace-only) value on either side is never a conflict --
/// an unfilled field isn't a disagreement, same "not a fact worth indexing"
/// convention `SessionNoteStore.save`/`ReadmeNotesParser.parse` apply.
@Test func detectIgnoresBlankValuesOnEitherSide() {
    let appBlank = NoteConflicts.detect(appNotes: ["Bortle": "   "], readmeNotes: ["Bortle": "5"])
    #expect(appBlank.isEmpty)

    let readmeBlank = NoteConflicts.detect(appNotes: ["Bortle": "5"], readmeNotes: ["Bortle": ""])
    #expect(readmeBlank.isEmpty)
}

/// A key like the app's plain "Bortle" and the README template's
/// "Location/Bortle" are DIFFERENT key text entirely -- `NoteConflicts`
/// deliberately does exact (normalized) key matching, not the looser
/// substring heuristic `AcquisitionExport.bortleValue` uses for its own
/// column extraction.
@Test func detectDoesNotFuzzyMatchDifferentKeyText() {
    let conflicts = NoteConflicts.detect(
        appNotes: ["Bortle": "5"],
        readmeNotes: ["Location/Bortle": "7"]
    )
    #expect(conflicts.isEmpty)
}

@Test func detectHandlesMultipleConflictingKeysIndependently() {
    let conflicts = NoteConflicts.detect(
        appNotes: ["Bortle": "5", "SQM": "20.8", "Seeing": "3/5"],
        readmeNotes: ["Bortle": "7", "SQM": "20.8", "Szél": "10 km/h"]
    )
    #expect(conflicts.count == 1)
    #expect(conflicts["Bortle"] != nil)
    #expect(conflicts["SQM"] == nil, "SQM agrees on both sides -- not a conflict")
    #expect(conflicts["Seeing"] == nil, "Seeing is app-only -- not a conflict")
}
