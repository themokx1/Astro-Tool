import Foundation
import Testing
@testable import AstroCore

// MARK: - Fixture helpers

private func headerJSON(_ cards: [String: String]) -> String {
    let data = try! JSONEncoder().encode(cards)
    return String(data: data, encoding: .utf8)!
}

private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

/// Inserts one rated LIGHT frame for `target`/`date`: a `FileRecord` (with a
/// unique fake inode so same-exptime frames never collapse into one under
/// `FrameSet`'s dedup, same convention as `EquipmentProfileTests`), its
/// `FITSMetaRecord` (camera/gain/offset/exptime + `BAYERPAT` header when
/// `bayerPattern` is given), and a `RatingRecord` carrying the per-Bayer
/// background medians (`bg00`/`bg01`/`bg10`/`bg11` at CFA positions
/// 00/01/10/11) plus `saturatedFraction`.
@discardableResult
private func insertRatedLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    camera: String? = "ASI2600MC",
    gain: Double? = 100,
    offset: Double? = 50,
    exptime: Double? = 120,
    bayerPattern: String? = "RGGB",
    bg00: Double? = nil,
    bg01: Double? = nil,
    bg10: Double? = nil,
    bg11: Double? = nil,
    saturatedFraction: Double? = 0
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

    var cards: [String: String] = [:]
    if let bayerPattern { cards["BAYERPAT"] = "'\(bayerPattern)'" }
    try db.upsertFITSMeta(
        FITSMetaRecord(
            fileID: fileID, exptime: exptime, gain: gain, offset: offset,
            instrume: camera, egain: 1.0,
            headerJSON: cards.isEmpty ? nil : headerJSON(cards)
        )
    )
    try db.upsertRating(
        RatingRecord(
            fileID: fileID, background: bg00 ?? bg11, saturatedFraction: saturatedFraction,
            score: 0, ratedAt: 1_700_000_200, inputSig: "sig-\(name)",
            bg00: bg00, bg01: bg01, bg10: bg10, bg11: bg11
        )
    )
    return fileID
}

/// bias 500 ADU, egain 1.0 -- the fixtures' `FITSMetaRecord.egain` above is
/// always 1.0, so `B_ch = max(0, (median_ch − 500))/exptime` reduces to
/// simple arithmetic that's easy to hand-verify per test.
private func insertProfile(
    db: Database, camera: String = "ASI2600MC", gain: Double? = 100, offset: Double? = 50,
    biasLevelADU: Double = 500, readNoiseE: Double = 1.3, egain: Double = 1.0
) throws {
    try db.upsertSensorProfile(
        SensorProfileRecord(
            camera: camera, gain: gain, offset: offset, biasLevelADU: biasLevelADU,
            readNoiseE: readNoiseE, egain: egain, measuredAt: 1_700_000_000
        )
    )
}

/// The "NGC7000-like" reference fixture used by several tests: `R=1.3`,
/// weakest channel (B, per RGGB) `= 0.081 e⁻/s/px` at a 120s current sub --
/// `R position(00)=700` → rate 1.667, `G(01/10)=650` → rate 1.25,
/// `B(11)=509.72` → rate `(509.72−500)/120 = 0.081` exactly, the weakest.
@discardableResult
private func makeReferenceFixture(
    db: Database, target: String = "NGC7000", date: String = "2026-08-01",
    exptime: Double = 120, bg11: Double = 509.72, saturatedFraction: Double = 0
) throws -> Int64 {
    try insertProfile(db: db)
    return try insertRatedLight(
        db: db, target: target, date: date, name: "a", exptime: exptime,
        bg00: 700, bg01: 650, bg10: 650, bg11: bg11, saturatedFraction: saturatedFraction
    )
}

// MARK: - Formula exactness

@Test func exposureAdvisorComputesOptimalSubSecondsFromExactFormula() throws {
    let db = try makeMemoryDB()
    try makeReferenceFixture(db: db)

    let advice = try ExposureAdvisor.advise(target: "NGC7000", db: db, config: AstroConfig())

    let expected = 1.69 / (0.081 * 0.1025) // R²/(B×((1.05)²−1))
    let optimal = try #require(advice.optimalSubSeconds)
    #expect(abs(optimal - expected) < 0.05)
    #expect(advice.notAvailableReason == nil)
}

