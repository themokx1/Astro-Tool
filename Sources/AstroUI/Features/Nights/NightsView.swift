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
    }
    let snapshot: LibrarySnapshot?
    let rootURL: URL?
    @Bindable var store: NightsStore
    let accessMode: LibraryAccessMode
    let chooseLibrary: () -> Void
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

    public init(
        snapshot: LibrarySnapshot?,
        rootURL: URL? = nil,
        store: NightsStore,
        accessMode: LibraryAccessMode = .readOnly,
        chooseLibrary: @escaping () -> Void,
        openNight: @escaping (UUID) -> Void,
        openCalibration: @escaping () -> Void = {},
        openInsights: @escaping (String?) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.rootURL = rootURL
        self.store = store
        self.accessMode = accessMode
        self.chooseLibrary = chooseLibrary
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
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("v2.nights.mode")
            HStack(spacing: AstroTokens.Spacing.standard) {
                MetricCard(title: "Observed nights", value: snapshot.map { "\($0.nightCount)" } ?? "—", detail: "Detected date-based sessions", systemImage: "calendar")
                MetricCard(title: "Frames", value: snapshot.map { "\($0.frameCount)" } ?? "—", detail: "Indexed read-only", systemImage: "photo.stack")
                MetricCard(title: "Morning triage", value: "\(store.needsReviewCount)", detail: "Needs review", systemImage: "checklist")
            }
            .accessibilityIdentifier("v2.nights.triage")
            if mode == .history { GroupBox("Session model") {
                VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
                    Label("A night can contain multiple OSC, narrowband, exposure, and filter series.", systemImage: "square.stack.3d.up")
                    Label("Quality and reports stay comparable per series and roll up to the night.", systemImage: "chart.line.uptrend.xyaxis")
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(AstroTokens.Spacing.compact)
            } }
            if mode == .history, !store.availableMonths.isEmpty {
                Picker("Month", selection: Binding(
                    get: { store.selectedMonth },
                    set: { store.selectMonth($0) }
                )) {
                    Text("All months").tag(String?.none)
                    ForEach(store.availableMonths, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("v2.nights.calendar")
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
                ContentUnavailableView(
                    "Planning calendar unavailable",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Set your coordinates in Settings ▸ Location, or scan FITS files that carry site coordinates, to calculate the next 30 nights.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                calendarTable
            }
        }
    }

    private var observedNightsTable: some View {
        GroupBox("Observed nights") {
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
                TableColumn("Triage", value: \NightRow.triageState.rawValue) { night in
                    Label(night.triageState.rawValue, systemImage: night.triageState == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(night.triageState == .ready ? AstroTokens.Color.ok : AstroTokens.Color.attention)
                }
                .width(min: 110, ideal: 125)
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
        GroupBox("Astronomical planning calendar") {
            Table(store.planningRows, sortOrder: $planningSortOrder) {
                TableColumn("Night", value: \PlanningNightRow.summary.date) { Text($0.summary.date).font(.headline.monospacedDigit()) }
                TableColumn("Darkness", value: \PlanningNightRow.astroDarkHoursSortKey) { Text($0.darkHours) }
                TableColumn("Moon", value: \PlanningNightRow.summary.moonIlluminationPercent) { Text($0.moon).monospacedDigit() }
                    .width(min: 65, ideal: 75)
                TableColumn("Best target windows") { Text($0.bestTargets.isEmpty ? "No usable target window" : $0.bestTargets).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("v2.nights.planning-calendar")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
