@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// Pins `NightHealthLessons.evaluate`'s pure aggregation rule -- ideation #9
/// ("Éjszaka-tanulságok banner"). `NightHealth.report` only ever verdicts ONE
/// night; this is the first place anything looks for a REPEATED pattern
/// across several nights before saying so. Every case here builds its own
/// plain `NightHealthReport` fixtures (never a real DB) -- the same "extract
/// the pure decision, test it directly" shape `AnniversaryQueryTests`/
/// `MilestoneQueryTests` already use for their own siblings.
struct NightHealthLessonsTests {
    private func coolerReport(date: String, failing: Bool) -> NightHealthReport {
        NightHealthReport(
            target: "M31",
            date: date,
            cooler: CoolerHealth(
                medianDeltaC: failing ? 1.4 : 0.1,
                maxAbsDeltaC: failing ? 2.1 : 0.2,
                outOfBandFraction: failing ? 0.4 : 0.0,
                verdict: failing
                    ? "hűtő nem tartja a célhőmérsékletet (max +2.1 °C, a keretek 40%-án)"
                    : "stabil"
            ),
            focus: FocusHealth(ratedFrameCount: 0, verdict: "n/a — kevés pontozott keret")
        )
    }

    private func coolerReportWithoutData(date: String) -> NightHealthReport {
        NightHealthReport(
            target: "M31",
            date: date,
            cooler: CoolerHealth(verdict: "n/a — nincs hűtési adat"),
            focus: FocusHealth(ratedFrameCount: 0, verdict: "n/a — kevés pontozott keret")
        )
    }

    private func focusReport(date: String, verdict: FocusVerdict) -> NightHealthReport {
        let focus: FocusHealth
        switch verdict {
        case .drifting:
            focus = FocusHealth(
                slopePerHour: 0.5, slopeUnit: "arcsec/h", totalDrift: 0.6, ratedFrameCount: 12,
                verdict: "fókuszcsúszás gyanú (+0.6\"/6 óra)"
            )
        case .improving:
            focus = FocusHealth(
                slopePerHour: -0.5, slopeUnit: "arcsec/h", totalDrift: -0.6, ratedFrameCount: 12,
                verdict: "javuló FWHM (lehűlés/seeing) (-0.6\"/6 óra)"
            )
        case .stable:
            focus = FocusHealth(
                slopePerHour: 0.02, slopeUnit: "arcsec/h", totalDrift: 0.05, ratedFrameCount: 12,
                verdict: "stabil fókusz"
            )
        case .noData:
            focus = FocusHealth(ratedFrameCount: 2, verdict: "n/a — kevés pontozott keret")
        }
        return NightHealthReport(
            target: "M31", date: date,
            cooler: CoolerHealth(verdict: "n/a — nincs hűtési adat"),
            focus: focus
        )
    }

    private enum FocusVerdict { case drifting, improving, stable, noData }

    // MARK: - Cooler lesson

    @Test("Repeated cooler failure across enough sessions fires, naming its own numerator/denominator")
    func coolerLessonFiresOnRepeatedFailure() {
        let reports = [
            coolerReport(date: "2026-08-01", failing: true),
            coolerReport(date: "2026-08-02", failing: true),
            coolerReport(date: "2026-08-03", failing: true),
            coolerReport(date: "2026-08-04", failing: true),
            coolerReport(date: "2026-08-05", failing: false),
            coolerReport(date: "2026-08-06", failing: false),
        ]

        let lessons = NightHealthLessons.evaluate(reports: reports)

        #expect(lessons.count == 1)
        #expect(lessons.first?.kind == .coolerNotHoldingSetpoint)
        #expect(lessons.first?.failingCount == 4)
        #expect(lessons.first?.sessionCount == 6)
    }

    @Test("3 of 8 (37.5%) never crosses the >50% threshold")
    func coolerLessonSilentUnderThreshold() {
        let reports =
            (1...3).map { coolerReport(date: "2026-08-0\($0)", failing: true) } +
            (4...8).map { coolerReport(date: "2026-08-0\($0)", failing: false) }

        #expect(NightHealthLessons.evaluate(reports: reports).isEmpty)
    }

    @Test("Exactly 50% (4 of 8) stays silent -- the threshold is strictly 'more nights than not'")
    func coolerLessonSilentAtExactlyHalf() {
        let reports =
            (1...4).map { coolerReport(date: "2026-08-0\($0)", failing: true) } +
            (5...8).map { coolerReport(date: "2026-08-0\($0)", failing: false) }

        #expect(NightHealthLessons.evaluate(reports: reports).isEmpty)
    }

