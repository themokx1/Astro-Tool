import Foundation

/// One session's flat-frame discipline verdict -- for OSC deep-sky the flat
/// is the #1 quality item (it corrects vignetting + sensor dust) and it is
/// NOT transferable between sessions if the optical train rotated, the focal
/// length changed, or dust moved (time gap). This answers "does this
/// session's own flat actually still describe its lights?"
public struct FlatDiscipline: Codable, Sendable, Equatable {
    public var target: String
    public var date: String
    /// One of `"rendben"` (flat present and matches), `"nincs flat"` (no
    /// flat at all for a session with usable lights), or `"flat nem illik"`
    /// (a flat exists but fails at least one check in `reasons`).
    public var status: String
    /// Hungarian reasons the flat was rejected, e.g.
    /// `["gyújtótáv eltér: light 750mm, flat 800mm"]` -- empty whenever
    /// `status` isn't `"flat nem illik"`.
    public var reasons: [String]

    public init(target: String, date: String, status: String, reasons: [String]) {
        self.target = target
        self.date = date
        self.status = status
        self.reasons = reasons
    }
}

/// All bias frames (session-local + `calibration_library/biases/`) sharing
/// one (gain, offset, camera) electronic identity -- v1 bias has no exposure/
/// temp breakdown (see `CalibAnalyzer`'s own doc comment), so this is the
/// finest grouping that makes sense for bias frames.
public struct BiasGroup: Codable, Sendable, Equatable {
    public var gain: Double?
    public var offset: Double?
    public var camera: String?
    public var frameCount: Int
    /// Root-relative directories this group's frames live under (sorted,
    /// distinct), e.g. `["calibration_library/biases",
    /// "sessions/T1/2026-01-10/biases"]`.
    public var locations: [String]

    public init(gain: Double?, offset: Double?, camera: String?, frameCount: Int, locations: [String]) {
        self.gain = gain
        self.offset = offset
        self.camera = camera
        self.frameCount = frameCount
        self.locations = locations
    }
}

/// One master-dark directory's health: age, cooler-temperature stability
/// across its own files, and whether any of today's lights actually still
/// need it.
public struct DarkMasterHealth: Codable, Sendable, Equatable {
    public var path: String
    /// Age (in whole days) of the dir's newest file, DATE-OBS-based (same
    /// convention as `CalibNeed.masterAgeDays`); `nil` only if the dir
    /// somehow contributed no files at all.
    public var ageDays: Int?
    /// `true` when `ageDays` exceeds `CalibRule.darkMaxAgeMonths * 30`.
    public var isStale: Bool
    /// Median `CCD-TEMP` across the dir's files, `nil` when none of them had
    /// one.
    public var tempMedian: Double?
    /// Largest absolute deviation from `tempMedian` among the dir's files --
    /// `nil` under the same condition as `tempMedian`. A cooled CMOS
    /// camera's own set-point wobble is small; a spread past 1.5°C usually
    /// means the cooler struggled (or the dir mixes sessions shot under
    /// different ambient conditions) and its noise profile is less uniform
    /// than a single dark master implies.
    public var tempMaxDeviation: Double?
    public var frameCount: Int
    /// `true` when no current light-combo (`CalibAnalyzer.coverage()`'s own
    /// matching) actually matched this master -- an orphan nobody needs
    /// anymore.
    public var isUnused: Bool
    /// Hungarian warnings, e.g. `["instabil hőmérséklet"]`, `["nem használt"]`
    /// -- both may be present at once.
    public var warnings: [String]

    public init(
        path: String,
        ageDays: Int?,
        isStale: Bool,
        tempMedian: Double?,
        tempMaxDeviation: Double?,
        frameCount: Int,
        isUnused: Bool,
        warnings: [String]
    ) {
        self.path = path
        self.ageDays = ageDays
        self.isStale = isStale
        self.tempMedian = tempMedian
        self.tempMaxDeviation = tempMaxDeviation
        self.frameCount = frameCount
        self.isUnused = isUnused
        self.warnings = warnings
    }
}

/// The full calibration-health report: flat discipline per session, the
/// whole library's bias inventory (+ which used light-combos have no bias
/// at all), and per-master-dir dark health.
public struct CalibHealthReport: Codable, Sendable, Equatable {
    public var flats: [FlatDiscipline]
    public var biasGroups: [BiasGroup]
    public var missingBiasCombos: [String]
    public var darkMasters: [DarkMasterHealth]

    public init(flats: [FlatDiscipline], biasGroups: [BiasGroup], missingBiasCombos: [String], darkMasters: [DarkMasterHealth]) {
        self.flats = flats
        self.biasGroups = biasGroups
        self.missingBiasCombos = missingBiasCombos
        self.darkMasters = darkMasters
    }
}

