import Foundation

/// A path containing either character could break out of a Siril script's
/// quoted `"..."` string (e.g. a `load "..."` or `cd "..."` line) and inject
/// arbitrary script commands. Shared by `SirilCLI.buildScript` and
/// `PlateSolver`'s own script builder so the two guards can never silently
/// diverge -- see `SirilCLI.buildScript`'s doc comment for why an outright
/// rejection (rather than guessing at Siril's DSL escaping rules) is the
/// right call here.
func containsSirilScriptInjectionRisk(_ path: String) -> Bool {
    path.contains("\"") || path.contains("\\")
}

/// Star-detection metrics for a single frame, as measured by whichever
/// `StarMetricsProvider` produced them (currently only `SirilCLI`).
public struct StarMetrics: Codable, Equatable, Sendable {
    public var fwhm: Double
    /// `nil` when Siril's `findstar` log didn't print a roundness figure at
    /// all -- previously defaulted to a fabricated `0.5` "neutral" value,
    /// which polluted rating stats with data that was never actually
    /// measured. `Rater` already renormalizes its scoring weights over
    /// whichever metrics are actually present for a frame, so a `nil` here
    /// simply drops roundness from that frame's score instead of lying
    /// about it.
    public var roundness: Double?
    public var starCount: Int

    public init(fwhm: Double, roundness: Double?, starCount: Int) {
        self.fwhm = fwhm
        self.roundness = roundness
        self.starCount = starCount
    }
}

/// A pluggable source of star-detection metrics for a single image file.
/// `Rater` is written against this protocol (not `SirilCLI` directly) so
/// tests can substitute a mock and production code can substitute a
/// different star-detection tool in the future without touching `Rater`.
public protocol StarMetricsProvider: Sendable {
    /// Measures star metrics for the image at `url`. `workDir` is a scratch
    /// directory the provider may use for temp files — implementations must
    /// never write outside it (in particular, never into the library being
    /// rated).
    func metrics(for url: URL, workDir: URL) throws -> StarMetrics

    /// A short version string for provenance (stored on the persisted
    /// rating row), or `"unknown"` if it couldn't be determined.
    var version: String { get }
}

/// `StarMetricsProvider` backed by Siril's command-line tool (`siril-cli`).
///
/// Siril is invoked as `siril-cli -s -`: a small script (see
/// `buildScript(imagePath:)`) is fed on stdin rather than written to a
/// `.ssf` file on disk, and the process's working directory is set to the
/// caller-supplied `workDir` — Siril writes some scratch/log files relative
/// to its working directory, so this keeps it confined to the scratch
/// directory `Rater` hands out rather than the scanned library.
public struct SirilCLI: StarMetricsProvider {
    /// Errors specific to running/parsing the `siril-cli` subprocess.
    /// Deliberately not `AstroError` — these are adapter-internal failure
    /// modes (a hung process, unparsable output) rather than the
    /// filesystem/library errors `AstroError` models; callers (`Rater`)
    /// only need *that* the call threw, not a specific case to switch on.
    public enum ProcessError: Error, Equatable {
        case timedOut
        case unparsableOutput
        /// `buildScript(imagePath:)` refused to build a script for this
        /// path (see its doc comment for why).
        case unsupportedPath(String)
    }

    public let path: String
    public let version: String

    /// Timeout for a single `metrics(for:workDir:)` invocation. `findstar`
    /// on a single frame should take a few seconds at most; 120s gives
    /// generous headroom before treating the process as hung.
    private static let timeoutSeconds: TimeInterval = 120

