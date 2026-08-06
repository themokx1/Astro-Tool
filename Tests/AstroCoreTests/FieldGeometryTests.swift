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

// MARK: - dominantFOV(db:config:) (R10-B4)

/// Inserts one light frame carrying BOTH a derivable `EquipmentProfile`
/// fingerprint (`instrume`/`focallen`/`xpixsz` as actual `fits_meta`
/// COLUMNS -- what `EquipmentProfile.fingerprint` reads) AND, optionally, a
/// WCS solution (`CRVAL`+ a rotation-free `CD` matrix in `header_json` --
/// what `frameField` reads) -- `insertLight` above only ever populates the
/// SECOND half (its own `xpixsz`/`focallen` parameters land in the header
/// JSON blob, for `frameField`'s OWN xpixsz/focallen fallback-scale path,
/// never the `fits_meta` columns `EquipmentProfile` reads), so
/// `dominantFOV`'s tests need this separate, combined fixture.
///
/// `scaleArcsecPerPixel: nil` omits the CD matrix entirely (CRVAL alone, no
/// scale) -- a frame with a coordinate but no derivable FOV, for the "some
/// dominant-fingerprint frames have no FOV of their own" cases.
@discardableResult
private func insertFingerprintedLight(
    db: Database,
    target: String,
    date: String,
    name: String,
    instrume: String,
    focallen: Double,
    xpixsz: Double,
    raDeg: Double = 100.0,
    decDeg: Double = 20.0,
    scaleArcsecPerPixel: Double? = 1.0,
    naxis1: Int = 3600,
    naxis2: Int = 2400
) throws -> Int64 {
    let path = "sessions/\(target)/\(date)/lights/\(name).fit"
    let fileID = try db.upsertFile(
        FileRecord(
            path: path, size: 1024, mtime: 1_700_000_000, ext: "fit", kind: "fits",
            area: .sessions, target: target, sessionDate: date, role: .light,
            scannedAt: 1_700_000_100
        )
    )
    // Same fake-inode trick as `insertLight` above -- distinct per-row
    // inodes so `FrameSet`'s dedup never collapses these synthetic rows.
    try db.backfillInode(id: fileID, inode: fileID, nlink: 1)

    var cards: [String: String] = ["CRVAL1": String(raDeg), "CRVAL2": String(decDeg)]
    if let scaleArcsecPerPixel {
        let scaleDeg = scaleArcsecPerPixel / 3600
        cards["CD1_1"] = String(scaleDeg)
        cards["CD1_2"] = "0"
        cards["CD2_1"] = "0"
        cards["CD2_2"] = String(scaleDeg)
    }

    try db.upsertFITSMeta(
        FITSMetaRecord(
            fileID: fileID, exptime: 60, instrume: instrume, focallen: focallen,
            naxis1: naxis1, naxis2: naxis2, xpixsz: xpixsz, headerJSON: headerJSON(cards)
        )
    )
    return fileID
}

@Test func dominantFOVReturnsNilWhenLibraryHasNoUsableLightsAtAll() throws {
    let db = try makeMemoryDB()
    #expect(try FieldGeometry.dominantFOV(db: db, config: AstroConfig()) == nil)
}

@Test func dominantFOVReturnsNilWhenNoFrameHasADerivableFingerprint() throws {
    let db = try makeMemoryDB()
    // Coordinate/FOV fully resolvable, but with NO camera/focal length/
    // pixel size at all -- `EquipmentProfile.fingerprint` returns `nil` for
    // every one of these, so `EquipmentProfile.dominant` has an empty
    // `counts` to pick from.
    try insertLight(db: db, target: "T1", date: "2026-06-01", name: "l0", raDeg: 100.0, decDeg: 20.0)
    try insertLight(db: db, target: "T1", date: "2026-06-01", name: "l1", raDeg: 100.0, decDeg: 20.0)

    #expect(try FieldGeometry.dominantFOV(db: db, config: AstroConfig()) == nil)
}

@Test func dominantFOVReturnsNilWhenDominantFingerprintFramesHaveNoResolvableFOV() throws {
    let db = try makeMemoryDB()
    // A real fingerprint on every frame, but none of them carries a CD
    // matrix (or XPIXSZ/FOCALLEN header cards, or solved columns) -- so
    // `frameField`'s `fovWidthDeg`/`fovHeightDeg` are `nil` for all of them.
    for i in 0..<3 {
        try insertFingerprintedLight(
            db: db, target: "T2", date: "2026-06-02", name: "l\(i)",
            instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76, scaleArcsecPerPixel: nil
        )
    }

    #expect(try FieldGeometry.dominantFOV(db: db, config: AstroConfig()) == nil)
}

