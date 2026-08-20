@testable import AstroApplication
import Foundation
import Testing

@Suite("Scoped V2 background operations")
struct OperationCenterTests {
    @Test("Operation kinds and policies have stable value semantics")
    func operationMetadataHasValueSemantics() {
        let kinds: [OperationKind] = [
            .scan(library: "A"),
            .loadHome(library: "B"),
            .rate(series: "S"),
            .audit(library: "C"),
            .export(project: "P"),
            .convert(session: "N"),
            .sensorMeasurement(library: "D"),
            // Wave 0 seam (V3 pre-stack program): `.buildMaster`/
            // `.liveNightWatch` are stub cases nothing constructs for real
            // yet (sections 5.2/5.6) -- this pins that they exist, stay
            // Hashable, and stay distinct from every case above and from
            // each other.
            .buildMaster(combo: "dark-120s--20C"),
            .liveNightWatch,
        ]

        #expect(Set(kinds).count == kinds.count)
        #expect(Set([CancellationPolicy.cooperative, .discardResult, .unavailable]).count == 3)
        #expect(Set([OperationPhase.running, .succeeded, .failed, .cancelled]).count == 4)
    }

    @Test("Operation state exposes completed work through its public API")
    func operationStateExposesCompletedWork() async {
        let center = OperationCenter()
        let operation = await center.start(
            kind: .scan(library: "A"),
            cancellation: .cooperative
        )

        #expect(operation.completed == 0)
        #expect(await center.progress(operation.id, to: 3, total: 10))
        #expect(await center.state(operation.id)?.completed == 3)
    }

    @Test("Cancelling one operation does not cancel unrelated work")
    func operationsAreScopedAndDoNotCancelUnrelatedWork() async {
        let center = OperationCenter()
        let scan = await center.start(kind: .scan(library: "A"), cancellation: .cooperative)
        let export = await center.start(kind: .export(project: "P"), cancellation: .discardResult)

        #expect(await center.cancel(scan.id))
        #expect(await center.state(scan.id)?.phase == .cancelled)
        #expect(await center.state(export.id)?.phase == .running)
    }

    @Test("Cooperative cancellation invokes its handler exactly once")
    func cooperativeCancellationInvokesHandlerOnce() async {
        let center = OperationCenter()
        let spy = CancellationSpy()
        let operation = await center.start(
            kind: .scan(library: "A"),
            cancellation: .cooperative,
            cancelHandler: { spy.record() }
        )

        #expect(await center.cancel(operation.id))
        #expect(!(await center.cancel(operation.id)))
        #expect(spy.count == 1)
    }

    @Test("Every terminal transition releases cancellation-handler captures")
    func terminalTransitionsReleaseCancellationCaptures() async {
        let center = OperationCenter()
        let (completed, completedCapture) = await startTrackedOperation(
            center: center,
            kind: .scan(library: "A"),
            cancellation: .cooperative
        )
        let (failed, failedCapture) = await startTrackedOperation(
            center: center,
            kind: .rate(series: "S"),
            cancellation: .cooperative
        )
        let (cancelled, cancelledCapture) = await startTrackedOperation(
            center: center,
            kind: .export(project: "P"),
            cancellation: .discardResult
        )

        #expect(completedCapture.value != nil)
        #expect(failedCapture.value != nil)
        #expect(cancelledCapture.value != nil)
        #expect(await center.finish(completed.id))
        #expect(await center.fail(failed.id, message: "failed"))
        #expect(await center.cancel(cancelled.id))
        #expect(completedCapture.value == nil)
        #expect(failedCapture.value == nil)
        #expect(cancelledCapture.value == nil)
    }

