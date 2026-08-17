import AstroApplication
import Observation
import SwiftUI

public enum SavedTargetsStoreError: LocalizedError, Equatable {
    case libraryNotOpen

    public var errorDescription: String? {
        "Open an image library before saving a target."
    }
}

/// Backs both `PlanningView`'s inline "Save target"/note actions and the
/// standalone `SavedTargetsView` list -- one small store, the same shape
/// `ProjectsStore` uses for its own confined `MetadataStore` connection
/// (`MetadataFactory` injected for tests, `productionMetadata` in
/// production), so a saved-targets bookmark and its note persist in the same
/// per-library metadata database everything else in V2 already uses
/// (schema v6, `planning_saved_targets`).
@MainActor
@Observable
public final class SavedTargetsStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore

    public private(set) var savedTargets: [SavedTargetRecord] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var rootURL: URL?

    private let metadataFactory: MetadataFactory
    private var metadata: MetadataStore?

    public init(metadataFactory: @escaping MetadataFactory = SavedTargetsStore.productionMetadata) {
        self.metadataFactory = metadataFactory
    }

    /// The saved designations, for `PlanningView`'s table to mark rows with --
    /// cheap to recompute from `savedTargets` on each read since the saved
    /// list is small (a handful to a few dozen bookmarks, not the 217-target
    /// catalog).
    public var savedDesignations: Set<String> { Set(savedTargets.map(\.designation)) }

    public func isSaved(_ designation: String) -> Bool {
        savedDesignations.contains(designation)
    }

    public func note(for designation: String) -> String? {
        savedTargets.first { $0.designation == designation }?.note
    }

    /// Points this store at a (possibly different) library -- same-value
    /// guarded like every other root-URL setter in V2 Planning
    /// (`PlanningStore.setRootURL`): a `nil` root clears the list rather than
    /// leaving a stale one from a previously-open library on screen.
    public func setRootURL(_ url: URL?) async {
        guard url != rootURL else { return }
        rootURL = url
        metadata = nil
        guard url != nil else {
            savedTargets = []
            errorMessage = nil
            return
        }
        await reload()
    }

    @discardableResult
    public func save(designation: String, note: String? = nil) async -> Bool {
        await perform { metadata in
            try await metadata.saveTarget(designation: designation, note: note)
        }
    }

    @discardableResult
    public func updateNote(designation: String, note: String?) async -> Bool {
        await perform { metadata in
            try await metadata.updateNote(designation: designation, note: note)
        }
    }

    @discardableResult
    public func remove(designation: String) async -> Bool {
        await perform { metadata in
            try await metadata.removeSavedTarget(designation: designation)
        }
    }

    private func perform(_ body: @escaping (MetadataStore) async throws -> Void) async -> Bool {
        do {
            let metadata = try resolveMetadata()
            try await body(metadata)
            await reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func reload() async {
        guard let metadata = try? resolveMetadata() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            savedTargets = try await metadata.savedTargets()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resolveMetadata() throws -> MetadataStore {
        if let metadata { return metadata }
        guard let rootURL else { throw SavedTargetsStoreError.libraryNotOpen }
        let metadata = try metadataFactory(rootURL)
        self.metadata = metadata
        return metadata
    }

    public static func productionMetadata(rootURL: URL) throws -> MetadataStore {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return try MetadataStore(storagePaths: storage)
    }
}

/// The saved-targets list, reachable from Planning -- shows every bookmarked
/// target with its note, editing behind the same note sheet
/// `PlanningView`'s inline action uses, removal behind a confirmation (every
/// other destructive path in V2 is confirmed).
public struct SavedTargetsView: View {
    let rootURL: URL?
    let chooseLibrary: () -> Void
    @State private var store: SavedTargetsStore
    @State private var pendingRemoval: SavedTargetRecord?
    @State private var editingTarget: SavedTargetRecord?

    public init(
        rootURL: URL?,
        store: SavedTargetsStore = SavedTargetsStore(),
        chooseLibrary: @escaping () -> Void
    ) {
        self.rootURL = rootURL
        self.chooseLibrary = chooseLibrary
        _store = State(initialValue: store)
    }

    public var body: some View {
        WorkspacePage(
            subtitle: "Targets you've bookmarked from Planning, with your own notes."
        ) {
            content
        }
        .navigationTitle("Saved Targets")
        .accessibilityLabel("Saved Targets")
        .accessibilityIdentifier("v2.planning.saved")
        .task(id: rootURL) { await store.setRootURL(rootURL) }
        .confirmationDialog(
            "Remove this saved target?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Remove", role: .destructive) {
                if let designation = pendingRemoval?.designation {
                    Task { await store.remove(designation: designation) }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval.map { "\($0.designation) will be removed from your saved list." } ?? "")
        }
        .sheet(item: $editingTarget) { record in
            SavedTargetNoteSheet(
                designation: record.designation,
                initialNote: record.note ?? "",
                save: { newNote in
                    Task {
                        await store.updateNote(designation: record.designation, note: newNote)
                        editingTarget = nil
                    }
                },
                cancel: { editingTarget = nil }
            )
        }
    }

    /// W3-12 finding 2: `SavedTargetsStore.perform(_:)` already set
    /// `errorMessage` on every failed save/note-update/remove, but no view
    /// ever read it back -- a failed remove or note edit left the row
    /// exactly as it was with no visible reason why. Rendered above whichever
    /// branch is showing, the same "loaded content plus an inline error line"
    /// shape `SensorProfilesView`/`FrameBlinkReview`/`NightNoteSheet` already
    /// use for their own store's `errorMessage`.
    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(AstroTokens.Color.critical)
                    .accessibilityIdentifier("v2.planning.saved-error")
            }
            mainContent
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if rootURL == nil {
            ContentUnavailableView {
                Label("Open a Library", systemImage: "bookmark")
            } description: {
                Text("Saved targets are stored per image library.")
            } actions: {
                Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent)
            }
        } else if store.savedTargets.isEmpty {
            ContentUnavailableView(
                "No Saved Targets Yet",
                systemImage: "bookmark",
                description: Text("Save a target from the Planning table to see it here.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            savedList
        }
    }

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(store.savedTargets) { record in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.designation).font(.headline)
                        if let note = record.note, !note.isEmpty {
                            Text(note).font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Saved \(record.savedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Note…") { editingTarget = record }
                        .accessibilityLabel("Edit note for \(record.designation)")
                    Button(role: .destructive) { pendingRemoval = record } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Remove \(record.designation)")
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
        // Task 7c: a divider-separated list of saved targets is content, not
        // page scaffolding, so it reads on the one raised layer.
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.planning.saved-list")
    }
}

/// A small note-editor sheet, shared by `SavedTargetsView`'s per-row "Note…"
/// action and `PlanningView`'s inline note action for the selected row.
struct SavedTargetNoteSheet: View {
    let designation: String
    let save: (String?) -> Void
    let cancel: () -> Void
    @State private var note: String

    init(designation: String, initialNote: String, save: @escaping (String?) -> Void, cancel: @escaping () -> Void) {
        self.designation = designation
        self.save = save
        self.cancel = cancel
        _note = State(initialValue: initialNote)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note for \(designation)").font(.headline)
            TextEditor(text: $note)
                .frame(minWidth: 360, minHeight: 160)
                // W2-10: was a bare `RoundedRectangle(cornerRadius: 6)` --
                // a radius derived from nothing, the exact "assorted small
                // radii" defect the owner's corners complaint named.
                // `ConcentricRectangle` (macOS 26) matches whatever corner
                // this sheet itself resolves to instead of guessing a
                // second number.
                .overlay(ConcentricRectangle().stroke(.separator))
                .accessibilityIdentifier("v2.planning.note")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(trimmed.isEmpty ? nil : trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
