import AstroCore
import SwiftUI

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    /// At most one target's session detail list is expanded at a time --
    /// mirrors `AppState`'s single `selectedTarget`/`sessionDetails` pair
    /// (expanding a different row replaces both).
    @State private var expandedTarget: String?

    private var filtered: [TargetStats] {
        guard !searchText.isEmpty else { return appState.stats }
        return appState.stats.filter { stats in
            stats.target.localizedCaseInsensitiveContains(searchText)
                || stats.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var totalIntegrationSeconds: Double {
        appState.stats.reduce(0) { $0 + $1.totalIntegrationSeconds }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Keresés célpont vagy címke szerint", text: $searchText)
                    .frame(width: 280)
                Button("Frissítés") { appState.loadStats() }
                    .disabled(appState.isBusy || appState.db == nil)
                Spacer()
                if appState.isBusy {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }

            if filtered.isEmpty {
                Text(appState.stats.isEmpty ? "Nincs célpont." : "Nincs találat.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(filtered, id: \.target) { stats in
                            targetRow(stats)
                            Divider()
                        }
                    }
                }
            }

            HStack {
                Text("Összes integráció:").bold()
                Text(formatDuration(totalIntegrationSeconds))
                Spacer()
            }
        }
        .onAppear {
            if appState.stats.isEmpty { appState.loadStats() }
        }
        .padding()
    }

    @ViewBuilder
    private func targetRow(_ stats: TargetStats) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedTarget == stats.target },
                set: { isExpanded in
                    if isExpanded {
                        expandedTarget = stats.target
                        appState.loadSessionDetails(target: stats.target)
                    } else if expandedTarget == stats.target {
                        expandedTarget = nil
                    }
                }
            )
        ) {
            if expandedTarget == stats.target {
                SessionDetailPanel(
                    sessions: appState.sessionDetails,
                    isBusy: appState.isBusy,
                    onAddTag: { date, tag in appState.addTag(target: stats.target, date: date, tag: tag) },
                    onRemoveTag: { date, tag in appState.removeTag(target: stats.target, date: date, tag: tag) }
                )
                .padding(.top, 4)
                .padding(.leading, 12)
            }
        } label: {
            targetHeader(stats)
        }
    }

    private func targetHeader(_ stats: TargetStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Text(stats.target).bold()
                    .frame(minWidth: 160, alignment: .leading)
                Text(formatDuration(stats.totalIntegrationSeconds))
                    .frame(width: 70, alignment: .leading)
                Text("\(stats.sessionDates.count) session")
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Text(stats.lastSessionDate ?? "-")
                    .frame(width: 100, alignment: .leading)
                if stats.isWideField {
                    Text("wide-field")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                }
                Spacer()
            }
            TagChipsRow(
                tags: stats.tags,
                onAdd: { tag in appState.addTag(target: stats.target, date: nil, tag: tag) },
                onRemove: { tag in appState.removeTag(target: stats.target, date: nil, tag: tag) }
            )
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}

/// Detail area shown inside an expanded target's `DisclosureGroup`: one
/// block per session date-dir with the equipment signals `TargetStats`
/// doesn't carry (focal length, camera, gain/ISO, sensor temp, filter) plus
/// that session's own tag chips.
private struct SessionDetailPanel: View {
    let sessions: [SessionDetail]
    let isBusy: Bool
    /// `(sessionDateRaw, tagText)`.
    let onAddTag: (String, String) -> Void
    let onRemoveTag: (String, String) -> Void

