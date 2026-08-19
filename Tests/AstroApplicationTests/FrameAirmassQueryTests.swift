@testable import AstroApplication
import AstroCore
import Foundation
import Testing

private func headerJSON(_ cards: [String: String]) -> String {
    let data = try! JSONEncoder().encode(cards)
    return String(data: data, encoding: .utf8)!
}

/// Same fixture shape as `FrameQualityQueryTests.QualityFixture` -- a fresh
/// sqlite-backed `Database`, writing `files`/`fits_meta` rows directly (no
/// scanner, no real FITS bytes on disk). Unlike that fixture, this one never
/// writes a `ratings` row at all: `FrameAirmassQuery.lowAltitudeQC` takes
/// each frame's score directly as a `FrameAirmassScoreInput` (the caller's
/// already-loaded `FrameQualityMetrics.score`), never re-reads it from the
/// index DB itself.
private struct AirmassFixture {
    let dbDir: URL
    let db: Database
    var config = AstroConfig()

    static func make() throws -> AirmassFixture {
        let dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("astro-airmass-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try Database(path: dbDir.appendingPathComponent("test.sqlite").path)
        return AirmassFixture(dbDir: dbDir, db: db)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dbDir)
    }

    /// Registers one scanned light frame with an optional `DATE-OBS` and an
    /// optional plate-solved-in-header RA/Dec (`CRVAL1`/`CRVAL2`, already
    /// degrees -- see `TargetCoordinates.coordinates`'s own doc comment for
    /// why that's the WCS convention rather than the sexagesimal `RA`/`DEC`
    /// fallback). Passing `raDeg`/`decDeg` as `nil` mimics an unsolved
    /// DSLR wide-field frame with no header WCS and no plate solve at all.
    @discardableResult
    func addFrame(
        path: String,
        dateObs: String?,
        raDeg: Double? = nil,
        decDeg: Double? = nil
    ) throws -> Int64 {
        let id = try db.upsertFile(FileRecord(
            path: path, size: 0, mtime: 0, ext: "fit", kind: "fits",
            area: .sessions, target: "M31", sessionDate: "2026-01-15", role: .light, scannedAt: 0
        ))
        var cards: [String: String] = [:]
        if let raDeg, let decDeg {
            cards["CRVAL1"] = String(raDeg)
            cards["CRVAL2"] = String(decDeg)
        }
        try db.upsertFITSMeta(FITSMetaRecord(
            fileID: id,
            dateObs: dateObs,
            headerJSON: cards.isEmpty ? nil : headerJSON(cards)
        ))
        return id
    }
}

@Suite("FrameAirmassQuery")
struct FrameAirmassQueryTests {
    @Test("Fires when the worst-scoring quartile sat meaningfully lower in the sky than the best-scoring quartile")
    func firesOnLowAltitudeWorstQuartile() throws {
        let fixture = try AirmassFixture.make()
        defer { fixture.cleanup() }
        var config = fixture.config
        config.site = SiteRule(latitudeDeg: 45, longitudeDeg: 0)

        // A fixed instant every frame shares -- only RA (hence hour angle,
        // hence altitude) varies between the "low" and "high" groups below,
        // so the expected altitudes can be computed independent of exactly
        // which JD/LST this instant happens to resolve to.
        let dateObs = "2026-01-15T22:00:00"
        let instant = try #require(SessionTimeline.parseDateObs(dateObs))
        let jd = JulianDate.julianDay(instant)
        let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: 0)
        let lstDeg = lst * 15
        let decDeg = 45.0
        // Hour angle 100 deg at dec == lat gives altitude ~24 deg (< 35).
        let lowRA = (lstDeg - 100).truncatingRemainder(dividingBy: 360)
        // Hour angle 20 deg at dec == lat gives altitude ~76 deg.
        let highRA = (lstDeg - 20).truncatingRemainder(dividingBy: 360)

