import AstroCore
import Foundation

/// One past measurement of a `(camera, gain, offset)` combo, projected from
/// `sensor_profile_history` -- ascending by `measuredAt` (oldest first),
/// matching `Database.sensorProfileHistory`'s own chronological order so a
/// sparkline built directly from this array never needs to re-sort.
public struct SensorProfileHistoryPoint: Equatable, Sendable, Identifiable {
    public var id: TimeInterval { measuredAt.timeIntervalSince1970 }
    public let measuredAt: Date
    public let biasLevelADU: Double?
    public let readNoiseElectrons: Double?
    public let darkRateElectronsPerSecond: Double?
}

public struct SensorProfileSnapshot: Equatable, Sendable, Identifiable {
    public var id: String { "\(camera)|\(gain ?? -1)|\(offset ?? -1)" }
    public let camera: String
    public let gain: Double?
    public let offset: Double?
    public let biasLevelADU: Double?
    public let readNoiseElectrons: Double?
    public let darkRateElectronsPerSecond: Double?
    public let darkTemperatureCelsius: Double?
    public let electronsPerADU: Double?
    public let measuredAt: Date
    public let frameCount: Int
    public let estimatorVersion: Int?
    /// This combo's own measurement history, oldest first -- empty when the
    /// index database predates schema v10 (`sensor_profile_history` did not
    /// exist yet) or simply has no prior measurement recorded.
    public let history: [SensorProfileHistoryPoint]

    /// `true` when this profile predates `SensorProfiler.estimatorVersion`
    /// -- mirrors `SensorProfileRecord.isEstimatorStale`: `nil` counts as
    /// stale too, since it means "measured before versioning existed".
    public var isEstimatorStale: Bool {
        guard let estimatorVersion else { return true }
        return estimatorVersion < SensorProfiler.estimatorVersion
    }
}

/// A `(camera, gain, offset)` combo among tracked LIGHT frames that has no
/// usable measured profile on record yet -- projects
/// `SensorProfiler.combosMissingProfile` for display; re-measuring
/// (`SensorMeasurementCommand`) is how a user closes this gap.
public struct MissingSensorProfileCombo: Equatable, Sendable, Identifiable {
    public var id: String { "\(camera)|\(gain ?? -1)|\(offset ?? -1)" }
    public let camera: String
    public let gain: Double?
    public let offset: Double?
}

public struct SensorProfilesSnapshot: Equatable, Sendable {
    public let profiles: [SensorProfileSnapshot]
    public let isReadOnly: Bool
    public let missingCombos: [MissingSensorProfileCombo]
}

public struct SensorProfilesQuery: Sendable {
    private let indexDatabase: URL

