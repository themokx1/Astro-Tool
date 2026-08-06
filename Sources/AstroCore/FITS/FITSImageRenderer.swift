import Foundation
import CoreGraphics

/// Renders a FITS light frame's primary HDU into a small, displayable 8-bit
/// `CGImage` -- the core image-generation logic behind the app's thumbnail
/// grid (`QLThumbnailGenerator` produces nothing for FITS files, so this is
/// the only source of a preview for the vast majority of frames in this
/// pipeline). Debayers Bayer-pattern (CFA) sensors with a cheap superpixel
/// algorithm and applies a Siril-style MTF auto-stretch so faint linear data
/// is actually visible rather than a near-black rectangle.
///
/// This is a QUICK-LOOK preview renderer, not a science-grade stretch: one
/// shared MTF curve is applied to every channel (no per-channel white
/// balance, no star-based black point), which keeps thumbnails predictable
/// and cheap rather than color-accurate. App-layer integration (the
/// thumbnail column itself) is a separate, later task -- this file only
/// turns FITS bytes into a `CGImage`, and never touches disk.
public struct FITSImageRenderer {
    /// Target background brightness (normalized 0...1) that the frame's
    /// median pixel is stretched to land on -- Siril's own "autostretch"
    /// default.
    private static let targetBackground = 0.25
    /// Shadows clipping point = `median - shadowsClippingFactor * MAD`,
    /// clamped to >= 0 -- again Siril's own default factor.
    private static let shadowsClippingFactor = 2.8
    /// Median/MAD are computed from at most this many sampled pixels --
    /// plenty for a stable estimate, far cheaper than scanning every pixel
    /// of a multi-megapixel frame.
    private static let maxStatsSampleCount = 200_000
    /// Below this, a sample is treated as having zero spread (the MAD==0
    /// edge case): a genuinely constant/near-constant frame, where the
    /// normal MTF solve would divide by (approximately) zero.
    private static let madDegenerateThreshold = 1e-12
    /// Flat output value (of 255) used for the MAD==0 degenerate case --
    /// deliberately mid-gray (not black, not the `targetBackground` value)
    /// so a genuinely-blank/constant frame reads as "no information" rather
    /// than looking like a real (if dim or bright) exposure.
    private static let degenerateFlatGrayByte: UInt8 = 128

    /// Renders `url`'s primary HDU into an sRGB 8-bit `CGImage`, debayered
    /// (superpixel) when the header carries a recognized `BAYERPAT`,
    /// auto-stretched (MTF) so the result is actually visible. Safe to call
    /// off the main thread; never writes anything to disk.
    ///
    /// See `render(data:maxDimension:)` for the actual algorithm and for
    /// exactly which conditions return `nil` versus throw.
    public static func render(url: URL, maxDimension: Int = 1024) throws -> CGImage? {
        let data = try Data(contentsOf: url)
        return try render(data: data, maxDimension: maxDimension)
    }

