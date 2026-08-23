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

public enum MobileSyncPhase: String, Equatable, Sendable {
    case idle
    case previewing
    case ready
    case exporting
    case exported
    case importing
    case importPreviewReady
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
    public typealias IdentityPreview = @Sendable (URL) throws -> PortableIdentityPreview
    public typealias IdentityCommit = @Sendable (URL, PortableLibraryID) throws -> PortableLibraryID
    public typealias SnapshotProvider = @Sendable (URL, PortableLibraryID) async throws -> MobileLibrarySnapshot
    public typealias PackageExport = @Sendable (MobilePackageEnvelope, URL, OneTimePackageKey) async throws -> MobileSyncExportResult
    public typealias PackageImportPreview = @Sendable (URL, OneTimePackageKey) async throws -> MobilePackageImportPreview
    public typealias DestinationPreparation = @Sendable (URL) throws -> Void

    public private(set) var phase: MobileSyncPhase = .idle
    public private(set) var preview: MobileSyncPreview?
    public private(set) var incomingPreview: MobilePackageImportPreview?
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

    public let rootURL: URL?
    public let destinationToken: String

    private let identityPreview: IdentityPreview
    private let identityCommit: IdentityCommit
    private let snapshotProvider: SnapshotProvider
    private let packageExport: PackageExport
    private let packageImportPreview: PackageImportPreview
    private let prepareDestination: DestinationPreparation
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cancellationRequested = false
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    public init(
        rootURL: URL?,
        identityPreview: IdentityPreview? = nil,
        identityCommit: IdentityCommit? = nil,
        snapshotProvider: SnapshotProvider? = nil,
        packageExport: PackageExport? = nil,
        packageImportPreview: PackageImportPreview? = nil,
        destinationToken: String = UUID().uuidString.lowercased(),
        prepareDestination: DestinationPreparation? = nil,
        packageService: MobilePackageService = MobilePackageService()
    ) {
        self.rootURL = rootURL
        self.destinationToken = destinationToken
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
        } else {
            self.packageImportPreview = { source, key in
                try await packageService.importPreview(from: source, wrapping: key)
            }
        }
    }

    public var canExport: Bool {
        phase == .ready && isIdentityConfirmed && isSummaryConfirmed && preview != nil
    }

    public var isBusy: Bool {
        phase == .previewing || phase == .exporting || phase == .importing
    }

    public func startPreview() {
        operationTask?.cancel()
        operationTask = Task { [weak self] in await self?.preview() }
    }

    public func startIncomingPreview(from source: URL, qrPayload: String) {
        operationTask?.cancel()
        operationTask = Task { [weak self] in
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
            for night in nights {
                let series = try await metadataStore.series(nightID: night.id)
                captures.append(contentsOf: series)
                for capture in series {
                    let decisions = try await metadataStore.frameDecisions(seriesID: capture.id)
                    let usable = decisions.filter { !$0.logicallyExcluded && $0.verdict != .rejected }.count
                    totals[capture.id] = Double(usable) * capture.exposureSeconds
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
                revision: Self.metadataRevision(projects: projects, nights: nights, captures: captures, annotations: annotations, briefings: briefings),
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
            fail(.exportFailed, message: Self.userMessage(for: error, fallback: "AstroTool could not prepare a safe preview."))
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
            _ = try identityCommit(rootURL, confirmedID)
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
        let token = generation
        let key = OneTimePackageKey()
        let envelope = MobilePackageEnvelope(snapshot: preview.snapshot, changes: [], acknowledgedChangeIDs: [])
        do {
            try prepareDestination(destination)
            let result = try await packageExport(envelope, destination, key)
            guard token == generation, (phase == .exporting || (phase == .idle && cancellationRequested)) else { return }
            packageID = result.packageID
            exportedAt = result.createdAt
            encryptedByteCount = result.encryptedByteCount
            exportedURL = destination
            oneTimeQRPayload = key.qrPayload
            errorMessage = nil
            failure = nil
            phase = .exported
        } catch {
            guard token == generation else { return }
            let destinationExists = (error as? MobilePackageError) == .destinationExists
            fail(
                destinationExists ? .destinationExists : .exportFailed,
                message: Self.userMessage(for: error, fallback: "The package was not sent. Choose a new destination and try again.")
            )
        }
    }

    public func previewIncomingPackage(from source: URL, qrPayload: String) async {
        beginNewOperation(.importing)
        let token = generation
        do {
            let key = try OneTimePackageKey(scanning: qrPayload)
            let imported = try await packageImportPreview(source, key)
            guard token == generation, phase == .importing else { return }
            incomingPreview = imported
            didApplyIncomingChanges = false
            errorMessage = nil
            failure = nil
            phase = .importPreviewReady
        } catch {
            guard token == generation else { return }
            let isKeyError = (error as? MobilePackageError) == .invalidKeyPayload
            fail(isKeyError ? .invalidKey : .importFailed, message: Self.userMessage(for: error, fallback: "This package could not be opened. Check the package and scan its code again."))
        }
    }

    public func cancel() {
        if phase == .exporting {
            cancellationRequested = true
            phase = .idle
            return
        }
        operationTask?.cancel()
        operationTask = nil
        generation += 1
        phase = .idle
        preview = nil
        incomingPreview = nil
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
    }

    public func reset() { dismiss() }

    public func dismiss() {
        generation += 1
        operationTask?.cancel()
        operationTask = nil
        phase = .idle
        preview = nil
        incomingPreview = nil
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
    }

    public func retry() async {
        guard failure != nil else { return }
        await preview()
    }

    private func beginNewOperation(_ next: MobileSyncPhase) {
        generation += 1
        oneTimeQRPayload = nil
        errorMessage = nil
        failure = nil
        phase = next
        cancellationRequested = false
        if next != .importing {
            preview = nil
            incomingPreview = nil
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

    nonisolated private static func metadataRevision(
        projects: [ProjectRecord], nights: [NightRecord], captures: [SeriesRecord], annotations: [ProjectAnnotationRecord], briefings: [NightBriefingDraft]
    ) -> Int {
        var hash: UInt64 = 1469598103934665603
        let text = (projects.map { $0.id.uuidString } + nights.map { $0.id.uuidString } + captures.map { $0.id.uuidString } + annotations.map { $0.projectID.uuidString } + briefings.map { "\($0.id.uuidString):\($0.revision):\($0.savedAt.timeIntervalSince1970)" }).sorted().joined(separator: "|") + "|\(projects.count)|\(nights.count)|\(captures.count)|\(annotations.count)|\(briefings.count)"
        for byte in text.utf8 { hash ^= UInt64(byte); hash &*= 1099511628211 }
        return Int(hash & 0x7fff_ffff_ffff_ffff)
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
