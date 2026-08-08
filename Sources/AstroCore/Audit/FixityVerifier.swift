import Foundation

/// Fixity ("bitrot") verification (R11-T14/F9): re-hashes every tracked,
/// non-missing file that already has a cached `content_hash` (written by
/// `DuplicateFinder`) and compares the freshly computed SHA-256 against the
/// stored value.
///
/// Unlike `DuplicateFinder`, this NEVER writes back to `files.content_hash`
/// -- a mismatch is only ever surfaced as a `Finding` for a human to act on
/// (restore the file from backup); the tool never "fixes" a hash mismatch by
/// adopting the new hash as ground truth, since that would silently launder
/// real corruption into the next run's baseline. Read-only against the
/// library in every sense: the only writes this subsystem makes are the
/// `runs`/`findings` rows in the app's own `.astro_tool` database (`run`
/// below), the same class of bookkeeping `AuditEngine.run` already does.
///
/// Files that have never been hashed at all (no same-size sibling ever
/// triggered `DuplicateFinder`'s hashing, or the file was added after the
/// library's last audit) are silently skipped -- `verify` only ever
/// RE-checks a hash that already exists, it never computes one for the
/// first time (that would just be `DuplicateFinder` with extra steps, and
/// would turn "never audited this file's content before" into a false "it
/// used to be fine").
public enum FixityVerifier {
    /// One file's outcome. `Equatable`/`Sendable` for straightforward
    /// testing and safe use from a detached `Task`.
    public enum FileStatus: Equatable, Sendable {
        /// The freshly computed hash matches the stored one.
        case ok
        /// The hash differs, but the file's `mtime` AND `size` BOTH differ
        /// from what's on record too -- a legitimate edit/resave, not
        /// bitrot. Informative, not an error: nothing here contradicts the
        /// file's own recorded metadata.
        case modified(oldHash: String, newHash: String)
        /// The hash differs, and the file's `mtime`/`size` do NOT both
        /// differ from what's on record (i.e. either both match, or only
        /// one of the two does) -- nothing about the file's recorded
        /// metadata explains why its bytes changed, which is exactly what
        /// silent disk-level corruption (bitrot) looks like: the file
        /// manager never touched it, so mtime/size stayed put, yet the
        /// bytes did not.
        case contentChanged(oldHash: String, newHash: String)
        /// The file could not be read (deleted since the last scan,
        /// permission revoked, ...) -- distinct from a hash mismatch,
        /// since this file's integrity couldn't be confirmed OR refuted.
        case readError(String)
    }

    /// One file's `FileRecord` (as read from the DB, i.e. reflecting
    /// whatever the last `scan`/`audit` recorded, not necessarily today's
    /// on-disk state) paired with its verification outcome.
    public struct FileResult: Sendable {
        public let file: FileRecord
        public let status: FileStatus

        public init(file: FileRecord, status: FileStatus) {
            self.file = file
            self.status = status
        }
    }

    /// Aggregate counts for the CLI's human summary line and the app's
    /// end-of-run toast. `Codable` so `astrotool verify --json` can encode
    /// it directly as a sibling of the findings list.
    public struct Summary: Codable, Equatable, Sendable {
        public let checked: Int
        public let ok: Int
        public let contentChanged: Int
        public let modified: Int
        public let readErrors: Int

        public init(checked: Int, ok: Int, contentChanged: Int, modified: Int, readErrors: Int) {
            self.checked = checked
            self.ok = ok
            self.contentChanged = contentChanged
            self.modified = modified
            self.readErrors = readErrors
        }
    }

    // MARK: - Seeded sampling

