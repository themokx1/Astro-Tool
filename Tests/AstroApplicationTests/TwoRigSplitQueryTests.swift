@testable import AstroApplication
import AstroCore
import Foundation
import Testing

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
}
