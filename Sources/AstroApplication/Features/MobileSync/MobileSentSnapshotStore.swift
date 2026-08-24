import Darwin
import Foundation
import AstroMobileDomain

/// Persists the exact forward snapshot identity that authorizes a later
/// phone return package. It is deliberately separate from the package
/// envelope and contains no key material.
public protocol MobileSentSnapshotStore: Sendable {
    func load() throws -> [UUID]
    func save(snapshotID: UUID) throws
}

/// A forward package is not authorization until its exclusive file
/// publication has completed. Pending entries intentionally survive crashes:
/// they are recoverable evidence, but never authorize a return or consume one
/// of the published-base slots.
public enum MobileSentSnapshotPublicationState: String, Codable, Equatable, Sendable {
    case pending
    case published
}

public struct MobileSentSnapshotRecord: Codable, Equatable, Sendable {
    public let snapshotID: UUID
    public let acknowledgementIDs: [UUID]
    public let state: MobileSentSnapshotPublicationState

    public init(
        snapshotID: UUID,
        acknowledgementIDs: [UUID],
        state: MobileSentSnapshotPublicationState = .published
    ) {
        self.snapshotID = snapshotID
        self.acknowledgementIDs = Array(Set(acknowledgementIDs)).sorted { $0.uuidString < $1.uuidString }
        self.state = state
    }

    private enum CodingKeys: String, CodingKey { case snapshotID, acknowledgementIDs, state }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshotID = try values.decode(UUID.self, forKey: .snapshotID)
        acknowledgementIDs = Array(Set(try values.decodeIfPresent([UUID].self, forKey: .acknowledgementIDs) ?? []))
            .sorted { $0.uuidString < $1.uuidString }
        // Schema-1 history only contained successfully saved bases, so its
        // absence is unambiguously a published record.
        state = try values.decodeIfPresent(MobileSentSnapshotPublicationState.self, forKey: .state) ?? .published
    }
}

public protocol MobileSentSnapshotAcknowledgementStore: MobileSentSnapshotStore {
    func loadRecords() throws -> [MobileSentSnapshotRecord]
    func loadPublishedRecords() throws -> [MobileSentSnapshotRecord]
    func save(snapshotID: UUID, acknowledgementIDs: [UUID]) throws
    func reserve(snapshotID: UUID, acknowledgementIDs: [UUID]) throws
    func markPublished(snapshotID: UUID) throws
    func consumePublished(snapshotID: UUID) throws
}

public final class MobileSentSnapshotIdentityStore: MobileSentSnapshotAcknowledgementStore, @unchecked Sendable {
    private static let maximumPublishedBases = 128
    private static let maximumAcknowledgements = 10_000
    private static let maximumEncodedBytes = 1_048_576
    /// Independent scenes can use distinct store instances for this same
    /// file. Every operation reloads while holding this shared lock so there
    /// is no cached blind replacement between Mac windows.
    private static let processLock = NSLock()

    private struct Payload: Codable, Sendable {
        let schemaVersion: Int
        let records: [MobileSentSnapshotRecord]

        enum CodingKeys: String, CodingKey { case schemaVersion, snapshotIDs, snapshotID, records }