@Test func exposureAdvisorComputesC10VariantIndependentlyOfConfiguredC() throws {
    let db = try makeMemoryDB()
    var config = AstroConfig()
    config.expose.noiseContributionC = 0.05
    try makeReferenceFixture(db: db)

    let advice = try ExposureAdvisor.advise(target: "NGC7000", db: db, config: config)

    let expectedC10 = 1.69 / (0.081 * 0.21) // R²/(B×((1.10)²−1))
    let c10 = try #require(advice.recommendedSubSecondsC10)
    #expect(abs(c10 - expectedC10) < 0.05)
}

@Test func exposureAdvisorSelectsTheLowestRateChannelAsWeakest() throws {
    let db = try makeMemoryDB()
    try makeReferenceFixture(db: db)

    let advice = try ExposureAdvisor.advise(target: "NGC7000", db: db, config: AstroConfig())

    // R rate 1.667, G rate 1.25, B rate 0.081 -- B is lowest.
    #expect(advice.weakestChannel == "B")
    let skyRate = try #require(advice.skyRateEPerSPx)
    #expect(abs(skyRate - 0.081) < 0.001)
}

@Test func exposureAdvisorComputesCurrentReadNoiseSharePercent() throws {
    let db = try makeMemoryDB()
    try makeReferenceFixture(db: db)

    let advice = try ExposureAdvisor.advise(target: "NGC7000", db: db, config: AstroConfig())

    // share = (1 − √(B·t/(R²+B·t))) × 100 = (1 − √(9.72/11.41)) × 100 ≈ 7.70%
    let expected = (1 - (9.72 / 11.41).squareRoot()) * 100
    let share = try #require(advice.currentReadNoiseSharePercent)
    #expect(abs(share - expected) < 0.01)
    #expect(share > 7.0 && share < 8.5, "expected roughly 7.7% per the formula, got \(share)")
}

// MARK: - Caps

@Test func exposureAdvisorCapsByMaxSubSecondsWithCapReason() throws {
    let db = try makeMemoryDB()
    try makeReferenceFixture(db: db) // current 120s, optimal ≈203.5s
    var config = AstroConfig()
    config.expose.maxSubSeconds = 150 // between current and optimal

    let advice = try ExposureAdvisor.advise(target: "NGC7000", db: db, config: config)

    #expect(advice.capReason == "maxSubSeconds")
    #expect(advice.recommendedSubSeconds == 150)
    #expect(advice.advice.contains { $0.contains("guiding") })
}

@Test func exposureAdvisorCapsAtCurrentSubWhenAlreadySaturating() throws {
    let db = try makeMemoryDB()
    // current sub 120s, optimal ≈203.5s > current -- but the session is
    // already saturating at 120s, so must not recommend going longer.
    try makeReferenceFixture(db: db, saturatedFraction: 0.01)

    let advice = try ExposureAdvisor.advise(target: "NGC7000", db: db, config: AstroConfig())

    #expect(advice.capReason == "szaturáció")
    #expect(advice.recommendedSubSeconds == 120)
    #expect(advice.advice.contains { $0.contains("szaturál") })
}

@Test func exposureAdvisorReportsAlreadyFineWhenCurrentIsCloseToRecommended() throws {
    let db = try makeMemoryDB()
    // bg11 chosen so B = (515.831−500)/120 ≈ 0.13193 → optimal =
    // 1.69/(0.13193×0.1025) ≈ 125s -- current 120s is 96% of that, above
    // the 90% "already fine" threshold, well under the default 300s cap.
    try makeReferenceFixture(db: db, exptime: 120, bg11: 515.831)

    let advice = try ExposureAdvisor.advise(target: "NGC7000", db: db, config: AstroConfig())

    let optimal = try #require(advice.optimalSubSeconds)
    #expect(abs(optimal - 125) < 1)
    #expect(advice.capReason == nil)
    #expect(advice.advice.contains { $0.contains("rendben van") })
}

// MARK: - n/a refusal paths

@Test func exposureAdvisorRefusesWhenNoSensorProfileForTheCombo() throws {
    let db = try makeMemoryDB()
    // Rated, has BAYERPAT, but no sensor_profile row was ever measured.
    try insertRatedLight(
        db: db, target: "M42", date: "2026-08-01", name: "a",
        bg00: 700, bg01: 650, bg10: 650, bg11: 510
    )

    let advice = try ExposureAdvisor.advise(target: "M42", db: db, config: AstroConfig())

    #expect(advice.optimalSubSeconds == nil)
    let reason = try #require(advice.notAvailableReason)
    #expect(reason.contains("sensor --measure"))
}

