import Foundation

/// One (exposure, temperature) combination of dark frames actually needed by
/// scanned session lights, and whether the calibration library already
/// covers it with a fresh master.
public struct CalibNeed: Codable, Sendable, Equatable {
    public var kind: FrameRole
    public var exposureSeconds: Double
    public var tempC: Double?
    public var lightCount: Int
    /// Sorted, distinct targets whose lights need this combo.
    public var targets: [String]
    /// Directory path of the matched master, e.g.
    /// `"calibration_library/darks/300sec_-10deg"` -- `nil` when no master
    /// covers this combo at all.
    public var matchedMasterPath: String?
    /// Age (in whole days) of the newest file inside `matchedMasterPath`,
    /// `nil` when there's no match.
    public var masterAgeDays: Int?
    /// `true` when matched but `masterAgeDays` exceeds
    /// `CalibRule.darkMaxAgeMonths * 30`.
    public var isStale: Bool
    /// Hungarian todo string: `nil` when the combo is covered by a fresh
    /// master, otherwise a "go create/refresh this" instruction.
    public var todo: String?

    public init(
        kind: FrameRole,
        exposureSeconds: Double,
        tempC: Double?,
        lightCount: Int,
        targets: [String],
        matchedMasterPath: String?,
        masterAgeDays: Int?,
        isStale: Bool,
        todo: String?
    ) {
        self.kind = kind
        self.exposureSeconds = exposureSeconds
        self.tempC = tempC
        self.lightCount = lightCount
        self.targets = targets
        self.matchedMasterPath = matchedMasterPath
        self.masterAgeDays = masterAgeDays
        self.isStale = isStale
        self.todo = todo
    }
}

/// Compares session lights against the on-disk `calibration_library/darks/`
/// masters and produces a per-combo coverage report with ready-to-show
/// Hungarian todo strings.
///
/// v1 scope: only DARKS are analyzed. `calibration_library/flats/` and
/// `calibration_library/biases/` have no exposure/temperature subdirectory
/// breakdown on disk today (see the top-level design doc), so there is no
/// (exposure, temp) combo to match a light against for those roles yet --
/// that's left for a future task once the library layout grows per-exposure
/// / per-temp subdirs for flats/biases too.
public enum CalibAnalyzer {
    /// Parses a master-dark directory name of the form `<exp>sec_<temp>deg`
    /// (e.g. `"60sec_-10deg"`, `"6.8sec_-10deg"`, `"300sec_0deg"`) into its
    /// exposure (seconds) and set-temperature (°C). `exp` and `temp` are both
    /// parsed as `Double`, so fractional exposures and signed temperatures
    /// are supported. Returns `nil` for anything that doesn't match this
    /// exact grammar (e.g. `"60sec"`, `"sec_deg"`, `"60s_-10deg"`).
    public static func parseMasterDirName(_ name: String) -> (exposureS: Double, tempC: Double)? {
        guard let secRange = name.range(of: "sec_"), name.hasSuffix("deg") else { return nil }

        let expPart = name[name.startIndex..<secRange.lowerBound]
        let tempStart = secRange.upperBound
        let tempEnd = name.index(name.endIndex, offsetBy: -3)
        guard tempStart <= tempEnd else { return nil }
        let tempPart = name[tempStart..<tempEnd]

        guard !expPart.isEmpty, !tempPart.isEmpty,
              let exposureS = Double(expPart), let tempC = Double(tempPart)
        else { return nil }

        return (exposureS, tempC)
    }

    /// Builds the coverage report. Reads only from `db` (`allFiles`/
    /// `fitsMeta`) -- never touches the filesystem.
    public static func coverage(db: Database, config: AstroConfig, now: Date = Date()) throws -> [CalibNeed] {
        let files = try db.allFiles(includeMissing: false)

        let groups = try lightGroups(files: files, db: db)
        let masters = masterDirs(files: files)

        let calib = config.calib
        let staleThresholdDays = calib.darkMaxAgeMonths * 30

        var needs: [CalibNeed] = []
        needs.reserveCapacity(groups.count)

        for (key, info) in groups {
            let candidates = masters.values
                .filter { master in
                    abs(master.exposureS - key.exposureS) <= calib.exposureToleranceS
                        && (key.tempC == nil || abs(master.tempC - key.tempC!) <= calib.tempToleranceC)
                }
                .sorted { $0.dirName < $1.dirName }

            let matched = candidates.first
            let matchedPath = matched.map { "calibration_library/darks/\($0.dirName)" }
            let ageDays = matched.map { dayCount(from: $0.newestMtime, to: now) }
            let isStale = matched != nil && (ageDays ?? 0) > staleThresholdDays

            let todo = todoString(
                matched: matched,
                exposureS: key.exposureS,
                tempC: key.tempC,
                lightCount: info.count,
                ageDays: ageDays,
                isStale: isStale
            )

            needs.append(
                CalibNeed(
                    kind: .dark,
                    exposureSeconds: key.exposureS,
                    tempC: key.tempC,
                    lightCount: info.count,
                    targets: info.targets.sorted(),
                    matchedMasterPath: matchedPath,
                    masterAgeDays: ageDays,
                    isStale: isStale,
                    todo: todo
                )
            )
        }

        return needs.sorted { a, b in
            let rankA = rank(a)
            let rankB = rank(b)
            if rankA != rankB { return rankA < rankB }
            return a.exposureSeconds > b.exposureSeconds
        }
    }

