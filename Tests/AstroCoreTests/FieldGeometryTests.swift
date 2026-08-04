import Foundation
import Testing
@testable import AstroCore

/// `FieldGeometry` reads only `Database` rows (files + fits_meta, the same
/// `header_json` blob every other Sky/Stats query reads) -- these tests
/// build exactly those rows directly, same spirit as `NightHealthTests`'s
/// own fixture helper.
private func headerJSON(_ cards: [String: String]) -> String {
    let data = try! JSONEncoder().encode(cards)
    return String(data: data, encoding: .utf8)!
}

private func makeMemoryDB() throws -> Database {
    try Database(path: ":memory:")
}

/// Inserts one light-frame row (`files` + `fits_meta`) and returns its
/// `fileID`. `cdMatrix`/`xpixsz`+`focallen` are mutually exclusive knobs for
/// the two `frameField` scale sources; omit both for a bare-CRVAL frame.
@discardableResult
private func insertLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    raDeg: Double? = nil,
    decDeg: Double? = nil,
    cdMatrix: (cd11: Double, cd12: Double, cd21: Double, cd22: Double)? = nil,
    xpixsz: Double? = nil,
    focallen: Double? = nil,
    naxis1: Int? = nil,
    naxis2: Int? = nil,
    exptime: Double? = 60,
    solvedRA: Double? = nil,
    solvedDec: Double? = nil,
    solvedScaleArcsec: Double? = nil,
    solvedRotationDeg: Double? = nil
) throws -> Int64 {
    let path = "sessions/\(target)/\(date)/lights/\(name).fit"
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light,
            scannedAt: 1_700_000_100
        )
    )
    // Same fake-inode trick `NightHealthTests`/`SessionQualityTests` use:
    // these synthetic rows have no real file to `stat()`, so without a
    // per-row inode `FrameSet`'s fallback dedup key (same exptime, no
    // DATE-OBS) would collapse every frame in one session down to a single
    // "canonical" copy.
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)

    var cards: [String: String] = [:]
    if let raDeg { cards["CRVAL1"] = String(raDeg) }
    if let decDeg { cards["CRVAL2"] = String(decDeg) }
    if let cdMatrix {
        cards["CD1_1"] = String(cdMatrix.cd11)
        cards["CD1_2"] = String(cdMatrix.cd12)
        cards["CD2_1"] = String(cdMatrix.cd21)
        cards["CD2_2"] = String(cdMatrix.cd22)
    }
    if let xpixsz { cards["XPIXSZ"] = String(xpixsz) }
    if let focallen { cards["FOCALLEN"] = String(focallen) }

    try db.upsertFITSMeta(
        FITSMetaRecord(
            fileID: fileID, exptime: exptime, naxis1: naxis1, naxis2: naxis2,
            headerJSON: cards.isEmpty ? nil : headerJSON(cards)
        )
    )
    if solvedRA != nil || solvedDec != nil || solvedScaleArcsec != nil || solvedRotationDeg != nil {
        try db.updateSolvedWCS(fileID: fileID, ra: solvedRA, dec: solvedDec, scale: solvedScaleArcsec, rotation: solvedRotationDeg)
    }
    return fileID
}

// MARK: - frameField

@Test func frameFieldReturnsNilWithoutCRVAL() {
    let json = headerJSON(["FOCALLEN": "300", "XPIXSZ": "3.76"])
    #expect(FieldGeometry.frameField(headerJSON: json, naxis1: nil, naxis2: nil) == nil)
}

@Test func frameFieldReturnsNilWithoutHeaderJSONAtAll() {
    #expect(FieldGeometry.frameField(headerJSON: nil, naxis1: nil, naxis2: nil) == nil)
}

