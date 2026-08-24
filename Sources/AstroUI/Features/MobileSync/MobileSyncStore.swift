import Foundation
import Observation
import AstroApplication
import AstroMobileDomain
import AstroMobileTransport

public struct MobileSyncExportResult: Equatable, Sendable {
    public let packageID: UUID
    public let createdAt: Date
    public let encryptedByteCount: Int64?

    public init(packageID: UUID, createdAt: Date, encryptedByteCount: Int64? = nil) {
        self.packageID = packageID
        self.createdAt = createdAt
        self.encryptedByteCount = encryptedByteCount
    }
}

public struct MobileSyncPreview: Equatable, Sendable {
    public let identity: PortableIdentityPreview
    public let snapshot: MobileLibrarySnapshot
    public let snapshotSummary: MobileSnapshotSummary
    public let confirmationToken: MobileSyncConfirmationToken

    public init(
        identity: PortableIdentityPreview,
        snapshot: MobileLibrarySnapshot,
        snapshotSummary: MobileSnapshotSummary,
        confirmationToken: MobileSyncConfirmationToken
    ) {
        self.identity = identity
        self.snapshot = snapshot
        self.snapshotSummary = snapshotSummary
        self.confirmationToken = confirmationToken
    }
}

public struct MobileSyncConfirmationToken: Equatable, Sendable {
    public let snapshotID: UUID
    public let revision: Int
    public let createdAt: Date
    public let summary: MobileSnapshotSummary
    public let libraryID: PortableLibraryID

    public init(snapshotID: UUID, revision: Int, createdAt: Date, summary: MobileSnapshotSummary, libraryID: PortableLibraryID) {
        self.snapshotID = snapshotID
        self.revision = revision
        self.createdAt = createdAt
        self.summary = summary
        self.libraryID = libraryID
    }
}

public struct MobileChangeOutcomeTotals: Equatable, Sendable {
    public let applied: Int
    public let keptOnMac: Int
    public let superseded: Int
    public let alreadyHandled: Int
    public let duplicates: Int
    public let rejected: Int

    public init(applied: Int = 0, keptOnMac: Int = 0, superseded: Int = 0, alreadyHandled: Int = 0, duplicates: Int = 0, rejected: Int = 0) {
        self.applied = applied
        self.keptOnMac = keptOnMac
        self.superseded = superseded
        self.alreadyHandled = alreadyHandled
        self.duplicates = duplicates
        self.rejected = rejected
    }
}

public enum MobileSyncPhase: String, Equatable, Sendable {
    case idle
    case previewing
    case ready
    case exporting
    case finishing
    case exported
    case importing
    case importPreviewReady
    case applying
    case completed
    case discarding
    case failed
}

public enum MobileSyncFailure: Equatable, Sendable {
    case missingLibrary
    case identityMismatch
    case summaryMismatch
    case identityWriteFailed
    case exportFailed
    case destinationExists
    case importFailed
    case invalidKey
    case staleOperation
}

@MainActor
@Observable
public final class MobileSyncStore {
    package typealias IdentityPreview = @Sendable (URL) throws -> PortableIdentityPreview
    package typealias IdentityCommit = @Sendable (URL, PortableLibraryID) throws -> PortableLibraryID
    public typealias SnapshotProvider = @Sendable (URL, PortableLibraryID) async throws -> MobileLibrarySnapshot
    package typealias PackageExport = @Sendable (MobilePackageEnvelope, URL, OneTimePackageKey) async throws -> MobileSyncExportResult
    package typealias PackageImportPreview = @Sendable (URL, OneTimePackageKey) async throws -> MobilePackageImportPreview
    package typealias PackageAuthenticatePreview = @Sendable (URL, OneTimePackageKey) async throws -> MobilePackageAuthenticatedPreview
    package typealias PackageAuthenticatedReturn = @Sendable (MobilePackagePreviewToken) async throws -> MobileAuthenticatedReturnPackage
    package typealias PackageImportCommitReturn = @Sendable (MobileAuthenticatedReturnPackage) async throws -> Void
    package typealias PackageImportDiscardReturn = @Sendable (MobileAuthenticatedReturnPackage) async -> Void
    package typealias PackageImportDiscardCapability = @Sendable (MobilePackagePreviewToken) async -> Void
    package typealias PackageImportDiscard = @Sendable (UUID) async -> Void
    package typealias DestinationPreparation = @Sendable (URL) throws -> Void

    public private(set) var phase: MobileSyncPhase = .idle
    public private(set) var preview: MobileSyncPreview?
    public private(set) var incomingPreview: MobilePackageImportPreview?
    public private(set) var changePreview: MobileChangeImportPreview?
    public private(set) var changeResolutions: [UUID: MobileChangeResolution] = [:]
    public private(set) var appliedChangeReceipt: MobileChangeApplicationReceipt?
    public private(set) var exportedURL: URL?
    public private(set) var packageID: UUID?
    public private(set) var encryptedByteCount: Int64?
    public private(set) var exportedAt: Date?
    public private(set) var oneTimeQRPayload: String?
    public private(set) var errorMessage: String?
    public private(set) var failure: MobileSyncFailure?
    public private(set) var isIdentityConfirmed = false
    public private(set) var isSummaryConfirmed = false
    public private(set) var didApplyIncomingChanges = false
    public private(set) var appliedChangeTotals = MobileChangeOutcomeTotals()

