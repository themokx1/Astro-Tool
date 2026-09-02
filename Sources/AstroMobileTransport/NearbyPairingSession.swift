import CryptoKit
import Foundation
import Security

/// Which side of a pairing handshake this device is playing. The protocol is
/// symmetric in every other respect; the role only decides fixed ordering
/// (session ID, transcript hash) and which HKDF-labelled traffic key flows
/// which way.
public enum NearbyRole: Sendable, Equatable {
    case listener
    case initiator

    var opposite: NearbyRole {
        switch self {
        case .listener: return .initiator
        case .initiator: return .listener
        }
    }

    /// The byte a `.pairingConfirm` proof binds itself to, so a peer cannot
    /// replay the verifier's own confirmation message back at it.
    var confirmRoleByte: UInt8 {
        switch self {
        case .listener: return 0
        case .initiator: return 1
        }
    }

    var trafficKeyInfo: Data {
        switch self {
        case .listener: return Data("astrotool-nearby-traffic-listener".utf8)
        case .initiator: return Data("astrotool-nearby-traffic-initiator".utf8)
        }
    }
}

/// What `NearbyPairingSession.establish()` returns on success.
public struct NearbyPairingOutcome: Sendable {
    public let channel: NearbySecureChannel
    public let peer: MobilePeerIdentity
    public let wasFirstPairing: Bool
}

