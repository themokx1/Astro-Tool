import Foundation

/// A single light frame's rating result, as returned by `Rater.rate`.
///
/// `saturatedFraction`, `exptime`, and `sessionSubdir` were added after the
/// initial release. They're all `Optional`, so Swift's synthesized
/// `Codable` conformance decodes them via `decodeIfPresent` -- JSON produced
/// before these fields existed (e.g. a cached CLI `--json` capture) still
/// decodes fine, with all three simply `nil`.
public struct FrameScore: Codable, Sendable {
    public var path: String
    public var score: Double
    public var isOutlier: Bool
    public var metrics: StarMetrics?
    public var background: Double?
    public var saturatedFraction: Double?
    public var exptime: Double?
    /// The path component(s) between the session date dir and the filename,
    /// e.g. `"lights"` or `"lights/Junk"` -- `nil` when the frame sits
    /// directly in the date dir with no role subfolder. Lets a user's own
    /// triage subfolders (a hand-made "Junk" under `lights/`) show up
    /// directly in the quality table instead of only being visible by
    /// reading the full path.
    public var sessionSubdir: String?

    /// The filename only (last path component) -- computed, not stored, so
    /// it never affects `Codable` (old JSON without it still decodes, and
    /// there's no key to omit).
    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public init(
        path: String,
        score: Double,
        isOutlier: Bool,
        metrics: StarMetrics?,
        background: Double?,
        saturatedFraction: Double? = nil,
        exptime: Double? = nil,
        sessionSubdir: String? = nil
    ) {
        self.path = path
        self.score = score
        self.isOutlier = isOutlier
        self.metrics = metrics
        self.background = background
        self.saturatedFraction = saturatedFraction
        self.exptime = exptime
        self.sessionSubdir = sessionSubdir
    }
}

/// Rates the light frames of one target (optionally scoped to a single
/// session date) by combining always-available native pixel statistics
/// (`NativeStats`) with optional Siril-derived star metrics
/// (`StarMetricsProvider`), persisting everything through `Database` so an
/// unchanged frame is never re-measured on a later call.
///
/// ## Caching
/// Each frame's `inputSig` is `"<size>-<mtime rounded to Int>"`. If the
/// persisted rating for a frame already carries that exact signature, its
/// stored metrics/background/score are reused as-is — neither `NativeStats`
/// nor the provider is invoked for that frame.
///
/// ## Scoring
/// Once every frame in the batch has native + (optional) star metrics on
/// record, frames are first split into exposure groups -- fits_meta
/// `exptime` rounded to 0.1s, with every frame lacking an `exptime` sharing
/// one common group -- mirroring the proven `tools/rate/LightFrameRater.py`
/// triage tool, which always compares frames of the same exposure time
/// separately rather than pooling the whole session. Within each group,
/// each metric is z-scored (mean/std over the frames *in that group* that
/// have a value for it), oriented so higher-is-better (FWHM and background
/// are negated), weighted by `config.rating.weights`, and averaged over
/// only the metrics actually available for that frame (i.e. weights are
/// renormalized per frame rather than assuming all four are always present
/// — a `nil` provider means only `background` contributes). A frame is
/// `isOutlier` when its score falls more than `config.rating.outlierZScore`
/// below zero (only the "worse than its group" direction is flagged). A
/// group with a single frame gets `z == 0` for every metric (the usual
/// std-is-zero guard), same as a batch-wide singleton always did.
///
/// ## Concurrency
/// Processing is strictly sequential for this version.
/// `config.rating.workers` is read by nothing here yet — it's reserved for
/// a future parallel implementation once the provider call (the expensive
/// part, one Siril subprocess per frame) is made safe to fan out.
public final class Rater {
    private let db: Database
    private let config: AstroConfig
    private let provider: StarMetricsProvider?

    public init(db: Database, config: AstroConfig, provider: StarMetricsProvider?) {
        self.db = db
        self.config = config
        self.provider = provider
    }