        var inputs: [FrameAirmassScoreInput] = []
        for i in 0..<2 {
            let path = "sessions/M31/2026-01-15/lights/low\(i).fit"
            try fixture.addFrame(path: path, dateObs: dateObs, raDeg: lowRA, decDeg: decDeg)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: -1.0 - Double(i) * 0.1))
        }
        for i in 0..<4 {
            let path = "sessions/M31/2026-01-15/lights/mid\(i).fit"
            try fixture.addFrame(path: path, dateObs: dateObs, raDeg: highRA, decDeg: decDeg)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: Double(i) * 0.01))
        }
        for i in 0..<2 {
            let path = "sessions/M31/2026-01-15/lights/high\(i).fit"
            try fixture.addFrame(path: path, dateObs: dateObs, raDeg: highRA, decDeg: decDeg)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: 1.0 + Double(i) * 0.1))
        }

        let query = FrameAirmassQuery(db: fixture.db, config: config)
        let result = try #require(try query.lowAltitudeQC(frames: inputs))

        let expectedWorstAlt = AltAz.position(raDeg: lowRA, decDeg: decDeg, lstHours: lst, latDeg: 45).altitudeDeg
        let expectedBestAlt = AltAz.position(raDeg: highRA, decDeg: decDeg, lstHours: lst, latDeg: 45).altitudeDeg

        #expect(result.worstQuartileFrameCount == 2)
        #expect(abs(result.worstQuartileMedianAltitudeDeg - expectedWorstAlt) < 0.0001)
        #expect(abs(result.bestQuartileMedianAltitudeDeg - expectedBestAlt) < 0.0001)
        #expect(result.worstQuartileMedianAltitudeDeg < 35)
        #expect(result.bestQuartileMedianAltitudeDeg - result.worstQuartileMedianAltitudeDeg >= 10)
    }

    @Test("A uniform-altitude session never fires -- there is no real gap to report")
    func uniformAltitudeNeverFires() throws {
        let fixture = try AirmassFixture.make()
        defer { fixture.cleanup() }
        var config = fixture.config
        config.site = SiteRule(latitudeDeg: 45, longitudeDeg: 0)

        var inputs: [FrameAirmassScoreInput] = []
        for i in 0..<8 {
            let path = "sessions/M31/2026-01-15/lights/f\(i).fit"
            try fixture.addFrame(path: path, dateObs: "2026-01-15T22:00:00", raDeg: 10, decDeg: 45)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: Double(i) - 4))
        }

        let query = FrameAirmassQuery(db: fixture.db, config: config)
        #expect(try query.lowAltitudeQC(frames: inputs) == nil)
    }

    @Test("A real altitude gap that never dips below 35 deg does not fire")
    func gapAboveThresholdDoesNotFire() throws {
        let fixture = try AirmassFixture.make()
        defer { fixture.cleanup() }
        var config = fixture.config
        config.site = SiteRule(latitudeDeg: 45, longitudeDeg: 0)

        let dateObs = "2026-01-15T22:00:00"
        let instant = try #require(SessionTimeline.parseDateObs(dateObs))
        let jd = JulianDate.julianDay(instant)
        let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: 0)
        let lstDeg = lst * 15
        let decDeg = 45.0
        // Hour angle 40 deg gives ~55 deg altitude; hour angle 10 deg gives
        // ~65 deg -- a real ~10 deg gap, but the worse side never dips under
        // 35 deg, so the line should stay silent (rule part 2 fails).
        let higherLowRA = (lstDeg - 40).truncatingRemainder(dividingBy: 360)
        let higherHighRA = (lstDeg - 10).truncatingRemainder(dividingBy: 360)

        var inputs: [FrameAirmassScoreInput] = []
        for i in 0..<2 {
            let path = "sessions/M31/2026-01-15/lights/low\(i).fit"
            try fixture.addFrame(path: path, dateObs: dateObs, raDeg: higherLowRA, decDeg: decDeg)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: -1.0 - Double(i) * 0.1))
        }
        for i in 0..<4 {
            let path = "sessions/M31/2026-01-15/lights/mid\(i).fit"
            try fixture.addFrame(path: path, dateObs: dateObs, raDeg: higherHighRA, decDeg: decDeg)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: Double(i) * 0.01))
        }
        for i in 0..<2 {
            let path = "sessions/M31/2026-01-15/lights/high\(i).fit"
            try fixture.addFrame(path: path, dateObs: dateObs, raDeg: higherHighRA, decDeg: decDeg)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: 1.0 + Double(i) * 0.1))
        }

        let query = FrameAirmassQuery(db: fixture.db, config: config)
        let result = try query.lowAltitudeQC(frames: inputs)
        #expect(result == nil)
    }

    @Test("No configured or derivable site reports nil, never a crash")
    func noSiteReportsNil() throws {
        let fixture = try AirmassFixture.make()
        defer { fixture.cleanup() }
        // `fixture.config` is a bare `AstroConfig()` -- no `site`, no
        // `sites`, and no frame carries `SITELAT`/`SITELONG` either, so
        // `Planner.resolveSite` itself resolves to `SiteRule(nil, nil)`.
        var inputs: [FrameAirmassScoreInput] = []
        for i in 0..<8 {
            let path = "sessions/M31/2026-01-15/lights/f\(i).fit"
            try fixture.addFrame(path: path, dateObs: "2026-01-15T22:00:00", raDeg: 10, decDeg: 45)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: Double(i) - 4))
        }

        let query = FrameAirmassQuery(db: fixture.db, config: fixture.config)
        #expect(try query.altitudeDeg(relativePaths: inputs.map(\.relativePath)).isEmpty)
        #expect(try query.lowAltitudeQC(frames: inputs) == nil)
    }

    @Test("Frames with no resolvable RA/Dec (an unsolved DSLR series) report nil, never a crash")
    func unsolvedFramesReportNil() throws {
        let fixture = try AirmassFixture.make()
        defer { fixture.cleanup() }
        var config = fixture.config
        config.site = SiteRule(latitudeDeg: 45, longitudeDeg: 0)

        var inputs: [FrameAirmassScoreInput] = []
        for i in 0..<8 {
            let path = "sessions/M31/2026-01-15/lights/f\(i).fit"
            // No `raDeg`/`decDeg` at all -- mimics a DSLR wide-field frame
            // that was never plate-solved and carries no header WCS.
            try fixture.addFrame(path: path, dateObs: "2026-01-15T22:00:00")
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: Double(i) - 4))
        }

        let query = FrameAirmassQuery(db: fixture.db, config: config)
        #expect(try query.altitudeDeg(relativePaths: inputs.map(\.relativePath)).isEmpty)
        #expect(try query.lowAltitudeQC(frames: inputs) == nil)
    }

    @Test("No frame has a score yet reports nil, never a crash")
    func noScoresYetReportsNil() throws {
        let fixture = try AirmassFixture.make()
        defer { fixture.cleanup() }
        var config = fixture.config
        config.site = SiteRule(latitudeDeg: 45, longitudeDeg: 0)

        var inputs: [FrameAirmassScoreInput] = []
        for i in 0..<8 {
            let path = "sessions/M31/2026-01-15/lights/f\(i).fit"
            try fixture.addFrame(path: path, dateObs: "2026-01-15T22:00:00", raDeg: 10, decDeg: 45)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: nil))
        }

        let query = FrameAirmassQuery(db: fixture.db, config: config)
        #expect(try query.lowAltitudeQC(frames: inputs) == nil)
    }

    @Test("Fewer than 4 scored-and-resolved frames reports nil -- too few for a real quartile split")
    func tooFewFramesReportsNil() throws {
        let fixture = try AirmassFixture.make()
        defer { fixture.cleanup() }
        var config = fixture.config
        config.site = SiteRule(latitudeDeg: 45, longitudeDeg: 0)

        var inputs: [FrameAirmassScoreInput] = []
        for i in 0..<3 {
            let path = "sessions/M31/2026-01-15/lights/f\(i).fit"
            try fixture.addFrame(path: path, dateObs: "2026-01-15T22:00:00", raDeg: 10, decDeg: 45)
            inputs.append(FrameAirmassScoreInput(relativePath: path, score: Double(i)))
        }

        let query = FrameAirmassQuery(db: fixture.db, config: config)
        #expect(try query.lowAltitudeQC(frames: inputs) == nil)
    }

    @Test("altitudeDeg cross-checks bit-for-bit against a direct SiderealTime/AltAz call for a fixed instant")
    func altitudeCrossChecksDirectEngineCall() throws {
        let fixture = try AirmassFixture.make()
        defer { fixture.cleanup() }
        var config = fixture.config
        config.site = SiteRule(latitudeDeg: 51.5, longitudeDeg: -0.1)

        let dateObs = "2026-06-21T23:15:00"
        let raDeg = 279.23
        let decDeg = 38.78
        let path = "sessions/M31/2026-01-15/lights/cross-check.fit"
        try fixture.addFrame(path: path, dateObs: dateObs, raDeg: raDeg, decDeg: decDeg)

        let query = FrameAirmassQuery(db: fixture.db, config: config)
        let altitudes = try query.altitudeDeg(relativePaths: [path])
        let measured = try #require(altitudes[path])

        let instant = try #require(SessionTimeline.parseDateObs(dateObs))
        let jd = JulianDate.julianDay(instant)
        let lst = SiderealTime.lstHours(julianDay: jd, longitudeDeg: -0.1)
        let expected = AltAz.position(raDeg: raDeg, decDeg: decDeg, lstHours: lst, latDeg: 51.5).altitudeDeg

        #expect(measured == expected)
    }
}
