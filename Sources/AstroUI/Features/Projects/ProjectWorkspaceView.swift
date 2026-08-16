import AstroApplication
import SwiftUI
import UniformTypeIdentifiers

public struct ProjectWorkspaceView: View {
    let snapshot: ProjectSnapshot
    let rootURL: URL?
    let accessMode: LibraryAccessMode
    let review: () -> Void
    let results: () -> Void
    let openNight: (UUID) -> Void
    let openSeries: (UUID) -> Void
    let openCalibration: () -> Void
    let openInsights: (String?) -> Void
    let annotation: ProjectAnnotationRecord?
    let saveAnnotation: (Double?, String) async throws -> Void
    /// Wave 4 Task 3: the segmented tab used to be `@State` here, which
    /// `.id(route)` (see `DetailHost`'s doc comment) resets on every push --
    /// so drilling into a night and popping back silently reset the tab to
    /// Overview. It is now `router.projectTab`, a plain property on the
    /// router the view does not own the identity of, so it survives.
    @Bindable var router: AppRouter
    @State private var goalHours: Double?
    @State private var projectNotes: String
    @State private var saveError: String?
    @State private var isSaving = false
    @Environment(WorkspaceActionCenter.self) private var workspaceActionCenter
    /// Wave 4 (post-20014) fix: this view's own stable identity within
    /// `WorkspaceActionCenter` -- see that type's own doc comment for why
    /// publishing is now owner-keyed rather than a per-body-pass focused
    /// value. A fresh token per view instance is exactly right here: `.id
    /// (route)` (see `DetailHost`'s own doc comment) recreates this view --
    /// and therefore this token -- every time the pushed project changes,
    /// while an in-place re-render (the SAME project, new `snapshot`
    /// content) keeps the same token/owner.
    @State private var actionOwner = UUID().uuidString

    public init(
        snapshot: ProjectSnapshot,
        rootURL: URL? = nil,
        accessMode: LibraryAccessMode = .readOnly,
        annotation: ProjectAnnotationRecord?,
        router: AppRouter,
        review: @escaping () -> Void,
        results: @escaping () -> Void,
        openNight: @escaping (UUID) -> Void,
        openSeries: @escaping (UUID) -> Void,
        openCalibration: @escaping () -> Void = {},
        openInsights: @escaping (String?) -> Void = { _ in },
        saveAnnotation: @escaping (Double?, String) async throws -> Void
    ) {
        self.snapshot = snapshot
        self.rootURL = rootURL
        self.accessMode = accessMode
        self.annotation = annotation
        self.router = router
        self.review = review
        self.results = results
        self.openNight = openNight
        self.openSeries = openSeries
        self.openCalibration = openCalibration
        self.openInsights = openInsights
        self.saveAnnotation = saveAnnotation
        _goalHours = State(initialValue: annotation?.integrationGoalHours)
        _projectNotes = State(initialValue: annotation?.notes ?? "")
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("Project section", selection: $router.projectTab) {
                ForEach(ProjectWorkspaceTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AstroTokens.Spacing.spacious)
            .padding(.vertical, AstroTokens.Spacing.standard)
            .accessibilityIdentifier("v2.project.workspace.tab")
            if router.projectTab == .results {
                resultsContent
            } else if router.projectTab == .nights || router.projectTab == .series {
                // Deliberately NOT inside the `ScrollView` below, for the
                // same reason `.results` above already isn't: a `Table`
                // proposed an unbounded height cannot virtualize its rows --
                // see `WorkspaceTablePage`'s own doc comment for the same
                // fix applied to the main table-hosting workspaces.
                tableTabContent
                    .padding(AstroTokens.Spacing.spacious)
            } else {
                ScrollView {
                    content.padding(AstroTokens.Spacing.spacious)
                }
            }
        }
        .background(AstroTokens.Color.ground.opacity(0.36))
        .navigationTitle(snapshot.project.displayName)
        .accessibilityIdentifier("v2.project.workspace")
        // Wave 4 Task 2: this workspace's own primary actions (Export,
        // Review Frames, Results) used to be an in-body button row in
        // `header` below -- they now render in the shell's own stable
        // toolbar instead (see `WorkspaceActions`'s doc comment), so the
        // header keeps ONLY identity (title/summary) plus the global
        // breadcrumb above it (Wave 4 Task 3 removed the redundant
        // "Project" eyebrow prefix that used to duplicate that breadcrumb).
        // Wave 4 (post-20014) fix: published from discrete lifecycle/state-
        // change events rather than from `body` itself -- see
        // `WorkspaceActionCenter`'s own doc comment.
        .onAppear { publishWorkspaceActions() }
        .onChange(of: rootURL) { _, _ in publishWorkspaceActions() }
        .onChange(of: snapshot) { _, _ in publishWorkspaceActions() }
        .onDisappear { workspaceActionCenter.clear(owner: actionOwner) }
    }

