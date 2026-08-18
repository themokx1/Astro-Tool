@testable import AstroApplication
import AstroCore
import Foundation
import Testing

/// W7-B item 2: `IntegrationGoalCalculator` (`AstroCore/Stats/
/// IntegrationGoal.swift`) and `IntegrationTimeModel` (`AstroApplication/
/// Features/Planning/IntegrationTimeModel.swift`) answer the same physical
/// question -- "how much longer does a target that is Δμ fainter per
/// arcsec2 need, at fixed equipment" -- from two different modules, and used
/// to disagree: the former scaled by `10^(0.4*Δμ)`, the latter (the
/// physically correct one, since surface-brightness SNR is squared) by
/// `10^(0.8*Δμ)`. Both now use `0.8`. This test locks that agreement down
/// directly, not just via each engine's own isolated unit tests, so a future
/// edit to either one that reintroduces a drift is caught here.
struct IntegrationGoalOrderingConsistencyTests {
    @Test("For fixed, reference-matched equipment, the two integration engines produce the SAME hours -- not merely the same order -- across a range that stays inside the goal calculator's own clamp")
    func theTwoEnginesAgreeExactlyWithinTheClamp() {
        // Kept inside `IntegrationReferenceRule()`'s default
        // [0.5x, 3x] clamp (|0.8*delta| <= log10(3) ~= 0.477, i.e.
        // |delta| <~ 0.596) so neither engine's own saturation masks a
        // reintroduced exponent mismatch.
        let deltas: [Double] = [-0.3, -0.1, 0, 0.2, 0.5]
        let referenceSB = 22.0
        let setup = ImagingSetupProfile(
            id: "cross-engine-test", name: "Cross-engine test", cameraName: "Test",
            cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.6,
            focalLengthMinMM: 200, focalLengthMaxMM: 200, defaultFocalLengthMM: 200,
            fNumber: 5, relativeEfficiency: 1, isDefault: true
        )
        let rule = IntegrationReferenceRule()
        #expect(rule.baseHours == IntegrationTimeModel.referenceHours)
        #expect(rule.referenceFNumber == setup.fNumber)
        #expect(rule.referenceSurfaceBrightnessMagPerArcsec2 == referenceSB)

        var goalHours: [Double] = []
        var modelHours: [Double] = []
        for delta in deltas {
            let target = CatalogTarget(
                designation: "TEST delta \(delta)", commonNameHU: nil,
                raDeg: 0, decDeg: 0, kind: .emissionNebula,
                sizeArcmin: 1, magnitude: nil,
                surfaceBrightnessMagPerArcsec2: referenceSB + delta
            )
            goalHours.append(IntegrationGoalCalculator.recommendedHours(rule: rule, setup: setup, target: target))
            modelHours.append(IntegrationTimeModel.hours(
                IntegrationTimeInput(
                    targetSurfaceBrightness: referenceSB + delta,
                    // `IntegrationTimeModel.hours`'s sky factor is hardcoded
                    // against 21 internally regardless of the reference
                    // surface brightness parameter -- 21 keeps it neutral
                    // (skyFactor == 1), isolating the target-brightness term
                    // this test is actually about.
                    skySurfaceBrightness: 21,
                    focalRatio: setup.fNumber,
                    systemEfficiency: setup.relativeEfficiency,
                    passbandFactor: 1,
                    samplingFactor: 1
                ),
                referenceFocalRatio: setup.fNumber,
                referenceSurfaceBrightness: referenceSB
            ))
        }

        for index in deltas.indices {
            #expect(
                abs(goalHours[index] - modelHours[index]) < 0.000_001,
                "delta=\(deltas[index]) goal=\(goalHours[index]) model=\(modelHours[index])"
            )
        }
        // Both strictly increasing in delta -- a fainter target always needs
        // (never less, never equal) more integration time in both engines.
        for index in 1..<goalHours.count {
            #expect(goalHours[index] > goalHours[index - 1])
            #expect(modelHours[index] > modelHours[index - 1])
        }
    }
}
