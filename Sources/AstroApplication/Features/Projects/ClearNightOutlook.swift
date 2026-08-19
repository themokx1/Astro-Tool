import AstroCore
import Foundation

/// Expert ideation reserve #5 ("Clear-Night Countdown to project
/// completion"): marries `CompletionForecast.nightsNeeded`'s own pace-based
/// "still ~N clear nights to go" estimate with the 7-day Open-Meteo cloud
/// forecast (`WeatherService.dailySummaries`) already fetched elsewhere in
/// this app -- "of the next 7 days, ~2 nights look clear; at this rate,
/// about 3 weeks to the goal."
///
/// Honesty rail (the whole reason this is its own small type rather than a
/// string built inline at either call site): the 7-day Open-Meteo horizon
/// must NEVER be silently extrapolated into a longer-range promise. The
/// only two things this can say for certain are (1) how many clear nights
/// are needed (`CompletionForecast`'s own number, unchanged) and (2) how
/// many of the NEXT `horizonNights` look clear right now. Anything past
/// that -- "so about N weeks" -- is explicitly marked as an "if this rate
/// holds" projection (`ClearNightProjection.paceWeeks`), never printed on
/// its own. Both call sites (`ProjectWorkspaceView`'s Overview forecast row,
/// `HomeView`'s "Continue where it matters" caption) build their own
/// `Text(_:)` around these fields -- this type carries no display string of
/// its own, the same "domain model, no UI string" split `HomeSnapshot
/// .Highlight` already uses.
public struct ClearNightProjection: Equatable, Sendable {
    /// `CompletionForecast.nightsNeeded`'s own estimate, carried through
    /// unchanged -- this type never recomputes or second-guesses it.
    public let nightsNeeded: Int
    /// How many of `horizonNights` have a mean cloud cover at or under
    /// `ClearNightOutlook.cloudyThresholdPercent` -- see
    /// `ClearNightOutlook.clearNightCount(dailySummaries:)`.
    public let clearNightsInHorizon: Int
    /// The actual number of nights `clearNightsInHorizon` was counted over
    /// -- the real size of the fetched forecast window (ordinarily 7, from
    /// Open-Meteo's own `forecast_days=7`, but read from the real data
    /// rather than hardcoded so a shorter/longer bucketed window is still
    /// reported honestly).
    public let horizonNights: Int
    /// `nil` whenever `clearNightsInHorizon == 0` -- a week with no clear
    /// nights at all gives no real rate to divide by, and the honest thing
    /// is silence, not a fabricated "infinite weeks". When present, this is
    /// an EXPLICIT "if this rate holds" projection (see this type's own
    /// doc comment) -- callers must never surface it without that
    /// qualifying language.
    public let paceWeeks: Double?

    public init(nightsNeeded: Int, clearNightsInHorizon: Int, horizonNights: Int, paceWeeks: Double?) {
        self.nightsNeeded = nightsNeeded
        self.clearNightsInHorizon = clearNightsInHorizon
        self.horizonNights = horizonNights
        self.paceWeeks = paceWeeks
    }
}

/// Pure logic behind `ClearNightProjection`, plus the ONE shared "counts as
/// a clear night" threshold both this feature and Home's own cloud-outlook
/// search (`HomeStore.cloudOutlook`) read -- moved here from the former
/// `HomeStore.cloudyThresholdPercent` (an `AstroUI`-only constant) so the
/// two features can share a single definition despite `AstroUI` depending
/// on `AstroApplication` and not the other way around. `HomeStore` now
/// reads `ClearNightOutlook.cloudyThresholdPercent` instead of keeping its
/// own copy.
public enum ClearNightOutlook {
    /// A night's own mean cloud cover at or under this percent counts as
    /// "clear enough to shoot" -- the owner's own "~60%" figure
    /// (`HomeStore.cloudOutlook`'s original doc comment), now the one
    /// definition both features read.
    public static let cloudyThresholdPercent: Double = 60

    /// Counts how many of `dailySummaries` are clear by
    /// `cloudyThresholdPercent` -- the complement of `HomeStore.cloudOutlook`'s
    /// own "cloudy" test (`meanPercent > threshold`), so a night sitting
    /// exactly on the threshold counts as clear in both places rather than
    /// falling into neither bucket.
    public static func clearNightCount(dailySummaries: [String: DailyCloudSummary]) -> Int {
        dailySummaries.values.filter { $0.meanPercent <= cloudyThresholdPercent }.count
    }

    /// The combined projection, `nil` when there is nothing honest to say:
    /// no forecast to reach a goal (`nightsNeeded <= 0` -- the caller's own
    /// "not enough data"/"goal reached" text already covers that) or no
    /// weather data at all (`horizonNights <= 0`, i.e. an empty or
    /// unavailable `dailySummaries`). `clearNightsInHorizon` is passed
    /// separately from `horizonNights` (rather than this function taking
    /// `dailySummaries` itself) so both `ProjectWorkspaceView` (a live
    /// per-site fetch) and `HomeStore` (already-fetched dusk/dawn weather)
    /// can feed it their own already-derived counts without either owning
    /// the other's fetch.
    public static func project(
        nightsNeeded: Int,
        clearNightsInHorizon: Int,
        horizonNights: Int
    ) -> ClearNightProjection? {
        guard nightsNeeded > 0, horizonNights > 0 else { return nil }
        let paceWeeks: Double?
        if clearNightsInHorizon > 0 {
            // Clear nights per calendar night, at the observed rate ->
            // how many calendar nights it would take to rack up
            // `nightsNeeded` clear ones -> in weeks. Never computed (left
            // `nil`) when `clearNightsInHorizon == 0` -- see this
            // property's own doc comment.
            let clearNightsPerCalendarNight = Double(clearNightsInHorizon) / Double(horizonNights)
            let calendarNightsNeeded = Double(nightsNeeded) / clearNightsPerCalendarNight
            paceWeeks = calendarNightsNeeded / 7
        } else {
            paceWeeks = nil
        }
        return ClearNightProjection(
            nightsNeeded: nightsNeeded,
            clearNightsInHorizon: clearNightsInHorizon,
            horizonNights: horizonNights,
            paceWeeks: paceWeeks
        )
    }

    /// `ProjectWorkspaceView`'s own weather fetch: resolves the same site
    /// `Planner`/`HomeStore.productionWeather` would use for `rootURL` and
    /// returns its 7-day `dailySummaries`, `nil` when weather is disabled
    /// (`config.weather.enabled == false`) or no site resolves -- the same
    /// two honest "nothing to show" cases `HomeStore.productionWeather`
    /// already guards on. Deliberately duplicates that site-resolution
    /// logic rather than threading it through from `HomeStore` (which lives
    /// in a different module, `AstroUI`, that this one cannot depend on) --
    /// the same accepted duplication `HomeStore.productionWeather`/
    /// `.productionNightContext` already have between each other.
    public static func productionDailySummaries(rootURL: URL) async throws -> [String: DailyCloudSummary]? {
        struct ResolvedSite { let latitudeDeg: Double; let longitudeDeg: Double }
        let resolved: ResolvedSite? = try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            guard config.weather.enabled else { return nil }
            let site = try Planner.resolveSite(db: database, config: config)
            guard let latitudeDeg = site.latitudeDeg, let longitudeDeg = site.longitudeDeg else { return nil }
            return ResolvedSite(latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg)
        }.value
        guard let resolved else { return nil }
        let (_, summaries) = try await WeatherService.shared.fetch(
            latitude: resolved.latitudeDeg, longitude: resolved.longitudeDeg
        )
        return summaries
    }
}
