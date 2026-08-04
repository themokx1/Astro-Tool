import Foundation

/// Absolute, cross-setup-comparable quality metrics for one target's session
/// -- the counterpart to `Rater`'s per-frame z-scores, which are RELATIVE
/// (they can only say "this frame is worse than its own group tonight") and
/// therefore can never answer "was tonight better than last month", let
/// alone compare across a focal-length or camera change. Everything here is
/// derived from already-rated frames (`ratings`) joined with their FITS
/// metadata (`fits_meta`), never from the filesystem.
public struct SessionQualitySummary: Codable, Sendable, Equatable {
    public var target: String
    public var date: String
    /// Usable (deduped, non-rejected) light frames that have a rating
    /// record on file -- NOT every usable light frame for the session, since
    /// an un-rated frame contributes no metrics at all.
    public var frameCount: Int
    /// Median `ratings.fwhm` (in pixels) over rated frames that have one.
    public var medianFWHMPixels: Double?
    /// Median FWHM converted to arcseconds via each frame's own pixel
    /// scale -- `nil` whenever `medianFWHMPixels` or `pixelScaleArcsec`-
    /// contributing metadata (`xpixsz`/`focallen`) is missing.
    public var medianFWHMArcsec: Double?
    /// Median arcsec-per-pixel scale (`206.265 * xpixsz(µm) / focallen(mm)`)
    /// across frames that have both `xpixsz` and a positive `focallen`.
    public var pixelScaleArcsec: Double?
    /// Median `ratings.background` (in ADU) over rated frames that have one.
    public var medianBackgroundADU: Double?
    /// Median sky background converted to e-/s/arcsec² via each frame's own
    /// `egain`/`exptime`/pixel scale, AFTER subtracting the sensor's
    /// measured bias pedestal (`SensorProfileRecord.biasLevelADU`, matched
    /// on an EXACT `(camera, gain, offset)` -- never a gain-only/camera-only
    /// fallback): `max(0, (background_ADU - biasLevel) * egain / exptime /
    /// scale²)`. `nil` whenever any of `egain`/`exptime`/pixel-scale is
    /// missing, OR no measured sensor profile (with a bias level) exists yet
    /// for this exact combo -- reporting a number computed as if the bias
    /// pedestal were 0 is exactly the ~64x-inflation bug this subtraction
    /// fixes (real Rosette data: reported 0.147 e⁻/s/arcsec² against a
    /// measured truth of 0.0023), so "no measured bias level" always means
    /// `nil`, never a guessed number.
    public var backgroundEPerSecPerArcsec2: Double?
    /// Median `ratings.star_count` over rated frames that have one, rounded
    /// to the nearest integer (the median of two middle values can be a
    /// half-integer for an even-sized sample).
    public var medianStarCount: Int?
    /// Fraction (0...1) of rated (scored) frames whose stored `score` falls
    /// below `-config.rating.outlierZScore` -- recomputed from the
    /// persisted score rather than re-running `Rater`, since that's exactly
    /// the threshold `Rater.scoreGroup` itself used to set `isOutlier`.
    public var outlierFraction: Double?
    /// 1 = best (lowest) `medianFWHMArcsec` among this target's summarized
    /// sessions; `nil` for a session with no `medianFWHMArcsec` to rank by
    /// (it's simply left out of the ranking, not placed last with a rank).
    public var rankAmongSessions: Int?
    /// Total number of sessions `summaries(target:...)` returned for this
    /// target -- lets a caller show "2/6" without a second query.
    public var sessionCountForTarget: Int?

