import AstroCore
import Foundation

public struct ConversionSessionID: Hashable, Sendable {
    public let target: String
    public let date: String
    public init(target: String, date: String) { self.target = target; self.date = date }
    public static let ic1396 = Self(target: "IC_1396_Elephants_Trunk_Nebula", date: "2026-08-08")
}

public enum ConversionPreviewMode: String, Sendable { case logical, physical }
public struct ConversionScopeSummary: Equatable, Sendable { public let target: String; public let date: String; public let sessionCount: Int }
public struct ProposedConversionSeries: Equatable, Sendable, Identifiable {
    public let id: String; public let exposureSeconds: Double; public let title: String; public let frameCount: Int
}
public struct ConversionMovePreview: Equatable, Sendable { public let source: String; public let destination: String }
public struct ConversionPreview: Equatable, Sendable {
    public let scope: ConversionScopeSummary
    public let mode: ConversionPreviewMode
    public let proposedSeries: [ProposedConversionSeries]
    public let moves: [ConversionMovePreview]
    public let canApply: Bool
    public let authorizationMessage: String?
}

public struct ConversionUseCase: Sendable {
    private let indexDatabase: URL?
    private init(indexDatabase: URL? = nil) { self.indexDatabase = indexDatabase }
    init(indexDatabaseForTesting: URL) { self.indexDatabase = indexDatabaseForTesting }
    public static func fixture() -> Self { Self() }
    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return Self(indexDatabase: storage.indexDatabase)
    }

    public func availableSessions() async throws -> [ConversionSessionID] {
        guard let indexDatabase else { return [.ic1396] }
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        var sessions: [ConversionSessionID] = []
        try db.query(
            """
            SELECT DISTINCT target, session_date FROM files
            WHERE missing = 0 AND area = 'sessions' AND role = 'light'
              AND target IS NOT NULL AND session_date IS NOT NULL
            ORDER BY session_date DESC, target COLLATE NOCASE;
            """
        ) { row in
            guard let target = row.string(0), let date = row.string(1) else { return }
            sessions.append(.init(target: target, date: date))
        }
        return sessions
    }

    public func plan(sessionID: ConversionSessionID, mode: ConversionPreviewMode = .logical) async throws -> ConversionPreview {
        if let indexDatabase {
            return try Self.readPreview(indexDatabase: indexDatabase, sessionID: sessionID, mode: mode)
        }
        let exposures: [(Double, Int)] = [(5, 24), (30, 32), (120, 3), (300, 46)]
        let series = exposures.map { exposure, count in
            ProposedConversionSeries(
                id: "capture-\(Int(exposure))s", exposureSeconds: exposure,
                title: exposure < 120 ? "OSC \(Int(exposure)) s" : "OSC · Dual-band · \(Int(exposure)) s",
                frameCount: count
            )
        }
        return ConversionPreview(
            scope: .init(target: sessionID.target, date: sessionID.date, sessionCount: 1),
            mode: mode, proposedSeries: series,
            moves: mode == .logical ? [] : [],
            canApply: mode == .logical,
            authorizationMessage: mode == .physical ? "Explicit write access is required before any file can move." : nil
        )
    }

    private static func readPreview(
        indexDatabase: URL,
        sessionID: ConversionSessionID,
        mode: ConversionPreviewMode
    ) throws -> ConversionPreview {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        var groups: [(Double, String?, Int)] = []
        try db.query(
            """
            SELECT COALESCE(m.exptime, 0), NULLIF(TRIM(m.filter), ''), COUNT(*)
            FROM files f LEFT JOIN fits_meta m ON m.file_id = f.id
            WHERE f.missing = 0 AND f.area = 'sessions' AND f.role = 'light'
              AND f.target = ? AND f.session_date = ?
            GROUP BY COALESCE(m.exptime, 0), NULLIF(TRIM(m.filter), '')
            ORDER BY COALESCE(m.exptime, 0), NULLIF(TRIM(m.filter), '');
            """,
            bind: [.text(sessionID.target), .text(sessionID.date)]
        ) { row in
            groups.append((row.double(0) ?? 0, row.string(1), Int(row.int64(2) ?? 0)))
        }
        let series = groups.map { exposure, filter, count in
            let exposureLabel = exposure > 0 ? "\(exposure.formatted(.number.precision(.fractionLength(0...1)))) s" : "Unknown exposure"
            let title = ["Light", filter, exposureLabel].compactMap { $0 }.joined(separator: " · ")
            return ProposedConversionSeries(
                id: "\(filter ?? "unfiltered")|\(exposure)", exposureSeconds: exposure,
                title: title, frameCount: count
            )
        }
        return ConversionPreview(
            scope: .init(target: sessionID.target, date: sessionID.date, sessionCount: 1),
            mode: mode, proposedSeries: series, moves: [],
            canApply: mode == .logical && !series.isEmpty,
            authorizationMessage: mode == .physical
                ? "Physical organization requires explicit write access. No file will move in this preview."
                : nil
        )
    }
}
