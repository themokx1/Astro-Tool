import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-stats-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fresh fixture library + fresh sqlite-backed `Database`, everything a
/// stats test needs. Deliberately minimal (unlike `Fixtures.makeMessyLibrary`)
/// -- these tests build only the small trees each scenario cares about.
private struct StatsFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> StatsFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return StatsFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    func writeFITSLight(_ relativePath: String, exptime: Double?, instrume: String?, filter: String?) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let instrume { cards.append("INSTRUME= '\(instrume)'") }
        if let filter { cards.append("FILTER  = '\(filter)'") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
    }

    func writePlainTextFile(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not a FITS file, just plain text\n".write(to: url, atomically: true, encoding: .utf8)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

// MARK: - StatsQueries

@Test func statsSumsIntegrationAndBreaksDownExposuresForSessionLightsOnly() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITSLight(
            "sessions/T1/2026-01-10/lights/l\(i).fit",
            exptime: 300.0, instrume: "ZWO ASI2600MC Pro", filter: "L-eXtreme"
        )
    }
    for i in 1...2 {
        try fixture.writeFITSLight(
            "sessions/T1/2026-01-10/lights/s\(i).fit",
            exptime: 60.0, instrume: "ZWO ASI2600MC Pro", filter: "L-eXtreme"
        )
    }
    // Must NOT count: a flat frame and a stack.
    try fixture.writeFITSLight("sessions/T1/2026-01-10/flats/f1.fit", exptime: 5.0, instrume: "ZWO ASI2600MC Pro", filter: nil)
    try fixture.writeFITSLight("stacks/T1/2026-01-10/stack.fit", exptime: 9999.0, instrume: nil, filter: nil)

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.totalIntegrationSeconds == 1020.0)
    #expect(stats.exposureBreakdown == ["300.0": 3, "60.0": 2])
    #expect(stats.cameras == ["ZWO ASI2600MC Pro"])
    #expect(stats.filters == ["L-eXtreme"])
}

/// R4-2 fix (a): float-noisy exptimes that mean the same nominal exposure
/// (30.0 vs. 29.899999618523, ground-truthed from a real library) must share
/// one `exposureBreakdown` key instead of splitting into two near-empty
/// buckets.
@Test func statsExposureBreakdownMergesFloatNoisyExptimesIntoOneNominalKey() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    for i in 1...2 {
        try fixture.writeFITSLight(
            "sessions/T1/2026-01-10/lights/a\(i).fit",
            exptime: 30.0, instrume: nil, filter: nil
        )
    }
    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/b1.fit",
        exptime: 29.899999618523, instrume: nil, filter: nil
    )

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.exposureBreakdown == ["30.0": 3])
    #expect(stats.totalIntegrationSeconds == 30.0 + 30.0 + 29.899999618523)
}

@Test func statsCountsDSLRLightExposureFromEXIFInIntegrationTotal() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    // No FITS EXPTIME here at all -- a CR3-style DSLR light (using a .tif
    // fixture, since ImageIO can't encode a CR3 in tests) whose exposure
    // only exists as Exif ExposureTime/ISOSpeedRatings. Without reading
    // those, this frame would land entirely in the "unknown" bucket and
    // contribute 0 seconds.
    let relativePath = "sessions/T4/2026-02-01/lights/dslr_frame.tif"
    let url = fixture.libraryDir.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeTestTIFF(to: url, cameraModel: "Canon EOS Ra", exposureSeconds: 30.0, iso: 800)

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T4", db: fixture.db, config: fixture.config))
    #expect(stats.totalIntegrationSeconds == 30.0)
    #expect(stats.exposureBreakdown == ["30.0": 1])
    #expect(stats.cameras == ["Canon EOS Ra"])
}

@Test func statsCountsLightWithoutMetaAsUnknownBucketWithoutChangingIntegration() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, instrume: "Cam", filter: "L")
    // Plain-text ".fit" -- no parseable FITS header, so no fits_meta row.
    try fixture.writePlainTextFile("sessions/T1/2026-01-10/lights/corrupt.fit")

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.totalIntegrationSeconds == 300.0)
    #expect(stats.exposureBreakdown["unknown"] == 1)
    #expect(stats.exposureBreakdown["300.0"] == 1)
}

