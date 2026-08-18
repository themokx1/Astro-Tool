import AstroApplication
import SwiftUI

/// One session's identity for `NightNoteSheet.item`-driven presentation --
/// `Identifiable` so `.sheet(item:)` can key off `(target, date)` without a
/// separate `Bool` flag going stale relative to which night it was opened
/// for.
struct NightNoteEditingTarget: Identifiable, Equatable {
    let target: String
    let date: String
    var id: String { "\(target)|\(date)" }
}

public struct NightsView: View {
    private enum Mode: String, CaseIterable {
        case history = "Observed"
        case calendar = "Next 30 nights"

        /// W3-9: the segmented picker below used to render `Text($0.rawValue)`
        /// -- a `String`, so it always chose `Text`'s verbatim overload.
        var displayLabel: LocalizedStringKey { LocalizedStringKey(rawValue) }
    }
    let snapshot: LibrarySnapshot?
    let rootURL: URL?
    @Bindable var store: NightsStore
    let accessMode: LibraryAccessMode
    let chooseLibrary: () -> Void
    /// W3-10: opens the shared "New Session" sheet, unprefilled -- the user
    /// picks an existing project or types a catalog number and target name.
    let createSession: () -> Void
    let openNight: (UUID) -> Void
    let openCalibration: () -> Void
    let openInsights: (String?) -> Void
    @State private var mode: Mode = .history
    @State private var noteEditorTarget: NightNoteEditingTarget?
    /// Mirrors `NightsStore.sortOrder`/`planningSortOrder`. The tables need
    /// a `Binding`, but the actual re-sorting happens in the store's cached
    /// recompute -- never in `body` (see `PlanningView.sortOrder`'s own doc
    /// comment for why).
    @State private var sortOrder: [KeyPathComparator<NightRow>] = [
        KeyPathComparator(\NightRow.date, order: .reverse)
    ]
    @State private var planningSortOrder: [KeyPathComparator<PlanningNightRow>] = [
        KeyPathComparator(\PlanningNightRow.summary.date, order: .forward)
    ]
    /// Wave W6-A section B: the calendar tab's "no site" placeholder used to
    /// just NAME the Settings ▸ Location panel with no way to reach it --
    /// this is the same escape hatch `V2RootView`'s own `openSettings` calls
    /// already use everywhere else a placeholder points at Settings.
    @Environment(\.openSettings) private var openSettings

    public init(
        snapshot: LibrarySnapshot?,
        rootURL: URL? = nil,
        store: NightsStore,
        accessMode: LibraryAccessMode = .readOnly,
        chooseLibrary: @escaping () -> Void,
        createSession: @escaping () -> Void = {},
        openNight: @escaping (UUID) -> Void,
        openCalibration: @escaping () -> Void = {},
        openInsights: @escaping (String?) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.rootURL = rootURL
        self.store = store
        self.accessMode = accessMode
        self.chooseLibrary = chooseLibrary
        self.createSession = createSession
        self.openNight = openNight
        self.openCalibration = openCalibration
        self.openInsights = openInsights
    }