/// Drives one authenticated pairing handshake to completion over a
/// `NearbyByteConnection`: hello → ephemeral key exchange → (first pairing
/// only) short-authentication-code confirmation → traffic key derivation.
///
/// Trust-on-first-use (plan ruling 2): if the peer's deviceID is already in
/// `trustStore`, this is a **known-peer** session — the peer's `.hello`-
/// supplied identity key is checked against the STORED key (a mismatch is
/// the terminal `peerIdentityChanged`, never a silent replace), and once
/// signatures verify, traffic keys are derived immediately with no SAS
/// prompt. If the deviceID is unknown, this is a **first-pairing** session —
/// `shortAuthenticationCode` becomes available once both ephemeral keys are
/// exchanged and verified, `establish()` suspends until `confirmPairing()`
/// or `rejectPairing()` is called, and only a confirmation from BOTH sides
/// (the local call, and a peer `.pairingConfirm` whose HMAC proof verifies)
/// causes the peer identity to be stored and traffic keys derived.
///
/// `shortAuthenticationCode` on a known-peer session throws
/// `.shortAuthenticationCodeUnavailable` — as soon as the peer's identity is
/// recognized (early in `establish()`), so this is true whether it is
/// awaited during or after `establish()`. On a first-pairing session it
/// resolves to the 6-digit code once derivable and stays resolved (readable
/// again) after `establish()` returns.
///
/// Every await on the connection (each `send`/`receive` during the
/// handshake) races the configured timeout; a peer that stops answering
/// causes `establish()` to throw `.handshakeTimeout` and cancels the
/// connection rather than hanging forever. Waiting for the LOCAL caller to
/// invoke `confirmPairing()`/`rejectPairing()` is not connection I/O and is
/// never subject to this timeout.
public actor NearbyPairingSession {
    private let role: NearbyRole
    private let identity: MobileDeviceIdentity
    private let trustStore: any MobileDeviceIdentityStoring
    private let connection: any NearbyByteConnection
    private let timeout: Duration

    private enum SASState {
        case pending
        case resolved(Result<String, Error>)
    }
    private var sasState: SASState = .pending
    private var pendingSASContinuations: [CheckedContinuation<String, Error>] = []

    private enum LocalDecision {
        case confirmed
        case rejected
    }
    private var localDecision: LocalDecision?
    private var confirmationContinuation: CheckedContinuation<Void, Never>?

    /// The peer's `.hello`-supplied display name, set as soon as that
    /// message is received — before the ephemeral key exchange, and so
    /// before `shortAuthenticationCode` ever resolves. Multi-Mac/multi-
    /// iPhone disambiguation (fix item 3): the pairing-code confirmation UI
    /// needs to say WHICH device answered before the user compares digits,
    /// not just after `establish()` returns.
    private var resolvedPeerDisplayName: String = ""

    public init(
        role: NearbyRole,
        identity: MobileDeviceIdentity,
        trustStore: any MobileDeviceIdentityStoring,
        connection: any NearbyByteConnection,
        timeout: Duration = .seconds(30)
    ) {
        self.role = role
        self.identity = identity
        self.trustStore = trustStore
        self.connection = connection
        self.timeout = timeout
    }

    /// The six-digit short authentication code for a first pairing. Suspends
    /// until it is derivable; throws `.shortAuthenticationCodeUnavailable`
    /// immediately once this session is known to be a known-peer session (no
    /// code will ever be produced), or rethrows whatever error aborted the
    /// handshake before a code was ever derived.
    public var shortAuthenticationCode: String {
        get async throws {
            switch sasState {
            case .resolved(let result):
                return try result.get()
            case .pending:
                return try await withCheckedThrowingContinuation { continuation in
                    pendingSASContinuations.append(continuation)
                }
            }
        }
    }

    /// Records local acceptance of the short authentication code. A no-op if
    /// a local decision was already made, or on a known-peer session (which
    /// never suspends for one).
    public func confirmPairing() async {
        guard localDecision == nil else { return }
        localDecision = .confirmed
        confirmationContinuation?.resume()
        confirmationContinuation = nil
    }

    /// The peer's display name, readable as soon as its `.hello` message has
    /// been received — empty until then. By the time
    /// `shortAuthenticationCode` resolves (which requires the peer's hello
    /// AND its key exchange) this is always already populated, so a caller
    /// can safely read it right alongside the code.
    public var peerDisplayName: String {
        resolvedPeerDisplayName
    }

    /// Records local rejection of the short authentication code. A no-op if
    /// a local decision was already made.
    public func rejectPairing() async {
        guard localDecision == nil else { return }
        localDecision = .rejected
        confirmationContinuation?.resume()
        confirmationContinuation = nil
    }

    public func establish() async throws -> NearbyPairingOutcome {
        do {
            return try await runHandshake()
        } catch {
            failSAS(with: error)
            await connection.cancel()
            throw error
        }
    }

    // MARK: - Handshake

    private func runHandshake() async throws -> NearbyPairingOutcome {
        let ownHelloNonce = Self.randomBytes(16)
        let ownIdentityPub = identity.publicIdentity.signingPublicKeyRawRepresentation

        try await sendFrame(NearbySessionMessage.hello(NearbyHelloMessage(
            protocolVersion: NearbyFrameCodec.currentProtocolVersion,
            deviceID: identity.deviceID,
            displayName: identity.publicIdentity.displayName,
            signingPublicKeyRawRepresentation: ownIdentityPub,
            helloNonce: ownHelloNonce
        )).encodedFrame())

        let peerHello = try await receiveMessage { message in
            guard case .hello(let hello) = message else { throw NearbyTransportError.unexpectedMessage }
            return hello
        }
        guard peerHello.protocolVersion == NearbyFrameCodec.currentProtocolVersion else {
            throw NearbyTransportError.unsupportedVersion(peerHello.protocolVersion)
        }
        guard peerHello.helloNonce.count == 16,
              peerHello.signingPublicKeyRawRepresentation.count == 32 else {
            throw NearbyTransportError.invalidMessage
        }
        // Set as soon as the hello is structurally valid -- well before the
        // trust decision, key exchange, or SAS derivation below, so
        // `peerDisplayName` is already readable the instant a caller sees
        // the pairing code (fix item 3).
        resolvedPeerDisplayName = peerHello.displayName

        // Trust decision, from the hello exchange alone.
        let storedPeer = try trustStore.trustedPeers().first { $0.deviceID == peerHello.deviceID }
        let peerIdentityPub: Data
        let isFirstPairing: Bool
        if let storedPeer {
            guard storedPeer.signingPublicKeyRawRepresentation == peerHello.signingPublicKeyRawRepresentation else {
                throw NearbyTransportError.peerIdentityChanged(peerHello.deviceID)
            }
            peerIdentityPub = storedPeer.signingPublicKeyRawRepresentation
            isFirstPairing = false
            // A known peer never gets a SAS prompt; resolve this immediately
            // so an already-awaiting caller does not hang until establish()
            // eventually returns.
            failSAS(with: NearbyTransportError.shortAuthenticationCodeUnavailable)
        } else {
            peerIdentityPub = peerHello.signingPublicKeyRawRepresentation
            isFirstPairing = true
        }

        // Ephemeral key exchange, signed over each side's own view of the
        // transcript so far.
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let ownEphemeralPub = ephemeralKey.publicKey.rawRepresentation
        let ownContribution = Self.randomBytes(16)

        let ownDigest = SHA256.hash(data: Self.signedTranscript(
            protocolVersion: NearbyFrameCodec.currentProtocolVersion,
            ownIdentityPub: ownIdentityPub,
            peerIdentityPub: peerIdentityPub,
            ownEphemeralPub: ownEphemeralPub,
            ownContribution: ownContribution,
            ownHelloNonce: ownHelloNonce,
            peerHelloNonce: peerHello.helloNonce
        ))
        let ownSignature = try identity.signingKey.signature(for: Data(ownDigest))

        try await sendFrame(NearbySessionMessage.keyExchange(NearbyKeyExchangeMessage(
            ephemeralPublicKey: ownEphemeralPub,
            sessionIDContribution: ownContribution,
            identitySignature: Data(ownSignature)
        )).encodedFrame())

        let peerKeyExchange = try await receiveMessage { message in
            guard case .keyExchange(let exchange) = message else { throw NearbyTransportError.unexpectedMessage }
            return exchange
        }
        guard peerKeyExchange.ephemeralPublicKey.count == 32,
              peerKeyExchange.sessionIDContribution.count == 16,
              peerKeyExchange.identitySignature.count == 64,
              let peerIdentityKey = try? Curve25519.Signing.PublicKey(rawRepresentation: peerIdentityPub),
              let peerEphemeralKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyExchange.ephemeralPublicKey)
        else {
            throw NearbyTransportError.signatureVerificationFailed
        }

        let peerDigest = SHA256.hash(data: Self.signedTranscript(
            protocolVersion: NearbyFrameCodec.currentProtocolVersion,
            ownIdentityPub: peerIdentityPub,
            peerIdentityPub: ownIdentityPub,
            ownEphemeralPub: peerKeyExchange.ephemeralPublicKey,
            ownContribution: peerKeyExchange.sessionIDContribution,
            ownHelloNonce: peerHello.helloNonce,
            peerHelloNonce: ownHelloNonce
        ))
        guard peerIdentityKey.isValidSignature(peerKeyExchange.identitySignature, for: Data(peerDigest)) else {
            throw NearbyTransportError.signatureVerificationFailed
        }

        // Fixed listener/initiator ordering, independent of which role this
        // instance is playing.
        let listenerContribution = role == .listener ? ownContribution : peerKeyExchange.sessionIDContribution
        let initiatorContribution = role == .initiator ? ownContribution : peerKeyExchange.sessionIDContribution
        let sessionID = Data(SHA256.hash(data: listenerContribution + initiatorContribution).prefix(16))

        let listenerIdentityPub = role == .listener ? ownIdentityPub : peerIdentityPub
        let initiatorIdentityPub = role == .initiator ? ownIdentityPub : peerIdentityPub
        let listenerEphemeralPub = role == .listener ? ownEphemeralPub : peerKeyExchange.ephemeralPublicKey
        let initiatorEphemeralPub = role == .initiator ? ownEphemeralPub : peerKeyExchange.ephemeralPublicKey

        let transcriptHash = Data(SHA256.hash(
            data: Data([NearbyFrameCodec.currentProtocolVersion])
                + listenerIdentityPub + initiatorIdentityPub
                + listenerEphemeralPub + initiatorEphemeralPub
                + sessionID
        ))

        if isFirstPairing {
            resolveSAS(with: Self.shortAuthenticationCode(fromTranscriptHash: transcriptHash))
        }

        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: peerEphemeralKey)

        if isFirstPairing {
            await waitForLocalDecision()
            guard localDecision == .confirmed else {
                try? await sendFrame(NearbySessionMessage.failure(
                    NearbyFailureMessage(reason: .handshakeFailed)
                ).encodedFrame())
                throw NearbyTransportError.pairingRejected
            }

            let confirmKey = sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: transcriptHash,
                sharedInfo: Data("astrotool-nearby-confirm".utf8),
                outputByteCount: 32
            )
            let ownProof = HMAC<SHA256>.authenticationCode(
                for: Data([role.confirmRoleByte]) + transcriptHash,
                using: confirmKey
            )
            try await sendFrame(NearbySessionMessage.pairingConfirm(
                NearbyPairingConfirmMessage(proof: Data(ownProof))
            ).encodedFrame())

            let peerConfirm = try await receiveMessage { message in
                guard case .pairingConfirm(let confirm) = message else { throw NearbyTransportError.unexpectedMessage }
                return confirm
            }
            let peerProofIsValid = HMAC<SHA256>.isValidAuthenticationCode(
                peerConfirm.proof,
                authenticating: Data([role.opposite.confirmRoleByte]) + transcriptHash,
                using: confirmKey
            )
            guard peerProofIsValid else {
                try? await sendFrame(NearbySessionMessage.failure(
                    NearbyFailureMessage(reason: .handshakeFailed)
                ).encodedFrame())
                throw NearbyTransportError.pairingConfirmationFailed
            }

            try trustStore.storeTrustedPeer(MobilePeerIdentity(
                deviceID: peerHello.deviceID,
                signingPublicKeyRawRepresentation: peerHello.signingPublicKeyRawRepresentation,
                displayName: peerHello.displayName
            ))
        }

        // Reuses this session's own handshake `timeout` as the channel's
        // post-handshake I/O timeout, rather than adding a second
        // caller-configurable duration: both bound "an await on this same
        // connection that should complete quickly against a cooperative
        // peer," and every production/test call site that configures one
        // already means the same thing for the other (see
        // `NearbySyncCoordinator`/`NearbyPhoneSyncSession`, which both pass
        // a single `timeout`/`handshakeTimeout` through to this initializer).
        let channel = NearbySecureChannel(
            connection: connection,
            sendKey: Self.deriveTrafficKey(sharedSecret: sharedSecret, transcriptHash: transcriptHash, sender: role),
            receiveKey: Self.deriveTrafficKey(sharedSecret: sharedSecret, transcriptHash: transcriptHash, sender: role.opposite),
            ioTimeout: timeout
        )

        return NearbyPairingOutcome(
            channel: channel,
            peer: MobilePeerIdentity(
                deviceID: peerHello.deviceID,
                signingPublicKeyRawRepresentation: peerIdentityPub,
                displayName: peerHello.displayName
            ),
            wasFirstPairing: isFirstPairing
        )
    }

    // MARK: - Local confirmation gate

    private func waitForLocalDecision() async {
        guard localDecision == nil else { return }
        await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
        }
    }

    // MARK: - Short authentication code plumbing

    private func resolveSAS(with code: String) {
        guard case .pending = sasState else { return }
        sasState = .resolved(.success(code))
        let waiters = pendingSASContinuations
        pendingSASContinuations = []
        for waiter in waiters { waiter.resume(returning: code) }
    }

    private func failSAS(with error: Error) {
        guard case .pending = sasState else { return }
        sasState = .resolved(.failure(error))
        let waiters = pendingSASContinuations
        pendingSASContinuations = []
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    // MARK: - Connection I/O with timeout

    private func sendFrame(_ frame: NearbyFrame) async throws {
        try await withTimeout { try await self.connection.send(frame) }
    }

    private func receiveFrame() async throws -> NearbyFrame {
        try await withTimeout { try await self.connection.receive() }
    }

    /// A `.failure` frame at any handshake step means the peer aborted; this
    /// is always surfaced as `.pairingRejected` rather than reaching the
    /// caller-supplied extractor (which would otherwise report the less
    /// specific `.unexpectedMessage`).
    private func receiveMessage<T>(_ extract: (NearbySessionMessage) throws -> T) async throws -> T {
        let frame = try await receiveFrame()
        let message = try NearbySessionMessage(frame: frame)
        if case .failure = message {
            throw NearbyTransportError.pairingRejected
        }
        return try extract(message)
    }

    /// Races `operation` against `timeout`. The two child tasks never both
    /// try to decide the outcome: the timeout branch only ever returns the
    /// `nil` sentinel (never touches the connection), so whichever of the
    /// two `group.next()` sees first is the genuine, uncontested winner.
    /// Only AFTER that winner is committed to do we (if it was the timeout)
    /// cancel the connection — purely to unblock the loser so the implicit
    /// "await remaining children" when the task group scope exits cannot
    /// hang forever. That unblocked loser's own result/error, if any, is
    /// simply discarded by the group's cleanup; it can no longer influence
    /// what this call already decided to return or throw.
    private func withTimeout<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                return nil
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                throw NearbyTransportError.handshakeTimeout
            }
            if let value = first {
                group.cancelAll()
                return value
            }
            // The timeout sentinel won the race: commit to failing before
            // touching the connection.
            await connection.cancel()
            group.cancelAll()
            throw NearbyTransportError.handshakeTimeout
        }
    }

    // MARK: - Transcript / key derivation

    /// `protocolVersion(1) ‖ ownIdentityPub(32) ‖ peerIdentityPub(32) ‖
    /// ownEphemeralPub(32) ‖ ownContribution(16) ‖ ownHelloNonce(16) ‖
    /// peerHelloNonce(16)` — every field is a fixed length (validated on any
    /// peer-supplied value before this is called), so the concatenation is
    /// injective.
    ///
    /// `ownContribution` is the signer's own `sessionIDContribution` (the
    /// same 16 random bytes carried alongside the signature in the same
    /// `.keyExchange` message) — folded into the signed transcript so an
    /// on-path attacker cannot tamper a relayed `.keyExchange`'s
    /// `sessionIDContribution` field without also failing the known-peer
    /// signature check. Only the SIGNER's own contribution is ever included:
    /// this digest is computed before the peer's `.keyExchange` (and thus
    /// its contribution) has arrived, so each side signs its own view of the
    /// transcript — a verifier passes the value it actually received from
    /// the peer (`peerKeyExchange.sessionIDContribution`) as `ownContribution`
    /// here, since that is what the peer, as signer, included.
    private static func signedTranscript(
        protocolVersion: UInt8,
        ownIdentityPub: Data,
        peerIdentityPub: Data,
        ownEphemeralPub: Data,
        ownContribution: Data,
        ownHelloNonce: Data,
        peerHelloNonce: Data
    ) -> Data {
        Data([protocolVersion]) + ownIdentityPub + peerIdentityPub + ownEphemeralPub + ownContribution + ownHelloNonce + peerHelloNonce
    }

    private static func shortAuthenticationCode(fromTranscriptHash hash: Data) -> String {
        let firstFourBytes = hash.prefix(4)
        let value = firstFourBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06d", value % 1_000_000)
    }

    private static func deriveTrafficKey(sharedSecret: SharedSecret, transcriptHash: Data, sender: NearbyRole) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: sender.trafficKeyInfo,
            outputByteCount: 32
        )
    }

    private static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        return data
    }
}
