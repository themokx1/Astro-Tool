import Foundation
import Testing
@testable import AstroCore

/// Expert ideation reserve #9 ("Év-összegző Wrapped"): `YearWrapped.
/// summarize(points:year:)` builds the whole year card from `TrendPoint`s.
/// Fixture spans two years on purpose -- per-year isolation is the whole
/// point of this type existing at all.
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

struct YearWrappedTests {
    @Test("An empty year (no sessions at all) summarizes to nil, not a wall of honest zeroes")
    func emptyYearIsNil() throws {
        let points = [point(target: "M42", date: "2025-01-10")]
        #expect(YearWrapped.summarize(points: points, year: 2026) == nil)
    }

    @Test("Per-year isolation: one year's totals never leak into another's")
    func perYearIsolation() throws {
        let points = [
            point(target: "M42", date: "2025-06-01", integrationSeconds: 1200, usableFrameCount: 20),
            point(target: "M31", date: "2026-01-10", integrationSeconds: 600, usableFrameCount: 10),
            point(target: "M31", date: "2026-01-11", integrationSeconds: 600, usableFrameCount: 10),
        ]

        let wrapped2025 = try #require(YearWrapped.summarize(points: points, year: 2025))
        #expect(wrapped2025.year == 2025)
        #expect(wrapped2025.sessionCount == 1)
        #expect(wrapped2025.totalIntegrationSeconds == 1200)
        #expect(wrapped2025.totalUsableFrameCount == 20)
        #expect(wrapped2025.distinctTargetCount == 1)

        let wrapped2026 = try #require(YearWrapped.summarize(points: points, year: 2026))
        #expect(wrapped2026.year == 2026)
        #expect(wrapped2026.sessionCount == 2)
        #expect(wrapped2026.totalIntegrationSeconds == 1200)
        #expect(wrapped2026.totalUsableFrameCount == 20)
        #expect(wrapped2026.distinctTargetCount == 1)
    }

    @Test("Most-shot target is the highest-integration target that year, reusing TrendAnalytics' own ranking")
    func mostShotCorrectness() throws {
        let points = [
            point(target: "NGC 2237", date: "2026-02-01", integrationSeconds: 3600),
            point(target: "NGC 2237", date: "2026-02-02", integrationSeconds: 3600),
            point(target: "M45", date: "2026-02-05", integrationSeconds: 1200),
        ]

        let wrapped = try #require(YearWrapped.summarize(points: points, year: 2026))
        #expect(wrapped.mostShotTarget?.target == "NGC 2237")
        #expect(wrapped.mostShotTarget?.integrationSeconds == 7200)
        #expect(wrapped.distinctTargetCount == 2)
    }

    @Test("First lights: a target begun the prior year does NOT count, even with sessions this year")
    func firstLightsExcludesTargetsBegunEarlier() throws {
        let points = [
            // M42 started in 2025 -- still shoots in 2026, but that is not
            // its first light.
            point(target: "M42", date: "2025-11-01"),
            point(target: "M42", date: "2026-01-05"),
            // NGC 2237's very first session is in 2026.
            point(target: "NGC 2237", date: "2026-02-01"),
        ]

        let wrapped = try #require(YearWrapped.summarize(points: points, year: 2026))
        #expect(wrapped.firstLights == ["NGC 2237"])

        let wrapped2025 = try #require(YearWrapped.summarize(points: points, year: 2025))
        #expect(wrapped2025.firstLights == ["M42"])
    }

    @Test("Best FWHM night picks the single lowest measured value, arcsec preferred over the pixel fallback")
    func bestFWHMPicksLowestMeasuredValue() throws {
        let points = [
            point(target: "M42", date: "2026-01-01", medianFWHMArcsec: 3.2),
            point(target: "M42", date: "2026-01-05", medianFWHMArcsec: 1.8),
            point(target: "M31", date: "2026-01-10", medianFWHMArcsec: 2.4),
        ]

        let wrapped = try #require(YearWrapped.summarize(points: points, year: 2026))
        let best = try #require(wrapped.bestFWHMNight)
        #expect(best.target == "M42")
        #expect(best.date == "2026-01-05")
        #expect(best.value == 1.8)
        #expect(best.isPixelFallback == false)
    }

    @Test("Best FWHM night is absent, not fabricated, when no session that year was ever measured")
    func bestFWHMAbsentWhenUnmeasured() throws {
        let points = [
            point(target: "M42", date: "2026-01-01"),
            point(target: "M31", date: "2026-01-10"),
        ]

        let wrapped = try #require(YearWrapped.summarize(points: points, year: 2026))
        #expect(wrapped.bestFWHMNight == nil)
    }

    @Test("Biggest month is the year's own highest-integration calendar month")
    func biggestMonthIsHighestIntegrationMonth() throws {
        let points = [
            point(target: "M42", date: "2026-01-01", integrationSeconds: 600),
            point(target: "M42", date: "2026-06-01", integrationSeconds: 600),
            point(target: "M42", date: "2026-06-02", integrationSeconds: 600),
        ]

        let wrapped = try #require(YearWrapped.summarize(points: points, year: 2026))
        #expect(wrapped.biggestMonth?.month == "2026-06")
        #expect(wrapped.biggestMonth?.integrationSeconds == 1200)
    }
}
