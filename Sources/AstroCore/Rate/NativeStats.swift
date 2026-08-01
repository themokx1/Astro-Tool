import Foundation

/// Cheap, dependency-free pixel statistics computed directly from a FITS
/// frame's primary data block — no external tool required. These are always
/// available (unlike Siril-derived star metrics, which need an optional
/// external adapter), so `Rater` can score every frame on at least these
/// two axes.
public struct NativeFrameStats: Codable, Equatable, Sendable {
    /// Median pixel value across the frame (see `NativeStats.compute` for
    /// the sampling strategy used on large frames).
    public var backgroundMedian: Double
    /// Fraction of pixels at or above 98% of the data type's maximum
    /// representable value — a proxy for blown-out/saturated pixels.
    public var saturatedFraction: Double

    public init(backgroundMedian: Double, saturatedFraction: Double) {
        self.backgroundMedian = backgroundMedian
        self.saturatedFraction = saturatedFraction
    }
}

/// Computes `NativeFrameStats` straight from a FITS file's primary HDU: the
/// header is parsed with `FITSReader.parse` for `BITPIX`/`NAXIS1`/`NAXIS2`,
/// then the raw pixel bytes immediately following that header are read and
/// reduced to a background median + saturated-pixel fraction.
///
/// Only plain (non-`.fz`) primary-HDU data is supported: the pixel data is
/// assumed to start right after the primary header's own blocks, which is
/// the normal layout for raw light frames straight off a camera/capture
/// tool. Rice-compressed `.fz` files (whose pixels live inside a `BINTABLE`
/// extension, not right after the primary header) are out of scope here.
public enum NativeStats {
    private static let blockSize = 2880
    private static let cardSize = 80
    private static let cardsPerBlock = blockSize / cardSize

    /// Above this many pixels, the median is computed from a stride-sampled
    /// subset (~100k samples) rather than sorting every pixel — sorting a
    /// full multi-megapixel frame for a single summary statistic is wasted
    /// work; a ~100k-pixel systematic sample gives an equally usable median
    /// for rating purposes.
    private static let sampleThreshold = 1_000_000
    private static let targetSampleCount = 100_000

    /// Convenience entry point: reads `url` and computes stats from its
    /// bytes. See `compute(data:)` for the actual logic.
    public static func compute(url: URL) throws -> NativeFrameStats {
        let data = try Data(contentsOf: url)
        return try compute(data: data)
    }

    /// Computes stats from an in-memory FITS file buffer. Throws
    /// `AstroError.corruptFITS` when the header can't be parsed, is missing
    /// `NAXIS1`/`NAXIS2`, the pixel data is truncated, or `BITPIX` is
    /// anything other than 8 or 16 (the only depths real capture tools in
    /// this pipeline produce).
    public static func compute(data: Data) throws -> NativeFrameStats {
        let header = try FITSReader.parse(data: data)

        guard let bitpix = header.int("BITPIX") else {
            throw AstroError.corruptFITS(path: "<data>", reason: "missing BITPIX")
        }
        guard let naxis1 = header.int("NAXIS1"), naxis1 > 0,
              let naxis2 = header.int("NAXIS2"), naxis2 > 0
        else {
            throw AstroError.corruptFITS(path: "<data>", reason: "missing or invalid NAXIS1/NAXIS2")
        }

        let pixelCount = naxis1 * naxis2
        let dataOffset = try primaryHeaderByteLength(data: data)

        switch bitpix {
        case 16:
            let bzero = header.double("BZERO") ?? 0
            let isUnsigned = bzero == 32768
            let maxValue: Double = isUnsigned ? 65535 : 32767
            return try compute16Bit(
                data: data, dataOffset: dataOffset, pixelCount: pixelCount,
                isUnsigned: isUnsigned, maxValue: maxValue
            )
        case 8:
            return try compute8Bit(data: data, dataOffset: dataOffset, pixelCount: pixelCount, maxValue: 255)
        default:
            throw AstroError.corruptFITS(path: "<data>", reason: "unsupported BITPIX")
        }
    }

    // MARK: - Pixel reduction

    private static func compute16Bit(
        data: Data, dataOffset: Int, pixelCount: Int, isUnsigned: Bool, maxValue: Double
    ) throws -> NativeFrameStats {
        let byteCount = pixelCount * 2
        guard dataOffset + byteCount <= data.count else {
            throw AstroError.corruptFITS(path: "<data>", reason: "truncated pixel data")
        }

        let stride = max(1, pixelCount / targetSampleCount)
        var samples: [Double] = []
        samples.reserveCapacity(min(pixelCount, targetSampleCount) + 1)
        var saturatedCount = 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            for i in 0..<pixelCount {
                let byteOffset = i * 2
                let hi = base.load(fromByteOffset: byteOffset, as: UInt8.self)
                let lo = base.load(fromByteOffset: byteOffset + 1, as: UInt8.self)
                let rawValue = Int16(bitPattern: (UInt16(hi) << 8) | UInt16(lo))
                let value: Double = isUnsigned ? Double(Int32(rawValue) + 32768) : Double(rawValue)

                if value >= 0.98 * maxValue { saturatedCount += 1 }
                if i % stride == 0 { samples.append(value) }
            }
        }

        return NativeFrameStats(
            backgroundMedian: median(of: samples),
            saturatedFraction: Double(saturatedCount) / Double(pixelCount)
        )
    }

    private static func compute8Bit(
        data: Data, dataOffset: Int, pixelCount: Int, maxValue: Double
    ) throws -> NativeFrameStats {
        guard dataOffset + pixelCount <= data.count else {
            throw AstroError.corruptFITS(path: "<data>", reason: "truncated pixel data")
        }

        let stride = max(1, pixelCount / targetSampleCount)
        var samples: [Double] = []
        samples.reserveCapacity(min(pixelCount, targetSampleCount) + 1)
        var saturatedCount = 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            for i in 0..<pixelCount {
                let value = Double(base.load(fromByteOffset: i, as: UInt8.self))
                if value >= 0.98 * maxValue { saturatedCount += 1 }
                if i % stride == 0 { samples.append(value) }
            }
        }

        return NativeFrameStats(
            backgroundMedian: median(of: samples),
            saturatedFraction: Double(saturatedCount) / Double(pixelCount)
        )
    }

    private static func median(of samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return sorted[n / 2]
        }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    // MARK: - Header byte length

    /// Scans 2880-byte blocks from the start of `data`, looking for the
    /// primary header's `END` card, and returns the byte offset immediately
    /// following it (i.e. where the primary data block begins). This
    /// mirrors `FITSReader`'s own block scanning but only needs the byte
    /// offset, not the parsed keyword values `FITSReader.parse` already
    /// gave us.
    private static func primaryHeaderByteLength(data: Data) throws -> Int {
        var offset = 0
        while true {
            guard offset + blockSize <= data.count else {
                throw AstroError.corruptFITS(path: "<data>", reason: "truncated FITS header")
            }
            let block = data.subdata(in: offset..<(offset + blockSize))
            offset += blockSize

            guard let blockString = String(data: block, encoding: .ascii) else {
                throw AstroError.corruptFITS(path: "<data>", reason: "header block contains non-ASCII bytes")
            }
            let chars = Array(blockString)

            for cardIndex in 0..<cardsPerBlock {
                let start = cardIndex * cardSize
                let keyword = String(chars[start..<(start + 8)]).trimmingCharacters(in: .whitespaces)
                if keyword == "END" {
                    return offset
                }
            }
        }
    }
}
