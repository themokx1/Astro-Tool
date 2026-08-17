import AstroApplication
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

    public init(
        row: NightRow,
        rootURL: URL? = nil,
        accessMode: LibraryAccessMode = .readOnly,
        router: AppRouter,
        openProject: @escaping (ProjectRecord) -> Void,
        reviewProject: @escaping (ProjectRecord) -> Void,
        openCalibration: @escaping () -> Void = {},
        openInsights: @escaping (String?) -> Void = { _ in }
    ) {
        self.row = row
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.router = router
        self.openProject = openProject
        self.reviewProject = reviewProject
        self.openCalibration = openCalibration
        self.openInsights = openInsights
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.projectSummary).font(.title2.weight(.semibold))
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
                                operationHost: operationHost
                            )
                        } label: {
                            Label("Rate Frames", systemImage: "star.leadinghalf.filled")
                        }
                        .help("Measure quality for every series captured this night")
                        .accessibilityIdentifier("v2.night.page.rate")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(AstroTokens.Spacing.spacious)
            Divider()
            Picker("Night section", selection: $router.nightTab) {
                ForEach(NightWorkspaceTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
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
    }

    private func publishWorkspaceActions() {
        workspaceActionCenter.publish(owner: actionOwner, workspaceActions)
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
                    MetricCard(title: "Triage", value: row.triageState.rawValue, detail: "\(row.excludedFrames) excluded", systemImage: "checklist")
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
            TableColumn("Filter", value: \SeriesRow.filterSortKey) { Text($0.series.filterName ?? "Unfiltered") }
            TableColumn("Exposure", value: \SeriesRow.series.exposureSeconds) { Text("\($0.series.exposureSeconds.formatted()) s").monospacedDigit() }
            TableColumn("Setup", value: \SeriesRow.series.setupDescriptor) { Text($0.series.setupDescriptor).lineLimit(1) }
            TableColumn("Mode", value: \SeriesRow.series.passband.rawValue) { Text($0.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// This night's report (`AppState.exportNightReport`'s V2 equivalent) --
    /// `[]` when no library is open, or this night has no project at all to
    /// resolve a library/folder key from.
    private var nightExportItems: [ExportMenuItem] {
        guard let rootURL, let project = row.snapshot.projects.first else { return [] }
        let target = ProjectsQuery.canonicalFolderName(for: project)
        let date = row.date
        return [
            .file(title: "Night Report…", systemImage: "doc.richtext", contentType: .html) {
                let export = try ExportService.production(rootURL: rootURL).nightReport(target: target, date: date)
                return (export.content, export.suggestedFilename, [])
            },
        ]
    }

    private var workspaceActions: WorkspaceActions {
        var items: [WorkspaceActionItem] = [
            .exportMenu(WorkspaceActionExportMenu(
                id: "v2.nights.export", items: nightExportItems, accessibilityID: "v2.nights.export"
            )),
        ]
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
}
