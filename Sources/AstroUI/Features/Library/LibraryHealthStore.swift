import AstroApplication
import AstroCore
import Foundation
import Observation

/// Thread-safe box for a `(done, total)` progress pair, bridged into
/// `OperationHost.reportProgress`'s async, polled-from-the-outside world --
/// mirrors `ReviewStore`'s own `FrameRatingProgressBox` (same shape, kept as
/// its own private copy per this codebase's per-file convention for these
/// small progress bridges).
private final class HealthOperationProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _done: Int64 = 0
    private var _total: Int64 = 0
    func update(done: Int, total: Int) {
        lock.lock(); _done = Int64(done); _total = Int64(total); lock.unlock()
    }
    var current: (done: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        return (_done, _total)
    }
}

@MainActor
@Observable
public final class LibraryHealthStore {
    public typealias MetadataFactory = @MainActor @Sendable (URL) throws -> MetadataStore
    public typealias QueryFactory = @Sendable (URL, MetadataStore, LibraryAccessMode) throws -> LibraryHealthQuery
    public typealias AuditCommandFactory = @Sendable (URL, MetadataStore) throws -> AuditRunCommand

    public private(set) var snapshot: LibraryHealthSnapshot?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var showAcknowledged = false
    /// V2 product/UX audit (2026-08-15) section 3(a), CRITICAL: threaded the
    /// same way `CalibrationStore.accessMode` already is -- `load`'s caller
    /// supplies the library's real access mode, and `snapshot`'s own
    /// `isReadOnly` is derived from it instead of a hardcoded `true`.
    public private(set) var accessMode: LibraryAccessMode = .readOnly
    /// The most recently completed `runVerify`'s own summary -- kept around
    /// so the confirmation sheet's caller can show a one-line result after
    /// `OperationHost`'s own generic success toast, without re-querying
    /// anything. `nil` before the first verify run this session.
    public private(set) var lastVerifySummary: FixityVerifier.Summary?
    /// Fired after `acknowledge`/`revokeAcknowledgement` each succeed --
    /// lets `V2RootView` keep the sidebar's Library badge fresh without this
    /// store needing to know anything about `SidebarBadgeStore` itself
    /// (wave 3 follow-up fix: the badge previously only refreshed on
    /// appear/nights-change/scan+audit success, going stale after an ack or
    /// revoke). `runAudit`/`verifyIntegrity` don't also call this: those
    /// already refresh the badge through `OperationHost`'s own
    /// `recentOutcomes` success path in `V2RootView`.
    public var onLibraryFindingsChanged: (() -> Void)?

    private let metadataFactory: MetadataFactory
    private let queryFactory: QueryFactory
    private let auditCommandFactory: AuditCommandFactory
    private var metadata: MetadataStore?
    private var rootURL: URL?

    public init(
        metadataFactory: @escaping MetadataFactory = LibraryHealthStore.productionMetadata,
        queryFactory: @escaping QueryFactory = { rootURL, metadata, accessMode in
            try LibraryHealthQuery.production(rootURL: rootURL, metadata: metadata, accessMode: accessMode)
        },
        auditCommandFactory: @escaping AuditCommandFactory = { rootURL, metadata in
            try AuditRunCommand.production(rootURL: rootURL, metadata: metadata)
        }
    ) {
        self.metadataFactory = metadataFactory
        self.queryFactory = queryFactory
        self.auditCommandFactory = auditCommandFactory
    }

