import AppKit
import AstroCore
import SwiftUI

/// One row of the hierarchical stats `Table`: either a target roll-up (with
/// its sessions as children) or a single session detail nested under one.
/// View-layer only -- built fresh from `AppState.stats` /
/// `AppState.sessionDetailsByTarget` on every render, never persisted.
struct StatsRow: Identifiable {
    enum Kind {
        case target(TargetStats)
        case session(target: String, detail: SessionDetail)
    }

    /// "t:<target>" for a target row, "s:<target>:<dateRaw>" for a session
    /// row -- unique across the whole table since `dateRaw` is unique within
    /// one target's session list.
    let id: String
    let kind: Kind
    /// `nil` (not merely `[]`) when there are no sessions, so `Table` shows
    /// no disclosure chevron at all for a target with no session rows on
    /// record (e.g. stacks/processed-only targets).
    var children: [StatsRow]?
}

struct StatsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    /// The session currently shown in `CalibLinkSheet`, `nil` when the sheet
    /// is closed. Row-scoped by construction: only one "Kalibráció
    /// linkelése…" context-menu item can be triggered at a time. (Shared
    /// `LinkingSession`/`SolvingTarget` types, `Views/TargetDetail/
    /// Shared.swift` -- R9-T3 lifted these out of this file so
    /// `TargetDetailPage` could reuse the same sheets.)
    @State private var linkingSession: LinkingSession?
    @State private var selection: StatsRow.ID?
    /// The target currently shown in `PlateSolveSheet`, `nil` when closed --
    /// same row-scoped pattern as `linkingSession`.
    @State private var solvingTarget: SolvingTarget?
    /// The session currently shown in `StackListSheet` (R7-B4/A.10
    /// "Stackelés előkészítése…"), `nil` when closed -- same row-scoped
    /// pattern as `linkingSession`.
    @State private var stackListingSession: LinkingSession?
    /// The session currently shown in `SessionNoteSheet` (R9-T6/B4's
    /// "Éjszaka-jegyzet szerkesztése…"), `nil` when closed -- same
    /// row-scoped pattern as `linkingSession`.
    @State private var noteEditingSession: LinkingSession?

    /// `true` once `AppState.plan` has loaded and reports no resolvable
    /// coordinate for `target` at all -- gates the "Plate-solve…" action so
    /// it only shows up for targets that actually need it (ASIAIR lights are
    /// already plate-solved; this is for wide-field Canon CR3 targets).
    /// `false` (hidden) while `plan` hasn't loaded yet, same "don't guess"
    /// stance as the mosaic-panel button only showing once `panelReportsByTarget`
    /// has data.
    private func targetLacksCoordinate(_ target: String) -> Bool {
        guard let plan = appState.plan else { return false }
        return plan.first(where: { $0.target == target })?.raDeg == nil
    }

    private var filteredTargets: [TargetStats] {
        guard !searchText.isEmpty else { return appState.stats }
        return appState.stats.filter { stats in
            stats.target.localizedCaseInsensitiveContains(searchText)
                || stats.displayName.localizedCaseInsensitiveContains(searchText)
                || stats.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var rows: [StatsRow] {
        filteredTargets.map { stats in
            // R9-T3: the discovered-stacks summary child row is gone --
            // "Stackek" now live on the target's own Célpont-részletek page
            // (Stackek szegmens), so duplicating a summary of them here (on
            // top of the tooltip's own `stacksSummaryLine`) would just be
            // noise.
            let childRows: [StatsRow] = (appState.sessionDetailsByTarget[stats.target] ?? []).map { detail in
                StatsRow(
                    id: "s:\(stats.target):\(detail.dateRaw)",
                    kind: .session(target: stats.target, detail: detail),
                    children: nil
                )
            }
            return StatsRow(
                id: "t:\(stats.target)",
                kind: .target(stats),
                children: childRows.isEmpty ? nil : childRows
            )
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
                Button("Újraszámolás") { appState.loadStats() }
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

            if rows.isEmpty {
                Text(appState.stats.isEmpty ? "Nincs célpont." : "Nincs találat.")
                    .foregroundStyle(.secondary)
            } else {
                statsTable
            }

            HStack {
                Text("Összes integráció:").bold()
                Text(formatDuration(totalIntegrationSeconds))
                Spacer()
            }
        }
        .onAppear {
            if appState.stats.isEmpty { appState.loadStats() }
            // Needed for `targetLacksCoordinate` to gate the "Plate-solve…"
            // action -- `plan` isn't otherwise loaded from this tab.
            if appState.plan == nil { appState.loadPlan() }
        }
        .sheet(item: $linkingSession) { session in
            CalibLinkSheet(target: session.target, date: session.date)
        }
        .sheet(item: $solvingTarget) { solving in
            PlateSolveSheet(target: solving.target)
        }
        .sheet(item: $stackListingSession) { session in
            StackListSheet(target: session.target, date: session.date)
        }
        .sheet(item: $noteEditingSession) { session in
            SessionNoteSheet(target: session.target, date: session.date)
        }
        .padding()
    }

    private var statsTable: some View {
        Table(rows, children: \.children, selection: $selection) {
            TableColumn("Célpont / Session") { row in
                nameCell(row)
            }
            .width(min: 260, ideal: 300)

            TableColumn("Integráció") { row in
                Text(formatDuration(integrationSeconds(row)))
            }
            .width(min: 80, ideal: 90)

            // R9-T3/B11: goal-tag UI landed on the Célpont-részletek header
            // first -- this minimal read-only column (target rows only) is
            // what makes a goal set there immediately visible here too,
            // without pulling in the rest of A.2's not-yet-scheduled
            // "Minden célpont" redesign (Fázis/Stackek columns, tile row).
            TableColumn("Cél") { row in
                Text(goalText(row)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Keretek") { row in
                Text(framesText(row))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Expozíciók / Utolsó dátum") { row in
                Text(exposureOrLastDateText(row))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 140, ideal: 200)

            TableColumn("Kamera") { row in
                Text(cameraText(row))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 100, ideal: 140)

            TableColumn("Részletek") { row in
                Text(detailsText(row))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Címkék") { row in
                tagsCell(row)
            }
            .width(min: 140, ideal: 200)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: - Column 1: Célpont / Session

    @ViewBuilder
    private func nameCell(_ row: StatsRow) -> some View {
        switch row.kind {
        case .target(let stats):
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(stats.displayName).bold()
                    if stats.isWideField {
                        Text("wide-field")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                }
                .lineLimit(1)
                // Resolved catalog designation/common name (R7-B7) --
                // secondary caption with the raw folder name underneath,
                // only when it actually differs (an unresolved/junk folder
                // name already equals `displayName`, so showing it twice
                // would be noise).
                if stats.displayName != stats.target {
                    Text(stats.target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(targetBreakdownTooltip(stats))
            .contentShape(Rectangle())
            // R9-T3/A.2: double-click opens Célpont-részletek -- the
            // "Kész stackek…"/"Panelek…" buttons this row used to carry are
            // gone (their content now lives on that page's Stackek/
            // Áttekintés segments), so this is the row's one navigation
            // affordance besides the context menu's own "Megnyitás".
            .onTapGesture(count: 2) { appState.currentPage = .target(stats.target) }
            .contextMenu { targetContextMenuItems(stats) }
        case .session(let target, let detail):
            HStack(spacing: 6) {
                Text(detail.dateRaw)
                if detail.hasReadme {
                    Text("README")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .help(readmeNotesTooltip(detail.notes))
                }
                if detail.isExcludedFromTotals {
                    Text("kizárva")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                        .foregroundStyle(.red)
                }
            }
            .lineLimit(1)
            .opacity(detail.isExcludedFromTotals ? 0.5 : 1.0)
            .contentShape(Rectangle())
            .contextMenu { sessionContextMenuItems(target: target, detail: detail) }
        }
    }

    // MARK: - Context menus (R9-T3/A.2/B9 -- replaces the old Műveletek column)

    /// Target row's right-click menu -- everything the removed "Műveletek"
    /// column used to offer for a target EXCEPT "Panelek…"/"Stackek…" (those
    /// are dropped outright, not moved: both now live on the target's own
    /// Célpont-részletek page, and duplicating an entry point to the exact
    /// same page the "Megnyitás" item already opens would be redundant).
    @ViewBuilder
    private func targetContextMenuItems(_ stats: TargetStats) -> some View {
        Button("Megnyitás") { appState.currentPage = .target(stats.target) }
        Button("Megnyitás Finderben") { revealInFinder(relativePath: "sessions/\(stats.target)") }
        Divider()
        Menu("Exportálás") {
            Button("AstroBin CSV") { appState.exportAcquisition(target: stats.target, format: .astrobin) }
            Button("CSV") { appState.exportAcquisition(target: stats.target, format: .csv) }
            Button("Markdown") { appState.exportAcquisition(target: stats.target, format: .md) }
        }
        Button("Célpont-riport készítése") { appState.exportTargetReport(target: stats.target) }
        if targetLacksCoordinate(stats.target) {
            Divider()
            Button("Plate-solve…") { solvingTarget = SolvingTarget(target: stats.target) }
        }
    }

    /// Session row's right-click menu -- the same three actions the removed
    /// "Műveletek" column offered per session, unchanged in behavior.
    @ViewBuilder
    private func sessionContextMenuItems(target: String, detail: SessionDetail) -> some View {
        Button("Megnyitás Finderben") { revealInFinder(relativePath: "sessions/\(target)/\(detail.dateRaw)") }
        Divider()
        Button("Kalibráció linkelése…") { linkingSession = LinkingSession(target: target, date: detail.dateRaw) }
        Button("Stackelés előkészítése…") { stackListingSession = LinkingSession(target: target, date: detail.dateRaw) }
        Divider()
        Button("Éjszaka-riport készítése") { appState.exportNightReport(target: target, date: detail.dateRaw) }
        Button("Éjszaka-jegyzet szerkesztése…") { noteEditingSession = LinkingSession(target: target, date: detail.dateRaw) }
    }

    private func revealInFinder(relativePath: String) {
        let url = URL(fileURLWithPath: appState.config.rootPath, isDirectory: true).appendingPathComponent(relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Hover tooltip on a target row's name cell: the usable-vs-gross
    /// breakdown behind the headline integration number, so a user who sees
    /// "42.55h" shrink to "29.77h" after upgrading can see WHY without
    /// digging into individual sessions.
    private func targetBreakdownTooltip(_ stats: TargetStats) -> String {
        var lines = [
            "Valós (usable) integráció: \(formatDuration(stats.usableIntegrationSeconds))",
            "Bruttó (dedup nélkül): \(formatDuration(stats.grossIntegrationSeconds))",
            "Használható keret: \(stats.usableFrameCount)",
        ]
        if stats.duplicateLinkCount > 0 { lines.append("Duplikált link/másolat: \(stats.duplicateLinkCount)") }
        if stats.rejectedFrameCount > 0 { lines.append("Elvetett (Reject/): \(stats.rejectedFrameCount)") }
        if stats.nonFrameFileCount > 0 { lines.append("Nem-keret fájl a lights/ alatt: \(stats.nonFrameFileCount)") }
        if !stats.excludedSessionDates.isEmpty {
            lines.append("Kizárt session-ök: \(stats.excludedSessionDates.joined(separator: ", "))")
        }
        if let panels = appState.panelReportsByTarget[stats.target], panels.isMosaic {
            lines.append("Panelek: \(panelsSummaryLine(panels))")
        }
        if let report = appState.stackReportsByTarget[stats.target], !report.stacks.isEmpty {
            lines.append("Stackek: \(stacksSummaryLine(report))")
        }
        return lines.joined(separator: "\n")
    }

    /// "3 stack, legjobb: 106×120 s (3:32)" (R8-1) -- the compact one-line
    /// discovered-stacks summary shared by the target tooltip, the
    /// "Stackek" child row, and the "Stackek…" popover's header. The "best"
    /// stack is the first one in `report.stacks` that has a parsed
    /// `totalSecondsFromName` -- the list is already sorted that way
    /// (`StackDiscovery.discover`'s own convention).
    private func stacksSummaryLine(_ report: TargetStacks) -> String {
        var line = "\(report.stacks.count) stack"
        if let best = report.stacks.first(where: { $0.totalSecondsFromName != nil }) {
            let frames = best.framesFromName.map(String.init) ?? "?"
            let sub = best.subSecondsFromName.map { String(format: "%.0f", $0) } ?? "?"
            line += ", legjobb: \(frames)×\(sub) s (\(formatDuration(best.totalSecondsFromName ?? 0)))"
        }
        return line
    }

    /// Hover tooltip on a session row's "README" badge (R6-4): every note
    /// `ReadmeNotesParser` pulled out of that session's `README.txt`, one
    /// `key: value` line each, sorted by key for a stable read. Falls back
    /// to a short placeholder for a README with no parseable lines at all
    /// (an edge case, but the badge itself only reflects the file's
    /// existence, not whether it has any content worth surfacing).
    private func readmeNotesTooltip(_ notes: [String: String]) -> String {
        guard !notes.isEmpty else { return "README.txt (nincs kiolvasható bejegyzés)" }
        return notes.keys.sorted().map { "\($0): \(notes[$0] ?? "")" }.joined(separator: "\n")
    }

    /// "3 panel: A 2:10 · B 1:50 · C 0:35 ⚠️ kiegyenlítetlen" -- the compact
    /// one-line mosaic summary shared by the target tooltip and the
    /// "Panelek…" popover's header.
    private func panelsSummaryLine(_ report: PanelReport) -> String {
        let perPanel = report.panels.map { "\($0.label) \(formatDuration($0.integrationSeconds))" }.joined(separator: " · ")
        var line = "\(report.panels.count) panel: \(perPanel)"
        if report.isUnbalanced { line += " ⚠️ kiegyenlítetlen" }
        return line
    }

    // MARK: - Column 2: Integráció

    private func integrationSeconds(_ row: StatsRow) -> Double {
        switch row.kind {
        case .target(let stats): return stats.totalIntegrationSeconds
        case .session(_, let detail): return detail.integrationSeconds
        }
    }

    /// "6:00" for a target with a `goal:6h` tag, "-" otherwise -- `nil` for
    /// session rows (a goal is target-scoped only). Reads
    /// `AppState.projectStates` (`ProjectState.goalSeconds`, already
    /// `GoalTag`-parsed) rather than re-parsing `TargetStats.tags` itself.
    private func goalText(_ row: StatsRow) -> String {
        guard case .target(let stats) = row.kind else { return "" }
        guard let goalSeconds = appState.projectStates.first(where: { $0.target == stats.target })?.goalSeconds else {
            return "-"
        }
        return formatDuration(goalSeconds)
    }

    // MARK: - Column 3: Keretek

    private func framesText(_ row: StatsRow) -> String {
        switch row.kind {
        case .target(let stats):
            return "\(stats.sessionDates.count) session"
        case .session(_, let detail):
            var parts: [String] = []
            if detail.usableLightCount > 0 { parts.append("\(detail.usableLightCount) light") }
            if detail.flatCount > 0 { parts.append("\(detail.flatCount) flat") }
            if detail.darkCount > 0 { parts.append("\(detail.darkCount) dark") }
            if detail.biasCount > 0 { parts.append("\(detail.biasCount) bias") }
            var text = parts.isEmpty ? "-" : parts.joined(separator: " · ")
            var extras: [String] = []
            if detail.rejectedCount > 0 { extras.append("\(detail.rejectedCount) elvetett") }
            if detail.duplicateLinkCount > 0 { extras.append("\(detail.duplicateLinkCount) link") }
            if !extras.isEmpty {
                text += "  (+\(extras.joined(separator: " · ")))"
            }
            if let accepted = detail.dssAcceptedCount, let rejected = detail.dssRejectedCount {
                text += " · DSS: \(accepted)✓/\(rejected)✗"
            }
            return text
        }
    }

    // MARK: - Column 4: Expozíciók / Utolsó dátum

    private func exposureOrLastDateText(_ row: StatsRow) -> String {
        switch row.kind {
        case .target(let stats):
            return stats.lastSessionDate ?? "-"
        case .session(_, let detail):
            return exposureSummary(detail.exposureBreakdown)
        }
    }

    private func exposureSummary(_ breakdown: [String: Int]) -> String {
        guard !breakdown.isEmpty else { return "-" }
        return breakdown
            .sorted { $0.key < $1.key }
            .map { key, count in
                if key == "unknown" { return "?×\(count)" }
                let label = Double(key).map(Self.formatNumber) ?? key
                return "\(label)s×\(count)"
            }
            .joined(separator: ", ")
    }

    // MARK: - Column 5: Kamera

    private func cameraText(_ row: StatsRow) -> String {
        switch row.kind {
        case .target(let stats):
            return stats.cameras.isEmpty ? "-" : stats.cameras.joined(separator: ", ")
        case .session(_, let detail):
            return detail.cameras.isEmpty ? "-" : detail.cameras.joined(separator: ", ")
        }
    }

    // MARK: - Column 6: Részletek (sessions only)

    private func detailsText(_ row: StatsRow) -> String {
        guard case .session(_, let detail) = row.kind else { return "" }
        var parts: [String] = []
        if !detail.focalLengthsMM.isEmpty {
            parts.append(detail.focalLengthsMM.map { "\(Self.formatNumber($0)) mm" }.joined(separator: "/"))
        }
        if !detail.gains.isEmpty {
            parts.append("gain \(detail.gains.map(Self.formatNumber).joined(separator: "/"))")
        }
        if !detail.sensorTempsC.isEmpty {
            parts.append(detail.sensorTempsC.map { "\(Self.formatNumber($0)) °C" }.joined(separator: "/"))
        }
        if !detail.filters.isEmpty {
            parts.append(detail.filters.joined(separator: "/"))
        }
        return parts.isEmpty ? "-" : parts.joined(separator: " · ")
    }

    // MARK: - Column 7: Címkék

    @ViewBuilder
    private func tagsCell(_ row: StatsRow) -> some View {
        switch row.kind {
        case .target(let stats):
            TagChipsRow(
                tags: stats.tags,
                onAdd: { tag in appState.addTag(target: stats.target, date: nil, tag: tag) },
                onRemove: { tag in appState.removeTag(target: stats.target, date: nil, tag: tag) }
            )
        case .session(let target, let detail):
            TagChipsRow(
                tags: detail.tags,
                onAdd: { tag in appState.addTag(target: target, date: detail.dateRaw, tag: tag) },
                onRemove: { tag in appState.removeTag(target: target, date: detail.dateRaw, tag: tag) }
            )
        }
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
/// text field for adding a new one. Shared by target rows and session rows.
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