    /// Disjoint outcome totals for the currently retained
    /// `appliedChangeReceipt`, reused by every view that renders that
    /// receipt so no call site duplicates the keptOnMac/superseded
    /// arithmetic. Unlike `appliedChangeTotals` (frozen at apply time),
    /// this recomputes against whatever `changePreview` the store still
    /// retains; if the preview has already been cleared, superseded,
    /// already-handled, duplicate, and rejected counts fall back to zero
    /// and keptOnMac reports the full resolved set.
    var receiptTotals: MobileChangeOutcomeTotals? {
        guard let appliedChangeReceipt else { return nil }
        guard let changePreview else {
            return MobileChangeOutcomeTotals(
                applied: appliedChangeReceipt.appliedChangeIDs.count,
                keptOnMac: appliedChangeReceipt.resolvedChangeIDs.count
            )
        }
        return Self.totals(receipt: appliedChangeReceipt, preview: changePreview)
    }

    public let rootURL: URL?
    public let destinationToken: String

    private let changeImporter: MobileChangeImporter?
    /// Normal application uses this opaque boundary. The legacy closures
    /// below remain only for hermetic UI fixtures, which have no production
    /// root and cannot mint a live package capability.
    private let returnCoordinator: MobileReturnApplicationCoordinator?
    private let productionMode: Bool

    private let identityPreview: IdentityPreview
    private let identityCommit: IdentityCommit
    private let snapshotProvider: SnapshotProvider
    private let packageExport: PackageExport
    private let packageImportPreview: PackageImportPreview
    private let packageAuthenticatePreview: PackageAuthenticatePreview
    private let packageAuthenticatedReturn: PackageAuthenticatedReturn
    private let packageImportCommitReturn: PackageImportCommitReturn
    private let packageImportDiscardReturn: PackageImportDiscardReturn
    private let packageImportDiscardCapability: PackageImportDiscardCapability
    private let usesLegacyImportPreview: Bool
    private let packageImportDiscard: PackageImportDiscard
    private let prepareDestination: DestinationPreparation
    private let sentSnapshotStore: MobileSentSnapshotStore?
    private let sentSnapshotLoadFailed: Bool
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cancellationRequested = false
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var discardTask: Task<Void, Never>?
    @ObservationIgnored private var incomingSource: URL?
    @ObservationIgnored private var incomingQRPayload: String?
    @ObservationIgnored private var incomingCapability: MobilePackagePreviewToken?
    @ObservationIgnored private var incomingReturn: MobileAuthenticatedReturnPackage?
    @ObservationIgnored private var incomingReview: MobileReturnApplicationReview?
    @ObservationIgnored private var sentBaseSnapshotIDs: Set<UUID> = []
    @ObservationIgnored private var sentBaseAcknowledgements: [UUID: Set<UUID>] = [:]

    /// Production construction accepts only the library root and the typed,
    /// read-only snapshot provider used by the already-open application
    /// model. Return authentication, sent-base evidence, domain commands and
    /// receipts are always selected from that root.
    public convenience init(
        rootURL: URL?,
        snapshotProvider: SnapshotProvider? = nil
    ) {
        self.init(rootURL: rootURL, snapshotProvider: snapshotProvider, productionMode: true, fixture: ())
    }

    /// Explicit package-only fixture construction. None of these dependency
    /// seams are visible to clients importing AstroUI as a product.
    package init(
        rootURL: URL?,
        identityPreview: IdentityPreview? = nil,
        identityCommit: IdentityCommit? = nil,
        snapshotProvider: SnapshotProvider? = nil,
        packageExport: PackageExport? = nil,
        packageImportPreview: PackageImportPreview? = nil,
        packageAuthenticatePreview: PackageAuthenticatePreview? = nil,
        packageAuthenticatedReturn: PackageAuthenticatedReturn? = nil,
        packageImportCommitReturn: PackageImportCommitReturn? = nil,
        packageImportDiscardReturn: PackageImportDiscardReturn? = nil,
        packageImportDiscardCapability: PackageImportDiscardCapability? = nil,
        packageImportDiscard: PackageImportDiscard? = nil,
        destinationToken: String = UUID().uuidString.lowercased(),
        prepareDestination: DestinationPreparation? = nil,
        packageService: MobilePackageService = MobilePackageService(),
        changeImporter: MobileChangeImporter? = nil,
        changeRecordStore: MobileChangeApplicationRecordStore? = nil,
        sentSnapshotStore: MobileSentSnapshotStore? = nil,
        productionMode: Bool = false,
        fixture: Void = ()
    ) {
        self.rootURL = rootURL
        self.destinationToken = destinationToken
        self.productionMode = productionMode
        let defaultLedgerStore = productionMode ? nil : (changeRecordStore ?? rootURL.map { MobileChangeReceiptStore(fileURL: $0.appendingPathComponent(".astro-tool/mobile-change-ledger.json")) })
        self.changeImporter = productionMode ? nil : (changeImporter ?? MobileChangeImporter(recordStore: defaultLedgerStore))
        self.returnCoordinator = productionMode ? rootURL.flatMap { try? MobileReturnApplicationCoordinator(rootURL: $0) } : nil
        let configuredSentSnapshotStore = productionMode ? nil : (sentSnapshotStore ?? rootURL.map { MobileSentSnapshotIdentityStore(fileURL: $0.appendingPathComponent(".astro-tool/mobile-sent-snapshot.json")) })
        self.sentSnapshotStore = configuredSentSnapshotStore
        do {
            if let acknowledgementStore = configuredSentSnapshotStore as? MobileSentSnapshotAcknowledgementStore {
                let loaded = try acknowledgementStore.loadPublishedRecords()
                self.sentBaseSnapshotIDs = Set(loaded.map(\.snapshotID))
                self.sentBaseAcknowledgements = Dictionary(uniqueKeysWithValues: loaded.map { ($0.snapshotID, Set($0.acknowledgementIDs)) })
            } else {
                let loaded = try configuredSentSnapshotStore?.load() ?? []
                self.sentBaseSnapshotIDs = Set(loaded)
                self.sentBaseAcknowledgements = Dictionary(uniqueKeysWithValues: loaded.map { ($0, []) })
            }
            self.sentSnapshotLoadFailed = false
        } catch {
            self.sentSnapshotLoadFailed = true
        }
        let identityStore = PortableLibraryIdentityStore()
        self.identityPreview = identityPreview ?? { root in try identityStore.preview(root: root) }
        self.identityCommit = identityCommit ?? { root, id in try identityStore.loadOrCreate(root: root, confirmedID: id) }
        self.snapshotProvider = snapshotProvider ?? MobileSyncStore.emptySnapshot
        self.prepareDestination = prepareDestination ?? { destination in
            try MobileSyncDestinationCoordinator.removePlaceholder(at: destination, token: destinationToken)
        }
        if let packageExport {
            self.packageExport = packageExport
        } else {
            self.packageExport = { envelope, destination, key in
                let manifest = try await packageService.export(envelope, to: destination, wrapping: key)
                return MobileSyncExportResult(packageID: manifest.packageID, createdAt: manifest.createdAt, encryptedByteCount: manifest.encryptedByteCount)
            }
        }
        if let packageImportPreview {
        self.packageImportPreview = packageImportPreview
            self.usesLegacyImportPreview = true
        } else {
            self.packageImportPreview = { source, key in
                try await packageService.importPreview(from: source, wrapping: key)
            }
            self.usesLegacyImportPreview = false
        }
        self.packageAuthenticatePreview = packageAuthenticatePreview ?? { source, key in try await packageService.authenticatePreview(from: source, wrapping: key) }
        self.packageAuthenticatedReturn = packageAuthenticatedReturn ?? { token in try await packageService.authenticatedReturn(token: token) }
        self.packageImportCommitReturn = packageImportCommitReturn ?? { package in try await packageService.commitAuthenticatedReturn(package) }
        self.packageImportDiscardReturn = packageImportDiscardReturn ?? { package in await packageService.discardAuthenticatedReturn(package) }
        self.packageImportDiscardCapability = packageImportDiscardCapability ?? { token in await packageService.discardImportPreview(token: token) }
        self.packageImportDiscard = packageImportDiscard ?? { _ in }
    }

