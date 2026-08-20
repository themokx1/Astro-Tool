import AstroCore
import Foundation

/// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): the in-memory,
/// never-persisted state one live-imaging session accumulates while
/// `AstroUI.LiveNightWatcher` polls a watched folder. Deliberately a pure
/// value type with a pure `recordFrame`/`markIdleTooLong`/... transition
/// API -- no `FileManager`, no FITS decoding, no `@Observable` -- so every
/// case here is a plain, exhaustively testable input/output pair, mirroring
/// `IngestSuggestionEngine`'s own "pure engine below the UI-owned watcher"
/// split (`Sources/AstroApplication/Features/Library/
/// IngestSuggestionEngine.swift`).
///
/// Never persisted across a relaunch: per the spec's own "Adat/séma" note
/// and the owner's own answer to the spec's Open Question 6, a
/// crashed/closed app simply forgets an in-progress session -- the frames
/// already on disk are picked up the ordinary way by the next
/// `LibraryScanner.scan`, which remains the sole source of truth once the
/// night actually ends. Nothing here ever claims otherwise.
///
/// The UI showing `medianQuickProxyRadiusPixels` MUST label it a proxy
/// (e.g. "FWHM (proxy)"), never the real, Siril-computed measurement --
/// see `QuickStarProxy`'s own doc comment for why the two must never be
/// confused.
public struct LiveNightSessionModel: Equatable, Sendable {
    public enum FrameKind: Equatable, Sendable {
        case fits
        case cr3
    }

    /// Health of the watch itself, independent of the frame/goal numbers --
    /// `LiveNightWatcher` drives these transitions from wall-clock/poll
    /// outcomes; this type only stores the result.
    public enum ConnectionState: Equatable, Sendable {
        case watching
        /// No new frame for longer than the session's own cadence expects
        /// -- the spec's own "vége az éjszakának?" state, never a silent
        /// disappearance.
        case idleTooLong
        /// The watched folder itself became unreachable (share unmounted,
        /// folder deleted) -- distinct from `.idleTooLong` (the folder is
        /// still there, just quiet).
        case disconnected
    }

    /// One newly-seen frame the watcher wants folded into the running
    /// state.
    public struct FrameObservation: Equatable, Sendable {
        public let kind: FrameKind
        /// `nil` when this specific frame's exposure length could not be
        /// read (FITS with no `EXPTIME`, CR3 with no Exif `ExposureTime`)
        /// -- the frame still counts toward `fitsFrameCount`/`cr3FrameCount`,
        /// it simply never enters the goal-integration arithmetic, rather
        /// than being guessed at with an invented duration.
        public let exposureSeconds: Double?
        public let capturedAt: Date
        /// Always ignored for a `.cr3` frame regardless of what a caller
        /// passes -- see this type's own "CR3-korlát" note and
        /// `QuickStarProxy`'s structural FITS-only constraint.
        public let quickProxyRadiusPixels: Double?

        public init(kind: FrameKind, exposureSeconds: Double?, capturedAt: Date, quickProxyRadiusPixels: Double? = nil) {
            self.kind = kind
            self.exposureSeconds = exposureSeconds
            self.capturedAt = capturedAt
            self.quickProxyRadiusPixels = quickProxyRadiusPixels
        }
    }

    public private(set) var fitsFrameCount: Int = 0
    public private(set) var cr3FrameCount: Int = 0
    public private(set) var quickProxyRadii: [Double] = []
    public private(set) var exposureSeconds: [Double] = []
    public private(set) var timestamps: [Date] = []
    public private(set) var connectionState: ConnectionState = .watching
    public private(set) var lastFrameAt: Date?

    public init() {}

    public var totalFrameCount: Int { fitsFrameCount + cr3FrameCount }

    /// Median of every FITS frame's `quickProxyRadiusPixels` observed so
    /// far -- `nil` while there isn't one yet (no FITS frames measured
    /// yet, or every attempt failed), the Home card's own signal to render
    /// "n/a", never a number.
    public var medianQuickProxyRadiusPixels: Double? {
        guard !quickProxyRadii.isEmpty else { return nil }
        let sorted = quickProxyRadii.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// Delegates straight to `LiveNightGoalEstimator.estimate` with this
    /// session's own accumulated `exposureSeconds`/`timestamps` -- `nil`
    /// `goalSeconds` (no matched project, or the matched project has no
    /// goal set) short-circuits to `nil` here without even reaching that
    /// function, the same "nothing real, nothing shown" contract every
    /// other V2 Home card follows.
    public func goalEstimate(goalSeconds: Double?, now: Date) -> LiveNightGoalEstimator.Estimate? {
        guard let goalSeconds else { return nil }
        return LiveNightGoalEstimator.estimate(
            exposureSeconds: exposureSeconds, timestamps: timestamps, goalSeconds: goalSeconds, now: now
        )
    }

    public mutating func recordFrame(_ observation: FrameObservation) {
        switch observation.kind {
        case .fits: fitsFrameCount += 1
        case .cr3: cr3FrameCount += 1
        }
        if let exposure = observation.exposureSeconds {
            exposureSeconds.append(exposure)
            timestamps.append(observation.capturedAt)
        }
        if observation.kind == .fits, let radius = observation.quickProxyRadiusPixels {
            quickProxyRadii.append(radius)
        }
        lastFrameAt = observation.capturedAt
        connectionState = .watching
    }

    public mutating func markIdleTooLong() {
        guard connectionState == .watching else { return }
        connectionState = .idleTooLong
    }

    public mutating func markDisconnected() {
        connectionState = .disconnected
    }

    public mutating func markReconnected() {
        guard connectionState != .watching else { return }
        connectionState = .watching
    }
}
