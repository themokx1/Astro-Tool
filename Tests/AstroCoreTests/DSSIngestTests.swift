import Foundation
import Testing
@testable import AstroCore

// MARK: - DSSInfoParser

@Test func dssInfoParserParsesFullFileWithAllKnownKeys() {
    let text = """
    OverallQuality = 1234.56
    SkyBackground = 0.0123
    NrStars = 78
    MeanRadius = 2.34
    Circularity = 0.89
    """
    let metrics = DSSInfoParser.parse(data: Data(text.utf8))
    #expect(metrics.overallQuality == 1234.56)
    #expect(metrics.skyBackground == 0.0123)
    #expect(metrics.nrStars == 78)
    #expect(metrics.meanRadius == 2.34)
    #expect(metrics.circularity == 0.89)
    #expect(abs(metrics.fwhm! - 4.68) < 0.0001, "fwhm ~= 2 x MeanRadius")
    #expect(metrics.roundness == 0.89)
    #expect(metrics.starCount == 78)
}

@Test func dssInfoParserHandlesPartialFileLeavingMissingFieldsNil() {
    let text = "NrStars = 50\nMeanRadius = 1.5\n"
    let metrics = DSSInfoParser.parse(data: Data(text.utf8))
    #expect(metrics.nrStars == 50)
    #expect(metrics.fwhm == 3.0)
    #expect(metrics.overallQuality == nil)
    #expect(metrics.skyBackground == nil)
    #expect(metrics.circularity == nil)
    #expect(metrics.roundness == nil, "no Circularity and no Axises lines -> no fallback either")
}

@Test func dssInfoParserTreatsQualityAsAliasForOverallQualityWhenOverallQualityAbsent() {
    let text = "Quality = 555.0\n"
    let metrics = DSSInfoParser.parse(data: Data(text.utf8))
    #expect(metrics.overallQuality == 555.0)
}

@Test func dssInfoParserPrefersExplicitOverallQualityOverQualityAlias() {
    let text = "OverallQuality = 100.0\nQuality = 999.0\n"
    let metrics = DSSInfoParser.parse(data: Data(text.utf8))
    #expect(metrics.overallQuality == 100.0)
}

@Test func dssInfoParserReturnsAllNilMetricsForGarbageInput() {
    let text = "this is not a key value file\njust some random noise\n1234\n"
    let metrics = DSSInfoParser.parse(data: Data(text.utf8))
    #expect(metrics == DSSInfoMetrics())
}

@Test func dssInfoParserCapsReadAt256KiBIgnoringContentBeyondTheCap() {
    // A value before the cap must survive; the same key repeated well past
    // the cap boundary must never overwrite it.
    let filler = String(repeating: "#", count: DSSInfoParser.maxBytes + 1000)
    let text = "NrStars = 42\n" + filler + "\nNrStars = 999\n"
    let metrics = DSSInfoParser.parse(data: Data(text.utf8))
    #expect(metrics.nrStars == 42, "content beyond the 256 KiB cap must never be parsed")
}

@Test func dssInfoMetricsFWHMIsTwiceMeanRadius() {
    let metrics = DSSInfoMetrics(meanRadius: 2.0)
    #expect(metrics.fwhm == 4.0)
}

@Test func dssInfoParserUsesMeanAxisRatioAsRoundnessFallbackWhenCircularityAbsent() {
    let text = """
    NrStars = 10
    Axises = 4.0, 2.0
    Axises = 3.0, 3.0
    """
    let metrics = DSSInfoParser.parse(data: Data(text.utf8))
    #expect(metrics.circularity == nil)
    #expect(metrics.roundness == 0.75) // mean of (2/4=0.5) and (3/3=1.0)
}

@Test func dssInfoParserPrefersCircularityOverAxisRatioFallbackWhenBothPresent() {
    let text = "Circularity = 0.95\nAxises = 1.0, 2.0\n"
    let metrics = DSSInfoParser.parse(data: Data(text.utf8))
    #expect(metrics.roundness == 0.95)
}

// MARK: - DSSFilelistParser

