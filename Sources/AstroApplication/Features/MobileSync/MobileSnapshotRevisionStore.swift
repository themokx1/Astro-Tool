import Foundation
import AstroMobileDomain

/// The forward snapshot revision is app-owned durable state, not a hash of
/// mutable content. It therefore remains monotonic across identical and
/// acknowledgement-only snapshots and survives relaunch.
public final class MobileSnapshotRevisionStore: @unchecked Sendable {
    private struct Payload: Codable { let schemaVersion: Int; let revision: Int }
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func next() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var previous = 0
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let payload = try MobileJSON.decoder.decode(Payload.self, from: Data(contentsOf: fileURL))
                guard payload.schemaVersion == 1, payload.revision >= 0 else { throw MobileChangeImportError.receiptFailed }
                previous = payload.revision
            } catch let error as MobileChangeImportError { throw error }
            catch { throw MobileChangeImportError.receiptFailed }
        }
        guard previous < Int.max else { throw MobileChangeImportError.limitsExceeded }
        let next = previous + 1
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try MobileJSON.encoder.encode(Payload(schemaVersion: 1, revision: next))
            try data.write(to: fileURL, options: [.atomic])
            return next
        } catch let error as MobileChangeImportError { throw error }
        catch { throw MobileChangeImportError.receiptFailed }
    }

    public func current() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        do {
            let payload = try MobileJSON.decoder.decode(Payload.self, from: Data(contentsOf: fileURL))
            guard payload.schemaVersion == 1, payload.revision >= 0 else { throw MobileChangeImportError.receiptFailed }
            return payload.revision
        } catch let error as MobileChangeImportError { throw error }
        catch { throw MobileChangeImportError.receiptFailed }
    }
}
