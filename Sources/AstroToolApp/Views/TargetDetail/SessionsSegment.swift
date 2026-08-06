import AppKit
import AstroCore
import SwiftUI

/// R9-T3/A.3's "Sessionök" segment: the 10-column session table plus an
/// inline detail band (timeline sentence + horizontal timeline bar +
/// hardware-health line + README notes) below it once a row is selected.
struct SessionsSegment: View {
    @Environment(AppState.self) private var appState
    let target: String
    @Binding var linkingSession: LinkingSession?
    @Binding var stackListingSession: LinkingSession?

    @State private var selectedDate: String?
    /// The session currently shown in `SessionNoteSheet` (R9-T6/B4), `nil`
    /// when closed -- kept local (not a `@Binding` like the other two sheet
    /// triggers) since no other segment/context menu on this page needs to
    /// open the same sheet.
    @State private var noteEditingSession: LinkingSession?

    private struct Row: Identifiable {
        let id: String
        let detail: SessionDetail
    }

    private var rows: [Row] {
        (appState.sessionDetailsByTarget[target] ?? [])
            .sorted { $0.dateRaw < $1.dateRaw }
            .map { Row(id: $0.dateRaw, detail: $0) }
    }

    private var qualityByDate: [String: SessionQualitySummary] {
        Dictionary(uniqueKeysWithValues: appState.qualitySummaries.map { ($0.date, $0) })
    }

