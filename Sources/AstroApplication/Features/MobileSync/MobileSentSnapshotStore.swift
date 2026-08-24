import Foundation
import AstroMobileDomain

/// Persists the exact forward snapshot identity that authorizes a later
/// phone return package. It is deliberately separate from the package
/// envelope and contains no key material.
public protocol MobileSentSnapshotStore: Sendable {
    func load() throws -> UUID?
    func save(snapshotID: UUID) throws
}

public final class MobileSentSnapshotIdentityStore: MobileSentSnapshotStore, @unchecked Sendable {
    private struct Payload: Codable, Sendable {
        let schemaVersion: Int
        let snapshotID: UUID
    }

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { throw MobileChangeImportError.receiptFailed }
            let payload = try MobileJSON.decoder.decode(Payload.self, from: data)
            guard payload.schemaVersion == 1 else { throw MobileChangeImportError.receiptFailed }
            return payload.snapshotID
        } catch let error as MobileChangeImportError {
            throw error
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    public func save(snapshotID: UUID) throws {
        let data = try MobileJSON.encoder.encode(Payload(schemaVersion: 1, snapshotID: snapshotID))
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }
}