@Test func exposureAdvisorRefusesWhenRatedFramesHaveNoPerBayerData() throws {
    let db = try makeMemoryDB()
    try insertProfile(db: db)
    // Rated (score/background present) but bg00..11 all nil -- rated before
    // R7-B1 introduced the per-Bayer columns.
    try insertRatedLight(
        db: db, target: "M42", date: "2026-08-01", name: "a",
        bg00: nil, bg01: nil, bg10: nil, bg11: nil
    )

    let advice = try ExposureAdvisor.advise(target: "M42", db: db, config: AstroConfig())

    #expect(advice.optimalSubSeconds == nil)
    let reason = try #require(advice.notAvailableReason)
    #expect(reason.contains("astrotool rate"))
}

@Test func exposureAdvisorRefusesForCameraWithNoBayerPattern() throws {
    let db = try makeMemoryDB()
    try insertProfile(db: db, camera: "Canon EOS Ra")
    // No BAYERPAT header at all -- mono/DSLR.
    try insertRatedLight(
        db: db, target: "M31", date: "2026-08-01", name: "a", camera: "Canon EOS Ra",
        bayerPattern: nil, bg00: 700, bg01: 650, bg10: 650, bg11: 510
    )

    let advice = try ExposureAdvisor.advise(target: "M31", db: db, config: AstroConfig())

    #expect(advice.optimalSubSeconds == nil)
    let reason = try #require(advice.notAvailableReason)
    #expect(reason.contains("Canon EOS Ra"))
}

// MARK: - Relative SNR (needs no sky data)

@Test func exposureAdvisorSNRPlus10PercentHoursForTenHoursOfIntegration() throws {
    let db = try makeMemoryDB()
    // 10 hours (36000s) of usable integration, spread over enough distinct
    // frames -- unrated is fine, the SNR section needs no rating at all.
    for i in 0..<10 {
        try insertRatedLight(
            db: db, target: "M45", date: "2026-08-01", name: "f\(i)", exptime: 3600,
            bg00: nil, bg01: nil, bg10: nil, bg11: nil
        )
    }

    let advice = try ExposureAdvisor.advise(target: "M45", db: db, config: AstroConfig())

    #expect(abs(advice.totalUsableSeconds - 36000) < 1)
    #expect(abs(advice.snrPlus10PercentHours - 2.1) < 0.01)
}

@Test func exposureAdvisorSNRPlus3hMultiplierMatchesSquareRootFormula() throws {
    let db = try makeMemoryDB()
    for i in 0..<10 {
        try insertRatedLight(
            db: db, target: "M45", date: "2026-08-01", name: "f\(i)", exptime: 3600,
            bg00: nil, bg01: nil, bg10: nil, bg11: nil
        )
    }

    let advice = try ExposureAdvisor.advise(target: "M45", db: db, config: AstroConfig())

    let expected = (13.0 / 10.0).squareRoot() // (T+3h)/T with T=10h
    let multiplier = try #require(advice.snrPlus3hMultiplier)
    #expect(abs(multiplier - expected) < 0.0001)
}

// MARK: - adviseAll

@Test func exposureAdvisorAdviseAllIncludesEveryTargetWithUsableLightsAndSkipsTargetsWithNone() throws {
    let db = try makeMemoryDB()
    try makeReferenceFixture(db: db, target: "NGC7000")

    // A target whose only light frame sits under a Reject/ triage
    // subdirectory -- FrameSet.lightBuckets buckets it as `.rejected`, never
    // `.usable`, so adviseAll must skip this target entirely.
    let rejectedPath = "sessions/M13/2026-08-01/lights/Reject/bad.fit"
    let fileID = try db.upsertFile(
        FileRecord(
            path: rejectedPath, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: "M13", sessionDate: "2026-08-01", role: .light,
            scannedAt: 1_700_000_100
        )
    )
    try db.upsertFITSMeta(FITSMetaRecord(fileID: fileID, exptime: 60, instrume: "ASI2600MC"))

    let results = try ExposureAdvisor.adviseAll(db: db, config: AstroConfig())

    #expect(results.map(\.target) == ["NGC7000"])
}