    public var canExport: Bool {
        phase == .ready && isIdentityConfirmed && isSummaryConfirmed && preview != nil
    }

    public var isBusy: Bool {
        phase == .previewing || phase == .exporting || phase == .finishing || phase == .importing || phase == .applying || phase == .discarding
    }

    public func startPreview() {
        operationTask?.cancel()
        operationTask = Task { [weak self] in await self?.preview() }
    }

    public func startIncomingPreview(from source: URL, qrPayload: String) {
        operationTask?.cancel()
        let priorDiscard = discardTask
        operationTask = Task { [weak self] in
            await priorDiscard?.value
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            await self?.previewIncomingPackage(from: source, qrPayload: qrPayload)
        }
    }

    public func startExport(to destination: URL) {
        operationTask?.cancel()
        operationTask = Task { [weak self] in await self?.export(to: destination) }
    }

    public func startRetry() {
        operationTask?.cancel()
        operationTask = Task { [weak self] in await self?.retry() }
    }

    public func setChangeResolution(_ resolution: MobileChangeResolution, for changeID: UUID) {
        guard changePreview?.conflicts.contains(where: { $0.changeID == changeID }) == true else { return }
        changeResolutions[changeID] = resolution
    }

    /// Applies the authenticated return document retained by this store.
    /// Callers cannot supply an envelope, package UUID, or fingerprint as
    /// authority; all three come from the retained package capability.
    public func applyAuthenticatedReturnChanges(confirmed: Bool) async throws {
        guard let changePreview else { throw MobileChangeImportError.stalePreview }
        guard phase == .importPreviewReady else { throw MobileChangeImportError.stalePreview }
        generation += 1
        let operationGeneration = generation
        phase = .applying
        var completedReceipt: MobileChangeApplicationReceipt?
        do {
            let receipt: MobileChangeApplicationReceipt
            if let returnCoordinator, let incomingReview {
                // The coordinator owns the service-minted capability and
                // re-borrows it live just before committing the typed domain
                // batch. A copied/discarded UI value has no authority here.
                receipt = try await returnCoordinator.apply(
                    incomingReview,
                    resolutions: changeResolutions,
                    confirmed: confirmed
                )
            } else if let authenticatedReturn = incomingReturn,
                      let changeImporter,
                      let current = try await currentSnapshotForReturn() {
                receipt = try await changeImporter.apply(preview: changePreview, authenticatedReturn: authenticatedReturn, currentSnapshot: current, resolutions: changeResolutions, confirmed: confirmed)
            } else {
                throw MobileChangeImportError.stalePreview
            }
            completedReceipt = receipt
            guard generation == operationGeneration, phase == .applying else { throw MobileChangeImportError.stalePreview }
            if returnCoordinator == nil, let authenticatedReturn = incomingReturn {
                try await packageImportCommitReturn(authenticatedReturn)
            }
            guard generation == operationGeneration else { throw MobileChangeImportError.stalePreview }
            if returnCoordinator == nil, let authenticatedReturn = incomingReturn {
                try consumePublishedEvidence(for: authenticatedReturn.baseSnapshotID)
            }
            appliedChangeReceipt = receipt
            appliedChangeTotals = Self.totals(receipt: receipt, preview: changePreview)
            didApplyIncomingChanges = true
            incomingCapability = nil
            incomingReturn = nil
            incomingReview = nil
            incomingPreview = nil
            self.changePreview = nil
            changeResolutions = [:]
            incomingSource = nil
            incomingQRPayload = nil
            phase = .completed
        } catch {
            if let completedReceipt {
                // The domain batch has committed its own atomic change-ID
                // markers. A subsequent capability acknowledgement failure
                // must never claim that those reviewed edits were rolled back.
                appliedChangeReceipt = completedReceipt
                appliedChangeTotals = Self.totals(receipt: completedReceipt, preview: changePreview)
                errorMessage = String(localized: "The reviewed changes were saved, but package acknowledgement could not be finalized. Keep the phone package and create a fresh forward snapshot after recovery.")
            } else if case let MobileChangeImportError.partialReceipt(partial) = error {
                appliedChangeReceipt = partial
                appliedChangeTotals = Self.totals(receipt: partial, preview: changePreview)
                errorMessage = String(localized: "Some reviewed changes were saved before the receipt failed. Applied \(partial.appliedChangeIDs.count); resolved \(partial.resolvedChangeIDs.count). Keep the phone package and create a fresh forward snapshot after recovery.")
            }
            if let returnCoordinator, let incomingReview {
                await returnCoordinator.discard(incomingReview)
            } else if let authenticatedReturn = incomingReturn {
                await packageImportDiscardReturn(authenticatedReturn)
            }
            incomingCapability = nil
            incomingReturn = nil
            incomingReview = nil
            incomingPreview = nil
            failure = .importFailed
            if completedReceipt != nil {
                // The recovery message above is the authoritative result.
            } else if let importError = error as? MobileChangeImportError, case .partialReceipt = importError {
                // Preserve exact partial totals and the recovery action above.
            } else {
                errorMessage = String(localized: "The reviewed changes were not applied. No phone changes were acknowledged.")
            }
            phase = .failed
            throw error
        }
    }

