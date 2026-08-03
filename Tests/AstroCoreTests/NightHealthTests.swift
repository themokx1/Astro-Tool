import Foundation
import Testing
@testable import AstroCore

/// `NightHealth` reads only `Database` rows (files + fits_meta + ratings) --
/// these tests build exactly those rows directly (no scanner, no real FITS/
/// image files), same spirit as `SessionQualityTests`'s own fixture helper.
private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

/// A FITS-style (`"yyyy-MM-dd'T'HH:mm:ss"`, UTC) `DATE-OBS` string
/// `hoursOffset` hours after a fixed reference instant -- deterministic
/// (unlike "now"-relative helpers) so the focus-regression tests can predict
/// exact hour spacing between frames.
private func dateObs(hoursOffset: Double) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    let reference = Date(timeIntervalSince1970: 1_700_000_000)
    return formatter.string(from: reference.addingTimeInterval(hoursOffset * 3600))
}

/// Inserts one light-frame row (`files` + `fits_meta` + optional `ratings`)
/// and returns its `fileID`. Every metric parameter is optional so a test
/// can build exactly the shape it needs.
@discardableResult
private func insertLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    exptime: Double? = 60,
    setTemp: Double? = nil,
    ccdTemp: Double? = nil,
    xpixsz: Double? = nil,
    focallen: Double? = nil,
    dateObsHours: Double? = nil,
    fwhm: Double? = nil
) throws -> Int64 {
    let path = "sessions/\(target)/\(date)/lights/\(name).fit"
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light,
            scannedAt: 1_700_000_100
        )
    )
    // Same fake-inode trick `SessionQualityTests` uses: these synthetic rows
    // have no real file to `stat()`, so without a per-row inode `FrameSet`'s
    // fallback dedup key would collide same-exptime/no-dateObs frames in one
    // session down to a single "canonical" copy.
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)
    try db.upsertFITSMeta(
        FITSMetaRecord(
            fileID: fileID, exptime: exptime, setTemp: setTemp, ccdTemp: ccdTemp,
            focallen: focallen, dateObs: dateObsHours.map(dateObs(hoursOffset:)), xpixsz: xpixsz
        )
    )
    if let fwhm {
        try db.upsertRating(
            RatingRecord(fileID: fileID, fwhm: fwhm, ratedAt: 1_700_000_200, inputSig: "sig-\(name)")
        )
    }
    return fileID
}

// MARK: - Cooler health

@Test func coolerHealthReportsStableWhenAllFramesWithinTolerance() throws {
    let db = try makeMemoryDB()
    for i in 1...5 {
        try insertLight(db: db, target: "T1", date: "2026-06-01", name: "l\(i)", setTemp: -20, ccdTemp: -19.8)
    }

    let report = try NightHealth.report(target: "T1", date: "2026-06-01", db: db, config: AstroConfig())
    #expect(report.cooler.verdict == "stabil")
    let outOfBandFraction = try #require(report.cooler.outOfBandFraction)
    #expect(outOfBandFraction == 0)
    let medianDelta = try #require(report.cooler.medianDeltaC)
    #expect(abs(medianDelta - 0.2) < 0.0001)
}

@Test func coolerHealthReportsExactOutOfBandFractionAndVerdictWhenCoolerStruggles() throws {
    let db = try makeMemoryDB()
    // 2 of 5 frames drift more than 1.0°C above SET-TEMP -- exactly 40%.
    try insertLight(db: db, target: "T2", date: "2026-07-10", name: "l1", setTemp: -20, ccdTemp: -19.9)
    try insertLight(db: db, target: "T2", date: "2026-07-10", name: "l2", setTemp: -20, ccdTemp: -19.8)
    try insertLight(db: db, target: "T2", date: "2026-07-10", name: "l3", setTemp: -20, ccdTemp: -19.95)
    try insertLight(db: db, target: "T2", date: "2026-07-10", name: "l4", setTemp: -20, ccdTemp: -16.8)
    try insertLight(db: db, target: "T2", date: "2026-07-10", name: "l5", setTemp: -20, ccdTemp: -14.0)

    let report = try NightHealth.report(target: "T2", date: "2026-07-10", db: db, config: AstroConfig())
    let outOfBandFraction = try #require(report.cooler.outOfBandFraction)
    #expect(abs(outOfBandFraction - 0.4) < 0.0001)
    let maxAbsDelta = try #require(report.cooler.maxAbsDeltaC)
    #expect(abs(maxAbsDelta - 6.0) < 0.0001)
    #expect(report.cooler.verdict.contains("nem tartja"))
    #expect(report.cooler.verdict.contains("+6.0"))
}

