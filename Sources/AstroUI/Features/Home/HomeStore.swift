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
    /// W7-A leftover (item 3b): honest rendering of `culmination` --
    /// `TargetPlan.isGenuineCulmination == false` means `culmination` (when
    /// non-`nil`) is only the EDGE of tonight's scanned window, not a real
    /// meridian transit (`NightSweepResult.isGenuineCulmination`'s own doc).
    /// `culmination` itself is kept unchanged (raw `HH:mm` or `nil`) for any
    /// other existing reader of this type; `HomeView` renders THIS field
    /// instead of building a "Culminates HH:mm" label straight off
    /// `culmination`.
    public let culminationDisplay: PlanningCulminationDisplay
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
        /// `ClearNightOutlook.cloudyThresholdPercent`. Computed once here, in
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
        /// Expert ideation reserve #5 ("Clear-Night Countdown"): how many of
        /// the fetched 7-day `WeatherService.dailySummaries` count as clear
        /// by `ClearNightOutlook.cloudyThresholdPercent`
        /// (`ClearNightOutlook.clearNightCount`) -- feeds the "Continue
        /// where it matters" card's own clear-night caption
        /// (`HomeView.featuredClearNightCaption`) once paired with
        /// `HomeSnapshot.featuredCompletionForecast`. `nil` whenever no
        /// weather data was fetched at all (weather disabled, no site, or
        /// the fetch failed) -- distinct from a real `0`, which means the
        /// forecast was read and genuinely found no clear night yet.
        public let clearNightsInHorizon: Int?

        public init(
            duskPercent: Double?,
            dawnPercent: Double?,
            fetchedAt: Date,
            isCloudyTonight: Bool = false,
            nextClearNight: NextClearNight? = nil,
            clearNightsInHorizon: Int? = nil
        ) {
            self.duskPercent = duskPercent
            self.dawnPercent = dawnPercent
            self.fetchedAt = fetchedAt
            self.isCloudyTonight = isCloudyTonight
            self.nextClearNight = nextClearNight
            self.clearNightsInHorizon = clearNightsInHorizon
        }
    }

    /// W7-E workflow #3: the outcome of searching `WeatherService
    /// .dailySummaries`'s 7-day forecast for the first night whose own mean
    /// cloud reads back under `ClearNightOutlook.cloudyThresholdPercent`,
    /// once tonight itself has already crossed it. A plain `nil` on `NightCloud`
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
    /// Expert ideation spec #5 ("First-Light Anniversaries + honest
    /// milestones"): today's own real, screenshot-worthy facts about this
    /// library -- a project whose first light lands on today's exact date N
    /// years ago, or one that just crossed a real integration-hour
    /// threshold. `[]` on every ordinary day, the same "nothing real, so
    /// nothing shown" contract `RatingGate.clear`/`NightContext.unconfigured`
    /// already keep -- `HomeStore.composeHighlights` is the one place that
    /// builds this list (from `AnniversaryQuery`/`MilestoneQuery`, capped and
    /// prioritized), never counted or judged again here or in the view body.
    public let highlights: [Highlight]

    /// Expert ideation reserve #5 ("Clear-Night Countdown to project
    /// completion"): the SAME `CompletionForecast.nightsNeeded` estimate
    /// `ProjectWorkspaceView`'s own Overview forecast row computes, resolved
    /// here for `nextProject` specifically so the "Continue where it
    /// matters" card can add one honest caption line once weather data
    /// ALSO exists for this library (`nightCloud?.clearNightsInHorizon`) --
    /// see `HomeView.featuredClearNightCaption`. `nil` on every ordinary
    /// case this estimate itself already returns `nil` for (no
    /// `nextProject`, goal already met, fewer than two recent sessions) --
    /// the same "nothing real, so nothing shown" contract every other
    /// optional field on this snapshot keeps.
    public let featuredCompletionForecast: CompletionForecastEstimate?

    /// Ideation #5 ("Két géped mára" -- tonight's rig split): which saved
    /// `ImagingSetupProfile` best frames which of `tonightRecommendations`,
    /// from `TwoRigSplitQuery.assign` (`AstroApplication`) -- computed FRESH
    /// every `configure(...)`, never re-derived from `tonightRecommendations`
    /// by this view layer. `nil` in two honest cases `HomeView` treats the
    /// same way (hide the whole card): fewer than
    /// `TwoRigSplitQuery.minimumSetupCount` setups are saved (V2 has no
    /// imaging-setup CRUD yet, a known gap), or no `rootURL` is open at all.
    /// An empty (non-`nil`) array means the setups exist but tonight has
    /// nothing to recommend -- also nothing to show.
    public let twoRigSplit: [TwoRigSplitAssignment]?

    /// One `(target, sessionDate)` session anchors `FrameRatingCommand`'s own
    /// scope (`firstKnownFrame`), so `unratedNightCount` here counts exactly
    /// the sessions one "Rate Everything" run would still need to touch --
    /// see `RatingCoverageQuery`'s own doc comment for the precise rule.
    public struct RatingGate: Equatable, Sendable {
        public let unratedNightCount: Int
        public let sensorProfileMeasured: Bool
        /// OWNER BUG (2026-08-19 real-library audit): `RatingCoverageSnapshot.
        /// unmeasurableFrameCount` passed straight through -- frames (CR3
        /// today) no rerun of "Rate Everything" can ever produce a score for.
        /// Surfaced separately so the card can say so honestly instead of
        /// silently omitting them from `unratedNightCount` with no
        /// explanation.
        public let unmeasurableFrameCount: Int

        public init(unratedNightCount: Int, sensorProfileMeasured: Bool, unmeasurableFrameCount: Int = 0) {
            self.unratedNightCount = unratedNightCount
            self.sensorProfileMeasured = sensorProfileMeasured
            self.unmeasurableFrameCount = unmeasurableFrameCount
        }

        /// Nothing left to rate, and a sensor profile is on record -- the
        /// honest "no gate to show" state, same role `.unconfigured` plays
        /// for `NightContext`.
        public static let clear = RatingGate(unratedNightCount: 0, sensorProfileMeasured: true)
    }

    /// One anniversary or milestone card-line, expert ideation spec #5.
    /// `HomeView` maps `kind` to an SF Symbol and a `LocalizedStringKey` at
    /// the view layer (the same `ProjectNextActionKind.localizedTitle`
    /// pattern `ProjectsStore.swift` already establishes) -- this domain
    /// model carries no display string of its own, only the real numbers
    /// (`yearsAgo`/`hours`) and the project identity behind them.
    public struct Highlight: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable {
            case anniversary(yearsAgo: Int)
            case milestone(hours: Int)
            /// Ideation #9 ("Éjszaka-tanulságok banner"): a repeated
            /// `NightHealthLesson` pattern, ranked below every anniversary/
            /// milestone by `HomeStore.composeHighlights`. `failingCount`/
            /// `sessionCount` are `NightHealthLesson`'s own numerator/
            /// denominator, carried through unchanged -- see that type's own
            /// honesty-rail doc comment.
            case coolerLesson(failingCount: Int, sessionCount: Int)
            case focusLesson(failingCount: Int, sessionCount: Int)
        }
        public let kind: Kind
        /// Not a real project/catalog reference for the two lesson `Kind`
        /// cases -- a lesson is a fact about the whole library's recent
        /// sessions, not about one project. `HomeStore.composeHighlights`
        /// fills these with a stable, non-project tag ("night-health-cooler"/
        /// "night-health-focus") purely so `id` stays unique; `HomeView`'s
        /// lesson text is built entirely from `kind`, never from this field.
        public let catalogID: String
        public let displayName: String

        public init(kind: Kind, catalogID: String, displayName: String) {
            self.kind = kind
            self.catalogID = catalogID
            self.displayName = displayName
        }

        public var id: String {
            switch kind {
            case .anniversary(let yearsAgo): "anniversary|\(catalogID)|\(yearsAgo)"
            case .milestone(let hours): "milestone|\(catalogID)|\(hours)"
            case .coolerLesson(let failingCount, let sessionCount): "coolerLesson|\(failingCount)|\(sessionCount)"
            case .focusLesson(let failingCount, let sessionCount): "focusLesson|\(failingCount)|\(sessionCount)"
            }
        }
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
        ratingGate: RatingGate = .clear,
        highlights: [Highlight] = [],
        featuredCompletionForecast: CompletionForecastEstimate? = nil,
        twoRigSplit: [TwoRigSplitAssignment]? = nil
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
        self.highlights = highlights
        self.featuredCompletionForecast = featuredCompletionForecast
        self.twoRigSplit = twoRigSplit
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
    /// Section 5.2 (Kalibrációs automata): flat-only coverage
    /// (`CalibAnalyzer.flatCoverage()`), kept as its OWN provider rather than
    /// folded into `calibCoverageProvider` (which already concatenates dark +
    /// flat for `calibShoppingItems`'s existing "cloudy tonight" card/export
    /// use) -- the Preflight `.flatNeeded` line needs a flat-only count, and
    /// splitting `calibCoverageProvider` itself would change what
    /// `calibShoppingItems`/`cloudyDarksCard` already show today. Injectable
    /// for the same reason every other provider here is.
    public typealias FlatCoverageProvider = @Sendable (URL) async throws -> [CalibNeed]
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
    /// Expert ideation spec #5: resolves today's anniversary/milestone
    /// highlights for an open library. Injectable for the same reason every
    /// other provider here is: tests supply a fixed result without a real
    /// FITS-backed library, index DB, or milestone ledger file on disk.
    public typealias HighlightsProvider = @Sendable (URL) async throws -> [HomeSnapshot.Highlight]
    /// Expert ideation reserve #5 ("Clear-Night Countdown"): resolves
    /// `CompletionForecast.nightsNeeded` for one specific project (`target`
    /// is its `ProjectSnapshot.canonicalFolderName`, the same key
    /// `ProjectStatusQueries`/`TrendQueries` both index by). Injectable for
    /// the same reason every other provider here is: tests supply a fixed
    /// result without a real FITS-backed library or index DB.
    public typealias CompletionOutlookProvider = @Sendable (URL, String) async throws -> CompletionForecastEstimate?
    /// Ideation #5 ("Két géped mára"): resolves `TwoRigSplitQuery.assign`'s
    /// result for an open library, given tonight's already-planned targets
    /// (`configure`'s own `recommendations`, mapped to the dependency-free
    /// `TwoRigSplitTarget` shape -- this is the "reuse Home's existing
    /// tonight data source, never re-plan" contract; see
    /// `TwoRigSplitQuery`'s own doc comment). Injectable for the same reason
    /// every other provider here is: tests supply a fixed result without a
    /// real FITS-backed library, index DB, or saved imaging setups.
    public typealias TwoRigSplitProvider = @Sendable (URL, [TwoRigSplitTarget]) async throws -> [TwoRigSplitAssignment]?
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
    /// Section 5.2 (Kalibrációs automata): the SAME "actionable AND relevant
    /// to tonight" `CalibShoppingList.build` engine `calibShoppingItems`
    /// already uses, run over flat-only coverage instead -- feeds the
    /// Preflight `.flatNeeded` line's `missingCount`. Deliberately a separate
    /// list rather than filtering `calibShoppingItems` by `kind == .flat`:
    /// `calibShoppingItems`'s own coverage input already concatenates dark +
    /// flat (see `productionCalibCoverage`), so filtering it would only ever
    /// see flats that happen to still be present after whatever the darks
    /// side already contributed -- this is computed straight from
    /// `flatCoverageProvider`'s own dedicated flat-only read instead.
    public private(set) var flatShoppingItems: [CalibShoppingList.Item] = []
    /// Pre-flight Checklist (ideation #1, "Indulás előtti lista"): composed
    /// FRESH from state this store already loaded, on every read -- never
    /// stored on `HomeSnapshot` itself, and never a new query of its own.
    /// `PreflightChecklist.build` (`AstroApplication`) is the pure decision;
    /// this property only ever unpacks the exact facts `HomeSnapshot`/
    /// `calibShoppingItems` already carry into that function's plain-value
    /// inputs -- `AstroApplication` cannot depend on this module's own
    /// `HomeSnapshot`, so the seam has to be plain values/`SkyVerdictKind`
    /// (an `AstroCore` type both modules already share), not that struct
    /// itself. See `PreflightChecklist`'s own doc for exactly which four
    /// facts feed this.
    public var preflightChecklist: PreflightChecklist {
        let topRecommendation = snapshot.tonightRecommendations.first.map {
            PreflightChecklist.TopRecommendation(
                displayName: $0.displayName,
                visibleWindow: $0.visibleWindow,
                verdict: SkyVerdict.parse($0.verdict)
            )
        }
        return PreflightChecklist.build(
            calibrationMissingCount: calibShoppingItems.count,
            isCloudyTonight: snapshot.nightCloud?.isCloudyTonight,
            topRecommendation: topRecommendation,
            flatMissingCount: flatShoppingItems.count
        )
    }
    private let tonightProvider: TonightProvider
    private let calibCoverageProvider: CalibCoverageProvider
    private let flatCoverageProvider: FlatCoverageProvider
    private let nightContextProvider: NightContextProvider
    private let weatherProvider: WeatherProvider
    private let ratingGateProvider: RatingGateProvider
    private let highlightsProvider: HighlightsProvider
    private let completionOutlookProvider: CompletionOutlookProvider
    private let twoRigSplitProvider: TwoRigSplitProvider
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
        flatCoverageProvider: FlatCoverageProvider? = nil,
        nightContextProvider: NightContextProvider? = nil,
        weatherProvider: WeatherProvider? = nil,
        ratingGateProvider: RatingGateProvider? = nil,
        highlightsProvider: HighlightsProvider? = nil,
        completionOutlookProvider: CompletionOutlookProvider? = nil,
        twoRigSplitProvider: TwoRigSplitProvider? = nil
    ) {
        self.snapshot = snapshot
        self.tonightProvider = tonightProvider ?? HomeStore.productionTonight
        self.calibCoverageProvider = calibCoverageProvider ?? HomeStore.productionCalibCoverage
        self.flatCoverageProvider = flatCoverageProvider ?? HomeStore.productionFlatCoverage
        self.nightContextProvider = nightContextProvider ?? HomeStore.productionNightContext
        self.weatherProvider = weatherProvider ?? HomeStore.productionWeather
        self.ratingGateProvider = ratingGateProvider ?? HomeStore.productionRatingGate
        self.highlightsProvider = highlightsProvider ?? HomeStore.productionHighlights
        self.completionOutlookProvider = completionOutlookProvider ?? HomeStore.productionCompletionOutlook
        self.twoRigSplitProvider = twoRigSplitProvider ?? HomeStore.productionTwoRigSplit
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
            ratingGate: snapshot.ratingGate,
            highlights: snapshot.highlights,
            featuredCompletionForecast: snapshot.featuredCompletionForecast,
            twoRigSplit: snapshot.twoRigSplit
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
        // Expert ideation reserve #5: `canonicalFolderName` rides along with
        // the same `projectSnapshot` lookup this loop already makes for
        // `integration` -- the "least collected" ranking's own per-project
        // fetch -- rather than a second pass, purely so `next`'s eventual
        // winner already carries the key `completionOutlookProvider` needs
        // (`ProjectStatusQueries`/`TrendQueries` both index by this same
        // canonical folder name, not the raw `catalogID`).
        var ranked: [(ProjectRecord, Double, String?)] = []
        for project in continuable {
            let projectSnapshot = (try? await projectsStore.projectSnapshot(id: project.id)) ?? nil
            ranked.append((project, projectSnapshot?.integrationSeconds ?? 0, projectSnapshot?.canonicalFolderName))
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

        let flatCoverage: [CalibNeed] = if let rootURL {
            (try? await flatCoverageProvider(rootURL)) ?? []
        } else {
            []
        }
        flatShoppingItems = CalibShoppingList.build(coverage: flatCoverage, plans: plans)

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
                culminationDisplay: PlanningCulminationDisplay.derive(
                    culminationLocal: plan.culminationLocal,
                    isGenuineCulmination: plan.isGenuineCulmination,
                    visibleWindowLocal: plan.visibleWindowLocal
                ),
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
        // Expert ideation spec #5: same "await it inline, honest empty
        // default on failure" shape as `ratingGate` above -- a fast,
        // synchronous read (project snapshots plus one small JSON ledger),
        // never worth `loadWeather`'s fire-and-forget dance.
        let highlights: [HomeSnapshot.Highlight] = if let rootURL {
            (try? await highlightsProvider(rootURL)) ?? []
        } else {
            []
        }
        // Expert ideation reserve #5: same "await it inline, honest nil
        // default on failure" shape as `ratingGate`/`highlights` above -- a
        // fast, synchronous index-DB read (`ProjectStatusQueries`/
        // `TrendQueries`), never worth `loadWeather`'s fire-and-forget
        // dance. Only ever computed for the SAME project `next` already
        // names -- `canonicalFolderName == nil` (an unresolved snapshot)
        // is treated the same as "nothing to forecast" rather than guessing
        // at a key.
        let featuredCompletionForecast: CompletionForecastEstimate? = if let rootURL, let next, let target = next.2 {
            (try? await completionOutlookProvider(rootURL, target)) ?? nil
        } else {
            nil
        }
        // Ideation #5 ("Két géped mára"): reuses `recommendations` (this same
        // `configure` call's own tonight plan, already filtered to what's
        // actually shootable and capped to 8) -- `TwoRigSplitQuery.assign`
        // never re-plans. Mapped to the dependency-free `TwoRigSplitTarget`
        // shape since `AstroApplication` cannot see `HomeTonightRecommendation`
        // (this module's own type).
        let twoRigSplit: [TwoRigSplitAssignment]? = if let rootURL {
            (try? await twoRigSplitProvider(
                rootURL,
                recommendations.map { TwoRigSplitTarget(target: $0.target, displayName: $0.displayName) }
            )) ?? nil
        } else {
            nil
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
            ratingGate: ratingGate,
            highlights: highlights,
            featuredCompletionForecast: featuredCompletionForecast,
            twoRigSplit: twoRigSplit
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
        // Expert ideation reserve #5: counted off the SAME `dailySummaries`
        // this fetch already pulled down, no second network call -- see
        // `HomeSnapshot.NightCloud.clearNightsInHorizon`'s own doc comment.
        let clearNightsInHorizon = ClearNightOutlook.clearNightCount(dailySummaries: dailySummaries)
        return HomeSnapshot.NightCloud(
            duskPercent: duskPercent, dawnPercent: dawnPercent, fetchedAt: forecast.fetchedAt,
            isCloudyTonight: outlook.isCloudyTonight, nextClearNight: outlook.nextClearNight,
            clearNightsInHorizon: clearNightsInHorizon
        )
    }

    /// Expert ideation reserve #5: `CompletionForecast.nightsNeeded` for one
    /// project, resolved the exact same way `ProjectReportQuery.project(...)`
    /// (`AstroApplication`'s Reports feature) resolves
    /// `projectState.missingSeconds`/`recentSessionIntegrationSeconds` for
    /// its own Overview forecast row -- `ProjectStatusQueries.projects`
    /// filtered to `target`, `TrendQueries.points` filtered to `target` and
    /// capped to the last 5. Deliberately its own independent DB read
    /// rather than reusing `ProjectReportQuery` itself: that query builds
    /// a whole project report (stacks, sessions, panel geometry, ...) this
    /// caption needs none of, and `AstroUI` already accepts this exact
    /// "duplicate the narrow DB read" trade-off between its own
    /// `production…` methods (see `productionWeather`'s own doc comment).
    public static func productionCompletionOutlook(rootURL: URL, target: String) async throws -> CompletionForecastEstimate? {
        try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            guard let missing = try ProjectStatusQueries.projects(db: database, config: config)
                .first(where: { $0.target == target })?.missingSeconds
            else { return nil }
            let recent = try TrendQueries.points(db: database, config: config)
                .filter { $0.target == target }
                .suffix(5)
                .map(\.integrationSeconds)
            return CompletionForecast.nightsNeeded(remainingSeconds: missing, recentSessionSeconds: recent)
        }.value
    }

    /// Ideation #5 ("Két géped mára"): resolves `config.imagingSetups` and,
    /// for each of `targets`, this library's own dominant historical
    /// `EquipmentProfile` fingerprint (`TwoRigSplitQuery
    /// .historicalDominantFingerprint`, the fallback branch's own input),
    /// then hands both to the pure `TwoRigSplitQuery.assign`. Short-circuits
    /// before any per-target DB read when fewer than
    /// `TwoRigSplitQuery.minimumSetupCount` setups are saved -- the whole
    /// feature is hidden then, so there is nothing to resolve a history for.
    public static func productionTwoRigSplit(
        rootURL: URL, targets: [TwoRigSplitTarget]
    ) async throws -> [TwoRigSplitAssignment]? {
        try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            guard config.imagingSetups.count >= TwoRigSplitQuery.minimumSetupCount else { return nil }

            var mutableFingerprintByTarget: [String: SetupFingerprint] = [:]
            for row in targets {
                if let fingerprint = try? TwoRigSplitQuery.historicalDominantFingerprint(
                    target: row.target, db: database, config: config
                ) {
                    mutableFingerprintByTarget[row.target] = fingerprint
                }
            }
            // `historicalFingerprint` below must be `@Sendable`
            // (`TwoRigSplitQuery.assign`'s own parameter) -- a `let` capture
            // of the finished dictionary, never the `var` being built above,
            // is what makes that legal.
            let fingerprintByTarget = mutableFingerprintByTarget

            return TwoRigSplitQuery.assign(
                targets: targets,
                setups: config.imagingSetups,
                historicalFingerprint: { fingerprintByTarget[$0] }
            )
        }.value
    }

    /// W7-E workflow #2/#3: tonight's mean cloud crosses this to count as
    /// "cloudy" -- the one threshold both the "name the next clear night"
    /// line and the "cloudy night = darks night" card gate on, per the
    /// owner audit's own "~60%" figure.
    ///
    /// Expert ideation reserve #5 ("Clear-Night Countdown"): moved to
    /// `ClearNightOutlook.cloudyThresholdPercent` (`AstroApplication`) so
    /// that feature's own clear-night counting reads the exact same number
    /// rather than an independently-tuned duplicate -- `AstroUI` depends on
    /// `AstroApplication`, never the other way around, so the shared home
    /// has to live there. This alias keeps every existing reference in this
    /// file unchanged.
    static let cloudyThresholdPercent: Double = ClearNightOutlook.cloudyThresholdPercent

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
            sensorProfileMeasured: !sensorProfiles.profiles.isEmpty,
            unmeasurableFrameCount: coverage.unmeasurableFrameCount
        )
    }

    /// Expert ideation spec #5: the COMBINED anniversary + milestone list,
    /// capped and prioritized -- extracted as its own pure function (the
    /// same "extract the pure decision, test it directly" shape
    /// `cloudOutlook`/`isShootableTonight` above already use) so
    /// `HomeStoreTests` can exercise the priority/cap rule directly against
    /// plain `AnniversaryHit`/`MilestoneHit` fixtures rather than a real
    /// library.
    ///
    /// Anniversaries sort ahead of milestones outright (a first-light
    /// anniversary is the rarer, more personal fact of the two), each group
    /// already sorted with its own largest hit first
    /// (`AnniversaryQuery.anniversaries`/`MilestoneQuery.evaluate`'s own
    /// sort) -- "prioritize larger anniversaries" from the spec. `lessons`
    /// (ideation #9, "Éjszaka-tanulságok banner") rank BELOW both -- a
    /// hardware-health pattern is a useful nudge, never as screenshot-worthy
    /// as a real anniversary or milestone, so it only shows once neither of
    /// those has filled the card. The combined list is then capped to
    /// `AnniversaryQuery.maximumHits` (2): three anniversaries firing the
    /// same day show only the two largest, and a milestone -- or a lesson --
    /// is dropped entirely once two anniversaries already fill the card.
    static func composeHighlights(
        anniversaries: [AnniversaryHit],
        milestones: [MilestoneHit],
        lessons: [NightHealthLesson] = []
    ) -> [HomeSnapshot.Highlight] {
        let anniversaryHighlights = anniversaries.map {
            HomeSnapshot.Highlight(kind: .anniversary(yearsAgo: $0.yearsAgo), catalogID: $0.catalogID, displayName: $0.displayName)
        }
        let milestoneHighlights = milestones.map {
            HomeSnapshot.Highlight(kind: .milestone(hours: $0.thresholdHours), catalogID: $0.catalogID, displayName: $0.displayName)
        }
        // See `HomeSnapshot.Highlight.catalogID`'s own doc comment for why
        // these two tags are stable, non-project strings rather than a real
        // catalog reference.
        let lessonHighlights = lessons.map { lesson -> HomeSnapshot.Highlight in
            switch lesson.kind {
            case .coolerNotHoldingSetpoint:
                HomeSnapshot.Highlight(
                    kind: .coolerLesson(failingCount: lesson.failingCount, sessionCount: lesson.sessionCount),
                    catalogID: "night-health-cooler", displayName: ""
                )
            case .focusDrift:
                HomeSnapshot.Highlight(
                    kind: .focusLesson(failingCount: lesson.failingCount, sessionCount: lesson.sessionCount),
                    catalogID: "night-health-focus", displayName: ""
                )
            }
        }
        return Array((anniversaryHighlights + milestoneHighlights + lessonHighlights).prefix(AnniversaryQuery.maximumHits))
    }

    /// Expert ideation spec #5: resolves every project's own snapshot for
    /// `rootURL` (the same per-project `ProjectsQuery.project(id:)` loop
    /// `ProjectsStore.makeWorkspaceRows` already uses to build its own
    /// workspace rows), feeds them to `AnniversaryQuery`/`MilestoneQuery`,
    /// and persists the milestone ledger's updated totals -- the ONE place
    /// in this feature that touches the metadata store or the small JSON
    /// ledger file. A ledger write failure is swallowed (`try?`): a
    /// milestone that fails to persist just risks re-firing next time,
    /// which is a far more honest failure mode than losing today's card or
    /// throwing the whole dashboard load.
    public static func productionHighlights(rootURL: URL) async throws -> [HomeSnapshot.Highlight] {
        let metadata = try ProjectsStore.productionMetadata(rootURL: rootURL)
        let query = ProjectsQuery(metadata: metadata)
        var snapshots: [ProjectSnapshot] = []
        for project in try await metadata.projects() {
            if let snapshot = try await query.project(id: project.id) {
                snapshots.append(snapshot)
            }
        }

        let anniversaries = AnniversaryQuery.anniversaries(projects: snapshots)

        let ledger = try MilestoneLedger.production(rootURL: rootURL)
        let previousTotals = ledger.load()
        let (milestones, updatedTotals) = MilestoneQuery.evaluate(projects: snapshots, previousTotals: previousTotals)
        try? ledger.save(updatedTotals)

        // Ideation #9 ("Éjszaka-tanulságok banner"): same "await it inline,
        // honest empty default on failure" shape the milestone ledger write
        // above already takes -- a lesson that fails to resolve just risks
        // staying silent this once, never worth failing the whole highlights
        // read.
        let lessons = (try? await NightHealthLessons.production(rootURL: rootURL)) ?? []

        return composeHighlights(anniversaries: anniversaries, milestones: milestones, lessons: lessons)
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

    /// Section 5.2 (Kalibrációs automata): flat-only coverage, for the
    /// Preflight `.flatNeeded` line -- see `FlatCoverageProvider`'s own doc
    /// comment for why this is a separate read rather than filtering
    /// `productionCalibCoverage`'s already-combined result.
    public static func productionFlatCoverage(rootURL: URL) async throws -> [CalibNeed] {
        let query = try CalibrationQuery.production(rootURL: rootURL)
        return try await Task.detached(priority: .utility) {
            try query.flatCoverage()
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
