import AstroApplication
import SwiftUI
import UniformTypeIdentifiers

public struct NightWorkspaceView: View {
    private struct SeriesRow: Identifiable {
        let series: SeriesRecord
        var id: UUID { series.id }
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
    /// Wave 4 (post-20014) fix: see `ProjectWorkspaceView.actionOwner`'s own
    /// doc comment -- same reasoning here.
    @State private var actionOwner = UUID().uuidString

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
            VStack(alignment: .leading, spacing: 4) {
                Text(row.projectSummary).font(.title2.weight(.semibold))
                Text("\(row.snapshot.usableFrames) usable · \(row.excludedFrames) excluded · \(row.integrationSummary)")
                    .font(.callout).foregroundStyle(.secondary)
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
                seriesTable
                    .padding(AstroTokens.Spacing.spacious)
            } else {
                ScrollView {
                    content.padding(AstroTokens.Spacing.spacious)
                }
            }
        }
        .background(AstroTokens.Color.graphite.opacity(0.36))
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
        // Wave 4 Task 2: Export/Night Actions/Review Frames/Open Project
        // used to be an in-body button row in this same header -- they now
        // render in the shell's own stable toolbar (see `WorkspaceActions`'s
        // doc comment), so the header above keeps only identity plus the
        // global breadcrumb above it (Wave 4 Task 3 removed the redundant
        // "Night" eyebrow prefix that used to duplicate that breadcrumb).
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
                    MetricCard(title: "Series", value: row.seriesCount.formatted(), detail: row.filterSummary, systemImage: "square.stack.3d.up")
                    MetricCard(title: "Triage", value: row.triageState.rawValue, detail: "\(row.excludedFrames) excluded", systemImage: "checklist")
                }
                GroupBox("Projects captured this night") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(row.snapshot.projects, id: \.id) { project in
                            HStack {
                                Text(project.displayName)
                                Spacer()
                                Button("Open Project") { openProject(project) }
                                    .buttonStyle(.link)
                            }
                        }
                    }.padding(AstroTokens.Spacing.compact)
                }
            }
        case .series:
            // `body` above renders `seriesTable` directly for this tab (a
            // `Table` must never sit inside this switch's own `ScrollView`),
            // so this branch is never actually reached -- kept only so the
            // switch stays exhaustive without a catch-all `default:`.
            EmptyView()
        case .frames:
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
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
        case .notes:
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                GroupBox("Session notes") {
                    Text("Bortle, SQM, seeing, transparency, wind, dew, and freeform notes are stored with this session's own files.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(AstroTokens.Spacing.compact)
                }
                Button("Edit Notes") { isEditingNotes = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(rootURL == nil || row.snapshot.projects.first == nil)
            }
        }
    }

    private var seriesTable: some View {
        Table(row.snapshot.series.map(SeriesRow.init)) {
            TableColumn("Project") { series in
                Text(row.snapshot.projects.first { $0.id == series.series.projectID }?.displayName ?? "Unknown")
            }
            TableColumn("Filter") { Text($0.series.filterName ?? "Unfiltered") }
            TableColumn("Exposure") { Text("\($0.series.exposureSeconds.formatted()) s").monospacedDigit() }
            TableColumn("Setup") { Text($0.series.setupDescriptor).lineLimit(1) }
            TableColumn("Mode") { Text($0.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
