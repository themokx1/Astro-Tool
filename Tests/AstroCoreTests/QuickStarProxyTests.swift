import Foundation
import Testing
@testable import AstroCore

/// Builds a flat, row-major pixel grid filled with `background`, with one
/// or more 2D Gaussian "stars" added on top -- `amplitude` above
/// background at the peak, falling off with standard deviation `sigma`
/// pixels. No noise: a deterministic synthetic star field lets these tests
/// assert exact detection counts/positions, and (per the house rule for
/// this engine) that a WIDER input sigma always ranks as a wider measured
/// radius, never merely "close to a reference number" with no real ground
/// truth to compare against.
private func gaussianGrid(
    width: Int, height: Int, background: Double,
    stars: [(cx: Double, cy: Double, amplitude: Double, sigma: Double)]
) -> [Double] {
    var grid = [Double](repeating: background, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            var value = background
            for star in stars {
                let dx = Double(x) - star.cx
                let dy = Double(y) - star.cy
                value += star.amplitude * exp(-(dx * dx + dy * dy) / (2 * star.sigma * star.sigma))
            }
            grid[y * width + x] = value
        }
    }
    return grid
}

@Suite("QuickStarProxy detection")
struct QuickStarProxyTests {
    @Test("A perfectly flat background with no stars yields no detections")
    func flatBackgroundYieldsNoDetections() {
        let grid = [Double](repeating: 500, count: 40 * 40)
        let result = QuickStarProxy.estimate(pixels: grid, width: 40, height: 40)
        #expect(result.stars.isEmpty)
        #expect(result.medianRadiusPixels == nil)
    }

    @Test("A single bright Gaussian star is detected at its own center")
    func singleStarDetectedAtCenter() {
        let grid = gaussianGrid(
            width: 41, height: 41, background: 100,
            stars: [(cx: 20, cy: 20, amplitude: 5000, sigma: 2.0)]
        )
        let stars = QuickStarProxy.detectStars(pixels: grid, width: 41, height: 41)
        #expect(stars.count == 1)
        #expect(stars.first?.x == 20)
        #expect(stars.first?.y == 20)
    }

    @Test("Two widely separated stars of the same width both get their own detection")
    func twoSeparatedStarsBothDetected() {
        let grid = gaussianGrid(
            width: 60, height: 30, background: 100,
            stars: [
                (cx: 10, cy: 15, amplitude: 4000, sigma: 1.5),
                (cx: 45, cy: 15, amplitude: 4000, sigma: 1.5),
            ]
        )
        let stars = QuickStarProxy.detectStars(pixels: grid, width: 60, height: 30)
        #expect(stars.count == 2)
        let xs = Set(stars.map(\.x))
        #expect(xs == Set([10, 45]))
    }

    @Test("Two stars close together within the suppression radius collapse to one detection")
    func closeStarsSuppressToOneDetection() {
        // 5px apart at sigma 1.5 -- far enough that the two Gaussians barely
        // overlap (each contributes < 1% of its amplitude at the other's
        // center), so each keeps its OWN distinct local maximum rather than
        // blending into a single merged peak somewhere between them (which
        // is what happens at closer separations -- not a bug, just not what
        // THIS test wants to exercise: a `suppressionRadius` wide enough to
        // treat two genuinely separate peaks as one star, with the brighter
        // one winning).
        let grid = gaussianGrid(
            width: 41, height: 41, background: 100,
            stars: [
                (cx: 20, cy: 20, amplitude: 5000, sigma: 1.5),
                (cx: 25, cy: 20, amplitude: 3000, sigma: 1.5),
            ]
        )
        let stars = QuickStarProxy.detectStars(pixels: grid, width: 41, height: 41, suppressionRadius: 6)
        #expect(stars.count == 1)
        // The brighter of the two candidates wins -- peak-first ordering.
        #expect(stars.first?.x == 20)
    }

    /// The house-rule test for this engine: prove the proxy RANKS three
    /// star fields of increasing known Gaussian width in the correct
    /// order, rather than merely landing "close to" an unverifiable
    /// reference number. A wider Gaussian genuinely has a wider half-max
    /// radius, so a correct detector's own `radiusPixels` must increase
    /// monotonically with `sigma`.
    @Test("A wider synthetic star measures a proportionally larger radius than a narrower one")
    func widerStarsMeasureLargerRadius() {
        let sigmas: [Double] = [1.0, 2.0, 4.0]
        let radii: [Double] = sigmas.map { sigma in
            let grid = gaussianGrid(
                width: 61, height: 61, background: 200,
                stars: [(cx: 30, cy: 30, amplitude: 8000, sigma: sigma)]
            )
            let stars = QuickStarProxy.detectStars(pixels: grid, width: 61, height: 61, maxSearchRadius: 30)
            return stars.first?.radiusPixels ?? -1
        }
        #expect(radii[0] > 0)
        #expect(radii[1] > radii[0])
        #expect(radii[2] > radii[1])
    }

