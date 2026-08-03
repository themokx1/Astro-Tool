import Foundation

/// A parsed FITS header: keyword → raw value text (the card's value field,
/// comment stripped, quotes kept on string values so the typed accessors
/// below can re-derive int/double/bool/string from the same source of
/// truth). Keywords are stored upper-cased since FITS keywords are
/// case-insensitive by convention.
public struct FITSHeader: Sendable {
    /// Raw value texts by upper-cased keyword, exactly as read from the
    /// header cards (comment stripped, quotes retained for string values).
    public let allCards: [String: String]

    init(rawValues: [String: String]) {
        self.allCards = rawValues
    }

    /// A FITS string value with the surrounding quotes stripped, `''`
    /// unescaped to `'`, and insignificant trailing spaces (inside the
    /// quotes) trimmed. `nil` if the key is absent or its raw value isn't a
    /// quoted string.
    public func string(_ key: String) -> String? {
        guard let raw = allCards[key.uppercased()] else { return nil }
        return FITSHeader.parseQuotedString(raw)
    }

    /// A numeric value, parsed as `Double`. Accepts both float forms
    /// (`300.0`, `100.`, `-10.0`) and plain integer forms (`6248`).
    public func double(_ key: String) -> Double? {
        guard let raw = allCards[key.uppercased()] else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespaces))
    }

    /// An integer value. Only accepts a plain integer literal — a float
    /// form (even an integer-valued one like `100.`) returns `nil` rather
    /// than silently truncating.
    public func int(_ key: String) -> Int? {
        guard let raw = allCards[key.uppercased()] else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    /// A FITS logical value: `T` → `true`, `F` → `false`, anything else
    /// (including absent) → `nil`.
    public func bool(_ key: String) -> Bool? {
        guard let raw = allCards[key.uppercased()] else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "T": return true
        case "F": return false
        default: return nil
        }
    }

    /// Un-escapes a FITS quoted string value (`raw` includes the leading
    /// and trailing `'`). `''` inside the quotes is a literal apostrophe;
    /// the first unescaped `'` ends the string. Trailing spaces inside the
    /// quotes are insignificant per the FITS standard and are trimmed.
    private static func parseQuotedString(_ raw: String) -> String? {
        guard raw.hasPrefix("'") else { return nil }
        let chars = Array(raw)
        var i = 1
        var result = ""
        while i < chars.count {
            if chars[i] == "'" {
                if i + 1 < chars.count, chars[i + 1] == "'" {
                    result.append("'")
                    i += 2
                } else {
                    break
                }
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        while result.hasSuffix(" ") {
            result.removeLast()
        }
        return result
    }
}

/// Native, dependency-free FITS header reader. Understands plain FITS
/// (primary HDU only) as well as Rice-compressed `.fz` layouts (fpack /
/// ASIAIR): a primary HDU with `NAXIS=0` immediately followed by a
/// `BINTABLE` extension whose `ZNAXIS1`/`ZNAXIS2` carry the real image
/// dimensions. `readHeader` never loads a whole file into memory — it reads
/// 2880-byte header blocks incrementally and stops as soon as it has what
/// it needs.
public enum FITSReader {
    private static let blockSize = 2880
    private static let cardSize = 80
    private static let cardsPerBlock = blockSize / cardSize

    /// Safety valve: if `END` hasn't shown up within this many header bytes
    /// for a single HDU, treat the file as corrupt rather than reading
    /// forever.
    private static let maxHeaderBytesPerHDU = 65536

    /// One HDU's header, freshly parsed: the raw keyword → value-text
    /// dictionary plus the very first card's keyword (used to validate that
    /// an HDU actually starts with `SIMPLE`/`XTENSION`, independent of
    /// whether that first card happens to carry a value).
    private struct RawHeader {
        let firstCardKeyword: String?
        let values: [String: String]
    }

    /// Reads just the header of the primary HDU (and, for `.fz`-style files
    /// where the primary has `NAXIS=0`, merges in the first extension's
    /// header too) from the file at `url`, reading 2880-byte blocks
    /// incrementally rather than loading the whole file.
    public static func readHeader(url: URL) throws -> FITSHeader {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw AstroError.corruptFITS(path: url.path, reason: "cannot open file for reading")
        }
        defer { try? handle.close() }

        func nextBlock() -> Data? {
            let block = handle.readData(ofLength: blockSize)
            return block.isEmpty ? nil : block
        }

        return try readAndMerge(path: url.path, nextBlock: nextBlock)
    }

    /// Parses a complete FITS header (primary, plus first-extension merge
    /// for `.fz`-style layouts) from an in-memory buffer. This is the
    /// testable entry point — production code should prefer `readHeader`.
    public static func parse(data: Data) throws -> FITSHeader {
        var offset = 0
        func nextBlock() -> Data? {
            guard offset < data.count else { return nil }
            let end = min(offset + blockSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            offset = end
            return chunk
        }

        return try readAndMerge(path: "<data>", nextBlock: nextBlock)
    }

    /// Reads the primary HDU's header, validates it starts with `SIMPLE` or
    /// `XTENSION`, and — if `NAXIS=0` (the `.fz` primary-is-empty pattern) —
    /// attempts to read one more header (the first extension) and merge it
    /// in, extension keys winning on conflict, with `ZNAXIS1`/`ZNAXIS2`
    /// additionally copied onto `NAXIS1`/`NAXIS2`. If there's no further
    /// header to read (plain small FITS file, primary is everything), the
    /// primary header is returned as-is.
    private static func readAndMerge(path: String, nextBlock: () throws -> Data?) throws -> FITSHeader {
        let primary = try readOneHeader(path: path, nextBlock: nextBlock)
        guard let firstKeyword = primary.firstCardKeyword,
              firstKeyword == "SIMPLE" || firstKeyword == "XTENSION"
        else {
            throw AstroError.corruptFITS(path: path, reason: "FITS data does not start with SIMPLE or XTENSION")
        }

        var merged = primary.values
        let naxis = Int(primary.values["NAXIS"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        if naxis == 0, let extension_ = try? readOneHeader(path: path, nextBlock: nextBlock),
           extension_.firstCardKeyword == "XTENSION"
        {
            for (key, value) in extension_.values {
                merged[key] = value
            }
            if let znaxis1 = extension_.values["ZNAXIS1"] {
                merged["NAXIS1"] = znaxis1
            }
            if let znaxis2 = extension_.values["ZNAXIS2"] {
                merged["NAXIS2"] = znaxis2
            }
        }

        return FITSHeader(rawValues: merged)
    }

    /// Reads consecutive 2880-byte blocks from `nextBlock` until an `END`
    /// card is seen, parsing each 80-char card into (keyword, value text)
    /// pairs. Throws `AstroError.corruptFITS` if a block comes back short
    /// (truncated file / EOF before `END`) or if `END` isn't found within
    /// `maxHeaderBytesPerHDU` bytes.
    private static func readOneHeader(path: String, nextBlock: () throws -> Data?) throws -> RawHeader {
        var values: [String: String] = [:]
        var firstCardKeyword: String?
        var isFirstCardOverall = true
        var bytesRead = 0

        while true {
            // Each block's read + ASCII decode + card parsing happens
            // inside its own `autoreleasepool`: on Darwin, the Data/NSData
            // bridging behind `FileHandle` reads and `String(data:...)`
            // decoding can leave autoreleased buffers alive until the pool
            // drains, which for a long-running CLI with no run loop means
            // "until the process exits" rather than "after this block".
            // `maxHeaderBytesPerHDU` already caps this per file, but this
            // still runs once per scanned file, so bounding it per block
            // keeps memory flat regardless of file count.
            let reachedEnd = try autoreleasepool { () -> Bool in
                guard let blockData = try nextBlock(), blockData.count == blockSize else {
                    throw AstroError.corruptFITS(
                        path: path,
                        reason: "truncated FITS header: incomplete 2880-byte block"
                    )
                }
                bytesRead += blockSize

                // Decode byte-by-byte (`Unicode.Scalar` per byte) rather
                // than via `String(data:encoding:.ascii)` + `Array(_:)`:
                // ASCII bytes are all valid Unicode scalars, but Swift's
                // `Character` grapheme-cluster rules merge some adjacent
                // scalar pairs (notably CR+LF, `0x0D 0x0A`) into a SINGLE
                // `Character`. A block containing such a pair anywhere would
                // then produce a 2879-element (or shorter) array for a
                // 2880-byte block, and the fixed `cardIndex * cardSize`
                // slicing below -- which assumes exactly one array element
                // per input byte -- traps with "Array index is out of
                // range" once it reaches a card whose range no longer fits.
                // Scalar-per-byte decoding keeps a strict 1:1 byte↔element
                // correspondence regardless of byte content.
                guard blockData.allSatisfy({ $0 < 0x80 }) else {
                    throw AstroError.corruptFITS(path: path, reason: "header block contains non-ASCII bytes")
                }
                let blockChars = blockData.map { Character(Unicode.Scalar($0)) }
                for cardIndex in 0..<cardsPerBlock {
                    let start = cardIndex * cardSize
                    let cardChars = Array(blockChars[start..<(start + cardSize)])
                    let keyword = String(cardChars[0..<8]).trimmingCharacters(in: .whitespaces)

                    if isFirstCardOverall {
                        firstCardKeyword = keyword
                        isFirstCardOverall = false
                    }

                    if keyword == "END" {
                        return true
                    }

                    let indicator = String(cardChars[8..<10])
                    if indicator == "= " {
                        let rest = String(cardChars[10..<80])
                        values[keyword.uppercased()] = extractValueText(rest)
                    }
                }
                return false
            }

            if reachedEnd {
                return RawHeader(firstCardKeyword: firstCardKeyword, values: values)
            }
            if bytesRead >= maxHeaderBytesPerHDU {
                throw AstroError.corruptFITS(
                    path: path,
                    reason: "END card not found within \(maxHeaderBytesPerHDU) header bytes"
                )
            }
        }
    }

    /// Extracts the value-field text from a card's columns 11-80 (`rest`),
    /// stopping at an unquoted `/` (the comment delimiter) and trimming
    /// insignificant surrounding whitespace. A leading quote is treated
    /// specially: everything up to the matching (non-escaped) closing quote
    /// is part of the value, `/` included — only text after that closing
    /// quote can start a comment.
    private static func extractValueText(_ rest: String) -> String {
        let chars = Array(rest)
        var i = 0
        while i < chars.count, chars[i] == " " {
            i += 1
        }
        guard i < chars.count else { return "" }

        if chars[i] == "'" {
            var j = i + 1
            while j < chars.count {
                if chars[j] == "'" {
                    if j + 1 < chars.count, chars[j + 1] == "'" {
                        j += 2
                        continue
                    } else {
                        j += 1
                        break
                    }
                }
                j += 1
            }
            return String(chars[i..<min(j, chars.count)])
        }

        var j = i
        while j < chars.count, chars[j] != "/" {
            j += 1
        }
        var value = String(chars[i..<j])
        while value.hasSuffix(" ") {
            value.removeLast()
        }
        return value
    }
}
