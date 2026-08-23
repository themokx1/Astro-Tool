import Foundation

public enum MobileChange: Codable, Equatable, Sendable {
    case checklistCompletion(ChecklistCompletionChange)
    case noteRevision(NoteRevisionChange)

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .checklistCompletion(let change):
            try container.encode(MobileChangeKind.checklistCompletion, forKey: .kind)
            try container.encode(change, forKey: .payload)
        case .noteRevision(let change):
            try container.encode(MobileChangeKind.noteRevision, forKey: .kind)
            try container.encode(change, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(MobileChangeKind.self, forKey: .kind)
        switch kind {
        case .checklistCompletion:
            self = .checklistCompletion(try container.decode(ChecklistCompletionChange.self, forKey: .payload))
        case .noteRevision:
            self = .noteRevision(try container.decode(NoteRevisionChange.self, forKey: .payload))
        }
    }
}

public enum MobileChangeKind: String, Codable, CaseIterable, Sendable {
    case checklistCompletion
    case noteRevision
}

public struct ChecklistCompletionChange: Codable, Equatable, Sendable {
    public let changeID: UUID
    public let deviceID: UUID
    public let briefingID: UUID
    public let itemID: String
    public let baseRevision: Int
    public let isCompleted: Bool
    public let createdAt: Date

    public init(
        changeID: UUID,
        deviceID: UUID,
        briefingID: UUID,
        itemID: String,
        baseRevision: Int,
        isCompleted: Bool,
        createdAt: Date
    ) {
        self.changeID = changeID
        self.deviceID = deviceID
        self.briefingID = briefingID
        self.itemID = itemID
        self.baseRevision = baseRevision
        self.isCompleted = isCompleted
        self.createdAt = createdAt
    }
}

public struct NoteRevisionChange: Codable, Equatable, Sendable {
    public let changeID: UUID
    public let deviceID: UUID
    public let noteID: String
    public let ownerID: String
    public let baseRevision: Int
    public let text: String
    public let createdAt: Date

    public init(
        changeID: UUID,
        deviceID: UUID,
        noteID: String,
        ownerID: String,
        baseRevision: Int,
        text: String,
        createdAt: Date
    ) {
        self.changeID = changeID
        self.deviceID = deviceID
        self.noteID = noteID
        self.ownerID = ownerID
        self.baseRevision = baseRevision
        self.text = text
        self.createdAt = createdAt
    }
}
