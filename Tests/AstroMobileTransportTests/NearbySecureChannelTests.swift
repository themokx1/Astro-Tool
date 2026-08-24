import CryptoKit
import Foundation
import Testing
@testable import AstroMobileTransport

@Suite struct NearbySecureChannelTests {

    // MARK: - Happy path

    @Test func roundTripsSeveralMessageKindsInOrder() async throws {
        let (channelA, channelB, _, _) = Self.makeMatchedChannelPair()

        let messages: [NearbySessionMessage] = [
            .acknowledgement(NearbyAcknowledgementMessage(acknowledgedChangeIDs: [UUID(), UUID()])),
            .packageManifest(NearbyPackageManifestMessage(packageID: UUID(), manifestJSON: Data("{}".utf8), totalChunkCount: 1, totalByteCount: 10)),
            .packageChunk(NearbyPackageChunkMessage(index: 0, bytes: Data(repeating: 9, count: 16))),
            .packageComplete(NearbyPackageCompleteMessage(packageID: UUID(), sha256Hex: String(repeating: "a", count: 64))),
            .failure(NearbyFailureMessage(reason: .transferAborted)),
        ]

        for message in messages {
            try await channelA.send(message)
            let received = try await channelB.receive()
            #expect(received == message)
        }
    }

    @Test func bothDirectionsHaveIndependentCounters() async throws {
        let (channelA, channelB, _, _) = Self.makeMatchedChannelPair()

        // Send several messages A -> B without B ever replying, then several
        // B -> A: each direction's counter must track only its own traffic.
        for index in 0..<3 {
            try await channelA.send(.acknowledgement(NearbyAcknowledgementMessage(acknowledgedChangeIDs: [])))
            let received = try await channelB.receive()
            guard case .acknowledgement = received else {
                Issue.record("unexpected message at A->B index \(index)")
                return
            }
        }
        for index in 0..<3 {
            try await channelB.send(.failure(NearbyFailureMessage(reason: .limitsExceeded)))
            let received = try await channelA.receive()
            guard case .failure = received else {
                Issue.record("unexpected message at B->A index \(index)")
                return
            }
        }
    }

    // MARK: - Oversized message

    @Test func oversizedMessageIsRejectedBeforeSendAndChannelStaysUsable() async throws {
        let (channelA, channelB, _, _) = Self.makeMatchedChannelPair()

        let tooBig = NearbyPackageChunkMessage(index: 0, bytes: Data(repeating: 1, count: NearbySecureChannel.maxPlaintextBytes + 1))
        await #expect(throws: NearbyTransportError.oversizedMessage) {
            try await channelA.send(.packageChunk(tooBig))
        }

        // The channel is still usable for a correctly sized message.
        try await channelA.send(.failure(NearbyFailureMessage(reason: .limitsExceeded)))
        let received = try await channelB.receive()
        #expect(received == .failure(NearbyFailureMessage(reason: .limitsExceeded)))
    }

    // MARK: - Tampering is terminal

    @Test func flippedCiphertextByteIsTerminalForBothSubsequentSendAndReceive() async throws {
        let (channelA, channelB, rawA, rawB) = Self.makeMatchedChannelPair()

        try await channelA.send(.failure(NearbyFailureMessage(reason: .transferAborted)))
        let capturedFrame = try await rawB.receive()
        var tamperedPayload = capturedFrame.payload
        tamperedPayload[tamperedPayload.startIndex] ^= 0xFF
        try await rawA.send(NearbyFrame(kind: capturedFrame.kind, payload: tamperedPayload))

        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            _ = try await channelB.receive()
        }
        // Terminal: the channel refuses all further use.
        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            _ = try await channelB.receive()
        }
        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            try await channelB.send(.failure(NearbyFailureMessage(reason: .transferAborted)))
        }
    }

    @Test func replayedFrameIsTerminal() async throws {
        let (channelA, channelB, rawA, rawB) = Self.makeMatchedChannelPair()

        try await channelA.send(.failure(NearbyFailureMessage(reason: .transferAborted)))
        let capturedFrame = try await rawB.receive()
        // Deliver the legitimate first message, then replay the exact same
        // wire bytes a second time.
        try await rawA.send(capturedFrame)
        let first = try await channelB.receive()
        #expect(first == .failure(NearbyFailureMessage(reason: .transferAborted)))

        try await rawA.send(capturedFrame)
        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            _ = try await channelB.receive()
        }
    }

    @Test func frameKindSwapOnASealedFrameIsTerminal() async throws {
        let (channelA, channelB, rawA, rawB) = Self.makeMatchedChannelPair()

        try await channelA.send(.acknowledgement(NearbyAcknowledgementMessage(acknowledgedChangeIDs: [])))
        let capturedFrame = try await rawB.receive()
        // Same sealed payload bytes, but declared as a different frame kind
        // — the AAD binds the kind, so this must fail authentication rather
        // than being reinterpreted as that other kind.
        let swappedKindFrame = NearbyFrame(kind: .failure, payload: capturedFrame.payload)
        try await rawA.send(swappedKindFrame)

        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            _ = try await channelB.receive()
        }
    }

    @Test func outOfOrderCounterIsTerminal() async throws {
        let (channelA, channelB, rawA, rawB) = Self.makeMatchedChannelPair()

        try await channelA.send(.acknowledgement(NearbyAcknowledgementMessage(acknowledgedChangeIDs: [])))
        let first = try await rawB.receive()
        try await channelA.send(.acknowledgement(NearbyAcknowledgementMessage(acknowledgedChangeIDs: [UUID()])))
        let second = try await rawB.receive()

        // Deliver counter 1 before counter 0 — receiver expects 0 first.
        try await rawA.send(second)
        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            _ = try await channelB.receive()
        }
        // Terminal even for the frame that WOULD have been valid next.
        try await rawA.send(first)
        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            _ = try await channelB.receive()
        }
    }

    // MARK: - Counter exhaustion

    @Test func counterWrapIsTerminalForSendAndReceive() async throws {
        let (sendChannel, _, _, _) = Self.makeMatchedChannelPair()
        await sendChannel.debugSetCounters(send: UInt64.max)
        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            try await sendChannel.send(.failure(NearbyFailureMessage(reason: .transferAborted)))
        }
        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            try await sendChannel.send(.failure(NearbyFailureMessage(reason: .transferAborted)))
        }

        let (_, receiveChannel, _, _) = Self.makeMatchedChannelPair()
        await receiveChannel.debugSetCounters(receive: UInt64.max)
        await #expect(throws: NearbyTransportError.secureChannelFailed) {
            _ = try await receiveChannel.receive()
        }
    }

    // MARK: - Helpers

    /// Builds a matched pair of channels over an `InMemoryDuplexConnection`,
    /// with symmetric directional keys derived the same way
    /// `NearbyPairingSession` derives them, plus the two RAW connection
    /// endpoints so tests can intercept, tamper with, or replay wire frames
    /// beneath the channel abstraction.
    private static func makeMatchedChannelPair() -> (
        a: NearbySecureChannel, b: NearbySecureChannel, rawA: InMemoryDuplexConnection, rawB: InMemoryDuplexConnection
    ) {
        let (rawA, rawB) = InMemoryDuplexConnection.makePair()
        let keyAToB = SymmetricKey(size: .bits256)
        let keyBToA = SymmetricKey(size: .bits256)
        let channelA = NearbySecureChannel(connection: rawA, sendKey: keyAToB, receiveKey: keyBToA)
        let channelB = NearbySecureChannel(connection: rawB, sendKey: keyBToA, receiveKey: keyAToB)
        return (channelA, channelB, rawA, rawB)
    }
}
