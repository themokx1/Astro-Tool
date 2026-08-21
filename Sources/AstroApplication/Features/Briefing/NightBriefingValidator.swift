import Foundation

public enum BriefingValidationCode: String, Codable, Sendable {
    case missingDate
    case invalidTargetWindow
    case missingSite
    case missingSetup
    case missingWeather
    case missingPrimaryTarget
    case overlappingTargets
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

    public func validate(_ draft: NightBriefingDraft) -> BriefingValidationReport {
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
        }
        if !draft.targets.contains(where: { $0.role == .primary }) {
            issues.append(.init(code: .missingPrimaryTarget, message: message(.missingPrimaryTarget, draft.language)))
        }
        if hasOverlap(draft.targets.filter { $0.end > $0.start }) {
            issues.append(.init(code: .overlappingTargets, message: message(.overlappingTargets, draft.language)))
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
        case (.en, .missingDate): "Choose a date for the night."
        case (.en, .invalidTargetWindow): "A target must end after it starts."
        case (.en, .missingSite): "No observing site is selected."
        case (.en, .missingSetup): "No equipment setup is selected."
        case (.en, .missingWeather): "No weather data; check the sky before leaving."
        case (.en, .missingPrimaryTarget): "There is no primary target yet."
        case (.en, .overlappingTargets): "Two planned target windows overlap."
        }
    }
}
