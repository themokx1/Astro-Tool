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

public struct MobileForwardSnapshotPublication: Sendable {
    public let packageID: UUID
    public let createdAt: Date
    public let encryptedByteCount: Int64

    fileprivate init(packageID: UUID, createdAt: Date, encryptedByteCount: Int64) {
        self.packageID = packageID
        self.createdAt = createdAt
        self.encryptedByteCount = encryptedByteCount
    }
}

public actor MobileReturnApplicationCoordinator {
    package typealias CurrentSnapshotProvider = @Sendable () async throws -> MobileLibrarySnapshot

    private struct Session: Sendable {
        let package: MobileAuthenticatedReturnPackage
        let review: MobileChangeImportPreview
    }

    private let packageService: MobilePackageService
    private let importer: MobileChangeImporter
    private let sentBases: MobileSentSnapshotIdentityStore
    private let currentSnapshotProvider: CurrentSnapshotProvider
    private var sessions: [UUID: Session] = [:]

    package init(
        packageService: MobilePackageService,
        importer: MobileChangeImporter,
        sentBases: MobileSentSnapshotIdentityStore,
        currentSnapshotProvider: @escaping CurrentSnapshotProvider
    ) {
        self.packageService = packageService
        self.importer = importer
        self.sentBases = sentBases
        self.currentSnapshotProvider = currentSnapshotProvider
    }

    public init(rootURL: URL) throws {
        let packageService = MobilePackageService()
        let receiptStore = MobileChangeReceiptStore(
            fileURL: rootURL.appendingPathComponent(".astro-tool/mobile-change-ledger.json")
        )
        self.packageService = packageService
        self.importer = try MobileChangeImporter.production(rootURL: rootURL, recordStore: receiptStore)
        self.sentBases = MobileSentSnapshotIdentityStore(
            fileURL: rootURL.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json")
        )
        self.currentSnapshotProvider = Self.productionSnapshotProvider(rootURL: rootURL)
    }

    /// Package-only construction for hermetic tests. Production clients
    /// cannot substitute the service, importer, sent evidence, or receipt
    /// store selected by `init(rootURL:)`.
    package static func production(
        rootURL: URL,
        packageService: MobilePackageService,
        currentSnapshotProvider: @escaping CurrentSnapshotProvider
    ) throws -> MobileReturnApplicationCoordinator {
        let receiptStore = MobileChangeReceiptStore(
            fileURL: rootURL.appendingPathComponent(".astro-tool/mobile-change-ledger.json")
        )
        return MobileReturnApplicationCoordinator(
            packageService: packageService,
            importer: try MobileChangeImporter.production(rootURL: rootURL, recordStore: receiptStore),
            sentBases: MobileSentSnapshotIdentityStore(
                fileURL: rootURL.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json")
            ),
            currentSnapshotProvider: currentSnapshotProvider
        )
    }

    /// Authenticates the package, checks that its base is currently
    /// published, and creates a non-reusable review session. The opaque
    /// package capability never crosses this public boundary.
    public func preview(
        from source: URL,
        wrapping: MobilePackageKeyWrapping
    ) async throws -> MobileReturnApplicationReview {
        let currentSnapshot = try await currentSnapshotProvider()
        let authenticated = try await packageService.authenticatePreview(from: source, wrapping: wrapping)
        do {
            let package = try await packageService.authenticatedReturn(token: authenticated.token)
            guard let base = try sentBases.loadRecords().first(where: { $0.snapshotID == package.baseSnapshotID }) else {
                await packageService.discardAuthenticatedReturn(package)
                throw MobileChangeImportError.snapshotMismatch
            }
            let changePreview = try importer.preview(
                authenticatedReturn: package,
                expectedLibraryID: currentSnapshot.libraryID,
                expectedBaseSnapshotID: base.snapshotID,
                currentSnapshot: currentSnapshot
            )
            guard base.state == .published || (
                base.state == .claimed
                    && base.claimedPackageID == package.packageID
                    && base.claimedSourceFingerprint == changePreview.sourceFingerprint
            ) else {
                await packageService.discardAuthenticatedReturn(package)
                throw MobileChangeImportError.snapshotMismatch
            }
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
        let currentSnapshot = try await currentSnapshotProvider()
        let refreshed = try importer.preview(
            authenticatedReturn: livePackage,
            expectedLibraryID: currentSnapshot.libraryID,
            expectedBaseSnapshotID: livePackage.baseSnapshotID,
            currentSnapshot: currentSnapshot
        )
        guard refreshed == session.review else { throw MobileChangeImportError.stalePreview }
        let claimed = try sentBases.claimPublished(
            snapshotID: livePackage.baseSnapshotID,
            packageID: livePackage.packageID,
            sourceFingerprint: refreshed.sourceFingerprint
        )
        let receipt: MobileChangeApplicationReceipt
        do {
            receipt = try await importer.apply(
                preview: refreshed,
                authenticatedReturn: livePackage,
                currentSnapshot: currentSnapshot,
                resolutions: resolutions,
                confirmed: confirmed
            )
        } catch {
            // Releasing after a failed apply (including a `partialReceipt`
            // reported by the importer itself, e.g. a domain batch failure
            // partway through) is safe because global change-ID markers make
            // any replay idempotent: a retry of already-applied changes is a
            // no-op, so the base's mutual-exclusion job is over once
            // `importer.apply` has thrown, and the same package may still
            // re-claim it. Deliberately not done in `discard(_:)`, which can
            // run concurrently with an in-flight apply and must not disturb
            // that apply's exclusive claim.
            try? sentBases.releaseClaim(
                snapshotID: livePackage.baseSnapshotID,
                packageID: livePackage.packageID,
                sourceFingerprint: refreshed.sourceFingerprint
            )
            throw error
        }
        do {
            // The phone package itself proves the attached forward
            // acknowledgements were observed. Prune the latest root ledger
            // before consuming the package token, then retire the bound base.
            try importer.acknowledgePhoneEvidence(Set(claimed.acknowledgementIDs))
            try await packageService.commitAuthenticatedReturn(livePackage)
            try sentBases.consumeClaimed(
                snapshotID: livePackage.baseSnapshotID,
                packageID: livePackage.packageID,
                sourceFingerprint: refreshed.sourceFingerprint
            )
            sessions.removeValue(forKey: review.sessionID)
            return receipt
        } catch {
            // The domain batch is already atomically marked. Never imply it
            // rolled back because capability/evidence finalization failed.
            throw MobileChangeImportError.partialReceipt(receipt)
        }
    }

    public func discard(_ review: MobileReturnApplicationReview) async {
        guard let session = sessions.removeValue(forKey: review.sessionID) else { return }
        await packageService.discardAuthenticatedReturn(session.package)
    }

    /// Publishes a reviewed forward snapshot while keeping the envelope,
    /// acknowledgement ledger, revision lease, and sent-base evidence behind
    /// this root-bound boundary.
    public func publishForwardSnapshot(
        _ snapshot: MobileLibrarySnapshot,
        to destination: URL,
        wrapping: MobilePackageKeyWrapping
    ) async throws -> MobileForwardSnapshotPublication {
        let acknowledgementIDs = try importer.currentAcknowledgementIDs()
        let revisions = MobileSnapshotRevisionStore(
            fileURL: sentBases.fileURL.deletingLastPathComponent()
                .appendingPathComponent("mobile-snapshot-revision.json")
        )
        let reservation = try await revisions.beginPublication(expectedRevision: snapshot.revision)
        do {
            try sentBases.reserve(snapshotID: snapshot.snapshotID, acknowledgementIDs: acknowledgementIDs)
            let manifest = try await packageService.export(
                MobilePackageEnvelope(
                    snapshot: snapshot,
                    changes: [],
                    acknowledgedChangeIDs: acknowledgementIDs
                ),
                to: destination,
                wrapping: wrapping
            )
            try sentBases.markPublished(snapshotID: snapshot.snapshotID)
            await revisions.finishPublication(reservation, published: true)
            return .init(
                packageID: manifest.packageID,
                createdAt: manifest.createdAt,
                encryptedByteCount: manifest.encryptedByteCount
            )
        } catch {
            try? sentBases.cancelPending(snapshotID: snapshot.snapshotID)
            await revisions.finishPublication(reservation, published: false)
            throw error
        }
    }

    private nonisolated static func productionSnapshotProvider(rootURL: URL) -> CurrentSnapshotProvider {
        {
            let identity = try PortableLibraryIdentityStore().preview(root: rootURL)
            guard identity.alreadyExists else { throw MobileChangeImportError.libraryMismatch }
            let paths = try AppStoragePaths.production(
                libraryID: LibraryIdentity(rootURL: rootURL),
                libraryRoot: rootURL
            )
            let metadata = try MetadataStore(storagePaths: paths)
            let projects = try await metadata.projects()
            let nights = try await metadata.nights()
            var captures: [SeriesRecord] = []
            var totals: [UUID: Double] = [:]
            for night in nights {
                let series = try await metadata.series(nightID: night.id)
                captures.append(contentsOf: series)
                for capture in series {
                    let decisions = try await metadata.frameDecisions(seriesID: capture.id)
                    let usable = decisions.filter { !$0.logicallyExcluded && $0.verdict != .rejected }.count
                    totals[capture.id] = Double(usable) * capture.exposureSeconds
                }
            }
            var annotations: [ProjectAnnotationRecord] = []
            for project in projects {
                if let annotation = try await metadata.projectAnnotation(projectID: project.id) {
                    annotations.append(annotation)
                }
            }
            let briefings = try await NightBriefingRevisionStore(directory: paths.briefings).latestRevisions()
            let revision = try await MobileSnapshotRevisionStore(
                fileURL: rootURL.appendingPathComponent(".astro-tool/mobile-snapshot-revision.json")
            ).current()
            return try MobileSnapshotComposer().compose(
                input: .init(
                    libraryID: identity.proposedID,
                    revision: revision,
                    projects: projects,
                    nights: nights,
                    captures: captures,
                    annotations: annotations,
                    briefings: briefings,
                    integrationSecondsByCaptureID: totals
                ),
                now: Date()
            )
        }
    }
}
