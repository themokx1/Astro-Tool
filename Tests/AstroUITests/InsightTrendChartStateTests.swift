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
}
