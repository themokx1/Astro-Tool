import AstroCore
import Foundation

public struct MonthlyCapture: Equatable, Sendable, Identifiable {
    public var id: String { month }
    public let month: String
    public let integrationSeconds: Double
    public let frameCount: Int
}

public struct TargetCapture: Equatable, Sendable, Identifiable {
    public var id: String { target }
    public let target: String
    public let integrationSeconds: Double
    public let nightCount: Int
}

public struct InsightsSnapshot: Equatable, Sendable {
    public let nightCount: Int
    public let targetCount: Int
    public let frameCount: Int
    public let integrationSeconds: Double
    public let months: [MonthlyCapture]
    public let topTargets: [TargetCapture]
    public let isReadOnly: Bool
}

public struct InsightsQuery: Sendable {
    private let indexDatabase: URL

    init(indexDatabaseForTesting: URL) { self.indexDatabase = indexDatabaseForTesting }

    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return Self(indexDatabaseForTesting: storage.indexDatabase)
    }

    public func snapshot() async throws -> InsightsSnapshot {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        var nightCount = 0
        var targetCount = 0
        var frameCount = 0
        var integrationSeconds = 0.0
        try db.query(
            """
            SELECT COUNT(DISTINCT target || '|' || session_date), COUNT(DISTINCT target), COUNT(*),
                   COALESCE(SUM(COALESCE(m.exptime, 0)), 0)
            FROM files f LEFT JOIN fits_meta m ON m.file_id = f.id
            WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light';
            """
        ) { row in
            nightCount = Int(row.int64(0) ?? 0)
            targetCount = Int(row.int64(1) ?? 0)
            frameCount = Int(row.int64(2) ?? 0)
            integrationSeconds = row.double(3) ?? 0
        }
        var months: [MonthlyCapture] = []
        try db.query(
            """
            SELECT SUBSTR(f.session_date, 1, 7), COALESCE(SUM(COALESCE(m.exptime, 0)), 0), COUNT(*)
            FROM files f LEFT JOIN fits_meta m ON m.file_id = f.id
            WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light' AND f.session_date IS NOT NULL
            GROUP BY SUBSTR(f.session_date, 1, 7) ORDER BY 1;
            """
        ) { row in
            months.append(.init(month: row.string(0) ?? "Unknown", integrationSeconds: row.double(1) ?? 0, frameCount: Int(row.int64(2) ?? 0)))
        }
        var targets: [TargetCapture] = []
        try db.query(
            """
            SELECT f.target, COALESCE(SUM(COALESCE(m.exptime, 0)), 0), COUNT(DISTINCT f.session_date)
            FROM files f LEFT JOIN fits_meta m ON m.file_id = f.id
            WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light' AND f.target IS NOT NULL
            GROUP BY f.target ORDER BY 2 DESC, f.target COLLATE NOCASE LIMIT 8;
            """
        ) { row in
            targets.append(.init(target: row.string(0) ?? "Unknown", integrationSeconds: row.double(1) ?? 0, nightCount: Int(row.int64(2) ?? 0)))
        }
        return InsightsSnapshot(
            nightCount: nightCount, targetCount: targetCount, frameCount: frameCount,
            integrationSeconds: integrationSeconds, months: months, topTargets: targets, isReadOnly: true
        )
    }
}
