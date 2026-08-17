import AstroApplication
import SwiftUI

public struct ProjectsView: View {
    let snapshot: LibrarySnapshot?
    @Bindable var store: ProjectsStore
    let createProject: () -> Void
    let chooseLibrary: () -> Void
    let reviewProject: (ProjectRecord) -> Void
    let showResults: (ProjectRecord) -> Void
    let openProject: (ProjectRecord) -> Void
    /// Task 4 (2026-08-17 owner-feedback wave 3): backs "Rate All Projects"
    /// below -- the owner's own words: "ezt úgy is kéne tudnom, hogy minden
    /// projektre ráengedni" (run the whole-project rate across every
    /// project).
    @Environment(OperationHost.self) private var operationHost
    @State private var searchText = ""
    @State private var visibleProjects: [ProjectRecord] = []
    /// Mirrors `ProjectsStore.sortOrder`. The table needs a `Binding`, but
    /// the actual re-sort happens in the store's `workspaceRows` (see
    /// `PlanningView.sortOrder`'s own doc comment for why that split
    /// exists). Task 5 (2026-08-17 owner-feedback wave 3): default is
    /// most-recent-capture-first -- see `ProjectsStore.sortOrder`'s own doc
    /// comment for why.
    @State private var sortOrder: [KeyPathComparator<ProjectWorkspaceRow>] = [
        KeyPathComparator(\ProjectWorkspaceRow.latestNightSortKey, order: .reverse)
    ]

