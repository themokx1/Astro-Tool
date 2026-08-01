import Foundation
import Testing
@testable import AstroCore

// `card` / `buildHeaderData` now live in FITSTestBuilder.swift, shared with
// ScannerTests.

@Test func stringValueQuotesStrippedTrailingSpacesTrimmedAndApostropheEscaped() throws {
    let data = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "OBJECT  = 'O''Neill Cluster   '",
        "END",
    ])
    let header = try FITSReader.parse(data: data)
    #expect(header.string("OBJECT") == "O'Neill Cluster")
}

@Test func parsesBoolIntAndFloatValuesIncludingTrailingDotForm() throws {
    let data = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 6248",
        "NAXIS2  =                 4176",
        "EXPTIME =                300.0",
        "GAIN    =                 100.",
        "END",
    ])
    let header = try FITSReader.parse(data: data)
    #expect(header.bool("SIMPLE") == true)
    #expect(header.int("BITPIX") == 16)
    #expect(header.int("NAXIS1") == 6248)
    #expect(header.double("EXPTIME") == 300.0)
    #expect(header.double("GAIN") == 100.0)
    #expect(header.int("GAIN") == nil, "float form (\"100.\") is not a plain int literal")
}

@Test func commentAfterSlashIsStrippedButSlashInsideQuotedStringIsNotCommentStart() throws {
    let data = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "EXPTIME =                300.0 / exposure time in seconds",
        "FILTER  = 'H/A     '           / narrowband filter",
        "END",
    ])
    let header = try FITSReader.parse(data: data)
    #expect(header.double("EXPTIME") == 300.0)
    #expect(header.string("FILTER") == "H/A")
}

@Test func keywordWithHyphenParsesCorrectly() throws {
    let data = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "SET-TEMP=                -10.0",
        "END",
    ])
    let header = try FITSReader.parse(data: data)
    #expect(header.double("SET-TEMP") == -10.0)
}

@Test func cardsAfterEndAreIgnoredAndCommentHistoryBlankCardsAreSkipped() throws {
    let data = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "COMMENT this is a comment card, no value",
        "HISTORY processed by ASIAIR",
        "",
        "IMAGETYP= 'Light Frame'",
        "END",
        "GHOST   =                    1",
    ])
    let header = try FITSReader.parse(data: data)
    #expect(header.string("IMAGETYP") == "Light Frame")
    #expect(header.allCards["COMMENT"] == nil)
    #expect(header.allCards["HISTORY"] == nil)
    #expect(header.int("GHOST") == nil, "cards after END must be ignored")
}

@Test func truncatedFileNotMultipleOf2880AndNoEndThrowsCorruptFITS() throws {
    let full = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
    ])
    // No END card was included above, so `full` is one padded-with-spaces
    // 2880 block with no END anywhere. Chop it to simulate a file that was
    // cut off mid-header (not a multiple of 2880 and END never found).
    let data = full.prefix(2000)
    do {
        _ = try FITSReader.parse(data: data)
        Issue.record("expected AstroError.corruptFITS to be thrown")
    } catch AstroError.corruptFITS {
        // expected
    } catch {
        Issue.record("expected AstroError.corruptFITS, got \(error)")
    }
}

@Test func dataNotStartingWithSimpleOrXtensionThrowsCorruptFITS() throws {
    let data = buildHeaderData([
        "NOTFITS =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "END",
    ])
    do {
        _ = try FITSReader.parse(data: data)
        Issue.record("expected AstroError.corruptFITS to be thrown")
    } catch AstroError.corruptFITS {
        // expected
    } catch {
        Issue.record("expected AstroError.corruptFITS, got \(error)")
    }
}

@Test func fzStyleCompressedFITSMergesPrimaryAndExtensionWithZNAXISCopiedToNAXIS() throws {
    let primary = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "END",
    ])
    let extensionHeader = buildHeaderData([
        "XTENSION= 'BINTABLE'",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "NAXIS1  =                    8",
        "NAXIS2  =                    1",
        "PCOUNT  =                    0",
        "GCOUNT  =                    1",
        "ZIMAGE  =                    T",
        "ZNAXIS1 =                 6248",
        "ZNAXIS2 =                 4176",
        "EXPTIME =                300.0",
        "IMAGETYP= 'Light Frame'",
        "END",
    ])
    // Extension's own (fake, tiny) data block — never actually read by the
    // parser, just present so the byte layout matches a real .fz file.
    let fakeDataBlock = Data(repeating: 0, count: 2880)
    let data = primary + extensionHeader + fakeDataBlock

    let header = try FITSReader.parse(data: data)
    #expect(header.string("XTENSION") == "BINTABLE")
    #expect(header.bool("ZIMAGE") == true)
    #expect(header.int("NAXIS1") == 6248, "ZNAXIS1 must be copied into NAXIS1")
    #expect(header.int("NAXIS2") == 4176, "ZNAXIS2 must be copied into NAXIS2")
    #expect(header.double("EXPTIME") == 300.0)
    #expect(header.string("IMAGETYP") == "Light Frame")
    #expect(header.int("NAXIS") == 2, "extension NAXIS must win over primary's NAXIS=0")
}

