import AstroApplication
import Foundation
import Testing

/// V3 pre-stack program section 5.5 ("Derült-trigger"): `ClearSkyTrigger
/// .evaluate` is the ONE pure decision behind the "tell me when it clears
/// tonight" notification -- this suite pins its entire matrix (borult ->
/// tiszta, tiszta -> tiszta, borult -> borult, plus the permission gate and
/// the once-per-night dedupe) with an injected clock/calendar, never the
/// real wall clock.
@Suite("Clear-sky trigger (V3 5.5)")
struct ClearSkyTriggerTests {
    /// Gregorian, fixed to UTC so every test's hand-picked hour means
    /// exactly what it says regardless of the machine running the suite.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static let threshold: Double = 60

    // MARK: - Permission gate

    @Test("Not authorized never fires, even with a genuine cloudy-to-clear improvement")
    func notAuthorizedNeverFires() {
        let earlier = ClearSkyTrigger.Measurement(dayKey: "2026-08-20", cloudPercent: 90)
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 10,
            authorization: .notDetermined,
            state: .init(earlierMeasurement: earlier)
        )
        #expect(result.decision == .skip(.notAuthorized))
    }

    @Test("Denied authorization never fires either")
    func deniedNeverFires() {
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 10,
            authorization: .denied,
            state: .init()
        )
        #expect(result.decision == .skip(.notAuthorized))
    }

    // MARK: - Before the check window: baseline only, never fires

    @Test("Before the check hour, a clear reading only records a baseline -- it never fires")
    func beforeWindowNeverFires() {
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 11),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 5,
            authorization: .authorized,
            state: .init()
        )
        #expect(result.decision == .skip(.beforeCheckWindow))
        #expect(result.nextState.earlierMeasurement == .init(dayKey: "2026-08-20", cloudPercent: 5))
    }

    @Test("Before the check hour, an existing same-day baseline is left untouched")
    func beforeWindowKeepsFirstBaseline() {
        let existing = ClearSkyTrigger.Measurement(dayKey: "2026-08-20", cloudPercent: 80)
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 12),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 20,
            authorization: .authorized,
            state: .init(earlierMeasurement: existing)
        )
        #expect(result.decision == .skip(.beforeCheckWindow))
        #expect(result.nextState.earlierMeasurement == existing)
    }

    // MARK: - At/after the check hour, with no same-day baseline

    @Test("At the check hour with no earlier same-day reading, this tick only becomes the baseline")
    func noBaselineYetSkipsAndRecords() {
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 14),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 5,
            authorization: .authorized,
            state: .init()
        )
        #expect(result.decision == .skip(.noBaselineYet))
        #expect(result.nextState.earlierMeasurement == .init(dayKey: "2026-08-20", cloudPercent: 5))
    }

    @Test("A baseline from a different calendar day never counts as today's")
    func staleBaselineFromAnotherDayIsDiscarded() {
        let staleFromYesterday = ClearSkyTrigger.Measurement(dayKey: "2026-08-19", cloudPercent: 90)
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 5,
            authorization: .authorized,
            state: .init(earlierMeasurement: staleFromYesterday)
        )
        #expect(result.decision == .skip(.noBaselineYet))
        #expect(result.nextState.earlierMeasurement == .init(dayKey: "2026-08-20", cloudPercent: 5))
    }

    // MARK: - The matrix: cloudy->clear, clear->clear, cloudy->cloudy

    @Test("Cloudy this morning, clear this afternoon: fires, and pins the night")
    func cloudyToClearFires() {
        let earlier = ClearSkyTrigger.Measurement(dayKey: "2026-08-20", cloudPercent: 90)
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 10,
            authorization: .authorized,
            state: .init(earlierMeasurement: earlier)
        )
        #expect(result.decision == .fire)
        #expect(result.nextState.lastNotifiedDayKey == "2026-08-20")
    }

    @Test("Already clear this morning, still clear this afternoon: nothing new, skips")
    func clearToClearSkips() {
        let earlier = ClearSkyTrigger.Measurement(dayKey: "2026-08-20", cloudPercent: 15)
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 10,
            authorization: .authorized,
            state: .init(earlierMeasurement: earlier)
        )
        #expect(result.decision == .skip(.alreadyClearEarlier))
        #expect(result.nextState.lastNotifiedDayKey == nil)
    }

    @Test("Cloudy this morning, still cloudy this afternoon: nothing improved, skips")
    func cloudyToCloudySkips() {
        let earlier = ClearSkyTrigger.Measurement(dayKey: "2026-08-20", cloudPercent: 90)
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 80,
            authorization: .authorized,
            state: .init(earlierMeasurement: earlier)
        )
        #expect(result.decision == .skip(.stillCloudy))
    }

    @Test("Clear this morning, cloudy this afternoon (it got worse): still cloudy wins, skips")
    func clearToCloudySkips() {
        let earlier = ClearSkyTrigger.Measurement(dayKey: "2026-08-20", cloudPercent: 10)
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 90,
            authorization: .authorized,
            state: .init(earlierMeasurement: earlier)
        )
        #expect(result.decision == .skip(.stillCloudy))
    }

    @Test("The cloudy/clear threshold is inclusive: exactly the threshold percent counts as clear")
    func thresholdBoundaryIsInclusive() {
        let earlier = ClearSkyTrigger.Measurement(dayKey: "2026-08-20", cloudPercent: 90)
        let result = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: Self.threshold,
            authorization: .authorized,
            state: .init(earlierMeasurement: earlier)
        )
        #expect(result.decision == .fire)
    }

    // MARK: - Never notify twice for the same night (house rule, pinned)

    @Test("Once fired for tonight, a second check the same evening never fires again")
    func neverNotifiesTwiceForTheSameNight() {
        let earlier = ClearSkyTrigger.Measurement(dayKey: "2026-08-20", cloudPercent: 90)
        let first = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 10,
            authorization: .authorized,
            state: .init(earlierMeasurement: earlier)
        )
        #expect(first.decision == .fire)

        // A later check the SAME evening, even though the raw inputs would
        // still say "cloudy -> clear" if evaluated from scratch, must never
        // fire again -- only `first.nextState`'s own dedupe pin is threaded
        // through, exactly as the runner persists it between ticks.
        let second = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 16),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 10,
            authorization: .authorized,
            state: first.nextState
        )
        #expect(second.decision == .skip(.alreadyNotifiedTonight))
    }

    @Test("A new calendar day clears the previous night's dedupe pin and baseline")
    func newDayResetsDedupeAndBaseline() {
        let earlier = ClearSkyTrigger.Measurement(dayKey: "2026-08-20", cloudPercent: 90)
        let firstNight = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 20, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 10,
            authorization: .authorized,
            state: .init(earlierMeasurement: earlier)
        )
        #expect(firstNight.decision == .fire)

        // The next evening, even at the same clear reading, there is no
        // baseline for THIS day yet -- so it must not fire immediately off
        // yesterday's dedupe/baseline state, honestly recording a fresh
        // baseline instead.
        let nextEvening = ClearSkyTrigger.evaluate(
            now: Self.date(2026, 8, 21, hour: 15),
            calendar: Self.calendar,
            checkHourLocal: 14,
            cloudyThresholdPercent: Self.threshold,
            currentCloudPercent: 10,
            authorization: .authorized,
            state: firstNight.nextState
        )
        #expect(nextEvening.decision == .skip(.noBaselineYet))
        #expect(nextEvening.nextState.earlierMeasurement?.dayKey == "2026-08-21")
    }
}
