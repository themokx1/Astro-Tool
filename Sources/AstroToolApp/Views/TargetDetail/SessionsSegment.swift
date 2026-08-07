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
    /// R11-T2: this segment's session rows now route through the shared
    /// `SessionActionMenu`, which needs an `AddTagSheet` trigger -- this
    /// segment had no tag add/remove of its own before (only
    /// `AllTargetsPage`'s session rows did).
    @State private var addingTag: AddTagTarget?

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
        .sheet(item: $addingTag) { info in
            AddTagSheet(target: info.target, date: info.date)
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

            TableColumn("README") { row in Text(row.detail.hasReadme ? "✓" : TDFormat.missingCell).foregroundStyle(.secondary) }
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
            .width(actionColumnWidth)
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

    /// R11-T2: now the shared `SessionActionMenu` -- `showOpenTarget: false`
    /// since this segment IS the target's own page already ("Célpont
    /// megnyitása" would be a no-op here), and `onRateFrames` keeps this
    /// segment's one deliberate difference: running the rate right in
    /// place (there's a Minőség segment one tab over to see the result in),
    /// rather than `AllTargetsPage`/`NightsPage`'s "navigate to Minőség
    /// with this date preselected" (they have no frame table of their own).
    private func contextMenuItems(for detail: SessionDetail) -> some View {
        SessionActionMenu(
            target: target,
            date: detail.dateRaw,
            tags: detail.tags,
            showOpenTarget: false,
            onRateFrames: { appState.runRate(target: target, date: detail.dateRaw) },
            linkingSession: $linkingSession,
            stackListingSession: $stackListingSession,
            noteEditingSession: $noteEditingSession,
            addingTag: $addingTag
        )
    }

    // MARK: - Cell text

    private func exposureSummary(_ breakdown: [String: Int]) -> String {
        guard !breakdown.isEmpty else { return TDFormat.missingCell }
        return breakdown
            .sorted { $0.key < $1.key }
            .map { key, count in
                if key == "unknown" { return "?×\(count)" }
                return "\(TDFormat.number(Double(key) ?? 0))s×\(count)"
            }
            .joined(separator: ", ")
    }

    private func fwhmText(for date: String) -> String {
        guard let summary = qualityByDate[date] else { return TDFormat.missingCell }
        if let arcsec = summary.medianFWHMArcsec { return String(format: "%.2f", arcsec) }
        if let px = summary.medianFWHMPixels { return String(format: "%.2f px", px) }
        return TDFormat.missingCell
    }

    private func backgroundText(for date: String) -> String {
        guard let value = qualityByDate[date]?.backgroundEPerSecPerArcsec2 else { return TDFormat.missingCell }
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
            Text(TDFormat.missingCell).foregroundStyle(.secondary)
        }
    }

    /// R11-T1: table-cell fallback -- "no `NightHealth` loaded yet for this
    /// date" is a missing VALUE in a dense grid, same convention every other
    /// column here already follows (was the one "n/a" holdout in a table
    /// cell). Not to be confused with `NightHealthReport` itself reporting
    /// "n/a — nincs hűtési adat" as an actual verdict once loaded -- that
    /// string flows through unchanged, `VerdictChip` colors it via its own
    /// fallback either way.
    private func coolerVerdict(for date: String) -> String { appState.targetNightHealthByDate[date]?.cooler.verdict ?? TDFormat.missingCell }
    private func focusVerdict(for date: String) -> String { appState.targetNightHealthByDate[date]?.focus.verdict ?? TDFormat.missingCell }

    /// R11-T1: Hűtés/Fókusz now render as the same `VerdictChip` every other
    /// state-verdict column in the app uses, instead of plain colored text.
    @ViewBuilder
    private func coolerCell(_ row: Row) -> some View {
        VerdictChip(verdict: coolerVerdict(for: row.detail.dateRaw))
    }

    @ViewBuilder
    private func focusCell(_ row: Row) -> some View {
        VerdictChip(verdict: focusVerdict(for: row.detail.dateRaw))
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
        parts.append("Ablak \(TDFormat.cell(timeline.windowSeconds.map(TDFormat.hm)))")
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
            Text("Hűtés: \(health.cooler.verdict)").foregroundStyle(VerdictChip.color(for: health.cooler.verdict))
            Text("·").foregroundStyle(.secondary)
            Text("Fókusz: \(health.focus.verdict)").foregroundStyle(VerdictChip.color(for: health.focus.verdict))
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
