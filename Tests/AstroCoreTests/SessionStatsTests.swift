import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-session-stats-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fresh fixture library + fresh sqlite-backed `Database` for
/// `SessionStatsQueries` tests -- deliberately minimal, same spirit as
/// `StatsFixture` in `StatsTests.swift`.
private struct SessionStatsFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> SessionStatsFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return SessionStatsFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Writes a minimal FITS file, with header cards only for the fields
    /// callers pass -- enough for `PathClassifier` (role comes from the
    /// directory name, not the header) plus whatever `fits_meta` columns
    /// the test cares about.
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

    func writeReadme(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "session readme\n".write(to: url, atomically: true, encoding: .utf8)
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

@Test func sessionDetailsSplitByDateWithCountsIntegrationAndEquipmentSignals() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    // Session A: 3 FITS lights (uniform equipment) + 2 flats + README.
    for i in 1...3 {
        try fixture.writeFITS(
            "sessions/T1/2026-01-10/lights/l\(i).fit",
            exptime: 300.0, instrume: "ZWO ASI2600MC Pro", focallen: 250.0,
            gain: 100.0, setTemp: -10.0, filter: "L-eXtreme"
        )
    }
    for i in 1...2 {
        try fixture.writeFITS("sessions/T1/2026-01-10/flats/f\(i).fit")
    }
    try fixture.writeReadme("sessions/T1/2026-01-10/README.txt")

    // Session B: 2 TIFF (DSLR) lights, no README.
    for i in 1...2 {
        try fixture.writeTIFFLight(
            "sessions/T1/2026-02-05/lights/dslr\(i).tif",
            cameraModel: "Canon EOS R8", exposureSeconds: 30.0, iso: 800, focalLengthMM: 50.0
        )
    }

    try fixture.scan()

    let sessions = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
    #expect(sessions.map(\.dateRaw) == ["2026-01-10", "2026-02-05"])

    let a = sessions[0]
    #expect(a.lightCount == 3)
    #expect(a.flatCount == 2)
    #expect(a.darkCount == 0)
    #expect(a.biasCount == 0)
    #expect(a.integrationSeconds == 900.0)
    #expect(a.exposureBreakdown == ["300.0": 3])
    #expect(a.cameras == ["ZWO ASI2600MC Pro"])
    #expect(a.focalLengthsMM == [250.0])
    #expect(a.gains == [100.0])
    #expect(a.sensorTempsC == [-10.0])
    #expect(a.filters == ["L-eXtreme"])
    #expect(a.hasReadme == true)

    let b = sessions[1]
    #expect(b.lightCount == 2)
    #expect(b.flatCount == 0)
    #expect(b.darkCount == 0)
    #expect(b.biasCount == 0)
    #expect(b.integrationSeconds == 60.0)
    #expect(b.exposureBreakdown == ["30.0": 2])
    #expect(b.cameras == ["Canon EOS R8"])
    #expect(b.focalLengthsMM == [50.0])
    #expect(b.gains == [800.0])
    #expect(b.hasReadme == false)
}

@Test func sessionDetailsCountsDarksAndBiasesSeparately() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T2/2026-03-01/lights/l1.fit", exptime: 60.0)
    try fixture.writeFITS("sessions/T2/2026-03-01/darks/d1.fit")
    try fixture.writeFITS("sessions/T2/2026-03-01/darks/d2.fit")
    try fixture.writeFITS("sessions/T2/2026-03-01/biases/b1.fit")

    try fixture.scan()

    let sessions = try SessionStatsQueries.sessions(target: "T2", db: fixture.db, config: fixture.config)
    let session = try #require(sessions.first)
    #expect(session.lightCount == 1)
    #expect(session.darkCount == 2)
    #expect(session.biasCount == 1)
}

@Test func sessionDetailsDistinctFocalLengthsRoundedAndSortedAcrossMultipleLights() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T3/2026-04-01/lights/l1.fit", exptime: 60.0, focallen: 250.4)
    try fixture.writeFITS("sessions/T3/2026-04-01/lights/l2.fit", exptime: 60.0, focallen: 250.6)
    try fixture.writeFITS("sessions/T3/2026-04-01/lights/l3.fit", exptime: 60.0, focallen: 50.0)

    try fixture.scan()

    let sessions = try SessionStatsQueries.sessions(target: "T3", db: fixture.db, config: fixture.config)
    let session = try #require(sessions.first)
    // 250.4 rounds to 250, 250.6 rounds to 251 -- both distinct from 50.
    #expect(session.focalLengthsMM == [50.0, 250.0, 251.0])
}