    public init(
        target: String,
        date: String,
        frameCount: Int,
        medianFWHMPixels: Double? = nil,
        medianFWHMArcsec: Double? = nil,
        pixelScaleArcsec: Double? = nil,
        medianBackgroundADU: Double? = nil,
        backgroundEPerSecPerArcsec2: Double? = nil,
        medianStarCount: Int? = nil,
        outlierFraction: Double? = nil,
        rankAmongSessions: Int? = nil,
        sessionCountForTarget: Int? = nil
    ) {
        self.target = target
        self.date = date
        self.frameCount = frameCount
        self.medianFWHMPixels = medianFWHMPixels
        self.medianFWHMArcsec = medianFWHMArcsec
        self.pixelScaleArcsec = pixelScaleArcsec
        self.medianBackgroundADU = medianBackgroundADU
        self.backgroundEPerSecPerArcsec2 = backgroundEPerSecPerArcsec2
        self.medianStarCount = medianStarCount
        self.outlierFraction = outlierFraction
        self.rankAmongSessions = rankAmongSessions
        self.sessionCountForTarget = sessionCountForTarget
    }
}

/// Builds `SessionQualitySummary` rows for one target, one per session
/// date-dir on record -- reads only from `Database`, never touches the
/// filesystem.
public enum SessionQuality {
    /// Arcseconds per radian, used to convert a pixel's angular size from
    /// (microns / mm) to arcsec: `206265 * xpixsz(µm) / focallen(mm) /
    /// 1000` simplifies to `206.265 * xpixsz / focallen`.
    private static let arcsecPerRadianOverMM = 206.265

    /// The arcsec/pixel scale for one frame's `xpixsz`/`focallen` pair --
    /// `nil` whenever either is missing or `focallen` isn't positive. Shared
    /// with `NightHealth` (R6-2's focus-drift arcsec conversion) so the two
    /// features never compute this differently.
    static func pixelScaleArcsec(xpixsz: Double?, focallen: Double?) -> Double? {
        guard let xpixsz, let focallen, focallen > 0 else { return nil }
        return arcsecPerRadianOverMM * xpixsz / focallen
    }

    /// One entry per session date-dir on record for `target` (mirrors
    /// `SessionStatsQueries.sessions`'s date enumeration), ranked by
    /// ascending `medianFWHMArcsec`. `[]` if the target has no session-area
    /// files at all.
    public static func summaries(target: String, db: Database, config: AstroConfig) throws -> [SessionQualitySummary] {
        let files = try db.allFiles(includeMissing: false)
        let sessionFiles = files.filter { $0.target == target && $0.area == .sessions }
        guard !sessionFiles.isEmpty else { return [] }

        let dates = Set(sessionFiles.compactMap(\.sessionDate)).sorted()
        var summaries = try dates.map { date in
            try computeSummary(target: target, date: date, files: sessionFiles, db: db, config: config)
        }

        assignRanks(&summaries)
        return summaries
    }

    // MARK: - Per-session computation

    private struct FrameMetrics {
        var fwhmPixels: Double?
        var fwhmArcsec: Double?
        var pixelScale: Double?
        var backgroundADU: Double?
        var backgroundEPerSecPerArcsec2: Double?
        var starCount: Int?
        var score: Double?
    }

    /// Cache key for a `db.sensorProfile(camera:gain:offset:)` lookup within
    /// one `computeSummary` call -- see `biasLevelCache`'s doc comment.
    private struct ComboKey: Hashable {
        var camera: String
        var gain: Double?
        var offset: Double?
    }

    private static func computeSummary(
        target: String,
        date: String,
        files: [FileRecord],
        db: Database,
        config: AstroConfig
    ) throws -> SessionQualitySummary {
        let dayLights = files.filter { $0.sessionDate == date && $0.role == .light }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in dayLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: dayLights, meta: metaByFileID, config: config)

        // Caches `db.sensorProfile(camera:gain:offset:)` lookups per unique
        // (camera, gain, offset) combo seen this session -- many frames in a
        // session normally share the exact same combo, and each is an exact
        // DB round-trip (see the method's own doc comment for why no
        // gain-only/camera-only fallback is ever attempted). `nil` INSIDE
        // the optional (`.some(nil)`) means "looked up, no profile" so a
        // repeat miss doesn't re-query either.
        var biasLevelCache: [ComboKey: Double?] = [:]

