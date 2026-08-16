import AstroCore
import Foundation

public enum ArchiveTaskKind: String, CaseIterable, Sendable {
    case intermediateFiles
    case duplicateContent
    case misplacedCalibration
    case brokenNames
    /// Silent corruption: the bytes changed while size and timestamp did
    /// not. The only finding here that means data may already be lost, and
    /// the only one for which "restore from a backup copy" is true advice.
    case corruption
    /// The verify pass could not confirm these files -- it read an error, or
    /// found an in-place rewrite. Not proof of loss, so it must not borrow
    /// corruption's language.
    case unverified
    /// Not a problem -- the honest "I have not looked yet" state, which
    /// still deserves a card because it has a real button.
    case auditNeverRun

    /// The raw `findings.category` values that roll up into this card.
    var findingCategories: [String] {
        switch self {
        case .intermediateFiles: ["residue"]
        case .duplicateContent: ["duplicate-content"]
        case .misplacedCalibration: ["calib-in-wrong-dir", "orphan-calib-dir"]
        case .brokenNames: ["placeholder-name", "duplicated-catalog-prefix",
                            "nested-session-tree", "noncanonical-subdir"]
        case .corruption: ["content-changed"]
        case .unverified: ["modified-in-place", "verify-read-error"]
        case .auditNeverRun: []
        }
    }
}

public enum ArchiveTaskSeverity: String, Sendable {
    case error
    case reclaim
    case attention
    case info

    var rank: Int {
        switch self {
        case .error: 0
        case .reclaim: 1
        case .attention: 2
        case .info: 3
        }
    }
}

public enum ArchiveTaskAction: Equatable, Sendable {
    /// Pushes the existing quarantine preview, pre-selected to these
    /// `CleanupPreviewGroup.category` values -- both the "Stacking
    /// leftovers" and "Byte-identical copies" cards resolve to this same
    /// action, each with its own correct categories, instead of the
    /// duplicate card promising a distinct comparison surface (`case
    /// compareDuplicates`, removed) this wave never built. See Task 10's
    /// own prerequisite note in the plan for why.
    case previewQuarantine(categories: [String])
    case revealInFinder(path: String)
    case runAudit
    /// Only ever produced internally, and filtered out before `tasks()`
    /// returns -- a card with no action must not reach the UI. Deliberately
    /// NOT named `none`: `ArchiveTaskAction.none` collides with
    /// `Optional.none` at every `??` and comparison site.
    case unavailable
}

public struct ArchiveTask: Equatable, Sendable, Identifiable {
    public var id: String { kind.rawValue }
    public let kind: ArchiveTaskKind
    public let severity: ArchiveTaskSeverity
    public let affectedFileCount: Int
    public let bytes: Int64
    /// Up to three real paths from the underlying findings, so the card can
    /// show what it is talking about instead of only a count.
    public let evidencePaths: [String]
    public let action: ArchiveTaskAction

    /// The acknowledgement key this card is silenced by -- one key per
    /// KIND, so acknowledging survives a re-audit that renumbers every
    /// individual finding.
    public static let ackCategory = "archive-task"
    public var ackGroupKey: String { kind.rawValue }

    public init(
        kind: ArchiveTaskKind, severity: ArchiveTaskSeverity,
        affectedFileCount: Int, bytes: Int64,
        evidencePaths: [String], action: ArchiveTaskAction
    ) {
        self.kind = kind
        self.severity = severity
        self.affectedFileCount = affectedFileCount
        self.bytes = bytes
        self.evidencePaths = evidencePaths
        self.action = action
    }
}

/// What `ArchiveTaskQuery` intentionally does not turn into a card: findings
/// whose `category` maps to no `ArchiveTaskKind` at all. Replayed against the
/// real library this is 138 findings, 8.69 GB, across twelve categories
/// (`capture-unassigned-artifact`, `capture-legacy-folder`, `tool-output`,
/// `missing-counterpart`, and eight more). Dropping them is the right call --
/// they have no executable action -- but dropping them SILENTLY is not: four
/// cards and nothing else reads as complete coverage. The footer renders this
/// as a single quiet line so the page never implies it saw more than it did.
///
/// Deliberately distinct from a card that exists but is suppressed
/// (acknowledged, or dropped by the actionability gate in `action(for:entry:)`):
/// those findings' categories DID map to a kind, so they are not "uncovered" --
/// conflating the two would make an acknowledged finding look like a coverage
/// gap.
public struct UncoveredFindings: Equatable, Sendable {
    public let count: Int
    public let bytes: Int64
    /// Category name -> how many findings, for the footer's tooltip.
    public let categories: [String: Int]

    public static let none = UncoveredFindings(count: 0, bytes: 0, categories: [:])
    public var isEmpty: Bool { count == 0 }

    public init(count: Int, bytes: Int64, categories: [String: Int]) {
        self.count = count
        self.bytes = bytes
        self.categories = categories
    }
}

/// `ArchiveTaskQuery.summary()`'s full result: the cards the page can act on,
/// plus what it could not cover. Kept as one struct rather than two return
/// values so a caller can never read one half without the other.
public struct ArchiveTaskSummary: Equatable, Sendable {
    public let tasks: [ArchiveTask]
    public let uncovered: UncoveredFindings

    public init(tasks: [ArchiveTask], uncovered: UncoveredFindings) {
        self.tasks = tasks
        self.uncovered = uncovered
    }
}