@Test func statsCollectsSessionDatesAndPicksLastSessionDateByMaxStart() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T2/2026-01-10/lights/l1.fit", exptime: 60.0, instrume: nil, filter: nil)
    try fixture.writeFITSLight("sessions/T2/2026-04-06-2/lights/l1.fit", exptime: 60.0, instrume: nil, filter: nil)
    try fixture.writeFITSLight("sessions/T2/2026-02-25_2026-03-15/lights/l1.fit", exptime: 60.0, instrume: nil, filter: nil)

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T2", db: fixture.db, config: fixture.config))
    #expect(Set(stats.sessionDates) == Set(["2026-01-10", "2026-04-06-2", "2026-02-25_2026-03-15"]))
    #expect(stats.sessionDates == stats.sessionDates.sorted())
    #expect(stats.lastSessionDate == "2026-04-06")
}

@Test func statsIncludesStacksOnlyTargetWithZeroIntegrationAndEmptyDates() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("stacks/T3/2026-05-01/stack.fit", exptime: 12345.0, instrume: "Cam", filter: "L")

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T3", db: fixture.db, config: fixture.config))
    #expect(stats.totalIntegrationSeconds == 0)
    #expect(stats.exposureBreakdown.isEmpty)
    #expect(stats.sessionDates.isEmpty)
    #expect(stats.lastSessionDate == nil)
    #expect(stats.cameras.isEmpty)
    #expect(stats.filters.isEmpty)
}

@Test func perTargetReturnsAllDistinctTargetsSortedByName() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/Zed/2026-01-10/lights/l1.fit", exptime: 60.0, instrume: nil, filter: nil)
    try fixture.writeFITSLight("sessions/Alpha/2026-01-10/lights/l1.fit", exptime: 60.0, instrume: nil, filter: nil)
    try fixture.writeFITSLight("stacks/Mid/2026-01-10/stack.fit", exptime: 60.0, instrume: nil, filter: nil)

    try fixture.scan()

    let all = try StatsQueries.perTarget(db: fixture.db, config: fixture.config)
    #expect(all.map(\.target) == ["Alpha", "Mid", "Zed"])
}

@Test func fileDirectlyUnderSessionsNeverYieldsAStatsRow() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    // A real target with lights, plus Finder noise sitting directly under
    // sessions/ (no target dir of its own) -- the latter must never turn
    // into a bogus ".DS_Store" stats row.
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, instrume: nil, filter: nil)
    try fixture.writePlainTextFile("sessions/.DS_Store")

    try fixture.scan()

    let all = try StatsQueries.perTarget(db: fixture.db, config: fixture.config)
    #expect(all.map(\.target) == ["T1"])
    #expect(!all.contains { $0.target == ".DS_Store" })
}

@Test func targetLookupReturnsNilForUnknownName() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, instrume: nil, filter: nil)
    try fixture.scan()

    #expect(try StatsQueries.target("DoesNotExist", db: fixture.db, config: fixture.config) == nil)
}

@Test func targetStatsCarriesItsTargetLevelTags() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, instrume: nil, filter: nil)
    try fixture.scan()
    try fixture.db.addTag(TagRecord(kind: "target", target: "T1", sessionDate: nil, tag: "favorite"))

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.tags == ["favorite"])
}

@Test func targetStatsHasEmptyTagsWhenNoneAdded() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, instrume: nil, filter: nil)
    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.tags == [])
}

@Test func targetLookupMatchesEntryFromPerTarget() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, instrume: "Cam", filter: "L")
    try fixture.scan()

    let all = try StatsQueries.perTarget(db: fixture.db, config: fixture.config)
    let single = try StatsQueries.target("T1", db: fixture.db, config: fixture.config)
    #expect(all.first { $0.target == "T1" } == single)
}

// MARK: - R4-1: true integration (dedup, non-frame filtering, label exclusion)

@Test func statsDedupesHardlinkedTriageCopyCountingItOnceTowardIntegration() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, instrume: "Cam", filter: "L"
    )
    let originalURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/l1.fit")
    let linkURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/Review/l1.fit")
    try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.linkItem(at: originalURL, to: linkURL)

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.totalIntegrationSeconds == 300.0)
    #expect(stats.usableFrameCount == 1)
    #expect(stats.duplicateLinkCount == 1)
    #expect(stats.grossIntegrationSeconds == 600.0)
}

