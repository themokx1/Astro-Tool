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
/// scales with f-number squared and total captured field with sensor area.
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

        let raw = pow(10, 0.4 * (surfaceBrightness - rule.referenceSurfaceBrightnessMagPerArcsec2))
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

        let referenceArea = rule.referenceSensorWidthMM * rule.referenceSensorHeightMM
        let setupArea = setup.sensorWidthMM * setup.sensorHeightMM
        return pow(setup.fNumber / rule.referenceFNumber, 2)
            * (referenceArea / setupArea)
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
