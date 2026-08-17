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
///
/// Deliberately time-of-night-agnostic: `hours(...)` is a pure photometric
/// ratio against the reference target/setup, with no dusk/dawn/altitude
/// input at all. The number it returns is a TOTAL exposure budget an
/// astrophotographer would accumulate across as many nights as it takes --
/// it is not, and was never meant to be, "hours available tonight", so it
/// routinely and correctly exceeds a single night's astronomical darkness
/// for anything fainter than the reference. `PlanningQuery` is what has a
/// notion of "tonight" at all (`nightConditions`, `DiscoveryPlanner`'s
/// night-bounded `visibleHours`) -- see its `integrationEstimate(...)` and
/// `PlanningRecommendation.integrationNightsAtTonightsPace`, which divides
/// this model's output by that per-night figure rather than conflating the
/// two (2026-08-17 owner report: "az integráció tévesen azt nézi csak,
/// mikor van fent a célpont, azt nem, hogy mettől meddig van éjszaka" --
/// investigation found this model was never consulting up-time or night
/// bounds in the first place; the fix is exposing the multi-night relationship
/// explicitly instead of leaving a bare, easy-to-misread hour count).
public enum IntegrationTimeModel {
    public static let referenceHours = 10.0
    public static let referenceSurfaceBrightness = 22.0
    /// Above this many hours, the model's own inputs have stopped producing
    /// a trustworthy planning figure. The surface-brightness estimate this
    /// model is fed (`TargetCatalog.estimatedSurfaceBrightness`, when no
    /// curated value exists) spreads a target's INTEGRATED catalog magnitude
    /// evenly across its full angular area -- honest for a compact object,
    /// but for a large, faint extended nebula (the Pelican Nebula shape: mag
    /// 8 spread over 60 arcmin) it manufactures a surface brightness far
    /// fainter than the object's actual photographable structure, which this
    /// model's inverse-square relation then turns into a four-digit hour
    /// count. `PlanningQuery` treats anything past this bound as "beyond this
    /// model's range" rather than printing a precise but meaningless number
    /// -- see its own `integrationEstimate(...)`. Chosen well above any
    /// exposure time an astrophotographer would actually plan for (even a
    /// tough narrowband target rarely exceeds this), so it never demotes a
    /// genuinely faint-but-plannable target.
    public static let maxPlausibleHours = 60.0

    /// `referenceHours`/`referenceFocalRatio`/`referenceSurfaceBrightness`
    /// default to this type's own baseline constants (10 hours at f/5 and
    /// μ22), matching every existing call site's behavior exactly. V2's
    /// Planning settings (`v2.planning.reference*`) let a user move this
    /// baseline; `PlanningStore`/`PlanningQuery` are what actually thread
    /// the user's preferences in here -- this function itself stays a pure,
    /// preference-agnostic calculation.
    public static func hours(
        _ input: IntegrationTimeInput,
        referenceHours: Double = IntegrationTimeModel.referenceHours,
        referenceFocalRatio: Double = 5,
        referenceSurfaceBrightness: Double = IntegrationTimeModel.referenceSurfaceBrightness
    ) -> Double {
        guard input.targetSurfaceBrightness.isFinite,
              input.skySurfaceBrightness.isFinite,
              input.focalRatio.isFinite, input.focalRatio > 0,
              input.systemEfficiency.isFinite, input.systemEfficiency > 0,
              input.passbandFactor.isFinite, input.passbandFactor > 0,
              input.samplingFactor.isFinite, input.samplingFactor > 0,
              referenceHours.isFinite, referenceHours > 0,
              referenceFocalRatio.isFinite, referenceFocalRatio > 0,
              referenceSurfaceBrightness.isFinite
        else { return IntegrationTimeModel.referenceHours }

        let targetFactor = pow(10, 0.8 * (input.targetSurfaceBrightness - referenceSurfaceBrightness))
        let skyFactor = pow(10, -0.4 * (input.skySurfaceBrightness - 21))
        let opticsFactor = pow(input.focalRatio / referenceFocalRatio, 2)
        let throughputFactor = 1 / (input.systemEfficiency * input.passbandFactor)
        return max(0.25, referenceHours * targetFactor * skyFactor * opticsFactor * throughputFactor * input.samplingFactor)
    }
}
