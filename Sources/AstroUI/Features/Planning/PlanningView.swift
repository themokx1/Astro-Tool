import AstroApplication
import AstroCore
import SwiftUI

public struct PlanningView: View {
    @State private var store = PlanningStore()
    @State private var savedTargetsStore = SavedTargetsStore()
    /// Downloads the extended catalog once on first launch (the toggle is on
    /// by default). Its `init` is deliberately side-effect free; the cache
    /// read and any fetch happen from `.task` below.
    @State private var catalogUpdate = ExtendedCatalogUpdateStore()
    @AppStorage("v2.settings.extended-catalog") private var extendedCatalogEnabled = true
    @State private var selectedTargetID: String?
    /// Mirrors `PlanningStore.sortOrder`. The table needs a `Binding`, but the
    /// actual re-sorting happens in the store's cached recompute — never in
    /// `body`, where sorting the whole catalog every layout pass is exactly
    /// what froze this page before.
    @State private var sortOrder: [KeyPathComparator<PlanningRecommendation>] = [
        KeyPathComparator(\PlanningRecommendation.planningScore, order: .reverse)
    ]
    /// Task 4: the note sheet's target -- set by either the selected row's
    /// inline "Note…" action or (indirectly) reused by `SavedTargetsView`
    /// itself, which owns its own instance of the same sheet.
    @State private var editingNoteFor: PlanningRecommendation?
    let rootURL: URL?
    let createProject: (String) -> Void
    let openSavedTargets: () -> Void
    /// Wave W6-A section B: the no-library placeholder below used to be a
    /// dead end -- no button at all -- unlike `ArchiveView`/`HealthView`'s
    /// own "no library" states, which both already thread a `chooseLibrary`
    /// closure down from `V2RootView`. Defaults to a no-op so existing
    /// previews/tests that never reach that branch don't need to supply one.
    let chooseLibrary: () -> Void
    /// Wave W6-A section B: the no-site placeholder's own escape hatch --
    /// `V2RootView`'s own `openSettings` calls use the identical
    /// `@Environment(\.openSettings)` pattern everywhere else a placeholder
    /// points at Settings.
    @Environment(\.openSettings) private var openSettings

    public init(
        rootURL: URL?,
        createProject: @escaping (String) -> Void,
        openSavedTargets: @escaping () -> Void = {},
        chooseLibrary: @escaping () -> Void = {}
    ) {
        self.rootURL = rootURL
        self.createProject = createProject
        self.openSavedTargets = openSavedTargets
        self.chooseLibrary = chooseLibrary
    }

    public var body: some View {
        WorkspaceTablePage(
            subtitle: "Choose a setup first, then compare honest framing and integration estimates."
        ) {
            setupBar
            baselineCard
            filterBar
        } table: {
            recommendationList
        } footer: {
            skyPathSection
        }
        .navigationTitle("Planning")
        .accessibilityLabel("Planning")
        .accessibilityIdentifier("v2.detail.planning")
        .task { store.activate() }
        .task {
            // First launch: fetch the catalog, then re-rank so the wider list
            // is what the user actually sees. A failure leaves the built-in
            // catalog in place and surfaces in Settings.
            let before = catalogUpdate.cachedTargetCount
            await catalogUpdate.startUpdateIfNeeded(isEnabled: extendedCatalogEnabled)
            if catalogUpdate.cachedTargetCount != before { store.refresh() }
        }
        .task(id: rootURL) { store.setRootURL(rootURL) }
        .task(id: rootURL) { await savedTargetsStore.setRootURL(rootURL) }
        .onChange(of: sortOrder) { _, newValue in store.setSortOrder(newValue) }
        .onChange(of: selectedTargetID) { _, newValue in
            let target = newValue.flatMap { id in store.filteredRecommendations.first(where: { $0.id == id })?.target }
            store.selectTarget(target)
        }
        .sheet(item: $editingNoteFor) { row in
            SavedTargetNoteSheet(
                designation: row.target.designation,
                initialNote: savedTargetsStore.note(for: row.target.designation) ?? "",
                save: { newNote in
                    Task {
                        await savedTargetsStore.save(designation: row.target.designation, note: newNote)
                        editingNoteFor = nil
                    }
                },
                cancel: { editingNoteFor = nil }
            )
        }
    }

