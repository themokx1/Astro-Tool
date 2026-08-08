import AstroCore
import Charts
import SwiftUI

/// R11-T10/F7 "Trendek" page (sidebar ÁLLAPOT section, no `⌘`-shortcut):
/// long-term session-level time series across every target -- median
/// FWHM″ (px-fallback points marked distinctly), background e⁻/s/″², and
/// hatékonyság% (duty cycle), each a point-plus-moving-average chart.
/// Backed by `AppState.trendPoints` (`TrendQueries.points`, loaded
/// UNFILTERED exactly once) -- every control below (time range, setup,
/// target type) filters CLIENT-SIDE, the same "load once, filter locally"
/// split `NightsPage`'s year/month Picker already established. Clicking a
/// point navigates to that session (`TargetDetailPage`'s Sessionök
/// szegmens), the same `pendingTargetSegment`/`pendingSessionSelection`
/// hand-off `PreviousNightPage`'s cards already use.
struct TrendsPage: View {
    @Environment(AppState.self) private var appState

    private enum TimeRange: String, CaseIterable, Identifiable {
        case sixMonths, oneYear, threeYears, all
        var id: String { rawValue }

        var label: String {
            switch self {
            case .sixMonths: return "6 hónap"
            case .oneYear: return "1 év"
            case .threeYears: return "3 év"
            case .all: return "Mind"
            }
        }

