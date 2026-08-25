import Foundation
import AstroMobileDomain

/// The initial handshake message: identifies the sender, carries the
/// sender's persistent identity public key, and contributes a fresh random
/// nonce to the pairing transcript. `helloNonce` is always exactly 16 bytes
/// and `signingPublicKeyRawRepresentation` always exactly 32 — the pairing
/// session validates a peer-supplied hello's field lengths before using them
/// in any transcript so the transcript concatenation stays injective.
public struct NearbyHelloMessage: Codable, Equatable, Sendable {
    public let protocolVersion: UInt8
    public let deviceID: UUID
    public let displayName: String
    public let signingPublicKeyRawRepresentation: Data
    public let helloNonce: Data

    public init(
        protocolVersion: UInt8,
        deviceID: UUID,
        displayName: String,
        signingPublicKeyRawRepresentation: Data,
        helloNonce: Data
    ) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.displayName = displayName
        self.signingPublicKeyRawRepresentation = signingPublicKeyRawRepresentation
        self.helloNonce = helloNonce
    }
}

/// Carries one side's ephemeral key-agreement public key, its random
/// contribution to the session ID, and a signature (always present) over the
/// sender's view of the pairing transcript, made with the sender's
/// persistent identity signing key. `ephemeralPublicKey` is always exactly
/// 32 bytes, `sessionIDContribution` always exactly 16, and
/// `identitySignature` always exactly 64 (a raw Ed25519 signature) — the
/// pairing session validates a peer-supplied message's field lengths before
/// verifying anything.
public struct NearbyKeyExchangeMessage: Codable, Equatable, Sendable {
    public let ephemeralPublicKey: Data
    public let sessionIDContribution: Data
    public let identitySignature: Data

    public init(ephemeralPublicKey: Data, sessionIDContribution: Data, identitySignature: Data) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.sessionIDContribution = sessionIDContribution
        self.identitySignature = identitySignature
    }
}

/// Sent only by a side that has locally accepted the short authentication
/// code during a first pairing; a decline is reported as `.failure` instead,
/// never as a `NearbyPairingConfirmMessage` with a negative flag. `proof` is
/// `HMAC-SHA256(key: confirmKey, data: roleByte ‖ transcriptHash)` under the
/// sender's own role byte, so the verifier's reflected-proof check (verifying
/// under the PEER's role byte) fails closed against a replay of the
/// verifier's own message.
public struct NearbyPairingConfirmMessage: Codable, Equatable, Sendable {
    public let proof: Data

    public init(proof: Data) {
        self.proof = proof
    }
}

/// Announces an incoming sealed package before its chunks arrive, so the
/// receiver can validate size against the manifest as chunks land.
public struct NearbyPackageManifestMessage: Codable, Equatable, Sendable {
    public let packageID: UUID
    public let manifestJSON: Data
    public let totalChunkCount: Int
    public let totalByteCount: Int64
    /// The raw 32-byte `pairedDevice` content-key wrap key for this transfer
    /// (see `PairedDeviceKeyWrapping` in `MobilePackageCrypto.swift`). It
    /// travels here — as a field of a message that only ever crosses the
    /// wire inside `NearbySecureChannel.send`/`receive` — rather than as a
    /// QR-scanned secret, because that already-authenticated AEAD channel
    /// IS this key's transport. Defaults to `Data()` so call sites that only
    /// exercise wire framing or the secure channel (Tasks 1 and 3's tests)
    /// keep compiling without ever touching package crypto.
    public let contentKeyWrapRawRepresentation: Data

    public init(
        packageID: UUID,
        manifestJSON: Data,
        totalChunkCount: Int,
        totalByteCount: Int64,
        contentKeyWrapRawRepresentation: Data = Data()
    ) {
        self.packageID = packageID
        self.manifestJSON = manifestJSON
        self.totalChunkCount = totalChunkCount
        self.totalByteCount = totalByteCount
        self.contentKeyWrapRawRepresentation = contentKeyWrapRawRepresentation
    }
}

/// One slice of the sealed payload's byte stream, in order.
public struct NearbyPackageChunkMessage: Codable, Equatable, Sendable {
    public let index: Int
    public let bytes: Data

    public init(index: Int, bytes: Data) {
        self.index = index
        self.bytes = bytes
    }
}

/// Marks the end of a chunk stream and carries the hash the receiver must
/// match before it may hand the assembled bytes to `MobilePackageService`.
public struct NearbyPackageCompleteMessage: Codable, Equatable, Sendable {
    public let packageID: UUID
    public let sha256Hex: String

    public init(packageID: UUID, sha256Hex: String) {
        self.packageID = packageID
        self.sha256Hex = sha256Hex
    }
}

