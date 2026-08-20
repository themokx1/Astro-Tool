import Foundation

/// Builds a stacked calibration master (dark/flat/bias) from a list of
/// already-scanned source subs, via the real `siril-cli` subprocess.
///
/// `SirilCLI` (this same package, `Sources/AstroCore/Rate/SirilCLI.swift`)
/// only ever runs a `findstar`/plate-solve script against ONE image at a
/// time -- master STACKING is genuinely new subprocess territory (V3
/// pre-stack program, `docs/superpowers/specs/2026-08-20-v3-prestack-program.md`
/// section 5.2, Kalibrációs automata). The exact script shape below was
/// validated by hand against a real Siril 1.4.4 install on this machine
/// (`siril-cli -d <dir> -s -` fed a `requires`/`cd`/`convert`/`cd`/`stack`
/// script over stdin) before being written here -- two real findings from
/// that validation shaped the implementation:
///
/// 1. `stack`'s own `-out=<name>` argument must NEVER be quoted -- unlike
///    `cd "<path>"` (which Siril's tokenizer correctly unquotes), a quoted
///    `-out="../process"` is taken completely literally, including the `"`
///    characters, and silently creates a directory named `"../process"`
///    (quote characters and all) instead of the intended one. `convert`'s
///    own `-out=` argument has the exact same trap.
/// 2. `siril-cli`'s exit code is NOT a reliable success signal: a script
///    that fails outright (e.g. `stack` unable to find its sequence) still
///    exits `0`. The only honest way to know a master was actually built is
///    to check that the expected output FILE exists afterward -- this type
///    never reports success on log text or exit code alone, matching this
///    codebase's "never mark a gap resolved on failure" rule.
///
/// Every filesystem touch stays inside the caller-supplied `workDir` --
/// source frames are only ever SYMLINKED into a private `input` subdirectory
/// (Siril's own `convert` command reads a directory of images by extension,
/// not an explicit file list), so the real library files being stacked are
/// never written to, moved, or renamed by this type. The caller
/// (`CalibrationMasterBuildCommand`, `AstroApplication`) is the one that
/// copies the produced file into `calibration_library/`, through
/// `WriteGuard.writeCalibrationMaster` -- this type never writes outside
/// `workDir`.
public struct SirilMasterBuilder: Sendable {
    public enum BuildError: Error, Equatable, Sendable {
        /// Fewer than `minimumFrameCount` source frames were supplied --
        /// technically stackable, but a rejection algorithm needs enough
        /// samples to actually reject outliers, so this refuses rather than
        /// silently producing a scientifically weak master.
        case insufficientFrames(have: Int, minimum: Int)
        case timedOut
        /// The subprocess's own merged stdout+stderr log, kept for the
        /// honest failure message the UI shows -- never parsed for success/
        /// failure itself (see this type's own doc comment, finding 2).
        case outputMissing(log: String)
    }

    /// The spec's own worked tooltip example ("csak 3 dark van, minimum 10
    /// kell") -- a stack of fewer than this many subs is scientifically weak
    /// even where Siril would technically run on 2-3 frames.
    public static let minimumFrameCount = 10

    /// Generous headroom for a real stack of dozens of full-resolution
    /// frames -- `SirilCLI.metrics`'s own single-frame `findstar` gets 120s;
    /// stacking dozens of frames is real, disk-bound work, not a quick
    /// per-frame measurement. A `public` constant (not just the default
    /// argument value below) so callers/tests can reference the same number
    /// without repeating the literal.
    public static let defaultTimeoutSeconds: TimeInterval = 300

    public let path: String

    /// - Throws: `AstroError.sirilNotFound(path:)` if `path` isn't an
    ///   executable file -- same contract as `SirilCLI.init(path:)`.
    public init(path: String) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw AstroError.sirilNotFound(path: path)
        }
        self.path = path
    }

    /// Stacks `sourceURLs` into one master FITS under `workDir/process/`,
    /// returning its URL. Never touches `sourceURLs` themselves (read-only,
    /// symlinked into a scratch `input` dir) and never writes anywhere
    /// outside `workDir`.
    ///
    /// `kind` only changes the stacking normalization: `-nonorm` for dark/
    /// bias (subtracting a dark/bias never rescales its own pixel values,
    /// so normalizing across subs would only distort the result), `-norm=mul`
    /// for flat (Siril's own documented recommendation for combining flats
    /// shot at slightly different sky-brightness levels).
    public func buildMaster(
        kind: FrameRole,
        sourceURLs: [URL],
        workDir: URL,
        timeoutSeconds: TimeInterval = SirilMasterBuilder.defaultTimeoutSeconds
    ) throws -> URL {
        guard sourceURLs.count >= Self.minimumFrameCount else {
            throw BuildError.insufficientFrames(have: sourceURLs.count, minimum: Self.minimumFrameCount)
        }

        let inputDir = workDir.appendingPathComponent("input", isDirectory: true)
        let processDir = workDir.appendingPathComponent("process", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: processDir, withIntermediateDirectories: true)

        let sequenceName = "src"
        for (index, source) in sourceURLs.enumerated() {
            let ext = source.pathExtension.isEmpty ? "fit" : source.pathExtension
            let indexText = String(format: "%04d", index + 1)
            let linkURL = inputDir.appendingPathComponent("\(sequenceName)_\(indexText).\(ext)")
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: source)
        }

        let normalization = kind == .flat ? "-norm=mul" : "-nonorm"
        let outputName = "master"
        // NOTE: `-out=` is deliberately UNQUOTED on both `convert` and
        // `stack` -- see this type's own doc comment, finding 1.
        let script = """
        requires 1.2.0
        cd "input"
        convert \(sequenceName) -out=../process
        cd "../process"
        stack \(sequenceName) rej 3 3 \(normalization) -out=\(outputName)
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-d", workDir.path, "-s", "-"]

        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        // Same blocking-read-on-a-background-queue pattern `SirilCLI.metrics`
        // uses, for the same reason: exactly one read, complete by
        // construction once it returns, sidestepping the classic
        // readabilityHandler/terminationHandler race.
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

        let outcome = readDone.wait(timeout: .now() + timeoutSeconds)
        if outcome == .timedOut {
            process.terminate()
            throw BuildError.timedOut
        }
        process.waitUntilExit()

        let log = String(data: collected.data, encoding: .utf8) ?? ""

        // Deliberately NOT gated on `process.terminationStatus` -- validated
        // by hand that `siril-cli` exits 0 even after a script step fails
        // outright (see this type's own doc comment, finding 2). The output
        // file's existence is the only honest signal.
        let candidateExtensions = ["fit", "fits"]
        let candidates = candidateExtensions.map { processDir.appendingPathComponent("\(outputName).\($0)") }
        guard let outputURL = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw BuildError.outputMissing(log: log)
        }
        return outputURL
    }

    /// Thread-safe one-shot box for the merged stdout+stderr bytes, written
    /// once by the background read task -- same shape as `SirilCLI`'s own
    /// private `OutputCollector` (not shared across files: each is a small,
    /// self-contained implementation detail of its own subprocess call).
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
