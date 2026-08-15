import AstroApplication
import Foundation
import Observation
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

    // MARK: - `outcome(of:)`/`errorMessage(for:)` (Task 2: the launch-scan
    // preparation pipeline needs to react inline to a `run`-registered
    // operation's actual result, unlike every other fire-and-forget caller).

    @Test("outcome(of:) awaits a still-running operation and reports its final phase")
    func outcomeAwaitsAStillRunningOperation() async throws {
        let host = OperationHost(center: OperationCenter())
        let gate = AsyncGate()

        let id = await host.run(kind: .loadHome(library: "A"), title: "Preparing A") {
            await gate.waitToProceed()
        }

        async let outcome = host.outcome(of: id)
        try await waitUntil { host.activeOperations.contains { $0.id == id } }
        gate.open()

        #expect(await outcome == .succeeded)
        #expect(!host.activeOperations.contains { $0.id == id })
    }

    @Test("outcome(of:) reports .failed for an operation whose work threw")
    func outcomeReportsFailed() async throws {
        struct Boom: Error {}
        let host = OperationHost(center: OperationCenter())

        let id = await host.run(kind: .loadHome(library: "A"), title: "Preparing A") {
            throw Boom()
        }

        #expect(await host.outcome(of: id) == .failed)
    }

    @Test("outcome(of:) called after an operation already finished still returns the recorded phase")
    func outcomeAfterAlreadyFinished() async throws {
        let host = OperationHost(center: OperationCenter())
        let id = await host.run(kind: .loadHome(library: "A"), title: "Preparing A") {}
        try await waitUntil { host.activeOperations.isEmpty }

        #expect(await host.outcome(of: id) == .succeeded)
    }

    @Test("errorMessage(for:) surfaces the actual thrown error's description for a failed operation")
    func errorMessageSurfacesTheFailureText() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let host = OperationHost(center: OperationCenter())
        let id = await host.run(kind: .loadHome(library: "A"), title: "Preparing A") {
            throw Boom()
        }

        _ = await host.outcome(of: id)

        #expect(await host.errorMessage(for: id) == "disk full")
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

    @Test("Work that ignores cancellation and completes anyway is recorded as succeeded, with a visible toast -- not silently swallowed as cancelled")
    func workThatOutrunsCancellationIsRecordedAsSucceededNotSilentlyCancelled() async throws {
        let center = OperationCenter()
        let host = OperationHost(center: center)
        let gate = AsyncGate()
        let started = ObservedFlag()

        let id = await host.run(
            kind: .audit(library: "A"),
            title: "Auditing A",
            cancellation: .cooperative
        ) {
            // Deliberately ignores `Task.isCancelled` -- simulates the exact
            // race the finding describes: `OperationCenter.cancel` flips the
            // entry's phase to `.cancelled` and calls the cancel handler,
            // but the work itself has already passed its last cooperative
            // check and finishes normally right after.
            started.set(true)
            await gate.waitToProceed()
        }

        try await waitUntil { started.value }

        // Cancel directly through `OperationCenter`, not `OperationHost.cancel`
        // -- for a `.cooperative` op the host's own `cancel(id:)` awaits the
        // run task's completion, which would deadlock here since the work
        // hasn't been released yet. Calling the center directly
        // deterministically reproduces the exact race the finding
        // describes: the center's own state flips to `.cancelled` strictly
        // BEFORE the ignored-cancellation work goes on to finish, rather
        // than leaving the ordering to chance.
        let didCancel = await center.cancel(id)
        #expect(didCancel)
        #expect(await center.state(id)?.phase == .cancelled)

        gate.open()
        try await waitUntil { host.activeOperations.isEmpty }

        // The work actually completed successfully -- the honest outcome is
        // success, not a silently-swallowed cancellation.
        #expect(await center.state(id)?.phase == .succeeded)
        #expect(host.toasts.contains { $0.level == .success })
        #expect(!host.toasts.contains { $0.message.contains("unexpectedly") })
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

    // Freeze diagnosis (build 20017, live-sampled): `ToastOverlay`'s `.task`
    // called `expireToasts(now:)` once a second FOREVER, even with zero
    // toasts, because `toasts.removeAll { ... }` goes through `@Observable`'s
    // `_modify` accessor unconditionally -- that registers a mutation (and so
    // notifies every observer) even when nothing was actually removed. Since
    // `ToastOverlay` sits on the root view, that one notification per second
    // invalidated the entire shell forever. These three tests pin
    // `expireToasts(now:)` to the honest contract: touch `toasts` (and so
    // notify) ONLY when a toast is actually removed.
    @Test("expireToasts is an observable no-op when there are no toasts at all")
    func expireToastsWithNoToastsDoesNotNotify() async throws {
        let host = OperationHost(center: OperationCenter())
        let counter = NotificationCounter()

        withObservationTracking {
            _ = host.toasts
        } onChange: {
            counter.increment()
        }

        host.expireToasts(now: Date())

        // Give an (incorrect) notification a moment to land before asserting
        // its absence -- `withObservationTracking`'s `onChange` fires
        // synchronously on mutation, but this guards against any accidental
        // async indirection creeping in later.
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(counter.value == 0)
    }

    @Test("expireToasts is an observable no-op when every toast is still unexpired")
    func expireToastsWithOnlyUnexpiredToastsDoesNotNotify() async throws {
        var now = Date(timeIntervalSince1970: 0)
        let host = OperationHost(center: OperationCenter(), clock: { now }, toastLifetime: { _ in 10 })
        _ = await host.run(kind: .export(project: "P"), title: "Exporting P") {}
        try await waitUntil { !host.toasts.isEmpty }

        let counter = NotificationCounter()
        withObservationTracking {
            _ = host.toasts
        } onChange: {
            counter.increment()
        }

        now = now.addingTimeInterval(1) // well within the 10s lifetime
        host.expireToasts(now: now)

        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(counter.value == 0)
        #expect(!host.toasts.isEmpty)
    }

    @Test("expireToasts removes an actually-expired toast and DOES notify observers")
    func expireToastsRemovesExpiredToastAndNotifies() async throws {
        var now = Date(timeIntervalSince1970: 0)
        let host = OperationHost(center: OperationCenter(), clock: { now }, toastLifetime: { _ in 4 })
        _ = await host.run(kind: .export(project: "P"), title: "Exporting P") {}
        try await waitUntil { !host.toasts.isEmpty }

        let counter = NotificationCounter()
        withObservationTracking {
            _ = host.toasts
        } onChange: {
            counter.increment()
        }

        now = now.addingTimeInterval(10) // past the 4s lifetime
        host.expireToasts(now: now)

        #expect(counter.value == 1)
        #expect(host.toasts.isEmpty)
    }

    // MARK: - Systemic S2: throttled progress relay
    //
    // Five hand-rolled poll loops (`LibraryHealthStore.verifyIntegrity`,
    // `SensorProfilesStore.measure`, `ReviewStore.rateSelectedSeries`,
    // `OnboardingStore.rescan`, `OnboardingStore.openAndScan`) each mutated
    // shared `@Observable` state at 20-50 Hz -- far faster than any human
    // perceives, and every observer (shell toolbar, `OperationStatusView`,
    // `HealthView`, `ReviewWorkspace`, onboarding views) re-rendered at that
    // rate for the entire duration of any long-running operation. These
    // tests pin `ProgressRelay`'s replacement contract.

    @Test("ProgressRelay.run throttles application to the polling interval, not to how often the underlying value changes")
    func progressRelayThrottlesToPollingInterval() async throws {
        let source = ThreadSafeBox(0)
        let applyCalls = ThreadSafeBox(0)
        let active = ThreadSafeBox(true)

        let task = ProgressRelay.run(
            interval: .milliseconds(20),
            while: { active.value },
            read: { source.value },
            apply: { _ in applyCalls.value += 1 }
        )

        // Hammer the source far faster than the relay can poll -- simulates
        // the 50 Hz hand-rolled loops this replaces pushing a fresh value on
        // every tick of the underlying work.
        let mutator = Task.detached {
            for i in 1...300 {
                source.value = i
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        active.value = false
        _ = await mutator.value
        await task.value

        // ~150ms at a 20ms interval is at most ~8-9 ticks plus one final
        // flush -- nowhere near the 300 individual changes the source went
        // through underneath it.
        #expect(applyCalls.value >= 1)
        #expect(applyCalls.value < 20)
    }

    @Test("ProgressRelay.run always applies the final value once isActive() goes false, even if it changed after the last tick")
    func progressRelayAppliesFinalValueOnCompletion() async throws {
        let source = ThreadSafeBox(OperationProgress(completed: 0))
        let active = ThreadSafeBox(true)
        let appliedValues = ThreadSafeArray<OperationProgress>()

        let task = ProgressRelay.run(
            interval: .milliseconds(500), // deliberately long: no natural tick should fire in this test's short window
            while: { active.value },
            read: { source.value },
            apply: { value in appliedValues.append(value) }
        )

        try await Task.sleep(for: .milliseconds(30)) // let the relay start and apply its first (initial) value
        source.value = OperationProgress(completed: 99, total: 100) // changes AFTER the last tick, before completion
        active.value = false // signal "the underlying work has completed"
        await task.value

        #expect(appliedValues.values.last == OperationProgress(completed: 99, total: 100))
    }

    @Test("ProgressRelay.run applies an unchanging value exactly once, no matter how many polling intervals elapse")
    func progressRelayDoesNotReapplyAnUnchangingValue() async throws {
        let applyCalls = ThreadSafeBox(0)
        let active = ThreadSafeBox(true)

        let task = ProgressRelay.run(
            interval: .milliseconds(10),
            while: { active.value },
            read: { OperationProgress(completed: 5, total: 10) }, // never changes
            apply: { _ in applyCalls.value += 1 }
        )

        // Several polling intervals' worth of time, all reading the same
        // unchanging value.
        try await Task.sleep(for: .milliseconds(80))
        active.value = false
        await task.value

        // Exactly one application: the first (nil -> (5, 10)). The unchanged
        // final flush is skipped, and none of the ~8 intervening ticks
        // re-applied it either.
        #expect(applyCalls.value == 1)
    }

    @Test("relayProgress forwards progress to OperationCenter at a throttled rate and flushes the final value")
    func relayProgressIntegratesWithOperationHostAndCenter() async throws {
        let center = OperationCenter()
        let host = OperationHost(center: center)
        let gate = AsyncGate()
        let progress = ThreadSafeBox(OperationProgress(completed: 0, total: 100))

        let id = await host.run(kind: .verify(library: "A"), title: "Verifying A") {
            await gate.waitToProceed()
        }

        let relay = host.relayProgress(id: id, interval: .milliseconds(10)) { progress.value }

        try await waitUntil { host.activeOperations.first { $0.id == id }?.completed == 0 }
        progress.value = OperationProgress(completed: 100, total: 100)

        gate.open()
        try await waitUntil { host.activeOperations.isEmpty }
        _ = await relay.value

        #expect(await center.state(id)?.phase == .succeeded)
    }

    @Test("None of the five files with hand-rolled progress pollers still hot-polls every 20-50ms")
    func noHandRolledHotPollLoopsRemain() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/AstroUI/Features/Library/LibraryHealthStore.swift",
            "Sources/AstroUI/Features/Library/SensorProfilesStore.swift",
            "Sources/AstroUI/Features/Review/ReviewStore.swift",
            "Sources/AstroUI/Onboarding/LibraryWelcomeView.swift",
        ]
        for relativePath in files {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(!source.contains(".milliseconds(20)"), "\(relativePath) still hot-polls at 20ms")
            #expect(!source.contains(".milliseconds(50)"), "\(relativePath) still hot-polls at 50ms")
        }
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

/// `withObservationTracking`'s `onChange` closure is `@Sendable` -- this
/// tiny reference-type counter is what these tests mutate from inside it
/// instead of a plain captured `var` (mirrors `WorkspaceActionsTests`'s
/// `NotificationCounter`, redefined locally here since it is file-private
/// there).
private final class NotificationCounter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// A thread-safe single-value box for `ProgressRelay` tests -- `read`/`apply`
/// closures run inside the relay's own `Task`, concurrently with whatever
/// mutates the source value, so a plain captured `var` isn't safe here.
private final class ThreadSafeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// A thread-safe append-only log of applied values, for asserting on the
/// full sequence `ProgressRelay.run`'s `apply` closure was called with.
private final class ThreadSafeArray<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []
    func append(_ value: Value) { lock.withLock { _values.append(value) } }
    var values: [Value] { lock.withLock { _values } }
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