/// Carries the exact acknowledged change IDs the same way the AirDrop
/// package envelope does — never a free-form status.
public struct NearbyAcknowledgementMessage: Codable, Equatable, Sendable {
    public let acknowledgedChangeIDs: [UUID]

    public init(acknowledgedChangeIDs: [UUID]) {
        self.acknowledgedChangeIDs = acknowledgedChangeIDs
    }
}

/// Closed set of reasons a session may report failure with. A peer can never
/// inject free text here — only one of these cases decodes successfully.
public enum NearbyFailureReason: String, Codable, CaseIterable, Sendable {
    case handshakeFailed
    case identityMismatch
    case transferAborted
    case limitsExceeded
}

public struct NearbyFailureMessage: Codable, Equatable, Sendable {
    public let reason: NearbyFailureReason

    public init(reason: NearbyFailureReason) {
        self.reason = reason
    }
}

/// The full set of messages exchanged over a nearby session, one payload
/// type per `NearbyFrameKind`. The frame's `kind` byte is the wire
/// discriminator, so the JSON payload carries only the case's own fields —
/// there is no redundant in-payload tag.
public enum NearbySessionMessage: Equatable, Sendable {
    case hello(NearbyHelloMessage)
    case keyExchange(NearbyKeyExchangeMessage)
    case pairingConfirm(NearbyPairingConfirmMessage)
    case packageManifest(NearbyPackageManifestMessage)
    case packageChunk(NearbyPackageChunkMessage)
    case packageComplete(NearbyPackageCompleteMessage)
    case acknowledgement(NearbyAcknowledgementMessage)
    case failure(NearbyFailureMessage)

    /// The one `NearbyFrameKind` this message case is ever carried under.
    public var frameKind: NearbyFrameKind {
        switch self {
        case .hello: return .hello
        case .keyExchange: return .keyExchange
        case .pairingConfirm: return .pairingConfirm
        case .packageManifest: return .packageManifest
        case .packageChunk: return .packageChunk
        case .packageComplete: return .packageComplete
        case .acknowledgement: return .acknowledgement
        case .failure: return .failure
        }
    }

    /// Encodes this message as the frame its `frameKind` requires.
    public func encodedFrame(version: UInt8 = NearbyFrameCodec.currentProtocolVersion) throws -> NearbyFrame {
        let payload: Data
        do {
            switch self {
            case .hello(let message): payload = try MobileJSON.encoder.encode(message)
            case .keyExchange(let message): payload = try MobileJSON.encoder.encode(message)
            case .pairingConfirm(let message): payload = try MobileJSON.encoder.encode(message)
            case .packageManifest(let message): payload = try MobileJSON.encoder.encode(message)
            case .packageChunk(let message): payload = try MobileJSON.encoder.encode(message)
            case .packageComplete(let message): payload = try MobileJSON.encoder.encode(message)
            case .acknowledgement(let message): payload = try MobileJSON.encoder.encode(message)
            case .failure(let message): payload = try MobileJSON.encoder.encode(message)
            }
        } catch {
            throw NearbyTransportError.invalidMessage
        }
        return NearbyFrame(version: version, kind: frameKind, payload: payload)
    }

    /// Decodes a message from a frame already validated by
    /// `NearbyFrameCodec`. The frame's `kind` selects which payload type is
    /// expected; a payload that fails to decode into that exact type — an
    /// unknown `NearbyFailureReason` string included — fails closed with
    /// `.invalidMessage` rather than surfacing the underlying decoder error.
    public init(frame: NearbyFrame) throws {
        do {
            switch frame.kind {
            case .hello:
                self = .hello(try MobileJSON.decoder.decode(NearbyHelloMessage.self, from: frame.payload))
            case .keyExchange:
                self = .keyExchange(try MobileJSON.decoder.decode(NearbyKeyExchangeMessage.self, from: frame.payload))
            case .pairingConfirm:
                self = .pairingConfirm(try MobileJSON.decoder.decode(NearbyPairingConfirmMessage.self, from: frame.payload))
            case .packageManifest:
                self = .packageManifest(try MobileJSON.decoder.decode(NearbyPackageManifestMessage.self, from: frame.payload))
            case .packageChunk:
                self = .packageChunk(try MobileJSON.decoder.decode(NearbyPackageChunkMessage.self, from: frame.payload))
            case .packageComplete:
                self = .packageComplete(try MobileJSON.decoder.decode(NearbyPackageCompleteMessage.self, from: frame.payload))
            case .acknowledgement:
                self = .acknowledgement(try MobileJSON.decoder.decode(NearbyAcknowledgementMessage.self, from: frame.payload))
            case .failure:
                self = .failure(try MobileJSON.decoder.decode(NearbyFailureMessage.self, from: frame.payload))
            }
        } catch {
            throw NearbyTransportError.invalidMessage
        }
    }
}