    public var body: some View {
        if snapshot == nil {
            ContentUnavailableView {
                Label("No library open", systemImage: "folder")
            } description: {
                Text("Open a library to keep every target's nights, series, stacks, and results together.")
            } actions: {
                Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent)
            }
            .navigationTitle("Projects")
            .accessibilityLabel("Projects")
            .accessibilityIdentifier("v2.detail.projects")
        } else {
            projectsWorkspace
        }
    }

    private var projectsWorkspace: some View {
        WorkspaceTablePage(
            subtitle: "One target, every night, series, stack, and result — kept together."
        ) {
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(title: "Projects", value: snapshot.map { "\($0.projectCount)" } ?? "—", detail: "Recognized target folders", systemImage: "folder")
                MetricCard(title: "Nights", value: snapshot.map { "\($0.nightCount)" } ?? "—", detail: "Across the open library", systemImage: "moon.stars")
            }

            GroupBox("Start cleanly") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    Label("Search by catalog number, English name, or Hungarian name.", systemImage: "sparkle.magnifyingglass")
                    Label("AstroTool proposes one canonical folder name to prevent duplicates.", systemImage: "checkmark.seal")
                    Button("New Project…", action: createProject)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AstroTokens.Spacing.compact)
            }

            if !store.projects.isEmpty {
                TextField("Search projects, catalog, filter, setup, or status", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("v2.projects.search")
                    .onChange(of: searchText) { _, value in
                        Task { visibleProjects = (try? await store.search(value)) ?? [] }
                    }
                // Task 4 (2026-08-17 owner-feedback wave 3): the owner's own
                // words -- "ezt úgy is kéne tudnom, hogy minden projektre
                // ráengedni" (run the whole-project rate across every
                // project). Page-level, not toolbar: this page never
                // publishes to `WorkspaceActionCenter` at all (it is a
                // section ROOT, not a pushed workspace), so a bulk action
                // like this one has no drill-down to survive and needs no
                // toolbar copy.
                HStack {
                    Spacer()
                    Button(action: rateAllProjects) {
                        Label("Rate All Projects", systemImage: "star.leadinghalf.filled")
                    }
                    .help("Measure quality for every night and series across every project in this library")
                    .accessibilityIdentifier("v2.projects.rate-all")
                }
            }
        } table: {
            tableContent
        }
        .navigationTitle("Projects")
        .accessibilityLabel("Projects")
        .accessibilityIdentifier("v2.detail.projects")
        .task(id: store.projects) {
            visibleProjects = (try? await store.search(searchText)) ?? store.projects
        }
        .onChange(of: sortOrder) { _, newValue in store.setSortOrder(newValue) }
    }

    @ViewBuilder
    private var tableContent: some View {
        if !store.projects.isEmpty {
            GroupBox("Saved projects") {
                Table(filteredRows, selection: projectSelection, sortOrder: $sortOrder) {
                    TableColumn("Project", value: \ProjectWorkspaceRow.project.displayName) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.project.displayName).font(.headline)
                            Text(row.project.catalogID).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { openProject(row.project) }
                    }
                    TableColumn("Phase", value: \ProjectWorkspaceRow.project.phase.rawValue) { row in Text(row.project.phase.displayLabel) }
                        .width(min: 85, ideal: 100)
                    TableColumn("Nights", value: \ProjectWorkspaceRow.nightCount) { row in Text(row.nightCount.formatted()).monospacedDigit() }
                        .width(60)
                    TableColumn("Series", value: \ProjectWorkspaceRow.seriesCount) { row in Text(row.seriesCount.formatted()).monospacedDigit() }
                        .width(58)
                    TableColumn("Integration", value: \ProjectWorkspaceRow.integrationSeconds) { row in Text(AstroFormat.duration(seconds: row.integrationSeconds)).monospacedDigit() }
                        .width(85)
                    TableColumn("Frames", value: \ProjectWorkspaceRow.usableFrames) { row in
                        Text("\(row.usableFrames) / \(row.excludedFrames)").monospacedDigit()
                            .help("Usable / excluded")
                    }.width(80)
                    TableColumn("Latest", value: \ProjectWorkspaceRow.latestNightSortKey) { row in Text(row.latestNight ?? "—").monospacedDigit() }
                        .width(100)
                    TableColumn("Goal", value: \ProjectWorkspaceRow.goalProgressSortKey) { row in
                        if let progress = row.goalProgress {
                            HStack(spacing: 6) {
                                ProgressView(value: progress).frame(width: 44)
                                Text(progress, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit().font(.caption)
                            }
                            .help("\(AstroFormat.duration(seconds: row.integrationSeconds)) of \((row.goalHours ?? 0).formatted(.number.precision(.fractionLength(0...1)))) h goal")
                        } else {
                            Text("—").foregroundStyle(.secondary)
                                .help("No integration goal set — add one on the project's Notes tab.")
                        }
                    }.width(96)
                    TableColumn("Next") { row in
                        Text(row.nextAction).lineLimit(1).help(row.nextActionExplanation)
                    }
                    // Task 5b (2026-08-17 owner-feedback wave 3): this used
                    // to be two bare icon buttons (`checklist`,
                    // `square.stack.3d.up`) -- readable only by hovering
                    // each one out to its `.help()` tooltip, and missing
                    // "Open Project" entirely (the row's own context menu
                    // had three actions, this strip had two: one row, two
                    // different sets). Chose a single "..." overflow menu
                    // over widening the column with labelled buttons: the
                    // row's action set is not fixed -- `NightsView`'s own
                    // row menu (below) already needs seven items behind one
                    // button, and a labelled-button strip would need
                    // re-widening every time this list grows. `More`/
                    // `projectRowActions(_:)` is the exact affordance
                    // `ResultsView.resultActions` and the shell toolbar's
                    // "Night Actions" menu already use elsewhere in this
                    // app, so this is one convention, not a bespoke one.
                    // The context menu below now builds from the SAME
                    // `projectRowActions(_:)` function, so the two can never
                    // drift back into different sets.
                    TableColumn("") { row in
                        Menu {
                            projectRowActions(row)
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("More actions")
                        .accessibilityIdentifier("v2.projects.row-actions.\(row.id.uuidString)")
                    }.width(40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first, let row = store.workspaceRows.first(where: { $0.id == id }) {
                        projectRowActions(row)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let row = store.workspaceRows.first(where: { $0.id == id }) {
                        openProject(row.project)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Task 4: rates every night/series of EVERY project in the open
    /// library -- reuses `ProjectRatingRunner`, the same batching layer over
    /// `FrameRatingCommand` that `ProjectWorkspaceView.rateEntireProject`
    /// uses for a single project, so there is exactly one rating pipeline,
    /// not a second one reinvented for the "all projects" case.
    private func rateAllProjects() {
        guard let rootURL = store.rootURL else { return }
        Task {
            await ProjectRatingRunner.run(
                scope: .allProjects(libraryName: rootURL.lastPathComponent),
                rootURL: rootURL,
                metadataFactory: ProjectsStore.productionMetadata,
                operationHost: operationHost
            )
        }
    }

    /// Task 5b (2026-08-17 owner-feedback wave 3): the ONE place this row's
    /// action set is declared -- both the row's own "..." overflow menu and
    /// its right-click context menu build from this same function, so they
    /// can never again offer two different sets for the same row.
    @ViewBuilder
    private func projectRowActions(_ row: ProjectWorkspaceRow) -> some View {
        Button("Open Project") { openProject(row.project) }
        Button("Review Frames") { reviewProject(row.project) }
        Button("Results") { showResults(row.project) }
    }

    private var filteredRows: [ProjectWorkspaceRow] {
        let ids = Set(visibleProjects.map(\.id))
        return store.workspaceRows.filter { ids.contains($0.id) }
    }

    /// V2 UI/UX audit (2026-08-14) systemic pattern S3: this setter used to
    /// ALSO call `openProject`, alongside the table's own double-click
    /// `primaryAction:` (below) -- a double-click therefore pushed the
    /// project route twice, and it was impossible to select a row without
    /// immediately navigating away from it (breaking its context menu and
    /// arrow-key traversal). Selecting now only ever updates selection
    /// state; only `primaryAction:` (double-click) navigates.
    private var projectSelection: Binding<UUID?> {
        Binding(
            get: { store.selectedProjectID },
            set: { id in
                Task { try? await store.selectProject(id) }
            }
        )
    }
}

private struct ProjectAcquisitionDetail: View {
    let snapshot: ProjectSnapshot
    let review: () -> Void
    let results: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.project.displayName)
                            .font(.title2.weight(.semibold))
                        Text(snapshot.canonicalFolderName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Review frames", action: review)
                    Button("Results", action: results)
                        .buttonStyle(.borderedProminent)
                }

                HStack(spacing: AstroTokens.Spacing.standard) {
                    MetricCard(
                        title: "Usable integration",
                        value: AstroFormat.duration(seconds: snapshot.integrationSeconds),
                        detail: "\(snapshot.usableFrames) of \(snapshot.totalFrames) frames",
                        systemImage: "timer"
                    )
                    MetricCard(
                        title: "Nights",
                        value: "\(snapshot.nights.count)",
                        detail: "\(snapshot.series.count) capture series",
                        systemImage: "moon.stars"
                    )
                    MetricCard(
                        title: "Excluded",
                        value: "\(snapshot.totalFrames - snapshot.usableFrames)",
                        detail: "Rejected or archived frames",
                        systemImage: "archivebox"
                    )
                }

                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.nextAction.kind.titleKey).font(.headline)
                        Text(snapshot.nextAction.kind.explanationKey)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.forward.circle.fill")
                        .foregroundStyle(AstroTokens.Color.accent)
                }

                Divider()

                ForEach(snapshot.nights) { night in
                    ProjectNightSection(snapshot: night)
                }
            }
            .padding(AstroTokens.Spacing.compact)
        } label: {
            Label("Project acquisition", systemImage: "rectangle.stack")
        }
        .accessibilityIdentifier("v2.projects.detail")
    }
}

