import AstroCore
import Foundation

public enum ArchiveTaskKind: String, CaseIterable, Sendable {
    case intermediateFiles
    case duplicateContent
    case misplacedCalibration
    case brokenNames
    case integrity
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
        case .integrity: ["integrity"]
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
    /// `CleanupPreviewGroup.category` values.
    case previewQuarantine(categories: [String])
    case compareDuplicates
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

/// Turns the latest audit run's findings into at most six cards -- one per
/// `ArchiveTaskKind` -- instead of one row per finding. The 3 228 residue
/// findings on the reference library are one card, not 3 228 rows.
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

    public func tasks() async throws -> [ArchiveTask] {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)

        guard try Self.hasAuditRun(db: db) else {
            return [ArchiveTask(
                kind: .auditNeverRun, severity: .info,
                affectedFileCount: 0, bytes: 0, evidencePaths: [], action: .runAudit
            )]
        }

        var grouped: [ArchiveTaskKind: (files: Int, bytes: Int64, paths: [String])] = [:]
        try db.query(
            """
            SELECT d.category, d.path, COALESCE(f.size, 0)
            FROM findings d LEFT JOIN files f ON f.path = d.path
            WHERE d.run_id = (SELECT MAX(id) FROM runs WHERE kind = 'audit')
            ORDER BY d.id;
            """
        ) { row in
            let category = row.string(0) ?? ""
            let path = row.string(1) ?? ""
            let size = row.int64(2) ?? 0
            guard let kind = ArchiveTaskKind.allCases.first(where: {
                $0.findingCategories.contains(category)
            }) else { return }
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

        return grouped.compactMap { kind, entry -> ArchiveTask? in
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
    }

    private static func severity(for kind: ArchiveTaskKind) -> ArchiveTaskSeverity {
        switch kind {
        case .misplacedCalibration, .brokenNames, .integrity: .error
        case .intermediateFiles, .duplicateContent: .reclaim
        case .auditNeverRun: .info
        }
    }

    private static func action(
        for kind: ArchiveTaskKind, entry: (files: Int, bytes: Int64, paths: [String])
    ) -> ArchiveTaskAction {
        switch kind {
        case .intermediateFiles:
            .previewQuarantine(categories: kind.findingCategories)
        case .duplicateContent:
            .compareDuplicates
        case .misplacedCalibration, .brokenNames, .integrity:
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
