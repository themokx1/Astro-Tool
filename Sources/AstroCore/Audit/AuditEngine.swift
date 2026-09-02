import Foundation

/// Settings persisted alongside an audit run. `includeDuplicates` is
/// optional so a legacy plain-config row can explicitly represent an
/// unknown setting rather than inventing `true` or `false`.
public struct AuditRunConfig: Codable, Sendable {
    public let astroConfig: AstroConfig
    public let includeDuplicates: Bool?

    public init(astroConfig: AstroConfig, includeDuplicates: Bool?) {
        self.astroConfig = astroConfig
        self.includeDuplicates = includeDuplicates
    }
}

/// A single classification rule the audit engine evaluates against a
/// snapshot of the scanned library. Implementations are pure functions of
/// `AuditContext` — no filesystem or database access of their own, so they
/// stay trivially testable and safe to run in any order.
public protocol AuditRule: Sendable {
    /// Kebab-case identifier, also used as the finding `category`.
    var id: String { get }
    func evaluate(_ ctx: AuditContext) -> [Finding]
}

/// Everything a rule needs to evaluate the library: the config, the
/// non-missing files recorded by the scanner, every directory on disk
/// (including ones with no files in them, which the scanner never sees),
/// and FITS metadata keyed by file id for files that have it.
public struct AuditContext {
    public let config: AstroConfig
    public let files: [FileRecord]
    public let directories: [String]
    public let fitsMetaByFileID: [Int64: FITSMetaRecord]
    public let captureGroups: [CaptureGroupRecord]
    public let captureSources: [CaptureSourceRecord]
    public let fileCaptureAssignments: [Int64: FileCaptureAssignmentRecord]

    public init(
        config: AstroConfig,
        files: [FileRecord],
        directories: [String],
        fitsMetaByFileID: [Int64: FITSMetaRecord],
        captureGroups: [CaptureGroupRecord] = [],
        captureSources: [CaptureSourceRecord] = [],
        fileCaptureAssignments: [Int64: FileCaptureAssignmentRecord] = [:]
    ) {
        self.config = config
        self.files = files
        self.directories = directories
        self.fitsMetaByFileID = fitsMetaByFileID
        self.captureGroups = captureGroups
        self.captureSources = captureSources
        self.fileCaptureAssignments = fileCaptureAssignments
    }
}

/// Runs the full set of classification rules over a scanned library and
/// persists the resulting findings as one `runs` row. Read-only against the
/// library itself (directory listing only) plus DB reads/writes — never
/// renames, moves, or deletes anything; that's for a human to do later from
/// a suggestion script (Task 11), not this engine.
public final class AuditEngine {
    private let config: AstroConfig
    private let db: Database
    private let rules: [AuditRule]

    public init(config: AstroConfig, db: Database, rules: [AuditRule]? = nil) {
        self.config = config
        self.db = db
        self.rules = rules ?? Self.defaultRules()
    }

    public static func defaultRules() -> [AuditRule] {
        [
            PlaceholderNameRule(),
            OrphanCalibDirRule(),
            DuplicatedCatalogPrefixRule(),
            NestedSessionTreeRule(),
            NoncanonicalSubdirRule(),
            AssetsWithoutDateRule(),
            SimilarTargetNamesRule(),
            MissingCounterpartRule(),
            IntentionalDateRule(),
            InvalidDateDirRule(),
            ResidueRule(),
            CalibInWrongDirRule(),
            EmptyTargetComponentRule(),
            LooseFramesInDateDirRule(),
            ToolOutputRule(),
            CoolerNotReachingSetpointRule(),
            MixedSetupInSessionRule(),
            MixedSetupInTargetRule(),
            CorruptFITSRule(),
            CaptureClassificationRule(),
            UnrecognizedLibraryLayoutRule(),
            StrayAreaFilesRule(),
            UnindexedCompoundExtensionRule(),
        ]
    }

