import AstroCore
import Foundation

/// A key that failed `NightNotesCommand.isValidKey` -- doesn't match the
/// SAME ASCII key shape `ReadmeNotesParser`'s own `linePattern` requires
/// (`^[A-Za-z][A-Za-z0-9 ()/_-]{0,40}$`). Saving it anyway would silently
/// corrupt the note file: the core engine's own `SessionNoteStore.save`
/// happily writes any string as a `Kulcs: érték` line, but `SessionNoteStore
/// .load`/`ReadmeNotesParser.parse` only ever reads a line back if its key
/// matches that exact pattern -- a key starting with a non-ASCII letter, or
/// containing a colon, would be written once and then silently vanish on
/// every subsequent read (`SessionNoteStoreTests.saveThenLoadRoundTripsNotes`
/// documents this exact gap for an accented key like "Megjegyzés"). This
/// command refuses that outcome up front with a typed error instead of
/// reproducing V1's silent data loss.
public enum NightNotesCommandError: Error, Equatable, Sendable, LocalizedError {
    case invalidKey(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidKey(key):
            return "\"\(key)\" isn't a valid note key. Use letters, numbers, spaces, and ()/_- only, starting with a letter, up to 41 characters."
        }
    }
}

/// V2's entry point for a session's structured "night notes" -- the same
/// `.astro_tool/notes/<target>-<date>.txt` key-value store V1's
/// `SessionNoteSheet`/`AppState.saveSessionNotes` writes through
/// `SessionNoteStore`, never that session's own `README.txt` (the iron
/// rule; `SessionNoteStore` itself guarantees this, see its own doc
/// comment).
///
/// `readmeNotes`/`storeNotes` are always available, even in `.readOnly`
/// mode -- reads never mutate anything. `save` is gated on `accessMode`,
/// throwing `LibraryMutationError.readOnly` before any filesystem access
/// when the library is open read-only -- the exact same shape
/// `CalibrationLinkCommand.apply` uses, because `SessionNoteStore.save`
/// writes a real file INSIDE the library root (under `.astro_tool/`), not
/// to this app's own external index database the way `SensorMeasurementCommand`
/// does (that command's own doc comment explains why IT skips this gate;
/// this command cannot, for the same reason `CalibrationLinkCommand` can't).
public struct NightNotesCommand: Sendable {
    private let db: Database
    private let root: URL
    private let accessMode: LibraryAccessMode

    /// The exact ASCII key shape `ReadmeNotesParser`'s own `linePattern`
    /// requires for its key group -- kept in lockstep with that private
    /// pattern (`Sources/AstroCore/Scan/ReadmeNotesParser.swift`) since a
    /// key this command accepts but that parser can't re-match would be the
    /// very data loss this whole validation step exists to prevent.
    private static let keyPattern = try! NSRegularExpression(
        pattern: "^[A-Za-z][A-Za-z0-9 ()/_-]{0,40}$"
    )

    public init(db: Database, root: URL, accessMode: LibraryAccessMode) {
        self.db = db
        self.root = root
        self.accessMode = accessMode
    }

    public static func production(rootURL: URL, accessMode: LibraryAccessMode) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        return Self(db: database, root: root, accessMode: accessMode)
    }

    /// One-letter-drift fix (2026-08-17): `target` arrives here as
    /// `NightNoteSheet`'s own `ProjectsQuery.canonicalFolderName(for:)`,
    /// which is not guaranteed to be the folder the scanner actually
    /// recorded (same defect `ExportService.resolvedTarget`'s own doc
    /// comment documents, with the NGC 7000 example). `readmeNotes` reads
    /// `db.sessionNotes` by exact string match, so a drifted `target` would
    /// silently hide a session's real README notes. Resolved once here
    /// through the identical `TargetCatalog.existingFolder(for:among:)`
    /// engine (via `ResultsQuery.libraryFolder`) so all three methods below
    /// agree on the same folder identity within one command -- `readmeNotes`
    /// resolving while `storeNotes`/`save` didn't would just trade one
    /// inconsistency for another.
    private func resolvedTarget(_ target: String) throws -> String {
        let knownFolders = Array(Set(try db.allFiles(includeMissing: false).compactMap(\.target)))
        return ResultsQuery.libraryFolder(matching: target, among: knownFolders) ?? target
    }

    /// This session's README-parsed notes -- the scanner's own read-only
    /// `session_notes` table (`Database.sessionNotes`), never the
    /// note-editor's own store. Available in any `accessMode`.
    public func readmeNotes(target: String, date: String) throws -> [String: String] {
        try db.sessionNotes(target: try resolvedTarget(target), date: date)
    }

    /// This session's note-editor-only notes (`SessionNoteStore`, under
    /// `.astro_tool/notes/`) -- `[:]` for a session that was never edited.
    /// Available in any `accessMode`.
    public func storeNotes(target: String, date: String) -> [String: String] {
        let target = (try? resolvedTarget(target)) ?? target
        return SessionNoteStore.load(target: target, date: date, root: root)
    }

    /// Validates every non-blank key in `notes`, then writes them all via
    /// `SessionNoteStore.save` -- exactly the core engine's own write path,
    /// re-deriving no format of its own. Throws `LibraryMutationError
    /// .readOnly` immediately when `accessMode != .mutationEnabled`, before
    /// validation or any filesystem access; throws
    /// `NightNotesCommandError.invalidKey` (also before any write) for the
    /// first key that fails `isValidKey` -- a blank key is silently
    /// dropped instead, matching `SessionNoteStore.save`'s own "not a fact
    /// worth indexing" stance for blank rows.
    @discardableResult
    public func save(
        target: String, date: String, notes: [(String, String)]
    ) throws -> [String: String] {
        guard accessMode == .mutationEnabled else { throw LibraryMutationError.readOnly }
        for (key, _) in notes {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }
            guard Self.isValidKey(trimmedKey) else {
                throw NightNotesCommandError.invalidKey(trimmedKey)
            }
        }
        let target = try resolvedTarget(target)
        let writeGuard = WriteGuard(root: root)
        try SessionNoteStore.save(target: target, date: date, notes: notes, using: writeGuard)
        return storeNotes(target: target, date: date)
    }

    /// Public so callers building the key field BEFORE ever calling `save`
    /// (`NightNoteStore.addCustomKey` in `AstroUI`) can reject an invalid
    /// custom key immediately, with the identical rule `save` itself
    /// enforces -- no separate copy of this pattern to drift out of sync.
    public static func isValidKey(_ key: String) -> Bool {
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        return Self.keyPattern.firstMatch(in: key, range: range) != nil
    }
}