@Test func dominantFOVComputesMedianWidthAndHeightAcrossDominantFingerprintFrames() throws {
    let db = try makeMemoryDB()
    // Three frames, one setup, three scales (1.0/1.2/1.4 arcsec/px) ->
    // width = naxis1(3600) * scale / 3600 = scale itself in degrees;
    // height = naxis2(2400) * scale / 3600 = (2/3) * scale.
    for scale in [1.0, 1.2, 1.4] {
        try insertFingerprintedLight(
            db: db, target: "T3", date: "2026-06-03", name: "s\(scale)",
            instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76, scaleArcsecPerPixel: scale
        )
    }

    let fov = try #require(try FieldGeometry.dominantFOV(db: db, config: AstroConfig()))
    #expect(abs(fov.widthDeg - 1.2) < 1e-9)
    #expect(abs(fov.heightDeg - 0.8) < 1e-9)
}

@Test func dominantFOVIgnoresMinorityFingerprintFrames() throws {
    let db = try makeMemoryDB()
    // Three frames of the dominant setup (302mm), scale 1.0"/px throughout
    // -> exact 1.0deg/0.6667deg FOV.
    for i in 0..<3 {
        try insertFingerprintedLight(
            db: db, target: "T4", date: "2026-06-04", name: "a\(i)",
            instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76, scaleArcsecPerPixel: 1.0
        )
    }
    // One minority-setup frame (480mm) with a wildly different scale --
    // must NOT pull the median toward it.
    try insertFingerprintedLight(
        db: db, target: "T4", date: "2026-06-04", name: "b0",
        instrume: "ASI2600MC", focallen: 480, xpixsz: 3.76, scaleArcsecPerPixel: 5.0
    )

    let fov = try #require(try FieldGeometry.dominantFOV(db: db, config: AstroConfig()))
    #expect(abs(fov.widthDeg - 1.0) < 1e-9)
    #expect(abs(fov.heightDeg - (2400.0 / 3600.0)) < 1e-9)
}

@Test func dominantFOVSkipsDominantFingerprintFramesWithNoOwnFOVButUsesTheOnesThatDo() throws {
    let db = try makeMemoryDB()
    // Two dominant-setup frames WITH a resolvable FOV (scale 1.0"/px)...
    for i in 0..<2 {
        try insertFingerprintedLight(
            db: db, target: "T5", date: "2026-06-05", name: "a\(i)",
            instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76, scaleArcsecPerPixel: 1.0
        )
    }
    // ...plus a THIRD frame of the SAME dominant setup with no CD matrix at
    // all (still fingerprints identically, but contributes no FOV sample).
    try insertFingerprintedLight(
        db: db, target: "T5", date: "2026-06-05", name: "a2",
        instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76, scaleArcsecPerPixel: nil
    )

    let fov = try #require(try FieldGeometry.dominantFOV(db: db, config: AstroConfig()))
    #expect(abs(fov.widthDeg - 1.0) < 1e-9)
    #expect(abs(fov.heightDeg - (2400.0 / 3600.0)) < 1e-9)
}

@Test func dominantFOVExcludesRejectedFramesFromTheMedian() throws {
    let db = try makeMemoryDB()
    // Two usable dominant-setup frames at scale 1.0"/px...
    for i in 0..<2 {
        try insertFingerprintedLight(
            db: db, target: "T6", date: "2026-06-06", name: "a\(i)",
            instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76, scaleArcsecPerPixel: 1.0
        )
    }
    // ...plus a REJECTED one (lives under a `Reject/` triage subdirectory)
    // at a wildly different scale -- must not affect the median, same
    // "usable only" rule `FieldGeometry.panels` itself already follows.
    let rejectFileID = try db.upsertFile(
        FileRecord(
            path: "sessions/T6/2026-06-06/lights/Reject/r0.fit", size: 1024, mtime: 1_700_000_000,
            ext: "fit", kind: "fits", area: .sessions, target: "T6", sessionDate: "2026-06-06", role: .light,
            scannedAt: 1_700_000_100
        )
    )
    try db.backfillInode(id: rejectFileID, inode: rejectFileID, nlink: 1)
    let rejectScaleDeg = 9.0 / 3600
    try db.upsertFITSMeta(
        FITSMetaRecord(
            fileID: rejectFileID, exptime: 60, instrume: "ASI2600MC", focallen: 302,
            naxis1: 3600, naxis2: 2400, xpixsz: 3.76,
            headerJSON: headerJSON([
                "CRVAL1": "100.0", "CRVAL2": "20.0",
                "CD1_1": String(rejectScaleDeg), "CD1_2": "0", "CD2_1": "0", "CD2_2": String(rejectScaleDeg),
            ])
        )
    )

    let fov = try #require(try FieldGeometry.dominantFOV(db: db, config: AstroConfig()))
    #expect(abs(fov.widthDeg - 1.0) < 1e-9)
    #expect(abs(fov.heightDeg - (2400.0 / 3600.0)) < 1e-9)
}
