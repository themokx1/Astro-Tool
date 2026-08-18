import Foundation

/// Whether a target's effective overall integration goal was written by the
/// photographer or supplied by the library-wide planning reference.
public enum IntegrationGoalSource: String, Codable, Equatable, Sendable {
    case explicitTag
    case automaticReference
}

/// One resolved overall target goal and the provenance the UI must show.
public struct EffectiveIntegrationGoal: Codable, Equatable, Sendable {
    public var seconds: Double
    public var source: IntegrationGoalSource

    public init(seconds: Double, source: IntegrationGoalSource) {
        self.seconds = seconds
        self.source = source
    }
}

/// Shared planning heuristic for targets without an explicit `goal:<hours>h`
/// tag. The comparison assumes equivalent normalized framing: optical speed
/// scales with f-number squared.
///
/// W7-B item 2 (2026-08-18 expert audit, correctness #2): this used to scale
/// its `targetDifficultyFactor` by `10^(0.4*Δμ)` and its `equipmentFactor` by
/// `referenceArea/setupArea` -- both fixed here, and BOTH engines now agree
/// with `IntegrationTimeModel` (`AstroApplication/Features/Planning/
/// IntegrationTimeModel.swift`), which this type mirrors in spirit but not
/// in code (different module, same "how much longer for a fainter target"
/// question). See `IntegrationGoalOrderingConsistencyTests` for the test
/// asserting the two engines now order targets identically for fixed
/// equipment.
public enum IntegrationGoalCalculator {
    public static func recommendedHours(
        rule: IntegrationReferenceRule,
        setup: ImagingSetupProfile?,
        target: CatalogTarget? = nil
    ) -> Double {
        guard validRule(rule) else { return 10 }
        let fallback = rule.baseHours
        let equipmentFactor = equipmentFactor(rule: rule, setup: setup)
        let targetFactor = targetDifficultyFactor(rule: rule, target: target)
        let result = fallback * equipmentFactor * targetFactor
        return valid(result) ? result : fallback
    }

    /// W7-B item 2: the exponent here used to be `0.4`, disagreeing with
    /// `IntegrationTimeModel.hours`'s `0.8` for the identical physical
    /// question ("how much longer does a target need once it gets fainter
    /// per unit area"). Surface-brightness signal-to-noise is squared, so
    /// integration time for equal SNR scales as flux^-2, i.e.
    /// `10^(0.8*Δμ)`, not `10^(0.4*Δμ)` (`IntegrationTimeModel`'s own doc
    /// comment: "one magnitude fainter needs 10^0.8 ... more time"). Fixed
    /// to `0.8` here, WITHIN the existing `minimumTargetFactor`/
    /// `maximumTargetFactor` clamp (unchanged) -- note that clamp now
    /// saturates for smaller magnitude differences than it used to (a
    /// single magnitude fainter already exceeds the default 3x ceiling),
    /// which is the correct, if more aggressive, consequence of the
    /// physically correct exponent, not a new bug.
    public static func targetDifficultyFactor(
        rule: IntegrationReferenceRule,
        target: CatalogTarget?
    ) -> Double {
        guard valid(rule.referenceSurfaceBrightnessMagPerArcsec2),
              valid(rule.minimumTargetFactor), valid(rule.maximumTargetFactor),
              rule.minimumTargetFactor <= rule.maximumTargetFactor,
              let target,
              let surfaceBrightness = TargetCatalog.estimatedSurfaceBrightness(for: target),
              surfaceBrightness.isFinite
        else { return 1 }

        let raw = pow(10, 0.8 * (surfaceBrightness - rule.referenceSurfaceBrightnessMagPerArcsec2))
        guard raw.isFinite, raw > 0 else { return 1 }
        return min(rule.maximumTargetFactor, max(rule.minimumTargetFactor, raw))
    }

    public static func effectiveGoal(
        tags: [String],
        rule: IntegrationReferenceRule,
        setup: ImagingSetupProfile?,
        target: CatalogTarget? = nil
    ) -> EffectiveIntegrationGoal {
        if let explicit = GoalTag.parse(tags: tags), explicit > 0, explicit.isFinite {
            return EffectiveIntegrationGoal(seconds: explicit, source: .explicitTag)
        }
        return EffectiveIntegrationGoal(
            seconds: recommendedHours(rule: rule, setup: setup, target: target) * 3600,
            source: .automaticReference
        )
    }

    /// W7-B item 2: this used to also multiply by `referenceArea/setupArea`
    /// (`rule.referenceSensorWidthMM * referenceSensorHeightMM` vs. the
    /// setup's own). Dropped: sensor area determines how much TOTAL sky a
    /// frame covers, not how long any one pixel needs to integrate for a
    /// given per-pixel (equivalently, per-arcsec2 surface-brightness) SNR --
    /// two cameras at the same f-ratio and efficiency accumulate signal per
    /// pixel at the same rate regardless of how many pixels/how much area
    /// the sensor has. `IntegrationTimeModel.hours` (the other engine this
    /// type is reconciled against, `IntegrationGoalOrderingConsistencyTests`)
    /// never had an area term at all -- only `focalRatio` and
    /// `systemEfficiency`. `sensorWidthMM`/`sensorHeightMM` are still
    /// validated on both `rule` and `setup` even though unused in the
    /// arithmetic below, so a setup with a missing/invalid sensor size still
    /// falls back to the neutral `1` rather than silently ignoring bad data
    /// elsewhere in this same `ImagingSetupProfile`.
    private static func equipmentFactor(
        rule: IntegrationReferenceRule,
        setup: ImagingSetupProfile?
    ) -> Double {
        guard valid(rule.referenceSensorWidthMM), valid(rule.referenceSensorHeightMM),
              valid(rule.referenceFNumber), valid(rule.referenceEfficiency),
              let setup,
              valid(setup.sensorWidthMM), valid(setup.sensorHeightMM),
              valid(setup.fNumber), valid(setup.relativeEfficiency)
        else { return 1 }

        return pow(setup.fNumber / rule.referenceFNumber, 2)
            * (rule.referenceEfficiency / setup.relativeEfficiency)
    }

    private static func valid(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }

    private static func validRule(_ rule: IntegrationReferenceRule) -> Bool {
        valid(rule.baseHours)
            && valid(rule.referenceSensorWidthMM)
            && valid(rule.referenceSensorHeightMM)
            && valid(rule.referenceFNumber)
            && valid(rule.referenceEfficiency)
            && valid(rule.referenceSurfaceBrightnessMagPerArcsec2)
            && valid(rule.minimumTargetFactor)
            && valid(rule.maximumTargetFactor)
            && rule.minimumTargetFactor <= rule.maximumTargetFactor
    }
}