    public var body: some View {
        if snapshot == nil {
            ContentUnavailableView {
                Label("No library open", systemImage: "moon.stars")
            } description: {
                Text("Open a library to review each observing night without losing its series boundaries.")
            } actions: {
                Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent)
            }
            .navigationTitle("Nights")
            .accessibilityLabel("Nights")
            .accessibilityIdentifier("v2.detail.nights")
        } else {
            nightsWorkspace
        }
    }

    private var nightsWorkspace: some View {
        WorkspaceTablePage(subtitle: "Review each observing night without losing its series boundaries.") {
            // W4-2 (sibling): stays exactly as shipped -- unchanged position,
            // unchanged style.
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("v2.nights.mode")
            // W4-3b (owner's second Projects complaint, verbatim: "a
            // projektek oldal fele még mindig felesleges infó" -- applies
            // here too): this slot used to ALSO stack three `MetricCard`s
            // (Observed nights / Frames / Morning triage -- the triage count
            // duplicated the sidebar's own `.badge()`, the other two were
            // inert numbers linking nowhere) and a permanent "Session model"
            // explainer card with two documentation sentences, above a
            // segmented month picker that already needed 10 buttons and
            // grows every month. All four are gone: the sidebar badge still
            // carries the review count, "Session model" moved into the ⓘ
            // popover next to "Observed nights" below (`observedNightsTable`
            // -- the one place it is actually relevant, not permanent page
            // furniture), the month filter is now a compact menu `Picker`
            // (macOS' own answer to an unbounded, ever-growing choice list,
            // matching e.g. Mail's date-range filters), and a new triage
            // filter (Mind / Áttekintésre vár / Kész) joins it in this one
            // action row -- see `NightsStore.NightTriageFilter` and
            // `uniformVisibleTriageState` for how the Triage column itself
            // then collapses into one summary sentence once every visible
            // row already agrees.
            HStack(spacing: AstroTokens.Spacing.standard) {
                if mode == .history {
                    if !store.availableMonths.isEmpty {
                        Picker("Month", selection: Binding(
                            get: { store.selectedMonth },
                            set: { store.selectMonth($0) }
                        )) {
                            Text("All months").tag(String?.none)
                            ForEach(store.availableMonths, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityIdentifier("v2.nights.calendar")
                    }
                    Picker("Triage", selection: Binding(
                        get: { store.triageFilter },
                        set: { store.setTriageFilter($0) }
                    )) {
                        ForEach(NightTriageFilter.allCases, id: \.self) { filter in
                            Text(filter.displayLabel).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityIdentifier("v2.nights.triage-filter")
                }
                Spacer()
                // W3-10: the owner's own report -- "Projektet tudok hozzá
                // adni, de új sessiont nem tudok, legalábbis nem találom a
                // gombot." (I can add a project, but not a new session -- or
                // at least I can't find the button.) V2 had no
                // session-creation entry point anywhere; this is the
                // unprefilled one -- the user picks an existing project or
                // types a catalog/name.
                Button(action: createSession) {
                    Label("New Session…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help("Create a new session — pick an existing project or a custom target")
                .accessibilityIdentifier("v2.nights.new-session")
            }
        } table: {
            tableContent
        }
        .navigationTitle("Nights")
        .accessibilityLabel("Nights")
        .accessibilityIdentifier("v2.detail.nights")
        .onChange(of: sortOrder) { _, newValue in store.setSortOrder(newValue) }
        .onChange(of: planningSortOrder) { _, newValue in store.setPlanningSortOrder(newValue) }
        .sheet(item: $noteEditorTarget) { editing in
            if let rootURL {
                NightNoteSheet(
                    rootURL: rootURL, target: editing.target, date: editing.date,
                    accessMode: accessMode, dismiss: { noteEditorTarget = nil }
                )
            }
        }
    }

    /// The two table-hosting `Mode`s already act as a swap, not a stack --
    /// `mode`'s own segmented control (in the fixed toolbar above) picks
    /// exactly one of these at a time, so there is never more than one
    /// `Table` materialized here, and it always gets the whole table region.
    @ViewBuilder
    private var tableContent: some View {
        if mode == .history, !store.nights.isEmpty {
            observedNightsTable
        } else if mode == .calendar {
            if store.planningRows.isEmpty {
                ContentUnavailableView {
                    Label("Planning calendar unavailable", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("Set your coordinates in Settings ▸ Location, or scan FITS files that carry site coordinates, to calculate the next 30 nights.")
                } actions: {
                    // Wave W6-A section B: a real path to the panel this
                    // text names, not just the name of one.
                    Button("Open Settings…") { openSettings() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                calendarTable
            }
        }
    }

    /// Backs the "Observed nights" header's ⓘ button -- the two documentation
    /// sentences a permanent "Session model" card used to spend on every
    /// visit (W4-3b; see `nightsWorkspace`'s own doc comment for the fuller
    /// account). Same "explain it once, on demand" move the Projects page's
    /// "Tiszta kezdés" card made into `NewProjectView`'s caption.
    private static let sessionModelInfo: [MetricInfoButton.Metric] = [
        .init(title: "Multiple series per night", explanation: "A night can contain multiple OSC, narrowband, exposure, and filter series."),
        .init(title: "Comparable quality and reports", explanation: "Quality and reports stay comparable per series and roll up to the night."),
    ]

    private var observedNightsTable: some View {
        // Task 7 (2026-08-17, GroupBox removal): heading + Divider + Table,
        // `ReviewWorkspace.frameReview`'s own shape -- `WorkspaceTablePage`
        // already gives this whole `table:` slot its one solid
        // `AstroTokens.Color.surface` background, so a `GroupBox` here was
        // a second, opaque box painted inside that surface.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Observed nights").font(.headline)
                    MetricInfoButton(metrics: Self.sessionModelInfo)
                }
                // W4-3b: when every currently visible night already shares
                // one `NightRow.TriageState` -- typically because the new
                // triage filter above narrowed to exactly one, but also
                // whenever the data itself just happens to agree --
                // repeating the same badge once per row is pure noise; one
                // sentence says it once instead. The Triage column itself is
                // dropped below in this same case, so the state is never
                // shown twice.
                if let sharedState = store.uniformVisibleTriageState {
                    triageSummaryText(for: sharedState, count: store.visibleNights.count)
                        .font(.subheadline)
                        .foregroundStyle(sharedState == .ready ? AstroTokens.Color.ok : AstroTokens.Color.attention)
                        .accessibilityIdentifier("v2.nights.triage-summary")
                }
            }
            .padding(.horizontal, AstroTokens.Spacing.standard)
            .padding(.vertical, AstroTokens.Spacing.compact)
            Divider()
            Table(store.visibleNights, selection: Binding(
                get: { store.selectedNightID },
                set: { store.selectNight($0) }
            ), sortOrder: $sortOrder) {
                TableColumn("Night", value: \NightRow.date) { night in
                    Label(night.date, systemImage: "moon.stars.fill")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(AstroTokens.Color.accent)
                }
                TableColumn("Projects") { Text($0.projectSummary).lineLimit(1) }
                TableColumn("Series", value: \NightRow.seriesCount) { Text($0.seriesCount.formatted()).monospacedDigit() }
                    .width(min: 55, ideal: 65)
                TableColumn("Usable", value: \NightRow.snapshot.usableFrames) { Text("\($0.snapshot.usableFrames) / \($0.snapshot.totalFrames)").monospacedDigit() }
                    .width(min: 70, ideal: 85)
                TableColumn("Integration", value: \NightRow.snapshot.integrationSeconds) { Text($0.integrationSummary).monospacedDigit() }
                    .width(min: 75, ideal: 90)
                // W4-3b: redundant with `triageSummaryText` above once every
                // visible row already shares one state -- see
                // `NightsStore.uniformVisibleTriageState`'s own doc comment
                // for why that is not the same thing as "only under Mind"
                // (a specific filter guarantees this by construction, but
                // "Mind" can land here too if the data just happens to
                // agree).
                if store.uniformVisibleTriageState == nil {
                    TableColumn("Triage", value: \NightRow.triageState.rawValue) { night in
                        Label(night.triageState.displayLabel, systemImage: night.triageState == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(night.triageState == .ready ? AstroTokens.Color.ok : AstroTokens.Color.attention)
                    }
                    .width(min: 110, ideal: 125)
                }
                // Task 4 (2026-08-17 owner-feedback wave 3) first gave this
                // column a single visible "Rate Frames" icon button, since
                // the owner could only reach any row action through the
                // right-click `NightActionMenu`. Task 5b (same wave)
                // replaced that single-action button with this "..."
                // overflow menu once auditing `ProjectsView`'s own row strip
                // turned up the same underlying problem here: a one-icon
                // row strip and a seven-item context menu are still two
                // different sets for the same row, just an obviously
                // incomplete one instead of an obviously wrong one. The
                // menu's content is `actionMenu(for:openNight:)` -- the
                // EXACT function the context menu below already calls -- so
                // the row and the right-click menu can never drift apart.
                TableColumn("") { night in
                    Menu {
                        actionMenu(for: night, openNight: { openNight(night.id) })
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More actions")
                    .accessibilityIdentifier("v2.nights.row-actions.\(night.id.uuidString)")
                }
                .width(40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu(forSelectionType: UUID.self) { nightIDs in
                if let id = nightIDs.first, let night = store.nights.first(where: { $0.id == id }) {
                    actionMenu(for: night, openNight: { openNight(id) })
                }
            } primaryAction: { nightIDs in
                if let id = nightIDs.first { openNight(id) }
            }
            .accessibilityIdentifier("v2.nights.table")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calendarTable: some View {
        // Task 7 (2026-08-17, GroupBox removal): same fix as
        // `observedNightsTable` above -- see its own comment.
        VStack(alignment: .leading, spacing: 0) {
            Text("Astronomical planning calendar").font(.headline)
                .padding(.horizontal, AstroTokens.Spacing.standard)
                .padding(.vertical, AstroTokens.Spacing.compact)
            Divider()
            Table(store.planningRows, sortOrder: $planningSortOrder) {
                TableColumn("Night", value: \PlanningNightRow.summary.date) { Text($0.summary.date).font(.headline.monospacedDigit()) }
                // `darkHours`/`bestTargets` are `String`, mixing already-
                // Hungarian engine text, plain formatted numbers, and (on
                // the rarer fallback paths) an English literal -- wrapping
                // in `LocalizedStringKey(...)` at the call site is the same
                // fix `NightWorkspaceView`'s own `MetricCard(detail:
                // LocalizedStringKey(row.filterSummary))` already uses, and
                // the ternary below is the same "wrap the whole ternary"
                // workaround `PlanningView`'s Save/Saved button uses (see
                // `LocalizationCoverageTests.saveTargetLocalizesDespiteTernary`).
                TableColumn("Darkness", value: \PlanningNightRow.astroDarkHoursSortKey) { Text(LocalizedStringKey($0.darkHours)) }
                TableColumn("Moon", value: \PlanningNightRow.summary.moonIlluminationPercent) { Text($0.moon).monospacedDigit() }
                    .width(min: 65, ideal: 75)
                // W4-2: `store.nightWeather` is keyed by the exact same
                // "yyyy-MM-dd, night-start" date string `summary.date`
                // already is -- a date simply missing from the dictionary
                // covers every honest "nothing to show" case at once
                // (weather off, no site, or beyond Open-Meteo's 7-day
                // horizon), rendered as the same "—" this table already uses
                // for other missing values.
                TableColumn("Cloud") { row in
                    Text(cloudSummaryText(for: row.summary.date)).monospacedDigit()
                }
                .width(min: 65, ideal: 85)
                TableColumn("Best target windows") { Text(LocalizedStringKey($0.bestTargets.isEmpty ? "No usable target window" : $0.bestTargets)).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("v2.nights.planning-calendar")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cloudSummaryText(for date: String) -> String {
        guard let summary = store.nightWeather[date] else { return "—" }
        return "\(Int(summary.minPercent.rounded()))–\(Int(summary.maxPercent.rounded()))%"
    }

    /// Backs the Triage-column-to-one-line collapse (`observedNightsTable`,
    /// `NightsStore.uniformVisibleTriageState`) -- the sentence follows the
    /// shared state itself rather than a single fixed phrase, so it never
    /// claims "needs review" for a row set that is actually all `.ready` or
    /// all `.empty`.
    private func triageSummaryText(for state: NightRow.TriageState, count: Int) -> Text {
        switch state {
        case .ready:
            Text("\(count) night(s) need no further review")
        case .needsReview:
            Text("\(count) night(s) need review")
        case .empty:
            Text("\(count) night(s) have no usable frames")
        }
    }

    /// `NightActionMenu`'s shared action set for one night row -- V1's
    /// per-session "Éjszaka-riport készítése" context-menu item had the
    /// same "act on the row, don't force a navigation first" shape; this
    /// extends that same idea to every action the menu now offers.
    @ViewBuilder
    private func actionMenu(for night: NightRow, openNight: @escaping () -> Void) -> some View {
        if let project = night.snapshot.projects.first {
            NightActionMenu(
                target: ProjectsQuery.canonicalFolderName(for: project),
                date: night.date,
                setupDescriptor: night.snapshot.series.first?.setupDescriptor,
                nightID: night.id,
                rootURL: rootURL,
                openNight: openNight,
                editNotes: {
                    noteEditorTarget = NightNoteEditingTarget(
                        target: ProjectsQuery.canonicalFolderName(for: project), date: night.date
                    )
                },
                openCalibration: openCalibration,
                openInsights: openInsights
            )
        } else {
            Button("Open Night", action: openNight)
        }
    }
}
