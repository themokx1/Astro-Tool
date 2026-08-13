import AstroApplication
import AstroCore
import Foundation
import Observation

@MainActor
@Observable
public final class PlanningStore {
    /// Shared with `V2SettingsView`'s Planning tab -- both read and write
    /// the same `UserDefaults` keys, so a preference change there is
    /// reflected here without any direct store-to-store wiring.
    public static let referenceHoursKey = "v2.planning.referenceHours"
    public static let referenceFocalRatioKey = "v2.planning.referenceFocalRatio"
    public static let referenceSurfaceBrightnessKey = "v2.planning.referenceSurfaceBrightness"

    public let setups: [ImagingSetupProfile]
    public var selectedSetupID: String {
        didSet { adoptSelectedSetupDefaults() }
    }
    public private(set) var focalLength: Double
    public var searchText = ""
    public var usefulFramingOnly = true
    private let defaults: UserDefaults

    public init(setups: [ImagingSetupProfile] = PlanningStore.defaultSetups, defaults: UserDefaults = .standard) {
        let safeSetups = setups.isEmpty ? PlanningStore.defaultSetups : setups
        self.setups = safeSetups
        self.defaults = defaults
        defaults.register(defaults: [
            Self.referenceHoursKey: IntegrationTimeModel.referenceHours,
            Self.referenceFocalRatioKey: 5.0,
            Self.referenceSurfaceBrightnessKey: IntegrationTimeModel.referenceSurfaceBrightness,
        ])
        let initial = safeSetups.first(where: \.isDefault) ?? safeSetups[0]
        selectedSetupID = initial.id
        focalLength = initial.defaultFocalLengthMM
    }

    public var selectedSetup: ImagingSetupProfile {
        setups.first { $0.id == selectedSetupID } ?? setups[0]
    }

    public var fieldOfView: SetupFieldOfView? {
        selectedSetup.fieldOfView(at: focalLength)
    }

    /// The Planning tab's integration baseline (`v2.planning.reference*`),
    /// read live from `UserDefaults` on every access -- a preference change
    /// while this store is alive (e.g. the Settings window is open at the
    /// same time) is picked up on the very next `recommendations` read,
    /// with no notification plumbing required.
    public var referenceHours: Double { defaults.double(forKey: Self.referenceHoursKey) }
    public var referenceFocalRatio: Double { defaults.double(forKey: Self.referenceFocalRatioKey) }
    public var referenceSurfaceBrightness: Double { defaults.double(forKey: Self.referenceSurfaceBrightnessKey) }

    public var recommendations: [PlanningRecommendation] {
        PlanningQuery(
            setup: selectedSetup,
            focalLength: focalLength,
            referenceHours: referenceHours,
            referenceFocalRatio: referenceFocalRatio,
            referenceSurfaceBrightness: referenceSurfaceBrightness
        ).recommendations()
    }

    public var filteredRecommendations: [PlanningRecommendation] {
        var rows = recommendations
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let matchingIDs = Set(TargetCatalog.search(query, limit: TargetCatalog.all.count).map(\.designation))
            rows = rows.filter { matchingIDs.contains($0.target.designation) }
        }
        if usefulFramingOnly {
            rows = rows.filter { $0.fit != .tooSmall && $0.fit != .mosaic }
        }
        return rows
    }

    public func setFocalLength(_ value: Double) {
        focalLength = min(max(value, selectedSetup.focalLengthMinMM), selectedSetup.focalLengthMaxMM)
    }

    private func adoptSelectedSetupDefaults() {
        focalLength = selectedSetup.defaultFocalLengthMM
    }

    public static let defaultSetups: [ImagingSetupProfile] = [
        ImagingSetupProfile(
            id: "aps-c-astro-100-400", name: "APS-C astro · 100–400 mm", cameraName: "APS-C astro",
            cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.6,
            focalLengthMinMM: 100, focalLengthMaxMM: 400, defaultFocalLengthMM: 200,
            fNumber: 5, relativeEfficiency: 1, isDefault: true
        ),
        ImagingSetupProfile(
            id: "canon-r8-16", name: "Canon R8 · 16 mm", cameraName: "Canon EOS R8",
            cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
            focalLengthMinMM: 16, focalLengthMaxMM: 16, defaultFocalLengthMM: 16,
            fNumber: 2.8, relativeEfficiency: 1, isDefault: false
        ),
        ImagingSetupProfile(
            id: "canon-r8-28-70", name: "Canon R8 · 28–70 mm", cameraName: "Canon EOS R8",
            cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
            focalLengthMinMM: 28, focalLengthMaxMM: 70, defaultFocalLengthMM: 50,
            fNumber: 4, relativeEfficiency: 1, isDefault: false
        ),
    ]
}
