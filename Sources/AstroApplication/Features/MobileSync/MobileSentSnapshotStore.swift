import Foundation
import AstroMobileDomain

/// Persists the exact forward snapshot identity that authorizes a later
/// phone return package. It is deliberately separate from the package
/// envelope and contains no key material.
public protocol MobileSentSnapshotStore: Sendable {
    func load() throws -> [UUID]
    func save(snapshotID: UUID) throws
}

public final class MobileSentSnapshotIdentityStore: MobileSentSnapshotStore, @unchecked Sendable {
    private static let maximumBases = 128
    private struct Payload: Codable, Sendable {
        let schemaVersion: Int
        let snapshotIDs: [UUID]

        enum CodingKeys: String, CodingKey { case schemaVersion, snapshotIDs, snapshotID }
        init(schemaVersion: Int, snapshotIDs: [UUID]) {
            self.schemaVersion = schemaVersion
            self.snapshotIDs = snapshotIDs
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            if let ids = try values.decodeIfPresent([UUID].self, forKey: .snapshotIDs) {
                snapshotIDs = ids
            } else if let id = try values.decodeIfPresent(UUID.self, forKey: .snapshotID) {
                snapshotIDs = [id]
            } else {
                snapshotIDs = []
            }
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(schemaVersion, forKey: .schemaVersion)
            try values.encode(snapshotIDs, forKey: .snapshotIDs)
        }
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { throw MobileChangeImportError.receiptFailed }
            let payload = try MobileJSON.decoder.decode(Payload.self, from: data)
            guard payload.schemaVersion == 1 else { throw MobileChangeImportError.receiptFailed }
            guard payload.snapshotIDs.count <= Self.maximumBases else { throw MobileChangeImportError.limitsExceeded }
            return payload.snapshotIDs
        } catch let error as MobileChangeImportError {
            throw error
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    public func save(snapshotID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            var ids = try loadUnlocked()
            ids.removeAll { $0 == snapshotID }
            guard ids.count < Self.maximumBases else { throw MobileChangeImportError.limitsExceeded }
            ids.append(snapshotID)
            let data = try MobileJSON.encoder.encode(Payload(schemaVersion: 1, snapshotIDs: ids))
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch let error as MobileChangeImportError {
            throw error
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    private func loadUnlocked() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let payload = try MobileJSON.decoder.decode(Payload.self, from: Data(contentsOf: fileURL))
            guard payload.schemaVersion == 1 else { throw MobileChangeImportError.receiptFailed }
            guard payload.snapshotIDs.count <= Self.maximumBases else { throw MobileChangeImportError.limitsExceeded }
            return payload.snapshotIDs
        } catch let error as MobileChangeImportError { throw error }
        catch { throw MobileChangeImportError.receiptFailed }
    }
}
