import AstroApplication
import AstroCore
import Foundation
import Observation

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
    public typealias CatalogSearch = @Sendable (String) -> [CatalogTarget]

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
    /// `nonisolated(unsafe)`: only ever mutated on the main actor (`init`),
    /// but `deinit` is always `nonisolated` (it may run on any thread), so
    /// it needs to read this without a MainActor-isolation check. Safe --
    /// by the time `deinit` runs, no other code holds a reference through
    /// which this could race.
    private nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?

    public init(
        setups: [ImagingSetupProfile] = PlanningStore.defaultSetups,
        defaults: UserDefaults = .standard,
        computeRecommendations: @escaping RecommendationsComputer = { $0.recommendations() },
        catalogSearch: @escaping CatalogSearch = { TargetCatalog.search($0, limit: TargetCatalog.all.count) }
    ) {
        let safeSetups = setups.isEmpty ? PlanningStore.defaultSetups : setups
        self.setups = safeSetups
        self.defaults = defaults
        self.computeRecommendations = computeRecommendations
        self.catalogSearch = catalogSearch
        let initial = safeSetups.first(where: \.isDefault) ?? safeSetups[0]
        selectedSetupID = initial.id
        focalLength = initial.defaultFocalLengthMM
        lastObservedReferenceHours = defaults.double(forKey: Self.referenceHoursKey)
        lastObservedReferenceFocalRatio = defaults.double(forKey: Self.referenceFocalRatioKey)
        lastObservedReferenceSurfaceBrightness = defaults.double(forKey: Self.referenceSurfaceBrightnessKey)
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

    public func activate() {
        guard !isActivated else { return }
        isActivated = true
        registerReferenceDefaults()
        observeDefaultsChanges()
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
    /// `selectedSetupID`, `focalLength`, or a tracked `UserDefaults`
    /// preference changes; exposed publicly for callers that want to force
    /// an explicit recompute.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        lastObservedReferenceHours = referenceHours
        lastObservedReferenceFocalRatio = referenceFocalRatio
        lastObservedReferenceSurfaceBrightness = referenceSurfaceBrightness
        recomputeGeneration += 1
        let generation = recomputeGeneration
        isComputing = true
        let query = PlanningQuery(
            setup: selectedSetup,
            focalLength: focalLength,
            referenceHours: lastObservedReferenceHours,
            referenceFocalRatio: lastObservedReferenceFocalRatio,
            referenceSurfaceBrightness: lastObservedReferenceSurfaceBrightness
        )
        let compute = computeRecommendations
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                compute(query)
            }.value
            guard let self, generation == self.recomputeGeneration else { return }
            self.recommendations = result
            self.isComputing = false
            self.recomputeFilteredRecommendations()
        }
        pendingRefresh = task
        return task
    }

    /// Recomputes `filteredRecommendations` from the current
    /// `recommendations`/`searchText`/`usefulFramingOnly` -- called whenever
    /// any of those three actually changes, never on a mere property read.
    /// `TargetCatalog.search` (via the injected `catalogSearch`) only runs
    /// when `searchText` is non-empty, matching its prior behavior; the
    /// `usefulFramingOnly` filter is a cheap array pass either way.
    private func recomputeFilteredRecommendations() {
        var rows = recommendations
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let matchingIDs = Set(catalogSearch(query).map(\.designation))
            rows = rows.filter { matchingIDs.contains($0.target.designation) }
        }
        if usefulFramingOnly {
            rows = rows.filter { $0.fit != .tooSmall && $0.fit != .mosaic }
        }
        filteredRecommendations = rows
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
