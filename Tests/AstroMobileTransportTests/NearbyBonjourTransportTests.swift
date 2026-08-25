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

    // MARK: - Bounded pending-connection buffer (Finding 3)

    /// Before the fix, `newConnectionHandler` wrapped and buffered every
    /// inbound connection into a plain (unbounded) `AsyncStream` ahead of
    /// the coordinator's own one-at-a-time gate — a flood of connections
    /// could grow that buffer without bound. The listener now bounds itself
    /// to at most one pending, undelivered connection
    /// (`.bufferingOldest(1)`) and cancels any further inbound connection
    /// immediately rather than letting it accumulate.
    @Test func onlyOnePendingInboundConnectionIsDeliveredAndExtrasAreCancelledNotBuffered() async throws {
        let listener = NearbyBonjourListener.loopbackForTesting()
        let connections = try await listener.start()
        let port = try await requireBoundPort(listener)

        // All three connect concurrently, before anything is ever dequeued
        // from `connections` — this is what makes the LISTENER's own bound
        // (as opposed to the coordinator's separate one-at-a-time gate,
        // which sits a layer above this type and never even sees the
        // extras) observable in isolation.
        let browserA = NearbyBonjourBrowser()
        let browserB = NearbyBonjourBrowser()
        let browserC = NearbyBonjourBrowser()
        async let clientAResult = browserA.connectDirectlyForTesting(port: port, timeout: .seconds(5))
        async let clientBResult = browserB.connectDirectlyForTesting(port: port, timeout: .seconds(5))
        async let clientCResult = browserC.connectDirectlyForTesting(port: port, timeout: .seconds(5))
        let clients = try await [clientAResult, clientBResult, clientCResult]

        // Give the listener's own `accept()` Task hops time to settle for
        // all three connections before this test ever touches `connections`.
        var attempts = 0
        while await listener.acceptedConnectionCountForTesting < 3, attempts < 100 {
            try await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }
        #expect(await listener.acceptedConnectionCountForTesting == 3)

        var iterator = connections.makeAsyncIterator()
        guard let delivered = await iterator.next() else {
            Issue.record("listener never delivered the one connection it should have buffered")
            return
        }

        // No unbounded growth: nothing further is buffered behind the one
        // delivered connection. Observed via a background task rather than
        // an unguarded `await iterator.next()`, since that call never
        // throws or times out on its own — it would simply hang the test
        // forever if this regressed back to unbounded buffering with a
        // second item actually queued.
        let observedSecond = ObservedDequeue()
        let secondDequeueTask = Task {
            var pendingIterator = iterator
            _ = await pendingIterator.next()
            observedSecond.markObserved()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!observedSecond.value)

        // The two extras were cancelled server-side before ever reaching
        // the stream. A plain `send()` is not a reliable enough signal on
        // its own — a local `NWConnection.send` completion only means "the
        // kernel accepted these bytes," which can still succeed once even
        // against an already-cancelled peer — so this instead has the
        // server reply on the one delivered connection and races a
        // `receive()` per client: exactly the survivor should ever see that
        // reply; the other two should fail (or, generously, time out)
        // because their underlying connection was actually torn down.
        let ackPayload = Data("ack".utf8)
        try await delivered.send(NearbyFrame(kind: .acknowledgement, payload: ackPayload))

        var receivedCount = 0
        var failedOrTimedOutCount = 0
        for client in clients {
            switch await Self.raceReceive(client, timeout: .milliseconds(800)) {
            case .received(let frame):
                #expect(frame.payload == ackPayload)
                receivedCount += 1
            case .failed, .timedOut:
                failedOrTimedOutCount += 1
            }
        }
        #expect(receivedCount == 1)
        #expect(failedOrTimedOutCount == 2)

        await delivered.cancel()
        for client in clients { await client.cancel() }
        await listener.stop()
        _ = await secondDequeueTask.value
    }

    /// Pins the new `readyTimeout:` parameter's happy path. A genuine
    /// timeout-firing test is not reliably constructible for the LISTENER
    /// side: binding a fresh loopback ephemeral port (`127.0.0.1:0`) reaches
    /// `.ready` essentially instantly at the OS level, and there is no
    /// listener-side equivalent of `connectingToAnUnattendedPortTimesOut`'s
    /// "nobody is listening" trick (that trick is inherently about the
    /// CONNECT side finding no peer). The timeout RACE mechanism itself
    /// (`raceListenerReady`) is the exact same commit-winner-first pattern
    /// already exercised end to end by `connectingToAnUnattendedPortTimesOut`
    /// above and by `NearbyPairingSessionTests
    /// .establishTimesOutWhenThePeerNeverAnswers`.
    @Test func startAcceptsAnInjectableReadyTimeoutAndStillSucceedsQuickly() async throws {
        let listener = NearbyBonjourListener.loopbackForTesting()
        let connections = try await listener.start(readyTimeout: .milliseconds(500))
        _ = try await requireBoundPort(listener)

        await listener.stop()
        var iterator = connections.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
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

    private enum ReceiveOutcome {
        case received(NearbyFrame)
        case failed(Error)
        case timedOut
    }

    /// Races one `connection.receive()` against `timeout` — used where a
    /// call might genuinely hang forever (an already-cancelled connection
    /// that never fails promptly would otherwise stall the test) rather than
    /// throw quickly.
    private static func raceReceive(_ connection: any NearbyByteConnection, timeout: Duration) async -> ReceiveOutcome {
        await withTaskGroup(of: ReceiveOutcome.self) { group in
            group.addTask {
                do {
                    return .received(try await connection.receive())
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

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

/// A tiny lock-guarded flag for asserting "a background `AsyncStream.next()`
/// call has not yet resolved" without a data race — mirrors
/// `NearbyPairingSessionTests.ManagedAtomicBool`'s own pattern for the same
/// reason (a plain `Bool` is not safely shared across a concurrently
/// running background `Task`).
private final class ObservedDequeue: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func markObserved() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
