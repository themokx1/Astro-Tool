import Testing
@testable import AstroCore

private func bulkFrame(_ path: String, exposure: Double?) -> CaptureAssignmentCandidate {
    CaptureAssignmentCandidate(path: path, exposureSeconds: exposure)
}

@Test func captureBulkSelectorExplainsEverySupportedScope() {
    let anchor = bulkFrame("sessions/IC_1396/2026-08-08/lights_osc/a.fit", exposure: 30)
    let sibling = bulkFrame("sessions/IC_1396/2026-08-08/lights_osc/b.fit", exposure: 30)
    let sameExposureElsewhere = bulkFrame("sessions/IC_1396/2026-08-08/lights/c.fit", exposure: 30)
    let narrowband = bulkFrame("sessions/IC_1396/2026-08-08/lights/d.fit", exposure: 300)
    let candidates = [anchor, sibling, sameExposureElsewhere, narrowband]

    #expect(CaptureBulkSelector.paths(scope: .currentFile, anchor: anchor, selectedPaths: [], candidates: candidates) == [anchor.path])
    #expect(CaptureBulkSelector.paths(scope: .selectedFiles, anchor: anchor, selectedPaths: [narrowband.path, sibling.path], candidates: candidates) == [narrowband.path, sibling.path].sorted())
    #expect(CaptureBulkSelector.paths(scope: .sameFolder, anchor: anchor, selectedPaths: [], candidates: candidates) == [anchor.path, sibling.path])
    #expect(CaptureBulkSelector.paths(scope: .sameExposure, anchor: anchor, selectedPaths: [], candidates: candidates) == [anchor.path, sibling.path, sameExposureElsewhere.path].sorted())
    #expect(CaptureBulkSelector.paths(scope: .wholeSession, anchor: anchor, selectedPaths: [], candidates: candidates) == candidates.map(\.path).sorted())
}

@Test func captureBulkSelectorUsesNominalExposureAndNeverCrossesSession() {
    let anchor = bulkFrame("sessions/IC_1396/2026-08-08/lights/a.fit", exposure: 29.96)
    let sameNominal = bulkFrame("sessions/IC_1396/2026-08-08/lights/b.fit", exposure: 30.04)
    let otherSession = bulkFrame("sessions/IC_1396/2026-08-09/lights/c.fit", exposure: 30)

    let paths = CaptureBulkSelector.paths(
        scope: .sameExposure,
        anchor: anchor,
        selectedPaths: [],
        candidates: [anchor, sameNominal, otherSession]
    )

    #expect(paths == [anchor.path, sameNominal.path])
}

@Test func selectedScopeFallsBackToAnchorAndDeduplicates() {
    let anchor = bulkFrame("sessions/T/2026-01-01/lights/a.fit", exposure: nil)
    #expect(CaptureBulkSelector.paths(scope: .selectedFiles, anchor: anchor, selectedPaths: [], candidates: [anchor]) == [anchor.path])
    #expect(CaptureBulkSelector.paths(scope: .selectedFiles, anchor: anchor, selectedPaths: [anchor.path, anchor.path], candidates: [anchor]) == [anchor.path])
}
