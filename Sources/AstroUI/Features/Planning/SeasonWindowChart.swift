import AstroApplication
import AstroCore
import Charts
import SwiftUI

/// Season Window Finder (expert ideation reserve #1, "mikor van az
/// M31-szezon nálam"): the selected Planning row's YEAR-shaped visibility --
/// when does its usable window open, peak, close -- as a small companion to
/// `SkyPathChart`'s existing "tonight" chart. Follows that file's own Swift
/// Charts conventions (a plain `Chart` builder, `AstroTokens` colors).
struct SeasonWindowChart: View {
    let result: SeasonWindowResult

    var body: some View {
        Chart(result.monthlySamples, id: \.date) { sample in
            BarMark(
                x: .value("Month", sample.date, unit: .month),
                y: .value("Visible hours", sample.visibleHours)
            )
            .foregroundStyle(
                // Both branches are DATA-category tokens on purpose --
                // "below threshold" is a fact about this month's own
                // sample, not a status/severity judgment on the app's
                // state, so this must never reach for `.attention`
                // (AstroTokensTests's "data/status boundary" gate treats
                // any status token painting a `BarMark` as a violation).
                // `dataUnclassified`'s muted grey already reads as "less
                // than" `accent` without borrowing a semantic status hue.
                sample.visibleHours >= result.minVisibleHoursThreshold
                    ? AstroTokens.Color.accent
                    : AstroTokens.Color.dataUnclassified
            )
        }
        .chartXAxis {
            // W5-2's own lesson (`InsightTrendChartState.shortAxisLabel`): a
            // chart this compact needs short tick labels, or Swift Charts
            // silently collapses every surviving one to its own ellipsis.
            // `.month(.narrow)` ("J", "F", "M"...) is the shortest built-in
            // unit and already locale-aware -- no hand-rolled Hungarian
            // abbreviation table needed here.
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.month(.narrow))
            }
        }
        .chartYAxisLabel("Hours")
        .frame(minHeight: 110)
        .accessibilityIdentifier("v2.planning.season-chart")
    }
}

/// Shared "Season: … · peak …" text assembly -- `PlanningView`'s footer
/// section and `SavedTargetsView`'s compact per-row line both render the
/// SAME `SeasonWindowResult`, so both go through this one place instead of
/// two independently-drifting phrasings.
///
/// Every case interpolates ONLY pre-formatted `String`s (`dateText`/
/// `hoursText`/`rangesText`, never a raw `Date`/`Double`) into its `Text`
/// template -- the same "%@-only interpolation" rule `HomeView
/// .highlightText`/`AnniversaryHit` already document, so the hand-added
/// `hu.lproj` key always matches what actually renders.
enum SeasonWindowSummary {
    /// `PlanningView`'s footer line -- the full sentence, range(s) and peak
    /// together.
    static func fullText(_ result: SeasonWindowResult) -> Text {
        if result.hasNoUsableSeason {
            return Text("This target never usefully clears the horizon from this site")
        }
        if result.isCircumpolarYearRound {
            return Text("Visible year-round from here") + peakSuffix(result)
        }
        guard !result.ranges.isEmpty else {
            return Text("This target never usefully clears the horizon from this site")
        }
        return Text("Season: \(rangesText(result.ranges))") + peakSuffix(result)
    }

    /// `SavedTargetsView`'s per-row caption -- compact text only, no chart
    /// (a saved-targets list can hold dozens of rows; a chart per row would
    /// be noise, not a "small chart" per the feature's own scope).
    static func compactText(_ result: SeasonWindowResult) -> Text {
        if result.hasNoUsableSeason {
            return Text("No usable season from this site")
        }
        if result.isCircumpolarYearRound {
            return Text("Visible year-round")
        }
        guard let first = result.ranges.first else {
            return Text("No usable season from this site")
        }
        return Text("Season \(dateText(first.startDate)) – \(dateText(first.endDate))")
    }

    private static func peakSuffix(_ result: SeasonWindowResult) -> Text {
        guard let peakDate = result.peakDate, let peakHours = result.peakVisibleHours else {
            return Text(verbatim: "")
        }
        return Text(verbatim: " · ") + Text("peak \(dateText(peakDate)) (\(hoursText(peakHours)) h)")
    }

    private static func rangesText(_ ranges: [SeasonWindowRange]) -> String {
        ranges.map { "\(dateText($0.startDate)) – \(dateText($0.endDate))" }.joined(separator: ", ")
    }

    /// System-locale month/day, no year -- the same `.formatted(date:time:)`
    /// convention every other absolute-date display in this app already
    /// uses (`SavedTargetsView`'s own "Saved …" caption, `SensorProfilesView`,
    /// `ResultsView`), rather than a second, hand-rolled formatter. A
    /// recurring annual pattern has no meaningful year to show at all.
    private static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    private static func hoursText(_ hours: Double) -> String {
        hours.formatted(.number.precision(.fractionLength(1)))
    }
}
