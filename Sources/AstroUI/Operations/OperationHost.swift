import AstroApplication
import Foundation
import Observation

/// The V2 UI's window onto `OperationCenter` -- a MainActor-observable store
/// that turns the actor's plain state snapshots into something a SwiftUI
/// toolbar can bind to directly: a live `activeOperations` projection for
/// `OperationStatusView`, and a `toasts` queue for `ToastOverlay`. Every V2
/// background job (scan, audit, sensor measurement, quarantine apply, ...)
/// is meant to run through `run(kind:title:work:)` rather than spinning up
/// its own ad-hoc `Task`, so this is the one place that decides how running
/// work is shown, how cancellation reaches it, and how its outcome becomes
/// user-visible feedback.
@MainActor
@Observable
public final class OperationHost {
    /// A live projection of one `OperationCenter` entry, plus the UI-facing
    /// `title` the caller supplied (the center itself only knows `OperationKind`,
    /// which is not something to show a user directly).
    public struct ActiveOperation: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let kind: OperationKind
        public let title: String
        public let cancellationPolicy: CancellationPolicy
        public var phase: OperationPhase
        public var completed: Int64
        public var total: Int64?
    }

    public enum ToastLevel: Sendable, Equatable {
        case success
        case failure
        case info
    }

    /// One transient outcome bubble. `expiresAt` is computed once at creation
    /// from the injected `clock` and `toastLifetime`, so expiry is a pure
    /// comparison (`expireToasts(now:)`) rather than something that depends
    /// on a live timer actually having fired.
    public struct Toast: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let level: ToastLevel
        public let message: String
        public let createdAt: Date
        public let expiresAt: Date
    }

    /// One finished operation, kept around briefly so `OperationStatusView`'s
    /// popover can show "what just happened" after the toast that announced
    /// it has already expired.
    public struct OutcomeRecord: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let kind: OperationKind
        public let title: String
        public let phase: OperationPhase
        public let finishedAt: Date
    }

    /// Operations currently known to be running, oldest-start-first.
    public private(set) var activeOperations: [ActiveOperation] = []
    /// Visible toasts, oldest first. Production code prunes these by calling
    /// `expireToasts(now:)` from a view-level timer (see `ToastOverlay`);
    /// tests can call it directly with an arbitrary `now` for determinism.
    public private(set) var toasts: [Toast] = []
    /// The most recent finished operations, newest first, capped at
    /// `recentOutcomesLimit`.
    public private(set) var recentOutcomes: [OutcomeRecord] = []

    private let recentOutcomesLimit = 8
    private let center: OperationCenter
    private let clock: () -> Date
    private let toastLifetime: (ToastLevel) -> TimeInterval
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        center: OperationCenter,
        clock: @escaping () -> Date = Date.init,
        toastLifetime: @escaping (ToastLevel) -> TimeInterval = OperationHost.defaultToastLifetime
    ) {
        self.center = center
        self.clock = clock
        self.toastLifetime = toastLifetime
    }

    public nonisolated static func defaultToastLifetime(_ level: ToastLevel) -> TimeInterval {
        switch level {
        case .failure: 8
        case .success, .info: 4.5
        }
    }

    /// Registers `work` with `OperationCenter` under `kind` and starts running
    /// it on a detached task (so a slow scan or audit never blocks the main
    /// actor), returning as soon as registration lands -- callers get the
    /// operation's id back immediately, without waiting for the work itself
    /// to finish. `work` should observe `Task.isCancelled` / let
    /// `CancellationError` propagate to cooperate with `cancel(id:)`.
    @discardableResult
    public func run(
        kind: OperationKind,
        title: String,
        cancellation: CancellationPolicy = .cooperative,
        work: @escaping @Sendable () async throws -> Void
    ) async -> UUID {
        let cancelBox = CancellableTaskBox()
        let state = await center.start(
            kind: kind,
            cancellation: cancellation,
            cancelHandler: { cancelBox.cancel() }
        )
        let id = state.id

        activeOperations.append(
            ActiveOperation(
                id: id,
                kind: kind,
                title: title,
                cancellationPolicy: cancellation,
                phase: .running,
                completed: 0,
                total: nil
            )
        )

        let task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await work()
                if await self.center.finish(id) {
                    await self.finalize(id: id, kind: kind, title: title, phase: .succeeded)
                    await self.enqueueToast(.success, "\(title) finished.")
                } else {
                    await self.reconcileSuccessRace(id: id, kind: kind, title: title)
                }
            } catch is CancellationError {
                await self.finalize(id: id, kind: kind, title: title, phase: .cancelled)
            } catch {
                if await self.center.fail(id, message: error.localizedDescription) {
                    await self.finalize(id: id, kind: kind, title: title, phase: .failed)
                    await self.enqueueToast(.failure, "\(title) failed: \(error.localizedDescription)")
                } else {
                    await self.reconcileRaceOutcome(id: id, kind: kind, title: title)
                }
            }
        }
        cancelBox.assign(task)
        runningTasks[id] = task
        return id
    }

    /// Requests cooperative cancellation of `id` through `OperationCenter`.
    /// For a `.cooperative` operation this also waits for the run task's own
    /// cleanup to finish, so callers observe the final, settled state (no
    /// longer in `activeOperations`) as soon as `cancel` returns rather than
    /// racing the detached task's unwind. `.discardResult` and `.unavailable`
    /// operations are not awaited here -- their work keeps running (or never
    /// stops), matching `OperationCenter`'s own cancellation semantics.
    @discardableResult
    public func cancel(id: UUID) async -> Bool {
        let policy = activeOperations.first(where: { $0.id == id })?.cancellationPolicy
        let didCancel = await center.cancel(id)
        if didCancel, policy == .cooperative, let task = runningTasks[id] {
            await task.value
        }
        return didCancel
    }

    /// Reports incremental progress for a still-running operation: updates
    /// the matching `activeOperations` entry's `completed`/`total` and
    /// forwards the same numbers to `OperationCenter` so its own state (and
    /// anything else observing it) stays in sync. Returns `false` -- without
    /// touching `activeOperations` -- when `id` is not currently running or
    /// `OperationCenter` rejects the update (e.g. it would move progress
    /// backward), matching `OperationCenter.progress(_:to:total:)`'s own
    /// contract.
    @discardableResult
    public func reportProgress(id: UUID, completed: Int64, total: Int64? = nil) async -> Bool {
        guard activeOperations.contains(where: { $0.id == id }) else { return false }
        guard await center.progress(id, to: completed, total: total) else { return false }
        guard let index = activeOperations.firstIndex(where: { $0.id == id }) else { return false }
        activeOperations[index].completed = completed
        if let total {
            activeOperations[index].total = total
        }
        return true
    }

    /// Posts a toast that has no associated running operation -- for
    /// outcomes that never became an `OperationCenter` entry, such as a
    /// rescan request arriving with no library open. Callers that already
    /// have an operation in flight should let `run(kind:title:work:)`'s own
    /// success/failure toast carry the message instead of calling this.
    public func notify(_ level: ToastLevel, message: String) {
        enqueueToastNow(level, message)
    }

    public func dismissToast(id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    /// Removes every toast whose lifetime has elapsed as of `now`. Driven by
    /// a real timer in production (`ToastOverlay`) and called directly with a
    /// synthetic `now` in tests -- either way this method itself never reads
    /// the wall clock, so its behavior is fully deterministic.
    ///
    /// The `contains(where:)` guard below is load-bearing, not an
    /// optimization: `@Observable`'s generated `_modify` accessor registers a
    /// mutation (and so notifies every observer) on ANY write to `toasts`,
    /// even a `removeAll(where:)` that ends up removing nothing. Without the
    /// guard, `ToastOverlay`'s per-second poll would touch this
    /// root-mounted store's observable state every single tick forever, even
    /// with zero toasts -- exactly the unconditional 1 Hz invalidation that
    /// froze the V2 shell (diagnosed by sampling the live frozen process at
    /// build 20017). Reading `toasts` here (the `contains` check) does not
    /// itself notify -- only the write below does.
    public func expireToasts(now: Date) {
        guard toasts.contains(where: { $0.expiresAt <= now }) else { return }
        toasts.removeAll { $0.expiresAt <= now }
    }

    // MARK: - Private

    private func finalize(id: UUID, kind: OperationKind, title: String, phase: OperationPhase) async {
        runningTasks[id] = nil
        activeOperations.removeAll { $0.id == id }
        recentOutcomes.insert(
            OutcomeRecord(id: id, kind: kind, title: title, phase: phase, finishedAt: clock()),
            at: 0
        )
        if recentOutcomes.count > recentOutcomesLimit {
            recentOutcomes.removeLast(recentOutcomes.count - recentOutcomesLimit)
        }
    }

    /// Reached when `work` threw a plain (non-cancellation) `Error` but the
    /// center no longer reports `.running` for `id` -- almost always because
    /// `cancel(id:)` won between the last cooperative check and this point.
    /// Rather than guess, defer to whatever `OperationCenter` actually
    /// recorded, and only surface an (info-level) toast if the outcome is
    /// something other than the expected cancellation.
    private func reconcileRaceOutcome(id: UUID, kind: OperationKind, title: String) async {
        let recordedPhase = await center.state(id)?.phase ?? .cancelled
        await finalize(id: id, kind: kind, title: title, phase: recordedPhase)
        if recordedPhase != .cancelled {
            await enqueueToast(.info, "\(title) ended unexpectedly.")
        }
    }

    /// Reached when `work` returned successfully (no throw at all) but the
    /// center no longer reports `.running` for `id` -- `cancel(id:)` already
    /// flipped it to `.cancelled` between the work's last cooperative check
    /// and this point, yet the work went on to actually finish anyway (it
    /// either ignored cancellation or won a genuine race against it). The
    /// honest outcome here is success, not the cancellation the center
    /// happened to record first: unlike `reconcileRaceOutcome` above (which
    /// defers to whatever got recorded), this forces the center's own state
    /// to `.succeeded` via `forceSucceed` and tells the user, rather than
    /// silently swallowing a completed operation as a cancellation with no
    /// toast at all.
    private func reconcileSuccessRace(id: UUID, kind: OperationKind, title: String) async {
        let recordedPhase = await center.state(id)?.phase
        guard recordedPhase == .cancelled else {
            // Some other outcome got there first (e.g. a stray `fail(id:)`
            // call from elsewhere) -- defer to it rather than overwrite it.
            await reconcileRaceOutcome(id: id, kind: kind, title: title)
            return
        }
        await center.forceSucceed(id)
        await finalize(id: id, kind: kind, title: title, phase: .succeeded)
        await enqueueToast(.success, "\(title) finished.")
    }

    private func enqueueToast(_ level: ToastLevel, _ message: String) async {
        enqueueToastNow(level, message)
    }

    private func enqueueToastNow(_ level: ToastLevel, _ message: String) {
        let createdAt = clock()
        toasts.append(
            Toast(
                id: UUID(),
                level: level,
                message: message,
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(toastLifetime(level))
            )
        )
    }
}

/// Lets `OperationCenter`'s synchronous `CancellationHandler` reach the
/// `Task.detached` running a given operation's `work`, without needing the
/// task to exist yet at the moment the handler closure is created (the
/// center only hands back an id once `start` returns, and the run task needs
/// that id to report progress/completion) -- `assign` fills it in right
/// after the task is created.
private final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func assign(_ task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }
}