        init(records: [MobileSentSnapshotRecord]) {
            schemaVersion = 2
            self.records = records
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let version = try values.decode(Int.self, forKey: .schemaVersion)
            guard version == 1 || version == 2 else { throw MobileChangeImportError.receiptFailed }
            schemaVersion = version
            if let decoded = try values.decodeIfPresent([MobileSentSnapshotRecord].self, forKey: .records) {
                records = decoded
            } else if let ids = try values.decodeIfPresent([UUID].self, forKey: .snapshotIDs) {
                records = ids.map { .init(snapshotID: $0, acknowledgementIDs: [], state: .published) }
            } else if let id = try values.decodeIfPresent(UUID.self, forKey: .snapshotID) {
                records = [.init(snapshotID: id, acknowledgementIDs: [], state: .published)]
            } else {
                records = []
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(2, forKey: .schemaVersion)
            try values.encode(records, forKey: .records)
        }
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [UUID] {
        try loadPublishedRecords().map(\.snapshotID)
    }

    public func loadRecords() throws -> [MobileSentSnapshotRecord] {
        try withLockedRecords { $0 }
    }

    public func loadPublishedRecords() throws -> [MobileSentSnapshotRecord] {
        try withLockedRecords { records in
            records.filter { $0.state == .published }
        }
    }

    /// Compatibility operation for callers which publish the package and
    /// evidence in one known-complete step. New production publication uses
    /// reserve/markPublished around the physical package export instead.
    public func save(snapshotID: UUID) throws {
        try save(snapshotID: snapshotID, acknowledgementIDs: [])
    }

    public func save(snapshotID: UUID, acknowledgementIDs: [UUID]) throws {
        try mutate { records in
            try Self.validateAcknowledgements(acknowledgementIDs)
            records.removeAll { $0.snapshotID == snapshotID }
            guard records.filter({ $0.state == .published }).count < Self.maximumPublishedBases else {
                throw MobileChangeImportError.limitsExceeded
            }
            records.append(.init(snapshotID: snapshotID, acknowledgementIDs: acknowledgementIDs, state: .published))
        }
    }

    public func reserve(snapshotID: UUID, acknowledgementIDs: [UUID]) throws {
        try mutate { records in
            try Self.validateAcknowledgements(acknowledgementIDs)
            if let index = records.firstIndex(where: { $0.snapshotID == snapshotID }) {
                guard records[index].state == .pending else {
                    // A repeated post-publication reservation is idempotent
                    // only for identical durable evidence.
                    guard records[index].acknowledgementIDs == Self.normalized(acknowledgementIDs) else {
                        throw MobileChangeImportError.receiptFailed
                    }
                    return
                }
                records[index] = .init(snapshotID: snapshotID, acknowledgementIDs: acknowledgementIDs, state: .pending)
            } else {
                records.append(.init(snapshotID: snapshotID, acknowledgementIDs: acknowledgementIDs, state: .pending))
            }
        }
    }

    public func markPublished(snapshotID: UUID) throws {
        try mutate { records in
            guard let index = records.firstIndex(where: { $0.snapshotID == snapshotID }) else {
                throw MobileChangeImportError.receiptFailed
            }
            if records[index].state == .published { return }
            guard records.filter({ $0.state == .published }).count < Self.maximumPublishedBases else {
                throw MobileChangeImportError.limitsExceeded
            }
            records[index] = .init(
                snapshotID: records[index].snapshotID,
                acknowledgementIDs: records[index].acknowledgementIDs,
                state: .published
            )
        }
    }

    /// Consuming evidence after a fully authenticated return releases both
    /// the authorization base and exactly the acknowledgement set attached to
    /// it. Pending entries are deliberately untouched.
    public func consumePublished(snapshotID: UUID) throws {
        try mutate { records in
            records.removeAll { $0.snapshotID == snapshotID && $0.state == .published }
        }
    }

    private func mutate(_ body: (inout [MobileSentSnapshotRecord]) throws -> Void) throws {
        _ = try withLockedRecords { records in
            var next = records
            try body(&next)
            try Self.validate(next)
            try persist(next)
            return ()
        }
    }

    private func withLockedRecords<T>(_ body: ([MobileSentSnapshotRecord]) throws -> T) throws -> T {
        Self.processLock.lock()
        lock.lock()
        defer {
            lock.unlock()
            Self.processLock.unlock()
        }
        return try withFileLock { try body(loadRecordsUnlocked()) }
    }

    private func loadRecordsUnlocked() throws -> [MobileSentSnapshotRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty, data.count <= Self.maximumEncodedBytes else { throw MobileChangeImportError.receiptFailed }
            let records = try MobileJSON.decoder.decode(Payload.self, from: data).records
            try Self.validate(records)
            return records
        } catch let error as MobileChangeImportError {
            throw error
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    private func persist(_ records: [MobileSentSnapshotRecord]) throws {
        let data = try MobileJSON.encoder.encode(Payload(records: records))
        guard data.count <= Self.maximumEncodedBytes else { throw MobileChangeImportError.limitsExceeded }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    /// The sidecar advisory lock extends the reload/mutate/write critical
    /// section across separately launched AstroTool processes, while the
    /// in-process locks keep normal scene work cheap and deterministic.
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
        let lockPath = fileURL.appendingPathExtension("lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw MobileChangeImportError.receiptFailed
        }
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        return try body()
    }

    private static func normalized(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    private static func validateAcknowledgements(_ ids: [UUID]) throws {
        guard ids.count <= maximumAcknowledgements, Set(ids).count == ids.count else {
            throw MobileChangeImportError.limitsExceeded
        }
    }

    private static func validate(_ records: [MobileSentSnapshotRecord]) throws {
        guard Set(records.map(\.snapshotID)).count == records.count,
              records.filter({ $0.state == .published }).count <= maximumPublishedBases,
              records.allSatisfy({ $0.acknowledgementIDs.count <= maximumAcknowledgements && Set($0.acknowledgementIDs).count == $0.acknowledgementIDs.count })
        else { throw MobileChangeImportError.limitsExceeded }
    }
}
