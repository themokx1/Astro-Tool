import Foundation

/// One frame's plate-solve attempt outcome (R7-1). `error` is `nil` exactly
/// when `raDeg`/`decDeg` were both filled in and persisted.
public struct SolveResult: Codable, Sendable {
    public var path: String
    public var raDeg: Double?
    public var decDeg: Double?
    public var scaleArcsec: Double?
    public var rotationDeg: Double?
    public var error: String?

    public init(
        path: String,
        raDeg: Double? = nil,
        decDeg: Double? = nil,
        scaleArcsec: Double? = nil,
        rotationDeg: Double? = nil,
        error: String? = nil
    ) {
        self.path = path
        self.raDeg = raDeg
        self.decDeg = decDeg
        self.scaleArcsec = scaleArcsec
        self.rotationDeg = rotationDeg
        self.error = error
    }
}

/// Aggregate outcome of one `PlateSolver.solveTarget` call.
public struct SolveSummary: Codable, Sendable {
    public var attempted: Int
    public var solved: Int
    public var failed: Int
    /// Usable lights that already had a coordinate (header WCS or a prior
    /// `solved_ra`/`solved_dec`) and were therefore never handed to the
    /// backend at all -- not counted in `attempted`. Always `0` when
    /// `force` was passed to `solveTarget`.
    public var skipped: Int

    public init(attempted: Int, solved: Int, failed: Int, skipped: Int) {
        self.attempted = attempted
        self.solved = solved
        self.failed = failed
        self.skipped = skipped
    }
}

/// Pluggable plate-solve backend: given the path to the ORIGINAL image
/// (read-only -- never written to) and a scratch work directory, produces a
/// solved FITS file (WCS cards in its header) somewhere under `workDir`.
/// Implementations must never write anywhere outside `workDir` -- in
/// particular, never back into the original library. `PlateSolver` is
/// written against this protocol (not the Siril subprocess directly) so
/// tests can substitute a mock that writes a synthetic solved FITS instead
/// of actually invoking `siril-cli`.
public protocol SolveBackend: Sendable {
    func solve(originalPath: String, workDir: URL) throws -> URL
}

/// Errors specific to the default Siril-backed `SolveBackend`.
public enum SolveBackendError: Error, Equatable, Sendable {
    /// `buildScript`'s path guard rejected `originalPath`/`workDir.path` --
    /// see `containsSirilScriptInjectionRisk`'s doc comment.
    case unsupportedPath(String)
    case timedOut
    /// Siril ran but produced neither `solved.fit` nor `solved.fits` --
    /// the associated string is whatever it printed, for diagnosis.
    case solveFailed(String)
}

/// Default `SolveBackend`: runs `siril-cli -s -` with a small script that
/// `cd`s into the caller-supplied `workDir`, loads the ORIGINAL file
/// read-only, blind plate-solves it, and saves the solved result as
/// `solved.fit` -- Siril's `save "name"` writes relative to the process's
/// current working directory, which is why `cd`ing into `workDir` first
/// (rather than the original file's own directory) is what keeps the
/// library untouched: the solved output lands only in the scratch dir.
struct SirilSolveBackend: SolveBackend {
    let sirilPath: String

    /// Blind plate-solving (no near-coordinate hint) can take a while --
    /// generous per-frame timeout, an order of magnitude above
    /// `SirilCLI`'s `findstar`-only timeout.
    static let timeoutSeconds: TimeInterval = 180

    /// The Siril script text run for one frame: `requires` pins the minimum
    /// version the script grammar assumes, same convention as
    /// `SirilCLI.buildScript`. Both `originalPath` and `workDir.path` are
    /// interpolated into quoted script strings, so both go through the same
    /// injection guard `SirilCLI.buildScript` uses.
    static func buildScript(originalPath: String, workDir: URL) throws -> String {
        guard !containsSirilScriptInjectionRisk(originalPath) else {
            throw SolveBackendError.unsupportedPath(originalPath)
        }
        guard !containsSirilScriptInjectionRisk(workDir.path) else {
            throw SolveBackendError.unsupportedPath(workDir.path)
        }
        return """
        requires 1.2.0
        cd "\(workDir.path)"
        load "\(originalPath)"
        platesolve
        save solved
        close
        """
    }

