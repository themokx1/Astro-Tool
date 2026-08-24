import AstroApplication
import AstroCore
import Foundation
import Observation
import SwiftUI

/// Tonight's resolved observing site plus the instant it was resolved for --
/// exactly what `PlanningQuery.site`/`date` need, bundled so
/// `PlanningStore.SkyContextProvider` has one return type instead of a tuple.
public struct PlanningSkyContext: Equatable, Sendable {
    public let site: SiteRule
    public let date: Date

    public init(site: SiteRule, date: Date) {
        self.site = site
        self.date = date
    }
}

@MainActor
@Observable
public final class PlanningStore {
    /// Shared with `V2SettingsView`'s Planning tab -- both read and write
    /// the same `UserDefaults` keys, so a preference change there is
    /// reflected here without any direct store-to-store wiring.
    public static let referenceHoursKey = "v2.planning.referenceHours"
    public static let referenceFocalRatioKey = "v2.planning.referenceFocalRatio"
    public static let referenceSurfaceBrightnessKey = "v2.planning.referenceSurfaceBrightness"

    /// Runs the full recommendation pipeline for a given `PlanningQuery`.
    /// Injectable so tests can wrap the production pipeline with a call
    /// counter without needing to make `PlanningQuery.recommendations()`
    /// itself instrumentable. `@Sendable` because it runs inside
    /// `Task.detached`, off the main actor -- see `refresh()`.
    public typealias RecommendationsComputer = @Sendable (PlanningQuery) -> [PlanningRecommendation]
    /// Runs `TargetCatalog.search` for `filteredRecommendations`. Injectable
    /// for the same reason `computeRecommendations` is: it lets tests count
    /// invocations without needing `TargetCatalog` itself to be mockable.
    public typealias CatalogSearch = @Sendable (String, [CatalogTarget]) -> [CatalogTarget]
    /// Resolves tonight's real site the same way `HomeStore`'s
    /// `NightContextProvider` does (`Planner.resolveSite`: explicit config,
    /// else the FITS-median fallback) -- `nil` when no library is open
    /// (`rootURL == nil`) or no site resolves for the one that is.
    /// Injectable so tests can supply a fixed site/date without a real
    /// FITS-backed library on disk.
    public typealias SkyContextProvider = @Sendable (URL?) async throws -> PlanningSkyContext?
    /// W7-B item 1: this library's own measured sky background
    /// (`MeasuredSkyQuery`) -- `nil` when no library is open, or the library
    /// has fewer than `MeasuredSkyQuery.minimumSessionCount` measured
    /// sessions on record, both of which `PlanningQuery.integrationEstimate`
    /// treats as "use the honest μ=21 fallback". Injectable for the same
    /// reason `skyContextProvider` is: tests supply a fixed result without a
    /// real FITS-backed library and index DB.
    public typealias MeasuredSkyProvider = @Sendable (URL?) async throws -> MeasuredSkySurfaceBrightness?
    /// W4-2: tonight's (or the planned night's) per-date cloud summaries for
    /// whichever library is open, keyed the same "yyyy-MM-dd, named by the
    /// night's start" way `DailyCloudSummary.date`/`NightSummary.date`
    /// already are. `nil` means "no row" (weather off, or no site resolves);
    /// throws `WeatherError` only when `WeatherService.fetch` itself throws
    /// (no cached forecast to fall back on). Injectable for the same reason
    /// `skyContextProvider` is: tests supply a fixed result without a real
    /// network call.
    public typealias WeatherProvider = @Sendable (URL?) async throws -> [String: DailyCloudSummary]?
    /// Re-reads this library's saved imaging setups on every `refresh()`,
    /// exactly the fresh-every-call contract `SkyContextProvider`/
    /// `WeatherProvider` already have -- `nil` means "nothing new to
    /// report" (no root yet, or no config on disk at all), which leaves
    /// `setups` untouched; the production implementation only ever returns
    /// nil in exactly that case, falling back to `PlanningStore.defaultSetups`
    /// itself once a real config loads with an empty `imagingSetups` (the
    /// same graceful-degrade a fresh install with no setups configured at
    /// all already gets -- deleting every saved setup must land in the
    /// identical place). Synchronous, unlike the two providers above: it is
    /// only ever a small on-disk JSON read (`SiteSettingsStore
    /// .productionConfigLoader`'s own shape), never a database open.
    public typealias SetupsProvider = @Sendable (URL?) -> [ImagingSetupProfile]?

