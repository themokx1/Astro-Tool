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
        let store = PlanningStore(setups: [.apsCReference], skyContextProvider: fixedSkyContext)
        store.activate()
        await store.pendingRefresh?.value
        let initial = store.recommendations

        store.setFocalLength(400)
        await store.pendingRefresh?.value

        #expect(store.focalLength == 400)
        #expect(store.recommendations != initial)
        #expect(store.recommendations.first?.fit != .tooSmall)
    }

    @Test("Search accepts catalog and Hungarian target names")
    func targetSearchIsLocalized() async {
        let store = PlanningStore(setups: [.apsCReference], skyContextProvider: fixedSkyContext)
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
        let baselineRow = try #require(baseline.recommendations.first { $0.integrationHours != nil })
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
        let store = PlanningStore(setups: [.apsCReference]) { query in
            counter.increment()
            return query.recommendations()
        }
        store.activate()
        await store.pendingRefresh?.value
        #expect(counter.current == 1)

        store.setFocalLength(350)
        await store.pendingRefresh?.value

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
        let store = PlanningStore(setups: [.apsCReference]) { query in
            let call = counter.increment()
            if call == 1 {
                // The FIRST (init-triggered) compute is the slow one, so it
                // completes AFTER the second, faster, `setFocalLength`-
                // triggered compute below.
                Thread.sleep(forTimeInterval: 0.2)
            }
            return query.recommendations()
        }
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
        } catalogSearch: { query in
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
        } catalogSearch: { query in
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
        } catalogSearch: { query in
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
        let store = PlanningStore(setups: [.apsCReference], skyContextProvider: fixedSkyContext)
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
        let store = PlanningStore(setups: [.apsCReference], skyContextProvider: fixedSkyContext)
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
        let store = PlanningStore(setups: [.apsCReference], skyContextProvider: fixedSkyContext)
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
        let store = PlanningStore(setups: [.apsCReference], skyContextProvider: fixedSkyContext)
        store.activate()
        await store.pendingRefresh?.value

        #expect(store.showLowAltitudeTargets == false)
        #expect(store.filteredRecommendations.allSatisfy { !$0.isLowAltitude })
        #expect(store.recommendations.contains { $0.isLowAltitude }, "the fixture site/date must actually include some low-altitude targets for this test to mean anything")

        store.showLowAltitudeTargets = true

        #expect(store.filteredRecommendations.contains { $0.isLowAltitude })
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
}
