import Foundation

/// One night's cooler-stability verdict for a target's session -- summer
/// heat can make a cooled CMOS camera's cooler (e.g. the ASI2600's) fail to
/// hold its `SET-TEMP`; when `CCD-TEMP` drifts away from it, dark
/// calibration silently degrades (dark current no longer matches the master
/// dark's own temperature). Built only from paired `fits_meta.ccd_temp`/
/// `fits_meta.set_temp` readings -- a frame missing either side (common on
/// DSLR, which has neither header) contributes nothing to any of these
/// numbers.
public struct CoolerHealth: Codable, Sendable, Equatable {
    /// Median of `ccdTemp - setTemp` (signed) across paired frames; `nil`
    /// when no frame has both readings.
    public var medianDeltaC: Double?
    /// Largest `|ccdTemp - setTemp|` across paired frames; `nil` under the
    /// same condition as `medianDeltaC`.
    public var maxAbsDeltaC: Double?
    /// Fraction (0...1) of paired frames whose `|ccdTemp - setTemp|` exceeds
    /// `config.calib.coolerToleranceC`; `nil` when no frame has both
    /// readings (the "n/a" case, e.g. a DSLR session).
    public var outOfBandFraction: Double?
    /// One of `"stabil"`, `"n/a — nincs hűtési adat"` (no paired readings at
    /// all), or a Hungarian message naming the worst excursion and the
    /// affected fraction.
    public var verdict: String

    public init(
        medianDeltaC: Double? = nil,
        maxAbsDeltaC: Double? = nil,
        outOfBandFraction: Double? = nil,
        verdict: String
    ) {
        self.medianDeltaC = medianDeltaC
        self.maxAbsDeltaC = maxAbsDeltaC
        self.outOfBandFraction = outOfBandFraction
        self.verdict = verdict
    }
}

/// One night's focus-drift verdict for a target's session -- FWHM creeping
/// up over a night usually means focus drift or dew, and the lesson feeds
/// the NEXT night's refocus interval. Built from a plain least-squares
/// regression of `ratings.fwhm` (pixels) against time-since-first-frame,
/// over the session's rated frames that have both a `DATE-OBS` and an FWHM.
public struct FocusHealth: Codable, Sendable, Equatable {
    /// The regression's slope, in `slopeUnit` per hour; `nil` when there
    /// aren't enough points to regress (see `ratedFrameCount`'s doc).
    public var slopePerHour: Double?
    /// `"arcsec/h"` when the session's frames carry a pixel scale
    /// (`xpixsz`+`focallen`), else `"px/h"`; `nil` alongside `slopePerHour`.
    public var slopeUnit: String?
    /// The regression line's total change (in `slopeUnit`, NOT per-hour)
    /// across the session's actual time window -- `slopePerHour * hours
    /// elapsed`; `nil` alongside `slopePerHour`.
    public var totalDrift: Double?
    /// Number of (FWHM, DATE-OBS) pairs the regression actually ran over --
    /// below 5, the trend isn't trusted at all (`slopePerHour`/`slopeUnit`/
    /// `totalDrift` all stay `nil` and `verdict` reads "n/a").
    public var ratedFrameCount: Int
    /// One of `"stabil fókusz"`, `"n/a — kevés pontozott keret"`, a
    /// `"fókuszcsúszás gyanú (...)"` warning, or a `"javuló FWHM
    /// (lehűlés/seeing) (...)"` note.
    public var verdict: String

    public init(
        slopePerHour: Double? = nil,
        slopeUnit: String? = nil,
        totalDrift: Double? = nil,
        ratedFrameCount: Int,
        verdict: String
    ) {
        self.slopePerHour = slopePerHour
        self.slopeUnit = slopeUnit
        self.totalDrift = totalDrift
        self.ratedFrameCount = ratedFrameCount
        self.verdict = verdict
    }
}

/// The full per-night hardware-health report (R6-2): cooler stability +
/// focus drift for one target's one session.
public struct NightHealthReport: Codable, Sendable, Equatable {
    public var target: String
    public var date: String
    public var cooler: CoolerHealth
    public var focus: FocusHealth

    public init(target: String, date: String, cooler: CoolerHealth, focus: FocusHealth) {
        self.target = target
        self.date = date
        self.cooler = cooler
        self.focus = focus
    }
}

/// Shared paired-delta convention for "is the cooler holding SET-TEMP" --
/// used by both `NightHealth`'s cooler-health verdict and
/// `CoolerNotReachingSetpointRule` (the matching audit finding), so the two
/// never disagree about what counts as an out-of-band frame.
enum CoolerStats {
    /// `ccdTemp - setTemp` (signed) for every frame that has BOTH readings --
    /// frames missing either side (a DSLR has neither) are silently dropped,
    /// same "nothing to compare" convention as `CalibHealth`'s flat-mismatch
    /// checks.
    static func pairedDeltas(_ metas: [FITSMetaRecord]) -> [Double] {
        metas.compactMap { meta -> Double? in
            guard let ccdTemp = meta.ccdTemp, let setTemp = meta.setTemp else { return nil }
            return ccdTemp - setTemp
        }
    }
}

/// Builds the `NightHealthReport` (R6-2): cooler stability + focus drift for
/// one target/date session. Reuses `FrameSet` (usable-light dedup),
/// `SessionTimeline.parseDateObs` (DATE-OBS parsing), and
/// `SessionQuality.pixelScaleArcsec` (arcsec/pixel scale) rather than
/// re-deriving any of them. Read-only against `db`; never touches the
/// filesystem.
public enum NightHealth {
    /// Session cooler-health verdict threshold -- shared with
    /// `CoolerNotReachingSetpointRule` so the audit finding fires exactly
    /// when this report would already say "nem tartja".
    static let coolerOutOfBandFractionThreshold = 0.10
    private static let minRatedFramesForFocus = 5
    private static let focusStableArcsecThreshold = 0.3
    private static let focusStablePixelThreshold = 0.15

