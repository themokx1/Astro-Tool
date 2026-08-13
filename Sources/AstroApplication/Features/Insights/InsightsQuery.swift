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

public struct FilterUsage: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let frameCount: Int
    public let integrationSeconds: Double
}

public struct SetupUsage: Equatable, Sendable, Identifiable {
    public var id: String { "\(camera)|\(focalLength ?? -1)" }
    public let camera: String
    public let focalLength: Double?
    public let frameCount: Int
    public let integrationSeconds: Double
}

public struct InsightsSnapshot: Equatable, Sendable {
    public let nightCount: Int
    public let targetCount: Int
    public let frameCount: Int
    public let integrationSeconds: Double
    public let months: [MonthlyCapture]
    public let topTargets: [TargetCapture]
    public let filterUsage: [FilterUsage]
    public let setupUsage: [SetupUsage]
    public let rejectedFrameCount: Int
    public let isReadOnly: Bool
    public var bestMonth: MonthlyCapture? { months.max { $0.integrationSeconds < $1.integrationSeconds } }
    public var averageIntegrationPerNight: Double {
        nightCount == 0 ? 0 : integrationSeconds / Double(nightCount)
    }
    public var usableFrameCount: Int { max(0, frameCount - rejectedFrameCount) }
    public var captureEfficiency: Double {
        frameCount == 0 ? 0 : Double(usableFrameCount) / Double(frameCount)
    }
}

public struct InsightsQuery: Sendable {
    private let indexDatabase: URL

    init(indexDatabaseForTesting: URL) { self.indexDatabase = indexDatabaseForTesting }

    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return Self(indexDatabaseForTesting: storage.indexDatabase)
    }

    public func snapshot(year: Int? = nil) async throws -> InsightsSnapshot {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        let yearClause = year.map { " AND f.session_date LIKE '\($0)-%'" } ?? ""
        var nightCount = 0
        var targetCount = 0
        var frameCount = 0
        var integrationSeconds = 0.0
        var rejectedFrameCount = 0
        try db.query(
            """
            SELECT COUNT(DISTINCT target || '|' || session_date), COUNT(DISTINCT target), COUNT(*),
                   COALESCE(SUM(COALESCE(m.exptime, 0)), 0)
            FROM files f LEFT JOIN fits_meta m ON m.file_id = f.id
            WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light'\(yearClause);
            """
        ) { row in
            nightCount = Int(row.int64(0) ?? 0)
            targetCount = Int(row.int64(1) ?? 0)
            frameCount = Int(row.int64(2) ?? 0)
            integrationSeconds = row.double(3) ?? 0
        }
        if try Self.tableExists(db: db, table: "user_verdicts") {
            try db.query(
                """
                SELECT COUNT(*) FROM user_verdicts uv JOIN files f ON f.id = uv.file_id
                WHERE uv.accepted = 0 AND f.missing = 0 AND f.area = 'sessions'
                  AND f.role = 'light'\(yearClause);
                """
            ) { row in rejectedFrameCount = Int(row.int64(0) ?? 0) }
        }
        var months: [MonthlyCapture] = []
        try db.query(
            """
            SELECT SUBSTR(f.session_date, 1, 7), COALESCE(SUM(COALESCE(m.exptime, 0)), 0), COUNT(*)
            FROM files f LEFT JOIN fits_meta m ON m.file_id = f.id
            WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light' AND f.session_date IS NOT NULL\(yearClause)
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
            WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light' AND f.target IS NOT NULL\(yearClause)
            GROUP BY f.target ORDER BY 2 DESC, f.target COLLATE NOCASE LIMIT 8;
            """
        ) { row in
            targets.append(.init(target: row.string(0) ?? "Unknown", integrationSeconds: row.double(1) ?? 0, nightCount: Int(row.int64(2) ?? 0)))
        }
        let columns = try Self.columns(db: db, table: "fits_meta")
        var filterUsage: [FilterUsage] = []
        if columns.contains("filter") {
            try db.query(
                """
                SELECT m.filter, COUNT(*), COALESCE(SUM(COALESCE(m.exptime, 0)), 0)
                FROM files f JOIN fits_meta m ON m.file_id = f.id
                WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light'\(yearClause)
                  AND m.filter IS NOT NULL AND TRIM(m.filter) <> ''
                GROUP BY m.filter ORDER BY 3 DESC, 1 COLLATE NOCASE;
                """
            ) { row in
                filterUsage.append(.init(
                    name: row.string(0) ?? "Unknown", frameCount: Int(row.int64(1) ?? 0),
                    integrationSeconds: row.double(2) ?? 0
                ))
            }
        }
        var setupUsage: [SetupUsage] = []
        if columns.contains("instrume") {
            let focal = columns.contains("focallen") ? "m.focallen" : "NULL"
            try db.query(
                """
                SELECT COALESCE(NULLIF(TRIM(m.instrume), ''), 'Unknown camera'), \(focal),
                       COUNT(*), COALESCE(SUM(COALESCE(m.exptime, 0)), 0)
                FROM files f JOIN fits_meta m ON m.file_id = f.id
                WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light'\(yearClause)
                GROUP BY 1, 2 ORDER BY 4 DESC, 1 COLLATE NOCASE;
                """
            ) { row in
                setupUsage.append(.init(
                    camera: row.string(0) ?? "Unknown camera", focalLength: row.double(1),
                    frameCount: Int(row.int64(2) ?? 0), integrationSeconds: row.double(3) ?? 0
                ))
            }
        }
        return InsightsSnapshot(
            nightCount: nightCount, targetCount: targetCount, frameCount: frameCount,
            integrationSeconds: integrationSeconds, months: months, topTargets: targets,
            filterUsage: filterUsage, setupUsage: setupUsage,
            rejectedFrameCount: rejectedFrameCount, isReadOnly: true
        )
    }

    private static func columns(db: SQLiteDB, table: String) throws -> Set<String> {
        var result: Set<String> = []
        try db.query("PRAGMA table_info(\(table));") { row in
            if let name = row.string(1) { result.insert(name) }
        }
        return result
    }

    private static func tableExists(db: SQLiteDB, table: String) throws -> Bool {
        var exists = false
        try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;", bind: [.text(table)]) { _ in
            exists = true
        }
        return exists
    }
}
