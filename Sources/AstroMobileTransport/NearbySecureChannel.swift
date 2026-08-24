import CryptoKit
import Foundation

/// The post-handshake authenticated channel `NearbyPairingSession.establish()`
/// hands back. Every `NearbySessionMessage` is sealed with ChaChaPoly under a
/// per-direction key derived during pairing; the sender's own message
/// counter (monotonically increasing, starting at 0) doubles as the AEAD
/// nonce, and the frame kind byte plus that same counter form the
/// additional authenticated data — so a replay, an out-of-order delivery, or
/// a frame whose `kind` byte was swapped in transit all fail the AEAD open
/// rather than silently decoding.
///
/// Any such failure — or a counter that would wrap past `UInt64.max` — is
/// terminal: the channel latches `isFailed` and every subsequent `send` or
/// `receive` throws `NearbyTransportError.secureChannelFailed` immediately,
/// without touching the connection again.
public actor NearbySecureChannel {
    /// `NearbyFrameCodec.maxFramePayloadBytes` minus the ChaChaPoly combined
    /// representation's fixed overhead (a 12-byte nonce and a 16-byte tag
    /// wrap the ciphertext, which is exactly as long as the plaintext). A
    /// plaintext frame payload this size or smaller is guaranteed to still
    /// fit under the wire cap once sealed.
    private static let nonceByteCount = 12
    private static let tagByteCount = 16

    public static let maxPlaintextBytes = NearbyFrameCodec.maxFramePayloadBytes - nonceByteCount - tagByteCount

    private let connection: any NearbyByteConnection
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var isFailed = false

    init(connection: any NearbyByteConnection, sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.connection = connection
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    /// Seals `message` under this channel's send-direction key and counter,
    /// then writes it to the underlying connection as a frame of the
    /// message's own `frameKind`. Throws `.oversizedMessage` (channel stays
    /// usable) if the encoded message is too large; throws
    /// `.secureChannelFailed` (channel becomes unusable) for a counter that
    /// would wrap, or if the underlying connection rejects the write.
    public func send(_ message: NearbySessionMessage) async throws {
        guard !isFailed else { throw NearbyTransportError.secureChannelFailed }

        let plaintextFrame: NearbyFrame
        do {
            plaintextFrame = try message.encodedFrame()
        } catch {
            isFailed = true
            throw NearbyTransportError.invalidMessage
        }
        guard plaintextFrame.payload.count <= Self.maxPlaintextBytes else {
            throw NearbyTransportError.oversizedMessage
        }
        guard sendCounter != UInt64.max else {
            isFailed = true
            throw NearbyTransportError.secureChannelFailed
        }

        let counter = sendCounter
        let sealedPayload: Data
        do {
            let nonce = try ChaChaPoly.Nonce(data: Self.nonceBytes(forCounter: counter))
            let sealedBox = try ChaChaPoly.seal(
                plaintextFrame.payload,
                using: sendKey,
                nonce: nonce,
                authenticating: Self.additionalData(kind: plaintextFrame.kind, counter: counter)
            )
            sealedPayload = sealedBox.combined
        } catch {
            isFailed = true
            throw NearbyTransportError.secureChannelFailed
        }

        do {
            try await connection.send(NearbyFrame(kind: plaintextFrame.kind, payload: sealedPayload))
        } catch {
            isFailed = true
            throw error
        }
        sendCounter = counter + 1
    }

    /// Reads the next frame from the underlying connection and opens it
    /// under this channel's receive-direction key, requiring the receive
    /// counter to be exactly this side's next expected value (enforced
    /// through the AEAD's additional authenticated data, so any mismatch —
    /// replay, reordering, or a swapped frame kind — surfaces as an
    /// authentication failure). Terminal on any such failure, on a counter
    /// that would wrap, or on the connection itself failing.
    public func receive() async throws -> NearbySessionMessage {
        guard !isFailed else { throw NearbyTransportError.secureChannelFailed }
        guard receiveCounter != UInt64.max else {
            isFailed = true
            throw NearbyTransportError.secureChannelFailed
        }

        let frame: NearbyFrame
        do {
            frame = try await connection.receive()
        } catch {
            isFailed = true
            throw error
        }

        let counter = receiveCounter
        let plaintext: Data
        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: frame.payload)
            plaintext = try ChaChaPoly.open(
                sealedBox,
                using: receiveKey,
                authenticating: Self.additionalData(kind: frame.kind, counter: counter)
            )
        } catch {
            isFailed = true
            throw NearbyTransportError.secureChannelFailed
        }

        let message: NearbySessionMessage
        do {
            message = try NearbySessionMessage(frame: NearbyFrame(kind: frame.kind, payload: plaintext))
        } catch {
            isFailed = true
            throw NearbyTransportError.secureChannelFailed
        }

        receiveCounter = counter + 1
        return message
    }

    // MARK: - Nonce / AAD layout

    /// The 12-byte ChaChaPoly nonce is the big-endian encoding of the
    /// direction's own counter, left-padded with zero bytes.
    private static func nonceBytes(forCounter counter: UInt64) -> Data {
        Data(repeating: 0, count: nonceByteCount - MemoryLayout<UInt64>.size) + counterBytes(counter)
    }

    /// `[frameKind:1][counter:8]`, bound into the AEAD so a swapped frame
    /// kind or a counter other than the receiver's own expected next value
    /// fails to authenticate.
    private static func additionalData(kind: NearbyFrameKind, counter: UInt64) -> Data {
        Data([kind.rawValue]) + counterBytes(counter)
    }

    private static func counterBytes(_ counter: UInt64) -> Data {
        withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }

    // MARK: - Test-only seams

    /// Overwrites both direction counters so tests can exercise the
    /// counter-wrap path without sending `UInt64.max` real frames first.
    /// Reachable only through `@testable import`.
    func debugSetCounters(send: UInt64? = nil, receive: UInt64? = nil) {
        if let send { sendCounter = send }
        if let receive { receiveCounter = receive }
    }
}
