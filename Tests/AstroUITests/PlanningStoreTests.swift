@testable import AstroUI
import AstroApplication
import AstroCore
import Foundation
import Testing

@MainActor
struct PlanningStoreTests {
    @Test("Changing focal length recalculates framing and preserves useful-first ordering")
    func focalLengthRecalculatesRecommendations() {
        let store = PlanningStore(setups: [.apsCReference])
        let initial = store.recommendations

        store.setFocalLength(400)

        #expect(store.focalLength == 400)
        #expect(store.recommendations != initial)
        #expect(store.recommendations.first?.fit != .tooSmall)
    }

    @Test("Search accepts catalog and Hungarian target names")
    func targetSearchIsLocalized() {
        let store = PlanningStore(setups: [.apsCReference])

        store.searchText = "elefántormány"

        #expect(store.filteredRecommendations.map(\.target.designation) == ["IC 1396"])
    }

    @Test("Changing the Planning settings baseline changes the computed integration hours")
    func referencePreferencesChangeComputedIntegrationHours() throws {
        let suite = "AstroTool-PlanningStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let baseline = PlanningStore(setups: [.apsCReference], defaults: defaults)
        let baselineHours = try #require(baseline.recommendations.first?.integrationHours)
        // `PlanningStore` reads `UserDefaults` live rather than caching, so
        // this initial value is captured before the mutation below -- both
        // stores otherwise share the same `defaults` instance.
        let initialReferenceHours = baseline.referenceHours

        defaults.set(initialReferenceHours * 2, forKey: PlanningStore.referenceHoursKey)
        let doubled = PlanningStore(setups: [.apsCReference], defaults: defaults)

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
}
