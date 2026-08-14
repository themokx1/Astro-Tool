@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

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
    @Test("Changing focal length recalculates framing and preserves useful-first ordering")
    func focalLengthRecalculatesRecommendations() async {
        let store = PlanningStore(setups: [.apsCReference])
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
        let store = PlanningStore(setups: [.apsCReference])
        await store.pendingRefresh?.value

        store.searchText = "elefántormány"

        #expect(store.filteredRecommendations.map(\.target.designation) == ["IC 1396"])
    }

    @Test("Changing the Planning settings baseline changes the computed integration hours")
    func referencePreferencesChangeComputedIntegrationHours() async throws {
        let suite = "AstroTool-PlanningStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let baseline = PlanningStore(setups: [.apsCReference], defaults: defaults)
        await baseline.pendingRefresh?.value
        let baselineHours = try #require(baseline.recommendations.first?.integrationHours)
        // `PlanningStore` reads `UserDefaults` live rather than caching, so
        // this initial value is captured before the mutation below -- both
        // stores otherwise share the same `defaults` instance.
        let initialReferenceHours = baseline.referenceHours

        defaults.set(initialReferenceHours * 2, forKey: PlanningStore.referenceHoursKey)
        let doubled = PlanningStore(setups: [.apsCReference], defaults: defaults)
        await doubled.pendingRefresh?.value

        #expect(doubled.referenceHours == initialReferenceHours * 2)
        let doubledHours = try #require(doubled.recommendations.first?.integrationHours)
        #expect(abs(doubledHours / baselineHours - 2) < 0.001)
    }

    @Test("PlanningStore's reference defaults match IntegrationTimeModel's own baseline")
    func referenceDefaultsMatchIntegrationTimeModel() throws {
        let suite = "AstroTool-PlanningStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlanningStore(setups: [.apsCReference], defaults: defaults)

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
        let store = PlanningStore(setups: [.apsCReference]) { query in
            Thread.sleep(forTimeInterval: 0.05)
            return query.recommendations()
        }

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
