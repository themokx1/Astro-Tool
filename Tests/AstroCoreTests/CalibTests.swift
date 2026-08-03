import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-calib-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A FITS-style (`"yyyy-MM-dd'T'HH:mm:ss"`, UTC) `DATE-OBS` string for
/// `daysAgo` days before now -- matches `SessionTimeline.parseDateObs`'s
/// no-fraction format.
private func dateObsDaysAgo(_ daysAgo: Int) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    let date = Date().addingTimeInterval(-Double(daysAgo) * 86400)
    return formatter.string(from: date)
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

    /// Writes a generated light frame with the given EXPTIME/SET-TEMP/GAIN/
    /// OFFSET/INSTRUME cards -- any card is omitted entirely when its value
    /// is `nil`, e.g. to simulate a DSLR with no cooler telemetry, or a
    /// corrupt/incomplete header with no exposure time at all.
    func writeFITSLight(
        _ relativePath: String,
        exptime: Double?,
        setTemp: Double?,
        gain: Double? = nil,
        offset: Double? = nil,
        instrume: String? = nil
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        if let gain { cards.append("GAIN    =                \(gain)") }
        if let offset { cards.append("OFFSET  =                \(offset)") }
        if let instrume { cards.append("INSTRUME= '\(instrume)'") }
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

    /// Writes a master-calibration file as a real (parseable) FITS header
    /// carrying GAIN/OFFSET/INSTRUME/XBINNING/DATE-OBS cards -- unlike
    /// `writeMasterFile`, this one's content matters: `CalibAnalyzer`
    /// aggregates these straight off the file's `fits_meta` row (and
    /// `header_json` for `XBINNING`).
    func writeFITSMaster(
        _ relativePath: String,
        gain: Double? = nil,
        offset: Double? = nil,
        instrume: String? = nil,
        xbinning: Int? = nil,
        dateObs: String? = nil
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let gain { cards.append("GAIN    =                \(gain)") }
        if let offset { cards.append("OFFSET  =                \(offset)") }
        if let instrume { cards.append("INSTRUME= '\(instrume)'") }
        if let xbinning { cards.append("XBINNING=                \(xbinning)") }
        if let dateObs { cards.append("DATE-OBS= '\(dateObs)'") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
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

    var config = fixture.config
    config.calib.darkMaxAgeMonths = 6 // 180-day threshold -- pinned so 210 days old reads as stale regardless of the tool's own default.

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: config)
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

// MARK: - R4-3: full electronic-key matching

@Test func darkCoverageAggregatesGainOffsetFromHeadersAndReportsBothMismatches() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    // Master's own electronic identity, parsed straight off its FITS
    // header (GAIN/OFFSET/INSTRUME/XBINNING cards) -- not the dir name.
    try fixture.writeFITSMaster(
        "calibration_library/darks/300sec_-10deg/master.fit",
        gain: 0, offset: 10, instrume: "ZWO ASI2600MC Pro", xbinning: 1
    )
    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300.0, setTemp: -10.0,
        gain: 100, offset: 20, instrume: "ZWO ASI2600MC Pro"
    )

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first { $0.exposureSeconds == 300 })

    // Same (exposure, temp), same camera -- but gain AND offset differ, so
    // the master is rejected (not silently accepted) with both reasons
    // surfaced, proving the aggregation actually read the header values
    // rather than defaulting to "no data, so always match".
    #expect(need.matchedMasterPath == nil)
    #expect(need.mismatchReasons.contains("gain 0 ≠ 100"))
    #expect(need.mismatchReasons.contains("offset 10 ≠ 20"))
    #expect(need.requiredGain == 100)
    #expect(need.requiredCamera == "ZWO ASI2600MC Pro")
}

@Test func darkCoverageRejectsGainMismatchWithReason() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSMaster("calibration_library/darks/60sec_-10deg/master.fit", gain: 0)
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, setTemp: -10.0, gain: 100)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath == nil)
    #expect(need.mismatchReasons == ["gain 0 ≠ 100"])
    #expect(need.requiredGain == 100)
}

