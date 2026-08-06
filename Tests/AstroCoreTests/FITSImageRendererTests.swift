import Foundation
import Testing
import CoreGraphics
@testable import AstroCore

// MARK: - Fixture helpers
//
// `card` / `buildHeaderData` come from `FITSTestBuilder.swift` (shared with
// `FITSReaderTests`/`ScannerTests`). The pixel-data builders below mirror
// `RateTests.build16BitFITS`/`buildFZShapedFITS` in shape, but are kept
// local to this file rather than promoted to the shared builder -- the two
// test files (`NativeStats` vs. `FITSImageRenderer`) evolve independently
// and neither should risk breaking the other's fixtures.

/// Builds a plain (non-`.fz`) primary-HDU FITS file: header + big-endian
/// pixel data, `BITPIX` 8 or 16, optional `BZERO` (ASI "unsigned stored as
/// signed" convention: pixel `value - bzero` is what's written on disk, so
/// a reader that adds `bzero` back gets `value`) and optional `BAYERPAT`.
private func buildFITS(
    width: Int, height: Int, pixels: [Int], bitpix: Int = 16, bzero: Int? = nil, bayerPattern: String? = nil
) -> Data {
    precondition(pixels.count == width * height, "pixel count must match width*height")
    var cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   \(bitpix)",
        "NAXIS   =                    2",
        "NAXIS1  =                 \(width)",
        "NAXIS2  =                 \(height)",
    ]
    if let bzero {
        cards.append("BZERO   =                \(bzero)")
    }
    if let bayerPattern {
        cards.append("BAYERPAT= '\(bayerPattern)'")
    }
    cards.append("END")

    var data = buildHeaderData(cards)
    var pixelBytes = Data()
    if bitpix == 16 {
        pixelBytes.reserveCapacity(pixels.count * 2)
        for value in pixels {
            let raw = Int16(bzero.map { value - $0 } ?? value)
            let unsigned = UInt16(bitPattern: raw)
            pixelBytes.append(UInt8(unsigned >> 8))
            pixelBytes.append(UInt8(unsigned & 0xFF))
        }
    } else {
        pixelBytes.reserveCapacity(pixels.count)
        for value in pixels {
            pixelBytes.append(UInt8(clamping: value))
        }
    }
    data.append(pixelBytes)
    return data
}

/// Realistic `.fz` (fpack-style Rice-compressed) layout: primary HDU with
/// `NAXIS=0` immediately followed by a `BINTABLE` extension carrying the
/// tile-compression keywords -- mirrors `RateTests.buildFZShapedFITS`.
private func buildCompressedFITSFixture() -> Data {
    let primaryCards = [
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "END",
    ]
    let extensionCards = [
        "XTENSION= 'BINTABLE'",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    1",
        "NAXIS2  =                    1",
        "PCOUNT  =                  500",
        "GCOUNT  =                    1",
        "TFIELDS =                    1",
        "ZIMAGE  =                    T",
        "ZCMPTYPE= 'RICE_1  '",
        "ZBITPIX =                   16",
        "ZNAXIS  =                    2",
        "ZNAXIS1 =                   10",
        "ZNAXIS2 =                   10",
        "END",
    ]
    var data = buildHeaderData(primaryCards)
    data.append(buildHeaderData(extensionCards))
    data.append(Data(repeating: 0xAB, count: 500))
    return data
}

/// `BITPIX=32` (float/other-depth) primary HDU -- a real, well-formed FITS
/// layout this renderer just doesn't support (only 8/16 are handled).
private func buildBitpix32Fixture() -> Data {
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   32",
        "NAXIS   =                    2",
        "NAXIS1  =                    4",
        "NAXIS2  =                    4",
        "END",
    ]
    var data = buildHeaderData(cards)
    data.append(Data(repeating: 0, count: 4 * 4 * 4))
    return data
}

/// `NAXIS=1` primary HDU (a 1-D spectrum-shaped file, not an image) --
/// deliberately has no `NAXIS2` card at all, so a renderer that checked
/// `NAXIS1`/`NAXIS2` presence *before* checking `NAXIS == 2` would throw
/// instead of returning `nil`. This fixture only passes if the `NAXIS`
/// check runs first.
private func buildNaxisOneFixture() -> Data {
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    1",
        "NAXIS1  =                   10",
        "END",
    ]
    var data = buildHeaderData(cards)
    data.append(Data(repeating: 0, count: 20))
    return data
}

/// Reads back an 8-bit grayscale `CGImage`'s raw bytes, one per pixel, in
/// on-disk row order (row 0 first) -- valid only because
/// `FITSImageRenderer`'s gray output has no row padding (`bytesPerRow ==
/// width`) and no alpha channel.
private func grayBytes(_ image: CGImage) -> [UInt8] {
    [UInt8](image.dataProvider!.data! as Data)
}

