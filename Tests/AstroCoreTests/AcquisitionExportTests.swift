import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-acquisition-export-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fresh fixture library + fresh sqlite-backed `Database` for
/// `AcquisitionExport` tests -- same spirit as `SessionStatsFixture` in
/// `SessionStatsTests.swift`.
private struct AcquisitionExportFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> AcquisitionExportFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return AcquisitionExportFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func writeFITS(
        _ relativePath: String,
        exptime: Double? = nil,
        instrume: String? = nil,
        focallen: Double? = nil,
        gain: Double? = nil,
        setTemp: Double? = nil,
        filter: String? = nil
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let instrume { cards.append("INSTRUME= '\(instrume)'") }
        if let focallen { cards.append("FOCALLEN=                \(focallen)") }
        if let gain { cards.append("GAIN    =                \(gain)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        if let filter { cards.append("FILTER  = '\(filter)'") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
    }

    func writeTIFFLight(
        _ relativePath: String,
        cameraModel: String,
        exposureSeconds: Double,
        iso: Int,
        focalLengthMM: Double
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeTestTIFF(
            to: url,
            focalLengthMM: focalLengthMM,
            cameraModel: cameraModel,
            exposureSeconds: exposureSeconds,
            iso: iso
        )
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

// MARK: - astrobin

@Test func astrobinHeaderIsExact() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0)
    try fixture.scan()

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    let firstLine = output.components(separatedBy: "\n").first
    #expect(firstLine == "date,filter,number,duration,binning,gain,sensorCooling,darks,flats,flatDarks,bias,bortle,meanSqm")
}

@Test func astrobinOneRowPerNominalExposureGroupWithCorrectNumberAndDuration() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITS(
            "sessions/T1/2026-01-10/lights/a\(i).fit",
            exptime: 300.0, instrume: "ZWO ASI2600MC Pro", gain: 100.0, setTemp: -10.0, filter: "L-eXtreme"
        )
    }
    for i in 1...2 {
        try fixture.writeFITS(
            "sessions/T1/2026-01-10/lights/b\(i).fit",
            exptime: 60.0, instrume: "ZWO ASI2600MC Pro", gain: 100.0, setTemp: -10.0, filter: "L-eXtreme"
        )
    }
    try fixture.scan()

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    let dataLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst()
    #expect(dataLines.count == 2)

    let byDuration = Dictionary(uniqueKeysWithValues: dataLines.map { line -> (String, [String]) in
        let fields = line.components(separatedBy: ",")
        return (fields[3], fields)
    })

    let row300 = try #require(byDuration["300"])
    #expect(row300[0] == "2026-01-10")
    #expect(row300[2] == "3")
    #expect(row300[5] == "100")
    #expect(row300[6] == "-10")

    let row60 = try #require(byDuration["60"])
    #expect(row60[2] == "2")
}

@Test func astrobinLeavesFilterBlankForOSCFrames() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 120.0, instrume: "ZWO ASI2600MC Pro")
    try fixture.scan()

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    let dataLine = try #require(output.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst().first)
    let fields = dataLine.components(separatedBy: ",")
    #expect(fields[1] == "")
}

@Test func astrobinLeavesSensorCoolingBlankForDSLRFrames() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeTIFFLight(
        "sessions/T1/2026-02-05/lights/dslr1.tif",
        cameraModel: "Canon EOS R8", exposureSeconds: 30.0, iso: 800, focalLengthMM: 50.0
    )
    try fixture.scan()

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    let dataLine = try #require(output.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst().first)
    let fields = dataLine.components(separatedBy: ",")
    #expect(fields[6] == "") // sensorCooling
    #expect(fields[5] == "800") // gain carries ISO
    #expect(fields[4] == "") // binning always blank
}

@Test func astrobinIncludesCalibFrameCountsAndComputesFlatDarks() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0)
    for i in 1...2 {
        try fixture.writeFITS("sessions/T1/2026-01-10/flats/f\(i).fit", exptime: 5.0)
    }
    try fixture.writeFITS("sessions/T1/2026-01-10/biases/b1.fit")
    // One dark matches the flats' dominant exptime (5.0) -- a flat-dark.
    try fixture.writeFITS("sessions/T1/2026-01-10/darks/fd1.fit", exptime: 5.0)
    // One dark matches the light's own exptime (300.0) -- a light-dark.
    try fixture.writeFITS("sessions/T1/2026-01-10/darks/ld1.fit", exptime: 300.0)

    try fixture.scan()

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    let dataLine = try #require(output.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst().first)
    let fields = dataLine.components(separatedBy: ",")
    // darks, flats, flatDarks, bias
    #expect(fields[7] == "2") // total darks on record for the session
    #expect(fields[8] == "2") // flats
    #expect(fields[9] == "1") // flatDarks -- only the 5.0s dark matches flats
    #expect(fields[10] == "1") // bias
}

