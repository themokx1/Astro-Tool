import Foundation

/// R11-T13/F20: which `Kulcs: érték` pairs DISAGREE between the app's own
/// editable session-note store (`SessionNoteStore`, `.astro_tool/notes/`)
/// and the session's `README.txt` (`Database.sessionNotes`) -- the two
/// sources this whole note-merge design (see `SessionNoteStore`'s own doc
/// comment) already reads at query time. A key present in only ONE of the
/// two sources is never a conflict -- that's simply "not filled in over
/// there", exactly what the existing README-wins merge
/// (`SessionStatsQueries.computeSessionDetail`) already handles correctly.
/// A conflict only exists when BOTH sources have something to say about the
/// SAME (normalized) key, and they say something DIFFERENT -- the case the
/// merge silently hides today by always picking the README's value.
///
/// Deliberately its own tiny, pure, side-effect-free type (no `Database`/
/// filesystem access of its own) -- every call site already has both
/// dictionaries on hand (the app's `AppState.readmeNotes`/`storeNotes`, the
/// CLI's `db.sessionNotes`/`SessionNoteStore.load`, or the core's own
/// `computeSessionDetail`), so this only ever does the comparison.
public enum NoteConflicts {
    /// One conflicting key's two disagreeing values, both already trimmed
    /// of leading/trailing whitespace (`SessionNoteStore.save`/
    /// `ReadmeNotesParser.parse` both trim on their own write/read path, but
    /// a value read straight from a live, not-yet-saved UI field --
    /// `SessionNoteSheet`'s own `values` -- has not necessarily been).
    public struct Conflict: Equatable, Sendable {
        public let appValue: String
        public let readmeValue: String

        public init(appValue: String, readmeValue: String) {
            self.appValue = appValue
            self.readmeValue = readmeValue
        }
    }

    /// Detects conflicts keyed by the EXACT (not normalized) key text as it
    /// appears in `appNotes` -- callers iterate their own editable key list
    /// (e.g. `SessionNoteSheet.editableKeys`) and look up this dictionary by
    /// that same exact key, so normalizing away casing there would make the
    /// lookup useless. Two keys are considered "the same key" for conflict
    /// purposes when they match after trimming whitespace and
    /// lowercasing (case-insensitive) -- e.g. an app-store `"SQM"` and a
    /// README `"sqm"` line are the SAME key; an app-store `"Bortle"` and a
    /// README `"Location/Bortle"` line are NOT (different key text
    /// entirely, matching `NoteConflicts`'s "same normalized key" contract,
    /// not `AcquisitionExport`'s looser "key CONTAINS this substring"
    /// heuristic used for its own Bortle/SQM column extraction).
    ///
    /// A key missing from either side, or whose value is blank/whitespace-only
    /// on either side, never conflicts (an unfilled field isn't a
    /// disagreement) -- matching the "blank is not a fact worth indexing"
    /// convention `SessionNoteStore.save`/`ReadmeNotesParser.parse` already
    /// apply on the write/read side. Values that are equal once BOTH are
    /// trimmed are not a conflict either, even if their raw (untrimmed)
    /// text differs.
    public static func detect(
        appNotes: [String: String], readmeNotes: [String: String]
    ) -> [String: Conflict] {
        var readmeByNormalizedKey: [String: String] = [:]
        for (key, value) in readmeNotes {
            readmeByNormalizedKey[normalize(key)] = value
        }

        var result: [String: Conflict] = [:]
        for (appKey, appRawValue) in appNotes {
            guard let readmeRawValue = readmeByNormalizedKey[normalize(appKey)] else { continue }
            let appValue = appRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let readmeValue = readmeRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appValue.isEmpty, !readmeValue.isEmpty, appValue != readmeValue else { continue }
            result[appKey] = Conflict(appValue: appValue, readmeValue: readmeValue)
        }
        return result
    }

    private static func normalize(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
