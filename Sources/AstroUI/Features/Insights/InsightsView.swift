import AstroApplication
import AstroCore
import Charts
import SwiftUI

/// V2 UI/UX audit (2026-08-14) systemic pattern S8: this used to be a
/// `private final class` with `InsightsQuery.production` called directly
/// inside `load`, so this whole screen had zero unit-test surface. Follows
/// `LibraryHealthStore`'s query-factory injection pattern so tests can
/// supply a fixture-backed `InsightsQuery` without touching the
/// filesystem-resolving `production` constructor.
@MainActor
@Observable
public final class InsightsStore {
    public typealias QueryFactory = @Sendable (URL) throws -> InsightsQuery

    public private(set) var snapshot: InsightsSnapshot?
    public private(set) var availableYears: [Int] = []
    public private(set) var errorMessage: String?
    public private(set) var isLoading = false

    private let queryFactory: QueryFactory

    public init(queryFactory: @escaping QueryFactory = { rootURL in try InsightsQuery.production(rootURL: rootURL) }) {
        self.queryFactory = queryFactory
    }

    public func load(rootURL: URL?, year: Int? = nil) async {
        guard let rootURL else { snapshot = nil; return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await queryFactory(rootURL).snapshot(year: year)
            if year == nil, let snapshot {
                availableYears = Array(Set(snapshot.months.compactMap { Int($0.month.prefix(4)) })).sorted(by: >)
            }
        }
        catch { errorMessage = error.localizedDescription }
    }
}

public struct InsightsView: View {
    let librarySnapshot: LibrarySnapshot?
    let rootURL: URL?
    let chooseLibrary: () -> Void
    /// Consumed once, on this view's very first appearance -- `NightActionMenu`'s
    /// "Open in Insights" action presets the Setup Trends filter to the
    /// night's own setup via `AppRouter.navigateToInsights(presetSetupFilter:)`
    /// / `pendingInsightsSetupFilter`. `nil` leaves `selectedSetup` at its
    /// usual "All setups" default.
    let initialSetupFilter: String?
    @State private var store: InsightsStore
    @State private var selectedYear: Int?
    @State private var selectedSetup: String?

    public init(
        snapshot: LibrarySnapshot?,
        rootURL: URL?,
        initialSetupFilter: String? = nil,
        chooseLibrary: @escaping () -> Void,
        store: InsightsStore = InsightsStore()
    ) {
        self.librarySnapshot = snapshot
        self.rootURL = rootURL
        self.initialSetupFilter = initialSetupFilter
        self.chooseLibrary = chooseLibrary
        _store = State(initialValue: store)
        _selectedSetup = State(initialValue: initialSetupFilter)
    }

