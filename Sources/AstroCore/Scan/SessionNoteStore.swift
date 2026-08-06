import Foundation

/// Where a session's user-entered "night notes" (Bortle, SQM, seeing,
/// transparency, wind, dew, free-form remarks) live on disk: plain
/// `Kulcs: érték` lines (the exact shape `ReadmeNotesParser` already reads)
/// under `.astro_tool/notes/<sanitized-target>-<date>.txt`, written via
/// `WriteGuard.writeToolFile` so this landing spot inherits that type's own
/// containment guarantees for free -- no `WriteGuard` change was needed,
/// `writeToolFile` already allows any relative path under `toolDir`.
///
/// This is the T6/B4 fix for the gap the R9 review called out: `session_notes`
/// (R6-4) only ever gets filled from a session's `README.txt`, and in the
/// real library that backed this review every one of its 119 rows was
/// `new-session` template boilerplate (`Target folder`, `Catalog prefix`,
/// `Created at`) -- there was no UI anywhere that actually asked the user
/// for an observing-conditions note. This store is that missing write path,
/// and it does so WITHOUT ever touching the session's own `README.txt`,
/// which the iron rule forbids this tool from writing to under any
/// circumstance.
///
/// `Database` has no knowledge of this store at all: its own
/// `session_notes` table (and `searchNotes`) stays exactly what the scanner
/// captured from `README.txt`, nothing more. The merge of the two sources
/// happens at QUERY time, not write time, in two places:
/// - `SessionStatsQueries.computeSessionDetail` builds `SessionDetail.notes`
///   as `SessionNoteStore.load(...)` (this store) merged with
///   `Database.sessionNotes(...)` (the README), with the README winning any
///   key collision -- so every existing reader of `SessionDetail.notes`
///   (the AstroBin export's `bortle`/`meanSqm` columns, the Jegyzetek
///   segment, `NightReport`/`TargetReport` HTML) picks up store-written
///   notes automatically, no changes needed on their end.
/// - A caller that wants a GLOBAL search across store-written notes too
///   (the CLI's `search` command, the app's `SearchResultsPage`) calls
///   `search` below itself, since only that caller has both the library
///   root AND the full list of `(target, date)` pairs to check.
///
/// Choosing to keep `Database` itself README-only (rather than also
/// upserting into `session_notes` on every `save`) is deliberate: the
/// scanner unconditionally REPLACES a session's `session_notes` rows from
/// its `README.txt` on every rescan (`LibraryScanner.captureReadmeNotes` ->
/// `Database.upsertSessionNotes`), so anything this store wrote into that
/// same table would be silently wiped out by the next scan. Merging at read
/// time instead means a rescan can never lose a note this store holds.
public enum SessionNoteStore {
    /// `.astro_tool/notes/<sanitized-target>-<date>.txt`, relative to
    /// `WriteGuard.toolDir` -- the one filename shape `save` and `load`
    /// agree on. `target` is run through `Sanitizer.sanitize` (the same
    /// folder-name convention `SessionCreator`'s own new-session tree
    /// uses); `date` is used as-is since every date-dir on record is
    /// already a plain filesystem-safe component.
    public static func relativePath(target: String, date: String) -> String {
        "notes/\(Sanitizer.sanitize(target))-\(date).txt"
    }

    /// Writes `notes` as `Kulcs: érték` lines, overwriting whatever this
    /// session's note file held before -- this is the tool's own state
    /// under `.astro_tool/`, always freely rewritable, same as every other
    /// `writeToolFile` caller (`AstroConfig.save`, `AcquisitionExport.write`,
    /// ...). A key or value that's blank (or whitespace-only) after
    /// trimming is dropped entirely, same "not a fact worth indexing"
    /// convention `ReadmeNotesParser.parse` already applies -- so clearing
    /// every field in the note editor and saving results in an empty (but
    /// present) file, not a stale leftover line. Never touches
    /// `README.txt` -- see this type's own doc comment.
    public static func save(
        target: String, date: String, notes: [(String, String)], using writeGuard: WriteGuard
    ) throws {
        let lines = notes
            .map { (
                $0.0.trimmingCharacters(in: .whitespacesAndNewlines),
                $0.1.trimmingCharacters(in: .whitespacesAndNewlines)
            ) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)" }
        let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try writeGuard.writeToolFile(
            relativePath: relativePath(target: target, date: date), data: Data(content.utf8)
        )
    }

    /// Every note this store holds for one session -- `[:]` when the file
    /// was never saved, or exists but can't be parsed, same "absent means
    /// empty, not an error" convention `Database.sessionNotes` follows for
    /// its own (README-sourced) table. Read-only, no side effects, safe to
    /// call speculatively for a session that has never been edited.
    public static func load(target: String, date: String, root: URL) -> [String: String] {
        let url = root
            .appendingPathComponent(".astro_tool", isDirectory: true)
            .appendingPathComponent(relativePath(target: target, date: date), isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return ReadmeNotesParser.parse(data: data) ?? [:]
    }

    /// The store-backed half of a "searchNotes union" (spec B3/B4): every
    /// note this store holds, across every `(target, date)` pair in
    /// `sessions`, whose key or value contains `query` (case-insensitive) --
    /// the counterpart to `Database.searchNotes`, which only ever sees
    /// README-sourced notes. This does no filesystem enumeration of its
    /// own -- it only ever probes a note file whose exact name it can
    /// already predict from a `(target, date)` pair the caller already has
    /// on hand (e.g. every session on record for the whole library). A
    /// blank `query` returns `[]`, matching `Database.searchAll`'s own
    /// "blank query, empty result" convention.
    public static func search(
        query: String, root: URL, sessions: [(target: String, date: String)]
    ) -> [(target: String, date: String, key: String, value: String)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [(target: String, date: String, key: String, value: String)] = []
        for (target, date) in sessions {
            let notes = load(target: target, date: date, root: root)
            for key in notes.keys.sorted() {
                guard let value = notes[key] else { continue }
                if key.range(of: trimmed, options: .caseInsensitive) != nil
                    || value.range(of: trimmed, options: .caseInsensitive) != nil
                {
                    result.append((target, date, key, value))
                }
            }
        }
        return result.sorted { ($0.target, $0.date, $0.key) < ($1.target, $1.date, $1.key) }
    }
}
