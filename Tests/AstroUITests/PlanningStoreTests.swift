@testable import AstroUI
import AstroCore
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
