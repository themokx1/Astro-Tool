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
    /// Sorted, distinct target/date sessions affected by this exact need.
    /// Legacy JSON predating R12-U5 decodes this as an empty list.
    public var sessions: [ScanSummary.SessionKey]
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
    /// R11-T16/F17: the FILTER this need's coverage is keyed on -- always
    /// `nil` for `kind == .dark` (darks have no filter dimension; the
    /// coverage table shows `TDFormat.missingCell` for those rows), and for
    /// `kind == .flat` either the dominant raw FITS `FILTER` value across
    /// the affected lights, or `nil` for a filterless (OSC/DSLR) group.
    public var filter: String?

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
        mismatchReasons: [String] = [],
        filter: String? = nil,
        sessions: [ScanSummary.SessionKey] = []
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
        self.filter = filter
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case kind, exposureSeconds, tempC, lightCount, targets, sessions
        case matchedMasterPath, masterAgeDays, isStale, todo, requiredGain
        case requiredCamera, mismatchReasons, filter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(FrameRole.self, forKey: .kind)
        exposureSeconds = try c.decode(Double.self, forKey: .exposureSeconds)
        tempC = try c.decodeIfPresent(Double.self, forKey: .tempC)
        lightCount = try c.decode(Int.self, forKey: .lightCount)
        targets = try c.decode([String].self, forKey: .targets)
        sessions = try c.decodeIfPresent([ScanSummary.SessionKey].self, forKey: .sessions) ?? []
        matchedMasterPath = try c.decodeIfPresent(String.self, forKey: .matchedMasterPath)
        masterAgeDays = try c.decodeIfPresent(Int.self, forKey: .masterAgeDays)
        isStale = try c.decode(Bool.self, forKey: .isStale)
        todo = try c.decodeIfPresent(String.self, forKey: .todo)
        requiredGain = try c.decodeIfPresent(Double.self, forKey: .requiredGain)
        requiredCamera = try c.decodeIfPresent(String.self, forKey: .requiredCamera)
        mismatchReasons = try c.decodeIfPresent([String].self, forKey: .mismatchReasons) ?? []
        filter = try c.decodeIfPresent(String.self, forKey: .filter)
    }
}

