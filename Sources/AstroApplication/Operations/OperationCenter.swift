import Foundation

public actor OperationCenter {
    public typealias CancellationHandler = @Sendable () -> Void

    private struct Entry: Sendable {
        var state: OperationState
        let cancelHandler: CancellationHandler?
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

    @discardableResult
    public func cancel(_ id: UUID) -> Bool {
        guard var entry = entries[id], entry.state.phase == .running else {
            return false
        }
        guard entry.state.cancellationPolicy != .unavailable else {
            return false
        }

        let handler = entry.state.cancellationPolicy == .cooperative
            ? entry.cancelHandler
            : nil
        let now = nextTimestamp(after: entry.state.updatedAt)
        entry.state.phase = .cancelled
        entry.state.updatedAt = now
        entry.state.finishedAt = now
        entries[id] = entry
        handler?()
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
        entries[id] = entry
        return true
    }

    private func nextTimestamp(after timestamp: Date) -> Date {
        max(Date(), timestamp)
    }
}
