import Foundation

/// Fixity ("bitrot") verification (R11-T14/F9): re-hashes every tracked,
/// non-missing file that already has a cached `content_hash` (written by
/// `DuplicateFinder`) and compares the freshly computed SHA-256 against the
/// stored value.
///
/// Normal verification NEVER writes back to `files.content_hash` -- a
/// mismatch is only ever surfaced as a `Finding` for a human to act on
/// (restore the file from backup); the tool never "fixes" a hash mismatch by
/// adopting the new hash as ground truth, since that would silently launder
/// real corruption into the next run's baseline. Read-only against the
/// library in every sense. The separate, explicit `baseline(...)` operation
/// is the sole exception: it fills only previously missing hashes in Astro
/// Tool's DB and still never changes an image file.
///
/// Files that have never been hashed at all (no same-size sibling ever
/// triggered `DuplicateFinder`'s hashing, or the file was added after the
/// library's last audit) are silently skipped -- `verify` only ever
/// RE-checks a hash that already exists, it never computes one for the
/// first time. Users can opt into `baseline(...)` first, with coverage shown
/// by `coverage(...)`, so "not yet baselined" is never confused with "OK".
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
        /// The hash differs, the `mtime` differs, but the `size` does NOT
        /// (R12-U3/4) -- e.g. a tool rewriting a FITS header in place
        /// (same byte count, fresh timestamp) rather than a plain resave.
        /// This CAN be a legitimate in-place metadata edit, but unlike
        /// `.modified` it's not the clean "both changed" shape either, so
        /// it's surfaced as suspicious rather than waved through as
        /// `.modified` or escalated to `.contentChanged`'s "corruption
        /// suspect" -- worth a human's attention, not the CLI's exit-5
        /// "confirmed corruption" signal.
        case modifiedInPlace(oldHash: String, newHash: String)
        /// The hash differs, and the file's `mtime`/`size` do NOT differ
        /// from what's on record AT ALL (or only the `size` does, with the
        /// `mtime` unchanged -- itself even harder to explain than the
        /// `.modifiedInPlace` case above) -- nothing about the file's
        /// recorded metadata explains why its bytes changed, which is
        /// exactly what silent disk-level corruption (bitrot) looks like:
        /// the file manager never touched it, so mtime/size stayed put (or
        /// only size moved without the mtime the OS would normally bump
        /// alongside it), yet the bytes did not.
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
        /// R12-U3/4: files whose `mtime` changed but `size` didn't -- see
        /// `FileStatus.modifiedInPlace`'s own doc comment. A sibling count
        /// to `modified`/`contentChanged`, not a subset of either.
        public let modifiedInPlace: Int
        public let readErrors: Int

        public init(checked: Int, ok: Int, contentChanged: Int, modified: Int, modifiedInPlace: Int = 0, readErrors: Int) {
            self.checked = checked
            self.ok = ok
            self.contentChanged = contentChanged
            self.modified = modified
            self.modifiedInPlace = modifiedInPlace
            self.readErrors = readErrors
        }

        private enum CodingKeys: String, CodingKey {
            case checked, ok, contentChanged, modified, modifiedInPlace, readErrors
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            checked = try values.decode(Int.self, forKey: .checked)
            ok = try values.decode(Int.self, forKey: .ok)
            contentChanged = try values.decode(Int.self, forKey: .contentChanged)
            modified = try values.decode(Int.self, forKey: .modified)
            modifiedInPlace = try values.decodeIfPresent(Int.self, forKey: .modifiedInPlace) ?? 0
            readErrors = try values.decode(Int.self, forKey: .readErrors)
        }
    }

    /// Additive metadata envelope persisted in `runs.config_json` for a
    /// verify run. `summary == nil` represents an older/incomplete run.
    public struct RunMetadata: Codable, Sendable {
        public let astroConfig: AstroConfig
        public let samplePercent: Int?
        public let summary: Summary?

        public init(astroConfig: AstroConfig, samplePercent: Int?, summary: Summary?) {
            self.astroConfig = astroConfig
            self.samplePercent = samplePercent
            self.summary = summary
        }
    }

    /// Decodes the current metadata envelope and also accepts legacy rows
    /// whose `config_json` was a plain `AstroConfig`.
    public static func decodeRunMetadata(_ json: String?) throws -> RunMetadata? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let metadata = try? decoder.decode(RunMetadata.self, from: data) {
            return metadata
        }
        if let legacyConfig = try? decoder.decode(AstroConfig.self, from: data) {
            return RunMetadata(astroConfig: legacyConfig, samplePercent: nil, summary: nil)
        }
        return nil
    }

    private static func encodeRunMetadata(_ metadata: RunMetadata) throws -> String {
        let data = try JSONEncoder().encode(metadata)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AstroError.databaseError("verify run metadata is not valid UTF-8")
        }
        return json
    }

    /// How much of one library scope has a stored SHA-256 baseline. The
    /// complement (`unhashed`) and percentage are derived so CLI and app
    /// cannot disagree about coverage wording.
    public struct Coverage: Codable, Equatable, Sendable {
        public let tracked: Int
        public let hashed: Int

        public init(tracked: Int, hashed: Int) {
            self.tracked = tracked
            self.hashed = hashed
        }

        public var unhashed: Int { max(0, tracked - hashed) }
        public var percent: Double {
            tracked == 0 ? 0 : Double(hashed) * 100.0 / Double(tracked)
        }

        private enum CodingKeys: String, CodingKey {
            case tracked, hashed, unhashed, percent
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            tracked = try values.decode(Int.self, forKey: .tracked)
            hashed = try values.decode(Int.self, forKey: .hashed)
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(tracked, forKey: .tracked)
            try values.encode(hashed, forKey: .hashed)
            try values.encode(unhashed, forKey: .unhashed)
            try values.encode(percent, forKey: .percent)
        }
    }

    /// Fast DB-only coverage query, sharing the exact target/path scoping
    /// used by verify and baseline selection.
    public static func coverage(
        db: Database,
        target: String? = nil,
        path: String? = nil
    ) throws -> Coverage {
        let tracked = try db.countTrackedFiles(target: target, pathPrefix: path)
        let hashed = try db.countHashedFiles(target: target, pathPrefix: path)
        return Coverage(tracked: tracked, hashed: hashed)
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
    /// `beginOperation`/`progressText` plumbing handle it identically. Also
    /// mirrors `Rater.rate`'s own `throws` widening (R12-W3): a caller
    /// (`AuditRunCommand`) can turn a `throw CancellationError()` inside its
    /// own wrapping closure into a stop that lands BETWEEN two files, with
    /// every file reported so far already reflected in `results` -- never
    /// mid-file. Source-compatible with every existing non-throwing closure
    /// literal call site (Swift widens a non-throwing closure to a `throws`
    /// parameter automatically).
    public static func verify(
        db: Database,
        config: AstroConfig,
        target: String? = nil,
        path: String? = nil,
        samplePercent: Int? = nil,
        seed: UInt64? = nil,
        progress: (@Sendable (Int, Int) throws -> Void)? = nil
    ) throws -> [FileResult] {
        let files = try eligibleFiles(db: db, config: config, target: target, path: path, samplePercent: samplePercent, seed: seed)
        guard !files.isEmpty else { return [] }

        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let total = files.count
        var done = 0
        var results: [FileResult] = []
        results.reserveCapacity(files.count)

        for file in files {
            // `eligibleFiles` already filtered to non-nil `contentHash`, so
            // this is never actually nil -- guarding rather than force-
            // unwrapping just to stay defensive against a future caller
            // building `files` some other way.
            if let storedHash = file.contentHash {
                let fileURL = root.appendingPathComponent(file.path)
                do {
                    let currentHash = try autoreleasepool { try DuplicateFinder.sha256Hash(of: fileURL) }
                    if currentHash == storedHash {
                        results.append(FileResult(file: file, status: .ok))
                    } else {
                        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        let currentSize = resourceValues.fileSize.map(Int64.init)
                        let currentMTime = resourceValues.contentModificationDate?.timeIntervalSince1970
                        results.append(FileResult(
                            file: file,
                            status: classifyMismatch(
                                file: file,
                                oldHash: storedHash,
                                newHash: currentHash,
                                currentSize: currentSize,
                                currentMTime: currentMTime
                            )
                        ))
                    }
                } catch {
                    results.append(FileResult(file: file, status: .readError(describeReadError(error))))
                }
            }
            // Deliberately OUTSIDE any `defer` (a `defer` body cannot itself
            // `throw`): this is the one point between two files' work where
            // a throwing `progress` can stop the batch, with this file's
            // outcome already durably appended to `results`.
            done += 1
            try progress?(done, total)
        }
        return results
    }

    /// Aggregate counts over `verify(...)`'s own results.
    public static func summarize(_ results: [FileResult]) -> Summary {
        var ok = 0, contentChanged = 0, modified = 0, modifiedInPlace = 0, readErrors = 0
        for result in results {
            switch result.status {
            case .ok: ok += 1
            case .contentChanged: contentChanged += 1
            case .modified: modified += 1
            case .modifiedInPlace: modifiedInPlace += 1
            case .readError: readErrors += 1
            }
        }
        return Summary(
            checked: results.count, ok: ok, contentChanged: contentChanged, modified: modified,
            modifiedInPlace: modifiedInPlace, readErrors: readErrors
        )
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
            case .modifiedInPlace(let oldHash, let newHash):
                return Finding(
                    severity: .suspicious,
                    category: "modified-in-place",
                    path: result.file.path,
                    message: "a fájl módosítási ideje megváltozott, a mérete nem, mégis más a tartalom-hash — "
                        + "lehet helyben történő (pl. FITS-fejléc-) felülírás, de gyanús is lehet "
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
                // R12-U3/4: a read error couldn't confirm OR refute the
                // file's integrity (unlike `.contentChanged`, there's no
                // confirmed mismatch here) -- `.suspicious`, not
                // `.sureError`, matching the CLI's own exit-code contract
                // (a read error never triggers the exit-5 "confirmed
                // corruption" path, see `cmdVerify`).
                return Finding(
                    severity: .suspicious,
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
        progress: (@Sendable (Int, Int) throws -> Void)? = nil
    ) throws -> (runID: Int64, results: [FileResult], findings: [Finding]) {
        let initialMetadata = RunMetadata(
            astroConfig: config, samplePercent: samplePercent, summary: nil
        )
        let runID = try db.beginRun(
            kind: "verify",
            root: config.rootPath,
            configJSON: try encodeRunMetadata(initialMetadata)
        )

        let results = try verify(db: db, config: config, target: target, path: path, samplePercent: samplePercent, seed: seed, progress: progress)
        let resultFindings = findings(from: results)
        for finding in resultFindings {
            try db.insertFinding(runID: runID, finding)
        }
        let completedMetadata = RunMetadata(
            astroConfig: config,
            samplePercent: samplePercent,
            summary: summarize(results)
        )
        try db.updateRunConfig(id: runID, configJSON: try encodeRunMetadata(completedMetadata))
        try db.finishRun(id: runID)
        // Same B20 retention idea as `AuditEngine.run`'s own call -- kept to
        // its own `"verify"` kind so it never touches `"audit"`'s findings
        // (or vice versa); best-effort, a pruning failure must never turn
        // an otherwise-successful verify into a reported error.
        try? db.pruneFindings(keepRuns: 3, kind: "verify")

        return (runID, results, resultFindings)
    }

    // MARK: - Baseline (R12-U3/5)

    /// One baseline-hashing outcome: either the freshly computed hash was
    /// stored, or the file couldn't be read at all (mirrors `FileResult`'s
    /// own shape, minus the "compare against a stored hash" step baselining
    /// has nothing to compare against yet).
    public struct BaselineResult: Codable, Equatable, Sendable {
        public let path: String
        public let readError: String?

        public init(path: String, readError: String?) {
            self.path = path
            self.readError = readError
        }
    }

    /// Every tracked, non-missing file that has NEVER been hashed at all
    /// (`content_hash IS NULL`) -- the complement of `eligibleFiles(...)`'s
    /// own `contentHash != nil` filter, narrowed by `target`/`path` the same
    /// way. This is exactly the "coverage gap" the app's confirmation sheet
    /// wants a percentage for (`countHashedFiles` / `countTrackedFiles`) and
    /// `baseline(...)` below re-hashes.
    public static func baselineEligibleFiles(
        db: Database,
        config: AstroConfig,
        target: String? = nil,
        path: String? = nil
    ) throws -> [FileRecord] {
        var files = try db.allFiles(includeMissing: false).filter { $0.contentHash == nil }
        if let target {
            files = files.filter { $0.target == target }
        }
        if let path {
            files = files.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        }
        files.sort { $0.path < $1.path }
        return files
    }

    /// R12-U3/5's "Hiányzó ellenőrző-összegek pótlása": computes and STORES
    /// a SHA-256 for every `baselineEligibleFiles(...)` file -- unlike every
    /// other function in this type, this DOES write to `files.content_hash`
    /// (via `Database.upsertFile`, the same write-back path
    /// `DuplicateFinder` already uses), since there is no prior hash here to
    /// preserve as ground truth: an unhashed file has no baseline for
    /// `verify(...)` to compare against on a future run, and this is the
    /// one-time step that gives it one. Still read-only against the file's
    /// own bytes -- nothing here renames, moves, or rewrites the file
    /// itself, only reads it to compute the hash.
    ///
    /// A per-file read failure is collected into the returned array rather
    /// than aborting the whole batch (same "keep going" shape `verify(...)`
    /// itself has for a mid-run error) -- one unreadable file must not stop
    /// every OTHER file in scope from getting its baseline hash.
    /// `progress`, when given, mirrors `verify(...)`'s own `(completedCount,
    /// totalCount)` contract, including its `throws` widening (R12-W3): a
    /// throw lands between two files, after the current one's hash (if any)
    /// is already durably `upsertFile`d.
    public static func baseline(
        db: Database,
        config: AstroConfig,
        target: String? = nil,
        path: String? = nil,
        progress: (@Sendable (Int, Int) throws -> Void)? = nil
    ) throws -> (hashed: Int, errors: [BaselineResult]) {
        let files = try baselineEligibleFiles(db: db, config: config, target: target, path: path)
        guard !files.isEmpty else { return (0, []) }

        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)
        let total = files.count
        var done = 0
        var hashed = 0
        var errors: [BaselineResult] = []

        for file in files {
            let fileURL = root.appendingPathComponent(file.path)
            do {
                let hash = try autoreleasepool { try DuplicateFinder.sha256Hash(of: fileURL) }
                var updated = file
                updated.contentHash = hash
                try db.upsertFile(updated)
                hashed += 1
            } catch {
                errors.append(BaselineResult(path: file.path, readError: describeReadError(error)))
            }
            // Deliberately OUTSIDE any `defer` -- see `verify(...)`'s own
            // identical comment above.
            done += 1
            try progress?(done, total)
        }
        return (hashed, errors)
    }

    // MARK: - Helpers

    static func classifyMismatch(
        file: FileRecord,
        oldHash: String,
        newHash: String,
        currentSize: Int64?,
        currentMTime: Double?
    ) -> FileStatus {
        guard let currentSize, let currentMTime else {
            return .readError("a fájl mérete vagy módosítási ideje nem olvasható; az eltérés nem minősíthető")
        }

        let sizeChanged = currentSize != file.size
        // Same 1-second tolerance `LibraryScanner` uses for unchanged files.
        let mtimeChanged = abs(currentMTime - file.mtime) > 1.0
        if sizeChanged && mtimeChanged {
            return .modified(oldHash: oldHash, newHash: newHash)
        }
        if mtimeChanged && !sizeChanged {
            return .modifiedInPlace(oldHash: oldHash, newHash: newHash)
        }
        return .contentChanged(oldHash: oldHash, newHash: newHash)
    }

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
