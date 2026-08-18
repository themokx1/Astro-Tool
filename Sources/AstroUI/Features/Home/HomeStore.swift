import Foundation
import Observation
import AstroApplication
import AstroCore

public struct HomeTonightRecommendation: Equatable, Sendable, Identifiable {
    public var id: String { target }
    public let projectID: UUID?
    public let target: String
    public let displayName: String
    public let visibleWindow: String?
    public let culmination: String?
    public let maxAltitude: Double?
    public let moonSeparation: Double?
    public let verdict: String
    public let score: Double
}

public struct HomeSnapshot: Equatable, Sendable {
    /// V2 UI/UX audit (2026-08-14) section 4: this used to be three plain
    /// strings with no way to say "there is nothing real to show yet" --
    /// `HomeStore.configure` therefore always carried the very first
    /// (hardcoded) value forward unchanged, and `NightContextRail` drew a
    /// fixed-geometry dusk/observation-window/dawn plot that never reflected
    /// any actual site or time. `isConfigured` is the honest flag: `false`
    /// means no site could be resolved (no explicit `AstroConfig.site`, no
    /// FITS-median fallback) for this library, so the rail must say so
    /// instead of drawing a plot. `nowFraction` (0...1) is only meaningful
    /// when configured -- where "now" sits between dusk and dawn tonight --
    /// and `nil` whenever `now` falls outside that window (before dusk /
    /// after dawn) or the window can't be computed.
    public struct NightContext: Equatable, Sendable {
        public let isConfigured: Bool
        public let leadingLabel: String
        public let centerLabel: String
        public let trailingLabel: String
        public let nowFraction: Double?

        public init(
            isConfigured: Bool,
            leadingLabel: String,
            centerLabel: String,
            trailingLabel: String,
            nowFraction: Double? = nil
        ) {
            self.isConfigured = isConfigured
            self.leadingLabel = leadingLabel
            self.centerLabel = centerLabel
            self.trailingLabel = trailingLabel
            self.nowFraction = nowFraction
        }

        /// Neutral, honest default: no site has been resolved for the open
        /// library (or none is open yet), so there is nothing real to plot.
        ///
        /// V2 UI/UX audit (W3-9): these three used to be plain English
        /// literals assigned straight into `String` properties -- the exact
        /// "store-composed display string" leak class this task's own doc
        /// names (`leadingLabel`/`centerLabel`/`trailingLabel` are `String`,
        /// so `NightContextRail`'s `Text(context.leadingLabel)` etc. always
        /// select `Text`'s verbatim, never-localized overload no matter what
        /// `hu.lproj` says). Restructuring these into an enum/`Date` pair
        /// would touch `NightContextRail`'s accessibility-label string
        /// interpolation too; eagerly resolving through `NSLocalizedString`
        /// here instead matches the already-established
        /// `ProjectNextActionKind.localizedTitle`/`.localizedExplanation`
        /// pattern (`ProjectsStore.swift`) -- same "String(localized) in the
        /// store" fix this task's own instructions call out as acceptable
        /// when restructuring is invasive.
        public static let unconfigured = NightContext(
            isConfigured: false,
            leadingLabel: NSLocalizedString("Dusk", bundle: .main, comment: ""),
            centerLabel: NSLocalizedString("Site not configured", bundle: .main, comment: ""),
            trailingLabel: NSLocalizedString("Dawn", bundle: .main, comment: "")
        )
    }

    /// W4-2: tonight's Open-Meteo cloud picture for the resolved site, dusk
    /// to dawn -- the exact vocabulary V1's Tonight page "Felhőzet" tile
    /// already uses (`TonightPage.cloudTileInfo`), computed against the SAME
    /// twilight window `productionNightContext` resolves `leadingLabel`/
    /// `trailingLabel` from. `nil` dusk/dawn percents (rather than `nil` for
    /// the whole struct) is the "beyond the 7-day horizon" honest case --
    /// `WeatherProvider`/`NightForecast.cloudPercent`'s own 90-minute
    /// tolerance is what actually produces that.
    public struct NightCloud: Equatable, Sendable {
        public let duskPercent: Double?
        public let dawnPercent: Double?
        public let fetchedAt: Date
        /// W7-E workflow #3 (2026-08-18 owner audit, "cloudy tonight, name
        /// the next clear night"): `true` when tonight's own dark-hours mean
        /// cloud (`WeatherService.dailySummaries`, NOT the dusk/dawn POINT
        /// samples above -- a genuinely different reading) crosses
        /// `HomeStore.cloudyThresholdPercent`. Computed once here, in
        /// `productionWeather`, so the "name the next clear night" line and
        /// the "cloudy night = darks night" card gate on the exact same
        /// signal instead of each re-deriving (and risking disagreeing with)
        /// it from a raw `Double?`. Defaults to `false` for fixtures/tests
        /// that only care about the dusk/dawn point values.
        public let isCloudyTonight: Bool
        /// `nil` whenever `isCloudyTonight` is `false` -- a clear night has
        /// nothing to add. Set only when tonight is cloudy: `.found` names
        /// the first night within Open-Meteo's 7-day horizon whose own mean
        /// cloud drops back under the threshold; `.unavailable` is the
        /// honest case where none of the remaining forecast nights do.
        public let nextClearNight: NextClearNight?