/// R6-4: `bortle`/`meanSqm` come from `SessionDetail.notes` (README.txt
/// indexing) -- a plain digit value, a digit embedded in a longer sentence,
/// and a session with no matching note at all (blank, not a guess).
@Test func astrobinExtractsBortleFromNotesPlainAndEmbeddedDigitElseBlank() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-11/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-12/lights/l1.fit", exptime: 300.0)
    try fixture.scan()

    try fixture.db.upsertSessionNotes(target: "T1", date: "2026-01-10", notes: ["Bortle": "4"])
    try fixture.db.upsertSessionNotes(target: "T1", date: "2026-01-11", notes: ["Location/Bortle": "falu, 4"])
    // 2026-01-12 has no Bortle-ish key at all.

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    let rowsByDate = Dictionary(uniqueKeysWithValues: output.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst().map {
        line -> (String, [String]) in
        let fields = line.components(separatedBy: ",")
        return (fields[0], fields)
    })

    #expect(rowsByDate["2026-01-10"]?[11] == "4")
    #expect(rowsByDate["2026-01-11"]?[11] == "4")
    #expect(rowsByDate["2026-01-12"]?[11] == "")
}

/// Same three shapes for `meanSqm`: a plain reading, a reading embedded
/// alongside an unrelated (out-of-range) number that must be skipped rather
/// than picked up first, and a session whose only number is out of the
/// plausible 16-22 range at all (blank).
@Test func astrobinExtractsMeanSqmFromNotesPlainAndEmbeddedNumberElseBlank() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-11/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-12/lights/l1.fit", exptime: 300.0)
    try fixture.scan()

    try fixture.db.upsertSessionNotes(target: "T1", date: "2026-01-10", notes: ["SQM": "20.8"])
    try fixture.db.upsertSessionNotes(
        target: "T1", date: "2026-01-11",
        notes: ["SQM": "device serial 12345, reading 21.2 mag/arcsec2"]
    )
    try fixture.db.upsertSessionNotes(target: "T1", date: "2026-01-12", notes: ["SQM": "device serial 12345"])

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    let rowsByDate = Dictionary(uniqueKeysWithValues: output.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst().map {
        line -> (String, [String]) in
        let fields = line.components(separatedBy: ",")
        return (fields[0], fields)
    })

    #expect(rowsByDate["2026-01-10"]?[12] == "20.8")
    #expect(rowsByDate["2026-01-11"]?[12] == "21.2")
    #expect(rowsByDate["2026-01-12"]?[12] == "")
}

// MARK: - R11-T16/F20: AstroBin filter-ID mapping

@Test func astrobinWritesTheMappedFilterIDInsteadOfTheName() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, filter: "Ha")
    try fixture.scan()

    var config = fixture.config
    config.astrobin.filterIds = ["Ha": 4663]

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: config)
    let dataLine = try #require(output.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst().first)
    let fields = dataLine.components(separatedBy: ",")
    #expect(fields[1] == "4663")
}

@Test func astrobinLookupIsCaseInsensitiveAndTrimmed() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, filter: "Ha")
    try fixture.scan()

    var config = fixture.config
    // Mapping entered as "  HA  " in Settings -- must still match the
    // scanned "Ha" header value.
    config.astrobin.filterIds = ["  HA  ": 4663]

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: config)
    let dataLine = try #require(output.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst().first)
    let fields = dataLine.components(separatedBy: ",")
    #expect(fields[1] == "4663")
}

@Test func astrobinKeepsTheRawNameWhenUnmapped() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, filter: "OIII")
    try fixture.scan()

    // No mapping at all -- the raw name must still export, unchanged.
    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    let dataLine = try #require(output.components(separatedBy: "\n").filter { !$0.isEmpty }.dropFirst().first)
    let fields = dataLine.components(separatedBy: ",")
    #expect(fields[1] == "OIII")
}

@Test func unmappedAstrobinFiltersReturnsOnlyTheFiltersWithNoMappingEntry() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, filter: "Ha")
    try fixture.writeFITS("sessions/T1/2026-01-11/lights/l1.fit", exptime: 300.0, filter: "OIII")
    try fixture.scan()

    var config = fixture.config
    config.astrobin.filterIds = ["Ha": 4663]

    let unmapped = try AcquisitionExport.unmappedAstrobinFilters(target: "T1", db: fixture.db, config: config)
    #expect(unmapped == ["OIII"])
}

