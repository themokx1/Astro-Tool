import AstroCore
import Foundation

public enum LibraryHealthCategory: String, Sendable { case flat, dark, bias, storage, integrity }
public enum LibraryHealthSeverity: String, Sendable { case healthy, info, warning, critical }
public struct LibraryHealthItem: Equatable, Sendable, Identifiable {
    public let id: String; public let category: LibraryHealthCategory; public let severity: LibraryHealthSeverity
    public let title: String; public let detail: String
}
public struct LibraryHealthSnapshot: Equatable, Sendable {
    public let sessionCount: Int; public let calibrationIssues: Int; public let items: [LibraryHealthItem]; public let isReadOnly: Bool
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
        return LibraryHealthSnapshot(sessionCount: 1, calibrationIssues: 2, items: [
            .init(id: "flat", category: .flat, severity: .warning, title: "Flat mismatch", detail: "Rotation differs between lights and flats."),
            .init(id: "dark", category: .dark, severity: .warning, title: "Dark missing", detail: "No matching session or library dark."),
            .init(id: "integrity", category: .integrity, severity: .healthy, title: "Source library protected", detail: "Health checks are read-only."),
        ], isReadOnly: true)
    }

    private static func readSnapshot(indexDatabase: URL) throws -> LibraryHealthSnapshot {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        var sessions: [(String, String, Int, Int)] = []
        try db.query(
            """
            SELECT target, session_date,
                   SUM(CASE WHEN role = 'light' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN role = 'flat' THEN 1 ELSE 0 END)
            FROM files
            WHERE missing = 0 AND area = 'sessions'
              AND target IS NOT NULL AND session_date IS NOT NULL
            GROUP BY target, session_date ORDER BY session_date DESC, target;
            """
        ) { row in
            sessions.append((row.string(0) ?? "", row.string(1) ?? "", Int(row.int64(2) ?? 0), Int(row.int64(3) ?? 0)))
        }
        let missingFlats = sessions.filter { $0.2 > 0 && $0.3 == 0 }
        var items = missingFlats.map { target, date, lights, _ in
            LibraryHealthItem(
                id: "flat|\(target)|\(date)", category: .flat, severity: .warning,
                title: "Flat missing · \(date)", detail: "\(target): \(lights) light frame has no session flat."
            )
        }
        items.append(.init(
            id: "integrity", category: .integrity, severity: .healthy,
            title: "Source library protected", detail: "This health scan opened only AstroTool's external index."
        ))
        return LibraryHealthSnapshot(
            sessionCount: sessions.count, calibrationIssues: missingFlats.count,
            items: items, isReadOnly: true
        )
    }
}
