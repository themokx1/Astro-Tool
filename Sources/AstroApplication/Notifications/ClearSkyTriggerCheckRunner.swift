import AstroCore
import Foundation

/// V3 pre-stack program section 5.5's own thin "do the actual check" entry
/// point -- resolves the same site/weather/tonight-plan/calibration facts
/// Home's own dashboard load already resolves, feeds them through the pure
/// `ClearSkyTrigger` engine, and only on `.fire` asks
/// `UserNotificationScheduler` to actually show something.
///
/// Every step before that pure decision fails silently and honestly, per
/// this feature's own spec: disabled in Settings -> `.disabled`; no site
/// configured or derivable from FITS headers -> `.noSite` (never a guess);
/// `WeatherService` has nothing cached and the network fetch failed ->
/// `.weatherUnavailable` (never a false "it's clear" from missing data).
/// None of these three early exits touch `ClearSkyTriggerStateStore` at all
/// -- an unconfigured/offline check leaves no trace and asks for no
/// permission.
///
/// Deliberately reimplements the small slice of `HomeStore.productionWeather`/
/// `productionTonight`/`productionCalibCoverage` (`AstroUI`) this needs,
/// rather than importing them: this whole feature lives in `AstroApplication`
/// (so it can run from `AstroToolApp`'s own app-lifetime loop without ever
/// depending on a specific window's SwiftUI store), and `AstroApplication`
/// cannot depend on `AstroUI`. Every underlying call
/// (`Planner.resolveSite`/`.plan`, `CalibAnalyzer.coverage`,
/// `CalibShoppingList.build`, `WeatherService.shared.fetch`) is the exact
/// same `AstroCore`/`AstroApplication` function those `HomeStore` methods
/// themselves call -- no predicate is re-derived, only the DB-opening
/// plumbing around it is duplicated, the same accepted trade-off
/// `HomeStore`'s own `production...` methods already make between each
/// other.
public enum ClearSkyTriggerCheckRunner {
    /// One check's outcome -- not shown to the user directly (there is no
    /// persistent V3.0 log surface for this feature), but lets
    /// `ClearSkyTriggerCheckRunnerTests` assert on exactly why a check did
    /// or did not lead to a notification, without depending on
    /// `UserNotificationScheduler`'s own delivered-or-not state.
    public enum Outcome: Equatable, Sendable {
        case disabled
        case noSite
        case weatherUnavailable
        case decision(ClearSkyTrigger.Decision)
    }

    /// Injectable so tests can point this at a temporary
    /// application-support/caches pair instead of the user's real ones --
    /// `SiteSettingsStoreTests`' own fixture establishes this exact seam for
    /// `AppStoragePaths`.
    public typealias StoragePathsResolver = @Sendable (LibraryIdentity, URL) throws -> AppStoragePaths

    public static func check(
        rootURL: URL,
        scheduler: UserNotificationScheduler = .shared,
        storagePaths: @escaping StoragePathsResolver = { try AppStoragePaths.production(libraryID: $0, libraryRoot: $1) },
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> Outcome {
        let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = rootURL.path
        guard config.notification.enabled else { return .disabled }

        guard let resolved = Self.resolveSiteAndDatabase(rootURL: rootURL, config: config, storagePaths: storagePaths) else {
            return .noSite
        }

        guard let (_, dailySummaries) = try? await WeatherService.shared.fetch(
            latitude: resolved.latitudeDeg, longitude: resolved.longitudeDeg
        ) else {
            return .weatherUnavailable
        }
        let tonightKey = WeatherService.isoDateFormatter.string(from: now)
        guard let tonightSummary = dailySummaries[tonightKey] else {
            return .weatherUnavailable
        }

        let authorization = await scheduler.authorizationStatus()
        let state = ClearSkyTriggerStateStore.load(from: rootURL)
        let result = ClearSkyTrigger.evaluate(
            now: now,
            calendar: calendar,
            checkHourLocal: config.notification.checkHourLocal,
            cloudyThresholdPercent: ClearNightOutlook.cloudyThresholdPercent,
            currentCloudPercent: tonightSummary.meanPercent,
            authorization: authorization,
            state: state
        )
        try? ClearSkyTriggerStateStore.save(result.nextState, using: WriteGuard(root: rootURL))

        if case .fire = result.decision {
            let facts = (try? Self.tonightFacts(database: resolved.database, config: config)) ?? (plans: [], calibMissingCount: 0)
            let topTarget = facts.plans.first { CalibShoppingList.isObservableTonight($0) }?.displayName
            let content = ClearSkyNotificationContent.build(
                missingCalibrationCount: facts.calibMissingCount, targetDisplayName: topTarget
            )
            await scheduler.deliverClearSkyNotification(dayKey: tonightKey, content: content)
        }

        return .decision(result.decision)
    }

    private struct ResolvedSite {
        let database: Database
        let latitudeDeg: Double
        let longitudeDeg: Double
    }

    private static func resolveSiteAndDatabase(
        rootURL: URL,
        config: AstroConfig,
        storagePaths: StoragePathsResolver
    ) -> ResolvedSite? {
        let identity = LibraryIdentity(rootURL: rootURL)
        guard
            let paths = try? storagePaths(identity, rootURL),
            let database = try? Database(path: paths.indexDatabase.path),
            let site = try? Planner.resolveSite(db: database, config: config),
            let latitudeDeg = site.latitudeDeg,
            let longitudeDeg = site.longitudeDeg
        else { return nil }
        return ResolvedSite(database: database, latitudeDeg: latitudeDeg, longitudeDeg: longitudeDeg)
    }

    private static func tonightFacts(
        database: Database, config: AstroConfig
    ) throws -> (plans: [TargetPlan], calibMissingCount: Int) {
        let plans = try Planner.plan(db: database, config: config)
        let coverage = try CalibAnalyzer.coverage(db: database, config: config)
        let items = CalibShoppingList.build(coverage: coverage, plans: plans)
        return (plans, items.count)
    }
}
