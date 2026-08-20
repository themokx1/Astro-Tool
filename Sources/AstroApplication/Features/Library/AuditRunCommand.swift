import AstroCore
import Foundation

/// The two ways V1's "Audit futtatása" menu can run a full library audit
/// (`AppState.runAudit`, `Commands.swift`'s "Audit futtatása" vs.
/// "Duplikátum-keresés nélkül auditálás") -- V2 exposes the same two,
/// nothing more. `.full` runs every classification rule plus
/// `DuplicateFinder`'s hash-based duplicate scan (the slow part on a large
/// library); `.fast` skips only the duplicate scan, every protocol-based
/// rule still runs.
public enum AuditRunMode: String, Sendable, Equatable, CaseIterable {
    case full
    case fast
}

/// One completed `AuditRunCommand.runAudit` call: the underlying engine's own
/// run id and sorted findings, plus the `MetadataStore` row it was just
/// recorded as (so a caller never has to re-derive `groupKeys` itself to show
/// "what this run just wrote").
public struct AuditRunOutcome: Equatable, Sendable {
    public let runID: Int64
    public let findings: [Finding]
    public let groupKeys: [String]
    public let auditRun: AuditRunRecord

    public init(runID: Int64, findings: [Finding], groupKeys: [String], auditRun: AuditRunRecord) {
        self.runID = runID
        self.findings = findings
        self.groupKeys = groupKeys
        self.auditRun = auditRun
    }
}

/// V1's "Integritás-ellenőrzés" confirmation sheet folded into a single
/// request (`VerifyConfirmationSheet.swift`'s "Csak minta (10%)" toggle and
/// "Hiányzó összegek pótlása" button, which V1 exposes as two independent
/// actions on the same sheet): V2's sheet instead offers both as toggles on
/// one "Verify Integrity…" action, so `fillMissingChecksums` -- when set --
/// always runs BEFORE the verify pass, in the same call, giving every
/// previously-unhashed file a baseline hash before it's judged eligible to be
/// (sampled and) re-checked.
public struct VerifyRunOptions: Sendable, Equatable {
    /// `nil` verifies every eligible (already-hashed) file. `0.0...1.0`
    /// verifies a random subset sized `max(1, round(eligibleCount * fraction))`
    /// -- matches `FixityVerifier.eligibleFiles`'s own rounding, just
    /// expressed as a fraction instead of a whole percent (V1's sheet only
    /// ever offers 10%, i.e. `0.1`).
    public let sampleFraction: Double?
    public let fillMissingChecksums: Bool

    public init(sampleFraction: Double? = nil, fillMissingChecksums: Bool = false) {
        self.sampleFraction = sampleFraction
        self.fillMissingChecksums = fillMissingChecksums
    }
}

/// One completed `AuditRunCommand.runVerify` call: the verify pass's own
/// summary counts, plus -- when `fillMissingChecksums` was requested -- how
/// many files the baseline step hashed for the first time and which (if any)
/// couldn't be read.
public struct VerifyRunOutcome: Equatable, Sendable {
    public let runID: Int64
    public let summary: FixityVerifier.Summary
    public let baselineHashed: Int
    public let baselineErrors: [FixityVerifier.BaselineResult]

    public init(
        runID: Int64, summary: FixityVerifier.Summary,
        baselineHashed: Int, baselineErrors: [FixityVerifier.BaselineResult]
    ) {
        self.runID = runID
        self.summary = summary
        self.baselineHashed = baselineHashed
        self.baselineErrors = baselineErrors
    }
}

/// Wraps `AuditEngine.run`/`FixityVerifier` for V2's Library Health "Run
/// Audit"/"Verify Integrity…" flows -- the same read-tracked-files-write-
/// only-to-the-index-database contract V1's own Audit page already runs
/// under (`AppState.runAudit`/`runVerify`/`runVerifyBaseline`). Unlike
/// `CalibrationLinkCommand`/`QuarantineApplyCommand`, this never gates on
/// `LibraryAccessMode`: everything it writes -- cached content hashes, the
/// `findings`/`runs` tables, `audit_run_history` -- lives in this library's
/// OWN external index/metadata databases, never inside the image library
/// itself (the same reasoning `SensorMeasurementCommand`'s own doc comment
/// gives for skipping that gate).
///
/// `AuditEngine.run` and `FixityVerifier.baseline`/`.run` each expose a
/// per-item, cooperatively-cancellable `progress` hook (R12-W3 fix) the same
/// shape `SensorProfiler.measure`/`Rater.rate` already do: `AuditEngine.run`
/// ticks once per rule AND once per file `DuplicateFinder` hashes;
/// `FixityVerifier.baseline`/`.run` tick once per file. Both hooks are
/// `throws`, so -- mirroring `FrameRatingCommand.run`'s own wrapping
/// closure -- `runAudit`/`runVerify` below turn a cooperative
/// `isCancelled` check inside that per-item tick into a
/// `throw CancellationError()`, letting a cancel request land BETWEEN two
/// rules/files instead of only at this command's own outer phase boundaries
/// (immediately before starting, and -- for verify -- between the baseline
/// step and the verify pass).
public struct AuditRunCommand: Sendable {
    private let db: Database
    private let config: AstroConfig
    private let metadata: MetadataStore