    /// No longer a `let`: the equipment-setups Settings tab (V2 UI/UX audit,
    /// imaging-setup CRUD) is a SEPARATE `Settings { }` scene from the one
    /// hosting this store (see `SiteSettingsStore`'s own cross-scene doc
    /// comment), so there is no direct call path from an edit there into an
    /// already-running `PlanningStore` here. Instead this is kept fresh the
    /// exact same way `resolvedSite`/`cloudState` already are: `refresh()`
    /// re-reads it from disk via `setupsProvider` on every recompute, never
    /// only once at `init`, so a Settings edit is picked up the next time
    /// anything re-triggers `refresh()` -- no cross-scene signal needed.
    public private(set) var setups: [ImagingSetupProfile]
    /// AppKit's Picker re-asserts the bound selection during its own update
    /// pass, and `didSet` fires on every assignment -- equal values included.
    /// `@Observable` reports a mutation regardless of equality, so an
    /// unguarded didSet here closes an infinite view-invalidation loop
    /// (the build 20016 Planning freeze). Same-value writes must be no-ops.
    public var selectedSetupID: String {
        get { selectedSetupIDStorage }
        set {
            guard newValue != selectedSetupIDStorage else { return }
            selectedSetupIDStorage = newValue
            adoptSelectedSetupDefaults()
            // A setup picked as the COMPARE target can become the newly
            // SELECTED one (the picker's own options exclude the selected
            // setup, so this only happens via `selectedSetupID` moving out
            // from under an already-made compare choice) -- comparing a
            // setup against itself is meaningless, so this clears the now-
            // invalid choice by writing the backing field directly rather
            // than through `compareSetupID`'s own setter, which would kick
            // off a second, redundant `recomputeRigCompare()` on top of the
            // one `refresh()` below already runs at the end of its pipeline.
            if compareSetupIDStorage == selectedSetupIDStorage {
                compareSetupIDStorage = nil
            }
            refresh()
        }
    }
    /// Backs `selectedSetupID` -- `reloadSetupsIfNeeded()` (called from
    /// `refresh()`, i.e. from WITHIN `selectedSetupID`'s own setter's call
    /// chain in the reentrant case) writes here directly to correct a
    /// selection a fresh `setups` reload just invalidated, the same
    /// direct-backing-field technique `compareSetupIDStorage` already uses
    /// to avoid a second, redundant `refresh()`/`recomputeRigCompare()`
    /// dispatch on top of the one already running.
    private var selectedSetupIDStorage: String
    public private(set) var focalLength: Double
    /// Same-value guard: a SwiftUI `TextField` binding can re-assert the
    /// current text during its own update pass, and `didSet` fires on every
    /// assignment -- equal values included. `@Observable` reports a mutation
    /// regardless of equality, so an unguarded didSet here would re-run
    /// `TargetCatalog.search` (and re-notify every observer) on every such
    /// redundant re-assertion -- same reason `selectedSetupID`'s own
    /// `didSet` above is guarded.
    public var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            recomputeFilteredRecommendations()
        }
    }
    /// Same-value guard as `searchText` above -- a `Toggle` binding
    /// re-asserts its current value the same way.
    public var usefulFramingOnly = true {
        didSet {
            guard oldValue != usefulFramingOnly else { return }
            recomputeFilteredRecommendations()
        }
    }
    /// The table's column sort. Defaults to the composite score, descending —
    /// the whole point of the score is that the first row is the best target
    /// for the chosen night.
    public private(set) var sortOrder: [KeyPathComparator<PlanningRecommendation>] = [
        KeyPathComparator(\PlanningRecommendation.planningScore, order: .reverse)
    ]

    /// The night being planned for. `nil` until `activate()` sets it to
    /// today, so a test that injects a fixed sky context keeps using that
    /// context's own date. Same-value guarded like every other setter here:
    /// a `DatePicker` binding re-asserts its value during AppKit's update
    /// pass, and an unguarded write would re-run the whole pipeline (and, as
    /// five separate freeze regressions in this file showed, can close an
    /// invalidation loop).
    public private(set) var planningDate: Date?

    /// Plans for a different night. Normalised to the start of that day, so
    /// picking the same date twice — which a `DatePicker` does routinely — is
    /// a genuine no-op rather than a fresh recompute for a new timestamp.
    public func setPlanningDate(_ date: Date, calendar: Calendar = .current) {
        let normalized = calendar.startOfDay(for: date)
        guard normalized != planningDate else { return }
        planningDate = normalized
        refresh()
    }

    /// Whether the planner is looking at tonight — what the "Today" button
    /// disables itself on.
    public func isPlanningToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let planningDate else { return true }
        return calendar.isDate(planningDate, inSameDayAs: now)
    }

    /// Off by default: a target that can't clear the imaging altitude
    /// threshold tonight (`PlanningRecommendation.isLowAltitude`) must not
    /// read as a good suggestion (the bug this store was rebuilt to fix --
    /// see `PlanningQuery`'s own doc). Same-value guard as the toggles above.
    public var showLowAltitudeTargets = false {
        didSet {
            guard oldValue != showLowAltitudeTargets else { return }
            recomputeFilteredRecommendations()
        }
    }

    /// The library whose site `refresh()` resolves tonight's sky against --
    /// `nil` means no library is open. Set via `setRootURL(_:)`, mirroring
    /// `selectedSetupID`'s same-value-guarded, refresh-triggering contract.
    public private(set) var rootURL: URL?
    /// Whether tonight's sky ranking is actually available, distinguishing
    /// "no library open yet" and "library open but no site resolves" from
    /// the genuine "computed, ranking available" state -- `PlanningView`
    /// shows an explicit, honest prompt for the first two rather than an
    /// empty results table (see `PlanningQuery.site`'s own doc: no site
    /// means no invented ranking).
    public enum SkyAvailability: Equatable, Sendable {
        case pending
        case noLibrary
        case noSite
        case available
    }
    public private(set) var skyAvailability: SkyAvailability = .pending

    /// W4-2: the planned night's cloud picture -- one indicator for the
    /// WHOLE table (every row shares tonight's sky, so this is per-night,
    /// not a column repeating the same value on every row). `.hidden`
    /// mirrors `HomeSnapshot`'s "no site configured -> no weather row, no
    /// error" rule exactly (weather off, or no site resolves); `.error` is
    /// the one case something IS shown despite there being no summary: a
    /// fetch that failed outright with no cached forecast to fall back on.
    public enum PlanningCloudState: Equatable, Sendable {
        case hidden
        case summary(DailyCloudSummary)
        case beyondHorizon
        case error(WeatherError)
    }
    public private(set) var cloudState: PlanningCloudState = .hidden

    /// The full recommendation pipeline's most recent result -- STORED, not
    /// computed. Build 20013 shipped a crash (and, with the underlying
    /// `NSException` swallowed, a multi-second 98%-CPU main-thread hang)
    /// that traced straight to this property: `PlanningView.body` reads it
    /// (via `filteredRecommendations`) 3+ times per layout pass, and it used
    /// to be a COMPUTED property that built a fresh `PlanningQuery` and ran
    /// the full 217-target catalog pipeline synchronously on the main actor
    /// on every single access. It is now recomputed only when an input
    /// actually changes (`selectedSetupID`, `focalLength`, the three
    /// `v2.planning.reference*` preferences, or an explicit `refresh()`
    /// call), off the main actor, via `Task.detached`.
    public private(set) var recommendations: [PlanningRecommendation] = []
    /// `true` from the moment a recompute is kicked off until its result
    /// lands -- lets `PlanningView` tell "still computing, first load" apart
    /// from a genuine "no matches" empty state.
    public private(set) var isComputing = false
    /// Tonight's resolved site, as last landed by `refresh()` -- kept around
    /// (not just used transiently inside that `Task`) so `recomputeSkyPath()`
    /// can build a `SkyPathQuery` for whichever target is currently selected
    /// without re-resolving the site itself. `nil` exactly when
    /// `skyAvailability` isn't `.available`.
    private var resolvedSite: SiteRule?
    /// The Planning table's currently-selected target, set by `PlanningView`
    /// via `selectTarget(_:)` -- Task 3's sky-path chart is keyed on this,
    /// recomputed off the main actor the same way `recommendations` is,
    /// never in `body`.
    public private(set) var selectedSkyPathTarget: CatalogTarget?
    /// The selected target's altitude sweep for the planned night -- STORED,
    /// recomputed only when the selection or tonight's resolved site/date
    /// actually changes. `nil` means "nothing selected", "no site resolved",
    /// or "this target's sweep couldn't be computed" -- `PlanningView` shows
    /// an honest empty state rather than inventing a flat line.
    public private(set) var skyPath: SkyPathResult?
    /// `true` from the moment a sky-path recompute is kicked off until its
    /// result lands -- mirrors `isComputing`'s own "still computing" story,
    /// one level down (per-selection rather than per-refresh).
    public private(set) var isComputingSkyPath = false
    /// Bumped at the start of every sky-path recompute -- same stale-result
    /// guard `recomputeGeneration` gives `refresh()`, one level down.
    private var skyPathGeneration = 0
    /// Test-only handle to the in-flight sky-path recompute `Task`, mirroring
    /// `pendingRefresh`'s own contract -- never read by production code.
    private(set) var pendingSkyPathRefresh: Task<Void, Never>?
    /// Season Window Finder (expert ideation reserve #1): the selected
    /// target's year-shaped visibility at tonight's resolved site --
    /// "when does its usable window open, peak, close", not just tonight.
    /// STORED and recomputed off the main actor, same discipline as
    /// `skyPath`/`recommendations` above -- `SeasonWindowQuery.evaluate`
    /// sweeps ~150-200 single-target `DiscoveryPlanner.discover` calls, cheap
    /// enough for one selection but not for `body` or for the whole catalog.
    /// `nil` means "nothing selected" or "no site resolved" -- the same
    /// honest-empty-state contract `skyPath` already has.
    public private(set) var seasonWindow: SeasonWindowResult?
    public private(set) var isComputingSeasonWindow = false
    private var seasonWindowGeneration = 0
    /// Test-only handle to the in-flight season-window recompute `Task`,
    /// mirroring `pendingSkyPathRefresh`'s own contract -- never read by
    /// production code.
    private(set) var pendingSeasonWindowRefresh: Task<Void, Never>?
    /// Session-lifetime cache keyed by (designation, site) -- a season
    /// doesn't depend on `planningDate` at all (it's an evergreen property of
    /// target+site), so re-selecting an already-evaluated target, or picking
    /// a different night for the SAME target, must never re-run the sweep.
    /// Never persisted, never grown by anything other than a genuine
    /// on-selection evaluate -- explicitly NOT a whole-catalog cache.
    private var seasonWindowCache: [SeasonWindowCacheKey: SeasonWindowResult] = [:]

    /// Ideation #2 ("melyik géppel fér be?"), reworked per owner feedback
    /// (2026-08-19): a boolean "compare with the other rig" checkbox only
    /// ever made sense with exactly two saved setups -- with three or more
    /// there is no single "other" rig for a checkbox to imply, and the
    /// checkbox's own label baked in that other setup's name, which read as
    /// the owner's personal gear hardcoded into the product. This is now the
    /// EXPLICITLY picked comparison setup's `id` -- `nil` means "off", same
    /// meaning `compareOtherRig == false` used to carry. Backed by
    /// `compareSetupIDStorage` (not a plain stored `didSet`) so
    /// `selectedSetupID`'s own didSet can clear a now-invalid selection by
    /// writing that backing field directly, without a second, redundant
    /// `recomputeRigCompare()` dispatch -- `refresh()` already calls it once
    /// more at the end of its own pipeline regardless.
    public var compareSetupID: String? {
        get { compareSetupIDStorage }
        set {
            guard newValue != compareSetupIDStorage else { return }
            compareSetupIDStorage = newValue
            recomputeRigCompare()
        }
    }
    private var compareSetupIDStorage: String?
    /// `true` only once ≥2 setups are saved -- `PlanningView` hides the
    /// compare picker entirely below that, matching the feature's own scope
    /// note: V2 has no setups CRUD yet, so an owner with 0-1 setups simply
    /// never sees a control that could never do anything for them.
    public var canCompareRigs: Bool { setups.count >= 2 }
    /// Every saved setup EXCEPT the one currently selected -- `PlanningView`'s
    /// picker options, so an owner with three or more setups can name exactly
    /// which one to compare against instead of the old checkbox's forced
    /// "the other one" guess.
    public var compareOptions: [ImagingSetupProfile] {
        setups.filter { $0.id != selectedSetupID }
    }
    /// The setup `compareSetupID` currently names, resolved against `setups`
    /// -- `nil` while comparison is off, or if a stale ID (a setup removed
    /// out from under an active selection; no setups CRUD exists in V2 yet,
    /// but this stays honest rather than assuming it can't happen) no longer
    /// resolves.
    public var compareSetup: ImagingSetupProfile? {
        guard let compareSetupID else { return nil }
        return setups.first { $0.id == compareSetupID }
    }
    /// This target's FOV-fit comparison across both rigs, keyed by
    /// `CatalogTarget.designation` -- `nil` while comparison is off, the
    /// picked setup no longer resolves, or nothing has resolved yet to
    /// compare against. STORED and recomputed only by `recomputeRigCompare()`,
    /// off the main actor -- never derived in `PlanningView.body`, the same
    /// "recompute path, not a body-time derivation" discipline
    /// `recommendations`/`filteredRecommendations`/`skyPath`/`seasonWindow`
    /// all already follow in this file.
    public private(set) var rigCompare: [String: RigCompareRow]?
    public private(set) var isComputingRigCompare = false
    private var rigCompareGeneration = 0
    /// Test-only handle to the in-flight rig-compare recompute `Task`,
    /// mirroring `pendingSkyPathRefresh`'s own contract -- never read by
    /// production code.
    private(set) var pendingRigCompareRefresh: Task<Void, Never>?
    /// Runs `RigCompareQuery.compare` for `recomputeRigCompare()`. Injectable
    /// for the same reason `computeRecommendations` is: it lets
    /// `PlanningStoreTests` control the relative timing of two overlapping
    /// sweeps (proving the stale-generation guard drops the older one)
    /// without needing `RigCompareQuery` itself to be mockable. `@Sendable`
    /// because it runs inside `Task.detached`, off the main actor -- see
    /// `recomputeRigCompare()`.
    public typealias RigCompareComputer = @Sendable (
        _ selectedSetupID: String,
        _ compareSetupID: String,
        _ setups: [ImagingSetupProfile],
        _ focalLengthMM: Double?,
        _ site: SiteRule,
        _ date: Date,
        _ targets: [CatalogTarget]
    ) -> [String: RigCompareRow]?
    private let defaults: UserDefaults
    private let computeRecommendations: RecommendationsComputer
    private let computeRigCompare: RigCompareComputer
    /// Bumped at the start of every `refresh()` and captured into that
    /// call's own local `generation` -- mirrors the guard
    /// `ProjectsStore.selectProject` uses for the same "several async calls
    /// in flight, only the newest one's completion may win" race. Without
    /// it, a slow stale recompute (e.g. the very first one, racing a
    /// slider-driven `setFocalLength` burst) could land AFTER a newer one
    /// and silently revert `recommendations` to stale data.
    private var recomputeGeneration = 0
    /// Test-only handle to the in-flight recompute `Task`, so
    /// `PlanningStoreTests` can deterministically `await` a
    /// `didSet`/preference-triggered `refresh()` instead of polling
    /// `isComputing`. Never read by production code. Also set by
    /// `scheduleDebouncedFocalLengthRefresh()` below, once its own debounce
    /// window elapses and it actually calls `refresh()` -- so awaiting this,
    /// same as every other test in this file already does, still covers a
    /// slider-driven refresh end to end, sleep included.
    private(set) var pendingRefresh: Task<Void, Never>?
    /// How long `setFocalLength` waits for a slider drag to settle before
    /// letting `refresh()`'s heavy pipeline run -- see
    /// `scheduleDebouncedFocalLengthRefresh()`. `PlanningStoreTests` injects
    /// near-zero (via `init`) to exercise the real cancel-and-replace code
    /// path without an actual multi-hundred-millisecond sleep per test.
    private let focalLengthDebounceInterval: Duration
    /// The in-flight "waiting for the drag to settle" `Task`, so a fresh
    /// `setFocalLength` tick can cancel the PREVIOUS tick's wait before it
    /// ever reaches `refresh()` -- see `scheduleDebouncedFocalLengthRefresh()`.
    /// Distinct from `pendingRefresh` above (which this sets once the wait
    /// elapses): this one exists purely for cancel-and-replace bookkeeping,
    /// never awaited directly by production code or tests.
    private var pendingFocalLengthRefresh: Task<Void, Never>?
    /// The three `v2.planning.reference*` values as last read when a
    /// recompute was kicked off -- compared against the live values in
    /// `handleDefaultsChange()` so an unrelated `UserDefaults` write (the
    /// notification fires for the whole suite, not just these three keys)
    /// doesn't trigger a spurious recompute.
    private var lastObservedReferenceHours: Double
    private var lastObservedReferenceFocalRatio: Double
    private var lastObservedReferenceSurfaceBrightness: Double
    private let catalogSearch: CatalogSearch
    private let catalogProvider: CatalogProvider
    private let setupsProvider: SetupsProvider
    private let skyContextProvider: SkyContextProvider
    private let weatherProvider: WeatherProvider
    private let measuredSkyProvider: MeasuredSkyProvider
    /// `nonisolated(unsafe)`: only ever mutated on the main actor (`init`),
    /// but `deinit` is always `nonisolated` (it may run on any thread), so
    /// it needs to read this without a MainActor-isolation check. Safe --
    /// by the time `deinit` runs, no other code holds a reference through
    /// which this could race.
    private nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?

    /// The catalog the planner ranks and searches. Defaults to the built-in
    /// 217 objects merged with whatever the opt-in SIMBAD/VizieR fetch has
    /// cached, so enabling the extended catalog in Settings actually widens
    /// what Planning shows — without it, the download would be invisible here.
    /// Not `@Sendable`: it is only ever called on the main actor, in
    /// `refresh()`, before the detached compute starts — the resulting array
    /// is what crosses the isolation boundary, not this closure.
    public typealias CatalogProvider = @MainActor () -> [CatalogTarget]

    /// Cache key for `productionCatalog()`'s memoization immediately below --
    /// captures exactly the two inputs that can change what it returns: the
    /// opt-in toggle, and the on-disk cache file's own modification date (a
    /// cheap `stat`, not a re-read). The catalog itself never depends on
    /// focal length or anything else `refresh()` juggles, so between a
    /// toggle flip and a fresh "Update Catalog" fetch (which rewrites the
    /// file) there is nothing to invalidate.
    private struct CatalogCacheKey: Equatable {
        let enabled: Bool
        let modificationDate: Date?
    }

    /// `nonisolated(unsafe)`: `productionCatalog()` is declared `nonisolated`
    /// so it can serve as a plain default-argument value, but its only two
    /// call sites (this type's own `init` default and `SavedTargetsStore`'s)
    /// are both `@MainActor`, so in practice this is only ever read or
    /// written from the main actor -- same invariant `defaultsObserver`
    /// above already relies on, for the same reason.
    private nonisolated(unsafe) static var cachedCatalog: (key: CatalogCacheKey, targets: [CatalogTarget])?

    /// Reads the cache only when the user opted in. A missing, corrupt or
    /// version-mismatched cache falls back to the built-in catalog rather
    /// than failing (`CatalogCache.load()` returns `nil` for all three).
    /// `nonisolated` and parameterless so the default search closure — which
    /// must be `@Sendable` — can call it without capturing anything.
    ///
    /// Memoized by `CatalogCacheKey` above: `refresh()` calls this
    /// synchronously on the main actor on every single focal-length tick
    /// (a slider drag fires dozens of these), and re-reading + re-decoding
    /// the whole extended catalog from disk and re-merging it with the
    /// built-in one on EVERY tick is exactly the "heavy work re-run on every
    /// access" defect class `recommendations`/`filteredRecommendations`'s
    /// own doc comments already describe for this same page -- measured at
    /// ~39ms per call with a real extended-catalog cache on disk, which is
    /// what made `testPlanningStaysResponsiveUnderRepeatedEntryAndSliderDrag`
    /// blow its budget. A cache hit costs one `stat()`.
    nonisolated public static func productionCatalog() -> [CatalogTarget] {
        // Absent key means "never touched the toggle", and the toggle now
        // defaults to on -- `bool(forKey:)` alone would read that as off.
        let enabled = UserDefaults.standard.object(forKey: extendedCatalogEnabledKey) as? Bool ?? true
        let fileURL = enabled ? try? CatalogCache.productionFileURL() : nil
        let modificationDate: Date? = fileURL.flatMap { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        let key = CatalogCacheKey(enabled: enabled, modificationDate: modificationDate)
        if let cached = cachedCatalog, cached.key == key {
            return cached.targets
        }
        let targets: [CatalogTarget]
        if let fileURL, let payload = CatalogCache(fileURL: fileURL).load() {
            targets = TargetCatalog.merged(cached: payload.targets)
        } else {
            targets = TargetCatalog.all
        }
        cachedCatalog = (key, targets)
        return targets
    }

    /// Mirrors `V2SettingsView`'s `@AppStorage` key for the opt-in toggle.
    nonisolated public static let extendedCatalogEnabledKey = "v2.settings.extended-catalog"

    public init(
        setups: [ImagingSetupProfile] = PlanningStore.defaultSetups,
        defaults: UserDefaults = .standard,
        computeRecommendations: @escaping RecommendationsComputer = { $0.recommendations() },
        /// Injectable for the same reason `computeRecommendations` is --
        /// `PlanningStoreTests` uses this to control the relative timing of
        /// two overlapping rig-compare sweeps, proving `rigCompareGeneration`
        /// actually drops a stale one rather than letting it clobber a newer
        /// result.
        computeRigCompare: @escaping RigCompareComputer = { selectedSetupID, compareSetupID, setups, focalLengthMM, site, date, targets in
            RigCompareQuery.compare(
                selectedSetupID: selectedSetupID,
                compareSetupID: compareSetupID,
                setups: setups,
                focalLengthMM: focalLengthMM,
                site: site,
                date: date,
                targets: targets
            )
        },
        catalogSearch: CatalogSearch? = nil,
        catalogProvider: CatalogProvider? = nil,
        /// Not `async`, so (unlike the three providers below) this can stay
        /// a plain defaulted parameter -- the async-default-argument bug
        /// documented on `skyContextProvider` below only affects `async`
        /// closures.
        setupsProvider: @escaping SetupsProvider = PlanningStore.productionSetupsProvider,
        /// Optional rather than an async default argument. Swift 6.3.3 emits
        /// an async default's implicit closure as a `weak private external`
        /// record whose context size differs between the defining module and
        /// its clients; whichever copy the linker keeps, one side is wrong,
        /// and the resume funclet overruns the task allocator. See
        /// `docs/swift-async-default-arg-bug/` and `AsyncContextSizeGateTests`.
        /// Resolving inside the body keeps the record non-external.
        ///
        /// This site was MISSED by the original sweep (`46c83c9`, which fixed
        /// HomeStore/NightsStore/GlobalSearchStore/SiteSettingsStore) because
        /// the sizes happened to agree at that moment. The gate caught it
        /// later when unrelated edits re-rolled the layout -- which is exactly
        /// the failure mode the gate exists for, and why a source audit alone
        /// was never going to be enough.
        skyContextProvider: SkyContextProvider? = nil,
        /// Same `Optional`-not-async-default shape as `skyContextProvider`
        /// immediately above, for the identical reason.
        weatherProvider: WeatherProvider? = nil,
        /// Same `Optional`-not-async-default shape as `skyContextProvider`
        /// immediately above, for the identical reason.
        measuredSkyProvider: MeasuredSkyProvider? = nil,
        /// See `focalLengthDebounceInterval`'s own doc comment. A plain
        /// defaulted `Duration`, not `Optional`-with-a-static-fallback like
        /// the three providers above -- it isn't `async`, so it doesn't hit
        /// the async-default-argument bug those work around.
        focalLengthDebounceInterval: Duration = .milliseconds(200)
    ) {
        let safeSetups = setups.isEmpty ? PlanningStore.defaultSetups : setups
        self.setups = safeSetups
        self.defaults = defaults
        self.computeRecommendations = computeRecommendations
        self.computeRigCompare = computeRigCompare
        self.setupsProvider = setupsProvider
        self.skyContextProvider = skyContextProvider ?? PlanningStore.productionSkyContext
        self.weatherProvider = weatherProvider ?? PlanningStore.productionWeather
        self.measuredSkyProvider = measuredSkyProvider ?? PlanningStore.productionMeasuredSky
        self.catalogProvider = catalogProvider ?? { PlanningStore.productionCatalog() }
        self.focalLengthDebounceInterval = focalLengthDebounceInterval
        // Search the SAME catalog the ranking uses, so a target that appears
        // in the table can always be found by name and vice versa.
        // Searches whatever catalog the ranking actually used (passed in by
        // `recomputeFilteredRecommendations`), so extended-catalog targets
        // stay findable and search can never offer a target the table lacks.
        self.catalogSearch = catalogSearch ?? { query, source in
            TargetCatalog.search(query, limit: source.count, in: source)
        }
        let initial = safeSetups.first(where: \.isDefault) ?? safeSetups[0]
        selectedSetupIDStorage = initial.id
        focalLength = initial.defaultFocalLengthMM
        lastObservedReferenceHours = defaults.double(forKey: Self.referenceHoursKey)
        lastObservedReferenceFocalRatio = defaults.double(forKey: Self.referenceFocalRatioKey)
        lastObservedReferenceSurfaceBrightness = defaults.double(forKey: Self.referenceSurfaceBrightnessKey)
    }

    /// Sets the library `refresh()` resolves tonight's site against.
    /// Same-value guard: `PlanningView`'s `.task(id: rootURL)` re-runs on
    /// every observation of a SwiftUI view identity, not just genuine
    /// changes -- same reason `selectedSetupID`/`setFocalLength` guard
    /// themselves.
    public func setRootURL(_ url: URL?) {
        guard url != rootURL else { return }
        rootURL = url
        refresh()
    }

    /// Registers the Planning baseline fallbacks.
    ///
    /// This deliberately does NOT live in `init`. `UserDefaults.register`
    /// posts `UserDefaults.didChangeNotification`, and SwiftUI re-evaluates
    /// `PlanningView`'s `@State` default expression -- i.e. constructs a
    /// throwaway store -- on every view construction. Registering from `init`
    /// therefore posted a defaults-change notification once per render, which
    /// invalidates every `@AppStorage` property in the mounted tree
    /// (`V2RootView`, `HomeView`, `V2SettingsView`); the shell re-rendered,
    /// Planning re-rendered, and the next throwaway store posted again. That
    /// closed the loop behind the build 20017 Planning freeze, measured at
    /// 99% CPU on Planning while Home and Projects sat at 0%.
    private func registerReferenceDefaults() {
        defaults.register(defaults: [
            Self.referenceHoursKey: IntegrationTimeModel.referenceHours,
            Self.referenceFocalRatioKey: 5.0,
            Self.referenceSurfaceBrightnessKey: IntegrationTimeModel.referenceSurfaceBrightness,
        ])
        lastObservedReferenceHours = defaults.double(forKey: Self.referenceHoursKey)
        lastObservedReferenceFocalRatio = defaults.double(forKey: Self.referenceFocalRatioKey)
        lastObservedReferenceSurfaceBrightness = defaults.double(forKey: Self.referenceSurfaceBrightnessKey)
    }

    /// `init` must stay free of side effects: `PlanningView` holds this store
    /// as `@State private var store = PlanningStore()`, and SwiftUI
    /// re-evaluates that default value on every view construction -- one per
    /// enclosing render pass -- keeping only the first instance. A
    /// side-effectful `init` therefore launches one discarded full-pipeline
    /// compute per render (the build 20015 Planning freeze). The view calls
    /// this from `.task`, which runs once per view identity.
    private var isActivated = false

    public func activate(now: Date = Date(), calendar: Calendar = .current) {
        guard !isActivated else { return }
        isActivated = true
        registerReferenceDefaults()
        observeDefaultsChanges()
        // The planner opens on tonight; the date picker can move it from here.
        planningDate = calendar.startOfDay(for: now)
        refresh()
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    public var selectedSetup: ImagingSetupProfile {
        setups.first { $0.id == selectedSetupID } ?? setups[0]
    }

    public func makeBriefingSeed(for recommendation: PlanningRecommendation?) -> NightBriefingSeed {
        let date = planningDate ?? Date()
        let isHungarian = Locale.current.language.languageCode?.identifier == "hu"
        let site = resolvedSite.flatMap { rule -> BriefingSiteSummary? in
            guard let latitude = rule.latitudeDeg, let longitude = rule.longitudeDeg else { return nil }
            let name = "\(AstroFormat.degrees(latitude)), \(AstroFormat.degrees(longitude))"
            return BriefingSiteSummary(id: "\(latitude),\(longitude)", name: name)
        }
        let setup = BriefingSetupSummary(id: selectedSetup.id, name: selectedSetup.name)
        let target: BriefingTargetBlock? = recommendation.flatMap { row in
            guard let path = skyPath,
                  path.target.designation == row.target.designation
            else { return nil }
            let usable = path.samples.filter { $0.altitudeDeg >= path.minAltitudeDeg }
            guard let start = usable.first?.time,
                  let end = usable.last?.time,
                  end > start
            else { return nil }
            return BriefingTargetBlock(
                name: row.target.designation,
                role: .primary,
                start: start,
                end: end,
                astronomicalStart: path.duskUTC,
                astronomicalEnd: path.dawnUTC,
                capturePlan: .init(filterName: selectedSetup.defaultFilterName),
                warnings: [
                    "Maximum altitude: \(AstroFormat.wholeDegrees(path.maxAltitudeDeg))",
                    path.moonSeparationDeg.map { "Moon separation: \(AstroFormat.wholeDegrees($0))" },
                ].compactMap { $0 }
            )
        }
        let sky: BriefingDataState<BriefingSkySummary>
        if let path = skyPath,
           recommendation?.target.designation == path.target.designation {
            sky = .known(.init(
                darknessStart: path.duskUTC,
                darknessEnd: path.dawnUTC,
                maxAltitudeDeg: path.maxAltitudeDeg,
                minimumAltitudeDeg: path.minAltitudeDeg,
                moonSeparationDeg: path.moonSeparationDeg,
                altitudePoints: path.samples.map { .init(time: $0.time, altitudeDeg: $0.altitudeDeg) }
            ))
        } else {
            sky = .missing(reason: isHungarian ? "Nincs ellenőrzött égútadat." : "No verified sky-path data is available.")
        }
        let equipment: BriefingDataState<BriefingEquipmentFacts> = .known(.init(
            cameraName: selectedSetup.cameraName,
            focalLengthMM: focalLength,
            fNumber: selectedSetup.fNumber,
            filterName: selectedSetup.defaultFilterName
        ))
        let project: BriefingDataState<BriefingProjectProgress> = .missing(
            reason: isHungarian ? "Nincs megadott projektcél." : "No project goal is available."
        )
        let weather: BriefingDataState<BriefingWeatherSummary>
        switch cloudState {
        case .summary(let summary):
            let range = "\(AstroFormat.percent(summary.minPercent))–\(AstroFormat.percent(summary.maxPercent))"
            let mean = AstroFormat.percent(summary.meanPercent)
            let text = isHungarian
                ? "Felhőzet \(range), átlag \(mean)"
                : "Cloud \(range), mean \(mean)"
            weather = .known(.init(summary: text, source: "Open-Meteo", updatedAt: nil))
        case .beyondHorizon:
            weather = .missing(reason: isHungarian ? "A dátum kívül esik a 7 napos előrejelzésen." : "The date is beyond the 7-day forecast horizon.")
        case .error:
            weather = .missing(reason: isHungarian ? "Az előrejelzés nem volt elérhető." : "The forecast was unavailable.")
        case .hidden:
            weather = .missing(reason: isHungarian ? "Az időjárás nincs bekapcsolva vagy nincs helyszín." : "Weather is disabled or no site is available.")
        }
        return NightBriefingSeed(
            date: date,
            site: site,
            setup: setup,
            target: target,
            context: .init(sky: sky, equipment: equipment, projectProgress: project),
            weather: weather
        )
    }

    public var fieldOfView: SetupFieldOfView? {
        selectedSetup.fieldOfView(at: focalLength)
    }

    /// The Planning tab's integration baseline (`v2.planning.reference*`),
    /// read live from `UserDefaults` on every access -- a preference change
    /// while this store is alive (e.g. the Settings window is open at the
    /// same time) is picked up via `handleDefaultsChange()` below, which
    /// re-reads these and kicks off a `refresh()` if any of the three
    /// actually moved.
    public var referenceHours: Double { defaults.double(forKey: Self.referenceHoursKey) }
    public var referenceFocalRatio: Double { defaults.double(forKey: Self.referenceFocalRatioKey) }
    public var referenceSurfaceBrightness: Double { defaults.double(forKey: Self.referenceSurfaceBrightnessKey) }

    /// Cached filter over `recommendations` -- STORED, not computed, for the
    /// identical reason `recommendations` itself is: `PlanningView.body`
    /// reads this 3+ times per layout pass (the "Useful matches" metric
    /// card, the `isEmpty` branch, and the `Table`'s data source), and this
    /// used to be a computed property that ran a full 217-target
    /// `TargetCatalog.search` on every single one of those reads. It is now
    /// recomputed only when an input actually changes (`recommendations`,
    /// `searchText`, or `usefulFramingOnly`), via `recomputeFilteredRecommendations()`.
    public private(set) var filteredRecommendations: [PlanningRecommendation] = []

    public func setFocalLength(_ value: Double) {
        let clamped = min(max(value, selectedSetup.focalLengthMinMM), selectedSetup.focalLengthMaxMM)
        // Same-value guard: the zoom Slider re-asserts its bound value during
        // view updates; writing an equal value would still count as an
        // observable mutation and re-invalidate the view (see selectedSetupID).
        guard clamped != focalLength else { return }
        focalLength = clamped
        scheduleDebouncedFocalLengthRefresh()
    }

    /// Coalesces the `refresh()` calls a focal-length slider drag would
    /// otherwise fire on every tick into ONE, once the drag settles.
    ///
    /// A drag fires dozens of `setFocalLength` calls, and before this fix
    /// EVERY one called `refresh()` directly: a sky-context lookup, a
    /// measured-sky lookup, a weather resolve, and a detached full ranking
    /// compute over the whole catalog, immediately superseded by the very
    /// next tick, plus (on that compute's completion) four more recomputes
    /// -- filtered/skyPath/seasonWindow/rigCompare. Chained back-to-back
    /// across dozens of ticks, that kept `isComputing` (and the
    /// `ProgressView` `PlanningView` shows while it's true) continuously
    /// true for the whole drag, which is what made
    /// `testPlanningStaysResponsiveUnderRepeatedEntryAndSliderDrag` measure
    /// the app as never quiescing (XCUIElement.adjust's ~12.7s internal
    /// wait-for-idle cap, blown on nearly every tick) -- identically on
    /// released v4.0.2, so this was never a regression, just never fixed.
    /// It was also pure waste even ignoring the test: `productionCatalog()`
    /// and `selectedSetup`'s own memoized/no-op guards above only ever
    /// addressed the CHEAP half of each tick.
    ///
    /// `focalLength` itself is already updated by the time this is called
    /// (`setFocalLength` above writes it before calling this), so the mm
    /// label and `fieldOfView` stay live on every tick -- only the
    /// expensive, freely-supersedable ranking pipeline waits. Cancelling and
    /// replacing `pendingFocalLengthRefresh` on every call is the same
    /// "newest wins" shape `NightBriefingStore.scheduleAutosaveIfNeeded()`
    /// uses; `refresh()`'s own `recomputeGeneration` guard is a second,
    /// independent line of defense in case a debounced refresh and a
    /// discrete one (e.g. a setup change mid-drag) ever race.
    ///
    /// Only THIS call path debounces. `refresh()` itself, and every other
    /// caller of it (`setRootURL`, `setPlanningDate`, `selectedSetupID`'s
    /// setter, `handleDefaultsChange()`, `activate()`), stays immediate --
    /// none of those fire at slider-drag frequency, and `refresh()` cancels
    /// any still-pending focal-length debounce as soon as it runs, so a
    /// discrete trigger mid-drag doesn't leave a stale one to fire later.
    @discardableResult
    private func scheduleDebouncedFocalLengthRefresh() -> Task<Void, Never> {
        pendingFocalLengthRefresh?.cancel()
        let interval = focalLengthDebounceInterval
        let task = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self else { return }
            await self.refresh().value
        }
        pendingFocalLengthRefresh = task
        pendingRefresh = task
        return task
    }

    /// Recomputes `recommendations` off the main actor and publishes the
    /// result back once it lands, guarding against a stale (superseded)
    /// completion with `recomputeGeneration`. Called automatically whenever
    /// `selectedSetupID`, `focalLength`, `rootURL`, or a tracked
    /// `UserDefaults` preference changes; exposed publicly for callers that
    /// want to force an explicit recompute. Resolves tonight's site (via
    /// `skyContextProvider`) BEFORE building the `PlanningQuery` -- this is
    /// computed work, so like the pipeline itself it stays entirely inside
    /// this `Task`, never in `body`.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        // Any pending "waiting for the drag to settle" debounce is now moot
        // -- either this IS that debounce's own call (see
        // `scheduleDebouncedFocalLengthRefresh()`, harmless to cancel here),
        // or it's a discrete trigger firing mid-drag, in which case a stale
        // debounce running LATER would be wasted work at best and a
        // needless second `isComputing` flip at worst.
        pendingFocalLengthRefresh?.cancel()
        pendingFocalLengthRefresh = nil
        reloadSetupsIfNeeded()
        lastObservedReferenceHours = referenceHours
        lastObservedReferenceFocalRatio = referenceFocalRatio
        lastObservedReferenceSurfaceBrightness = referenceSurfaceBrightness
        recomputeGeneration += 1
        let generation = recomputeGeneration
        isComputing = true
        let setup = selectedSetup
        let focalLength = focalLength
        let referenceHours = lastObservedReferenceHours
        let referenceFocalRatio = lastObservedReferenceFocalRatio
        let referenceSurfaceBrightness = lastObservedReferenceSurfaceBrightness
        let rootURL = rootURL
        let resolveSkyContext = skyContextProvider
        let resolveWeather = weatherProvider
        let resolveMeasuredSky = measuredSkyProvider
        let compute = computeRecommendations
        let plannedDate = planningDate
        let targets = catalogProvider()
        let task = Task { [weak self] in
            let skyContext = try? await resolveSkyContext(rootURL)
            // W7-B item 1: resolved alongside the sky context -- both are
            // read-only lookups against the same open library, independent
            // of each other (same accepted duplication `resolveCloudState`
            // already has with `skyContextProvider` below).
            let measuredSky = try? await resolveMeasuredSky(rootURL)
            let query = PlanningQuery(
                setup: setup,
                focalLength: focalLength,
                targets: targets,
                referenceHours: referenceHours,
                referenceFocalRatio: referenceFocalRatio,
                referenceSurfaceBrightness: referenceSurfaceBrightness,
                site: skyContext?.site,
                // The night the user is planning for. `skyContext.date` is
                // only the fallback for a store that never had a date set
                // (tests injecting a fixed context); the picker owns this.
                date: plannedDate ?? skyContext?.date ?? Date(),
                measuredSky: measuredSky
            )
            // W4-2: fetched concurrently with the ranking compute, not after
            // it -- the cloud indicator is on the same "one recompute" cadence
            // as the table itself (same night/date, refetched on every
            // `refresh()`; `WeatherService`'s own 1-hour cache absorbs the
            // redundant calls a slider-driven `refresh()` burst would
            // otherwise cause).
            async let computedResult = Task.detached(priority: .userInitiated) {
                compute(query)
            }.value
            async let cloud = Self.resolveCloudState(weatherProvider: resolveWeather, rootURL: rootURL, date: query.date)
            let result = await computedResult
            let cloudState = await cloud
            guard let self, generation == self.recomputeGeneration else { return }
            self.recommendations = result
            self.skyAvailability = rootURL == nil ? .noLibrary : (skyContext == nil ? .noSite : .available)
            self.resolvedSite = skyContext?.site
            self.cloudState = cloudState
            self.isComputing = false
            self.recomputeFilteredRecommendations()
            // Tonight's site/date may have just changed (a new library, or a
            // different planned night) -- if a target is already selected,
            // its sky path must follow, the same way `recommendations` itself
            // just did.
            self.recomputeSkyPath()
            // The season window doesn't care which night is planned, only
            // which SITE resolved -- a library switch can change that, so
            // this must follow `resolvedSite` the same way `recomputeSkyPath`
            // does. `recomputeSeasonWindow` itself is cache-guarded, so a
            // planning-date-only change (same site) is a cheap no-op here.
            self.recomputeSeasonWindow()
            // A new setup, focal length, planned night, or library can all
            // change what there is to compare -- follows `resolvedSite`/
            // `planningDate` the same way `recomputeSkyPath` does.
            // `recomputeRigCompare` itself is a no-op unless
            // `compareSetupID` actually names a setup.
            self.recomputeRigCompare()
        }
        pendingRefresh = task
        return task
    }

    /// Sets the Planning table's selected target -- `nil` when the selection
    /// is cleared. Same-value guard as every other setter here: `Table`'s
    /// selection binding can re-assert the current value during its own
    /// update pass.
    public func selectTarget(_ target: CatalogTarget?) {
        guard target != selectedSkyPathTarget else { return }
        selectedSkyPathTarget = target
        recomputeSkyPath()
        recomputeSeasonWindow()
    }

    /// Recomputes `skyPath` off the main actor, guarded against a stale
    /// (superseded) completion by `skyPathGeneration` -- the same shape
    /// `refresh()` uses for `recommendations`. Called whenever the selected
    /// target changes, and again whenever `refresh()` itself lands (tonight's
    /// site/date may have moved under an already-selected target).
    @discardableResult
    private func recomputeSkyPath() -> Task<Void, Never> {
        skyPathGeneration += 1
        let generation = skyPathGeneration
        guard let target = selectedSkyPathTarget, let site = resolvedSite, let date = planningDate else {
            skyPath = nil
            isComputingSkyPath = false
            let task = Task {}
            pendingSkyPathRefresh = task
            return task
        }
        isComputingSkyPath = true
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                SkyPathQuery.samples(target: target, site: site, date: date)
            }.value
            guard let self, generation == self.skyPathGeneration else { return }
            self.skyPath = result
            self.isComputingSkyPath = false
        }
        pendingSkyPathRefresh = task
        return task
    }

    /// Recomputes `seasonWindow` off the main actor, guarded against a stale
    /// (superseded) completion by `seasonWindowGeneration` -- the exact same
    /// shape `recomputeSkyPath()` uses. Called whenever the selected target
    /// changes, and again whenever `refresh()` itself lands (the resolved
    /// site may have moved under an already-selected target). A cache hit
    /// resolves synchronously with no spinner at all -- re-selecting a target
    /// already evaluated this session (or returning to it after picking a
    /// different planning night) must never re-run the sweep.
    @discardableResult
    private func recomputeSeasonWindow() -> Task<Void, Never> {
        seasonWindowGeneration += 1
        let generation = seasonWindowGeneration
        guard let target = selectedSkyPathTarget, let site = resolvedSite else {
            seasonWindow = nil
            isComputingSeasonWindow = false
            let task = Task {}
            pendingSeasonWindowRefresh = task
            return task
        }
        let cacheKey = SeasonWindowCacheKey(designation: target.designation, site: site)
        if let cached = seasonWindowCache[cacheKey] {
            seasonWindow = cached
            isComputingSeasonWindow = false
            let task = Task {}
            pendingSeasonWindowRefresh = task
            return task
        }
        isComputingSeasonWindow = true
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                SeasonWindowQuery.evaluate(target: target, site: site)
            }.value
            guard let self, generation == self.seasonWindowGeneration else { return }
            if let result {
                self.seasonWindowCache[cacheKey] = result
            }
            self.seasonWindow = result
            self.isComputingSeasonWindow = false
        }
        pendingSeasonWindowRefresh = task
        return task
    }

    /// Recomputes `rigCompare` off the main actor, guarded against a stale
    /// (superseded) completion by `rigCompareGeneration` -- the same shape
    /// `recomputeSkyPath()`/`recomputeSeasonWindow()` use. Called both when
    /// the picked comparison setup itself changes (no need to re-resolve the
    /// site/weather/measured-sky pipeline just to change a display option --
    /// this reuses the already-resolved `resolvedSite`/`planningDate`) and
    /// again whenever `refresh()` itself lands (a new setup, focal length,
    /// planned night, or library can all change what there is to compare). A
    /// second `DiscoveryPlanner.discover` sweep over the whole catalog is
    /// real work -- gated behind `compareSetupID` being non-`nil` so an
    /// owner who never picks a comparison setup never pays for it.
    @discardableResult
    private func recomputeRigCompare() -> Task<Void, Never> {
        rigCompareGeneration += 1
        let generation = rigCompareGeneration
        guard let compareSetupID, let site = resolvedSite, let date = planningDate,
              compareSetup != nil
        else {
            rigCompare = nil
            isComputingRigCompare = false
            let task = Task {}
            pendingRigCompareRefresh = task
            return task
        }
        isComputingRigCompare = true
        let selectedSetupID = selectedSetupID
        let allSetups = setups
        let focalLength = focalLength
        let targets = catalogProvider()
        let compute = computeRigCompare
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                compute(selectedSetupID, compareSetupID, allSetups, focalLength, site, date, targets)
            }.value
            guard let self, generation == self.rigCompareGeneration else { return }
            self.rigCompare = result
            self.isComputingRigCompare = false
        }
        pendingRigCompareRefresh = task
        return task
    }

    /// The two raw pieces (the compared setup's name, its own framing
    /// verdict for the given target) `PlanningView` composes into one
    /// sentence for the sky-path footer under whichever row is selected --
    /// returning pieces rather than a finished sentence keeps this store's
    /// own `String(format:)`-free, matching `V2PolishSurfaceTests
    /// .noHandRolledFormatting`'s "use `Text`'s own interpolation, never a
    /// hand-rolled format string, anywhere under `Sources/AstroUI`" gate --
    /// `PlanningView` composes the actual `Text` via `Text`'s own nested-
    /// `Text` interpolation (`Text("With \(Text(verbatim: name)): \(Text
    /// (fit.displayLabel))")`), which resolves through the SAME `hu.lproj`
    /// without ever calling `String(format:)` in source. `nil` under the
    /// exact same conditions `rigCompare` itself is (nothing picked, <2
    /// setups, nothing resolved yet), or when this particular designation
    /// has no comparison row, or the compared setup's own fit is unknown (no
    /// size/FOV to judge).
    public func rigCompareSentenceComponents(for designation: String) -> (setupName: String, fit: PlanningFit)? {
        guard let compareSetup, let compare = rigCompare?[designation], let otherFit = compare.otherFit
        else { return nil }
        return (compareSetup.cameraName, otherFit)
    }

    /// Recomputes `filteredRecommendations` from the current
    /// `recommendations`/`searchText`/`usefulFramingOnly`/
    /// `showLowAltitudeTargets` -- called whenever any of those four
    /// actually changes, never on a mere property read. `TargetCatalog.search`
    /// (via the injected `catalogSearch`) only runs when `searchText` is
    /// non-empty, matching its prior behavior; the other two filters are a
    /// cheap array pass either way.
    private func recomputeFilteredRecommendations() {
        var rows = recommendations
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let matchingIDs = Set(catalogSearch(query, rows.map(\.target)).map(\.designation))
            rows = rows.filter { matchingIDs.contains($0.target.designation) }
        }
        if usefulFramingOnly {
            rows = rows.filter { $0.fit != .tooSmall && $0.fit != .mosaic }
        }
        if !showLowAltitudeTargets {
            rows = rows.filter { !$0.isLowAltitude }
        }
        // Sorting happens HERE, not in `PlanningView.body`: the table can hold
        // the whole catalog, and re-sorting it on every layout pass is exactly
        // the class of render-path work that froze this page five times.
        if !sortOrder.isEmpty {
            rows.sort(using: sortOrder)
        }
        filteredRecommendations = rows
    }

    /// Applies the column sort the user clicked in the table header. Same-value
    /// guarded like every other setter here.
    public func setSortOrder(_ newValue: [KeyPathComparator<PlanningRecommendation>]) {
        guard newValue != sortOrder else { return }
        sortOrder = newValue
        recomputeFilteredRecommendations()
    }

    private func adoptSelectedSetupDefaults() {
        focalLength = selectedSetup.defaultFocalLengthMM
    }

    /// Re-reads `setups` from `setupsProvider` at the top of every
    /// `refresh()` -- see `setups`'s own doc comment for why this, not a
    /// cross-scene signal from the Settings tab, is how an equipment-setup
    /// edit reaches an already-running `PlanningStore`. A `nil`/unchanged
    /// result is a no-op; a genuinely different list replaces `setups` and,
    /// if the current selection (or an active rig-compare pick) no longer
    /// resolves in it, falls back the same way `EquipmentSettingsView.save()`
    /// (V1's own imaging-setup editor) already does when the previously
    /// selected setup disappears: the config's own explicit default, or
    /// simply the first remaining setup.
    ///
    /// Writes `selectedSetupIDStorage`/`compareSetupIDStorage` directly
    /// (never through `selectedSetupID`/`compareSetupID`'s own setters) so
    /// correcting an invalidated selection here -- itself already running
    /// INSIDE `refresh()` -- can't recursively kick off a second, redundant
    /// `refresh()`/`recomputeRigCompare()` on top of the one already in
    /// flight; `adoptSelectedSetupDefaults()` is called directly instead for
    /// the same reason.
    private func reloadSetupsIfNeeded() {
        guard let updated = setupsProvider(rootURL), updated != setups else { return }
        setups = updated
        if !setups.contains(where: { $0.id == selectedSetupIDStorage }) {
            selectedSetupIDStorage = ImagingSetupProfile.defaultSetup(in: setups)?.id ?? setups[0].id
            adoptSelectedSetupDefaults()
        }
        if let compareID = compareSetupIDStorage, !setups.contains(where: { $0.id == compareID }) {
            compareSetupIDStorage = nil
        }
    }

    /// `UserDefaults.didChangeNotification` fires for ANY write to the
    /// suite, not just the three Planning-reference keys, so
    /// `handleDefaultsChange()` below compares the live values against
    /// `lastObservedReference*` before deciding whether an actual `refresh()`
    /// is warranted.
    private func observeDefaultsChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { [weak self] _ in
            // `queue: nil` delivers synchronously on the posting thread,
            // which -- both here and in production (`@AppStorage` writes
            // from `V2SettingsView`, itself `@MainActor`) -- is always the
            // main thread; `assumeIsolated` bridges that synchronous call
            // into `PlanningStore`'s main-actor isolation without an
            // `await` hop, so a `defaults.set(...)` call and this store's
            // reaction to it stay on the same run-loop turn (observable
            // and testable without a race).
            MainActor.assumeIsolated {
                self?.handleDefaultsChange()
            }
        }
    }

    private func handleDefaultsChange() {
        guard referenceHours != lastObservedReferenceHours
            || referenceFocalRatio != lastObservedReferenceFocalRatio
            || referenceSurfaceBrightness != lastObservedReferenceSurfaceBrightness
        else { return }
        refresh()
    }

    /// Resolves tonight's site the exact same way `HomeStore.productionNightContext`
    /// does -- `Planner.resolveSite` (explicit `AstroConfig.site`/`sites`,
    /// else the FITS-median fallback across the library's own scanned
    /// lights) -- so Planning's ranking never disagrees with the rest of the
    /// app about where "tonight" is being evaluated from. `nil` whenever no
    /// library is open (`rootURL == nil`) or no site resolves for the one
    /// that is (a fresh library with no site set and no FITS coordinates
    /// yet); `PlanningQuery.recommendations()` treats a `nil` site as "don't
    /// invent a ranking" rather than falling back to a framing-only one.
    public static func productionSkyContext(rootURL: URL?) async throws -> PlanningSkyContext? {
        guard let rootURL else { return nil }
        return try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            let site = try Planner.resolveSite(db: database, config: config)
            guard site.latitudeDeg != nil, site.longitudeDeg != nil else { return nil }
            return PlanningSkyContext(site: site, date: Date())
        }.value
    }

    /// W7-B item 1: `nil` whenever no library is open, or that library has
    /// fewer than `MeasuredSkyQuery.minimumSessionCount` measured sessions
    /// on record -- both mean `PlanningQuery.integrationEstimate` falls back
    /// to the honest μ=21 assumption instead.
    public static func productionMeasuredSky(rootURL: URL?) async throws -> MeasuredSkySurfaceBrightness? {
        guard let rootURL else { return nil }
        return try await Task.detached(priority: .utility) {
            try MeasuredSkyQuery.production(rootURL: rootURL)
        }.value
    }

    /// W4-2: turns a `WeatherProvider` result into the state `PlanningView`'s
    /// cloud indicator actually renders -- `nil` (disabled/no site) becomes
    /// `.hidden`, a thrown `WeatherError` becomes `.error`, and a fetched
    /// dictionary either has an entry for `date`'s night or doesn't (the
    /// latter meaning `date` falls beyond Open-Meteo's 7-day horizon).
    static func resolveCloudState(
        weatherProvider: WeatherProvider,
        rootURL: URL?,
        date: Date
    ) async -> PlanningCloudState {
        do {
            guard let summaries = try await weatherProvider(rootURL) else { return .hidden }
            guard let summary = summaries[Self.nightDateKey(for: date)] else { return .beyondHorizon }
            return .summary(summary)
        } catch let error as WeatherError {
            return .error(error)
        } catch {
            return .hidden
        }
    }

    /// `yyyy-MM-dd` local-day key matching `DailyCloudSummary.date`'s own
    /// "named by the night's start" convention -- deliberately its own
    /// formatter rather than a shared one (same accepted per-file
    /// duplication `Planner.swift`/`TrendQueries.swift`/`NewSessionView.swift`
    /// already have for this exact format string).
    private static func nightDateKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// W4-2: tonight's (or the planned night's) per-date cloud summaries,
    /// gated behind the exact same `config.weather.enabled` opt-in V1's
    /// `AppState.loadWeather` reads (the same `config.json`, so a toggle
    /// flipped from either V1's or V2's Settings takes effect here too).
    /// Resolves the site independently of `productionSkyContext` -- the same
    /// accepted duplication that method already has with
    /// `HomeStore.productionNightContext`.
    public static func productionWeather(rootURL: URL?) async throws -> [String: DailyCloudSummary]? {
        guard let rootURL else { return nil }
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

    /// Reads `<root>/.astro_tool/config.json`'s own `imagingSetups` --
    /// exactly the file `SiteSettingsStore.productionConfigLoader`/
    /// `SupportDiagnosticsWeatherState.weatherEnabled` already read for
    /// their own settings, so an edit made in the Equipment Settings tab is
    /// visible here with no second config-writing/-reading path. `nil` for
    /// no root or a config that fails to load (missing file, malformed
    /// JSON) -- `reloadSetupsIfNeeded()` treats that as "nothing new",
    /// leaving whatever `setups` already held. A config that DOES load with
    /// an empty `imagingSetups` (every saved setup deleted) falls back to
    /// `defaultSetups` here, the same bundled fallback a library that never
    /// had any configured setups already gets.
    public nonisolated static func productionSetupsProvider(rootURL: URL?) -> [ImagingSetupProfile]? {
        guard let rootURL else { return nil }
        let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
        guard let config = try? AstroConfig.load(from: configURL) else { return nil }
        return config.imagingSetups.isEmpty ? PlanningStore.defaultSetups : config.imagingSetups
    }

    public nonisolated static let defaultSetups: [ImagingSetupProfile] = [
        ImagingSetupProfile(
            id: "aps-c-astro-100-400", name: "APS-C astro · 100–400 mm", cameraName: "APS-C astro",
            cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.6,
            focalLengthMinMM: 100, focalLengthMaxMM: 400, defaultFocalLengthMM: 200,
            fNumber: 5, relativeEfficiency: 1, isDefault: true
        ),
        ImagingSetupProfile(
            id: "canon-r8-16", name: "Canon R8 · 16 mm", cameraName: "Canon EOS R8",
            cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
            focalLengthMinMM: 16, focalLengthMaxMM: 16, defaultFocalLengthMM: 16,
            fNumber: 2.8, relativeEfficiency: 1, isDefault: false
        ),
        ImagingSetupProfile(
            id: "canon-r8-28-70", name: "Canon R8 · 28–70 mm", cameraName: "Canon EOS R8",
            cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
            focalLengthMinMM: 28, focalLengthMaxMM: 70, defaultFocalLengthMM: 50,
            fNumber: 4, relativeEfficiency: 1, isDefault: false
        ),
    ]
}