    private func publishWorkspaceActions() {
        workspaceActionCenter.publish(owner: actionOwner, workspaceActions)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.project.displayName).font(.title2.weight(.semibold))
            Text("\(AstroFormat.duration(seconds: snapshot.integrationSeconds)) usable · \(snapshot.nights.count) nights · \(snapshot.series.count) series")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions([
            .exportMenu(WorkspaceActionExportMenu(
                id: "v2.project.export", items: projectExportItems, accessibilityID: "v2.project.export"
            )),
            .button(WorkspaceAction(
                id: "v2.project.review",
                title: "Review Frames",
                systemImage: "checkmark.rectangle.stack",
                help: "Open the frame-by-frame review workspace for this project",
                action: review
            )),
            .button(WorkspaceAction(
                id: "v2.project.results",
                title: "Results",
                systemImage: "square.stack.3d.up",
                help: "Inspect stacks, processed variants, and their provenance",
                action: results
            )),
        ])
    }

    /// Acquisition (all three V1 formats), the target report, and the latest
    /// night's stack list -- every project-scoped export V1's per-target
    /// context menu offered (`AppState.exportAcquisition`/`exportTargetReport`/
    /// `exportStackList`), all through `ExportService`. `[]` when no library
    /// is open at all (`rootURL == nil`, never true once a project workspace
    /// is actually reachable, but `ExportMenu` degrades to disabled rather
    /// than assume).
    private var projectExportItems: [ExportMenuItem] {
        guard let rootURL else { return [] }
        let target = snapshot.canonicalFolderName
        let latestNightDate = snapshot.nights.first?.night.localDate
        var items: [ExportMenuItem] = [
            .file(title: "Acquisition (AstroBin CSV)…", systemImage: "tablecells", contentType: .commaSeparatedText) {
                let export = try ExportService.production(rootURL: rootURL).acquisitionExport(target: target, format: .astrobin)
                return (export.content, export.suggestedFilename, export.unmappedFilters)
            },
            .file(title: "Acquisition (CSV)…", systemImage: "tablecells", contentType: .commaSeparatedText) {
                let export = try ExportService.production(rootURL: rootURL).acquisitionExport(target: target, format: .csv)
                return (export.content, export.suggestedFilename, export.unmappedFilters)
            },
            .file(title: "Acquisition (Markdown)…", systemImage: "doc.text", contentType: .init(filenameExtension: "md") ?? .plainText) {
                let export = try ExportService.production(rootURL: rootURL).acquisitionExport(target: target, format: .md)
                return (export.content, export.suggestedFilename, export.unmappedFilters)
            },
            .divider,
            .file(title: "Target Report…", systemImage: "doc.richtext", contentType: .html) {
                let export = try ExportService.production(rootURL: rootURL).targetReport(target: target)
                return (export.content, export.suggestedFilename, [])
            },
        ]
        if let latestNightDate {
            items.append(
                .file(title: "Stack List (Latest Night)…", systemImage: "square.stack.3d.up", contentType: .commaSeparatedText) {
                    let export = try ExportService.production(rootURL: rootURL).stackList(target: target, date: latestNightDate)
                    return (export.content, export.suggestedFilename, [])
                }
            )
        }
        return items
    }

    /// The Results tab -- Wave 4 Task 3: this used to be a
    /// `ContentUnavailableView` telling the reader to press the (separate)
    /// "Results" toolbar button instead of actually showing anything.
    /// `ProjectResultsPane` is the exact same table/detail/QuickLook content
    /// `ResultsView`'s own `.resultsWorkspace(projectID:)` route renders,
    /// scoped to this project, so the tab now hosts the real thing rather
    /// than pointing elsewhere. Deliberately NOT wrapped in the outer
    /// `ScrollView` the other tabs use -- the pane manages its own
    /// `HSplitView`/`Table` scrolling exactly like the full Results route
    /// does.
    @ViewBuilder private var resultsContent: some View {
        if let rootURL {
            ProjectResultsPane(rootURL: rootURL, project: snapshot.project)
        } else {
            ContentUnavailableView(
                "No library open",
                systemImage: "square.stack.3d.up.slash",
                description: Text("Open a library to inspect this project's stacks and processed variants.")
            )
        }
    }

    /// `.nights` and `.series` render here (via `body`'s own `if` above),
    /// not inside `content`'s `ScrollView`, since both host a `Table`.
    @ViewBuilder private var tableTabContent: some View {
        switch router.projectTab {
        case .nights:
            ProjectNightsSummary(
                snapshot: snapshot, rootURL: rootURL, accessMode: accessMode,
                openNight: openNight, openCalibration: openCalibration, openInsights: openInsights
            )
        case .series:
            ProjectSeriesSummary(snapshot: snapshot, openSeries: openSeries)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch router.projectTab {
        case .overview:
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(title: "Integration", value: AstroFormat.duration(seconds: snapshot.integrationSeconds), detail: "Usable exposure", systemImage: "timer")
                    MetricCard(title: "Frames", value: "\(snapshot.usableFrames)", detail: "\(snapshot.totalFrames - snapshot.usableFrames) excluded", systemImage: "photo.stack")
                    MetricCard(title: "Latest night", value: snapshot.nights.first?.night.localDate ?? "—", detail: LocalizedStringKey(snapshot.canonicalFolderName), systemImage: "moon.stars")
                }
                GroupBox("Next action") {
                    Label(snapshot.nextAction.kind.titleKey, systemImage: "arrow.forward.circle.fill")
                    Text(snapshot.nextAction.kind.explanationKey).foregroundStyle(.secondary)
                }
            }
        case .nights, .series:
            // `body` above renders `tableTabContent` directly for these tabs
            // (each hosts a `Table`, which must not sit inside this switch's
            // own `ScrollView`), so this branch is never actually reached --
            // kept only so the switch stays exhaustive without a catch-all
            // `default:`.
            EmptyView()
        case .results:
            // `body` above renders `resultsContent` directly for this tab
            // (Results manages its own `HSplitView`/`Table` scrolling and
            // should not be nested inside this switch's own `ScrollView`),
            // so this branch is never actually reached -- kept only so the
            // switch stays exhaustive without a catch-all `default:`.
            EmptyView()
        case .notes:
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                GroupBox("Acquisition goal") {
                    LabeledContent("Integration goal") {
                        HStack(spacing: 6) {
                            TextField("Hours", value: $goalHours, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 90)
                            Text("hours").foregroundStyle(.secondary)
                        }
                    }
                    .padding(AstroTokens.Spacing.compact)
                }
                GroupBox("Project notes") {
                    TextEditor(text: $projectNotes)
                        .font(.body)
                        .frame(minHeight: 180)
                        .padding(6)
                }
                if let saveError { Text(saveError).foregroundStyle(AstroTokens.Color.critical) }
                HStack {
                    Text(annotation.map { "Last saved \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "Not saved yet")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Project Details") {
                        isSaving = true
                        saveError = nil
                        Task {
                            do { try await saveAnnotation(goalHours, projectNotes) }
                            catch { saveError = error.localizedDescription }
                            isSaving = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || (goalHours != nil && goalHours! <= 0))
                    .accessibilityIdentifier("v2.project.save-details")
                }
            }
        }
    }
}