    /// - Throws: `AstroError.sirilNotFound(path:)` if `path` isn't an
    ///   executable file.
    public init(path: String) throws {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw AstroError.sirilNotFound(path: path)
        }
        self.path = path
        self.version = Self.readVersion(path: path)
    }

    /// Runs `siril-cli --version` once at init time and parses its output
    /// via `parseVersionOutput`. Falls back to `"unknown"` on any failure —
    /// version provenance is nice-to-have, not worth failing init over.
    private static func readVersion(path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8) {
                return parseVersionOutput(text)
            }
        } catch {
            // Fall through to "unknown".
        }
        return "unknown"
    }

    /// Parses `siril-cli --version`'s real output. On this machine (Siril
    /// 1.4.4, macOS app bundle) that output is TWO lines, not one:
    /// ```
    /// Siril is started as macOS application
    /// siril 1.4.4
    /// ```
    /// The macOS-launch banner (line 1) has no digit in it at all -- taking
    /// "the first line" (the old behavior) silently stored that banner as
    /// `siril_version` on every real rating row instead of an actual
    /// version, which is exactly the bug found on the user's real database
    /// (`siril_version == "Siril is started as macOS application"` on all
    /// 586 rows). This instead:
    ///   1. picks the first line that mentions "siril" (case-insensitive)
    ///      AND contains a digit -- the real version line, wherever it
    ///      falls;
    ///   2. failing that, the LAST non-empty line that merely looks like a
    ///      version number (`\d+\.\d+`), in case some other Siril build
    ///      never says "siril" by name;
    ///   3. failing that, `"unknown"` -- never the banner text.
    static func parseVersionOutput(_ text: String) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let match = lines.first(where: { line in
            line.range(of: "siril", options: .caseInsensitive) != nil
                && line.range(of: #"\d"#, options: .regularExpression) != nil
        }) {
            return match
        }

        if let match = lines.last(where: { line in
            line.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil
        }) {
            return match
        }

        return "unknown"
    }

    /// The Siril script text run against `imagePath`: loads the image, runs
    /// `findstar` (which logs a star-detection summary `parseFindstarOutput`
    /// can read back), then closes it. `requires` pins the minimum Siril
    /// version the script grammar assumes.
    ///
    /// `imagePath` is interpolated straight into a `load "..."` line, so a
    /// path containing an unescaped `"` could break out of that string and
    /// inject arbitrary Siril script commands. Rather than assume Siril's
    /// command DSL supports backslash-escaping inside quoted strings (it
    /// isn't documented either way, and guessing wrong would silently
    /// reopen the same injection while looking "fixed"), any path
    /// containing `"` or `\` is rejected outright -- neither character is
    /// expected in a real astrophotography library path.
    static func buildScript(imagePath: String) throws -> String {
        guard !containsSirilScriptInjectionRisk(imagePath) else {
            throw ProcessError.unsupportedPath(imagePath)
        }
        return """
        requires 1.2.0
        load "\(imagePath)"
        findstar
        close
        """
    }

    public func metrics(for url: URL, workDir: URL) throws -> StarMetrics {
        let script = try Self.buildScript(imagePath: url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-s", "-"]
        process.currentDirectoryURL = workDir

        let stdinPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        // Read on a background queue with a blocking `readDataToEndOfFile`,
        // which only returns once the pipe's write end is closed (i.e. the
        // process has exited or explicitly closed its stdout/stderr).
        // This sidesteps the classic race between a `readabilityHandler`
        // and `terminationHandler` firing in the "wrong" order -- there's
        // exactly one read, and it is complete by construction once it
        // returns.
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
            throw ProcessError.timedOut
        }
        process.waitUntilExit()

        let text = String(data: collected.data, encoding: .utf8) ?? ""
        guard let parsed = Self.parseFindstarOutput(text) else {
            throw ProcessError.unparsableOutput
        }
        return parsed
    }

    /// Thread-safe one-shot box for the merged stdout+stderr bytes, written
    /// once by the background read task in `metrics(for:workDir:)`.
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

    /// Parses Siril's `findstar` log output. Liberal by design — Siril's
    /// exact wording has changed across versions, so this looks for
    /// substrings/patterns rather than a fixed line format:
    ///   - star count: `Found <N> ... star(s)` — required; `nil` (parse
    ///     failure) if absent, since without a star count there's nothing
    ///     usable here at all. The real Siril 1.4 wording observed on this
    ///     machine is `"Found 5 Gaussian profile stars in image, channel #0
    ///     (FWHM 5.416091)"` -- extra words ("Gaussian profile") sit between
    ///     the count and "stars", which the old `Found\s+(\d+)\s+star`
    ///     pattern (requiring "star" immediately after the number) never
    ///     matched at all; this is the real cause of every rated frame's
    ///     `fwhm`/`roundness`/`star_count` coming back NULL on the real
    ///     library. The non-greedy `.*?` stays within one line (`.` never
    ///     matches a newline by default), so it can't accidentally reach
    ///     into an unrelated later line's "star" mention.
    ///   - FWHM: `FWHM[= ]<float>` (also matches the `(FWHM 3.42)` form) —
    ///     defaults to `0` if absent.
    ///   - roundness: `roundness[= ]<float>` — `nil` if absent (older Siril
    ///     builds don't always print it, and the real Siril 1.4 findstar
    ///     line above prints none at all), rather than a fabricated neutral
    ///     value that would silently pollute rating stats with data that was
    ///     never actually measured.
    static func parseFindstarOutput(_ output: String) -> StarMetrics? {
        guard let starCountText = firstMatch(pattern: #"Found\s+(\d+)\s+.*?\bstars?\b"#, in: output),
              let starCount = Int(starCountText)
        else {
            return nil
        }

        let fwhm = firstMatch(pattern: #"FWHM[=\s]+([0-9]+(?:\.[0-9]+)?)"#, in: output)
            .flatMap(Double.init) ?? 0
        let roundness = firstMatch(pattern: #"roundness[=\s]+([0-9]+(?:\.[0-9]+)?)"#, in: output)
            .flatMap(Double.init)

        return StarMetrics(fwhm: fwhm, roundness: roundness, starCount: starCount)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[matchRange])
    }
}