    /// Builds the safe, allowlisted snapshot from the already-open metadata
    /// actor. The store only receives typed records; source paths, image
    /// bytes, and database objects never enter the package envelope.
    public static func metadataSnapshotProvider(
        metadataStore: MetadataStore?,
        applicationSupport: URL? = nil,
        caches: URL? = nil
    ) -> SnapshotProvider {
        { root, id in
            guard let metadataStore else { return try await emptySnapshot(root: root, id: id) }
            let projects = try await metadataStore.projects()
            let nights = try await metadataStore.nights()
            var captures: [SeriesRecord] = []
            var totals: [UUID: Double] = [:]
            var decisions: [FrameDecisionRecord] = []
            for night in nights {
                let series = try await metadataStore.series(nightID: night.id)
                captures.append(contentsOf: series)
                for capture in series {
                    let frameDecisions = try await metadataStore.frameDecisions(seriesID: capture.id)
                    let usable = frameDecisions.filter { !$0.logicallyExcluded && $0.verdict != .rejected }.count
                    totals[capture.id] = Double(usable) * capture.exposureSeconds
                    decisions.append(contentsOf: frameDecisions)
                }
            }
            var annotations: [ProjectAnnotationRecord] = []
            for project in projects {
                if let annotation = try await metadataStore.projectAnnotation(projectID: project.id) {
                    annotations.append(annotation)
                }
            }
            let briefings = await Self.latestBriefings(
                root: root,
                applicationSupport: applicationSupport,
                caches: caches
            )
            let input = MobileSnapshotComposer.Input(
                libraryID: id,
                revision: try await MobileSnapshotRevisionStore(fileURL: root.appendingPathComponent(".astro-tool/mobile-snapshot-revision.json")).next(),
                projects: projects,
                nights: nights,
                captures: captures,
                annotations: annotations,
                briefings: briefings,
                integrationSecondsByCaptureID: totals
            )
            return try MobileSnapshotComposer().compose(input: input, now: Date())
        }
    }

    public func preview() async {
        await discardIncomingPreviewNow()
        beginNewOperation(.previewing)
        guard let rootURL else {
            fail(.missingLibrary, message: String(localized: "Open an image library on the Mac before sending anything."))
            return
        }
        let token = generation
        do {
            let identity = try identityPreview(rootURL)
            let snapshot = try await snapshotProvider(rootURL, identity.proposedID)
            guard token == generation, phase == .previewing else { return }
            preview = MobileSyncPreview(
                identity: identity,
                snapshot: snapshot,
                snapshotSummary: Self.summary(for: snapshot),
                confirmationToken: MobileSyncConfirmationToken(snapshotID: snapshot.snapshotID, revision: snapshot.revision, createdAt: snapshot.createdAt, summary: Self.summary(for: snapshot), libraryID: snapshot.libraryID)
            )
            guard snapshot.libraryID == identity.proposedID else {
                fail(.identityMismatch, message: String(localized: "The library identity changed. Review it again, then confirm the exact identity."))
                return
            }
            isIdentityConfirmed = identity.alreadyExists
            isSummaryConfirmed = false
            errorMessage = nil
            failure = nil
            phase = .ready
        } catch {
            guard token == generation else { return }
            fail(.exportFailed, message: Self.userMessage(for: error, fallback: String(localized: "AstroTool could not prepare a safe preview.")))
        }
    }