/// `PlanningStore.seasonWindowCache`'s key -- a season is entirely determined
/// by which target and which site, never by the planned night, so this
/// deliberately carries neither `planningDate` nor anything else. `SiteRule`
/// itself isn't `Hashable` (only `Equatable`), so this pulls out just the two
/// `Double?`s that actually vary -- both `Optional<Double>` conform to
/// `Hashable` already, so the synthesized conformance below is exact, not an
/// approximation.
private struct SeasonWindowCacheKey: Hashable {
    let designation: String
    let latitudeDeg: Double?
    let longitudeDeg: Double?

    init(designation: String, site: SiteRule) {
        self.designation = designation
        self.latitudeDeg = site.latitudeDeg
        self.longitudeDeg = site.longitudeDeg
    }
}

/// V2 UI/UX audit (2026-08-16): `PlanningFit.label` is a plain `String`
/// computed in `AstroApplication` (`PlanningQuery.swift`) -- rendering it
/// directly (`Text(row.fit.label)`) routes through `Text`'s verbatim
/// `StringProtocol` overload, so it never localized. Per the localization
/// plan, the fix lives here at the view layer: map the engine's *case*
/// (never its rendered English sentence) to a `LocalizedStringKey`, so
/// `hu.lproj` can translate it like any other UI literal. The engine keeps
/// emitting English-only `label` for any other (non-UI) consumer.
extension PlanningFit {
    var displayLabel: LocalizedStringKey {
        switch self {
        case .mosaic: "Mosaic"
        case .tooSmall: "Too small"
        case .wide: "Wide composition"
        case .good: "Good framing"
        case .tight: "Tight framing"
        }
    }
}

