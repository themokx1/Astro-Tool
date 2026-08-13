import AstroApplication
import Charts
import SwiftUI

@MainActor
@Observable
private final class InsightsStore {
    var snapshot: InsightsSnapshot?
    var availableYears: [Int] = []
    var errorMessage: String?
    var isLoading = false

    func load(rootURL: URL?, year: Int? = nil) async {
        guard let rootURL else { snapshot = nil; return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await InsightsQuery.production(rootURL: rootURL).snapshot(year: year)
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
    @State private var store = InsightsStore()
    @State private var selectedYear: Int?

    public init(snapshot: LibrarySnapshot?, rootURL: URL?, chooseLibrary: @escaping () -> Void) {
        self.librarySnapshot = snapshot
        self.rootURL = rootURL
        self.chooseLibrary = chooseLibrary
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

    private func metrics(_ insight: InsightsSnapshot) -> some View {
        HStack(spacing: AstroTokens.Spacing.standard) {
            MetricCard(title: "Integration", value: duration(insight.integrationSeconds), detail: "Verified light exposure", systemImage: "timer")
            MetricCard(title: "Nights", value: "\(insight.nightCount)", detail: "Capture sessions", systemImage: "moon.stars")
            MetricCard(title: "Targets", value: "\(insight.targetCount)", detail: "Unique objects", systemImage: "scope")
            MetricCard(title: "Light frames", value: "\(insight.frameCount)", detail: "Indexed and present", systemImage: "photo.stack")
            MetricCard(title: "Average night", value: duration(insight.averageIntegrationPerNight), detail: insight.bestMonth.map { "Best month: \($0.month)" } ?? "No monthly data", systemImage: "chart.bar.fill")
        }
    }

    private func qualitySummary(_ insight: InsightsSnapshot) -> some View {
        GroupBox("Capture efficiency") {
            HStack(spacing: AstroTokens.Spacing.spacious) {
                Label("\(insight.usableFrameCount) usable", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(insight.rejectedFrameCount) rejected", systemImage: "xmark.circle.fill")
                    .foregroundStyle(insight.rejectedFrameCount == 0 ? Color.secondary : Color.orange)
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
                            .foregroundStyle(AstroTokens.Color.spectralViolet)
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
                            .foregroundStyle(AstroTokens.Color.spectralBlue)
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