    /// Core entry point (also the testable one, mirroring
    /// `FITSReader.parse(data:)`/`NativeStats.compute(data:)`'s
    /// url-wraps-data convention).
    ///
    /// Returns `nil` -- never throws, never fabricates pixels -- for FITS
    /// layouts this renderer intentionally doesn't support: Rice-compressed
    /// `.fz` tables (detected exactly the way `NativeStats` does, via the
    /// shared `NativeStats.primaryHeaderInfo` scan, so the two never
    /// disagree about what's compressed), `BITPIX` other than 8/16, or
    /// `NAXIS != 2`. Genuine corruption (truncated header/pixel data,
    /// missing `NAXIS1`/`NAXIS2`) still throws `AstroError.corruptFITS`,
    /// same as `FITSReader`/`NativeStats` -- those are actually-broken
    /// files, not merely a layout this renderer chooses not to draw.
    public static func render(data: Data, maxDimension: Int = 1024) throws -> CGImage? {
        let header = try FITSReader.parse(data: data)
        let (dataOffset, rawPrimaryNAXIS) = try NativeStats.primaryHeaderInfo(data: data)

        // Same positive compressed-layout detection `NativeStats.compute`
        // uses (see its own doc comment): a merged-in tile-compression
        // keyword, or the *raw* primary header declaring NAXIS=0. Checking
        // this before anything else means we never risk reading a Rice-
        // encoded BINTABLE heap as if it were a flat pixel grid.
        let hasCompressionKeywords = header.allCards["ZIMAGE"] != nil
            || header.allCards["ZCMPTYPE"] != nil
            || header.allCards["ZBITPIX"] != nil
        guard !hasCompressionKeywords, rawPrimaryNAXIS != 0 else {
            return nil
        }

        guard let bitpix = header.int("BITPIX"), bitpix == 8 || bitpix == 16 else {
            return nil
        }
        // Must run before the NAXIS1/NAXIS2 presence check below: a NAXIS=1
        // (or 3+) file legitimately has no NAXIS2 card at all, and that's
        // "unsupported layout" (nil), not "corrupt" (throw).
        guard header.int("NAXIS") == 2 else {
            return nil
        }
        guard let naxis1 = header.int("NAXIS1"), naxis1 > 0,
              let naxis2 = header.int("NAXIS2"), naxis2 > 0
        else {
            throw AstroError.corruptFITS(path: "<data>", reason: "missing or invalid NAXIS1/NAXIS2")
        }

        let bytesPerPixel = bitpix == 16 ? 2 : 1
        guard dataOffset + naxis1 * naxis2 * bytesPerPixel <= data.count else {
            throw AstroError.corruptFITS(path: "<data>", reason: "truncated pixel data")
        }

        let bzero = header.double("BZERO") ?? 0
        let isUnsigned16 = bitpix == 16 && bzero == 32768
        let maxValue: Double = bitpix == 16 ? (isUnsigned16 ? 65535 : 32767) : 255
        let clampedMaxDimension = max(1, maxDimension)

        // `channels` holds either 1 grid (grayscale: no/unrecognized
        // BAYERPAT) or 3 grids (R/G/B: debayered), all the same
        // width/height, normalized to 0...1 -- everything downstream
        // (stats + stretch) is written once against this shape rather than
        // branching mono/color throughout.
        let channels: [[Double]]
        let width: Int
        let height: Int

        if let labels = BayerMap.labels(for: header.string("BAYERPAT")) {
            let mosaic = readBayerMosaic(
                data: data, dataOffset: dataOffset, bitpix: bitpix, isUnsigned16: isUnsigned16,
                maxValue: maxValue, naxis1: naxis1, naxis2: naxis2, maxDimension: clampedMaxDimension
            )
            guard mosaic.width > 0, mosaic.height > 0 else { return nil }
            let debayered = debayer(mosaic: mosaic.values, width: mosaic.width, height: mosaic.height, labels: labels)
            channels = [debayered.r, debayered.g, debayered.b]
            width = debayered.width
            height = debayered.height
        } else {
            let grid = readMonoGrid(
                data: data, dataOffset: dataOffset, bitpix: bitpix, isUnsigned16: isUnsigned16,
                maxValue: maxValue, naxis1: naxis1, naxis2: naxis2, maxDimension: clampedMaxDimension
            )
            channels = [grid.values]
            width = grid.width
            height = grid.height
        }
        guard width > 0, height > 0 else { return nil }

        let luminance = sampleLuminance(channels: channels, maxSamples: maxStatsSampleCount)
        let med = median(luminance)
        let deviation = medianAbsoluteDeviation(luminance, median: med)

        guard deviation > madDegenerateThreshold else {
            // Constant/near-constant frame: no contrast for MTF to work
            // with (the normal solve would divide by ~zero). A flat
            // mid-gray preview honestly says "no information" instead of
            // risking NaN or a misleadingly bright/dark placeholder.
            let flat = [UInt8](repeating: degenerateFlatGrayByte, count: width * height)
            return buildImage(channels: channels.map { _ in flat }, width: width, height: height)
        }

        let shadowsClip = max(0, med - shadowsClippingFactor * deviation)
        let rescaleDenominator = max(1 - shadowsClip, 1e-9)
        let rescaledMedian = min(max((med - shadowsClip) / rescaleDenominator, 0), 1)
        let m = solveMidtoneBalance(x0: rescaledMedian, target: targetBackground)

        let stretchedChannels = channels.map { stretchToBytes($0, shadowsClip: shadowsClip, denominator: rescaleDenominator, m: m) }
        return buildImage(channels: stretchedChannels, width: width, height: height)
    }

