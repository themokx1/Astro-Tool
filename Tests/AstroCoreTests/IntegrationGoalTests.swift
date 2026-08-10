import Foundation
import Testing
@testable import AstroCore

private func goalSetup(
    width: Double = 23.5,
    height: Double = 15.6,
    fNumber: Double = 5,
    efficiency: Double = 1
) -> ImagingSetupProfile {
    ImagingSetupProfile(
        id: "goal-setup", name: "Tervezési setup", cameraName: "Kamera",
        cameraKind: .dedicatedAstro,
        sensorWidthMM: width, sensorHeightMM: height,
        focalLengthMinMM: 200, focalLengthMaxMM: 200,
        defaultFocalLengthMM: 200,
        fNumber: fNumber,
        relativeEfficiency: efficiency,
        isDefault: true
    )
}

@Test func defaultIntegrationReferenceIsTenHoursOnAPSCAtF5() {
    let rule = IntegrationReferenceRule()

    #expect(rule.baseHours == 10)
    #expect(rule.referenceSensorWidthMM == 23.5)
    #expect(rule.referenceSensorHeightMM == 15.6)
    #expect(rule.referenceFNumber == 5)
    #expect(rule.referenceEfficiency == 1)
    #expect(rule.referenceSurfaceBrightnessMagPerArcsec2 == 22)
    #expect(rule.minimumTargetFactor == 0.5)
    #expect(rule.maximumTargetFactor == 3)
    #expect(IntegrationGoalCalculator.recommendedHours(rule: rule, setup: goalSetup()) == 10)
}

@Test func integrationReferenceIsTenHoursAtReferenceSurfaceBrightness() {
    let target = CatalogTarget(
        designation: "TEST 1", commonNameHU: nil,
        raDeg: 0, decDeg: 0, kind: .other,
        sizeArcmin: 1, magnitude: nil,
        surfaceBrightnessMagPerArcsec2: 22
    )

    let hours = IntegrationGoalCalculator.recommendedHours(
        rule: IntegrationReferenceRule(), setup: goalSetup(), target: target
    )
    #expect(abs(hours - 10) < 0.000_001)
}

@Test func integrationReferenceMakesFaintExtendedTargetsLonger() {
    let target = CatalogTarget(
        designation: "TEST 2", commonNameHU: nil,
        raDeg: 0, decDeg: 0, kind: .emissionNebula,
        sizeArcmin: 1, magnitude: nil,
        surfaceBrightnessMagPerArcsec2: 23
    )

    let hours = IntegrationGoalCalculator.recommendedHours(
        rule: IntegrationReferenceRule(), setup: goalSetup(), target: target
    )
    #expect(abs(hours - 25.118_864_315) < 0.000_001)
}

@Test func integrationReferenceClampsTargetDifficultyToAchievableRange() {
    let veryBright = CatalogTarget(
        designation: "TEST 3", commonNameHU: nil,
        raDeg: 0, decDeg: 0, kind: .other,
        sizeArcmin: 1, magnitude: nil,
        surfaceBrightnessMagPerArcsec2: 15
    )
    let veryFaint = CatalogTarget(
        designation: "TEST 4", commonNameHU: nil,
        raDeg: 0, decDeg: 0, kind: .other,
        sizeArcmin: 1, magnitude: nil,
        surfaceBrightnessMagPerArcsec2: 30
    )

    #expect(IntegrationGoalCalculator.recommendedHours(rule: .init(), setup: goalSetup(), target: veryBright) == 5)
    #expect(IntegrationGoalCalculator.recommendedHours(rule: .init(), setup: goalSetup(), target: veryFaint) == 30)
}

@Test func catalogTargetsProduceUsefulAttainableReferenceGoals() throws {
    let m42 = try #require(TargetCatalog.all.first { $0.designation == "M 42" })
    let elephant = try #require(TargetCatalog.all.first { $0.designation == "IC 1396" })

    let m42Hours = IntegrationGoalCalculator.recommendedHours(
        rule: .init(), setup: goalSetup(), target: m42
    )
    let elephantHours = IntegrationGoalCalculator.recommendedHours(
        rule: .init(), setup: goalSetup(), target: elephant
    )

    #expect(m42Hours == 5)
    #expect(elephantHours > m42Hours)
    #expect(elephantHours == 30)
}

@Test func integrationReferenceFallsBackToNeutralTargetFactorWithoutPhotometry() {
    let target = CatalogTarget(
        designation: "TEST 5", commonNameHU: nil,
        raDeg: 0, decDeg: 0, kind: .darkNebula,
        sizeArcmin: 60, magnitude: nil
    )
    #expect(IntegrationGoalCalculator.recommendedHours(rule: .init(), setup: goalSetup(), target: target) == 10)
}

