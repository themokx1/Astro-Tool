import Foundation
import Testing
@testable import AstroCore

/// Ideation #3 ("Ez a hónap tavalyhoz képest"): `YearOverYearComparison.
/// summarize(points:today:calendar:)` builds the whole card from
/// `TrendPoint`s -- the CURRENT calendar month's sessions this year vs the
/// same calendar month last year. Fixture dates are fixed via an explicit
/// `today` (never the real `Date()`) so every test is deterministic
/// regardless of which day it actually runs on.
private func point(
    target: String,
    date: String,
    integrationSeconds: Double = 600,
    usableFrameCount: Int = 10,
    medianFWHMArcsec: Double? = nil,
    medianFWHMPixels: Double? = nil
) -> TrendPoint {
    TrendPoint(
        target: target,
        date: date,
        sessionStartDate: date,
        medianFWHMArcsec: medianFWHMArcsec,
        medianFWHMPixels: medianFWHMPixels,
        integrationSeconds: integrationSeconds,
        usableFrameCount: usableFrameCount
    )
}

/// Fixed "today" for every test: 2026-08-19 -- August, this year 2026, so
/// "same month last year" is always August 2025.
private let fixedToday: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 19
    return Calendar(identifier: .gregorian).date(from: components)!
}()

private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

struct YearOverYearComparisonTests {
    @Test("Same-month-two-years delta correctness: integration and session count deltas match hand totals")
    func sameMonthTwoYearsDeltaCorrectness() throws {
        let points = [
            // This August (2026): two sessions, 3600 s total.
            point(target: "M31", date: "2026-08-05", integrationSeconds: 1800),
            point(target: "M31", date: "2026-08-12", integrationSeconds: 1800),
            // Last August (2025): one session, 1200 s.
            point(target: "M31", date: "2025-08-03", integrationSeconds: 1200),
        ]

        let comparison = try #require(
            YearOverYearComparison.summarize(points: points, today: fixedToday, calendar: utcCalendar)
        )
        #expect(comparison.month == 8)
        #expect(comparison.thisYear == 2026)
        #expect(comparison.lastYear == 2025)
        #expect(comparison.thisYearIntegrationSeconds == 3600)
        #expect(comparison.lastYearIntegrationSeconds == 1200)
        #expect(comparison.integrationSecondsDelta == 2400)
        #expect(comparison.thisYearSessionCount == 2)
        #expect(comparison.lastYearSessionCount == 1)
        #expect(comparison.sessionCountDelta == 1)
    }

    @Test("No prior-year same-month data at all summarizes to nil, not a wall of honest zeroes")
    func noPriorYearDataIsNil() throws {
        let points = [
            point(target: "M31", date: "2026-08-05"),
            // Some sessions exist last year, but not in August.
            point(target: "M31", date: "2025-06-01"),
        ]

        #expect(YearOverYearComparison.summarize(points: points, today: fixedToday, calendar: utcCalendar) == nil)
    }

    @Test("Still compares honestly when THIS year has zero sessions yet but last year has some")
    func thisYearEmptyStillComparesAgainstLastYear() throws {
        let points = [
            point(target: "M31", date: "2025-08-03", integrationSeconds: 1200, usableFrameCount: 15),
        ]

        let comparison = try #require(
            YearOverYearComparison.summarize(points: points, today: fixedToday, calendar: utcCalendar)
        )
        #expect(comparison.thisYearIntegrationSeconds == 0)
        #expect(comparison.thisYearSessionCount == 0)
        #expect(comparison.lastYearIntegrationSeconds == 1200)
        #expect(comparison.lastYearSessionCount == 1)
        #expect(comparison.integrationSecondsDelta == -1200)
        #expect(comparison.sessionCountDelta == -1)
    }

    @Test("Month boundary: sessions from adjacent months (July, September) are excluded from both sides")
    func monthBoundaryExcludesAdjacentMonths() throws {
        let points = [
            point(target: "M31", date: "2026-07-31", integrationSeconds: 9999), // just before August
            point(target: "M31", date: "2026-08-01", integrationSeconds: 100), // first day of August
            point(target: "M31", date: "2026-08-31", integrationSeconds: 200), // last day of August
            point(target: "M31", date: "2026-09-01", integrationSeconds: 9999), // just after August
            point(target: "M31", date: "2025-08-01", integrationSeconds: 50),
            point(target: "M31", date: "2025-07-31", integrationSeconds: 9999),
            point(target: "M31", date: "2025-09-01", integrationSeconds: 9999),
        ]

        let comparison = try #require(
            YearOverYearComparison.summarize(points: points, today: fixedToday, calendar: utcCalendar)
        )
        #expect(comparison.thisYearIntegrationSeconds == 300)
        #expect(comparison.lastYearIntegrationSeconds == 50)
    }

    @Test("Best FWHM delta present and correct when both sides carry a measured session, same unit")
    func bestFWHMDeltaPresentWhenBothMeasured() throws {
        let points = [
            point(target: "M31", date: "2026-08-05", medianFWHMArcsec: 2.4),
            point(target: "M31", date: "2026-08-12", medianFWHMArcsec: 1.9),
            point(target: "M31", date: "2025-08-03", medianFWHMArcsec: 3.1),
        ]

        let comparison = try #require(
            YearOverYearComparison.summarize(points: points, today: fixedToday, calendar: utcCalendar)
        )
        let fwhm = try #require(comparison.bestFWHM)
        #expect(fwhm.thisYearValue == 1.9)
        #expect(fwhm.lastYearValue == 3.1)
        #expect(fwhm.delta == 1.9 - 3.1)
        #expect(fwhm.isPixelFallback == false)
    }

    @Test("FWHM row is absent, not fabricated, when this year has no measured session")
    func fwhmAbsentWhenThisYearUnmeasured() throws {
        let points = [
            point(target: "M31", date: "2026-08-05"),
            point(target: "M31", date: "2025-08-03", medianFWHMArcsec: 3.1),
        ]

        let comparison = try #require(
            YearOverYearComparison.summarize(points: points, today: fixedToday, calendar: utcCalendar)
        )
        #expect(comparison.bestFWHM == nil)
    }

    @Test("FWHM row is absent when last year has no measured session")
    func fwhmAbsentWhenLastYearUnmeasured() throws {
        let points = [
            point(target: "M31", date: "2026-08-05", medianFWHMArcsec: 2.0),
            point(target: "M31", date: "2025-08-03"),
        ]

        let comparison = try #require(
            YearOverYearComparison.summarize(points: points, today: fixedToday, calendar: utcCalendar)
        )
        #expect(comparison.bestFWHM == nil)
    }

    @Test("FWHM row is absent when the two sides' best values use different fallback units (arcsec vs pixel)")
    func fwhmAbsentWhenUnitsMismatch() throws {
        let points = [
            point(target: "M31", date: "2026-08-05", medianFWHMArcsec: 2.0),
            point(target: "M31", date: "2025-08-03", medianFWHMPixels: 4.5),
        ]

        let comparison = try #require(
            YearOverYearComparison.summarize(points: points, today: fixedToday, calendar: utcCalendar)
        )
        #expect(comparison.bestFWHM == nil)
    }
}