/// Compares session lights against the on-disk `calibration_library/darks/`
/// masters and produces a per-combo coverage report with ready-to-show
/// Hungarian todo strings.
///
/// v1 scope (`coverage()` itself): only DARKS are analyzed. `calibration_
/// library/biases/` still has no exposure/temperature subdirectory
/// breakdown on disk today (see the top-level design doc), so there is no
/// (exposure, temp) combo to match a light against for that role yet.
///
/// R11-T16/F17 added a SEPARATE `flatCoverage()` (kind == `.flat`
/// `CalibNeed`s) for flats -- a filter-keyed coverage report, not an
/// (exposure, temp) one, since flats' own shared pool
/// (`calibration_library/flats/`) has no subdirectory breakdown either, and
/// a flat's relevant "match" dimension is FILTER (+FOCALLEN), not exposure/
/// temperature. Kept as its own function (not merged into `coverage()`)
/// deliberately: `coverage()` has ~25 existing callers/tests that assert
/// dark-only counts/rows, and darks vs. flats have genuinely different
/// matching rules (a flat can ALSO be covered by the session's own local
/// `flats/` folder, always "fresh" to that session -- a dark never has that
/// per-session fallback inside this analyzer). Callers that want ONE merged
/// list for display (`AppState.loadCalibBundle`, the CLI's plain `calib`)
/// simply concatenate both.
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
                    mismatchReasons: outcome.mismatchReasons,
                    sessions: info.sessions.sorted { ($0.date, $0.target) < ($1.date, $1.target) }
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
        var sessions = Set<ScanSummary.SessionKey>()
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
                if let date = file.sessionDate {
                    info.sessions.insert(.init(target: target, date: date))
                }
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
                return "Készíts \(expStr) s / \(formatted(tempC)) °C darkot (\(detail))"
            }
            return "Készíts \(expStr) s darkot (\(detail))"
        }

        guard isStale, let ageDays else { return nil }
        return "Készíts friss \(matched.dirName) darkot (a jelenlegi \(ageDays) napos)"
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

    // MARK: - R11-T16/F17: flat coverage

    /// One (session, filter) cell: usable session lights sharing one
    /// normalized FILTER value (case-insensitive, trimmed; `nil` for a light
    /// with no `FILTER` header at all -- OSC/DSLR), plus what `evaluateFlat
    /// Coverage` needs to judge whether a flat actually covers them.
    private struct FlatCell {
        var target: String
        var date: String
        var filterKey: String?
        /// Original-case FILTER text for display (the dominant raw value
        /// among this cell's lights) -- `nil` exactly when `filterKey` is.
        var filterDisplay: String?
        var lightCount: Int
        var focalLenMM: Double?
        /// Median DATE-OBS instant among this cell's lights, `nil` when none
        /// parsed -- nothing to compare a library flat's own age against
        /// then (same "nothing to compare" convention as `CalibRule`'s other
        /// tolerances).
        var medianInstant: Double?
    }

    /// The pooled `calibration_library/flats/` frames sharing one normalized
    /// filter -- v1 has no per-filter subdirectory breakdown on disk for
    /// flats (same as biases; see this file's own top-level doc comment), so
    /// this is the finest grouping available for library flats.
    private struct FlatPool {
        var focalLenMM: Double?
        var medianInstant: Double?
    }

    private enum FlatCoverageStatus {
        /// `ageDays` is `nil` for a session's own flat (always "fresh" to
        /// its own session -- dust/rotation can't have moved in the time
        /// between a session's own lights and its own flats) OR a library
        /// flat with nothing to compare its date against.
        case fresh(path: String, ageDays: Int?)
        case stale(path: String, ageDays: Int)
        case missing
    }

    private struct FlatCoverageResult {
        var status: FlatCoverageStatus
        var mismatchReasons: [String]
    }

    /// One evaluated `FlatCell` -- shared shape between `flatCoverage(db:
    /// config:)`'s per-session-per-filter loop and `buildFlatNeed`'s own
    /// aggregation, so the latter doesn't need a second, tuple-typed
    /// parameter shape.
    private struct FlatCellResult {
        var cell: FlatCell
        var result: FlatCoverageResult
    }

    private static func flatRank(_ status: FlatCoverageStatus) -> Int {
        switch status {
        case .missing: return 0
        case .stale: return 1
        case .fresh: return 2
        }
    }

    /// Normalizes a raw FITS `FILTER` value for matching: trimmed and
    /// lower-cased, `nil` for `nil`/blank (an OSC/DSLR light with no filter
    /// wheel at all) -- two differently-cased spellings of the same filter
    /// (`"Ha"` vs. `"HA"`) must land in the same cell/pool, and a blank
    /// string must be treated exactly like a missing header, not its own
    /// bogus "filter" group.
    private static func normalizedFilterKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// Same phrasing `CalibHealth.flatMismatchReasons` uses for its own
    /// per-session focal-length check -- kept textually identical so a user
    /// never sees two different wordings for the same underlying problem.
    private static func focalMismatchReason(lightFocal: Double, flatFocal: Double) -> String {
        "gyújtótáv eltér: light \(formatted(lightFocal))mm, flat \(formatted(flatFocal))mm"
    }

    private static func medianInstant(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Judges one `FlatCell` against its session's own matching flats (own
    /// `sessionFlatMetas`, filtered by the caller to the cell's own
    /// `filterKey` already) and the shared library pool for that same
    /// filter. Session-own coverage is tried FIRST (it's always "fresh");
    /// the library pool is only consulted when the session has none of its
    /// own for this filter, OR its own fails the FOCALLEN check -- matching
    /// `findMatch`'s own "coarse match, then reject on a secondary
    /// dimension" shape for darks, just with FILTER as the coarse key and
    /// FOCALLEN as the secondary one instead of (exposure, temp) + gain/
    /// offset/camera.
    private static func evaluateFlatCoverage(
        cell: FlatCell,
        sessionFlatMetas: [FITSMetaRecord],
        libraryPool: FlatPool?,
        calib: CalibRule,
        sessionFlatsPath: String
    ) -> FlatCoverageResult {
        var reasons: [String] = []

        if !sessionFlatMetas.isEmpty {
            let flatFocal = mode(sessionFlatMetas.compactMap(\.focallen))
            if let lightFocal = cell.focalLenMM, let flatFocal, abs(lightFocal - flatFocal) > 2.0 {
                reasons.append(focalMismatchReason(lightFocal: lightFocal, flatFocal: flatFocal))
            } else {
                return FlatCoverageResult(status: .fresh(path: sessionFlatsPath, ageDays: nil), mismatchReasons: [])
            }
        }

        if let libraryPool {
            if let lightFocal = cell.focalLenMM, let flatFocal = libraryPool.focalLenMM, abs(lightFocal - flatFocal) > 2.0 {
                reasons.append(focalMismatchReason(lightFocal: lightFocal, flatFocal: flatFocal))
            } else if let lightInstant = cell.medianInstant, let poolInstant = libraryPool.medianInstant {
                let ageDays = Int(abs(lightInstant - poolInstant) / 86400)
                if ageDays > calib.flatMaxAgeDays {
                    return FlatCoverageResult(status: .stale(path: "calibration_library/flats", ageDays: ageDays), mismatchReasons: [])
                }
                return FlatCoverageResult(status: .fresh(path: "calibration_library/flats", ageDays: ageDays), mismatchReasons: [])
            } else {
                // Nothing to compare either side's date against -- same
                // "nothing to compare never rejects" rule the electronic
                // dimensions above already follow.
                return FlatCoverageResult(status: .fresh(path: "calibration_library/flats", ageDays: nil), mismatchReasons: [])
            }
        }

        return FlatCoverageResult(status: .missing, mismatchReasons: reasons)
    }

    /// Builds the `calibration_library/flats/` pools, one per normalized
    /// filter -- shared by `flatCoverage(db:config:)` (the library-wide
    /// aggregate) and `flatCoverage(target:date:files:db:config:)` (a single
    /// session's view), so both answer "is there a library flat for this
    /// filter" against the exact same underlying data.
    private static func libraryFlatPools(files: [FileRecord], db: Database) throws -> [String?: FlatPool] {
        var focalLensByKey: [String?: [Double]] = [:]
        var instantsByKey: [String?: [Double]] = [:]

        for file in files where file.area == .calibration && file.role == .flat {
            guard let id = file.id, let meta = try db.fitsMeta(fileID: id) else { continue }
            let key = normalizedFilterKey(meta.filter)
            if let focallen = meta.focallen { focalLensByKey[key, default: []].append(focallen) }
            if let instant = meta.dateObs.flatMap(SessionTimeline.parseDateObs)?.timeIntervalSince1970 {
                instantsByKey[key, default: []].append(instant)
            }
        }

        var pools: [String?: FlatPool] = [:]
        for key in Set(focalLensByKey.keys).union(instantsByKey.keys) {
            pools[key] = FlatPool(
                focalLenMM: mode(focalLensByKey[key] ?? []),
                medianInstant: medianInstant(instantsByKey[key] ?? [])
            )
        }
        return pools
    }

    /// This session's own usable lights, grouped into `FlatCell`s by
    /// normalized filter -- shared by both flat-coverage entry points below.
    private static func flatCells(
        target: String,
        date: String,
        sessionFiles: [FileRecord],
        db: Database,
        config: AstroConfig
    ) throws -> [FlatCell] {
        let lightFiles = sessionFiles.filter { $0.role == .light }
        guard !lightFiles.isEmpty else { return [] }

        var lightMetaByID: [Int64: FITSMetaRecord] = [:]
        for file in lightFiles {
            guard let id = file.id, let meta = try db.fitsMeta(fileID: id) else { continue }
            lightMetaByID[id] = meta
        }
        let usableLights = FrameSet.lightBuckets(files: lightFiles, meta: lightMetaByID, config: config).usable
        guard !usableLights.isEmpty else { return [] }

        struct CellBuilder {
            var count = 0
            var focalLens: [Double] = []
            var instants: [Double] = []
            var displays: [String] = []
        }
        var builders: [String?: CellBuilder] = [:]
        for file in usableLights {
            guard let id = file.id, let meta = lightMetaByID[id] else { continue }
            let filterKey = normalizedFilterKey(meta.filter)
            var builder = builders[filterKey] ?? CellBuilder()
            builder.count += 1
            if let focallen = meta.focallen { builder.focalLens.append(focallen) }
            if let instant = meta.dateObs.flatMap(SessionTimeline.parseDateObs)?.timeIntervalSince1970 {
                builder.instants.append(instant)
            }
            if let filter = meta.filter { builder.displays.append(filter) }
            builders[filterKey] = builder
        }

        return builders.map { filterKey, builder in
            FlatCell(
                target: target,
                date: date,
                filterKey: filterKey,
                filterDisplay: mode(builder.displays),
                lightCount: builder.count,
                focalLenMM: mode(builder.focalLens),
                medianInstant: medianInstant(builder.instants)
            )
        }
    }

    /// This session's own flat metas, grouped by normalized filter.
    private static func sessionFlatMetasByFilterKey(sessionFiles: [FileRecord], db: Database) throws -> [String?: [FITSMetaRecord]] {
        var result: [String?: [FITSMetaRecord]] = [:]
        for file in sessionFiles where file.role == .flat {
            guard let id = file.id, let meta = try db.fitsMeta(fileID: id) else { continue }
            result[normalizedFilterKey(meta.filter), default: []].append(meta)
        }
        return result
    }

    /// Per-filter flat coverage for ONE session (target/date) -- the
    /// TargetDetail Áttekintés kalibráció-kártya's per-session "flat: Ha ✓ ·
    /// OIII —" line (`SessionMatcher.match`'s `flatsByFilter`). `covered` is
    /// `true` for BOTH `.fresh` and `.stale` (this compact view has no room
    /// for staleness -- that nuance belongs to the coverage-table/Teendők
    /// view via `flatCoverage(db:config:)` instead), `false` only for
    /// `.missing`. `[]` when the session has no usable lights at all.
    public struct FlatFilterCoverage: Codable, Sendable, Equatable {
        public var filter: String?
        public var covered: Bool

        public init(filter: String?, covered: Bool) {
            self.filter = filter
            self.covered = covered
        }
    }

    /// `files` is expected to already be `db.allFiles(includeMissing: false)`
    /// -- callers that already fetched it (`SessionMatcher.match`) pass it
    /// straight through instead of paying for a second read.
    public static func flatCoverage(
        target: String,
        date: String,
        files: [FileRecord],
        db: Database,
        config: AstroConfig
    ) throws -> [FlatFilterCoverage] {
        let sessionFiles = files.filter { $0.area == .sessions && $0.target == target && $0.sessionDate == date }
        let cells = try flatCells(target: target, date: date, sessionFiles: sessionFiles, db: db, config: config)
        guard !cells.isEmpty else { return [] }

        let sessionFlatsByKey = try sessionFlatMetasByFilterKey(sessionFiles: sessionFiles, db: db)
        let pools = try libraryFlatPools(files: files, db: db)
        let sessionFlatsPath = "sessions/\(target)/\(date)/flats"

        return cells
            .map { cell -> FlatFilterCoverage in
                let result = evaluateFlatCoverage(
                    cell: cell,
                    sessionFlatMetas: sessionFlatsByKey[cell.filterKey] ?? [],
                    libraryPool: pools[cell.filterKey],
                    calib: config.calib,
                    sessionFlatsPath: sessionFlatsPath
                )
                let covered: Bool
                if case .missing = result.status { covered = false } else { covered = true }
                return FlatFilterCoverage(filter: cell.filterDisplay, covered: covered)
            }
            .sorted { ($0.filter ?? "\u{FFFF}") < ($1.filter ?? "\u{FFFF}") }
    }

    /// Library-wide flat coverage, aggregated per normalized filter across
    /// EVERY scanned session with usable lights -- `kind == .flat`
    /// `CalibNeed`s, the flat counterpart to `coverage()`'s dark rows. Kept
    /// as its own function rather than merged into `coverage()` -- see this
    /// file's own top-level doc comment for why.
    ///
    /// One `CalibNeed` per distinct filter (case-insensitive, trimmed;
    /// `nil` for OSC/DSLR lights with no `FILTER` header at all). A filter's
    /// row is "missing" the moment ANY session using it has no covering
    /// flat at all (own session flat, or a library one within
    /// `calib.flatMaxAgeDays` of that session's own lights); "stale" when
    /// none are missing but at least one session's only coverage is a
    /// library flat past that age threshold; "fresh" (`todo == nil`) only
    /// when every affected session is covered. `targets`/the todo's session
    /// count only ever name the AFFECTED sessions (missing, or stale in a
    /// stale-overall row) -- a session already covered by its own flat
    /// contributes to `lightCount` but never shows up as something to fix.
    public static func flatCoverage(db: Database, config: AstroConfig) throws -> [CalibNeed] {
        let files = try db.allFiles(includeMissing: false)
        let calib = config.calib

        var sessionKeys = Set<SessionDateKey>()
        for file in files where file.area == .sessions {
            guard let target = file.target, let date = file.sessionDate else { continue }
            sessionKeys.insert(SessionDateKey(target: target, date: date))
        }

        let pools = try libraryFlatPools(files: files, db: db)

        var byFilterKey: [String?: [FlatCellResult]] = [:]

        for key in sessionKeys {
            let sessionFiles = files.filter { $0.area == .sessions && $0.target == key.target && $0.sessionDate == key.date }
            let cells = try flatCells(target: key.target, date: key.date, sessionFiles: sessionFiles, db: db, config: config)
            guard !cells.isEmpty else { continue }

            let sessionFlatsByKey = try sessionFlatMetasByFilterKey(sessionFiles: sessionFiles, db: db)
            let sessionFlatsPath = "sessions/\(key.target)/\(key.date)/flats"

            for cell in cells {
                let result = evaluateFlatCoverage(
                    cell: cell,
                    sessionFlatMetas: sessionFlatsByKey[cell.filterKey] ?? [],
                    libraryPool: pools[cell.filterKey],
                    calib: calib,
                    sessionFlatsPath: sessionFlatsPath
                )
                byFilterKey[cell.filterKey, default: []].append(FlatCellResult(cell: cell, result: result))
            }
        }

        return byFilterKey.map { _, results in buildFlatNeed(results: results) }
            .sorted { ($0.filter ?? "\u{FFFF}") < ($1.filter ?? "\u{FFFF}") }
    }

    /// A (target, date) session key -- distinct nested type from
    /// `CalibHealth`'s own private `SessionKey` (different enum, no name
    /// collision), same shape.
    private struct SessionDateKey: Hashable {
        var target: String
        var date: String
    }

    private static func buildFlatNeed(results: [FlatCellResult]) -> CalibNeed {
        let sorted = results.sorted { ($0.cell.target, $0.cell.date) < ($1.cell.target, $1.cell.date) }
        let filterDisplay = sorted.compactMap(\.cell.filterDisplay).first
        let lightCount = sorted.reduce(0) { $0 + $1.cell.lightCount }
        let worstRank = sorted.map { flatRank($0.result.status) }.min() ?? 2

        let affected = sorted.filter { flatRank($0.result.status) == worstRank && worstRank != 2 }
        let affectedTargets = Set(affected.map(\.cell.target)).sorted()
        let affectedSessions = Set(affected.map {
            ScanSummary.SessionKey(target: $0.cell.target, date: $0.cell.date)
        }).sorted { ($0.date, $0.target) < ($1.date, $1.target) }
        let affectedSessionCount = affected.count

        var mismatchReasons: [String] = []
        var seenReasons = Set<String>()
        for reason in affected.flatMap({ $0.result.mismatchReasons }) where seenReasons.insert(reason).inserted {
            mismatchReasons.append(reason)
        }

        let matchedPath: String?
        let ageDays: Int?
        let isStale: Bool

        switch worstRank {
        case 0:
            matchedPath = nil
            ageDays = nil
            isStale = false
        case 1:
            isStale = true
            matchedPath = "calibration_library/flats"
            ageDays = affected.compactMap { entry -> Int? in
                if case .stale(_, let a) = entry.result.status { return a }
                return nil
            }.max()
        default:
            isStale = false
            if let libraryFresh = sorted.first(where: { entry in
                if case .fresh(let path, _) = entry.result.status { return path == "calibration_library/flats" }
                return false
            }) {
                if case .fresh(let path, let a) = libraryFresh.result.status {
                    matchedPath = path
                    ageDays = a
                } else {
                    matchedPath = nil
                    ageDays = nil
                }
            } else if let sessionFresh = sorted.first(where: { if case .fresh = $0.result.status { return true }; return false }) {
                if case .fresh(let path, let a) = sessionFresh.result.status {
                    matchedPath = path
                    ageDays = a
                } else {
                    matchedPath = nil
                    ageDays = nil
                }
            } else {
                matchedPath = nil
                ageDays = nil
            }
        }

        let todo = flatTodoString(
            filterDisplay: filterDisplay,
            worstRank: worstRank,
            affectedSessionCount: affectedSessionCount,
            ageDays: ageDays
        )

        return CalibNeed(
            kind: .flat,
            exposureSeconds: 0,
            tempC: nil,
            lightCount: lightCount,
            targets: affectedTargets,
            matchedMasterPath: matchedPath,
            masterAgeDays: ageDays,
            isStale: isStale,
            todo: todo,
            requiredGain: nil,
            requiredCamera: nil,
            mismatchReasons: mismatchReasons,
            filter: filterDisplay,
            sessions: affectedSessions
        )
    }

    /// Hungarian todo text for one filter's aggregate flat need -- deliberately
    /// omits any "(nincs szűrő)" qualifier for a filterless (OSC/DSLR) group
    /// (`filterDisplay == nil`): the spec's own words are "don't generate
    /// fake noise" for that case, so the sentence just reads without naming
    /// a filter at all rather than inventing a placeholder label for one.
    private static func flatTodoString(
        filterDisplay: String?,
        worstRank: Int,
        affectedSessionCount: Int,
        ageDays: Int?
    ) -> String? {
        switch worstRank {
        case 0:
            if let filterDisplay {
                return "Készíts \(filterDisplay) flatet — \(affectedSessionCount) session érintett"
            }
            return "Készíts flatet — \(affectedSessionCount) session érintett"
        case 1:
            let ageText = ageDays.map(String.init) ?? "?"
            if let filterDisplay {
                return "Készíts friss \(filterDisplay) flatet (a jelenlegi \(ageText) napos; \(affectedSessionCount) session érintett)"
            }
            return "Készíts friss flatet (a jelenlegi \(ageText) napos; \(affectedSessionCount) session érintett)"
        default:
            return nil
        }
    }
}
