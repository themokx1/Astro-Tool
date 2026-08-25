import Foundation
@preconcurrency import Network

/// Names the one Bonjour service AstroTool ever publishes or browses for.
/// Declared once here and referenced everywhere else (this file,
/// `project.yml`'s `NSBonjourServices`) so the literal only exists in one
/// place.
public enum NearbyBonjour: Sendable {
    public static let serviceType = "_astrotool-sync._tcp"
}

/// A resume-at-most-once latch shared between two Network-framework callback
/// closures that may race each other on the same serial dispatch queue.
/// Plain-lock based (rather than actor-isolated) so it can be captured
/// directly by non-`async` framework closures without an isolation hop; a
/// `Bool` captured by two `@Sendable`-inferred closures is rejected by
/// Swift 6's closure-capture checking even when — as here — the two
/// closures only ever run serially on one queue, so this small
/// `@unchecked Sendable` box is the escape hatch.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    /// Returns `true` exactly once (the first caller); every subsequent
    /// call, from either closure, returns `false`.
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

/// The Network-framework adapter that turns a raw `NWConnection` into a
/// `NearbyByteConnection`. This is the ONLY place in `AstroMobileTransport`
/// that reasons about byte buffering off a socket; everything above it
/// (framing, handshake, secure channel, package transport) already has its
/// own test coverage against `InMemoryDuplexConnection` and is reused
/// unchanged here.
///
/// Buffering contract: `receive()` accumulates raw bytes from the connection
/// until `NearbyFrameCodec.decode` can produce one whole frame, then returns
/// exactly that frame and keeps any surplus bytes buffered for the next
/// call. A peer that never completes a coherent frame cannot grow this
/// buffer without bound: `NearbyFrameCodec.decode` inspects the 6-byte
/// header (and rejects an oversized declared length) as soon as that many
/// bytes are available, and — belt-and-suspenders, in case a single
/// underlying `receive` completion ever handed back an oversized chunk in
/// one shot — every append is also checked against `maxBufferedBytes`
/// (header + `maxFramePayloadBytes`) directly, failing closed with
/// `.frameTooLarge` before any further I/O.
///
/// Concurrency contract: this type does not support more than one in-flight
/// `receive()` call at a time (mirroring `InMemoryDuplexConnection`'s
/// single-reader mailbox); callers — the pairing handshake and the secure
/// channel — already only ever call `receive()` sequentially. `send()` may
/// be called concurrently with an in-flight `receive()` (the two use
/// disjoint state), but concurrent `send()` calls are simply serialized by
/// actor isolation.
actor NearbyNWConnection: NearbyByteConnection {
    /// Lifecycle of the underlying `NWConnection`, tracked so `send`/
    /// `receive` can await first readiness and then fail fast forever after
    /// any terminal transition.
    private enum Lifecycle {
        case starting
        case ready
        case closed(NearbyTransportError)
    }

    /// Header (6 bytes) plus the largest payload a single frame may declare.
    /// The hard ceiling this connection ever buffers before it gives up and
    /// fails closed.
    private static let maxBufferedBytes = 6 + NearbyFrameCodec.maxFramePayloadBytes

    /// One dedicated serial queue per connection: `NWConnection` delivers all
    /// callbacks for a given instance serially on whatever queue it was
    /// started with, so a fresh queue per wrapper keeps connections fully
    /// independent of one another.
    private let queue = DispatchQueue(label: "com.astrotool.nearby.connection")

    private let connection: NWConnection
    private var lifecycle: Lifecycle = .starting
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var receiveBuffer = Data()
    private var isReceiveInFlight = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Wires the state handler and starts the underlying `NWConnection`.
    /// Must be called exactly once, before any `send`/`receive`. Does not
    /// itself wait for readiness — `send`/`receive` (and the browser's own
    /// connect helper) do that via `waitUntilReady()`.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handle(state: state) }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: NearbyFrame) async throws {
        try await waitUntilReady()
        let data = NearbyFrameCodec.encode(frame)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        continuation.resume(throwing: NearbyTransportError.connectionClosed)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } catch {
            fail(with: .connectionClosed)
            throw error
        }
    }

    func receive() async throws -> NearbyFrame {
        try await waitUntilReady()
        guard !isReceiveInFlight else {
            // Documented misuse (see the type's doc comment): fail closed
            // rather than corrupt the shared receive buffer with two
            // interleaved readers.
            throw NearbyTransportError.connectionClosed
        }
        isReceiveInFlight = true
        defer { isReceiveInFlight = false }

        while true {
            if let (frame, consumed) = try attemptDecode() {
                receiveBuffer.removeFirst(consumed)
                return frame
            }
            let chunk = try await receiveChunk()
            receiveBuffer.append(chunk)
            guard receiveBuffer.count <= Self.maxBufferedBytes else {
                fail(with: .frameTooLarge)
                throw NearbyTransportError.frameTooLarge
            }
        }
    }

    func cancel() async {
        connection.cancel()
        fail(with: .connectionClosed)
    }

    /// Test-only: writes raw bytes directly to the underlying connection,
    /// bypassing `NearbyFrameCodec.encode` entirely. Lets tests craft
    /// malformed or truncated wire traffic (an oversized declared length, a
    /// frame abandoned partway through) without needing their own raw
    /// `NWConnection`. Reachable only via `@testable import
    /// AstroMobileTransport` plus a downcast from `any NearbyByteConnection`
    /// to this concrete type.
    func sendRawBytesForTesting(_ data: Data) async throws {
        try await waitUntilReady()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    continuation.resume(throwing: NearbyTransportError.connectionClosed)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Readiness

    private func waitUntilReady() async throws {
        switch lifecycle {
        case .ready:
            return
        case .closed(let error):
            throw error
        case .starting:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyWaiters.append(continuation)
            }
        }
    }

    /// Used only by `NearbyBonjourBrowser`, which must know whether a
    /// just-created connection ever reaches `.ready` (rather than sitting in
    /// `.waiting`, retrying a refused endpoint forever) before it can hand
    /// the connection back to its caller.
    fileprivate func waitUntilReadyOrFailed() async throws {
        try await waitUntilReady()
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            guard case .starting = lifecycle else { return }
            lifecycle = .ready
            resumeReadyWaiters(with: .success(()))
        case .failed, .cancelled:
            fail(with: .connectionClosed)
        default:
            // `.setup` and `.waiting` are transient (waiting includes
            // automatic reconnect attempts on a refused/unreachable
            // endpoint); the caller's own timeout is what bounds those.
            break
        }
    }

    private func resumeReadyWaiters(with result: Result<Void, Error>) {
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters {
            switch result {
            case .success: waiter.resume()
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    private func fail(with error: NearbyTransportError) {
        if case .closed = lifecycle { return }
        lifecycle = .closed(error)
        resumeReadyWaiters(with: .failure(error))
    }

    // MARK: - Decoding

    private func attemptDecode() throws -> (frame: NearbyFrame, consumedBytes: Int)? {
        do {
            return try NearbyFrameCodec.decode(receiveBuffer)
        } catch NearbyTransportError.incompleteFrame {
            return nil
        } catch let error as NearbyTransportError {
            fail(with: error)
            throw error
        }
    }

    /// Reads one chunk of raw bytes off the connection. Throws
    /// `.connectionClosed` for a network error, or for a clean remote close
    /// (`isComplete` with no further content) — including mid-frame, which
    /// is exactly the case the caller's decode loop is still waiting on more
    /// bytes for.
    private func receiveChunk() async throws -> Data {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let content, !content.isEmpty {
                        continuation.resume(returning: content)
                        return
                    }
                    if isComplete {
                        continuation.resume(throwing: NearbyTransportError.connectionClosed)
                        return
                    }
                    // No content, no error, not complete: spurious wakeup.
                    // NWConnection does not normally produce this, but fail
                    // safe rather than return an empty chunk that would spin
                    // the caller's loop.
                    continuation.resume(throwing: NearbyTransportError.connectionClosed)
                }
            }
        } catch {
            fail(with: .connectionClosed)
            throw NearbyTransportError.connectionClosed
        }
    }
}

