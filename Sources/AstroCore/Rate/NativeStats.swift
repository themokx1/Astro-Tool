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
    /// Median pixel value over only the pixels at grid position
    /// `(row%2, col%2) == (0,0)` within the same sampled pass that produces
    /// `backgroundMedian` -- i.e. one quadrant of a Bayer-pattern CFA
    /// sensor's 2x2 tile, NOT yet mapped to a color channel (that mapping
    /// depends on the frame's `BAYERPAT` header and belongs to
    /// `BayerMap.channelMedians`, a consumer-level concern). `nil` when the
    /// frame has no pixel at this parity at all (e.g. a 1-column frame has
    /// no `col%2 == 1` position, so `backgroundMedian01`/`backgroundMedian11`
    /// would be `nil`).
    public var backgroundMedian00: Double?
    /// Same as `backgroundMedian00`, for grid position `(row%2, col%2) == (0,1)`.
    public var backgroundMedian01: Double?
    /// Same as `backgroundMedian00`, for grid position `(row%2, col%2) == (1,0)`.
    public var backgroundMedian10: Double?
    /// Same as `backgroundMedian00`, for grid position `(row%2, col%2) == (1,1)`.
    public var backgroundMedian11: Double?

    public init(
        backgroundMedian: Double,
        saturatedFraction: Double,
        backgroundMedian00: Double? = nil,
        backgroundMedian01: Double? = nil,
        backgroundMedian10: Double? = nil,
        backgroundMedian11: Double? = nil
    ) {
        self.backgroundMedian = backgroundMedian
        self.saturatedFraction = saturatedFraction
        self.backgroundMedian00 = backgroundMedian00
        self.backgroundMedian01 = backgroundMedian01
        self.backgroundMedian10 = backgroundMedian10
        self.backgroundMedian11 = backgroundMedian11
    }
}