@Test func statsDedupesCR3AndTIFPairCountingItOnce() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    // A DSLR frame kept as both the original .cr3 and a converted .tif --
    // ImageIO can't decode either dummy file here, but the dedup only needs
    // the matching basename stem, not readable metadata.
    try fixture.writePlainTextFile("sessions/T1/2026-01-10/lights/IMG_0001.cr3")
    try fixture.writePlainTextFile("sessions/T1/2026-01-10/lights/IMG_0001.tif")

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.usableFrameCount == 1)
    #expect(stats.duplicateLinkCount == 1)
}

@Test func statsCountsXMPSidecarAsNonFrameNeverAsALight() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, instrume: "Cam", filter: "L"
    )
    try fixture.writePlainTextFile("sessions/T1/2026-01-10/lights/l1.fit.xmp")

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.totalIntegrationSeconds == 300.0)
    #expect(stats.usableFrameCount == 1)
    #expect(stats.nonFrameFileCount == 1)
}

@Test func statsExcludesRejectedFrameFromUsableTotalButCountsItSeparately() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, instrume: "Cam", filter: "L"
    )
    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/Reject/blurry/l2.fit", exptime: 120.0, instrume: "Cam", filter: "L"
    )

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.totalIntegrationSeconds == 300.0)
    #expect(stats.usableFrameCount == 1)
    #expect(stats.rejectedFrameCount == 1)
}

@Test func statsExcludesHibasLabeledSessionFromTargetTotalButKeepsItInSessionDates() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10_hibas/lights/l1.fit", exptime: 300.0, instrume: "Cam", filter: "L"
    )
    try fixture.writeFITSLight(
        "sessions/T1/2026-01-11/lights/l2.fit", exptime: 60.0, instrume: "Cam", filter: "L"
    )

    try fixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: fixture.db, config: fixture.config))
    #expect(stats.totalIntegrationSeconds == 60.0)
    #expect(stats.usableFrameCount == 1)
    #expect(stats.excludedSessionDates == ["2026-01-10_hibas"])
    #expect(Set(stats.sessionDates) == Set(["2026-01-10_hibas", "2026-01-11"]))
    #expect(stats.grossIntegrationSeconds == 360.0)
}

@Test func statsRespectsCustomExcludeLabelsFromConfig() throws {
    let fixture = try StatsFixture.make()
    defer { fixture.cleanup() }
    var config = fixture.config
    config.stats.excludeLabels = ["clouds"]
    let customFixture = StatsFixture(libraryDir: fixture.libraryDir, dbDir: fixture.dbDir, db: fixture.db, config: config)

    try customFixture.writeFITSLight(
        "sessions/T1/2026-01-10_clouds/lights/l1.fit", exptime: 300.0, instrume: "Cam", filter: "L"
    )
    try customFixture.writeFITSLight(
        "sessions/T1/2026-01-11_hibas/lights/l2.fit", exptime: 60.0, instrume: "Cam", filter: "L"
    )

    try customFixture.scan()

    let stats = try #require(try StatsQueries.target("T1", db: customFixture.db, config: customFixture.config))
    // "clouds" is excluded (custom config); "hibas" is NOT excluded here
    // since it's not in this target's configured list.
    #expect(stats.excludedSessionDates == ["2026-01-10_clouds"])
    #expect(stats.totalIntegrationSeconds == 60.0)
}

// MARK: - WideFieldHeuristic

private func lightFile(_ id: Int64, ext: String, target: String) -> FileRecord {
    FileRecord(id: id, path: "sessions/\(target)/2026-01-01/lights/f\(id).fit", size: 0, mtime: 0, ext: ext, kind: "fits", area: .sessions, target: target, sessionDate: "2026-01-01", role: .light, scannedAt: 0)
}

@Test func wideFieldOverrideTrueWinsRegardlessOfSignals() {
    let rule = WideFieldRule(extensions: ["cr3"], maxFocalLengthMM: 135, nameMarkers: ["wide"], overrides: ["M42": true])
    let files = [lightFile(1, ext: "fit", target: "M42")]
    let meta: [Int64: FITSMetaRecord] = [1: FITSMetaRecord(fileID: 1, focallen: 2000)]
    #expect(WideFieldHeuristic.isWideField(target: "M42", files: files, meta: meta, rule: rule))
}

