import Foundation

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

    public init(
        config: AstroConfig,
        files: [FileRecord],
        directories: [String],
        fitsMetaByFileID: [Int64: FITSMetaRecord]
    ) {
        self.config = config
        self.files = files
        self.directories = directories
        self.fitsMetaByFileID = fitsMetaByFileID
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
        ]
    }

    /// Begins an "audit" run, evaluates every rule against a fresh
    /// `AuditContext`, persists all findings, finishes the run, and returns
    /// them sorted with sure errors first, then suspicious, then
    /// probably-intentional — ties broken by path.
    public func run() throws -> (runID: Int64, findings: [Finding]) {
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

        let configData = try? JSONEncoder().encode(config)
        let configJSON = configData.flatMap { String(data: $0, encoding: .utf8) }

        let runID = try db.beginRun(kind: "audit", root: config.rootPath, configJSON: configJSON)

        let ctx = AuditContext(config: config, files: files, directories: directories, fitsMetaByFileID: fitsMetaByFileID)
        var findings: [Finding] = []
        for rule in rules {
            findings.append(contentsOf: rule.evaluate(ctx))
        }

        for finding in findings {
            try db.insertFinding(runID: runID, finding)
        }
        try db.finishRun(id: runID)

        let sorted = findings.sorted { lhs, rhs in
            let leftRank = Self.severityRank(lhs.severity)
            let rightRank = Self.severityRank(rhs.severity)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.path < rhs.path
        }

        return (runID, sorted)
    }

    private static func severityRank(_ severity: Severity) -> Int {
        switch severity {
        case .sureError: return 0
        case .suspicious: return 1
        case .probablyIntentional: return 2
        }
    }
}