        var frameMetrics: [FrameMetrics] = []
        for file in buckets.usable {
            guard let id = file.id, let rating = try db.rating(fileID: id) else { continue }

            var m = FrameMetrics()
            m.fwhmPixels = rating.fwhm
            m.backgroundADU = rating.background
            m.starCount = rating.starCount
            m.score = rating.score

            let meta = metaByFileID[id]
            let pixelScale = pixelScaleArcsec(xpixsz: meta?.xpixsz, focallen: meta?.focallen)
            m.pixelScale = pixelScale

            if let fwhm = rating.fwhm, let scale = pixelScale {
                m.fwhmArcsec = fwhm * scale
            }
            if let background = rating.background, let egain = meta?.egain, let exptime = meta?.exptime,
               exptime > 0, let scale = pixelScale, scale > 0, let camera = meta?.instrume
            {
                let key = ComboKey(camera: camera, gain: meta?.gain, offset: meta?.offset)
                let biasLevel: Double?
                if let cached = biasLevelCache[key] {
                    biasLevel = cached
                } else {
                    // EXACT (camera, gain, offset) match only -- see this
                    // method's doc comment for why a gain-only/camera-only
                    // fallback is deliberately never attempted (the R7-B1
                    // spec: "exact or nil, document").
                    let resolved = try db.sensorProfile(camera: camera, gain: meta?.gain, offset: meta?.offset)?.biasLevelADU
                    biasLevelCache[key] = resolved
                    biasLevel = resolved
                }

                if let biasLevel {
                    m.backgroundEPerSecPerArcsec2 = max(0, (background - biasLevel) * egain / exptime / (scale * scale))
                }
                // No measured sensor profile (or no bias level within it)
                // for this exact combo -> stays `nil`. See this file's top
                // doc comment: reporting a number computed with an
                // unsubtracted (or guessed) bias pedestal is exactly the
                // 64x-inflation bug this fix closes -- "n/a" is the honest
                // answer here, never a wrong number.
            }

            frameMetrics.append(m)
        }

        let scores = frameMetrics.compactMap(\.score)
        let outlierFraction: Double?
        if scores.isEmpty {
            outlierFraction = nil
        } else {
            let outliers = scores.filter { $0 < -config.rating.outlierZScore }.count
            outlierFraction = Double(outliers) / Double(scores.count)
        }

        return SessionQualitySummary(
            target: target,
            date: date,
            frameCount: frameMetrics.count,
            medianFWHMPixels: median(frameMetrics.compactMap(\.fwhmPixels)),
            medianFWHMArcsec: median(frameMetrics.compactMap(\.fwhmArcsec)),
            pixelScaleArcsec: median(frameMetrics.compactMap(\.pixelScale)),
            medianBackgroundADU: median(frameMetrics.compactMap(\.backgroundADU)),
            backgroundEPerSecPerArcsec2: median(frameMetrics.compactMap(\.backgroundEPerSecPerArcsec2)),
            medianStarCount: median(frameMetrics.compactMap { $0.starCount.map(Double.init) }).map { Int($0.rounded()) },
            outlierFraction: outlierFraction
        )
    }

    // MARK: - Ranking

    /// Ranks sessions by ascending `medianFWHMArcsec` (1 = best/lowest);
    /// sessions with no value are left with `rankAmongSessions == nil`
    /// rather than ranked last. Every session (ranked or not) gets
    /// `sessionCountForTarget` set to the total count.
    private static func assignRanks(_ summaries: inout [SessionQualitySummary]) {
        let total = summaries.count
        let ranked = summaries.enumerated()
            .filter { $0.element.medianFWHMArcsec != nil }
            .sorted { ($0.element.medianFWHMArcsec ?? .infinity) < ($1.element.medianFWHMArcsec ?? .infinity) }

        for (rank, entry) in ranked.enumerated() {
            summaries[entry.offset].rankAmongSessions = rank + 1
        }
        for index in summaries.indices {
            summaries[index].sessionCountForTarget = total
        }
    }

    // MARK: - Median

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