/// Turns the latest audit run's and the latest verify run's findings into at
/// most six cards -- one per `ArchiveTaskKind` -- instead of one row per
/// finding. The 3 228 residue findings on the reference library are one
/// card, not 3 228 rows.
///
/// Hard rule, gated by `ArchiveTaskQueryTests.everyCardIsActionable`: a card
/// only exists if its `action` can actually run. Titles and explanatory
/// sentences are NOT built here -- they are localized UI strings keyed off
/// `kind`, so this type stays free of presentation text.
public struct ArchiveTaskQuery: Sendable {
    public static let evidenceLimit = 3

    private let indexDatabase: URL
    private let metadata: MetadataStore?

    init(indexDatabaseForTesting: URL, metadata: MetadataStore? = nil) {
        self.indexDatabase = indexDatabaseForTesting
        self.metadata = metadata
    }

    public static func production(rootURL: URL, metadata: MetadataStore? = nil) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let resolvedMetadata = try metadata ?? MetadataStore(storagePaths: storage)
        return Self(indexDatabaseForTesting: storage.indexDatabase, metadata: resolvedMetadata)
    }

    public func summary() async throws -> ArchiveTaskSummary {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)

        guard try Self.hasAuditRun(db: db) else {
            return ArchiveTaskSummary(
                tasks: [ArchiveTask(
                    kind: .auditNeverRun, severity: .info,
                    affectedFileCount: 0, bytes: 0, evidencePaths: [], action: .runAudit
                )],
                uncovered: .none
            )
        }

        var grouped: [ArchiveTaskKind: (files: Int, bytes: Int64, paths: [String])] = [:]
        // Categories with no ArchiveTaskKind at all -- see UncoveredFindings'
        // doc comment. Kept separate from `grouped` because a finding here
        // never had a chance to become a card, unlike one that is grouped
        // and later suppressed by an acknowledgement or the actionability gate.
        var uncoveredByCategory: [String: (files: Int, bytes: Int64)] = [:]
        try db.query(
            """
            SELECT d.category, d.path, COALESCE(f.size, 0)
            FROM findings d LEFT JOIN files f ON f.path = d.path
            WHERE d.run_id IN (
                    (SELECT MAX(id) FROM runs WHERE kind = 'audit'),
                    (SELECT MAX(id) FROM runs WHERE kind = 'verify')
                  )
            ORDER BY d.id;
            """
        ) { row in
            let category = row.string(0) ?? ""
            let path = row.string(1) ?? ""
            let size = row.int64(2) ?? 0
            guard let kind = ArchiveTaskKind.allCases.first(where: {
                $0.findingCategories.contains(category)
            }) else {
                var entry = uncoveredByCategory[category] ?? (files: 0, bytes: 0)
                entry.files += 1
                entry.bytes += size
                uncoveredByCategory[category] = entry
                return
            }
            var entry = grouped[kind] ?? (files: 0, bytes: 0, paths: [])
            entry.files += 1
            entry.bytes += size
            if entry.paths.count < Self.evidenceLimit, !path.isEmpty { entry.paths.append(path) }
            grouped[kind] = entry
        }

        let ackedKeys: Set<String>
        if let metadata {
            ackedKeys = Set(try await metadata.acknowledgements().map(\.ackKey))
        } else {
            ackedKeys = []
        }

        let tasks = grouped.compactMap { kind, entry -> ArchiveTask? in
            let ackKey = MetadataStore.ackKey(category: ArchiveTask.ackCategory, groupKey: kind.rawValue)
            guard !ackedKeys.contains(ackKey) else { return nil }
            let action = Self.action(for: kind, entry: entry)
            guard action != .unavailable else { return nil }
            return ArchiveTask(
                kind: kind, severity: Self.severity(for: kind),
                affectedFileCount: entry.files, bytes: entry.bytes,
                evidencePaths: entry.paths, action: action
            )
        }
        .sorted {
            ($0.severity.rank, -$0.bytes, $0.kind.rawValue)
                < ($1.severity.rank, -$1.bytes, $1.kind.rawValue)
        }

        let uncovered = UncoveredFindings(
            count: uncoveredByCategory.values.reduce(0) { $0 + $1.files },
            bytes: uncoveredByCategory.values.reduce(0) { $0 + $1.bytes },
            categories: uncoveredByCategory.mapValues(\.files)
        )
        return ArchiveTaskSummary(tasks: tasks, uncovered: uncovered)
    }

    private static func severity(for kind: ArchiveTaskKind) -> ArchiveTaskSeverity {
        switch kind {
        case .misplacedCalibration, .brokenNames, .corruption: .error
        case .intermediateFiles, .duplicateContent: .reclaim
        case .unverified: .attention
        case .auditNeverRun: .info
        }
    }

    private static func action(
        for kind: ArchiveTaskKind, entry: (files: Int, bytes: Int64, paths: [String])
    ) -> ArchiveTaskAction {
        switch kind {
        case .intermediateFiles, .duplicateContent:
            .previewQuarantine(categories: kind.findingCategories)
        case .misplacedCalibration, .brokenNames, .corruption, .unverified:
            // Honest gate: with no concrete path there is nothing to open,
            // so no card is produced at all (see this type's doc comment).
            entry.paths.first.map { ArchiveTaskAction.revealInFinder(path: $0) } ?? .unavailable
        case .auditNeverRun:
            .runAudit
        }
    }

    private static func hasAuditRun(db: SQLiteDB) throws -> Bool {
        var found = false
        try db.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'runs';"
        ) { _ in found = true }
        guard found else { return false }
        var hasRun = false
        try db.query("SELECT COUNT(*) FROM runs WHERE kind = 'audit';") { row in
            hasRun = (row.int64(0) ?? 0) > 0
        }
        return hasRun
    }
}