    public func confirmIdentity(_ id: PortableLibraryID) {
        guard phase == .ready, let rootURL, let preview else { return }
        let confirmedID = id
        guard confirmedID == preview.identity.proposedID else {
            fail(.identityMismatch, message: String(localized: "The library identity changed. Review it again, then confirm the exact identity."))
            return
        }
        guard !preview.identity.alreadyExists else {
            isIdentityConfirmed = true
            return
        }
        do {
            let committedID = try identityCommit(rootURL, confirmedID)
            guard committedID == confirmedID else {
                fail(.identityMismatch, message: String(localized: "The saved library identity did not match the identity you confirmed. Review it again."))
                return
            }
            isIdentityConfirmed = true
            errorMessage = nil
            failure = nil
        } catch {
            fail(.identityWriteFailed, message: String(localized: "AstroTool could not save the library identity. Nothing was sent."))
        }
    }

    public func confirmSummary(_ token: MobileSyncConfirmationToken) {
        guard phase == .ready, let preview, isIdentityConfirmed else { return }
        guard token == preview.confirmationToken else {
            fail(.summaryMismatch, message: String(localized: "The summary changed. Review the latest counts before sending."))
            return
        }
        isSummaryConfirmed = true
        errorMessage = nil
        failure = nil
    }

    public func recordExporterFailure() {
        guard phase == .ready else { return }
        fail(.destinationExists, message: String(localized: "Choose a new package name. Existing packages are never replaced."))
    }

    @discardableResult
    public func beginExport() -> Bool {
        guard canExport else { return false }
        generation += 1
        oneTimeQRPayload = nil
        exportedURL = nil
        packageID = nil
        encryptedByteCount = nil
        exportedAt = nil
        errorMessage = nil
        failure = nil
        phase = .exporting
        cancellationRequested = false
        return true
    }

    public func export(to destination: URL) async {
        guard beginExport(), let preview else { return }
        guard !sentSnapshotLoadFailed else {
            fail(.exportFailed, message: String(localized: "The previous sync identity could not be read safely. Nothing was sent."))
            return
        }
        let token = generation
        let key = OneTimePackageKey()
        do {
            try Task.checkCancellation()
            try prepareDestination(destination)
            if productionMode {
                guard let returnCoordinator else { throw MobileChangeImportError.configurationMissing }
                let result = try await returnCoordinator.publishForwardSnapshot(
                    preview.snapshot,
                    to: destination,
                    wrapping: key
                )
                guard token == generation, (phase == .exporting || phase == .finishing) else { return }
                packageID = result.packageID
                exportedAt = result.createdAt
                encryptedByteCount = result.encryptedByteCount
                exportedURL = destination
                oneTimeQRPayload = key.qrPayload
                errorMessage = nil
                failure = nil
                phase = .exported
                return
            }
            guard let changeImporter else { throw MobileChangeImportError.configurationMissing }
            let acknowledgementIDs = try changeImporter.currentAcknowledgementIDs()
            let envelope = MobilePackageEnvelope(snapshot: preview.snapshot, changes: [], acknowledgedChangeIDs: acknowledgementIDs)
            let revisions = MobileSnapshotRevisionStore(fileURL: (rootURL ?? destination.deletingLastPathComponent()).appendingPathComponent(".astro-tool/mobile-snapshot-revision.json"))
            let reservation = try await revisions.beginPublication(expectedRevision: preview.snapshot.revision)
            do {
                // Persist non-authorizing intent before touching the final
                // package name. A crash/failure leaves recoverable pending
                // evidence, while only the post-export transition below can
                // authorize this base for a return package.
                if let acknowledgementStore = sentSnapshotStore as? MobileSentSnapshotAcknowledgementStore {
                    try acknowledgementStore.reserve(snapshotID: preview.snapshot.snapshotID, acknowledgementIDs: acknowledgementIDs)
                }
                let result = try await packageExport(envelope, destination, key)
                guard token == generation, (phase == .exporting || phase == .finishing) else {
                    if let acknowledgementStore = sentSnapshotStore as? MobileSentSnapshotAcknowledgementStore {
                        try? acknowledgementStore.cancelPending(snapshotID: preview.snapshot.snapshotID)
                    }
                    await revisions.finishPublication(reservation, published: false)
                    return
                }
                packageID = result.packageID
                exportedAt = result.createdAt
                encryptedByteCount = result.encryptedByteCount
                exportedURL = destination
                if let acknowledgementStore = sentSnapshotStore as? MobileSentSnapshotAcknowledgementStore {
                    try acknowledgementStore.markPublished(snapshotID: preview.snapshot.snapshotID)
                } else {
                    try sentSnapshotStore?.save(snapshotID: preview.snapshot.snapshotID)
                }
                sentBaseSnapshotIDs.insert(preview.snapshot.snapshotID)
                sentBaseAcknowledgements[preview.snapshot.snapshotID] = Set(acknowledgementIDs)
                await revisions.finishPublication(reservation, published: true)
                oneTimeQRPayload = key.qrPayload
                errorMessage = nil
                failure = nil
                phase = .exported
            } catch {
                if let acknowledgementStore = sentSnapshotStore as? MobileSentSnapshotAcknowledgementStore {
                    try? acknowledgementStore.cancelPending(snapshotID: preview.snapshot.snapshotID)
                }
                await revisions.finishPublication(reservation, published: false)
                throw error
            }
        } catch {
            guard token == generation else { return }
            if cancellationRequested {
                clearCancelledExport()
                return
            }
            let destinationExists = (error as? MobilePackageError) == .destinationExists
            fail(
                destinationExists ? .destinationExists : .exportFailed,
                message: Self.userMessage(for: error, fallback: String(localized: "The package was not sent. Choose a new destination and try again."))
            )
        }
    }

