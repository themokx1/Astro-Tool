import Foundation

/// A single session's calibration inventory: what it has of its own
/// (flats/darks/biases), a fallback dark master from the calibration
/// library when it has none of its own, and any problems found while
/// putting this picture together.
public struct SessionCalibration: Codable, Sendable, Equatable {
    public var target: String
    public var date: String
    public var lights: Int
    /// Root-relative paths of this session's flat frames, sorted.
    public var flats: [String]
    /// Root-relative paths of this session's dark frames, sorted.
    public var darks: [String]
    /// Root-relative paths of this session's bias frames, sorted.
    public var biases: [String]
    /// Root-relative `calibration_library/darks/<dir>` path matching this
    /// session's dominant light (exposure, temp) combo -- only ever set
    /// when `darks` is empty. `nil` when the session has its own darks, or
    /// there's no matching library master.
    public var libraryDark: String?
    public var problems: [Finding]

    public init(
        target: String,
        date: String,
        lights: Int,
        flats: [String],
        darks: [String],
        biases: [String],
        libraryDark: String?,
        problems: [Finding]
    ) {
        self.target = target
        self.date = date
        self.lights = lights
        self.flats = flats
        self.darks = darks
        self.biases = biases
        self.libraryDark = libraryDark
        self.problems = problems
    }
}

/// Matches one scanned session's frames against its own calibration frames
/// and, failing that, the shared `calibration_library/darks/` masters --
/// answering "does this session actually have what it needs to be
/// calibrated?" Read-only against `db`; never touches the filesystem.
public enum SessionMatcher {
    /// Builds the `SessionCalibration` for `target`/`date`. Throws
    /// `AstroError.pathNotFound` when no scanned file at all matches this
    /// (target, date) pair under `sessions/`.
    public static func match(target: String, date: String, db: Database, config: AstroConfig) throws -> SessionCalibration {
        let allFiles = try db.allFiles(includeMissing: false)
        let sessionFiles = allFiles.filter { $0.area == .sessions && $0.target == target && $0.sessionDate == date }

        guard !sessionFiles.isEmpty else {
            throw AstroError.pathNotFound(path: "sessions/\(target)/\(date)")
        }

        let lights = sessionFiles.filter { $0.role == .light }
        let flats = sessionFiles.filter { $0.role == .flat }.map(\.path).sorted()
        let darks = sessionFiles.filter { $0.role == .dark }.map(\.path).sorted()
        let biases = sessionFiles.filter { $0.role == .bias }.map(\.path).sorted()

        var problems: [Finding] = []

        // (a) frames misplaced within this session -- same IMAGETYP-vs-path
        // contradiction check as `CalibInWrongDirRule`, scoped to this
        // session's files only.
        for file in sessionFiles {
            guard let fileID = file.id,
                  let meta = try db.fitsMeta(fileID: fileID),
                  let imagetyp = meta.imagetyp
            else { continue }
            if let problem = CalibInWrongDirRule.misplacedFinding(file: file, imagetyp: imagetyp, id: "calib-in-wrong-dir", toolOutputDirNames: config.toolOutputDirNames) {
                problems.append(problem)
            }
        }

        // (b) no flats at all for a session that has lights.
        let sessionPath = "sessions/\(target)/\(date)"
        if !lights.isEmpty, flats.isEmpty {
            problems.append(
                Finding(
                    severity: .suspicious,
                    category: "missing-flats",
                    path: sessionPath,
                    message: "Ehhez a session-höz nincs flat felvétel.",
                    suggestion: nil
                )
            )
        }

        // (c) no session darks -- fall back to the calibration library
        // before deciding this is actually a problem.
        var libraryDark: String?
        if darks.isEmpty {
            libraryDark = try dominantLibraryDark(lights: lights, db: db, allFiles: allFiles, config: config)
        }

        if !lights.isEmpty, darks.isEmpty, libraryDark == nil {
            problems.append(
                Finding(
                    severity: .suspicious,
                    category: "missing-darks",
                    path: sessionPath,
                    message: "Nincs saját dark felvétel a session-höz, és nincs hozzá illő library dark sem.",
                    suggestion: nil
                )
            )
        }

        return SessionCalibration(
            target: target,
            date: date,
            lights: lights.count,
            flats: flats,
            darks: darks,
            biases: biases,
            libraryDark: libraryDark,
            problems: problems
        )
    }

    // MARK: - Library dark fallback

    /// Picks `lights`' dominant (exptime, setTemp) combo -- via
    /// `CalibAnalyzer.dominantCombo`, shared with `CalibLinker`'s flat-dark
    /// matching -- and matches it against the calibration library. `nil`
    /// when no light has usable exposure meta, or no library master matches
    /// the dominant combo.
    private static func dominantLibraryDark(
        lights: [FileRecord],
        db: Database,
        allFiles: [FileRecord],
        config: AstroConfig
    ) throws -> String? {
        guard let dominant = try CalibAnalyzer.dominantCombo(files: lights, db: db) else { return nil }

        return CalibAnalyzer.matchedMasterDarkPath(
            exposureS: dominant.exposureS,
            tempC: dominant.tempC,
            files: allFiles,
            config: config
        )
    }
}
