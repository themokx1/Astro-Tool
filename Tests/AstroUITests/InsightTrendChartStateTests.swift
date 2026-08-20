import Foundation
import Testing

@testable import AstroUI

/// W4-4 item 6 (owner review): "with <2 measured sessions the three trend
/// charts render" a lone dot / an empty-state graphic / an x-axis of
/// nothing but "…". `InsightTrendChartState` is the pure classification and
/// tick-thinning logic behind `InsightsView.trendChart`
/// (`Sources/AstroUI/Features/Insights/InsightsView.swift`); these tests
/// exercise it directly, without rendering a `Chart`.
@Suite("Insights trend chart honesty (W4-4 item 6)")
struct InsightTrendChartStateTests {
    @Test("Zero measured sessions is noData, one is singleSession, two or more is trend", arguments: [
        (pointCount: 0, expected: InsightTrendChartState.noData),
        (pointCount: 1, expected: InsightTrendChartState.singleSession),
        (pointCount: 2, expected: InsightTrendChartState.trend),
        (pointCount: 3, expected: InsightTrendChartState.trend),
        (pointCount: 30, expected: InsightTrendChartState.trend),
    ])
    func classifiesByPointCount(pointCount: Int, expected: InsightTrendChartState) {
        #expect(InsightTrendChartState(pointCount: pointCount) == expected)
    }

    @Test("The zero- and one-session messages are distinct -- the owner's own two phrasings, not one generic fallback")
    func distinctMessagesForZeroAndOne() {
        #expect(
            String(describing: InsightTrendChartState.unavailableMessage(pointCount: 0))
                != String(describing: InsightTrendChartState.unavailableMessage(pointCount: 1))
        )
    }

    @Test("Below the tick cap, every date keeps its own tick -- unchanged from before this task", arguments: [1, 2, 5, 6])
    func noThinningBelowCap(count: Int) {
        let dates = (0..<count).map { "2026-08-\(10 + $0)" }
        #expect(InsightTrendChartState.thinnedAxisDates(dates, maxTicks: 6) == dates)
    }

    @Test("Above the tick cap, the result never exceeds the cap and every surviving label is a real, untruncated date")
    func thinsAboveCap() {
        let dates = (0..<20).map { "2026-08-\(String(format: "%02d", $0 + 1))" }
        let thinned = InsightTrendChartState.thinnedAxisDates(dates, maxTicks: 6)
        #expect(thinned.count <= 6)
        #expect(!thinned.isEmpty)
        // Every survivor is one of the real dates, verbatim -- never an
        // ellipsis or a truncated fragment.
        #expect(thinned.allSatisfy { dates.contains($0) })
        // The very first date always survives, so the chart's earliest
        // point is never unlabeled.
        #expect(thinned.first == dates.first)
    }

    @Test("Thinning never crashes or returns something absurd on an empty list")
    func thinningHandlesEmpty() {
        #expect(InsightTrendChartState.thinnedAxisDates([], maxTicks: 6).isEmpty)
    }

    // MARK: - W5-2 finding 2 (owner pixel review): axis labels all rendered "…"
    //
    // Capping ticks at 6 (above) was not enough by itself -- a full
    // `YYYY-MM-DD` label is still too wide for six of them to fit across one
    // third of the row, so Swift Charts collapsed every survivor down to its
    // own ellipsis. `shortAxisLabel` shortens to `MM-dd`.

    @Test("A canonical YYYY-MM-DD date shortens to MM-dd", arguments: [
        (input: "2026-08-14", expected: "08-14"),
        (input: "2026-01-01", expected: "01-01"),
        (input: "1999-12-31", expected: "12-31"),
    ])
    func shortensCanonicalDates(input: String, expected: String) {
        #expect(InsightTrendChartState.shortAxisLabel(for: input) == expected)
    }

    @Test("A non-date raw session-dir name renders verbatim rather than being mangled", arguments: [
        "not-a-date", "2026-8-14", "M31-session-2", "",
    ])
    func nonDateStringsPassThroughUnchanged(raw: String) {
        #expect(InsightTrendChartState.shortAxisLabel(for: raw) == raw)
    }

    @Test("Every real tick label the axis renders is strictly shorter after shortening, never longer")
    func shortenedLabelsAreNeverLongerThanTheOriginal() {
        let dates = ["2026-08-14", "2026-09-02", "not-a-date"]
        for date in dates {
            #expect(InsightTrendChartState.shortAxisLabel(for: date).count <= date.count)
        }
    }

    /// `trendChart` is the ONE function `qualityTrends` calls for all three
    /// of FWHM/Background/Efficiency (see `InsightsView.swift`'s own doc
    /// comment on `trendChart`'s `title` parameter) -- so `shortAxisLabel`
    /// wired into its single `AxisValueLabel` call site fixes all three at
    /// once, and can never drift into "two charts fixed, one forgotten".
    /// This is a source check, not a render, matching this codebase's
    /// established "surface test" convention (SwiftUI bodies are not
    /// snapshot-tested here).
    @Test("shortAxisLabel is wired into the one shared trendChart axis, not duplicated per chart")
    func shortAxisLabelIsWiredOnceIntoTheSharedChart() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AstroUI/Features/Insights/InsightsView.swift"),
            encoding: .utf8
        )
        let occurrences = source.components(separatedBy: "AxisValueLabel(InsightTrendChartState.shortAxisLabel(for: date))").count - 1
        #expect(occurrences == 1, "expected exactly one AxisValueLabel call site, shared by all three trend charts")
        // Exactly one `private func trendChart(` -- proves the FWHM/
        // Background/Efficiency call sites in `qualityTrends` all funnel
        // through the same function rather than each having their own body.
        #expect(source.components(separatedBy: "private func trendChart(").count - 1 == 1)
    }
}
