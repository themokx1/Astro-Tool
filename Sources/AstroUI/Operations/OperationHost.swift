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
        // Task 5c (2026-08-17) resolution of the Task 5b UNDECIDED entry:
        // `ActiveOperation` has to stay `Sendable` (it crosses from the
        // `Task.detached` in `run(kind:title:work:)` onto this MainActor
        // type), and `LocalizedStringKey` is explicitly NOT `Sendable`
        // (`extension LocalizedStringKey: Sendable` is marked
        // `@available(*, unavailable)` in SwiftUI) -- so this can't just
        // change type the way `MetricCard`'s properties did. Same fix as
        // `ProjectWorkspaceRow.nextAction`: every `run(kind:title:...)` call
        // site now resolves its literal English fragment eagerly via
        // `OperationHost.localized(_:)` (a thin `NSLocalizedString` wrapper)
        // before interpolating any dynamic data (a filename, a target
        // label) around it, so the runtime data never enters the
        // translation key. See `OperationHost.localized(_:)`'s own doc
        // comment and `V2PolishSurfaceTests.uiPropertyAllowlist`'s entry for
        // this file.
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
        // Task 5c (2026-08-17) resolution of the Task 5b UNDECIDED entry:
        // same `Sendable`-vs-`LocalizedStringKey` conflict as
        // `ActiveOperation.title` above, but for every `notify(_:message:)`
        // call site plus this file's own success/failure/cancellation
        // toasts. Several interpolate `error.localizedDescription` -- a
        // runtime string that must never become part of a translation key
        // -- so each call site now resolves only its own literal English
        // fragment via `OperationHost.localized(_:)` and interpolates the
        // error text (or a filename, or an already-resolved `title`)
        // around that, never through it. One call site
        // (`NightNoteSheet.save()`) stays partly opaque -- see
        // `V2PolishSurfaceTests.uiPropertyAllowlist`'s entry for this file
        // for why.
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
        // Task 5c (2026-08-17): same resolution as `ActiveOperation.title`
        // above -- this is the same caller-supplied, already-resolved
        // operation name, kept around after the operation finishes.
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

    /// Eagerly resolves an English literal fragment against `hu.lproj`, the
    /// same pattern `ProjectNextActionKind.localizedTitle`/
    /// `.localizedExplanation` use for `ProjectWorkspaceRow`. `ActiveOperation`,
    /// `Toast`, and `OutcomeRecord` are all `Sendable` -- required, since
    /// `run(kind:title:work:)` carries `title` across the `Task.detached`
    /// boundary it runs `work` on -- and `LocalizedStringKey` itself is
    /// explicitly not `Sendable` (`extension LocalizedStringKey: Sendable`
    /// is `@available(*, unavailable)` in SwiftUI), so none of those three
    /// types can hold one the way `MetricCard`'s properties do.
    ///
    /// Callers pass only the literal English words they would otherwise
    /// have wrapped in `Text("...")` -- never a fully-assembled sentence --
    /// and interpolate any dynamic data (a filename, a target label, an
    /// `error.localizedDescription`) around the resolved result, not
    /// through it. That keeps the runtime data out of the translation key
    /// entirely: the `hu.lproj` entry this looks up is always a fixed,
    /// finite English phrase, never a string built at runtime.
    nonisolated static func localized(_ text: String) -> String {
        NSLocalizedString(text, bundle: .main, comment: "")
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
                    await self.enqueueToast(.success, "\(title) \(Self.localized("finished."))")
                } else {
                    await self.reconcileSuccessRace(id: id, kind: kind, title: title)
                }
            } catch is CancellationError {
                await self.finalize(id: id, kind: kind, title: title, phase: .cancelled)
            } catch {
                if await self.center.fail(id, message: error.localizedDescription) {
                    await self.finalize(id: id, kind: kind, title: title, phase: .failed)
                    await self.enqueueToast(.failure, "\(title) \(Self.localized("failed:")) \(error.localizedDescription)")
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

    /// Awaits the outcome of an operation started via `run`, unlike `run`
    /// itself (which returns as soon as registration lands, never waiting for
    /// `work` to finish). Introduced for the launch-time "prepare this
    /// library" pipeline (`V2RootView.prepareLibrary`): unlike a rescan/audit/
    /// sensor-measurement (fire-and-forget, only a toast on completion), that
    /// pipeline still needs to react inline to success/failure (recording the
    /// library as open, or surfacing a retryable error) while ALSO being
    /// visible/cancellable through the toolbar exactly like every other
    /// operation. Safe to call after `id` has already finished: `runningTasks`
    /// no longer holds it, so this returns immediately from `recentOutcomes`.
    /// `.failed` is the fallback for an `id` this host never registered at all
    /// (a caller bug), matching `reconcileRaceOutcome`'s own "defer to
    /// whatever actually got recorded, else assume the worst" stance.
    public func outcome(of id: UUID) async -> OperationPhase {
        if let task = runningTasks[id] {
            await task.value
        }
        return recentOutcomes.first(where: { $0.id == id })?.phase ?? .failed
    }

    /// The human-readable failure message `OperationCenter` recorded for
    /// `id`, if any -- `ActiveOperation`/`OutcomeRecord` deliberately don't
    /// carry this (a toast already renders it once, and most callers need
    /// nothing more), but `outcome(of:)`'s callers that show their own
    /// dedicated failure UI (an alert with Retry, not just a toast) need the
    /// actual text, not just the phase.
    public func errorMessage(for id: UUID) async -> String? {
        await center.state(id)?.errorMessage
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
            await enqueueToast(.info, "\(title) \(Self.localized("ended unexpectedly."))")
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
        await enqueueToast(.success, "\(title) \(Self.localized("finished."))")
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

/// One `(completed, total)` progress reading -- the value type
/// `OperationHost.relayProgress` polls and forwards to
/// `reportProgress(id:completed:total:)`. `total == nil` means "not yet
/// known" and, per `reportProgress`'s own contract, leaves whatever total is
/// already recorded untouched rather than clobbering it with a bogus zero.
public struct OperationProgress: Equatable, Sendable {
    public var completed: Int64
    public var total: Int64?

    public init(completed: Int64, total: Int64? = nil) {
        self.completed = completed
        self.total = total
    }
}

/// A throttled relay between a progress source that may update far faster
/// than any human perceives (or than a `@Observable` store should be mutated
/// at) and whatever is consuming it. Introduced to replace five near-
/// identical hand-rolled poll loops -- `LibraryHealthStore.verifyIntegrity`,
/// `SensorProfilesStore.measure`, `ReviewStore.rateSelectedSeries`,
/// `OnboardingStore.rescan`, and `OnboardingStore.openAndScan` -- each of
/// which polled its own progress box every 20-50ms and pushed straight into
/// `@Observable` state (`OperationHost.activeOperations` or
/// `OnboardingStore.phase`), so every observer (shell toolbar,
/// `OperationStatusView`, `HealthView`, `ReviewWorkspace`, four onboarding
/// views) re-rendered at 20-50 Hz for the entire duration of any long-running
/// operation -- exactly while the UI most needed to stay responsive.
///
/// `ProgressRelay.run` polls `read()` every `interval` while `isActive()`
/// holds, calling `apply(_:)` only when the read value actually differs from
/// the last one applied -- mirrors `OperationHost.expireToasts`'s own same-
/// value guard: `@Observable` registers a mutation (and so notifies every
/// observer) on any write, even one that changes nothing, so applying an
/// unchanged value on every tick would still invalidate every observer at
/// the throttle rate for no reason. Once `isActive()` goes false, it
/// performs exactly one more `read()`/`apply()` if that final value hasn't
/// already been applied -- so a value that changed between the last tick and
/// the underlying work finishing is never simply dropped on the floor.
@MainActor
public enum ProgressRelay {
    /// Fast enough to read as smooth progress, slow enough that the
    /// `@Observable` mutation it drives fires at most 5x/second instead of
    /// the 20-50 Hz the five hand-rolled loops it replaces used to run at.
    public static let defaultInterval: Duration = .milliseconds(200)

    @discardableResult
    public static func run<Value: Equatable & Sendable>(
        interval: Duration = defaultInterval,
        while isActive: @escaping @MainActor @Sendable () -> Bool,
        read: @escaping @Sendable () -> Value,
        apply: @escaping @MainActor @Sendable (Value) async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            var lastApplied: Value?
            while isActive() {
                let value = read()
                if value != lastApplied {
                    await apply(value)
                    lastApplied = value
                }
                try? await Task.sleep(for: interval)
            }
            let final = read()
            if final != lastApplied {
                await apply(final)
            }
        }
    }
}

extension OperationHost {
    /// Convenience over `ProgressRelay.run` for the common case every V2
    /// background job needs: relaying a synchronous progress source into
    /// `reportProgress(id:completed:total:)` while `id` remains in
    /// `activeOperations`, at a throttled cadence instead of a hand-rolled
    /// hot poll loop.
    @discardableResult
    public func relayProgress(
        id: UUID,
        interval: Duration = ProgressRelay.defaultInterval,
        read: @escaping @Sendable () -> OperationProgress
    ) -> Task<Void, Never> {
        ProgressRelay.run(
            interval: interval,
            while: { [weak self] in
                self?.activeOperations.contains(where: { $0.id == id }) ?? false
            },
            read: read,
            apply: { [weak self] progress in
                _ = await self?.reportProgress(id: id, completed: progress.completed, total: progress.total)
            }
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