@Test func frameFieldParsesCRVALWithNoScaleSource() throws {
    let json = headerJSON(["CRVAL1": "83.633083", "CRVAL2": "22.0145"])
    let field = try #require(FieldGeometry.frameField(headerJSON: json, naxis1: nil, naxis2: nil))
    #expect(abs(field.raDeg - 83.633083) < 1e-6)
    #expect(abs(field.decDeg - 22.0145) < 1e-6)
    #expect(field.pixelScaleArcsec == nil)
    #expect(field.rotationDeg == nil)
    #expect(field.fovWidthDeg == nil)
    #expect(field.fovHeightDeg == nil)
}

/// A plain rotation matrix scaled by `scaleDeg` (`CD1_1 = s·cosθ, CD1_2 =
/// s·sinθ, CD2_1 = -s·sinθ, CD2_2 = s·cosθ`) has `det = s²` regardless of
/// θ -- so `sqrt(det)*3600` recovers exactly the injected arcsec/px scale,
/// and `atan2(CD1_2, CD1_1)` recovers exactly θ, letting this test assert
/// both a known scale AND a known rotation from one constructed matrix.
@Test func frameFieldComputesRotationAndScaleFromCDMatrix() throws {
    let scaleArcsecPerPixel = 1.2
    let scaleDeg = scaleArcsecPerPixel / 3600
    let thetaDeg = 37.0
    let thetaRad = thetaDeg * .pi / 180
    let cd = (
        cd11: scaleDeg * cos(thetaRad), cd12: scaleDeg * sin(thetaRad),
        cd21: -scaleDeg * sin(thetaRad), cd22: scaleDeg * cos(thetaRad)
    )
    let json = headerJSON([
        "CRVAL1": "100.0", "CRVAL2": "20.0",
        "CD1_1": String(cd.cd11), "CD1_2": String(cd.cd12),
        "CD2_1": String(cd.cd21), "CD2_2": String(cd.cd22),
    ])

    let field = try #require(FieldGeometry.frameField(headerJSON: json, naxis1: 3600, naxis2: 2400))
    let scale = try #require(field.pixelScaleArcsec)
    #expect(abs(scale - scaleArcsecPerPixel) < 1e-6)
    let rotation = try #require(field.rotationDeg)
    #expect(abs(rotation - thetaDeg) < 1e-6)
    let fovWidth = try #require(field.fovWidthDeg)
    #expect(abs(fovWidth - (3600.0 * scaleArcsecPerPixel / 3600)) < 1e-6)
    let fovHeight = try #require(field.fovHeightDeg)
    #expect(abs(fovHeight - (2400.0 * scaleArcsecPerPixel / 3600)) < 1e-6)
}

@Test func frameFieldFallsBackToXpixszFocallenScaleWhenNoCDMatrix() throws {
    let json = headerJSON(["CRVAL1": "10.0", "CRVAL2": "-5.0", "XPIXSZ": "3.76", "FOCALLEN": "302"])
    let field = try #require(FieldGeometry.frameField(headerJSON: json, naxis1: nil, naxis2: nil))
    let expectedScale = 206.265 * 3.76 / 302.0
    let scale = try #require(field.pixelScaleArcsec)
    #expect(abs(scale - expectedScale) < 1e-6)
    #expect(field.rotationDeg == nil)
}

// MARK: - frameField solved-column fallback (R7-1)

@Test func frameFieldFallsBackToSolvedColumnsWhenHeaderHasNoWCSAtAll() throws {
    // A wide-field Canon CR3 frame: no FITS header at all (nil headerJSON),
    // but `PlateSolver` has since persisted a solved coordinate + scale +
    // rotation.
    let field = try #require(FieldGeometry.frameField(
        headerJSON: nil, naxis1: 6000, naxis2: 4000,
        solvedRA: 56.75, solvedDec: 24.1, solvedScaleArcsec: 3.0, solvedRotationDeg: 12.0
    ))
    #expect(abs(field.raDeg - 56.75) < 1e-9)
    #expect(abs(field.decDeg - 24.1) < 1e-9)
    #expect(field.pixelScaleArcsec == 3.0)
    #expect(field.rotationDeg == 12.0)
    let fovWidth = try #require(field.fovWidthDeg)
    #expect(abs(fovWidth - (6000.0 * 3.0 / 3600)) < 1e-9)
}