    /// R9-T6/B16(a): this table's own computed-metric columns, explained --
    /// see `MetricInfoButton`'s doc comment for why this is one button per
    /// table rather than one popover per column header.
    private static let sessionMetricInfo: [MetricInfoButton.Metric] = [
        .init(
            title: "FWHM″",
            explanation: "A session kerete(i) félértékszélessége ívmásodpercben (pixelméret+fókusz ismeretében) vagy pixelben. Mikor hazudik: pontozás nélkül „-”; \"Siril nélkül\" pontozásnál is mindig „-”."
        ),
        .init(
            title: "Háttér e⁻/s/″²",
            explanation: "A session égi hátterének valódi elektron/másodperc/ívmásodperc² rátája. Mikor hazudik: mért szenzor-profil nélkül (Szenzor-profilok oldal) ez nem számolható, „-” marad."
        ),
        .init(
            title: "Rang",
            explanation: "A session sorrendje a célpont összes sessionje között, a pontszám-medián szerint (1 = legjobb). Mikor hazudik: kevés pontozott kerettel a rangsor néhány zajos mérésen alapul."
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nincs session ehhez a célponthoz",
                    systemImage: "calendar.badge.exclamationmark"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Spacer()
                    MetricInfoButton(metrics: Self.sessionMetricInfo)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                table
                if let selectedDate, let row = rows.first(where: { $0.id == selectedDate }) {
                    Divider()
                    detailBand(for: row.detail)
                }
            }
        }
        .sheet(item: $noteEditingSession) { session in
            SessionNoteSheet(target: session.target, date: session.date)
        }
    }

    private var table: some View {
        Table(rows, selection: $selectedDate) {
            TableColumn("Dátum") { row in
                HStack(spacing: 4) {
                    Text(row.detail.dateRaw)
                    if row.detail.isExcludedFromTotals {
                        Text("kizárva").font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            .width(min: 90, ideal: 100)

            TableColumn("Keretek") { row in Text("\(row.detail.usableLightCount)") }
                .width(min: 60, ideal: 70)

            TableColumn("Integráció") { row in Text(TDFormat.hm(row.detail.integrationSeconds)) }
                .width(min: 80, ideal: 90)

            TableColumn("Expozíciók") { row in
                Text(exposureSummary(row.detail.exposureBreakdown))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 100, ideal: 140)

            TableColumn("FWHM″") { row in Text(fwhmText(for: row.detail.dateRaw)) }
                .width(min: 60, ideal: 70)

            TableColumn("Háttér e⁻/s/″²") { row in Text(backgroundText(for: row.detail.dateRaw)) }
                .width(min: 90, ideal: 110)

            TableColumn("Rang") { row in rankChip(for: row.detail.dateRaw) }
                .width(min: 60, ideal: 70)

            // R10-B7: grouped so the table stays AT (not over) `Table`'s
            // 10-top-level-column cap once the trailing "⋯" actions column
            // below needs its own slot -- same `Group { }` workaround
            // `QualitySegment.frameTable` already established. Routed
            // through `coolerCell`/`focusCell` (rather than inlining
            // `Text(...).foregroundStyle(...)` directly) since even a
            // helper-function-composed expression inline in a `Group { }`
            // cell closure hit the same "cannot infer closure parameter
            // type" error `CalibrationPage`'s R10-B7 fix hit -- wrapping
            // the whole cell body in its own `@ViewBuilder` gives the
            // type-checker a concrete anchor instead.
            Group {
                TableColumn("Hűtés") { row in coolerCell(row) }
                    .width(min: 80, ideal: 100)

                TableColumn("Fókusz") { row in focusCell(row) }
                    .width(min: 80, ideal: 100)
            }

            TableColumn("README") { row in Text(row.detail.hasReadme ? "✓" : "-").foregroundStyle(.secondary) }
                .width(min: 50, ideal: 60)

            // R10-B7: visible row-actions -- mirrors `contextMenuItems(for:)`
            // exactly (same function, both call sites), so the right-click
            // menu and this borderless "⋯" button can never drift apart.
            TableColumn("") { row in
                Menu {
                    contextMenuItems(for: row.detail)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .width(36)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if let date = ids.first, let row = rows.first(where: { $0.id == date }) {
                contextMenuItems(for: row.detail)
            }
        }
        .onChange(of: selectedDate) { _, newDate in
            if let newDate {
                appState.loadSessionTimeline(target: target, date: newDate)
            }
        }
        .onAppear { consumePendingSelection() }
        .onChange(of: appState.sessionDetailsByTarget[target]) { _, _ in consumePendingSelection() }
    }

    /// R9-T6/B3: a search-result session/note hit sets
    /// `AppState.pendingSessionSelection` before navigating here -- select
    /// that row (and load its timeline, same as a normal click) as soon as
    /// it actually appears in `rows`, then clear the pending value so it's
    /// only ever consumed once.
    private func consumePendingSelection() {
        guard let pending = appState.pendingSessionSelection, rows.contains(where: { $0.id == pending }) else { return }
        selectedDate = pending
        appState.pendingSessionSelection = nil
        appState.loadSessionTimeline(target: target, date: pending)
    }

    @ViewBuilder
    private func contextMenuItems(for detail: SessionDetail) -> some View {
        Button("Megnyitás Finderben") { revealInFinder(date: detail.dateRaw) }
        Divider()
        Button("Kalibráció linkelése…") { linkingSession = LinkingSession(target: target, date: detail.dateRaw) }
        Button("Stackelés előkészítése…") { stackListingSession = LinkingSession(target: target, date: detail.dateRaw) }
        Divider()
        Button("Keretek pontozása") { appState.runRate(target: target, date: detail.dateRaw) }
        Button("Éjszaka-riport készítése") { appState.exportNightReport(target: target, date: detail.dateRaw) }
        Button("Éjszaka-jegyzet szerkesztése…") { noteEditingSession = LinkingSession(target: target, date: detail.dateRaw) }
    }

    private func revealInFinder(date: String) {
        let url = URL(fileURLWithPath: appState.config.rootPath, isDirectory: true)
            .appendingPathComponent("sessions/\(target)/\(date)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Cell text

    private func exposureSummary(_ breakdown: [String: Int]) -> String {
        guard !breakdown.isEmpty else { return "-" }
        return breakdown
            .sorted { $0.key < $1.key }
            .map { key, count in
                if key == "unknown" { return "?×\(count)" }
                return "\(TDFormat.number(Double(key) ?? 0))s×\(count)"
            }
            .joined(separator: ", ")
    }

    private func fwhmText(for date: String) -> String {
        guard let summary = qualityByDate[date] else { return "-" }
        if let arcsec = summary.medianFWHMArcsec { return String(format: "%.2f", arcsec) }
        if let px = summary.medianFWHMPixels { return String(format: "%.2f px", px) }
        return "-"
    }

    private func backgroundText(for date: String) -> String {
        guard let value = qualityByDate[date]?.backgroundEPerSecPerArcsec2 else { return "-" }
        return String(format: "%.4f", value)
    }

    @ViewBuilder
    private func rankChip(for date: String) -> some View {
        if let summary = qualityByDate[date], let rank = summary.rankAmongSessions, let total = summary.sessionCountForTarget {
            Text("\(rank)/\(total)")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill((rank == 1 ? Color.green : Color.secondary).opacity(0.2)))
        } else {
            Text("-").foregroundStyle(.secondary)
        }
    }

    private func coolerVerdict(for date: String) -> String { appState.targetNightHealthByDate[date]?.cooler.verdict ?? "n/a" }
    private func focusVerdict(for date: String) -> String { appState.targetNightHealthByDate[date]?.focus.verdict ?? "n/a" }
    private func coolerText(for date: String) -> String { coolerVerdict(for: date) }
    private func focusText(for date: String) -> String { focusVerdict(for: date) }

    @ViewBuilder
    private func coolerCell(_ row: Row) -> some View {
        Text(coolerText(for: row.detail.dateRaw)).foregroundStyle(verdictColor(coolerVerdict(for: row.detail.dateRaw)))
    }

    @ViewBuilder
    private func focusCell(_ row: Row) -> some View {
        Text(focusText(for: row.detail.dateRaw)).foregroundStyle(verdictColor(focusVerdict(for: row.detail.dateRaw)))
    }

    private func verdictColor(_ verdict: String) -> Color {
        if verdict == "stabil" || verdict == "stabil fókusz" { return .green }
        if verdict.contains("gyanú") || verdict.contains("nem tartja") { return .orange }
        return .secondary
    }

    // MARK: - Inline detail band

    private func detailBand(for detail: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let timeline = appState.sessionTimeline, timeline.date == detail.dateRaw {
                Text(timelineSentence(timeline))
                    .font(.callout)
                timelineBar(timeline)
                if let health = appState.nightHealth, health.date == detail.dateRaw {
                    hardwareHealthLine(health)
                }
            } else {
                ProgressView().controlSize(.small)
            }

            if !detail.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("README").font(.caption).bold()
                    ForEach(detail.notes.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(detail.notes[key] ?? "")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
    }

    /// "Ablak 3:42 · integráció 2:11 · hatékonyság 59% · 2 kiesés (37m, 12m)"
    private func timelineSentence(_ timeline: SessionTimeline) -> String {
        var parts: [String] = []
        parts.append("Ablak \(timeline.windowSeconds.map(TDFormat.hm) ?? "-")")
        parts.append("integráció \(TDFormat.hm(timeline.integrationSeconds))")
        if let dutyCycle = timeline.dutyCycle {
            parts.append("hatékonyság \(TDFormat.percent(dutyCycle * 100))")
        }
        if timeline.gaps.isEmpty {
            parts.append("nincs kiesés")
        } else {
            let gapList = timeline.gaps.map { "\(Int(($0.seconds / 60).rounded()))m" }.joined(separator: ", ")
            parts.append("\(timeline.gaps.count) kiesés (\(gapList))")
        }
        return parts.joined(separator: " · ")
    }

    private func hardwareHealthLine(_ health: NightHealthReport) -> some View {
        HStack(spacing: 4) {
            Text("Hűtés: \(health.cooler.verdict)").foregroundStyle(verdictColor(health.cooler.verdict))
            Text("·").foregroundStyle(.secondary)
            Text("Fókusz: \(health.focus.verdict)").foregroundStyle(verdictColor(health.focus.verdict))
        }
        .font(.caption)
    }

    // MARK: - Timeline bar (ported from NightReport.renderTimelineBar's CSS-bar concept)

    private struct BarSegment: Identifiable {
        let id: Int
        let widthFraction: Double
        let isGap: Bool
        let gapMinutes: Int?
    }

    /// Same alternating "active"/"gap" segment computation
    /// `NightReport.renderTimelineBar` uses for its CSS bar, ported to
    /// SwiftUI: a `GeometryReader`-driven `HStack` of proportionally-sized
    /// rectangles -- filled (accent color) for integration, gray for a gap,
    /// with the gap's minute count as a caption when the segment is wide
    /// enough to read.
    private func barSegments(_ timeline: SessionTimeline) -> [BarSegment]? {
        guard let startISO = timeline.windowStart, let endISO = timeline.windowEnd,
              let start = TDFormat.isoZFormatter.date(from: startISO),
              let end = TDFormat.isoZFormatter.date(from: endISO),
              let windowSeconds = timeline.windowSeconds, windowSeconds > 0
        else { return nil }

        var segments: [BarSegment] = []
        var cursor = start
        var index = 0
        for gap in timeline.gaps.sorted(by: { $0.start < $1.start }) {
            guard let gapStart = TDFormat.isoZFormatter.date(from: gap.start),
                  let gapEnd = TDFormat.isoZFormatter.date(from: gap.end)
            else { continue }
            let activeSeconds = gapStart.timeIntervalSince(cursor)
            if activeSeconds > 0 {
                segments.append(BarSegment(id: index, widthFraction: activeSeconds / windowSeconds, isGap: false, gapMinutes: nil))
                index += 1
            }
            segments.append(BarSegment(
                id: index, widthFraction: gap.seconds / windowSeconds, isGap: true,
                gapMinutes: Int((gap.seconds / 60).rounded())
            ))
            index += 1
            cursor = gapEnd
        }
        let trailing = end.timeIntervalSince(cursor)
        if trailing > 0 {
            segments.append(BarSegment(id: index, widthFraction: trailing / windowSeconds, isGap: false, gapMinutes: nil))
        }
        return segments
    }

    @ViewBuilder
    private func timelineBar(_ timeline: SessionTimeline) -> some View {
        if let segments = barSegments(timeline) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        ZStack {
                            (segment.isGap ? Color.secondary.opacity(0.25) : Color.accentColor)
                            if segment.isGap, let minutes = segment.gapMinutes, segment.widthFraction * geo.size.width > 26 {
                                Text("\(minutes)m").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: max(1, geo.size.width * segment.widthFraction))
                    }
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Text("Nincs elég DATE-OBS adat az idővonalhoz.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
