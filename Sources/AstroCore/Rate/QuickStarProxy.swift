import Foundation

/// V3 pre-stack program, section 5.6 (Élő éjszaka-mód): a lightweight,
/// pure-Swift star-detection pass used ONLY to give the live-night Home
/// card a rough, continuously-updating focus indicator while a session is
/// still capturing -- never a substitute for the real, Siril-computed
/// star metrics `StarMetricsProvider`/`Rater` use for the actual rating
/// pipeline. Per the spec's own words, the UI must always label this
/// "proxy"/"approximate" (e.g. "FWHM (proxy)"), never present it as the
/// real, calibrated measurement -- see `LiveNightSessionModel`'s own doc
/// comment for exactly where that copy lives.
///
/// Lives next to `NativeStats` (same "no external tool required, dependency-
/// free" contract) but is its own type rather than a `NativeStats` method:
/// `NativeStats` reduces a whole frame to ONE summary statistic (background
/// median, saturated fraction) and deliberately throws individual pixel
/// positions away; this type's entire job is finding and measuring
/// individual bright spots, a different shape of computation the spec's
/// own wave-plan table keeps in a separate file for exactly that reason.
public enum QuickStarProxy {
    /// One detected bright spot.
    public struct StarDetection: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let peakValue: Double
        /// Crude half-max radius in pixels, averaged over the four cardinal
        /// directions from the peak -- NOT a calibrated HFR/FWHM. See this
        /// type's own doc comment.
        public let radiusPixels: Double