    /// SplitMix64 -- the standard tiny seedable generator: fast, decent
    /// distribution, pure integer arithmetic (no OS entropy involved), so
    /// the exact same seed reliably reproduces the exact same shuffle across
    /// runs and platforms. Used only when a caller supplies an explicit
    /// `seed` (tests, or a scripted reproducible sample); an unseeded call
    /// uses `SystemRandomNumberGenerator` instead, same as any other
    /// "actually random" sample would.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Every non-missing tracked file with a cached `content_hash`,
    /// narrowed by `target`/`path`, then by `samplePercent` if given -- the
    /// exact set `verify(...)` re-hashes, and what the app's confirmation
    /// sheet sizes its "N fájl" time estimate from (this is `public`
    /// specifically so the app/CLI can size that estimate without
    /// duplicating the filtering logic).
    ///
    /// `path`, when given, matches the file itself or anything nested under
    /// it (`path == p || path.hasPrefix(p + "/")`), the same subtree
    /// convention `Database.markMissing(underSubpath:)` already uses.
    /// `samplePercent` (1-100) takes a random subset of that size, sorted
    /// back to path order afterward so the caller's output stays
    /// deterministically ordered regardless of the sample; `100` (or `nil`)
    /// means "no sampling, check everything in scope". `seed`, when given,
    /// makes the sample itself deterministic too (tests; a real run leaves
    /// it `nil` for a genuinely random sample every time).
    public static func eligibleFiles(
        db: Database,
        config: AstroConfig,
        target: String? = nil,
        path: String? = nil,
        samplePercent: Int? = nil,
        seed: UInt64? = nil
    ) throws -> [FileRecord] {
        var files = try db.allFiles(includeMissing: false).filter { $0.contentHash != nil }

        if let target {
            files = files.filter { $0.target == target }
        }
        if let path {
            files = files.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        }
        files.sort { $0.path < $1.path }

        guard let samplePercent else { return files }
        let clamped = max(1, min(100, samplePercent))
        guard clamped < 100, !files.isEmpty else { return files }

        let sampleCount = max(1, Int((Double(files.count) * Double(clamped) / 100.0).rounded()))
        let sampled: [FileRecord]
        if let seed {
            var rng = SplitMix64(seed: seed)
            sampled = Array(files.shuffled(using: &rng).prefix(sampleCount))
        } else {
            var rng = SystemRandomNumberGenerator()
            sampled = Array(files.shuffled(using: &rng).prefix(sampleCount))
        }
        return sampled.sorted { $0.path < $1.path }
    }

