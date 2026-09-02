import AppKit
import AstroApplication
import AstroCore
import SwiftUI
import UniformTypeIdentifiers

public struct NightWorkspaceView: View {
    private struct SeriesRow: Identifiable, Equatable {
        let series: SeriesRecord
        let projectName: String
        var id: UUID { series.id }
        /// `KeyPathComparator` needs a non-optional `Comparable` value --
        /// unfiltered series sort first (as the empty string).
        var filterSortKey: String { series.filterName ?? "" }
    }
    let row: NightRow
    let rootURL: URL?
    let accessMode: LibraryAccessMode
    let openProject: (ProjectRecord) -> Void
    let reviewProject: (ProjectRecord) -> Void
    let openCalibration: () -> Void
    let openInsights: (String?) -> Void
    /// v5 library-switch fixes (item 3, follow-up): the window's ALREADY-OPEN
    /// `MetadataStore` for `rootURL`, handed down by `DetailHost` so this
    /// page's own "Rate Frames" button reuses that one connection -- see
    /// `NightActionMenu.rateFrames`'s own `sharedMetadata` doc comment.
    /// `nil` when nothing is open for this root (yet), which falls back to
    /// `ProjectsStore.productionMetadata`.
    let sharedMetadataStore: MetadataStore?
    /// W6-E item 6 (live pixel review): backs the Quality section's
    /// exposure-advice "no sensor profile" reason -- see
    /// `exposureAdviceReasonText(_:)`'s own doc comment. `nil` (its
    /// default) degrades to plain text naming the CLI command, for any
    /// caller not yet updated to pass a real route -- never a button with
    /// nothing wired behind it.
    let openSensorProfiles: (() -> Void)?
    /// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): true when the
    /// currently-watched live session's own night matches `row.date` -- the
    /// spec's own "a `NightWorkspaceView` egy 'ÉLŐ' jelvényt kap, ha a
    /// megnyitott éjszaka éppen a figyelt session." `false` (the default)
    /// is zero behavior change for every night that isn't the one being
    /// actively watched right now; see `LiveNightWatcher`'s own doc comment
    /// for how the caller derives this.
    let isLiveSession: Bool
    /// Wave 4 Task 3: router-owned for the same reason as
    /// `ProjectWorkspaceView.router` -- see that view's own doc comment.
    @Bindable var router: AppRouter
    @State private var isEditingNotes = false
    @Environment(WorkspaceActionCenter.self) private var workspaceActionCenter
    /// Task 4 (2026-08-17 owner-feedback wave 3): backs the page-level
    /// "Rate Frames" action in `header` below -- see
    /// `ProjectWorkspaceView.operationHost`'s own doc comment for the same
    /// reasoning.
    @Environment(OperationHost.self) private var operationHost
    /// Wave 4 (post-20014) fix: see `ProjectWorkspaceView.actionOwner`'s own
    /// doc comment -- same reasoning here.
    @State private var actionOwner = UUID().uuidString
    /// V2 UI/UX audit (2026-08-14) systemic pattern S7: `row.snapshot.series`
    /// is a small, already-in-memory local array (one night's own series),
    /// so the sort is cached in local `@State` rather than a store (see
    /// `NightsStore.sortOrder`'s own doc comment for the convention this
    /// follows). Default is filter name ascending.
    @State private var sortOrder: [KeyPathComparator<SeriesRow>] = [
        KeyPathComparator(\SeriesRow.filterSortKey, order: .forward)
    ]
    @State private var sortedSeries: [SeriesRow] = []
    /// W5-1: the former "Éjszaka-riport" HTML export's data, now rendered
    /// natively in the Overview tab (`reportSections` below) instead of
    /// generated/saved as a file -- the owner's own words: "ne html
    /// oldalakat generáljunk és mentsünk".
    @State private var reportStore = NightReportStore()
    /// Ideation #6 ("Éjszaka idővonala"): the visual night ribbon --
    /// astronomical twilight/Moon-up/target-visible/capture/gap bands.
    /// Loaded AFTER `reportStore` (same `.task(id: row)` block below) since
    /// it consumes that load's own `SessionTimeline`, never re-querying
    /// per-frame `DATE-OBS` data itself -- see `NightRibbonQuery`'s own doc
    /// comment.
    @State private var ribbonStore = NightRibbonStore()