/// W3-9: `SkyVerdictKind.english` (`AstroCore/Sky/NightSweep.swift`) is the
/// domain layer's English-only rendering, documented there as "today's only
/// renderer" for non-UI consumers -- `HomeView` (`Text(...verdict).english`)
/// and this file's own `PlanningRecommendationsTable`/`skyDetail` used to
/// render it directly, the exact "domain-layer strings displayed raw" leak
/// this task's own doc names ("good tonight" reaching a Hungarian screen
/// verbatim). Same fix as `PlanningFit`/`ProjectWorkflowPhase` above: map
/// the engine's *case* -- never its rendered English sentence -- to a
/// `LocalizedStringKey` here, at the view layer. `AstroCore` keeps emitting
/// English-only `.english` for whatever other consumer still wants it.
extension SkyVerdictKind {
    var displayLabel: LocalizedStringKey {
        switch self {
        case .noCoordinates: "no coordinates"
        case .notVisibleTonight: "not visible tonight"
        case .goodTonight: "good tonight"
        case .cometStaleCoordinate:
            "comet -- stored coordinate is from capture time, not valid for tonight"
        case let .lowAltitude(maxDeg):
            "low (max \(Int(maxDeg.rounded()))°)"
        case let .moonInterferes(separationDeg, illuminationPercent):
            // The `%` sign is baked into `percentText` (a plain `String`,
            // interpolated here as a single `%@` argument) rather than
            // written as a literal `%` inside this `LocalizedStringKey`
            // template -- a bare `%` in a format-string TEMPLATE needs `%%`
            // escaping (see `SkyVerdict.moonInterferes`'s own `String(format:)`
            // call in `AstroCore`), which this sidesteps entirely: the
            // substituted VALUE of a `%@` argument is never re-parsed for
            // `%` signs of its own.
            "Moon interferes (\(Int(separationDeg.rounded()))°, \(Self.percentText(illuminationPercent)))"
        case let .unrecognized(raw):
            // No closed case to translate -- `LocalizedStringKey(raw)`
            // behaves exactly like `.english`'s own fallback (return the
            // original text unchanged) when `raw` has no `hu.lproj` entry,
            // which it never will since this is meant to be unreachable
            // (see `SkyVerdict.parse`'s own doc comment).
            LocalizedStringKey(raw)
        }
    }