private struct ProjectNightSection: View {
    let snapshot: ProjectNightSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(snapshot.night.localDate, systemImage: "moon.stars.fill")
                    .font(.headline)
                Spacer()
                Text("\(snapshot.usableFrames) usable · \(AstroFormat.duration(seconds: snapshot.integrationSeconds))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshot.series) { item in
                HStack(spacing: 10) {
                    Image(systemName: passbandIcon(item.series.passband))
                        .foregroundStyle(AstroTokens.Color.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(seriesTitle(item))
                            .font(.callout.weight(.medium))
                        Text(seriesDetail(item))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(item.usableFrames) × \(exposure(item.series.exposureSeconds))")
                        .font(.callout.monospacedDigit())
                    if item.excludedFrames > 0 {
                        Text("\(item.excludedFrames) excluded")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AstroTokens.Color.attention)
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
        .accessibilityIdentifier("v2.projects.night.\(snapshot.id.uuidString)")
    }

    private func seriesTitle(_ item: ProjectSeriesSnapshot) -> String {
        [item.series.sensorMode.rawValue.uppercased(), item.series.passband.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, item.filterName]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func seriesDetail(_ item: ProjectSeriesSnapshot) -> String {
        [item.series.setupDescriptor, "bin \(item.series.binning)", item.series.gain.map { "gain \($0.formatted())" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func exposure(_ seconds: Double) -> String {
        "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
    }

    private func passbandIcon(_ passband: SeriesPassband) -> String {
        switch passband {
        case .dualBand, .narrowband: "line.3.horizontal.decrease.circle"
        case .broadband, .unfiltered: "camera.aperture"
        default: "circle.lefthalf.filled"
        }
    }
}

public struct NewProjectView: View {
    @State private var search: String
    @State private var selectedID: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @Bindable var store: ProjectsStore
    let dismiss: () -> Void
    let didCreate: (ProjectRecord) -> Void

    public init(
        store: ProjectsStore,
        initialQuery: String = "",
        dismiss: @escaping () -> Void,
        didCreate: @escaping (ProjectRecord) -> Void = { _ in }
    ) {
        _store = Bindable(store)
        _search = State(initialValue: initialQuery)
        self.dismiss = dismiss
        self.didCreate = didCreate
    }

    private var matches: [ProjectCatalogMatch] {
        ProjectsQuery.searchCatalog(search, limit: 12)
    }

    private var selected: ProjectCatalogMatch? {
        matches.first { $0.id == selectedID }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            HStack {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.title)
                    .foregroundStyle(AstroTokens.Color.accent)
                VStack(alignment: .leading) {
                    Text("New Project").font(.title2.weight(.semibold))
                    Text("Choose the target first; AstroTool will keep its identity canonical.")
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Catalog number or target name", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("v2.new-project.search")
            if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("Find a target", systemImage: "scope")
                } description: {
                    Text("Try IC 1396, Elephant's Trunk, or Elefántormány-köd.")
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                List(matches, selection: $selectedID) { match in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(match.displayName).font(.headline)
                        HStack(spacing: 8) {
                            if let englishName = match.englishName { Text(englishName) }
                            Text(match.canonicalFolderName).font(.caption.monospaced())
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(match.id)
                }
                .frame(minHeight: 210)
            }
            if let selected {
                HStack {
                    Image(systemName: "folder.badge.plus").foregroundStyle(AstroTokens.Color.accent)
                    Text("Folder preview")
                    Spacer()
                    Text(selected.canonicalFolderName).font(.caption.monospaced()).textSelection(.enabled)
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AstroTokens.CornerRadius.panel))
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(AstroTokens.Color.critical)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Create Project") {
                    guard let selected else { return }
                    isSaving = true
                    saveError = nil
                    Task {
                        do {
                            let project = try await store.createProject(from: selected)
                            didCreate(project)
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                            isSaving = false
                        }
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || isSaving)
            }
        }
        .padding(AstroTokens.Spacing.spacious)
        .frame(minWidth: 640, minHeight: 520)
        .accessibilityIdentifier("v2.new-project")
    }
}