    public init(
        row: NightRow,
        rootURL: URL? = nil,
        accessMode: LibraryAccessMode = .readOnly,
        router: AppRouter,
        openProject: @escaping (ProjectRecord) -> Void,
        reviewProject: @escaping (ProjectRecord) -> Void,
        openCalibration: @escaping () -> Void = {},
        openInsights: @escaping (String?) -> Void = { _ in },
        openSensorProfiles: (() -> Void)? = nil,
        isLiveSession: Bool = false,
        sharedMetadataStore: MetadataStore? = nil
    ) {
        self.row = row
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.router = router
        self.openProject = openProject
        self.reviewProject = reviewProject
        self.openCalibration = openCalibration
        self.openInsights = openInsights
        self.openSensorProfiles = openSensorProfiles
        self.isLiveSession = isLiveSession
        self.sharedMetadataStore = sharedMetadataStore
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.projectSummary).font(.title2.weight(.semibold))
                        if isLiveSession {
                            liveBadge
                        }
                    }
                    Text("\(row.snapshot.usableFrames) usable · \(row.excludedFrames) excluded · \(row.integrationSummary)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                // Task 4 (2026-08-17 owner-feedback wave 3): the page's own
                // primary actions, above the content they act on -- the
                // toolbar keeps its own copy (`workspaceActions` below,
                // still useful once a night's own project/frame review is
                // pushed on top of this workspace).
                if let project = row.snapshot.projects.first {
                    HStack(spacing: 8) {
                        Button { reviewProject(project) } label: {
                            Label("Review Frames", systemImage: "checkmark.rectangle.stack")
                        }
                        .accessibilityIdentifier("v2.night.page.review")

                        Button { openProject(project) } label: {
                            Label("Open Project", systemImage: "folder")
                        }
                        .accessibilityIdentifier("v2.night.page.open-project")

                        Button {
                            NightActionMenu.rateFrames(
                                target: ProjectsQuery.canonicalFolderName(for: project),
                                date: row.date,
                                nightID: row.id,
                                rootURL: rootURL,
                                metadataFactory: ProjectsStore.productionMetadata,
                                sharedMetadata: sharedMetadataStore,
                                operationHost: operationHost
                            )
                        } label: {
                            Label("Rate Frames", systemImage: "star.leadinghalf.filled")
                        }
                        .help("Measure quality for every series captured this night")
                        .accessibilityIdentifier("v2.night.page.rate")

                        // Expert ideation spec #4 ("Session Summary Card --
                        // shareable PNG"): W5-1 removed this workspace's own
                        // file-export UI entirely (see `workspaceActions`'
                        // own doc comment) in favor of native on-page report
                        // sections, so there is no existing export/share
                        // menu to add a menu item to here -- a small
                        // secondary action next to Review/Open/Rate is the
                        // closest fit, matching this same header's own
                        // "primary actions, above the content they act on"
                        // convention.
                        Button {
                            Task { await exportSessionCard() }
                        } label: {
                            Label("Export Session Card…", systemImage: "photo.on.rectangle.angled")
                        }
                        .help(isSessionCardExportable
                            ? "Save a shareable PNG summary of this session"
                            : "Not yet rated — run scoring first")
                        .disabled(!isSessionCardExportable)
                        .accessibilityIdentifier("v2.night.page.export-session-card")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(AstroTokens.Spacing.spacious)
            Divider()
            Picker("Night section", selection: $router.nightTab) {
                ForEach(NightWorkspaceTab.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AstroTokens.Spacing.spacious)
            .padding(.vertical, AstroTokens.Spacing.standard)
            .accessibilityIdentifier("v2.night.workspace.tab")
            if router.nightTab == .series {
                // Deliberately NOT inside the `ScrollView` below: a `Table`
                // proposed an unbounded height (as it would be inside a
                // ScrollView) cannot virtualize its rows -- see
                // `WorkspaceTablePage`'s own doc comment for the same fix
                // applied to the main table-hosting workspaces.
                // Task 7c: same treatment the eight `WorkspaceTablePage`
                // routes get for their own tables -- `.flush`, so AppKit's
                // row insets and scroller reach the card's edge.
                seriesTable
                    .astroRaisedSurface(.flush)
                    .padding(AstroTokens.Spacing.spacious)
            } else {
                ScrollView {
                    content.padding(AstroTokens.Spacing.spacious)
                }
            }
        }
        // Owner review (2026-08-19): "ahogy váltok a tabok között, a tabsor
        // elugrál a tartalom függvényében" -- the IDENTICAL defect
        // `ProjectWorkspaceView` fixed in 4fc3993 ("stop the header floating
        // mid-page"). The Overview/Frames/Notes tabs wrap `content` in a
        // `ScrollView` above, which always claims its full proposed height
        // and top-aligns regardless of how little it contains -- but the
        // Series tab renders `seriesTable` directly (deliberately outside
        // that `ScrollView`, see its own doc comment) with a row-count-capped
        // height (`tableMaxHeight`), never the full pane. With no
        // `.frame(maxHeight:)` of its own, this top-level `VStack` was
        // proposed the whole pane's height by `DetailHost`'s
        // `NavigationStack` but only claimed as much as its shortest tab's
        // content needed, so it centered vertically in the leftover space --
        // moving the header + Divider + Picker up or down depending on
        // whether the current tab's content (a handful of series rows vs. a
        // scrolling report) filled the pane. `alignment: .top` makes every
        // tab claim the full height and pin the header at a constant
        // position, the same fix `ProjectWorkspaceView`'s own Sorozat tab
        // needed for the same reason.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Task 7b (2026-08-17): self-tint removed -- `V2RootView`'s detail
        // column owns the single opaque `ground` page backdrop now.
        .navigationTitle(row.date)
        .accessibilityIdentifier("v2.night.workspace")
        .sheet(isPresented: $isEditingNotes) {
            if let rootURL, let project = row.snapshot.projects.first {
                NightNoteSheet(
                    rootURL: rootURL, target: ProjectsQuery.canonicalFolderName(for: project), date: row.date,
                    accessMode: accessMode, dismiss: { isEditingNotes = false }
                )
            }
        }
        // Task 4 (2026-08-17 owner-feedback wave 3) reverses Wave 4 Task 2's
        // "Export/Night Actions/Review Frames/Open Project live only in the
        // shell's stable toolbar" decision -- Review Frames/Open Project/
        // Rate Frames are back in the header above, directly on the page;
        // the toolbar (`workspaceActions` below) keeps its own copy, plus
        // Export and the full Night Actions menu the header does not
        // duplicate (Wave 4 Task 3's removed "Night" eyebrow prefix stays
        // gone -- redundant with the global breadcrumb either way).
        // Wave 4 (post-20014) fix: published from discrete lifecycle/state-
        // change events rather than from `body` itself -- see
        // `WorkspaceActionCenter`'s own doc comment.
        .onAppear { publishWorkspaceActions() }
        .onChange(of: rootURL) { _, _ in publishWorkspaceActions() }
        .onChange(of: row) { _, _ in publishWorkspaceActions() }
        .onDisappear { workspaceActionCenter.clear(owner: actionOwner) }
        .task(id: row) {
            let target = row.snapshot.projects.first.map(ProjectsQuery.canonicalFolderName(for:))
            await reportStore.load(rootURL: rootURL, target: target, date: row.date)
            await ribbonStore.load(
                rootURL: rootURL, target: target, date: row.date,
                timeline: reportStore.result?.timeline
            )
        }
    }

    private func publishWorkspaceActions() {
        workspaceActionCenter.publish(owner: actionOwner, workspaceActions)
    }

    /// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): the "ÉLŐ"
    /// pill next to this night's own title, shown only while
    /// `isLiveSession` is true. `.capsule` rather than a
    /// `RoundedRectangle(cornerRadius:)` literal -- no numeric corner
    /// radius to drift from a token (`CornerRadiusLiteralGate`).
    /// `AstroTokens.Color.critical` reads as "attention, live right now",
    /// the same status-not-category color this app reserves for a
    /// genuinely live/urgent state, never a data category.
    private var liveBadge: some View {
        Text("LIVE")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(AstroTokens.Color.critical.opacity(0.15), in: .capsule)
            .foregroundStyle(AstroTokens.Color.critical)
            .accessibilityIdentifier("v2.night.live-badge")
    }

    /// Mirrors the exact "has at least one rated frame" predicate the
    /// Overview tab's own Quality section already gates on
    /// (`report.quality.map { $0.frameCount > 0 } ?? false`, `reportSections`
    /// below) -- see `SessionCardAssembler.isExportable`'s own doc comment.
    private var isSessionCardExportable: Bool {
        SessionCardAssembler.isExportable(quality: reportStore.result?.quality)
    }

    /// Renders `SessionCardView` off-screen via `ImageRenderer` and saves it
    /// as a PNG through an `NSSavePanel` -- same "panel only ever supplies
    /// `url`, this never invents a destination of its own" rule
    /// `ExportMenu.performFile` follows, just for binary PNG bytes instead
    /// of `ExportFileWriter`'s `String` content (see `SessionCardFileWriter`'s
    /// own doc comment for why this is a separate writer rather than a new
    /// `ExportMenuItem` case). `async` (called from the button as `Task {
    /// await exportSessionCard() }`) so it can resolve the representative
    /// frame and its thumbnail BEFORE `ImageRenderer` ever snapshots
    /// `SessionCardView` -- see `resolvedThumbnail`/`SessionCardThumbnailLoader`'s
    /// own doc comments for why that ordering, not `FrameThumbnailCell`'s
    /// own in-view async load, is what keeps the export from either hanging
    /// or baking a placeholder spinner into the PNG.
    private func exportSessionCard() async {
        guard let report = reportStore.result else { return }
        let thumbnailRelativePath = await representativeFramePath(target: report.target, date: row.date)
        let content = SessionCardAssembler.content(
            targetName: report.displayName,
            dateText: row.date,
            integrationText: row.integrationSummary,
            quality: report.quality,
            thumbnailRelativePath: thumbnailRelativePath
        )
        let preloadedThumbnail = await resolvedThumbnail(relativePath: content.thumbnailRelativePath)
        let renderer = ImageRenderer(content: SessionCardView(content: content, preloadedThumbnail: preloadedThumbnail))
        renderer.scale = 2
        guard let nsImage = renderer.nsImage, let pngData = SessionCardImageEncoder.pngData(from: nsImage) else {
            operationHost.notify(.failure, message: "\(OperationHost.localized("Export Session Card")) \(OperationHost.localized("failed:")) \(OperationHost.localized("could not render the card"))")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Session Card"
        panel.nameFieldStringValue = SessionCardAssembler.suggestedFilename(targetName: report.displayName, dateText: row.date)
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SessionCardFileWriter.write(pngData: pngData, to: url)
            operationHost.notify(.success, message: "\(OperationHost.localized("Exported")) \(url.lastPathComponent)")
        } catch {
            operationHost.notify(.failure, message: "Export Session Card \(OperationHost.localized("failed:")) \(error.localizedDescription)")
        }
    }

    /// Off-`MainActor` DB lookup for `SessionCardContent.thumbnailRelativePath`
    /// -- see `RepresentativeFrameQuery`'s own doc comment for the selection
    /// rule (highest-scored usable light, else the middle usable light by
    /// capture time, else none). `nil` on any failure (no library open,
    /// query error, no usable frame at all) -- the card simply renders
    /// without a thumbnail, same as before this frame-picking query existed.
    private func representativeFramePath(target: String, date: String) async -> String? {
        guard let rootURL else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do {
                let query = try RepresentativeFrameQuery.production(rootURL: rootURL)
                return try query.representativeFrame(target: target, date: date)
            } catch {
                return nil
            }
        }.value
    }

    /// Awaits (with a short timeout) the representative frame's thumbnail
    /// through `SessionCardThumbnailLoader` -- BEFORE `ImageRenderer` ever
    /// sees `SessionCardView`, not inside it (see that loader's own doc
    /// comment). `nil` when there is no path, no open library, the path
    /// doesn't resolve under the library root, or the load times out --
    /// `SessionCardView` treats all of those identically.
    private func resolvedThumbnail(relativePath: String?) async -> NSImage? {
        guard let rootURL, let relativePath,
              let url = FrameThumbnailCell.resolvedURL(rootURL: rootURL, relativePath: relativePath)
        else { return nil }
        return await SessionCardThumbnailLoader.load {
            await SessionCardThumbnailLoader.loadFrameImage(url: url)
        }
    }

    /// Wave 4 Task 3: the flat one-scroll layout is now four segmented
    /// tabs -- Overview keeps the metric-card summary, Series keeps the
    /// exact same series table the flat layout always showed, Frames is a
    /// per-project "Review Frames" entry point (frame review itself is
    /// project-scoped, not night-scoped -- see `ReviewWorkspace`'s own
    /// `projectID` parameter), and Notes surfaces the same
    /// `NightNoteSheet` this workspace already wired up, just with an
    /// explanatory summary card in front of the Edit button rather than
    /// requiring a toolbar hunt.
    @ViewBuilder private var content: some View {
        switch router.nightTab {
        case .overview:
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(title: "Integration", value: row.integrationSummary, detail: "Usable light frames", systemImage: "timer")
                    MetricCard(title: "Series", value: row.seriesCount.formatted(), detail: LocalizedStringKey(row.filterSummary), systemImage: "square.stack.3d.up")
                    TextMetricCard(title: "Triage", value: row.triageState.localizedText, detail: "\(row.excludedFrames) excluded", systemImage: "checklist")
                }
                // Task 7 (2026-08-17, GroupBox removal): `GroupBox`'s
                // opaque grey panel gone for good; Task 7c gives the block
                // back a presence through the one shared raised surface.
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                    Text("Projects captured this night").font(.headline)
                    ForEach(row.snapshot.projects, id: \.id) { project in
                        HStack {
                            Text(project.displayName)
                            Spacer()
                            Button("Open Project") { openProject(project) }
                                .buttonStyle(.link)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .astroRaisedSurface()
                reportSections
            }
        case .series:
            // `body` above renders `seriesTable` directly for this tab (a
            // `Table` must never sit inside this switch's own `ScrollView`),
            // so this branch is never actually reached -- kept only so the
            // switch stays exhaustive without a catch-all `default:`.
            EmptyView()
        case .frames:
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                Text("Frame review is per-project. Pick a project captured this night to review its frames.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(row.snapshot.projects, id: \.id) { project in
                    HStack {
                        Label(project.displayName, systemImage: "photo.stack")
                        Spacer()
                        Button("Review Frames") { reviewProject(project) }
                            .buttonStyle(.bordered)
                    }
                }
                if row.snapshot.projects.isEmpty {
                    ContentUnavailableView("No projects", systemImage: "photo.stack", description: Text("This night has no associated project to review frames for."))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .astroRaisedSurface()
        case .notes:
            // Task 7c: the explanation and its action are one block, so they
            // share one surface -- the inner `VStack` is a grouping WITHIN
            // the card (heading plus spacing), never a second card.
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                    Text("Session notes").font(.headline)
                    Text("Bortle, SQM, seeing, transparency, wind, dew, and freeform notes are stored with this session's own files.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Edit Notes") { isEditingNotes = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(rootURL == nil || row.snapshot.projects.first == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .astroRaisedSurface()
        }
    }

    private var seriesTable: some View {
        Table(sortedSeries, sortOrder: $sortOrder) {
            TableColumn("Project", value: \SeriesRow.projectName) { series in
                Text(series.projectName)
            }
            // `filterName` is arbitrary user/FITS data, so it can't become a
            // `LocalizedStringKey`-typed property outright -- wrapping the
            // `?? "Unfiltered"` fallback in `LocalizedStringKey(...)` at the
            // call site translates the fallback and leaves any real filter
            // name displaying as itself (an unmatched key just shows its own
            // text), same trick `NightsView`'s `darkHours`/`bestTargets`
            // columns use above.
            TableColumn("Filter", value: \SeriesRow.filterSortKey) { Text(LocalizedStringKey($0.series.filterName ?? "Unfiltered")) }
            TableColumn("Exposure", value: \SeriesRow.series.exposureSeconds) { Text(AstroFormat.exposureSeconds($0.series.exposureSeconds)).monospacedDigit() }
            TableColumn("Setup", value: \SeriesRow.series.setupDescriptor) { Text($0.series.setupDescriptor).lineLimit(1) }
            TableColumn("Mode", value: \SeriesRow.series.passband.rawValue) { Text($0.series.passband.displayLabel) }
        }
        // W3-9: was `.frame(maxWidth: .infinity, maxHeight: .infinity)` --
        // see `tableMaxHeight`'s own doc comment (`WorkspaceComponents.swift`)
        // for why an unbounded height painted empty alternating stripes
        // below this night's real series rows.
        .frame(maxWidth: .infinity, maxHeight: tableMaxHeight(rowCount: sortedSeries.count))
        .onChange(of: sortOrder) { _, _ in recomputeSortedSeries() }
        .task(id: row) { recomputeSortedSeries() }
    }

    private func recomputeSortedSeries() {
        var rows = row.snapshot.series.map { series in
            SeriesRow(
                series: series,
                projectName: row.snapshot.projects.first { $0.id == series.projectID }?.displayName ?? "Unknown"
            )
        }
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        sortedSeries = rows
    }

    /// W5-1: the night report's export menu is gone -- "tünjenek el az
    /// exportálás file-ba gombok" (the owner's own words). Its content lives
    /// natively in `reportSections` (Overview tab) instead of an
    /// `NSSavePanel`-written HTML file.
    private var workspaceActions: WorkspaceActions {
        var items: [WorkspaceActionItem] = []
        if let project = row.snapshot.projects.first {
            items.append(.nightActionsMenu(WorkspaceActionNightMenu(
                id: "v2.night.workspace.actions",
                target: ProjectsQuery.canonicalFolderName(for: project),
                date: row.date,
                setupDescriptor: row.snapshot.series.first?.setupDescriptor,
                nightID: row.id,
                rootURL: rootURL,
                editNotes: { isEditingNotes = true },
                openCalibration: openCalibration,
                openInsights: openInsights
            )))
            items.append(.button(WorkspaceAction(
                id: "v2.night.review",
                title: "Review Frames",
                systemImage: "checkmark.rectangle.stack",
                action: { reviewProject(project) }
            )))
            items.append(.button(WorkspaceAction(
                id: "v2.night.open-project",
                title: "Open Project",
                systemImage: "folder",
                action: { openProject(project) }
            )))
        }
        return WorkspaceActions(items)
    }

    // MARK: - Report sections (W5-1)
    //
    // The former "Éjszaka-riport" HTML export's own sections, now rendered
    // natively here instead of generated/saved as a file -- assembled by
    // `NightReportQuery` (`AstroApplication`), the exact same `AstroCore`
    // queries `NightReport.render`'s HTML path itself calls. Filters/Series
    // duplicate nothing the Series tab already shows (that table has no
    // quality/goal data); Notes below folds the report's own key/value
    // README notes into the Notes tab's existing "Session notes" card
    // rather than a second copy here.

    @ViewBuilder private var reportSections: some View {
        if reportStore.isLoading, reportStore.result == nil {
            ProgressView().frame(maxWidth: .infinity, alignment: .center)
        } else if let message = reportStore.errorMessage {
            ReportEmptyNote(text: LocalizedStringKey(message))
        } else if let report = reportStore.result {
            // W5-3 (owner pixel review, 2026-08-24 IC 4604 night): when this
            // night's captures span more than one session date-dir (see
            // `NightReportQuery.run`'s own doc comment for why -- a
            // mixed-exposure run split by `SessionConversionPlanner` into a
            // "-2"-suffixed sibling folder), `filterRows`/`captureGroups`
            // below already SUM every one of them (`NightReportQuery`
            // merges them in), so the numbers here now agree with the
            // header's own usable-frame count. This note is the only trace
            // of that merge left visible -- without it, two rows both named
            // e.g. "Untitled" in the Capture Groups table below would look
            // like an unexplained duplicate rather than two real sessions.
            if !report.mergedSessionDates.isEmpty {
                ReportEmptyNote(text: "Filters and Capture Groups below combine every session folder for this calendar night: \(([report.date] + report.mergedSessionDates).joined(separator: ", ")).")
            }
            ReportSection(title: "Night Ribbon") {
                if ribbonStore.isLoading, ribbonStore.result == nil {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                } else if let ribbon = ribbonStore.result {
                    NightRibbonView(model: ribbon)
                } else {
                    ReportEmptyNote(text: "No timestamped events for this night.")
                }
            }
            ReportSection(title: "Filters") {
                if report.filterRows.isEmpty {
                    ReportEmptyNote(text: "No filter data for this session.")
                } else {
                    ReportGrid(headers: ["Filter", "Frames", "Integration"]) {
                        ForEach(report.filterRows.sorted(by: { $0.filter.localizedCaseInsensitiveCompare($1.filter) == .orderedAscending }), id: \.filter) { row in
                            GridRow {
                                Text(LocalizedStringKey(row.filter))
                                Text(row.usableFrameCount.formatted()).monospacedDigit()
                                Text(AstroFormat.duration(seconds: row.integrationSeconds)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            ReportSection(title: "Capture Groups") {
                // Wave W6-A section D: mirrors the Filters section right
                // above -- an empty grid used to render as a bare header
                // with nothing underneath it, the same silent-looking blank
                // this codebase's own "every section explains why it has
                // nothing to show" rule (`ReportEmptyNote`'s own doc
                // comment) otherwise holds everywhere else on this tab.
                if report.captureGroups.isEmpty {
                    ReportEmptyNote(text: "No capture groups for this session.")
                } else {
                    ReportGrid(headers: ["Group", "Filters", "Frames", "Integration", "FWHM"]) {
                        ForEach(report.captureGroups) { row in
                            GridRow {
                                Text(row.group.displayName)
                                Text(row.group.filters.isEmpty ? "—" : row.group.filters.joined(separator: ", "))
                                Text(row.group.usableLightCount.formatted()).monospacedDigit()
                                Text(AstroFormat.duration(seconds: row.group.integrationSeconds)).monospacedDigit()
                                Text(fwhmText(row.quality))
                            }
                        }
                    }
                }
            }
            ReportSection(title: "Quality") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    if let quality = report.quality, quality.frameCount > 0 {
                        ReportStatGrid(items: qualityStatItems(quality))
                    } else {
                        ReportEmptyNote(text: "No rated frames for this session.")
                    }
                    if let reason = report.advice.notAvailableReason {
                        if exposureAdviceNeedsSensorProfile(reason) {
                            HStack(spacing: 6) {
                                Text("Exposure advice: n/a — \(exposureAdviceReasonText(reason))")
                                    .font(.callout).foregroundStyle(.secondary)
                                if let openSensorProfiles {
                                    Button("Sensor Profiles…", action: openSensorProfiles)
                                        .font(.callout)
                                        .accessibilityIdentifier("v2.night.page.open-sensor-profiles")
                                }
                            }
                        } else {
                            Text("Exposure advice: n/a — \(exposureAdviceReasonText(reason))").font(.callout).foregroundStyle(.secondary)
                        }
                    } else if !report.advice.advice.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Exposure Advice").font(.subheadline.weight(.medium))
                            ForEach(report.advice.advice, id: \.self) { line in
                                Text("• \(line)").font(.callout)
                            }
                        }
                    }
                }
            }
            ReportSection(title: "Altitude & Moon") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    if report.altitude == nil, report.moon == nil {
                        ReportEmptyNote(text: "No coordinate or site data for the altitude calculation.")
                    } else {
                        ReportStatGrid(items: altitudeMoonStatItems(report))
                    }
                }
            }
            ReportSection(title: "Hardware & Calibration") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    ReportStatGrid(items: hardwareCalibrationStatItems(report))
                    if !report.calibration.libraryDarkMismatchReasons.isEmpty {
                        Text("Library dark mismatches: \(report.calibration.libraryDarkMismatchReasons.joined(separator: ", "))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(report.calibration.problems, id: \.message) { problem in
                        Text("• \(problem.message)").font(.callout).foregroundStyle(AstroTokens.Color.attention)
                    }
                    if let accepted = report.session.dssAcceptedCount, let rejected = report.session.dssRejectedCount {
                        ReportStatGrid(items: [
                            ("DSS Accepted", "\(accepted)"),
                            ("DSS Rejected", "\(rejected)"),
                        ])
                    }
                }
            }
            ReportSection(title: "To-dos") {
                if report.projectTodos.isEmpty {
                    ReportEmptyNote(text: "No to-dos.")
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.projectTodos, id: \.self) { todo in
                            Text("• \(todo)").font(.callout)
                        }
                    }
                }
            }
        }
    }

    /// `ExposureAdvisor.notAvailableReason` (`AstroCore/Stats/ExposureAdvisor.swift`)
    /// ends with a CLI-era suggestion, verbatim " — futtasd újra: astrotool
    /// rate" -- honest advice for the `astrotool rate` command line (which
    /// still says exactly this), but this app has no terminal: the actual
    /// fix is the header's own "Rate Frames" button
    /// (`v2.night.page.rate`, above). `ExposureAdvisor.swift` itself stays
    /// untouched -- it backs several other callers (the CLI, `TargetReport`/
    /// `NightReport`'s own HTML export, `ProjectWorkspaceView`'s report tab)
    /// that either ARE the CLI or are out of this fix's scope -- this is a
    /// narrow, display-only substitution local to this view. A reason that
    /// does NOT end in the CLI suggestion (e.g. the missing-per-Bayer-data
    /// case) passes through unchanged rather than risk dropping real
    /// information this substitution was never told about.
    private static let exposureAdviceCLISuffix = " — futtasd újra: astrotool rate"

    /// W6-E item 6 (live pixel review): the SAME class of defect
    /// `exposureAdviceCLISuffix` above already fixes for `astrotool rate`,
    /// for `ExposureAdvisor`'s OTHER CLI branch -- `naReply(...)`'s "no
    /// sensor profile" reason (`AstroCore/Stats/ExposureAdvisor.swift`,
    /// `reason: "nincs szenzor-profil — futtasd: astrotool sensor
    /// --measure"`). Sensor Profiles is a real in-app page/route
    /// (`SensorProfilesView`, reachable via `ContentRoute.sensorProfiles`)
    /// unlike the "Rate Frames" case above (that one has no destination of
    /// its own to link to, only a button already on this same page) -- so
    /// this branch adds an actual navigable button next to the reworded
    /// text, not only a rephrased sentence.
    private static let exposureAdviceSensorCLISuffix = " — futtasd: astrotool sensor --measure"

    private func exposureAdviceNeedsSensorProfile(_ reason: String) -> Bool {
        reason.hasSuffix(Self.exposureAdviceSensorCLISuffix)
    }

    private func exposureAdviceReasonText(_ reason: String) -> String {
        if reason.hasSuffix(Self.exposureAdviceCLISuffix) {
            let honestPart = reason.dropLast(Self.exposureAdviceCLISuffix.count)
            let inAppSuggestion = NSLocalizedString(
                "Rate the frames using the “Rate Frames” button above.",
                bundle: .main,
                comment: "Replaces ExposureAdvisor's CLI-era \" — futtasd újra: astrotool rate\" suggestion in the in-app night report; this app has no terminal."
            )
            return honestPart + " — " + inAppSuggestion
        }
        if reason.hasSuffix(Self.exposureAdviceSensorCLISuffix) {
            let honestPart = reason.dropLast(Self.exposureAdviceSensorCLISuffix.count)
            let inAppSuggestion = NSLocalizedString(
                "Measure one on the Sensor Profiles page.",
                bundle: .main,
                comment: "Replaces ExposureAdvisor's CLI-era \" — futtasd: astrotool sensor --measure\" suggestion in the in-app night report; this app has no terminal. Paired with an actual \"Sensor Profiles…\" button next to this text."
            )
            return honestPart + " — " + inAppSuggestion
        }
        return reason
    }

    private func fwhmText(_ quality: CaptureQualitySummary?) -> String {
        guard let quality else { return "–" }
        if let arcsec = quality.medianFWHMArcsec { return AstroFormat.fwhmArcsec(arcsec) }
        if let px = quality.medianFWHMPixels { return AstroFormat.fwhmPixels(px) }
        return "–"
    }

    private func qualityStatItems(_ quality: SessionQualitySummary) -> [(LocalizedStringKey, String)] {
        var items: [(LocalizedStringKey, String)] = []
        if let arcsec = quality.medianFWHMArcsec {
            items.append(("FWHM", AstroFormat.fwhmArcsec(arcsec)))
        } else if let px = quality.medianFWHMPixels {
            items.append(("FWHM", AstroFormat.fwhmPixels(px)))
        }
        if let background = quality.backgroundEPerSecPerArcsec2 {
            items.append(("Background", AstroFormat.backgroundEPerSecArcsec2(background)))
        }
        if let rank = quality.rankAmongSessions, let total = quality.sessionCountForTarget {
            items.append(("Rank", "\(rank) / \(total)"))
        }
        if let outlier = quality.outlierFraction {
            items.append(("Outliers", AstroFormat.percent(outlier * 100)))
        }
        return items
    }

    private func altitudeMoonStatItems(_ report: NightReportQuery.Result) -> [(LocalizedStringKey, String)] {
        var items: [(LocalizedStringKey, String)] = []
        if let altitude = report.altitude {
            items.append(("Min. Altitude", AstroFormat.wholeDegrees(altitude.minAltitudeDeg)))
            items.append(("Median Altitude", AstroFormat.wholeDegrees(altitude.medianAltitudeDeg)))
            items.append(("Max. Altitude", AstroFormat.wholeDegrees(altitude.maxAltitudeDeg)))
            items.append(("Below 30°", AstroFormat.percent(altitude.belowThresholdPercent)))
        }
        if let moon = report.moon {
            items.append(("Moon Illumination", AstroFormat.percent(moon.illuminationPercent)))
            items.append(("Moon Separation (median)", AstroFormat.wholeDegrees(moon.medianSeparationDeg)))
            items.append(("Moon Max. Altitude", AstroFormat.wholeDegrees(moon.maxAltitudeDeg)))
        }
        return items
    }

    private func hardwareCalibrationStatItems(_ report: NightReportQuery.Result) -> [(LocalizedStringKey, String)] {
        var items: [(LocalizedStringKey, String)] = [
            ("Cooler", report.health.cooler.verdict),
            ("Focus", report.health.focus.verdict),
            ("Flats", "\(report.calibration.flats.count)"),
        ]
        if report.calibration.darks.isEmpty, let libraryDark = report.calibration.libraryDark {
            items.append(("Dark", "library: \((libraryDark as NSString).lastPathComponent)"))
        } else {
            items.append(("Dark", "\(report.calibration.darks.count)"))
        }
        items.append(("Bias", "\(report.calibration.biases.count)"))
        return items
    }
}

