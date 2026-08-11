import Foundation

public struct LibraryMutationPlan: Codable, Equatable, Sendable, Identifiable {
    public struct Entry: Codable, Equatable, Sendable {
        public let source: URL
        public let destination: URL
        public let fingerprint: String

        public init(source: URL, destination: URL, fingerprint: String) {
            self.source = source
            self.destination = destination
            self.fingerprint = fingerprint
        }
    }

    public let id: UUID
    public let libraryID: LibraryIdentity
    public let revision: UInt64
    public let entries: [Entry]
    public let totalBytes: Int64
    public let confirmationToken: String

    public init(
        id: UUID = UUID(),
        libraryID: LibraryIdentity,
        revision: UInt64,
        entries: [Entry],
        totalBytes: Int64,
        confirmationToken: String
    ) {
        self.id = id
        self.libraryID = libraryID
        self.revision = revision
        self.entries = entries
        self.totalBytes = totalBytes
        self.confirmationToken = confirmationToken
    }
}

public struct MutationReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let planID: UUID
    public let libraryID: LibraryIdentity
    public let revision: UInt64
    public let entries: [LibraryMutationPlan.Entry]
    public let totalBytes: Int64
    public let appliedAt: Date

    public init(
        id: UUID = UUID(),
        planID: UUID,
        libraryID: LibraryIdentity,
        revision: UInt64,
        entries: [LibraryMutationPlan.Entry],
        totalBytes: Int64,
        appliedAt: Date = Date()
    ) {
        self.id = id
        self.planID = planID
        self.libraryID = libraryID
        self.revision = revision
        self.entries = entries
        self.totalBytes = totalBytes
        self.appliedAt = appliedAt
    }
}