@Test func frameFieldPrefersHeaderWCSOverSolvedColumnsWhenBothPresent() throws {
    let json = headerJSON(["CRVAL1": "100.0", "CRVAL2": "20.0"])
    let field = try #require(FieldGeometry.frameField(
        headerJSON: json, naxis1: nil, naxis2: nil,
        solvedRA: 999, solvedDec: 999, solvedScaleArcsec: 999, solvedRotationDeg: 999
    ))
    #expect(abs(field.raDeg - 100.0) < 1e-9)
    #expect(abs(field.decDeg - 20.0) < 1e-9)
    #expect(field.pixelScaleArcsec == nil, "the header branch has no CD/xpixsz+focallen here, must not pick up the solved scale")
}

@Test func frameFieldReturnsNilWhenNeitherHeaderNorSolvedColumnsResolve() {
    #expect(FieldGeometry.frameField(headerJSON: nil, naxis1: nil, naxis2: nil) == nil)
    #expect(FieldGeometry.frameField(headerJSON: nil, naxis1: nil, naxis2: nil, solvedRA: 10.0) == nil, "solvedDec missing")
}

// MARK: - panels(target:db:config:)

@Test func panelsReportsSingleFieldAsNotMosaic() throws {
    let db = try makeMemoryDB()
    try insertLight(db: db, target: "T1", date: "2026-06-01", name: "l1", raDeg: 100.0, decDeg: 20.0)

    let report = try FieldGeometry.panels(target: "T1", db: db, config: AstroConfig())
    #expect(report.panels.count == 1)
    #expect(report.isMosaic == false)
    #expect(report.isUnbalanced == false)
    #expect(report.panels[0].frameCount == 1)
}

@Test func panelsClustersTwoGroupsThreeDegreesApartWithOneDegreeFOVIntoTwoPanels() throws {
    let db = try makeMemoryDB()
    // A rotation-free CD matrix with scale exactly 1"/px, NAXIS 3600 -> an
    // exact 1.0deg FOV width on every frame, so the join-threshold is
    // exactly 0.5deg.
    let cd = (cd11: 1.0 / 3600, cd12: 0.0, cd21: 0.0, cd22: 1.0 / 3600)

    for (i, ra) in [100.0, 100.01, 100.02].enumerated() {
        try insertLight(
            db: db, target: "MOS", date: "2026-06-01", name: "a\(i)",
            raDeg: ra, decDeg: 0.0, cdMatrix: cd, naxis1: 3600, naxis2: 3600
        )
    }
    for (i, ra) in [103.0, 103.01, 103.02].enumerated() {
        try insertLight(
            db: db, target: "MOS", date: "2026-06-01", name: "b\(i)",
            raDeg: ra, decDeg: 0.0, cdMatrix: cd, naxis1: 3600, naxis2: 3600
        )
    }

    let report = try FieldGeometry.panels(target: "MOS", db: db, config: AstroConfig())
    #expect(report.isMosaic)
    #expect(report.panels.count == 2)
    #expect(report.panels.map(\.frameCount).sorted() == [3, 3])
    #expect(report.panels[0].label == "A")
    #expect(report.panels[1].label == "B")
}

@Test func panelsFlagsUnbalancedIntegrationAcrossPanels() throws {
    let db = try makeMemoryDB()
    // Two clusters far enough apart (10deg) to always land in separate
    // panels regardless of FOV/threshold subtlety.
    try insertLight(db: db, target: "UNBAL", date: "2026-06-01", name: "a0", raDeg: 10.0, decDeg: 0.0, exptime: 3900)
    try insertLight(db: db, target: "UNBAL", date: "2026-06-01", name: "a1", raDeg: 10.01, decDeg: 0.0, exptime: 3900)
    try insertLight(db: db, target: "UNBAL", date: "2026-06-01", name: "b0", raDeg: 20.0, decDeg: 0.0, exptime: 2100)

    let report = try FieldGeometry.panels(target: "UNBAL", db: db, config: AstroConfig())
    #expect(report.panels.count == 2)
    #expect(report.isMosaic)
    #expect(report.isUnbalanced)

    let panelA = try #require(report.panels.first { $0.label == "A" })
    let panelB = try #require(report.panels.first { $0.label == "B" })
    #expect(abs(panelA.integrationSeconds - 7800) < 0.01)
    #expect(abs(panelB.integrationSeconds - 2100) < 0.01)
}