/// W5-3 (owner pixel review, 2026-08-24 IC 4604 night): the owner's own live
/// review flagged the Triage hero card ("Áttekintésre vár") rendering
/// through `MetricCard`'s `astroDataHero()` -- the huge, `@ScaledMetric`,
/// tabular-monospace 30pt style `AstroType.swift` documents as being for "a
/// card's headline numeric value" specifically. `MetricCard.value`'s own
/// doc comment already says as much ("almost always a formatted number/
/// duration, never a phrase to translate"), and `row.triageState
/// .localizedText` is this workspace's one exception -- a whole word/phrase
/// ("Needs review", "Complete"), not a number, and at 30pt monospaced it
/// sprawls well past the width its two numeric siblings ("3h 20m", "6")
/// occupy.
///
/// This is a narrow, file-local twin of `MetricCard`
/// (`WorkspaceComponents.swift`, shared by every OTHER workspace's numeric
/// hero cards and out of this fix's scope) rather than a change to that
/// shared component: identical chrome -- label, glass card, detail line --
/// so it sits flush with `MetricCard`'s own two cards in the same `HStack`,
/// but the hero VALUE gets a text-appropriate style (`.title2.weight
/// (.semibold)`, the same weight class `AstroType.sectionTitle` already
/// uses for headings) instead of the numeric `astroDataHero()`.
/// `W53NightReportFindingsSurfaceTests.triageHeroCardUsesTextStyleNotNumericHero`
/// pins this: Triage never regresses back to `MetricCard`/`astroDataHero()`,
/// and the two numeric cards next to it never lose it either.
private struct TextMetricCard: View {
    let title: LocalizedStringKey
    let value: String
    let detail: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(AstroTokens.Spacing.standard)
        .glassEffect(.regular, in: ConcentricRectangle())
    }
}