@Test func coolerHealthReportsNAWhenSetTempMissingEntirelyDSLR() throws {
    let db = try makeMemoryDB()
    for i in 1...5 {
        // A DSLR frame: no SET-TEMP/CCD-TEMP headers at all.
        try insertLight(db: db, target: "T3", date: "2026-05-01", name: "l\(i)")
    }

    let report = try NightHealth.report(target: "T3", date: "2026-05-01", db: db, config: AstroConfig())
    #expect(report.cooler.verdict == "n/a — nincs hűtési adat")
    #expect(report.cooler.outOfBandFraction == nil)
    #expect(report.cooler.medianDeltaC == nil)
    #expect(report.cooler.maxAbsDeltaC == nil)
}

// MARK: - Focus health

@Test func focusHealthComputesExactSlopeInPixelsWhenNoPixelScaleAvailable() throws {
    let db = try makeMemoryDB()
    // Perfectly linear synthetic FWHM: slope is exactly 0.2 px/hour.
    let fwhms: [Double] = [2.0, 2.2, 2.4, 2.6, 2.8]
    for (i, fwhm) in fwhms.enumerated() {
        try insertLight(db: db, target: "F1", date: "2026-01-01", name: "l\(i)", dateObsHours: Double(i), fwhm: fwhm)
    }

    let report = try NightHealth.report(target: "F1", date: "2026-01-01", db: db, config: AstroConfig())
    #expect(report.focus.ratedFrameCount == 5)
    let slope = try #require(report.focus.slopePerHour)
    #expect(abs(slope - 0.2) < 1e-6)
    #expect(report.focus.slopeUnit == "px/h")
    let totalDrift = try #require(report.focus.totalDrift)
    #expect(abs(totalDrift - 0.8) < 1e-6)
    #expect(report.focus.verdict.contains("gyanú"))
}

@Test func focusHealthConvertsSlopeToArcsecWhenPixelScaleKnown() throws {
    let db = try makeMemoryDB()
    let fwhms: [Double] = [2.0, 2.2, 2.4, 2.6, 2.8]
    for (i, fwhm) in fwhms.enumerated() {
        try insertLight(
            db: db, target: "F2", date: "2026-01-02", name: "l\(i)",
            xpixsz: 3.76, focallen: 302, dateObsHours: Double(i), fwhm: fwhm
        )
    }

    let report = try NightHealth.report(target: "F2", date: "2026-01-02", db: db, config: AstroConfig())
    #expect(report.focus.slopeUnit == "arcsec/h")
    let expectedScale = 206.265 * 3.76 / 302.0
    let slope = try #require(report.focus.slopePerHour)
    #expect(abs(slope - 0.2 * expectedScale) < 0.0001)
    let totalDrift = try #require(report.focus.totalDrift)
    #expect(abs(totalDrift - 0.8 * expectedScale) < 0.0001)
}

@Test func focusHealthReportsNAWhenFewerThanFiveRatedFrames() throws {
    let db = try makeMemoryDB()
    for i in 0..<3 {
        try insertLight(db: db, target: "F3", date: "2026-01-03", name: "l\(i)", dateObsHours: Double(i), fwhm: 3.0)
    }

    let report = try NightHealth.report(target: "F3", date: "2026-01-03", db: db, config: AstroConfig())
    #expect(report.focus.ratedFrameCount == 3)
    #expect(report.focus.verdict == "n/a — kevés pontozott keret")
    #expect(report.focus.slopePerHour == nil)
    #expect(report.focus.totalDrift == nil)
}