/// Reads back an 8-bit-per-component RGBA `CGImage`'s bytes as parallel
/// R/G/B arrays (alpha dropped) -- valid only because
/// `FITSImageRenderer`'s color output has no row padding (`bytesPerRow ==
/// width*4`).
private func rgbaBytes(_ image: CGImage) -> (r: [UInt8], g: [UInt8], b: [UInt8]) {
    let bytes = [UInt8](image.dataProvider!.data! as Data)
    let count = image.width * image.height
    var r = [UInt8](repeating: 0, count: count)
    var g = [UInt8](repeating: 0, count: count)
    var b = [UInt8](repeating: 0, count: count)
    for i in 0..<count {
        r[i] = bytes[i * 4]
        g[i] = bytes[i * 4 + 1]
        b[i] = bytes[i * 4 + 2]
    }
    return (r, g, b)
}

// MARK: - Mono rendering + downsampling + BZERO

@Test func rendersSixteenBitMonoWithBZeroAndRespectsMaxDimension() throws {
    let width = 200, height = 150
    // Mostly-flat background with scattered brighter pixels so the frame
    // has real contrast (a perfectly flat frame would hit the MAD==0
    // flat-gray fallback tested separately below).
    var pixels = [Int](repeating: 30000, count: width * height)
    for i in pixels.indices where i % 7 == 0 { pixels[i] = 40000 }
    let data = buildFITS(width: width, height: height, pixels: pixels, bzero: 32768)

    let image = try FITSImageRenderer.render(data: data, maxDimension: 64)
    let cgImage = try #require(image, "a supported 16-bit mono BZERO=32768 frame must render")

    #expect(cgImage.width <= 64)
    #expect(cgImage.height <= 64)
    #expect(cgImage.width > 0 && cgImage.height > 0)
    // No BAYERPAT -> grayscale (1 component), not RGBA.
    #expect(cgImage.bitsPerPixel == 8)
}

@Test func rendersEightBitMonoFrame() throws {
    let width = 10, height = 10
    var pixels = [Int](repeating: 100, count: width * height)
    for i in pixels.indices where i % 3 == 0 { pixels[i] = 200 }
    let data = buildFITS(width: width, height: height, pixels: pixels, bitpix: 8)

    let image = try FITSImageRenderer.render(data: data)
    let cgImage = try #require(image, "BITPIX=8 is a supported depth")
    #expect(cgImage.width == 10)
    #expect(cgImage.height == 10)
}

@Test func renderFromURLReadsFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-fits-image-renderer-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let width = 16, height = 16
    var pixels = [Int](repeating: 1000, count: width * height)
    for i in pixels.indices where i % 5 == 0 { pixels[i] = 2000 }
    let data = buildFITS(width: width, height: height, pixels: pixels)
    let url = dir.appendingPathComponent("frame.fit")
    try data.write(to: url)

    let image = try FITSImageRenderer.render(url: url)
    #expect(image != nil)
}

// MARK: - Debayer

@Test func debayersRGGBWithCorrectChannelDominance() throws {
    // 8x8 mosaic = 16 Bayer cells. Fifteen cells are neutral "sky"
    // background (alternating 990/1010 so the frame has real contrast,
    // avoiding the MAD==0 flat-gray path); one cell is a strongly
    // red-dominant "star" (high R, mid G, low B). RGGB layout per cell:
    // row0 = R,G ; row1 = G,B.
    let width = 8, height = 8
    var pixels = [Int](repeating: 0, count: width * height)
    for cellRow in 0..<4 {
        for cellCol in 0..<4 {
            let r0 = cellRow * 2, c0 = cellCol * 2
            let isSignalCell = (cellRow == 0 && cellCol == 0)
            let (r, g, b): (Int, Int, Int)
            if isSignalCell {
                (r, g, b) = (30000, 15000, 2000)
            } else {
                let neutral = ((cellRow * 4 + cellCol) % 2 == 0) ? 990 : 1010
                (r, g, b) = (neutral, neutral, neutral)
            }
            pixels[r0 * width + c0] = r         // (0,0) R
            pixels[r0 * width + c0 + 1] = g      // (0,1) G
            pixels[(r0 + 1) * width + c0] = g    // (1,0) G
            pixels[(r0 + 1) * width + c0 + 1] = b // (1,1) B
        }
    }
    let data = buildFITS(width: width, height: height, pixels: pixels, bayerPattern: "RGGB")

    let image = try FITSImageRenderer.render(data: data, maxDimension: 1024)
    let cgImage = try #require(image)
    #expect(cgImage.width == 4, "8x8 mosaic debayers to 4x4")
    #expect(cgImage.height == 4)
    #expect(cgImage.bitsPerPixel == 32, "BAYERPAT present -> RGBA color output")

    let (r, g, b) = rgbaBytes(cgImage)
    // Whichever pixel ends up reddest must be the signal cell -- and at
    // that exact pixel, R must dominate B (same monotonic MTF applied to
    // every channel preserves per-pixel channel ordering, so R>B before
    // the stretch guarantees R>B after it). The margin required is modest
    // (not e.g. 100+) because this fixture's background sits at ~3% of
    // full-scale, which drives the solved midtone `m` very low and makes
    // MTF compress separation between BRIGHT pixels toward white -- the
    // point here is confirming R/B were not swapped, not measuring exact
    // contrast.
    let maxRIndex = r.indices.max { r[$0] < r[$1] }!
    #expect(Int(r[maxRIndex]) - Int(b[maxRIndex]) > 10, "the reddest pixel should be red-dominant, not blue-dominant")
    #expect(Int(r[maxRIndex]) - Int(g[maxRIndex]) > 0, "R should also exceed G at the signal cell")
}