@Test func dssFilelistParserParsesCheckedZeroOneAcrossCRLFLineEndingsKeepingNonLightRows() {
    let text = "DSS file list\r\nCHECKED\tTYPE\tFILE\r\n1\tlight\tlights/a.fit\r\n0\tlight\tlights/b.fit\r\n1\tdark\tdarks/d1.fit\r\n"
    let rows = DSSFilelistParser.parseRows(text: text)
    #expect(rows.count == 3)
    #expect(rows[0] == DSSFilelistRow(checked: true, type: "light", relativePath: "lights/a.fit"))
    #expect(rows[1] == DSSFilelistRow(checked: false, type: "light", relativePath: "lights/b.fit"))
    #expect(rows[2] == DSSFilelistRow(checked: true, type: "dark", relativePath: "darks/d1.fit"))
}

@Test func dssFilelistParserResolvedLightRowsIgnoresNonLightRowsAndResolvesRelativePaths() {
    let text = """
    DSS file list
    CHECKED\tTYPE\tFILE
    1\tlight\tlights/a.fit
    0\tdark\tdarks/d1.fit
    1\tlight\t../2026-01-02/lights/b.fit
    """
    let resolved = DSSFilelistParser.resolvedLightRows(text: text, baseDir: "sessions/M31/2026-01-01")
    #expect(resolved.count == 2, "the dark-typed row must be dropped")
    #expect(resolved[0].path == "sessions/M31/2026-01-01/lights/a.fit")
    #expect(resolved[0].checked == true)
    #expect(resolved[1].path == "sessions/M31/2026-01-02/lights/b.fit", "\"..\" must resolve up one directory")
    #expect(resolved[1].checked == true)
}

// MARK: - DSSIngest end-to-end fixture

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-dss-ingest-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private struct DSSIngestFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> DSSIngestFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return DSSIngestFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    var root: URL { libraryDir }

    /// Registers a tracked LIGHT frame (content is irrelevant to
    /// `DSSIngest`, only `size`/`mtime` feed its `inputSig`).
    @discardableResult
    func addLightFile(
        relativePath: String, target: String, sessionDate: String = "2026-01-01",
        size: Int64 = 2048, mtime: Double = 1_700_000_000
    ) throws -> Int64 {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: Int(size)).write(to: url)
        let record = FileRecord(
            path: relativePath, size: size, mtime: mtime, ext: (relativePath as NSString).pathExtension.lowercased(),
            kind: "fits", area: .sessions, target: target, sessionDate: sessionDate, role: .light,
            scannedAt: Date().timeIntervalSince1970
        )
        return try db.upsertFile(record)
    }

    /// Registers a tracked text-ish sidecar (`.info.txt` or `.dssfilelist`)
    /// and writes `content` to disk at the same path -- mirrors how the
    /// scanner tracks every `.txt`/other file it walks, whether or not it
    /// parses its content.
    @discardableResult
    func addTextFile(
        relativePath: String, content: String, kind: String,
        target: String? = nil, sessionDate: String? = nil, role: FrameRole = .light
    ) throws -> Int64 {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let record = FileRecord(
            path: relativePath, size: Int64(content.utf8.count), mtime: 1_700_000_000,
            ext: (relativePath as NSString).pathExtension.lowercased(), kind: kind,
            area: .sessions, target: target, sessionDate: sessionDate, role: role,
            scannedAt: Date().timeIntervalSince1970
        )
        return try db.upsertFile(record)
    }
}

private let sampleInfoTxt = """
OverallQuality = 900.0
SkyBackground = 0.02
NrStars = 120
MeanRadius = 2.5
Circularity = 0.91
"""

