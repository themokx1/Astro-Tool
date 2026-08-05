import Foundation

/// A rounded (exposure, temperature, gain, offset, camera) combo. Lights are
/// grouped by this both for calibration-coverage analysis
/// (`CalibAnalyzer.lightGroups`) and for per-session dark fallback matching
/// (`SessionMatcher.dominantLibraryDark`) -- sharing one rounding rule keeps
/// "which combo is this light in" answered identically in both places.
///
/// `gain`/`offset`/`camera` are read straight off each file's already-parsed
/// `fits_meta` columns (`gain`, `offset`, `instrume`) -- no extra header
/// parsing needed, unlike a master dir's `xbinning` (see `MasterDir`), which
/// only exists in `header_json` and is deliberately aggregated for masters
/// only (hundreds of files) and never per scanned light (could be
/// thousands).
struct CalibCombo: Hashable {
    var exposureS: Double
    var tempC: Double?
    var gain: Double?
    var offset: Double?
    var camera: String?

    /// Rounds `exptime` via `NominalExposure` (whole seconds at 10s+, 0.1s
    /// below that -- see its own doc comment for why: real acquisition
    /// software reports the same nominal "30s" sub as `30.0` for most
    /// frames and `29.899999618523` for others, and a naive 0.1s-only
    /// rounding still keeps those apart) and `setTemp` to the nearest
    /// 0.5°C -- coarse enough to bucket a camera's own temperature jitter
    /// into the same combo, fine enough to keep genuinely distinct
    /// dark-frame setups apart. `gain`/`offset`/`camera` are taken as-is (a
    /// session's electronic settings don't jitter the way exposure/
    /// temperature do).
    static func rounded(exptime: Double, setTemp: Double?, gain: Double?, offset: Double?, camera: String?) -> CalibCombo {
        CalibCombo(
            exposureS: NominalExposure.nominal(exptime),
            tempC: setTemp.map { ($0 / 0.5).rounded() * 0.5 },
            gain: gain,
            offset: offset,
            camera: camera
        )
    }
}

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
    /// This combo's dominant light `GAIN`, but only populated when a master
    /// existed at the same (exposure, temp) and got rejected on an
    /// electronic dimension (see `mismatchReasons`) -- `nil` whenever
    /// `matchedMasterPath` is set, or when no master matched (exposure,
    /// temp) at all.
    public var requiredGain: Double?
    /// This combo's dominant light `INSTRUME`, populated under the same
    /// condition as `requiredGain`.
    public var requiredCamera: String?
    /// Hungarian reasons a same-(exposure, temp) master was rejected, e.g.
    /// `["gain 0 ≠ 100"]`, `["másik kamera: ZWO ASI2600MC Pro"]` -- empty
    /// unless a coarse (exposure, temp) match existed but failed an enabled
    /// electronic check (`CalibRule.matchGain`/`matchOffset`/`matchBinning`/
    /// `matchCamera`). `matchedMasterPath` stays `nil` whenever this is
    /// non-empty.
    public var mismatchReasons: [String]

    public init(
        kind: FrameRole,
        exposureSeconds: Double,
        tempC: Double?,
        lightCount: Int,
        targets: [String],
        matchedMasterPath: String?,
        masterAgeDays: Int?,
        isStale: Bool,
        todo: String?,
        requiredGain: Double? = nil,
        requiredCamera: String? = nil,
        mismatchReasons: [String] = []
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
        self.requiredGain = requiredGain
        self.requiredCamera = requiredCamera
        self.mismatchReasons = mismatchReasons
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

        let groups = try lightGroups(files: files, db: db, config: config)
        let masters = try masterDirs(files: files, db: db)

        let calib = config.calib
        let staleThresholdDays = calib.darkMaxAgeMonths * 30

        // Ambiguity context for the todo text, computed once over every
        // combo in this batch (not per-row) -- see the real bug this fixes:
        // a light-frame library scanned two representations of the same
        // captures (e.g. a Canon `.CR3` original alongside a converted
        // `.tif` whose header happens to carry a `GAIN`/ISO value the raw
        // file's header didn't), which legitimately produces two distinct
        // `CalibCombo`s at the very same nominal exposure/temp/camera. That
        // split is real (this function must not silently merge rows with
        // different electronic settings), but showing only "822" and "310"
        // side by side with no explanation reads as a bug to a user. Naming
        // the camera/gain in the todo only when it's ACTUALLY ambiguous
        // (rather than always) keeps the common, unambiguous case's
        // wording unchanged.
        let allCameras = Set(groups.keys.compactMap(\.camera))
        let cameraAmbiguous = allCameras.count > 1

        struct ExposureTempCameraKey: Hashable {
            var exposureS: Double
            var tempC: Double?
            var camera: String?
        }
        // `nil` is included alongside real values here (unlike the camera
        // set above) -- the real-world split this guards against is
        // exactly "some frames at this exposure/temp/camera have a GAIN
        // reading and some don't" (e.g. `822` with no GAIN card at all vs.
        // `310` more at `gain == 1600`), not just two different non-nil
        // values.
        var gainsByExposureTempCamera: [ExposureTempCameraKey: Set<Double?>] = [:]
        for key in groups.keys {
            let bucket = ExposureTempCameraKey(exposureS: key.exposureS, tempC: key.tempC, camera: key.camera)
            gainsByExposureTempCamera[bucket, default: []].insert(key.gain)
        }

        var needs: [CalibNeed] = []
        needs.reserveCapacity(groups.count)

        for (key, info) in groups {
            let outcome = findMatch(
                exposureS: key.exposureS,
                tempC: key.tempC,
                gain: key.gain,
                offset: key.offset,
                camera: key.camera,
                masters: Array(masters.values),
                calib: calib
            )

            let matched = outcome.master
            let matchedPath = matched.map { "calibration_library/darks/\($0.dirName)" }
            let ageDays = matched.map { dayCount(fromInstant: $0.newestInstant, to: now) }
            let isStale = matched != nil && (ageDays ?? 0) > staleThresholdDays

            let gainBucket = ExposureTempCameraKey(exposureS: key.exposureS, tempC: key.tempC, camera: key.camera)
            let gainAmbiguous = (gainsByExposureTempCamera[gainBucket]?.count ?? 0) > 1

            let todo = todoString(
                matched: matched,
                exposureS: key.exposureS,
                tempC: key.tempC,
                lightCount: info.count,
                ageDays: ageDays,
                isStale: isStale,
                camera: key.camera,
                gain: key.gain,
                cameraAmbiguous: cameraAmbiguous,
                gainAmbiguous: gainAmbiguous
            )

            let hasMismatch = matched == nil && !outcome.mismatchReasons.isEmpty

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
                    todo: todo,
                    requiredGain: hasMismatch ? key.gain : nil,
                    requiredCamera: hasMismatch ? key.camera : nil,
                    mismatchReasons: outcome.mismatchReasons
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

    /// Finds the `calibration_library/darks/<dir>` (root-relative path)
    /// whose parsed (exposure, temp) matches `exposureS`/`tempC` within
    /// `config.calib` tolerances AND whose aggregated gain/offset/camera
    /// agree with `gain`/`offset`/`camera` on every dimension enabled in
    /// `config.calib` -- the same per-combo matching `coverage()` does
    /// internally, exposed standalone so callers matching a single combo
    /// (e.g. `SessionMatcher`, `CalibLinker`) don't have to re-derive it.
    /// `tempC == nil` matches any master's temperature (a DSLR light with no
    /// cooler telemetry); `gain`/`offset`/`camera == nil` similarly never
    /// fail their respective check (nothing to compare against). Ties among
    /// multiple fully-matching dirs are broken by directory name, same as
    /// `coverage()`. Returns a `nil` path both when no master dir matches at
    /// all, and when a same-(exposure, temp) master exists but fails an
    /// electronic check -- `mismatchReasons` distinguishes the two: empty in
    /// the former case, populated in the latter.
    public static func matchedMasterDarkPath(
        exposureS: Double,
        tempC: Double?,
        gain: Double?,
        offset: Double?,
        camera: String?,
        files: [FileRecord],
        db: Database,
        config: AstroConfig
    ) throws -> (path: String?, mismatchReasons: [String]) {
        let masters = try masterDirs(files: files, db: db)
        let outcome = findMatch(
            exposureS: exposureS,
            tempC: tempC,
            gain: gain,
            offset: offset,
            camera: camera,
            masters: Array(masters.values),
            calib: config.calib
        )
        let path = outcome.master.map { "calibration_library/darks/\($0.dirName)" }
        return (path, outcome.mismatchReasons)
    }

    /// Groups `files`' FITS meta by rounded (exptime, setTemp, gain, offset,
    /// camera) -- via `CalibCombo.rounded` -- and returns the most common
    /// combo. Shared dominant-combo logic used both by `SessionMatcher` (a
    /// session's lights, to find a fallback library dark) and `CalibLinker`
    /// (a session's flats, to find a matching flat-dark). `nil` when none of
    /// `files` has usable exposure meta at all.
    static func dominantCombo(files: [FileRecord], db: Database) throws -> CalibCombo? {
        var counts: [CalibCombo: Int] = [:]

        for file in files {
            guard let fileID = file.id,
                  let meta = try db.fitsMeta(fileID: fileID),
                  let exptime = meta.exptime
            else { continue }

            let key = CalibCombo.rounded(
                exptime: exptime,
                setTemp: meta.setTemp,
                gain: meta.gain,
                offset: meta.offset,
                camera: meta.instrume
            )
            counts[key, default: 0] += 1
        }

        return counts.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Matching

    /// A candidate master dir together with why it was (or wasn't) accepted.
    private struct MatchOutcome {
        var master: MasterDir?
        var mismatchReasons: [String]
    }

    /// Filters `masters` to those within (exposure, temp) tolerance of the
    /// light side (the "coarse" match `coverage()` used to do on its own),
    /// then picks the first (by dir name) that also agrees on every enabled
    /// electronic dimension. When at least one coarse candidate exists but
    /// none of them pass the electronic check, `mismatchReasons` carries the
    /// reasons from the best (first, by dir name) coarse candidate -- same
    /// tie-break `coverage()` always used for picking "the" match.
    private static func findMatch(
        exposureS: Double,
        tempC: Double?,
        gain: Double?,
        offset: Double?,
        camera: String?,
        masters: [MasterDir],
        calib: CalibRule
    ) -> MatchOutcome {
        let exposureTolerance = max(calib.exposureToleranceS, exposureS * calib.exposureToleranceFraction)

        let coarse = masters
            .filter { master in
                abs(master.exposureS - exposureS) <= exposureTolerance
                    && (tempC == nil || abs(master.tempC - tempC!) <= calib.tempToleranceC)
            }
            .sorted { $0.dirName < $1.dirName }

        guard !coarse.isEmpty else { return MatchOutcome(master: nil, mismatchReasons: []) }

        for candidate in coarse {
            let reasons = electronicMismatchReasons(gain: gain, offset: offset, camera: camera, master: candidate, calib: calib)
            if reasons.isEmpty {
                return MatchOutcome(master: candidate, mismatchReasons: [])
            }
        }

        let reasons = electronicMismatchReasons(gain: gain, offset: offset, camera: camera, master: coarse[0], calib: calib)
        return MatchOutcome(master: nil, mismatchReasons: reasons)
    }

    /// Hungarian reasons `master` fails an enabled electronic check against
    /// the light side's gain/offset/camera -- empty when every enabled,
    /// comparable (both sides non-nil) dimension agrees. A dimension whose
    /// check is disabled (`CalibRule.matchGain` etc. `false`), or where
    /// either side has no value at all, never contributes a reason: there's
    /// nothing to safely compare. `binning` is deliberately not a parameter
    /// here -- it's aggregated for masters (`MasterDir.xbinning`) but never
    /// captured per light frame (see `CalibRule.matchBinning`'s doc comment)
    /// so it can never actually differ from an always-absent light value;
    /// the `matchBinning` config flag is still honored the moment a caller
    /// starts passing a real light-side binning through.
    private static func electronicMismatchReasons(
        gain: Double?,
        offset: Double?,
        camera: String?,
        binning: Int? = nil,
        master: MasterDir,
        calib: CalibRule
    ) -> [String] {
        var reasons: [String] = []

        if calib.matchGain, let lightGain = gain, let masterGain = master.gain,
           abs(masterGain - lightGain) > calib.gainTolerance
        {
            reasons.append("gain \(formatted(masterGain)) ≠ \(formatted(lightGain))")
        }

        if calib.matchOffset, let lightOffset = offset, let masterOffset = master.offset,
           lightOffset != masterOffset
        {
            reasons.append("offset \(formatted(masterOffset)) ≠ \(formatted(lightOffset))")
        }

        if calib.matchBinning, let lightBinning = binning, let masterBinning = master.xbinning,
           lightBinning != masterBinning
        {
            reasons.append("bin \(masterBinning) ≠ \(lightBinning)")
        }

        if calib.matchCamera, let lightCamera = camera, let masterCamera = master.instrume,
           lightCamera != masterCamera
        {
            reasons.append("másik kamera: \(masterCamera)")
        }

        return reasons
    }

    // MARK: - Grouping

    private struct GroupInfo {
        var count = 0
        var targets = Set<String>()
    }

    /// Groups scanned session lights by rounded (exptime, setTemp, gain,
    /// offset, camera). Lights with no `fits_meta` row or a nil `exptime`
    /// are skipped entirely -- there's nothing to match a dark against.
    ///
    /// Counts only the DEDUPED, non-rejected frames (`FrameSet.lightBuckets`
    /// -- same source of truth `StatsQueries`/`NightHealth`/`ExposureAdvisor`
    /// use), not every raw `role == .light` row: a physical DSLR shot kept
    /// as both its original `.cr3` and a converted `.tif` used to be counted
    /// TWICE here, inflating `lightCount` (and thus which combos look
    /// "missing" vs. "covered").
    private static func lightGroups(files: [FileRecord], db: Database, config: AstroConfig) throws -> [CalibCombo: GroupInfo] {
        let sessionLights = files.filter { $0.area == .sessions && $0.role == .light }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in sessionLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) {
                metaByFileID[id] = meta
            }
        }

        let usable = FrameSet.lightBuckets(files: sessionLights, meta: metaByFileID, config: config).usable

        var groups: [CalibCombo: GroupInfo] = [:]

        for file in usable {
            guard let id = file.id, let meta = metaByFileID[id], let exptime = meta.exptime else { continue }

            let key = CalibCombo.rounded(
                exptime: exptime,
                setTemp: meta.setTemp,
                gain: meta.gain,
                offset: meta.offset,
                camera: meta.instrume
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
        /// Newest "instant" among the dir's files: each file's parsed
        /// `DATE-OBS` when present, its `mtime` otherwise (a plain copy/
        /// rsync of a master resets `mtime` but never `DATE-OBS`, so this is
        /// the age source of truth whenever it's available at all).
        var newestInstant: Double
        /// Dominant (most common) `GAIN` across the dir's files, `nil` when
        /// none of them has one.
        var gain: Double?
        /// Dominant `OFFSET`, same convention as `gain`.
        var offset: Double?
        /// Dominant `INSTRUME`, same convention as `gain`.
        var instrume: String?
        /// Dominant `XBINNING`, parsed from each file's `header_json` (not a
        /// dedicated `fits_meta` column) -- affordable here because master
        /// dirs hold hundreds of files at most, unlike the scanned light
        /// library.
        var xbinning: Int?
        /// Total file count -- every file contributing to this dir, whether
        /// or not it had a parseable `CCD-TEMP`. Used by `CalibHealth`'s
        /// dark-master-health report (`MasterDirInfo.frameCount`); `coverage()`
        /// itself never needed a raw count before.
        var fileCount: Int
        /// Every file's own `CCD-TEMP` (actual cooler reading, not the
        /// `SET-TEMP` setpoint used for exposure/temp combo matching) --
        /// kept as a raw list (not collapsed to `mode`, unlike gain/offset/
        /// instrume/xbinning) so `CalibHealth` can compute a median and max
        /// deviation across the dir to flag cooler instability.
        var ccdTemps: [Double]
    }

    /// Accumulates one master dir's raw per-file values before they're
    /// collapsed into a `MasterDir`'s dominant values.
    private struct MasterDirBuilder {
        var exposureS: Double
        var tempC: Double
        var dirName: String
        var newestInstant: Double
        var gains: [Double] = []
        var offsets: [Double] = []
        var instrumes: [String] = []
        var xbinnings: [Int] = []
        var fileCount = 0
        var ccdTemps: [Double] = []
    }

    /// Discovers master-dark directories from DB rows: files with
    /// `area == .calibration` and `role == .dark` whose path's directory
    /// component (the 3rd path component, right under
    /// `calibration_library/darks/`) parses via `parseMasterDirName`. A
    /// directory whose name doesn't parse contributes no master (its files
    /// are silently ignored, same as an empty/absent directory). Reads each
    /// file's `fits_meta` row (gain/offset/instrume/date_obs columns, plus
    /// `header_json` for `XBINNING`) to aggregate the dir's electronic
    /// identity and true (DATE-OBS-based) age.
    private static func masterDirs(files: [FileRecord], db: Database) throws -> [String: MasterDir] {
        var builders: [String: MasterDirBuilder] = [:]

        for file in files where file.area == .calibration && file.role == .dark {
            let components = file.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard components.count >= 3 else { continue }
            let dirName = components[2]
            guard let parsed = parseMasterDirName(dirName) else { continue }

            let meta = try file.id.flatMap { try db.fitsMeta(fileID: $0) }
            let instant = meta?.dateObs.flatMap(SessionTimeline.parseDateObs)?.timeIntervalSince1970 ?? file.mtime

            var builder = builders[dirName] ?? MasterDirBuilder(
                exposureS: parsed.exposureS,
                tempC: parsed.tempC,
                dirName: dirName,
                newestInstant: instant
            )
            builder.newestInstant = max(builder.newestInstant, instant)
            builder.fileCount += 1
            if let gain = meta?.gain { builder.gains.append(gain) }
            if let offset = meta?.offset { builder.offsets.append(offset) }
            if let instrume = meta?.instrume { builder.instrumes.append(instrume) }
            if let ccdTemp = meta?.ccdTemp { builder.ccdTemps.append(ccdTemp) }
            if let xbinning = parseXBinning(headerJSON: meta?.headerJSON) { builder.xbinnings.append(xbinning) }
            builders[dirName] = builder
        }

        var masters: [String: MasterDir] = [:]
        for (dirName, builder) in builders {
            masters[dirName] = MasterDir(
                exposureS: builder.exposureS,
                tempC: builder.tempC,
                dirName: dirName,
                newestInstant: builder.newestInstant,
                gain: mode(builder.gains),
                offset: mode(builder.offsets),
                instrume: mode(builder.instrumes),
                xbinning: mode(builder.xbinnings),
                fileCount: builder.fileCount,
                ccdTemps: builder.ccdTemps
            )
        }
        return masters
    }

    // MARK: - R6-1: public master-dir detail (CalibHealth)

    /// Everything `CalibHealth`'s dark-master-health report needs about one
    /// master-dark directory that `coverage()`'s own `CalibNeed` view
    /// doesn't carry: a raw frame count and per-file `CCD-TEMP` readings,
    /// alongside the same `path`/age-source `newestInstant` `coverage()`
    /// already derives. Deliberately NOT the private `MasterDir` itself --
    /// that type also carries matching-only fields (`gain`/`offset`/
    /// `instrume`/`xbinning`) `CalibHealth` has no use for.
    public struct MasterDirInfo: Sendable {
        /// Root-relative path, e.g. `"calibration_library/darks/300sec_-10deg"`.
        public var path: String
        /// Newest "instant" among the dir's files -- see `MasterDir`'s own
        /// doc comment for the DATE-OBS-first, mtime-fallback rule.
        public var newestInstant: Double
        public var frameCount: Int
        public var ccdTemps: [Double]

        public init(path: String, newestInstant: Double, frameCount: Int, ccdTemps: [Double]) {
            self.path = path
            self.newestInstant = newestInstant
            self.frameCount = frameCount
            self.ccdTemps = ccdTemps
        }
    }

    /// Builds `MasterDirInfo` for every discoverable master-dark directory --
    /// same discovery/parsing rule as `coverage()`'s internal `masterDirs`
    /// (reused, not re-derived). Reads only from `db`; never touches the
    /// filesystem.
    public static func masterDirInfos(db: Database) throws -> [MasterDirInfo] {
        let files = try db.allFiles(includeMissing: false)
        let masters = try masterDirs(files: files, db: db)
        return masters.values.map { master in
            MasterDirInfo(
                path: "calibration_library/darks/\(master.dirName)",
                newestInstant: master.newestInstant,
                frameCount: master.fileCount,
                ccdTemps: master.ccdTemps
            )
        }
    }

    /// Parses the `XBINNING` card out of a `fits_meta.header_json` blob
    /// (upserted by the scanner as a flat `[String: String]` keyword->raw
    /// value dump, see `Scanner.fitsMetaRecord`). `nil` when `headerJSON` is
    /// absent, isn't valid JSON, has no `XBINNING` key, or its value isn't
    /// parseable as a number.
    private static func parseXBinning(headerJSON: String?) -> Int? {
        guard let headerJSON, let data = headerJSON.data(using: .utf8),
              let cards = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = cards["XBINNING"]
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let intValue = Int(trimmed) { return intValue }
        return Double(trimmed).map { Int($0) }
    }

    /// The most frequent value in `values`, `nil` when `values` is empty.
    /// Ties are broken arbitrarily (dictionary iteration order) -- in
    /// practice, a real master dir's files share one gain/offset/camera/
    /// binning setting, so this only ever matters for pathological mixed
    /// dirs.
    private static func mode<T: Hashable>(_ values: [T]) -> T? {
        guard !values.isEmpty else { return nil }
        var counts: [T: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    // MARK: - Todo strings

    /// `camera`/`gain` are only ever mentioned in the returned text when
    /// `cameraAmbiguous`/`gainAmbiguous` say there's actually more than one
    /// value for that dimension among this batch's combos -- see
    /// `coverage()`'s own doc comment on why that ambiguity can be real
    /// (not a bug) and still confusing to read without it. `tempC == nil`
    /// always gets its own "(hőmérséklet nélkül)" callout, independent of
    /// the camera/gain flags -- a light with no cooler telemetry at all is
    /// worth flagging regardless of how many cameras/gains are in play.
    private static func todoString(
        matched: MasterDir?,
        exposureS: Double,
        tempC: Double?,
        lightCount: Int,
        ageDays: Int?,
        isStale: Bool,
        camera: String?,
        gain: Double?,
        cameraAmbiguous: Bool,
        gainAmbiguous: Bool
    ) -> String? {
        guard let matched else {
            let expStr = formatted(exposureS)

            var detail = "\(lightCount) light frame-hez"
            if tempC == nil {
                detail += ", hőmérséklet nélkül"
            }
            if cameraAmbiguous, let camera {
                detail += ", kamera: \(camera)"
            }
            if gainAmbiguous, let gain {
                detail += ", gain: \(formatted(gain))"
            }

            if let tempC {
                return "készíts \(expStr) s / \(formatted(tempC)) °C darkot (\(detail))"
            }
            return "készíts \(expStr) s darkot (\(detail))"
        }

        guard isStale, let ageDays else { return nil }
        return "a(z) \(matched.dirName) dark \(ageDays) napos — készíts frisset"
    }

    /// Trims a `Double` to its shortest decimal form for display: `300.0` ->
    /// `"300"`, `6.8` -> `"6.8"`, `-10.0` -> `"-10"`.
    private static func formatted(_ value: Double) -> String {
        String(format: "%g", value)
    }

    private static func dayCount(fromInstant instant: Double, to now: Date) -> Int {
        Int((now.timeIntervalSince1970 - instant) / 86400)
    }

    private static func rank(_ need: CalibNeed) -> Int {
        if need.matchedMasterPath == nil { return 0 } // missing
        if need.isStale { return 1 } // stale
        return 2 // covered + fresh
    }
}
