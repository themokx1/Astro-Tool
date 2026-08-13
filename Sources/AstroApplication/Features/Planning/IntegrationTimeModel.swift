import Foundation

public struct IntegrationTimeInput: Equatable, Sendable {
    public var targetSurfaceBrightness: Double
    public var skySurfaceBrightness: Double
    public var focalRatio: Double
    public var systemEfficiency: Double
    public var passbandFactor: Double
    public var samplingFactor: Double

    public init(
        targetSurfaceBrightness: Double,
        skySurfaceBrightness: Double,
        focalRatio: Double,
        systemEfficiency: Double,
        passbandFactor: Double,
        samplingFactor: Double
    ) {
        self.targetSurfaceBrightness = targetSurfaceBrightness
        self.skySurfaceBrightness = skySurfaceBrightness
        self.focalRatio = focalRatio
        self.systemEfficiency = systemEfficiency
        self.passbandFactor = passbandFactor
        self.samplingFactor = samplingFactor
    }

    public static func reference(targetSurfaceBrightness: Double) -> Self {
        Self(
            targetSurfaceBrightness: targetSurfaceBrightness,
            skySurfaceBrightness: 21,
            focalRatio: 5,
            systemEfficiency: 1,
            passbandFactor: 1,
            samplingFactor: 1
        )
    }
}

/// A relative planning model, not a promise of final-image SNR.
///
/// Ten hours at μ=22 mag/arcsec², f/5 and reference throughput is the
/// approachable baseline. Surface-brightness signal-to-noise is squared,
/// therefore one magnitude fainter needs 10^0.8 (about 6.31) more time.
public enum IntegrationTimeModel {
    public static let referenceHours = 10.0
    public static let referenceSurfaceBrightness = 22.0

    public static func hours(_ input: IntegrationTimeInput) -> Double {
        guard input.targetSurfaceBrightness.isFinite,
              input.skySurfaceBrightness.isFinite,
              input.focalRatio.isFinite, input.focalRatio > 0,
              input.systemEfficiency.isFinite, input.systemEfficiency > 0,
              input.passbandFactor.isFinite, input.passbandFactor > 0,
              input.samplingFactor.isFinite, input.samplingFactor > 0
        else { return referenceHours }

        let targetFactor = pow(10, 0.8 * (input.targetSurfaceBrightness - referenceSurfaceBrightness))
        let skyFactor = pow(10, -0.4 * (input.skySurfaceBrightness - 21))
        let opticsFactor = pow(input.focalRatio / 5, 2)
        let throughputFactor = 1 / (input.systemEfficiency * input.passbandFactor)
        return max(0.25, referenceHours * targetFactor * skyFactor * opticsFactor * throughputFactor * input.samplingFactor)
    }
}
