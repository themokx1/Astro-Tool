import Foundation
import Testing
@testable import AstroCore

private let apscZoom = ImagingSetupProfile(
    id: "apsc-zoom",
    name: "APS-C astro 100–400",
    cameraName: "APS-C astro kamera",
    cameraKind: .dedicatedAstro,
    sensorWidthMM: 23.5,
    sensorHeightMM: 15.7,
    focalLengthMinMM: 100,
    focalLengthMaxMM: 400,
    defaultFocalLengthMM: 200,
    isDefault: true
)

@Test func imagingSetupRecognizesZoomAndClampsPlanningFocalLength() {
    #expect(apscZoom.isZoom)
    #expect(apscZoom.clampedFocalLengthMM(nil) == 200)
    #expect(apscZoom.clampedFocalLengthMM(50) == 100)
    #expect(apscZoom.clampedFocalLengthMM(250) == 250)
    #expect(apscZoom.clampedFocalLengthMM(500) == 400)
}

@Test func fixedImagingSetupUsesOneFocalLength() {
    let setup = ImagingSetupProfile(
        id: "r8-16", name: "Canon R8 · 16 mm", cameraName: "Canon R8",
        cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
        focalLengthMinMM: 16, focalLengthMaxMM: 16,
        defaultFocalLengthMM: 16
    )

    #expect(!setup.isZoom)
    #expect(setup.clampedFocalLengthMM(70) == 16)
}

@Test func imagingSetupCalculatesKnownFullFrameSixteenMillimeterFOV() throws {
    let setup = ImagingSetupProfile(
        id: "r8-16", name: "Canon R8 · 16 mm", cameraName: "Canon R8",
        cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
        focalLengthMinMM: 16, focalLengthMaxMM: 16,
        defaultFocalLengthMM: 16
    )

    let fov = try #require(setup.fieldOfView())
    #expect(abs(fov.widthDeg - 96.73) < 0.01)
    #expect(abs(fov.heightDeg - 73.74) < 0.01)
}

@Test func imagingSetupCalculatesDifferentFOVAtBothZoomEnds() throws {
    let wide = try #require(apscZoom.fieldOfView(at: 100))
    let tele = try #require(apscZoom.fieldOfView(at: 400))

    #expect(abs(wide.widthDeg - 13.40) < 0.01)
    #expect(abs(wide.heightDeg - 8.98) < 0.01)
    #expect(abs(tele.widthDeg - 3.36) < 0.01)
    #expect(abs(tele.heightDeg - 2.25) < 0.01)
}

@Test func imagingSetupReturnsNilForInvalidPhysicalDimensions() {
    let setup = ImagingSetupProfile(
        id: "broken", name: "Hibás", cameraName: "Kamera",
        cameraKind: .dedicatedAstro, sensorWidthMM: 0, sensorHeightMM: 15.7,
        focalLengthMinMM: 100, focalLengthMaxMM: 400,
        defaultFocalLengthMM: 200
    )

    #expect(setup.fieldOfView() == nil)
}

@Test func malformedFocalRangesAreNeverExposedAsZoomControls() {
    var setup = apscZoom
    setup.focalLengthMinMM = 500
    setup.focalLengthMaxMM = 100

    #expect(!setup.isZoom)
    #expect(setup.fieldOfView() == nil)

    setup = apscZoom
    setup.focalLengthMaxMM = .infinity
    #expect(!setup.isZoom)
    #expect(setup.fieldOfView() == nil)
}

@Test func defaultImagingSetupPrefersFlaggedThenFallsBackToFirst() {
    let first = ImagingSetupProfile(
        id: "first", name: "Első", cameraName: "A", cameraKind: .dedicatedAstro,
        sensorWidthMM: 23.5, sensorHeightMM: 15.7,
        focalLengthMinMM: 100, focalLengthMaxMM: 100, defaultFocalLengthMM: 100
    )
    var second = first
    second.id = "second"
    second.name = "Második"
    second.isDefault = true

    #expect(ImagingSetupProfile.defaultSetup(in: [first, second])?.id == "second")
    #expect(ImagingSetupProfile.defaultSetup(in: [first])?.id == "first")
    #expect(ImagingSetupProfile.defaultSetup(in: []) == nil)
}

@Test func imagingSetupValidationAcceptsACompleteProfile() throws {
    try apscZoom.validate()
}

@Test func imagingSetupValidationRejectsEachInvalidPhysicalInput() {
    var setup = apscZoom

    setup.name = "   "
    #expect(throws: ImagingSetupValidationError.emptyName) { try setup.validate() }

    setup = apscZoom
    setup.cameraName = ""
    #expect(throws: ImagingSetupValidationError.emptyCameraName) { try setup.validate() }

    setup = apscZoom
    setup.sensorWidthMM = 0
    #expect(throws: ImagingSetupValidationError.invalidSensorSize) { try setup.validate() }

    setup = apscZoom
    setup.focalLengthMinMM = 500
    #expect(throws: ImagingSetupValidationError.invalidFocalRange) { try setup.validate() }

    setup = apscZoom
    setup.defaultFocalLengthMM = 450
    #expect(throws: ImagingSetupValidationError.defaultFocalLengthOutsideRange) { try setup.validate() }
}