    /// Rates every scanned, non-missing light frame under `area == .sessions`
    /// whose `target` matches, further narrowed to `date` when given.
    /// Returns `[]` immediately if no such frames are on record. `progress`,
    /// when given, is called once per frame as it finishes (cache hit,
    /// freshly measured, or skipped for being unreadable) with
    /// `(completedCount, totalCount)`. `force`, when `true`, treats every
    /// frame as a cache miss -- see `rate(target:date:progress:)`'s own
    /// cache-hit/staleness doc comment above the loop for why a plain
    /// `inputSig` match isn't always enough on its own.
    public func rate(
        target: String,
        date: String? = nil,
        force: Bool = false,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> [FrameScore] {
        let frames = try db.allFiles(includeMissing: false).filter { file in
            file.area == .sessions && file.role == .light && file.target == target
                && (date == nil || file.sessionDate == date)
        }
        guard !frames.isEmpty else { return [] }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astrotool-siril-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { cleanupWorkDir(workDir) }

        let total = frames.count
        var done = 0
        var rated: [(file: FileRecord, record: RatingRecord, exptime: Double?)] = []
        rated.reserveCapacity(frames.count)

        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)

        for file in frames {
            defer {
                done += 1
                progress?(done, total)
            }
            guard let fileID = file.id else { continue }

            // Needed for exposure-group scoring regardless of cache hit/miss.
            let exptime = try db.fitsMeta(fileID: fileID)?.exptime

            let inputSig = "\(file.size)-\(Int(file.mtime.rounded()))"
            let cached = try db.rating(fileID: fileID)
            let cacheValid = !force && cached != nil && cached!.inputSig == inputSig
            let isFZ = file.ext.lowercased() == "fz"

            if cacheValid {
                let cachedRow = cached!
                let stale = Self.staleness(of: cachedRow, isFZ: isFZ, providerAvailable: provider != nil)

                if !stale.native && !stale.metrics {
                    // TRUE cache hit -- reuse the stored row untouched,
                    // neither `NativeStats` nor the provider is invoked.
                    rated.append((file, cachedRow, exptime))
                    continue
                }

                // Self-heal (item 1's real bug): this row's `inputSig`
                // matches, but it's missing data a healthy pipeline would
                // have filled in -- e.g. a rating written before `bg_00..11`
                // existed, or before the Siril adapter was fixed. Only the
                // missing PART is (re)computed; every already-present value
                // that this pass doesn't touch is carried over unchanged
                // (never erased) via `RatingRecord.merging`.
                let url = root.appendingPathComponent(file.path)

                var nativeStats: NativeFrameStats?
                if stale.native {
                    do {
                        nativeStats = try autoreleasepool { try NativeStats.compute(url: url) }
                    } catch {
                        continue
                    }
                }

                var metrics: StarMetrics?
                if stale.metrics {
                    metrics = try? provider?.metrics(for: url, workDir: workDir)
                }

                let record = cachedRow.merging(
                    nativeStats: nativeStats, metrics: metrics,
                    sirilVersion: provider?.version, inputSig: inputSig
                )
                try db.upsertRating(record)
                rated.append((file, record, exptime))
                continue
            }

            let url = root.appendingPathComponent(file.path)

            // `.fz` (Rice-compressed) frames are never handed to
            // `NativeStats` -- it rejects them anyway (see
            // `NativeStats.compute`'s compressed-layout guard), but this is
            // defense in depth: don't even attempt the read. Siril *can*
            // read `.fz` directly, so the provider still runs; the frame is
            // still rated, just with `background`/`saturatedFraction` left
            // `nil` (scoring already renormalizes weights over whichever
            // metrics are actually present for a frame).
            var nativeStats: NativeFrameStats?
            if !isFZ {
                do {
                    // `NativeStats.compute(url:)` loads the whole frame
                    // into memory to read its pixels. Wrapping just the
                    // call in `autoreleasepool` ensures that buffer (and
                    // any autoreleased bridging temporaries underneath it)
                    // is freed as soon as this frame's stats are computed,
                    // rather than lingering for the rest of a large batch
                    // -- `nativeStats` itself is a plain struct with no
                    // Foundation object references, so it's safe to return
                    // out of the pool.
                    nativeStats = try autoreleasepool { try NativeStats.compute(url: url) }
                } catch {
                    // Can't even read the pixel data -- skip this frame but
                    // keep rating the rest of the batch.
                    continue
                }
            }

            let metrics = try? provider?.metrics(for: url, workDir: workDir)

            let record = RatingRecord(
                fileID: fileID,
                fwhm: metrics?.fwhm,
                roundness: metrics?.roundness,
                starCount: metrics?.starCount,
                background: nativeStats?.backgroundMedian,
                saturatedFraction: nativeStats?.saturatedFraction,
                score: nil,
                ratedAt: Date().timeIntervalSince1970,
                sirilVersion: provider?.version,
                inputSig: inputSig,
                bg00: nativeStats?.backgroundMedian00,
                bg01: nativeStats?.backgroundMedian01,
                bg10: nativeStats?.backgroundMedian10,
                bg11: nativeStats?.backgroundMedian11
            )
            try db.upsertRating(record)
            rated.append((file, record, exptime))
        }

        guard !rated.isEmpty else { return [] }

        return try score(rated)
    }