/// Maps `NativeFrameStats`'s parity-indexed per-Bayer medians
/// (`backgroundMedian00`/`01`/`10`/`11`, positions in a 2x2 CFA tile) to
/// actual R/G/G/B color channels, using the frame's own `BAYERPAT` FITS
/// header value -- a consumer-level concern deliberately kept out of
/// `NativeStats` itself, which only knows pixel positions, never colors.
/// The two green positions (present in every standard CFA pattern) are
/// averaged into a single `g` value -- both are the same color, just
/// differently-neighbored samples of it.
public enum BayerMap {
    /// `bayerPattern` is matched case-insensitively against the four
    /// standard CFA layouts; anything else (unset header, an unrecognized
    /// string) yields `(nil, nil, nil)` rather than guessing -- silently
    /// mislabeling a channel would be worse than admitting it isn't known.
    public static func channelMedians(
        stats: NativeFrameStats,
        bayerPattern: String?
    ) -> (r: Double?, g: Double?, b: Double?) {
        guard let pattern = bayerPattern?.uppercased() else { return (nil, nil, nil) }

        let labels: [Character]
        switch pattern {
        case "RGGB": labels = ["R", "G", "G", "B"]
        case "BGGR": labels = ["B", "G", "G", "R"]
        case "GRBG": labels = ["G", "R", "B", "G"]
        case "GBRG": labels = ["G", "B", "R", "G"]
        default: return (nil, nil, nil)
        }

        // Position order matches `NativeFrameStats`'s own 00/01/10/11 fields.
        let values = [stats.backgroundMedian00, stats.backgroundMedian01, stats.backgroundMedian10, stats.backgroundMedian11]

        func average(for channel: Character) -> Double? {
            let matched = zip(labels, values).filter { $0.0 == channel }.compactMap(\.1)
            guard !matched.isEmpty else { return nil }
            return matched.reduce(0, +) / Double(matched.count)
        }

        return (average(for: "R"), average(for: "G"), average(for: "B"))
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
/// tool. Rice-compressed `.fz` files (whose pixels live Rice-encoded inside
/// a `BINTABLE` extension's heap, not as a flat grid right after the
/// primary header) are actively rejected -- see the compressed-layout guard
/// in `compute(data:)` -- rather than silently read as garbage.
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
    /// `AstroError.corruptFITS` when the header can't be parsed, describes a
    /// compressed (`.fz`-style) layout, is missing `NAXIS1`/`NAXIS2`, the
    /// pixel data is truncated, or `BITPIX` is anything other than 8 or 16
    /// (the only depths real capture tools in this pipeline produce).
    public static func compute(data: Data) throws -> NativeFrameStats {
        let header = try FITSReader.parse(data: data)
        let (dataOffset, rawPrimaryNAXIS) = try primaryHeaderInfo(data: data)

        // `FITSReader.parse` merges a `.fz` file's BINTABLE extension header
        // into the returned `FITSHeader` -- including backfilling NAXIS1/
        // NAXIS2 from ZNAXIS1/ZNAXIS2 -- so a plain "is NAXIS1/NAXIS2
        // present" check below would never catch this case, and reading
        // "pixel data" right after the primary header would actually read
        // the extension header's own text and/or the Rice-compressed heap
        // bytes as if they were flat pixels, silently producing garbage
        // stats. Detect the compressed layout positively instead, from two
        // independent signals: the merged header carrying any tile-
        // compression keyword (present only when an extension was merged
        // in), or the *raw* primary header (read fresh below, unaffected by
        // the merge) declaring `NAXIS=0` (no pixel data of its own,
        // regardless of why).
        let hasCompressionKeywords = header.allCards["ZIMAGE"] != nil
            || header.allCards["ZCMPTYPE"] != nil
            || header.allCards["ZBITPIX"] != nil
        guard !hasCompressionKeywords, rawPrimaryNAXIS != 0 else {
            throw AstroError.corruptFITS(path: "", reason: "compressed FITS (.fz) pixel data unsupported")
        }

        guard let bitpix = header.int("BITPIX") else {
            throw AstroError.corruptFITS(path: "<data>", reason: "missing BITPIX")
        }
        guard let naxis1 = header.int("NAXIS1"), naxis1 > 0,
              let naxis2 = header.int("NAXIS2"), naxis2 > 0
        else {
            throw AstroError.corruptFITS(path: "<data>", reason: "missing or invalid NAXIS1/NAXIS2")
        }

        let pixelCount = naxis1 * naxis2

        switch bitpix {
        case 16:
            let bzero = header.double("BZERO") ?? 0
            let isUnsigned = bzero == 32768
            let maxValue: Double = isUnsigned ? 65535 : 32767
            return try compute16Bit(
                data: data, dataOffset: dataOffset, pixelCount: pixelCount, naxis1: naxis1,
                isUnsigned: isUnsigned, maxValue: maxValue
            )
        case 8:
            return try compute8Bit(data: data, dataOffset: dataOffset, pixelCount: pixelCount, naxis1: naxis1, maxValue: 255)
        default:
            throw AstroError.corruptFITS(path: "<data>", reason: "unsupported BITPIX")
        }
    }

    // MARK: - Pixel reduction

    /// Accumulates the overall sample array plus the four Bayer-parity
    /// buckets (`(row%2, col%2)`, keyed same order as `NativeFrameStats`'s
    /// `00`/`01`/`10`/`11` fields) for every stride-selected pixel index --
    /// shared by `compute16Bit`/`compute8Bit` so the bucketing logic (and
    /// its row/col arithmetic) exists exactly once.
    private struct BayerBuckets {
        var b00: [Double] = []
        var b01: [Double] = []
        var b10: [Double] = []
        var b11: [Double] = []

        mutating func append(_ value: Double, row: Int, col: Int) {
            switch (row % 2, col % 2) {
            case (0, 0): b00.append(value)
            case (0, 1): b01.append(value)
            case (1, 0): b10.append(value)
            default: b11.append(value)
            }
        }
    }

    private static func compute16Bit(
        data: Data, dataOffset: Int, pixelCount: Int, naxis1: Int, isUnsigned: Bool, maxValue: Double
    ) throws -> NativeFrameStats {
        let byteCount = pixelCount * 2
        guard dataOffset + byteCount <= data.count else {
            throw AstroError.corruptFITS(path: "<data>", reason: "truncated pixel data")
        }

        let stride = max(1, pixelCount / targetSampleCount)
        var samples: [Double] = []
        samples.reserveCapacity(min(pixelCount, targetSampleCount) + 1)
        var buckets = BayerBuckets()
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
                if i % stride == 0 {
                    samples.append(value)
                    buckets.append(value, row: i / naxis1, col: i % naxis1)
                }
            }
        }