    @Test("Fewer than the minimum sessions WITH data never fires, however bad the failing fraction is")
    func coolerLessonSilentBelowMinimumData() {
        // 3 of 3 failing is a 100% fraction, but 3 sessions is under the
        // minimum-sessions-with-data floor -- absence of a lesson is the
        // honest state here, not a "stable" claim either.
        let reports = (1...3).map { coolerReport(date: "2026-08-0\($0)", failing: true) }

        #expect(NightHealthLessons.evaluate(reports: reports).isEmpty)
    }

    @Test("Sessions with no cooler reading at all (DSLR nights) never count toward the denominator")
    func coolerLessonIgnoresSessionsWithoutData() {
        let reports = [
            coolerReport(date: "2026-08-01", failing: true),
            coolerReport(date: "2026-08-02", failing: true),
            coolerReport(date: "2026-08-03", failing: true),
            coolerReport(date: "2026-08-04", failing: false),
            coolerReportWithoutData(date: "2026-08-05"),
            coolerReportWithoutData(date: "2026-08-06"),
            coolerReportWithoutData(date: "2026-08-07"),
        ]

        // Only 4 sessions actually carry cooler data; 3 of 4 (75%) fires.
        let lessons = NightHealthLessons.evaluate(reports: reports)
        #expect(lessons.count == 1)
        #expect(lessons.first?.failingCount == 3)
        #expect(lessons.first?.sessionCount == 4)
    }

    // MARK: - Focus-drift lesson

    @Test("Repeated focus drift fires, but 'improving FWHM' nights never count as a failure")
    func focusLessonFiresOnlyOnSuspectedDrift() {
        let reports = [
            focusReport(date: "2026-08-01", verdict: .drifting),
            focusReport(date: "2026-08-02", verdict: .drifting),
            focusReport(date: "2026-08-03", verdict: .drifting),
            focusReport(date: "2026-08-04", verdict: .drifting),
            focusReport(date: "2026-08-05", verdict: .improving),
            focusReport(date: "2026-08-06", verdict: .stable),
        ]

        let lessons = NightHealthLessons.evaluate(reports: reports)

        #expect(lessons.count == 1)
        #expect(lessons.first?.kind == .focusDrift)
        #expect(lessons.first?.failingCount == 4)
        #expect(lessons.first?.sessionCount == 6)
    }

    @Test("Focus-drift lesson only counts sessions where drift was actually measurable")
    func focusLessonIgnoresSessionsWithoutMeasurableDrift() {
        let reports = [
            focusReport(date: "2026-08-01", verdict: .drifting),
            focusReport(date: "2026-08-02", verdict: .drifting),
            focusReport(date: "2026-08-03", verdict: .drifting),
            focusReport(date: "2026-08-04", verdict: .stable),
            focusReport(date: "2026-08-05", verdict: .noData),
            focusReport(date: "2026-08-06", verdict: .noData),
        ]

        // Only 4 sessions have a measurable trend at all; 3 of 4 (75%) fires.
        let lessons = NightHealthLessons.evaluate(reports: reports)
        #expect(lessons.count == 1)
        #expect(lessons.first?.failingCount == 3)
        #expect(lessons.first?.sessionCount == 4)
    }

    // MARK: - Both, and neither

    @Test("Both lessons can fire together from the same session window")
    func bothLessonsCanFireTogether() {
        let coolerFailing = (1...4).map { coolerReport(date: "2026-08-0\($0)", failing: true) }
        let focusFailing = (5...8).map { focusReport(date: "2026-08-0\($0)", verdict: .drifting) }

        let lessons = NightHealthLessons.evaluate(reports: coolerFailing + focusFailing)

        #expect(lessons.count == 2)
        #expect(lessons.contains { $0.kind == .coolerNotHoldingSetpoint })
        #expect(lessons.contains { $0.kind == .focusDrift })
    }

    @Test("An ordinary window with no repeated pattern produces nothing")
    func noPatternProducesNothing() {
        #expect(NightHealthLessons.evaluate(reports: []).isEmpty)

        let allStable = (1...6).map { coolerReport(date: "2026-08-0\($0)", failing: false) }
        #expect(NightHealthLessons.evaluate(reports: allStable).isEmpty)
    }
}