    public func load(rootURL: URL, accessMode: LibraryAccessMode = .readOnly) async {
        isLoading = true
        errorMessage = nil
        self.accessMode = accessMode
        defer { isLoading = false }
        do {
            let metadata = try metadataFactory(rootURL.standardizedFileURL)
            self.metadata = metadata
            self.rootURL = rootURL.standardizedFileURL
            snapshot = try await queryFactory(rootURL, metadata, accessMode).snapshot(includeAcknowledged: showAcknowledged)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Toggles whether already-acknowledged findings stay visible (dimmed by
    /// the caller) instead of being hidden, then reloads to apply it.
    public func setShowAcknowledged(_ value: Bool) async {
        showAcknowledged = value
        await refresh()
    }

    /// Marks one finding group as acknowledged and refreshes the rows.
    public func acknowledge(_ item: LibraryHealthItem, note: String? = nil) async {
        guard let metadata else { return }
        do {
            try await metadata.acknowledgeFindingGroup(
                category: item.ackCategory, groupKey: item.ackGroupKey, note: note
            )
            errorMessage = nil
            await refresh()
            onLibraryFindingsChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reverses `acknowledge` and refreshes the rows.
    public func revokeAcknowledgement(_ item: LibraryHealthItem) async {
        guard let metadata else { return }
        do {
            try await metadata.revokeAcknowledgement(
                ackKey: MetadataStore.ackKey(category: item.ackCategory, groupKey: item.ackGroupKey)
            )
            errorMessage = nil
            await refresh()
            onLibraryFindingsChanged?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a full or fast (skip duplicate scan) audit through
    /// `AuditRunCommand.runAudit`, via `OperationHost` so it shows up in the
    /// toolbar with progress/cancel and gets `OperationHost`'s own success/
    /// failure toast. Refreshes `snapshot` (findings + audit run history)
    /// once it settles, whether it succeeded, failed, or was cancelled --
    /// mirrors `ReviewStore.rateSelectedSeries`'s own "always refresh before
    /// rethrowing" shape.
    ///
    /// `rootURL` is always taken explicitly rather than read back from a
    /// prior `load(rootURL:)` call -- unlike `ReviewStore` (opened once per
    /// project workspace), this store's own action must also work from the
    /// V2 menu bar's "Run Audit" (⌥⌘A), which can fire while `HealthView`
    /// itself was never mounted this session and so never called `load`.
    public func runAudit(mode: AuditRunMode, rootURL: URL?, operationHost: OperationHost) async {
        guard let rootURL else {
            operationHost.notify(.info, message: OperationHost.localized("Choose a library before running an audit."))
            return
        }
        let standardizedRoot = rootURL.standardizedFileURL
        let kind = OperationKind.audit(library: standardizedRoot.path)
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else {
            operationHost.notify(.info, message: OperationHost.localized("An audit is already running for this library."))
            return
        }

        do {
            let metadata = try metadataFactory(standardizedRoot)
            self.metadata = metadata
            self.rootURL = standardizedRoot
            let command = try auditCommandFactory(standardizedRoot, metadata)
            let title = OperationHost.localized(mode == .full ? "Running audit" : "Running audit (fast)")
            _ = await operationHost.run(kind: kind, title: title, cancellation: .cooperative) { [weak self] in
                do {
                    try Task.checkCancellation()
                    _ = try await command.runAudit(mode: mode, isCancelled: { Task.isCancelled })
                } catch {
                    await self?.refresh()
                    throw error
                }
                await self?.refresh()
            }
        } catch {
            operationHost.notify(.failure, message: "\(OperationHost.localized("Audit failed:")) \(error.localizedDescription)")
        }
    }

    /// Runs `AuditRunCommand.runVerify` (optionally filling missing checksums
    /// first) via `OperationHost`, relaying its per-file `(done, total)`
    /// progress the same way `ReviewStore.rateSelectedSeries` relays
    /// `FrameRatingCommand`'s. Records `lastVerifySummary` and refreshes
    /// `snapshot` once it settles. Takes `rootURL` explicitly for the same
    /// reason `runAudit` does.
    public func verifyIntegrity(options: VerifyRunOptions, rootURL: URL?, operationHost: OperationHost) async {
        guard let rootURL else {
            operationHost.notify(.info, message: OperationHost.localized("Choose a library before verifying integrity."))
            return
        }
        let standardizedRoot = rootURL.standardizedFileURL
        let kind = OperationKind.verify(library: standardizedRoot.path)
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else {
            operationHost.notify(.info, message: OperationHost.localized("An integrity verification is already running for this library."))
            return
        }

        do {
            let metadata = try metadataFactory(standardizedRoot)
            self.metadata = metadata
            self.rootURL = standardizedRoot
            let command = try auditCommandFactory(standardizedRoot, metadata)
            let box = HealthOperationProgressBox()
            let title = OperationHost.localized(options.sampleFraction == nil ? "Verifying integrity" : "Verifying integrity (sample)")

            let id = await operationHost.run(kind: kind, title: title, cancellation: .cooperative) { [weak self] in
                do {
                    try Task.checkCancellation()
                    let outcome = try command.runVerify(
                        options: options,
                        progress: { done, total in box.update(done: done, total: total) },
                        isCancelled: { Task.isCancelled }
                    )
                    await self?.recordVerifySummary(outcome.summary)
                } catch {
                    await self?.refresh()
                    throw error
                }
                await self?.refresh()
            }

            operationHost.relayProgress(id: id) {
                let progress = box.current
                return OperationProgress(completed: progress.done, total: progress.total > 0 ? progress.total : nil)
            }
        } catch {
            operationHost.notify(.failure, message: "\(OperationHost.localized("Integrity verification failed:")) \(error.localizedDescription)")
        }
    }

    private func recordVerifySummary(_ summary: FixityVerifier.Summary) {
        lastVerifySummary = summary
    }

    private func refresh() async {
        guard let rootURL, let metadata else { return }
        do {
            snapshot = try await queryFactory(rootURL, metadata, accessMode).snapshot(includeAcknowledged: showAcknowledged)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public static func productionMetadata(rootURL: URL) throws -> MetadataStore {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return try MetadataStore(storagePaths: storage)
    }
}
