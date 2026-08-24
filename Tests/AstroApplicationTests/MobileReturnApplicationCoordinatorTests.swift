import Foundation
import Testing
@testable import AstroApplication
@testable import AstroMobileDomain
@testable import AstroMobileTransport

@Suite("Mobile return application coordinator")
struct MobileReturnApplicationCoordinatorTests {
    @Test("discarded public review cannot apply a copied value")
    func discardedReviewCannotApplyCopiedValue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("return-coordinator-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let libraryID = PortableLibraryID(rawValue: UUID())
        let base = MobileLibrarySnapshot.empty(libraryID: libraryID)
        let service = MobilePackageService()
        let key = OneTimePackageKey()
        let source = root.appendingPathComponent("phone-return.astromobile", isDirectory: true)
        _ = try await service.export(
            MobilePackageEnvelope(purpose: .returnChanges, snapshot: base, baseSnapshotID: base.snapshotID, changes: [], acknowledgedChangeIDs: []),
            to: source,
            wrapping: key
        )
        let sent = MobileSentSnapshotIdentityStore(fileURL: root.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json"))
        try sent.reserve(snapshotID: base.snapshotID, acknowledgementIDs: [])
        try sent.markPublished(snapshotID: base.snapshotID)
        let coordinator = try MobileReturnApplicationCoordinator.production(rootURL: root, packageService: service)

        let review = try await coordinator.preview(from: source, wrapping: key, currentSnapshot: base)
        let copiedReview = review
        await coordinator.discard(review)
        await #expect(throws: MobileChangeImportError.stalePreview) {
            try await coordinator.apply(copiedReview, currentSnapshot: base, resolutions: [:], confirmed: true)
        }
    }
}

private extension MobileLibrarySnapshot {
    static func empty(libraryID: PortableLibraryID) -> MobileLibrarySnapshot {
        .init(
            schemaVersion: 1,
            libraryID: libraryID,
            snapshotID: UUID(),
            revision: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            projects: [], nights: [], captures: [], briefings: [], notes: []
        )
    }
}
