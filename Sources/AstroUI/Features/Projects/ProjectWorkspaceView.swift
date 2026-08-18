import AstroApplication
import AstroCore
import SwiftUI
import UniformTypeIdentifiers

/// W4-4 item 3 (owner review): "Következő lépés ... looks like a button but
/// is dead" -- the "Next action" card's arrow icon + imperative text used to
/// render for every `ProjectNextActionKind` with no action attached at all.
/// This maps each case to exactly one of three real outcomes -- reused by
/// `ProjectWorkspaceView.nextActionAffordance` below, and unit-tested
/// directly (`ProjectNextActionAffordanceTests`) without rendering a view.
enum ProjectNextActionAffordance: Equatable {
    /// Opens the shared New Session sheet, prefilled with this project --
    /// the exact same action `header`'s own "New Session…" button already
    /// performs (`ProjectWorkspaceView.createSession`), never a second code
    /// path.
    case startSession
    /// Opens this project's own Results tab/workspace -- the exact same
    /// action `header`'s own "Results" button already performs
    /// (`ProjectWorkspaceView.results`). `.keepProcessing`'s own explanation
    /// ("Check the stacks and the results' lineage") names this
    /// destination directly.
    case viewResults
    /// W5-1: "the project is done; look at the final summary" no longer
    /// means "pick a file format and export" -- the target report is now
    /// native content on THIS SAME Overview tab (`ProjectWorkspaceView.
    /// reportSections`, below "Következő lépés" itself), so this scrolls
    /// there instead of opening the (now deleted) export menu. Replaces the
    /// former `.exportSummary` case, which pointed at the target-report
    /// export menu item -- that item no longer exists.
    case viewReport
    /// No sensible single destination -- `.archived`'s own explanation is
    /// "Nothing to do." This renders as plain text with no button chrome,
    /// never a fake affordance.
    case none

    init(_ kind: ProjectNextActionKind) {
        switch kind {
        case .planFirstNight, .startCollecting, .keepCollecting: self = .startSession
        case .keepProcessing: self = .viewResults
        case .writeFinalReport: self = .viewReport
        case .archived: self = .none
        }
    }
}

public struct ProjectWorkspaceView: View {
    let snapshot: ProjectSnapshot
    let rootURL: URL?
    let accessMode: LibraryAccessMode
    /// W3-10: opens the shared "New Session" sheet, prefilled with this
    /// project's own catalog target -- the user only picks the date.
    let createSession: () -> Void
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
    /// Task 4 (2026-08-17 owner-feedback wave 3): backs the page-level
    /// "Rate Entire Project" action in `header` below -- the owner's own
    /// words: "az egészet tudjam értékelni, az összes session összes
    /// capture, ezt úgy is kéne tudnom, hogy minden projektre ráengedni".
    @Environment(OperationHost.self) private var operationHost
    /// Wave 4 (post-20014) fix: this view's own stable identity within
    /// `WorkspaceActionCenter` -- see that type's own doc comment for why
    /// publishing is now owner-keyed rather than a per-body-pass focused
    /// value. A fresh token per view instance is exactly right here: `.id
    /// (route)` (see `DetailHost`'s own doc comment) recreates this view --
    /// and therefore this token -- every time the pushed project changes,
    /// while an in-place re-render (the SAME project, new `snapshot`
    /// content) keeps the same token/owner.
    @State private var actionOwner = UUID().uuidString
    /// W5-1: the former "Célpont-riport" HTML export's data, now rendered
    /// natively in the Áttekintés (Overview) tab (`reportSections` below)
    /// instead of generated/saved as a file -- the owner's own words: "a
    /// teljes projekt áttekintése ... az áttekintő oldalra".
    @State private var reportStore = ProjectReportStore()
    /// Lets `.viewReport` (`ProjectNextActionAffordance`) scroll the
    /// Overview tab down to `reportSections` instead of opening a (now
    /// deleted) export menu -- see that affordance case's own doc comment.
    @State private var reportScrollProxy: ScrollViewProxy?