@Test func panelsDoesNotFlagBalancedIntegrationAcrossPanels() throws {
    let db = try makeMemoryDB()
    try insertLight(db: db, target: "BAL", date: "2026-06-01", name: "a0", raDeg: 10.0, decDeg: 0.0, exptime: 3000)
    try insertLight(db: db, target: "BAL", date: "2026-06-01", name: "b0", raDeg: 20.0, decDeg: 0.0, exptime: 3000)

    let report = try FieldGeometry.panels(target: "BAL", db: db, config: AstroConfig())
    #expect(report.panels.count == 2)
    #expect(report.isUnbalanced == false)
}

@Test func panelsVectorMeanHandlesRAWraparoundCorrectly() throws {
    let db = try makeMemoryDB()
    // No CD/xpixsz+focallen on either frame -> no known FOV anywhere ->
    // fallback 1.0deg join threshold; the two centers are only 0.2deg apart
    // (359.9 -> 0.1 wrapping through 0/360), well within it, so this is one
    // panel whose naive-mean RA would badly misplace to ~180deg.
    try insertLight(db: db, target: "WRAP", date: "2026-06-01", name: "w0", raDeg: 359.9, decDeg: 0.0)
    try insertLight(db: db, target: "WRAP", date: "2026-06-01", name: "w1", raDeg: 0.1, decDeg: 0.0)

    let report = try FieldGeometry.panels(target: "WRAP", db: db, config: AstroConfig())
    #expect(report.panels.count == 1)
    let center = report.panels[0].centerRaDeg
    #expect(center < 0.5 || center > 359.5)
}

@Test func panelsBuildsFieldsFromSolvedColumnsWhenNoFrameHasHeaderWCS() throws {
    // Every frame here is a wide-field CR3 with no FITS header (headerJSON
    // nil) -- only `PlateSolver`'s persisted solved_* columns carry a
    // coordinate. `panels(target:db:config:)` must still cluster them.
    let db = try makeMemoryDB()
    try insertLight(db: db, target: "CR3T", date: "2026-06-01", name: "a0", solvedRA: 10.0, solvedDec: 0.0)
    try insertLight(db: db, target: "CR3T", date: "2026-06-01", name: "a1", solvedRA: 10.01, solvedDec: 0.0)

    let report = try FieldGeometry.panels(target: "CR3T", db: db, config: AstroConfig())
    #expect(report.panels.count == 1)
    #expect(report.panels[0].frameCount == 2)
    #expect(report.isMosaic == false)
}

@Test func panelsReturnsEmptyReportWhenTargetHasNoUsableLightsAtAll() throws {
    let db = try makeMemoryDB()
    let report = try FieldGeometry.panels(target: "NOPE", db: db, config: AstroConfig())
    #expect(report.panels.isEmpty)
    #expect(report.isMosaic == false)
    #expect(report.isUnbalanced == false)
}

@Test func panelReportJSONRoundTrips() throws {
    let db = try makeMemoryDB()
    try insertLight(db: db, target: "RT", date: "2026-06-01", name: "l1", raDeg: 50.0, decDeg: 10.0, exptime: 120)

    let report = try FieldGeometry.panels(target: "RT", db: db, config: AstroConfig())
    let data = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(PanelReport.self, from: data)
    #expect(decoded.target == report.target)
    #expect(decoded.panels.count == report.panels.count)
    #expect(decoded.isMosaic == report.isMosaic)
    #expect(decoded.isUnbalanced == report.isUnbalanced)
}
