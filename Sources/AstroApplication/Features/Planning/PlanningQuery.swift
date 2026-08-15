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
    /// The computed integration hours fell outside
    /// `IntegrationTimeModel.maxPlausibleHours` -- an honest "this model
    /// can't give you a trustworthy number here" state, not a guess. See
    /// `PlanningQuery.integrationEstimate(...)`.
    case unknown
}

public struct PlanningRecommendation: Equatable, Sendable, Identifiable {
    public var id: String { target.designation }
    public let target: CatalogTarget
    public let frameCoverage: Double
    public let fit: PlanningFit
    public let compositionScore: Double
    /// `nil` when `integrationConfidence == .unknown` -- beyond the model's
    /// validity range, so no precise figure is presented at all (see
    /// `integrationEstimate(...)`).
    public let integrationHours: Double?
    public let integrationSource: String
    public let integrationConfidence: PlanningEstimateConfidence
    /// The following five fields come from `DiscoveryPlanner.discover` --
    /// the same tonight's-sky engine `Planner.plan` uses for the user's own
    /// library -- evaluated for `PlanningQuery.site`/`date`. All `nil` only
    /// when `PlanningQuery.site` itself is `nil` (an unresolved-site query
    /// short-circuits to an empty `recommendations()` result, so in practice
    /// these are non-nil on every row `recommendations()` actually returns).
    public let maxAltitudeDeg: Double?
    public let visibleHours: Double?
    public let culminationLocal: String?
    public let moonSeparationDeg: Double?
    /// Same Hungarian verdict vocabulary `Planner.plan`/`DiscoveryPlanner`
    /// use elsewhere in the app (`"ma jó"`, `"alacsony (max N°)"`, ...).
    public let skyVerdict: String
    /// `DiscoveryPlanner`'s own `visibilityFactor x moonPenalty` (composition
    /// is intentionally excluded here -- `compositionScore` above already
    /// carries this query's own framing opinion, so the two aren't
    /// double-counted). This is the PRIMARY sort key; `compositionScore` only
    /// breaks ties within it.
    public let skyScore: Double
    /// `true` when `maxAltitudeDeg` never reaches the imaging threshold
    /// (`PlanningQuery.minAltitudeDeg`) tonight -- a target this app must
    /// never present as a good suggestion no matter how well it would frame.
    /// Rows are NOT filtered on this here (same "flag, don't hide" contract
    /// `DiscoveryRow.alreadyInLibrary` documents) -- `PlanningStore` decides
    /// whether/how to hide them by default.
    public let isLowAltitude: Bool
}

public struct PlanningQuery: Sendable {
    public let setup: ImagingSetupProfile
    public let focalLength: Double
    public let targets: [CatalogTarget]
    /// The user's Planning-settings baseline (`v2.planning.reference*`,
    /// wired in by `PlanningStore`) -- defaults match
    /// `IntegrationTimeModel`'s own built-in baseline exactly, so a caller
    /// that never supplies these (every prior call site, and every fixture
    /// below) keeps its historical behavior unchanged.
    public let referenceHours: Double
    public let referenceFocalRatio: Double
    public let referenceSurfaceBrightness: Double
    /// Tonight's resolved observing site -- `nil` means no site could be
    /// resolved (no library open, or no explicit config/FITS-median site for
    /// the open one). `recommendations()` returns an empty array in that
    /// case rather than falling back to a framing-only ranking that ignores
    /// the sky entirely -- the bug this type was rebuilt to fix. Callers
    /// resolve this the same way the rest of the app does
    /// (`Planner.resolveSite`; see `PlanningStore.productionSkyContext`).
    public let site: SiteRule?
    /// The instant "tonight" is evaluated from. Defaults to `Date()` so a
    /// caller that never supplies one gets today's real sky; tests pin this
    /// to a fixed date for determinism.
    public let date: Date
    /// Mirrors `DiscoveryPlanner.discover`'s own default -- a target whose
    /// max altitude never reaches this tonight is `isLowAltitude`.
    public let minAltitudeDeg: Double