/// Publishes (or, for tests, listens without publishing) the AstroTool
/// nearby service and hands each inbound connection out as a
/// `NearbyByteConnection`.
///
/// Kept thin per the plan: no crypto, no retry logic beyond what
/// `NWListener` itself does, no multicast. Everything above the raw byte
/// stream — framing, pairing, the secure channel, package transport — is
/// already implemented and tested against `InMemoryDuplexConnection`; this
/// type's only job is producing connections that behave the same way.
public actor NearbyBonjourListener {
    private enum Mode {
        case bonjour(serviceName: String)
        /// Test-only: listens on an OS-assigned loopback TCP port without
        /// publishing a Bonjour service, so tests exercise the real
        /// `NWListener`/`NWConnection` machinery without a local-network
        /// permission prompt or any dependency on mDNS. Never reachable from
        /// the public API.
        case loopbackTest
    }

    private static let queue = DispatchQueue(label: "com.astrotool.nearby.listener")

    private let mode: Mode
    private var listener: NWListener?
    private var streamContinuation: AsyncStream<any NearbyByteConnection>.Continuation?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var loopbackPortValue: UInt16?

    /// `serviceName` is the Bonjour service INSTANCE name (what shows up to
    /// a browsing peer, e.g. "Zoltán's Mac") — never the service TYPE, which
    /// is always the fixed `NearbyBonjour.serviceType`. An empty string (the
    /// default) lets the system pick and disambiguate an instance name,
    /// which is the right default for a device with no configured display
    /// name yet.
    public init(serviceName: String = "") {
        self.mode = .bonjour(serviceName: serviceName)
    }

    private init(mode: Mode) {
        self.mode = mode
    }

    /// Test-only seam (see `Mode.loopbackTest`). `package` visibility: only
    /// reachable via `@testable import AstroMobileTransport`.
    package static func loopbackForTesting() -> NearbyBonjourListener {
        NearbyBonjourListener(mode: .loopbackTest)
    }

    /// The OS-assigned port a `loopbackForTesting()` listener bound to,
    /// valid once `start()`'s returned stream exists. `nil` for a
    /// Bonjour-publishing listener (peers discover it by service type, never
    /// by port) or before the listener reaches `.ready`.
    package var boundLoopbackPortForTesting: UInt16? {
        loopbackPortValue
    }

    /// Starts listening and returns a stream of every inbound connection,
    /// each already wrapped as a `NearbyByteConnection`. Throws if the
    /// underlying `NWListener` fails to reach `.ready` (e.g. the OS refuses
    /// to bind). Call `stop()` to end the stream and tear the listener down;
    /// `start()` may not be called again on the same instance afterward.
    public func start() async throws -> AsyncStream<any NearbyByteConnection> {
        precondition(listener == nil, "NearbyBonjourListener.start() called more than once")

        let parameters = NWParameters.tcp
        switch mode {
        case .bonjour:
            parameters.includePeerToPeer = true
        case .loopbackTest:
            parameters.includePeerToPeer = false
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        }

        let newListener = try NWListener(using: parameters)
        if case .bonjour(let serviceName) = mode {
            newListener.service = NWListener.Service(
                name: serviceName.isEmpty ? nil : serviceName,
                type: NearbyBonjour.serviceType
            )
        }

        let (stream, continuation) = AsyncStream<any NearbyByteConnection>.makeStream()
        streamContinuation = continuation

        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        newListener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(listenerState: state) }
        }

        listener = newListener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            startContinuation = continuation
            newListener.start(queue: Self.queue)
        }
        return stream
    }

    /// Tears the listener down and ends the `AsyncStream` returned by
    /// `start()`. Idempotent.
    public func stop() async {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        loopbackPortValue = nil
        streamContinuation?.finish()
        streamContinuation = nil
        resumeStart(with: .failure(NearbyTransportError.connectionClosed))
    }

    private func accept(_ connection: NWConnection) async {
        let wrapper = NearbyNWConnection(connection: connection)
        await wrapper.start()
        streamContinuation?.yield(wrapper)
    }

    private func handle(listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            if case .loopbackTest = mode {
                loopbackPortValue = listener?.port?.rawValue
            }
            resumeStart(with: .success(()))
        case .failed:
            resumeStart(with: .failure(NearbyTransportError.connectionClosed))
            streamContinuation?.finish()
        case .cancelled:
            streamContinuation?.finish()
        default:
            break
        }
    }

    private func resumeStart(with result: Result<Void, Error>) {
        guard let startContinuation else { return }
        self.startContinuation = nil
        switch result {
        case .success: startContinuation.resume()
        case .failure(let error): startContinuation.resume(throwing: error)
        }
    }
}

