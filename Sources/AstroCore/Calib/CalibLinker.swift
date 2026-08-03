import Foundation

/// A plan to hard-link calibration masters from `calibration_library/` into
/// one session's own `darks`/`biases`/`flats` folders -- computed read-only
/// against `db`, applied (the only place anything actually gets written)
/// via `WriteGuard.linkCalibrationFile`.
public struct CalibLinkPlan: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        /// Root-relative path of the source file, always under
        /// `calibration_library/`.
        public var sourcePath: String
        /// Root-relative destination directory, always
        /// `sessions/<target>/<date>/(darks|biases|flats)`.
        public var destDir: String
        /// Hungarian, human-facing reason this item is in the plan, e.g.
        /// `"dark 300s/-10°C a lightokhoz"`, `"flat-dark 6.8s/-10°C a
        /// flatokhoz"`, `"bias master"`.
        public var reason: String

        public init(sourcePath: String, destDir: String, reason: String) {
            self.sourcePath = sourcePath
            self.destDir = destDir
            self.reason = reason
        }
    }

    public var target: String
    public var date: String
    public var items: [Item]
    /// Hungarian reasons a same-(exposure, temp) master (light-dark and/or
    /// flat-dark) was found but rejected on an electronic dimension
    /// (`CalibRule.matchGain`/`matchOffset`/`matchBinning`/`matchCamera`) --
    /// e.g. `["gain 0 ≠ 100"]`. Empty in the common case (either a full
    /// match was found, contributing items, or no master exists at that
    /// (exposure, temp) at all -- nothing to explain either way). Surfaced
    /// so an otherwise-silent empty plan reads as "nem linkelhető: gain 0 ≠
    /// 100" rather than just "nothing to link".
    public var mismatchReasons: [String]

    public init(target: String, date: String, items: [Item], mismatchReasons: [String] = []) {
        self.target = target
        self.date = date
        self.items = items
        self.mismatchReasons = mismatchReasons
    }
}

/// Computes and applies `CalibLinkPlan`s. Reuses `SessionMatcher` (session
/// inventory + library-dark fallback matching) and `CalibAnalyzer` (master-dir
/// matching, dominant-combo grouping) rather than re-deriving any of that
/// matching semantics here -- this type only decides which already-matched
/// master files become link items, and walks them through `WriteGuard`.
public enum CalibLinker {
    /// Builds the plan for `target`/`date`. Read-only: never touches the
    /// filesystem.
    ///
    /// - A session with no lights at all gets an empty plan (nothing to
    ///   calibrate).
    /// - **Darks for lights**: only when the session has no darks of its own
    ///   (`SessionCalibration.darks.isEmpty`) and `SessionMatcher` found a
    ///   matching library dark dir (`libraryDark`) -- every file under that
    ///   master dir becomes an item into `.../darks`.
    /// - **Flat-darks for flats**: only when the session has flats; their
    ///   dominant (exptime, setTemp) combo (`CalibAnalyzer.dominantCombo`) is
    ///   matched against `calibration_library/darks/` the same way a light's
    ///   combo would be (`CalibAnalyzer.matchedMasterDarkPath`) -- every file
    ///   under that dir becomes an item into `.../darks` too, tagged as a
    ///   flat-dark so it reads distinctly from the light-dark reason above.
    /// - **Biases**: only when the session has no biases of its own; v1 has
    ///   no exposure/temp breakdown for biases (see `CalibAnalyzer`'s own doc
    ///   comment), so every file directly under `calibration_library/biases/`
    ///   becomes an item into `.../biases`.
    /// - A session with its own darks/biases contributes no items for that
    ///   role at all -- it already has what it needs.
    /// - Items are deduplicated by (source, destDir) -- the same master file
    ///   is never listed twice for the same destination even if both the
    ///   light-dark and flat-dark match resolve to the same master dir.
    public static func plan(target: String, date: String, db: Database, config: AstroConfig) throws -> CalibLinkPlan {
        let sc = try SessionMatcher.match(target: target, date: date, db: db, config: config)

        guard sc.lights > 0 else {
            return CalibLinkPlan(target: target, date: date, items: [])
        }

        let allFiles = try db.allFiles(includeMissing: false)
        let destBase = "sessions/\(target)/\(date)"

        var items: [CalibLinkPlan.Item] = []
        var seenKeys = Set<String>()
        var mismatchReasons: [String] = []
        var seenMismatchReasons = Set<String>()

        func addMasterDirItems(masterDir: String, destDir: String, reason: String) {
            let files = allFiles
                .filter { $0.area == .calibration && $0.path.hasPrefix(masterDir + "/") }
                .sorted { $0.path < $1.path }
            for file in files {
                let key = "\(file.path)\u{0}\(destDir)"
                guard seenKeys.insert(key).inserted else { continue }
                items.append(CalibLinkPlan.Item(sourcePath: file.path, destDir: destDir, reason: reason))
            }
        }

        func addMismatchReasons(_ reasons: [String]) {
            for reason in reasons where seenMismatchReasons.insert(reason).inserted {
                mismatchReasons.append(reason)
            }
        }

        // 1. Darks for lights -- only when the session has none of its own.
        // `SessionMatcher` already resolved the light-dark match (including
        // any electronic mismatch) -- reuse it rather than re-deriving.
        if sc.darks.isEmpty {
            if let libraryDark = sc.libraryDark {
                addMasterDirItems(
                    masterDir: libraryDark,
                    destDir: "\(destBase)/darks",
                    reason: reasonForDark(masterDir: libraryDark, isFlatDark: false)
                )
            } else {
                addMismatchReasons(sc.libraryDarkMismatchReasons)
            }
        }

        // 2. Flat-darks for flats -- computed from the flats' own dominant
        // combo, independent of whatever the lights matched above.
        if !sc.flats.isEmpty {
            let sessionFiles = allFiles.filter { $0.area == .sessions && $0.target == target && $0.sessionDate == date }
            let flatFiles = sessionFiles.filter { $0.role == .flat }
            if let dominant = try CalibAnalyzer.dominantCombo(files: flatFiles, db: db) {
                let match = try CalibAnalyzer.matchedMasterDarkPath(
                    exposureS: dominant.exposureS,
                    tempC: dominant.tempC,
                    gain: dominant.gain,
                    offset: dominant.offset,
                    camera: dominant.camera,
                    files: allFiles,
                    db: db,
                    config: config
                )
                if let flatDarkDir = match.path {
                    addMasterDirItems(
                        masterDir: flatDarkDir,
                        destDir: "\(destBase)/darks",
                        reason: reasonForDark(masterDir: flatDarkDir, isFlatDark: true)
                    )
                } else {
                    addMismatchReasons(match.mismatchReasons)
                }
            }
        }

        // 3. Biases -- only when the session has none of its own; no exp/
        // temp breakdown in v1, so every file directly under
        // calibration_library/biases/ is a candidate.
        if sc.biases.isEmpty {
            let biasFiles = allFiles
                .filter { $0.area == .calibration && $0.role == .bias }
                .sorted { $0.path < $1.path }
            let destDir = "\(destBase)/biases"
            for file in biasFiles {
                let key = "\(file.path)\u{0}\(destDir)"
                guard seenKeys.insert(key).inserted else { continue }
                items.append(CalibLinkPlan.Item(sourcePath: file.path, destDir: destDir, reason: "bias master"))
            }
        }

        return CalibLinkPlan(target: target, date: date, items: items, mismatchReasons: mismatchReasons)
    }