    /// Decodes the current envelope and accepts legacy rows containing a
    /// plain `AstroConfig`, where duplicate participation is unknown.
    public static func decodeRunConfig(_ json: String?) -> AuditRunConfig? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let current = try? decoder.decode(AuditRunConfig.self, from: data) {
            return current
        }
        if let legacy = try? decoder.decode(AstroConfig.self, from: data) {
            return AuditRunConfig(astroConfig: legacy, includeDuplicates: nil)
        }
        return nil
    }

    /// Begins an "audit" run, evaluates every rule against a fresh
    /// `AuditContext`, persists all findings, finishes the run, and returns
    /// them sorted with sure errors first, then suspicious, then
    /// probably-intentional — ties broken by path.
    ///
    /// When `includeDuplicates` is true (the default), hash-based duplicate
    /// detection (`DuplicateFinder`) also runs as part of this same run: its
    /// findings share the run's `runID` and are persisted and sorted right
    /// alongside the protocol rules' findings. `DuplicateFinder` isn't itself
    /// an `AuditRule` (it needs DB write access to cache content hashes,
    /// which the read-only `AuditContext` doesn't provide), so it's invoked
    /// directly here instead of through `rules`.
    ///
    /// `progress`, when given, is called once per rule evaluated AND once
    /// per file `DuplicateFinder` hashes (R12-W3 fix) -- a single unified
    /// tick, since a caller (`AuditRunCommand`) cancelling cooperatively
    /// doesn't need to distinguish which phase it's in, only that it gets a
    /// chance to stop BETWEEN two units of work rather than only before this
    /// call starts or after it returns. The rule loop alone is fast,
    /// in-memory work; the real wall-clock cost of a full audit is
    /// `DuplicateFinder`'s hashing, so forwarding its own per-file ticks
    /// here (rather than only ticking once per rule) is what actually lets
    /// cancellation land inside a long-running audit, not just around it.
    /// `progress` is allowed to `throw` (mirrors `Rater.rate`/
    /// `FixityVerifier.verify`'s own widened contract): a throw propagates
    /// immediately, before any finding is persisted and before `finishRun`
    /// runs, leaving this run's own `runs` row unfinished (`finished_at IS
    /// NULL`) -- already-ignored by every query that only looks at
    /// finished runs. Source-compatible with every existing non-throwing
    /// closure literal call site.
    public func run(
        includeDuplicates: Bool = true,
        progress: (@Sendable () throws -> Void)? = nil
    ) throws -> (runID: Int64, findings: [Finding]) {
        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let directories = try DirectoryLister.listDirectories(root: root, config: config)
        let files = try db.allFiles(includeMissing: false)

        var fitsMetaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in files {
            guard let fileID = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: fileID) {
                fitsMetaByFileID[fileID] = meta
            }
        }

        let runConfig = AuditRunConfig(
            astroConfig: config, includeDuplicates: includeDuplicates
        )
        let configData = try? JSONEncoder().encode(runConfig)
        let configJSON = configData.flatMap { String(data: $0, encoding: .utf8) }

        let runID = try db.beginRun(kind: "audit", root: config.rootPath, configJSON: configJSON)

        let ctx = try AuditContext(
            config: config,
            files: files,
            directories: directories,
            fitsMetaByFileID: fitsMetaByFileID,
            captureGroups: db.allCaptureGroups(),
            captureSources: db.allCaptureSources(),
            fileCaptureAssignments: db.allFileCaptureAssignments()
        )
        var findings: [Finding] = []
        for rule in rules {
            findings.append(contentsOf: rule.evaluate(ctx))
            try progress?()
        }

        findings = Self.suppressRedundantFindings(findings)

        if includeDuplicates {
            findings.append(contentsOf: try DuplicateFinder.findDuplicates(
                db: db, config: config, onPrefixHash: progress, onFullHash: progress
            ))
        }

        for finding in findings {
            try db.insertFinding(runID: runID, finding)
        }
        try db.finishRun(id: runID)

        // B20 retention: the `findings` table otherwise grows unbounded (32k+
        // rows across 12 runs on a real library, never pruned before this) --
        // this is the app's OWN `.astro_tool` database, not the image
        // library the iron rule protects, so deleting old rows here is
        // ordinary housekeeping. One call site (here, not the CLI or the app
        // layer) so both benefit; best-effort, since a pruning failure must
        // never turn an otherwise-successful audit into a reported error.
        try? db.pruneFindings(keepRuns: 3)

        let sorted = findings.sorted { lhs, rhs in
            let leftRank = Self.severityRank(lhs.severity)
            let rightRank = Self.severityRank(rhs.severity)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.path < rhs.path
        }

        return (runID, sorted)
    }

    /// One root cause (a whole session tree accidentally nested a level too
    /// deep, e.g. `sessions/<target>/<date>/flats/sessions/session1/darks/`)
    /// can otherwise flood the result with dozens of near-identical per-file
    /// findings underneath it, on top of the single `nested-session-tree`
    /// finding that already names the actionable unit -- a human fixes this
    /// by moving the whole nested tree, not file by file, and the per-file
    /// `.move` suggestions computed for those files are wrong anyway (they're
    /// derived from a path-implied role that only holds for the canonical
    /// `sessions/<target>/<date>/<role>/` shape, not for an arbitrarily
    /// deeper nested one). So once every rule has run, drop any
    /// `calib-in-wrong-dir` / `misplaced-file` / `loose-frames-in-date-dir`
    /// finding whose path lies at or under a directory this same run also
    /// flagged as `nested-session-tree`.
    private static func suppressRedundantFindings(_ findings: [Finding]) -> [Finding] {
        let nestedTreeDirs = findings
            .filter { $0.category == "nested-session-tree" }
            .map(\.path)
        guard !nestedTreeDirs.isEmpty else { return findings }

        let suppressibleCategories: Set<String> = ["calib-in-wrong-dir", "misplaced-file", "loose-frames-in-date-dir"]

        return findings.filter { finding in
            guard suppressibleCategories.contains(finding.category) else { return true }
            return !nestedTreeDirs.contains { dir in finding.path == dir || finding.path.hasPrefix(dir + "/") }
        }
    }

    private static func severityRank(_ severity: Severity) -> Int {
        switch severity {
        case .sureError: return 0
        case .suspicious: return 1
        case .probablyIntentional: return 2
        }
    }
}
