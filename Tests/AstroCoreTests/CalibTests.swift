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
    /// OFFSET/INSTRUME/FILTER/FOCALLEN/DATE-OBS cards -- any card is omitted
    /// entirely when its value is `nil`, e.g. to simulate a DSLR with no
    /// cooler telemetry, or a corrupt/incomplete header with no exposure
    /// time at all.
    func writeFITSLight(
        _ relativePath: String,
        exptime: Double?,
        setTemp: Double?,
        gain: Double? = nil,
        offset: Double? = nil,
        instrume: String? = nil,
        filter: String? = nil,
        focallen: Double? = nil,
        dateObs: String? = nil
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        if let gain { cards.append("GAIN    =                \(gain)") }
        if let offset { cards.append("OFFSET  =                \(offset)") }
        if let instrume { cards.append("INSTRUME= '\(instrume)'") }
        if let filter { cards.append("FILTER  = '\(filter)'") }
        if let focallen { cards.append("FOCALLEN=                \(focallen)") }
        if let dateObs { cards.append("DATE-OBS= '\(dateObs)'") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
    }

    /// Writes a flat frame (session-local `flats/` dir, or
    /// `calibration_library/flats/`) with the given FILTER/FOCALLEN/
    /// DATE-OBS cards -- any card omitted entirely when its value is `nil`,
    /// e.g. to simulate an OSC/DSLR flat with no filter wheel at all.
    func writeFITSFlat(
        _ relativePath: String,
        filter: String? = nil,
        focallen: Double? = nil,
        dateObs: String? = nil
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let filter { cards.append("FILTER  = '\(filter)'") }
        if let focallen { cards.append("FOCALLEN=                \(focallen)") }
        if let dateObs { cards.append("DATE-OBS= '\(dateObs)'") }
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

@Test func darkCoverageDedupesCR3AndTIFPairCountingOneLight() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    // A physical DSLR shot kept as both its original `.cr3` and a converted
    // `.tif` -- same matching stem/DATE-OBS, same EXPTIME -- must count as
    // ONE light, not two (see R7-B7: this used to inflate `lightCount`
    // because `CalibAnalyzer` iterated every raw `role == .light` row
    // instead of going through `FrameSet.lightBuckets`, same as
    // `StatsQueries`). `writeTestTIFF` writes real, ImageIO-decodable TIFF
    // bytes regardless of the target extension, so EXIF EXPTIME/DATE-OBS
    // come through for the `.cr3`-named file too, even though a real CR3
    // can't be fabricated in tests.
    let cr3URL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/IMG_0001.cr3")
    let tifURL = fixture.libraryDir.appendingPathComponent("sessions/T1/2026-01-10/lights/IMG_0001.tif")
    try FileManager.default.createDirectory(at: cr3URL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeTestTIFF(to: cr3URL, dateTimeOriginal: "2026:01:10 20:00:00", exposureSeconds: 300.0)
    try writeTestTIFF(to: tifURL, dateTimeOriginal: "2026:01:10 20:00:00", exposureSeconds: 300.0)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first { $0.exposureSeconds == 300 })
    #expect(need.lightCount == 1)
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

// MARK: - R7-B6: nominal-exposure grouping + todo disambiguation

/// Ground-truthed against a real library (see R7-B6's investigation): the
/// SAME nominal "30s" dark need showed up as two separate rows -- 822
/// lights at `exptime == 30.0` and 91 more at `29.899999618523` -- because
/// the old grouping only rounded to 0.1s. After switching to
/// `NominalExposure`, both float-noisy readings must land in ONE combo
/// with the summed light count.
@Test func darkCoverageMergesFloatNoisyExptimesIntoOneNominalGroup() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/a\(i).fit", exptime: 30.0, setTemp: -10.0)
    }
    // Float-noisy "30s" sub -- must be counted into the SAME combo, not its
    // own separate row.
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/b1.fit", exptime: 29.899999618523, setTemp: -10.0)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    #expect(needs.count == 1, "29.9s and 30.0s must merge into one nominal-exposure combo, not split into two rows")
    let need = try #require(needs.first)
    #expect(need.exposureSeconds == 30)
    #expect(need.lightCount == 4)
}

/// A light with no cooler telemetry at all (DSLR, `SET-TEMP` never
/// written) must get an explicit "(hőmérséklet nélkül)" callout in its todo
/// text -- previously the temp clause was just silently omitted, which
/// read the same as "temperature doesn't matter here" rather than "we
/// don't actually know it".
@Test func darkCoverageTodoLabelsNilTempExplicitly() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 30.0, setTemp: nil)

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.todo?.contains("hőmérséklet nélkül") == true)
}

