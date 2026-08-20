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
    /// W4-1: the card-import wizard's own copy step -- copies files from an
    /// external source (an SD card, an ASI Air's storage) into an
    /// already-created capture tree. Its own kind, distinct from
    /// `.createSession` (that one only ever mkdir's/writes a README; this
    /// one copies potentially gigabytes of frame data and is cancellable
    /// mid-copy) and from `.convert` (that one MOVES files already inside
    /// the library; this one only ever ADDS new ones from outside it, and
    /// never touches the source).
    case importCapture(target: String)
    /// W3-12: `ArchiveStore.acknowledge`'s finding-group write -- gives a
    /// failed acknowledge the same toast receipt every other V2 write gets,
    /// instead of the empty `catch` `ArchiveView.acknowledge` used to have
    /// (a failed write left the card on screen with no visible reason why).
    /// Keyed per-library so a second acknowledge on the same library cannot
    /// race the first, matching `.audit`/`.verify`'s own shape.
    case acknowledge(library: String)
    /// The opt-in "Update Catalog" action (Settings ▸ Planning): downloads
    /// the extended SIMBAD/VizieR target catalog into `CatalogCache`. Not
    /// per-library (the extended catalog is the same regardless of which
    /// library is open), so unlike every other case here it carries no
    /// associated value.
    case catalogFetch
    /// Wave 0 seam (V3 pre-stack program, `docs/superpowers/specs/
    /// 2026-08-20-v3-prestack-program.md` section 5.2, Kalibrációs automata):
    /// the forthcoming Siril-backed master-frame build for one dark/flat/bias
    /// gap combo (`combo` names it the same way `CalibAnalyzer.CalibCombo`'s
    /// own description does) -- registers under `OperationHost` the same way
    /// `.rate`/`.sensorMeasurement` do for their own Siril-backed
    /// long-running work. Nothing constructs this case yet; this stub only
    /// opens the seam so 5.2's own commit never has to touch this closed
    /// enum's other cases again.
    case buildMaster(combo: String)
    /// Wave 0 seam (V3 pre-stack program, section 5.6, Élő éjszaka-mód): the
    /// in-process file-system watch for an active live-imaging session.
    /// Carries no associated value, unlike every per-library/per-series case
    /// above -- exactly one live watch can run app-wide at a time, so there
    /// is nothing to key it by. Nothing constructs this case yet; see
    /// `.buildMaster`'s own doc comment for why this is a stub.
    case liveNightWatch
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