    private static func percentText(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}

/// `CatalogTargetKind.rawValue` (`AstroCore/Sky/TargetCatalog.swift`) is a
/// camelCase Swift identifier ("emissionNebula"), never meant for display --
/// `PlanningView`'s target-kind caption used to render it directly
/// (`Text(row.target.kind.rawValue)`), which was broken even before
/// considering localization. Mapped to a `LocalizedStringKey` here, same
/// pattern as every other engine-enum-to-display-label fix in this file.
extension CatalogTargetKind {
    var displayLabel: LocalizedStringKey {
        switch self {
        case .galaxy: "Galaxy"
        case .emissionNebula: "Emission nebula"
        case .planetaryNebula: "Planetary nebula"
        case .supernovaRemnant: "Supernova remnant"
        case .openCluster: "Open cluster"
        case .globularCluster: "Globular cluster"
        case .reflectionNebula: "Reflection nebula"
        case .darkNebula: "Dark nebula"
        case .other: "Other"
        }
    }
}

/// `PlanningEstimateConfidence.rawValue.capitalized`
/// (`AstroApplication/Features/Planning/PlanningQuery.swift`) rendered its
/// raw Swift case name ("Curated"/"Estimated"/"Fallback"/"Unknown") directly
/// -- same leak class as `CatalogTargetKind` above.
extension PlanningEstimateConfidence {
    var displayLabel: LocalizedStringKey {
        switch self {
        case .curated: "Curated"
        case .estimated: "Estimated"
        case .fallback: "Fallback"
        case .unknown: "Unknown"
        }
    }
}
