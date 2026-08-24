import Foundation
import AstroMobileDomain

/// App-owned durable metadata boundary for the cumulative return ledger.
/// It intentionally contains no package keys or document contents.
public final class MobileChangeReceiptStore: MobileChangeApplicationRecordStore, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> MobileChangeApplicationLedger? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
        guard !data.isEmpty else { throw MobileChangeImportError.receiptFailed }
        do {
            return try MobileJSON.decoder.decode(MobileChangeApplicationLedger.self, from: data)
        } catch {
            throw MobileChangeImportError.receiptFailed
        }
    }

    public func save(_ ledger: MobileChangeApplicationLedger) throws {
        let data = try MobileJSON.encoder.encode(ledger)
        guard data.count <= 1_048_576 else { throw MobileChangeImportError.limitsExceeded }
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