@Test func sessionDetailsUnknownTargetReturnsEmptyArray() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0)
    try fixture.scan()

    let sessions = try SessionStatsQueries.sessions(target: "DoesNotExist", db: fixture.db, config: fixture.config)
    #expect(sessions.isEmpty)
}

@Test func sessionDetailCarriesItsSessionLevelTags() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0)
    try fixture.scan()
    try fixture.db.addTag(TagRecord(kind: "session", target: "T1", sessionDate: "2026-01-10", tag: "clouds"))

    let sessions = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
    let session = try #require(sessions.first)
    #expect(session.tags == ["clouds"])
}

@Test func sessionDetailHasEmptyTagsWhenNoneAdded() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0)
    try fixture.scan()

    let sessions = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
    let session = try #require(sessions.first)
    #expect(session.tags == [])
}

// MARK: - R4-1: true per-session stats

@Test func sessionDetailFlagsHibasLabeledDateAsExcludedFromTotals() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10_hibas/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-11/lights/l2.fit", exptime: 60.0)
    try fixture.scan()

    let sessions = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
    #expect(sessions.map(\.dateRaw) == ["2026-01-10_hibas", "2026-01-11"])

    let bad = sessions[0]
    #expect(bad.isExcludedFromTotals == true)
    // The session's OWN numbers are still real -- only the target roll-up
    // excludes it.
    #expect(bad.integrationSeconds == 300.0)
    #expect(bad.usableLightCount == 1)

    let good = sessions[1]
    #expect(good.isExcludedFromTotals == false)
}

@Test func sessionDetailCountsRejectedAndDuplicateLinksSeparatelyFromUsable() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0)
    try fixture.writeFITS("sessions/T1/2026-01-10/lights/Reject/blurry/l2.fit", exptime: 120.0)
    try fixture.scan()

    let originalURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/l1.fit")
    let linkURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/Review/l1.fit")
    try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.linkItem(at: originalURL, to: linkURL)
    try fixture.scan()

    let sessions = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
    let session = try #require(sessions.first)

    #expect(session.usableLightCount == 1)
    #expect(session.rejectedCount == 1)
    #expect(session.duplicateLinkCount == 1)
    #expect(session.integrationSeconds == 300.0)
    // Raw (undeduped) count still reflects every role-.light row on disk.
    #expect(session.lightCount == 3)
}

/// R4-2 fix (a): same nominal-exposure merge as `StatsQueries`'s
/// `exposureBreakdown`, applied to `SessionDetail`'s per-session bucket.
@Test func sessionDetailExposureBreakdownMergesFloatNoisyExptimesIntoOneNominalKey() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/a1.fit", exptime: 120.0)
    try fixture.writeFITS("sessions/T1/2026-01-10/lights/a2.fit", exptime: 119.9)

    try fixture.scan()

    let sessions = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
    let session = try #require(sessions.first)
    #expect(session.exposureBreakdown == ["120.0": 2])
    #expect(session.integrationSeconds == 120.0 + 119.9)
}

@Test func sessionDetailsLightWithoutMetaLandsInUnknownExposureBucket() throws {
    let fixture = try SessionStatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0)
    // Plain-text ".fit" -- no parseable FITS header, so no fits_meta row.
    let corruptURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/corrupt.fit")
    try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "not a FITS file".write(to: corruptURL, atomically: true, encoding: .utf8)

    try fixture.scan()

    let sessions = try SessionStatsQueries.sessions(target: "T1", db: fixture.db, config: fixture.config)
    let session = try #require(sessions.first)
    #expect(session.lightCount == 2)
    #expect(session.integrationSeconds == 300.0)
    #expect(session.exposureBreakdown["unknown"] == 1)
    #expect(session.exposureBreakdown["300.0"] == 1)
}
