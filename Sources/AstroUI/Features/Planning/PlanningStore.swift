import AstroApplication
import AstroCore
import Foundation
import Observation

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

    public let setups: [ImagingSetupProfile]
    /// AppKit's Picker re-asserts the bound selection during its own update
    /// pass, and `didSet` fires on every assignment -- equal values included.
    /// `@Observable` reports a mutation regardless of equality, so an
    /// unguarded didSet here closes an infinite view-invalidation loop
    /// (the build 20016 Planning freeze). Same-value writes must be no-ops.
    public var selectedSetupID: String {
        didSet {
            guard oldValue != selectedSetupID else { return }
            adoptSelectedSetupDefaults()
            refresh()
        }
    }
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
    private let defaults: UserDefaults
    private let computeRecommendations: RecommendationsComputer
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
    /// `isComputing`. Never read by production code.
    private(set) var pendingRefresh: Task<Void, Never>?
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
    private let skyContextProvider: SkyContextProvider
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

    /// Reads the cache only when the user opted in. A missing, corrupt or
    /// version-mismatched cache falls back to the built-in catalog rather
    /// than failing (`CatalogCache.load()` returns `nil` for all three).
    /// `nonisolated` and parameterless so the default search closure — which
    /// must be `@Sendable` — can call it without capturing anything.
    nonisolated public static func productionCatalog() -> [CatalogTarget] {
        // Absent key means "never touched the toggle", and the toggle now
        // defaults to on -- `bool(forKey:)` alone would read that as off.
        let enabled = UserDefaults.standard.object(forKey: extendedCatalogEnabledKey) as? Bool ?? true
        guard enabled,
              let fileURL = try? CatalogCache.productionFileURL(),
              let payload = CatalogCache(fileURL: fileURL).load()
        else { return TargetCatalog.all }
        return TargetCatalog.merged(cached: payload.targets)
    }

    /// Mirrors `V2SettingsView`'s `@AppStorage` key for the opt-in toggle.
    nonisolated public static let extendedCatalogEnabledKey = "v2.settings.extended-catalog"

    public init(
        setups: [ImagingSetupProfile] = PlanningStore.defaultSetups,
        defaults: UserDefaults = .standard,
        computeRecommendations: @escaping RecommendationsComputer = { $0.recommendations() },
        catalogSearch: CatalogSearch? = nil,
        catalogProvider: CatalogProvider? = nil,
        skyContextProvider: @escaping SkyContextProvider = PlanningStore.productionSkyContext
    ) {
        let safeSetups = setups.isEmpty ? PlanningStore.defaultSetups : setups
        self.setups = safeSetups
        self.defaults = defaults
        self.computeRecommendations = computeRecommendations
        self.catalogProvider = catalogProvider ?? { PlanningStore.productionCatalog() }
        // Search the SAME catalog the ranking uses, so a target that appears
        // in the table can always be found by name and vice versa.
        // Searches whatever catalog the ranking actually used (passed in by
        // `recomputeFilteredRecommendations`), so extended-catalog targets
        // stay findable and search can never offer a target the table lacks.
        self.catalogSearch = catalogSearch ?? { query, source in
            TargetCatalog.search(query, limit: source.count, in: source)
        }
        self.skyContextProvider = skyContextProvider
        let initial = safeSetups.first(where: \.isDefault) ?? safeSetups[0]
        selectedSetupID = initial.id
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
        refresh()
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
        let compute = computeRecommendations
        let plannedDate = planningDate
        let targets = catalogProvider()
        let task = Task { [weak self] in
            let skyContext = try? await resolveSkyContext(rootURL)
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
                date: plannedDate ?? skyContext?.date ?? Date()
            )
            let result = await Task.detached(priority: .userInitiated) {
                compute(query)
            }.value
            guard let self, generation == self.recomputeGeneration else { return }
            self.recommendations = result
            self.skyAvailability = rootURL == nil ? .noLibrary : (skyContext == nil ? .noSite : .available)
            self.resolvedSite = skyContext?.site
            self.isComputing = false
            self.recomputeFilteredRecommendations()
            // Tonight's site/date may have just changed (a new library, or a
            // different planned night) -- if a target is already selected,
            // its sky path must follow, the same way `recommendations` itself
            // just did.
            self.recomputeSkyPath()
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

    public static let defaultSetups: [ImagingSetupProfile] = [
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
