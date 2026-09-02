import Foundation

/// Typed, closed failure reasons a phone-side nearby sync session can end
/// with. Every case maps to exactly one localized string on the phone
/// screen — never a raw error surfaced to the UI. Mirrors
/// `NearbySyncFailure` (the Mac coordinator's counterpart), adapted to the
/// phone's role: it browses/connects instead of advertising, and a failed
/// import is its own distinct case (the Mac side never imports anything
/// itself on this leg).
public enum NearbyPhoneSyncFailure: Equatable, Sendable {
    /// Browsing for the Mac's published service, or connecting to it once
    /// found, did not succeed within the session's timeout.
    case peerNotFound
    /// Either side declined the six-digit short authentication code during
    /// a first pairing.
    case pairingRejected
    /// The Mac's presented identity key no longer matches the key this
    /// iPhone already trusts for it — a hard re-pairing signal, never
    /// silently accepted. Carries the Mac's deviceID so the recovery UI can
    /// offer "Forget this Mac and pair again" (`forgetPeer(deviceID:)`)
    /// without a second round trip to look it up.
    case identityChanged(deviceID: UUID)
    /// The handshake, or the wire-level exchange of package bytes, failed
    /// for a reason other than an idle stall.
    case transferFailed
    /// A `NearbySecureChannel` `send`/`receive` during the post-handshake
    /// transfer idled past its own `ioTimeout`
    /// (`NearbyTransportError.transferTimeout`) — a stalled Wi-Fi link, or a
    /// Mac that paired and then went silent, rather than a rejected or
    /// malformed transfer. Distinct from `.transferFailed` so the UI can say
    /// plainly that the CONNECTION stalled, not that something about the
    /// data was wrong.
    case connectionStalled
    /// The forward package arrived and was hash-verified at the wire layer,
    /// but the caller's own handling of it (staging and importing through
    /// `MobileLibraryStore`) failed — an unrelated library, a stale
    /// revision, or a damaged local package.
    case importFailed
    /// The handshake, or waiting for the Mac to answer, exceeded its
    /// timeout.
    case timeout
    /// `cancel()` ended the session before it reached a natural outcome.
    case cancelled
}

/// One state a phone-side nearby sync session passes through, in order, on
/// the `AsyncStream` `NearbyPhoneSyncSession.run` returns. The stream ends
/// with exactly one terminal state (`.finished` or `.failed`), never both,
/// never neither. Deliberately `Equatable` and payload-free everywhere it
/// can be, so a pure UI/test observer can compare states directly without
/// carrying wire types (the one exception, `.pairingCode`, only ever
/// carries the six digits a person reads and compares by eye anyway).
///
/// `.staged` marks the moment the forward package has been received,
/// hash-verified, and handed to the caller-supplied handler in `run` — the
/// handler itself receives the actual package location and unwrap key as
/// its own arguments, not through this stream, so this case carries no
/// payload of its own.
public enum NearbyPhoneSyncState: Equatable, Sendable {
    case idle
    case searching
    case pairingCode(String)
    case connecting
    case receiving
    case staged
    case sendingReturn
    case finished
    case failed(NearbyPhoneSyncFailure)
}

/// What a `NearbyPhoneSyncSession.run` handler hands back when the phone has
/// its own changes to send to the Mac: an already-exported package
/// directory (produced by the caller's own unmodified export path — see
/// `NearbyPhoneSyncSession`'s doc comment), the package's ID, and the
/// `pairedDevice`-style key that directory was wrapped with.
public struct NearbyPhoneReturnPackage: Sendable {
    public let packageDirectory: URL
    public let packageID: UUID
    public let wrapping: PairedDeviceKeyWrapping

    public init(packageDirectory: URL, packageID: UUID, wrapping: PairedDeviceKeyWrapping) {
        self.packageDirectory = packageDirectory
        self.packageID = packageID
        self.wrapping = wrapping
    }
}

