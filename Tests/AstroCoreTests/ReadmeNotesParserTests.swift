import Foundation
import Testing
@testable import AstroCore

private func makeTempRoot(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-readmenotes-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The exact `SessionCreator` template (ground-truthed the same way
/// `SessionCreatorTests` already verifies it) parsed straight through
/// `ReadmeNotesParser`: the header keys (`Target folder`, `Date`, ...) all
/// come through since they're harmless and useful, but every blank "Fill in
/// metadata" field (`Camera:`, `Sensor temp:`, ...) is skipped since it has
/// no value yet.
@Test func parserExtractsTemplateHeaderKeysAndSkipsBlankMetadataFields() throws {
    let root = try makeTempRoot("template")
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try SessionCreator.create(root: root, catalogRaw: "M1", nameRaw: "Crab Nebula", date: "2026-08-02")
    let readmeURL = root.appendingPathComponent("sessions/M1_Crab_Nebula/2026-08-02/README.txt")
    let contents = try String(contentsOf: readmeURL, encoding: .utf8)

    let notes = ReadmeNotesParser.parse(text: contents)

    #expect(notes["Target folder"] == "M1_Crab_Nebula")
    #expect(notes["Target (raw)"] == "Crab Nebula")
    #expect(notes["Catalog prefix"] == "M1")
    #expect(notes["Date"] == "2026-08-02")
    #expect(notes["Created at"] != nil)

    for blankField in [
        "Camera", "Sensor temp", "Gain/Offset", "Exposure (lights)", "Filter",
        "Optics", "Mount", "Guiding", "Total integration", "Location/Bortle", "Notes/issues",
    ] {
        #expect(notes[blankField] == nil, "blank field \(blankField) must be skipped, not stored empty")
    }
}

@Test func parserCapturesUserFilledMetadataFields() throws {
    let text = """
    Fill in metadata (recommended)
    ------------------------------
    Camera: ZWO ASI2600MC Pro
    Sensor temp: -10C
    Exposure (lights): 300s
    Location/Bortle: falu, 4
    Notes/issues: some dew on the corrector around 2am
    """

    let notes = ReadmeNotesParser.parse(text: text)
    #expect(notes["Camera"] == "ZWO ASI2600MC Pro")
    #expect(notes["Sensor temp"] == "-10C")
    #expect(notes["Exposure (lights)"] == "300s")
    #expect(notes["Location/Bortle"] == "falu, 4")
    #expect(notes["Notes/issues"] == "some dew on the corrector around 2am")
}

/// A key the template doesn't even ship (the user just typed a new line) is
/// captured exactly the same way as any of the template's own fields --
/// this is what makes ad-hoc "SQM: 20.8" notes searchable.
@Test func parserCapturesArbitraryCustomKeyNotInTemplate() throws {
    let notes = ReadmeNotesParser.parse(text: "SQM: 20.8\nSeeing: 2.5 arcsec\n")
    #expect(notes["SQM"] == "20.8")
    #expect(notes["Seeing"] == "2.5 arcsec")
}

@Test func parserSkipsLinesWithNoColonOrLeadingNonLetterCharacter() throws {
    let text = """
    Astro Session Notes
    ===================
    - sessions/M1/2026-08-02/lights : RAW light frames
    Camera: ASI2600MC
    """
    let notes = ReadmeNotesParser.parse(text: text)
    #expect(notes.count == 1)
    #expect(notes["Camera"] == "ASI2600MC")
}

@Test func parseFromDataReturnsNilForOversizedFile() throws {
    let oversized = Data(repeating: UInt8(ascii: "a"), count: ReadmeNotesParser.maxBytes + 1)
    #expect(ReadmeNotesParser.parse(data: oversized) == nil)

    // At-or-under the cap must still parse normally.
    let atCap = Data("Camera: ASI2600MC\n".utf8)
    #expect(ReadmeNotesParser.parse(data: atCap) != nil)
}

@Test func parseFromDataReturnsNilForNonUTF8Bytes() throws {
    // A lone continuation byte is never valid UTF-8 on its own.
    let invalidUTF8 = Data([0xFF, 0xFE, 0x00, 0x81])
    #expect(ReadmeNotesParser.parse(data: invalidUTF8) == nil)
}

@Test func parserReturnsEmptyDictionaryForBlankText() throws {
    #expect(ReadmeNotesParser.parse(text: "") == [:])
    #expect(ReadmeNotesParser.parse(text: "\n\n   \n") == [:])
}