    // MARK: - Cache self-heal (R7-B6, item 1)

    /// Which parts of an `inputSig`-matching cached row still need
    /// (re)computing. The real bug this guards against: a rating row can
    /// have the RIGHT `inputSig` (the underlying file hasn't changed) while
    /// still carrying data from a broken era of the pipeline -- ratings
    /// written before `bg_00..11` existed, or written while the Siril
    /// adapter was silently failing to parse its own output (see
    /// `shouldWarnNoMetrics`'s doc comment for that real incident). Plain
    /// `inputSig` equality treats that row as a full cache hit forever,
    /// since the file itself never changes again -- this is what let 141
    /// real frames sit at "Siril metrika: 0/141" no matter how many times
    /// `rate` re-ran.
    struct Staleness {
        /// ANY of `bg_00`/`bg_01`/`bg_10`/`bg_11` is `nil` while the file is
        /// one `NativeStats` could actually analyze (a non-`.fz` FITS) -- the
        /// native-stats half of the row was never (fully) computed. Checking
        /// all four, not just `bg_00`, is what lets a row written while
        /// `NativeStats`'s sampling only ever populated the even-column
        /// buckets (`bg_00`/`bg_10`) self-heal here once that bug is fixed --
        /// `bg_00` alone being non-`nil` used to look like a complete row.
        var native: Bool
        /// Every star-metric column is `nil`, a provider is available RIGHT
        /// NOW to try filling them, AND this row isn't `source == "dss"` --
        /// a `DSSIngest`-written row's `nil` metrics-columns-when-`source`-
        /// is-set-to-"dss" case never applies here (dss rows always carry
        /// real metrics), but the explicit `source == nil` check is what
        /// stops a genuinely dss-sourced row's native-only gap (case b)
        /// from also re-triggering a Siril run over data DSS already
        /// supplied.
        var metrics: Bool
    }

    static func staleness(of cached: RatingRecord, isFZ: Bool, providerAvailable: Bool) -> Staleness {
        let native = !isFZ && (cached.bg00 == nil || cached.bg01 == nil || cached.bg10 == nil || cached.bg11 == nil)
        let metricsAllNil = cached.fwhm == nil && cached.roundness == nil && cached.starCount == nil
        let metrics = metricsAllNil && providerAvailable && cached.source == nil
        return Staleness(native: native, metrics: metrics)
    }

    // MARK: - Scoring

    private struct MetricStats {
        var mean: Double
        var std: Double
    }

