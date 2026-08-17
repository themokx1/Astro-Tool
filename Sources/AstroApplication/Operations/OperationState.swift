import Foundation

public enum OperationKind: Hashable, Sendable {
    case scan(library: String)
    case loadHome(library: String)
    case rate(series: String)
    case audit(library: String)
    case verify(library: String)
    case export(project: String)
    case convert(session: String)
    /// W3-10: the "New Session" sheet's own create/undo -- mkdir-only
    /// scaffolding (`sessions/flats/darks/biases/README`, `stacks/`,
    /// `processed/`), never a move, so it gets its own kind rather than
    /// reusing `.convert` (which names an existing session being
    /// reorganized, not a brand-new one being made).
    case createSession(target: String)
    case sensorMeasurement(library: String)
    /// The opt-in "Update Catalog" action (Settings ▸ Planning): downloads
    /// the extended SIMBAD/VizieR target catalog into `CatalogCache`. Not
    /// per-library (the extended catalog is the same regardless of which
    /// library is open), so unlike every other case here it carries no
    /// associated value.
    case catalogFetch
}

public enum CancellationPolicy: Hashable, Sendable {
    case cooperative
    case discardResult
    case unavailable
}

public enum OperationPhase: Hashable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

public struct OperationState: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: OperationKind
    public let cancellationPolicy: CancellationPolicy
    public internal(set) var phase: OperationPhase
    public internal(set) var completed: Int64
    public internal(set) var total: Int64?
    public internal(set) var errorMessage: String?
    public let startedAt: Date
    public internal(set) var updatedAt: Date
    public internal(set) var finishedAt: Date?

    public init(
        id: UUID,
        kind: OperationKind,
        cancellationPolicy: CancellationPolicy,
        phase: OperationPhase,
        completed: Int64,
        total: Int64?,
        errorMessage: String?,
        startedAt: Date,
        updatedAt: Date,
        finishedAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.cancellationPolicy = cancellationPolicy
        self.phase = phase
        self.completed = completed
        self.total = total
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
    }

    public var progress: Int64 {
        completed
    }
}
