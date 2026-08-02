import Foundation

/// Per-session detail roll-up for one target's session date-dir: frame
/// counts by role, integration time and exposure breakdown from the raw
/// session LIGHT frames only (same convention as `TargetStats`), plus the
/// distinct equipment signals (camera, focal length, gain/ISO, sensor temp,
/// filter) those lights were shot with, and whether the session folder has
/// its `README.txt`.
public struct SessionDetail: Codable, Sendable, Equatable {
    public var target: String
    /// Raw date-dir name, verbatim as it appears on disk under
    /// `sessions/<target>/`.
    public var dateRaw: String
    public var lightCount: Int
    public var flatCount: Int
    public var darkCount: Int
    public var biasCount: Int
    /// Sum of the session's light exptimes (seconds); lights with no
    /// exptime contribute 0, same as `TargetStats.totalIntegrationSeconds`.
    public var integrationSeconds: Double
    /// Light-frame count per exposure length, keyed by the exposure's
    /// `Double.description`; frames with no exptime land under `"unknown"`.
    public var exposureBreakdown: [String: Int]
    /// Distinct, sorted `instrume` values across the session's lights.
    public var cameras: [String]
    /// Distinct `focallen` values across the session's lights, rounded to
    /// the nearest 1 mm, sorted ascending.
    public var focalLengthsMM: [Double]
    /// Distinct `gain` (ISO for DSLR frames) values across the session's
    /// lights, sorted ascending.
    public var gains: [Double]
    /// Distinct `setTemp` values across the session's lights, rounded to
    /// the nearest 0.5°C, sorted ascending.
    public var sensorTempsC: [Double]
    /// Distinct, sorted `filter` values across the session's lights.
    public var filters: [String]
    /// Whether the session's date-dir has a `README.txt` on record (a
    /// `kind == "text"` file whose last path component is `README.txt`).
    public var hasReadme: Bool

    public init(
        target: String,
        dateRaw: String,
        lightCount: Int,
        flatCount: Int,
        darkCount: Int,
        biasCount: Int,
        integrationSeconds: Double,
        exposureBreakdown: [String: Int],
        cameras: [String],
        focalLengthsMM: [Double],
        gains: [Double],
        sensorTempsC: [Double],
        filters: [String],
        hasReadme: Bool
    ) {
        self.target = target
        self.dateRaw = dateRaw
        self.lightCount = lightCount
        self.flatCount = flatCount
        self.darkCount = darkCount
        self.biasCount = biasCount
        self.integrationSeconds = integrationSeconds
        self.exposureBreakdown = exposureBreakdown
        self.cameras = cameras
        self.focalLengthsMM = focalLengthsMM
        self.gains = gains
        self.sensorTempsC = sensorTempsC
        self.filters = filters
        self.hasReadme = hasReadme
    }
}

/// Builds `SessionDetail` rows for one target, one per session date-dir.
/// Reads only from `Database` -- never touches the filesystem.
public enum SessionStatsQueries {
    /// Every session date-dir on record for `target`, sorted by `dateRaw`
    /// ascending. `[]` if the target has no `area == .sessions` files at
    /// all (including an unknown target name).
    public static func sessions(target: String, db: Database, config: AstroConfig) throws -> [SessionDetail] {
        let files = try db.allFiles(includeMissing: false)
        let sessionFiles = files.filter { $0.target == target && $0.area == .sessions }
        guard !sessionFiles.isEmpty else { return [] }

        let dates = Set(sessionFiles.compactMap(\.sessionDate)).sorted()
        return try dates.map { date in
            try computeSessionDetail(target: target, date: date, files: sessionFiles, db: db)
        }
    }

    private static func computeSessionDetail(
        target: String,
        date: String,
        files: [FileRecord],
        db: Database
    ) throws -> SessionDetail {
        let dayFiles = files.filter { $0.sessionDate == date }
        let lights = dayFiles.filter { $0.role == .light }
        let flats = dayFiles.filter { $0.role == .flat }
        let darks = dayFiles.filter { $0.role == .dark }
        let biases = dayFiles.filter { $0.role == .bias }
        let hasReadme = dayFiles.contains {
            $0.kind == "text" && ($0.path as NSString).lastPathComponent == "README.txt"
        }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in lights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) {
                metaByFileID[id] = meta
            }
        }

        var totalSeconds: Double = 0
        var exposureBreakdown: [String: Int] = [:]
        var cameras = Set<String>()
        var focalLengths = Set<Double>()
        var gains = Set<Double>()
        var sensorTemps = Set<Double>()
        var filters = Set<String>()

        for file in lights {
            let meta = file.id.flatMap { metaByFileID[$0] }
            if let exptime = meta?.exptime {
                totalSeconds += exptime
                exposureBreakdown[exptime.description, default: 0] += 1
            } else {
                exposureBreakdown["unknown", default: 0] += 1
            }
            if let camera = meta?.instrume { cameras.insert(camera) }
            if let filter = meta?.filter { filters.insert(filter) }
            if let focallen = meta?.focallen { focalLengths.insert(focallen.rounded()) }
            if let gain = meta?.gain { gains.insert(gain) }
            if let setTemp = meta?.setTemp { sensorTemps.insert((setTemp * 2).rounded() / 2) }
        }

        return SessionDetail(
            target: target,
            dateRaw: date,
            lightCount: lights.count,
            flatCount: flats.count,
            darkCount: darks.count,
            biasCount: biases.count,
            integrationSeconds: totalSeconds,
            exposureBreakdown: exposureBreakdown,
            cameras: cameras.sorted(),
            focalLengthsMM: focalLengths.sorted(),
            gains: gains.sorted(),
            sensorTempsC: sensorTemps.sorted(),
            filters: filters.sorted(),
            hasReadme: hasReadme
        )
    }
}
