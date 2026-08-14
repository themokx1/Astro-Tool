import AstroApplication
import AstroCore
import Foundation
import Observation

/// Backs `NightNoteSheet`: loads a session's README-sourced notes
/// (read-only) and its own note-editor store (`NightNotesCommand
/// .readmeNotes`/`.storeNotes`), tracks the editable template + custom
/// fields the user is currently typing, and drives `save` through the same
/// command -- exactly the functional shape V1's `SessionNoteSheet` owns
/// inline, extracted here so field editing/validation/save is testable
/// without hosting a SwiftUI view. Follows `CalibrationStore`'s
/// factory-injection pattern so tests supply a fixture-backed
/// `NightNotesCommand` without touching the filesystem-resolving
/// `production` constructor.
@MainActor
@Observable
public final class NightNoteStore {
    public typealias CommandFactory = @Sendable (URL, LibraryAccessMode) throws -> NightNotesCommand

    /// The fixed template rows every session gets -- V1's own Hungarian
    /// template (`SessionNoteSheet.templateKeys`: Bortle, SQM, Seeing,
    /// Átlátszóság, Szél, Páralecsapódás, Megjegyzés) translated into the
    /// ASCII key set `ReadmeNotesParser`'s own key pattern can actually
    /// round-trip -- see `NightNotesCommandError.invalidKey`'s own doc
    /// comment for why four of V1's seven literal keys never survive a
    /// reload today. Order matters: shown in this exact sequence.
    public static let templateKeys = ["Bortle", "SQM", "Seeing", "Transparency", "Wind", "Dew", "Notes"]

    public private(set) var readmeNotes: [String: String] = [:]
    public private(set) var customKeys: [String] = []
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?
    public private(set) var customKeyErrorMessage: String?
    public private(set) var accessMode: LibraryAccessMode = .readOnly

    private var values: [String: String] = [:]
    private let commandFactory: CommandFactory
    private var rootURL: URL?
    private var target: String?
    private var date: String?

    public var editableKeys: [String] { Self.templateKeys + customKeys }

    /// Every editable key whose current value disagrees with the README's
    /// own value for it (`NoteConflicts.detect`) -- recomputed on every
    /// access straight off the live `values` the user is editing, same
    /// "cheap derived read, no cache" stance `SessionNoteSheet.conflicts`
    /// already takes.
    public var conflicts: [String: NoteConflicts.Conflict] {
        NoteConflicts.detect(appNotes: values, readmeNotes: readmeNotes)
    }

    public init(
        commandFactory: @escaping CommandFactory = { rootURL, accessMode in
            try NightNotesCommand.production(rootURL: rootURL, accessMode: accessMode)
        }
    ) {
        self.commandFactory = commandFactory
    }

    public func value(for key: String) -> String { values[key] ?? "" }

    public func setValue(_ value: String, for key: String) {
        values[key] = value
    }

    /// Loads this session's README notes (read-only reference) and its
    /// note-editor store, pre-filling every template key (blank if never
    /// saved) and recovering any custom key a prior save added -- the exact
    /// same two-source load `SessionNoteSheet.load` performs.
    public func load(rootURL: URL, target: String, date: String, accessMode: LibraryAccessMode) async {
        let root = rootURL.standardizedFileURL
        self.rootURL = root
        self.target = target
        self.date = date
        self.accessMode = accessMode
        isLoading = true
        errorMessage = nil
        customKeyErrorMessage = nil
        defer { isLoading = false }
        do {
            let command = try commandFactory(root, accessMode)
            readmeNotes = (try? command.readmeNotes(target: target, date: date)) ?? [:]
            let stored = command.storeNotes(target: target, date: date)
            var newValues: [String: String] = [:]
            var newCustomKeys: [String] = []
            for key in Self.templateKeys { newValues[key] = stored[key] ?? "" }
            for (key, value) in stored where !Self.templateKeys.contains(key) {
                newCustomKeys.append(key)
                newValues[key] = value
            }
            values = newValues
            customKeys = newCustomKeys.sorted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Adds a custom key beyond the fixed template -- rejects a blank key,
    /// a key that duplicates an existing editable key (template or
    /// already-added custom), and a key that `NightNotesCommand.isValidKey`
    /// would reject at save time, surfacing that last case's explanation in
    /// `customKeyErrorMessage` immediately rather than only after a failed
    /// save. Returns whether the key was added.
    @discardableResult
    public func addCustomKey(_ key: String, value: String) -> Bool {
        customKeyErrorMessage = nil
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !editableKeys.contains(trimmed) else { return false }
        guard NightNotesCommand.isValidKey(trimmed) else {
            customKeyErrorMessage = NightNotesCommandError.invalidKey(trimmed).errorDescription
            return false
        }
        customKeys.append(trimmed)
        values[trimmed] = value
        return true
    }

    /// Saves every editable row through `NightNotesCommand.save`. On
    /// success, refreshes `values`/`customKeys` from what the command
    /// actually persisted (a row left entirely blank is dropped, matching
    /// the core engine's own "not a fact worth indexing" stance) and
    /// returns `true`. On failure (read-only mode, or an invalid key that
    /// slipped past `addCustomKey`'s own up-front check some other way),
    /// sets `errorMessage` and returns `false` -- the caller (`NightNoteSheet`)
    /// is expected to keep the sheet open in that case rather than dismiss.
    @discardableResult
    public func save() async -> Bool {
        guard let rootURL, let target, let date else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let command = try commandFactory(rootURL, accessMode)
            let notes = editableKeys.map { ($0, values[$0] ?? "") }
            let saved = try command.save(target: target, date: date, notes: notes)
            var newValues: [String: String] = [:]
            for key in Self.templateKeys { newValues[key] = saved[key] ?? "" }
            var newCustomKeys: [String] = []
            for (key, value) in saved where !Self.templateKeys.contains(key) {
                newCustomKeys.append(key)
                newValues[key] = value
            }
            values = newValues
            customKeys = newCustomKeys.sorted()
            return true
        } catch LibraryMutationError.readOnly {
            errorMessage = "Requires write access. Enable write operations in Settings to save night notes."
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