    /// `.timeLimit` rather than a hand-rolled deadline: if `cancel(_:)` ever
    /// regresses to invoking the handler inline on the actor, the two
    /// `center.state(_:)` calls below never return, and a trait is what turns
    /// that hang into a reported failure. It is a hang guard, not a
    /// performance assertion -- the body takes microseconds.
    @Test(
        "A blocking reentrant cancellation handler does not occupy the actor",
        .timeLimit(.minutes(1))
    )
    func blockingCancellationHandlerLeavesOtherStateResponsive() async {
        let center = OperationCenter()
        let unrelated = await center.start(
            kind: .audit(library: "B"),
            cancellation: .unavailable
        )
        let handler = BlockingCancelHandler()
        let cancellable = await center.start(
            kind: .scan(library: "A"),
            cancellation: .cooperative,
            cancelHandler: { handler.enterAndBlock() }
        )

        let cancellation = Task { await center.cancel(cancellable.id) }
        await handler.waitUntilBlocking()

        // The handler is sitting in a blocking `wait()` right now, inside the
        // `Task.detached` that `cancel(_:)` runs it on, and `cancel(_:)` is
        // itself suspended awaiting it. These two queries reach the actor
        // anyway -- that is the property.
        //
        // They deliberately run on this test's own, already-scheduled task
        // rather than a fresh `Task.detached`. The previous version fired the
        // reentrant query from inside the handler and then blocked a SECOND
        // cooperative-pool thread waiting up to a second for it, so proving
        // the point required three pool threads at once while holding two of
        // them hostage. See `BlockingCancelHandler` for what that cost the
        // rest of the suite.
        #expect(await center.state(unrelated.id)?.phase == .running)
        #expect(await center.state(cancellable.id)?.phase == .cancelled)

        handler.release()
        #expect(await cancellation.value)
    }

    @Test("Discard-result cancellation is terminal without stopping a worker")
    func discardResultCancellationRejectsWorkerUpdates() async {
        let center = OperationCenter()
        let spy = CancellationSpy()
        let operation = await center.start(
            kind: .export(project: "P"),
            cancellation: .discardResult,
            cancelHandler: { spy.record() }
        )

        #expect(await center.cancel(operation.id))
        #expect(spy.count == 0)
        #expect(!(await center.progress(operation.id, to: 5, total: 10)))
        #expect(!(await center.finish(operation.id)))
        #expect(await center.state(operation.id)?.phase == .cancelled)
    }

    @Test("Unavailable cancellation leaves the operation running")
    func unavailableCancellationLeavesRunning() async {
        let center = OperationCenter()
        let operation = await center.start(
            kind: .audit(library: "A"),
            cancellation: .unavailable
        )

        #expect(!(await center.cancel(operation.id)))
        #expect(await center.state(operation.id)?.phase == .running)
        #expect(await center.progress(operation.id, to: 1, total: 2))
    }

    @Test("Terminal completion is idempotent and immutable")
    func duplicateCompletionDoesNotMutateTerminalState() async {
        let center = OperationCenter()
        let operation = await center.start(
            kind: .loadHome(library: "A"),
            cancellation: .unavailable
        )

        #expect(await center.finish(operation.id))
        let completed = await center.state(operation.id)
        #expect(!(await center.finish(operation.id)))
        #expect(!(await center.fail(operation.id, message: "late failure")))
        #expect(!(await center.cancel(operation.id)))
        #expect(await center.state(operation.id) == completed)
    }

    @Test("Failures preserve an error message and terminal timestamps")
    func failureCapturesDiagnostics() async {
        let center = OperationCenter()
        let operation = await center.start(
            kind: .rate(series: "S"),
            cancellation: .cooperative
        )

        #expect(await center.fail(operation.id, message: "rating failed"))
        let failed = await center.state(operation.id)

        #expect(failed?.phase == .failed)
        #expect(failed?.errorMessage == "rating failed")
        #expect(failed?.finishedAt != nil)
        #expect(failed?.updatedAt == failed?.finishedAt)
        #expect((failed?.updatedAt ?? .distantPast) >= (failed?.startedAt ?? .distantFuture))
    }

    @Test("Progress is monotonic, validated, and clamped to its total")
    func progressRejectsStaleAndInvalidUpdates() async {
        let center = OperationCenter()
        let operation = await center.start(
            kind: .convert(session: "N"),
            cancellation: .cooperative
        )

        #expect(await center.progress(operation.id, to: 5, total: 10))
        let accepted = await center.state(operation.id)
        #expect(!(await center.progress(operation.id, to: 4, total: 10)))
        #expect(!(await center.progress(operation.id, to: -1, total: 10)))
        #expect(!(await center.progress(operation.id, to: 6, total: -1)))
        #expect(await center.state(operation.id) == accepted)

        #expect(await center.progress(operation.id, to: 50, total: 12))
        #expect(await center.state(operation.id)?.completed == 12)
        #expect(await center.state(operation.id)?.total == 12)
    }