        /// The earliest session start date this range includes -- `nil`
        /// for `.all` (no lower bound at all).
        func cutoff(from now: Date) -> Date? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            switch self {
            case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: now)
            case .oneYear: return calendar.date(byAdding: .year, value: -1, to: now)
            case .threeYears: return calendar.date(byAdding: .year, value: -3, to: now)
            case .all: return nil
            }
        }
    }

    private enum TargetTypeFilter: String, CaseIterable, Identifiable {
        case all, wideField, deepSky
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "Mind"
            case .wideField: return "Wide-field"
            case .deepSky: return "Deep-sky"
            }
        }
    }

    @State private var timeRange: TimeRange = .all
    @State private var selectedSetup: String?
    @State private var targetType: TargetTypeFilter = .all

    /// Minimum session count IN THE ACTIVE FILTER before the charts show at
    /// all -- same "don't trend a handful of points" floor
    /// `QualitySegment.minFWHMPointsForTrend` already uses for its own
    /// (much narrower) per-session FWHM-over-the-night chart.
    private static let minPointsForCharts = 5

    private var allPoints: [TrendPoint] { appState.trendPoints ?? [] }

    private var distinctSetups: [String] {
        TrendQueries.distinctSetupDescriptors(allPoints)
    }

    /// `TargetStats.isWideField`, keyed by target -- `appState.stats` is
    /// already loaded for every other page that needs a target's wide-
    /// field/deep-sky classification, so the target-type filter reuses it
    /// rather than re-deriving `WideFieldHeuristic` here.
    private var isWideFieldByTarget: [String: Bool] {
        Dictionary(uniqueKeysWithValues: appState.stats.map { ($0.target, $0.isWideField) })
    }

    private var hasActiveFilter: Bool {
        timeRange != .all || selectedSetup != nil || targetType != .all
    }

    private var filteredPoints: [TrendPoint] {
        let cutoff = timeRange.cutoff(from: Date())
        return allPoints.filter { point in
            if let cutoff {
                guard let startText = point.sessionStartDate, let start = Self.ymdFormatter.date(from: startText),
                      start >= cutoff
                else { return false }
            }
            if let selectedSetup, point.setupDescriptor != selectedSetup { return false }
            switch targetType {
            case .all: break
            case .wideField: guard isWideFieldByTarget[point.target] == true else { return false }
            case .deepSky: guard isWideFieldByTarget[point.target] == false else { return false }
            }
            return true
        }
    }

    var body: some View {
        Group {
            if appState.trendPoints == nil {
                if appState.isBusy {
                    ProgressView(appState.progressText)
                } else {
                    notLoadedState
                }
            } else if filteredPoints.count < Self.minPointsForCharts {
                tooFewSessionsState
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    // R12-U1 item 5: only once there's actually something to
                    // refresh -- `notLoadedState`'s own "Betöltés" button
                    // already covers the "never loaded yet" case.
                    if appState.trendPoints != nil {
                        if appState.isBusy {
                            ProgressView().controlSize(.small)
                        }
                        Button("Frissítés") { appState.loadTrends() }
                            .disabled(appState.isBusy || appState.db == nil)
                    }
                    filterMenu
                }
            }
        }
        .onAppear {
            // R12-U1 item 5: a session row's "Megnyitás a Trendeken" action
            // (`SessionActionMenu`) sets this right before navigating here --
            // consumed once, same "set, navigate, consume on appear" pattern
            // `pendingTargetSegment`/`pendingSessionSelection` establish. A
            // `nil` pending value (a session with no derivable dominant
            // setup) needs no special handling here -- `selectedSetup`
            // already starts `nil` on a freshly created page.
            if let pending = appState.pendingTrendsSetupFilter {
                selectedSetup = pending
                appState.pendingTrendsSetupFilter = nil
            }
            if appState.trendPoints == nil && !appState.isBusy { appState.loadTrends() }
        }
    }

    // MARK: - Empty states

    private var notLoadedState: some View {
        ContentUnavailableView {
            Label("Még nincs betöltve", systemImage: "chart.xyaxis.line")
        } description: {
            Text("Töltsd be a könyvtár session-idősorait, hogy a hosszú távú trendeket láthasd.")
        } actions: {
            Button("Betöltés") { appState.loadTrends() }
                .disabled(appState.db == nil)
        }
    }

    private var tooFewSessionsState: some View {
        ContentUnavailableView {
            Label("Kevés adat a trendekhez", systemImage: "chart.xyaxis.line")
        } description: {
            Text(
                hasActiveFilter
                    ? "A jelenlegi szűrővel csak \(filteredPoints.count) session van (legalább \(Self.minPointsForCharts) kellene). Próbáld tágabbra venni az időtartományt, vagy törölni a szűrőt."
                    : "Eddig csak \(filteredPoints.count) mért/pontozott session van (legalább \(Self.minPointsForCharts) kellene a trendekhez). Pontozz több sessiont, vagy várj, amíg több anyag gyűlik össze."
            )
        } actions: {
            if hasActiveFilter {
                Button("Szűrők törlése") {
                    timeRange = .all
                    selectedSetup = nil
                    targetType = .all
                }
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Időtartomány", selection: $timeRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TrendChartCard(
                        title: "Medián FWHM″",
                        points: fwhmChartPoints,
                        yAxisLabel: "FWHM",
                        valueFormat: { String(format: "%.2f″", $0) },
                        onSelect: openSession
                    )
                    TrendChartCard(
                        title: "Háttér (e⁻/s/″²)",
                        points: backgroundChartPoints,
                        yAxisLabel: "e⁻/s/″²",
                        valueFormat: { String(format: "%.4f", $0) },
                        onSelect: openSession
                    )
                    TrendChartCard(
                        title: "Hatékonyság%",
                        points: efficiencyChartPoints,
                        yAxisLabel: "%",
                        valueFormat: { String(format: "%.0f%%", $0) },
                        onSelect: openSession
                    )
                }
            }
        }
    }

    // MARK: - Chart point extraction

    /// `yyyy-MM-dd`, UTC -- parses `TrendPoint.sessionStartDate` back into a
    /// `Date` purely for charting/range-filtering; a point with no
    /// parseable start date is simply excluded from every chart (there's no
    /// sane x-axis position for it), same stance the core query itself
    /// takes for an active `from`/`to` filter.
    private static let ymdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var fwhmChartPoints: [TrendChartPoint] {
        filteredPoints.compactMap { point -> TrendChartPoint? in
            guard let startText = point.sessionStartDate, let time = Self.ymdFormatter.date(from: startText),
                  let fwhm = point.fwhmValue
            else { return nil }
            return TrendChartPoint(
                target: point.target, date: point.date, time: time,
                value: fwhm.value, isPixelFallback: fwhm.isPixelFallback
            )
        }.sorted { $0.time < $1.time }
    }

    private var backgroundChartPoints: [TrendChartPoint] {
        filteredPoints.compactMap { point -> TrendChartPoint? in
            guard let startText = point.sessionStartDate, let time = Self.ymdFormatter.date(from: startText),
                  let value = point.backgroundEPerSecPerArcsec2
            else { return nil }
            return TrendChartPoint(target: point.target, date: point.date, time: time, value: value, isPixelFallback: false)
        }.sorted { $0.time < $1.time }
    }

    private var efficiencyChartPoints: [TrendChartPoint] {
        filteredPoints.compactMap { point -> TrendChartPoint? in
            guard let startText = point.sessionStartDate, let time = Self.ymdFormatter.date(from: startText),
                  let value = point.efficiencyPercent
            else { return nil }
            return TrendChartPoint(target: point.target, date: point.date, time: time, value: value, isPixelFallback: false)
        }.sorted { $0.time < $1.time }
    }

    /// A chart point tapped/selected -- navigates straight to that
    /// session's card on the target-detail page's Sessionök szegmens, same
    /// hand-off `PreviousNightPage.cardView`'s title button already uses.
    private func openSession(target: String, date: String) {
        appState.pendingTargetSegment = .sessions
        appState.pendingSessionSelection = date
        appState.currentPage = .target(target)
    }

    // MARK: - Toolbar filter menu

    private var filterMenu: some View {
        Menu {
            Menu(selectedSetup.map { "Setup: \($0)" } ?? "Setup: Mind") {
                Button {
                    selectedSetup = nil
                } label: {
                    HStack {
                        if selectedSetup == nil { Image(systemName: "checkmark") }
                        Text("Minden setup")
                    }
                }
                ForEach(distinctSetups, id: \.self) { setup in
                    Button {
                        selectedSetup = setup
                    } label: {
                        HStack {
                            if selectedSetup == setup { Image(systemName: "checkmark") }
                            Text(setup)
                        }
                    }
                }
            }
            Menu("Célpont típusa: \(targetType.label)") {
                ForEach(TargetTypeFilter.allCases) { option in
                    Button {
                        targetType = option
                    } label: {
                        HStack {
                            if targetType == option { Image(systemName: "checkmark") }
                            Text(option.label)
                        }
                    }
                }
            }
        } label: {
            Label("Szűrők", systemImage: "line.3.horizontal.decrease.circle")
        }
    }
}

