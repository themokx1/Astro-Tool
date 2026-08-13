import AstroApplication
import AstroCore
import Foundation
import Observation

@MainActor
@Observable
public final class PlanningStore {
    public let setups: [ImagingSetupProfile]
    public var selectedSetupID: String {
        didSet { adoptSelectedSetupDefaults() }
    }
    public private(set) var focalLength: Double
    public var searchText = ""
    public var usefulFramingOnly = true

    public init(setups: [ImagingSetupProfile] = PlanningStore.defaultSetups) {
        let safeSetups = setups.isEmpty ? PlanningStore.defaultSetups : setups
        self.setups = safeSetups
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

    public var recommendations: [PlanningRecommendation] {
        PlanningQuery(setup: selectedSetup, focalLength: focalLength).recommendations()
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