        public init(
            duskPercent: Double?,
            dawnPercent: Double?,
            fetchedAt: Date,
            isCloudyTonight: Bool = false,
            nextClearNight: NextClearNight? = nil
        ) {
            self.duskPercent = duskPercent
            self.dawnPercent = dawnPercent
            self.fetchedAt = fetchedAt
            self.isCloudyTonight = isCloudyTonight
            self.nextClearNight = nextClearNight
        }
    }

    /// W7-E workflow #3: the outcome of searching `WeatherService
    /// .dailySummaries`'s 7-day forecast for the first night whose own mean
    /// cloud reads back under `HomeStore.cloudyThresholdPercent`, once
    /// tonight itself has already crossed it. A plain `nil` on `NightCloud`
    /// means "tonight isn't cloudy, this search never ran" -- once it DOES
    /// run, its own two outcomes are both worth telling the user, so neither
    /// collapses to `nil`.
    public enum NextClearNight: Equatable, Sendable {
        /// `date` is the raw `yyyy-MM-dd` key `WeatherService.dailySummaries`
        /// itself uses (matches `DailyCloudSummary.date`) -- shown verbatim,
        /// the same "raw ISO date, no locale-specific month name" convention
        /// `NightRow.date`/`CaptureTrendPoint.date` already use elsewhere in
        /// this app, rather than inventing a new formatted-date convention
        /// for one line.
        case found(date: String, minPercent: Double, maxPercent: Double)
        /// Every night left in the 7-day Open-Meteo horizon stays at or
        /// above the threshold too -- an honest "nothing to name" rather
        /// than silence or a guess beyond the forecast's own horizon.
        case unavailable
    }

    public let libraryName: String?
    public let nightContext: NightContext
    public let projectCount: Int
    /// W6-E item 3: `V2RootView` configures this from `nightsStore.nights.count`
    /// -- deduplicated `NightRecord` rows, one per canonical calendar date
    /// (`SessionDateParser`-normalized, so a run-suffix sibling folder
    /// collapses into the same night it belongs to), built only from
    /// `role == "light"` files with a real target. This is the smallest of
    /// this app's three "night-shaped" counts by design: `LibrarySnapshot
    /// .nightCount` (onboarding's "Session Folders" tile) counts raw
    /// session-date FOLDER strings with no dedup, and `InsightsQuery`'s own
    /// "Nights"/"Felvételi sessionök" figure counts distinct
    /// target+session-date PAIRS. All three are correct for what they
    /// measure; only the shared word "Nights" used to make them look like a
    /// contradiction.
    public let nightCount: Int
    public let nextProject: ProjectRecord?
    public let nextProjectIntegrationSeconds: Double
    public let tonightRecommendations: [HomeTonightRecommendation]
    /// Task 1 (owner feedback wave 3): `true` when at least one active
    /// (`.collecting`/`.planned`) project exists but every one of them
    /// resolved to a `SkyVerdict` the app already knows means "cannot be
    /// pointed at tonight" (a comet's stale capture-time coordinate, no
    /// resolvable coordinate at all, an altitude/window that never clears
    /// the bar) -- so `nextProject` is honestly `nil` rather than the least
    /// bad of a set of unshootable candidates. `HomeView` uses this to tell
    /// "no active project exists yet" apart from "one exists, but none of
    /// them can be continued tonight".
    public let hasActiveProjectsExcludedTonight: Bool
    /// `nil` whenever there is nothing real to show: weather disabled
    /// (`config.weather.enabled == false`), no site resolved, or the fetch
    /// hasn't landed yet -- `HomeView` shows no cloud row at all in every one
    /// of those cases (W4-2 spec: "no site configured -> no weather row, no
    /// error"). `nightCloudError` is the ONE case where something IS shown
    /// despite `nightCloud` being `nil`: a fetch that failed with no cached
    /// forecast to fall back on (`WeatherService.fetch`'s only throwing
    /// case).
    public let nightCloud: NightCloud?
    public let nightCloudError: WeatherError?
    /// W7-E workflow #1 (2026-08-18 owner audit, "rating is the gate on half
    /// the app, and nothing drives you through it"): the numbers behind the
    /// Home dashboard's rating-gate callout -- read from `RatingCoverageQuery`
    /// (unrated nights) and `SensorProfilesQuery` (measured or not), never
    /// counted here or in a view body. `.clear` (zero unrated, sensor
    /// measured) is the honest default for every snapshot that never asked --
    /// the callout only ever shows once a real query says there is something
    /// to drive through.
    public let ratingGate: RatingGate