    /// Walks every item in `plan` through `writeGuard.linkCalibrationFile`,
    /// accumulating a `LinkResult`. `root` is used only to express the
    /// linked destinations as root-relative paths in the result; the actual
    /// write (and all its validation) happens inside `writeGuard`.
    @discardableResult
    public static func apply(_ plan: CalibLinkPlan, root: URL, using writeGuard: WriteGuard) throws -> LinkResult {
        var linked: [String] = []
        var skipped: [String] = []

        let rootPath = root.standardizedFileURL.path

        for item in plan.items {
            if let destURL = try writeGuard.linkCalibrationFile(sourceRelative: item.sourcePath, destDirRelative: item.destDir) {
                linked.append(rootRelative(destURL, rootPath: rootPath))
            } else {
                let fileName = (item.sourcePath as NSString).lastPathComponent
                skipped.append("\(item.destDir)/\(fileName)")
            }
        }

        return LinkResult(linked: linked, skipped: skipped)
    }

    private static func rootRelative(_ url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }

    /// Hungarian reason string for a dark/flat-dark item, parsing the
    /// (exposure, temp) combo back out of the matched master dir's own name
    /// (e.g. `"300sec_-10deg"`) via `CalibAnalyzer.parseMasterDirName` --
    /// same grammar `CalibAnalyzer.coverage()` relies on already, so this
    /// never re-derives the combo independently of what actually matched.
    private static func reasonForDark(masterDir: String, isFlatDark: Bool) -> String {
        let dirName = (masterDir as NSString).lastPathComponent
        let kind = isFlatDark ? "flat-dark" : "dark"
        let suffix = isFlatDark ? "a flatokhoz" : "a lightokhoz"

        guard let parsed = CalibAnalyzer.parseMasterDirName(dirName) else {
            return "\(kind) \(suffix)"
        }

        let expStr = formattedNumber(parsed.exposureS)
        let tempStr = formattedNumber(parsed.tempC)
        return "\(kind) \(expStr)s/\(tempStr)°C \(suffix)"
    }

    private static func formattedNumber(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
