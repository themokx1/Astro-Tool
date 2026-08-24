@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

/// A fixed Budapest site/date, matching `Tests/AstroCoreTests/DiscoveryPlannerTests.swift`'s
/// own fixture -- most of this file's tests exercise infrastructure
/// (recompute counts, same-value guards, generation racing) that doesn't
/// care WHAT tonight's ranking is, only that a resolvable one exists so
/// `PlanningQuery.recommendations()` doesn't short-circuit to `[]` (see that
/// type's own doc: no site means no invented ranking).
private let planningTestSite = SiteRule(latitudeDeg: 47.5, longitudeDeg: 19.0)
private let planningTestDate: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: 12))!
}()
private func fixedSkyContext(_: URL?) async throws -> PlanningSkyContext? {
    PlanningSkyContext(site: planningTestSite, date: planningTestDate)
}

/// Matches `PlanningStore`'s own private `nightDateKey(for:)` formatter
/// exactly (`yyyy-MM-dd`, `en_US_POSIX`, `TimeZone.current`) -- both use
/// `TimeZone.current`, so this test's expectations stay correct regardless
/// of the machine's own time zone.
private func nightKey(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

/// Thread-safe call counter for injected `PlanningStore.RecommendationsComputer`
/// closures -- `@Sendable` closures can't capture a plain `var`, and the
/// closure body itself is synchronous (it runs inside `Task.detached`, off
/// the main actor), so an `actor`-based counter (which would need `await`)
/// doesn't fit either.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Thread-safe mutable holder for a `PlanningStore.SetupsProvider`'s
/// result -- `@Sendable` closures can't capture a plain `var` (same
/// restriction `CallCounter` above exists to work around), and these tests
/// need to change what "config on disk" reports MID-TEST to simulate a
/// Settings-tab edit landing between two `refresh()` calls.
private final class SetupsProviderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [ImagingSetupProfile]

    init(_ value: [ImagingSetupProfile]) { self.value = value }

    var current: [ImagingSetupProfile] {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

@MainActor
struct PlanningStoreTests {
    // Build 20015 shipped a Planning freeze caused by a side-effectful
    // `init`: `PlanningView`'s `@State private var store = PlanningStore()`
    // default value is re-evaluated on every view construction (every
    // enclosing render pass), so an `init` that kicked off a full
    // recommendation compute launched one discarded background pipeline run
    // per render. Construction must therefore be free of side effects;
    // activation is explicit and idempotent.
    // Build 20017 STILL froze on Planning, and only on Planning (measured:
    // Home 0% CPU, Projects 0% CPU, Planning 99%). `PlanningStore.init` called
    // `UserDefaults.register(defaults:)`, and SwiftUI re-evaluates
    // `PlanningView`'s `@State private var store = PlanningStore()` default
    // expression on every view construction. Each discarded construction
    // therefore posted `UserDefaults.didChangeNotification`, which invalidates
    // every `@AppStorage` property in the mounted tree (V2RootView, HomeView,
    // V2SettingsView) -- so the shell re-rendered, which re-rendered Planning,
    // which constructed another store, which posted again: an endless loop.
    // Construction must be silent; registration happens once, in `activate()`.
    @Test("Constructing a store posts no UserDefaults change notification")
    func constructionDoesNotPostDefaultsNotification() async throws {
        let suite = "AstroTool-PlanningStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let posts = CallCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { _ in posts.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Stand in for SwiftUI re-evaluating the @State default expression.
        for _ in 0..<5 {
            _ = PlanningStore(setups: [.apsCReference], defaults: defaults)
        }

        #expect(posts.current == 0)
    }

    @Test("Constructing a store computes nothing until activate() is called")
    func constructionHasNoSideEffects() async {
        let counter = CallCounter()
        let store = PlanningStore(setups: [.apsCReference]) { query in
            counter.increment()
            return query.recommendations()
        }
        #expect(store.pendingRefresh == nil)
        #expect(counter.current == 0)

        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        // Idempotent: a second activate (e.g. `.task` re-running after an
        // `.id(route)` identity reset recreated the store anyway) is a no-op.
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)
    }

    // Build 20016 still froze on Planning: AppKit's Picker re-asserts the
    // bound selection during its own update pass, and a Swift `didSet` fires
    // on EVERY assignment -- equal values included. `@Observable` then
    // reports a mutation regardless of equality, which invalidates the view,
    // which re-runs the Picker update, which writes again: an infinite
    // SwiftUI transaction loop (`GraphHost.flushTransactions` at 99% CPU,
    // confirmed by sampling the live frozen process). Same-value writes must
    // therefore be observable no-ops.
    @Test("Same-value writes to setup, focal length and refresh inputs do not mutate or recompute")
    func sameValueWritesAreObservableNoOps() async {
        let counter = CallCounter()
        let store = PlanningStore(setups: [.apsCReference, .canonR8Zoom]) { query in
            counter.increment()
            return query.recommendations()
        }
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        let mutations = CallCounter()
        withObservationTracking {
            _ = store.selectedSetupID
            _ = store.focalLength
            _ = store.isComputing
        } onChange: {
            mutations.increment()
        }

        // Simulate the Picker/Slider re-asserting the current values.
        store.selectedSetupID = store.selectedSetupID
        store.setFocalLength(store.focalLength)
        await store.pendingRefresh?.value

        #expect(mutations.current == 0)
        #expect(counter.current == 1)

        // A genuine change must still recompute.
        store.selectedSetupID = ImagingSetupProfile.canonR8Zoom.id
        await store.pendingRefresh?.value
        #expect(mutations.current > 0)
        #expect(counter.current == 2)
    }

    @Test("Changing focal length recalculates framing and preserves useful-first ordering")
    func focalLengthRecalculatesRecommendations() async {
        // Zero debounce: this test is about the recompute's OUTCOME, not the
        // debounce timing itself, so there is no reason to pay a real
        // ~200ms sleep per run.
        let store = PlanningStore(
            setups: [.apsCReference],
            catalogProvider: { TargetCatalog.all },
            skyContextProvider: fixedSkyContext,
            focalLengthDebounceInterval: .zero
        )
        store.activate()
        await store.pendingRefresh?.value
        let initial = store.recommendations

        store.setFocalLength(400)
        await store.pendingRefresh?.value

        #expect(store.focalLength == 400)
        #expect(store.recommendations != initial)
        #expect(store.recommendations.first?.fit != .tooSmall)
    }

    // The opt-in SIMBAD/VizieR fetch is only worth anything if the targets it
    // caches actually reach the planner. Without this wiring the download
    // succeeds, Settings reports a cache, and Planning still shows the
    // built-in 217 — a silently useless feature.
    @Test("Targets from the extended catalog are ranked and searchable in Planning")
    func extendedCatalogTargetsReachThePlanner() async {
        let extra = CatalogTarget(
            designation: "LBN 437", commonNameHU: nil, raDeg: 338.051, decDeg: 40.591,
            kind: .emissionNebula, sizeArcmin: 20, magnitude: nil
        )
        let store = PlanningStore(
            setups: [.apsCReference],
            catalogProvider: { TargetCatalog.merged(cached: [extra]) },
            skyContextProvider: fixedSkyContext
        )
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.recommendations.contains { $0.target.designation == "LBN 437" })

        // ...and findable by name, from the same source the ranking used.
        // The framing filter is off here on purpose: this asserts the catalog
        // reaches the planner, not that a 20-arcmin nebula frames well at
        // 200 mm (it doesn't, and `usefulFramingOnly` would hide it).
        store.usefulFramingOnly = false
        store.searchText = "LBN 437"
        #expect(store.filteredRecommendations.contains { $0.target.designation == "LBN 437" })
    }

    @Test("Search accepts catalog and Hungarian target names")
    func targetSearchIsLocalized() async {
        let store = PlanningStore(setups: [.apsCReference], catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext)
        store.activate()
        await store.pendingRefresh?.value

        store.searchText = "elefántormány"

        #expect(store.filteredRecommendations.map(\.target.designation) == ["IC 1396"])
    }

    @Test("Changing the Planning settings baseline changes the computed integration hours")
    func referencePreferencesChangeComputedIntegrationHours() async throws {
        let suite = "AstroTool-PlanningStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let baseline = PlanningStore(setups: [.apsCReference], defaults: defaults, skyContextProvider: fixedSkyContext)
        baseline.activate()
        await baseline.pendingRefresh?.value
        // Pick a target whose estimate stays within
        // `IntegrationTimeModel.maxPlausibleHours` at the baseline reference
        // (so `integrationHours` is non-nil) rather than trusting `.first`,
        // whose sky-driven ranking is now independent of the reference
        // hours being tested here.
        // ...and one whose DOUBLED estimate also stays inside that cap,
        // otherwise the doubled store reports `nil` ("beyond model range")
        // and there is no second figure to compare against.
        let baselineRow = try #require(baseline.recommendations.first {
            guard let hours = $0.integrationHours else { return false }
            return hours * 2 < IntegrationTimeModel.maxPlausibleHours
        })
        let baselineHours = try #require(baselineRow.integrationHours)
        // `PlanningStore` reads `UserDefaults` live rather than caching, so
        // this initial value is captured before the mutation below -- both
        // stores otherwise share the same `defaults` instance.
        let initialReferenceHours = baseline.referenceHours

        defaults.set(initialReferenceHours * 2, forKey: PlanningStore.referenceHoursKey)
        let doubled = PlanningStore(setups: [.apsCReference], defaults: defaults, skyContextProvider: fixedSkyContext)
        doubled.activate()
        await doubled.pendingRefresh?.value

        #expect(doubled.referenceHours == initialReferenceHours * 2)
        let doubledRow = try #require(doubled.recommendations.first { $0.target.designation == baselineRow.target.designation })
        let doubledHours = try #require(doubledRow.integrationHours)
        #expect(abs(doubledHours / baselineHours - 2) < 0.001)
    }

    @Test("PlanningStore's reference defaults match IntegrationTimeModel's own baseline")
    func referenceDefaultsMatchIntegrationTimeModel() throws {
        let suite = "AstroTool-PlanningStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlanningStore(setups: [.apsCReference], defaults: defaults)
        store.activate()

        #expect(store.referenceHours == IntegrationTimeModel.referenceHours)
        #expect(store.referenceFocalRatio == 5)
        #expect(store.referenceSurfaceBrightness == IntegrationTimeModel.referenceSurfaceBrightness)
    }

    // MARK: - Crash-fix regression coverage (build 20013)
    //
    // `PlanningView.body` reads `store.filteredRecommendations` at least 3x
    // per layout pass. When `recommendations` was a COMPUTED property that
    // built a fresh `PlanningQuery` and ran the full 217-target pipeline on
    // every access, that meant the full pipeline ran 3x+ per pass,
    // synchronously on the main actor -- seconds-long stalls that (with a
    // state mutation landing mid-layout) crashed AppKit with a reentrant
    // constraints exception. These tests pin the fix: `recommendations` is a
    // STORED property, recomputed only on explicit input changes, off the
    // main actor.

    @Test("Repeated reads of recommendations/filteredRecommendations do not re-run the pipeline")
    func recommendationsAreNotRecomputedOnRepeatedPropertyAccess() async {
        let counter = CallCounter()
        let store = PlanningStore(setups: [.apsCReference]) { query in
            counter.increment()
            return query.recommendations()
        }
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        // Simulate `PlanningView.body`'s 3+ reads per layout pass.
        _ = store.recommendations
        _ = store.filteredRecommendations.count
        _ = store.filteredRecommendations.isEmpty
        _ = store.filteredRecommendations
        _ = store.recommendations
        _ = store.filteredRecommendations

        #expect(counter.current == 1)
    }

    @Test("Changing focalLength triggers exactly one recompute")
    func focalLengthChangeTriggersExactlyOneRecompute() async {
        let counter = CallCounter()
        // Zero debounce: a single tick recomputing exactly once holds
        // regardless of the debounce window's length -- the multi-tick
        // coalescing story itself is `debouncesABurstOfFocalLengthTicksIntoOneRecompute`
        // below, which needs a real (if tiny) window to prove the burst
        // lands as ONE recompute rather than one per tick.
        let store = PlanningStore(
            setups: [.apsCReference],
            computeRecommendations: { query in
                counter.increment()
                return query.recommendations()
            },
            focalLengthDebounceInterval: .zero
        )
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        store.setFocalLength(350)
        await store.pendingRefresh?.value

        #expect(counter.current == 2)
    }

    // MARK: - Focal-length slider debounce (macOS UI gate: quiescence)
    //
    // `testPlanningStaysResponsiveUnderRepeatedEntryAndSliderDrag` measured
    // the Planning page as never quiescing during a focal-length slider
    // drag: `setFocalLength` fired the WHOLE heavy pipeline (sky-context
    // lookup, measured-sky lookup, weather resolve, a detached full ranking
    // compute over the catalog, then four more recomputes on completion) on
    // every one of the dozens of ticks a drag produces, each one
    // immediately superseded by the next. `scheduleDebouncedFocalLengthRefresh()`
    // now coalesces a burst of ticks into exactly one recompute, once the
    // drag settles -- these tests pin that contract directly, the same way
    // `focalLengthChangeTriggersExactlyOneRecompute` above already pins the
    // single-tick case.

    @Test("A burst of focal-length ticks (a slider drag) triggers exactly one recompute, after the debounce window, at the final value")
    func debouncesABurstOfFocalLengthTicksIntoOneRecompute() async {
        let counter = CallCounter()
        let store = PlanningStore(
            setups: [.apsCReference],
            computeRecommendations: { query in
                counter.increment()
                return query.recommendations()
            },
            focalLengthDebounceInterval: .milliseconds(20)
        )
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        // Simulate a drag: dozens of ticks fired back to back, with no
        // suspension point between them -- exactly how `PlanningView`'s
        // `Slider` drives `setFocalLength` today.
        for tick in 1...30 {
            store.setFocalLength(100 + Double(tick))
        }

        // `focalLength` itself is never debounced -- the mm label and
        // `fieldOfView` must already show the drag's LAST value, even
        // though the heavy recompute for it hasn't run yet.
        #expect(store.focalLength == 130)
        #expect(counter.current == 1)

        await store.pendingRefresh?.value

        #expect(counter.current == 2)
        #expect(store.focalLength == 130)
        #expect(!store.isComputing)
    }

    @Test("isComputing does not flicker on during the focal-length debounce window, only once the real recompute starts")
    func isComputingStaysFalseDuringFocalLengthDebounceWindow() async {
        let store = PlanningStore(
            setups: [.apsCReference],
            focalLengthDebounceInterval: .milliseconds(50)
        )
        store.activate()
        await store.pendingRefresh?.value
        #expect(!store.isComputing)

        store.setFocalLength(250)

        // Still inside the debounce window -- no recompute has started, so
        // the "Finding matches…" spinner `PlanningView` shows while
        // `isComputing` is true must NOT be flickering on yet. A brief
        // real sleep, well under the 50ms window above, stands in for
        // however long it takes the drag's LAST tick to be followed by
        // this assertion.
        try? await Task.sleep(for: .milliseconds(10))
        #expect(!store.isComputing)

        await store.pendingRefresh?.value
        #expect(!store.isComputing)
        #expect(store.focalLength == 250)
    }

    @Test("A discrete refresh trigger during a pending focal-length debounce still recomputes immediately, and drops the stale debounce")
    func discreteRefreshDuringPendingDebounceStaysImmediate() async {
        let counter = CallCounter()
        let setups: [ImagingSetupProfile] = [.apsCReference, .canonR8Zoom]
        let store = PlanningStore(
            setups: setups,
            computeRecommendations: { query in
                counter.increment()
                return query.recommendations()
            },
            focalLengthDebounceInterval: .milliseconds(200)
        )
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        // Start a slider drag (schedules a debounce, does not recompute yet)...
        store.setFocalLength(300)
        #expect(counter.current == 1)

        // ...then a DISCRETE trigger fires mid-drag (e.g. the setup picker),
        // which must recompute immediately -- `isComputing` flips true
        // synchronously, with no debounce wait, exactly like every other
        // discrete trigger in this file (`selectedSetupChangeTriggersExactlyOneRecompute`
        // above never waited on a timer either).
        store.selectedSetupID = ImagingSetupProfile.canonR8Zoom.id
        #expect(store.isComputing)
        await store.pendingRefresh?.value

        #expect(counter.current == 2)

        // The debounce that was pending when the discrete trigger fired
        // must have been dropped -- letting it fire later would silently
        // re-run the pipeline for a focal length the user already moved
        // away from, and flip `isComputing` a third time for nothing.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(counter.current == 2)
    }

    @Test("Changing the selected setup triggers exactly one recompute")
    func selectedSetupChangeTriggersExactlyOneRecompute() async {
        let counter = CallCounter()
        let setups: [ImagingSetupProfile] = [.apsCReference, .canonR8Zoom]
        let store = PlanningStore(setups: setups) { query in
            counter.increment()
            return query.recommendations()
        }
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        store.selectedSetupID = ImagingSetupProfile.canonR8Zoom.id
        await store.pendingRefresh?.value

        #expect(counter.current == 2)
        #expect(store.focalLength == ImagingSetupProfile.canonR8Zoom.defaultFocalLengthMM)
    }

    @Test("Changing a Planning reference preference triggers exactly one recompute")
    func referencePreferenceChangeTriggersExactlyOneRecompute() async throws {
        let suite = "AstroTool-PlanningStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let counter = CallCounter()
        let store = PlanningStore(setups: [.apsCReference], defaults: defaults) { query in
            counter.increment()
            return query.recommendations()
        }
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        defaults.set(store.referenceHours * 2, forKey: PlanningStore.referenceHoursKey)
        await store.pendingRefresh?.value

        #expect(counter.current == 2)

        // A defaults notification carrying no actual change to the three
        // tracked keys must NOT trigger a spurious recompute.
        defaults.set("unrelated", forKey: "some.other.v2.key")
        // Give a same-thread synchronous observer nothing to await on; the
        // call count must still read 2 immediately.
        #expect(counter.current == 2)
    }

    @Test("A stale completed recompute does not overwrite a newer one's result")
    func staleCompletionDoesNotOverwriteNewer() async {
        let counter = CallCounter()
        // Zero debounce: this test is about `recomputeGeneration`'s own
        // staleness guard, not about the focal-length debounce window --
        // with the production ~200ms default, the `setFocalLength`-triggered
        // compute below wouldn't even START until well after this comment's
        // "faster" premise needs it to have FINISHED, turning a deterministic
        // ordering into a coin flip against the slow first compute's own
        // 0.2s sleep.
        let store = PlanningStore(
            setups: [.apsCReference],
            computeRecommendations: { query in
                let call = counter.increment()
                if call == 1 {
                    // The FIRST (init-triggered) compute is the slow one, so
                    // it completes AFTER the second, faster,
                    // `setFocalLength`-triggered compute below.
                    Thread.sleep(forTimeInterval: 0.2)
                }
                return query.recommendations()
            },
            focalLengthDebounceInterval: .zero
        )
        store.activate()

        store.setFocalLength(300)
        await store.pendingRefresh?.value
        #expect(store.focalLength == 300)
        let afterSecond = store.recommendations

        // Let the slow, now-stale first compute finish; its generation is
        // behind, so it must not clobber `recommendations`.
        try? await Task.sleep(nanoseconds: 350_000_000)

        #expect(store.recommendations == afterSecond)
        #expect(store.focalLength == 300)
    }

    @Test("isComputing is true while a recompute is in flight and false once it lands")
    func isComputingTransitions() async {
        let store = PlanningStore(
            setups: [.apsCReference],
            computeRecommendations: { query in
                Thread.sleep(forTimeInterval: 0.05)
                return query.recommendations()
            },
            skyContextProvider: fixedSkyContext
        )
        store.activate()

        // No suspension point has occurred yet, so the detached compute
        // Task kicked off by `init` cannot have run at all -- this read is
        // deterministic, not a race.
        #expect(store.isComputing == true)
        #expect(store.recommendations.isEmpty)

        await store.pendingRefresh?.value

        #expect(store.isComputing == false)
        #expect(!store.recommendations.isEmpty)
    }

    @Test("recommendations is a stored property, not a computed one that rebuilds a PlanningQuery per access")
    func recommendationsIsStoredNotComputed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Planning/PlanningStore.swift"),
            encoding: .utf8
        )
        #expect(source.contains("public private(set) var recommendations: [PlanningRecommendation] = []"))
        #expect(!source.contains("public var recommendations: [PlanningRecommendation] {"))
    }

    // MARK: - Finding 3.2: filteredRecommendations caching
    //
    // `filteredRecommendations` ran a full 217-target `TargetCatalog.search`
    // as a COMPUTED property, and `PlanningView.body` reads it 3+ times per
    // layout pass -- the identical defect class as `recommendations` above,
    // one property lower in the same pipeline. These tests pin the fix:
    // `filteredRecommendations` is a STORED property, recomputed only on an
    // actual input change (`recommendations`, `searchText`,
    // `usefulFramingOnly`), with same-value writes to the latter two as
    // observable no-ops.

    @Test("Repeated reads of filteredRecommendations do not re-run the catalog search")
    func filteredRecommendationsAreNotRecomputedOnRepeatedPropertyAccess() async {
        let searchCounter = CallCounter()
        let store = PlanningStore(setups: [.apsCReference]) { query in
            query.recommendations()
        } catalogSearch: { query, _ in
            searchCounter.increment()
            return TargetCatalog.search(query, limit: TargetCatalog.all.count)
        }
        store.activate()
        await store.pendingRefresh?.value
        #expect(searchCounter.current == 0) // empty searchText never searches the catalog

        store.searchText = "andromeda"
        #expect(searchCounter.current == 1)

        // Simulate `PlanningView.body`'s 3+ reads per layout pass.
        _ = store.filteredRecommendations
        _ = store.filteredRecommendations.count
        _ = store.filteredRecommendations.isEmpty
        _ = store.filteredRecommendations
        _ = store.filteredRecommendations

        #expect(searchCounter.current == 1)
    }

    @Test("Changing searchText triggers exactly one catalog search")
    func searchTextChangeTriggersExactlyOneCatalogSearch() async {
        let searchCounter = CallCounter()
        let store = PlanningStore(setups: [.apsCReference]) { query in
            query.recommendations()
        } catalogSearch: { query, _ in
            searchCounter.increment()
            return TargetCatalog.search(query, limit: TargetCatalog.all.count)
        }
        store.activate()
        await store.pendingRefresh?.value

        store.searchText = "andromeda"
        #expect(searchCounter.current == 1)

        store.searchText = "andromeda galaxy"
        #expect(searchCounter.current == 2)
    }

    @Test("Same-value writes to searchText/usefulFramingOnly do not recompute or mutate filteredRecommendations")
    func sameValueWritesToFilterInputsAreObservableNoOps() async {
        let searchCounter = CallCounter()
        let store = PlanningStore(setups: [.apsCReference]) { query in
            query.recommendations()
        } catalogSearch: { query, _ in
            searchCounter.increment()
            return TargetCatalog.search(query, limit: TargetCatalog.all.count)
        }
        store.activate()
        await store.pendingRefresh?.value
        store.searchText = "andromeda"
        #expect(searchCounter.current == 1)
        let beforeReassertion = store.filteredRecommendations

        let mutations = CallCounter()
        withObservationTracking {
            _ = store.filteredRecommendations
        } onChange: {
            mutations.increment()
        }

        // Simulate a TextField/Toggle re-asserting their current values --
        // AppKit does this during its own update pass.
        store.searchText = "andromeda"
        store.usefulFramingOnly = store.usefulFramingOnly

        #expect(mutations.current == 0)
        #expect(searchCounter.current == 1)
        #expect(store.filteredRecommendations == beforeReassertion)
    }

    @Test("A genuine change to usefulFramingOnly still recomputes filteredRecommendations")
    func usefulFramingOnlyChangeStillRecomputes() async {
        let store = PlanningStore(setups: [.apsCReference], catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext)
        store.activate()
        await store.pendingRefresh?.value
        // No search filter active -- toggling the useful-framing filter is
        // guaranteed to change which rows survive (tiny/mosaic targets
        // dropping out of the visible-tonight subset).
        let withUsefulFilter = store.filteredRecommendations

        store.usefulFramingOnly = false
        let withoutUsefulFilter = store.filteredRecommendations

        #expect(withoutUsefulFilter.count >= withUsefulFilter.count)
        #expect(withoutUsefulFilter != withUsefulFilter)
    }

    @Test("filteredRecommendations reflects a fresh recommendations pipeline result after refresh")
    func filteredRecommendationsTracksRecommendationsAcrossRefresh() async {
        let store = PlanningStore(
            setups: [.apsCReference],
            catalogProvider: { TargetCatalog.all },
            skyContextProvider: fixedSkyContext,
            focalLengthDebounceInterval: .zero
        )
        store.activate()
        await store.pendingRefresh?.value
        let initialFiltered = store.filteredRecommendations

        store.setFocalLength(400)
        await store.pendingRefresh?.value

        #expect(store.filteredRecommendations != initialFiltered)
        #expect(store.filteredRecommendations.allSatisfy { $0.fit != .tooSmall && $0.fit != .mosaic })
    }

    @Test("filteredRecommendations is a stored property, not a computed one that re-runs TargetCatalog.search per access")
    func filteredRecommendationsIsStoredNotComputed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Planning/PlanningStore.swift"),
            encoding: .utf8
        )
        #expect(source.contains("public private(set) var filteredRecommendations: [PlanningRecommendation] = []"))
        #expect(!source.contains("public var filteredRecommendations: [PlanningRecommendation] {"))
    }

    // MARK: - Task 1: tonight's-sky ranking, honest no-site state

    @Test("No library open means no invented ranking -- an explicit noLibrary state, not an empty search result")
    func noRootURLMeansNoLibrarySkyAvailability() async {
        let store = PlanningStore(setups: [.apsCReference])
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.skyAvailability == .noLibrary)
        #expect(store.recommendations.isEmpty)
    }

    @Test("A library whose site never resolves reports an explicit noSite state, not an invented ranking")
    func unresolvableSiteMeansNoSiteSkyAvailability() async {
        let store = PlanningStore(setups: [.apsCReference], skyContextProvider: { _ in nil })
        store.activate()
        store.setRootURL(URL(fileURLWithPath: "/tmp/does-not-matter"))
        await store.pendingRefresh?.value

        #expect(store.skyAvailability == .noSite)
        #expect(store.recommendations.isEmpty)
    }

    @Test("A resolved site produces a real ranking and reports the available state")
    func resolvedSiteMeansAvailableSkyAvailability() async {
        let store = PlanningStore(setups: [.apsCReference], catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext)
        store.activate()
        store.setRootURL(URL(fileURLWithPath: "/tmp/does-not-matter"))
        await store.pendingRefresh?.value

        #expect(store.skyAvailability == .available)
        #expect(!store.recommendations.isEmpty)
    }

    @Test("Setting the same rootURL twice does not trigger a second recompute")
    func sameValueSetRootURLIsAnObservableNoOp() async {
        let counter = CallCounter()
        let store = PlanningStore(setups: [.apsCReference]) { query in
            counter.increment()
            return query.recommendations()
        } skyContextProvider: { _ in nil }
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        let root = URL(fileURLWithPath: "/tmp/library-a")
        store.setRootURL(root)
        await store.pendingRefresh?.value
        #expect(counter.current == 2)

        store.setRootURL(root)
        #expect(counter.current == 2)
    }

    @Test("Low-altitude targets are hidden by default and revealed by the opt-in toggle")
    func lowAltitudeTargetsAreHiddenByDefault() async {
        let store = PlanningStore(setups: [.apsCReference], catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext)
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.showLowAltitudeTargets == false)
        #expect(store.filteredRecommendations.allSatisfy { !$0.isLowAltitude })
        #expect(store.recommendations.contains { $0.isLowAltitude }, "the fixture site/date must actually include some low-altitude targets for this test to mean anything")

        store.showLowAltitudeTargets = true

        #expect(store.filteredRecommendations.contains { $0.isLowAltitude })
    }

    // MARK: - Task 3: sky-path chart selection

    @Test("Selecting a target computes its sky path off the main actor")
    func selectingATargetComputesSkyPath() async throws {
        let store = PlanningStore(setups: [.apsCReference], catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext)
        store.activate()
        await store.pendingRefresh?.value
        let row = try #require(store.recommendations.first)

        store.selectTarget(row.target)
        await store.pendingSkyPathRefresh?.value

        let skyPath = try #require(store.skyPath)
        #expect(skyPath.target.designation == row.target.designation)
        #expect(!skyPath.samples.isEmpty)
    }

    @Test("Deselecting clears the sky path rather than leaving a stale one")
    func deselectingClearsSkyPath() async throws {
        let store = PlanningStore(setups: [.apsCReference], catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext)
        store.activate()
        await store.pendingRefresh?.value
        let row = try #require(store.recommendations.first)
        store.selectTarget(row.target)
        await store.pendingSkyPathRefresh?.value
        #expect(store.skyPath != nil)

        store.selectTarget(nil)

        #expect(store.skyPath == nil)
    }

    @Test("Selecting the same target twice is a same-value no-op")
    func sameValueSelectTargetIsANoOp() async throws {
        let store = PlanningStore(setups: [.apsCReference], catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext)
        store.activate()
        await store.pendingRefresh?.value
        let row = try #require(store.recommendations.first)
        store.selectTarget(row.target)
        await store.pendingSkyPathRefresh?.value

        let mutations = CallCounter()
        withObservationTracking {
            _ = store.skyPath
        } onChange: {
            mutations.increment()
        }

        store.selectTarget(row.target)

        #expect(mutations.current == 0)
    }

    @Test("No resolved site means no sky path, even with a target selected")
    func noSiteMeansNoSkyPath() async throws {
        let store = PlanningStore(setups: [.apsCReference])
        store.activate()
        await store.pendingRefresh?.value
        let target = try #require(TargetCatalog.all.first { $0.designation == "M 31" })

        store.selectTarget(target)
        await store.pendingSkyPathRefresh?.value

        #expect(store.skyAvailability == .noLibrary)
        #expect(store.skyPath == nil)
    }

    @Test("The sky path's max altitude agrees with DiscoveryPlanner's own value for the same target/night")
    func skyPathMaxAltitudeAgreesWithDiscoveryPlanner() async throws {
        let store = PlanningStore(setups: [.apsCReference], catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext)
        store.activate()
        await store.pendingRefresh?.value
        let row = try #require(store.recommendations.first { !$0.isLowAltitude })

        store.selectTarget(row.target)
        await store.pendingSkyPathRefresh?.value

        let skyPath = try #require(store.skyPath)
        #expect(skyPath.maxAltitudeDeg == row.maxAltitudeDeg)
    }

    // MARK: - W4-2 (cloud forecast)

    @Test("The planned night's cloud summary shows when the forecast covers it")
    func cloudStateShowsSummaryForPlannedNight() async throws {
        let key = nightKey(for: planningTestDate)
        let summary = DailyCloudSummary(date: key, minPercent: 12, maxPercent: 48, meanPercent: 30)
        let store = PlanningStore(
            setups: [.apsCReference], catalogProvider: { TargetCatalog.all },
            skyContextProvider: fixedSkyContext,
            weatherProvider: { _ in [key: summary] }
        )
        store.activate()
        await store.pendingRefresh?.value
        store.setPlanningDate(planningTestDate)
        await store.pendingRefresh?.value

        #expect(store.cloudState == .summary(summary))
    }

    @Test("A planned night beyond Open-Meteo's 7-day horizon reports so honestly, not a stale guess")
    func cloudStateReportsBeyondHorizonHonestly() async throws {
        let store = PlanningStore(
            setups: [.apsCReference], catalogProvider: { TargetCatalog.all },
            skyContextProvider: fixedSkyContext,
            // A real forecast fetch, just with no bucket covering this
            // particular night -- exactly what a night beyond Open-Meteo's
            // 7-day window looks like.
            weatherProvider: { _ in [:] }
        )
        store.activate()
        await store.pendingRefresh?.value
        store.setPlanningDate(planningTestDate)
        await store.pendingRefresh?.value

        #expect(store.cloudState == .beyondHorizon)
    }

    @Test("No cloud indicator at all when weather is off or no site resolves")
    func cloudStateHiddenWhenProviderReportsNothing() async throws {
        let store = PlanningStore(
            setups: [.apsCReference], catalogProvider: { TargetCatalog.all },
            skyContextProvider: fixedSkyContext,
            weatherProvider: { _ in nil }
        )
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.cloudState == .hidden)
    }

    // MARK: - Ideation #2 ("melyik géppel fér be?"): rig comparison
    //
    // Reworked per owner feedback (2026-08-19): the boolean `compareOtherRig`
    // checkbox (which always meant "compare against the one OTHER saved
    // setup") is now an explicit `compareSetupID: String?` selection --
    // `nil` means the same thing `compareOtherRig == false` used to, and any
    // non-`nil` value must name one of `store.compareOptions` (every saved
    // setup except the one currently selected).

    @Test("Setting compareSetupID recomputes the rig comparison exactly once, without re-running the recommendations pipeline")
    func settingCompareSetupIDRecomputesOnce() async throws {
        let counter = CallCounter()
        let setups: [ImagingSetupProfile] = [.apsCReference, .canonR8Zoom]
        let store = PlanningStore(
            setups: setups,
            computeRecommendations: { query in
                counter.increment()
                return query.recommendations()
            },
            catalogProvider: { TargetCatalog.all },
            skyContextProvider: fixedSkyContext
        )
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)
        #expect(store.rigCompare == nil, "the comparison must not be computed until a compare setup is actually picked")

        store.compareSetupID = ImagingSetupProfile.canonR8Zoom.id
        await store.pendingRigCompareRefresh?.value

        #expect(store.rigCompare != nil)
        #expect(counter.current == 1, "picking a comparison setup must not re-run the recommendations pipeline")

        // Same-value guard: re-asserting the current value (a `Picker`
        // binding does this during its own update pass) must not recompute.
        let afterFirstPick = store.rigCompare
        store.compareSetupID = ImagingSetupProfile.canonR8Zoom.id
        #expect(store.rigCompare != nil)
        #expect(store.rigCompare == afterFirstPick)

        // Setting it back to nil ("None") clears the stored comparison
        // rather than leaving a stale one the UI might read while the
        // picker reads "None".
        store.compareSetupID = nil
        await store.pendingRigCompareRefresh?.value
        #expect(store.rigCompare == nil)
    }

    @Test("A nil selection ('None') produces no compare data")
    func nilSelectionProducesNoCompareData() async {
        let setups: [ImagingSetupProfile] = [.apsCReference, .canonR8Zoom]
        let store = PlanningStore(
            setups: setups, catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext
        )
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.compareSetupID == nil, "comparison starts off until the owner explicitly picks a setup")
        #expect(store.rigCompare == nil)
        #expect(store.isComputingRigCompare == false)
    }

    @Test("compareOptions lists every saved setup except the one currently selected")
    func compareOptionsExcludesTheSelectedSetup() async {
        let setups: [ImagingSetupProfile] = [.apsCReference, .canonR8Zoom, .narrowReflector]
        let store = PlanningStore(
            setups: setups, catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext
        )
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.selectedSetupID == ImagingSetupProfile.apsCReference.id)
        let optionIDs = Set(store.compareOptions.map(\.id))
        #expect(optionIDs == [ImagingSetupProfile.canonR8Zoom.id, ImagingSetupProfile.narrowReflector.id])
        #expect(!optionIDs.contains(ImagingSetupProfile.apsCReference.id), "the currently selected setup must never be its own compare option")

        // Switching which setup is selected moves the exclusion, not just
        // the initial one -- the picker's options must always track
        // whichever setup is primary right now.
        store.selectedSetupID = ImagingSetupProfile.canonR8Zoom.id
        await store.pendingRefresh?.value
        let optionIDsAfterSwitch = Set(store.compareOptions.map(\.id))
        #expect(optionIDsAfterSwitch == [ImagingSetupProfile.apsCReference.id, ImagingSetupProfile.narrowReflector.id])
    }

    @Test("Selecting the primary setup as its own former compare target clears the now-invalid selection")
    func selectingThePickedCompareSetupClearsIt() async {
        let setups: [ImagingSetupProfile] = [.apsCReference, .canonR8Zoom, .narrowReflector]
        let store = PlanningStore(
            setups: setups, catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext
        )
        store.activate()
        await store.pendingRefresh?.value
        store.compareSetupID = ImagingSetupProfile.canonR8Zoom.id
        await store.pendingRigCompareRefresh?.value
        #expect(store.rigCompare != nil)

        // The setup that was picked as the COMPARE target becomes the newly
        // SELECTED one -- comparing a setup against itself is meaningless,
        // so this must clear the stale pick rather than silently comparing
        // Canon R8 zoom against itself.
        store.selectedSetupID = ImagingSetupProfile.canonR8Zoom.id
        await store.pendingRefresh?.value

        #expect(store.compareSetupID == nil)
        #expect(store.rigCompare == nil)
    }

    @Test("Fewer than two saved setups means no compare options and the comparison stays unavailable")
    func fewerThanTwoSetupsMeansRigCompareUnavailable() async {
        let store = PlanningStore(
            setups: [.apsCReference], catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext
        )
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.canCompareRigs == false)
        #expect(store.compareOptions.isEmpty, "a single-setup library exposes no compare options at all")
        #expect(store.compareSetup == nil)

        // Nothing in `compareOptions` to pick anyway, but even a hand-fed
        // invalid ID must not invent a comparison.
        store.compareSetupID = "does-not-exist"
        await store.pendingRigCompareRefresh?.value

        #expect(store.rigCompare == nil, "picking an unresolvable compare setup must not invent a comparison")
    }

    @Test("The rig-compare sentence components name the picked setup and its own fit for the selected target")
    func rigCompareSentenceComponentsNameThePickedSetupAndFit() async throws {
        let setups: [ImagingSetupProfile] = [.apsCReference, .canonR8Zoom]
        let store = PlanningStore(
            setups: setups, catalogProvider: { TargetCatalog.all }, skyContextProvider: fixedSkyContext
        )
        store.activate()
        await store.pendingRefresh?.value
        store.compareSetupID = ImagingSetupProfile.canonR8Zoom.id
        await store.pendingRigCompareRefresh?.value

        let designation = try #require(store.rigCompare?.first { $0.value.otherFit != nil }?.key)
        let components = try #require(store.rigCompareSentenceComponents(for: designation))
        #expect(components.setupName == ImagingSetupProfile.canonR8Zoom.cameraName)
        #expect(components.fit == store.rigCompare?[designation]?.otherFit)

        // No components at all once nothing is picked, or for a target this
        // designation-keyed lookup has never heard of.
        store.compareSetupID = nil
        #expect(store.rigCompareSentenceComponents(for: designation) == nil)
    }

    @Test("A stale rig-compare sweep never overwrites a newer one's result")
    func staleRigCompareSweepDoesNotOverwriteNewer() async throws {
        let setups: [ImagingSetupProfile] = [.apsCReference, .canonR8Zoom, .narrowReflector]
        let counter = CallCounter()
        let store = PlanningStore(
            setups: setups,
            computeRigCompare: { selectedSetupID, compareSetupID, allSetups, focalLengthMM, site, date, targets in
                let call = counter.increment()
                if call == 1 {
                    // The FIRST (canonR8Zoom-targeting) sweep is the slow
                    // one, so it completes AFTER the second, faster,
                    // narrowReflector-targeting sweep below -- exactly the
                    // ordering that would clobber the newer result if
                    // `rigCompareGeneration` didn't guard against it.
                    Thread.sleep(forTimeInterval: 0.2)
                }
                return RigCompareQuery.compare(
                    selectedSetupID: selectedSetupID, compareSetupID: compareSetupID,
                    setups: allSetups, focalLengthMM: focalLengthMM, site: site, date: date, targets: targets
                )
            },
            catalogProvider: { TargetCatalog.all },
            skyContextProvider: fixedSkyContext
        )
        store.activate()
        await store.pendingRefresh?.value

        store.compareSetupID = ImagingSetupProfile.canonR8Zoom.id
        let firstSweep = store.pendingRigCompareRefresh
        store.compareSetupID = ImagingSetupProfile.narrowReflector.id
        await store.pendingRigCompareRefresh?.value
        // Let the slow, now-stale first sweep finish; its generation is
        // behind, so it must not clobber `rigCompare` with narrowReflector's
        // own comparison overwritten back to canonR8Zoom's.
        await firstSweep?.value
        try? await Task.sleep(nanoseconds: 350_000_000)

        #expect(store.compareSetupID == ImagingSetupProfile.narrowReflector.id)
        let designation = try #require(store.rigCompare?.first { $0.value.otherFit != nil }?.key)
        let components = try #require(store.rigCompareSentenceComponents(for: designation))
        #expect(components.setupName == ImagingSetupProfile.narrowReflector.cameraName, "the stale canonR8Zoom sweep must not have landed after the newer narrowReflector one")
    }

    @Test("A fetch failure with no cached forecast surfaces the mapped error instead of silently hiding")
    func cloudStateSurfacesFetchFailure() async throws {
        let store = PlanningStore(
            setups: [.apsCReference], catalogProvider: { TargetCatalog.all },
            skyContextProvider: fixedSkyContext,
            weatherProvider: { _ in throw WeatherError.network }
        )
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.cloudState == .error(.network))
    }

    // MARK: - Task (imaging-setup CRUD): setups stay fresh across refreshes

    @Test("A setupsProvider result different from the injected setups replaces them on the next refresh")
    func refreshAdoptsANewSetupsListFromTheProvider() async {
        let store = PlanningStore(
            setups: [.apsCReference],
            setupsProvider: { _ in [.canonR8Zoom] },
            skyContextProvider: { _ in nil }
        )
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.setups == [.canonR8Zoom])
        #expect(store.selectedSetupID == ImagingSetupProfile.canonR8Zoom.id)
        #expect(store.focalLength == ImagingSetupProfile.canonR8Zoom.defaultFocalLengthMM)
    }

    @Test("A nil setupsProvider result leaves the current setups untouched")
    func refreshWithNoProviderResultKeepsInjectedSetups() async {
        let store = PlanningStore(
            setups: [.apsCReference],
            setupsProvider: { _ in nil },
            skyContextProvider: { _ in nil }
        )
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.setups == [.apsCReference])
        #expect(store.selectedSetupID == ImagingSetupProfile.apsCReference.id)
    }

    @Test("A setups reload that drops the active rig-compare pick clears the comparison")
    func refreshClearsAnInvalidatedCompareSetupID() async {
        let providerResult = SetupsProviderBox([.apsCReference, .canonR8Zoom])
        let store = PlanningStore(
            setups: [.apsCReference, .canonR8Zoom],
            setupsProvider: { _ in providerResult.current },
            skyContextProvider: { _ in nil }
        )
        store.activate()
        await store.pendingRefresh?.value
        store.compareSetupID = ImagingSetupProfile.canonR8Zoom.id
        #expect(store.compareSetupID == ImagingSetupProfile.canonR8Zoom.id)

        // The next reload reports canonR8Zoom deleted from config.
        providerResult.current = [.apsCReference]
        store.setPlanningDate(Date(timeIntervalSince1970: 0)) // forces a genuine refresh.
        await store.pendingRefresh?.value

        #expect(store.setups == [.apsCReference])
        #expect(store.compareSetupID == nil)
        #expect(store.selectedSetupID == ImagingSetupProfile.apsCReference.id)
    }

    @Test("Deleting the currently selected setup falls back to the config's own default, mirroring the no-setups-configured state")
    func refreshFallsBackWhenTheSelectedSetupIsDeleted() async {
        let providerResult = SetupsProviderBox([.apsCReference, .canonR8Zoom])
        let store = PlanningStore(
            setups: [.apsCReference, .canonR8Zoom],
            setupsProvider: { _ in providerResult.current },
            skyContextProvider: { _ in nil }
        )
        store.activate()
        await store.pendingRefresh?.value
        store.selectedSetupID = ImagingSetupProfile.canonR8Zoom.id
        #expect(store.selectedSetupID == ImagingSetupProfile.canonR8Zoom.id)

        // Settings deletes canonR8Zoom; apsCReference is config's own default.
        providerResult.current = [.apsCReference]
        store.setPlanningDate(Date(timeIntervalSince1970: 0))
        await store.pendingRefresh?.value

        #expect(store.selectedSetupID == ImagingSetupProfile.apsCReference.id)
        #expect(store.focalLength == ImagingSetupProfile.apsCReference.defaultFocalLengthMM)
    }

    // MARK: - `productionSetupsProvider`: the real config.json round trip

    @Test("productionSetupsProvider reads config.imagingSetups from disk")
    func productionSetupsProviderReadsConfiguredSetups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroTool-PlanningSetupsProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = AstroConfig()
        config.rootPath = root.path
        config.imagingSetups = [.canonR8Zoom]
        try config.save(using: WriteGuard(root: root))

        let result = PlanningStore.productionSetupsProvider(rootURL: root)
        #expect(result == [.canonR8Zoom])
    }

    @Test("productionSetupsProvider falls back to the bundled defaults once every saved setup is deleted")
    func productionSetupsProviderFallsBackWhenConfigHasNoSetups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AstroTool-PlanningSetupsProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = AstroConfig()
        config.rootPath = root.path
        config.imagingSetups = []
        try config.save(using: WriteGuard(root: root))

        let result = PlanningStore.productionSetupsProvider(rootURL: root)
        #expect(result == PlanningStore.defaultSetups)
    }

    @Test("productionSetupsProvider reports nothing new for a library with no config on disk yet")
    func productionSetupsProviderIsNilWithoutAConfigFile() {
        #expect(PlanningStore.productionSetupsProvider(rootURL: URL(fileURLWithPath: "/tmp/does-not-matter")) == nil)
        #expect(PlanningStore.productionSetupsProvider(rootURL: nil) == nil)
    }
}

