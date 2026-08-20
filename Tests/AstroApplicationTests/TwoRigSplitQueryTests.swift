@testable import AstroApplication
import AstroCore
import Foundation
import Testing

private func historicalFingerprintHeaderJSON(_ cards: [String: String]) -> String {
    let data = try! JSONEncoder().encode(cards)
    return String(data: data, encoding: .utf8)!
}

private func makeHistoricalFingerprintDB() throws -> Database {
    try Database(path: ":memory:")
}

/// Same fixture shape as `EquipmentProfileTests.insertLight` -- a fresh
/// in-memory `Database`, one scanned light per call, unique fake inode per
/// row so same-exptime/no-DATE-OBS frames in one session don't collapse to a
/// single canonical copy under `FrameSet`'s fallback dedup key.
@discardableResult
private func insertHistoricalFingerprintLight(
    db: Database, target: String, date: String, name: String, instrume: String, focallen: Double, xpixsz: Double
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
    try db.upsertFITSMeta(
        FITSMetaRecord(fileID: fileID, exptime: 60, instrume: instrume, focallen: focallen, xpixsz: xpixsz)
    )
    return fileID
}

/// Ideation #5 ("Két géped mára"): a wide, short-focal-length rig and a
/// narrow, long-focal-length rig -- the exact two setups the feature's own
/// UI example names (`HomeView`'s "2600MC+SV220 → IC 1396 · R8 wide →
/// NGC 7000" line).
private let wideRig = ImagingSetupProfile(
    id: "rig-wide", name: "R8 wide", cameraName: "Canon R8", cameraKind: .unmodifiedColor,
    sensorWidthMM: 36, sensorHeightMM: 24,
    focalLengthMinMM: 135, focalLengthMaxMM: 135, defaultFocalLengthMM: 135, fNumber: 2.8
)

private let narrowRig = ImagingSetupProfile(
    id: "rig-narrow", name: "2600MC+SV220", cameraName: "ASI2600MC", cameraKind: .dedicatedAstro,
    sensorWidthMM: 23.5, sensorHeightMM: 15.7,
    focalLengthMinMM: 1000, focalLengthMaxMM: 1000, defaultFocalLengthMM: 1000, fNumber: 5
)

