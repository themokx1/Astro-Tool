import Foundation
import AstroMobileDomain
import AstroMobileTransport

/// Typed, closed failure reasons a nearby sync session can end with. Every
/// case maps to exactly one localized string in `MobileSyncStore` — never a
/// raw error surfaced to the UI.
public enum NearbySyncFailure: Equatable, Sendable {
    /// Either side declined the six-digit short authentication code during a
    /// first pairing.
    case pairingRejected
    /// The connecting peer's stored identity key no longer matches the key
    /// it presented — a hard re-pairing signal, never silently accepted.
    /// Carries the peer's deviceID so the recovery UI can offer "Forget this
    /// iPhone and pair again" (`NearbySyncCoordinator.forgetPeer(deviceID:)`)
    /// without a second round trip to look it up.
    case identityChanged(deviceID: UUID)
    /// The authenticated handshake, the forward-snapshot publish, or the
    /// wire-level package transfer itself failed.
    case transferFailed
    /// A return package was received and previewed, but the session ended
    /// without a confirmed apply — the user dismissed the review, rejected
    /// it, or the apply itself failed. Nothing phone-side was acknowledged.
    case applyRefused
    /// The handshake, or waiting for a peer to connect/respond, exceeded its
    /// timeout.
    case timeout
    /// `stop()` ended the session before it reached a natural outcome.
    case cancelled
}

/// The progress events a nearby sync session reports, in order, over the
/// `AsyncStream` `NearbySyncCoordinator.startAdvertising` returns. The stream
/// carries exactly one session: it ends with exactly one terminal event
/// (`.finished` or `.failed`), never both, never neither.
public enum NearbySyncEvent: Sendable {
    case waitingForPhone
    /// A first pairing only — a known peer's session never produces this.
    case pairingCode(String)
    case preparing
    case transferring
    case verifying
    /// A return package was received and authenticated. The Mac has NOT
    /// applied anything yet — the caller must show the exact same review UI
    /// the AirDrop path shows and drive `MobileSyncStore
    /// .applyAuthenticatedReturnChanges` through the exact same human
    /// confirmation gate before calling `reportReturnOutcome`.
    case receivedReturn(MobileReturnApplicationReview)
    case finished
    case failed(NearbySyncFailure)
}

/// What the caller reports back to the coordinator once it has resolved a
/// `.receivedReturn` review through the existing, unmodified apply/discard
/// UI. `NearbySyncCoordinator` never applies anything itself — this is the
/// only way its session can move past `.receivedReturn` to a terminal event.
public enum NearbyReturnOutcome: Sendable {
    /// `MobileSyncStore.applyAuthenticatedReturnChanges` completed.
    case applied
    /// The review was discarded, cancelled, or the apply itself failed.
    case notApplied
}

