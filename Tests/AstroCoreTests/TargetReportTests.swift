import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixtures

private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-targetreport-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Inserts one light-frame row (`files` + `fits_meta`, optionally `ratings`)
/// under `sessions/<target>/<date>/lights/` -- same shape as
/// `NightReportTests`' own `insertLight`, extended with camera/gain/filter/
/// focal-length metadata so `TargetReport`'s session table has something to
/// show in every column.
@discardableResult
private func insertLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    dateObs: String,
    exptime: Double = 300,
    withCoordinates: Bool = true,
    camera: String = "TestCam",
    gain: Double? = 100,
    setTemp: Double? = -10,
    filter: String? = "L",
    focallen: Double? = 750,
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
            fileID: fileID, exptime: exptime, gain: gain, setTemp: setTemp, instrume: camera,
            focallen: focallen, filter: filter, dateObs: dateObs, headerJSON: headerJSON
        )
    )

    if fwhm != nil || background != nil || score != nil {
        try db.upsertRating(
            RatingRecord(fileID: fileID, fwhm: fwhm, background: background, score: score, ratedAt: 1_700_000_200, inputSig: "sig-\(name)")
        )
    }
    return fileID
}

/// A stack-looking file (ASIAIR autosave naming, so `StackDiscovery` picks
/// it up) directly tagged to `target`/`date` -- same convention as
/// `StackDiscoveryTests` (avoids needing `PathClassifier`, since the test
/// sets `FileRecord.target`/`sessionDate` explicitly).
@discardableResult
private func insertStack(
    db: Database,
    target: String,
    date: String,
    name: String,
    sizeBytes: Int64 = 50_000_000
) throws -> Int64 {
    let path = "stacks/\(target)/\(date)/\(name)"
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: sizeBytes, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .stacks, target: target, sessionDate: date, role: .stack,
            scannedAt: 1_700_000_100
        )
    )
    try db.backfillInode(id: fileID, inode: fileID + 1_000_000, nlink: 1)
    return fileID
}

/// Builds the "rich" fixture: target `T1` with two real sessions (one rated,
/// one not), one excluded (`_hibas`) session, a discoverable stack, a README
/// note, and a `goal:` tag -- everything `TargetReport.render`'s doc comment
/// says it composes.
private func makeRichFixture() throws -> (db: Database, config: AstroConfig) {
    let db = try makeMemoryDB()
    var config = AstroConfig()
    config.site.latitudeDeg = 47.5
    config.site.longitudeDeg = 19.0

    let target = "T1"

    // Session 1: rated, has a README note.
    try insertLight(db: db, target: target, date: "2026-04-18", name: "a", dateObs: "2026-04-18T21:00:00", fwhm: 2.4, background: 100, score: 0.5)
    try insertLight(db: db, target: target, date: "2026-04-18", name: "b", dateObs: "2026-04-18T21:05:00", fwhm: 2.6, background: 105, score: 0.3)
    try db.upsertSessionNotes(target: target, date: "2026-04-18", notes: ["Bortle": "4", "Camera": "TestCam"])

    // Session 2: unrated (no ratings row at all).
    try insertLight(db: db, target: target, date: "2026-04-19", name: "c", dateObs: "2026-04-19T21:00:00")

    // Session 3: excluded (`_hibas`).
    try insertLight(db: db, target: target, date: "2026-04-20_hibas", name: "d", dateObs: "2026-04-20T21:00:00")

    // A discoverable stack (R8-1) for the target.
    try insertStack(db: db, target: target, date: "2026-04-18", name: "T1_10x300sec_3000s_stacked.fit")

    try db.addTag(TagRecord(kind: "target", target: target, sessionDate: nil, tag: "goal:5h"))

    return (db, config)
}

// MARK: - 1. Rich fixture render contains the required Hungarian sections

@Test func targetReportRenderContainsKeySectionHeaders() throws {
    let (db, config) = try makeRichFixture()
    let html = try TargetReport.render(target: "T1", db: db, config: config)

    for header in ["Összkép", "Sessionök", "Minőség", "Stackek", "Kalibráció", "Panelek", "Tervezés", "Jegyzetek"] {
        #expect(html.contains(header), "missing section: \(header)")
    }
    #expect(html.contains("T1"))
}

// MARK: - 2. Usable vs gross integration numbers are correct

@Test func renderShowsCorrectUsableAndGrossIntegration() throws {
    let (db, config) = try makeRichFixture()
    let html = try TargetReport.render(target: "T1", db: db, config: config)

    let stat = try StatsQueries.target("T1", db: db, config: config)!
    // 2 usable lights in session 1 (300s + 300s == 600s == 10:00) + 1 usable
    // light in session 2 (300s == 5:00) == 15:00; the excluded session's
    // light contributes to gross but not usable.
    #expect(stat.usableIntegrationSeconds == 900)
    #expect(stat.grossIntegrationSeconds == 1200)
    #expect(html.contains("0:15"))
    #expect(html.contains("0:20"))
}

