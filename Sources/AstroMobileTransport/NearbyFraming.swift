import Foundation

/// The kinds of frames the nearby wire protocol can carry. Each raw byte is
/// the second header byte on the wire, so changing an existing case's raw
/// value is a wire-breaking change.
public enum NearbyFrameKind: UInt8, CaseIterable, Sendable {
    case hello = 1
    case keyExchange = 2
    case pairingConfirm = 3
    case packageManifest = 4
    case packageChunk = 5
    case packageComplete = 6
    case acknowledgement = 7
    case failure = 8
}

/// A single versioned, length-prefixed frame on the nearby wire.
///
/// Wire layout (big-endian): `[version:1][kind:1][length:4][payload:length]`.
public struct NearbyFrame: Equatable, Sendable {
    public let version: UInt8
    public let kind: NearbyFrameKind
    public let payload: Data

    public init(version: UInt8 = NearbyFrameCodec.currentProtocolVersion, kind: NearbyFrameKind, payload: Data) {
        self.version = version
        self.kind = kind
        self.payload = payload
    }
}

/// Failures the nearby wire layer can raise. Every case is closed and typed —
/// no free-text ever crosses from a peer into application-visible state.
public enum NearbyTransportError: Error, Equatable, Sendable {
    /// Fewer bytes are available than the declared frame needs (including a
    /// buffer shorter than the fixed header itself).
    case incompleteFrame
    /// The declared payload length exceeds `NearbyFrameCodec.maxFramePayloadBytes`.
    case frameTooLarge
    /// The frame declares a protocol version this build does not speak.
    case unsupportedVersion(UInt8)
    /// The frame declares a kind byte with no known `NearbyFrameKind` case.
    case unknownFrameKind(UInt8)
    /// A frame decoded structurally but its payload did not decode into the
    /// `NearbySessionMessage` its frame kind demands.
    case invalidMessage
    /// `storeTrustedPeer` was asked to persist a deviceID that is already
    /// trusted under a DIFFERENT public key. The store never silently
    /// replaces a known peer's key — this is a hard re-pairing signal.
    case peerIdentityChanged(UUID)
    /// A device identity store's persisted bytes did not decode into a valid
    /// identity or peer list (malformed JSON, wrong-length key material). The
    /// store fails closed rather than guessing at recovery.
    case identityStoreCorrupted

    /// An await on the connection (send or receive) during the pairing
    /// handshake did not complete within the session's configured timeout.
    /// Terminal: the underlying connection is cancelled as part of raising
    /// this error.
    case handshakeTimeout
    /// A `NearbyByteConnection` was cancelled (or otherwise closed) while a
    /// `send`/`receive` was pending or subsequently attempted on it.
    case connectionClosed
    /// A frame decoded into a `NearbySessionMessage` of a kind the handshake
    /// did not expect at this step (e.g. a `.packageChunk` where `.hello` was
    /// required).
    case unexpectedMessage
    /// A peer's `.keyExchange` signature did not verify against the identity
    /// key that applies for this session (the stored key for a known peer,
    /// or the hello-supplied key for a first pairing) — or a peer-supplied
    /// key/nonce field had the wrong byte length to be genuine. Terminal.
    case signatureVerificationFailed
    /// Either side declined the short authentication code during a first
    /// pairing. Terminal; nothing is persisted to either trust store.
    case pairingRejected
    /// A first-pairing peer's `.pairingConfirm` HMAC proof did not match the
    /// value expected from the shared transcript. Terminal.
    case pairingConfirmationFailed
    /// `shortAuthenticationCode` was awaited on a session that will never
    /// produce one: a known-peer session authenticates purely from stored
    /// identity keys and never prompts for a code.
    case shortAuthenticationCodeUnavailable
    /// A secure-channel operation failed authentication (tampering, replay,
    /// out-of-order delivery, or a frame-kind swap), or the frame counter
    /// would have wrapped past `UInt64.max`. Terminal: the channel latches
    /// closed and every subsequent `send`/`receive` throws this same error
    /// without touching the connection again.
    case secureChannelFailed
    /// A plaintext `NearbySessionMessage` encoding was too large to seal
    /// under the channel's frame cap. Rejected before anything is sent; the
    /// channel remains usable for subsequent, correctly sized messages.
    case oversizedMessage