    public static func report(target: String, date: String, db: Database, config: AstroConfig) throws -> NightHealthReport {
        let files = try db.allFiles(includeMissing: false)
        let dayLights = files.filter {
            $0.target == target && $0.area == .sessions && $0.sessionDate == date && $0.role == .light
        }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in dayLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let buckets = FrameSet.lightBuckets(files: dayLights, meta: metaByFileID, config: config)
        let usableMetas = buckets.usable.compactMap { $0.id.flatMap { metaByFileID[$0] } }

        let cooler = coolerHealth(metas: usableMetas, toleranceC: config.calib.coolerToleranceC)

        let pixelScales = usableMetas.compactMap { SessionQuality.pixelScaleArcsec(xpixsz: $0.xpixsz, focallen: $0.focallen) }
        let pixelScale = median(pixelScales)

        let focus = try focusHealth(usableFiles: buckets.usable, metaByFileID: metaByFileID, pixelScale: pixelScale, db: db)

        return NightHealthReport(target: target, date: date, cooler: cooler, focus: focus)
    }

    // MARK: - Cooler

    private static func coolerHealth(metas: [FITSMetaRecord], toleranceC: Double) -> CoolerHealth {
        let deltas = CoolerStats.pairedDeltas(metas)
        guard !deltas.isEmpty else {
            return CoolerHealth(verdict: "n/a — nincs hűtési adat")
        }

        let medianDelta = median(deltas)
        let maxAbsDelta = deltas.map(abs).max()
        let outOfBandCount = deltas.filter { abs($0) > toleranceC }.count
        let fraction = Double(outOfBandCount) / Double(deltas.count)

        let verdict: String
        if fraction > coolerOutOfBandFractionThreshold {
            let worst = deltas.max(by: { abs($0) < abs($1) }) ?? maxAbsDelta ?? 0
            let percent = Int((fraction * 100).rounded())
            verdict = "hűtő nem tartja a célhőmérsékletet (max \(String(format: "%+.1f", worst)) °C, a keretek \(percent)%-án)"
        } else {
            verdict = "stabil"
        }

        return CoolerHealth(medianDeltaC: medianDelta, maxAbsDeltaC: maxAbsDelta, outOfBandFraction: fraction, verdict: verdict)
    }

    // MARK: - Focus

    private static func focusHealth(
        usableFiles: [FileRecord],
        metaByFileID: [Int64: FITSMetaRecord],
        pixelScale: Double?,
        db: Database
    ) throws -> FocusHealth {
        var points: [(instant: Double, fwhm: Double)] = []
        for file in usableFiles {
            guard let id = file.id, let rating = try db.rating(fileID: id), let fwhm = rating.fwhm else { continue }
            guard let rawDateObs = metaByFileID[id]?.dateObs, let instant = SessionTimeline.parseDateObs(rawDateObs) else { continue }
            points.append((instant.timeIntervalSince1970, fwhm))
        }
        points.sort { $0.instant < $1.instant }

        guard points.count >= minRatedFramesForFocus else {
            return FocusHealth(ratedFrameCount: points.count, verdict: "n/a — kevés pontozott keret")
        }

        let t0 = points[0].instant
        let xs = points.map { ($0.instant - t0) / 3600.0 }
        let ys = points.map(\.fwhm)

        guard let slopePxPerHour = linearRegressionSlope(xs: xs, ys: ys) else {
            return FocusHealth(ratedFrameCount: points.count, verdict: "n/a — kevés pontozott keret")
        }

        let windowHours = (xs.last ?? 0) - (xs.first ?? 0)
        let totalDriftPx = slopePxPerHour * windowHours

        let slopePerHour: Double
        let totalDrift: Double
        let slopeUnit: String
        let threshold: Double
        let unitSuffix: String
        if let pixelScale {
            slopePerHour = slopePxPerHour * pixelScale
            totalDrift = totalDriftPx * pixelScale
            slopeUnit = "arcsec/h"
            threshold = focusStableArcsecThreshold
            unitSuffix = "\""
        } else {
            slopePerHour = slopePxPerHour
            totalDrift = totalDriftPx
            slopeUnit = "px/h"
            threshold = focusStablePixelThreshold
            unitSuffix = "px"
        }

        let verdict: String
        if abs(totalDrift) < threshold {
            verdict = "stabil fókusz"
        } else {
            let hoursText = "\(max(1, Int(windowHours.rounded()))) óra"
            let driftText = String(format: "%+.1f", totalDrift) + unitSuffix
            verdict = totalDrift > 0
                ? "fókuszcsúszás gyanú (\(driftText)/\(hoursText))"
                : "javuló FWHM (lehűlés/seeing) (\(driftText)/\(hoursText))"
        }

        return FocusHealth(
            slopePerHour: slopePerHour,
            slopeUnit: slopeUnit,
            totalDrift: totalDrift,
            ratedFrameCount: points.count,
            verdict: verdict
        )
    }

    /// Plain least-squares slope of `ys` against `xs` -- `nil` when the
    /// denominator degenerates (e.g. every `x` identical, which a real
    /// session's own DATE-OBS spread never produces once `points.count >=
    /// minRatedFramesForFocus`, but is still guarded against rather than
    /// dividing by zero).
    private static func linearRegressionSlope(xs: [Double], ys: [Double]) -> Double? {
        let n = Double(xs.count)
        guard n > 0 else { return nil }
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0 else { return nil }
        return (n * sumXY - sumX * sumY) / denominator
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
