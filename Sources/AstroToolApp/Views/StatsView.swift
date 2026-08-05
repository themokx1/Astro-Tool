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
        /// A target's discovered-stacks summary (R8-1) -- always the LAST
        /// child row under a target, after every session row. Only present
        /// when `TargetStacks.stacks` is non-empty (a target with none
        /// gets no row at all, same "don't show an empty summary" stance
        /// as the mosaic-panel button only appearing for `isMosaic`).
        case stacksSummary(target: String, report: TargetStacks)
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
    /// linkelése…" button can be pressed at a time.
    @State private var linkingSession: LinkingSession?
    @State private var selection: StatsRow.ID?
    /// The target currently shown in `PlateSolveSheet`, `nil` when closed --
    /// same row-scoped-button pattern as `linkingSession`.
    @State private var solvingTarget: SolvingTarget?
    /// The session currently shown in `StackListSheet` (R7-B4), `nil` when
    /// closed -- same row-scoped-button pattern as `linkingSession`.
    @State private var stackListingSession: LinkingSession?

    private struct LinkingSession: Identifiable {
        let target: String
        let date: String
        var id: String { "\(target):\(date)" }
    }

    private struct SolvingTarget: Identifiable {
        let target: String
        var id: String { target }
    }

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
            let sessions = appState.sessionDetailsByTarget[stats.target] ?? []
            var childRows: [StatsRow] = sessions.map { detail in
                StatsRow(
                    id: "s:\(stats.target):\(detail.dateRaw)",
                    kind: .session(target: stats.target, detail: detail),
                    children: nil
                )
            }
            // R8-1: the target's discovered-stacks summary, always LAST
            // among the children (after every session row).
            if let report = appState.stackReportsByTarget[stats.target], !report.stacks.isEmpty {
                childRows.append(
                    StatsRow(
                        id: "k:\(stats.target)",
                        kind: .stacksSummary(target: stats.target, report: report),
                        children: nil
                    )
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

            TableColumn("Műveletek") { row in
                actionsCell(row)
            }
            .width(min: 80, ideal: 240)
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
        case .session(_, let detail):
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
        case .stacksSummary(_, let report):
            Text(stacksSummaryLine(report))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
        case .stacksSummary: return 0
        }
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
        case .stacksSummary(_, let report):
            return "\(report.stacks.count) stack"
        }
    }

    // MARK: - Column 4: Expozíciók / Utolsó dátum

    private func exposureOrLastDateText(_ row: StatsRow) -> String {
        switch row.kind {
        case .target(let stats):
            return stats.lastSessionDate ?? "-"
        case .session(_, let detail):
            return exposureSummary(detail.exposureBreakdown)
        case .stacksSummary:
            return "-"
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
        case .stacksSummary:
            return "-"
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
        case .stacksSummary:
            EmptyView()
        }
    }

    // MARK: - Column 8: Műveletek

    @ViewBuilder
    private func actionsCell(_ row: StatsRow) -> some View {
        switch row.kind {
        case .target(let stats):
            HStack(spacing: 8) {
                Menu("Exportálás…") {
                    Button("AstroBin CSV") { appState.exportAcquisition(target: stats.target, format: .astrobin) }
                    Button("CSV") { appState.exportAcquisition(target: stats.target, format: .csv) }
                    Button("Markdown") { appState.exportAcquisition(target: stats.target, format: .md) }
                }
                .menuStyle(.borderlessButton)
                .font(.caption)
                .fixedSize()

                if let panels = appState.panelReportsByTarget[stats.target], panels.isMosaic {
                    PanelsPopoverButton(report: panels)
                }

                if let report = appState.stackReportsByTarget[stats.target], !report.stacks.isEmpty {
                    StacksPopoverButton(report: report, summaryLine: stacksSummaryLine(report))
                }

                if targetLacksCoordinate(stats.target) {
                    Button("Plate-solve…") {
                        solvingTarget = SolvingTarget(target: stats.target)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        case .session(let target, let detail):
            HStack(spacing: 8) {
                Button("Kalibráció linkelése…") {
                    linkingSession = LinkingSession(target: target, date: detail.dateRaw)
                }
                .buttonStyle(.link)
                .font(.caption)

                Button("Stack-lista…") {
                    stackListingSession = LinkingSession(target: target, date: detail.dateRaw)
                }
                .buttonStyle(.link)
                .font(.caption)

                Button("Éjszaka-riport") {
                    appState.exportNightReport(target: target, date: detail.dateRaw)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        case .stacksSummary:
            EmptyView()
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

// MARK: - Panels popover

/// "Panelek…" button on a mosaic target's row -- pops over the full panel
/// table (label, center RA/Dec, frame count, integration, rotation, pixel
/// scale) plus the same unbalanced-mosaic warning line the tooltip shows.
/// Only ever shown when `PanelReport.isMosaic` (the caller checks that
/// before instantiating this view).
private struct PanelsPopoverButton: View {
    let report: PanelReport

    @State private var showPopover = false

    var body: some View {
        Button("Panelek…") { showPopover = true }
            .buttonStyle(.link)
            .font(.caption)
            .popover(isPresented: $showPopover) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(report.target) — \(report.panels.count) panel").font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow {
                            Text("Panel").bold()
                            Text("Közép RA/Dec").bold()
                            Text("Keret").bold()
                            Text("Integráció").bold()
                            Text("Rot.").bold()
                            Text("Skála").bold()
                        }
                        .font(.caption)
                        ForEach(report.panels, id: \.label) { panel in
                            GridRow {
                                Text(panel.label)
                                Text(String(format: "%.4f / %+.4f", panel.centerRaDeg, panel.centerDecDeg))
                                Text("\(panel.frameCount)")
                                Text(formatDuration(panel.integrationSeconds))
                                Text(panel.rotationDeg.map { String(format: "%.1f°", $0) } ?? "-")
                                Text(panel.pixelScaleArcsec.map { String(format: "%.2f\"/px", $0) } ?? "-")
                            }
                            .font(.caption)
                        }
                    }

                    if report.isUnbalanced {
                        Text("⚠️ kiegyenlítetlen mozaik")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
            }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
    }
}

// MARK: - Stacks popover (R8-1)

/// "Stackek…" button on a target's row -- pops over the full discovered-
/// stacks table (file, location, frame×sub, total integration, size, kind,
/// date). Only ever shown when `TargetStacks.stacks` is non-empty (the
/// caller checks that before instantiating this view, same convention as
/// `PanelsPopoverButton`/`isMosaic`).
private struct StacksPopoverButton: View {
    let report: TargetStacks
    let summaryLine: String

    @State private var showPopover = false

    var body: some View {
        Button("Stackek…") { showPopover = true }
            .buttonStyle(.link)
            .font(.caption)
            .popover(isPresented: $showPopover) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(report.displayName) — \(summaryLine)").font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow {
                            Text("Fájl").bold()
                            Text("Hely").bold()
                            Text("Keret×sub").bold()
                            Text("Össz.").bold()
                            Text("Méret").bold()
                            Text("Dátum").bold()
                        }
                        .font(.caption)
                        ForEach(report.stacks, id: \.path) { stack in
                            GridRow {
                                Text((stack.path as NSString).lastPathComponent)
                                    .help(stack.path)
                                    .lineLimit(1)
                                Text(locationLabel(for: stack.path))
                                Text(framesSubText(stack))
                                Text(stack.totalSecondsFromName.map(formatDuration) ?? "-")
                                Text(formatBytes(stack.sizeBytes))
                                HStack(spacing: 4) {
                                    Text(stack.sessionDate ?? "-")
                                    if stack.kind != "stack" {
                                        Text(stack.kind)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding()
            }
    }

    private func framesSubText(_ stack: StackFile) -> String {
        guard let frames = stack.framesFromName else { return "-" }
        let sub = stack.subSecondsFromName.map { String(format: "%.0f", $0) } ?? "?"
        return "\(frames)×\(sub)s"
    }

    /// Same top-level-path-component labeling the CLI's `locationLabel`
    /// uses -- kept as its own tiny copy here since the CLI target and this
    /// app target don't share a module.
    private func locationLabel(for path: String) -> String {
        let top = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        switch top {
        case "stacks": return "stacks"
        case "processed": return "processed"
        case "sessions": return "sessions"
        default: return "gyökér"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", totalMinutes / 60, totalMinutes % 60)
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
            if !plan.mismatchReasons.isEmpty {
                Text("Nem linkelhető: \(plan.mismatchReasons.joined(separator: ", "))")
                    .foregroundStyle(.orange)
            } else {
                Text("Nincs linkelhető kalibráció ehhez a session-höz.")
                    .foregroundStyle(.secondary)
            }
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

// MARK: - Plate-solve sheet (R7-1)

/// Runs `AppState.runPlateSolve(target:)` on appear and shows the resulting
/// `SolveSummary` -- same "progress until `AppState` sets a result" pattern
/// as `CalibLinkSheet`, just with no plan/confirm step (the operation always
/// runs immediately; there's nothing to review beforehand since Siril work
/// never touches the library).
private struct PlateSolveSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Plate-solve").font(.headline)
            Text(target).foregroundStyle(.secondary)

            if let summary = appState.plateSolveSummary {
                resultView(summary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(appState.progressText).foregroundStyle(.secondary)
                }
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 160)
        .onAppear {
            appState.runPlateSolve(target: target)
        }
        .onDisappear {
            appState.plateSolveSummary = nil
        }
    }

    private func resultView(_ summary: SolveSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Megoldva: \(summary.solved) / \(summary.attempted) (sikertelen: \(summary.failed), kihagyva: \(summary.skipped))")
                .font(.callout)
            HStack {
                Spacer()
                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Stack-list export (R7-B4)

/// "Stack-lista…" sheet: a keep-fraction slider (50-100%) drives a live
/// `StackList.select` preview (criteria + selected/total counts), and
/// "Exportálás" runs `StackList.export` -- the additive hard-link + `.
/// dssfilelist`/`.ssf` write this whole feature bridges frame scoring to
/// actual stacking with. Same "load on appear, clear on disappear" pattern
/// as `CalibLinkSheet`/`PlateSolveSheet`; unlike `CalibLinkSheet` there's no
/// separate `--dry-run` state -- adjusting the slider just recomputes the
/// (read-only) preview in place.
private struct StackListSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: String
    let date: String

    @State private var keepFraction: Double = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stack-lista").font(.headline)
            Text("\(target) / \(date)").foregroundStyle(.secondary)

            HStack {
                Text("Megtartás:")
                Slider(value: $keepFraction, in: 0.5...1.0, step: 0.05)
                Text("\(Int((keepFraction * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(appState.stackListExportDir != nil)
            .onChange(of: keepFraction) { _, newValue in
                appState.loadStackListSelection(target: target, date: date, keepFraction: newValue)
            }

            if let exportDir = appState.stackListExportDir {
                resultView(exportDir)
            } else if let selection = appState.stackListSelection {
                selectionView(selection)
            } else {
                ProgressView().controlSize(.small)
            }

            if let lastError = appState.lastError {
                Text(lastError).foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
        .onAppear {
            appState.loadStackListSelection(target: target, date: date, keepFraction: keepFraction)
        }
        .onDisappear {
            appState.clearStackListSelection()
        }
    }

    @ViewBuilder
    private func selectionView(_ selection: StackSelection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kiválasztva: \(selection.selectedFrames) / \(selection.totalFrames)").font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(selection.criteria, id: \.self) { line in
                        Text("•  \(line)").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        }

        HStack {
            Spacer()
            if appState.isBusy {
                ProgressView().controlSize(.small)
            }
            Button("Mégse") { dismiss() }
            Button("Exportálás") { appState.exportStackList() }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.selectedFrames == 0 || appState.isBusy)
                .help(selection.selectedFrames == 0 ? "Nincs kiválasztható keret" : "")
        }
    }

    private func resultView(_ dir: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exportálva: \(dir.lastPathComponent)").font(.callout)
            Text(dir.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button("Bezárás") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
