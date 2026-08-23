import Foundation

public struct PortableLibraryID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum MobileJSON {
    private static func iso8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter
    }

    private static func string(from date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let wholeSeconds = floor(seconds)
        let fraction = seconds - wholeSeconds
        let base = iso8601Formatter().string(from: Date(timeIntervalSince1970: wholeSeconds))
        let digits = String(
            format: "%.17f",
            locale: Locale(identifier: "en_US_POSIX"),
            fraction
        ).dropFirst(2)
        return base.replacingOccurrences(of: "Z", with: ".\(digits)Z")
    }

    private static func date(from value: String) -> Date? {
        guard let timeSeparator = value.firstIndex(of: "T"),
              let fractionSeparator = value[timeSeparator...].firstIndex(of: ".") else {
            return iso8601Formatter().date(from: value)
        }

        let timezoneStart = value[fractionSeparator...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        guard let timezoneStart else { return nil }
        let fractionStart = value.index(after: fractionSeparator)
        let fractionDigits = String(value[fractionStart..<timezoneStart])
        guard !fractionDigits.isEmpty, fractionDigits.allSatisfy(\.isNumber),
              let fraction = Double("0.\(fractionDigits)") else { return nil }

        var baseValue = value
        baseValue.removeSubrange(fractionSeparator..<timezoneStart)
        guard let baseDate = iso8601Formatter().date(from: baseValue) else { return nil }
        return Date(timeIntervalSince1970: baseDate.timeIntervalSince1970 + fraction)
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date with an optional fractional second"
                )
            }
            return date
        }
        return decoder
    }
}

public struct MobileLibrarySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let libraryID: PortableLibraryID
    public let snapshotID: UUID
    public let revision: Int
    public let createdAt: Date
    public let projects: [MobileProject]
    public let nights: [MobileNight]
    public let captures: [MobileCapture]
    public let briefings: [MobileBriefing]
    public let notes: [MobileNote]

    public init(
        schemaVersion: Int,
        libraryID: PortableLibraryID,
        snapshotID: UUID,
        revision: Int,
        createdAt: Date,
        projects: [MobileProject],
        nights: [MobileNight],
        captures: [MobileCapture],
        briefings: [MobileBriefing],
        notes: [MobileNote]
    ) {
        self.schemaVersion = schemaVersion
        self.libraryID = libraryID
        self.snapshotID = snapshotID
        self.revision = revision
        self.createdAt = createdAt
        self.projects = projects
        self.nights = nights
        self.captures = captures
        self.briefings = briefings
        self.notes = notes
    }
}

public struct MobileProject: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let catalogID: String
    public let phase: String
    public let integrationSeconds: Double
    public let goalHours: Double?

    public init(
        id: UUID,
        displayName: String,
        catalogID: String,
        phase: String,
        integrationSeconds: Double,
        goalHours: Double?
    ) {
        self.id = id
        self.displayName = displayName
        self.catalogID = catalogID
        self.phase = phase
        self.integrationSeconds = integrationSeconds
        self.goalHours = goalHours
    }
}

public struct MobileNight: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let localDate: String
    public let timeZoneID: String

    public init(id: UUID, localDate: String, timeZoneID: String) {
        self.id = id
        self.localDate = localDate
        self.timeZoneID = timeZoneID
    }
}

public struct MobileCapture: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let projectID: UUID
    public let nightID: UUID
    public let displayName: String
    public let filterName: String?
    public let exposureSeconds: Double
    public let integrationSeconds: Double

    public init(
        id: UUID,
        projectID: UUID,
        nightID: UUID,
        displayName: String,
        filterName: String?,
        exposureSeconds: Double,
        integrationSeconds: Double
    ) {
        self.id = id
        self.projectID = projectID
        self.nightID = nightID
        self.displayName = displayName
        self.filterName = filterName
        self.exposureSeconds = exposureSeconds
        self.integrationSeconds = integrationSeconds
    }
}

public struct MobileBriefingTarget: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let role: String
    public let start: Date
    public let end: Date
    public let warnings: [String]

    public init(
        id: UUID,
        name: String,
        role: String,
        start: Date,
        end: Date,
        warnings: [String] = []
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.start = start
        self.end = end
        self.warnings = warnings
    }
}

public struct MobileChecklistSection: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [MobileChecklistItem]

    public init(id: String, title: String, items: [MobileChecklistItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct MobileBriefing: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let revision: Int
    public let savedAt: Date
    public let nightDate: Date?
    public let readiness: String
    public let targets: [MobileBriefingTarget]
    public let checklist: [MobileChecklistSection]
    public let noteID: String

    public init(
        id: UUID,
        revision: Int,
        savedAt: Date,
        nightDate: Date?,
        readiness: String,
        targets: [MobileBriefingTarget],
        checklist: [MobileChecklistSection],
        noteID: String
    ) {
        self.id = id
        self.revision = revision
        self.savedAt = savedAt
        self.nightDate = nightDate
        self.readiness = readiness
        self.targets = targets
        self.checklist = checklist
        self.noteID = noteID
    }
}

public struct MobileChecklistItem: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let explanation: String?
    public let isCompleted: Bool
    public let baseRevision: Int

    public init(
        id: String,
        title: String,
        explanation: String?,
        isCompleted: Bool,
        baseRevision: Int
    ) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.isCompleted = isCompleted
        self.baseRevision = baseRevision
    }
}

public enum MobileNoteScope: String, Codable, Sendable {
    case briefing
    case project
    case night
}

public struct MobileNote: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let scope: MobileNoteScope
    public let ownerID: String
    public let text: String
    public let baseRevision: Int
    public let updatedAt: Date
    public let isEditableOnPhone: Bool

    public init(
        id: String,
        scope: MobileNoteScope,
        ownerID: String,
        text: String,
        baseRevision: Int,
        updatedAt: Date,
        isEditableOnPhone: Bool
    ) {
        self.id = id
        self.scope = scope
        self.ownerID = ownerID
        self.text = text
        self.baseRevision = baseRevision
        self.updatedAt = updatedAt
        self.isEditableOnPhone = isEditableOnPhone
    }
}