        return NativeFrameStats(
            backgroundMedian: median(of: samples),
            saturatedFraction: Double(saturatedCount) / Double(pixelCount),
            backgroundMedian00: medianOrNil(of: buckets.b00),
            backgroundMedian01: medianOrNil(of: buckets.b01),
            backgroundMedian10: medianOrNil(of: buckets.b10),
            backgroundMedian11: medianOrNil(of: buckets.b11)
        )
    }

    private static func compute8Bit(
        data: Data, dataOffset: Int, pixelCount: Int, naxis1: Int, maxValue: Double
    ) throws -> NativeFrameStats {
        guard dataOffset + pixelCount <= data.count else {
            throw AstroError.corruptFITS(path: "<data>", reason: "truncated pixel data")
        }

        let stride = max(1, pixelCount / targetSampleCount)
        var samples: [Double] = []
        samples.reserveCapacity(min(pixelCount, targetSampleCount) + 1)
        var buckets = BayerBuckets()
        var saturatedCount = 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            for i in 0..<pixelCount {
                let value = Double(base.load(fromByteOffset: i, as: UInt8.self))
                if value >= 0.98 * maxValue { saturatedCount += 1 }
                if i % stride == 0 {
                    samples.append(value)
                    buckets.append(value, row: i / naxis1, col: i % naxis1)
                }
            }
        }

        return NativeFrameStats(
            backgroundMedian: median(of: samples),
            saturatedFraction: Double(saturatedCount) / Double(pixelCount),
            backgroundMedian00: medianOrNil(of: buckets.b00),
            backgroundMedian01: medianOrNil(of: buckets.b01),
            backgroundMedian10: medianOrNil(of: buckets.b10),
            backgroundMedian11: medianOrNil(of: buckets.b11)
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

    private static func medianOrNil(of samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        return median(of: samples)
    }

    // MARK: - Central-crop pixel reading (SensorProfiler's data-reading path)

    /// Reads every pixel (no subsampling) inside the CENTRAL `fraction` (by
    /// width AND height) crop of `url`'s primary HDU pixel grid, in
    /// row-major (`row * naxis1 + col`, then flattened crop-row-major) order
    /// -- used by `SensorProfiler`'s bias-level/read-noise/dark-rate
    /// measurements, which need exact per-pixel values from a STABLE region
    /// two different frames can be compared pixel-for-pixel against (a
    /// bias-pair difference), rather than `compute`'s stride-sampled summary
    /// statistic. Shares the same raw-primary-header scan
    /// (`primaryHeaderInfo`) and compressed-(.fz)-layout guard as
    /// `compute(data:)`, deliberately kept as its own read pass rather than
    /// routed through `compute` (which reduces straight to a median/
    /// saturated-fraction summary and throws the individual pixel values
    /// away).
    static func centralCropPixels(url: URL, fraction: Double = 0.5) throws -> [Double] {
        let data = try Data(contentsOf: url)
        return try centralCropPixels(data: data, fraction: fraction)
    }

    static func centralCropPixels(data: Data, fraction: Double = 0.5) throws -> [Double] {
        let header = try FITSReader.parse(data: data)
        let (dataOffset, rawPrimaryNAXIS) = try primaryHeaderInfo(data: data)

        // Same compressed-(.fz)-layout guard as `compute(data:)` -- see its
        // doc comment for why both signals (merged-header tile-compression
        // keywords, and the raw primary's own NAXIS==0) are checked.
        let hasCompressionKeywords = header.allCards["ZIMAGE"] != nil
            || header.allCards["ZCMPTYPE"] != nil
            || header.allCards["ZBITPIX"] != nil
        guard !hasCompressionKeywords, rawPrimaryNAXIS != 0 else {
            throw AstroError.corruptFITS(path: "", reason: "compressed FITS (.fz) pixel data unsupported")
        }

        guard let bitpix = header.int("BITPIX") else {
            throw AstroError.corruptFITS(path: "<data>", reason: "missing BITPIX")
        }
        guard let naxis1 = header.int("NAXIS1"), naxis1 > 0,
              let naxis2 = header.int("NAXIS2"), naxis2 > 0
        else {
            throw AstroError.corruptFITS(path: "<data>", reason: "missing or invalid NAXIS1/NAXIS2")
        }

        let cropW = max(1, min(naxis1, Int((Double(naxis1) * fraction).rounded())))
        let cropH = max(1, min(naxis2, Int((Double(naxis2) * fraction).rounded())))
        let x0 = (naxis1 - cropW) / 2
        let y0 = (naxis2 - cropH) / 2

        switch bitpix {
        case 16:
            let bzero = header.double("BZERO") ?? 0
            let isUnsigned = bzero == 32768
            return try readCrop16Bit(
                data: data, dataOffset: dataOffset, naxis1: naxis1,
                x0: x0, y0: y0, cropW: cropW, cropH: cropH, isUnsigned: isUnsigned
            )
        case 8:
            return try readCrop8Bit(data: data, dataOffset: dataOffset, naxis1: naxis1, x0: x0, y0: y0, cropW: cropW, cropH: cropH)
        default:
            throw AstroError.corruptFITS(path: "<data>", reason: "unsupported BITPIX")
        }
    }

    private static func readCrop16Bit(
        data: Data, dataOffset: Int, naxis1: Int, x0: Int, y0: Int, cropW: Int, cropH: Int, isUnsigned: Bool
    ) throws -> [Double] {
        let lastByteOffset = dataOffset + ((y0 + cropH - 1) * naxis1 + (x0 + cropW - 1)) * 2 + 1
        guard lastByteOffset < data.count else {
            throw AstroError.corruptFITS(path: "<data>", reason: "truncated pixel data")
        }

        var values: [Double] = []
        values.reserveCapacity(cropW * cropH)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            for row in y0..<(y0 + cropH) {
                for col in x0..<(x0 + cropW) {
                    let byteOffset = (row * naxis1 + col) * 2
                    let hi = base.load(fromByteOffset: byteOffset, as: UInt8.self)
                    let lo = base.load(fromByteOffset: byteOffset + 1, as: UInt8.self)
                    let rawValue = Int16(bitPattern: (UInt16(hi) << 8) | UInt16(lo))
                    let value: Double = isUnsigned ? Double(Int32(rawValue) + 32768) : Double(rawValue)
                    values.append(value)
                }
            }
        }
        return values
    }

    private static func readCrop8Bit(
        data: Data, dataOffset: Int, naxis1: Int, x0: Int, y0: Int, cropW: Int, cropH: Int
    ) throws -> [Double] {
        let lastByteOffset = dataOffset + (y0 + cropH - 1) * naxis1 + (x0 + cropW - 1)
        guard lastByteOffset < data.count else {
            throw AstroError.corruptFITS(path: "<data>", reason: "truncated pixel data")
        }

        var values: [Double] = []
        values.reserveCapacity(cropW * cropH)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            for row in y0..<(y0 + cropH) {
                for col in x0..<(x0 + cropW) {
                    let byteOffset = row * naxis1 + col
                    values.append(Double(base.load(fromByteOffset: byteOffset, as: UInt8.self)))
                }
            }
        }
        return values
    }

    // MARK: - Header byte length + raw primary NAXIS

    /// Scans 2880-byte blocks from the start of `data` -- the *primary*
    /// header only, never merged with any extension -- looking for its
    /// `END` card. Returns the byte offset immediately following that `END`
    /// (i.e. where the primary data block would begin, for a plain
    /// non-compressed file) together with the primary header's own `NAXIS`
    /// value (`nil` if no `NAXIS` card was seen).
    ///
    /// This deliberately mirrors `FITSReader`'s own block scanning rather
    /// than reusing it, because `FITSReader.parse`'s returned `FITSHeader`
    /// is post-merge: for a `.fz` file, its `NAXIS`/`NAXIS1`/`NAXIS2` no
    /// longer reflect the *primary* HDU (they're overwritten by the
    /// BINTABLE extension's own `NAXIS` and by `ZNAXIS1`/`ZNAXIS2`). Reading
    /// the raw primary `NAXIS` here, independently, is exactly what lets
    /// `compute(data:)` detect a `.fz` primary (`NAXIS=0`) even after that
    /// merge has papered over it.
    private static func primaryHeaderInfo(data: Data) throws -> (dataOffset: Int, naxis: Int?) {
        var offset = 0
        var naxis: Int?

        while true {
            guard offset + blockSize <= data.count else {
                throw AstroError.corruptFITS(path: "<data>", reason: "truncated FITS header")
            }
            let block = data.subdata(in: offset..<(offset + blockSize))
            offset += blockSize

            // Decode byte-by-byte (`Unicode.Scalar` per byte) rather than
            // via `String(data:encoding:.ascii)` + `Array(_:)`: Swift's
            // `Character` grapheme-cluster rules merge some adjacent ASCII
            // byte pairs (notably CR+LF, `0x0D 0x0A`) into a SINGLE
            // `Character`, which would shrink the resulting array below
            // 2880 elements for a 2880-byte block and trap the fixed
            // `cardIndex * cardSize` slicing below once it reaches a card
            // whose range no longer fits. See `FITSReader.readOneHeader`
            // for the sibling fix / full rationale -- this scan
            // deliberately duplicates that logic (see doc comment above)
            // and so duplicates this fix too.
            guard block.allSatisfy({ $0 < 0x80 }) else {
                throw AstroError.corruptFITS(path: "<data>", reason: "header block contains non-ASCII bytes")
            }
            let chars = block.map { Character(Unicode.Scalar($0)) }

            for cardIndex in 0..<cardsPerBlock {
                let start = cardIndex * cardSize
                let cardChars = chars[start..<(start + cardSize)]
                let keyword = String(cardChars.prefix(8)).trimmingCharacters(in: .whitespaces)

                if keyword == "END" {
                    return (offset, naxis)
                }
                if keyword == "NAXIS" {
                    let indicator = String(cardChars.dropFirst(8).prefix(2))
                    if indicator == "= " {
                        let rest = String(cardChars.dropFirst(10))
                        let valueText = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? rest
                        naxis = Int(valueText.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
    }
}
