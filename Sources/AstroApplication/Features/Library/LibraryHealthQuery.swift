import AstroCore
import Foundation

public enum LibraryHealthCategory: String, CaseIterable, Sendable { case flat, dark, bias, storage, integrity, duplicates, organization }
public enum LibraryHealthSeverity: String, Sendable { case healthy, info, warning, critical }
public struct LibraryHealthItem: Equatable, Sendable, Identifiable {
    public let id: String; public let category: LibraryHealthCategory; public let severity: LibraryHealthSeverity
    public let title: String; public let detail: String
    public let target: String?; public let sessionDate: String?

    public init(
        id: String, category: LibraryHealthCategory, severity: LibraryHealthSeverity,
        title: String, detail: String, target: String? = nil, sessionDate: String? = nil
    ) {
        self.id = id; self.category = category; self.severity = severity
        self.title = title; self.detail = detail; self.target = target; self.sessionDate = sessionDate
    }
}
public struct LibraryHealthSnapshot: Equatable, Sendable {
    public let sessionCount: Int; public let calibrationIssues: Int
    public let duplicateFiles: Int; public let organizationIssues: Int
    public let items: [LibraryHealthItem]; public let isReadOnly: Bool
}
public struct LibraryHealthQuery: Sendable {
    private let indexDatabase: URL?
    private init(indexDatabase: URL? = nil) { self.indexDatabase = indexDatabase }
    init(indexDatabaseForTesting: URL) { self.indexDatabase = indexDatabaseForTesting }
    public static func fixture() -> Self { Self() }
    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return Self(indexDatabase: storage.indexDatabase)
    }
    public func snapshot() async throws -> LibraryHealthSnapshot {
        if let indexDatabase {
            return try Self.readSnapshot(indexDatabase: indexDatabase)
        }
        return LibraryHealthSnapshot(sessionCount: 1, calibrationIssues: 2, duplicateFiles: 0, organizationIssues: 0, items: [
            .init(id: "flat", category: .flat, severity: .warning, title: "Flat mismatch", detail: "Rotation differs between lights and flats."),
            .init(id: "dark", category: .dark, severity: .warning, title: "Dark missing", detail: "No matching session or library dark."),
            .init(id: "integrity", category: .integrity, severity: .healthy, title: "Source library protected", detail: "Health checks are read-only."),
        ], isReadOnly: true)
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
            try db.query(
                """
                SELECT content_hash, COUNT(*), COALESCE(MAX(size), 0)
                FROM files WHERE missing = 0 AND content_hash IS NOT NULL AND content_hash <> ''
                GROUP BY content_hash HAVING COUNT(*) > 1;
                """
            ) { row in
                let count = Int(row.int64(1) ?? 0)
                duplicateFiles += max(0, count - 1)
                items.append(.init(
                    id: "duplicate|\(row.string(0) ?? "unknown")", category: .duplicates,
                    severity: .warning, title: "Duplicate content",
                    detail: "\(count) identical files; \(max(0, count - 1)) additional copy can be reviewed safely."
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
        items.append(.init(
            id: "integrity", category: .integrity, severity: .healthy,
            title: "Source library protected", detail: "This health scan opened only AstroTool's external index."
        ))
        return LibraryHealthSnapshot(
            sessionCount: sessions.count, calibrationIssues: missingFlats.count + missingDarks.count,
            duplicateFiles: duplicateFiles, organizationIssues: organizationIssues,
            items: items, isReadOnly: true
        )
    }

    private static func tableHasColumn(_ db: SQLiteDB, table: String, column: String) throws -> Bool {
        var found = false
        try db.query("PRAGMA table_info(\(table));") { row in
            if row.string(1) == column { found = true }
        }
        return found
    }
}
