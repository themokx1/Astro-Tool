import Foundation
import Testing
@testable import AstroCore

@Test func captureSensorModesHaveClearHungarianLabels() {
    #expect(SensorMode.osc.displayNameHU == "OSC")
    #expect(SensorMode.mono.displayNameHU == "Monokróm")
    #expect(SensorMode.unknown.displayNameHU == "Ismeretlen szenzor")
}

@Test func captureSignalModesKeepBroadbandAndNarrowbandOrthogonalToSensor() {
    #expect(SignalMode.broadband.displayNameHU == "Szélessáv")
    #expect(SignalMode.dualBand.displayNameHU == "Dual-band")
    #expect(SignalMode.narrowband.displayNameHU == "Keskenysáv")
}

@Test func captureGroupQuickLabelIncludesSensorSignalAndSpecificFilter() {
    let group = CaptureGroupRecord(
        id: 7,
        target: "IC_1396",
        sessionDate: "2026-08-08",
        slug: "sv220-nb",
        displayName: "SV220 dual-band",
        sensorMode: .osc,
        signalMode: .dualBand,
        filterManufacturer: "SVBONY",
        filterModel: "SV220"
    )

    #expect(group.quickLabel == "OSC · Dual-band · SVBONY SV220")
}

@Test func captureGroupRoundTripsThroughJSON() throws {
    let group = CaptureGroupRecord(
        id: 3,
        target: "M42",
        sessionDate: "2026-01-17",
        slug: "osc-30s",
        displayName: "OSC 30 s",
        sensorMode: .osc,
        signalMode: .broadband,
        filterName: "UV/IR cut",
        notes: "Rövid csillagmag-expozíció",
        createdAt: 10,
        updatedAt: 20
    )

    let decoded = try JSONDecoder().decode(
        CaptureGroupRecord.self,
        from: JSONEncoder().encode(group)
    )

    #expect(decoded == group)
}

@Test func resolvedCaptureMetadataRetainsProvenanceAndConflict() {
    let resolved = ResolvedCaptureMetadata(
        groupID: 1,
        slug: "sv220-nb",
        displayName: "SV220 dual-band",
        sensorMode: .osc,
        signalMode: .dualBand,
        filterManufacturer: "SVBONY",
        filterModel: "SV220",
        sensorOrigin: .fitsHeader,
        signalOrigin: .captureGroup,
        filterOrigin: .manualOverride,
        conflicts: ["A FITS FILTER és a kézi filter eltér."]
    )

    #expect(resolved.sensorOrigin == .fitsHeader)
    #expect(resolved.filterOrigin == .manualOverride)
    #expect(resolved.hasConflict)
}