    public init(
        setup: ImagingSetupProfile,
        focalLength: Double? = nil,
        targets: [CatalogTarget] = TargetCatalog.all,
        referenceHours: Double = IntegrationTimeModel.referenceHours,
        referenceFocalRatio: Double = 5,
        referenceSurfaceBrightness: Double = IntegrationTimeModel.referenceSurfaceBrightness,
        site: SiteRule? = nil,
        date: Date = Date(),
        minAltitudeDeg: Double = 30
    ) {
        self.setup = setup
        self.focalLength = focalLength ?? setup.defaultFocalLengthMM
        self.targets = targets
        self.referenceHours = referenceHours
        self.referenceFocalRatio = referenceFocalRatio
        self.referenceSurfaceBrightness = referenceSurfaceBrightness
        self.site = site
        self.date = date
        self.minAltitudeDeg = minAltitudeDeg
    }

    public static func fixture(
        focalLength: Double,
        site: SiteRule? = nil,
        date: Date = Date()
    ) -> Self {
        PlanningQuery(
            setup: ImagingSetupProfile(
                id: "aps-c-reference", name: "APS-C astro · 100–400 mm",
                cameraName: "APS-C astro", cameraKind: .dedicatedAstro,
                sensorWidthMM: 23.5, sensorHeightMM: 15.6,
                focalLengthMinMM: 100, focalLengthMaxMM: 400,
                defaultFocalLengthMM: focalLength, fNumber: 5,
                relativeEfficiency: 1, isDefault: true
            ),
            focalLength: focalLength,
            site: site,
            date: date
        )
    }

    public func recommendations() -> [PlanningRecommendation] {
        guard let fov = setup.fieldOfView(at: focalLength) else { return [] }
        // No site resolved -- honest empty result, not an invented,
        // sky-blind ranking. `PlanningStore` surfaces this as an explicit
        // "set your site to get tonight's ranking" state.
        guard let site else { return [] }
        let shortEdgeArcmin = min(fov.widthDeg, fov.heightDeg) * 60
        let longEdgeArcmin = max(fov.widthDeg, fov.heightDeg) * 60

        // Pure sky placement, no FOV opinion baked in (`setupFOVDeg: nil`
        // keeps `DiscoveryRow.score` to just `visibilityFactor x
        // moonPenalty`) -- this query's OWN `composition(...)` below is the
        // framing opinion, kept separate so the two aren't double-counted.
        let skyRows = DiscoveryPlanner.discover(date: date, site: site, minAltitudeDeg: minAltitudeDeg)
        let skyByDesignation = Dictionary(uniqueKeysWithValues: skyRows.map { ($0.target.designation, $0) })

        return targets.map { target in
            let coverage = max(0, (target.sizeArcmin ?? 0) / shortEdgeArcmin)
            let composition = Self.composition(coverage: coverage, sizeArcmin: target.sizeArcmin, longEdgeArcmin: longEdgeArcmin)
            let estimate = Self.integrationEstimate(
                target: target,
                focalRatio: setup.fNumber,
                systemEfficiency: setup.relativeEfficiency,
                referenceHours: referenceHours,
                referenceFocalRatio: referenceFocalRatio,
                referenceSurfaceBrightness: referenceSurfaceBrightness
            )
            let sky = skyByDesignation[target.designation]
            let isLowAltitude = (sky?.maxAltitudeDeg).map { $0 < minAltitudeDeg } ?? true

            return PlanningRecommendation(
                target: target,
                frameCoverage: coverage,
                fit: composition.fit,
                compositionScore: composition.score,
                integrationHours: estimate.hours,
                integrationSource: estimate.source,
                integrationConfidence: estimate.confidence,
                maxAltitudeDeg: sky?.maxAltitudeDeg,
                visibleHours: sky?.visibleHours,
                culminationLocal: sky?.culminationLocal,
                moonSeparationDeg: sky?.moonSeparationDeg,
                skyVerdict: sky?.verdict ?? SkyVerdictText.noCoordinate,
                skyScore: sky?.score ?? 0,
                isLowAltitude: isLowAltitude
            )
        }
        // Observability tonight first, framing second: a target that is
        // merely well-framed but unobservable (isLowAltitude) must never
        // outrank one that is genuinely up. Within each altitude bucket,
        // `skyScore` (visible hours/Moon) outranks `compositionScore`
        // (framing fit), with frame coverage as the final tiebreaker --
        // exactly the priority order the user's own bug report asked for.
        .sorted { lhs, rhs in
            if lhs.isLowAltitude != rhs.isLowAltitude { return !lhs.isLowAltitude }
            if lhs.skyScore != rhs.skyScore { return lhs.skyScore > rhs.skyScore }
            if lhs.compositionScore != rhs.compositionScore { return lhs.compositionScore > rhs.compositionScore }
            return lhs.frameCoverage > rhs.frameCoverage
        }
    }