    public func previewIncomingPackage(from source: URL, qrPayload: String) async {
        await discardIncomingPreviewNow()
        incomingSource = source
        incomingQRPayload = qrPayload
        beginNewOperation(.importing)
        let token = generation
        do {
            let key = try OneTimePackageKey(scanning: qrPayload)
            if productionMode {
                guard let returnCoordinator else { throw MobileChangeImportError.configurationMissing }
                let review = try await returnCoordinator.preview(from: source, wrapping: key)
                guard token == generation, phase == .importing else {
                    await returnCoordinator.discard(review)
                    return
                }
                incomingReview = review
                incomingPreview = review.packagePreview
                changePreview = review.changePreview
                changeResolutions = review.changePreview.conflicts.reduce(into: [:]) { values, conflict in
                    values[conflict.changeID] = conflict.recommendedResolution
                }
            } else if usesLegacyImportPreview {
                let imported = try await packageImportPreview(source, key)
                guard token == generation, phase == .importing else { await packageImportDiscard(imported.packageID); return }
                incomingPreview = imported
            } else {
                let authenticated = try await packageAuthenticatePreview(source, key)
                let imported = authenticated.preview
                guard token == generation, phase == .importing else { await packageImportDiscardCapability(authenticated.token); return }
                incomingCapability = authenticated.token
                incomingPreview = imported
                if imported.purpose == .returnChanges, let current = try await currentSnapshotForReturn() {
                    let authenticatedReturn = try await packageAuthenticatedReturn(authenticated.token)
                    guard try publishedAcknowledgements(for: authenticatedReturn.baseSnapshotID) != nil else {
                        throw MobileChangeImportError.snapshotMismatch
                    }
                    guard let changeImporter else { throw MobileChangeImportError.configurationMissing }
                    let typed = try changeImporter.preview(authenticatedReturn: authenticatedReturn, expectedLibraryID: current.libraryID, expectedBaseSnapshotID: authenticatedReturn.baseSnapshotID, currentSnapshot: current)
                    incomingReturn = authenticatedReturn
                    changePreview = typed
                    changeResolutions = typed.conflicts.reduce(into: [:]) { values, conflict in
                        values[conflict.changeID] = conflict.recommendedResolution
                    }
                }
            }
            didApplyIncomingChanges = false
            errorMessage = nil
            failure = nil
            phase = .importPreviewReady
        } catch {
            guard token == generation else { return }
            if let capability = incomingCapability {
                await packageImportDiscardCapability(capability)
                incomingCapability = nil
                incomingReturn = nil
                incomingPreview = nil
            }
            if let returnCoordinator, let incomingReview {
                await returnCoordinator.discard(incomingReview)
                self.incomingReview = nil
            }
            let isKeyError = (error as? MobilePackageError) == .invalidKeyPayload
            fail(isKeyError ? .invalidKey : .importFailed, message: Self.userMessage(for: error, fallback: String(localized: "This package could not be opened. Check the package and scan its code again.")))
        }
    }

    private func currentSnapshotForReturn() async throws -> MobileLibrarySnapshot? {
        guard let rootURL else { return nil }
        let identity = try identityPreview(rootURL)
        return try await snapshotProvider(rootURL, identity.proposedID)
    }

    /// Authorization always reloads durable evidence. A scene's initial cache
    /// can be stale after another Mac window publishes, consumes, or leaves a
    /// failed forward package pending.
    private func publishedAcknowledgements(for snapshotID: UUID) throws -> Set<UUID>? {
        if let acknowledgementStore = sentSnapshotStore as? MobileSentSnapshotAcknowledgementStore {
            let records = try acknowledgementStore.loadPublishedRecords()
            sentBaseSnapshotIDs = Set(records.map(\.snapshotID))
            sentBaseAcknowledgements = Dictionary(uniqueKeysWithValues: records.map { ($0.snapshotID, Set($0.acknowledgementIDs)) })
        } else if let sentSnapshotStore {
            let ids = try sentSnapshotStore.load()
            sentBaseSnapshotIDs = Set(ids)
            sentBaseAcknowledgements = Dictionary(uniqueKeysWithValues: ids.map { ($0, []) })
        }
        return sentBaseAcknowledgements[snapshotID]
    }

    private func consumePublishedEvidence(for snapshotID: UUID) throws {
        guard let acknowledgements = try publishedAcknowledgements(for: snapshotID) else {
            throw MobileChangeImportError.snapshotMismatch
        }
        // Production return application performs ledger pruning inside
        // MobileReturnApplicationCoordinator while it still owns the live
        // service capability. This UI store must not expose an arbitrary
        // acknowledgement mutation route.
        _ = acknowledgements
        if let acknowledgementStore = sentSnapshotStore as? MobileSentSnapshotAcknowledgementStore {
            try acknowledgementStore.consumePublished(snapshotID: snapshotID)
        }
        sentBaseSnapshotIDs.remove(snapshotID)
        sentBaseAcknowledgements.removeValue(forKey: snapshotID)
    }

    public func cancel() {
        if phase == .exporting {
            cancellationRequested = true
            operationTask?.cancel()
            phase = .finishing
            return
        }
        if phase == .finishing { return }
        if phase == .applying { return }
        if phase == .discarding { return }
        if incomingPreview != nil {
            startDiscardingIncomingPreview()
            return
        }
        operationTask?.cancel()
        operationTask = nil
        generation += 1
        phase = .idle
        preview = nil
        incomingPreview = nil
        changePreview = nil
        changeResolutions = [:]
        appliedChangeReceipt = nil
        appliedChangeTotals = .init()
        exportedURL = nil
        packageID = nil
        encryptedByteCount = nil
        exportedAt = nil
        oneTimeQRPayload = nil
        errorMessage = nil
        failure = nil
        isIdentityConfirmed = false
        isSummaryConfirmed = false
        didApplyIncomingChanges = false
        cancellationRequested = false
        incomingSource = nil
        incomingQRPayload = nil
    }

