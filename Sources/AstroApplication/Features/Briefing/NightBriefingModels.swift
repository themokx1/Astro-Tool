import Foundation

public enum BriefingDocumentLanguage: String, Codable, CaseIterable, Sendable {
    case hu
    case en
}

public enum BriefingDataState<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case known(Value)
    case missing(reason: String)
    case stale(Value, updatedAt: Date)
}

public enum BriefingTargetRole: String, Codable, CaseIterable, Sendable {
    case primary
    case backup
}

public struct BriefingSiteSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct BriefingSetupSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct BriefingWeatherSummary: Codable, Equatable, Sendable {
    public var summary: String
    public var source: String
    public var updatedAt: Date

    public init(summary: String, source: String, updatedAt: Date) {
        self.summary = summary
        self.source = source
        self.updatedAt = updatedAt
    }
}

public struct BriefingCapturePlan: Codable, Equatable, Sendable {
    public var filterName: String?
    public var exposureSeconds: Double?
    public var frameCount: Int?
    public var gain: Double?
    public var offset: Double?
    public var binning: Int?
    public var temperatureCelsius: Double?

    public init(
        filterName: String? = nil,
        exposureSeconds: Double? = nil,
        frameCount: Int? = nil,
        gain: Double? = nil,
        offset: Double? = nil,
        binning: Int? = nil,
        temperatureCelsius: Double? = nil
    ) {
        self.filterName = filterName
        self.exposureSeconds = exposureSeconds
        self.frameCount = frameCount
        self.gain = gain
        self.offset = offset
        self.binning = binning
        self.temperatureCelsius = temperatureCelsius
    }

    public var integrationSeconds: Double? {
        guard let exposureSeconds, let frameCount, exposureSeconds > 0, frameCount > 0 else { return nil }
        return exposureSeconds * Double(frameCount)
    }
}

public struct BriefingTargetBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var role: BriefingTargetRole
    public var start: Date
    public var end: Date
    public var astronomicalStart: Date?
    public var astronomicalEnd: Date?
    public var capturePlan: BriefingCapturePlan
    public var warnings: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        role: BriefingTargetRole,
        start: Date,
        end: Date,
        astronomicalStart: Date? = nil,
        astronomicalEnd: Date? = nil,
        capturePlan: BriefingCapturePlan = .init(),
        warnings: [String] = []
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.start = start
        self.end = end
        self.astronomicalStart = astronomicalStart
        self.astronomicalEnd = astronomicalEnd
        self.capturePlan = capturePlan
        self.warnings = warnings
    }
}

public struct BriefingChecklistItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var explanation: String?
    public var isVisible: Bool
    public var isBuiltIn: Bool

    public init(id: String, title: String, explanation: String? = nil, isVisible: Bool = true, isBuiltIn: Bool = true) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.isVisible = isVisible
        self.isBuiltIn = isBuiltIn
    }
}

public struct BriefingChecklistSection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var items: [BriefingChecklistItem]

    public init(id: String, title: String, items: [BriefingChecklistItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct NightBriefingDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var revision: Int
    public var savedAt: Date
    public var nightDate: Date?
    public var arrival: Date?
    public var departure: Date?
    public var site: BriefingSiteSummary?
    public var setup: BriefingSetupSummary?
    public var powerRuntimeHours: Double?
    public var weather: BriefingDataState<BriefingWeatherSummary>
    public var targets: [BriefingTargetBlock]
    public var checklist: [BriefingChecklistSection]
    public var notes: String
    public var language: BriefingDocumentLanguage

    public init(
        id: UUID = UUID(),
        revision: Int = 0,
        savedAt: Date,
        nightDate: Date? = nil,
        arrival: Date? = nil,
        departure: Date? = nil,
        site: BriefingSiteSummary? = nil,
        setup: BriefingSetupSummary? = nil,
        powerRuntimeHours: Double? = nil,
        weather: BriefingDataState<BriefingWeatherSummary> = .missing(reason: "No weather data"),
        targets: [BriefingTargetBlock] = [],
        checklist: [BriefingChecklistSection] = [],
        notes: String = "",
        language: BriefingDocumentLanguage = .hu
    ) {
        self.id = id
        self.revision = revision
        self.savedAt = savedAt
        self.nightDate = nightDate
        self.arrival = arrival
        self.departure = departure
        self.site = site
        self.setup = setup
        self.powerRuntimeHours = powerRuntimeHours
        self.weather = weather
        self.targets = targets
        self.checklist = checklist
        self.notes = notes
        self.language = language
    }
}

public enum BriefingReadiness: String, Codable, Sendable {
    case ready
    case attention
    case incomplete
}

public struct NightBriefingDocument: Codable, Equatable, Sendable {
    public let draft: NightBriefingDraft
    public let readiness: BriefingReadiness
    public let issues: [BriefingValidationIssue]
    public let contingencies: [BriefingContingency]

    public init(
        draft: NightBriefingDraft,
        readiness: BriefingReadiness,
        issues: [BriefingValidationIssue],
        contingencies: [BriefingContingency] = []
    ) {
        self.draft = draft
        self.readiness = readiness
        self.issues = issues
        self.contingencies = contingencies
    }
}

public struct BriefingContingency: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var action: String

    public init(id: String, title: String, action: String) {
        self.id = id
        self.title = title
        self.action = action
    }
}