/// Builds the `CalibHealthReport` (R6-1): flat discipline, bias inventory,
/// dark-master health. Reuses `FrameSet` (usable-light dedup),
/// `CalibAnalyzer.coverage`/`masterDirInfos` (master matching/detail), and
/// `SessionTimeline.parseDateObs` (DATE-OBS parsing) rather than
/// re-deriving any of that. Read-only against `db`; never touches the
/// filesystem.
public enum CalibHealth {
    public static func report(db: Database, config: AstroConfig, now: Date = Date()) throws -> CalibHealthReport {
        let files = try db.allFiles(includeMissing: false)
        let calib = config.calib

        var sessionKeys = Set<SessionKey>()
        for file in files where file.area == .sessions {
            guard let target = file.target, let date = file.sessionDate else { continue }
            sessionKeys.insert(SessionKey(target: target, date: date))
        }

        var flats: [FlatDiscipline] = []
        var usedBiasKeys = Set<BiasKey>()

        for key in sessionKeys.sorted(by: { ($0.target, $0.date) < ($1.target, $1.date) }) {
            let sessionFiles = files.filter { $0.area == .sessions && $0.target == key.target && $0.sessionDate == key.date }
            let lightFiles = sessionFiles.filter { $0.role == .light }

            var lightMetaByID: [Int64: FITSMetaRecord] = [:]
            for file in lightFiles {
                guard let id = file.id, let meta = try db.fitsMeta(fileID: id) else { continue }
                lightMetaByID[id] = meta
            }

            let buckets = FrameSet.lightBuckets(files: lightFiles, meta: lightMetaByID, config: config)
            guard !buckets.usable.isEmpty else { continue }

            let usableLightMetas = buckets.usable.compactMap { $0.id.flatMap { lightMetaByID[$0] } }

            for meta in usableLightMetas {
                let key = BiasKey(gain: meta.gain, offset: meta.offset, camera: meta.instrume)
                guard key.gain != nil || key.offset != nil || key.camera != nil else { continue }
                usedBiasKeys.insert(key)
            }

            let flatFiles = sessionFiles.filter { $0.role == .flat }
            guard !flatFiles.isEmpty else {
                flats.append(FlatDiscipline(target: key.target, date: key.date, status: "nincs flat", reasons: []))
                continue
            }

            var flatMetas: [FITSMetaRecord] = []
            for file in flatFiles {
                guard let id = file.id, let meta = try db.fitsMeta(fileID: id) else { continue }
                flatMetas.append(meta)
            }

            let reasons = flatMismatchReasons(lightMetas: usableLightMetas, flatMetas: flatMetas, calib: calib)
            flats.append(
                FlatDiscipline(
                    target: key.target,
                    date: key.date,
                    status: reasons.isEmpty ? "rendben" : "flat nem illik",
                    reasons: reasons
                )
            )
        }

        // (b) Bias inventory -- ALL bias frames (sessions + calibration_library).
        var groupEntries: [BiasKey: (count: Int, locations: Set<String>)] = [:]
        for file in files where file.role == .bias {
            guard let id = file.id, let meta = try db.fitsMeta(fileID: id) else { continue }
            let key = BiasKey(gain: meta.gain, offset: meta.offset, camera: meta.instrume)
            var entry = groupEntries[key] ?? (count: 0, locations: [])
            entry.count += 1
            entry.locations.insert(parentDir(file.path))
            groupEntries[key] = entry
        }

        let biasGroups = groupEntries.map { key, entry in
            BiasGroup(gain: key.gain, offset: key.offset, camera: key.camera, frameCount: entry.count, locations: entry.locations.sorted())
        }.sorted { comboLabel($0.gain, $0.offset, $0.camera) < comboLabel($1.gain, $1.offset, $1.camera) }

        let existingBiasKeys = Set(groupEntries.keys)
        let missingBiasCombos = usedBiasKeys
            .filter { !existingBiasKeys.contains($0) }
            .map { "nincs bias: \(comboLabel($0.gain, $0.offset, $0.camera))" }
            .sorted()

        // (c) Dark master health.
        let coverage = try CalibAnalyzer.coverage(db: db, config: config, now: now)
        let matchedPaths = Set(coverage.compactMap(\.matchedMasterPath))
        let masterInfos = try CalibAnalyzer.masterDirInfos(db: db)

        let darkMasters = masterInfos.map { info -> DarkMasterHealth in
            let ageDays = dayCount(fromInstant: info.newestInstant, to: now)
            let isStale = ageDays > calib.darkMaxAgeMonths * 30
            let (median, maxDeviation) = temperatureStats(info.ccdTemps)

            var warnings: [String] = []
            if let maxDeviation, maxDeviation > 1.5 {
                warnings.append("instabil hőmérséklet")
            }
            let isUnused = !matchedPaths.contains(info.path)
            if isUnused {
                warnings.append("nem használt")
            }

            return DarkMasterHealth(
                path: info.path,
                ageDays: ageDays,
                isStale: isStale,
                tempMedian: median,
                tempMaxDeviation: maxDeviation,
                frameCount: info.frameCount,
                isUnused: isUnused,
                warnings: warnings
            )
        }.sorted { $0.path < $1.path }

        return CalibHealthReport(flats: flats, biasGroups: biasGroups, missingBiasCombos: missingBiasCombos, darkMasters: darkMasters)
    }

    // MARK: - Keys

    private struct SessionKey: Hashable {
        var target: String
        var date: String
    }