/// Browses for the AstroTool nearby service and connects to the first peer
/// found. One attempt only — no retry loop beyond what a single `NWBrowser`
/// result and a single `NWConnection` attempt give — racing a caller-
/// supplied timeout.
///
/// The timeout race mirrors `NearbyPairingSession.withTimeout` exactly:
/// the two branches (the real browse-and-connect attempt, and a bare
/// `Task.sleep`) run as sibling child tasks; whichever `group.next()`
/// reports first is the sole, uncontested winner. Only once that winner is
/// committed to do we (if it was the timeout) cancel the in-flight
/// browser/connection — purely to unblock the loser so the task group's
/// implicit "await remaining children" on scope exit cannot hang. The
/// loser's own result, if any, is simply discarded.
public actor NearbyBonjourBrowser {
    private static let queue = DispatchQueue(label: "com.astrotool.nearby.browser")

    private var browser: NWBrowser?
    private var pendingConnection: NWConnection?

    public init() {}

    /// Browses for `NearbyBonjour.serviceType` and connects to the first
    /// peer found, or throws `.connectionTimeout` if none is found and
    /// connected within `timeout`.
    public func connectToFirstMatch(timeout: Duration) async throws -> any NearbyByteConnection {
        try await raceAgainstTimeout(timeout) {
            try await self.browseAndConnectToFirstBonjourMatch()
        }
    }

    /// Test-only seam: connects directly to `127.0.0.1:port` — no browsing,
    /// no Bonjour, no peer-to-peer — so tests can exercise the same
    /// `NWConnection` wrapping and the same timeout race without depending
    /// on Bonjour publication. `package` visibility: only reachable via
    /// `@testable import AstroMobileTransport`.
    package func connectDirectlyForTesting(port: UInt16, timeout: Duration) async throws -> any NearbyByteConnection {
        try await raceAgainstTimeout(timeout) {
            try await self.connectLoopback(port: port)
        }
    }

    /// Cancels any in-flight browse or connection attempt. Idempotent.
    public func cancel() async {
        await cancelInFlight()
    }

    // MARK: - Bonjour path

    private func browseAndConnectToFirstBonjourMatch() async throws -> any NearbyByteConnection {
        let browseParameters = NWParameters.tcp
        browseParameters.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: NearbyBonjour.serviceType, domain: nil), using: browseParameters)
        browser = newBrowser

        let endpoint = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint, Error>) in
            let resumeOnce = ResumeOnce()
            newBrowser.browseResultsChangedHandler = { results, _ in
                guard let first = results.first, resumeOnce.tryResume() else { return }
                continuation.resume(returning: first.endpoint)
            }
            newBrowser.stateUpdateHandler = { state in
                // Both `.failed` (a genuine browse error) and `.cancelled`
                // (this browser being torn down by `cancelInFlight()` when
                // the outer timeout wins) must resume this continuation —
                // otherwise a cancellation that arrives before any result
                // ever leaves this child task permanently suspended, and the
                // enclosing task group's implicit "await every child" on
                // scope exit hangs forever.
                switch state {
                case .failed, .cancelled:
                    if resumeOnce.tryResume() {
                        continuation.resume(throwing: NearbyTransportError.connectionClosed)
                    }
                default:
                    break
                }
            }
            newBrowser.start(queue: Self.queue)
        }
        newBrowser.cancel()
        browser = nil

        let connectParameters = NWParameters.tcp
        connectParameters.includePeerToPeer = true
        return try await connect(to: endpoint, using: connectParameters)
    }

    // MARK: - Loopback test path

    private func connectLoopback(port: UInt16) async throws -> any NearbyByteConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NearbyTransportError.connectionClosed
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        return try await connect(to: endpoint, using: parameters)
    }

    // MARK: - Shared connect + timeout

    private func connect(to endpoint: NWEndpoint, using parameters: NWParameters) async throws -> any NearbyByteConnection {
        let rawConnection = NWConnection(to: endpoint, using: parameters)
        pendingConnection = rawConnection
        let wrapper = NearbyNWConnection(connection: rawConnection)
        await wrapper.start()
        do {
            try await wrapper.waitUntilReadyOrFailed()
        } catch {
            pendingConnection = nil
            throw error
        }
        pendingConnection = nil
        return wrapper
    }

    private func cancelInFlight() async {
        browser?.cancel()
        browser = nil
        pendingConnection?.cancel()
        pendingConnection = nil
    }

    private func raceAgainstTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                return nil
            }

            guard let first = try await group.next() else {
                group.cancelAll()
                throw NearbyTransportError.connectionTimeout
            }
            if let value = first {
                group.cancelAll()
                return value
            }
            // The timeout sentinel won the race: commit to failing before
            // touching the browser/connection.
            await cancelInFlight()
            group.cancelAll()
            throw NearbyTransportError.connectionTimeout
        }
    }
}
