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
        WorkspacePage(eyebrow: "Long-term signal", title: "Insights", subtitle: "See what you photographed, how much signal you collected, and how your activity changes over time.") {
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
                    description: Text(store.errorMessage ?? "The external index does not contain reportable sessions yet.")
                )
            }
        }
        .navigationTitle("Insights")
        .accessibilityLabel("Insights")
        .accessibilityIdentifier("v2.detail.insights")
        .task(id: rootURL) { await store.load(rootURL: rootURL) }
    }

    private func qualityTrends(_ insight: InsightsSnapshot) -> some View {
        GroupBox("Session quality trends") {
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(8)
        }
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

    private func trendChart(
        title: String,
        unit: String,
        points: [InsightTrendDatum],
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if points.isEmpty {
                ContentUnavailableView("No measured values", systemImage: "chart.xyaxis.line")
                    .frame(minHeight: 150)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value(unit, point.value))
                        .foregroundStyle(color)
                    PointMark(x: .value("Date", point.date), y: .value(unit, point.value))
                        .foregroundStyle(color)
                }
                .chartYAxisLabel(unit)
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
                    Text(point.setupDescriptor ?? "Unknown").lineLimit(1)
                }
                .font(.caption)
            }
        }
        .accessibilityIdentifier("v2.insights.recent-quality-table")
    }

    private func metrics(_ insight: InsightsSnapshot) -> some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            MetricCard(title: "Integration", value: duration(insight.integrationSeconds), detail: "Verified light exposure", systemImage: "timer")
            MetricCard(title: "Nights", value: "\(insight.nightCount)", detail: "Capture sessions", systemImage: "moon.stars")
            MetricCard(title: "Targets", value: "\(insight.targetCount)", detail: "Unique objects", systemImage: "scope")
            MetricCard(title: "Light frames", value: "\(insight.frameCount)", detail: "Indexed and present", systemImage: "photo.stack")
            MetricCard(title: "Average night", value: duration(insight.averageIntegrationPerNight), detail: LocalizedStringKey(insight.bestMonth.map { "Best month: \($0.month)" } ?? "No monthly data"), systemImage: "chart.bar.fill")
        }
    }

    private func qualitySummary(_ insight: InsightsSnapshot) -> some View {
        GroupBox("Capture efficiency") {
            HStack(spacing: AstroTokens.Spacing.spacious) {
                Label("\(insight.usableFrameCount) usable", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AstroTokens.Color.ok)
                Label("\(insight.rejectedFrameCount) rejected", systemImage: "xmark.circle.fill")
                    .foregroundStyle(insight.rejectedFrameCount == 0 ? Color.secondary : AstroTokens.Color.attention)
                Spacer()
                Text(insight.captureEfficiency, format: .percent.precision(.fractionLength(0)))
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
            .padding(8)
        }
        .accessibilityIdentifier("v2.insights.quality")
    }

    private func filterBreakdown(_ insight: InsightsSnapshot) -> some View {
        GroupBox("Filters and passbands") {
            VStack(alignment: .leading, spacing: 10) {
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
            }.padding(8)
        }
        .accessibilityIdentifier("v2.insights.filters")
    }

    private func setupBreakdown(_ insight: InsightsSnapshot) -> some View {
        GroupBox("Equipment usage") {
            VStack(alignment: .leading, spacing: 10) {
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
            }.padding(8)
        }
        .accessibilityIdentifier("v2.insights.equipment")
    }

    private func activityChart(_ insight: InsightsSnapshot) -> some View {
        GroupBox("Capture activity") {
            Chart(insight.months) { month in
                BarMark(x: .value("Month", month.month), y: .value("Hours", month.integrationSeconds / 3600))
                    .foregroundStyle(.blue.gradient)
                    .cornerRadius(4)
            }
            .chartYAxisLabel("Integration hours")
            .frame(minHeight: 260)
            .padding(8)
            .accessibilityIdentifier("v2.insights.activity")
        }
    }

    private func targetRanking(_ insight: InsightsSnapshot) -> some View {
        GroupBox("Most photographed") {
            VStack(alignment: .leading, spacing: 12) {
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
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
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