        public init(x: Int, y: Int, peakValue: Double, radiusPixels: Double) {
            self.x = x
            self.y = y
            self.peakValue = peakValue
            self.radiusPixels = radiusPixels
        }
    }

    public struct Result: Equatable, Sendable {
        public let stars: [StarDetection]
        /// Median `radiusPixels` across `stars` -- smaller reads as tighter
        /// focus. `nil` when `stars` is empty (nothing cleared the
        /// detection threshold) -- callers must treat this as "can't
        /// estimate yet," never as a measured zero.
        public let medianRadiusPixels: Double?

        public init(stars: [StarDetection], medianRadiusPixels: Double?) {
            self.stars = stars
            self.medianRadiusPixels = medianRadiusPixels
        }
    }

    /// Sigma multiplier above the background used as the detection
    /// threshold -- conservative enough that ordinary background noise (a
    /// dark/bias/flat frame, an empty patch of sky) produces zero
    /// detections rather than false stars.
    public static let defaultSigmaThreshold: Double = 6.0
    /// Minimum pixel separation between two accepted detections -- keeps
    /// one bright, several-pixel-wide star from being counted twice.
    public static let defaultSuppressionRadius: Double = 4.0
    /// How far outward the half-max radius walk goes before giving up on a
    /// star whose wings never fall back below half-max (a saturated blob, a
    /// hot pixel/column) -- bounds the cost of a single detection.
    public static let defaultMaxSearchRadius: Int = 24

    /// Detects local intensity maxima above `background + sigmaThreshold *
    /// sigma` in a flat, row-major `pixels` buffer (`pixels[y * width +
    /// x]`), where `background`/`sigma` are the buffer's own median and a
    /// median-absolute-deviation-derived robust sigma -- robust specifically
    /// because a handful of bright star pixels among many background
    /// pixels must never drag the estimated noise level up and mask a real
    /// star. Candidates are visited brightest-first and a later one within
    /// `suppressionRadius` pixels of an already-accepted star is dropped,
    /// so one physical star is never reported twice.
    public static func detectStars(
        pixels: [Double],
        width: Int,
        height: Int,
        sigmaThreshold: Double = defaultSigmaThreshold,
        suppressionRadius: Double = defaultSuppressionRadius,
        maxSearchRadius: Int = defaultMaxSearchRadius
    ) -> [StarDetection] {
        guard width > 2, height > 2, pixels.count == width * height else { return [] }

        let background = median(pixels)
        // Median-absolute-deviation sigma is exactly 0 whenever MORE THAN
        // HALF the buffer sits exactly at the background level -- true for
        // a real sensor frame's noise floor essentially never, but true by
        // construction for a deterministic, noise-free synthetic star
        // field whose star covers less than half the frame (floating-point
        // ADDITION rounds a Gaussian's far tail back to exactly the
        // background value once it drops below that value's own ULP, so
        // "no measurable noise" and "a real but sparse star" are
        // indistinguishable to MAD alone). Falling back to the population
        // standard deviation keeps a real, isolated bright feature
        // detectable in that case, since a single outlier pulls a mean-
        // based statistic away from 0 even when it can't move the median.
        var sigma = medianAbsoluteDeviationSigma(pixels, background: background)
        if sigma == 0 {
            sigma = populationStandardDeviation(pixels, background: background)
        }
        guard sigma > 0 else { return [] }
        let maxValue = pixels.max() ?? background
        // A small, uniform background plus one (or a few) EXTREME outliers
        // -- e.g. a saturated plateau -- inflates the population stddev
        // fallback above enough that `background + sigmaThreshold * sigma`
        // can exceed every pixel in the buffer, refusing to detect even the
        // single most obviously real feature present because that feature
        // is the very thing that inflated its own threshold. Never demand
        // more than halfway from the background to the single brightest
        // pixel actually observed -- a plain floor that only ever LOWERS an
        // over-strict threshold, never raises a normal one (background
        // pixels stay far below "halfway to the brightest star" in every
        // realistic field), so it cannot manufacture a false positive on
        // its own.
        let threshold = min(background + sigmaThreshold * sigma, background + (maxValue - background) * 0.5)

        func value(_ x: Int, _ y: Int) -> Double { pixels[y * width + x] }

        var candidates: [(x: Int, y: Int, value: Double)] = []
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let v = value(x, y)
                guard v > threshold else { continue }
                var isPeak = true
                outer: for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0, dy == 0 { continue }
                        if value(x + dx, y + dy) > v {
                            isPeak = false
                            break outer
                        }
                    }
                }
                if isPeak { candidates.append((x, y, v)) }
            }
        }

        candidates.sort { $0.value > $1.value }

        var accepted: [StarDetection] = []
        for candidate in candidates {
            let tooClose = accepted.contains { existing in
                let dx = Double(existing.x - candidate.x)
                let dy = Double(existing.y - candidate.y)
                return (dx * dx + dy * dy).squareRoot() < suppressionRadius
            }
            guard !tooClose else { continue }
            let radius = halfMaxRadius(
                fromX: candidate.x, y: candidate.y, peak: candidate.value, background: background,
                pixels: pixels, width: width, height: height, maxSearchRadius: maxSearchRadius
            )
            accepted.append(StarDetection(x: candidate.x, y: candidate.y, peakValue: candidate.value, radiusPixels: radius))
        }
        return accepted
    }

    /// `detectStars` plus the aggregate `medianRadiusPixels` the Home card
    /// actually displays.
    public static func estimate(
        pixels: [Double],
        width: Int,
        height: Int,
        sigmaThreshold: Double = defaultSigmaThreshold,
        suppressionRadius: Double = defaultSuppressionRadius,
        maxSearchRadius: Int = defaultMaxSearchRadius
    ) -> Result {
        let stars = detectStars(
            pixels: pixels, width: width, height: height, sigmaThreshold: sigmaThreshold,
            suppressionRadius: suppressionRadius, maxSearchRadius: maxSearchRadius
        )
        let medianRadius = stars.isEmpty ? nil : median(stars.map(\.radiusPixels))
        return Result(stars: stars, medianRadiusPixels: medianRadius)
    }

    /// Reads a FITS frame's FULL (unsampled) pixel grid via
    /// `NativeStats.centralCropPixels(url:fraction:)` with `fraction: 1.0`
    /// (which, by that method's own crop-size math, degenerates to the
    /// whole frame) and estimates stars from it -- the one place this type
    /// touches the filesystem/FITS format at all. Every other function
    /// above works on plain in-memory arrays, kept deliberately separate so
    /// `QuickStarProxyTests` can drive the detection math with
    /// deterministic synthetic arrays and no file I/O at all.
    public static func estimate(url: URL) throws -> Result {
        let header = try FITSReader.parse(data: try Data(contentsOf: url))
        guard let width = header.int("NAXIS1"), width > 0 else {
            throw AstroError.corruptFITS(path: url.path, reason: "missing or invalid NAXIS1")
        }
        let pixels = try NativeStats.centralCropPixels(url: url, fraction: 1.0)
        guard width > 0, pixels.count % width == 0 else {
            throw AstroError.corruptFITS(path: url.path, reason: "pixel count does not match NAXIS1")
        }
        let height = pixels.count / width
        return estimate(pixels: pixels, width: width, height: height)
    }

    // MARK: - Private

    private static func halfMaxRadius(
        fromX x: Int, y: Int, peak: Double, background: Double,
        pixels: [Double], width: Int, height: Int, maxSearchRadius: Int
    ) -> Double {
        let halfMax = background + (peak - background) / 2
        func value(_ px: Int, _ py: Int) -> Double? {
            guard px >= 0, px < width, py >= 0, py < height else { return nil }
            return pixels[py * width + px]
        }
        func distance(dx: Int, dy: Int) -> Double {
            var r = 1
            while r <= maxSearchRadius {
                guard let v = value(x + dx * r, y + dy * r) else { return Double(r) }
                if v <= halfMax { return Double(r) }
                r += 1
            }
            return Double(maxSearchRadius)
        }
        let distances = [distance(dx: 1, dy: 0), distance(dx: -1, dy: 0), distance(dx: 0, dy: 1), distance(dx: 0, dy: -1)]
        return distances.reduce(0, +) / Double(distances.count)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    private static func medianAbsoluteDeviationSigma(_ values: [Double], background: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let deviations = values.map { abs($0 - background) }
        return 1.4826 * median(deviations)
    }

    /// Population standard deviation around `background` -- the MAD
    /// fallback for a buffer where more than half the pixels sit exactly at
    /// the median (see `detectStars`'s own doc comment on that call site).
    private static func populationStandardDeviation(_ values: [Double], background: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - background) * ($1 - background) } / Double(values.count)
        return variance.squareRoot()
    }
}