@Test func darkCoverageAcceptsGainMismatchWhenMatchGainDisabled() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSMaster("calibration_library/darks/60sec_-10deg/master.fit", gain: 0)
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, setTemp: -10.0, gain: 100)

    try fixture.scan()

    var config = fixture.config
    config.calib.matchGain = false

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath == "calibration_library/darks/60sec_-10deg")
    #expect(need.mismatchReasons.isEmpty)
}

@Test func darkCoverageOnlyEnforcesOffsetWhenBothSidesHaveAValue() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    // Master carries OFFSET, light doesn't (older header/no such card) --
    // nothing to compare, so the check is skipped rather than rejecting.
    try fixture.writeFITSMaster("calibration_library/darks/60sec_-10deg/master.fit", offset: 50)
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, setTemp: -10.0)

    // Light carries OFFSET, master doesn't -- same "nothing to compare" rule
    // applies from the other side too.
    try fixture.writeFITSMaster("calibration_library/darks/120sec_-10deg/master.fit")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l2.fit", exptime: 120.0, setTemp: -10.0, offset: 20)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)

    let need60 = try #require(needs.first { $0.exposureSeconds == 60 })
    #expect(need60.matchedMasterPath == "calibration_library/darks/60sec_-10deg")
    #expect(need60.mismatchReasons.isEmpty)

    let need120 = try #require(needs.first { $0.exposureSeconds == 120 })
    #expect(need120.matchedMasterPath == "calibration_library/darks/120sec_-10deg")
    #expect(need120.mismatchReasons.isEmpty)
}

@Test func darkCoverageAppliesRelativeExposureTolerance() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSMaster("calibration_library/darks/30sec_-10deg/master.fit")
    // 29.9s vs a 30s master: 0.1s off, within the default 2% relative
    // tolerance (0.6s) even though the absolute tolerance is 0.
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 29.9, setTemp: -10.0)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath == "calibration_library/darks/30sec_-10deg")
}

@Test func darkCoverageDefaultTempToleranceIsOnePointZero() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSMaster("calibration_library/darks/60sec_-20deg/master.fit")
    // -19.3 vs a -20 master: 0.7°C off -- within the new 1.0°C default, but
    // would have been rejected under the old 0.5°C default.
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 60.0, setTemp: -19.3)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath == "calibration_library/darks/60sec_-20deg")
}

@Test func darkCoverageAgeComesFromDateObsNotMtime() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    // The master's own DATE-OBS says it's 400 days old, but its mtime (set
    // by the fixture writing the file just now, and never backdated) says
    // it's brand new -- a plain copy/rsync would do exactly this. Age must
    // come from DATE-OBS, so the default 12-month (360-day) threshold
    // should flag it stale despite the fresh mtime.
    try fixture.writeFITSMaster(
        "calibration_library/darks/300sec_-10deg/master.fit",
        dateObs: dateObsDaysAgo(400)
    )
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath != nil)
    #expect(need.isStale == true)
    #expect((need.masterAgeDays ?? 0) >= 399)
}

@Test func darkCoverageDSLRLightWithISOInGainColumnDoesNotMatchASIMasterOnCameraMismatch() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSMaster(
        "calibration_library/darks/60sec_-10deg/master.fit",
        instrume: "ZWO ASI2600MC Pro"
    )
    // A DSLR light has no cooler telemetry (setTemp nil, already matches
    // any master temp) and its ISO lands in the same `gain` column real
    // FITS gain uses -- but its camera name is obviously not the ASI's.
    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 60.0, setTemp: nil,
        gain: 800, instrume: "Canon EOS Ra"
    )

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath == nil)
    #expect(need.mismatchReasons.contains("másik kamera: ZWO ASI2600MC Pro"))
    #expect(need.requiredCamera == "Canon EOS Ra")
}