@Test func unknownBayerPatternFallsBackToGrayscale() throws {
    let width = 8, height = 8
    var pixels = [Int](repeating: 1000, count: width * height)
    for i in pixels.indices where i % 3 == 0 { pixels[i] = 1500 }
    let data = buildFITS(width: width, height: height, pixels: pixels, bayerPattern: "XYZW")

    let image = try FITSImageRenderer.render(data: data)
    let cgImage = try #require(image)
    #expect(cgImage.bitsPerPixel == 8, "an unrecognized BAYERPAT must fall back to grayscale, not guess a mapping")
}

@Test func oddDimensionBayerFrameTruncatesLastRowColumnWithoutCrashing() throws {
    // 5x5 (odd both dimensions). Value depends only on (row%2, col%2), so
    // the kept 4x4 region (rows/cols 0...3) is well-defined regardless of
    // exactly how the last row/column get dropped.
    let width = 5, height = 5
    var pixels = [Int](repeating: 0, count: width * height)
    for row in 0..<height {
        for col in 0..<width {
            let value: Int
            switch (row % 2, col % 2) {
            case (0, 0): value = 1000
            case (0, 1): value = 1250
            case (1, 0): value = 1500
            default: value = 1750
            }
            pixels[row * width + col] = value
        }
    }
    let data = buildFITS(width: width, height: height, pixels: pixels, bayerPattern: "RGGB")

    // Must not crash/trap regardless of outcome.
    let image = try FITSImageRenderer.render(data: data, maxDimension: 1024)
    let cgImage = try #require(image, "a truncated-to-even 4x4 region is still renderable")
    #expect(cgImage.width == 2, "4x4 kept region debayers to 2x2")
    #expect(cgImage.height == 2)
}

// MARK: - Auto-stretch (MTF)

@Test func lowSignalFrameStretchesMedianNearQuarterBrightness() throws {
    // 25 pixels (odd count -> unambiguous single-value median), values
    // 990 (x12), 1000 (x1), 1010 (x12): median == 1000 exactly, MAD == 10
    // exactly (deviations are all 0 or 10). This whole population fits
    // under the 200k stats-sampling cap, so the stretch is computed from
    // an exact, fully-known distribution -- the image's own median byte
    // must land at MTF's target background (~0.25 * 255 ≈ 64).
    var pixels = [Int](repeating: 1000, count: 25)
    for i in 0..<12 { pixels[i] = 990 }
    for i in 12..<24 { pixels[i] = 1010 }
    // index 24 stays 1000 (the exact median value).
    let data = buildFITS(width: 5, height: 5, pixels: pixels)

    let image = try FITSImageRenderer.render(data: data, maxDimension: 1024)
    let cgImage = try #require(image)
    let bytes = grayBytes(cgImage).sorted()
    #expect(bytes.count == 25)
    let medianByte = bytes[12]
    #expect(medianByte > 20, "a low-signal frame must not stay near-black after auto-stretch")
    #expect(abs(Int(medianByte) - 64) <= 4, "median should map close to the 0.25 target background (~64/255)")
}

@Test func constantFrameReturnsFlatMidGrayWithoutCrashing() throws {
    let width = 4, height = 4
    let pixels = [Int](repeating: 5000, count: width * height)
    let data = buildFITS(width: width, height: height, pixels: pixels)

    let image = try FITSImageRenderer.render(data: data)
    let cgImage = try #require(image, "a constant frame is degenerate but still valid -- must not throw or return nil")
    let bytes = grayBytes(cgImage)
    #expect(bytes.allSatisfy { $0 == 128 }, "MAD==0 must fall back to a flat mid-gray, not NaN/garbage")
}

// MARK: - Unsupported layouts -> nil (never garbage, never throw)

@Test func compressedFZLayoutReturnsNilWithoutThrowing() throws {
    let data = buildCompressedFITSFixture()
    let image = try FITSImageRenderer.render(data: data, maxDimension: 256)
    #expect(image == nil)
}

@Test func unsupportedBitpix32ReturnsNilWithoutThrowing() throws {
    let data = buildBitpix32Fixture()
    let image = try FITSImageRenderer.render(data: data)
    #expect(image == nil)
}

@Test func naxisNotEqualTwoReturnsNilWithoutThrowing() throws {
    let data = buildNaxisOneFixture()
    let image = try FITSImageRenderer.render(data: data)
    #expect(image == nil)
}

// MARK: - Genuine corruption still throws (distinct from "unsupported -> nil")

@Test func truncatedPixelDataThrows() throws {
    let cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                   10",
        "NAXIS2  =                   10",
        "END",
    ]
    var data = buildHeaderData(cards)
    data.append(Data(repeating: 0, count: 10)) // needs 200 bytes, only 10 present

    #expect(throws: AstroError.self) {
        _ = try FITSImageRenderer.render(data: data)
    }
}