// MARK: - 3. Stack table row present, best stack highlighted

@Test func renderShowsStackTableWithBestStackHighlighted() throws {
    let (db, config) = try makeRichFixture()
    let html = try TargetReport.render(target: "T1", db: db, config: config)

    #expect(html.contains("T1_10x300sec_3000s_stacked.fit"))
    #expect(html.contains("★ legjobb"))
}

// MARK: - 4. Excluded session marked

@Test func renderMarksExcludedSession() throws {
    let (db, config) = try makeRichFixture()
    let html = try TargetReport.render(target: "T1", db: db, config: config)

    #expect(html.contains("2026-04-20_hibas"))
    #expect(html.contains("KIZÁRVA"))
}

@Test func targetReportRendersMergedFilterGoalTableWithEscapedNames() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    let filter = "Ha <5nm> & test"
    try insertLight(
        db: db,
        target: "FilterReport",
        date: "2026-04-18",
        name: "ha",
        dateObs: "2026-04-18T21:00:00",
        exptime: 3600,
        withCoordinates: false,
        filter: filter
    )
    try db.addTag(TagRecord(
        kind: "target", target: "FilterReport", sessionDate: nil,
        tag: GoalTag.formatFilter(filter: filter, hours: 2)
    ))

    let html = try TargetReport.render(target: "FilterReport", db: db, config: config)
    #expect(html.contains("<h2>Szűrők</h2>"))
    #expect(html.contains("Ha &lt;5nm&gt; &amp; test"))
    #expect(html.contains("<th>Megvan</th><th>Cél</th><th>Hiányzik</th>"))
    #expect(html.contains("1:00"))
    #expect(html.contains("2:00"))
}

// MARK: - 5. Graceful note when no coordinate resolves

@Test func targetReportRenderShowsNoteWhenNoCoordinateResolves() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T2", date: "2026-04-19", name: "a", dateObs: "2026-04-19T21:00:00", withCoordinates: false)

    let html = try TargetReport.render(target: "T2", db: db, config: config)

    #expect(html.contains("n/a — nincs plate-solve/fejléc koordináta"))
}

// MARK: - 6. Graceful note when no ratings at all

@Test func renderShowsNoteWhenNoRatingsExist() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()
    try insertLight(db: db, target: "T3", date: "2026-04-19", name: "a", dateObs: "2026-04-19T21:00:00")

    let html = try TargetReport.render(target: "T3", db: db, config: config)

    #expect(html.contains("Nincs pontozott keret"))
}

// MARK: - 7. Never contains a <script> tag

@Test func targetReportRenderNeverContainsScriptTag() throws {
    let (db, config) = try makeRichFixture()
    let html = try TargetReport.render(target: "T1", db: db, config: config)

    #expect(!html.contains("<script"))
}

// MARK: - 8 & 9. write() -> correct path, content == render()

@Test func targetReportWriteProducesTheExpectedPathAndMatchesRender() throws {
    let (db, config) = try makeRichFixture()
    let libraryDir = try makeTempDir("lib")
    defer { try? FileManager.default.removeItem(at: libraryDir) }

    var writableConfig = config
    writableConfig.rootPath = libraryDir.path
    let writeGuard = WriteGuard(root: libraryDir)

    let url = try TargetReport.write(target: "T1", db: db, config: writableConfig, using: writeGuard)

    let expectedURL = libraryDir.appendingPathComponent(".astro_tool/reports/target-T1.html")
    #expect(url.standardizedFileURL.path == expectedURL.standardizedFileURL.path)

    let writtenContent = try String(contentsOf: url, encoding: .utf8)
    let rendered = try TargetReport.render(target: "T1", db: db, config: writableConfig)
    #expect(writtenContent == rendered)
}

// MARK: - 10. Night-report-exists annotation appears when the file exists

@Test func renderAnnotatesSessionWhenNightReportAlreadyExists() throws {
    let (db, config) = try makeRichFixture()
    let libraryDir = try makeTempDir("nr")
    defer { try? FileManager.default.removeItem(at: libraryDir) }

    var writableConfig = config
    writableConfig.rootPath = libraryDir.path
    let writeGuard = WriteGuard(root: libraryDir)

    _ = try NightReport.write(
        target: "T1", date: "2026-04-18", timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        db: db, config: writableConfig, using: writeGuard
    )

    let html = try TargetReport.render(target: "T1", db: db, config: writableConfig)
    #expect(html.contains("van éjszaka-riport"))
}

// MARK: - 11. Unknown target throws pathNotFound

@Test func renderThrowsForUnknownTarget() throws {
    let db = try makeMemoryDB()
    let config = AstroConfig()

    #expect(throws: AstroError.self) {
        try TargetReport.render(target: "Nope", db: db, config: config)
    }
}
