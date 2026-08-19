@testable import AstroApplication
import Foundation
import Testing

/// Pins `CompletionForecast.nightsNeeded`'s pure division/rounding/honesty
/// rules -- expert ideation spec #2 ("még ~3 tiszta éjszaka a célig").
/// `ProjectReportQueryTests` separately pins that
/// `recentSessionIntegrationSeconds` is actually wired from a real scan, and
/// `ProjectWorkspaceOverviewSurfaceTests` pins the view's own wiring plus
/// the "not enough data" sentence -- this suite only covers the arithmetic.
struct CompletionForecastTests {
    @Test("Divides remaining time by the average recent-session pace, rounding UP to a whole night")
    func divisionCorrectness() {
        // 10h remaining, three recent sessions averaging 3h/night ->
        // 10/3 = 3.33... nights, rounds up to 4.
        let estimate = CompletionForecast.nightsNeeded(
            remainingSeconds: 10 * 3600,
            recentSessionSeconds: [2 * 3600, 3 * 3600, 4 * 3600]
        )
        #expect(estimate?.nightsNeeded == 4)
        #expect(estimate?.paceSecondsPerNight == 10800.0)
        #expect(estimate?.isCapped == false)
    }

    @Test("An exact, no-remainder division still needs that many whole nights, not one fewer")
    func exactDivisionRoundsToItselfNotDown() {
        // 9h remaining at a flat 3h/night pace divides evenly to 3 -- must
        // stay 3, not fall to 2 through a stray floor somewhere.
        let estimate = CompletionForecast.nightsNeeded(
            remainingSeconds: 9 * 3600,
            recentSessionSeconds: [3 * 3600, 3 * 3600]
        )
        #expect(estimate?.nightsNeeded == 3)
    }

    @Test("Never forecasts off a single historical session")
    func nilUnderTwoSessions() {
        #expect(CompletionForecast.nightsNeeded(remainingSeconds: 3600, recentSessionSeconds: []) == nil)
        #expect(CompletionForecast.nightsNeeded(remainingSeconds: 3600, recentSessionSeconds: [3600]) == nil)
    }

    @Test("Two historical sessions are enough to attempt a forecast")
    func twoSessionsIsEnough() {
        let estimate = CompletionForecast.nightsNeeded(
            remainingSeconds: 3600,
            recentSessionSeconds: [1800, 1800]
        )
        #expect(estimate != nil)
    }

    @Test("No forecast once the goal is already met or exceeded")
    func nilAtGoalMet() {
        #expect(CompletionForecast.nightsNeeded(remainingSeconds: 0, recentSessionSeconds: [3600, 3600]) == nil)
        #expect(CompletionForecast.nightsNeeded(remainingSeconds: -1, recentSessionSeconds: [3600, 3600]) == nil)
    }

    @Test("No forecast when the recent pace itself is zero (nothing usable logged)")
    func nilAtZeroPace() {
        #expect(CompletionForecast.nightsNeeded(remainingSeconds: 3600, recentSessionSeconds: [0, 0]) == nil)
    }

    @Test("Never returns a negative or zero night count")
    func neverNegative() {
        // A tiny remainder against a large pace still needs at least one
        // more night, never zero and never negative.
        let estimate = CompletionForecast.nightsNeeded(
            remainingSeconds: 1,
            recentSessionSeconds: [10 * 3600, 10 * 3600]
        )
        #expect((estimate?.nightsNeeded ?? 0) >= 1)
    }

    @Test("Caps the displayed night count instead of printing a falsely precise huge number")
    func roundingAndCapRule() {
        // 200h remaining at 1h/night -> a literal 200 nights; must clamp to
        // the 20-night display ceiling and flag isCapped.
        let estimate = CompletionForecast.nightsNeeded(
            remainingSeconds: 200 * 3600,
            recentSessionSeconds: [3600, 3600]
        )
        #expect(estimate?.nightsNeeded == CompletionForecast.maximumDisplayedNights)
        #expect(estimate?.isCapped == true)
    }

    @Test("Does not cap a night count that lands exactly on the ceiling")
    func exactlyAtCeilingIsNotFlaggedCapped() {
        let estimate = CompletionForecast.nightsNeeded(
            remainingSeconds: Double(CompletionForecast.maximumDisplayedNights) * 3600,
            recentSessionSeconds: [3600, 3600]
        )
        #expect(estimate?.nightsNeeded == CompletionForecast.maximumDisplayedNights)
        #expect(estimate?.isCapped == false)
    }
}
