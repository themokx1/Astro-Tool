import AstroApplication
import SwiftUI

public struct ProjectsView: View {
    let snapshot: LibrarySnapshot?
    @Bindable var store: ProjectsStore
    let createProject: () -> Void
    /// W3-10: the row action set's "New Session…" -- opens the shared
    /// "New Session" sheet prefilled with this row's own catalog target, the
    /// same prefill `ProjectWorkspaceView`'s header action uses for the
    /// project it has open.
    let createSession: (ProjectRecord) -> Void
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
            // W4-3a (2026-08-17 owner-feedback, second complaint): the
            // owner's own words, twice -- "a projektek oldal felső fele,
            // konkrétan white space és haszontalan infó és szöveg", then "a
            // projektek oldal fele még mindig felesleges infó". This slot
            // used to stack two metric cards (the 13 was only ever this
            // table's own row count; the 20 belonged to Nights -- neither
            // linked anywhere), a permanent "Tiszta kezdés" onboarding card
            // with two explainer bullets, a full-width search row, and a
            // lone right-aligned Rate All strip: ~45% of the viewport spent
            // before the table. Now: one action row, search left/New
            // Project/Rate All right, nothing else -- the explainer bullets
            // moved into `NewProjectView` itself (see its own doc comment),
            // since that is the one moment they are actually relevant.
            HStack(spacing: AstroTokens.Spacing.standard) {
                if !store.projects.isEmpty {
                    TextField("Search projects, catalog, filter, setup, or status", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .accessibilityIdentifier("v2.projects.search")
                        .onChange(of: searchText) { _, value in
                            Task { visibleProjects = (try? await store.search(value)) ?? [] }
                        }
                }
                Spacer()
                Button("New Project…", action: createProject)
                    .buttonStyle(.borderedProminent)
                // Task 4 (2026-08-17 owner-feedback wave 3): the owner's own
                // words -- "ezt úgy is kéne tudnom, hogy minden projektre
                // ráengedni" (run the whole-project rate across every
                // project). Page-level, not toolbar/`WorkspaceActionCenter`:
                // this page never publishes to that center at all (it is a
                // section ROOT, not a pushed workspace), so a bulk action
                // like this one has no drill-down to survive.
                if !store.projects.isEmpty {
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
            // Task 7 (2026-08-17, GroupBox removal): heading + Divider +
            // Table, `ReviewWorkspace.frameReview`'s own shape --
            // `WorkspaceTablePage` already gives this whole `table:` slot
            // one solid `AstroTokens.Color.surface` background.
            VStack(alignment: .leading, spacing: 0) {
                Text("Saved projects").font(.headline)
                    .padding(.horizontal, AstroTokens.Spacing.standard)
                    .padding(.vertical, AstroTokens.Spacing.compact)
                Divider()
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
                    // W5-2 finding 4 (owner pixel review): the real
                    // 13-project library has never set an integration goal
                    // on any project, so this column rendered "—" top to
                    // bottom for every row -- a whole column's width spent on
                    // nothing. `store.hasAnyGoal` is computed once in the
                    // store right after `workspaceRows` is (re)built (see
                    // `ProjectsStore.updateHasAnyGoal`), never re-scanned
                    // here in `body`, matching `NightsView`'s own
                    // `store.uniformVisibleTriageState == nil` precedent for
                    // a store-gated optional column just above it in this
                    // file's sibling view.
                    if store.hasAnyGoal {
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
                    }
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
        Button("New Session…") { createSession(row.project) }
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

/// `ProjectAcquisitionDetail`/`ProjectNightSection` are unreferenced by any
/// call site today -- `ProjectWorkspaceView`'s own overview/nights tabs
/// replaced this detail pane in an earlier wave (see
/// `ProjectsTableSelfSufficiencyTests.noBottomDetailStrip`, which pins that
/// this file must never construct this type again as a bottom detail strip
/// -- the owner's own "if it isn't in the list, put it in the list"
/// complaint). Kept, not deleted: `V2BetaWorkspaceSurfaceTests
/// .projectsExposeAcquisitionDetail` and
/// `V2AccessibilityIdentifierSurfaceTests.projectsNightIdentifierIsUniquePerRow`
/// still scan this file's source text for it, so removing the type outright
/// is a test-surface decision outside this task's scope, not a safe cleanup
/// -- Task 7 only owns the `GroupBox` inside it.
private struct ProjectAcquisitionDetail: View {
    let snapshot: ProjectSnapshot
    let review: () -> Void
    let results: () -> Void

    var body: some View {
        // Task 7 (2026-08-17, GroupBox removal): heading plus spacing, no
        // additional surface -- see this file's other conversions for the
        // same reasoning.
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.section) {
            Label("Project acquisition", systemImage: "rectangle.stack").font(.headline)
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
        // Task 7d (2026-08-17): was `.padding(12)` plus
        // `.background(.quaternary.opacity(0.45), in: RoundedRectangle(...))`
        // -- one of three different strengths of the same hierarchical style
        // used as a well across the app, and (like the other two) LIGHTER
        // than the surface it sat in whenever the user was in dark
        // appearance. See `astroRecessedSurface`'s own doc comment.
        .astroRecessedSurface()
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
        AstroFormat.exposureSeconds(seconds)
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
            // W4-3a (2026-08-17 owner-feedback, second complaint): moved
            // down from a permanent "Tiszta kezdés" card that used to sit
            // atop `ProjectsView` on every visit -- see that view's own doc
            // comment. This sheet's header already covers the OTHER
            // explainer ("AstroTool will keep its identity canonical" =
            // one canonical folder name, no duplicates), so only the
            // search-scope sentence moves here; repeating both would just
            // relocate the duplication instead of removing it.
            Text("Search by catalog number, English name, or Hungarian name.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                // W2-10 (2026-08-17, Liquid Glass): was a hand-rolled
                // `.regularMaterial` + `AstroTokens.CornerRadius.panel` panel
                // -- the informational strip is a single glance-and-confirm
                // row (no Table/List, no dense data), so it gets real glass
                // instead, matching `MetricCard`'s own reasoning.
                // `ConcentricRectangle` (no explicit radius) matches the
                // sheet it sits in rather than repeating the token.
                .glassEffect(.regular, in: ConcentricRectangle())
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
