import Foundation

/// A single light frame's rating result, as returned by `Rater.rate`.
public struct FrameScore: Codable, Sendable {
    public var path: String
    public var score: Double
    public var isOutlier: Bool
    public var metrics: StarMetrics?
    public var background: Double?

    public init(path: String, score: Double, isOutlier: Bool, metrics: StarMetrics?, background: Double?) {
        self.path = path
        self.score = score
        self.isOutlier = isOutlier
        self.metrics = metrics
        self.background = background
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
    /// `(completedCount, totalCount)`.
    public func rate(
        target: String,
        date: String? = nil,
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

            if let cached = try db.rating(fileID: fileID), cached.inputSig == inputSig {
                rated.append((file, cached, exptime))
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
            if file.ext.lowercased() != "fz" {
                do {
                    nativeStats = try NativeStats.compute(url: url)
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
                inputSig: inputSig
            )
            try db.upsertRating(record)
            rated.append((file, record, exptime))
        }

        guard !rated.isEmpty else { return [] }

        return try score(rated)
    }

    // MARK: - Scoring

    private struct MetricStats {
        var mean: Double
        var std: Double
    }

    /// Which exposure group a frame belongs to for scoring purposes: exptime
    /// rounded to the nearest 0.1s, or `.unknown` -- one single shared group
    /// for every frame with no `exptime` at all (not one singleton group
    /// each, which would force every such frame's z-score to 0).
    private enum ExposureGroupKey: Hashable {
        case exptime(Int)
        case unknown
    }

    private static func exposureGroupKey(_ exptime: Double?) -> ExposureGroupKey {
        guard let exptime else { return .unknown }
        return .exptime(Int((exptime * 10).rounded()))
    }

    /// Splits `rated` into exposure groups (see `ExposureGroupKey`) and
    /// scores each group independently, so a frame's z-scores only ever
    /// compare it against other frames shot at the same exposure time.
    private func score(_ rated: [(file: FileRecord, record: RatingRecord, exptime: Double?)]) throws -> [FrameScore] {
        var groups: [ExposureGroupKey: [(file: FileRecord, record: RatingRecord)]] = [:]
        for entry in rated {
            let key = Self.exposureGroupKey(entry.exptime)
            groups[key, default: []].append((entry.file, entry.record))
        }

        var results: [FrameScore] = []
        results.reserveCapacity(rated.count)
        for groupRated in groups.values {
            results.append(contentsOf: try scoreGroup(groupRated))
        }

        return results.sorted { $0.score > $1.score }
    }

    private func scoreGroup(_ rated: [(file: FileRecord, record: RatingRecord)]) throws -> [FrameScore] {
        let weights = config.rating.weights

        let fwhmStats = Self.metricStats(rated.compactMap { $0.record.fwhm })
        let roundnessStats = Self.metricStats(rated.compactMap { $0.record.roundness })
        let starCountStats = Self.metricStats(rated.compactMap { $0.record.starCount.map(Double.init) })
        let backgroundStats = Self.metricStats(rated.compactMap { $0.record.background })

        var results: [FrameScore] = []
        results.reserveCapacity(rated.count)

        for (file, original) in rated {
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
                guard let fwhm = record.fwhm, let roundness = record.roundness, let starCount = record.starCount
                else { return nil }
                return StarMetrics(fwhm: fwhm, roundness: roundness, starCount: starCount)
            }()

            results.append(
                FrameScore(
                    path: file.path,
                    score: finalScore,
                    isOutlier: finalScore < -config.rating.outlierZScore,
                    metrics: metrics,
                    background: record.background
                )
            )
        }

        return results.sorted { $0.score > $1.score }
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