@Test func unmappedAstrobinFiltersIsEmptyWhenEveryUsedFilterIsMapped() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, filter: "Ha")
    try fixture.scan()

    var config = fixture.config
    config.astrobin.filterIds = ["Ha": 4663]

    let unmapped = try AcquisitionExport.unmappedAstrobinFilters(target: "T1", db: fixture.db, config: config)
    #expect(unmapped.isEmpty)
}

@Test func unmappedAstrobinFiltersIsEmptyForFilterlessOSCFrames() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, instrume: "ZWO ASI2600MC Pro")
    try fixture.scan()

    let unmapped = try AcquisitionExport.unmappedAstrobinFilters(target: "T1", db: fixture.db, config: fixture.config)
    #expect(unmapped.isEmpty)
}

@Test func astrobinSkipsHibasExcludedSessions() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10_hibas/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-11/lights/l2.fit", exptime: 300.0)
    try fixture.scan()

    let output = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    #expect(!output.contains("2026-01-10"))
    #expect(output.contains("2026-01-11"))
}

// MARK: - csv (generic)

@Test func csvEscapesFieldsContainingCommas() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0)
    try fixture.scan()
    try fixture.db.addTag(TagRecord(kind: "session", target: "T1", sessionDate: "2026-01-10", tag: "clouds, partial"))

    let output = try AcquisitionExport.render(target: "T1", format: .csv, db: fixture.db, config: fixture.config)
    #expect(output.contains("\"clouds, partial\""))
}

@Test func csvContainsOneRowPerSessionWithUsableAndRejectedCounts() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-10/lights/Reject/blurry/l2.fit", exptime: 300.0)
    try fixture.scan()

    let output = try AcquisitionExport.render(target: "T1", format: .csv, db: fixture.db, config: fixture.config)
    let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
    #expect(lines.count == 2) // header + 1 session
    let fields = lines[1].components(separatedBy: ",")
    #expect(fields[0] == "T1")
    #expect(fields[2] == "1") // frames_usable
    #expect(fields[3] == "1") // frames_rejected
}

// MARK: - md

@Test func markdownContainsTargetHeadingAndIntegration() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l2.fit", exptime: 300.0)
    try fixture.scan()

    let output = try AcquisitionExport.render(target: "T1", format: .md, db: fixture.db, config: fixture.config)
    #expect(output.contains("# T1"))
    #expect(output.contains("## 2026-01-10"))
    #expect(output.contains("Összes usable integráció: 0:10"))
}

@Test func markdownMarksHibasExcludedSessionsButStillIncludesThem() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10_hibas/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-11/lights/l2.fit", exptime: 300.0)
    try fixture.scan()

    let output = try AcquisitionExport.render(target: "T1", format: .md, db: fixture.db, config: fixture.config)
    #expect(output.contains("## 2026-01-10_hibas (kizárva)"))
    #expect(output.contains("## 2026-01-11"))
    // Excluded session's own frames still count in ITS OWN section, but not
    // the target summary footer.
    #expect(output.contains("Session-ök száma: 1"))
}

// MARK: - write()

@Test func writeLandsUnderExportsWithExpectedExtensionAndMatchesRender() throws {
    let fixture = try AcquisitionExportFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0)
    try fixture.scan()

    let writeGuard = WriteGuard(root: fixture.libraryDir)
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    let csvURL = try AcquisitionExport.write(
        target: "T1", format: .astrobin, timestamp: timestamp, db: fixture.db, config: fixture.config, using: writeGuard
    )
    #expect(csvURL.path.contains(".astro_tool/exports/"))
    #expect(csvURL.pathExtension == "csv")
    let csvContent = try String(contentsOf: csvURL, encoding: .utf8)
    let expectedCSV = try AcquisitionExport.render(target: "T1", format: .astrobin, db: fixture.db, config: fixture.config)
    #expect(csvContent == expectedCSV)

    let mdURL = try AcquisitionExport.write(
        target: "T1", format: .md, timestamp: timestamp, db: fixture.db, config: fixture.config, using: writeGuard
    )
    #expect(mdURL.pathExtension == "md")
    let mdContent = try String(contentsOf: mdURL, encoding: .utf8)
    let expectedMD = try AcquisitionExport.render(target: "T1", format: .md, db: fixture.db, config: fixture.config)
    #expect(mdContent == expectedMD)
}
