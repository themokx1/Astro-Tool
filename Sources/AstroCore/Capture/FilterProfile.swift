import Foundation

/// One reusable, library-scoped filter from the user's own equipment
/// inventory. Capture groups copy these values as a historical snapshot;
/// they deliberately do not hold a foreign key to this editable row.
public struct FilterProfileRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64?
    public var manufacturer: String?
    public var model: String?
    public var name: String?
    public var signalMode: SignalMode
    public var notes: String?
    public var createdAt: Double
    public var updatedAt: Double

    public init(
        id: Int64? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        name: String? = nil,
        signalMode: SignalMode = .unknown,
        notes: String? = nil,
        createdAt: Double = 0,
        updatedAt: Double = 0
    ) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.name = name
        self.signalMode = signalMode
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayLabel: String {
        CaptureFilterLabel.make(manufacturer: manufacturer, model: model, name: name)
            ?? "Névtelen szűrő"
    }

    public var identityKey: String {
        CaptureFilterLabel.normalized(displayLabel)
    }
}
public enum FilterProfileValidator {
    public static func validate(_ record: FilterProfileRecord) throws {
        guard CaptureFilterLabel.make(
            manufacturer: record.manufacturer,
            model: record.model,
            name: record.name
        ) != nil else {
            throw AstroError.invalidInput("Adj meg legalább gyártót, modellt vagy saját szűrőnevet.")
        }
    }

    public static func prepared(_ record: FilterProfileRecord) throws -> FilterProfileRecord {
        var copy = record
        copy.manufacturer = nonBlank(copy.manufacturer)
        copy.model = nonBlank(copy.model)
        copy.name = nonBlank(copy.name)
        copy.notes = nonBlank(copy.notes)
        try validate(copy)
        return copy
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
