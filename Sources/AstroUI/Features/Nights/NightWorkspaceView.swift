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
    @State private var isEditingNotes = false

    public init(
        row: NightRow,
        rootURL: URL? = nil,
        accessMode: LibraryAccessMode = .readOnly,
        openProject: @escaping (ProjectRecord) -> Void,
        reviewProject: @escaping (ProjectRecord) -> Void,
        openCalibration: @escaping () -> Void = {},
        openInsights: @escaping (String?) -> Void = { _ in }
    ) {
        self.row = row
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.openProject = openProject
        self.reviewProject = reviewProject
        self.openCalibration = openCalibration
        self.openInsights = openInsights
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Night › \(row.date)").font(.caption.weight(.semibold)).foregroundStyle(AstroTokens.Color.spectralViolet)
                Text(row.projectSummary).font(.title2.weight(.semibold))
                Text("\(row.snapshot.usableFrames) usable · \(row.excludedFrames) excluded · \(row.integrationSummary)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(AstroTokens.Spacing.spacious)
            Divider()
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(title: "Integration", value: row.integrationSummary, detail: "Usable light frames", systemImage: "timer")
                    MetricCard(title: "Series", value: row.seriesCount.formatted(), detail: row.filterSummary, systemImage: "square.stack.3d.up")
                    MetricCard(title: "Triage", value: row.triageState.rawValue, detail: "\(row.excludedFrames) excluded", systemImage: "checklist")
                }
                Table(row.snapshot.series.map(SeriesRow.init)) {
                    TableColumn("Project") { series in
                        Text(row.snapshot.projects.first { $0.id == series.series.projectID }?.displayName ?? "Unknown")
                    }
                    TableColumn("Filter") { Text($0.series.filterName ?? "Unfiltered") }
                    TableColumn("Exposure") { Text("\($0.series.exposureSeconds.formatted()) s").monospacedDigit() }
                    TableColumn("Setup") { Text($0.series.setupDescriptor).lineLimit(1) }
                    TableColumn("Mode") { Text($0.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) }
                }
                .frame(minHeight: 360)
            }
            .padding(AstroTokens.Spacing.spacious)
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
        // global breadcrumb above it.
        .focusedSceneValue(\.workspaceActions, workspaceActions)
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
            .custom(id: "v2.nights.export") {
                ExportMenu(items: nightExportItems, accessibilityID: "v2.nights.export")
            },
        ]
        if let project = row.snapshot.projects.first {
            items.append(.custom(id: "v2.night.workspace.actions") {
                Menu {
                    NightActionMenu(
                        target: ProjectsQuery.canonicalFolderName(for: project),
                        date: row.date,
                        setupDescriptor: row.snapshot.series.first?.setupDescriptor,
                        nightID: row.id,
                        rootURL: rootURL,
                        editNotes: { isEditingNotes = true },
                        openCalibration: openCalibration,
                        openInsights: openInsights
                    )
                } label: {
                    Label("Night Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("v2.night.workspace.actions")
            })
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
