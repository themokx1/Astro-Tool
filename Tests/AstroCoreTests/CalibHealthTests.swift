import Foundation
import Testing
@testable import AstroCore

private func makeTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-calib-health-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
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

/// A fresh fixture library + fresh sqlite-backed `Database` for
/// `CalibHealth` tests -- same shape as `CalibTests.swift`'s own
/// `CalibFixture`, kept separate (rather than shared) since it needs a wider
/// set of header cards (FOCALLEN/FILTER/ROTATOR/CCD-TEMP) than the darks-only
/// coverage tests do.
private struct CalibHealthFixture {
    let libraryDir: URL
    let dbDir: URL
    let db: Database
    var config: AstroConfig

    static func make() throws -> CalibHealthFixture {
        let libraryDir = try makeTempDir("lib")
        let dbDir = try makeTempDir("db")
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        var config = AstroConfig()
        config.rootPath = libraryDir.path
        return CalibHealthFixture(libraryDir: libraryDir, dbDir: dbDir, db: db, config: config)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: libraryDir)
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Writes one generated FITS frame with whichever cards are non-nil --
    /// used for lights, flats, darks (session or library master), and
    /// biases alike; the file's `role`/`area` come from `PathClassifier`
    /// reading the path itself (directory name), not from these cards.
    func writeFITSFrame(
        _ relativePath: String,
        exptime: Double? = nil,
        setTemp: Double? = nil,
        ccdTemp: Double? = nil,
        gain: Double? = nil,
        offset: Double? = nil,
        instrume: String? = nil,
        focallen: Double? = nil,
        filter: String? = nil,
        rotator: Double? = nil,
        dateObs: String? = nil
    ) throws {
        let url = libraryDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cards = ["SIMPLE  =                    T", "BITPIX  =                   16", "NAXIS   =                    2"]
        if let exptime { cards.append("EXPTIME =                \(exptime)") }
        if let setTemp { cards.append("SET-TEMP=                \(setTemp)") }
        if let ccdTemp { cards.append("CCD-TEMP=                \(ccdTemp)") }
        if let gain { cards.append("GAIN    =                \(gain)") }
        if let offset { cards.append("OFFSET  =                \(offset)") }
        if let instrume { cards.append("INSTRUME= '\(instrume)'") }
        if let focallen { cards.append("FOCALLEN=                \(focallen)") }
        if let filter { cards.append("FILTER  = '\(filter)'") }
        if let rotator { cards.append("ROTATOR =                \(rotator)") }
        if let dateObs { cards.append("DATE-OBS= '\(dateObs)'") }
        cards.append("END")
        try buildHeaderData(cards).write(to: url)
    }

    func scan() throws {
        let scanner = LibraryScanner(config: config, db: db)
        _ = try scanner.scan()
    }
}

// MARK: - (a) Flat discipline

@Test func flatDisciplineFlagsSessionWithNoFlatsAsMissing() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10, focallen: 750, dateObs: dateObsDaysAgo(1)
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    let flat = try #require(report.flats.first { $0.target == "T1" })
    #expect(flat.status == "nincs flat")
    #expect(flat.reasons.isEmpty)
}

@Test func flatDisciplineFlagsFocalLengthMismatch() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10, focallen: 750, dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/flats/f1.fit",
        focallen: 800, dateObs: dateObsDaysAgo(1)
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    let flat = try #require(report.flats.first { $0.target == "T1" })
    #expect(flat.status == "flat nem illik")
    let hasFocalReason = flat.reasons.contains { $0.contains("gyújtótáv") }
    #expect(hasFocalReason)
}

@Test func flatDisciplineFlagsRotatorMismatchBeyondTolerance() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10, rotator: 10.0, dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/flats/f1.fit",
        rotator: 20.0, dateObs: dateObsDaysAgo(1)
    )
    try fixture.scan()

    var config = fixture.config
    config.calib.rotatorToleranceDeg = 2.0

    let report = try CalibHealth.report(db: fixture.db, config: config)
    let flat = try #require(report.flats.first { $0.target == "T1" })
    #expect(flat.status == "flat nem illik")
    let hasRotatorReason = flat.reasons.contains { $0.contains("rotátor") }
    #expect(hasRotatorReason)
}

@Test func flatDisciplineRotatorAbsentProducesNoRotatorReason() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    // Neither side carries ROTATOR -- nothing to compare, so the check must
    // never contribute a reason (same "nothing to compare" convention as
    // CalibAnalyzer's offset/camera checks).
    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10, focallen: 750, dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/flats/f1.fit",
        focallen: 750, dateObs: dateObsDaysAgo(1)
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    let flat = try #require(report.flats.first { $0.target == "T1" })
    #expect(flat.status == "rendben")
    #expect(flat.reasons.isEmpty)
}