    func solve(originalPath: String, workDir: URL) throws -> URL {
        let script = try Self.buildScript(originalPath: originalPath, workDir: workDir)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sirilPath)
        process.arguments = ["-s", "-"]
        process.currentDirectoryURL = workDir

        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        // Same "background blocking read + semaphore" pattern as
        // `SirilCLI.metrics(for:workDir:)` -- see its doc comment for why
        // this sidesteps the readabilityHandler/terminationHandler race.
        let collected = OutputCollector()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            collected.set(data)
            readDone.signal()
        }

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(script.utf8))
        try? stdinPipe.fileHandleForWriting.close()

        let outcome = readDone.wait(timeout: .now() + Self.timeoutSeconds)
        if outcome == .timedOut {
            process.terminate()
            throw SolveBackendError.timedOut
        }
        process.waitUntilExit()

        let fitURL = workDir.appendingPathComponent("solved.fit")
        let fitsURL = workDir.appendingPathComponent("solved.fits")
        if FileManager.default.fileExists(atPath: fitURL.path) { return fitURL }
        if FileManager.default.fileExists(atPath: fitsURL.path) { return fitsURL }

        let text = String(data: collected.data, encoding: .utf8) ?? ""
        throw SolveBackendError.solveFailed(text.isEmpty ? "siril produced no solved.fit(s)" : text)
    }

    /// Thread-safe one-shot box for the merged stdout+stderr bytes, written
    /// once by the background read task above -- same as `SirilCLI`'s own
    /// `OutputCollector`, duplicated rather than shared since it's a tiny,
    /// file-private implementation detail in both places.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func set(_ data: Data) {
            lock.lock()
            buffer = data
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }
}

/// Plate-solve backfill (R7-1): blind-solves usable lights that have no WCS
/// solution at all (typically wide-field Canon CR3 frames -- ASIAIR FITS
/// lights are already plate-solved by the capture software) via Siril,
/// persisting only `fits_meta.solved_*` columns -- the scanned library
/// itself, and `header_json`, are never written to. All Siril work happens
/// in a per-frame scratch directory under `FileManager.temporaryDirectory`,
/// cleaned up afterward.
public final class PlateSolver {
    private let backend: SolveBackend