    /// Public (rather than `production`-only) so a store's own
    /// `QueryFactory` can construct this against a temp fixture database in
    /// tests -- the same shape `CalibrationQuery`'s own `public init(db:
    /// config:)` already established for that store.
    public init(indexDatabase: URL) { self.indexDatabase = indexDatabase }

    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return Self(indexDatabase: storage.indexDatabase)
    }

    public func snapshot() async throws -> SensorProfilesSnapshot {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)

        // `estimator_version` (schema v10) may not exist on a `sensor_profile`
        // table that predates it -- selected only when present, defaulting
        // every row's version to the honest "unknown, pre-versioning" `nil`
        // rather than failing the whole read.
        let hasEstimatorVersion = (try? Self.tableHasColumn(db: db, table: "sensor_profile", column: "estimator_version")) ?? false
        var rows: [(camera: String, gain: Double?, offset: Double?, bias: Double?, readNoise: Double?, darkRate: Double?, darkTemp: Double?, egain: Double?, measuredAt: Double, frameCount: Int, estimatorVersion: Int?)] = []
        try db.query(
            """
            SELECT camera,gain,offset,bias_level_adu,read_noise_e,dark_rate_e_per_s,
                   dark_temp_c,egain,measured_at,COALESCE(frame_count,0)\(hasEstimatorVersion ? ",estimator_version" : "")
            FROM sensor_profile ORDER BY measured_at DESC,camera COLLATE NOCASE,gain,offset;
            """
        ) { row in
            rows.append((
                camera: row.string(0) ?? "Unknown camera", gain: row.double(1), offset: row.double(2),
                bias: row.double(3), readNoise: row.double(4), darkRate: row.double(5), darkTemp: row.double(6),
                egain: row.double(7), measuredAt: row.double(8) ?? 0, frameCount: Int(row.int64(9) ?? 0),
                estimatorVersion: hasEstimatorVersion ? row.int64(10).map(Int.init) : nil
            ))
        }

        // `sensor_profile_history` (schema v10) may not exist yet if the
        // index database predates it -- read-only snapshots never migrate,
        // so this is a real possibility, not just test-fixture noise.
        let historyTableExists = (try? Self.tableExists(db: db, table: "sensor_profile_history")) ?? false
        var profiles: [SensorProfileSnapshot] = []
        for row in rows {
            var history: [SensorProfileHistoryPoint] = []
            if historyTableExists {
                try db.query(
                    """
                    SELECT bias_level_adu,read_noise_e,dark_rate_e_per_s,measured_at
                    FROM sensor_profile_history WHERE camera = ? AND gain IS ? AND offset IS ?
                    ORDER BY measured_at ASC;
                    """,
                    bind: [.text(row.camera), row.gain.map(SQLiteValue.real) ?? .null, row.offset.map(SQLiteValue.real) ?? .null]
                ) { historyRow in
                    history.append(.init(
                        measuredAt: Date(timeIntervalSince1970: historyRow.double(3) ?? 0),
                        biasLevelADU: historyRow.double(0), readNoiseElectrons: historyRow.double(1),
                        darkRateElectronsPerSecond: historyRow.double(2)
                    ))
                }
            }
            profiles.append(.init(
                camera: row.camera, gain: row.gain, offset: row.offset,
                biasLevelADU: row.bias, readNoiseElectrons: row.readNoise,
                darkRateElectronsPerSecond: row.darkRate, darkTemperatureCelsius: row.darkTemp,
                electronsPerADU: row.egain, measuredAt: Date(timeIntervalSince1970: row.measuredAt),
                frameCount: row.frameCount, estimatorVersion: row.estimatorVersion, history: history
            ))
        }

        let missingCombos = (try? Self.missingCombos(db: db, profiles: profiles)) ?? []
        return .init(profiles: profiles, isReadOnly: true, missingCombos: missingCombos)
    }

    /// Every `(camera, gain, offset)` combo among tracked LIGHT frames that
    /// has no usable profile (no row, or a row whose `biasLevelADU` was
    /// never measured) among `profiles` -- a read-only re-derivation of
    /// `SensorProfiler.combosMissingProfile`'s own rule, against `files`/
    /// `fits_meta` read directly (this query never opens a writable
    /// `Database`). Requires both tables to exist; a pre-scan or
    /// unexpectedly bare index database simply reports no missing combos
    /// rather than throwing.
    private static func missingCombos(
        db: SQLiteDB, profiles: [SensorProfileSnapshot]
    ) throws -> [MissingSensorProfileCombo] {
        guard try tableExists(db: db, table: "files"), try tableExists(db: db, table: "fits_meta") else { return [] }

        var usable = Set<String>()
        for profile in profiles where profile.biasLevelADU != nil {
            usable.insert(comboKey(camera: profile.camera, gain: profile.gain, offset: profile.offset))
        }

        var combos: [MissingSensorProfileCombo] = []
        var seen = Set<String>()
        try db.query(
            """
            SELECT DISTINCT m.instrume, m.gain, m."offset"
            FROM files f JOIN fits_meta m ON m.file_id = f.id
            WHERE f.area = 'sessions' AND f.role = 'light' AND m.instrume IS NOT NULL
            ORDER BY m.instrume COLLATE NOCASE, m.gain, m."offset";
            """
        ) { row in
            guard let camera = row.string(0) else { return }
            let gain = row.double(1)
            let offset = row.double(2)
            let key = comboKey(camera: camera, gain: gain, offset: offset)
            guard seen.insert(key).inserted, !usable.contains(key) else { return }
            combos.append(.init(camera: camera, gain: gain, offset: offset))
        }
        return combos
    }

    private static func comboKey(camera: String, gain: Double?, offset: Double?) -> String {
        "\(camera)|\(gain.map { String($0) } ?? "-")|\(offset.map { String($0) } ?? "-")"
    }

    private static func tableExists(db: SQLiteDB, table: String) throws -> Bool {
        var exists = false
        try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;", bind: [.text(table)]) { _ in
            exists = true
        }
        return exists
    }

    private static func tableHasColumn(db: SQLiteDB, table: String, column: String) throws -> Bool {
        var found = false
        try db.query("PRAGMA table_info(\(table));") { row in
            if row.string(1) == column { found = true }
        }
        return found
    }
}
