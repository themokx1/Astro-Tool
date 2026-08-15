import AstroCore
import Foundation

public enum LibraryHealthCategory: String, CaseIterable, Sendable { case flat, dark, bias, storage, integrity, duplicates, organization }
public enum LibraryHealthSeverity: String, Sendable { case healthy, info, warning, critical }
public struct LibraryHealthItem: Equatable, Sendable, Identifiable {
    public let id: String; public let category: LibraryHealthCategory; public let severity: LibraryHealthSeverity
    public let title: String; public let detail: String
    public let target: String?; public let sessionDate: String?
    public let isAcknowledged: Bool

    public init(
        id: String, category: LibraryHealthCategory, severity: LibraryHealthSeverity,
        title: String, detail: String, target: String? = nil, sessionDate: String? = nil,
        isAcknowledged: Bool = false
    ) {
        self.id = id; self.category = category; self.severity = severity
        self.title = title; self.detail = detail; self.target = target; self.sessionDate = sessionDate
        self.isAcknowledged = isAcknowledged
    }

    /// The `(category, groupKey)` pair a caller acks/revokes this item
    /// through -- `groupKey` is the item's own stable `id`, which is already
    /// derived from content that survives a re-scan (target/date/hash), not
    /// from an ephemeral row identity.
    public var ackCategory: String { category.rawValue }
    public var ackGroupKey: String { id }
    /// `KeyPathComparator` needs a `Comparable` value, and `severity`'s
    /// `rawValue` sorts alphabetically (critical, healthy, info, warning),
    /// not by actual severity -- this is the real "most severe first" key
    /// the findings table's default sort (and any user re-sort) uses.
    public var severityRank: Int {
        switch severity {
        case .critical: 3
        case .warning: 2
        case .info: 1
        case .healthy: 0
        }
    }

    func acknowledged(_ flag: Bool) -> LibraryHealthItem {
        LibraryHealthItem(
            id: id, category: category, severity: severity, title: title, detail: detail,
            target: target, sessionDate: sessionDate, isAcknowledged: flag
        )
    }
}

/// One completed audit run, ready for display: when it ran, how many
/// findings it produced, and how many of those are new/resolved compared to
/// the run immediately before it (V1 `AuditDiff` semantics).
public struct LibraryHealthAuditRunSummary: Equatable, Sendable {
    public let ranAt: Date
    public let findingCount: Int
    public let newCount: Int
    public let resolvedCount: Int

    public init(ranAt: Date, findingCount: Int, newCount: Int, resolvedCount: Int) {
        self.ranAt = ranAt
        self.findingCount = findingCount
        self.newCount = newCount
        self.resolvedCount = resolvedCount
    }
}

public struct LibraryHealthSnapshot: Equatable, Sendable {
    public let sessionCount: Int; public let calibrationIssues: Int
    public let duplicateFiles: Int; public let organizationIssues: Int
    public let items: [LibraryHealthItem]; public let isReadOnly: Bool
    public let auditRuns: [LibraryHealthAuditRunSummary]

    public init(
        sessionCount: Int, calibrationIssues: Int, duplicateFiles: Int, organizationIssues: Int,
        items: [LibraryHealthItem], isReadOnly: Bool, auditRuns: [LibraryHealthAuditRunSummary] = []
    ) {
        self.sessionCount = sessionCount; self.calibrationIssues = calibrationIssues
        self.duplicateFiles = duplicateFiles; self.organizationIssues = organizationIssues
        self.items = items; self.isReadOnly = isReadOnly; self.auditRuns = auditRuns
    }
}