    /// Which exposure group a frame belongs to for scoring purposes: the
    /// frame's session date (so rating a whole target across many nights
    /// without `--date` never pools different nights' sky conditions into
    /// one z-score population) crossed with its nominal exptime (see
    /// `NominalExposure`, which absorbs float noise like 29.9s vs. 30.0s) --
    /// or `nominalTenths == nil` for every frame with no `exptime` at all,
    /// one single shared group per date (not one singleton group each, which
    /// would force every such frame's z-score to 0).
    private struct ExposureGroupKey: Hashable {
        var sessionDate: String?
        var nominalTenths: Int?
    }

    private static func exposureGroupKey(sessionDate: String?, exptime: Double?) -> ExposureGroupKey {
        guard let exptime else { return ExposureGroupKey(sessionDate: sessionDate, nominalTenths: nil) }
        let nominal = NominalExposure.nominal(exptime)
        return ExposureGroupKey(sessionDate: sessionDate, nominalTenths: Int((nominal * 10).rounded()))
    }

    /// Splits `rated` into exposure groups (see `ExposureGroupKey`) and
    /// scores each group independently, so a frame's z-scores only ever
    /// compare it against other frames shot the same night at the same
    /// nominal exposure time.
    private func score(_ rated: [(file: FileRecord, record: RatingRecord, exptime: Double?)]) throws -> [FrameScore] {
        var groups: [ExposureGroupKey: [(file: FileRecord, record: RatingRecord, exptime: Double?)]] = [:]
        for entry in rated {
            let key = Self.exposureGroupKey(sessionDate: entry.file.sessionDate, exptime: entry.exptime)
            groups[key, default: []].append((entry.file, entry.record, entry.exptime))
        }

        var results: [FrameScore] = []
        results.reserveCapacity(rated.count)
        for groupRated in groups.values {
            results.append(contentsOf: try scoreGroup(groupRated))
        }

        return results.sorted { $0.score > $1.score }
    }

    private func scoreGroup(_ rated: [(file: FileRecord, record: RatingRecord, exptime: Double?)]) throws -> [FrameScore] {
        let weights = config.rating.weights

        let fwhmStats = Self.metricStats(rated.compactMap { $0.record.fwhm })
        let roundnessStats = Self.metricStats(rated.compactMap { $0.record.roundness })
        let starCountStats = Self.metricStats(rated.compactMap { $0.record.starCount.map(Double.init) })
        let backgroundStats = Self.metricStats(rated.compactMap { $0.record.background })

        var results: [FrameScore] = []
        results.reserveCapacity(rated.count)

        for (file, original, exptime) in rated {
            var record = original
            var weightedSum = 0.0
            var weightTotal = 0.0

            if let fwhm = record.fwhm {
                let weight = weights["fwhm"] ?? 0
                weightedSum += weight * -Self.zScore(fwhm, stats: fwhmStats) // lower fwhm is better
                weightTotal += weight
            }
            if let roundness = record.roundness {
                let weight = weights["roundness"] ?? 0
                weightedSum += weight * Self.zScore(roundness, stats: roundnessStats) // higher is better
                weightTotal += weight
            }
            if let starCount = record.starCount {
                let weight = weights["starCount"] ?? 0
                weightedSum += weight * Self.zScore(Double(starCount), stats: starCountStats) // higher is better
                weightTotal += weight
            }
            if let background = record.background {
                let weight = weights["background"] ?? 0
                weightedSum += weight * -Self.zScore(background, stats: backgroundStats) // lower is better
                weightTotal += weight
            }

            let finalScore = weightTotal > 0 ? weightedSum / weightTotal : 0
            record.score = finalScore
            try db.upsertRating(record)

            let metrics: StarMetrics? = {
                // `roundness` is deliberately NOT required here (unlike
                // `fwhm`/`starCount`): `SirilCLI.parseFindstarOutput` now
                // returns `nil` roundness when Siril's log doesn't print it,
                // rather than fabricating a neutral 0.5 -- that shouldn't
                // hide the real fwhm/starCount a frame does have.
                guard let fwhm = record.fwhm, let starCount = record.starCount else { return nil }
                return StarMetrics(fwhm: fwhm, roundness: record.roundness, starCount: starCount)
            }()

            results.append(
                FrameScore(
                    path: file.path,
                    score: finalScore,
                    isOutlier: finalScore < -config.rating.outlierZScore,
                    metrics: metrics,
                    background: record.background,
                    saturatedFraction: record.saturatedFraction,
                    exptime: exptime,
                    sessionSubdir: Self.sessionSubdir(path: file.path)
                )
            )
        }

        return results.sorted { $0.score > $1.score }
    }