    /// One `(target, sessionDate)` session anchors `FrameRatingCommand`'s own
    /// scope (`firstKnownFrame`), so `unratedNightCount` here counts exactly
    /// the sessions one "Rate Everything" run would still need to touch --
    /// see `RatingCoverageQuery`'s own doc comment for the precise rule.
    public struct RatingGate: Equatable, Sendable {
        public let unratedNightCount: Int
        public let sensorProfileMeasured: Bool

        public init(unratedNightCount: Int, sensorProfileMeasured: Bool) {
            self.unratedNightCount = unratedNightCount
            self.sensorProfileMeasured = sensorProfileMeasured
        }

        /// Nothing left to rate, and a sensor profile is on record -- the
        /// honest "no gate to show" state, same role `.unconfigured` plays
        /// for `NightContext`.
        public static let clear = RatingGate(unratedNightCount: 0, sensorProfileMeasured: true)
    }

    public init(
        libraryName: String?,
        nightContext: NightContext,
        projectCount: Int = 0,
        nightCount: Int = 0,
        nextProject: ProjectRecord? = nil,
        nextProjectIntegrationSeconds: Double = 0,
        tonightRecommendations: [HomeTonightRecommendation] = [],
        hasActiveProjectsExcludedTonight: Bool = false,
        nightCloud: NightCloud? = nil,
        nightCloudError: WeatherError? = nil,
        ratingGate: RatingGate = .clear
    ) {
        self.libraryName = libraryName
        self.nightContext = nightContext
        self.projectCount = projectCount
        self.nightCount = nightCount
        self.nextProject = nextProject
        self.nextProjectIntegrationSeconds = nextProjectIntegrationSeconds
        self.tonightRecommendations = tonightRecommendations
        self.hasActiveProjectsExcludedTonight = hasActiveProjectsExcludedTonight
        self.nightCloud = nightCloud
        self.nightCloudError = nightCloudError
        self.ratingGate = ratingGate
    }

    /// Neutral preview content: it conveys the shape of the workspace without
    /// inventing a home location, equipment profile, or observation target.
    public static let unconfigured = HomeSnapshot(
        libraryName: nil,
        nightContext: .unconfigured
    )
}

