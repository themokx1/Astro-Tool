import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixtures

private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-nightreport-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Inserts one light-frame row (`files` + `fits_meta`, optionally `ratings`)
/// with a real `DATE-OBS`/`exptime` so `SessionTimeline`/`NightReport`'s own
/// altitude/Moon math has something to chew on. `withCoordinates` adds a
/// `CRVAL1`/`CRVAL2` WCS pair to `header_json` -- the "this session has a
/// resolvable target position" case; omitted entirely for the "no
/// coordinate" fixture.
@discardableResult
private func insertLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    dateObs: String,
    exptime: Double = 300,
    withCoordinates: Bool = true,
    fwhm: Double? = nil,
    background: Double? = nil,
    score: Double? = nil
) throws -> Int64 {
    let path = "sessions/\(target)/\(date)/lights/\(name).fit"
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light,
            scannedAt: 1_700_000_100
        )
    )
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)

    let headerJSON: String? = withCoordinates ? "{\"CRVAL1\":\"180.0\",\"CRVAL2\":\"45.0\"}" : nil
    try db.upsertFITSMeta(
        FITSMetaRecord(
            fileID: fileID, exptime: exptime, instrume: "TestCam", dateObs: dateObs, headerJSON: headerJSON
        )
    )

    if fwhm != nil || background != nil || score != nil {
        try db.upsertRating(
            RatingRecord(fileID: fileID, fwhm: fwhm, background: background, score: score, ratedAt: 1_700_000_200, inputSig: "sig-\(name)")
        )
    }
    return fileID
}

/// Builds the "rich" fixture: a scanned-equivalent session with 3 usable
/// lights (one recorded gap, one gap below the auto threshold), coordinates
/// resolvable via header WCS, a rated frame, and a README note -- everything
/// `NightReport.render`'s doc comment says it composes.
private func makeRichFixture() throws -> (db: Database, config: AstroConfig) {
    let db = try makeMemoryDB()
    var config = AstroConfig()
    config.site.latitudeDeg = 47.5
    config.site.longitudeDeg = 19.0

    let target = "T1"
    let date = "2026-04-18"

    try insertLight(db: db, target: target, date: date, name: "a", dateObs: "2026-04-18T21:00:00", fwhm: 2.4, background: 100, score: 0.5)
    // Gap between a's end (21:05:00) and b's start (21:25:00) == 1200s,
    // safely above the auto threshold (3x the 300s nominal exptime == 900s).
    try insertLight(db: db, target: target, date: date, name: "b", dateObs: "2026-04-18T21:25:00")
    // Gap between b's end (21:30:00) and c's start (21:35:00) == 300s, below
    // the 900s threshold -- must NOT show up in `timeline.gaps`.
    try insertLight(db: db, target: target, date: date, name: "c", dateObs: "2026-04-18T21:35:00")

    try db.upsertSessionNotes(target: target, date: date, notes: ["Bortle": "4", "Camera": "TestCam"])

    return (db, config)
}

// MARK: - 1. Rich fixture render contains the required Hungarian sections

@Test func renderContainsKeySectionHeaders() throws {
    let (db, config) = try makeRichFixture()
    let html = try NightReport.render(target: "T1", date: "2026-04-18", db: db, config: config)

    for header in ["Összefoglaló számok", "Idővonal", "Minőség", "Magasság & Hold", "Hardver", "Kalibráció", "README-jegyzetek", "Teendők"] {
        #expect(html.contains(header), "missing section: \(header)")
    }
    #expect(html.contains("T1"))
    #expect(html.contains("2026-04-18"))
}

// MARK: - 2. Correct duty %

@Test func renderShowsCorrectDutyCycle() throws {
    let (db, config) = try makeRichFixture()
    let html = try NightReport.render(target: "T1", date: "2026-04-18", db: db, config: config)

    let timeline = try SessionTimeline.timeline(target: "T1", date: "2026-04-18", db: db, config: config)
    let duty = timeline.dutyCycle!
    let expectedPercent = Int((duty * 100).rounded())
    #expect(html.contains("\(expectedPercent)%"))

    // Sanity on the fixture's own numbers (documents the 38% expectation).
    #expect(timeline.integrationSeconds == 900)
    #expect(timeline.windowSeconds == 2400)
    #expect(expectedPercent == 38)
    #expect(timeline.gaps.count == 1)
}

// MARK: - 3. Altitude section present when coordinates exist

@Test func renderShowsAltitudeNumbersWhenCoordinatesExist() throws {
    let (db, config) = try makeRichFixture()
    let html = try NightReport.render(target: "T1", date: "2026-04-18", db: db, config: config)

    #expect(html.contains("Min. magasság"))
    #expect(html.contains("Max. magasság"))
    #expect(html.contains("30° alatt"))
    #expect(!html.contains("n/a — nincs koordináta vagy site adat"))
}

// MARK: - 4. Altitude section absent-with-note when no coordinate resolves

@Test func renderShowsNoteWhenNoCoordinateResolves() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig() // no site configured, no header coordinates either

    try insertLight(db: db, target: "T2", date: "2026-04-19", name: "a", dateObs: "2026-04-19T21:00:00", withCoordinates: false)

    let html = try NightReport.render(target: "T2", date: "2026-04-19", db: db, config: config)

    #expect(html.contains("n/a — nincs koordináta vagy site adat"))
    #expect(!html.contains("Min. magasság"))
}

// MARK: - 5. Moon numbers present alongside the altitude track

@Test func renderShowsMoonGeometryWhenAvailable() throws {
    let (db, config) = try makeRichFixture()
    let html = try NightReport.render(target: "T1", date: "2026-04-18", db: db, config: config)

    #expect(html.contains("Hold megvilágítás"))
    #expect(html.contains("Hold-szeparáció"))
    #expect(html.contains("Hold max. magasság"))
}

// MARK: - 6. Never contains a <script> tag

@Test func renderNeverContainsScriptTag() throws {
    let (db, config) = try makeRichFixture()
    let html = try NightReport.render(target: "T1", date: "2026-04-18", db: db, config: config)

    #expect(!html.contains("<script"))
}

// MARK: - 7 & 8. write() -> correct path, content == render()

@Test func writeProducesTheExpectedPathAndMatchesRender() throws {
    let (db, config) = try makeRichFixture()
    let libraryDir = try makeTempDir("lib")
    defer { try? FileManager.default.removeItem(at: libraryDir) }

    var writableConfig = config
    writableConfig.rootPath = libraryDir.path
    let writeGuard = WriteGuard(root: libraryDir)

    let url = try NightReport.write(
        target: "T1", date: "2026-04-18", timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        db: db, config: writableConfig, using: writeGuard
    )

    let expectedURL = libraryDir.appendingPathComponent(".astro_tool/reports/T1-2026-04-18.html")
    #expect(url.standardizedFileURL.path == expectedURL.standardizedFileURL.path)

    let writtenContent = try String(contentsOf: url, encoding: .utf8)
    let rendered = try NightReport.render(target: "T1", date: "2026-04-18", db: db, config: writableConfig)
    #expect(writtenContent == rendered)
}

// MARK: - 9. Unknown target/date throws pathNotFound

@Test func renderThrowsForUnknownSession() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    #expect(throws: AstroError.self) {
        try NightReport.render(target: "Nope", date: "2026-01-01", db: db, config: config)
    }
}