    private var selectedRow: PlanningRecommendation? {
        guard let selectedTargetID else { return nil }
        return store.filteredRecommendations.first { $0.id == selectedTargetID }
    }

    /// Backs the "Camera and optics" header's ⓘ button.
    private static let setupMetricInfo: [MetricInfoButton.Metric] = [
        .init(title: "Field of view (FOV)", explanation: "The area of sky your sensor and optics cover, in degrees wide by degrees tall.", glossaryTerm: "Field of view (FOV) / framing fit"),
        .init(title: "Focal length", explanation: "The optical system's focal length in millimeters. A longer focal length gives a narrower, more magnified field of view."),
        .init(title: "Integration", explanation: "The estimated total exposure time needed for a clean result at this setup's framing and sky conditions. Uses this library's own measured sky background when enough sessions are on record, otherwise an assumed μ=21 sky -- the caption under each estimate says which.", glossaryTerm: "Integration (gross vs. real)"),
    ]

    private var setupBar: some View {
        // Task 7 (2026-08-17, GroupBox removal): a heading plus spacing --
        // this sits inside the toolbar slot, which already floats on its
        // own glass bar (`WorkspaceTablePage.body`), so no additional
        // surface belongs here.
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Camera and optics").font(.headline)
                MetricInfoButton(metrics: Self.setupMetricInfo)
            }
            HStack {
                Picker("Setup", selection: $store.selectedSetupID) {
                    ForEach(store.setups) { setup in Text(setup.name).tag(setup.id) }
                }
                .accessibilityIdentifier("v2.planning.setup")
                Spacer()
                if let fov = store.fieldOfView {
                    Text("\(fov.widthDeg, format: .number.precision(.fractionLength(1)))° × \(fov.heightDeg, format: .number.precision(.fractionLength(1)))°")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if store.selectedSetup.isZoom {
                HStack {
                    Text("\(store.selectedSetup.focalLengthMinMM, format: .number) mm").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { store.focalLength },
                            set: { value in store.setFocalLength(value) }
                        ),
                        in: store.selectedSetup.focalLengthMinMM...store.selectedSetup.focalLengthMaxMM,
                        step: 1
                    )
                    Text("\(store.focalLength, format: .number.precision(.fractionLength(0))) mm")
                        .monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                .accessibilityIdentifier("v2.planning.focal-length")
            }
        }
    }

    private var baselineCard: some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            MetricCard(
                title: "Reference",
                // W6-C: was a hand-rolled decimal ("8.5 h") that read as a
                // second truth next to every other duration in the app's
                // own "H:MM h" style (`AstroFormat.duration`) -- this is a
                // pure display of `IntegrationTimeModel.referenceHours`, not
                // an editable draft field, so there is no round-trip-parsing
                // reason (unlike `SiteSettingsStore`'s own exemption) to keep
                // it decimal.
                value: AstroFormat.duration(seconds: store.referenceHours * 3600),
                detail: "f/\(store.referenceFocalRatio.formatted(.number.precision(.fractionLength(0...1)))) · μ \(store.referenceSurfaceBrightness.formatted(.number.precision(.fractionLength(0...1))))",
                systemImage: "timer"
            )
            MetricCard(
                title: "Focal length", value: "\(store.focalLength.formatted(.number.precision(.fractionLength(0)))) mm",
                detail: LocalizedStringKey(store.selectedSetup.cameraName), systemImage: "camera.aperture"
            )
            MetricCard(
                title: "Useful matches", value: "\(store.filteredRecommendations.count)",
                detail: "Tiny targets ranked lower", systemImage: "scope"
            )
        }
        .accessibilityIdentifier("v2.planning.integration")
    }

    /// The planner's fixed filter and action bar. It lives in
    /// `WorkspaceTablePage`'s non-scrolling toolbar slot, so it stays put
    /// while the target table scrolls underneath it.
    ///
    /// W4-3b (owner's second Projects complaint, same disease here): this
    /// used to be one undifferentiated band -- date + "Today" + two
    /// checkboxes + search field + four buttons, filters and actions
    /// interleaved in no particular order. Regrouped WITHOUT changing any
    /// behavior: filters/inputs (date, search, the two checkboxes) now read
    /// left to right on one line, actions (Plan Project primary, Save
    /// Target, Note…) sit right-aligned on the line below, and "Saved
    /// Targets" -- the one control here that navigates away rather than
    /// acting on the selected row -- is set off after its own `Divider`
    /// instead of blending into the action cluster. The cloud indicator
    /// (W4-2, a sibling's work) stays exactly where it already was, next to
    /// the date it describes.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            HStack(spacing: AstroTokens.Spacing.standard) {
                DatePicker(
                    "Night",
                    selection: Binding(
                        get: { store.planningDate ?? Date() },
                        set: { store.setPlanningDate($0) }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.field)
                .fixedSize()
                .accessibilityIdentifier("v2.planning.date")
                .help("Plan for a different night. Ranking is computed for that night's sky.")

                Button("Today") { store.setPlanningDate(Date()) }
                    .disabled(store.isPlanningToday())
                    .accessibilityIdentifier("v2.planning.today")
                    .help("Go back to planning for tonight.")

                cloudIndicator

                TextField("Catalog number, English or Hungarian name", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("v2.planning.search")

                // The two filter checkboxes used to sit loose in the band,
                // one per row -- grouped into one compact `Menu` so this
                // filter row reads as "date, search, filters", not a wall of
                // individual controls.
                Menu {
                    Toggle(
                        "Hide targets that aren't photographable",
                        isOn: Binding(
                            get: { !store.showLowAltitudeTargets },
                            set: { store.showLowAltitudeTargets = !$0 }
                        )
                    )
                    .accessibilityIdentifier("v2.planning.hide-unobservable")
                    .help("Targets that never clear the imaging altitude on the chosen night.")
                    Toggle("Useful framing only", isOn: $store.usefulFramingOnly)
                        .accessibilityIdentifier("v2.planning.useful-framing-only")
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("v2.planning.filters-menu")

                Spacer()
            }
            HStack(spacing: AstroTokens.Spacing.standard) {
                Spacer()
                Button("Plan Project") { planSelectedTarget() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTargetID == nil)
                    .accessibilityIdentifier("v2.planning.plan-project")
                    .help("Create a project for the selected target.")
                saveTargetButton
                noteButton
                Divider().frame(height: 16)
                Button("Saved Targets") { openSavedTargets() }
                    .accessibilityIdentifier("v2.planning.open-saved")
                    .help("Review every target you've bookmarked from Planning.")
            }
        }
    }

    /// W4-2: one compact indicator for the planned night's cloud picture --
    /// NOT a table column, since the whole table shares one night (every
    /// row's ranking is computed against the SAME sky). Follows
    /// `store.planningDate` the same way the ranking itself does: it's
    /// recomputed inside `PlanningStore.refresh()`, on the same "night
    /// changed" trigger. `.hidden` renders nothing at all -- weather off or
    /// no site resolved mirrors Home's "no site configured -> no weather
    /// row, no error" rule exactly.
    @ViewBuilder
    private var cloudIndicator: some View {
        switch store.cloudState {
        case .hidden:
            EmptyView()
        case .summary(let summary):
            // Pre-formatted into a plain `String` (rather than interpolating
            // the two `Int`s directly into the `Label` literal) so the
            // localization key this generates is "Cloud tonight: %@" -- the
            // same single-placeholder shape `NightRow`'s "Culminates %@"/
            // "Visible %@" already use -- instead of a two-`Int` "%lld–%lld%%"
            // key nothing else in this codebase's `hu.lproj` follows.
            Label(
                "Cloud tonight: \(Self.cloudRangeText(summary))",
                systemImage: "cloud.fill"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("v2.planning.cloud")
        case .beyondHorizon:
            Label("Forecast horizon is 7 days", systemImage: "cloud.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("v2.planning.cloud")
        case .error(let error):
            Label(error.captionKey, systemImage: "cloud.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("v2.planning.cloud")
        }
    }

    private static func cloudRangeText(_ summary: DailyCloudSummary) -> String {
        "\(Int(summary.minPercent.rounded()))–\(Int(summary.maxPercent.rounded()))%"
    }

    /// Task 4: bookmarks the selected row -- idempotent (re-clicking an
    /// already-saved target is a harmless no-op upsert), so this never needs
    /// its own "already saved" disabled state; the label change below is
    /// enough feedback.
    private var saveTargetButton: some View {
        // V2 UI/UX audit (2026-08-16): `Button(cond ? "Saved" : "Save
        // Target"))` looks like it should resolve to `Button`'s
        // `LocalizedStringKey` initializer the same way a plain literal
        // would, but it doesn't -- a ternary of two string literals infers
        // as plain `String` here, which routes through `Button`'s verbatim
        // `StringProtocol` overload instead. That's why "Save Target" stayed
        // English even once it had a `hu.lproj` entry. Wrapping the ternary
        // in `LocalizedStringKey(_:)` forces the intended overload; the
        // resulting key is still exactly "Saved" or "Save Target" at
        // runtime, so the existing translations apply unchanged.
        Button(LocalizedStringKey(isSelectedRowSaved ? "Saved" : "Save Target")) {
            guard let row = selectedRow else { return }
            Task { await savedTargetsStore.save(designation: row.target.designation) }
        }
        .disabled(selectedRow == nil)
        .accessibilityIdentifier("v2.planning.save-target")
        .help("Bookmark the selected target so you can find it again later.")
    }

    /// Only meaningful once the selected row is actually saved -- a note has
    /// nowhere to live otherwise (`planning_saved_targets.note` hangs off a
    /// saved row).
    private var noteButton: some View {
        Button("Note…") { editingNoteFor = selectedRow }
            .disabled(!isSelectedRowSaved)
            .accessibilityIdentifier("v2.planning.edit-note")
            .help("Write a note on the selected saved target.")
    }

    private var isSelectedRowSaved: Bool {
        guard let selectedRow else { return false }
        return savedTargetsStore.isSaved(selectedRow.target.designation)
    }

    private func planSelectedTarget() {
        guard let selectedTargetID,
              let row = store.filteredRecommendations.first(where: { $0.id == selectedTargetID })
        else { return }
        createProject(row.target.designation)
    }

    private var recommendationList: some View {
        // Task 7 (2026-08-17, GroupBox removal): heading + Divider + content,
        // `ReviewWorkspace.frameReview`'s own shape -- `WorkspaceTablePage`
        // already gives this whole `table:` slot one solid
        // `AstroTokens.Color.surface` background.
        VStack(alignment: .leading, spacing: 0) {
            Text("Target recommendations").font(.headline)
                .padding(.horizontal, AstroTokens.Spacing.standard)
                .padding(.vertical, AstroTokens.Spacing.compact)
            Divider()
            Group {
                switch store.skyAvailability {
                case .pending where store.recommendations.isEmpty:
                    // The first `refresh()` (kicked off by `PlanningStore.init`)
                    // hasn't landed yet -- an honest "still computing" state,
                    // not a false "no matches" claim (part of the build 20013
                    // crash fix: `recommendations` is now computed off the
                    // main actor, so it is briefly empty on first load).
                    ProgressView("Finding matches…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .noLibrary:
                    // Ranking by tonight's sky needs a resolved site
                    // (`Planner.resolveSite`); no library is open at all, so
                    // there is nothing to rank against and no ranking is
                    // invented -- see `PlanningQuery.site`'s own doc.
                    ContentUnavailableView {
                        Label("Open a Library to Get Tonight's Ranking", systemImage: "location.slash")
                    } description: {
                        Text("Planning ranks targets by where they actually are in the sky tonight. Open a library first.")
                    } actions: {
                        // Wave W6-A section B: mirrors `ArchiveView`/
                        // `HealthView`'s own "no library" actions.
                        Button("Choose Image Library…", action: chooseLibrary).buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .noSite:
                    ContentUnavailableView {
                        Label("Set Your Site to Get Tonight's Ranking", systemImage: "location.slash")
                    } description: {
                        Text("This library has no observing site configured and none could be derived from its FITS headers. Set your coordinates in Settings ▸ Location to rank targets by tonight's sky.")
                    } actions: {
                        // Wave W6-A section B: a real path to the panel this
                        // text names.
                        Button("Open Settings…") { openSettings() }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    if store.filteredRecommendations.isEmpty {
                        ContentUnavailableView.search(text: store.searchText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(store.filteredRecommendations, selection: $selectedTargetID, sortOrder: $sortOrder) {
                            TableColumn("Target", value: \.target.designation) { row in
                                HStack(spacing: 6) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayName(row)).font(.headline)
                                        Text(row.target.kind.displayLabel).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if savedTargetsStore.isSaved(row.target.designation) {
                                        Image(systemName: "bookmark.fill")
                                            .foregroundStyle(AstroTokens.Color.accent)
                                            .help("Saved")
                                            .accessibilityLabel("Saved")
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            TableColumn("Score", value: \.planningScore) { row in
                                Text(row.planningScore, format: .number.precision(.fractionLength(2)))
                                    .font(.headline.monospacedDigit())
                            }
                            .width(min: 62, ideal: 72)
                            TableColumn("Photographable", value: \.photographableFactor) { row in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(percent(row.photographableFactor))
                                        .font(.callout.monospacedDigit()).fontWeight(.medium)
                                    if let visibleHours = row.visibleHours {
                                        Text("\(visibleHours, format: .number.precision(.fractionLength(1))) h")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .width(min: 96, ideal: 112)
                            TableColumn("Frame fill", value: \.frameFillFactor) { row in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(percent(row.frameFillFactor))
                                        .font(.callout.monospacedDigit()).fontWeight(.medium)
                                    Text("\((row.frameCoverage * 100), format: .number.precision(.fractionLength(0)))% of edge")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 90, ideal: 108)
                            TableColumn("Moon", value: \.moonFactor) { row in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(percent(row.moonFactor))
                                        .font(.callout.monospacedDigit()).fontWeight(.medium)
                                    if let separation = row.moonSeparationDeg {
                                        Text("\(separation, format: .number.precision(.fractionLength(0)))° away")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .width(min: 74, ideal: 88)
                            TableColumn("Tonight's sky") { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    if row.isLowAltitude {
                                        Label(row.skyVerdict.displayLabel, systemImage: "exclamationmark.triangle.fill")
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(AstroTokens.Color.attention)
                                    } else {
                                        Text("\(row.maxAltitudeDeg ?? 0, format: .number.precision(.fractionLength(0)))° max alt")
                                            .fontWeight(.medium)
                                    }
                                    skyDetail(row).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 165, ideal: 200)
                            TableColumn("Framing") { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.fit.displayLabel).fontWeight(.medium)
                                    Text("\((row.frameCoverage * 100), format: .number.precision(.fractionLength(0)))% of short edge")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 145, ideal: 180)
                            TableColumn("Integration") { row in
                                VStack(alignment: .trailing, spacing: 2) {
                                    if let hours = row.integrationHours {
                                        Text("≈ \(hours, format: .number.precision(.fractionLength(1))) h")
                                            .font(.headline.monospacedDigit())
                                        // W4-5 (owner report): "≈ 27.9 h" alone read as a
                                        // broken per-night figure. It is a multi-night
                                        // exposure budget -- tie it to tonight's real
                                        // dark-hours pace so the reader sees both.
                                        if let nights = row.integrationNightsAtTonightsPace {
                                            Text("~\(nights, format: .number.rounded(rule: .up).precision(.fractionLength(0))) nights at tonight's pace")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        // Two different "no number" cases, and
                                        // conflating them would be its own
                                        // small lie: the model refusing an
                                        // out-of-range figure is not the same
                                        // as the catalog having no photometry.
                                        // V2 localization sweep (W3-13): a
                                        // ternary of two string literals
                                        // passed directly to `Text` resolves
                                        // to `String`, not
                                        // `LocalizedStringKey` (same trap
                                        // `PlanningView`'s own "Saved"/"Save
                                        // Target" button already works
                                        // around below), so neither phrase
                                        // ever localized.
                                        Text(LocalizedStringKey(row.integrationConfidence == .fallback ? "No data" : "Beyond model range"))
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(row.integrationConfidence.displayLabel).font(.caption).foregroundStyle(.secondary)
                                    // W7-B item 1: names the sky background
                                    // this estimate actually assumed, so
                                    // "≈ 27.9 h" never reads as if it needed
                                    // no assumption at all.
                                    skyBrightnessCaption(row.skyBrightnessSource)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 105, ideal: 135)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contextMenu(forSelectionType: String.self) { targetIDs in
                            if let row = store.filteredRecommendations.first(where: { targetIDs.contains($0.id) }) {
                                Button("Plan Selected") { createProject(row.target.designation) }
                            }
                        } primaryAction: { targetIDs in
                            if let row = store.filteredRecommendations.first(where: { targetIDs.contains($0.id) }) {
                                createProject(row.target.designation)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("v2.planning.recommendations")
    }

    /// Task 3: the selected row's altitude across the planned night --
    /// `WorkspaceTablePage`'s `footer` slot, so it sits below the table
    /// without competing for the table's own `.frame(maxHeight: .infinity)`.
    /// Computing the actual samples happens in `PlanningStore`'s own async
    /// path (`selectTarget`/`recomputeSkyPath`), never here in `body` --
    /// this view only reads the store's already-computed `skyPath`.
    private var skyPathSection: some View {
        // Task 7 (2026-08-17, GroupBox removal): `GroupBox`'s opaque grey
        // panel is gone from this footer slot for good. Task 7c: it is a
        // chart with a heading -- real content, not page scaffolding -- so
        // it reads on the same raised layer as the table above it rather
        // than as a chart floating loose on the backdrop.
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Sky path tonight").font(.headline)
            Group {
                if selectedTargetID == nil {
                    ContentUnavailableView(
                        "Select a Target",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Select a row in the table to see its altitude across tonight.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else if store.isComputingSkyPath {
                    ProgressView("Calculating altitude path…")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else if let skyPath = store.skyPath {
                    SkyPathChart(result: skyPath)
                } else {
                    ContentUnavailableView(
                        "No Sky Path Available",
                        systemImage: "chart.xyaxis.line",
                        // V2 localization sweep (W3-13): same ternary-of-
                        // literals leak as the Integration column fix above
                        // -- `Text(cond ? "A" : "B")` resolves to `String`,
                        // not `LocalizedStringKey`, so neither sentence ever
                        // localized.
                        description: Text(LocalizedStringKey(
                            store.skyAvailability == .available
                                ? "This target's altitude sweep could not be computed for the chosen night."
                                : "Open a library with a resolved site to see the target's path across the sky."
                        ))
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            // Season Window Finder (expert ideation reserve #1): only once a
            // row is actually selected -- when nothing is selected the sky
            // path placeholder above already says so, and this second
            // section would just repeat "select a target" a second time.
            if selectedTargetID != nil {
                Divider()
                seasonWindowSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.planning.sky-path-section")
    }

    /// The selected row's YEAR-shaped visibility -- "when does its usable
    /// window open, peak, close" -- computed and cached by `PlanningStore
    /// .recomputeSeasonWindow()` off the main actor, never here in `body`.
    /// `store.seasonWindow == nil` while `isComputingSeasonWindow` is still
    /// `true` is the honest "still computing" gap; once it lands `nil` means
    /// the site itself never resolved, which can't actually happen while a
    /// row is selected (the table only has selectable rows once
    /// `store.skyAvailability == .available`) but is handled anyway rather
    /// than force-unwrapped.
    @ViewBuilder
    private var seasonWindowSection: some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Season").font(.headline)
            if store.isComputingSeasonWindow {
                ProgressView("Calculating season…")
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else if let seasonWindow = store.seasonWindow {
                SeasonWindowSummary.fullText(seasonWindow)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("v2.planning.season-summary")
                if !seasonWindow.hasNoUsableSeason {
                    SeasonWindowChart(result: seasonWindow)
                }
            }
        }
        .accessibilityIdentifier("v2.planning.season-section")
    }

    private func percent(_ factor: Double) -> String {
        (factor * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    /// W3-9: used to return `String` (joining fragments like `"…h visible"`,
    /// `"culm. …"`, `"Moon …°"`, or falling back to `row.skyVerdict.english`)
    /// -- the exact same view-composed-`String` leak `recommendationDetailText`
    /// in `HomeView.swift` had, and its fallback doubled as the domain-layer
    /// `.english` leak `SkyVerdictKind.displayLabel` now fixes. Returning
    /// `Text` built from one real `Text("literal")` per fragment keeps every
    /// piece a genuine extraction-script call site.
    private func skyDetail(_ row: PlanningRecommendation) -> Text {
        var parts: [Text] = []
        if let visibleHours = row.visibleHours {
            parts.append(Text("\(visibleHours.formatted(.number.precision(.fractionLength(1))))h visible"))
        }
        if let culminationText = culminationText(row.culminationDisplay) {
            parts.append(culminationText)
        }
        if let moonSeparation = row.moonSeparationDeg {
            parts.append(Text("Moon \(moonSeparation.formatted(.number.precision(.fractionLength(0))))°"))
        }
        guard let first = parts.first else { return Text(row.skyVerdict.displayLabel) }
        return parts.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
    }

    /// W7-A leftover (item 3b): `nil` when there is nothing honest to say
    /// (`.none`) or when a window-edge sample's direction can't be inferred
    /// (`.unknownDirection` -- see `PlanningCulminationDisplay.derive(...)`'s
    /// own doc); the caller (`skyDetail`) simply omits the fragment rather
    /// than guessing. Never renders a bare "culm. HH:mm" for a sample that
    /// was only the edge of tonight's scanned window (the W7-A audit's own
    /// "delelés 03:54" dishonesty).
    /// W7-B item 1: states the sky-background assumption behind
    /// `row.integrationHours` -- an assumed μ=21 broadband fallback, or this
    /// library's own measured median (`PlanningSkyBrightnessSource
    /// .measured`).
    private func skyBrightnessCaption(_ source: PlanningSkyBrightnessSource) -> Text {
        switch source {
        case .assumedFallback:
            return Text("assumed μ=21 sky")
        case let .measured(magnitudePerArcsec2, sessionCount):
            return Text("own sky: μ≈\(magnitudePerArcsec2.formatted(.number.precision(.fractionLength(1)))) (\(sessionCount) sessions)")
        }
    }

    private func culminationText(_ display: PlanningCulminationDisplay) -> Text? {
        switch display {
        case .none, .unknownDirection:
            return nil
        case let .genuine(localTime):
            // W7-F item 1: see `HomeView.culminationText`'s identical case --
            // `PlanningCulminationDisplay.suggestsMeridianFlip`'s own doc
            // explains why a genuine (inside-window) culmination always
            // means a GEM-class mount is likely to need a meridian flip
            // mid-capture.
            return Text("culm. \(localTime) — meridian flip likely")
        case .afterWindow:
            return Text("culm. after tonight's window")
        case let .pastPeakAtWindowStart(windowEndLocal):
            return Text("window ends \(windowEndLocal)")
        }
    }

    private func displayName(_ row: PlanningRecommendation) -> String {
        if let name = row.target.commonNameHU { return "\(row.target.designation) · \(name)" }
        if let name = TargetCatalog.englishName(for: row.target) { return "\(row.target.designation) · \(name)" }
        return row.target.designation
    }
}