    public init(
        snapshot: ProjectSnapshot,
        rootURL: URL? = nil,
        accessMode: LibraryAccessMode = .readOnly,
        annotation: ProjectAnnotationRecord?,
        router: AppRouter,
        createSession: @escaping () -> Void = {},
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
        self.createSession = createSession
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
                ForEach(ProjectWorkspaceTab.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AstroTokens.Spacing.spacious)
            .padding(.vertical, AstroTokens.Spacing.standard)
            .accessibilityIdentifier("v2.project.workspace.tab")
            if router.projectTab == .results {
                // `ProjectResultsPane` -> `ResultsView` raises and insets
                // itself (Task 7c), exactly as it does on the standalone
                // `.resultsWorkspace` route, so no gutter is added here.
                resultsContent
            } else if router.projectTab == .nights || router.projectTab == .series {
                // Deliberately NOT inside the `ScrollView` below, for the
                // same reason `.results` above already isn't: a `Table`
                // proposed an unbounded height cannot virtualize its rows --
                // see `WorkspaceTablePage`'s own doc comment for the same
                // fix applied to the main table-hosting workspaces.
                // Task 7c: the Nights/Series tabs are dense `Table`s, the
                // same content shape `WorkspaceTablePage` raises on its own
                // eight pages -- `.flush` so AppKit's row insets and
                // scroller reach the card edge, with the same `spacious`
                // page gutter around it as everywhere else.
                tableTabContent
                    .astroRaisedSurface(.flush)
                    .padding(AstroTokens.Spacing.spacious)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        content.padding(AstroTokens.Spacing.spacious)
                    }
                    .onAppear { reportScrollProxy = proxy }
                }
            }
        }
        // Task 4 (owner review wave 4-4, item 4): with little content (the
        // Sorozat/Series tab's 5 rows, say) this `VStack` used to be proposed
        // the whole pane's height by `DetailHost`'s `NavigationStack` but
        // never claimed it -- `header`/`Divider`/the segmented `Picker`/
        // `tableTabContent`'s own row-capped `Table` (see `tableMaxHeight`'s
        // own doc comment) together are shorter than the pane, and a
        // hugging `VStack` with no `.frame(maxHeight:)` of its own is
        // centered in whatever extra room its parent gives it -- so the
        // header rendered ~40% down the page instead of pinned to the top.
        // The Overview/Notes tabs never showed this because they wrap
        // `content` in a `ScrollView` (below), and `ScrollView` always
        // claims its full proposed height and top-aligns its content
        // regardless of how little of it there is. `alignment: .top` here
        // makes every tab behave like that ScrollView case: claim the full
        // height, start at the top, and let unused space fall below the
        // content instead of splitting it above and below.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Task 7b (2026-08-17): self-tint removed -- `V2RootView`'s detail
        // column owns the single opaque `ground` page backdrop now.
        .navigationTitle(snapshot.project.displayName)
        .accessibilityIdentifier("v2.project.workspace")
        // Task 4 (2026-08-17 owner-feedback wave 3): reverses Wave 4 Task 2's
        // "actions live only in the shell's stable toolbar" decision -- the
        // owner could not find them there ("nem tetszik hogy az akció gomb
        // ... fent van a jobb sarokban, nem a page része"). `header` below
        // now carries this page's own primary actions directly, ABOVE the
        // content they act on; the toolbar keeps its own copy (published via
        // `workspaceActions` below) since it still earns its place surviving
        // drill-down into a pushed night/series (see `WorkspaceActionCenter`'s
        // own doc comment for why that mechanism itself is being kept, just
        // no longer the ONLY place these actions render).
        // Wave 4 (post-20014) fix: published from discrete lifecycle/state-
        // change events rather than from `body` itself -- see
        // `WorkspaceActionCenter`'s own doc comment.
        .onAppear { publishWorkspaceActions() }
        .onChange(of: rootURL) { _, _ in publishWorkspaceActions() }
        .onChange(of: snapshot) { _, _ in publishWorkspaceActions() }
        .onDisappear { workspaceActionCenter.clear(owner: actionOwner) }
        .task(id: snapshot) { await reportStore.load(rootURL: rootURL, target: snapshot.canonicalFolderName) }
    }

    private func publishWorkspaceActions() {
        workspaceActionCenter.publish(owner: actionOwner, workspaceActions)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.project.displayName).font(.title2.weight(.semibold))
                Text("\(AstroFormat.duration(seconds: snapshot.integrationSeconds)) usable · \(snapshot.nights.count) nights · \(snapshot.series.count) series")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // Task 4: the page's own primary actions, right where the owner
            // expects them -- above the content they act on, not tucked away
            // in the corner toolbar.
            HStack(spacing: 8) {
                Button(action: createSession) {
                    Label("New Session…", systemImage: "moon.stars")
                }
                .help("Create a new session for this project — you only pick the date")
                .accessibilityIdentifier("v2.project.page.new-session")

                Button(action: review) {
                    Label("Review Frames", systemImage: "checkmark.rectangle.stack")
                }
                .help("Open the frame-by-frame review workspace for this project")
                .accessibilityIdentifier("v2.project.page.review")

                Button(action: results) {
                    Label("Results", systemImage: "square.stack.3d.up")
                }
                .help("Inspect stacks, processed variants, and their provenance")
                .accessibilityIdentifier("v2.project.page.results")

                Button(action: rateEntireProject) {
                    Label("Rate Entire Project", systemImage: "star.leadinghalf.filled")
                }
                .help("Measure quality for every night and series in this project")
                .accessibilityIdentifier("v2.project.page.rate")
            }
            .buttonStyle(.bordered)
        }
        .padding(AstroTokens.Spacing.spacious)
    }

    /// Task 4: rates every night/series of this ONE project -- reuses
    /// `ProjectRatingRunner` (itself a thin batching layer over
    /// `FrameRatingCommand`, the same engine `ReviewStore.rateSelectedSeries`/
    /// `NightActionMenu.rateFrames` already use), reporting progress/
    /// cancellation through the shared `operationHost` exactly like every
    /// other long-running V2 operation.
    private func rateEntireProject() {
        guard let rootURL else { return }
        Task {
            await ProjectRatingRunner.run(
                scope: .project(id: snapshot.project.id, displayName: snapshot.project.displayName),
                rootURL: rootURL,
                metadataFactory: ProjectsStore.productionMetadata,
                operationHost: operationHost
            )
        }
    }

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions([
            .exportMenu(WorkspaceActionExportMenu(
                id: "v2.project.export", items: projectExportItems, accessibilityID: "v2.project.export"
            )),
            .button(WorkspaceAction(
                id: "v2.project.new-session",
                title: "New Session…",
                systemImage: "moon.stars",
                help: "Create a new session for this project — you only pick the date",
                action: createSession
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
            .button(WorkspaceAction(
                id: "v2.project.rate",
                title: "Rate Entire Project",
                systemImage: "star.leadinghalf.filled",
                help: "Measure quality for every night and series in this project",
                action: rateEntireProject
            )),
        ])
    }

    /// W5-1 (owner: "tünjenek el az exportálás file-ba gombok"): the
    /// generic per-session CSV/Markdown acquisition formats and the target
    /// report menu item are gone -- all three were human-readable
    /// SUMMARIES (the CSV's own doc comment: "a richer, generic per-session
    /// CSV"; the Markdown's: "a human-readable Markdown session log"), the
    /// same report-shaped content this ticket moves in-app (`reportSections`
    /// below already shows every session's frames/camera/gain/temp/focal
    /// length/filters/quality that CSV/Markdown carried). The AstroBin
    /// bulk-import CSV format stays -- it is not a report a person reads,
    /// it is a bulk-import file format for a SPECIFIC external tool
    /// (AstroBin), the same "hands off to other software" role `stackList`
    /// has for Siril, explicitly kept in scope. `[]` when no library is
    /// open at all (`rootURL == nil`, never true once a project workspace
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
            ProjectResultsPane(rootURL: rootURL, project: snapshot.project, review: review)
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
                // Task 7 (2026-08-17, GroupBox removal): `GroupBox`'s
                // opaque grey panel is gone for good. Task 7c gives the
                // block back a presence through the one shared raised
                // surface -- the MetricCards above it stay glass, since
                // glass and the raised layer are alternatives, not layers.
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                    Text("Next action").font(.headline)
                    nextActionAffordance
                    Text(snapshot.nextAction.kind.explanationKey).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .astroRaisedSurface()
                reportSections
                    .id(Self.reportSectionAnchorID)
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
                // Task 7 (2026-08-17, GroupBox removal): a standard `Form`/
                // `Section` in place of two `GroupBox`es -- `FrameInspector`'s
                // own `Form { Section("Frame") { LabeledContent(...) } }`
                // shape is the precedent for the label/value row, and a
                // `Section` holds the notes editor exactly as well as a
                // `GroupBox` did, without a second opaque background.
                Form {
                    Section("Acquisition goal") {
                        LabeledContent("Integration goal") {
                            HStack(spacing: 6) {
                                TextField("Hours", value: $goalHours, format: .number.precision(.fractionLength(0...1)))
                                    .frame(width: 90)
                                Text("hours").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Project notes") {
                        TextEditor(text: $projectNotes)
                            .font(.body)
                            .frame(minHeight: 180)
                    }
                }
                .formStyle(.grouped)
                if let saveError { Text(saveError).foregroundStyle(AstroTokens.Color.critical) }
                HStack {
                    // W3-9: `.map { "…" } ?? "Not saved yet"` infers `String`
                    // (the `??` right-hand side forces it), so `Text(String)`
                    // always chose the verbatim overload -- wrapping in
                    // `LocalizedStringKey(...)` is the same fix
                    // `NightsView`'s `darkHours`/`bestTargets` columns use.
                    Text(LocalizedStringKey(
                        annotation.map { "Last saved \($0.updatedAt.formatted(date: .abbreviated, time: .shortened))" } ?? "Not saved yet"
                    ))
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

    /// Task 3 (owner review wave 4-4): the "Next action" card's own control
    /// -- each `ProjectNextActionAffordance` case reuses one of this view's
    /// OWN existing closures (`createSession`/`results`, the same ones
    /// `header`'s buttons already call, or the export items `header`'s own
    /// export menu already builds), never a second, parallel code path.
    /// `.none` renders `Label` with no button chrome at all, so the card
    /// never promises an action it cannot perform.
    @ViewBuilder
    private var nextActionAffordance: some View {
        switch ProjectNextActionAffordance(snapshot.nextAction.kind) {
        case .startSession:
            Button(action: createSession) {
                Label(snapshot.nextAction.kind.titleKey, systemImage: "arrow.forward.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("v2.project.next-action")
        case .viewResults:
            Button(action: results) {
                Label(snapshot.nextAction.kind.titleKey, systemImage: "arrow.forward.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("v2.project.next-action")
        case .viewReport:
            // W5-1: scrolls down to `reportSections` (this same Overview
            // tab, below this very card) instead of opening the deleted
            // target-report export menu item.
            Button {
                withAnimation { reportScrollProxy?.scrollTo(Self.reportSectionAnchorID, anchor: .top) }
            } label: {
                Label(snapshot.nextAction.kind.titleKey, systemImage: "arrow.forward.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("v2.project.next-action")
        case .none:
            Label(snapshot.nextAction.kind.titleKey, systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("v2.project.next-action")
        }
    }

    // MARK: - Report sections (W5-1)
    //
    // The former "Célpont-riport" HTML export's own sections, now rendered
    // natively here instead of generated/saved as a file -- assembled by
    // `ProjectReportQuery` (`AstroApplication`), the exact same `AstroCore`
    // queries `TargetReport.render`'s HTML path itself calls. The per-night
    // table here is genuinely new -- the Nights tab's own `Table` has no
    // room for exposure/camera/gain/temp/flags columns without breaking the
    // "no Table/List in a ScrollView" rule, so this uses `Grid` instead
    // (small row counts, no virtualization needed -- see `ReportGrid`'s own
    // doc comment).

    static let reportSectionAnchorID = "v2.project.report-section"

    @ViewBuilder private var reportSections: some View {
        if reportStore.isLoading, reportStore.result == nil {
            ProgressView().frame(maxWidth: .infinity, alignment: .center)
        } else if let message = reportStore.errorMessage {
            ReportEmptyNote(text: LocalizedStringKey(message))
        } else if let report = reportStore.result {
            ReportSection(title: "Target Details") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    if let coordinateInfo = report.coordinateInfo {
                        ReportStatGrid(items: [
                            ("RA", AstroFormat.rightAscension(coordinateInfo.raDeg)),
                            ("Dec", AstroFormat.declination(coordinateInfo.decDeg)),
                            ("Coordinate Source", coordinateInfo.sourceLabel),
                        ])
                    } else {
                        ReportEmptyNote(text: "No plate-solve/header coordinate for this target.")
                    }
                    if !report.setupDescriptors.isEmpty {
                        Text("Setup: \(report.setupDescriptors.joined(separator: "; "))").font(.callout)
                    }
                    if report.stat.isWideField || !report.stat.tags.isEmpty {
                        HStack(spacing: 6) {
                            if report.stat.isWideField { reportBadge("Wide-field", ok: true) }
                            ForEach(report.stat.tags, id: \.self) { tag in
                                reportBadge(LocalizedStringKey(tag), ok: !tag.lowercased().hasPrefix("goal:"))
                            }
                        }
                    }
                }
            }
            ReportSection(title: "Filters") {
                if report.filterRows.isEmpty {
                    ReportEmptyNote(text: "No usable filter data for this target.")
                } else {
                    ReportGrid(headers: ["Filter", "Frames", "Integration", "Goal", "Missing"]) {
                        ForEach(report.filterRows.sorted(by: { $0.filter.localizedCaseInsensitiveCompare($1.filter) == .orderedAscending }), id: \.filter) { row in
                            GridRow {
                                Text(LocalizedStringKey(row.filter))
                                Text(row.usableFrameCount.formatted()).monospacedDigit()
                                Text(AstroFormat.duration(seconds: row.integrationSeconds)).monospacedDigit()
                                Text(row.goalSeconds.map(AstroFormat.duration(seconds:)) ?? "n/a").monospacedDigit()
                                Text(row.missingSeconds.map(AstroFormat.duration(seconds:)) ?? "n/a").monospacedDigit()
                            }
                        }
                    }
                }
            }
            ReportSection(title: "Sessions") {
                if report.sessions.isEmpty {
                    ReportEmptyNote(text: "No recorded session for this target.")
                } else {
                    ReportGrid(headers: ["Date", "Frames", "Integration", "Camera", "Focal Length", "Gain", "Temp", "Filter", "Flags"]) {
                        ForEach(report.sessions.sorted(by: { $0.session.dateRaw < $1.session.dateRaw })) { row in
                            GridRow {
                                Text(row.session.dateRaw).monospacedDigit()
                                Text(row.session.usableLightCount.formatted()).monospacedDigit()
                                Text(AstroFormat.duration(seconds: row.session.integrationSeconds)).monospacedDigit()
                                Text(row.session.cameras.joined(separator: "/"))
                                Text(formatDoubleList(row.session.focalLengthsMM, suffix: "mm"))
                                Text(formatDoubleList(row.session.gains, suffix: ""))
                                Text(formatDoubleList(row.session.sensorTempsC, suffix: "°C"))
                                Text(row.session.filters.joined(separator: "/"))
                                Text(sessionFlags(row.session))
                            }
                        }
                    }
                }
            }
            ReportSection(title: "Quality") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    let rated = report.qualitySummaries.filter { $0.frameCount > 0 }
                    if rated.isEmpty {
                        ReportEmptyNote(text: "No rated frames for this target.")
                    } else {
                        ReportGrid(headers: ["Date", "FWHM", "Background", "Stars", "Outliers", "Rank"]) {
                            ForEach(rated.sorted(by: { $0.date < $1.date }), id: \.date) { summary in
                                GridRow {
                                    Text(summary.date).monospacedDigit()
                                    Text(fwhmText(summary))
                                    Text(summary.backgroundEPerSecPerArcsec2.map(AstroFormat.backgroundEPerSecArcsec2) ?? "n/a")
                                    Text(summary.medianStarCount.map { "\($0)" } ?? "–")
                                    Text(summary.outlierFraction.map { AstroFormat.percent($0 * 100) } ?? "–")
                                    Text(rankText(summary))
                                }
                            }
                        }
                    }
                    if let reason = report.advice.notAvailableReason {
                        Text("Exposure advice: n/a — \(reason)").font(.callout).foregroundStyle(.secondary)
                    } else if !report.advice.advice.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(report.advice.advice, id: \.self) { line in
                                Text("• \(line)").font(.callout)
                            }
                        }
                    }
                }
            }
            ReportSection(title: "Stacks") {
                if report.stacks.isEmpty {
                    ReportEmptyNote(text: "No discovered stack file for this target.")
                } else {
                    ReportGrid(headers: ["File", "Location", "Frames×Sub", "Total", "Size", "Date"]) {
                        ForEach(report.stacks, id: \.path) { stack in
                            GridRow {
                                Text((stack.path as NSString).lastPathComponent).lineLimit(1)
                                Text((stack.path as NSString).deletingLastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                                Text(framesSubText(stack))
                                Text(stack.totalSecondsFromName.map(AstroFormat.duration(seconds:)) ?? "–")
                                Text(AstroFormat.bytes(stack.sizeBytes))
                                Text(stack.sessionDate ?? "–").monospacedDigit()
                            }
                        }
                    }
                }
            }
            ReportSection(title: "Calibration") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    // Wave W6-A section D: mirrors the Sessions section
                    // above -- calibration is keyed off the same
                    // `report.sessions` list, so an empty one used to render
                    // this grid as a bare header with nothing underneath it.
                    if report.sessions.isEmpty {
                        ReportEmptyNote(text: "No recorded session, so no calibration data for this target.")
                    } else {
                        ReportGrid(headers: ["Date", "Flat", "Dark", "Bias", "Problems"]) {
                            ForEach(report.sessions.sorted(by: { $0.session.dateRaw < $1.session.dateRaw })) { row in
                                GridRow {
                                    Text(row.session.dateRaw).monospacedDigit()
                                    Text(row.calibration.flats.count.formatted()).monospacedDigit()
                                    Text(darkText(row.calibration)).monospacedDigit()
                                    Text(row.calibration.biases.count.formatted()).monospacedDigit()
                                    Text(row.calibration.problems.isEmpty ? "–" : row.calibration.problems.map(\.message).joined(separator: "; "))
                                }
                            }
                        }
                    }
                    if !report.targetFlats.isEmpty {
                        Text("Flat Hygiene").font(.subheadline.weight(.medium))
                        ReportGrid(headers: ["Date", "Status", "Notes"]) {
                            ForEach(report.targetFlats.sorted(by: { $0.date < $1.date }), id: \.date) { flat in
                                GridRow {
                                    Text(flat.date).monospacedDigit()
                                    Text(flat.status)
                                    Text(flat.reasons.joined(separator: "; "))
                                }
                            }
                        }
                    }
                }
            }
            if report.panelReport.isMosaic {
                ReportSection(title: "Panels") {
                    ReportGrid(headers: ["Panel", "Center (RA/Dec)", "Frames", "Integration", "Rotation"]) {
                        ForEach(report.panelReport.panels, id: \.label) { panel in
                            GridRow {
                                Text(panel.label)
                                Text("\(AstroFormat.rightAscension(panel.centerRaDeg)) / \(AstroFormat.declination(panel.centerDecDeg))")
                                Text(panel.frameCount.formatted()).monospacedDigit()
                                Text(AstroFormat.duration(seconds: panel.integrationSeconds)).monospacedDigit()
                                Text(panel.rotationDeg.map(AstroFormat.rotationDegrees) ?? "–")
                            }
                        }
                    }
                    if report.panelReport.isUnbalanced {
                        Text("Unbalanced integration across panels.").font(.callout).foregroundStyle(AstroTokens.Color.attention)
                    }
                }
            }
            ReportSection(title: "Planning") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.standard) {
                    if let plan = report.plan {
                        ReportStatGrid(items: planningStatItems(plan))
                    } else {
                        ReportEmptyNote(text: "No plan data for this target.")
                    }
                    if let goalSeconds = report.projectState?.goalSeconds {
                        goalProgressText(report: report, goalSeconds: goalSeconds)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reportBadge(_ text: LocalizedStringKey, ok: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((ok ? AstroTokens.Color.ok : AstroTokens.Color.attention).opacity(0.18), in: Capsule())
            .foregroundStyle(ok ? AstroTokens.Color.ok : AstroTokens.Color.attention)
    }

    private func sessionFlags(_ session: SessionDetail) -> String {
        var flags: [String] = []
        if session.hasReadme { flags.append("README") }
        if let accepted = session.dssAcceptedCount, let rejected = session.dssRejectedCount {
            flags.append("DSS \(accepted)/\(rejected)")
        }
        if session.isExcludedFromTotals { flags.append("EXCLUDED") }
        return flags.isEmpty ? "–" : flags.joined(separator: ", ")
    }

    private func fwhmText(_ summary: SessionQualitySummary) -> String {
        if let arcsec = summary.medianFWHMArcsec { return AstroFormat.fwhmArcsec(arcsec) }
        if let px = summary.medianFWHMPixels { return AstroFormat.fwhmPixels(px) }
        return "n/a"
    }

    private func rankText(_ summary: SessionQualitySummary) -> String {
        guard let rank = summary.rankAmongSessions, let total = summary.sessionCountForTarget else { return "–" }
        return "\(rank) / \(total)"
    }

    private func darkText(_ calibration: SessionCalibration) -> String {
        if calibration.darks.isEmpty, let libraryDark = calibration.libraryDark {
            return "library: \((libraryDark as NSString).lastPathComponent)"
        }
        return "\(calibration.darks.count)"
    }

    private func framesSubText(_ stack: StackFile) -> String {
        guard let frames = stack.framesFromName, let sub = stack.subSecondsFromName else { return "n/a" }
        return "\(frames)×\(AstroFormat.coefficient(sub))s"
    }

    private func formatDoubleList(_ values: [Double], suffix: String) -> String {
        guard !values.isEmpty else { return "–" }
        return values.map { AstroFormat.coefficient($0) + suffix }.joined(separator: "/")
    }

    private func planningStatItems(_ plan: TargetPlan) -> [(LocalizedStringKey, String)] {
        var items: [(LocalizedStringKey, String)] = [("Verdict", plan.verdict)]
        if let window = plan.visibleWindowLocal { items.append(("Visible Window", window)) }
        if let maxAlt = plan.maxAltitudeDeg { items.append(("Max. Altitude", AstroFormat.wholeDegrees(maxAlt))) }
        if let culmination = plan.culminationLocal { items.append(("Culmination", culmination)) }
        if let illum = plan.moonIlluminationPercent { items.append(("Moon Illumination", AstroFormat.percent(illum))) }
        if let sep = plan.moonSeparationDeg { items.append(("Moon Separation", AstroFormat.wholeDegrees(sep))) }
        return items
    }

    /// A `Text`, not a `String`-returning helper: the sentence's own words
    /// ("Goal"/"remaining"/"reached") need translation, and only a string
    /// INTERPOLATION LITERAL written directly at a `Text(_:)` call site
    /// resolves to the `LocalizedStringKey` overload -- building the
    /// sentence as a `String` first and handing it to `Text(_:)` would
    /// route through the verbatim overload instead, the exact "seven
    /// separate, individually-fixed instances" defect class this app's own
    /// gates exist to catch (see `V2PolishSurfaceTests`'s doc comment).
    @ViewBuilder
    private func goalProgressText(report: ProjectReportQuery.Result, goalSeconds: Double) -> some View {
        let goalText = AstroFormat.duration(seconds: goalSeconds)
        if let missing = report.projectState?.missingSeconds, missing > 0 {
            Text("Goal: \(goalText) — \(AstroFormat.duration(seconds: missing)) remaining")
        } else {
            Text("Goal: \(goalText) — reached")
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
            // Task 5 (2026-08-17 owner-feedback wave 3): the owner's own
            // words -- "a nighs ... oldalak butucskák, pár infó van csak
            // kint" (the Nights tab is dumb, only a little info is out).
            // This is the exact signal the top-level Nights table already
            // shows (`NightsView.observedNightsTable`'s own "Triage"
            // column) -- which nights still need morning review -- so a
            // project's own Nights tab reads the same at a glance instead
            // of making the reader open every night to find out.
            TableColumn("Triage") { night in
                let state = triageState(for: night)
                Label(state.displayLabel, systemImage: state == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(state == .ready ? AstroTokens.Color.ok : AstroTokens.Color.attention)
            }
            .width(min: 110, ideal: 125)
            // Task 5: a visible row action, not only the right-click menu --
            // built from the SAME `nightActionMenu(for:)` function the
            // context menu below calls, per Task 5b's "one set, not two"
            // convention (see `ProjectsView.projectRowActions`'s own doc
            // comment for the fuller rationale).
            TableColumn("") { night in
                Menu {
                    nightActionMenu(for: night)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
                .accessibilityIdentifier("v2.projects.night-actions.\(night.id.uuidString)")
            }
            .width(40)
        }
        // W3-9: was `.frame(maxWidth: .infinity, maxHeight: .infinity)` --
        // see `tableMaxHeight`'s own doc comment for why an unbounded
        // height painted 2-5 real rows followed by ~20 empty alternating
        // stripes down to the bottom of the page.
        .frame(maxWidth: .infinity, maxHeight: tableMaxHeight(rowCount: sortedNights.count))
        .onChange(of: sortOrder) { _, _ in recomputeSortedNights() }
        .task(id: snapshot) { recomputeSortedNights() }
        .contextMenu(forSelectionType: UUID.self) { nightIDs in
            if let id = nightIDs.first, let night = snapshot.nights.first(where: { $0.id == id }) {
                nightActionMenu(for: night)
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

    /// The ONE place this row's action set is declared -- both the row's
    /// "..." overflow menu and its right-click context menu build from this
    /// same function (Task 5b's convention, applied here too).
    @ViewBuilder
    private func nightActionMenu(for night: ProjectNightSnapshot) -> some View {
        NightActionMenu(
            target: snapshot.canonicalFolderName,
            date: night.night.localDate,
            setupDescriptor: night.series.first?.series.setupDescriptor,
            nightID: night.id,
            rootURL: rootURL,
            openNight: { openNight(night.id) },
            editNotes: {
                noteEditorTarget = NightNoteEditingTarget(
                    target: snapshot.canonicalFolderName, date: night.night.localDate
                )
            },
            openCalibration: openCalibration,
            openInsights: openInsights
        )
    }

    /// Same business rule `NightRow.triageState`'s own doc comment defines
    /// (a night needs review only while frames are still `.undecided`, not
    /// merely because some were rejected) -- reuses `NightRow.TriageState`
    /// itself rather than a second, parallel enum, applied here to
    /// `ProjectNightSnapshot` instead of `NightSnapshot`.
    private func triageState(for night: ProjectNightSnapshot) -> NightRow.TriageState {
        if night.usableFrames == 0 { return .empty }
        return night.undecidedFrames > 0 ? .needsReview : .ready
    }

    private func recomputeSortedNights() {
        var rows = snapshot.nights
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        sortedNights = rows
    }
}

/// Task 5 (2026-08-17 owner-feedback wave 3): `ProjectSeriesSnapshot` itself
/// carries no night reference (it is nested UNDER `ProjectNightSnapshot` in
/// `AstroApplication`'s own model) -- flattening `snapshot.nights.flatMap
/// (\.series)` the way this view used to therefore lost which night each
/// series belonged to. For a project with more than one night, two series
/// under the same filter/exposure became indistinguishable, which was
/// exactly the owner's complaint ("a ... seris oldalak butucskák, pár infó
/// van csak kint" -- the Series tab is dumb, only a little info is out).
/// This row wrapper carries the night's date alongside its series purely at
/// the view layer, the same way `ProjectWorkspaceRow` wraps engine data for
/// `ProjectsView` -- no change needed to the `AstroApplication` model.
private struct ProjectSeriesRow: Identifiable, Equatable {
    let nightDate: String
    let series: ProjectSeriesSnapshot
    var id: UUID { series.id }
}

private struct ProjectSeriesSummary: View {
    let snapshot: ProjectSnapshot
    let openSeries: (UUID) -> Void
    @State private var selection: UUID?
    /// Small local array (see `ProjectNightsSummary.sortOrder`'s own doc
    /// comment for why this is cached in `@State` rather than a store).
    /// Default is filter name ascending.
    @State private var sortOrder: [KeyPathComparator<ProjectSeriesRow>] = [
        KeyPathComparator(\ProjectSeriesRow.series.filterSortKey, order: .forward)
    ]
    @State private var sortedSeries: [ProjectSeriesRow] = []

    var body: some View {
        Table(sortedSeries, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Night", value: \ProjectSeriesRow.nightDate) { Text($0.nightDate).monospacedDigit() }
                .width(min: 85, ideal: 100)
            // Same `LocalizedStringKey(...)`-wrapped fallback as
            // `NightWorkspaceView`'s own Filter column -- `filterName` is
            // arbitrary FITS/user data, so only the "Unfiltered" fallback
            // needs (and gets) a `hu.lproj` entry.
            TableColumn("Filter", value: \ProjectSeriesRow.series.filterSortKey) { Text(LocalizedStringKey($0.series.filterName ?? "Unfiltered")) }
            TableColumn("Exposure", value: \ProjectSeriesRow.series.series.exposureSeconds) { Text("\($0.series.series.exposureSeconds.formatted()) s").monospacedDigit() }
            TableColumn("Setup", value: \ProjectSeriesRow.series.series.setupDescriptor) { Text($0.series.series.setupDescriptor).lineLimit(1) }
            TableColumn("Frames", value: \ProjectSeriesRow.series.usableFrames) { Text("\($0.series.usableFrames) / \($0.series.excludedFrames)").monospacedDigit() }
            // Task 5: a visible row action, not only the right-click menu --
            // built from the SAME `seriesActionMenu(for:)` function the
            // context menu below calls (Task 5b's "one set, not two"
            // convention -- see `ProjectsView.projectRowActions`'s own doc
            // comment for the fuller rationale). Only one action exists
            // today, but the menu (not a bare icon button) is what keeps
            // this row and its context menu from drifting apart the moment
            // a second one is added.
            TableColumn("") { row in
                Menu {
                    seriesActionMenu(for: row)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
                .accessibilityIdentifier("v2.projects.series-actions.\(row.id.uuidString)")
            }
            .width(40)
        }
        // W3-9: same fix as `ProjectNightsSummary`'s Table above.
        .frame(maxWidth: .infinity, maxHeight: tableMaxHeight(rowCount: sortedSeries.count))
        .onChange(of: sortOrder) { _, _ in recomputeSortedSeries() }
        .task(id: snapshot) { recomputeSortedSeries() }
        .contextMenu(forSelectionType: UUID.self) { seriesIDs in
            if let id = seriesIDs.first, let row = sortedSeries.first(where: { $0.id == id }) {
                seriesActionMenu(for: row)
            }
        } primaryAction: { seriesIDs in
            if let id = seriesIDs.first { openSeries(id) }
        }
    }

    /// The ONE place this row's action set is declared -- both the row's
    /// "..." overflow menu and its right-click context menu build from this
    /// same function (Task 5b's convention, applied here too).
    @ViewBuilder
    private func seriesActionMenu(for row: ProjectSeriesRow) -> some View {
        Button("Open Series") { openSeries(row.id) }
    }

    private func recomputeSortedSeries() {
        var rows = snapshot.nights.flatMap { night in
            night.series.map { ProjectSeriesRow(nightDate: night.night.localDate, series: $0) }
        }
        if !sortOrder.isEmpty { rows.sort(using: sortOrder) }
        sortedSeries = rows
    }
}