/// Real symptom: a "30s" dark need split into two rows -- 822 lights with
/// no `GAIN` at all and 310 more at `gain == 1600` -- same nominal
/// exposure/temp/camera otherwise. That split is real (this function must
/// never silently pool different electronic settings together), but with
/// no explanation it reads as a duplicate-row bug. Once more than one gain
/// value exists at the same (exposure, temp, camera), each affected row's
/// todo must name its own gain so the two rows are told apart.
@Test func darkCoverageTodoNamesGainWhenAmbiguousAtSameExposureTempCamera() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITSLight(
            "sessions/T1/2026-01-10/lights/nogain\(i).fit",
            exptime: 30.0, setTemp: nil, instrume: "Canon EOS R8"
        )
    }
    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/gain1600.fit",
        exptime: 30.0, setTemp: nil, gain: 1600, instrume: "Canon EOS R8"
    )

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    #expect(needs.count == 2, "different gain at the same nominal exposure/temp/camera must stay two separate combos")

    let gainRow = try #require(needs.first { $0.lightCount == 1 })
    #expect(gainRow.todo?.contains("gain: 1600") == true)

    let noGainRow = try #require(needs.first { $0.lightCount == 3 })
    #expect(noGainRow.todo?.contains("gain:") == false, "the unambiguous single-gain-value case shouldn't grow a gain clause of its own")
}

/// When more than one camera shows up among the scanned lights, each
/// missing-combo todo must name its own camera so two rows at the same
/// nominal exposure/temp aren't mistaken for one duplicated row.
@Test func darkCoverageTodoNamesCameraWhenMoreThanOneCameraPresent() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/canon.fit",
        exptime: 30.0, setTemp: nil, instrume: "Canon EOS R8"
    )
    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/asi.fit",
        exptime: 30.0, setTemp: -10.0, instrume: "ZWO ASI2600MC Pro"
    )

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    #expect(needs.count == 2)

    let canonRow = try #require(needs.first { $0.tempC == nil })
    #expect(canonRow.todo?.contains("Canon EOS R8") == true)

    let asiRow = try #require(needs.first { $0.tempC == -10.0 })
    #expect(asiRow.todo?.contains("ZWO ASI2600MC Pro") == true)
}

/// A single-camera library (the common case) must keep the old, unadorned
/// todo wording -- no gratuitous "kamera: …" clause when there's nothing to
/// disambiguate.
@Test func darkCoverageTodoOmitsCameraWhenOnlyOneCameraPresent() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 120.0, setTemp: -10.0, instrume: "ZWO ASI2600MC Pro"
    )

    try fixture.scan()

    let needs = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.todo == "készíts 120 s / -10 °C darkot (1 light frame-hez)")
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

// MARK: - R11-T16/F17: flat coverage

@Test func flatCoverageOSCSessionOwnFlatCoversFilterlessLightsWithoutNoise() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    // An OSC/DSLR light with no FILTER header at all, covered by a
    // filterless session flat -- must read as fully covered, no
    // "(nincs szűrő)" placeholder anywhere in the output.
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0)
    try fixture.writeFITSFlat("sessions/T1/2026-01-10/flats/f1.fit")

    try fixture.scan()

    let needs = try CalibAnalyzer.flatCoverage(db: fixture.db, config: fixture.config)
    #expect(needs.count == 1)
    let need = try #require(needs.first)
    #expect(need.kind == .flat)
    #expect(need.filter == nil)
    #expect(need.todo == nil)
    #expect(need.matchedMasterPath == "sessions/T1/2026-01-10/flats")
    #expect(!(need.todo ?? "").contains("nincs szűrő"))
}

@Test func flatCoverageMonoMultiFilterFlagsOnlyTheUncoveredFilter() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/ha\(i).fit", exptime: 300.0, setTemp: -10.0, filter: "Ha")
    }
    for i in 1...2 {
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/oiii\(i).fit", exptime: 300.0, setTemp: -10.0, filter: "OIII")
    }
    // Own flat only for Ha -- OIII has no covering flat anywhere.
    try fixture.writeFITSFlat("sessions/T1/2026-01-10/flats/haflat.fit", filter: "Ha")

    try fixture.scan()

    let needs = try CalibAnalyzer.flatCoverage(db: fixture.db, config: fixture.config)
    #expect(needs.count == 2)

    let haNeed = try #require(needs.first { $0.filter == "Ha" })
    #expect(haNeed.todo == nil)
    #expect(haNeed.matchedMasterPath == "sessions/T1/2026-01-10/flats")
    #expect(haNeed.lightCount == 3)

    let oiiiNeed = try #require(needs.first { $0.filter == "OIII" })
    #expect(oiiiNeed.matchedMasterPath == nil)
    #expect(oiiiNeed.todo == "Hiányzó flat: OIII — 1 session érintett")
    #expect(oiiiNeed.lightCount == 2)
    #expect(oiiiNeed.targets == ["T1"])
}

