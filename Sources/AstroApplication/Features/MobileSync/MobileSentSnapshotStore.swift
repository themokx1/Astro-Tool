import Foundation
import AstroMobileDomain

/// Persists the exact forward snapshot identity that authorizes a later
/// phone return package. It is deliberately separate from the package
/// envelope and contains no key material.
public protocol MobileSentSnapshotStore: Sendable {
    func load() throws -> [UUID]
    func save(snapshotID: UUID) throws
}

/// Records the exact acknowledgement set carried by a published forward
/// snapshot. A return package based on that snapshot is authenticated evidence
/// that the phone received it; only then may acknowledgement storage be pruned.
public struct MobileSentSnapshotRecord: Codable, Equatable, Sendable {
    public let snapshotID: UUID
    public let acknowledgementIDs: [UUID]

    public init(snapshotID: UUID, acknowledgementIDs: [UUID]) {
        self.snapshotID = snapshotID
        self.acknowledgementIDs = Array(Set(acknowledgementIDs)).sorted { $0.uuidString < $1.uuidString }
    }
}

public protocol MobileSentSnapshotAcknowledgementStore: MobileSentSnapshotStore {
    func loadRecords() throws -> [MobileSentSnapshotRecord]
    func save(snapshotID: UUID, acknowledgementIDs: [UUID]) throws
}

public final class MobileSentSnapshotIdentityStore: MobileSentSnapshotAcknowledgementStore, @unchecked Sendable {
    private static let maximumBases = 128
    /// Independent scene stores can point to the same history file. Serialize
    /// their read-modify-write cycles so a new published base cannot erase a
    /// concurrent window's base within this application process.
    private static let processLock = NSLock()
    private struct Payload: Codable, Sendable {
        let schemaVersion: Int
        let snapshotIDs: [UUID]
        let records: [MobileSentSnapshotRecord]

        enum CodingKeys: String, CodingKey { case schemaVersion, snapshotIDs, snapshotID, records }
        init(schemaVersion: Int, records: [MobileSentSnapshotRecord]) {
            self.schemaVersion = schemaVersion
            self.records = records
            self.snapshotIDs = records.map(\.snapshotID)
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            if let decoded = try values.decodeIfPresent([MobileSentSnapshotRecord].self, forKey: .records) {
                records = decoded
                snapshotIDs = decoded.map(\.snapshotID)
            } else if let ids = try values.decodeIfPresent([UUID].self, forKey: .snapshotIDs) {
                records = ids.map { .init(snapshotID: $0, acknowledgementIDs: []) }
                snapshotIDs = ids
            } else if let id = try values.decodeIfPresent(UUID.self, forKey: .snapshotID) {
                records = [.init(snapshotID: id, acknowledgementIDs: [])]
                snapshotIDs = [id]
            } else {
                records = []
                snapshotIDs = []
            }
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(schemaVersion, forKey: .schemaVersion)
            try values.encode(records, forKey: .records)
        }
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [UUID] {
        try loadRecords().map(\.snapshotID)
    }

    public func loadRecords() throws -> [MobileSentSnapshotRecord] {
        Self.processLock.lock()
        lock.lock()
        defer {
            lock.unlock()
            Self.processLock.unlock()
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { throw MobileChangeImportError.receiptFailed }
            let payload = try MobileJSON.decoder.decode(Payload.self, from: data)
            guard payload.schemaVersion == 1 else { throw MobileChangeImportError.receiptFailed }
            guard payload.records.count <= Self.maximumBases,
                  Set(payload.records.map(\.snapshotID)).count == payload.records.count,
                  payload.records.allSatisfy({ $0.acknowledgementIDs.count <= 10_000 }) else { throw MobileChangeImportError.limitsExceeded }
            return payload.records
        } catch let error as MobileChangeImportError {
            throw error
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    public func save(snapshotID: UUID) throws {
        try save(snapshotID: snapshotID, acknowledgementIDs: [])
    }

    public func save(snapshotID: UUID, acknowledgementIDs: [UUID]) throws {
        Self.processLock.lock()
        lock.lock()
        defer {
            lock.unlock()
            Self.processLock.unlock()
        }
        do {
            var records = try loadRecordsUnlocked()
            records.removeAll { $0.snapshotID == snapshotID }
            guard records.count < Self.maximumBases, Set(acknowledgementIDs).count == acknowledgementIDs.count, acknowledgementIDs.count <= 10_000 else { throw MobileChangeImportError.limitsExceeded }
            records.append(.init(snapshotID: snapshotID, acknowledgementIDs: acknowledgementIDs))
            let data = try MobileJSON.encoder.encode(Payload(schemaVersion: 1, records: records))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch let error as MobileChangeImportError {
            throw error
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    private func loadRecordsUnlocked() throws -> [MobileSentSnapshotRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let payload = try MobileJSON.decoder.decode(Payload.self, from: Data(contentsOf: fileURL))
            guard payload.schemaVersion == 1 else { throw MobileChangeImportError.receiptFailed }
            guard payload.records.count <= Self.maximumBases,
                  Set(payload.records.map(\.snapshotID)).count == payload.records.count,
                  payload.records.allSatisfy({ $0.acknowledgementIDs.count <= 10_000 }) else { throw MobileChangeImportError.limitsExceeded }
            return payload.records
        } catch let error as MobileChangeImportError { throw error }
        catch { throw MobileChangeImportError.receiptFailed }
    }
}
