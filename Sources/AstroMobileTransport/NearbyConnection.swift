import Foundation

/// An async byte-oriented connection carrying one `NearbyFrame` at a time in
/// each direction. A real implementation (Task 5) wraps a Network-framework
/// `NWConnection`; `InMemoryDuplexConnection` below is the in-memory test
/// double every handshake and channel test in this module runs against.
///
/// `cancel()` is expected to unblock any in-flight `receive()` on either end
/// of the connection (not just the end `cancel()` was called on) — the
/// pairing handshake's timeout path relies on this to guarantee it never
/// blocks forever on a peer that stops answering.
public protocol NearbyByteConnection: Sendable {
    func send(_ frame: NearbyFrame) async throws
    func receive() async throws -> NearbyFrame
    func cancel() async
}

/// Two cross-wired in-memory connections for tests: a frame sent on one end
/// is delivered to the other end's `receive()`, and vice versa. `cancel()`
/// called on EITHER end finishes both directions, so a `receive()` blocked
/// on either end unblocks — throwing `NearbyTransportError.connectionClosed`
/// — rather than hanging forever. Sending after cancellation throws the same
/// error.
///
/// `package` visibility: production code never constructs this directly;
/// tests reach it through `@testable import AstroMobileTransport`.
package actor InMemoryDuplexConnection: NearbyByteConnection {
    private let outbound: Mailbox
    private let inbound: Mailbox

    private init(outbound: Mailbox, inbound: Mailbox) {
        self.outbound = outbound
        self.inbound = inbound
    }

    /// Builds one cross-wired pair: frames sent on `a` arrive at `b.receive()`
    /// and frames sent on `b` arrive at `a.receive()`.
    package static func makePair() -> (a: InMemoryDuplexConnection, b: InMemoryDuplexConnection) {
        let aToB = Mailbox()
        let bToA = Mailbox()
        let a = InMemoryDuplexConnection(outbound: aToB, inbound: bToA)
        let b = InMemoryDuplexConnection(outbound: bToA, inbound: aToB)
        return (a, b)
    }

    package func send(_ frame: NearbyFrame) async throws {
        guard outbound.deliver(frame) else { throw NearbyTransportError.connectionClosed }
    }

    package func receive() async throws -> NearbyFrame {
        guard let frame = await inbound.take() else { throw NearbyTransportError.connectionClosed }
        return frame
    }

    package func cancel() async {
        outbound.close()
        inbound.close()
    }

    /// A single-reader, multi-writer mailbox: `deliver` enqueues (or fails
    /// once closed), `take` suspends until a frame is available or the
    /// mailbox closes. Plain-lock based rather than actor-isolated so a
    /// frame can be handed from one `InMemoryDuplexConnection` instance
    /// straight into the other's without an isolation hop, and so `close()`
    /// can reach in from whichever end called `cancel()`.
    fileprivate final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffered: [NearbyFrame] = []
        private var waiter: CheckedContinuation<NearbyFrame?, Never>?
        private var isClosed = false

        /// Returns `false` without enqueuing if the mailbox is already closed.
        @discardableResult
        func deliver(_ frame: NearbyFrame) -> Bool {
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                return false
            }
            if let waiter {
                self.waiter = nil
                lock.unlock()
                waiter.resume(returning: frame)
            } else {
                buffered.append(frame)
                lock.unlock()
            }
            return true
        }

        /// Suspends until a frame is available, or returns `nil` once the
        /// mailbox is closed (immediately, if it is already closed with an
        /// empty buffer). Only one `take()` may be in flight at a time.
        func take() async -> NearbyFrame? {
            await withCheckedContinuation { (continuation: CheckedContinuation<NearbyFrame?, Never>) in
                lock.lock()
                if !buffered.isEmpty {
                    let frame = buffered.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: frame)
                } else if isClosed {
                    lock.unlock()
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        }

        func close() {
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                return
            }
            isClosed = true
            let pendingWaiter = waiter
            waiter = nil
            lock.unlock()
            pendingWaiter?.resume(returning: nil)
        }
    }
}
