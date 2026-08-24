import Darwin
import Foundation
import AstroMobileDomain

/// App-owned durable metadata boundary for the cumulative return ledger.
/// It intentionally contains no package keys or document contents.
public final class MobileChangeReceiptStore: MobileChangeApplicationRecordStore, @unchecked Sendable {
    private static let processLock = NSLock()
    private static let maximumEncodedBytes = 1_048_576
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> MobileChangeApplicationLedger? {
        Self.processLock.lock()
        lock.lock()
        defer { lock.unlock(); Self.processLock.unlock() }
        return try withFileLock { try loadUnlocked() }
    }

    public func updateLedger(
        _ mutation: (MobileChangeApplicationLedger?) throws -> MobileChangeApplicationLedger?
    ) throws {
        Self.processLock.lock()
        lock.lock()
        defer { lock.unlock(); Self.processLock.unlock() }
        try withFileLock {
            let next = try mutation(loadUnlocked())
            if let next { try saveUnlocked(next) }
        }
    }

    private func loadUnlocked() throws -> MobileChangeApplicationLedger? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
        guard !data.isEmpty, data.count <= Self.maximumEncodedBytes else { throw MobileChangeImportError.receiptFailed }
        do {
            return try MobileJSON.decoder.decode(MobileChangeApplicationLedger.self, from: data)
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    public func save(_ ledger: MobileChangeApplicationLedger) throws {
        Self.processLock.lock()
        lock.lock()
        defer { lock.unlock(); Self.processLock.unlock() }
        try withFileLock { try saveUnlocked(ledger) }
    }

    private func saveUnlocked(_ ledger: MobileChangeApplicationLedger) throws {
        let data = try MobileJSON.encoder.encode(ledger)
        guard data.count <= Self.maximumEncodedBytes else { throw MobileChangeImportError.limitsExceeded }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    /// `NSLock` protects cooperating windows in one process; the advisory
    /// sidecar lock also serializes independently launched Mac processes.
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
}