    /// The path component(s) between the session date dir and the filename
    /// of a `sessions/<target>/<date>/...` path, e.g. `"lights"` for
    /// `sessions/M31/2026-01-01/lights/a.fit` or `"lights/Junk"` for
    /// `sessions/M31/2026-01-01/lights/Junk/a.fit`. `nil` when the frame
    /// sits directly in the date dir (no role subfolder at all) or the path
    /// doesn't even have the expected `area/target/date/filename` depth --
    /// mirrors `PathClassifier`'s "only area/target/date are positionally
    /// consulted, everything after is untouched" stance, just surfacing that
    /// untouched remainder for display instead of discarding it.
    static func sessionSubdir(path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count > 4 else { return nil }
        let middle = components[3..<(components.count - 1)]
        return middle.joined(separator: "/")
    }

    /// Mean/std over whichever frames in the batch have a value for this
    /// metric. `std == 0` (a single sample, or every value identical) is
    /// the div-by-zero guard `zScore` checks for.
    private static func metricStats(_ values: [Double]) -> MetricStats {
        guard !values.isEmpty else { return MetricStats(mean: 0, std: 0) }
        guard values.count > 1 else { return MetricStats(mean: values[0], std: 0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return MetricStats(mean: mean, std: variance.squareRoot())
    }

    private static func zScore(_ value: Double, stats: MetricStats) -> Double {
        guard stats.std > 0 else { return 0 }
        return (value - stats.mean) / stats.std
    }

    // MARK: - Silent-failure guard (item D.3)

    /// Structural guard against the real bug found on this machine: a
    /// `StarMetricsProvider` (in practice, `SirilCLI`) that quietly fails to
    /// parse its own tool's output looks EXACTLY like a healthy run that
    /// simply found nothing -- every `FrameScore.metrics` comes back `nil`
    /// either way, and nothing throws. `true` exactly when a provider WAS
    /// supplied (a `nil` provider, e.g. `--no-siril`, is a deliberate choice,
    /// not a failure) and NOT ONE frame in a batch large enough to be
    /// meaningful (`>= 5`, so a 1-2 frame `--date` rate of genuinely
    /// starless calibration-adjacent frames doesn't cry wolf) came back with
    /// any metrics at all. Callers (the `rate` CLI command) print a loud
    /// stderr warning when this fires -- silence is exactly what let the
    /// real bug go unnoticed across 586 rated frames.
    public static func shouldWarnNoMetrics(_ results: [FrameScore], providerWasUsed: Bool) -> Bool {
        guard providerWasUsed, results.count >= 5 else { return false }
        return results.allSatisfy { $0.metrics == nil }
    }

    // MARK: - Scratch dir cleanup

    /// Removes this batch's Siril scratch directory. This is the one place
    /// in the codebase allowed to call `removeItem`: it only ever deletes a
    /// path the guard below confirms is under
    /// `FileManager.default.temporaryDirectory` -- never anything in the
    /// scanned library, which this tool never deletes from.
    private func cleanupWorkDir(_ workDir: URL) {
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let target = workDir.standardizedFileURL.path
        guard target == tempRoot || target.hasPrefix(tempRoot + "/") else { return }
        try? FileManager.default.removeItem(at: workDir)
    }
}