    // MARK: - Pixel reading (stride-skip downsample on read)

    /// Ceiling integer division (`b` assumed > 0 by every call site here --
    /// callers already clamp `maxDimension`/cell counts to >= 1).
    private static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        (a + b - 1) / b
    }

    /// Decodes one physical pixel value at flat index `pixelIndex`,
    /// applying the ASI-camera `BZERO=32768` "unsigned stored as signed"
    /// convention for `BITPIX=16` the same way `NativeStats` does -- see
    /// `NativeStats.compute16Bit`/`readCrop16Bit` for the sibling logic
    /// this deliberately mirrors (kept inline here rather than shared,
    /// since it's two lines of arithmetic and NativeStats already inlines
    /// it at two call sites of its own).
    private static func rawPixelValue(base: UnsafeRawPointer, pixelIndex: Int, bitpix: Int, isUnsigned16: Bool) -> Double {
        if bitpix == 16 {
            let byteOffset = pixelIndex * 2
            let hi = base.load(fromByteOffset: byteOffset, as: UInt8.self)
            let lo = base.load(fromByteOffset: byteOffset + 1, as: UInt8.self)
            let rawValue = Int16(bitPattern: (UInt16(hi) << 8) | UInt16(lo))
            return isUnsigned16 ? Double(Int32(rawValue) + 32768) : Double(rawValue)
        }
        return Double(base.load(fromByteOffset: pixelIndex, as: UInt8.self))
    }

    /// Reads a grayscale (no Bayer phase to preserve) working grid,
    /// stride-skipping source rows/columns so the result never exceeds
    /// `maxDimension` on its longer side. Values are normalized to 0...1
    /// (clamped) as they're read.
    private static func readMonoGrid(
        data: Data, dataOffset: Int, bitpix: Int, isUnsigned16: Bool, maxValue: Double,
        naxis1: Int, naxis2: Int, maxDimension: Int
    ) -> (values: [Double], width: Int, height: Int) {
        let stride = max(1, ceilDiv(max(naxis1, naxis2), maxDimension))
        let cols = Array(Swift.stride(from: 0, to: naxis1, by: stride))
        let rows = Array(Swift.stride(from: 0, to: naxis2, by: stride))
        let width = cols.count
        let height = rows.count

        var values = [Double](repeating: 0, count: width * height)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            for (outRow, srcRow) in rows.enumerated() {
                let rowBase = srcRow * naxis1
                for (outCol, srcCol) in cols.enumerated() {
                    let raw = rawPixelValue(base: base, pixelIndex: rowBase + srcCol, bitpix: bitpix, isUnsigned16: isUnsigned16)
                    values[outRow * width + outCol] = min(max(raw / maxValue, 0), 1)
                }
            }
        }
        return (values, width, height)
    }

    /// Reads a Bayer-mosaic working grid (still interleaved, pre-debayer),
    /// stride-skipping whole 2x2 CELLS (never individual rows/columns) so
    /// every kept cell still has all four of its original CFA positions
    /// intact -- skipping single rows/columns instead would desync which
    /// physical sensor position is R/G/G/B in the kept data. An odd
    /// trailing row and/or column (outside any whole 2x2 cell) is dropped
    /// entirely rather than guessed at.
    ///
    /// Returns a zero-sized grid (caller treats that as "give up, return
    /// nil") for a degenerate frame narrower/shorter than one full CFA
    /// cell (`naxis1 < 2` or `naxis2 < 2`) -- there's no 2x2 phase to
    /// preserve there at all.
    private static func readBayerMosaic(
        data: Data, dataOffset: Int, bitpix: Int, isUnsigned16: Bool, maxValue: Double,
        naxis1: Int, naxis2: Int, maxDimension: Int
    ) -> (values: [Double], width: Int, height: Int) {
        let evenW = naxis1 - naxis1 % 2
        let evenH = naxis2 - naxis2 % 2
        let numCellsX = evenW / 2
        let numCellsY = evenH / 2

        // `maxDimension` bounds the pre-debayer MOSAIC (twice the eventual
        // RGB size on each axis), so the cell budget is maxDimension/2.
        let maxCells = max(1, maxDimension / 2)
        let cellStride = max(1, ceilDiv(max(numCellsX, numCellsY), maxCells))

        let cellCols = Array(Swift.stride(from: 0, to: numCellsX, by: cellStride))
        let cellRows = Array(Swift.stride(from: 0, to: numCellsY, by: cellStride))
        let width = cellCols.count * 2
        let height = cellRows.count * 2
        guard width > 0, height > 0 else { return ([], 0, 0) }

        var values = [Double](repeating: 0, count: width * height)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            for (outCellRow, cellRow) in cellRows.enumerated() {
                let srcRow0 = cellRow * 2
                for (outCellCol, cellCol) in cellCols.enumerated() {
                    let srcCol0 = cellCol * 2
                    for dr in 0..<2 {
                        let rowBase = (srcRow0 + dr) * naxis1
                        let outRow = outCellRow * 2 + dr
                        for dc in 0..<2 {
                            let raw = rawPixelValue(base: base, pixelIndex: rowBase + srcCol0 + dc, bitpix: bitpix, isUnsigned16: isUnsigned16)
                            let outCol = outCellCol * 2 + dc
                            values[outRow * width + outCol] = min(max(raw / maxValue, 0), 1)
                        }
                    }
                }
            }
        }
        return (values, width, height)
    }

    // MARK: - Debayer (superpixel)

    /// Collapses each 2x2 CFA cell in `mosaic` to one RGB pixel: the two
    /// green positions are averaged, red/blue are taken as-is. `labels`
    /// (from `BayerMap.labels`) gives the 4 positions' colors in
    /// `(0,0),(0,1),(1,0),(1,1)` order, matching `mosaic`'s own row-major
    /// layout within each cell.
    private static func debayer(
        mosaic: [Double], width: Int, height: Int, labels: [Character]
    ) -> (r: [Double], g: [Double], b: [Double], width: Int, height: Int) {
        let outW = width / 2
        let outH = height / 2
        var r = [Double](repeating: 0, count: outW * outH)
        var g = [Double](repeating: 0, count: outW * outH)
        var b = [Double](repeating: 0, count: outW * outH)

        for cellRow in 0..<outH {
            let row0 = cellRow * 2
            for cellCol in 0..<outW {
                let col0 = cellCol * 2
                let values = [
                    mosaic[row0 * width + col0],
                    mosaic[row0 * width + col0 + 1],
                    mosaic[(row0 + 1) * width + col0],
                    mosaic[(row0 + 1) * width + col0 + 1],
                ]

                var rSum = 0.0, rCount = 0
                var gSum = 0.0, gCount = 0
                var bSum = 0.0, bCount = 0
                for (label, value) in zip(labels, values) {
                    switch label {
                    case "R": rSum += value; rCount += 1
                    case "G": gSum += value; gCount += 1
                    case "B": bSum += value; bCount += 1
                    default: break
                    }
                }
                let outIndex = cellRow * outW + cellCol
                r[outIndex] = rCount > 0 ? rSum / Double(rCount) : 0
                g[outIndex] = gCount > 0 ? gSum / Double(gCount) : 0
                b[outIndex] = bCount > 0 ? bSum / Double(bCount) : 0
            }
        }
        return (r, g, b, outW, outH)
    }

    // MARK: - Statistics (median / MAD, sampled)

    /// Per-pixel average across all channels (1 for grayscale, 3 for
    /// color), stride-sampled down to at most `maxSamples` points -- used
    /// as the brightness proxy the MTF stretch is solved against. Pooling
    /// per-pixel rather than per-channel avoids any single channel's own
    /// scale dominating the statistic.
    private static func sampleLuminance(channels: [[Double]], maxSamples: Int) -> [Double] {
        guard let first = channels.first, !first.isEmpty else { return [] }
        let total = first.count
        let stride = max(1, ceilDiv(total, maxSamples))

        var samples: [Double] = []
        samples.reserveCapacity(min(total, maxSamples) + 1)
        var i = 0
        while i < total {
            var sum = 0.0
            for channel in channels { sum += channel[i] }
            samples.append(sum / Double(channels.count))
            i += stride
        }
        return samples
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    private static func medianAbsoluteDeviation(_ xs: [Double], median med: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        return median(xs.map { abs($0 - med) })
    }

    // MARK: - MTF auto-stretch

    /// PixInsight/Siril's midtones transfer function: a monotonic bijection
    /// on `x` in [0,1] for `m` in (0,1), used both to solve for `m` (see
    /// `solveMidtoneBalance`) and to apply the resulting stretch per pixel.
    private static func mtf(_ x: Double, _ m: Double) -> Double {
        let denominator = (2 * m - 1) * x - m
        guard denominator != 0 else { return x < m ? 0 : 1 }
        return ((m - 1) * x) / denominator
    }

    /// Solves for the midtone parameter `m` such that `mtf(x0, m) ==
    /// target`, given `mtf`'s closed-form inverse:
    /// `m = x0*(1-target) / (x0 + target - 2*x0*target)`. `x0` is clamped
    /// away from the exact 0/1 endpoints (where the closed form is
    /// degenerate) before solving, and the result is clamped to stay a
    /// valid midtone (0,1) for numerical safety.
    private static func solveMidtoneBalance(x0: Double, target: Double) -> Double {
        let x = min(max(x0, 1e-6), 1 - 1e-6)
        let y = target
        let denominator = x + y - 2 * x * y
        guard denominator != 0 else { return 0.5 }
        let m = x * (1 - y) / denominator
        return min(max(m, 1e-6), 1 - 1e-6)
    }

    /// Applies the full stretch (shadow-clip rescale, then MTF) to every
    /// value in `channel`, producing 8-bit output bytes. `denominator` is
    /// `1 - shadowsClip`, pre-clamped away from zero by the caller so every
    /// call site (one per channel) shares the exact same rescale.
    private static func stretchToBytes(_ channel: [Double], shadowsClip: Double, denominator: Double, m: Double) -> [UInt8] {
        channel.map { x in
            let clamped = min(max(x, 0), 1)
            let rescaled = min(max((clamped - shadowsClip) / denominator, 0), 1)
            let y = min(max(mtf(rescaled, m), 0), 1)
            return UInt8((y * 255).rounded())
        }
    }

    // MARK: - CGImage construction

    /// Builds the final `CGImage`: grayscale for 1 channel, RGBA (opaque)
    /// for 3. `channels[n]` must all share `width*height` elements.
    private static func buildImage(channels: [[UInt8]], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        if channels.count >= 3 {
            return makeRGBImage(width: width, height: height, r: channels[0], g: channels[1], b: channels[2])
        }
        return makeGrayImage(width: width, height: height, gray: channels[0])
    }

    /// FITS pixel row 0 is the image's BOTTOM (FITS `NAXIS2` increases
    /// upward); a displayable bitmap's row 0 is its TOP. Both packers read
    /// the source bottom-to-top so the result comes out right-side-up
    /// rather than vertically mirrored.
    private static func makeRGBImage(width: Int, height: Int, r: [UInt8], g: [UInt8], b: [UInt8]) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let srcRow = height - 1 - row
            let srcRowBase = srcRow * width
            let dstRowBase = row * width
            for col in 0..<width {
                let srcIndex = srcRowBase + col
                let dstIndex = (dstRowBase + col) * 4
                bytes[dstIndex] = r[srcIndex]
                bytes[dstIndex + 1] = g[srcIndex]
                bytes[dstIndex + 2] = b[srcIndex]
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func makeGrayImage(width: Int, height: Int, gray: [UInt8]) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let srcRow = height - 1 - row
            let srcRowBase = srcRow * width
            let dstRowBase = row * width
            for col in 0..<width {
                bytes[dstRowBase + col] = gray[srcRowBase + col]
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