    @Test("Unknown operation updates are rejected")
    func unknownUpdatesAreRejected() async {
        let center = OperationCenter()
        let missing = UUID()

        #expect(!(await center.progress(missing, to: 1, total: 1)))
        #expect(!(await center.finish(missing)))
        #expect(!(await center.fail(missing, message: "missing")))
        #expect(!(await center.cancel(missing)))
        #expect(await center.state(missing) == nil)
    }

    @Test("Operation snapshots remain in deterministic start order")
    func statesAreOrderedByStart() async {
        let center = OperationCenter()
        let first = await center.start(kind: .scan(library: "A"), cancellation: .cooperative)
        let second = await center.start(kind: .audit(library: "A"), cancellation: .unavailable)
        let third = await center.start(kind: .export(project: "P"), cancellation: .discardResult)

        #expect(await center.states().map(\.id) == [first.id, second.id, third.id])
        #expect(first.startedAt <= second.startedAt)
        #expect(second.startedAt <= third.startedAt)
    }
}

private final class CancellationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.withLock { recordedCount }
    }

    func record() {
        lock.withLock { recordedCount += 1 }
    }
}

private final class TrackedCapture: @unchecked Sendable {}

private final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

private func startTrackedOperation(
    center: OperationCenter,
    kind: OperationKind,
    cancellation: CancellationPolicy
) async -> (OperationState, WeakReference<TrackedCapture>) {
    let capture = TrackedCapture()
    let reference = WeakReference(capture)
    let operation = await center.start(
        kind: kind,
        cancellation: cancellation,
        cancelHandler: { withExtendedLifetime(capture) {} }
    )
    return (operation, reference)
}

/// The deliberately-blocking cancel handler that
/// `blockingCancellationHandlerLeavesOtherStateResponsive` installs.
///
/// Nothing here may park a thread of the Swift concurrency cooperative pool
/// except the handler body itself -- whose blocking IS the behaviour under
/// test, and which `OperationCenter.cancel` deliberately runs on a
/// `Task.detached` precisely so it cannot occupy the actor. That pool is
/// process-wide and fixed-width (one thread per active core, 10 on this
/// machine) and swift-testing runs all 112 suites on it concurrently, so a
/// task that parks on a `DispatchSemaphore` takes a thread out of
/// circulation for every other suite too.
///
/// The version this replaces did that twice over and then made it worse: the
/// handler fired a reentrant `center.state(_:)` query on a THIRD
/// `Task.detached` and blocked a SECOND pool thread waiting up to a second
/// for it to answer. When the pool was busy -- which, in a 2441-test parallel
/// run, it continuously is -- the query could not be scheduled, so the wait
/// burned its full second with two threads pinned, and every other test that
/// needed a `Task.detached` to start promptly in that window missed its own
/// deadline. That was the entire load-dependent half of the suite's flake:
/// `LibraryLaunchScanTests` (4 tests), `LibraryHealthStoreTests` (3),
/// `ReviewStoreTests` -- none of which have anything to do with
/// cancellation, all of which are just waiting on `OperationHost.run`'s
/// detached task. Skipping this one test made all of them green across three
/// consecutive full parallel runs, which is how it was identified.
///
/// So the reentrant query moved to the test's own, already-running task: the
/// property ("the actor answers while a blocking handler is in flight") is
/// asserted directly instead of through two proxies, no additional pool
/// thread has to come free for the assertion to be reachable, and the one
/// thread that is blocked stays blocked for an actor round-trip rather than
/// for up to a second.
private final class BlockingCancelHandler: @unchecked Sendable {
    private let mayReturn = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isBlocking = false

    /// The cancel handler proper. Runs on the `Task.detached` inside
    /// `OperationCenter.cancel`, and parks that task's thread until
    /// `release()`. The timeout is a safety net against hanging a whole
    /// parallel test run if an assertion above it throws before `release()`
    /// is reached -- never the expected path.
    func enterAndBlock() {
        lock.withLock { isBlocking = true }
        _ = mayReturn.wait(timeout: .now() + 30)
    }

    /// Suspends -- without holding a cooperative thread -- until the handler
    /// has entered its blocking wait. Unbounded on purpose: the test carries
    /// a `.timeLimit` trait, which reports a hang as a failure instead of
    /// letting a hand-rolled deadline turn "the pool was busy for a moment"
    /// into a spurious one.
    func waitUntilBlocking() async {
        while !lock.withLock({ isBlocking }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        mayReturn.signal()
    }
}
