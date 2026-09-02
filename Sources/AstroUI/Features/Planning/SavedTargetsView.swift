import AstroApplication
import AstroCore
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
    /// Resolves the library's own observing site -- same shape/contract
    /// `PlanningStore.SkyContextProvider` uses (`Planner.resolveSite` under
    /// the hood), injected for the same testability reason.
    public typealias SiteResolver = @Sendable (URL?) async throws -> PlanningSkyContext?
    /// The catalog to look a saved designation up in (built-in + whatever
    /// the extended-catalog cache holds) -- `@MainActor` because
    /// `PlanningStore.productionCatalog()` itself reads `UserDefaults`/the
    /// cache file synchronously and is only ever called from the main actor
    /// in `PlanningStore`'s own use; called once per `reload()` here, before
    /// the detached season sweep starts.
    public typealias TargetCatalogProvider = @MainActor () -> [CatalogTarget]

    public private(set) var savedTargets: [SavedTargetRecord] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var rootURL: URL?
    /// Season Window Finder (expert ideation reserve #1): each saved
    /// target's YEAR-shaped visibility at this library's resolved site,
    /// keyed by designation -- `SavedTargetsView`'s per-row compact caption.
    /// Computed off the main actor after every `reload()`, session-cached
    /// (never re-swept for a designation this store already evaluated
    /// against the CURRENT site), and deliberately never for more than the
    /// user's own bookmarked handful-to-dozens -- never the whole catalog.
    public private(set) var seasonWindows: [String: SeasonWindowResult] = [:]
    public private(set) var isLoadingSeasonWindows = false
    private var seasonWindowGeneration = 0
    /// Test-only handle to the in-flight season sweep, mirroring
    /// `PlanningStore.pendingSeasonWindowRefresh`'s own contract -- never
    /// read by production code.
    private(set) var pendingSeasonWindowsTask: Task<Void, Never>?
    private var seasonSite: SiteRule?

    private let metadataFactory: MetadataFactory
    private let siteResolver: SiteResolver
    private let targetCatalogProvider: TargetCatalogProvider
    private var metadata: MetadataStore?
    /// v5 library-switch fixes (item 3, follow-up): hands back the window's
    /// ALREADY-OPEN `MetadataStore` for the asked-for root, or `nil` when
    /// there is none for that library -- same contract as
    /// `LibraryHealthStore.sharedMetadataProvider`. `resolveMetadata` used
    /// to open its OWN confined connection through `metadataFactory` the
    /// first time any of save/note/remove/reload ran, one more SQLite
    /// connection competing with `ProjectsStore`'s over the same file.
    /// `metadataFactory` stays as the fallback (and is what tests inject).
    public var sharedMetadataProvider: (@MainActor (URL) -> MetadataStore?)?

    public init(
        metadataFactory: @escaping MetadataFactory = SavedTargetsStore.productionMetadata,
        /// Optional rather than an async default argument -- the exact
        /// Swift 6.3.3 async-default-arg linker bug `PlanningStore.init`'s
        /// own `skyContextProvider` doc explains (see
        /// `docs/swift-async-default-arg-bug/`); resolving inside the body
        /// keeps the record non-external.
        siteResolver: SiteResolver? = nil,
        targetCatalogProvider: TargetCatalogProvider? = nil
    ) {
        self.metadataFactory = metadataFactory
        self.siteResolver = siteResolver ?? PlanningStore.productionSkyContext
        self.targetCatalogProvider = targetCatalogProvider ?? { PlanningStore.productionCatalog() }
    }

    /// This designation's season summary, if it's already been computed --
    /// `nil` either because the sweep hasn't landed yet (see
    /// `isLoadingSeasonWindows`) or because no site resolves for the current
    /// library at all, in which case it never will.
    public func seasonWindow(for designation: String) -> SeasonWindowResult? {
        seasonWindows[designation]
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
            seasonWindows = [:]
            seasonSite = nil
            seasonWindowGeneration += 1
            isLoadingSeasonWindows = false
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
        // Fire-and-forget: the season sweep is a nice-to-have per-row
        // caption, not part of `reload()`'s own contract, so a slow sweep
        // must never hold up a save/note/remove round-trip that already
        // awaits this function.
        recomputeSeasonWindows()
    }

    /// Recomputes `seasonWindows` off the main actor for every currently
    /// saved designation not already cached against the CURRENT site,
    /// guarded against a stale (superseded) completion by
    /// `seasonWindowGeneration` -- the same discipline `PlanningStore
    /// .recomputeSeasonWindow()` uses one target at a time, here fanned out
    /// over the (bounded, user-curated) saved list instead of the whole
    /// catalog.
    @discardableResult
    private func recomputeSeasonWindows() -> Task<Void, Never> {
        seasonWindowGeneration += 1
        let generation = seasonWindowGeneration
        guard !savedTargets.isEmpty else {
            seasonWindows = [:]
            isLoadingSeasonWindows = false
            let task = Task {}
            pendingSeasonWindowsTask = task
            return task
        }
        let designations = savedTargets.map(\.designation)
        let rootURL = rootURL
        let resolveSite = siteResolver
        let catalog = targetCatalogProvider()
        isLoadingSeasonWindows = true
        let task = Task { [weak self] in
            let context = try? await resolveSite(rootURL)
            guard let self, generation == self.seasonWindowGeneration else { return }
            guard let resolvedSite = context?.site else {
                // No resolvable site -- same "nothing invented" honesty
                // `SeasonWindowQuery.evaluate` itself already has for this
                // case, one level up: no site means no per-row caption.
                self.seasonWindows = [:]
                self.seasonSite = nil
                self.isLoadingSeasonWindows = false
                return
            }
            // A site change invalidates every previously-cached
            // designation -- yesterday's season at the OLD site says
            // nothing about this one.
            var results = self.seasonSite == resolvedSite ? self.seasonWindows : [:]
            let missing = designations.filter { results[$0] == nil }
            if !missing.isEmpty {
                let targets = missing.compactMap { designation in catalog.first { $0.designation == designation } }
                let computed = await Task.detached(priority: .utility) {
                    targets.reduce(into: [String: SeasonWindowResult]()) { partial, target in
                        if let result = SeasonWindowQuery.evaluate(target: target, site: resolvedSite) {
                            partial[target.designation] = result
                        }
                    }
                }.value
                results.merge(computed) { _, new in new }
            }
            guard generation == self.seasonWindowGeneration else { return }
            self.seasonSite = resolvedSite
            self.seasonWindows = results
            self.isLoadingSeasonWindows = false
        }
        pendingSeasonWindowsTask = task
        return task
    }

    private func resolveMetadata() throws -> MetadataStore {
        if let metadata { return metadata }
        guard let rootURL else { throw SavedTargetsStoreError.libraryNotOpen }
        if let shared = sharedMetadataProvider?(rootURL) {
            metadata = shared
            return shared
        }
        let resolved = try metadataFactory(rootURL)
        metadata = resolved
        return resolved
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
    /// v5 library-switch fixes (item 3, follow-up): the window's ALREADY-OPEN
    /// `MetadataStore` for `rootURL`, handed down by `DetailHost` so this
    /// store reuses that one connection instead of opening a competing
    /// second one -- see `SavedTargetsStore.sharedMetadataProvider`'s own
    /// doc comment. `nil` when nothing is open for this root (yet), which
    /// falls back to the store's own factory.
    let sharedMetadataStore: MetadataStore?
    @State private var store: SavedTargetsStore
    @State private var pendingRemoval: SavedTargetRecord?
    @State private var editingTarget: SavedTargetRecord?

    public init(
        rootURL: URL?,
        store: SavedTargetsStore = SavedTargetsStore(),
        chooseLibrary: @escaping () -> Void,
        sharedMetadataStore: MetadataStore? = nil
    ) {
        self.rootURL = rootURL
        self.chooseLibrary = chooseLibrary
        self.sharedMetadataStore = sharedMetadataStore
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
        .task(id: rootURL) {
            store.sharedMetadataProvider = { _ in sharedMetadataStore }
            await store.setRootURL(rootURL)
        }
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
                        // Season Window Finder (expert ideation reserve #1):
                        // compact text only here (a chart per bookmarked row
                        // would be noise across a list that can hold dozens)
                        // -- `nil` while the background sweep hasn't reached
                        // this designation yet, or no site resolves for this
                        // library at all, in which case the row simply says
                        // nothing rather than showing a stale guess.
                        if let seasonWindow = store.seasonWindow(for: record.designation) {
                            SeasonWindowSummary.compactText(seasonWindow)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("v2.planning.saved-season")
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
                    // W6-D fix: an icon-only button with an
                    // `.accessibilityLabel` but no `.help` -- VoiceOver users
                    // could tell what this does, but a sighted mouse user
                    // hovering it got no tooltip at all.
                    .help("Remove \(record.designation)")
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
