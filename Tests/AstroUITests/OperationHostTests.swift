import AstroApplication
import Foundation
import Testing

@testable import AstroUI

@MainActor
@Suite("V2 operation backbone")
struct OperationHostTests {
    @Test("Running work registers it with OperationCenter and projects it while active")
    func runRegistersActiveOperation() async throws {
        let center = OperationCenter()
        let host = OperationHost(center: center)
        let gate = AsyncGate()

        let id = await host.run(kind: .scan(library: "A"), title: "Scanning A") {
            await gate.waitToProceed()
        }

        #expect(host.activeOperations.contains { $0.id == id })
        #expect(await center.state(id)?.phase == .running)

        gate.open()
        try await waitUntil { host.activeOperations.isEmpty }
        #expect(await center.state(id)?.phase == .succeeded)
    }

    @Test("Successful work enqueues a success toast and clears the active projection")
    func successEnqueuesSuccessToast() async throws {
        let host = OperationHost(center: OperationCenter())

        let id = await host.run(kind: .export(project: "P"), title: "Exporting P") {}

        try await waitUntil { host.activeOperations.isEmpty }
        #expect(host.toasts.contains { $0.level == .success })
        #expect(!host.activeOperations.contains { $0.id == id })
    }

    @Test("A thrown error enqueues a failure toast and marks the operation failed")
    func failureEnqueuesFailureToast() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let center = OperationCenter()
        let host = OperationHost(center: center)

        let id = await host.run(kind: .rate(series: "S"), title: "Rating S") {
            throw Boom()
        }

        try await waitUntil { host.activeOperations.isEmpty }
        #expect(await center.state(id)?.phase == .failed)
        #expect(host.toasts.contains { $0.level == .failure && $0.message.contains("boom") })
    }

    @Test("Cancelling cooperative work ends it as cancelled, not a failure blaming the work")
    func cancelEndsWorkAsCancelledWithoutBlamingFailureToast() async throws {
        let center = OperationCenter()
        let host = OperationHost(center: center)
        let observedCancellation = ObservedFlag()

        let id = await host.run(
            kind: .audit(library: "A"),
            title: "Auditing A",
            cancellation: .cooperative
        ) {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch is CancellationError {
                await observedCancellation.set(true)
                throw CancellationError()
            }
        }

        let didCancel = await host.cancel(id: id)

        #expect(didCancel)
        #expect(await center.state(id)?.phase == .cancelled)
        #expect(await observedCancellation.value)
        #expect(!host.activeOperations.contains { $0.id == id })
        #expect(!host.toasts.contains { $0.level == .failure })
    }

    @Test("Reporting progress updates the active projection and forwards to OperationCenter")
    func reportProgressUpdatesActiveProjectionAndCenter() async throws {
        let center = OperationCenter()
        let host = OperationHost(center: center)
        let gate = AsyncGate()

        let id = await host.run(kind: .scan(library: "A"), title: "Scanning A") {
            await gate.waitToProceed()
        }

        let didUpdate = await host.reportProgress(id: id, completed: 40, total: 100)

        #expect(didUpdate)
        #expect(host.activeOperations.first { $0.id == id }?.completed == 40)
        #expect(host.activeOperations.first { $0.id == id }?.total == 100)
        #expect(await center.state(id)?.completed == 40)
        #expect(await center.state(id)?.total == 100)

        gate.open()
        try await waitUntil { host.activeOperations.isEmpty }
    }

    @Test("Reporting progress for an unknown operation is a harmless no-op")
    func reportProgressForUnknownOperationIsNoOp() async throws {
        let host = OperationHost(center: OperationCenter())

        let didUpdate = await host.reportProgress(id: UUID(), completed: 10, total: 20)

        #expect(!didUpdate)
        #expect(host.activeOperations.isEmpty)
    }

    @Test("A standalone notification posts a toast without a running operation")
    func standaloneNotificationPostsToastWithoutOperation() async throws {
        let host = OperationHost(center: OperationCenter())

        host.notify(.info, message: "Choose a library before rescanning.")

        #expect(host.activeOperations.isEmpty)
        #expect(host.toasts.contains { $0.level == .info && $0.message == "Choose a library before rescanning." })
    }

    @Test("Toasts can be dismissed individually")
    func dismissToastRemovesOnlyThatToast() async throws {
        let host = OperationHost(center: OperationCenter())
        _ = await host.run(kind: .export(project: "P"), title: "Exporting P") {}
        try await waitUntil { !host.toasts.isEmpty }
        let toastID = try #require(host.toasts.first?.id)

        host.dismissToast(id: toastID)

        #expect(!host.toasts.contains { $0.id == toastID })
    }

    @Test("Toasts expire once the injected clock passes their lifetime")
    func expireToastsRemovesStaleToastsOnly() async throws {
        var now = Date(timeIntervalSince1970: 0)
        let host = OperationHost(
            center: OperationCenter(),
            clock: { now },
            toastLifetime: { _ in 4 }
        )
        _ = await host.run(kind: .export(project: "P"), title: "Exporting P") {}
        try await waitUntil { !host.toasts.isEmpty }

        now = now.addingTimeInterval(1)
        host.expireToasts(now: now)
        #expect(!host.toasts.isEmpty)

        now = now.addingTimeInterval(10)
        host.expireToasts(now: now)
        #expect(host.toasts.isEmpty)
    }
}

/// Polls a MainActor-isolated condition until it becomes true, bounded so a
/// broken implementation fails the test instead of hanging the suite.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            Issue.record("Condition not met within \(timeout)s")
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Lets a test hold a piece of work open until it explicitly wants the
/// operation to observe completion, without depending on wall-clock sleeps.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitToProceed() async {
        let alreadyOpen: Bool = lock.withLock { isOpen }
        if alreadyOpen { return }
        await withCheckedContinuation { continuation in
            let shouldResumeNow: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }
}

private final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.withLock { flag }
    }

    func set(_ newValue: Bool) {
        lock.withLock { flag = newValue }
    }
}