/// The iPhone-side production driver for the direct (non-AirDrop) nearby
/// sync flow: browse for the Mac's advertised service, pair with it,
/// receive its forward package, hand that package off to the caller, and —
/// if the caller has something to send back — carry an already-exported
/// return package over the same authenticated session.
///
/// ## Platform-neutral by design
/// This type lives in `AstroMobileTransport` (cross-platform SwiftPM),
/// never in the iOS-only app target, specifically so it stays unit
/// testable under `swift test`: `Sources/AstroToolMobile` compiles only in
/// the Xcode project graph and its own test target is Xcode-only, so any
/// logic placed there has no SwiftPM verification at all. Everything this
/// type touches — `NearbyPairingSession`, `NearbyPackageTransport`, the
/// `NearbyByteConnection` protocol — already has its own SwiftPM coverage
/// against `InMemoryDuplexConnection`; this actor's own job is only to
/// sequence those pieces the way the phone's role requires, which is what
/// `NearbyPhoneSyncSessionTests` (also SwiftPM) exercises directly. The
/// phone app (`MobileNearbySyncScreen.swift`, Xcode-only) is left with
/// nothing but SwiftUI presentation and a call into this actor plus the
/// two existing `MobileLibraryStore` routes (staging/importing a received
/// package, exporting a queued return package) — no new mutation surface.
///
/// ## Message choreography (mirrors `NearbySyncCoordinator`'s Mac side
/// exactly — see that type's own doc comment, and
/// `NearbySyncCoordinatorTests.runPhoneSession`, which already drives a
/// phone-shaped test double through this exact sequence against the real
/// Mac coordinator)
/// 1. `NearbyPairingSession(role: .initiator, …).establish()` — the SAME
///    handshake actor the Mac side runs as `.listener`. A first pairing
///    surfaces the six-digit code exactly as the Mac side does; a known
///    peer skips straight to traffic keys.
/// 2. `NearbyPackageTransport.receiveStagedForReturnApplication` receives
///    the Mac's forward package: hash-verified at the wire layer, but
///    never auto-committed through a bare `MobilePackageService` (that
///    would bypass `MobileLibraryStore`'s own validating import path —
///    revision monotonicity, library-ID match, key-fingerprint dedup —
///    exactly the same gates an AirDropped package goes through). Instead
///    the staged directory and the reconstructed `PairedDeviceKeyWrapping`
///    are handed to the caller's `handleForwardPackage` closure, which is
///    expected to call `MobileLibraryStore.stagePackage` then
///    `importCurrentStagedPackage(pairedWrapping:)` — the same two calls,
///    generalized over the wrap-key type, that the AirDrop path already
///    makes with `importCurrentStagedPackage(keyPayload:)`.
/// 3. If that closure returns a `NearbyPhoneReturnPackage` (built from the
///    UNMODIFIED `MobileLibraryStore.exportReturnPackage` output — see that
///    type's own doc comment on why its `OneTimePackageKey` output is
///    carried here as a `PairedDeviceKeyWrapping` built from the exact same
///    raw bytes), it is sent with `NearbyPackageTransport.sendStaged`
///    exactly like the Mac's own forward publish. If it returns `nil` —
///    nothing queued to send back — this session sends the transport's own
///    `.acknowledgement` message with an empty ID list, the exact "nothing
///    to return" signal `NearbySyncCoordinator.runSession`'s
///    `receiveOptionalReturn` call already expects and treats as a clean
///    `.finished` on the Mac side (never as a failure).
/// 4. Any failure at any step — including the closure itself throwing,
///    e.g. because `MobileLibraryStore` rejected the package — ends the
///    session in exactly one `.failed` state and best-effort tells the Mac
///    side to abort too (`.failure` message), so its own
///    `receiveOptionalReturn` fails closed instead of reporting a false
///    `.finished`.
public actor NearbyPhoneSyncSession {
    /// Finds and connects to the Mac's advertised service, racing the
    /// caller-supplied timeout itself (mirrors
    /// `NearbyBonjourBrowser.connectToFirstMatch`'s own contract, which the
    /// production initializer wires up directly). Injectable so tests can
    /// hand back a pre-wired `InMemoryDuplexConnection` end instead of
    /// touching Bonjour.
    package typealias Connect = @Sendable (Duration) async throws -> any NearbyByteConnection

    private let identity: MobileDeviceIdentity
    private let trustStore: any MobileDeviceIdentityStoring
    private let connect: Connect
    private let packageService: MobilePackageService
    private let stagingDirectory: URL
    private let timeout: Duration

    private var eventContinuation: AsyncStream<NearbyPhoneSyncState>.Continuation?
    private var currentPairingSession: NearbyPairingSession?
    private var currentConnection: (any NearbyByteConnection)?
    private var runTask: Task<Void, Never>?
    private var didEmitTerminal = false

    /// Production construction: a Keychain-backed identity store and a
    /// real `NearbyBonjourBrowser`. No caller-supplied envelope or importer
    /// seam exists here — mirrors `NearbySyncCoordinator.init(rootURL:
    /// displayName:)`'s own hardening.
    public init(rootURL: URL, displayName: String, timeout: Duration = .seconds(30)) throws {
        let identityStore = KeychainDeviceIdentityStore()
        let identity = try identityStore.loadOrCreateOwnIdentity(displayName: displayName)
        let browser = NearbyBonjourBrowser()
        self.init(
            identity: identity,
            trustStore: identityStore,
            connect: { attemptTimeout in try await browser.connectToFirstMatch(timeout: attemptTimeout) },
            packageService: MobilePackageService(),
            stagingDirectory: rootURL.appendingPathComponent(".astro-tool/nearby-staging", isDirectory: true),
            timeout: timeout
        )
    }

    /// Injectable seam for tests: an in-memory identity store, a
    /// caller-supplied connection source standing in for
    /// `NearbyBonjourBrowser`, and an isolated staging directory. `package`
    /// visibility: unreachable outside `@testable import
    /// AstroMobileTransport`.
    package init(
        identity: MobileDeviceIdentity,
        trustStore: any MobileDeviceIdentityStoring,
        connect: @escaping Connect,
        packageService: MobilePackageService,
        stagingDirectory: URL,
        timeout: Duration = .seconds(30)
    ) {
        self.identity = identity
        self.trustStore = trustStore
        self.connect = connect
        self.packageService = packageService
        self.stagingDirectory = stagingDirectory
        self.timeout = timeout
    }

    /// Starts exactly one session and returns its state stream.
    /// `handleForwardPackage` is called once, with the staged directory and
    /// unwrap key for the package the Mac sent, after that package has
    /// already been hash-verified at the wire layer — see this type's own
    /// doc comment for the full choreography. Calling `run` again before
    /// the previous stream reached a terminal state replaces it (the prior
    /// stream simply stops receiving further states); callers are expected
    /// to call this once per user-initiated attempt.
    public func run(
        handleForwardPackage: @escaping @Sendable (URL, PairedDeviceKeyWrapping) async throws -> NearbyPhoneReturnPackage?
    ) -> AsyncStream<NearbyPhoneSyncState> {
        didEmitTerminal = false
        let (stream, continuation) = AsyncStream<NearbyPhoneSyncState>.makeStream()
        eventContinuation = continuation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(handleForwardPackage: handleForwardPackage)
        }
        runTask = task
        return stream
    }

    /// Forwards to the live pairing session's own confirmation gate. A
    /// no-op if no session is currently waiting on a decision.
    public func confirmPairing() async {
        await currentPairingSession?.confirmPairing()
    }

    /// Forwards to the live pairing session's own rejection. A no-op if no
    /// session is currently waiting on a decision.
    public func rejectPairing() async {
        await currentPairingSession?.rejectPairing()
    }

    /// Removes `deviceID` from this iPhone's own trust store — the recovery
    /// action behind "Forget this Mac and pair again" on the
    /// `.failed(.identityChanged)` screen. The next `run()` call then goes
    /// through a fresh first pairing instead of repeating the same
    /// `peerIdentityChanged` failure forever. Never touches the Mac's own
    /// trust store, which must forget this iPhone the same way on its side
    /// for the next handshake to succeed (see `NearbyPairingSessionTests
    /// .forgettingTheStalePeerOnBothSidesAfterIdentityChangedAllowsAFreshPairing`).
    public func forgetPeer(deviceID: UUID) throws {
        try trustStore.removeTrustedPeer(deviceID: deviceID)
    }

    /// The last known display name for `deviceID`, if this iPhone still has
    /// it trusted. Used to label the recovery action with the Mac's name
    /// ("Forget MacBook Pro and pair again") instead of a bare UUID.
    public func trustedPeerDisplayName(deviceID: UUID) -> String? {
        (try? trustStore.trustedPeers())?.first { $0.deviceID == deviceID }?.displayName
    }

    /// Cancels the in-flight session (any browse/connect attempt, any
    /// handshake, any confirmation wait) and finishes the state stream with
    /// exactly one terminal `.failed(.cancelled)` state. Idempotent. A
    /// cancellation that arrives after `handleForwardPackage` has already
    /// started running is NOT interrupted mid-flight — that closure owns
    /// its own atomicity (`MobileLibraryStore`'s own import path never
    /// leaves partial state either way) — but every step before it checks
    /// for cancellation first, so a cancel during browsing, pairing, or the
    /// wire-level receive never reaches the closure at all.
    public func cancel() async {
        runTask?.cancel()
        runTask = nil
        if let session = currentPairingSession {
            currentPairingSession = nil
            await session.rejectPairing()
        }
        if let connection = currentConnection {
            currentConnection = nil
            await connection.cancel()
        }
        finishTerminal(.failed(.cancelled))
    }

    // MARK: - One session

    private func execute(
        handleForwardPackage: @escaping @Sendable (URL, PairedDeviceKeyWrapping) async throws -> NearbyPhoneReturnPackage?
    ) async {
        emit(.searching)
        let connection: any NearbyByteConnection
        do {
            connection = try await connect(timeout)
        } catch {
            finishTerminal(.failed(.peerNotFound))
            return
        }
        guard !Task.isCancelled else {
            await connection.cancel()
            finishTerminal(.failed(.cancelled))
            return
        }
        currentConnection = connection
        defer {
            let closingConnection = connection
            Task { await closingConnection.cancel() }
        }

        emit(.connecting)
        let session = NearbyPairingSession(
            role: .initiator,
            identity: identity,
            trustStore: trustStore,
            connection: connection,
            timeout: timeout
        )
        currentPairingSession = session
        let establishTask = Task { try await session.establish() }

        if let code = try? await session.shortAuthenticationCode {
            emit(.pairingCode(code))
        }

        let outcome: NearbyPairingOutcome
        do {
            outcome = try await establishTask.value
        } catch {
            currentPairingSession = nil
            finishTerminal(.failed(Self.mapHandshakeFailure(error)))
            return
        }
        currentPairingSession = nil
        currentConnection = nil

        guard !Task.isCancelled else {
            finishTerminal(.failed(.cancelled))
            return
        }

        emit(.receiving)
        let packageTransport = NearbyPackageTransport(
            channel: outcome.channel,
            packageService: packageService,
            peer: outcome.peer,
            stagingDirectory: stagingDirectory
        )

        let returnPackage: NearbyPhoneReturnPackage?
        do {
            returnPackage = try await packageTransport.receiveStagedForReturnApplication { directory, wrapping in
                guard !Task.isCancelled else { throw CancellationError() }
                return try await handleForwardPackage(directory, wrapping)
            }
        } catch {
            try? await outcome.channel.send(.failure(NearbyFailureMessage(reason: .transferAborted)))
            finishTerminal(.failed(Self.mapPackageFailure(error)))
            return
        }
        emit(.staged)

        guard !Task.isCancelled else {
            finishTerminal(.failed(.cancelled))
            return
        }

        if let returnPackage {
            emit(.sendingReturn)
            do {
                try await packageTransport.sendStaged(
                    packageDirectory: returnPackage.packageDirectory,
                    packageID: returnPackage.packageID,
                    wrapping: returnPackage.wrapping
                )
            } catch {
                finishTerminal(.failed(Self.mapPackageFailure(error)))
                return
            }
        } else {
            do {
                try await outcome.channel.send(.acknowledgement(NearbyAcknowledgementMessage(acknowledgedChangeIDs: [])))
            } catch {
                finishTerminal(.failed(Self.mapPackageFailure(error)))
                return
            }
        }

        finishTerminal(.finished)
    }

    // MARK: - Event stream plumbing

    private func emit(_ event: NearbyPhoneSyncState) {
        guard !didEmitTerminal else { return }
        eventContinuation?.yield(event)
    }

    private func finishTerminal(_ event: NearbyPhoneSyncState) {
        guard !didEmitTerminal else { return }
        didEmitTerminal = true
        eventContinuation?.yield(event)
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private static func mapHandshakeFailure(_ error: Error) -> NearbyPhoneSyncFailure {
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

    /// Distinguishes a wire-level failure (`NearbyPackageTransportError`, or
    /// a `NearbyTransportError` from the underlying channel/connection —
    /// both already mean the Mac side's own `.failure` handling, if any,
    /// already ran) from `handleForwardPackage` itself throwing, which this
    /// module cannot type — the caller's own `MobileLibraryStore` errors are
    /// not visible here, so any other error is reported as `.importFailed`.
    private static func mapPackageFailure(_ error: Error) -> NearbyPhoneSyncFailure {
        if error is NearbyPackageTransportError { return .transferFailed }
        if let transportError = error as? NearbyTransportError {
            switch transportError {
            case .handshakeTimeout: return .timeout
            case .transferTimeout: return .connectionStalled
            default: return .transferFailed
            }
        }
        return .importFailed
    }
}