@MainActor
@Observable
public final class HomeStore {
    public typealias TonightProvider = @Sendable (URL) async throws -> [TargetPlan]
    public typealias CalibCoverageProvider = @Sendable (URL) async throws -> [CalibNeed]
    /// Resolves tonight's honest night context for an open library -- real
    /// dusk/dawn (from the site the planner itself would resolve: explicit
    /// config, else the FITS-median fallback) when a site is available,
    /// `.unconfigured` otherwise. Injectable for the same reason
    /// `tonightProvider`/`calibCoverageProvider` are: it lets tests supply a
    /// fixed result without needing a real FITS-backed library on disk.
    public typealias NightContextProvider = @Sendable (URL) async throws -> HomeSnapshot.NightContext
    /// W4-2: resolves tonight's cloud picture for an open library -- `nil`
    /// when weather is off or no site resolves (the honest "no row" case),
    /// throws `WeatherError` only when `WeatherService.fetch` itself throws
    /// (no cached forecast to fall back on). Injectable for the same reason
    /// every other provider here is: tests supply a fixed result without a
    /// real network call.
    public typealias WeatherProvider = @Sendable (URL) async throws -> HomeSnapshot.NightCloud?
    /// W7-E workflow #1: resolves the rating-gate numbers for an open
    /// library -- `RatingCoverageQuery`'s unrated-night count plus
    /// `SensorProfilesQuery`'s "has anything been measured" flag. Injectable
    /// for the same reason every other provider here is: tests supply a
    /// fixed result without a real FITS-backed library or index DB.
    public typealias RatingGateProvider = @Sendable (URL) async throws -> HomeSnapshot.RatingGate
    public private(set) var snapshot: HomeSnapshot
    /// The full plan `tonightRecommendations` was sliced from (`prefix(8)`,
    /// display-only) -- kept around so the "Export Plan" menu
    /// (`v2.home.plan-export`) can hand `ExportService.planCSV`/
    /// `planClipboardText` every planned target, not just the ones shown on
    /// screen.
    public private(set) var tonightPlans: [TargetPlan] = []
    /// Tonight's calibration shopping list (`CalibShoppingList.build`), for
    /// the same export menu's "Copy Shopping List" item -- same actionable +
    /// relevant-tonight filtering V1's "Kalibrációs teendők ma estére" card
    /// already applies.
    public private(set) var calibShoppingItems: [CalibShoppingList.Item] = []
    private let tonightProvider: TonightProvider
    private let calibCoverageProvider: CalibCoverageProvider
    private let nightContextProvider: NightContextProvider
    private let weatherProvider: WeatherProvider
    private let ratingGateProvider: RatingGateProvider
    /// Bumped at the start of every `loadWeather(rootURL:)` call and captured
    /// into that call's own local `generation` -- the weather fetch runs as
    /// its own fire-and-forget `Task` (never awaited by `configure`, so a
    /// slow or failed forecast can't delay the rest of the dashboard), and a
    /// second library open before the first fetch lands must not let the
    /// stale one win. Same guard shape as `PlanningStore.recomputeGeneration`.
    private var weatherGeneration = 0
    /// Test-only handle to the in-flight weather fetch, mirroring
    /// `PlanningStore.pendingRefresh`'s own contract -- `configure` doesn't
    /// await this `Task` itself (weather must never delay the dashboard), so
    /// tests need a way to deterministically wait for it. Never read by
    /// production code.
    private(set) var pendingWeatherLoad: Task<Void, Never>?

    /// All four providers are `Optional`/`nil` rather than defaulted
    /// directly to the `production…` methods, and must stay that way: an
    /// `async` default argument is re-emitted as a `weak`/`linkonce_odr`
    /// async function pointer record in every module that uses it, with a
    /// different context size in the declaring module than in a client (80
    /// vs 64 for `tonightProvider`/`calibCoverageProvider`) -- a link that
    /// pairs the big body with the small record corrupts the task allocator.
    /// `nightContextProvider`'s two copies happen to agree today (144 both
    /// ways, a coincidence of its return type, not a guarantee); it gets the
    /// same shape because the hazard is the pattern, not the one symbol that
    /// currently diverges. `snapshot` is not `async`, emits no such record,
    /// and is deliberately left as an ordinary default.
    /// `AsyncContextSizeGateTests` gates this and carries the full account.
    public init(
        snapshot: HomeSnapshot = .unconfigured,
        tonightProvider: TonightProvider? = nil,
        calibCoverageProvider: CalibCoverageProvider? = nil,
        nightContextProvider: NightContextProvider? = nil,
        weatherProvider: WeatherProvider? = nil,
        ratingGateProvider: RatingGateProvider? = nil
    ) {
        self.snapshot = snapshot
        self.tonightProvider = tonightProvider ?? HomeStore.productionTonight
        self.calibCoverageProvider = calibCoverageProvider ?? HomeStore.productionCalibCoverage
        self.nightContextProvider = nightContextProvider ?? HomeStore.productionNightContext
        self.weatherProvider = weatherProvider ?? HomeStore.productionWeather
        self.ratingGateProvider = ratingGateProvider ?? HomeStore.productionRatingGate
    }

    public func replaceSnapshot(_ snapshot: HomeSnapshot) {
        self.snapshot = snapshot
    }

    /// W4-2: fetches tonight's cloud picture for `rootURL` and folds it into
    /// `snapshot`, off `configure`'s own critical path -- weather is opt-in
    /// side data (same posture as V1's `AppState.loadWeather`) and must never
    /// delay the dashboard the way an awaited call would. Called once from
    /// `configure(libraryName:rootURL:projectsStore:nightCount:)` after that
    /// snapshot lands, and safe to call again on its own (e.g. a future "open
    /// a different library while the first fetch is still in flight" case)
    /// thanks to `weatherGeneration`.
    private func loadWeather(rootURL: URL?) {
        weatherGeneration += 1
        let generation = weatherGeneration
        guard let rootURL else {
            snapshot = Self.withCloud(snapshot, nightCloud: nil, nightCloudError: nil)
            return
        }
        let provider = weatherProvider
        pendingWeatherLoad = Task { [weak self] in
            guard let self else { return }
            do {
                let cloud = try await provider(rootURL)
                guard generation == self.weatherGeneration else { return }
                self.snapshot = Self.withCloud(self.snapshot, nightCloud: cloud, nightCloudError: nil)
            } catch let error as WeatherError {
                guard generation == self.weatherGeneration else { return }
                self.snapshot = Self.withCloud(self.snapshot, nightCloud: nil, nightCloudError: error)
            } catch {
                guard generation == self.weatherGeneration else { return }
                self.snapshot = Self.withCloud(self.snapshot, nightCloud: nil, nightCloudError: nil)
            }
        }
    }