    struct IntegrationEstimate: Equatable, Sendable {
        let hours: Double?
        let source: String
        let confidence: PlanningEstimateConfidence
    }

    /// Isolated from `recommendations()` so Task 2's honesty fix (four-digit
    /// hour counts for large, faint extended objects like the Pelican
    /// Nebula) is directly testable without needing a resolved site/sky
    /// pipeline at all.
    static func integrationEstimate(
        target: CatalogTarget,
        focalRatio: Double,
        systemEfficiency: Double,
        referenceHours: Double,
        referenceFocalRatio: Double,
        referenceSurfaceBrightness: Double
    ) -> IntegrationEstimate {
        let directBrightness = target.surfaceBrightnessMagPerArcsec2
        let estimatedBrightness = TargetCatalog.estimatedSurfaceBrightness(for: target)
        let brightness = directBrightness ?? estimatedBrightness ?? 22
        let rawHours = IntegrationTimeModel.hours(
            IntegrationTimeInput(
                targetSurfaceBrightness: brightness,
                skySurfaceBrightness: 21,
                focalRatio: focalRatio,
                systemEfficiency: systemEfficiency,
                passbandFactor: 1,
                samplingFactor: 1
            ),
            referenceHours: referenceHours,
            referenceFocalRatio: referenceFocalRatio,
            referenceSurfaceBrightness: referenceSurfaceBrightness
        )

        guard rawHours <= IntegrationTimeModel.maxPlausibleHours else {
            return IntegrationEstimate(
                hours: nil,
                source: "Beyond this model's range at this setup -- catalog magnitude spread over a large area no longer gives a trustworthy figure",
                confidence: .unknown
            )
        }

        let confidence: PlanningEstimateConfidence = directBrightness != nil
            ? .curated : (estimatedBrightness != nil ? .estimated : .fallback)
        let source = directBrightness != nil
            ? "Curated surface brightness"
            : (estimatedBrightness != nil ? "Catalog magnitude and angular size estimate" : "Reference μ=22 fallback")
        return IntegrationEstimate(hours: rawHours, source: source, confidence: confidence)
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

/// Just the one string `DiscoveryPlanner`'s own (internal, `AstroCore`-only)
/// `SkyVerdict.noCoordinate` produces -- duplicated here as a literal rather
/// than exposing that enum publicly, since this is the one case
/// `PlanningQuery` itself can ever need to say without a `DiscoveryRow` to
/// ask (a target absent from `skyByDesignation`, which cannot happen in
/// practice: `DiscoveryPlanner.discover` always returns one row per
/// `TargetCatalog.all` entry, and `targets` defaults to that same catalog).
private enum SkyVerdictText {
    static let noCoordinate = "nincs koordináta"
}