    // MARK: - Grouping

    private struct GroupKey: Hashable {
        var exposureS: Double
        var tempC: Double?
    }

    private struct GroupInfo {
        var count = 0
        var targets = Set<String>()
    }

    /// Groups scanned session lights by rounded (exptime, setTemp). Lights
    /// with no `fits_meta` row or a nil `exptime` are skipped entirely --
    /// there's nothing to match a dark against.
    private static func lightGroups(files: [FileRecord], db: Database) throws -> [GroupKey: GroupInfo] {
        var groups: [GroupKey: GroupInfo] = [:]

        for file in files where file.area == .sessions && file.role == .light {
            guard let id = file.id,
                  let meta = try db.fitsMeta(fileID: id),
                  let exptime = meta.exptime
            else { continue }

            let key = GroupKey(
                exposureS: (exptime * 10).rounded() / 10,
                tempC: meta.setTemp.map { ($0 / 0.5).rounded() * 0.5 }
            )

            var info = groups[key] ?? GroupInfo()
            info.count += 1
            if let target = file.target {
                info.targets.insert(target)
            }
            groups[key] = info
        }

        return groups
    }

    // MARK: - Master dirs

    private struct MasterDir {
        var exposureS: Double
        var tempC: Double
        var dirName: String
        var newestMtime: Double
    }

    /// Discovers master-dark directories from DB rows: files with
    /// `area == .calibration` and `role == .dark` whose path's directory
    /// component (the 3rd path component, right under
    /// `calibration_library/darks/`) parses via `parseMasterDirName`. A
    /// directory whose name doesn't parse contributes no master (its files
    /// are silently ignored, same as an empty/absent directory).
    private static func masterDirs(files: [FileRecord]) -> [String: MasterDir] {
        var masters: [String: MasterDir] = [:]

        for file in files where file.area == .calibration && file.role == .dark {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard components.count >= 3 else { continue }
            let dirName = components[2]
            guard let parsed = parseMasterDirName(dirName) else { continue }

            if var existing = masters[dirName] {
                existing.newestMtime = max(existing.newestMtime, file.mtime)
                masters[dirName] = existing
            } else {
                masters[dirName] = MasterDir(
                    exposureS: parsed.exposureS,
                    tempC: parsed.tempC,
                    dirName: dirName,
                    newestMtime: file.mtime
                )
            }
        }

        return masters
    }

    // MARK: - Todo strings

    private static func todoString(
        matched: MasterDir?,
        exposureS: Double,
        tempC: Double?,
        lightCount: Int,
        ageDays: Int?,
        isStale: Bool
    ) -> String? {
        guard let matched else {
            let expStr = formatted(exposureS)
            if let tempC {
                return "készíts \(expStr) s / \(formatted(tempC)) °C darkot (\(lightCount) light frame-hez)"
            }
            return "készíts \(expStr) s darkot (\(lightCount) light frame-hez)"
        }

        guard isStale, let ageDays else { return nil }
        return "a(z) \(matched.dirName) dark \(ageDays) napos — készíts frisset"
    }

    /// Trims a `Double` to its shortest decimal form for display: `300.0` ->
    /// `"300"`, `6.8` -> `"6.8"`, `-10.0` -> `"-10"`.
    private static func formatted(_ value: Double) -> String {
        String(format: "%g", value)
    }

    private static func dayCount(from mtime: Double, to now: Date) -> Int {
        Int((now.timeIntervalSince1970 - mtime) / 86400)
    }

    private static func rank(_ need: CalibNeed) -> Int {
        if need.matchedMasterPath == nil { return 0 } // missing
        if need.isStale { return 1 } // stale
        return 2 // covered + fresh
    }
}