    public func reset() {
        guard phase != .finishing, phase != .applying, phase != .discarding else { return }
        dismiss()
    }

    public func dismiss() {
        guard phase != .finishing, phase != .applying, phase != .discarding else { return }
        if incomingPreview != nil {
            startDiscardingIncomingPreview()
            return
        }
        generation += 1
        operationTask?.cancel()
        operationTask = nil
        phase = .idle
        preview = nil
        incomingPreview = nil
        changePreview = nil
        changeResolutions = [:]
        appliedChangeReceipt = nil
        appliedChangeTotals = .init()
        exportedURL = nil
        packageID = nil
        encryptedByteCount = nil
        exportedAt = nil
        oneTimeQRPayload = nil
        errorMessage = nil
        failure = nil
        isIdentityConfirmed = false
        isSummaryConfirmed = false
        didApplyIncomingChanges = false
        cancellationRequested = false
        incomingSource = nil
        incomingQRPayload = nil
    }

    public func retry() async {
        guard failure != nil else { return }
        if let incomingSource, let incomingQRPayload {
            await previewIncomingPackage(from: incomingSource, qrPayload: incomingQRPayload)
            return
        }
        await preview()
    }

    private func beginNewOperation(_ next: MobileSyncPhase) {
        generation += 1
        oneTimeQRPayload = nil
        errorMessage = nil
        failure = nil
        phase = next
        cancellationRequested = false
        // A previous attempt's receipt must never survive into a new
        // preview operation: once this store starts re-previewing (retry,
        // or scanning a fresh package), any prior appliedChangeReceipt is
        // from a different transaction than the changePreview that is
        // about to replace the current one. Leaving it in place would let
        // `receiptTotals` pair a stale receipt with a fresh preview and
        // render a false outcome on the `.importPreviewReady` review
        // banner. This clears unconditionally, including for `.importing`,
        // unlike the fields below that legitimately survive the brief
        // in-flight window of a same-kind re-preview.
        appliedChangeReceipt = nil
        appliedChangeTotals = .init()
        if next != .importing {
            preview = nil
            incomingPreview = nil
            changePreview = nil
            changeResolutions = [:]
            exportedURL = nil
            packageID = nil
            encryptedByteCount = nil
            exportedAt = nil
            isIdentityConfirmed = false
            isSummaryConfirmed = false
        }
    }

    private func fail(_ kind: MobileSyncFailure, message: String) {
        operationTask = nil
        phase = .failed
        failure = kind
        errorMessage = message
        oneTimeQRPayload = nil
        exportedURL = nil
        packageID = nil
        encryptedByteCount = nil
        exportedAt = nil
        isSummaryConfirmed = false
    }

    private func discardIncomingPreviewNow() async {
        if let discardTask {
            await discardTask.value
            self.discardTask = nil
        }
        if let returnCoordinator, let incomingReview {
            await returnCoordinator.discard(incomingReview)
        } else if let capability = incomingCapability {
            await packageImportDiscardCapability(capability)
        } else if let packageID = incomingPreview?.packageID {
            await packageImportDiscard(packageID)
        }
        incomingCapability = nil
        incomingReturn = nil
        incomingReview = nil
        incomingPreview = nil
    }

    private func startDiscardingIncomingPreview() {
        guard incomingPreview?.packageID != nil else { return }
        operationTask?.cancel()
        operationTask = nil
        generation += 1
        phase = .discarding
        let capability = incomingCapability
        let review = incomingReview
        let coordinator = returnCoordinator
        let packageID = incomingPreview?.packageID
        let discardCapability = packageImportDiscardCapability
        let discardLegacy = packageImportDiscard
        incomingPreview = nil
        incomingReturn = nil
        incomingReview = nil
        incomingCapability = nil
        incomingSource = nil
        incomingQRPayload = nil
        let priorDiscard = discardTask
        discardTask = Task { [weak self] in
            await priorDiscard?.value
            if let coordinator, let review { await coordinator.discard(review) }
            else if let capability { await discardCapability(capability) }
            else if let packageID { await discardLegacy(packageID) }
            self?.finishDiscardingIncomingPreview()
        }
    }

    private func finishDiscardingIncomingPreview() {
        guard phase == .discarding else { return }
        discardTask = nil
        operationTask = nil
        phase = .idle
        preview = nil
        exportedURL = nil
        changePreview = nil
        changeResolutions = [:]
        appliedChangeReceipt = nil
        appliedChangeTotals = .init()
        packageID = nil
        encryptedByteCount = nil
        exportedAt = nil
        oneTimeQRPayload = nil
        errorMessage = nil
        failure = nil
        isIdentityConfirmed = false
        isSummaryConfirmed = false
        didApplyIncomingChanges = false
    }

    private func clearCancelledExport() {
        operationTask = nil
        phase = .idle
        preview = nil
        exportedURL = nil
        packageID = nil
        encryptedByteCount = nil
        exportedAt = nil
        oneTimeQRPayload = nil
        errorMessage = nil
        failure = nil
        isIdentityConfirmed = false
        isSummaryConfirmed = false
        cancellationRequested = false
    }