/// One chart-plottable point -- shared shape for all three `TrendsPage`
/// metrics (`TrendChartCard`'s own input), built from `TrendPoint` by
/// `TrendsPage`'s own `fwhmChartPoints`/`backgroundChartPoints`/
/// `efficiencyChartPoints`.
private struct TrendChartPoint: Identifiable {
    let target: String
    let date: String
    let time: Date
    let value: Double
    /// `true` only for a `fwhmChartPoints` entry whose arcsec value was
    /// unavailable and fell back to the raw pixel FWHM (`TrendPoint
    /// .fwhmValue`'s own doc comment) -- always `false` for the other two
    /// metrics.
    let isPixelFallback: Bool
    var id: String { "\(target)|\(date)" }
}

/// One metric's point-plus-moving-average chart card -- pure presentation,
/// reused three times by `TrendsPage.content` with a different point set
/// each time. `points` must already be sorted ascending by `time`.
private struct TrendChartCard: View {
    let title: String
    let points: [TrendChartPoint]
    let yAxisLabel: String
    let valueFormat: (Double) -> String
    let onSelect: (_ target: String, _ date: String) -> Void

    /// `TrendMath.movingAverage`'s default 5-point trailing window --
    /// `points` never has gaps (every entry here already HAS this metric,
    /// see `TrendsPage`'s own `compactMap`), so this is a plain trailing
    /// average with no "skip the nil" behavior actually exercised.
    private var movingAverage: [Double?] {
        TrendMath.movingAverage(points.map(\.value))
    }

    private var hasPixelFallback: Bool {
        points.contains(where: \.isPixelFallback)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.bold())
                if let last = points.last {
                    Text("legutóbbi: \(valueFormat(last.value))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if hasPixelFallback {
                    legend
                }
            }

            if points.isEmpty {
                Text("Nincs adat ehhez a metrikához a jelenlegi szűrővel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                chart
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Circle().stroke(Color.accentColor, lineWidth: 1.5).frame(width: 8, height: 8)
            Text("px-becslés (nincs pixel-skála)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                PointMark(x: .value("Dátum", point.time), y: .value(title, point.value))
                    .foregroundStyle(Color.accentColor)
                    .symbol {
                        if point.isPixelFallback {
                            Circle().stroke(Color.accentColor, lineWidth: 1.5).frame(width: 7, height: 7)
                        } else {
                            Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        }
                    }
                if let average = movingAverage[index] {
                    LineMark(x: .value("Dátum", point.time), y: .value("Mozgóátlag", average))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
        .chartLegend(.hidden)
        .chartYAxisLabel(yAxisLabel)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { drag in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let origin = geometry[plotFrame].origin
                                let locationX = drag.location.x - origin.x
                                guard let time: Date = proxy.value(atX: locationX) else { return }
                                guard let nearest = points.min(by: {
                                    abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time))
                                }) else { return }
                                onSelect(nearest.target, nearest.date)
                            }
                    )
            }
        }
        .frame(height: 160)
    }
}