    @Test("estimate(pixels:width:height:) reports the median radius across multiple stars")
    func estimateReportsMedianRadius() throws {
        let grid = gaussianGrid(
            width: 61, height: 21, background: 100,
            stars: [
                (cx: 10, cy: 10, amplitude: 5000, sigma: 1.0),
                (cx: 30, cy: 10, amplitude: 5000, sigma: 2.0),
                (cx: 50, cy: 10, amplitude: 5000, sigma: 3.0),
            ]
        )
        let result = QuickStarProxy.estimate(pixels: grid, width: 61, height: 21)
        #expect(result.stars.count == 3)
        let median = try #require(result.medianRadiusPixels)
        let sortedRadii = result.stars.map(\.radiusPixels).sorted()
        #expect(median == sortedRadii[1])
    }

    @Test("A mismatched pixel count/dimensions yields no detections rather than crashing")
    func mismatchedDimensionsYieldsNoDetections() {
        let grid = [Double](repeating: 100, count: 10)
        let stars = QuickStarProxy.detectStars(pixels: grid, width: 5, height: 5)
        #expect(stars.isEmpty)
    }

    @Test("A saturated star's small flat-topped core still returns a bounded radius, never runs unbounded")
    func saturatedPlateauReturnsBoundedRadius() {
        var grid = [Double](repeating: 100, count: 41 * 41)
        // A small (3x3), flat-topped saturated CORE -- a real saturated
        // star's central pixels clip to the sensor's max value while its
        // wings still fall off normally, unlike an unrealistically large
        // flat block spanning many resolution elements. Small enough that
        // the default suppression radius (4px) collapses the core's own
        // several equal-valued "peak" pixels into ONE accepted detection,
        // rather than walking across the plateau and re-accepting a "new"
        // peak every few pixels. The half-max walk must still terminate at
        // `maxSearchRadius` rather than loop forever/overrun the buffer.
        for y in 19...21 {
            for x in 19...21 {
                grid[y * 41 + x] = 65535
            }
        }
        let stars = QuickStarProxy.detectStars(pixels: grid, width: 41, height: 41, maxSearchRadius: 12)
        #expect(stars.count == 1)
        #expect(stars.first?.radiusPixels ?? 0 <= 12)
    }

    // MARK: - FITS integration (estimate(url:))

    @Test("estimate(url:) reads a synthetic FITS frame's full pixel grid and finds its embedded star")
    func estimateFromURLFindsEmbeddedStar() throws {
        let width = 40
        let height = 40
        let pixels = gaussianGrid(
            width: width, height: height, background: 300,
            stars: [(cx: 20, cy: 20, amplitude: 20000, sigma: 1.5)]
        )
        let data = buildFITS16Bit(width: width, height: height, pixels: pixels)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fits")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = try QuickStarProxy.estimate(url: tempURL)
        #expect(result.stars.count == 1)
        #expect(result.stars.first?.x == 20)
        #expect(result.stars.first?.y == 20)
    }
}

/// Builds a plain (non-`.fz`), `BITPIX=16` primary-HDU FITS file from a
/// flat `Double` pixel grid, clamped to the unsigned 16-bit range --
/// mirrors `FITSImageRendererTests.buildFITS`'s own shape (same repo
/// convention for a hand-built test fixture), kept local to this file per
/// that file's own "each test file's pixel-data builder evolves
/// independently" precedent.
private func buildFITS16Bit(width: Int, height: Int, pixels: [Double]) -> Data {
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
        "END",
    ]
    var data = buildHeaderData(cards)
    var pixelBytes = Data()
    pixelBytes.reserveCapacity(pixels.count * 2)
    for value in pixels {
        let clamped = UInt16(clamping: Int(value.rounded()))
        pixelBytes.append(UInt8(clamped >> 8))
        pixelBytes.append(UInt8(clamped & 0xFF))
    }
    data.append(pixelBytes)
    return data
}