@Test func flatCoverageMissingAcrossThreeSessionsNamesSessionCountInTodo() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0, filter: "OIII")
    try fixture.writeFITSLight("sessions/T1/2026-01-11/lights/l1.fit", exptime: 300.0, setTemp: -10.0, filter: "OIII")
    try fixture.writeFITSLight("sessions/T2/2026-01-12/lights/l1.fit", exptime: 300.0, setTemp: -10.0, filter: "OIII")
    // No flats anywhere -- neither session-local nor library.

    try fixture.scan()

    let needs = try CalibAnalyzer.flatCoverage(db: fixture.db, config: fixture.config)
    #expect(needs.count == 1)
    let need = try #require(needs.first)
    #expect(need.filter == "OIII")
    #expect(need.matchedMasterPath == nil)
    #expect(need.todo == "Hiányzó flat: OIII — 3 session érintett")
    #expect(need.targets == ["T1", "T2"])
    #expect(need.mismatchReasons.isEmpty)
}

@Test func flatCoverageStaleLibraryFlatFlagsRefreshTodoWithAgeAndSessionCount() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300.0, setTemp: -10.0, filter: "Ha", dateObs: dateObsDaysAgo(0)
    )
    // No session-own flat -- only a stale library flat, 60 days away from
    // the light's own DATE-OBS (default flatMaxAgeDays is 30).
    try fixture.writeFITSFlat(
        "calibration_library/flats/libflat.fit",
        filter: "Ha", dateObs: dateObsDaysAgo(60)
    )

    try fixture.scan()

    let needs = try CalibAnalyzer.flatCoverage(db: fixture.db, config: fixture.config)
    #expect(needs.count == 1)
    let need = try #require(needs.first)
    #expect(need.filter == "Ha")
    #expect(need.isStale == true)
    #expect(need.matchedMasterPath == "calibration_library/flats")
    #expect((need.masterAgeDays ?? 0) >= 59)
    #expect(need.todo?.contains("napos") == true)
    #expect(need.todo?.contains("készíts frisset") == true)
    #expect(need.todo?.contains("1 session érintett") == true)
}

@Test func flatCoverageFreshLibraryFlatCoversAFilterWithNoSessionFlatAtAll() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300.0, setTemp: -10.0, filter: "Ha", dateObs: dateObsDaysAgo(0)
    )
    try fixture.writeFITSFlat(
        "calibration_library/flats/libflat.fit",
        filter: "Ha", dateObs: dateObsDaysAgo(2)
    )

    try fixture.scan()

    let needs = try CalibAnalyzer.flatCoverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.todo == nil)
    #expect(need.isStale == false)
    #expect(need.matchedMasterPath == "calibration_library/flats")
}

@Test func flatCoverageFocalLengthMismatchIsReportedAndCountsAsMissing() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSLight(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300.0, setTemp: -10.0, filter: "Ha", focallen: 800
    )
    // Session's own flat matches the filter but not the focal length --
    // must be REJECTED (not silently accepted), same "coarse match, reject
    // on secondary dimension" shape darks use for gain/offset/camera.
    try fixture.writeFITSFlat("sessions/T1/2026-01-10/flats/f1.fit", filter: "Ha", focallen: 500)

    try fixture.scan()

    let needs = try CalibAnalyzer.flatCoverage(db: fixture.db, config: fixture.config)
    let need = try #require(needs.first)
    #expect(need.matchedMasterPath == nil)
    #expect(need.mismatchReasons.contains("gyújtótáv eltér: light 800mm, flat 500mm"))
    #expect(need.todo == "Hiányzó flat: Ha — 1 session érintett")
}

@Test func flatCoveragePerSessionAPIReturnsCoveredFlagsSortedByFilter() throws {
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    for i in 1...3 {
        try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/ha\(i).fit", exptime: 300.0, setTemp: -10.0, filter: "Ha")
    }
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/oiii1.fit", exptime: 300.0, setTemp: -10.0, filter: "OIII")
    try fixture.writeFITSFlat("sessions/T1/2026-01-10/flats/haflat.fit", filter: "Ha")

    try fixture.scan()

    let files = try fixture.db.allFiles(includeMissing: false)
    let result = try CalibAnalyzer.flatCoverage(target: "T1", date: "2026-01-10", files: files, db: fixture.db, config: fixture.config)

    #expect(result.count == 2)
    #expect(result[0].filter == "Ha")
    #expect(result[0].covered == true)
    #expect(result[1].filter == "OIII")
    #expect(result[1].covered == false)
}

@Test func flatCoverageDoesNotAffectExistingDarkCoverageFunction() throws {
    // R11-T16/F17: `coverage()` (darks) must stay exactly as it was --
    // flats live in their own separate `flatCoverage` function. A library
    // with BOTH a dark master and a flat combo must have `coverage()`
    // return ONLY the dark row.
    let fixture = try CalibFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeMasterFile("calibration_library/darks/300sec_-10deg/master.fit")
    try fixture.writeFITSLight("sessions/T1/2026-01-10/lights/l1.fit", exptime: 300.0, setTemp: -10.0, filter: "Ha")
    try fixture.writeFITSFlat("sessions/T1/2026-01-10/flats/f1.fit", filter: "Ha")

    try fixture.scan()

    let darkNeeds = try CalibAnalyzer.coverage(db: fixture.db, config: fixture.config)
    #expect(darkNeeds.count == 1)
    #expect(darkNeeds[0].kind == .dark)
}