struct TwoRigSplitQueryTests {
    @Test("A wide target and a narrow target split to different rigs")
    func wideAndNarrowTargetsSplitToDifferentRigs() throws {
        // M 42 (Orion Nebula, 65 arcmin) massively overflows the narrow rig's
        // ~54 arcmin short edge but frames comfortably on the wide rig's
        // ~610 arcmin short edge.
        let wideTarget = TwoRigSplitTarget(target: "M_42", displayName: "M 42")
        // M 57 (Ring Nebula, 3.83 arcmin) is lost in the wide rig's frame but
        // sits close to the narrow rig's own ideal coverage.
        let narrowTarget = TwoRigSplitTarget(target: "M_57", displayName: "M 57")

        let noHistory: @Sendable (String) -> SetupFingerprint? = { _ in nil }
        let result = try #require(TwoRigSplitQuery.assign(
            targets: [wideTarget, narrowTarget],
            setups: [wideRig, narrowRig],
            historicalFingerprint: noHistory
        ))

        #expect(result.count == 2)
        #expect(result.first { $0.target == "M_42" }?.setupID == "rig-wide")
        #expect(result.first { $0.target == "M_42" }?.reason == .fieldOfViewFit)
        #expect(result.first { $0.target == "M_57" }?.setupID == "rig-narrow")
        #expect(result.first { $0.target == "M_57" }?.reason == .fieldOfViewFit)
    }

    @Test("A target with no resolvable catalog size falls back to its own shooting history")
    func unresolvableSizeFallsBackToHistoricalFingerprint() throws {
        let target = TwoRigSplitTarget(target: "Some_Uncataloged_Nebula", displayName: "Some Uncataloged Nebula")
        // The library's own scanned history for this target is dominated by
        // frames whose FITS `INSTRUME` reads "ZWO ASI2600MC Pro" -- not a
        // byte-for-byte match for `narrowRig.cameraName` ("ASI2600MC"), the
        // exact fuzz `normalizedCameraMatch` exists to absorb.
        let fingerprint = SetupFingerprint(camera: "ZWO ASI2600MC Pro", descriptor: "ZWO ASI2600MC Pro·1000mm")
        let historicalFingerprint: @Sendable (String) -> SetupFingerprint? = { queried in
            queried == target.target ? fingerprint : nil
        }

        let result = try #require(TwoRigSplitQuery.assign(
            targets: [target],
            setups: [wideRig, narrowRig],
            historicalFingerprint: historicalFingerprint
        ))

        let assignment = try #require(result.first)
        #expect(assignment.setupID == "rig-narrow")
        #expect(assignment.setupName == "2600MC+SV220")
        #expect(assignment.reason == .historicalFingerprint)
    }

    @Test("No resolvable size and no shooting history is an honest undecidable, never dropped")
    func noSizeAndNoHistoryIsUndecidable() throws {
        let target = TwoRigSplitTarget(target: "Some_Uncataloged_Nebula", displayName: "Some Uncataloged Nebula")
        let noHistory: @Sendable (String) -> SetupFingerprint? = { _ in nil }

        let result = try #require(TwoRigSplitQuery.assign(
            targets: [target],
            setups: [wideRig, narrowRig],
            historicalFingerprint: noHistory
        ))

        #expect(result.count == 1)
        let assignment = try #require(result.first)
        #expect(assignment.target == target.target)
        #expect(assignment.setupID == nil)
        #expect(assignment.setupName == nil)
        #expect(assignment.reason == .undecidable)
    }

    @Test("Fewer than two saved setups hides the whole feature")
    func fewerThanTwoSetupsHidesTheFeature() {
        let target = TwoRigSplitTarget(target: "M_42", displayName: "M 42")
        let noHistory: @Sendable (String) -> SetupFingerprint? = { _ in nil }

        let result = TwoRigSplitQuery.assign(
            targets: [target],
            setups: [wideRig],
            historicalFingerprint: noHistory
        )

        #expect(result == nil)
    }

    @Test("Assignment is stable: the same input always produces the same output")
    func assignmentIsStable() throws {
        let targets = [
            TwoRigSplitTarget(target: "M_42", displayName: "M 42"),
            TwoRigSplitTarget(target: "M_57", displayName: "M 57"),
            TwoRigSplitTarget(target: "Some_Uncataloged_Nebula", displayName: "Some Uncataloged Nebula"),
        ]
        let fingerprint = SetupFingerprint(camera: "ASI2600MC", descriptor: "ASI2600MC·1000mm")
        let historicalFingerprint: @Sendable (String) -> SetupFingerprint? = { queried in
            queried == "Some_Uncataloged_Nebula" ? fingerprint : nil
        }

        let first = try #require(TwoRigSplitQuery.assign(targets: targets, setups: [wideRig, narrowRig], historicalFingerprint: historicalFingerprint))
        let second = try #require(TwoRigSplitQuery.assign(targets: targets, setups: [wideRig, narrowRig], historicalFingerprint: historicalFingerprint))
        // Same result even with the candidate setups supplied in the
        // opposite order -- the tie-break inside `bestFieldOfViewFit` is by
        // `id`, never by array position.
        let third = try #require(TwoRigSplitQuery.assign(targets: targets, setups: [narrowRig, wideRig], historicalFingerprint: historicalFingerprint))

        #expect(first == second)
        #expect(first == third)
    }

    // MARK: - historicalDominantFingerprint delegates to EquipmentProfile

    /// W5-4 item 3: `historicalDominantFingerprint` used to hand-roll its own
    /// frame-counting/majority-vote loop against `EquipmentProfile
    /// .fingerprint`'s output instead of calling the SAME canonical
    /// `EquipmentProfile.fingerprintCounts`/`.dominant(_:)` the mixed-setup
    /// audit rules and `SessionStatsQueries` already share. This pins the
    /// mixed-fingerprint case (3 frames of one setup vs. 2 of another,
    /// across two different session dates -- `historicalDominantFingerprint`
    /// pools the target's FULL history, unlike `sessionFingerprints`, which
    /// is scoped to one date) against a value independently computed via the
    /// canonical `EquipmentProfile` calls on the same usable-lights buckets,
    /// proving the two paths agree.
    @Test("historicalDominantFingerprint agrees with EquipmentProfile.fingerprintCounts/.dominant on a mixed-fingerprint history")
    func historicalDominantFingerprintAgreesWithEquipmentProfileOnMixedHistory() throws {
        let db = try makeHistoricalFingerprintDB()
        let config = AstroConfig()
        let target = "Some_Uncataloged_Nebula"

        // Dominant setup: 3 frames, ASI2600MC @ 302mm, spread across two
        // session dates (pooled history, not a single session).
        for i in 0..<2 {
            try insertHistoricalFingerprintLight(
                db: db, target: target, date: "2026-06-01", name: "a\(i)",
                instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76
            )
        }
        try insertHistoricalFingerprintLight(
            db: db, target: target, date: "2026-06-05", name: "a2",
            instrume: "ASI2600MC", focallen: 302, xpixsz: 3.76
        )
        // Minority setup: 2 frames, a different camera+focal length entirely.
        for i in 0..<2 {
            try insertHistoricalFingerprintLight(
                db: db, target: target, date: "2026-06-05", name: "b\(i)",
                instrume: "Canon R8", focallen: 135, xpixsz: 5.94
            )
        }
        // A different target entirely -- must not leak into this target's
        // history.
        try insertHistoricalFingerprintLight(
            db: db, target: "Other_Target", date: "2026-06-01", name: "c0",
            instrume: "Canon R8", focallen: 135, xpixsz: 5.94
        )

        let actual = try TwoRigSplitQuery.historicalDominantFingerprint(target: target, db: db, config: config)

        // Independently reproduce the expected answer via the SAME canonical
        // `EquipmentProfile` calls `historicalDominantFingerprint` itself
        // now delegates to, against the target's pooled usable lights.
        let files = try db.allFiles(includeMissing: false)
        let lights = files.filter { $0.target == target && $0.area == .sessions && $0.role == .light }
        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in lights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) { metaByFileID[id] = meta }
        }
        let buckets = FrameSet.lightBuckets(files: lights, meta: metaByFileID, config: config)
        let expectedCounts = EquipmentProfile.fingerprintCounts(usableLights: buckets.usable, meta: metaByFileID)
        let expected = EquipmentProfile.dominant(expectedCounts)

        #expect(actual == expected)
        #expect(actual?.camera == "ASI2600MC")
        #expect(actual?.descriptor == "ASI2600MC·302mm·3.76µm")
    }

    @Test("historicalDominantFingerprint is nil when the target has no usable light with a derivable fingerprint")
    func historicalDominantFingerprintNilWhenNoUsableLight() throws {
        let db = try makeHistoricalFingerprintDB()
        let actual = try TwoRigSplitQuery.historicalDominantFingerprint(target: "Never_Scanned_Target", db: db, config: AstroConfig())
        #expect(actual == nil)
    }
}