    /// The session currently shown in `CalibLinkSheet`, `nil` when the sheet
    /// is closed. `SessionDetail` is made `Identifiable` (below) purely so
    /// `.sheet(item:)` can key off it.
    @State private var linkingSession: SessionDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBusy && sessions.isEmpty {
                ProgressView().controlSize(.small)
            } else if sessions.isEmpty {
                Text("Nincs session ehhez a célponthoz.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sessions, id: \.dateRaw) { session in
                        sessionRow(session)
                        Divider()
                    }
                }
            }
        }
        .sheet(item: $linkingSession) { session in
            CalibLinkSheet(target: session.target, date: session.dateRaw)
        }
    }

    private func sessionRow(_ session: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.dateRaw).bold()
                Text("(\(session.lightCount) light, \(session.flatCount) flat, \(session.darkCount) dark, \(session.biasCount) bias)")
                    .foregroundStyle(.secondary)
                if session.hasReadme {
                    Text("README").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Kalibráció linkelése…") { linkingSession = session }
                    .buttonStyle(.link)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow {
                    Text("Integráció:").foregroundStyle(.secondary)
                    Text(formatDuration(session.integrationSeconds))
                }
                GridRow {
                    Text("Expozíciók:").foregroundStyle(.secondary)
                    Text(exposureSummary(session.exposureBreakdown))
                }
                GridRow {
                    Text("Kamera:").foregroundStyle(.secondary)
                    Text(session.cameras.isEmpty ? "-" : session.cameras.joined(separator: ", "))
                }
                GridRow {
                    Text("Gyújtótávolság:").foregroundStyle(.secondary)
                    Text(session.focalLengthsMM.isEmpty ? "-" : session.focalLengthsMM.map { "\(Self.formatNumber($0)) mm" }.joined(separator: ", "))
                }
                GridRow {
                    Text("Gain/ISO:").foregroundStyle(.secondary)
                    Text(session.gains.isEmpty ? "-" : session.gains.map { Self.formatNumber($0) }.joined(separator: ", "))
                }
                GridRow {
                    Text("Szenzor hőm.:").foregroundStyle(.secondary)
                    Text(session.sensorTempsC.isEmpty ? "-" : session.sensorTempsC.map { "\(Self.formatNumber($0))°C" }.joined(separator: ", "))
                }
                GridRow {
                    Text("Szűrő:").foregroundStyle(.secondary)
                    Text(session.filters.isEmpty ? "-" : session.filters.joined(separator: ", "))
                }
            }
            .font(.callout)

            TagChipsRow(
                tags: session.tags,
                onAdd: { tag in onAddTag(session.dateRaw, tag) },
                onRemove: { tag in onRemoveTag(session.dateRaw, tag) }
            )
        }
    }

    private func exposureSummary(_ breakdown: [String: Int]) -> String {
        guard !breakdown.isEmpty else { return "-" }
        return breakdown
            .sorted { $0.key < $1.key }
            .map { "\($0.key)s×\($0.value)" }
            .joined(separator: ", ")
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

// MARK: - Tag chips

/// A wrapping row of tag capsules plus a trailing "+" chip that pops over a
/// text field for adding a new one. Shared by the target-level header and
/// each session row.
private struct TagChipsRow: View {
    let tags: [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                TagChip(text: tag, onRemove: { onRemove(tag) })
            }
            AddTagChip(onAdd: onAdd)
        }
    }
}

private struct TagChip: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35)))
    }
}

private struct AddTagChip: View {
    let onAdd: (String) -> Void

    @State private var showPopover = false
    @State private var text = ""

    var body: some View {
        Button {
            showPopover = true
        } label: {
            Image(systemName: "plus")
                .font(.caption2)
                .padding(6)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover) {
            HStack {
                TextField("Új címke", text: $text)
                    .frame(width: 160)
                    .onSubmit(submit)
                Button("Hozzáad", action: submit)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        text = ""
        showPopover = false
    }
}

/// Minimal wrapping horizontal-then-vertical layout for tag chips -- SwiftUI
/// has no built-in "flow" container. Lays subviews left-to-right, wrapping
/// to a new line once the proposed width would be exceeded.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > maxWidth {
                origin.x = 0
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, origin.x)
        }

        return CGSize(width: totalWidth, height: origin.y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Calibration hard-linking

/// Retroactive conformance purely so `.sheet(item:)` can key off a session
/// row -- `dateRaw` is unique within one target's session list, which is
/// exactly the scope this sheet is ever shown in.
extension SessionDetail: Identifiable {
    public var id: String { dateRaw }
}

/// Confirmation sheet for the one new write operation this tool performs
/// against the user's existing library: hard-linking matching calibration
/// masters (`calibration_library/darks|flats|biases`) into this session's own
/// `darks`/`biases` folders. Loads `AppState.calibLinkPlan` on appear, shows
/// it grouped by destination with each item's reason, and only ever writes
/// when the user explicitly presses "Linkelés" -- never on open, never
/// automatically.
private struct CalibLinkSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kalibráció linkelése").font(.headline)
            Text("\(target) / \(date)").foregroundStyle(.secondary)

            if let result = appState.calibLinkResult {
                resultView(result)
            } else if let plan = appState.calibLinkPlan {
                planView(plan)
            } else {
                ProgressView().controlSize(.small)
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 220)
        .onAppear {
            appState.loadCalibLinkPlan(target: target, date: date)
        }
        .onDisappear {
            appState.clearCalibLinkPlan()
        }
    }

    @ViewBuilder
    private func planView(_ plan: CalibLinkPlan) -> some View {
        if plan.items.isEmpty {
            Text("Nincs linkelhető kalibráció ehhez a session-höz.")
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groupedDestDirs(plan), id: \.self) { destDir in
                        Text(destDir).font(.subheadline).bold()
                        ForEach(plan.items.filter { $0.destDir == destDir }, id: \.sourcePath) { item in
                            Text("•  \(item.sourcePath)  —  \(item.reason)")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }

        HStack {
            Spacer()
            if appState.isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Mégse") { dismiss() }
            Button("Linkelés") { appState.applyCalibLinkPlan() }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.items.isEmpty || appState.isBusy)
                .help(plan.items.isEmpty ? "Nincs linkelhető kalibráció" : "")
        }
    }

    private func resultView(_ result: LinkResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Linkelve: \(result.linked.count), kihagyva: \(result.skipped.count)")
                .font(.callout)
            if !result.skipped.isEmpty {
                Text("Kihagyva (már létezett a célban): \(result.skipped.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func groupedDestDirs(_ plan: CalibLinkPlan) -> [String] {
        Set(plan.items.map(\.destDir)).sorted()
    }
}
