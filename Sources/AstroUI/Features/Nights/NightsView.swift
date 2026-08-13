import AstroApplication
import SwiftUI

public struct NightsView: View {
    private enum Mode: String, CaseIterable {
        case history = "Observed"
        case calendar = "Next 30 nights"
    }
    let snapshot: LibrarySnapshot?
    @Bindable var store: NightsStore
    let chooseLibrary: () -> Void
    let openNight: (UUID) -> Void
    @State private var mode: Mode = .history

    public init(
        snapshot: LibrarySnapshot?,
        store: NightsStore,
        chooseLibrary: @escaping () -> Void,
        openNight: @escaping (UUID) -> Void
    ) {
        self.snapshot = snapshot
        self.store = store
        self.chooseLibrary = chooseLibrary
        self.openNight = openNight
    }

    public var body: some View {
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
                VStack(alignment: .leading, spacing: 12) {
                    Label("A night can contain multiple OSC, narrowband, exposure, and filter series.", systemImage: "square.stack.3d.up")
                    Label("Quality and reports stay comparable per series and roll up to the night.", systemImage: "chart.line.uptrend.xyaxis")
                    if snapshot == nil { Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
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
                        if let id = nightIDs.first { Button("Open Night") { openNight(id) } }
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
    }
}