    public var body: some View {
        WorkspacePage(subtitle: "See what you photographed, how much signal you collected, and how your activity changes over time.") {
            if let insight = store.snapshot {
                Picker("Period", selection: $selectedYear) {
                    Text("All years").tag(Int?.none)
                    ForEach(store.availableYears, id: \.self) { year in
                        Text(String(year)).tag(Optional(year))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("v2.insights.period")
                .onChange(of: selectedYear) { _, year in
                    Task { await store.load(rootURL: rootURL, year: year) }
                }
                metrics(insight)
                if insight.hasDuplicateExposure {
                    Text("Duplicate frames in the index were counted once — raw index total before dedup: \(duration(insight.grossIntegrationSeconds))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                qualitySummary(insight)
                qualityTrends(insight)
                HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
                    activityChart(insight).frame(maxWidth: .infinity)
                    targetRanking(insight).frame(width: 320)
                }
                HStack(alignment: .top, spacing: AstroTokens.Spacing.standard) {
                    filterBreakdown(insight).frame(maxWidth: .infinity)
                    setupBreakdown(insight).frame(maxWidth: .infinity)
                }
                Label("Calculated from AstroTool's external read-only index", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            } else if store.isLoading {
                ProgressView("Calculating capture history…").frame(maxWidth: .infinity, minHeight: 280)
            } else if rootURL == nil {
                ContentUnavailableView {
                    Label("Open a library for insights", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("AstroTool will calculate nights, integration time and target history locally.")
                } actions: {
                    Button("Open Library…", action: chooseLibrary).buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "Insights unavailable", systemImage: "exclamationmark.triangle",
                    // V2 localization sweep (W3-13): `store.errorMessage` is
                    // `String?` -- `?? "..."` used to resolve the whole
                    // expression to `String`, so `Text(String)` picked the
                    // verbatim overload and the fallback phrase never
                    // localized. Two real `Text` values keep the dynamic
                    // message verbatim while the fallback goes through
                    // `Text`'s own `LocalizedStringKey` initializer.
                    description: store.errorMessage.map(Text.init) ?? Text("The external index does not contain reportable sessions yet.")
                )
            }
        }
        .navigationTitle("Insights")
        .accessibilityLabel("Insights")
        .accessibilityIdentifier("v2.detail.insights")
        .task(id: rootURL) { await store.load(rootURL: rootURL) }
    }

    private func qualityTrends(_ insight: InsightsSnapshot) -> some View {
        // Task 7 (2026-08-17, GroupBox removal): `GroupBox`'s opaque grey
        // panel is gone from here for good. Task 7c gives the section back a
        // real presence in the one shared way -- see the `.astroRaisedSurface()`
        // at the bottom of this function.
        VStack(alignment: .leading, spacing: 12) {
            Text("Session quality trends").font(.headline)
            HStack {
                Text("Compare measured sessions over time. Lower FWHM and background are better; higher efficiency is better.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Setup", selection: $selectedSetup) {
                    Text("All setups").tag(String?.none)
                    ForEach(insight.setupChoices, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .frame(maxWidth: 280)
            }
            HStack(alignment: .top, spacing: 12) {
                trendChart(
                    title: "FWHM",
                    unit: "arcsec / px",
                    points: trendData(insight) { point in point.fwhmValue?.value },
                    color: AstroTokens.Color.accent
                )
                trendChart(
                    title: "Background",
                    unit: "e⁻/s/arcsec²",
                    points: trendData(insight) { $0.backgroundEPerSecPerArcsec2 },
                    color: AstroTokens.Color.accent
                )
                trendChart(
                    title: "Efficiency",
                    unit: "%",
                    points: trendData(insight) { $0.efficiencyPercent },
                    color: AstroTokens.Color.accent
                )
            }
            recentTrendSessions(insight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Task 7c: ONE surface for this whole section. The three
        // `trendChart(...)` sub-blocks and `recentTrendSessions` inside it
        // stay bare on purpose -- they are groupings WITHIN a card, and
        // grouping within a card is a heading plus spacing, never a second
        // card. (Were one of them to grow its own `.astroRaisedSurface()`
        // anyway, the modifier's environment guard would collapse it rather
        // than paint the box-in-box the owner reported.)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.quality-trends")
    }

    private func trendData(
        _ insight: InsightsSnapshot,
        value: (TrendPoint) -> Double?
    ) -> [InsightTrendDatum] {
        insight.trendPoints.compactMap { point in
            guard selectedSetup == nil || point.setupDescriptor == selectedSetup,
                  let metric = value(point) else { return nil }
            return InsightTrendDatum(
                id: "\(point.target)|\(point.date)",
                date: point.sessionStartDate ?? point.date,
                target: point.target,
                value: metric
            )
        }
    }

    // V2 localization sweep (W3-13): `title` used to be a plain `String`
    // function parameter -- every call site (`"FWHM"`/`"Background"`/
    // `"Efficiency"`) passed a literal, but `Text(title)` inside this
    // function still resolved to the verbatim `StringProtocol` overload
    // because the PARAMETER's declared type, not the call-site literal,
    // decides which `Text` initializer is picked. "Background"/"Efficiency"
    // already had `hu.lproj` entries and still never localized; "FWHM" stays
    // untranslated on purpose either way (see `GlossaryView`'s own
    // convention -- technical vocabulary stays English, and this file's
    // `qualityMetricInfo`-style titles already follow it).
    private func trendChart(
        title: LocalizedStringKey,
        unit: String,
        points: [InsightTrendDatum],
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            // Task 6 (owner review wave 4-4): with fewer than two measured
            // sessions there is no TREND to draw -- a lone `PointMark` (one
            // dot, nothing to compare it to) or the old `ContentUnavailableView`
            // graphic both used to render here regardless, implying there
            // was something worth charting. `InsightTrendChartState` names
            // the honest reason instead; the chart itself only ever renders
            // once it can actually show a trend.
            switch InsightTrendChartState(pointCount: points.count) {
            case .noData, .singleSession:
                Text(InsightTrendChartState.unavailableMessage(pointCount: points.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
            case .trend:
                Chart(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value(unit, point.value))
                        .foregroundStyle(color)
                    PointMark(x: .value("Date", point.date), y: .value(unit, point.value))
                        .foregroundStyle(color)
                }
                .chartYAxisLabel(unit)
                // Task 6: this axis is categorical (one distinct `String`
                // session date per point, not a continuous scale), so Swift
                // Charts' own default -- one tick per category -- used to
                // cram a dozen-plus session dates into a third of the row's
                // width until every single label shrank to nothing but its
                // own ellipsis ("…"), worse than no label at all (the
                // Efficiency chart's own defect, since it typically has the
                // most measured sessions of the three). Explicit tick
                // values thin that down to real, readable dates.
                .chartXAxis {
                    AxisMarks(values: InsightTrendChartState.thinnedAxisDates(points.map(\.date))) { value in
                        AxisGridLine()
                        AxisTick()
                        if let date = value.as(String.self) {
                            AxisValueLabel(date)
                        }
                    }
                }
                .frame(minHeight: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentTrendSessions(_ insight: InsightsSnapshot) -> some View {
        let points = insight.trendPoints.filter {
            selectedSetup == nil || $0.setupDescriptor == selectedSetup
        }.suffix(8).reversed()
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow {
                Text("Recent session").font(.caption.weight(.semibold))
                Text("FWHM").font(.caption.weight(.semibold))
                Text("Background").font(.caption.weight(.semibold))
                Text("Efficiency").font(.caption.weight(.semibold))
                Text("Setup").font(.caption.weight(.semibold))
            }
            Divider().gridCellColumns(5)
            ForEach(Array(points), id: \.date) { point in
                GridRow {
                    Text("\(point.date) · \(point.target)").lineLimit(1)
                    Text(point.fwhmValue.map { $0.value.formatted(.number.precision(.fractionLength(2))) } ?? "—").monospacedDigit()
                    Text(point.backgroundEPerSecPerArcsec2?.formatted(.number.precision(.significantDigits(2...3))) ?? "—").monospacedDigit()
                    Text(point.efficiencyPercent.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? "—").monospacedDigit()
                    // `setupDescriptor` is arbitrary equipment data (never
                    // `nil` in a translatable sense) -- only the "Unknown"
                    // fallback is UI copy, so it alone needs to route
                    // through `Text`'s `LocalizedStringKey` initializer
                    // rather than the whole `?? "Unknown"` expression
                    // collapsing to `String` (same leak class as this file's
                    // other two `?? "..."` fallbacks above).
                    (point.setupDescriptor.map(Text.init) ?? Text("Unknown")).lineLimit(1)
                }
                .font(.caption)
            }
        }
        .accessibilityIdentifier("v2.insights.recent-quality-table")
    }

    private func metrics(_ insight: InsightsSnapshot) -> some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            MetricCard(title: "Integration", value: duration(insight.integrationSeconds), detail: "Deduplicated, verified exposure", systemImage: "timer")
            MetricCard(title: "Nights", value: "\(insight.nightCount)", detail: "Capture sessions", systemImage: "moon.stars")
            MetricCard(title: "Targets", value: "\(insight.targetCount)", detail: "Unique objects", systemImage: "scope")
            MetricCard(title: "Light frames", value: "\(insight.frameCount)", detail: "Indexed and present", systemImage: "photo.stack")
            MetricCard(title: "Average night", value: duration(insight.averageIntegrationPerNight), detail: averageNightDetail(insight), systemImage: "chart.bar.fill")
        }
    }

    // V2 localization sweep (W3-13): this used to build a plain `String` via
    // ordinary interpolation (`"Best month: \($0.month)"`) and wrap the
    // ALREADY-SUBSTITUTED result in `LocalizedStringKey(...)` afterward --
    // that produces a key equal to the finished sentence ("Best month:
    // March 2026"), which matches no `hu.lproj` entry, instead of a key with
    // a real `%@` argument ("Best month: %@", which DOES have one). Writing
    // the interpolation directly in a function whose return type is already
    // `LocalizedStringKey` (matching `SkyVerdictKind.displayLabel`'s own
    // pattern) keeps the substituted month a genuine format argument.
    private func averageNightDetail(_ insight: InsightsSnapshot) -> LocalizedStringKey {
        guard let bestMonth = insight.bestMonth else { return "No monthly data" }
        return "Best month: \(bestMonth.month)"
    }

    private func qualitySummary(_ insight: InsightsSnapshot) -> some View {
        // Task 7 (2026-08-17, GroupBox removal): heading plus spacing, same
        // reasoning as `qualityTrends` above.
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Capture efficiency").font(.headline)
            HStack(spacing: AstroTokens.Spacing.spacious) {
                Label("\(insight.usableFrameCount) usable", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AstroTokens.Color.ok)
                Label("\(insight.rejectedFrameCount) rejected", systemImage: "xmark.circle.fill")
                    .foregroundStyle(insight.rejectedFrameCount == 0 ? Color.secondary : AstroTokens.Color.attention)
                Spacer()
                Text(insight.captureEfficiency, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.quality")
    }

    private func filterBreakdown(_ insight: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Filters and passbands").font(.headline)
            ForEach(insight.filterUsage.prefix(8)) { item in
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(AstroTokens.Color.accent)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text("\(item.frameCount) · \(duration(item.integrationSeconds))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if insight.filterUsage.isEmpty {
                Text("No filter metadata yet").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.filters")
    }

    private func setupBreakdown(_ insight: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Equipment usage").font(.headline)
            ForEach(insight.setupUsage.prefix(8)) { item in
                HStack {
                    Image(systemName: "camera.aperture")
                        .foregroundStyle(AstroTokens.Color.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.camera).lineLimit(1)
                        if let focalLength = item.focalLength {
                            Text("\(focalLength.formatted(.number.precision(.fractionLength(0...1)))) mm")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(item.frameCount) · \(duration(item.integrationSeconds))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if insight.setupUsage.isEmpty {
                Text("No equipment metadata yet").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
        .accessibilityIdentifier("v2.insights.equipment")
    }

    private func activityChart(_ insight: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Capture activity").font(.headline)
            Chart(insight.months) { month in
                BarMark(x: .value("Month", month.month), y: .value("Hours", month.integrationSeconds / 3600))
                    .foregroundStyle(AstroTokens.Color.accent.gradient)
                    .cornerRadius(4)
            }
            .chartYAxisLabel("Integration hours")
            .frame(minHeight: 260)
            .accessibilityIdentifier("v2.insights.activity")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
    }

    private func targetRanking(_ insight: InsightsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AstroTokens.Spacing.compact) {
            Text("Most photographed").font(.headline)
            ForEach(Array(insight.topTargets.enumerated()), id: \.element.id) { index, target in
                HStack {
                    Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.target).lineLimit(1)
                        Text("\(duration(target.integrationSeconds)) · \(target.nightCount) nights")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            if insight.topTargets.isEmpty { Text("No light frames yet").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .astroRaisedSurface()
    }

    private func duration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

}

private struct InsightTrendDatum: Identifiable {
    let id: String
    let date: String
    let target: String
    let value: Double
}

/// W4-4 item 6 (owner review): "with <2 measured sessions the three trend
/// charts render" a lone dot, an empty-state graphic, and an x-axis of
/// nothing but "…" -- three different symptoms of the same underlying
/// problem, a chart drawn for data that cannot show a trend. This is the
/// honest classification `InsightsView.trendChart` switches on instead of
/// rendering `Chart` unconditionally; `internal` (not `private`), so
/// `InsightTrendChartStateTests` can exercise it directly without rendering
/// a view.
enum InsightTrendChartState: Equatable {
    /// No session has a measured value for this metric at all.
    case noData
    /// Exactly one session does -- a single point has nothing to compare
    /// against and cannot show a trend, even though `Chart` would happily
    /// draw one lone dot.
    case singleSession
    /// Two or more measured sessions -- enough to actually show a trend.
    case trend

    init(pointCount: Int) {
        switch pointCount {
        case 0: self = .noData
        case 1: self = .singleSession
        default: self = .trend
        }
    }

    /// The owner's own two phrasings ("1 mért session — a trendhez több
    /// mérés kell" / "Nincsenek mért értékek") -- hand-added at the
    /// `hu.lproj` tail since both keys reach `Text` through a ternary here,
    /// which the extraction script does not see. Never called for
    /// `.trend`, which renders the chart itself instead.
    static func unavailableMessage(pointCount: Int) -> LocalizedStringKey {
        pointCount == 1
            ? "Only one measured session — more measurements are needed for a trend"
            : "No measured values"
    }

    /// Caps how many x-axis ticks a categorical (`String`-dated) trend
    /// chart draws. With one tick per session and a dozen-plus measured
    /// sessions crammed into a third of the row's width, Swift Charts used
    /// to shrink every single label down to nothing but its own ellipsis
    /// ("…") -- worse than no label at all (the Efficiency chart's own
    /// defect, since it typically has the most measured sessions of the
    /// three). Every Nth date, capped at `maxTicks`, keeps each surviving
    /// label wide enough to actually read; below `maxTicks` sessions, every
    /// date still gets its own tick, exactly as before this task.
    static func thinnedAxisDates(_ dates: [String], maxTicks: Int = 6) -> [String] {
        guard dates.count > maxTicks else { return dates }
        let stride = Int((Double(dates.count) / Double(maxTicks)).rounded(.up))
        return dates.enumerated().compactMap { index, date in
            index.isMultiple(of: stride) ? date : nil
        }
    }
}
