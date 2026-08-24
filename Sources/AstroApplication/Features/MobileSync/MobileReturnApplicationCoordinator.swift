import Foundation
import AstroMobileDomain
import AstroMobileTransport

/// The sole public application boundary for a Mac-side return package. It
/// retains the service-minted capability privately; callers receive a review
/// value that identifies a live coordinator session but contains no package
/// authority or mutation closure.
public struct MobileReturnApplicationReview: Sendable {
    public let packagePreview: MobilePackageImportPreview
    public let changePreview: MobileChangeImportPreview
    fileprivate let sessionID: UUID

    fileprivate init(
        packagePreview: MobilePackageImportPreview,
        changePreview: MobileChangeImportPreview,
        sessionID: UUID
    ) {
        self.packagePreview = packagePreview
        self.changePreview = changePreview
        self.sessionID = sessionID
    }
}

public actor MobileReturnApplicationCoordinator {
    private struct Session: Sendable {
        let package: MobileAuthenticatedReturnPackage
        let review: MobileChangeImportPreview
    }

    private let packageService: MobilePackageService
    private let importer: MobileChangeImporter
    private let sentBases: MobileSentSnapshotIdentityStore
    private var sessions: [UUID: Session] = [:]

    private init(
        packageService: MobilePackageService,
        importer: MobileChangeImporter,
        sentBases: MobileSentSnapshotIdentityStore
    ) {
        self.packageService = packageService
        self.importer = importer
        self.sentBases = sentBases
    }

    public static func production(
        rootURL: URL,
        packageService: MobilePackageService = MobilePackageService()
    ) throws -> MobileReturnApplicationCoordinator {
        let receiptStore = MobileChangeReceiptStore(
            fileURL: rootURL.appendingPathComponent(".astro-tool/mobile-change-ledger.json")
        )
        return MobileReturnApplicationCoordinator(
            packageService: packageService,
            importer: try MobileChangeImporter.production(rootURL: rootURL, recordStore: receiptStore),
            sentBases: MobileSentSnapshotIdentityStore(
                fileURL: rootURL.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json")
            )
        )
    }

    /// Authenticates the package, checks that its base is currently
    /// published, and creates a non-reusable review session. The opaque
    /// package capability never crosses this public boundary.
    public func preview(
        from source: URL,
        wrapping: MobilePackageKeyWrapping,
        currentSnapshot: MobileLibrarySnapshot
    ) async throws -> MobileReturnApplicationReview {
        let authenticated = try await packageService.authenticatePreview(from: source, wrapping: wrapping)
        do {
            let package = try await packageService.authenticatedReturn(token: authenticated.token)
            guard let base = try sentBases.loadPublishedRecords().first(where: { $0.snapshotID == package.baseSnapshotID }) else {
                await packageService.discardAuthenticatedReturn(package)
                throw MobileChangeImportError.snapshotMismatch
            }
            let changePreview = try importer.preview(
                authenticatedReturn: package,
                expectedLibraryID: currentSnapshot.libraryID,
                expectedBaseSnapshotID: base.snapshotID,
                currentSnapshot: currentSnapshot
            )
            let sessionID = UUID()
            sessions[sessionID] = .init(package: package, review: changePreview)
            return .init(packagePreview: authenticated.preview, changePreview: changePreview, sessionID: sessionID)
        } catch {
            await packageService.discardImportPreview(token: authenticated.token)
            throw error
        }
    }

    /// Re-borrows the live service capability immediately before applying.
    /// A copied review only works while this coordinator's private session is
    /// still live; discard, successful apply, or service consumption remove
    /// that session and fail closed.
    public func apply(
        _ review: MobileReturnApplicationReview,
        currentSnapshot: MobileLibrarySnapshot,
        resolutions: [UUID: MobileChangeResolution],
        confirmed: Bool
    ) async throws -> MobileChangeApplicationReceipt {
        guard let session = sessions[review.sessionID], session.review == review.changePreview else {
            throw MobileChangeImportError.stalePreview
        }
        let livePackage: MobileAuthenticatedReturnPackage
        do {
            livePackage = try await packageService.borrowLiveAuthenticatedReturn(session.package)
        } catch {
            sessions.removeValue(forKey: review.sessionID)
            throw MobileChangeImportError.stalePreview
        }
        let refreshed = try importer.preview(
            authenticatedReturn: livePackage,
            expectedLibraryID: currentSnapshot.libraryID,
            expectedBaseSnapshotID: livePackage.baseSnapshotID,
            currentSnapshot: currentSnapshot
        )
        guard refreshed == session.review else { throw MobileChangeImportError.stalePreview }
        let receipt = try await importer.apply(
            preview: refreshed,
            authenticatedReturn: livePackage,
            currentSnapshot: currentSnapshot,
            resolutions: resolutions,
            confirmed: confirmed
        )
        do {
            try await packageService.commitAuthenticatedReturn(livePackage)
            guard let published = try sentBases.loadPublishedRecords().first(where: { $0.snapshotID == livePackage.baseSnapshotID }) else {
                throw MobileChangeImportError.snapshotMismatch
            }
            try importer.acknowledgePhoneEvidence(Set(published.acknowledgementIDs))
            try sentBases.consumePublished(snapshotID: livePackage.baseSnapshotID)
            sessions.removeValue(forKey: review.sessionID)
            return receipt
        } catch {
            sessions.removeValue(forKey: review.sessionID)
            // The domain batch is already atomically marked. Never imply it
            // rolled back because capability/evidence finalization failed.
            throw MobileChangeImportError.partialReceipt(receipt)
        }
    }

    public func discard(_ review: MobileReturnApplicationReview) async {
        guard let session = sessions.removeValue(forKey: review.sessionID) else { return }
        await packageService.discardAuthenticatedReturn(session.package)
    }
}
