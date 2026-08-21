import Foundation

public struct BriefingSkyPoint: Codable, Equatable, Sendable {
    public var time: Date
    public var altitudeDeg: Double

    public init(time: Date, altitudeDeg: Double) {
        self.time = time
        self.altitudeDeg = altitudeDeg
    }
}

public struct BriefingSkySummary: Codable, Equatable, Sendable {
    public var darknessStart: Date
    public var darknessEnd: Date
    public var maxAltitudeDeg: Double
    public var minimumAltitudeDeg: Double
    public var moonSeparationDeg: Double?
    public var altitudePoints: [BriefingSkyPoint]

    public init(
        darknessStart: Date,
        darknessEnd: Date,
        maxAltitudeDeg: Double,
        minimumAltitudeDeg: Double,
        moonSeparationDeg: Double? = nil,
        altitudePoints: [BriefingSkyPoint] = []
    ) {
        self.darknessStart = darknessStart
        self.darknessEnd = darknessEnd
        self.maxAltitudeDeg = maxAltitudeDeg
        self.minimumAltitudeDeg = minimumAltitudeDeg
        self.moonSeparationDeg = moonSeparationDeg
        self.altitudePoints = altitudePoints
    }
}

public struct BriefingEquipmentFacts: Codable, Equatable, Sendable {
    public var cameraName: String
    public var focalLengthMM: Double
    public var fNumber: Double
    public var filterName: String?

    public init(cameraName: String, focalLengthMM: Double, fNumber: Double, filterName: String? = nil) {
        self.cameraName = cameraName
        self.focalLengthMM = focalLengthMM
        self.fNumber = fNumber
        self.filterName = filterName
    }
}

public struct BriefingProjectProgress: Codable, Equatable, Sendable {
    public var existingIntegrationSeconds: Double
    public var goalIntegrationSeconds: Double

    public init(existingIntegrationSeconds: Double, goalIntegrationSeconds: Double) {
        self.existingIntegrationSeconds = existingIntegrationSeconds
        self.goalIntegrationSeconds = goalIntegrationSeconds
    }
}

public struct NightBriefingContext: Codable, Equatable, Sendable {
    public var calibrationGaps: [String]
    public var calibrationIsKnown: Bool
    public var poorQualityAction: String?
    public var sky: BriefingDataState<BriefingSkySummary>
    public var equipment: BriefingDataState<BriefingEquipmentFacts>
    public var projectProgress: BriefingDataState<BriefingProjectProgress>

    public init(
        calibrationGaps: [String] = [],
        calibrationIsKnown: Bool? = nil,
        poorQualityAction: String? = nil,
        sky: BriefingDataState<BriefingSkySummary> = .missing(reason: "Sky path is not available"),
        equipment: BriefingDataState<BriefingEquipmentFacts> = .missing(reason: "Equipment details are not available"),
        projectProgress: BriefingDataState<BriefingProjectProgress> = .missing(reason: "Project progress is not available")
    ) {
        self.calibrationGaps = calibrationGaps
        self.calibrationIsKnown = calibrationIsKnown ?? !calibrationGaps.isEmpty
        self.poorQualityAction = poorQualityAction
        self.sky = sky
        self.equipment = equipment
        self.projectProgress = projectProgress
    }
}

public struct NightBriefingContingencyBuilder: Sendable {
    public init() {}

    public func build(draft: NightBriefingDraft, context: NightBriefingContext) -> [BriefingContingency] {
        let backup = draft.targets.first(where: { $0.role == .backup })?.name
        return draft.language == .hu
            ? hungarian(backup: backup, context: context)
            : english(backup: backup, context: context)
    }

    private func hungarian(backup: String?, context: NightBriefingContext) -> [BriefingContingency] {
        let alternative = backup.map { "Válts a megadott tartalék célpontra: \($0)." }
            ?? "Nincs megadott tartalék célpont; az ég és a felszerelés ellenőrzése után dönts."
        let calibration = !context.calibrationIsKnown
            ? "A kalibrációs lefedettség nincs ellenőrizve; indulás előtt vesd össze a tervezett beállításokkal."
            : context.calibrationGaps.isEmpty
                ? "Nincs ismert kalibrációs hiány; a helyszínen is tartsd meg a beállításokat."
                : "Hiányzik: \(context.calibrationGaps.joined(separator: ", ")). Ne változtass olyan beállítást, amelyhez nincs megfelelő kalibráció."
        return [
            .init(id: "late-arrival", title: "Ha később érkezel", action: alternative),
            .init(id: "short-night", title: "Ha rövidebb lesz az éjszaka", action: "Az elsődleges célpont már megadott blokkját rövidítsd; ne sűrítsd össze ellenőrzés nélkül az expozíciókat."),
            .init(id: "clouds", title: "Ha erősödik a felhőzet", action: "Állítsd meg a sorozatot, ellenőrizd a képeket és a felszerelés biztonságát; a forecast nem garancia."),
            .init(id: "primary-unavailable", title: "Ha kiesik a fő célpont", action: alternative),
            .init(id: "calibration", title: "Ha hiányzik kalibráció", action: calibration),
            .init(id: "quality", title: "Ha romlik a képminőség", action: context.poorQualityAction ?? "Állj meg, készíts tesztképet, majd ellenőrizd a fókuszt, párát és guidingot."),
        ]
    }

    private func english(backup: String?, context: NightBriefingContext) -> [BriefingContingency] {
        let alternative = backup.map { "Switch to the selected backup target: \($0)." }
            ?? "No backup target is selected; decide only after checking the sky and equipment."
        let calibration = !context.calibrationIsKnown
            ? "Calibration coverage has not been checked; compare it with the planned settings before leaving."
            : context.calibrationGaps.isEmpty
                ? "No calibration gap is known; keep the planned settings in the field."
                : "Missing: \(context.calibrationGaps.joined(separator: ", ")). Do not change to settings without matching calibration."
        return [
            .init(id: "late-arrival", title: "If you arrive late", action: alternative),
            .init(id: "short-night", title: "If the night is shorter", action: "Shorten the primary target's existing block; do not compress exposures without checking them."),
            .init(id: "clouds", title: "If cloud increases", action: "Stop the sequence, check the frames and equipment safety; a forecast is not a guarantee."),
            .init(id: "primary-unavailable", title: "If the primary target is unavailable", action: alternative),
            .init(id: "calibration", title: "If calibration is missing", action: calibration),
            .init(id: "quality", title: "If image quality declines", action: context.poorQualityAction ?? "Pause, take a test frame, then check focus, dew and guiding."),
        ]
    }
}