private struct ProjectNightsSummary: View {
    let snapshot: ProjectSnapshot
    let rootURL: URL?
    let accessMode: LibraryAccessMode
    let openNight: (UUID) -> Void
    let openCalibration: () -> Void
    let openInsights: (String?) -> Void
    @State private var selection: UUID?
    @State private var noteEditorTarget: NightNoteEditingTarget?
    /// V2 UI/UX audit (2026-08-14) systemic pattern S7: this table's rows
    /// (`snapshot.nights`) are a small, already-in-memory local array (a
    /// project rarely has more than a few dozen nights), not a store's own
    /// cached collection -- so the sort is cached in local `@State` and
    /// re-run via `.onChange`/`.task(id:)`, matching the convention this
    /// codebase uses for exactly that case (see `NightsStore.sortOrder`'s
    /// own doc comment). Default is newest night first, consistent with
    /// the main Nights table.
    @State private var sortOrder: [KeyPathComparator<ProjectNightSnapshot>] = [
        KeyPathComparator(\ProjectNightSnapshot.night.localDate, order: .reverse)
    ]
    @State private var sortedNights: [ProjectNightSnapshot] = []

    var body: some View {
        Table(sortedNights, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Night", value: \ProjectNightSnapshot.night.localDate) { Text($0.night.localDate).monospacedDigit() }
            TableColumn("Series", value: \ProjectNightSnapshot.series.count) { Text($0.series.count.formatted()).monospacedDigit() }
            TableColumn("Usable", value: \ProjectNightSnapshot.usableFrames) { Text($0.usableFrames.formatted()).monospacedDigit() }
            TableColumn("Integration", value: \ProjectNightSnapshot.integrationSeconds) { Text(AstroFormat.duration(seconds: $0.integrationSeconds)).monospacedDigit() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: sortOrder) { _, _ in recomputeSortedNights() }
        .task(id: snapshot) { recomputeSortedNights() }
        .contextMenu(forSelectionType: UUID.self) { nightIDs in
            if let id = nightIDs.first, let night = snapshot.nights.first(where: { $0.id == id }) {
                NightActionMenu(
                    target: snapshot.canonicalFolderName,
                    date: night.night.localDate,
                    setupDescriptor: night.series.first?.series.setupDescriptor,
                    nightID: night.id,
                    rootURL: rootURL,
                    openNight: { openNight(id) },
                    editNotes: {
                        noteEditorTarget = NightNoteEditingTarget(
                            target: snapshot.canonicalFolderName, date: night.night.localDate
                        )
                    },
                    openCalibration: openCalibration,
                    openInsights: openInsights
                )
            }
        } primaryAction: { nightIDs in
            if let id = nightIDs.first { openNight(id) }
        }
        .sheet(item: $noteEditorTarget) { editing in
            if let rootURL {
                NightNoteSheet(
                    rootURL: rootURL, target: editing.target, date: editing.date,
                    accessMode: accessMode, dismiss: { noteEditorTarget = nil }
                )
            }
        }
    }

    private func recomputeSortedNights() {
        var rows = snapshot.nights
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        sortedNights = rows
    }
}

private struct ProjectSeriesSummary: View {
    let snapshot: ProjectSnapshot
    let openSeries: (UUID) -> Void
    @State private var selection: UUID?
    /// Small local array (see `ProjectNightsSummary.sortOrder`'s own doc
    /// comment for why this is cached in `@State` rather than a store).
    /// Default is filter name ascending.
    @State private var sortOrder: [KeyPathComparator<ProjectSeriesSnapshot>] = [
        KeyPathComparator(\ProjectSeriesSnapshot.filterSortKey, order: .forward)
    ]
    @State private var sortedSeries: [ProjectSeriesSnapshot] = []

    var body: some View {
        Table(sortedSeries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Filter", value: \ProjectSeriesSnapshot.filterSortKey) { Text($0.filterName ?? "Unfiltered") }
            TableColumn("Exposure", value: \ProjectSeriesSnapshot.series.exposureSeconds) { Text("\($0.series.exposureSeconds.formatted()) s").monospacedDigit() }
            TableColumn("Setup", value: \ProjectSeriesSnapshot.series.setupDescriptor) { Text($0.series.setupDescriptor).lineLimit(1) }
            TableColumn("Frames", value: \ProjectSeriesSnapshot.usableFrames) { Text("\($0.usableFrames) / \($0.excludedFrames)").monospacedDigit() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: sortOrder) { _, _ in recomputeSortedSeries() }
        .task(id: snapshot) { recomputeSortedSeries() }
        .contextMenu(forSelectionType: UUID.self) { seriesIDs in
            if let id = seriesIDs.first {
                Button("Open Series") { openSeries(id) }
            }
        } primaryAction: { seriesIDs in
            if let id = seriesIDs.first { openSeries(id) }
        }
    }

    private func recomputeSortedSeries() {
        var rows = snapshot.nights.flatMap(\.series)
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        sortedSeries = rows
    }
}