    /// Production entry point: verifies `sirilPath` is executable (same
    /// contract/error as `SirilCLI.init`) and wires up the real
    /// `SirilSolveBackend`.
    public init(sirilPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: sirilPath) else {
            throw AstroError.sirilNotFound(path: sirilPath)
        }
        self.backend = SirilSolveBackend(sirilPath: sirilPath)
    }

    /// Test seam: inject an arbitrary `SolveBackend` (e.g. a mock that
    /// writes a synthetic solved FITS with known `CRVAL`/`CD` cards) instead
    /// of invoking the real Siril subprocess.
    init(backend: SolveBackend) {
        self.backend = backend
    }

    /// Solves up to `maxFramesPerSession` usable lights per session date of
    /// `target` that currently lack a coordinate (no header WCS AND no
    /// `solved_ra` on record), preferring a session's middle frame(s) --
    /// index `count / 2` -- as representative of the whole session's
    /// pointing. `force` re-solves every usable light regardless of whether
    /// it already has a coordinate. `progress`, when given, is called once
    /// per attempted frame (NOT per skipped one) with `(completedCount,
    /// totalAttempted)`, same contract as `Rater.rate`'s callback.
    public func solveTarget(
        _ target: String,
        db: Database,
        config: AstroConfig,
        maxFramesPerSession: Int = 1,
        force: Bool = false,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> SolveSummary {
        let allFiles = try db.allFiles(includeMissing: false)
        let targetLights = allFiles.filter { $0.area == .sessions && $0.role == .light && $0.target == target }
        guard !targetLights.isEmpty else {
            return SolveSummary(attempted: 0, solved: 0, failed: 0, skipped: 0)
        }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in targetLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let sessionDates = Set(targetLights.compactMap(\.sessionDate)).sorted()

        var candidates: [FileRecord] = []
        var totalSkipped = 0

        for date in sessionDates {
            let sessionLights = targetLights.filter { $0.sessionDate == date }
            let buckets = FrameSet.lightBuckets(files: sessionLights, meta: metaByFileID, config: config)
            let usable = buckets.usable

            let needsSolve: [FileRecord]
            if force {
                needsSolve = usable
            } else {
                needsSolve = usable.filter { !Self.alreadyHasCoordinate($0, meta: metaByFileID) }
                totalSkipped += usable.count - needsSolve.count
            }

            candidates.append(contentsOf: Self.selectFrames(from: needsSolve, maxCount: maxFramesPerSession))
        }

        let total = candidates.count
        guard total > 0 else {
            return SolveSummary(attempted: 0, solved: 0, failed: 0, skipped: totalSkipped)
        }

        let batchWorkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astrotool-platesolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: batchWorkDir, withIntermediateDirectories: true)
        defer { cleanupWorkDir(batchWorkDir) }

        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)

        var solved = 0
        var failed = 0
        var done = 0

        for file in candidates {
            defer {
                done += 1
                progress?(done, total)
            }

            guard let fileID = file.id else {
                failed += 1
                continue
            }

            let frameWorkDir = batchWorkDir.appendingPathComponent("frame-\(fileID)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: frameWorkDir, withIntermediateDirectories: true)
                let originalURL = root.appendingPathComponent(file.path)
                let solvedURL = try backend.solve(originalPath: originalURL.path, workDir: frameWorkDir)
                let header = try FITSReader.readHeader(url: solvedURL)

                guard let ra = header.double("CRVAL1"), let dec = header.double("CRVAL2") else {
                    throw SolveBackendError.solveFailed("solved FITS has no CRVAL1/CRVAL2")
                }

                var scale: Double?
                var rotation: Double?
                if let cd11 = header.double("CD1_1"), let cd12 = header.double("CD1_2"),
                   let cd21 = header.double("CD2_1"), let cd22 = header.double("CD2_2")
                {
                    let derived = FieldGeometry.scaleAndRotation(cd11: cd11, cd12: cd12, cd21: cd21, cd22: cd22)
                    scale = derived.scaleArcsec
                    rotation = derived.rotationDeg
                }

                try db.updateSolvedWCS(fileID: fileID, ra: ra, dec: dec, scale: scale, rotation: rotation)
                solved += 1
            } catch {
                failed += 1
            }
        }

        return SolveSummary(attempted: total, solved: solved, failed: failed, skipped: totalSkipped)
    }

    // MARK: - Frame selection

    /// Whether `file` already has a usable coordinate -- header WCS/RA-DEC,
    /// or a previously persisted `solved_ra`/`solved_dec` -- reusing
    /// `TargetCoordinates.coordinates` as the single source of truth for
    /// "does this frame have a coordinate" so this check can never drift
    /// from what the planner/panel-tracker themselves consider solved.
    private static func alreadyHasCoordinate(_ file: FileRecord, meta: [Int64: FITSMetaRecord]) -> Bool {
        guard let id = file.id, let record = meta[id] else { return false }
        return TargetCoordinates.coordinates(
            headerJSON: record.headerJSON, solvedRA: record.solvedRA, solvedDec: record.solvedDec
        ) != nil
    }

    /// Picks up to `maxCount` frames from `candidates`, preferring the
    /// MIDDLE of the path-sorted list -- e.g. `maxCount == 1` picks exactly
    /// the frame at index `count / 2`, a representative mid-session
    /// pointing rather than the (possibly atypical) first or last frame.
    /// Returns every candidate, sorted, when `maxCount >= candidates.count`.
    static func selectFrames(from candidates: [FileRecord], maxCount: Int) -> [FileRecord] {
        guard !candidates.isEmpty, maxCount > 0 else { return [] }
        let sorted = candidates.sorted { $0.path < $1.path }
        guard maxCount < sorted.count else { return sorted }

        let mid = sorted.count / 2
        var start = mid - maxCount / 2
        start = max(0, min(start, sorted.count - maxCount))
        return Array(sorted[start..<(start + maxCount)])
    }

    // MARK: - Scratch dir cleanup

    /// Removes this batch's Siril scratch directory -- same guarded-delete
    /// convention as `Rater.cleanupWorkDir`: only ever deletes a path
    /// confirmed to be under `FileManager.default.temporaryDirectory`, never
    /// anything in the scanned library.
    private func cleanupWorkDir(_ workDir: URL) {
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let target = workDir.standardizedFileURL.path
        guard target == tempRoot || target.hasPrefix(tempRoot + "/") else { return }
        try? FileManager.default.removeItem(at: workDir)
    }
}