@Test func focusHealthReportsStableWhenDriftBelowThreshold() throws {
    let db = try makeMemoryDB()
    // Flat FWHM across the night -- zero drift, well under the 0.15px
    // threshold.
    for i in 0..<6 {
        try insertLight(db: db, target: "F4", date: "2026-01-04", name: "l\(i)", dateObsHours: Double(i), fwhm: 3.0)
    }

    let report = try NightHealth.report(target: "F4", date: "2026-01-04", db: db, config: AstroConfig())
    #expect(report.focus.verdict == "stabil fókusz")
}

// MARK: - Audit rule (cooler-not-reaching-setpoint)

private func makeAuditContext(files: [FileRecord], meta: [Int64: FITSMetaRecord], config: AstroConfig = AstroConfig()) -> AuditContext {
    AuditContext(config: config, files: files, directories: [], fitsMetaByFileID: meta)
}

private func lightFile(id: Int64, target: String, date: String, name: String) -> FileRecord {
    FileRecord(
        id: id, path: "sessions/\(target)/\(date)/lights/\(name).fit", size: 1024, mtime: 0,
        ext: "fit", kind: "fits", area: .sessions, target: target, sessionDate: date, role: .light,
        scannedAt: 0, inode: id, nlink: 1
    )
}

@Test func coolerRuleFiresWhenMoreThanTenPercentOfFramesOutOfBand() throws {
    var files: [FileRecord] = []
    var meta: [Int64: FITSMetaRecord] = [:]
    // 10 frames, 2 out of band (20% > 10%).
    for i in 1...10 {
        let id = Int64(i)
        files.append(lightFile(id: id, target: "T1", date: "2026-07-01", name: "l\(i)"))
        let ccd = i <= 2 ? -16.0 : -19.9
        meta[id] = FITSMetaRecord(fileID: id, setTemp: -20, ccdTemp: ccd)
    }

    let ctx = makeAuditContext(files: files, meta: meta)
    let findings = CoolerNotReachingSetpointRule().evaluate(ctx)

    #expect(findings.count == 1)
    let finding = try #require(findings.first)
    #expect(finding.category == "cooler-not-reaching-setpoint")
    #expect(finding.severity == .suspicious)
    #expect(finding.path == "sessions/T1/2026-07-01")
}

@Test func coolerRuleStaysSilentWhenSessionIsStable() throws {
    var files: [FileRecord] = []
    var meta: [Int64: FITSMetaRecord] = [:]
    for i in 1...10 {
        let id = Int64(i)
        files.append(lightFile(id: id, target: "T2", date: "2026-07-02", name: "l\(i)"))
        meta[id] = FITSMetaRecord(fileID: id, setTemp: -20, ccdTemp: -19.9)
    }

    let ctx = makeAuditContext(files: files, meta: meta)
    let findings = CoolerNotReachingSetpointRule().evaluate(ctx)
    #expect(findings.isEmpty)
}

@Test func coolerRuleStaysSilentWhenNoPairedTemperatureDataAtAll() throws {
    var files: [FileRecord] = []
    var meta: [Int64: FITSMetaRecord] = [:]
    for i in 1...10 {
        let id = Int64(i)
        files.append(lightFile(id: id, target: "T3", date: "2026-07-03", name: "l\(i)"))
        meta[id] = FITSMetaRecord(fileID: id)
    }

    let ctx = makeAuditContext(files: files, meta: meta)
    let findings = CoolerNotReachingSetpointRule().evaluate(ctx)
    #expect(findings.isEmpty)
}

// MARK: - JSON round-trip

@Test func nightHealthReportJSONRoundTrips() throws {
    let db = try makeMemoryDB()
    for i in 1...5 {
        try insertLight(db: db, target: "J1", date: "2026-01-05", name: "l\(i)", setTemp: -20, ccdTemp: -19.9)
    }

    let report = try NightHealth.report(target: "J1", date: "2026-01-05", db: db, config: AstroConfig())

    let encoder = JSONEncoder()
    let data = try encoder.encode(report)
    let decoded = try JSONDecoder().decode(NightHealthReport.self, from: data)

    #expect(decoded.target == report.target)
    #expect(decoded.date == report.date)
    #expect(decoded.cooler == report.cooler)
    #expect(decoded.focus == report.focus)
}