    private static func withCloud(
        _ snapshot: HomeSnapshot,
        nightCloud: HomeSnapshot.NightCloud?,
        nightCloudError: WeatherError?
    ) -> HomeSnapshot {
        HomeSnapshot(
            libraryName: snapshot.libraryName,
            nightContext: snapshot.nightContext,
            projectCount: snapshot.projectCount,
            nightCount: snapshot.nightCount,
            nextProject: snapshot.nextProject,
            nextProjectIntegrationSeconds: snapshot.nextProjectIntegrationSeconds,
            tonightRecommendations: snapshot.tonightRecommendations,
            hasActiveProjectsExcludedTonight: snapshot.hasActiveProjectsExcludedTonight,
            nightCloud: nightCloud,
            nightCloudError: nightCloudError,
            ratingGate: snapshot.ratingGate
        )
    }

    public func configure(libraryName: String, projects: [ProjectRecord], nightCount: Int) {
        let nextProject = projects.first(where: { $0.phase == .collecting }) ?? projects.first
        snapshot = HomeSnapshot(
            libraryName: libraryName,
            nightContext: snapshot.nightContext,
            projectCount: projects.count,
            nightCount: nightCount,
            nextProject: nextProject
        )
    }

    public func configure(
        libraryName: String,
        rootURL: URL? = nil,
        projectsStore: ProjectsStore,
        nightCount: Int
    ) async {
        let plans: [TargetPlan] = if let rootURL {
            (try? await tonightProvider(rootURL)) ?? []
        } else {
            []
        }
        tonightPlans = plans

        // Task 1 (owner feedback wave 3): `Planner.plan` -- this store's own
        // `tonightProvider` -- already stamps every plan with a `SkyVerdict`
        // (the exact same verdict vocabulary `DiscoveryPlanner.discover`
        // shares for Planning, see `AstroCore/Sky/NightSweep.swift`). Look
        // that verdict up by normalized target/display name so "least
        // collected active project" never picks a project whose only target
        // the app already knows it cannot point at tonight (a comet with a
        // stale coordinate, in the owner's own report).
        var verdictByNormalizedName: [String: String] = [:]
        for plan in plans {
            verdictByNormalizedName[Self.normalized(plan.target)] = plan.verdict
            verdictByNormalizedName[Self.normalized(plan.displayName)] = plan.verdict
        }
        func isKnownUnshootableTonight(_ project: ProjectRecord) -> Bool {
            // No verdict on record at all (no plans fetched, or this
            // project's target has no matching plan yet) -- an unknown
            // target must never be penalized for a judgment the engine
            // never actually made.
            guard let verdict = verdictByNormalizedName[Self.normalized(project.catalogID)]
                ?? verdictByNormalizedName[Self.normalized(project.displayName)]
            else { return false }
            return !Self.isShootableTonight(verdict: verdict)
        }

        let active = projectsStore.projects.filter { $0.phase == .collecting || $0.phase == .planned }
        let continuable = active.filter { !isKnownUnshootableTonight($0) }
        var ranked: [(ProjectRecord, Double)] = []
        for project in continuable {
            let integration = (try? await projectsStore.projectSnapshot(id: project.id)?.integrationSeconds) ?? 0
            ranked.append((project, integration))
        }
        let next = ranked.min {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.catalogID < $1.0.catalogID
        }
        // Honest, not silent: distinguishes "no active project exists yet"
        // (show the create-a-project prompt) from "one exists, but none of
        // them can be continued tonight" (say so instead of staying quiet).
        let hasActiveProjectsExcludedTonight = next == nil && !active.isEmpty

        let coverage: [CalibNeed] = if let rootURL {
            (try? await calibCoverageProvider(rootURL)) ?? []
        } else {
            []
        }
        calibShoppingItems = CalibShoppingList.build(coverage: coverage, plans: plans)

        // Task 1: a plan the shared `SkyVerdict` engine already flagged as
        // unshootable tonight (comet stale coordinate, no coordinate, low
        // altitude, or a visible window under half an hour) must never be
        // presented as one of the "best" targets -- see
        // `isShootableTonight`'s own doc for exactly which verdicts qualify.
        let shootablePlans = plans.filter { Self.isShootableTonight(verdict: $0.verdict) }
        let recommendations = shootablePlans.prefix(8).map { plan in
            HomeTonightRecommendation(
                projectID: Self.projectID(for: plan, projects: projectsStore.projects),
                target: plan.target,
                displayName: plan.displayName,
                visibleWindow: plan.visibleWindowLocal,
                culmination: plan.culminationLocal,
                maxAltitude: plan.maxAltitudeDeg,
                moonSeparation: plan.moonSeparationDeg,
                verdict: plan.verdict,
                score: plan.score
            )
        }
        // V2 UI/UX audit (2026-08-14) section 4: this used to carry
        // `snapshot.nightContext` forward completely unchanged, so the home
        // screen's night rail never reflected the library actually open --
        // it now asks `nightContextProvider` for the real answer (or the
        // honest `.unconfigured` state) every time a library opens.
        let nightContext: HomeSnapshot.NightContext = if let rootURL {
            (try? await nightContextProvider(rootURL)) ?? .unconfigured
        } else {
            .unconfigured
        }
        // W7-E workflow #1: same "await it inline, honest default on failure"
        // shape as `nightContext`/`coverage` above -- a fast, synchronous
        // index-DB read (`RatingCoverageQuery`), never worth the fire-and-
        // forget dance `loadWeather` needs for an actual network call.
        let ratingGate: HomeSnapshot.RatingGate = if let rootURL {
            (try? await ratingGateProvider(rootURL)) ?? .clear
        } else {
            .clear
        }
        snapshot = HomeSnapshot(
            libraryName: libraryName,
            nightContext: nightContext,
            projectCount: projectsStore.projects.count,
            nightCount: nightCount,
            nextProject: next?.0,
            nextProjectIntegrationSeconds: next?.1 ?? 0,
            tonightRecommendations: Array(recommendations),
            hasActiveProjectsExcludedTonight: hasActiveProjectsExcludedTonight,
            ratingGate: ratingGate
        )
        // Fire-and-forget, same reasoning as V1's `AppState.loadWeather`
        // (called right after its own site-scoped load lands): weather is
        // opt-in side data, never allowed to delay this method's own await.
        loadWeather(rootURL: rootURL)
    }

