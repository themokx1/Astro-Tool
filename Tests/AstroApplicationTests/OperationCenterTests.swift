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