    /// A bias frame's electronic identity -- deliberately NOT the rounded
    /// `CalibCombo` (which also carries exposure/temperature, meaningless
    /// for bias frames): grouped on gain/offset/camera exactly as read from
    /// `fits_meta`, no rounding, since a session's own electronic settings
    /// don't jitter the way exposure/temperature do.
    private struct BiasKey: Hashable {
        var gain: Double?
        var offset: Double?
        var camera: String?
    }

    // MARK: - Flat discipline matching

    /// Hungarian reasons a session's own flats fail to describe its usable
    /// lights: focal length (±2mm), filter, `ROTATOR` header angle (beyond
    /// `calib.rotatorToleranceDeg`, only when both sides have one), and
    /// capture-time gap (beyond `calib.flatMaxAgeDays`, DATE-OBS both
    /// sides). Each dimension is independent -- a session can fail more than
    /// one at once.
    private static func flatMismatchReasons(lightMetas: [FITSMetaRecord], flatMetas: [FITSMetaRecord], calib: CalibRule) -> [String] {
        var reasons: [String] = []

        let lightFocal = dominantValue(lightMetas.compactMap(\.focallen))
        let flatFocal = dominantValue(flatMetas.compactMap(\.focallen))
        if let lightFocal, let flatFocal, abs(lightFocal - flatFocal) > 2.0 {
            reasons.append("gyújtótáv eltér: light \(formatted(lightFocal))mm, flat \(formatted(flatFocal))mm")
        }

        let lightFilter = dominantValue(lightMetas.compactMap(\.filter))
        let flatFilter = dominantValue(flatMetas.compactMap(\.filter))
        if let lightFilter, let flatFilter, lightFilter != flatFilter {
            reasons.append("szűrő eltér: light \(lightFilter), flat \(flatFilter)")
        }

        let lightRotator = dominantValue(lightMetas.compactMap { parseRotator(headerJSON: $0.headerJSON) })
        let flatRotator = dominantValue(flatMetas.compactMap { parseRotator(headerJSON: $0.headerJSON) })
        if let lightRotator, let flatRotator, abs(lightRotator - flatRotator) > calib.rotatorToleranceDeg {
            reasons.append("rotátor-szög eltér: light \(formatted(lightRotator))°, flat \(formatted(flatRotator))°")
        }

        let lightInstant = medianInstant(lightMetas.compactMap { $0.dateObs.flatMap(SessionTimeline.parseDateObs)?.timeIntervalSince1970 })
        let flatInstant = medianInstant(flatMetas.compactMap { $0.dateObs.flatMap(SessionTimeline.parseDateObs)?.timeIntervalSince1970 })
        if let lightInstant, let flatInstant {
            let ageDays = Int(abs(lightInstant - flatInstant) / 86400)
            if ageDays > calib.flatMaxAgeDays {
                reasons.append("flat kora: \(ageDays) nap (limit \(calib.flatMaxAgeDays) nap)")
            }
        }

        return reasons
    }

    /// The `ROTATOR` FITS card, parsed from a `fits_meta.header_json` blob --
    /// same convention as `CalibAnalyzer`'s own `XBINNING` parse (not a
    /// dedicated `fits_meta` column, so read straight off the raw
    /// keyword->string dump the scanner upserts). `nil` when `headerJSON` is
    /// absent, isn't valid JSON, has no `ROTATOR` key, or its value isn't a
    /// parseable number.
    private static func parseRotator(headerJSON: String?) -> Double? {
        guard let headerJSON, let data = headerJSON.data(using: .utf8),
              let cards = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = cards["ROTATOR"]
        else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespaces))
    }

    /// The most frequent value in `values`, `nil` when `values` is empty --
    /// same tie-break convention as `CalibAnalyzer.mode` (dictionary
    /// iteration order on ties; in practice a session's own frames share one
    /// focal length/filter/rotator angle).
    private static func dominantValue<T: Hashable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        var counts: [T: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private static func medianInstant(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - Dark master temperature stats

    /// Median `CCD-TEMP` and largest absolute deviation from it across one
    /// master dir's files -- `(nil, nil)` when `values` is empty.
    private static func temperatureStats(_ values: [Double]) -> (median: Double?, maxDeviation: Double?) {
        guard !values.isEmpty else { return (nil, nil) }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        let maxDeviation = values.map { abs($0 - median) }.max()
        return (median, maxDeviation)
    }

    private static func dayCount(fromInstant instant: Double, to now: Date) -> Int {
        Int((now.timeIntervalSince1970 - instant) / 86400)
    }

    // MARK: - Formatting

    private static func parentDir(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// `"gain100/offset50/ZWO ASI2600MC Pro"` -- omits any segment whose
    /// value is `nil` (e.g. a DSLR combo with no offset reads just
    /// `"gain800/Canon EOS Ra"`).
    private static func comboLabel(_ gain: Double?, _ offset: Double?, _ camera: String?) -> String {
        var parts: [String] = []
        if let gain { parts.append("gain\(formatted(gain))") }
        if let offset { parts.append("offset\(formatted(offset))") }
        if let camera { parts.append(camera) }
        return parts.joined(separator: "/")
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