public struct LibraryHealthQuery: Sendable {
    private let indexDatabase: URL?
    private let metadata: MetadataStore?
    /// V2 product/UX audit (2026-08-15) section 3(a), CRITICAL: `snapshot()`
    /// used to hardcode `isReadOnly: true` no matter what -- Health claimed
    /// "Read only" even with write operations enabled, while Calibration
    /// (`CalibrationStore.accessMode`) one click away correctly said
    /// "Writable". This is the real access mode, threaded the same way
    /// `CleanupPreviewQuery`/`CalibrationLinkCommand` already do; the final
    /// snapshot's `isReadOnly` is derived from it, not from whatever the
    /// read path below happens to hand back.
    private let accessMode: LibraryAccessMode
    private init(indexDatabase: URL? = nil, metadata: MetadataStore? = nil, accessMode: LibraryAccessMode = .readOnly) {
        self.indexDatabase = indexDatabase
        self.metadata = metadata
        self.accessMode = accessMode
    }
    init(indexDatabaseForTesting: URL, metadata: MetadataStore? = nil, accessMode: LibraryAccessMode = .readOnly) {
        self.indexDatabase = indexDatabaseForTesting
        self.metadata = metadata
        self.accessMode = accessMode
    }
    public static func fixture() -> Self { Self() }
    public static func production(
        rootURL: URL, metadata: MetadataStore? = nil, accessMode: LibraryAccessMode = .readOnly
    ) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        let resolvedMetadata = try metadata ?? MetadataStore(storagePaths: storage)
        return Self(indexDatabase: storage.indexDatabase, metadata: resolvedMetadata, accessMode: accessMode)
    }

    /// `includeAcknowledged` controls whether an acked finding group is
    /// dropped from `items` (the default, matching V1's "hide by default")
    /// or kept in place (dimmed by the caller) with `isAcknowledged == true`.
    public func snapshot(includeAcknowledged: Bool = false) async throws -> LibraryHealthSnapshot {
        let isReadOnly = accessMode != .mutationEnabled
        let base: LibraryHealthSnapshot
        if let indexDatabase {
            base = try Self.readSnapshot(indexDatabase: indexDatabase)
        } else {
            base = LibraryHealthSnapshot(sessionCount: 1, calibrationIssues: 2, duplicateFiles: 0, organizationIssues: 0, items: [
                .init(id: "flat", category: .flat, severity: .warning, title: "Flat mismatch", detail: "Rotation differs between lights and flats."),
                .init(id: "dark", category: .dark, severity: .warning, title: "Dark missing", detail: "No matching session or library dark."),
                .init(id: "integrity", category: .integrity, severity: .healthy, title: "Source library protected", detail: "Health checks are read-only."),
            ], isReadOnly: true)
        }
        guard let metadata else {
            return LibraryHealthSnapshot(
                sessionCount: base.sessionCount, calibrationIssues: base.calibrationIssues,
                duplicateFiles: base.duplicateFiles, organizationIssues: base.organizationIssues,
                items: base.items, isReadOnly: isReadOnly, auditRuns: base.auditRuns
            )
        }

        let ackedKeys = Set(try await metadata.acknowledgements().map(\.ackKey))
        let annotatedItems = base.items.map { item -> LibraryHealthItem in
            let key = MetadataStore.ackKey(category: item.ackCategory, groupKey: item.ackGroupKey)
            return item.acknowledged(ackedKeys.contains(key))
        }
        let visibleItems = includeAcknowledged ? annotatedItems : annotatedItems.filter { !$0.isAcknowledged }
        let auditRuns = try await Self.auditRunSummaries(metadata: metadata)
        return LibraryHealthSnapshot(
            sessionCount: base.sessionCount, calibrationIssues: base.calibrationIssues,
            duplicateFiles: base.duplicateFiles, organizationIssues: base.organizationIssues,
            items: visibleItems, isReadOnly: isReadOnly, auditRuns: auditRuns
        )
    }

    private static func auditRunSummaries(
        metadata: MetadataStore, limit: Int = 10
    ) async throws -> [LibraryHealthAuditRunSummary] {
        let runs = try await metadata.auditRunHistory(limit: limit + 1)
        guard !runs.isEmpty else { return [] }
        var summaries: [LibraryHealthAuditRunSummary] = []
        for index in runs.indices where index < limit {
            let current = runs[index]
            let currentKeys = Set(current.groupKeys)
            if index + 1 < runs.count {
                let previousKeys = Set(runs[index + 1].groupKeys)
                summaries.append(LibraryHealthAuditRunSummary(
                    ranAt: current.ranAt, findingCount: current.findingCount,
                    newCount: currentKeys.subtracting(previousKeys).count,
                    resolvedCount: previousKeys.subtracting(currentKeys).count
                ))
            } else {
                summaries.append(LibraryHealthAuditRunSummary(
                    ranAt: current.ranAt, findingCount: current.findingCount,
                    newCount: currentKeys.count, resolvedCount: 0
                ))
            }
        }
        return summaries
    }

    private static func readSnapshot(indexDatabase: URL) throws -> LibraryHealthSnapshot {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        var sessions: [(String, String, Int, Int, Int)] = []
        try db.query(
            """
            SELECT target, session_date,
                   SUM(CASE WHEN role = 'light' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN role = 'flat' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN role = 'dark' THEN 1 ELSE 0 END)
            FROM files
            WHERE missing = 0 AND area = 'sessions'
              AND target IS NOT NULL AND session_date IS NOT NULL
            GROUP BY target, session_date ORDER BY session_date DESC, target;
            """
        ) { row in
            sessions.append((row.string(0) ?? "", row.string(1) ?? "", Int(row.int64(2) ?? 0), Int(row.int64(3) ?? 0), Int(row.int64(4) ?? 0)))
        }
        let missingFlats = sessions.filter { $0.2 > 0 && $0.3 == 0 }
        let missingDarks = sessions.filter { $0.2 > 0 && $0.4 == 0 }
        var items = missingFlats.map { target, date, lights, _, _ in
            LibraryHealthItem(
                id: "flat|\(target)|\(date)", category: .flat, severity: .warning,
                title: "Flat missing · \(date)", detail: "\(target): \(lights) light frame has no session flat.",
                target: target, sessionDate: date
            )
        }
        items.append(contentsOf: missingDarks.map { target, date, lights, _, _ in
            LibraryHealthItem(
                id: "dark|\(target)|\(date)", category: .dark, severity: .warning,
                title: "Dark coverage needs review · \(date)",
                detail: "\(target): \(lights) light frame has no session dark; check the calibration library.",
                target: target, sessionDate: date
            )
        })
        var duplicateFiles = 0
        if try tableHasColumn(db, table: "files", column: "content_hash") {
            // V2 product/UX audit (2026-08-15) section 3(c) cheap fix:
            // this used to say "4 identical files" with no path at all, so
            // there was no way to learn which files -- `GROUP_CONCAT` pulls
            // back the actual paths sharing the hash so the detail names
            // enough of them to act on.
            try db.query(
                """
                SELECT content_hash, COUNT(*), COALESCE(MAX(size), 0), GROUP_CONCAT(path, '\u{1}')
                FROM files WHERE missing = 0 AND content_hash IS NOT NULL AND content_hash <> ''
                GROUP BY content_hash HAVING COUNT(*) > 1;
                """
            ) { row in
                let count = Int(row.int64(1) ?? 0)
                duplicateFiles += max(0, count - 1)
                let paths = (row.string(3) ?? "").split(separator: "\u{1}").map(String.init)
                let shown = paths.prefix(2).joined(separator: ", ")
                let remaining = paths.count > 2 ? " and \(paths.count - 2) more" : ""
                items.append(.init(
                    id: "duplicate|\(row.string(0) ?? "unknown")", category: .duplicates,
                    severity: .warning, title: "Duplicate content",
                    detail: "\(count) identical files: \(shown)\(remaining)."
                ))
            }
        }
        var organizationIssues = 0
        try db.query(
            """
            SELECT COUNT(*) FROM files
            WHERE missing = 0 AND (area = 'other' OR role = 'other')
              AND (path LIKE '%.DS_Store' OR path LIKE '%.seq' OR path LIKE '%.lst');
            """
        ) { row in organizationIssues = Int(row.int64(0) ?? 0) }
        if organizationIssues > 0 {
            items.append(.init(
                id: "organization", category: .organization, severity: .info,
                title: "Organization cleanup available",
                detail: "\(organizationIssues) residue file can be reviewed; nothing will be deleted automatically."
            ))
        }
        // V2 product/UX audit (2026-08-15) section 3(b), CRITICAL: this used
        // to be a single hardcoded "healthy" item, no matter what a prior
        // `Verify Integrity…` run actually found -- a run that found real
        // corruption produced a generic success toast and nothing else,
        // while `HealthView` promised "Restore from backup" for a mismatch
        // that could never appear here. `findings` from the most recent
        // `kind = 'verify'` run (persisted by `FixityVerifier.run`, see its
        // own doc comment) are real, durable evidence of what that run
        // found; only when there are none does the reassuring placeholder
        // stand. Titles/detail are written fresh in English here rather
        // than passed through `findings.message` (Hungarian free text meant
        // for the CLI), keyed off the same `category` strings
        // `FixityVerifier.findings(from:)` already assigns.
        let integrityItems = try Self.latestVerifyFindings(db: db)
        if integrityItems.isEmpty {
            items.append(.init(
                id: "integrity", category: .integrity, severity: .healthy,
                title: "Source library protected", detail: "This health scan opened only AstroTool's external index."
            ))
        } else {
            items.append(contentsOf: integrityItems)
        }
        return LibraryHealthSnapshot(
            sessionCount: sessions.count, calibrationIssues: missingFlats.count + missingDarks.count,
            duplicateFiles: duplicateFiles, organizationIssues: organizationIssues,
            items: items, isReadOnly: true
        )
    }

    /// Real per-file mismatch/read-error findings from the most recently
    /// completed `kind = 'verify'` run, if any -- `[]` on a database that
    /// predates the `runs`/`findings` tables, or if the most recent verify
    /// run found nothing wrong.
    private static func latestVerifyFindings(db: SQLiteDB) throws -> [LibraryHealthItem] {
        guard try tableExists(db, name: "runs"), try tableExists(db, name: "findings") else { return [] }
        var latestRunID: Int64?
        try db.query("SELECT id FROM runs WHERE kind = 'verify' ORDER BY started_at DESC LIMIT 1;") { row in
            latestRunID = row.int64(0)
        }
        guard let runID = latestRunID else { return [] }
        var findings: [LibraryHealthItem] = []
        try db.query(
            "SELECT category, path FROM findings WHERE run_id = ? ORDER BY id;",
            bind: [.int(runID)]
        ) { row in
            let category = row.string(0) ?? ""
            let path = row.string(1) ?? "unknown file"
            let (title, detail, severity) = Self.integrityFindingText(category: category, path: path)
            findings.append(.init(
                id: "integrity|\(runID)|\(path)", category: .integrity, severity: severity,
                title: title, detail: detail
            ))
        }
        return findings
    }

    private static func integrityFindingText(category: String, path: String) -> (title: String, detail: String, severity: LibraryHealthSeverity) {
        switch category {
        case "content-changed":
            return (
                "Possible silent corruption",
                "\(path): content changed since the last integrity check, but its size and modification time did not -- this looks like bitrot, not an edit. Restore this file from a backup.",
                .critical
            )
        case "modified-in-place":
            return (
                "Suspicious in-place modification",
                "\(path): modification time changed but size did not, and the content hash differs -- could be an in-place header rewrite, but treat it as suspicious.",
                .warning
            )
        case "modified":
            return (
                "File modified since last check",
                "\(path): size and modification time both changed since the last integrity check -- likely an intentional edit or overwrite, not corruption.",
                .info
            )
        case "verify-read-error":
            return (
                "File unreadable during verification",
                "\(path): could not be read during the last integrity verification.",
                .warning
            )
        default:
            return ("Integrity finding", "\(path): \(category)", .warning)
        }
    }

    private static func tableExists(_ db: SQLiteDB, name: String) throws -> Bool {
        var found = false
        try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;", bind: [.text(name)]) { _ in
            found = true
        }
        return found
    }

    private static func tableHasColumn(_ db: SQLiteDB, table: String, column: String) throws -> Bool {
        var found = false
        try db.query("PRAGMA table_info(\(table));") { row in
            if row.string(1) == column { found = true }
        }
        return found
    }
}
