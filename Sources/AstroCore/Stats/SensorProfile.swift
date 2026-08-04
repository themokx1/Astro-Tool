import Foundation

/// A `(camera, gain, offset)` combo among tracked LIGHT frames that has no
/// usable measured sensor profile on record -- either no `sensor_profile`
/// row at all, or one whose `biasLevelADU` was never actually measured.
/// Surfaced by `astrotool sensor` as a drift warning ("nincs mérés ehhez…")
/// so a user who changed gain/offset between sessions finds out before
/// `SessionQuality`'s electron-domain numbers silently go `nil` on them.
public struct MissingProfileCombo: Equatable, Sendable {
    public var camera: String
    public var gain: Double?
    public var offset: Double?

    public init(camera: String, gain: Double?, offset: Double?) {
        self.camera = camera
        self.gain = gain
        self.offset = offset
    }
}

/// Measures real sensor characteristics (bias pedestal, read noise, dark
/// current, EGAIN) per `(camera, gain, offset)` combo, straight from
/// tracked BIAS/DARK frames already on record in `Database` -- the
/// prerequisite for `SessionQuality`'s bias-pedestal subtraction (item A)
/// and the `astrotool sensor` CLI command (item C). Every measured field is
/// independently `nil`-able (see `SensorProfileRecord`'s own doc comment)
/// rather than guessed from a datasheet or a different combo's numbers --
/// "n/a" is the honest answer when the frames needed for a given
/// measurement simply aren't there yet.
public enum SensorProfiler {
    /// Central crop used for every pixel read here (bias level, read-noise
    /// difference, dark level) -- avoids vignetted/amp-glow-affected edges
    /// and keeps two different frames' crops directly comparable pixel-for-
    /// pixel (same shape, same offset) as long as they share `NAXIS1`/
    /// `NAXIS2`, which two frames from the same camera/combo always do.
    private static let cropFraction = 0.5
    private static let clipSigmaThreshold = 5.0
    private static let maxClipIterations = 5

