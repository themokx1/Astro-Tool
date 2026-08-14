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
        WorkspacePage(eyebrow: "Capture history", title: "Nights", subtitle: "Review each observing night without losing its series boundaries.") {
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
            if mode == .history, !store.nights.isEmpty {
                GroupBox("Observed nights") {
                    Table(store.visibleNights, selection: Binding(
                        get: { store.selectedNightID },
                        set: { store.selectNight($0) }
                    )) {
                        TableColumn("Night") { night in
                            Label(night.date, systemImage: "moon.stars.fill")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(AstroTokens.Color.spectralViolet)
                        }
                        TableColumn("Projects") { Text($0.projectSummary).lineLimit(1) }
                        TableColumn("Series") { Text($0.seriesCount.formatted()).monospacedDigit() }
                            .width(min: 55, ideal: 65)
                        TableColumn("Usable") { Text("\($0.snapshot.usableFrames) / \($0.snapshot.totalFrames)").monospacedDigit() }
                            .width(min: 70, ideal: 85)
                        TableColumn("Integration") { Text($0.integrationSummary).monospacedDigit() }
                            .width(min: 75, ideal: 90)
                        TableColumn("Triage") { night in
                            Label(night.triageState.rawValue, systemImage: night.triageState == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(night.triageState == .ready ? .green : .orange)
                        }
                        .width(min: 110, ideal: 125)
                    }
                    .frame(minHeight: 330)
                    .contextMenu(forSelectionType: UUID.self) { nightIDs in
                        if let id = nightIDs.first, let night = store.nights.first(where: { $0.id == id }) {
                            actionMenu(for: night, openNight: { openNight(id) })
                        }
                    } primaryAction: { nightIDs in
                        if let id = nightIDs.first { openNight(id) }
                    }
                    .onChange(of: store.selectedNightID) { _, id in if let id { openNight(id) } }
                    .accessibilityIdentifier("v2.nights.table")
                }
            }
            if mode == .calendar {
                GroupBox("Astronomical planning calendar") {
                    if store.planningRows.isEmpty {
                        ContentUnavailableView(
                            "Planning calendar unavailable",
                            systemImage: "calendar.badge.exclamationmark",
                            description: Text("Add an observing site or scan FITS site coordinates to calculate the next 30 nights.")
                        )
                        .frame(minHeight: 260)
                    } else {
                        Table(store.planningRows) {
                            TableColumn("Night") { Text($0.summary.date).font(.headline.monospacedDigit()) }
                            TableColumn("Darkness") { Text($0.darkHours) }
                            TableColumn("Moon") { Text($0.moon).monospacedDigit() }
                                .width(min: 65, ideal: 75)
                            TableColumn("Best target windows") { Text($0.bestTargets.isEmpty ? "No usable target window" : $0.bestTargets).lineLimit(1) }
                        }
                        .frame(minHeight: 390)
                        .accessibilityIdentifier("v2.nights.planning-calendar")
                    }
                }
            }
        }
        .navigationTitle("Nights")
        .accessibilityLabel("Nights")
        .accessibilityIdentifier("v2.detail.nights")
        .sheet(item: $noteEditorTarget) { editing in
            if let rootURL {
                NightNoteSheet(
                    rootURL: rootURL, target: editing.target, date: editing.date,
                    accessMode: accessMode, dismiss: { noteEditorTarget = nil }
                )
            }
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
