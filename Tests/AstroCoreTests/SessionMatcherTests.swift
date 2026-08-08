import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-sessionmatcher-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fresh fixture library + fresh sqlite-backed `Database`, minimal like
/// `CalibFixture` -- each test builds only the small tree it cares about.
private struct SessionMatcherFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> SessionMatcherFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return SessionMatcherFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Writes a generated FITS file with the given EXPTIME/SET-TEMP/
    /// IMAGETYP/FILTER/FOCALLEN cards -- any `nil` parameter omits that card
    /// entirely.
    func writeFITS(
        _ relativePath: String,
        exptime: Double? = nil,
        setTemp: Double? = nil,
        imagetyp: String? = nil,
        filter: String? = nil,
        focallen: Double? = nil
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        if let imagetyp { cards.append("IMAGETYP= '\(imagetyp)'") }
        if let filter { cards.append("FILTER  = '\(filter)'") }
        if let focallen { cards.append("FOCALLEN=                \(focallen)") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
    }

    /// Writes a dummy file whose content SessionMatcher never inspects --
    /// only its path matters (flats/darks/biases frames, calibration
    /// library master files).
    func writeDummy(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy".write(to: url, atomically: true, encoding: .utf8)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

// MARK: - 1. Full session: own darks, no library fallback needed

@Test func sessionMatcherReportsFullSessionWithOwnCalibAndNoProblems() throws {
    let fixture = try SessionMatcherFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITS("sessions/T1/2026-01-10/lights/l\(i).fit", exptime: 300.0, setTemp: -10.0)
    }
    try fixture.writeDummy("sessions/T1/2026-01-10/flats/f1.fit")
    try fixture.writeDummy("sessions/T1/2026-01-10/darks/d1.fit")
    try fixture.writeDummy("sessions/T1/2026-01-10/biases/b1.fit")

    try fixture.scan()

    let result = try SessionMatcher.match(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    #expect(result.target == "T1")
    #expect(result.date == "2026-01-10")
    #expect(result.lights == 3)
    #expect(result.flats == ["sessions/T1/2026-01-10/flats/f1.fit"])
    #expect(result.darks == ["sessions/T1/2026-01-10/darks/d1.fit"])
    #expect(result.biases == ["sessions/T1/2026-01-10/biases/b1.fit"])
    #expect(result.libraryDark == nil)
    #expect(result.problems.isEmpty)
}

// MARK: - 2. No session darks, library has a matching master

@Test func sessionMatcherFallsBackToLibraryDarkWhenSessionHasNone() throws {
    let fixture = try SessionMatcherFixture.make()
    defer { fixture.cleanup() }

    for i in 1...2 {
        try fixture.writeFITS("sessions/T1/2026-01-10/lights/l\(i).fit", exptime: 300.0, setTemp: -10.0)
    }
    try fixture.writeDummy("sessions/T1/2026-01-10/flats/f1.fit")
    try fixture.writeDummy("calibration_library/darks/300sec_-10deg/master.fit")

    try fixture.scan()

    let result = try SessionMatcher.match(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    #expect(result.darks.isEmpty)
    #expect(result.libraryDark == "calibration_library/darks/300sec_-10deg")
    #expect(!result.problems.contains { $0.category == "missing-darks" })
}

// MARK: - 3. No session darks, no matching library dir

@Test func sessionMatcherFlagsMissingDarksWhenNoLibraryMatch() throws {
    let fixture = try SessionMatcherFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
    try fixture.writeDummy("sessions/T1/2026-01-10/flats/f1.fit")
    // Only a 60s master exists -- doesn't match the 300s light.
    try fixture.writeDummy("calibration_library/darks/60sec_-10deg/master.fit")

    try fixture.scan()

    let result = try SessionMatcher.match(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    #expect(result.libraryDark == nil)
    let hit = try #require(result.problems.first { $0.category == "missing-darks" })
    #expect(hit.severity == .suspicious)
    #expect(hit.path == "sessions/T1/2026-01-10")
    #expect(hit.suggestion == nil)
}

// MARK: - 4. No flats

@Test func sessionMatcherFlagsMissingFlats() throws {
    let fixture = try SessionMatcherFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
    try fixture.writeDummy("sessions/T1/2026-01-10/darks/d1.fit")

    try fixture.scan()

    let result = try SessionMatcher.match(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    #expect(result.flats.isEmpty)
    let hit = try #require(result.problems.first { $0.category == "missing-flats" })
    #expect(hit.severity == .suspicious)
    #expect(hit.path == "sessions/T1/2026-01-10")
    #expect(hit.suggestion == nil)
}

// MARK: - 5. Misplaced flat inside lights/

@Test func sessionMatcherFlagsMisplacedFrameWithinSession() throws {
    let fixture = try SessionMatcherFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
    try fixture.writeFITS("sessions/T1/2026-01-10/lights/flat_stray.fit", imagetyp: "Flat Field")
    try fixture.writeDummy("sessions/T1/2026-01-10/flats/f1.fit")
    try fixture.writeDummy("sessions/T1/2026-01-10/darks/d1.fit")

    try fixture.scan()

    let result = try SessionMatcher.match(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    let hit = try #require(result.problems.first { $0.path == "sessions/T1/2026-01-10/lights/flat_stray.fit" })
    #expect(hit.severity == .sureError)
    #expect(hit.category == "calib-in-wrong-dir")
    #expect(hit.suggestion == .move(
        from: "sessions/T1/2026-01-10/lights/flat_stray.fit",
        to: "sessions/T1/2026-01-10/flats/flat_stray.fit"
    ))
}

// MARK: - 6. Unknown (target, date)

@Test func sessionMatcherThrowsPathNotFoundForUnknownSession() throws {
    let fixture = try SessionMatcherFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
    try fixture.scan()

    do {
        _ = try SessionMatcher.match(target: "T2", date: "2099-01-01", db: fixture.db, config: fixture.config)
        Issue.record("expected AstroError.pathNotFound to be thrown")
    } catch let AstroError.pathNotFound(path) {
        #expect(path == "sessions/T2/2099-01-01")
    } catch {
        Issue.record("expected AstroError.pathNotFound, got \(error)")
    }
}

// MARK: - 8. CR3+TIF dedup (R7-B7)

@Test func sessionMatcherDedupesCR3AndTIFPairCountingOneLight() throws {
    let fixture = try SessionMatcherFixture.make()
    defer { fixture.cleanup() }

    // Same physical DSLR shot kept as both `.cr3` and a converted `.tif` --
    // `SessionMatcher.match` must report ONE light, not two, and pick a
    // dominant combo from the deduped set. `writeTestTIFF` writes real,
    // ImageIO-decodable TIFF bytes regardless of the target extension.
    let cr3URL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/IMG_0001.cr3")
    let tifURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/IMG_0001.tif")
    try FileManager.default.createDirectory(at: cr3URL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeTestTIFF(to: cr3URL, dateTimeOriginal: "2026:01:10 20:00:00", exposureSeconds: 300.0)
    try writeTestTIFF(to: tifURL, dateTimeOriginal: "2026:01:10 20:00:00", exposureSeconds: 300.0)
    try fixture.writeDummy("sessions/T1/2026-01-10/flats/f1.fit")
    try fixture.writeDummy("calibration_library/darks/300sec_0deg/master.fit")

    try fixture.scan()

    let result = try SessionMatcher.match(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    #expect(result.lights == 1)
}

// MARK: - 7. Dominant combo selection

@Test func sessionMatcherPicksLibraryDarkForDominantComboAmongMixedLights() throws {
    let fixture = try SessionMatcherFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITS("sessions/T1/2026-01-10/lights/l\(i).fit", exptime: 300.0, setTemp: -10.0)
    }
    try fixture.writeFITS("sessions/T1/2026-01-10/lights/l4.fit", exptime: 60.0, setTemp: -10.0)
    try fixture.writeDummy("sessions/T1/2026-01-10/flats/f1.fit")

    try fixture.writeDummy("calibration_library/darks/300sec_-10deg/master.fit")
    try fixture.writeDummy("calibration_library/darks/60sec_-10deg/master.fit")

    try fixture.scan()

    let result = try SessionMatcher.match(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    #expect(result.lights == 4)
    #expect(result.libraryDark == "calibration_library/darks/300sec_-10deg")
}

// MARK: - 9. R11-T16/F17: per-filter flat coverage

@Test func sessionMatcherPopulatesFlatsByFilterForAMultiFilterSession() throws {
    let fixture = try SessionMatcherFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITS("sessions/T1/2026-01-10/lights/ha\(i).fit", exptime: 300.0, setTemp: -10.0, filter: "Ha")
    }
    try fixture.writeFITS("sessions/T1/2026-01-10/lights/oiii1.fit", exptime: 300.0, setTemp: -10.0, filter: "OIII")
    // Own flat only for Ha -- OIII has no covering flat anywhere.
    try fixture.writeFITS("sessions/T1/2026-01-10/flats/haflat.fit", filter: "Ha")
    try fixture.writeDummy("sessions/T1/2026-01-10/darks/d1.fit")
    try fixture.writeDummy("sessions/T1/2026-01-10/biases/b1.fit")

    try fixture.scan()

    let result = try SessionMatcher.match(target: "T1", date: "2026-01-10", db: fixture.db, config: fixture.config)

    let sorted = result.flatsByFilter.sorted { ($0.filter ?? "") < ($1.filter ?? "") }
    #expect(sorted.count == 2)
    #expect(sorted[0].filter == "Ha")
    #expect(sorted[0].covered == true)
    #expect(sorted[1].filter == "OIII")
    #expect(sorted[1].covered == false)
}