@Test func dssIngestEndToEndParsesInfoFilesAndFilelistUpsertingRatingsAndVerdicts() throws {
    let fixture = try DSSIngestFixture.make()
    defer { fixture.cleanup() }

    let light1ID = try fixture.addLightFile(
        relativePath: "sessions/M31/2026-01-01/lights/light_0001.fit", target: "M31"
    )
    try fixture.addLightFile(
        relativePath: "sessions/M31/2026-01-01/lights/light_0002.fit", target: "M31"
    )

    try fixture.addTextFile(
        relativePath: "sessions/M31/2026-01-01/lights/light_0001.fit.info.txt",
        content: sampleInfoTxt, kind: "text", target: "M31", sessionDate: "2026-01-01"
    )

    // The .dssfilelist sits directly in the session date dir (not inside
    // lights/), so "lights/..." in FILE resolves relative to that.
    let filelistText = """
    DSS file list
    CHECKED\tTYPE\tFILE
    1\tlight\tlights/light_0001.fit
    0\tlight\tlights/light_0002.fit
    """
    try fixture.addTextFile(
        relativePath: "sessions/M31/2026-01-01/session.dssfilelist",
        content: filelistText, kind: "other", target: "M31", sessionDate: "2026-01-01"
    )

    let summary = try DSSIngest.ingest(db: fixture.db, config: fixture.config, root: fixture.root)

    #expect(summary.infoFilesParsed == 1)
    #expect(summary.ratingsUpserted == 1)
    #expect(summary.filelistsParsed == 1)
    #expect(summary.verdictsRecorded == 2)
    #expect(summary.skipped == 0)

    let rating = try #require(try fixture.db.rating(fileID: light1ID))
    #expect(rating.source == "dss")
    #expect(rating.fwhm == 5.0) // 2 x MeanRadius(2.5)
    #expect(rating.roundness == 0.91)
    #expect(rating.starCount == 120)
    #expect(rating.background == nil, "info.txt's SkyBackground is never mapped onto ratings.background")
    #expect(rating.score == nil)

    let light2ID = try #require(try fixture.db.fileID(path: "sessions/M31/2026-01-01/lights/light_0002.fit"))
    let verdict1 = try #require(try fixture.db.userVerdict(fileID: light1ID))
    #expect(verdict1.accepted == true)
    #expect(verdict1.source == "dssfilelist")
    let verdict2 = try #require(try fixture.db.userVerdict(fileID: light2ID))
    #expect(verdict2.accepted == false)
}

@Test func dssIngestDoesNotClobberExistingNonDSSRating() throws {
    let fixture = try DSSIngestFixture.make()
    defer { fixture.cleanup() }

    let lightID = try fixture.addLightFile(
        relativePath: "sessions/M42/2026-02-02/lights/light_0001.fit", target: "M42"
    )
    // A real astrotool/Siril rating already on file (source == nil).
    let existing = RatingRecord(
        fileID: lightID, fwhm: 1.8, roundness: 0.95, starCount: 500, background: 300, score: 1.2,
        ratedAt: 1_700_000_000, inputSig: "sig-astrotool"
    )
    try fixture.db.upsertRating(existing)

    try fixture.addTextFile(
        relativePath: "sessions/M42/2026-02-02/lights/light_0001.fit.info.txt",
        content: sampleInfoTxt, kind: "text", target: "M42", sessionDate: "2026-02-02"
    )

    let summary = try DSSIngest.ingest(db: fixture.db, config: fixture.config, root: fixture.root)
    #expect(summary.ratingsUpserted == 0)
    #expect(summary.skipped == 1)

    let fetched = try #require(try fixture.db.rating(fileID: lightID))
    #expect(fetched == existing, "an existing NULL-source rating must never be clobbered by a DSS ingest")
}

@Test func dssIngestIsIdempotentSkippingUnchangedInfoFilesOnRepeatedRuns() throws {
    let fixture = try DSSIngestFixture.make()
    defer { fixture.cleanup() }

    try fixture.addLightFile(relativePath: "sessions/M13/2026-03-03/lights/light_0001.fit", target: "M13")
    try fixture.addTextFile(
        relativePath: "sessions/M13/2026-03-03/lights/light_0001.fit.info.txt",
        content: sampleInfoTxt, kind: "text", target: "M13", sessionDate: "2026-03-03"
    )

    let first = try DSSIngest.ingest(db: fixture.db, config: fixture.config, root: fixture.root)
    #expect(first.ratingsUpserted == 1)
    #expect(first.skipped == 0)

    let second = try DSSIngest.ingest(db: fixture.db, config: fixture.config, root: fixture.root)
    #expect(second.ratingsUpserted == 0, "an unchanged frame's info.txt must not be re-ingested")
    #expect(second.skipped == 1)
    #expect(second.infoFilesParsed == 1)
}