private extension ImagingSetupProfile {
    static var apsCReference: Self {
        Self(
            id: "aps-c", name: "APS-C astro · 100–400 mm", cameraName: "APS-C astro",
            cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.6,
            focalLengthMinMM: 100, focalLengthMaxMM: 400, defaultFocalLengthMM: 200,
            fNumber: 5, relativeEfficiency: 1, isDefault: true
        )
    }

    static var canonR8Zoom: Self {
        Self(
            id: "canon-r8-zoom", name: "Canon R8 · 24–70 mm", cameraName: "Canon EOS R8",
            cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
            focalLengthMinMM: 24, focalLengthMaxMM: 70, defaultFocalLengthMM: 50,
            fNumber: 4, relativeEfficiency: 1, isDefault: false
        )
    }

    /// A THIRD saved setup, distinct from both `apsCReference` and
    /// `canonR8Zoom` -- exists only so the rig-compare picker tests can
    /// prove the owner's explicit selection is honored among three or more
    /// setups, not just "the one other setup" a boolean checkbox used to
    /// assume.
    static var narrowReflector: Self {
        Self(
            id: "narrow-reflector", name: "Big reflector · 673 mm", cameraName: "Big reflector",
            cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.6,
            focalLengthMinMM: 600, focalLengthMaxMM: 800, defaultFocalLengthMM: 673,
            fNumber: 8, relativeEfficiency: 1, isDefault: false
        )
    }
}
