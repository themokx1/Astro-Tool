import Foundation
import AstroMobileDomain

/// Opaque reservation held from export preflight until the package has been
/// published and its sent-base evidence has been persisted. A newer window
/// cannot allocate a revision for the same library during that interval.
public struct MobileSnapshotPublicationReservation: Sendable {
    fileprivate let fileKey: String
    fileprivate let id: UUID
    public let revision: Int

    fileprivate init(fileKey: String, id: UUID, revision: Int) {
        self.fileKey = fileKey
        self.id = id
        self.revision = revision
    }
}

/// The forward snapshot revision is app-owned durable state, not a hash of
/// mutable content. Its process-wide coordinator treats allocation,
/// publication, and sent-base association as one ordered interval, preventing
/// an older window from publishing after a newer preview has been allocated.
public final class MobileSnapshotRevisionStore: @unchecked Sendable {
    private static let coordinator = MobileSnapshotRevisionCoordinator()
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL.standardizedFileURL }

    public func next() async throws -> Int {
        try await Self.coordinator.next(fileURL: fileURL)
    }

    public func current() async throws -> Int {
        try await Self.coordinator.current(fileURL: fileURL)
    }

    /// Reserves the current preview revision for publication. Call
    /// `finishPublication(_:published:)` after the encrypted package and its
    /// sent-base record have either both completed or failed.
    public func beginPublication(expectedRevision: Int) async throws -> MobileSnapshotPublicationReservation {
        try await Self.coordinator.beginPublication(fileURL: fileURL, expectedRevision: expectedRevision)
    }

    public func finishPublication(_ reservation: MobileSnapshotPublicationReservation, published: Bool) async {
        await Self.coordinator.finishPublication(reservation, published: published)
    }
}

private actor MobileSnapshotRevisionCoordinator {
    private struct Payload: Codable { let schemaVersion: Int; let revision: Int }
    private let maximumRevision = 1_000_000_000
    private var publications: [String: UUID] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func next(fileURL: URL) async throws -> Int {
        let key = fileURL.path
        await waitUntilPublishFinishes(key: key)
        let previous = try currentUnlocked(fileURL: fileURL)
        guard previous < maximumRevision else { throw MobileChangeImportError.limitsExceeded }
        let next = previous + 1
        try persist(revision: next, fileURL: fileURL)
        return next
    }

    func current(fileURL: URL) throws -> Int {
        try currentUnlocked(fileURL: fileURL)
    }

    func beginPublication(fileURL: URL, expectedRevision: Int) async throws -> MobileSnapshotPublicationReservation {
        let key = fileURL.path
        await waitUntilPublishFinishes(key: key)
        guard try currentUnlocked(fileURL: fileURL) == expectedRevision else {
            throw MobileChangeImportError.stalePreview
        }
        let id = UUID()
        publications[key] = id
        return .init(fileKey: key, id: id, revision: expectedRevision)
    }

    func finishPublication(_ reservation: MobileSnapshotPublicationReservation, published: Bool) {
        guard publications[reservation.fileKey] == reservation.id else { return }
        // `published` is recorded by the caller's durable sent-base write;
        // releasing either outcome permits the next preview to continue.
        _ = published
        publications.removeValue(forKey: reservation.fileKey)
        let blocked = waiters.removeValue(forKey: reservation.fileKey) ?? []
        blocked.forEach { $0.resume() }
    }

    private func waitUntilPublishFinishes(key: String) async {
        while publications[key] != nil {
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }
    }

    private func currentUnlocked(fileURL: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        do {
            let payload = try MobileJSON.decoder.decode(Payload.self, from: Data(contentsOf: fileURL))
            guard payload.schemaVersion == 1, payload.revision >= 0, payload.revision <= maximumRevision else {
                throw MobileChangeImportError.receiptFailed
            }
            return payload.revision
        } catch let error as MobileChangeImportError { throw error }
        catch { throw MobileChangeImportError.receiptFailed }
    }

    private func persist(revision: Int, fileURL: URL) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try MobileJSON.encoder.encode(Payload(schemaVersion: 1, revision: revision))
            try data.write(to: fileURL, options: [.atomic])
        } catch let error as MobileChangeImportError { throw error }
        catch { throw MobileChangeImportError.receiptFailed }
    }
}