    private static func summary(for snapshot: MobileLibrarySnapshot) -> MobileSnapshotSummary {
        MobileSnapshotSummary(
            projectCount: snapshot.projects.count,
            nightCount: snapshot.nights.count,
            captureCount: snapshot.captures.count,
            briefingCount: snapshot.briefings.count,
            noteCount: snapshot.notes.count
            , checklistItemCount: snapshot.briefings.reduce(0) { total, briefing in total + briefing.checklist.reduce(0) { $0 + $1.items.count } }
        )
    }

    private static func totals(
        receipt: MobileChangeApplicationReceipt,
        preview: MobileChangeImportPreview
    ) -> MobileChangeOutcomeTotals {
        // `receipt.resolvedChangeIDs` unions superseded changes with
        // conflicts resolved as `.keepMac` for phone-acknowledgement
        // purposes (see MobileChangeImporter.apply). The six user-facing
        // totals must stay disjoint, so superseded IDs are subtracted here
        // before counting what was "kept on Mac".
        .init(
            applied: receipt.appliedChangeIDs.count,
            keptOnMac: Set(receipt.resolvedChangeIDs).subtracting(preview.superseded).count,
            superseded: preview.superseded.count,
            alreadyHandled: preview.alreadyApplied.count,
            duplicates: preview.duplicates.count,
            rejected: preview.rejected.count
        )
    }

    nonisolated private static func metadataRevision(
        projects: [ProjectRecord], nights: [NightRecord], captures: [SeriesRecord], annotations: [ProjectAnnotationRecord], briefings: [NightBriefingDraft], decisions: [FrameDecisionRecord], integrationSecondsByCaptureID: [UUID: Double]
    ) -> Int {
        var hash: UInt64 = 1469598103934665603
        let projectText = projects.sorted { $0.id.uuidString < $1.id.uuidString }.map(Self.stableEncoding)
        let nightText = nights.sorted { $0.id.uuidString < $1.id.uuidString }.map(Self.stableEncoding)
        let captureText = captures.sorted { $0.id.uuidString < $1.id.uuidString }.map(Self.stableEncoding)
        let annotationText = annotations.sorted { $0.projectID.uuidString < $1.projectID.uuidString }.map(Self.stableEncoding)
        let decisionText = decisions.sorted { $0.id.uuidString < $1.id.uuidString }.map(Self.stableEncoding)
        let totalText = integrationSecondsByCaptureID.keys.sorted { $0.uuidString < $1.uuidString }.map { "\($0.uuidString):\(integrationSecondsByCaptureID[$0] ?? 0)" }
        let briefingText = Self.stableEncoding(briefings.sorted { $0.id.uuidString < $1.id.uuidString })
        let text = (projectText + nightText + captureText + annotationText + decisionText + totalText + [briefingText]).joined(separator: "|")
        for byte in text.utf8 { hash ^= UInt64(byte); hash &*= 1099511628211 }
        return max(1, Int(hash & 0x7fff_ffff_ffff_ffff))
    }

    nonisolated private static func stableEncoding<T: Encodable>(_ value: T) -> String {
        guard let data = try? MobileJSON.encoder.encode(value) else { return "<encoding-failed>" }
        return String(decoding: data, as: UTF8.self)
    }

    // Kept internal for deterministic revision regression tests. Production
    // callers use metadataSnapshotProvider, which supplies these same values.
    nonisolated static func revisionForTesting(
        projects: [ProjectRecord],
        nights: [NightRecord],
        captures: [SeriesRecord],
        annotations: [ProjectAnnotationRecord],
        briefings: [NightBriefingDraft],
        decisions: [FrameDecisionRecord],
        integrationSecondsByCaptureID: [UUID: Double]
    ) -> Int {
        metadataRevision(
            projects: projects,
            nights: nights,
            captures: captures,
            annotations: annotations,
            briefings: briefings,
            decisions: decisions,
            integrationSecondsByCaptureID: integrationSecondsByCaptureID
        )
    }

    private static func emptySnapshot(root: URL, id: PortableLibraryID) async throws -> MobileLibrarySnapshot {
        _ = root
        return MobileLibrarySnapshot(
            schemaVersion: MobileLibrarySnapshot.currentSchemaVersion,
            libraryID: id,
            snapshotID: UUID(),
            revision: 0,
            createdAt: Date(),
            projects: [], nights: [], captures: [], briefings: [], notes: []
        )
    }

    private static func latestBriefings(
        root: URL,
        applicationSupport: URL?,
        caches: URL?
    ) async -> [NightBriefingDraft] {
        let paths: AppStoragePaths?
        if let applicationSupport, let caches {
            paths = try? AppStoragePaths(
                applicationSupport: applicationSupport,
                caches: caches,
                libraryID: LibraryIdentity(rootURL: root),
                libraryRoot: root
            )
        } else {
            paths = try? AppStoragePaths.production(
                libraryID: LibraryIdentity(rootURL: root),
                libraryRoot: root
            )
        }
        guard let paths else { return [] }
        return (try? await NightBriefingRevisionStore(directory: paths.briefings).latestRevisions()) ?? []
    }

    private static func userMessage(for error: Error, fallback: String) -> String {
        guard let error = error as? MobilePackageError else { return fallback }
        switch error {
        case .destinationExists:
            return String(localized: "That destination already exists. Choose a new name; AstroTool never overwrites it.")
        case .authenticationFailed, .invalidKeyPayload, .invalidKey:
            return String(localized: "This package could not be unlocked. Check the package and scan its code again.")
        case .malformedPackage, .invalidManifest, .manifestHashMismatch, .invalidEnvelope, .packageIDMismatch:
            return String(localized: "This package is damaged or incomplete. Ask for a fresh package and try again.")
        default:
            return fallback
        }
    }
}