@Test func wideFieldOverrideFalseWinsRegardlessOfSignals() {
    let rule = WideFieldRule(extensions: ["fit"], maxFocalLengthMM: 135, nameMarkers: ["m42"], overrides: ["M42": false])
    let files = [lightFile(1, ext: "fit", target: "M42")]
    let meta: [Int64: FITSMetaRecord] = [1: FITSMetaRecord(fileID: 1, focallen: 50)]
    #expect(!WideFieldHeuristic.isWideField(target: "M42", files: files, meta: meta, rule: rule))
}

@Test func wideFieldNameMarkerTriggersWithoutOverride() {
    let rule = WideFieldRule(extensions: ["cr3"], maxFocalLengthMM: 135, nameMarkers: ["wide"], overrides: [:])
    let files = [lightFile(1, ext: "fit", target: "Milkyway_Wide_Field")]
    #expect(WideFieldHeuristic.isWideField(target: "Milkyway_Wide_Field", files: files, meta: [:], rule: rule))
}

@Test func wideFieldExtensionMajorityTriggers() {
    let rule = WideFieldRule(extensions: ["cr3"], maxFocalLengthMM: 135, nameMarkers: ["wide"], overrides: [:])
    let files = [
        lightFile(1, ext: "cr3", target: "M31"),
        lightFile(2, ext: "cr3", target: "M31"),
        lightFile(3, ext: "fit", target: "M31"),
    ]
    #expect(WideFieldHeuristic.isWideField(target: "M31", files: files, meta: [:], rule: rule))
}

@Test func wideFieldExtensionMinorityDoesNotTrigger() {
    let rule = WideFieldRule(extensions: ["cr3"], maxFocalLengthMM: 135, nameMarkers: ["wide"], overrides: [:])
    let files = [
        lightFile(1, ext: "cr3", target: "M31"),
        lightFile(2, ext: "fit", target: "M31"),
        lightFile(3, ext: "fit", target: "M31"),
    ]
    #expect(!WideFieldHeuristic.isWideField(target: "M31", files: files, meta: [:], rule: rule))
}

@Test func wideFieldMedianFocalLengthAboveThresholdDoesNotTrigger() {
    let rule = WideFieldRule(extensions: ["cr3"], maxFocalLengthMM: 135, nameMarkers: ["wide"], overrides: [:])
    let files = [lightFile(1, ext: "fit", target: "M31"), lightFile(2, ext: "fit", target: "M31"), lightFile(3, ext: "fit", target: "M31")]
    let meta: [Int64: FITSMetaRecord] = [
        1: FITSMetaRecord(fileID: 1, focallen: 50),
        2: FITSMetaRecord(fileID: 2, focallen: 400),
        3: FITSMetaRecord(fileID: 3, focallen: 500),
    ]
    // median == 400, not < 135
    #expect(!WideFieldHeuristic.isWideField(target: "M31", files: files, meta: meta, rule: rule))
}

@Test func wideFieldMedianFocalLengthBelowThresholdTriggers() {
    let rule = WideFieldRule(extensions: ["cr3"], maxFocalLengthMM: 135, nameMarkers: ["wide"], overrides: [:])
    let files = [lightFile(1, ext: "fit", target: "M31"), lightFile(2, ext: "fit", target: "M31"), lightFile(3, ext: "fit", target: "M31")]
    let meta: [Int64: FITSMetaRecord] = [
        1: FITSMetaRecord(fileID: 1, focallen: 50),
        2: FITSMetaRecord(fileID: 2, focallen: 60),
        3: FITSMetaRecord(fileID: 3, focallen: 500),
    ]
    // median == 60, < 135
    #expect(WideFieldHeuristic.isWideField(target: "M31", files: files, meta: meta, rule: rule))
}

@Test func wideFieldNoSignalsReturnsFalse() {
    let rule = WideFieldRule(extensions: ["cr3"], maxFocalLengthMM: 135, nameMarkers: ["wide"], overrides: [:])
    let files = [lightFile(1, ext: "fit", target: "M31")]
    #expect(!WideFieldHeuristic.isWideField(target: "M31", files: files, meta: [:], rule: rule))
}