@Test func flatDisciplineFlagsFlatAgeBeyondMaxDays() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10, focallen: 750, dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/flats/f1.fit",
        focallen: 750, dateObs: dateObsDaysAgo(45)
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    let flat = try #require(report.flats.first { $0.target == "T1" })
    #expect(flat.status == "flat nem illik")
    let hasAgeReason = flat.reasons.contains { $0.contains("kor") }
    #expect(hasAgeReason)
}

@Test func flatDisciplineAllOKSessionIsRendben() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro",
        focallen: 750, filter: "L", rotator: 10.0, dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/flats/f1.fit",
        focallen: 750, filter: "L", rotator: 10.5, dateObs: dateObsDaysAgo(1)
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    let flat = try #require(report.flats.first { $0.target == "T1" })
    #expect(flat.status == "rendben")
    #expect(flat.reasons.isEmpty)
}

// MARK: - (b) Bias inventory

@Test func biasGroupingByGainOffsetCamera() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro"
    )
    for i in 1...3 {
        try fixture.writeFITSFrame(
            "sessions/T1/2026-01-10/biases/b\(i).fit",
            gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro"
        )
    }
    for i in 1...2 {
        try fixture.writeFITSFrame(
            "calibration_library/biases/b\(i).fit",
            gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro"
        )
    }

    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    let group = try #require(report.biasGroups.first { $0.gain == 100 && $0.offset == 50 && $0.camera == "ZWO ASI2600MC Pro" })
    #expect(group.frameCount == 5)
    #expect(group.locations.contains("sessions/T1/2026-01-10/biases"))
    #expect(group.locations.contains("calibration_library/biases"))
}

@Test func missingBiasComboDetectedForUsedLightCombo() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro"
    )
    // A bias exists, but for a DIFFERENT gain -- the light's own
    // gain100/offset50/ASI2600 combo has no matching bias group at all.
    try fixture.writeFITSFrame(
        "calibration_library/biases/b1.fit",
        gain: 0, offset: 50, instrume: "ZWO ASI2600MC Pro"
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    #expect(report.missingBiasCombos.contains { $0.contains("gain100") && $0.contains("offset50") && $0.contains("ASI2600") })
}

// MARK: - (c) Dark master health

@Test func darkMasterHealthFlagsTempSpreadWarning() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10
    )
    try fixture.writeFITSFrame(
        "calibration_library/darks/300sec_-10deg/d1.fit",
        ccdTemp: -10.0, dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "calibration_library/darks/300sec_-10deg/d2.fit",
        ccdTemp: -14.0, dateObs: dateObsDaysAgo(1)
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    let master = try #require(report.darkMasters.first { $0.path == "calibration_library/darks/300sec_-10deg" })
    #expect(master.frameCount == 2)
    let tempMaxDeviation = try #require(master.tempMaxDeviation)
    #expect(tempMaxDeviation > 1.5)
    #expect(master.warnings.contains("instabil hőmérséklet"))
}

@Test func darkMasterHealthFlagsUnusedMaster() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    // No light anywhere needs 60s/-10 -- this master is an orphan.
    try fixture.writeFITSFrame(
        "calibration_library/darks/60sec_-10deg/d1.fit",
        dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    let master = try #require(report.darkMasters.first { $0.path == "calibration_library/darks/60sec_-10deg" })
    #expect(master.isUnused == true)
    #expect(master.warnings.contains("nem használt"))
}

@Test func darkMasterHealthMatchedMasterIsNotFlaggedUnused() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "calibration_library/darks/300sec_-10deg/d1.fit",
        dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)
    let master = try #require(report.darkMasters.first { $0.path == "calibration_library/darks/300sec_-10deg" })
    #expect(master.isUnused == false)
    #expect(!master.warnings.contains("nem használt"))
}

// MARK: - JSON round-trip

@Test func calibHealthReportJSONRoundTrips() throws {
    let fixture = try CalibHealthFixture.make()
    defer { fixture.cleanup() }

    try fixture.writeFITSFrame(
        "sessions/T1/2026-01-10/lights/l1.fit",
        exptime: 300, setTemp: -10, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro", dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "calibration_library/darks/300sec_-10deg/d1.fit",
        ccdTemp: -10.0, gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro", dateObs: dateObsDaysAgo(1)
    )
    try fixture.writeFITSFrame(
        "calibration_library/biases/b1.fit",
        gain: 100, offset: 50, instrume: "ZWO ASI2600MC Pro"
    )
    try fixture.scan()

    let report = try CalibHealth.report(db: fixture.db, config: fixture.config)

    let encoder = JSONEncoder()
    let data = try encoder.encode(report)
    let decoded = try JSONDecoder().decode(CalibHealthReport.self, from: data)

    #expect(decoded.flats.count == report.flats.count)
    #expect(decoded.biasGroups.count == report.biasGroups.count)
    #expect(decoded.missingBiasCombos == report.missingBiasCombos)
    #expect(decoded.darkMasters.count == report.darkMasters.count)
}