/// The Mac-side production coordinator for the direct (non-AirDrop) nearby
/// sync flow: advertise the AstroTool Bonjour service, pair with exactly one
/// iPhone at a time, publish the confirmed forward snapshot, and land any
/// return package through the exact same authenticated preview boundary the
/// AirDrop flow uses.
///
/// ## Confirmation handoff (the human preview/confirm gate, spec §4.2)
/// `MobileSyncStore`'s existing AirDrop flow requires the user to review and
/// explicitly confirm the exact snapshot summary (`confirmIdentity` +
/// `confirmSummary`, gating `canExport`) BEFORE anything is exported. This
/// coordinator's production `init` deliberately accepts nothing but
/// `rootURL`/`displayName` — it cannot be handed a caller-supplied envelope,
/// importer, or sent-base evidence (mirrors the Task 7.1 hardening on
/// `MobileReturnApplicationCoordinator`). The forward-publish authority is
/// instead threaded through `startAdvertising(confirmedSnapshot:)`: the
/// SAME `MobileLibrarySnapshot` value `MobileSyncStore` already computed via
/// its own read-only snapshot provider and already required the user to
/// confirm before letting the AirDrop export button enable — i.e. the STORE
/// drives this: the user completes the existing identity/summary
/// confirmation UI, and only then does the store call `startAdvertising`.
/// This is not a new trust boundary: `MobileLibrarySnapshot` is exactly the
/// argument type `MobileReturnApplicationCoordinator.publishForwardSnapshot`
/// itself already accepts from outside its actor — never an envelope,
/// importer, marker, or sent-evidence value. If the confirmed snapshot's
/// revision has since moved (the library changed while waiting for a
/// phone), `publishForwardSnapshot`'s own revision-lease reservation fails
/// exactly as it would for a stale AirDrop export attempt, and this session
/// reports `.failed(.transferFailed)` — no different from today's AirDrop
/// race.
///
/// ## Return-package landing (the critical integration point)
/// `NearbyPackageTransport.receive()` (Task 4) commits an inbound package
/// immediately via `MobilePackageService.commitImport` — correct for a
/// forward snapshot (nothing to review), but that would silently bypass
/// every Wave 1 return-application gate (sent-base evidence, the typed
/// `MobileChangeImporter` preview, and the human confirmation before any
/// domain write) for a RETURN package. Rather than touching
/// `MobileReturnApplicationCoordinator`'s public surface — its
/// `preview(from:wrapping:)` already accepts any `MobilePackageKeyWrapping`,
/// so it needed no change at all — this coordinator uses two new, minimal,
/// package-internal seams added to `NearbyPackageTransport` in this same
/// change: `receiveOptionalReturn`/`receiveStagedForReturnApplication`
/// assemble and hash-verify a package exactly like `receive()` does, but
/// stop before authenticating or committing, handing the caller the staged
/// on-disk directory (`manifest.json` + the encrypted payload file) and the
/// reconstructed `pairedDevice` wrap key instead. This coordinator's own
/// `previewReturn` closure feeds that directory straight into
/// `MobileReturnApplicationCoordinator.preview(from:wrapping:)` — the exact
/// same call `MobileSyncStore`'s AirDrop production path already makes — so
/// a nearby-received return gets a `MobileReturnApplicationReview` through
/// the unmodified, already-hardened boundary. Applying it is left entirely
/// to the caller (`MobileSyncStore.applyAuthenticatedReturnChanges`,
/// unmodified); this coordinator only resumes once `reportReturnOutcome` is
/// called, and never exposes a second apply route of its own.
///
/// ## One session, one connection at a time
/// A single `startAdvertising` call handles exactly one paired session
/// (its stream always ends after one terminal event). A second inbound
/// connection that arrives while a session is already being handled is
/// cancelled without any handshake engagement.
public actor NearbySyncCoordinator {
    package typealias ListenerStart = @Sendable () async throws -> AsyncStream<any NearbyByteConnection>
    package typealias ListenerStop = @Sendable () async -> Void
    package typealias PublishForwardSnapshot = @Sendable (MobileLibrarySnapshot, URL, PairedDeviceKeyWrapping) async throws -> MobileForwardSnapshotPublication
    package typealias PreviewReturn = @Sendable (URL, PairedDeviceKeyWrapping) async throws -> MobileReturnApplicationReview

    private let identity: MobileDeviceIdentity
    private let trustStore: any MobileDeviceIdentityStoring
    private let listenerStart: ListenerStart
    private let listenerStop: ListenerStop
    private let stagingDirectory: URL
    private let packageService: MobilePackageService
    private let publishForwardSnapshotClosure: PublishForwardSnapshot
    private let previewReturnClosure: PreviewReturn
    private let handshakeTimeout: Duration

    private var eventContinuation: AsyncStream<NearbySyncEvent>.Continuation?
    private var currentPairingSession: NearbyPairingSession?
    private var acceptLoopTask: Task<Void, Never>?
    private var confirmedSnapshot: MobileLibrarySnapshot?
    private var didEmitTerminal = false
    private var returnOutcomeContinuation: CheckedContinuation<NearbyReturnOutcome, Never>?

    /// Production construction: a Keychain-backed identity store, a
    /// Bonjour-publishing listener, the real `MobilePackageService`, and a
    /// root-bound `MobileReturnApplicationCoordinator` this actor owns
    /// privately — mirroring exactly how `MobileReturnApplicationCoordinator
    /// .init(rootURL:)` and `MobileSyncStore`'s own production mode build
    /// their dependencies. No caller-supplied envelope, importer, or
    /// sent-evidence seam exists here.
    public init(rootURL: URL, displayName: String) throws {
        let identityStore = KeychainDeviceIdentityStore()
        let identity = try identityStore.loadOrCreateOwnIdentity(displayName: displayName)
        let listener = NearbyBonjourListener(serviceName: displayName)
        let stagingRoot = rootURL.appendingPathComponent(".astro-tool/nearby-staging", isDirectory: true)
        let packageService = MobilePackageService()
        let returnCoordinator = try MobileReturnApplicationCoordinator(rootURL: rootURL)
        self.init(
            identity: identity,
            trustStore: identityStore,
            listenerStart: { try await listener.start() },
            listenerStop: { await listener.stop() },
            stagingDirectory: stagingRoot,
            packageService: packageService,
            publishForwardSnapshot: { snapshot, destination, wrapping in
                try await returnCoordinator.publishForwardSnapshot(snapshot, to: destination, wrapping: wrapping)
            },
            previewReturn: { source, wrapping in
                try await returnCoordinator.preview(from: source, wrapping: wrapping)
            }
        )
    }

    /// Injectable seams for tests: an in-memory identity store, a
    /// caller-supplied connection source standing in for
    /// `NearbyBonjourListener`, an isolated staging directory, and the
    /// forward-publish/return-preview closures a test can point at a real
    /// `MobileReturnApplicationCoordinator` built against a temporary
    /// library fixture. `package` visibility: unreachable outside
    /// `@testable import AstroApplication`.
    package init(
        identity: MobileDeviceIdentity,
        trustStore: any MobileDeviceIdentityStoring,
        listenerStart: @escaping ListenerStart,
        listenerStop: @escaping ListenerStop,
        stagingDirectory: URL,
        packageService: MobilePackageService,
        publishForwardSnapshot: @escaping PublishForwardSnapshot,
        previewReturn: @escaping PreviewReturn,
        handshakeTimeout: Duration = .seconds(30)
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.listenerStart = listenerStart
        self.listenerStop = listenerStop
        self.stagingDirectory = stagingDirectory
        self.packageService = packageService
        self.publishForwardSnapshotClosure = publishForwardSnapshot
        self.previewReturnClosure = previewReturn
        self.handshakeTimeout = handshakeTimeout
    }

    /// Starts advertising and returns the event stream for exactly one
    /// paired session. `confirmedSnapshot` is the exact snapshot the user
    /// already confirmed through the existing identity/summary review UI —
    /// see this type's doc comment on the confirmation handoff.
    public func startAdvertising(confirmedSnapshot: MobileLibrarySnapshot) async throws -> AsyncStream<NearbySyncEvent> {
        self.confirmedSnapshot = confirmedSnapshot
        didEmitTerminal = false
        let (stream, continuation) = AsyncStream<NearbySyncEvent>.makeStream()
        eventContinuation = continuation
        let connections: AsyncStream<any NearbyByteConnection>
        do {
            connections = try await listenerStart()
        } catch {
            eventContinuation = nil
            throw error
        }
        emit(.waitingForPhone)
        acceptLoopTask = Task { [weak self] in
            await self?.runAcceptLoop(connections)
        }
        return stream
    }

    /// Forwards to the live pairing session's own confirmation gate. A no-op
    /// if no session is currently waiting on a decision.
    public func confirmPairing() async {
        await currentPairingSession?.confirmPairing()
    }

    /// Forwards to the live pairing session's own rejection. A no-op if no
    /// session is currently waiting on a decision.
    public func rejectPairing() async {
        await currentPairingSession?.rejectPairing()
    }

    /// Removes `deviceID` from the Mac's own trust store — the recovery
    /// action behind "Forget this iPhone and pair again" on the
    /// `.failed(.identityChanged)` state, and the same action the "Forget
    /// paired devices" list in iPhone Sync settings offers per-peer. The
    /// next `startAdvertising` session with this deviceID then goes through
    /// a fresh first pairing instead of repeating the same
    /// `peerIdentityChanged` failure forever. Never touches the iPhone's own
    /// trust store, which must forget this Mac the same way on its side for
    /// the next handshake to succeed (see `NearbyPairingSessionTests
    /// .forgettingTheStalePeerOnBothSidesAfterIdentityChangedAllowsAFreshPairing`).
    public func forgetPeer(deviceID: UUID) throws {
        try trustStore.removeTrustedPeer(deviceID: deviceID)
    }

    /// The last known display name for `deviceID`, if the Mac still has it
    /// trusted. Used to label the recovery action with the iPhone's name
    /// instead of a bare UUID.
    public func trustedPeerDisplayName(deviceID: UUID) -> String? {
        (try? trustStore.trustedPeers())?.first { $0.deviceID == deviceID }?.displayName
    }

    /// Reports the outcome of a `.receivedReturn` review resolved through
    /// the caller's own apply/discard UI. A no-op unless a session is
    /// currently suspended waiting for exactly this call.
    public func reportReturnOutcome(_ outcome: NearbyReturnOutcome) async {
        guard let continuation = returnOutcomeContinuation else { return }
        returnOutcomeContinuation = nil
        continuation.resume(returning: outcome)
    }

    /// Cancels everything (any in-flight handshake, any session waiting on
    /// a local confirmation, any session waiting on `reportReturnOutcome`),
    /// stops the listener, and finishes the event stream with exactly one
    /// terminal event. Idempotent.
    public func stop() async {
        acceptLoopTask?.cancel()
        acceptLoopTask = nil
        if let session = currentPairingSession {
            currentPairingSession = nil
            await session.rejectPairing()
        }
        if let continuation = returnOutcomeContinuation {
            returnOutcomeContinuation = nil
            continuation.resume(returning: .notApplied)
        }
        finishTerminal(.failed(.cancelled))
        await listenerStop()
    }

    // MARK: - Accept loop

    /// Processes at most one connection to completion; any connection that
    /// arrives afterward (a second phone, or a retry attempt while the first
    /// is still being handled) is cancelled without any handshake
    /// engagement — "one at a time" (spec §7.2).
    private func runAcceptLoop(_ connections: AsyncStream<any NearbyByteConnection>) async {
        var acceptedFirst = false
        for await connection in connections {
            if acceptedFirst || didEmitTerminal {
                await connection.cancel()
                continue
            }
            acceptedFirst = true
            await runSession(over: connection)
        }
    }

    // MARK: - One session

    private func runSession(over connection: any NearbyByteConnection) async {
        // Every exit path below — success or any failure — must leave the
        // peer's own blocking `receive()` calls unable to hang forever.
        // Cancelling the connection here (idempotent; safe even after a
        // normal completion) guarantees that: whichever end is still
        // waiting on a frame that will now never arrive unblocks with
        // `NearbyTransportError.connectionClosed` instead of hanging until
        // the app quits.
        defer {
            let closingConnection = connection
            Task { await closingConnection.cancel() }
        }
        let session = NearbyPairingSession(
            role: .listener,
            identity: identity,
            trustStore: trustStore,
            connection: connection,
            timeout: handshakeTimeout
        )
        currentPairingSession = session
        let establishTask = Task { try await session.establish() }

        // A known-peer session throws `.shortAuthenticationCodeUnavailable`
        // here immediately — no `.pairingCode` event for it. A first-pairing
        // session resolves once both ephemeral keys are exchanged; awaiting
        // it here runs concurrently with `establishTask` driving the same
        // handshake forward (both operate on `session`, an actor).
        if let code = try? await session.shortAuthenticationCode {
            emit(.pairingCode(code))
        }

        let outcome: NearbyPairingOutcome
        do {
            outcome = try await establishTask.value
        } catch {
            currentPairingSession = nil
            finishTerminal(.failed(Self.mapHandshakeFailure(error)))
            await listenerStop()
            return
        }
        currentPairingSession = nil

        emit(.preparing)
        let packageTransport = NearbyPackageTransport(
            channel: outcome.channel,
            packageService: packageService,
            peer: outcome.peer,
            stagingDirectory: stagingDirectory
        )

        guard let snapshot = confirmedSnapshot else {
            // Cannot happen through the public entry point (`startAdvertising`
            // always sets this first), but fails closed rather than
            // force-unwrapping if it ever did.
            finishTerminal(.failed(.transferFailed))
            await listenerStop()
            return
        }

        let fileManager = FileManager.default
        let sendSessionDirectory = stagingDirectory.appendingPathComponent(
            "forward-\(outcome.peer.deviceID.uuidString)-\(UUID().uuidString)", isDirectory: true
        )
        let packageDestination = sendSessionDirectory.appendingPathComponent("package.astromobile", isDirectory: true)
        let wrapping = PairedDeviceKeyWrapping()
        do {
            // `MobilePackageService.export` stages its private replacement
            // directory as a SIBLING of `packageDestination` (i.e. inside
            // `sendSessionDirectory`, which must already exist as a real
            // directory before `export` ever runs) and only atomically
            // renames the result into `packageDestination` itself — that
            // final component must NOT exist yet.
            try fileManager.createDirectory(at: sendSessionDirectory, withIntermediateDirectories: true)
            let publication = try await publishForwardSnapshotClosure(snapshot, packageDestination, wrapping)
            emit(.transferring)
            try await packageTransport.sendStaged(packageDirectory: packageDestination, packageID: publication.packageID, wrapping: wrapping)
        } catch {
            try? fileManager.removeItem(at: sendSessionDirectory)
            finishTerminal(.failed(.transferFailed))
            await listenerStop()
            return
        }
        try? fileManager.removeItem(at: sendSessionDirectory)

        emit(.verifying)
        let review: MobileReturnApplicationReview?
        do {
            review = try await packageTransport.receiveOptionalReturn { [previewReturnClosure] directory, wrapping in
                try await previewReturnClosure(directory, wrapping)
            }
        } catch {
            finishTerminal(.failed(.transferFailed))
            await listenerStop()
            return
        }

        guard let review else {
            finishTerminal(.finished)
            await listenerStop()
            return
        }

        emit(.receivedReturn(review))
        let returnOutcome = await withCheckedContinuation { (continuation: CheckedContinuation<NearbyReturnOutcome, Never>) in
            returnOutcomeContinuation = continuation
        }
        switch returnOutcome {
        case .applied:
            finishTerminal(.finished)
        case .notApplied:
            finishTerminal(.failed(.applyRefused))
        }
        await listenerStop()
    }

    // MARK: - Event stream plumbing

    private func emit(_ event: NearbySyncEvent) {
        guard !didEmitTerminal else { return }
        eventContinuation?.yield(event)
    }

    private func finishTerminal(_ event: NearbySyncEvent) {
        guard !didEmitTerminal else { return }
        didEmitTerminal = true
        eventContinuation?.yield(event)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private static func mapHandshakeFailure(_ error: Error) -> NearbySyncFailure {
        guard let transportError = error as? NearbyTransportError else { return .transferFailed }
        switch transportError {
        case .pairingRejected, .pairingConfirmationFailed:
            return .pairingRejected
        case .peerIdentityChanged(let deviceID):
            return .identityChanged(deviceID: deviceID)
        case .handshakeTimeout:
            return .timeout
        default:
            return .transferFailed
        }
    }
}