    /// Re-hashes `eligibleFiles(...)` and classifies each result against its
    /// current on-disk `stat()`. Purely a read: opens and streams each
    /// file's bytes (via the same chunked, autoreleasepool'd SHA-256
    /// `DuplicateFinder` uses) but never writes to it, and never writes the
    /// freshly computed hash back to `files.content_hash`.
    ///
    /// `progress`, when given, is called once per file as it finishes with
    /// `(completedCount, totalCount)` -- mirrors `Rater.rate(...)`'s own
    /// progress contract, so both the CLI and the app's
    /// `beginOperation`/`progressText` plumbing handle it identically.
    public static func verify(
        db: Database,
        config: AstroConfig,
        target: String? = nil,
        path: String? = nil,
        samplePercent: Int? = nil,
        seed: UInt64? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> [FileResult] {
        let files = try eligibleFiles(db: db, config: config, target: target, path: path, samplePercent: samplePercent, seed: seed)
        guard !files.isEmpty else { return [] }

        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let total = files.count
        var done = 0
        var results: [FileResult] = []
        results.reserveCapacity(files.count)

        for file in files {
            defer {
                done += 1
                progress?(done, total)
            }
            // `eligibleFiles` already filtered to non-nil `contentHash`, so
            // this is never actually nil -- guarding rather than force-
            // unwrapping just to stay defensive against a future caller
            // building `files` some other way.
            guard let storedHash = file.contentHash else { continue }

            let fileURL = root.appendingPathComponent(file.path)
            do {
                let currentHash = try autoreleasepool { try DuplicateFinder.sha256Hash(of: fileURL) }
                if currentHash == storedHash {
                    results.append(FileResult(file: file, status: .ok))
                    continue
                }

                let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let currentSize = resourceValues?.fileSize.map(Int64.init)
                let currentMTime = resourceValues?.contentModificationDate?.timeIntervalSince1970

                // Same 1-second tolerance `LibraryScanner` itself uses to
                // decide a file is "unchanged" on rescan -- filesystem
                // mtimes aren't always sub-second-precise, so a difference
                // inside that tolerance must not read as "the file was
                // touched".
                let sizeChanged = currentSize.map { $0 != file.size } ?? false
                let mtimeChanged = currentMTime.map { abs($0 - file.mtime) > 1.0 } ?? false

                if sizeChanged && mtimeChanged {
                    results.append(FileResult(file: file, status: .modified(oldHash: storedHash, newHash: currentHash)))
                } else {
                    results.append(FileResult(file: file, status: .contentChanged(oldHash: storedHash, newHash: currentHash)))
                }
            } catch {
                results.append(FileResult(file: file, status: .readError(describeReadError(error))))
            }
        }
        return results
    }

    /// Aggregate counts over `verify(...)`'s own results.
    public static func summarize(_ results: [FileResult]) -> Summary {
        var ok = 0, contentChanged = 0, modified = 0, readErrors = 0
        for result in results {
            switch result.status {
            case .ok: ok += 1
            case .contentChanged: contentChanged += 1
            case .modified: modified += 1
            case .readError: readErrors += 1
            }
        }
        return Summary(checked: results.count, ok: ok, contentChanged: contentChanged, modified: modified, readErrors: readErrors)
    }

    /// Converts `verify(...)`'s per-file results into `Finding`s -- `.ok`
    /// results produce nothing (nothing to report); every other status
    /// produces exactly one finding. Per the iron rule (verify only ever
    /// reads and only ever marks), `suggestion` is always `nil` -- there is
    /// no automatic fix for a corrupted or unreadable file, the message
    /// says so explicitly, and it is always the human's job to restore from
    /// backup.
    public static func findings(from results: [FileResult]) -> [Finding] {
        results.compactMap { result -> Finding? in
            switch result.status {
            case .ok:
                return nil
            case .modified(let oldHash, let newHash):
                return Finding(
                    severity: .probablyIntentional,
                    category: "modified",
                    path: result.file.path,
                    message: "a fájl mérete és módosítási ideje is megváltozott az utolsó ellenőrzött állapot óta — "
                        + "feltehetően szándékos szerkesztés/felülírás, nem bitrot "
                        + "(régi hash: \(shortHash(oldHash)), új hash: \(shortHash(newHash)))",
                    suggestion: nil
                )
            case .contentChanged(let oldHash, let newHash):
                return Finding(
                    severity: .sureError,
                    category: "content-changed",
                    path: result.file.path,
                    message: "a fájl tartalma megváltozott, miközben a mérete és a módosítási ideje nem — "
                        + "néma korrupció (bitrot) gyanús "
                        + "(régi hash: \(shortHash(oldHash)), új hash: \(shortHash(newHash))). "
                        + "Az eszköz csak jelöl, nem javít: állítsd vissza a fájlt biztonsági mentésből.",
                    suggestion: nil
                )
            case .readError(let reason):
                return Finding(
                    severity: .sureError,
                    category: "verify-read-error",
                    path: result.file.path,
                    message: "nem sikerült beolvasni ellenőrzéshez: \(reason)",
                    suggestion: nil
                )
            }
        }
    }

    /// Runs `verify(...)`, persists its findings into a fresh `"verify"`-kind
    /// run (mirrors `AuditEngine.run`'s own begin/insert/finish shape), and
    /// returns everything a caller (CLI or app) needs: the run id, the raw
    /// per-file results (for the CLI's/app's own summary text), and the
    /// findings that were just persisted.
    public static func run(
        db: Database,
        config: AstroConfig,
        target: String? = nil,
        path: String? = nil,
        samplePercent: Int? = nil,
        seed: UInt64? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> (runID: Int64, results: [FileResult], findings: [Finding]) {
        let configData = try? JSONEncoder().encode(config)
        let configJSON = configData.flatMap { String(data: $0, encoding: .utf8) }
        let runID = try db.beginRun(kind: "verify", root: config.rootPath, configJSON: configJSON)

        let results = try verify(db: db, config: config, target: target, path: path, samplePercent: samplePercent, seed: seed, progress: progress)
        let resultFindings = findings(from: results)
        for finding in resultFindings {
            try db.insertFinding(runID: runID, finding)
        }
        try db.finishRun(id: runID)
        // Same B20 retention idea as `AuditEngine.run`'s own call -- kept to
        // its own `"verify"` kind so it never touches `"audit"`'s findings
        // (or vice versa); best-effort, a pruning failure must never turn
        // an otherwise-successful verify into a reported error.
        try? db.pruneFindings(keepRuns: 3, kind: "verify")

        return (runID, results, resultFindings)
    }

    // MARK: - Helpers

    private static func describeReadError(_ error: Error) -> String {
        if let astroError = error as? AstroError {
            switch astroError {
            case .pathNotFound:
                return "fájl nem található"
            case .accessDenied:
                return "hozzáférés megtagadva"
            default:
                return "\(astroError)"
            }
        }
        return (error as NSError).localizedDescription
    }

    private static func shortHash(_ hash: String) -> String {
        String(hash.prefix(12)) + "…"
    }
}
