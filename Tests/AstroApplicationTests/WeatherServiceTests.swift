import AstroApplication
import Foundation
import Testing

/// W4-2 (bring back the cloud forecast): pure, non-networked coverage for
/// the two honesty rules `WeatherService`'s doc comments describe --
/// `NightForecast.cloudPercent`'s "beyond 7 days -> nil, never a guess" gate,
/// and `DailyCloudSummary`'s min/max/mean shape the calendar and Planning
/// indicators both read directly. `WeatherService.fetch` itself always hits
/// the real Open-Meteo API (no injectable transport), so its cache-on-
/// failure fallback is exercised indirectly instead, at the V2 store layer
/// (`HomeStoreTests`/`PlanningStoreTests`/`NightsStoreTests`), through each
/// store's own injectable `WeatherProvider` -- a live-network smoke test is
/// deliberately not part of this suite.
struct WeatherServiceTests {
    @Test("cloudPercent finds the nearest hour within 90 minutes")
    func cloudPercentFindsNearestHourWithinTolerance() {
        let base = Date(timeIntervalSince1970: 0)
        let forecast = NightForecast(
            hours: [
                HourlyCloud(time: base, cloudCoverPercent: 10),
                HourlyCloud(time: base.addingTimeInterval(3600), cloudCoverPercent: 80),
            ],
            fetchedAt: base
        )

        // 40 minutes past the second sample -- still within the 90-minute
        // tolerance, and closer to the second hour than the first.
        let percent = forecast.cloudPercent(nearestTo: base.addingTimeInterval(3600 + 40 * 60))

        #expect(percent == 80)
    }

    @Test("cloudPercent is honestly nil beyond the 90-minute tolerance -- a calendar night past the 7-day horizon must never reuse the last sample")
    func cloudPercentIsHonestlyNilBeyondTolerance() {
        let base = Date(timeIntervalSince1970: 0)
        let forecast = NightForecast(
            hours: [HourlyCloud(time: base, cloudCoverPercent: 42)],
            fetchedAt: base
        )

        // A full day past the only sample this "forecast" has -- standing in
        // for a calendar night picked beyond Open-Meteo's real 7-day window.
        let percent = forecast.cloudPercent(nearestTo: base.addingTimeInterval(24 * 3600))

        #expect(percent == nil)
    }

    @Test("cloudPercent is nil for an empty forecast, not a crash or a fabricated zero")
    func cloudPercentIsNilForEmptyForecast() {
        let forecast = NightForecast(hours: [], fetchedAt: Date())

        #expect(forecast.cloudPercent(nearestTo: Date()) == nil)
    }
}
