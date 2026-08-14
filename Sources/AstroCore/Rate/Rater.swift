import Foundation

/// Exact comparison population used for one frame's relative score. The
/// session/exposure pair remains, but capture, resolved filter, setup, and
/// binning prevent physically different acquisitions from sharing a z-score
/// population merely because they happened on the same date.
public struct RatingCohortDescriptor: Codable, Sendable, Equatable, Hashable {
    public var sessionDate: String?
    public var nominalExposureSeconds: Double?
    public var captureGroupID: Int64?
    public var captureSlug: String?
    public var resolvedFilter: String?
    public var setupDescriptor: String?
    public var binning: String?

    public init(
        sessionDate: String? = nil,
        nominalExposureSeconds: Double? = nil,
        captureGroupID: Int64? = nil,
        captureSlug: String? = nil,
        resolvedFilter: String? = nil,
        setupDescriptor: String? = nil,
        binning: String? = nil
    ) {
        self.sessionDate = sessionDate
        self.nominalExposureSeconds = nominalExposureSeconds
        self.captureGroupID = captureGroupID
        self.captureSlug = captureSlug
        self.resolvedFilter = resolvedFilter
        self.setupDescriptor = setupDescriptor
        self.binning = binning
    }
}

/// A single light frame's rating result, as returned by `Rater.rate`.
///
/// `saturatedFraction`, `exptime`, `sessionSubdir`, and `dateObs` were added
/// after the initial release. They're all `Optional`, so Swift's
/// synthesized `Codable` conformance decodes them via `decodeIfPresent` --
/// JSON produced before these fields existed (e.g. a cached CLI `--json`
/// capture) still decodes fine, with all four simply `nil`.
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
    /// Raw `fits_meta.date_obs` for this frame (FITS or EXIF-style text,
    /// whichever the header carried) -- `nil` when the frame has no
    /// `fits_meta` row at all, or that row's `date_obs` column is empty.
    /// R10-B5: added so the Minőség segment's per-session FWHM-over-time
    /// trend chart has a capture timestamp per frame without a second
    /// per-file `fits_meta` query -- parse with `SessionTimeline.
    /// parseDateObs`, the same shared parser every OTHER DATE-OBS consumer
    /// in this package already uses, rather than hand-rolling a second one.
    public var dateObs: String?
    /// Per-metric z-score breakdown -- R11-T7 (F4), added the same
    /// additive-`Optional` way every other post-release field on this
    /// struct was (see this struct's own doc comment): `nil` for JSON
    /// captured before this field existed, and for any `FrameScore` built
    /// somewhere other than `Rater.score`/`Rater.cachedScores` (the only two
    /// producers that populate it, right before their own final sort).
    /// `OutlierBreakdown.breakdowns(for:)` is what actually computes this --
    /// see its own doc comment for why re-deriving it at query time (rather
    /// than persisting new DB columns) was the chosen approach.
    public var outlierBreakdown: OutlierBreakdown?
    /// The exact population this frame was compared with. Optional for JSON
    /// written before capture-aware rating existed.
    public var cohort: RatingCohortDescriptor?

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
        sessionSubdir: String? = nil,
        dateObs: String? = nil,
        outlierBreakdown: OutlierBreakdown? = nil,
        cohort: RatingCohortDescriptor? = nil
    ) {
        self.path = path
        self.score = score
        self.isOutlier = isOutlier
        self.metrics = metrics
        self.background = background
        self.saturatedFraction = saturatedFraction
        self.exptime = exptime
        self.sessionSubdir = sessionSubdir
        self.dateObs = dateObs
        self.outlierBreakdown = outlierBreakdown
        self.cohort = cohort
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
    /// `(completedCount, totalCount)`, and is now allowed to `throw` --
    /// R12-W3T1 widened this from a plain non-throwing closure the exact
    /// same way `SensorProfiler.measure`'s own `progress` already does, so a
    /// caller (`FrameRatingCommand`) can turn a `throw CancellationError()`
    /// inside its own wrapping closure into a stop that lands BETWEEN two
    /// frames -- never mid-frame, since the throw only happens right after
    /// one frame's outcome (cache hit, self-heal, fresh measurement, or
    /// unreadable-skip) is already durably upserted (or was already durable
    /// from a previous run) and BEFORE the next frame's own work starts. This
    /// is source-compatible with every existing non-throwing closure literal
    /// call site (Swift widens a non-throwing closure to a `throws`
    /// parameter automatically), so `AppState`/`astrotool`'s call sites are
    /// unchanged. `force`, when `true`, treats every frame as a cache miss --
    /// see `rate(target:date:progress:)`'s own cache-hit/staleness doc
    /// comment above the loop for why a plain `inputSig` match isn't always
    /// enough on its own.
    public func rate(
        target: String,
        date: String? = nil,
        force: Bool = false,
        progress: (@Sendable (Int, Int) throws -> Void)? = nil
    ) throws -> [FrameScore] {
        let frames = try db.allFiles(includeMissing: false).filter { file in
            file.area == .sessions && file.role == .light && file.target == target
                && (date == nil || file.sessionDate == date)
        }
        guard !frames.isEmpty else { return [] }
        let captureResolver = try CaptureResolver.load(db: db)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astrotool-siril-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { cleanupWorkDir(workDir) }

        let total = frames.count
        var done = 0
        var rated: [(file: FileRecord, record: RatingRecord, exptime: Double?, dateObs: String?, cohort: RatingCohortDescriptor)] = []
        rated.reserveCapacity(frames.count)

        let root = URL(fileURLWithPath: config.rootPath, isDirectory: true)

        for file in frames {
            let entry = try processFrame(
                file: file,
                captureResolver: captureResolver,
                workDir: workDir,
                root: root,
                force: force
            )
            if let entry {
                rated.append(entry)
            }
            done += 1
            // Deliberately OUTSIDE any `defer` (a `defer` body cannot itself
            // `throw`): this is the one point between two frames' work where
            // a throwing `progress` can stop the batch, with this frame's
            // outcome already durably upserted.
            try progress?(done, total)
        }

        guard !rated.isEmpty else { return [] }

        return try score(rated)
    }

    /// One frame's worth of `rate(target:date:force:progress:)`'s loop body,
    /// extracted verbatim (R12-W3T1) so the outer loop can call `try
    /// progress?(...)` exactly once per frame at a single, well-known point
    /// between frames, instead of relying on a non-throwing `defer` to fire
    /// it on every exit path. Returns `nil` for every case the original loop
    /// used to `continue` on (no `fileID`, an unreadable frame); returns the
    /// same `rated` tuple the original loop used to `append` otherwise.
    private func processFrame(
        file: FileRecord,
        captureResolver: CaptureResolver,
        workDir: URL,
        root: URL,
        force: Bool
    ) throws -> (file: FileRecord, record: RatingRecord, exptime: Double?, dateObs: String?, cohort: RatingCohortDescriptor)? {
        guard let fileID = file.id else { return nil }

        // Needed for exposure-group scoring (exptime) and the FWHM-over-
        // night trend chart (dateObs) regardless of cache hit/miss.
        let meta = try db.fitsMeta(fileID: fileID)
        let exptime = meta?.exptime
        let dateObs = meta?.dateObs
        let cohort = Self.cohortDescriptor(
            file: file,
            meta: meta,
            resolver: captureResolver
        )

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
                return (file, cachedRow, exptime, dateObs, cohort)
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
                    return nil
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
            return (file, record, exptime, dateObs, cohort)
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
                return nil
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
        return (file, record, exptime, dateObs, cohort)
    }

    // MARK: - Cached scores, read-only (R9-D6)

    /// Rebuilds `[FrameScore]` for `target` (optionally scoped to `date`)
    /// purely from what's already persisted in `ratings`/`fits_meta` --
    /// never touches the filesystem or invokes Siril, unlike `rate(...)`.
    /// A frame with no rating row yet (never scored) is simply skipped, same
    /// as one whose stored row has a `nil` `score` (a self-heal in progress
    /// that never got to the scoring step). `isOutlier` is recomputed from
    /// the stored `score` using the same threshold `scoreGroup` applies when
    /// it first computes it, so this never needs its own persisted flag.
    /// Backs `AppState.loadFrameScores`, which lets the Minőség segment show
    /// a target's last-rated scores on open without silently implying "never
    /// rated" for a target that simply hasn't been re-rated THIS session.
    public static func cachedScores(target: String, date: String? = nil, db: Database, config: AstroConfig) throws -> [FrameScore] {
        let frames = try db.allFiles(includeMissing: false).filter { file in
            file.area == .sessions && file.role == .light && file.target == target
                && (date == nil || file.sessionDate == date)
        }
        guard !frames.isEmpty else { return [] }

        // N6 (R9 round 3): this used to run one `db.rating(fileID:)` +
        // one `db.fitsMeta(fileID:)` query PER FRAME in the loop below --
        // ~18k round trips on a real library's biggest target. Batched via
        // `ratingsBatch`/`fitsMetaBatch` (both chunked 500 ids/query)
        // instead, same "one query per 500 ids" shape `AppState`'s D12
        // fixes already established for `fitsMetaBatch`'s other call sites.
        let fileIDs = frames.compactMap(\.id)
        let ratingsByFileID = try db.ratingsBatch(fileIDs: fileIDs)
        let metaByFileID = try db.fitsMetaBatch(fileIDs: fileIDs)
        let captureResolver = try CaptureResolver.load(db: db)

        var results: [FrameScore] = []
        results.reserveCapacity(frames.count)
        for file in frames {
            guard let fileID = file.id,
                  let record = ratingsByFileID[fileID],
                  let score = record.score
            else { continue }

            let exptime = metaByFileID[fileID]?.exptime
            let dateObs = metaByFileID[fileID]?.dateObs
            let metrics: StarMetrics? = {
                guard let fwhm = record.fwhm, let starCount = record.starCount else { return nil }
                return StarMetrics(fwhm: fwhm, roundness: record.roundness, starCount: starCount)
            }()

            results.append(
                FrameScore(
                    path: file.path,
                    score: score,
                    isOutlier: score < -config.rating.outlierZScore,
                    metrics: metrics,
                    background: record.background,
                    saturatedFraction: record.saturatedFraction,
                    exptime: exptime,
                    sessionSubdir: sessionSubdir(path: file.path),
                    dateObs: dateObs,
                    cohort: cohortDescriptor(
                        file: file,
                        meta: metaByFileID[fileID],
                        resolver: captureResolver
                    )
                )
            )
        }

        // R11-T7: per-metric z-score breakdown, re-derived from the batch
        // that was just assembled -- see `OutlierBreakdown`'s own doc
        // comment for why this is computed at query time instead of read
        // back from a persisted column.
        let breakdowns = OutlierBreakdown.breakdowns(for: results)
        for i in results.indices {
            results[i].outlierBreakdown = breakdowns[results[i].path]
        }
        return results.sorted { $0.score > $1.score }
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

    /// R11-T7: the grouping key + mean/std/z-score math used below is now
    /// shared with `OutlierBreakdown` (`RatingGroupMath`, `AstroCore/Rate/
    /// OutlierBreakdown.swift`) rather than kept as a private copy here --
    /// these two `typealias`es plus the thin forwarding functions right
    /// below keep every call site in this file unchanged, while guaranteeing
    /// the popover's "why is this an outlier" breakdown can never silently
    /// drift from the actual scoring formula.
    private typealias MetricStats = RatingGroupMath.MetricStats
    private typealias ExposureGroupKey = RatingGroupMath.GroupKey

    private static func exposureGroupKey(
        sessionDate: String?,
        exptime: Double?,
        cohort: RatingCohortDescriptor?
    ) -> ExposureGroupKey {
        RatingGroupMath.groupKey(sessionDate: sessionDate, exptime: exptime, cohort: cohort)
    }

    /// Splits `rated` into exposure groups (see `ExposureGroupKey`) and
    /// scores each group independently, so a frame's z-scores only ever
    /// compare it against other frames shot the same night at the same
    /// nominal exposure time.
    private func score(_ rated: [(file: FileRecord, record: RatingRecord, exptime: Double?, dateObs: String?, cohort: RatingCohortDescriptor)]) throws -> [FrameScore] {
        var groups: [ExposureGroupKey: [(file: FileRecord, record: RatingRecord, exptime: Double?, dateObs: String?, cohort: RatingCohortDescriptor)]] = [:]
        for entry in rated {
            let key = Self.exposureGroupKey(
                sessionDate: entry.file.sessionDate,
                exptime: entry.exptime,
                cohort: entry.cohort
            )
            groups[key, default: []].append((entry.file, entry.record, entry.exptime, entry.dateObs, entry.cohort))
        }

        var results: [FrameScore] = []
        results.reserveCapacity(rated.count)
        for groupRated in groups.values {
            results.append(contentsOf: try scoreGroup(groupRated))
        }

        // R11-T7: per-metric z-score breakdown, computed once over the
        // WHOLE concatenated batch (re-grouping internally the same way --
        // see `OutlierBreakdown.breakdowns(for:)`), not per exposure group
        // above -- `scoreGroup` itself stays focused on the combined score.
        let breakdowns = OutlierBreakdown.breakdowns(for: results)
        for i in results.indices {
            results[i].outlierBreakdown = breakdowns[results[i].path]
        }
        return results.sorted { $0.score > $1.score }
    }

    private func scoreGroup(_ rated: [(file: FileRecord, record: RatingRecord, exptime: Double?, dateObs: String?, cohort: RatingCohortDescriptor)]) throws -> [FrameScore] {
        let weights = config.rating.weights

        let fwhmStats = Self.metricStats(rated.compactMap { $0.record.fwhm })
        let roundnessStats = Self.metricStats(rated.compactMap { $0.record.roundness })
        let starCountStats = Self.metricStats(rated.compactMap { $0.record.starCount.map(Double.init) })
        let backgroundStats = Self.metricStats(rated.compactMap { $0.record.background })

        var results: [FrameScore] = []
        results.reserveCapacity(rated.count)

        for (file, original, exptime, dateObs, cohort) in rated {
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
                    sessionSubdir: Self.sessionSubdir(path: file.path),
                    dateObs: dateObs,
                    cohort: cohort
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

    private static func cohortDescriptor(
        file: FileRecord,
        meta: FITSMetaRecord?,
        resolver: CaptureResolver
    ) -> RatingCohortDescriptor {
        let resolved = resolver.resolve(file: file, meta: meta)
        let setup = meta.flatMap { EquipmentProfile.fingerprint(meta: $0, headerJSON: $0.headerJSON) }
        let nominalExposure = meta?.exptime.map(NominalExposure.nominal)
        return RatingCohortDescriptor(
            sessionDate: file.sessionDate,
            nominalExposureSeconds: nominalExposure,
            captureGroupID: resolved.groupID,
            captureSlug: resolved.slug,
            resolvedFilter: resolvedFilterLabel(resolved),
            setupDescriptor: setup?.descriptor,
            binning: binning(from: meta?.headerJSON)
        )
    }

    private static func resolvedFilterLabel(_ resolved: ResolvedCaptureMetadata) -> String? {
        let parts = [resolved.filterManufacturer, resolved.filterModel]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        guard let name = resolved.filterName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return name
    }

    private static func binning(from headerJSON: String?) -> String? {
        guard let headerJSON,
              let data = headerJSON.data(using: .utf8),
              let cards = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        let header = FITSHeader(rawValues: cards)
        guard let x = header.int("XBINNING") else { return nil }
        return "\(x)x\(header.int("YBINNING") ?? x)"
    }

    /// Forwards to `RatingGroupMath` -- see the `typealias`es above this
    /// file's own doc comment on `MetricStats`/`ExposureGroupKey` for why.
    private static func metricStats(_ values: [Double]) -> MetricStats {
        RatingGroupMath.metricStats(values)
    }

    private static func zScore(_ value: Double, stats: MetricStats) -> Double {
        RatingGroupMath.zScore(value, stats: stats)
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