    /// `NearbyBonjourBrowser.connectToFirstMatch(timeout:)` did not discover
    /// and connect to a peer within the configured timeout. Distinct from
    /// `.handshakeTimeout` (which fires once a pairing session is already
    /// talking to a connected peer): this fires before any peer is even
    /// reached — e.g. no Bonjour result ever arrived, or the underlying
    /// `NWConnection` sat retrying a refused/unreachable endpoint. Terminal:
    /// the in-flight browse/connect attempt is cancelled before this is
    /// thrown.
    case connectionTimeout

    /// A `NearbySecureChannel.send`/`receive` did not complete within the
    /// channel's configured `ioTimeout` — the post-handshake analogue of
    /// `.handshakeTimeout` (which only ever fires during pairing, before a
    /// channel exists). Terminal: the underlying connection is cancelled as
    /// part of raising this error, and the channel latches failed exactly
    /// like every other terminal `NearbySecureChannel` error.
    case transferTimeout

    /// `NearbyBonjourListener.start()` did not observe the underlying
    /// `NWListener` reach `.ready` within the configured `readyTimeout`
    /// (e.g. the OS never resolves `.setup`/`.waiting`). Terminal: the
    /// listener is cancelled and torn down before this is thrown, so a
    /// caller may safely construct and start a fresh listener afterward.
    case listenerStartTimeout
}

/// Encodes and decodes `NearbyFrame`s to and from the wire format.
///
/// `decode` is designed for a streaming reader: it never consumes more than
/// one frame, reports exactly how many bytes that frame occupied, and — on
/// any failure — consumes nothing and leaves the caller's buffer untouched.
public enum NearbyFrameCodec {
    /// The only wire version this build emits or accepts. A peer declaring
    /// any other value fails closed via `.unsupportedVersion`.
    public static let currentProtocolVersion: UInt8 = 1

    /// Hard cap on a single frame's payload. Chosen so one frame is cheap to
    /// buffer in memory regardless of what it carries.
    public static let maxFramePayloadBytes = 1_048_576

    /// Documented cap on the total bytes a package transfer (many
    /// `.packageChunk` frames strung together) may carry end to end. Later
    /// streaming layers (Task 4+) enforce this across frames; the codec only
    /// guarantees each individual frame stays within `maxFramePayloadBytes`.
    public static let maxPackageStreamBytes = 512 * 1024 * 1024

    /// `[version:1][kind:1][length:4]`.
    private static let headerByteCount = 6
    private static let lengthByteCount = 4

    public static func encode(_ frame: NearbyFrame) -> Data {
        var data = Data(capacity: headerByteCount + frame.payload.count)
        data.append(frame.version)
        data.append(frame.kind.rawValue)
        let length = UInt32(frame.payload.count)
        withUnsafeBytes(of: length.bigEndian) { data.append(contentsOf: $0) }
        data.append(frame.payload)
        return data
    }

    public static func decode(_ data: Data) throws -> (frame: NearbyFrame, consumedBytes: Int) {
        guard data.count >= headerByteCount else { throw NearbyTransportError.incompleteFrame }
        let start = data.startIndex
        let version = data[start]
        let kindByte = data[data.index(start, offsetBy: 1)]
        let lengthStart = data.index(start, offsetBy: 2)
        let lengthEnd = data.index(lengthStart, offsetBy: lengthByteCount)
        let length = data[lengthStart..<lengthEnd].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        // Version and size are validated before the kind byte or payload
        // bytes are ever touched — an oversized declared length is rejected
        // without allocating or slicing a payload buffer.
        guard version == currentProtocolVersion else {
            throw NearbyTransportError.unsupportedVersion(version)
        }
        guard length <= UInt32(maxFramePayloadBytes) else {
            throw NearbyTransportError.frameTooLarge
        }
        guard let kind = NearbyFrameKind(rawValue: kindByte) else {
            throw NearbyTransportError.unknownFrameKind(kindByte)
        }

        let totalNeeded = headerByteCount + Int(length)
        guard data.count >= totalNeeded else { throw NearbyTransportError.incompleteFrame }

        let payloadStart = data.index(start, offsetBy: headerByteCount)
        let payloadEnd = data.index(payloadStart, offsetBy: Int(length))
        let payload = Data(data[payloadStart..<payloadEnd])

        return (NearbyFrame(version: version, kind: kind, payload: payload), totalNeeded)
    }
}
