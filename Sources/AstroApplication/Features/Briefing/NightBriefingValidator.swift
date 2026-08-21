import Foundation

public enum BriefingValidationCode: String, Codable, Sendable {
    case missingDate
    case invalidTargetWindow
    case missingSite
    case missingSetup
    case missingWeather
    case missingPrimaryTarget
    case overlappingTargets
    case missingCapturePlan
    case departureBeforeTargetEnd
    case targetOutsideDarkness
    case weatherFreshnessUnknown
    case missingSkyContext
    case calibrationGap
}

public struct BriefingValidationIssue: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(code.rawValue)-\(targetID?.uuidString ?? "briefing")" }
    public let code: BriefingValidationCode
    public let message: String
    public let blocksExport: Bool
    public let targetID: UUID?

    public init(code: BriefingValidationCode, message: String, blocksExport: Bool = false, targetID: UUID? = nil) {
        self.code = code
        self.message = message
        self.blocksExport = blocksExport
        self.targetID = targetID
    }
}

public struct BriefingValidationReport: Equatable, Sendable {
    public let readiness: BriefingReadiness
    public let issues: [BriefingValidationIssue]
    public var blocksExport: Bool { issues.contains(where: \.blocksExport) }

    public init(readiness: BriefingReadiness, issues: [BriefingValidationIssue]) {
        self.readiness = readiness
        self.issues = issues
    }
}

public struct NightBriefingValidator: Sendable {
    public init() {}

    public func validate(
        _ draft: NightBriefingDraft,
        context: NightBriefingContext = .init()
    ) -> BriefingValidationReport {
        var issues: [BriefingValidationIssue] = []
        if draft.nightDate == nil {
            issues.append(.init(code: .missingDate, message: message(.missingDate, draft.language), blocksExport: true))
        }
        for target in draft.targets where target.end <= target.start {
            issues.append(.init(
                code: .invalidTargetWindow,
                message: message(.invalidTargetWindow, draft.language),
                blocksExport: true,
                targetID: target.id
            ))
        }
        if draft.site == nil {
            issues.append(.init(code: .missingSite, message: message(.missingSite, draft.language)))
        }
        if draft.setup == nil {
            issues.append(.init(code: .missingSetup, message: message(.missingSetup, draft.language)))
        }
        if case .missing = draft.weather {
            issues.append(.init(code: .missingWeather, message: message(.missingWeather, draft.language)))
        } else if case let .known(weather) = draft.weather, weather.updatedAt == nil {
            issues.append(.init(code: .weatherFreshnessUnknown, message: message(.weatherFreshnessUnknown, draft.language)))
        }
        if !draft.targets.contains(where: { $0.role == .primary }) {
            issues.append(.init(code: .missingPrimaryTarget, message: message(.missingPrimaryTarget, draft.language)))
        }
        if hasOverlap(draft.targets.filter { $0.end > $0.start }) {
            issues.append(.init(code: .overlappingTargets, message: message(.overlappingTargets, draft.language)))
        }
        if draft.targets.contains(where: { $0.role == .primary && $0.capturePlan.integrationSeconds == nil }) {
            issues.append(.init(code: .missingCapturePlan, message: message(.missingCapturePlan, draft.language)))
        }
        if let departure = draft.departure, draft.targets.contains(where: { $0.end > departure }) {
            issues.append(.init(code: .departureBeforeTargetEnd, message: message(.departureBeforeTargetEnd, draft.language)))
        }
        if draft.targets.contains(where: { target in
            guard let start = target.astronomicalStart, let end = target.astronomicalEnd else { return false }
            return target.start < start || target.end > end
        }) {
            issues.append(.init(code: .targetOutsideDarkness, message: message(.targetOutsideDarkness, draft.language)))
        }
        if case .missing = context.sky, !draft.targets.isEmpty {
            issues.append(.init(code: .missingSkyContext, message: message(.missingSkyContext, draft.language)))
        }
        if !context.calibrationGaps.isEmpty {
            issues.append(.init(code: .calibrationGap, message: message(.calibrationGap, draft.language)))
        }

        let incompleteCodes: Set<BriefingValidationCode> = [
            .missingDate, .invalidTargetWindow, .missingSite, .missingSetup, .missingWeather, .missingPrimaryTarget,
        ]
        let readiness: BriefingReadiness
        if issues.contains(where: { incompleteCodes.contains($0.code) }) {
            readiness = .incomplete
        } else if issues.isEmpty {
            readiness = .ready
        } else {
            readiness = .attention
        }
        return BriefingValidationReport(readiness: readiness, issues: issues)
    }

    private func hasOverlap(_ targets: [BriefingTargetBlock]) -> Bool {
        let sorted = targets.sorted { $0.start < $1.start }
        return zip(sorted, sorted.dropFirst()).contains { $0.end > $1.start }
    }

    private func message(_ code: BriefingValidationCode, _ language: BriefingDocumentLanguage) -> String {
        switch (language, code) {
        case (.hu, .missingDate): "Válassz dátumot az estéhez."
        case (.hu, .invalidTargetWindow): "A célpont befejezése legyen később a kezdésnél."
        case (.hu, .missingSite): "A helyszín nincs megadva."
        case (.hu, .missingSetup): "A felszerelés nincs kiválasztva."
        case (.hu, .missingWeather): "Nincs időjárási adat; indulás előtt ellenőrizd az eget."
        case (.hu, .missingPrimaryTarget): "Még nincs elsődleges célpont."
        case (.hu, .overlappingTargets): "Két célpont tervezett ideje átfed."
        case (.hu, .missingCapturePlan): "A fő célpont capture-terve még nem teljes."
        case (.hu, .departureBeforeTargetEnd): "Egy célpont tervezett vége a hazautazás utánra esik."
        case (.hu, .targetOutsideDarkness): "Egy célpont blokkja túlnyúlik az ismert sötét időszakon."
        case (.hu, .weatherFreshnessUnknown): "Az időjárási adat ideje nem ismert; indulás előtt frissítsd az ellenőrzést."
        case (.hu, .missingSkyContext): "Nincs ellenőrzött égútadat ehhez a célponthoz."
        case (.hu, .calibrationGap): "A tervhez ismert kalibrációs hiány tartozik."
        case (.en, .missingDate): "Choose a date for the night."
        case (.en, .invalidTargetWindow): "A target must end after it starts."
        case (.en, .missingSite): "No observing site is selected."
        case (.en, .missingSetup): "No equipment setup is selected."
        case (.en, .missingWeather): "No weather data; check the sky before leaving."
        case (.en, .missingPrimaryTarget): "There is no primary target yet."
        case (.en, .overlappingTargets): "Two planned target windows overlap."
        case (.en, .missingCapturePlan): "The primary target's capture plan is not complete yet."
        case (.en, .departureBeforeTargetEnd): "A target is planned to end after your departure."
        case (.en, .targetOutsideDarkness): "A target block extends beyond the known dark window."
        case (.en, .weatherFreshnessUnknown): "The weather retrieval time is unknown; refresh your check before leaving."
        case (.en, .missingSkyContext): "There is no verified sky-path data for this target."
        case (.en, .calibrationGap): "The plan has a known calibration gap."
        }
    }
}
