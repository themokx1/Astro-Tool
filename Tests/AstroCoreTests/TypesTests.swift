import Foundation
import Testing
@testable import AstroCore

@Test func severityRawValues() {
    #expect(Severity.sureError.rawValue == "sure_error")
    #expect(Severity.suspicious.rawValue == "suspicious")
    #expect(Severity.probablyIntentional.rawValue == "probably_intentional")
}

@Test func findingJSONRoundTrip() throws {
    let finding = Finding(
        severity: .suspicious,
        category: "placeholder-name",
        path: "sessions/M31/2026-08-01/lights",
        message: "Directory name looks like a placeholder.",
        suggestion: .rename(from: "lights", to: "lights_renamed")
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(finding)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(Finding.self, from: data)

    #expect(decoded == finding)
}

@Test func findingJSONRoundTripWithoutSuggestion() throws {
    let finding = Finding(
        severity: .sureError,
        category: "orphan-calib-dir",
        path: "calibration_library/darks",
        message: "Calibration directory has no matching session."
    )

    let data = try JSONEncoder().encode(finding)
    let decoded = try JSONDecoder().decode(Finding.self, from: data)

    #expect(decoded == finding)
}
