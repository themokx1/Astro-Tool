@testable import AstroApplication
import Foundation
import Testing

struct IntegrationTimeModelTests {
    @Test("Reference APS-C f/5 target requires ten hours")
    func referenceBaselineIsTenHours() {
        let input = IntegrationTimeInput(
            targetSurfaceBrightness: 22,
            skySurfaceBrightness: 21,
            focalRatio: 5,
            systemEfficiency: 1,
            passbandFactor: 1,
            samplingFactor: 1
        )

        #expect(IntegrationTimeModel.hours(input) == 10)
    }

    @Test("One magnitude fainter surface brightness needs about 6.31 times more integration")
    func oneMagnitudeFainterNeedsSixPointThreeTimesMoreTime() {
        let bright = IntegrationTimeModel.hours(.reference(targetSurfaceBrightness: 22))
        let faint = IntegrationTimeModel.hours(.reference(targetSurfaceBrightness: 23))

        #expect(abs(faint / bright - pow(10, 0.8)) < 0.01)
    }

    @Test("Faster optics and higher efficiency reduce the recommendation")
    func setupFactorsRemainRelativeToReference() {
        let reference = IntegrationTimeModel.hours(.reference(targetSurfaceBrightness: 22))
        var faster = IntegrationTimeInput.reference(targetSurfaceBrightness: 22)
        faster.focalRatio = 4
        faster.systemEfficiency = 1.25

        #expect(IntegrationTimeModel.hours(faster) < reference)
    }
}
