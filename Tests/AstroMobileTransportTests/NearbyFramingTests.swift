import Foundation
import Testing
@testable import AstroMobileTransport

@Test func frameRoundTripsAllKinds() throws {
    for kind in NearbyFrameKind.allCases {
        let frame = NearbyFrame(kind: kind, payload: Data("payload".utf8))
        let decoded = try NearbyFrameCodec.decode(NearbyFrameCodec.encode(frame))
        #expect(decoded.frame == frame)
        #expect(decoded.consumedBytes == NearbyFrameCodec.encode(frame).count)
    }
}

@Test func truncatedFrameFailsClosedWithoutConsuming() throws {
    var bytes = NearbyFrameCodec.encode(NearbyFrame(kind: .hello, payload: Data(repeating: 1, count: 64)))
    bytes.removeLast(8)
    #expect(throws: NearbyTransportError.incompleteFrame) { try NearbyFrameCodec.decode(bytes) }
}

@Test func oversizedDeclaredLengthIsRejectedBeforeAllocation() throws {
    var header = NearbyFrameCodec.encode(NearbyFrame(kind: .hello, payload: Data()))
    header.replaceSubrange(2..<6, with: withUnsafeBytes(of: UInt32(2_000_000).bigEndian) { Data($0) })
    #expect(throws: NearbyTransportError.frameTooLarge) { try NearbyFrameCodec.decode(header) }
}

@Test func unknownVersionFailsClosed() throws {
    var bytes = NearbyFrameCodec.encode(NearbyFrame(kind: .hello, payload: Data()))
    bytes[0] = 99
    #expect(throws: NearbyTransportError.unsupportedVersion(99)) { try NearbyFrameCodec.decode(bytes) }
}

@Test func emptyInputFailsClosedWithIncompleteFrame() throws {
    #expect(throws: NearbyTransportError.incompleteFrame) { try NearbyFrameCodec.decode(Data()) }
}

@Test func unknownFrameKindByteFailsClosed() throws {
    var bytes = NearbyFrameCodec.encode(NearbyFrame(kind: .hello, payload: Data()))
    bytes[1] = 250
    #expect(throws: NearbyTransportError.unknownFrameKind(250)) { try NearbyFrameCodec.decode(bytes) }
}

@Test func decodingAtTheExactCapSucceedsButOneByteOverFails() throws {
    let atCap = NearbyFrame(kind: .packageChunk, payload: Data(repeating: 7, count: NearbyFrameCodec.maxFramePayloadBytes))
    let decodedAtCap = try NearbyFrameCodec.decode(NearbyFrameCodec.encode(atCap))
    #expect(decodedAtCap.frame == atCap)

    var overCapHeader = NearbyFrameCodec.encode(NearbyFrame(kind: .packageChunk, payload: Data()))
    let overCapLength = UInt32(NearbyFrameCodec.maxFramePayloadBytes) + 1
    overCapHeader.replaceSubrange(2..<6, with: withUnsafeBytes(of: overCapLength.bigEndian) { Data($0) })
    #expect(throws: NearbyTransportError.frameTooLarge) { try NearbyFrameCodec.decode(overCapHeader) }
}

@Test func partialSecondFrameDoesNotBlockDecodingTheFirst() throws {
    let first = NearbyFrame(kind: .hello, payload: Data("first".utf8))
    let second = NearbyFrame(kind: .acknowledgement, payload: Data("second-payload".utf8))
    var buffer = NearbyFrameCodec.encode(first)
    let secondEncoded = NearbyFrameCodec.encode(second)
    buffer.append(secondEncoded.prefix(secondEncoded.count - 3))

    let decodedFirst = try NearbyFrameCodec.decode(buffer)
    #expect(decodedFirst.frame == first)
    #expect(decodedFirst.consumedBytes == NearbyFrameCodec.encode(first).count)

    let remainder = buffer.suffix(from: buffer.startIndex + decodedFirst.consumedBytes)
    #expect(throws: NearbyTransportError.incompleteFrame) { try NearbyFrameCodec.decode(Data(remainder)) }
}

@Test func everySessionMessageRoundTripsThroughItsOwnFrameKind() throws {
    let messages: [NearbySessionMessage] = [
        .hello(NearbyHelloMessage(protocolVersion: 1, deviceID: UUID(), displayName: "Zoltán iPhone", sessionID: UUID())),
        .keyExchange(NearbyKeyExchangeMessage(ephemeralPublicKey: Data([1, 2, 3]), identitySignature: Data([4, 5]))),
        .pairingConfirm(NearbyPairingConfirmMessage(accepted: true)),
        .packageManifest(NearbyPackageManifestMessage(packageID: UUID(), manifestJSON: Data("{}".utf8), totalChunkCount: 3, totalByteCount: 4096)),
        .packageChunk(NearbyPackageChunkMessage(index: 2, bytes: Data(repeating: 9, count: 32))),
        .packageComplete(NearbyPackageCompleteMessage(packageID: UUID(), sha256Hex: String(repeating: "a", count: 64))),
        .acknowledgement(NearbyAcknowledgementMessage(acknowledgedChangeIDs: [UUID(), UUID()])),
        .failure(NearbyFailureMessage(reason: .transferAborted)),
    ]

    var seenKinds = Set<NearbyFrameKind>()
    for message in messages {
        let frame = try message.encodedFrame()
        #expect(frame.kind == message.frameKind)
        seenKinds.insert(frame.kind)

        let (decodedFrame, consumed) = try NearbyFrameCodec.decode(NearbyFrameCodec.encode(frame))
        #expect(consumed == NearbyFrameCodec.encode(frame).count)
        let decodedMessage = try NearbySessionMessage(frame: decodedFrame)
        #expect(decodedMessage == message)
    }

    // The mapping from message case to frame kind is total: every kind the
    // wire understands was exercised by exactly one message case above.
    #expect(seenKinds == Set(NearbyFrameKind.allCases))
}

@Test func unknownFailureReasonStringFailsClosedRatherThanSurfacingFreeText() throws {
    let bogusPayload = Data(#"{"reason":"somethingThePeerMadeUp"}"#.utf8)
    let frame = NearbyFrame(kind: .failure, payload: bogusPayload)
    #expect(throws: NearbyTransportError.invalidMessage) { try NearbySessionMessage(frame: frame) }
}

@Test func malformedPayloadForAKnownFrameKindFailsClosed() throws {
    let frame = NearbyFrame(kind: .hello, payload: Data("not-json".utf8))
    #expect(throws: NearbyTransportError.invalidMessage) { try NearbySessionMessage(frame: frame) }
}
