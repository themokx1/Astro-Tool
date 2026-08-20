@testable import AstroApplication
import Foundation
import Testing

/// Pins `ClearNightOutlook`'s pure counting/projection rules -- expert
/// ideation reserve #5 ("Clear-Night Countdown to project completion").
/// `HomeStoreTests`/`ProjectWorkspaceCompletionForecastSurfaceTests`
/// separately pin the two call sites' own wiring; this suite only covers
/// the arithmetic and the honesty rail against extrapolating past the
/// 7-day forecast horizon.
struct ClearNightOutlookTests {
    private func summary(date: String, mean: Double) -> DailyCloudSummary {
        DailyCloudSummary(date: date, minPercent: mean, maxPercent: mean, meanPercent: mean)
    }

    @Test("Counts a night at or under the threshold as clear, and one strictly over it as not")
    func clearNightCountThreshold() {
        let dailySummaries: [String: DailyCloudSummary] = [
            "2026-08-19": summary(date: "2026-08-19", mean: 60), // exactly on the line -> clear
            "2026-08-20": summary(date: "2026-08-20", mean: 60.1), // just over -> not clear
            "2026-08-21": summary(date: "2026-08-21", mean: 10),
        ]
        #expect(ClearNightOutlook.clearNightCount(dailySummaries: dailySummaries) == 2)
    }

    @Test("No projection at all once there is nothing to reach (nightsNeeded <= 0)")
    func nilWhenNothingNeeded() {
        #expect(ClearNightOutlook.project(nightsNeeded: 0, clearNightsInHorizon: 3, horizonNights: 7) == nil)
        #expect(ClearNightOutlook.project(nightsNeeded: -1, clearNightsInHorizon: 3, horizonNights: 7) == nil)
    }

    @Test("No projection at all once there is no weather data to read (empty horizon)")
    func nilWhenNoHorizon() {
        #expect(ClearNightOutlook.project(nightsNeeded: 6, clearNightsInHorizon: 0, horizonNights: 0) == nil)
    }

    @Test("Forecast+pace: a real clear-night rate produces an explicit 'if this rate holds' weeks projection")
    func forecastAndPace() {
        // The pitch's own example: 6 nights needed, 2 of the next 7 look
        // clear -> rate 2/7 per night -> 21 calendar nights -> 3 weeks.
        let projection = ClearNightOutlook.project(nightsNeeded: 6, clearNightsInHorizon: 2, horizonNights: 7)
        #expect(projection?.nightsNeeded == 6)
        #expect(projection?.clearNightsInHorizon == 2)
        #expect(projection?.horizonNights == 7)
        #expect(projection?.paceWeeks == 3)
    }

    @Test("Pace-less: zero clear nights in the horizon still reports the two hard facts, but never a fabricated rate")
    func factsOnlyWhenNoClearNightsYet() {
        let projection = ClearNightOutlook.project(nightsNeeded: 6, clearNightsInHorizon: 0, horizonNights: 7)
        #expect(projection?.nightsNeeded == 6)
        #expect(projection?.clearNightsInHorizon == 0)
        #expect(projection?.paceWeeks == nil)
    }

    @Test("Never claims a rate beyond the real fetched horizon size, whatever it happens to be")
    func honorsTheRealHorizonSizeNotAHardcodedSeven() {
        // A 5-night bucketed window (short of the usual 7) with all 5 clear
        // still produces a rate scaled off the REAL horizon, not 7.
        let projection = ClearNightOutlook.project(nightsNeeded: 5, clearNightsInHorizon: 5, horizonNights: 5)
        #expect(projection?.horizonNights == 5)
        // rate 5/5 = 1/night -> 5 calendar nights -> 5/7 weeks.
        #expect(projection?.paceWeeks == 5.0 / 7.0)
    }
}