    /// Groups tracked BIAS (and DARK) frames by `(instrume, gain, offset)`
    /// and measures one `SensorProfileRecord` per combo that has at least
    /// one bias frame, persisting each via `db.upsertSensorProfile` before
    /// returning the full set. `root` resolves each tracked file's
    /// root-relative `path` to an actual URL to read pixels from -- this
    /// never writes anywhere in the library itself, only reads.
    @discardableResult
    public static func measure(
        db: Database,
        config: AstroConfig,
        root: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> [SensorProfileRecord] {
        let allFiles = try db.allFiles(includeMissing: false)
        let biasFiles = allFiles.filter { ($0.area == .sessions || $0.area == .calibration) && $0.role == .bias }
        let darkFiles = allFiles.filter { ($0.area == .sessions || $0.area == .calibration) && $0.role == .dark }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in biasFiles + darkFiles {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }

        let biasByCombo = groupByCombo(biasFiles, meta: metaByFileID)
        let darksByCombo = groupByCombo(darkFiles, meta: metaByFileID)

        var results: [SensorProfileRecord] = []
        for key in biasByCombo.keys.sorted(by: comboKeyLessThan) {
            progress?(comboDescription(key))

            let biasSet = (biasByCombo[key] ?? []).sorted { $0.path < $1.path }
            guard !biasSet.isEmpty else { continue }

            let egainValues = biasSet.compactMap { file -> Double? in
                guard let id = file.id else { return nil }
                return metaByFileID[id]?.egain
            }
            let egain = medianOrNil(egainValues)

            let firstCrop = try NativeStats.centralCropPixels(
                url: root.appendingPathComponent(biasSet[0].path), fraction: cropFraction
            )
            let biasLevel = median(firstCrop)

            var readNoise: Double?
            if biasSet.count >= 2, let egain {
                let secondCrop = try NativeStats.centralCropPixels(
                    url: root.appendingPathComponent(biasSet[1].path), fraction: cropFraction
                )
                let count = min(firstCrop.count, secondCrop.count)
                var diffs: [Double] = []
                diffs.reserveCapacity(count)
                for i in 0..<count { diffs.append(firstCrop[i] - secondCrop[i]) }
                let sigma = clippedStandardDeviation(diffs)
                readNoise = sigma / 2.0.squareRoot() * egain
            }

            var darkRate: Double?
            var darkTemp: Double?
            if let egain,
               let darkFile = (darksByCombo[key] ?? []).sorted(by: { $0.path < $1.path }).first,
               let darkID = darkFile.id, let darkMeta = metaByFileID[darkID],
               let exptime = darkMeta.exptime, exptime > 0
            {
                let darkCrop = try NativeStats.centralCropPixels(
                    url: root.appendingPathComponent(darkFile.path), fraction: cropFraction
                )
                let darkMedian = median(darkCrop)
                darkRate = max(0, (darkMedian - biasLevel) * egain / exptime)
                darkTemp = darkMeta.ccdTemp
            }

            let record = SensorProfileRecord(
                camera: key.camera,
                gain: key.gain,
                offset: key.offset,
                biasLevelADU: biasLevel,
                readNoiseE: readNoise,
                darkRateEPerS: darkRate,
                darkTempC: darkTemp,
                egain: egain,
                measuredAt: Date().timeIntervalSince1970,
                frameCount: biasSet.count
            )
            try db.upsertSensorProfile(record)
            results.append(record)
        }

        return results
    }

    /// Every `(camera, gain, offset)` combo among `lights` that has no
    /// usable profile in `profiles` -- no row at all, or a row whose
    /// `biasLevelADU` is `nil` (a partial/failed measurement is exactly as
    /// unusable to `SessionQuality` as no row at all). Frames with no
    /// `instrume` are skipped -- there's no camera identity to warn about.
    public static func combosMissingProfile(
        lights: [FileRecord],
        meta: [Int64: FITSMetaRecord],
        profiles: [SensorProfileRecord]
    ) -> [MissingProfileCombo] {
        var usableProfileKeys = Set<ComboKey>()
        for profile in profiles where profile.biasLevelADU != nil {
            usableProfileKeys.insert(ComboKey(camera: profile.camera, gain: profile.gain, offset: profile.offset))
        }

        var seen = Set<ComboKey>()
        var missing: [MissingProfileCombo] = []
        for file in lights {
            guard let id = file.id, let record = meta[id], let camera = record.instrume else { continue }
            let key = ComboKey(camera: camera, gain: record.gain, offset: record.offset)
            guard seen.insert(key).inserted, !usableProfileKeys.contains(key) else { continue }
            missing.append(MissingProfileCombo(camera: key.camera, gain: key.gain, offset: key.offset))
        }
        return missing.sorted { comboKeyLessThan(ComboKey(camera: $0.camera, gain: $0.gain, offset: $0.offset), ComboKey(camera: $1.camera, gain: $1.gain, offset: $1.offset)) }
    }

    // MARK: - Grouping

    private struct ComboKey: Hashable {
        var camera: String
        var gain: Double?
        var offset: Double?
    }

    private static func groupByCombo(_ files: [FileRecord], meta: [Int64: FITSMetaRecord]) -> [ComboKey: [FileRecord]] {
        var result: [ComboKey: [FileRecord]] = [:]
        for file in files {
            guard let id = file.id, let record = meta[id], let camera = record.instrume else { continue }
            let key = ComboKey(camera: camera, gain: record.gain, offset: record.offset)
            result[key, default: []].append(file)
        }
        return result
    }

    private static func comboKeyLessThan(_ lhs: ComboKey, _ rhs: ComboKey) -> Bool {
        if lhs.camera != rhs.camera { return lhs.camera < rhs.camera }
        if lhs.gain != rhs.gain { return (lhs.gain ?? -.infinity) < (rhs.gain ?? -.infinity) }
        return (lhs.offset ?? -.infinity) < (rhs.offset ?? -.infinity)
    }

    private static func comboDescription(_ key: ComboKey) -> String {
        let gainText = key.gain.map { String(format: "%g", $0) } ?? "-"
        let offsetText = key.offset.map { String(format: "%g", $0) } ?? "-"
        return "mérés: \(key.camera) · gain \(gainText) · offset \(offsetText)"
    }

    // MARK: - Statistics

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    private static func medianOrNil(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : median(values)
    }

    /// 5σ-clipped standard deviation of `values`: iteratively computes the
    /// population mean/std, discards points more than `sigma` away from the
    /// mean, and recomputes -- up to `maxIterations` times, or stopping the
    /// moment nothing more gets clipped. This (not MAD) is what the
    /// expert-measured ground truth used: on this sensor, ADU quantization
    /// (~4 e⁻/ADU at typical gain) makes MAD under-read the true read noise
    /// (1.02 e⁻ from MAD vs. the correct 1.30 e⁻ from clipped σ) -- MAD's
    /// robustness to outliers comes at the cost of exactly the precision
    /// this measurement needs when the underlying data is coarsely
    /// quantized to begin with.
    static func clippedStandardDeviation(_ values: [Double], sigma: Double = clipSigmaThreshold, maxIterations: Int = maxClipIterations) -> Double {
        guard values.count > 1 else { return 0 }
        var current = values

        for _ in 0..<maxIterations {
            let mean = current.reduce(0, +) / Double(current.count)
            let variance = current.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(current.count)
            let std = variance.squareRoot()
            guard std > 0 else { return std }

            let filtered = current.filter { abs($0 - mean) <= sigma * std }
            if filtered.count == current.count || filtered.count < 2 {
                return std
            }
            current = filtered
        }

        let mean = current.reduce(0, +) / Double(current.count)
        let variance = current.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(current.count)
        return variance.squareRoot()
    }
}
