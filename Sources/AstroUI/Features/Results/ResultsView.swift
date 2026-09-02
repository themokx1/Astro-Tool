import AstroApplication
import AstroCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row of the Results table: either a stack family's roll-up or one of
/// its variant files nested under it. Same `children`-keypath `Table` shape
/// V1's `StacksSegment` uses -- the reference implementation the owner
/// already knew, and the one this page was missing.
public struct StackResultRow: Identifiable, Equatable {
    public enum Kind: Equatable {
        case family(StackResultGroup)
        /// The variant file plus its family's `stem`, carried along so the
        /// name cell can highlight the part of the filename that makes THIS
        /// file different without re-deriving the stem (`StackDiscovery.stem`
        /// is internal to `AstroCore`).
        case variant(StackResultFile, stem: String)
    }

    public let id: String
    public let kind: Kind
    public var children: [StackResultRow]?

    /// The file this row stands for -- a family row stands for its base.
    public var file: StackResultFile {
        switch kind {
        case .family(let group): return group.base
        case .variant(let file, _): return file
        }
    }
}

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: this used to be a
/// `private final class` that resolved `ProjectsStore.productionMetadata`
/// directly inside `load`, so this whole screen had zero unit-test surface.
/// Follows `ProjectsStore`'s own `metadataFactory` injection pattern so
/// tests can supply a fixture-backed `MetadataStore` without touching the
/// filesystem-resolving production path.
///
/// Task 7 (2026-08-17 owner-feedback wave 3) -- "result oldalban nincs
/// semmi". It was structurally empty for everyone: it read
/// `metadata.results(projectID:)`, and nothing in the product has ever
/// written a row into that table. It now loads what the library actually
/// contains, through `StackDiscovery` -- 697 lines of working, tested
/// stack-discovery logic that V1 called from four places and V2 called from
/// none. The missing piece was the wiring, not the logic.
@MainActor
@Observable
public final class ResultsStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore
    /// Injected the same way, so a test can drive this store from an
    /// in-memory `Database` fixture. Production installs
    /// `ResultsQuery.production`, whose only job is to hand the V2 index to
    /// `StackDiscovery.groupedStacks`.
    public typealias ResultsQueryFactory = @Sendable (URL) throws -> ResultsQuery

    public private(set) var snapshot: StackResultsSnapshot?
    /// The table's rows, built once per load -- never re-derived from
    /// `body` or a computed getter (see `PlanningStore.filteredRecommendations`
    /// for the same fix applied first).
    public private(set) var rows: [StackResultRow] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    /// This project's own library/folder key and most recent night, loaded
    /// alongside `snapshot` -- everything the "Export Stack List" menu item
    /// needs to call `ExportService.stackList(target:date:)`, without the
    /// export menu having to know how to resolve either on its own. The
    /// folder key is set from `loaded.target` in `apply` below, NOT the
    /// project's raw `canonicalFolderName` -- one-letter-drift fix
    /// (2026-08-17): those two used to be assumed interchangeable here, but
    /// `stackResults(target:)` already resolves its `target` argument
    /// against the library's real folders (`ResultsQuery.libraryFolder`)
    /// before it ever reaches `StackDiscovery`, so an unresolved catalog
    /// name landing back in this property would have handed the export menu
    /// a folder the scanner never recorded (NGC 7000's own
    /// `..._North_America_Nebula` vs. the real `..._North_American_Nebula`).
    /// This IS now the exact `target` the discovery ran against.
    public private(set) var canonicalFolderName: String?
    public private(set) var latestNightDate: String?

    public var groupCount: Int { snapshot?.groups.count ?? 0 }
    public var fileCount: Int { snapshot?.fileCount ?? 0 }
    public var bestGroup: StackResultGroup? { snapshot?.bestGroup }

    private var filesByRowID: [String: StackResultFile] = [:]
    private var familyByRowID: [String: StackResultGroup] = [:]
    private let metadataFactory: MetadataFactory
    private let resultsQueryFactory: ResultsQueryFactory
    /// Bumped on every `load`; a load that is no longer the newest writes
    /// nothing, so a fast project switch can't have the slower scan land on
    /// top of the newer one.
    private var loadGeneration = 0

    public init(
        metadataFactory: @escaping MetadataFactory = ProjectsStore.productionMetadata,
        resultsQueryFactory: @escaping ResultsQueryFactory = { try ResultsQuery.production(rootURL: $0) }
    ) {
        self.metadataFactory = metadataFactory
        self.resultsQueryFactory = resultsQueryFactory
    }

    /// `sharedMetadata` is the window's ALREADY-OPEN `MetadataStore` for
    /// `rootURL`, when there is one -- v5 library-switch fixes (item 3,
    /// follow-up). This store used to open its OWN confined connection
    /// through `metadataFactory` on every load, competing with
    /// `ProjectsStore`'s already-open one for the same file. `metadataFactory`
    /// stays as the fallback for the paths that genuinely have no open store
    /// to reuse (and for tests injecting a fixture-backed one).
    public func load(rootURL: URL, projectID: UUID, sharedMetadata: MetadataStore?) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        do {
            let metadata = try sharedMetadata ?? metadataFactory(rootURL)
            let project = try await ProjectsQuery(metadata: metadata).project(id: projectID)
            guard generation == loadGeneration else { return }
            latestNightDate = project?.nights.first?.night.localDate

            guard let target = project?.canonicalFolderName else {
                apply(nil, generation: generation)
                return
            }
            // `stackResults` is a nonisolated `async` method, so the library
            // scan runs off the main thread even though this store is
            // `@MainActor`.
            let loaded = try await resultsQueryFactory(rootURL).stackResults(target: target)
            apply(loaded, generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    public func file(rowID: String) -> StackResultFile? { filesByRowID[rowID] }
    /// The family a row belongs to -- itself for a family row, its parent
    /// for a variant row.
    public func family(rowID: String) -> StackResultGroup? { familyByRowID[rowID] }

    private func apply(_ loaded: StackResultsSnapshot?, generation: Int) {
        guard generation == loadGeneration else { return }
        // The resolved folder `stackResults(target:)` actually discovered
        // against, not the caller's unresolved request -- see
        // `canonicalFolderName`'s own doc comment above.
        canonicalFolderName = loaded?.target
        snapshot = loaded
        var builtRows: [StackResultRow] = []
        var files: [String: StackResultFile] = [:]
        var families: [String: StackResultGroup] = [:]
        for group in loaded?.groups ?? [] {
            let children = group.variants.map { variant -> StackResultRow in
                let id = "v:\(variant.relativePath)"
                files[id] = variant
                families[id] = group
                return StackResultRow(id: id, kind: .variant(variant, stem: group.stem), children: nil)
            }
            let id = "g:\(group.stem)"
            files[id] = group.base
            families[id] = group
            builtRows.append(StackResultRow(
                id: id, kind: .family(group), children: children.isEmpty ? nil : children
            ))
        }
        rows = builtRows
        filesByRowID = files
        familyByRowID = families
        isLoading = false
    }
}

/// Wave 4 Task 3: `ProjectWorkspaceView`'s own Results tab hosts this exact
/// table/detail/QuickLook content, scoped to its project, instead of the
/// `ContentUnavailableView` placeholder that used to tell the reader to
/// press a separate "Results" button. Rather than duplicate `ResultsStore`
/// and every table/detail helper into a second type, `ResultsView` itself
/// grew a `showsHeader` switch: the full `.resultsWorkspace(projectID:)`
/// route shows its own title/icon/quick-actions header (`showsHeader:
/// true`, `ResultsView`'s own default), while `ProjectResultsPane` renders
/// the identical content with that header suppressed -- the tab's own
/// segmented picker is already the "what am I looking at" context, so a
/// second "Results" headline immediately under it would be redundant.
public struct ProjectResultsPane: View {
    let rootURL: URL
    let project: ProjectRecord
    /// Task 5 (2026-08-17 owner-feedback wave 3): forwarded straight into
    /// `ResultsView`'s own empty-state action -- see that type's own
    /// `review` doc comment for why it exists.
    let review: () -> Void
    /// v5 library-switch fixes (item 3, follow-up): forwarded straight into
    /// `ResultsView`'s own `sharedMetadataStore` -- see that type's own doc
    /// comment.
    let sharedMetadataStore: MetadataStore?

    public init(
        rootURL: URL, project: ProjectRecord, review: @escaping () -> Void = {},
        sharedMetadataStore: MetadataStore? = nil
    ) {
        self.rootURL = rootURL
        self.project = project
        self.review = review
        self.sharedMetadataStore = sharedMetadataStore
    }

    public var body: some View {
        ResultsView(
            rootURL: rootURL, project: project, showsHeader: false, review: review,
            sharedMetadataStore: sharedMetadataStore
        )
    }
}

public struct ResultsView: View {
    let rootURL: URL
    let project: ProjectRecord
    let showsHeader: Bool
    /// Task 5 (2026-08-17 owner-feedback wave 3): the owner's own words --
    /// "result oldalban nincs semmi" (there's nothing in the Results page).
    /// The empty state's text was already accurate, it just offered no way
    /// forward. `review` routes its action button at this project's frames,
    /// the step that comes before there is anything to stack at all, rather
    /// than leaving the reader at a dead end. Defaults to a no-op so
    /// existing previews/tests that never reach this branch don't need to
    /// supply one.
    let review: () -> Void
    /// v5 library-switch fixes (item 3, follow-up): the window's ALREADY-OPEN
    /// `MetadataStore` for `rootURL`, handed down by `DetailHost`/
    /// `ProjectWorkspaceView` so `store.load` reuses that one connection
    /// instead of opening a competing second one -- see `ResultsStore.load`'s
    /// own `sharedMetadata` doc comment. `nil` when nothing is open for this
    /// root (yet), which falls back to the store's own factory.
    let sharedMetadataStore: MetadataStore?
    @State private var store: ResultsStore
    @State private var selectedRowID: String?
    @Environment(WorkspaceActionCenter.self) private var workspaceActionCenter
    /// Wave 4 (post-20014) fix: see `ProjectWorkspaceView.actionOwner`'s own
    /// doc comment -- same reasoning here.
    @State private var actionOwner = UUID().uuidString

    public init(
        rootURL: URL, project: ProjectRecord, showsHeader: Bool = true,
        review: @escaping () -> Void = {}, store: ResultsStore = ResultsStore(),
        sharedMetadataStore: MetadataStore? = nil
    ) {
        self.rootURL = rootURL
        self.project = project
        self.showsHeader = showsHeader
        self.review = review
        self.sharedMetadataStore = sharedMetadataStore
        _store = State(initialValue: store)
    }

    // Wave 4 navigation-rework code-review fix: publishing workspace actions
    // used to be unconditional on the view below, so when this same content
    // is embedded (`showsHeader == false`, as `ProjectResultsPane` renders it
    // on the project workspace's own Results tab) it shadowed
    // `ProjectWorkspaceView`'s own published actions (Export/Review Frames/
    // Results) the moment that tab was showing -- the shell's toolbar
    // silently lost two of its three buttons. The fix branches at `body`'s
    // own top level: the publish hooks are only ever attached to the tree at
    // all on the STANDALONE route (`showsHeader == true`); the embedded
    // branch renders the identical `workspaceContent` with none of them
    // anywhere underneath it, so it never calls `workspaceActionCenter
    // .publish`/`.clear` at all -- it simply never becomes an owner.
    public var body: some View {
        if showsHeader {
            workspaceContent
                // Wave 4 Task 2: the Export Stack List menu used to be an
                // in-body button in this header -- it now renders in the
                // shell's own stable toolbar (see `WorkspaceActions`'s doc
                // comment).
                // Wave 4 (post-20014) fix: published from discrete
                // lifecycle/state-change events rather than from `body`
                // itself -- see `WorkspaceActionCenter`'s own doc comment.
                // `store.canonicalFolderName`/`store.latestNightDate` start
                // `nil` and are filled in asynchronously by `store.load`
                // (below), so both are watched explicitly rather than
                // relying on some unrelated re-render to catch them landing.
                .onAppear { publishWorkspaceActions() }
                .onChange(of: store.canonicalFolderName) { _, _ in publishWorkspaceActions() }
                .onChange(of: store.latestNightDate) { _, _ in publishWorkspaceActions() }
                .onDisappear { workspaceActionCenter.clear(owner: actionOwner) }
        } else {
            workspaceContent
        }
    }

    private func publishWorkspaceActions() {
        workspaceActionCenter.publish(owner: actionOwner, workspaceActions)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }
            if store.isLoading {
                ProgressView("Looking for finished stacks…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.errorMessage {
                ContentUnavailableView {
                    Label("Results unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    // Wave W6-A: see `RetryButton`'s own doc comment.
                    RetryButton(identifier: "v2.results.try-again") {
                        Task { await store.load(rootURL: rootURL, projectID: project.id, sharedMetadata: sharedMetadataStore) }
                    }
                }
            } else if !store.rows.isEmpty {
                // V2 UI/UX audit (2026-08-14) systemic pattern S10: this
                // split's own minimums (440 + 430 = 870) used to be an even
                // bigger floor than the outer view's old 780pt sheet-era one
                // (removed below) -- reduced so both panes still fit inside
                // the narrower detail column the shell's split view
                // actually gives this route.
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        summaryLine.padding(.horizontal, AstroTokens.Spacing.standard).padding(.top, AstroTokens.Spacing.compact)
                        resultTable
                    }
                    .frame(minWidth: 260, idealWidth: 440)
                    resultDetail.frame(minWidth: 220)
                }
            } else {
                emptyState
            }
        }
        // Task 7c (2026-08-17): this used to paint `.background(.background)`
        // -- the window background, i.e. essentially white in light
        // appearance -- edge to edge across the whole detail pane, which
        // covered the `ground` backdrop Task 7b had just restored and left
        // this route reading as one flat white rectangle with no layer
        // structure at all. It is a single self-contained panel (header,
        // divider, split content), so it becomes ONE raised surface on the
        // backdrop, `.flush` because its own header/divider chrome already
        // reaches its edges. The page gutter matches
        // `WorkspacePage`/`WorkspaceTablePage`'s own `spacious`, so this
        // route lines up with the eight table pages instead of being the
        // one screen with no margin.
        .astroRaisedSurface(.flush)
        .padding(AstroTokens.Spacing.spacious)
        .task(id: project.id) { await store.load(rootURL: rootURL, projectID: project.id, sharedMetadata: sharedMetadataStore) }
        // Wave 4 Task 3: a distinct identifier while embedded (no header) as
        // `ProjectWorkspaceView`'s Results tab, so UI automation can tell the
        // pushed `.resultsWorkspace(projectID:)` route apart from this same
        // content hosted inline in a project's own tab.
        .accessibilityIdentifier(showsHeader ? "v2.results.workspace" : "v2.project.results.pane")
    }

    /// Deliberately names the rule instead of a folder: `StackDiscovery`
    /// recognizes a finished stack from its own FILENAME, anywhere in the
    /// library -- so "nothing here" really does mean "no finished stack
    /// exists yet", not "you saved it in the wrong place".
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No finished stacks yet", systemImage: "square.stack.3d.up.slash")
        } description: {
            Text("Stack this project's frames with your own software and save the output anywhere in the library — under stacks, under processed, or straight into the session folder. Every variant of it shows up here, grouped with the stack it came from.")
        } actions: {
            Button("Review Frames", action: review)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(AstroTokens.Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Results").font(.title2.bold())
                Text("\(project.displayName) · finished stacks and their variants").foregroundStyle(.secondary)
            }
            Spacer()
            if let file = selectedFile {
                resultActions(file)
            }
        }.padding(20)
    }

    /// "8 stack families · 41 files · best: 145×120 s · 3:25 h" -- V1
    /// `StacksSegment`'s own summary line. "Best" is the first family
    /// because `StackDiscovery` sorts best-integration first.
    @ViewBuilder
    private var summaryLine: some View {
        HStack(spacing: 6) {
            Text("\(store.groupCount) stack families · \(store.fileCount) files")
            if let best = store.bestGroup, let exposure = exposureText(best) {
                Text("· best: \(exposure)")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("v2.results.summary")
    }

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions([
            .exportMenu(WorkspaceActionExportMenu(
                id: "v2.results.export", items: stackListExportItems, accessibilityID: "v2.results.export"
            )),
        ])
    }

    /// The project's latest-night stack list (`AppState.exportStackList`'s
    /// V2 equivalent) -- `[]` until `store.load` has resolved this project's
    /// own library/folder key and most recent night.
    private var stackListExportItems: [ExportMenuItem] {
        guard let target = store.canonicalFolderName, let date = store.latestNightDate else { return [] }
        return [
            .file(title: "Stack List…", systemImage: "square.stack.3d.up", contentType: .commaSeparatedText) {
                let export = try ExportService.production(rootURL: rootURL).stackList(target: target, date: date)
                return (export.content, export.suggestedFilename, [])
            },
        ]
    }

    // MARK: - Table

    private var resultTable: some View {
        Table(store.rows, children: \.children, selection: $selectedRowID) {
            TableColumn("Preview") { row in
                FrameThumbnailCell(rootURL: rootURL, relativePath: row.file.relativePath)
            }
            .width(min: 36, ideal: 36, max: 36)
            TableColumn("Name") { row in nameCell(row) }
                .width(min: 200, ideal: 320)
            // Task 5 (owner review wave 4-4): the "Eredeti"/"Original" badge
            // used to render for EVERY row, including every family (parent)
            // row -- whose own file is always the untouched original stack,
            // so the column's value there never varies. A column whose
            // value is constant is noise, not information; only a variant
            // (child) row's kind can actually differ from the family it
            // belongs to (starless/starmask/edited/export), so only variant
            // rows keep the badge.
            TableColumn("Kind") { row in
                if case .variant = row.kind {
                    variantBadge(row.file.variantKind)
                }
            }
            .width(min: 84, ideal: 100)
            TableColumn("Exposure") { row in exposureCell(row) }
                .width(min: 110, ideal: 160)
            TableColumn("Location") { row in locationLabel(row.file.location) }
                .width(min: 70, ideal: 84)
            // Task 5: Size/Night narrowed (the owner's own suggestion) --
            // "245.3 MB" and a "YYYY-MM-DD" session date both fit
            // comfortably in less room than before, and the table needed a
            // horizontal scrollbar at the default window width without this
            // (see this file's own `nameCell`/`Kind` fixes above for the
            // other two contributors to that same defect).
            TableColumn("Size") { row in Text(AstroFormat.bytes(row.file.sizeBytes)) }
                .width(min: 55, ideal: 65)
            TableColumn("Night") { row in Text(row.file.sessionDate ?? "—") }
                .width(min: 75, ideal: 85)
            // Task 5b's rule, applied here too: a row action must be legible
            // without hovering, and the right-click menu and the row menu
            // must be the SAME set -- one function, both call sites.
            TableColumn("") { row in
                Menu {
                    rowActionMenu(row.file)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Actions for this file")
            }
            .width(28)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // W3-9 (screenshot defects): was implicitly proposed the whole
        // `HSplitView` pane's height (no `.frame(maxHeight:)` of its own),
        // so a project with only a handful of stack families painted empty
        // alternating stripes below its last real row all the way to the
        // bottom of the pane -- see `tableMaxHeight`'s own doc comment
        // (`WorkspaceComponents.swift`) for the mechanism. This is a
        // hierarchical `Table(children:)`, so the true visible row count
        // (families plus whichever are expanded) changes with user
        // interaction; capping on `store.rows.count` alone (top-level
        // families, never the expanded children) is simpler and still
        // correct for this fix's own purpose -- it only needs to rule out
        // an unbounded proposal, not track the exact rendered row count,
        // and a family with expanded children pushes the intrinsic content
        // height past the cap anyway once there are enough rows to matter.
        .frame(maxWidth: .infinity, maxHeight: tableMaxHeight(rowCount: store.rows.count))
        .contextMenu(forSelectionType: String.self) { rowIDs in
            if let id = rowIDs.first, let file = store.file(rowID: id) {
                rowActionMenu(file)
            }
        } primaryAction: { rowIDs in
            if let id = rowIDs.first, let file = store.file(rowID: id) {
                openFile(file)
            }
        }
        .background(QuickLookSpacebarMonitor(
            isEnabled: { selectedRowID != nil },
            onSpace: {
                if let file = selectedFile { quickLook(file) }
            }
        ))
        .accessibilityIdentifier("v2.results.table")
        .onChange(of: store.rows) { _, newRows in
            // A row that no longer exists after a reload must not stay
            // selected -- and the first family (the best integration) is the
            // most useful default.
            if selectedRowID == nil || store.file(rowID: selectedRowID ?? "") == nil {
                selectedRowID = newRows.first?.id
            }
        }
        .onAppear { selectedRowID = selectedRowID ?? store.rows.first?.id }
    }

    /// Highlights the part of a variant's filename beyond the family's
    /// shared `stem` -- its own edit chain (`_work_graxpert_result_HOO`) or
    /// its `starless_`/`starmask_` prefix -- so the marker that makes THIS
    /// file different is visible at a glance instead of buried in a long
    /// flat filename. V1 `StacksSegment.markerHighlightedName`'s own logic.
    ///
    /// Task 5 (owner review wave 4-4): this cell used to truncate from the
    /// MIDDLE ("mu cephei 068x300sec 1...le-2-0x"), which can still swallow
    /// the exact drizzle/edit-chain/time fragment that makes a long variant
    /// name distinguishable from its siblings -- the full name already
    /// lives in the detail pane (`resultDetail` below), so this cell only
    /// needs to keep the part that differs at a glance.
    /// `.truncationMode(.head)` removes characters from the BEGINNING,
    /// keeping the END (the tail) visible -- the same direction this
    /// codebase already uses for exactly this reason on `ArchiveTaskCard`'s
    /// own evidence-path `Text`, which keeps a path's own distinguishing
    /// filename readable while its shared leading directory structure
    /// truncates away.
    @ViewBuilder
    private func nameCell(_ row: StackResultRow) -> some View {
        HStack(spacing: 5) {
            // `StackDiscovery` lists calibration masters among the stacks on
            // purpose, but flags them "so it isn't mistaken for a light
            // stack" -- its own words. Carrying that flag through is the
            // engine's intent, not a column of this page's invention: nine
            // of M42_Orion's forty discovered files are masters, and an
            // unflagged row would claim a master dark is a result.
            if row.file.category == .calibrationMasterCandidate {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(AstroTokens.Color.dataCalibration)
                    .help("Calibration master candidate")
                    .accessibilityLabel("Calibration master candidate")
            }
            switch row.kind {
            case .family(let group):
                Text(group.stem.replacingOccurrences(of: "_", with: " "))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(group.base.fileName)
            case .variant(let file, let stem):
                markerHighlightedName(for: file, stem: stem)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.relativePath)
            }
        }
    }

    private func markerHighlightedName(for file: StackResultFile, stem: String) -> Text {
        let full = file.fileName
        let ext = (full as NSString).pathExtension
        let nameNoExt = ext.isEmpty ? full : String(full.dropLast(ext.count + 1))

        var remaining = Substring(nameNoExt)
        var prefix = ""
        for marker in ["starless_", "starmask_"] where remaining.lowercased().hasPrefix(marker) {
            prefix = String(remaining.prefix(marker.count))
            remaining = remaining.dropFirst(marker.count)
            break
        }

        let coreLength = min(stem.count, remaining.count)
        let core = String(remaining.prefix(coreLength))
        let suffix = String(remaining.dropFirst(coreLength)) + (ext.isEmpty ? "" : ".\(ext)")

        var text = Text(prefix).foregroundColor(AstroTokens.Color.inkDim)
        text = text + Text(core)
        if !suffix.isEmpty { text = text + Text(suffix).foregroundColor(AstroTokens.Color.attention) }
        return text
    }

    /// `StackVariantKind`'s raw values are AstroCore's own Hungarian strings
    /// (`"eredeti"`, `"szerkesztett"`), so rendering `rawValue` would be
    /// untranslatable on an English interface AND unlocalizable on any
    /// other. The finite enum is switched here instead, exactly the way
    /// `ProjectNextActionKind` is.
    private func variantBadge(_ kind: StackVariantKind) -> some View {
        Text(variantTitle(kind))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(AstroTokens.Color.ink)
            .background(Capsule().fill(variantColor(kind).opacity(0.28)))
    }

    private func variantTitle(_ kind: StackVariantKind) -> LocalizedStringKey {
        switch kind {
        case .original: return "Original"
        case .edited: return "Edited"
        case .starless: return "Starless"
        case .starmask: return "Star mask"
        case .export_: return "Export"
        }
    }

    private func variantColor(_ kind: StackVariantKind) -> Color {
        switch kind {
        case .original: return AstroTokens.Color.dataStack
        case .edited: return AstroTokens.Color.dataProcessed
        case .starless, .starmask: return AstroTokens.Color.dataCalibration
        case .export_: return AstroTokens.Color.dataUnclassified
        }
    }

    private func locationLabel(_ location: StackResultLocation) -> some View {
        Text(locationTitle(location)).foregroundStyle(.secondary)
    }

    private func locationTitle(_ location: StackResultLocation) -> LocalizedStringKey {
        switch location {
        case .stacks: return "Stacks"
        case .processed: return "Processed"
        case .sessions: return "Session folder"
        case .libraryRoot: return "Library root"
        }
    }

    private func categoryTitle(_ category: StackResultCategory) -> LocalizedStringKey {
        switch category {
        case .stack: return "Stack"
        case .calibrationMasterCandidate: return "Calibration master candidate"
        case .processed: return "Processed output"
        }
    }

    @ViewBuilder
    private func exposureCell(_ row: StackResultRow) -> some View {
        switch row.kind {
        case .family(let group):
            VStack(alignment: .leading, spacing: 1) {
                if let exposure = exposureText(group) {
                    Text(exposure).bold()
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
                if group.exposureFromHeader {
                    Text("from FITS header").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .variant(let file, _):
            if let frames = file.framesFromName {
                Text("\(frames)×\(subExposure(file.subSecondsFromName)) s").foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    /// "145×120 s · 3:25 h" -- the family's best-known exposure, taken
    /// verbatim from the engine's own `framesBest`/`subSecondsBest`/
    /// `totalSecondsBest` (filename-parsed, FITS header as the stated
    /// fallback). `nil` only when neither source carried a frame count.
    private func exposureText(_ group: StackResultGroup) -> String? {
        guard let frames = group.framesBest else { return nil }
        var text = "\(frames)×\(subExposure(group.subSecondsBest)) s"
        if let total = group.totalSecondsBest { text += " · \(AstroFormat.duration(seconds: total))" }
        return text
    }

    private func subExposure(_ seconds: Double?) -> String {
        guard let seconds else { return "?" }
        return seconds.formatted(.number.precision(.fractionLength(0)))
    }

    // MARK: - Actions

    private var selectedFile: StackResultFile? {
        guard let selectedRowID else { return nil }
        return store.file(rowID: selectedRowID)
    }

    private func resultActions(_ file: StackResultFile) -> some View {
        HStack(spacing: 8) {
            Button("Open Result") { openFile(file) }
                .disabled(fileURL(for: file) == nil)
                .help("Open this file with its default application")
            Menu {
                rowActionMenu(file)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func rowActionMenu(_ file: StackResultFile) -> some View {
        Button("Open Result") { openFile(file) }
            .disabled(fileURL(for: file) == nil)
        Button("Show in Finder") { revealFile(file) }
            .disabled(fileURL(for: file) == nil)
        Button("Quick Look") { quickLook(file) }
            .disabled(fileURL(for: file) == nil)
        Divider()
        Button("Copy Path") { copyPath(file) }
    }

    private func fileURL(for file: StackResultFile) -> URL? {
        let canonicalRoot = rootURL.standardizedFileURL
        let candidate = canonicalRoot.appendingPathComponent(file.relativePath).standardizedFileURL
        let allowedPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(allowedPrefix),
              FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private func openFile(_ file: StackResultFile) {
        guard let url = fileURL(for: file) else { return }
        NSWorkspace.shared.open(url)
    }

    private func revealFile(_ file: StackResultFile) {
        guard let url = fileURL(for: file) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func quickLook(_ file: StackResultFile) {
        guard let url = fileURL(for: file) else { return }
        QuickLookPreviewController.shared.preview(url)
    }

    private func copyPath(_ file: StackResultFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.relativePath, forType: .string)
    }

    // MARK: - Detail
    //
    // There is deliberately no lineage section. Lineage would name the
    // frames that went into a stack, and stack discovery cannot know that --
    // it recognizes a finished output from its filename. The two lineage
    // tables that could once have carried it had no writer anywhere in the
    // product and were dropped from the schema (W4-6, owner decision; see
    // `MetadataSchema.versionEightSQL`'s own note), so a lineage panel here
    // would be a panel that can never fill. An empty section promising
    // provenance is worse than not promising it.

    @ViewBuilder
    private var resultDetail: some View {
        if let file = selectedFile {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // W6-E item 4: the detail pane used to be pure text --
                    // no image at all, even though the exact same
                    // FrameThumbnailCell/FITSImageRenderer pipeline the
                    // Preview column and the import wizard already use can
                    // render this same file. Reused verbatim, just bigger,
                    // rather than a second thumbnail implementation.
                    FrameThumbnailCell(rootURL: rootURL, relativePath: file.relativePath, size: 180)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("v2.results.detail.preview")
                    Text(file.fileName)
                        .font(.title3.bold())
                        .textSelection(.enabled)
                        .lineLimit(3)
                    HStack(spacing: 12) {
                        metric("Kind", variantTitle(file.variantKind))
                        metric("Classified as", categoryTitle(file.category))
                        metric("Location", locationTitle(file.location))
                    }
                    Form {
                        Section("File") {
                            LabeledContent("Size") { Text(AstroFormat.bytes(file.sizeBytes)) }
                            if let dimensions = file.dimensions {
                                LabeledContent("Dimensions") { Text(dimensions) }
                            }
                            if let night = file.sessionDate {
                                LabeledContent("Night") { Text(night) }
                            }
                            if let modified = file.modifiedAt {
                                LabeledContent("Modified") {
                                    Text(modified.formatted(date: .abbreviated, time: .shortened))
                                }
                            }
                            Text(file.relativePath)
                                .font(.callout.monospaced()).textSelection(.enabled)
                        }
                        if let family = selectedRowID.flatMap({ store.family(rowID: $0) }) {
                            Section("Stack family") {
                                LabeledContent("Files in this family") { Text("\(family.fileCount)") }
                                if let exposure = exposureText(family) {
                                    LabeledContent("Best exposure") { Text(exposure) }
                                }
                                if family.exposureFromHeader {
                                    Text("Frame count and integration come from the file's FITS header, not its name.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("v2.results.family")
                        }
                    }
                    .formStyle(.grouped)
                    .frame(maxWidth: .infinity)
                    Spacer()
                }.padding(AstroTokens.Spacing.section)
            }
        } else {
            ContentUnavailableView("Select a stack", systemImage: "square.stack.3d.up")
        }
    }

    private func metric(_ title: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRecessedSurface()
    }
}
