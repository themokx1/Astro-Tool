import Foundation
import Testing
@testable import AstroMobileTransport

/// Loopback-only integration tests for the Task 5 Bonjour adapter. NONE of
/// these publish an actual Bonjour service — every test uses
/// `NearbyBonjourListener.loopbackForTesting()` (an OS-assigned loopback TCP
/// port, no `NWListener.service`) and `NearbyBonjourBrowser
/// .connectDirectlyForTesting(port:)` (a direct `127.0.0.1:port` connect, no
/// browsing) — so they need no local-network permission and never depend on
/// mDNS. They still exercise the real `NWListener`/`NWConnection` machinery
/// the public, Bonjour-publishing API also uses.
///
/// Gated (visibly, not silently) by `ASTRO_SKIP_LOOPBACK`: a sandboxed or CI
/// environment without a usable loopback socket can set that variable to
/// skip this entire suite, and Swift Testing reports the tests as skipped
/// rather than simply omitting them.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ASTRO_SKIP_LOOPBACK"] == nil))
struct NearbyBonjourTransportTests {

    @Test func oneFrameEachDirectionRoundTripsOverRealLoopbackConnections() async throws {
        let listener = NearbyBonjourListener.loopbackForTesting()
        let connections = try await listener.start()
        let port = try await requireBoundPort(listener)

        let browser = NearbyBonjourBrowser()
        async let clientResult = browser.connectDirectlyForTesting(port: port, timeout: .seconds(5))

        var iterator = connections.makeAsyncIterator()
        guard let serverConnection = await iterator.next() else {
            Issue.record("listener never produced an inbound connection")
            return
        }
        let client = try await clientResult

        let clientToServer = NearbyFrame(kind: .hello, payload: Data("client-hello".utf8))
        try await client.send(clientToServer)
        let receivedByServer = try await serverConnection.receive()
        #expect(receivedByServer == clientToServer)

        let serverToClient = NearbyFrame(kind: .acknowledgement, payload: Data("server-ack".utf8))
        try await serverConnection.send(serverToClient)
        let receivedByClient = try await client.receive()
        #expect(receivedByClient == serverToClient)

        await client.cancel()
        await serverConnection.cancel()
        await listener.stop()
    }

    @Test func oversizedDeclaredLengthFailsClosedAndConnectionStaysDead() async throws {
        let listener = NearbyBonjourListener.loopbackForTesting()
        let connections = try await listener.start()
        let port = try await requireBoundPort(listener)

        let browser = NearbyBonjourBrowser()
        async let clientResult = browser.connectDirectlyForTesting(port: port, timeout: .seconds(5))

        var iterator = connections.makeAsyncIterator()
        guard let serverConnection = await iterator.next() else {
            Issue.record("listener never produced an inbound connection")
            return
        }
        guard let client = try await clientResult as? NearbyNWConnection else {
            Issue.record("connectDirectlyForTesting did not return a NearbyNWConnection")
            return
        }

        // A well-formed 6-byte header alone is enough for the receiver's
        // decode loop to reject an oversized declared length — no payload
        // bytes need to follow.
        var oversizedHeader = Data([NearbyFrameCodec.currentProtocolVersion, NearbyFrameKind.hello.rawValue])
        withUnsafeBytes(of: UInt32(NearbyFrameCodec.maxFramePayloadBytes + 1).bigEndian) {
            oversizedHeader.append(contentsOf: $0)
        }
        try await client.sendRawBytesForTesting(oversizedHeader)

        await #expect(throws: NearbyTransportError.frameTooLarge) {
            try await serverConnection.receive()
        }
        // The connection is dead after: it keeps failing the same way
        // rather than accepting a subsequent, well-formed frame.
        await #expect(throws: NearbyTransportError.frameTooLarge) {
            try await serverConnection.receive()
        }

        await client.cancel()
        await listener.stop()
    }

    @Test func remoteCloseMidFrameSurfacesAsConnectionClosed() async throws {
        let listener = NearbyBonjourListener.loopbackForTesting()
        let connections = try await listener.start()
        let port = try await requireBoundPort(listener)

        let browser = NearbyBonjourBrowser()
        async let clientResult = browser.connectDirectlyForTesting(port: port, timeout: .seconds(5))

        var iterator = connections.makeAsyncIterator()
        guard let serverConnection = await iterator.next() else {
            Issue.record("listener never produced an inbound connection")
            return
        }
        guard let client = try await clientResult as? NearbyNWConnection else {
            Issue.record("connectDirectlyForTesting did not return a NearbyNWConnection")
            return
        }

        // A header that promises a 64-byte payload, followed by only 10 of
        // those bytes, then the sender goes away — the receiver is left
        // waiting mid-frame for bytes that will never arrive.
        var partialFrame = Data([NearbyFrameCodec.currentProtocolVersion, NearbyFrameKind.hello.rawValue])
        withUnsafeBytes(of: UInt32(64).bigEndian) { partialFrame.append(contentsOf: $0) }
        partialFrame.append(Data(repeating: 0x5A, count: 10))
        try await client.sendRawBytesForTesting(partialFrame)
        await client.cancel()

        await #expect(throws: NearbyTransportError.connectionClosed) {
            try await serverConnection.receive()
        }

        await listener.stop()
    }

    @Test func connectingToAnUnattendedPortTimesOut() async throws {
        // Nobody is listening on this loopback port: on a refused TCP
        // connect, `NWConnection` does not surface `.failed` promptly — it
        // sits in `.waiting`, which is exactly the case `timeout:` exists to
        // bound rather than hanging (or racing a slow OS-level failure)
        // forever.
        let unattendedPort = try await portWithNobodyListening()

        let browser = NearbyBonjourBrowser()
        await #expect(throws: NearbyTransportError.connectionTimeout) {
            _ = try await browser.connectDirectlyForTesting(port: unattendedPort, timeout: .milliseconds(300))
        }
    }

    @Test func listenerStopEndsTheAsyncStream() async throws {
        let listener = NearbyBonjourListener.loopbackForTesting()
        let connections = try await listener.start()
        _ = try await requireBoundPort(listener)

        await listener.stop()

        var iterator = connections.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }

    // MARK: - Helpers

    /// `start()` only returns once the underlying `NWListener` reached
    /// `.ready`, at which point a `loopbackForTesting()` listener's bound
    /// port is already recorded — this just fails the test with a clear
    /// message instead of force-unwrapping if that invariant is ever wrong.
    private func requireBoundPort(_ listener: NearbyBonjourListener) async throws -> UInt16 {
        guard let port = await listener.boundLoopbackPortForTesting else {
            Issue.record("loopback listener never recorded a bound port")
            throw NearbyTransportError.connectionClosed
        }
        return port
    }

    /// Binds and immediately releases a loopback listener to obtain a port
    /// number that was free a moment ago and has nobody listening on it now.
    private func portWithNobodyListening() async throws -> UInt16 {
        let probe = NearbyBonjourListener.loopbackForTesting()
        _ = try await probe.start()
        let port = try await requireBoundPort(probe)
        await probe.stop()
        return port
    }
}
