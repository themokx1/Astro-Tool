import AstroCore
import Foundation

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
}

public struct SensorProfilesSnapshot: Equatable, Sendable {
    public let profiles: [SensorProfileSnapshot]
    public let isReadOnly: Bool
}

public struct SensorProfilesQuery: Sendable {
    private let indexDatabase: URL
    private init(indexDatabase: URL) { self.indexDatabase = indexDatabase }
    init(indexDatabaseForTesting: URL) { self.indexDatabase = indexDatabaseForTesting }

    public static func production(rootURL: URL) throws -> Self {
        let identity = LibraryIdentity(rootURL: rootURL)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
        return Self(indexDatabase: storage.indexDatabase)
    }

    public func snapshot() async throws -> SensorProfilesSnapshot {
        let db = try SQLiteDB(readOnlyPath: indexDatabase.standardizedFileURL.path)
        var profiles: [SensorProfileSnapshot] = []
        try db.query(
            """
            SELECT camera,gain,offset,bias_level_adu,read_noise_e,dark_rate_e_per_s,
                   dark_temp_c,egain,measured_at,COALESCE(frame_count,0)
            FROM sensor_profile ORDER BY measured_at DESC,camera COLLATE NOCASE,gain,offset;
            """
        ) { row in
            profiles.append(.init(
                camera: row.string(0) ?? "Unknown camera", gain: row.double(1), offset: row.double(2),
                biasLevelADU: row.double(3), readNoiseElectrons: row.double(4),
                darkRateElectronsPerSecond: row.double(5), darkTemperatureCelsius: row.double(6),
                electronsPerADU: row.double(7), measuredAt: Date(timeIntervalSince1970: row.double(8) ?? 0),
                frameCount: Int(row.int64(9) ?? 0)
            ))
        }
        return .init(profiles: profiles, isReadOnly: true)
    }
}