@Test func integrationReferenceScalesWithFNumberSquared() {
    let hours = IntegrationGoalCalculator.recommendedHours(
        rule: IntegrationReferenceRule(), setup: goalSetup(fNumber: 4)
    )

    #expect(abs(hours - 6.4) < 0.000_001)
}

@Test func integrationReferenceScalesWithSensorAreaForEquivalentFraming() {
    let hours = IntegrationGoalCalculator.recommendedHours(
        rule: IntegrationReferenceRule(), setup: goalSetup(width: 36, height: 24)
    )

    #expect(abs(hours - 4.243_055_555_6) < 0.000_001)
}

@Test func integrationReferenceAccountsForRelativeSystemEfficiency() {
    let hours = IntegrationGoalCalculator.recommendedHours(
        rule: IntegrationReferenceRule(), setup: goalSetup(efficiency: 0.8)
    )

    #expect(abs(hours - 12.5) < 0.000_001)
}

@Test func integrationReferenceFallsBackToBaseForMissingOrInvalidSetup() {
    let rule = IntegrationReferenceRule()
    var broken = goalSetup()
    broken.fNumber = 0

    #expect(IntegrationGoalCalculator.recommendedHours(rule: rule, setup: nil) == 10)
    #expect(IntegrationGoalCalculator.recommendedHours(rule: rule, setup: broken) == 10)
}

@Test func malformedReferenceRuleFallsBackToSafeTenHoursWithoutPartialScaling() {
    let faint = CatalogTarget(
        designation: "TEST 6", commonNameHU: nil,
        raDeg: 0, decDeg: 0, kind: .emissionNebula,
        sizeArcmin: 1, magnitude: nil,
        surfaceBrightnessMagPerArcsec2: 25
    )
    var brokenEquipmentReference = IntegrationReferenceRule()
    brokenEquipmentReference.referenceSensorWidthMM = 0
    var brokenTargetReference = IntegrationReferenceRule()
    brokenTargetReference.minimumTargetFactor = 4
    brokenTargetReference.maximumTargetFactor = 1

    #expect(IntegrationGoalCalculator.recommendedHours(
        rule: brokenEquipmentReference, setup: goalSetup(width: 36, height: 24), target: faint
    ) == 10)
    #expect(IntegrationGoalCalculator.recommendedHours(
        rule: brokenTargetReference, setup: goalSetup(width: 36, height: 24), target: faint
    ) == 10)
}

@Test func effectiveGoalPrefersExplicitTagOverAutomaticReference() {
    let automatic = IntegrationGoalCalculator.effectiveGoal(
        tags: ["goal:18h"],
        rule: IntegrationReferenceRule(),
        setup: goalSetup()
    )

    #expect(automatic.seconds == 18 * 3600)
    #expect(automatic.source == .explicitTag)
}

@Test func effectiveGoalUsesAutomaticReferenceWithoutOverallTag() {
    let automatic = IntegrationGoalCalculator.effectiveGoal(
        tags: ["goal:Ha=12h"],
        rule: IntegrationReferenceRule(),
        setup: goalSetup()
    )

    #expect(automatic.seconds == 10 * 3600)
    #expect(automatic.source == .automaticReference)
}

@Test func oldImagingSetupJSONDecodesPlanningDefaults() throws {
    let json = """
    {
      "id": "legacy", "name": "Régi", "cameraName": "Kamera",
      "cameraKind": "dedicatedAstro",
      "sensorWidthMM": 23.5, "sensorHeightMM": 15.6,
      "focalLengthMinMM": 200, "focalLengthMaxMM": 200,
      "defaultFocalLengthMM": 200, "isDefault": true
    }
    """

    let setup = try JSONDecoder().decode(ImagingSetupProfile.self, from: Data(json.utf8))
    #expect(setup.fNumber == 5)
    #expect(setup.relativeEfficiency == 1)
}

@Test func integrationReferenceRoundTripsThroughConfig() throws {
    var config = AstroConfig()
    config.integrationReference = IntegrationReferenceRule(
        baseHours: 12,
        referenceSensorWidthMM: 22.3,
        referenceSensorHeightMM: 14.9,
        referenceFNumber: 4,
        referenceEfficiency: 0.9,
        referenceSurfaceBrightnessMagPerArcsec2: 21.5,
        minimumTargetFactor: 0.4,
        maximumTargetFactor: 4
    )

    let decoded = try JSONDecoder().decode(AstroConfig.self, from: JSONEncoder().encode(config))
    #expect(decoded.integrationReference == config.integrationReference)
}