    public init(db: Database, config: AstroConfig, metadata: MetadataStore) {
        self.db = db
        self.config = config
        self.metadata = metadata
    }

    /// `metadata`, when given, lets a caller that already holds an open
    /// `MetadataStore` for this library (e.g. `LibraryHealthStore`) reuse it
    /// rather than opening a second instance against the same database --
    /// the same optional-reuse shape `QuarantineApplyCommand.production`
    /// already uses.
    public static func production(rootURL: URL, metadata: MetadataStore? = nil) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        let resolvedMetadata = try metadata ?? MetadataStore(storagePaths: storage)
        return Self(db: database, config: config, metadata: resolvedMetadata)
    }

    /// Runs `AuditEngine.run(includeDuplicates:)` (`.full` includes
    /// `DuplicateFinder`'s hash scan, `.fast` skips it), then records the
    /// run's headline facts into `MetadataStore.recordAuditRun` so
    /// `auditRunHistory`/`auditRunDiff` have something to show and diff.
    /// Group keys are `FindingGrouper`'s own "one row per repeated cause"
    /// aggregation, re-expressed through `MetadataStore.ackKey`'s
    /// `"category|groupKey"` format -- the same keyspace notion the
    /// acknowledgement system already uses, so a later ack integration for
    /// these findings would land in the identical keyspace rather than a
    /// parallel one.
    @discardableResult
    public func runAudit(
        mode: AuditRunMode,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async throws -> AuditRunOutcome {
        if let isCancelled, isCancelled() { throw CancellationError() }

        let engine = AuditEngine(config: config, db: db)
        let (runID, findings) = try engine.run(includeDuplicates: mode == .full) {
            if let isCancelled, isCancelled() { throw CancellationError() }
        }

        if let isCancelled, isCancelled() { throw CancellationError() }

        let groupKeys = Self.groupKeys(for: findings, config: config)
        let record = try await metadata.recordAuditRun(findingCount: findings.count, groupKeys: groupKeys)
        return AuditRunOutcome(runID: runID, findings: findings, groupKeys: groupKeys, auditRun: record)
    }

    /// Runs `options.fillMissingChecksums`'s baseline step (if requested),
    /// then `FixityVerifier.run` over `options.sampleFraction` of whatever is
    /// now eligible. `progress` receives `(done, total)` from whichever
    /// phase is currently running -- baseline first (if any), then verify --
    /// mirroring `FixityVerifier`'s own per-file callback contract.
    @discardableResult
    public func runVerify(
        options: VerifyRunOptions,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> VerifyRunOutcome {
        if let isCancelled, isCancelled() { throw CancellationError() }

        // Wraps the caller's own (non-throwing) `progress` with a
        // per-file `isCancelled` check, then forwards it to both
        // `FixityVerifier.baseline` and `.run` below -- mirrors
        // `FrameRatingCommand.run`'s own wrapping closure over `Rater.rate`'s
        // `progress`, so a cancel request lands between two files instead of
        // only at this method's own outer phase boundaries.
        let cooperativeProgress: @Sendable (Int, Int) throws -> Void = { done, total in
            if let isCancelled, isCancelled() { throw CancellationError() }
            progress?(done, total)
        }

        var baselineHashed = 0
        var baselineErrors: [FixityVerifier.BaselineResult] = []
        if options.fillMissingChecksums {
            let baseline = try FixityVerifier.baseline(db: db, config: config, progress: cooperativeProgress)
            baselineHashed = baseline.hashed
            baselineErrors = baseline.errors
        }

        if let isCancelled, isCancelled() { throw CancellationError() }

        let samplePercent = options.sampleFraction.map { fraction in
            max(1, min(100, Int((fraction * 100).rounded())))
        }
        let (runID, results, _) = try FixityVerifier.run(
            db: db, config: config, samplePercent: samplePercent, progress: cooperativeProgress
        )
        return VerifyRunOutcome(
            runID: runID, summary: FixityVerifier.summarize(results),
            baselineHashed: baselineHashed, baselineErrors: baselineErrors
        )
    }

    private static func groupKeys(for findings: [Finding], config: AstroConfig) -> [String] {
        FindingGrouper.group(findings, config: config).map {
            MetadataStore.ackKey(category: $0.key.category, groupKey: $0.key.groupKey)
        }
    }
}
