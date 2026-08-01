import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-calib-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A fresh fixture library + fresh sqlite-backed `Database`, everything a
/// calibration-coverage test needs. Deliberately minimal (unlike
/// `Fixtures.makeMessyLibrary`) -- each test builds only the small tree it
/// cares about.
private struct CalibFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> CalibFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return CalibFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Writes a generated light frame with the given EXPTIME/SET-TEMP cards
    /// -- either card is omitted entirely when its value is `nil`, e.g. to
    /// simulate a DSLR with no cooler telemetry, or a corrupt/incomplete
    /// header with no exposure time at all.
    func writeFITSLight(_ relativePath: String, exptime: Double?, setTemp: Double?) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
    }

    /// Writes a dummy master-calibration file -- the directory name carries
    /// all the data `CalibAnalyzer` cares about, so the file content itself
    /// is irrelevant.
    func writeMasterFile(_ relativePath: String) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "dummy master".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Backdates a file already on disk. Must be called before `scan()` so
    /// the database records the backdated timestamp rather than "now".
    func setModificationDate(_ relativePath: String, daysAgo: Int) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        let date = Date().addingTimeInterval(-Double(daysAgo) * 86400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

// MARK: - parseMasterDirName

@Test func parseMasterDirNameParsesValidFormats() {
    let sixty = CalibAnalyzer.parseMasterDirName("60sec_-10deg")
    #expect(sixty?.exposureS == 60)
    #expect(sixty?.tempC == -10)

    let fractional = CalibAnalyzer.parseMasterDirName("6.8sec_-10deg")
    #expect(fractional?.exposureS == 6.8)
    #expect(fractional?.tempC == -10)

    let fractional2 = CalibAnalyzer.parseMasterDirName("5.5sec_-10deg")
    #expect(fractional2?.exposureS == 5.5)
    #expect(fractional2?.tempC == -10)

    let zeroTemp = CalibAnalyzer.parseMasterDirName("300sec_0deg")
    #expect(zeroTemp?.exposureS == 300)
    #expect(zeroTemp?.tempC == 0)
}

@Test func parseMasterDirNameRejectsMalformedNames() {
    #expect(CalibAnalyzer.parseMasterDirName("60sec") == nil)
    #expect(CalibAnalyzer.parseMasterDirName("sec_deg") == nil)
    #expect(CalibAnalyzer.parseMasterDirName("60s_-10deg") == nil)
    #expect(CalibAnalyzer.parseMasterDirName("60sec_deg") == nil)
    #expect(CalibAnalyzer.parseMasterDirName("random") == nil)
}

// MARK: - coverage

@Test func darkCoverageMatchesExactComboAndFlagsMissingComboWithTodo() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeMasterFile("calibration_library/darks/60sec_-10deg/master.fit")
    try fixture.writeMasterFile("calibration_library/darks/300sec_-10deg/master.fit")

    for i in 1...3 {
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l\(i).fit", exptime: 300.0, setTemp: -10.0)
    }
    for i in 1...2 {
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/s\(i).fit", exptime: 120.0, setTemp: -10.0)
    }

    try fixture.scan()

    // Sanity: the scanner classifies the master file's role from the
    // calibration_library/darks/ subdir -- CalibAnalyzer relies on this.
    let masterRecord = try fixture.db.file(path: "calibration_library/darks/300sec_-10deg/master.fit")
    #expect(masterRecord?.role == .dark)
    #expect(masterRecord?.area == .calibration)

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)

    let covered = try #require(needs.first { $0.exposureSeconds == 300 })
    #expect(covered.matchedMasterPath == "calibration_library/darks/300sec_-10deg")
    #expect(covered.lightCount == 3)
    #expect(covered.targets == ["T1"])
    #expect(covered.isStale == false)
    #expect(covered.todo == nil)

    let missing = try #require(needs.first { $0.exposureSeconds == 120 })
    #expect(missing.matchedMasterPath == nil)
    #expect(missing.lightCount == 2)
    #expect(missing.todo == "készíts 120 s / -10 °C darkot (2 light frame-hez)")
}

@Test func darkCoverageAppliesTemperatureTolerance() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeMasterFile("calibration_library/darks/60sec_-10deg/master.fit")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, setTemp: -9.8)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath == "calibration_library/darks/60sec_-10deg")
    #expect(need.todo == nil)
}

@Test func darkCoverageMatchesNilTempLightAgainstAnyTempMaster() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeMasterFile("calibration_library/darks/60sec_-10deg/master.fit")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, setTemp: nil)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.tempC == nil)
    #expect(need.matchedMasterPath == "calibration_library/darks/60sec_-10deg")
    #expect(need.todo == nil)
}

@Test func darkCoverageMarksStaleMasterPastMaxAgeMonths() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeMasterFile("calibration_library/darks/300sec_-10deg/master.fit")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
    try fixture.setModificationDate("calibration_library/darks/300sec_-10deg/master.fit", daysAgo: 210)

    try fixture.scan()

    var config = fixture.config
    config.calib.darkMaxAgeMonths = 6 // 180-day threshold

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath != nil)
    #expect(need.isStale == true)
    #expect((need.masterAgeDays ?? 0) >= 210)
    #expect(need.todo?.contains("napos") == true)
    #expect(need.todo?.contains("300sec_-10deg") == true)
}

@Test func darkCoverageSortsMissingBeforeStaleBeforeCovered() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    // Covered + fresh: 60s/-10.
    try fixture.writeMasterFile("calibration_library/darks/60sec_-10deg/master.fit")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a1.fit", exptime: 60.0, setTemp: -10.0)

    // Covered but stale: 300s/-10.
    try fixture.writeMasterFile("calibration_library/darks/300sec_-10deg/master.fit")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/b1.fit", exptime: 300.0, setTemp: -10.0)

    // Missing: 30s/-10, no master anywhere.
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/c1.fit", exptime: 30.0, setTemp: -10.0)

    try fixture.setModificationDate("calibration_library/darks/300sec_-10deg/master.fit", daysAgo: 210)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    #expect(needs.count == 3)
    #expect(needs[0].exposureSeconds == 30)
    #expect(needs[0].matchedMasterPath == nil)
    #expect(needs[1].exposureSeconds == 300)
    #expect(needs[1].isStale == true)
    #expect(needs[2].exposureSeconds == 60)
    #expect(needs[2].todo == nil)
}

@Test func darkCoverageSkipsLightsWithoutExptime() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/noexp.fit", exptime: nil, setTemp: -10.0)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    #expect(needs.isEmpty)
}

@Test func darkCoverageIgnoresMalformedMasterDirNames() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeMasterFile("calibration_library/darks/badname/master.fit")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, setTemp: -10.0)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath == nil)
    #expect(need.todo != nil)
}