    /// `true` for the `SkyVerdict` cases that mean "this target is genuinely
    /// observable tonight, at least in principle" (a plain good night, or one
    /// where only the Moon is a complication -- still worth pointing at).
    /// `false` for every case the shared engine already uses to say the app
    /// itself cannot back this target as a suggestion: no resolvable
    /// coordinate, a comet's stale capture-time coordinate, an altitude that
    /// never clears the imaging threshold, or a window open for under half
    /// an hour. This is the exact same `SkyVerdict` vocabulary
    /// `Planner.plan` (this store's own tonight provider) and
    /// `DiscoveryPlanner.discover` (Planning's engine) both already emit --
    /// see `AstroCore/Sky/NightSweep.swift` -- so filtering here rides on
    /// the one shared classification instead of a second, Home-specific
    /// predicate over raw altitude/coordinate values that could silently
    /// drift from Planning's own rule the way this bug started.
    static func isShootableTonight(verdict: String) -> Bool {
        switch SkyVerdict.parse(verdict) {
        case .goodTonight, .moonInterferes:
            true
        case .noCoordinates, .cometStaleCoordinate, .lowAltitude, .notVisibleTonight, .unrecognized:
            false
        }
    }

    public static func productionTonight(rootURL: URL) async throws -> [TargetPlan] {
        try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            return try Planner.plan(db: database, config: config)
        }.value
    }

    /// Resolves tonight's real dusk/dawn window from whatever site the
    /// planner itself would use -- `Planner.resolveSite` (explicit
    /// `AstroConfig.site`/`sites`, else the FITS-median fallback across the
    /// library's own scanned lights), so this never invents a location the
    /// rest of the app doesn't already treat as authoritative. Falls back to
    /// the honest `.unconfigured` state when no site resolves at all (a
    /// fresh library with no site set and no FITS coordinates yet), or when
    /// tonight's Sun never crosses twilight at this site (`astronomicalTwilight`
    /// returns `nil` dusk/dawn).
    public static func productionNightContext(rootURL: URL) async throws -> HomeSnapshot.NightContext {
        try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            let site = try Planner.resolveSite(db: database, config: config)
            guard let latitudeDeg = site.latitudeDeg, let longitudeDeg = site.longitudeDeg else {
                return .unconfigured
            }

            let now = Date()
            let timeZone = TimeZone.current
            let twilight = SunMoon.astronomicalTwilight(
                nightOf: now, latDeg: latitudeDeg, lonDeg: longitudeDeg, timeZone: timeZone
            )
            guard let duskUTC = twilight.duskUTC, let dawnUTC = twilight.dawnUTC else {
                return HomeSnapshot.NightContext(
                    isConfigured: true,
                    leadingLabel: NSLocalizedString("Dusk", bundle: .main, comment: ""),
                    centerLabel: NSLocalizedString("No astronomical night tonight at this latitude", bundle: .main, comment: ""),
                    trailingLabel: NSLocalizedString("Dawn", bundle: .main, comment: "")
                )
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            formatter.timeZone = timeZone
            // Eagerly localized: the static "Dusk"/"Dawn" word resolves via
            // `NSLocalizedString` (the same key `.unconfigured` above already
            // uses), and the formatted clock time is plain data interpolated
            // AROUND it -- never through a `String(format:)` template, which
            // is this codebase's own eager-localization convention (see
            // `OperationHost.localized(_:)`'s doc comment) and keeps this
            // file free of the `noHandRolledFormatting` gate's banned
            // construct outright, rather than merely reformatted to dodge
            // its substring scan.
            let duskWord = NSLocalizedString("Dusk", bundle: .main, comment: "")
            let dawnWord = NSLocalizedString("Dawn", bundle: .main, comment: "")
            let leadingLabel = duskWord + " " + formatter.string(from: duskUTC)
            let trailingLabel = dawnWord + " " + formatter.string(from: dawnUTC)
            let windowSeconds = dawnUTC.timeIntervalSince(duskUTC)
            let nowFraction: Double? = windowSeconds > 0
                ? min(max(now.timeIntervalSince(duskUTC) / windowSeconds, 0), 1)
                : nil

            let centerLabel: String
            if now < duskUTC {
                centerLabel = NSLocalizedString("Before tonight's dusk", bundle: .main, comment: "")
            } else if now > dawnUTC {
                centerLabel = NSLocalizedString("After tonight's dawn", bundle: .main, comment: "")
            } else {
                // `AstroFormat.compactCountdown` owns the hours/minutes split
                // -- the exact duplicate-formatting shape this file used to
                // hand-roll via `String(format: "%ldh %ldm to dawn", ...)`,
                // invisible to the gate only because the call wrapped onto a
                // second line (see `V2PolishSurfaceTests
                // .noHandRolledFormattingCatchesAMultilineCall`, which pins
                // the tightened gate down against exactly this shape).
                let countdown = AstroFormat.compactCountdown(seconds: dawnUTC.timeIntervalSince(now))
                let toDawnWord = NSLocalizedString("to dawn", bundle: .main, comment: "")
                centerLabel = countdown + " " + toDawnWord
            }

            return HomeSnapshot.NightContext(
                isConfigured: true, leadingLabel: leadingLabel, centerLabel: centerLabel,
                trailingLabel: trailingLabel, nowFraction: nowFraction
            )
        }.value
    }

    /// W4-2: tonight's dusk-to-dawn cloud picture, gated behind the exact
    /// same `config.weather.enabled` opt-in V1's `AppState.loadWeather` reads
    /// (this is the same `config.json`, so a toggle flipped from either V1's
    /// or V2's Settings takes effect here too) -- returns `nil`, not an
    /// error, for "disabled" and "no site resolves", both honest "nothing to
    /// show" cases. Resolves the site independently of `productionNightContext`
    /// (a second `Planner.resolveSite` call rather than threading the first
    /// one's result through) -- the same accepted duplication
    /// `productionSkyContext`/`productionNightContext` already have between
    /// each other, needed here because this method must stay independently
    /// callable (and testable) without entangling `NightContextProvider`'s
    /// own contract.
    public static func productionWeather(rootURL: URL) async throws -> HomeSnapshot.NightCloud? {
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

        let now = Date()
        let timeZone = TimeZone.current
        let twilight = SunMoon.astronomicalTwilight(
            nightOf: now, latDeg: resolved.latitudeDeg, lonDeg: resolved.longitudeDeg, timeZone: timeZone
        )
        let (forecast, dailySummaries) = try await WeatherService.shared.fetch(
            latitude: resolved.latitudeDeg, longitude: resolved.longitudeDeg
        )
        let duskPercent = twilight.duskUTC.flatMap { forecast.cloudPercent(nearestTo: $0) }
        let dawnPercent = twilight.dawnUTC.flatMap { forecast.cloudPercent(nearestTo: $0) }
        // W7-E workflow #2/#3: "tonight" is keyed the same way
        // `WeatherService.dailySummaries` itself buckets a night -- by the
        // LOCAL calendar day `now` falls on, via the same `isoDateFormatter`
        // `NightsStore`/`PlanningStore` already share for this exact lookup.
        let tonightKey = WeatherService.isoDateFormatter.string(from: now)
        let outlook = Self.cloudOutlook(tonightKey: tonightKey, dailySummaries: dailySummaries)
        return HomeSnapshot.NightCloud(
            duskPercent: duskPercent, dawnPercent: dawnPercent, fetchedAt: forecast.fetchedAt,
            isCloudyTonight: outlook.isCloudyTonight, nextClearNight: outlook.nextClearNight
        )
    }

    /// W7-E workflow #2/#3: tonight's mean cloud crosses this to count as
    /// "cloudy" -- the one threshold both the "name the next clear night"
    /// line and the "cloudy night = darks night" card gate on, per the
    /// owner audit's own "~60%" figure.
    static let cloudyThresholdPercent: Double = 60

    /// The pure decision behind `productionWeather`'s cloud-outlook fields,
    /// extracted so `HomeStoreTests` can exercise the actual threshold/search
    /// rule against a plain `dailySummaries` fixture instead of a real
    /// Open-Meteo fetch -- same "extract the pure decision, test it
    /// directly" shape as `isShootableTonight(verdict:)`/`HomeLibraryLoading
    /// .isLoading` elsewhere in this app. `tonightKey` not being present in
    /// `dailySummaries` at all (beyond the horizon, or no dark-hours sample
    /// landed) is treated the same as a clear night: there is nothing honest
    /// to say about a night with no reading.
    static func cloudOutlook(
        tonightKey: String,
        dailySummaries: [String: DailyCloudSummary]
    ) -> (isCloudyTonight: Bool, nextClearNight: HomeSnapshot.NextClearNight?) {
        guard let tonight = dailySummaries[tonightKey], tonight.meanPercent > cloudyThresholdPercent else {
            return (false, nil)
        }
        let laterClearNight = dailySummaries.values
            .filter { $0.date > tonightKey }
            .sorted { $0.date < $1.date }
            .first { $0.meanPercent < cloudyThresholdPercent }
        guard let laterClearNight else {
            return (true, .unavailable)
        }
        return (true, .found(date: laterClearNight.date, minPercent: laterClearNight.minPercent, maxPercent: laterClearNight.maxPercent))
    }

    /// W7-E workflow #1: the Home dashboard's rating-gate numbers --
    /// `RatingCoverageQuery`'s unrated-night count (a fast, synchronous
    /// index-DB read) plus `SensorProfilesQuery`'s "has anything been
    /// measured" flag (its own async read, same as `SensorProfilesStore`
    /// itself uses). Resolves both independently of every other
    /// `production…` method here -- the same accepted duplication
    /// `productionWeather`/`productionNightContext` already have between
    /// each other -- rather than threading either's own `Database`/site
    /// resolution through.
    public static func productionRatingGate(rootURL: URL) async throws -> HomeSnapshot.RatingGate {
        let coverage = try await Task.detached(priority: .utility) {
            try RatingCoverageQuery.production(rootURL: rootURL).snapshot()
        }.value
        let sensorProfiles = try await SensorProfilesQuery.production(rootURL: rootURL).snapshot()
        return HomeSnapshot.RatingGate(
            unratedNightCount: coverage.unratedNightCount,
            sensorProfileMeasured: !sensorProfiles.profiles.isEmpty
        )
    }

    /// Darks + flats concatenated into one list -- same "one merged coverage
    /// list" convention V1's `AppState.loadCalibBundle` already documents for
    /// itself, needed here only as `CalibShoppingList.build`'s own `coverage`
    /// input.
    public static func productionCalibCoverage(rootURL: URL) async throws -> [CalibNeed] {
        let query = try CalibrationQuery.production(rootURL: rootURL)
        return try await Task.detached(priority: .utility) {
            try query.coverage() + query.flatCoverage()
        }.value
    }

    private static func projectID(for plan: TargetPlan, projects: [ProjectRecord]) -> UUID? {
        let keys = [plan.target, plan.displayName].map(normalized)
        return projects.first {
            keys.contains(normalized($0.catalogID)) || keys.contains(normalized($0.displayName))
        }?.id
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined().lowercased()
    }
}
