import Foundation

public actor OperationCenter {
    public typealias CancellationHandler = @Sendable () -> Void

    private struct Entry: Sendable {
        var state: OperationState
        var cancelHandler: CancellationHandler?
    }

    private var entries: [UUID: Entry] = [:]
    private var orderedIDs: [UUID] = []

    public init() {}

    @discardableResult
    public func start(
        kind: OperationKind,
        cancellation: CancellationPolicy,
        cancelHandler: CancellationHandler? = nil
    ) -> OperationState {
        let now = Date()
        let state = OperationState(
            id: UUID(),
            kind: kind,
            cancellationPolicy: cancellation,
            phase: .running,
            completed: 0,
            total: nil,
            errorMessage: nil,
            startedAt: now,
            updatedAt: now,
            finishedAt: nil
        )
        entries[state.id] = Entry(state: state, cancelHandler: cancelHandler)
        orderedIDs.append(state.id)
        return state
    }

    @discardableResult
    public func progress(_ id: UUID, to progress: Int64, total: Int64? = nil) -> Bool {
        guard progress >= 0, total.map({ $0 >= 0 }) ?? true,
              var entry = entries[id], entry.state.phase == .running else {
            return false
        }

        let resolvedTotal = total ?? entry.state.total
        let resolvedProgress = resolvedTotal.map { min(progress, $0) } ?? progress
        guard resolvedProgress >= entry.state.completed else {
            return false
        }
        guard resolvedProgress != entry.state.completed || resolvedTotal != entry.state.total else {
            return false
        }

        entry.state.completed = resolvedProgress
        entry.state.total = resolvedTotal
        entry.state.updatedAt = nextTimestamp(after: entry.state.updatedAt)
        entries[id] = entry
        return true
    }

    @discardableResult
    public func finish(_ id: UUID) -> Bool {
        transition(id, to: .succeeded, errorMessage: nil)
    }

    @discardableResult
    public func fail(_ id: UUID, message: String) -> Bool {
        transition(id, to: .failed, errorMessage: message)
    }

    /// Forces `id`'s phase to `.succeeded` regardless of its current phase
    /// (unlike `finish(_:)`, which only transitions out of `.running`) --
    /// the one honest fix-up for the race where `cancel(_:)` already flipped
    /// an entry to `.cancelled` right before its work finished anyway: the
    /// work DID succeed, so the recorded outcome should say so, not keep the
    /// premature `.cancelled` the race left behind. Returns `false` only
    /// when `id` is not a known entry at all.
    @discardableResult
    public func forceSucceed(_ id: UUID) -> Bool {
        guard var entry = entries[id] else { return false }
        let now = nextTimestamp(after: entry.state.updatedAt)
        entry.state.phase = .succeeded
        entry.state.errorMessage = nil
        entry.state.updatedAt = now
        entry.state.finishedAt = entry.state.finishedAt ?? now
        entry.cancelHandler = nil
        entries[id] = entry
        return true
    }

    @discardableResult
    public func cancel(_ id: UUID) async -> Bool {
        guard var entry = entries[id], entry.state.phase == .running else {
            return false
        }
        guard entry.state.cancellationPolicy != .unavailable else {
            return false
        }

        let handler = entry.state.cancellationPolicy == .cooperative
            ? entry.cancelHandler
            : nil
        entry.cancelHandler = nil
        let now = nextTimestamp(after: entry.state.updatedAt)
        entry.state.phase = .cancelled
        entry.state.updatedAt = now
        entry.state.finishedAt = now
        entries[id] = entry
        if let handler {
            await Task.detached(operation: handler).value
        }
        return true
    }

    public func state(_ id: UUID) -> OperationState? {
        entries[id]?.state
    }

    public func states() -> [OperationState] {
        orderedIDs.compactMap { entries[$0]?.state }
    }

    private func transition(
        _ id: UUID,
        to phase: OperationPhase,
        errorMessage: String?
    ) -> Bool {
        guard var entry = entries[id], entry.state.phase == .running else {
            return false
        }

        let now = nextTimestamp(after: entry.state.updatedAt)
        entry.state.phase = phase
        entry.state.errorMessage = errorMessage
        entry.state.updatedAt = now
        entry.state.finishedAt = now
        entry.cancelHandler = nil
        entries[id] = entry
        return true
    }

    private func nextTimestamp(after timestamp: Date) -> Date {
        max(Date(), timestamp)
    }
}
