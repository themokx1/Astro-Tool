import AstroCore
import Foundation

public enum PlanningFit: String, Equatable, Sendable {
    case mosaic
    case tooSmall
    case wide
    case good
    case tight

    public var label: String {
        switch self {
        case .mosaic: "Mosaic"
        case .tooSmall: "Too small"
        case .wide: "Wide composition"
        case .good: "Good framing"
        case .tight: "Tight framing"
        }
    }
}

public enum PlanningEstimateConfidence: String, Equatable, Sendable {
    case curated
    case estimated
    case fallback
    case unknown
}

public struct PlanningRecommendation: Equatable, Sendable, Identifiable {
    public var id: String { target.designation }
    public let target: CatalogTarget
    public let frameCoverage: Double
    public let fit: PlanningFit
    public let compositionScore: Double
    public let integrationHours: Double
    public let integrationSource: String
    public let integrationConfidence: PlanningEstimateConfidence
}

public struct PlanningQuery: Sendable {
    public let setup: ImagingSetupProfile
    public let focalLength: Double
    public let targets: [CatalogTarget]

    public init(setup: ImagingSetupProfile, focalLength: Double? = nil, targets: [CatalogTarget] = TargetCatalog.all) {
        self.setup = setup
        self.focalLength = focalLength ?? setup.defaultFocalLengthMM
        self.targets = targets
    }

    public static func fixture(focalLength: Double) -> Self {
        PlanningQuery(
            setup: ImagingSetupProfile(
                id: "aps-c-reference", name: "APS-C astro · 100–400 mm",
                cameraName: "APS-C astro", cameraKind: .dedicatedAstro,
                sensorWidthMM: 23.5, sensorHeightMM: 15.6,
                focalLengthMinMM: 100, focalLengthMaxMM: 400,
                defaultFocalLengthMM: focalLength, fNumber: 5,
                relativeEfficiency: 1, isDefault: true
            ),
            focalLength: focalLength
        )
    }

    public func recommendations() -> [PlanningRecommendation] {
        guard let fov = setup.fieldOfView(at: focalLength) else { return [] }
        let shortEdgeArcmin = min(fov.widthDeg, fov.heightDeg) * 60
        let longEdgeArcmin = max(fov.widthDeg, fov.heightDeg) * 60

        return targets.map { target in
            let coverage = max(0, (target.sizeArcmin ?? 0) / shortEdgeArcmin)
            let composition = Self.composition(coverage: coverage, sizeArcmin: target.sizeArcmin, longEdgeArcmin: longEdgeArcmin)
            let directBrightness = target.surfaceBrightnessMagPerArcsec2
            let estimatedBrightness = TargetCatalog.estimatedSurfaceBrightness(for: target)
            let brightness = directBrightness ?? estimatedBrightness ?? 22
            let confidence: PlanningEstimateConfidence = directBrightness != nil
                ? .curated : (estimatedBrightness != nil ? .estimated : .fallback)
            let source = directBrightness != nil
                ? "Curated surface brightness"
                : (estimatedBrightness != nil ? "Catalog magnitude and angular size estimate" : "Reference μ=22 fallback")
            let hours = IntegrationTimeModel.hours(IntegrationTimeInput(
                targetSurfaceBrightness: brightness,
                skySurfaceBrightness: 21,
                focalRatio: setup.fNumber,
                systemEfficiency: setup.relativeEfficiency,
                passbandFactor: 1,
                samplingFactor: 1
            ))
            return PlanningRecommendation(
                target: target,
                frameCoverage: coverage,
                fit: composition.fit,
                compositionScore: composition.score,
                integrationHours: hours,
                integrationSource: source,
                integrationConfidence: confidence
            )
        }
        .sorted {
            if $0.compositionScore != $1.compositionScore { return $0.compositionScore > $1.compositionScore }
            return $0.frameCoverage > $1.frameCoverage
        }
    }

    private static func composition(
        coverage: Double,
        sizeArcmin: Double?,
        longEdgeArcmin: Double
    ) -> (fit: PlanningFit, score: Double) {
        guard let sizeArcmin, sizeArcmin > 0 else { return (.tooSmall, 0.02) }
        if sizeArcmin > longEdgeArcmin * 1.1 { return (.mosaic, 0.08) }
        if coverage < 0.08 { return (.tooSmall, max(0.02, coverage)) }
        if coverage < 0.18 { return (.wide, 0.3 + coverage) }
        if coverage <= 0.75 { return (.good, 1 - abs(coverage - 0.45) * 0.25) }
        return (.tight, coverage <= 1 ? 0.78 : 0.6)
    }
}