@Test func multiBlockHeaderWithMoreThan36CardsParsesAcrossBlocks() throws {
    var cards = [
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
    ]
    for i in 0..<40 {
        let keyword = "TESTK\(i)".padding(toLength: 8, withPad: " ", startingAt: 0)
        cards.append("\(keyword)=                    \(i)")
    }
    cards.append("END")
    let data = buildHeaderData(cards)
    #expect(data.count == 2 * 2880, "44 cards must overflow a single 36-card block")

    let header = try FITSReader.parse(data: data)
    #expect(header.int("TESTK0") == 0)
    #expect(header.int("TESTK39") == 39)
}

@Test func readHeaderFromURLReadsPrimaryHeaderIncrementally() throws {
    let data = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                   16",
        "NAXIS   =                    2",
        "NAXIS1  =                 6248",
        "NAXIS2  =                 4176",
        "INSTRUME= 'ZWO ASI2600MC Pro'",
        "END",
    ])
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fits-reader-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fileURL = dir.appendingPathComponent("test.fits")
    try data.write(to: fileURL)

    let header = try FITSReader.readHeader(url: fileURL)
    #expect(header.int("NAXIS1") == 6248)
    #expect(header.string("INSTRUME") == "ZWO ASI2600MC Pro")
}

@Test func readHeaderFromURLMergesFzStyleExtension() throws {
    let primary = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "END",
    ])
    let extensionHeader = buildHeaderData([
        "XTENSION= 'BINTABLE'",
        "BITPIX  =                    8",
        "NAXIS   =                    2",
        "ZNAXIS1 =                 6248",
        "ZNAXIS2 =                 4176",
        "END",
    ])
    let fakeDataBlock = Data(repeating: 0, count: 2880)
    let data = primary + extensionHeader + fakeDataBlock

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fits-reader-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fileURL = dir.appendingPathComponent("test.fits.fz")
    try data.write(to: fileURL)

    let header = try FITSReader.readHeader(url: fileURL)
    #expect(header.int("NAXIS1") == 6248)
    #expect(header.int("NAXIS2") == 4176)
}

@Test func readHeaderThrowsCorruptFITSWhenFileCannotBeOpened() throws {
    let missingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("does-not-exist-\(UUID().uuidString).fits")
    do {
        _ = try FITSReader.readHeader(url: missingURL)
        Issue.record("expected AstroError.corruptFITS to be thrown")
    } catch AstroError.corruptFITS {
        // expected
    } catch {
        Issue.record("expected AstroError.corruptFITS, got \(error)")
    }
}

@Test func headerExceedingSixtyFourKiBSafetyValveThrowsCorruptFITSForBothParseAndReadHeader() throws {
    // No END card anywhere, and comfortably more than the 64 KiB
    // per-HDU cap (>828 cards worth) — both entry points must give up
    // rather than read forever.
    var cards = ["SIMPLE  =                    T"]
    for i in 0..<900 {
        let keyword = "K\(i)".padding(toLength: 8, withPad: " ", startingAt: 0)
        cards.append("\(keyword)=                    \(i)")
    }
    let data = buildHeaderData(cards)
    #expect(data.count > 65536)

    do {
        _ = try FITSReader.parse(data: data)
        Issue.record("expected AstroError.corruptFITS to be thrown from parse(data:)")
    } catch AstroError.corruptFITS {
        // expected
    } catch {
        Issue.record("expected AstroError.corruptFITS from parse(data:), got \(error)")
    }

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fits-reader-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fileURL = dir.appendingPathComponent("huge_header.fits")
    try data.write(to: fileURL)

    do {
        _ = try FITSReader.readHeader(url: fileURL)
        Issue.record("expected AstroError.corruptFITS to be thrown from readHeader(url:)")
    } catch AstroError.corruptFITS {
        // expected
    } catch {
        Issue.record("expected AstroError.corruptFITS from readHeader(url:), got \(error)")
    }
}

@Test func allCardsExposesRawValueTexts() throws {
    let data = buildHeaderData([
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "INSTRUME= 'ZWO ASI2600MC Pro'",
        "END",
    ])
    let header = try FITSReader.parse(data: data)
    #expect(header.allCards["SIMPLE"] == "T")
    #expect(header.allCards["INSTRUME"] == "'ZWO ASI2600MC Pro'")
    #expect(header.allCards["NOPE"] == nil)
}
