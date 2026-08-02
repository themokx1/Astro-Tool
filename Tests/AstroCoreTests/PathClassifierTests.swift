import Testing
@testable import AstroCore

@Test func classifyNormalSessionLightFrame() {
    let info = PathClassifier.classify(relativePath: "sessions/M45_Pleiades/2026-01-10/lights/a.fit")
    #expect(info.area == .sessions)
    #expect(info.target == "M45_Pleiades")
    #expect(info.dateRaw == "2026-01-10")
    #expect(info.role == .light)
}

@Test func classifyCalibrationDarkHasNoTarget() {
    let info = PathClassifier.classify(relativePath: "calibration_library/darks/60sec_-10deg/d.fit")
    #expect(info.area == .calibration)
    #expect(info.role == .dark)
    #expect(info.target == nil)
    #expect(info.dateRaw == nil)
}

@Test func classifyStackResult() {
    let info = PathClassifier.classify(relativePath: "stacks/M42_Orion/2026-01-17/result.fit")
    #expect(info.area == .stacks)
    #expect(info.role == .stack)
    #expect(info.target == "M42_Orion")
    #expect(info.dateRaw == "2026-01-17")
}

@Test func classifyProcessedFile() {
    let info = PathClassifier.classify(relativePath: "processed/M45_Pleiades/2026-01-10/x.tif")
    #expect(info.area == .processed)
    #expect(info.role == .processed)
    #expect(info.target == "M45_Pleiades")
    #expect(info.dateRaw == "2026-01-10")
}

@Test func nestedSessionsDirUnderStacksDoesNotBecomeAreaSessions() {
    let info = PathClassifier.classify(relativePath: "stacks/M42_Orion/2026-01-17/sessions/session1/lights/a.fit")
    #expect(info.area == .stacks)
    #expect(info.target == "M42_Orion")
    #expect(info.dateRaw == "2026-01-17")
}

@Test func roleFromSessionSubdirectories() {
    #expect(PathClassifier.classify(relativePath: "sessions/M31/2026-01-01/lights/a.fit").role == .light)
    #expect(PathClassifier.classify(relativePath: "sessions/M31/2026-01-01/flats/a.fit").role == .flat)
    #expect(PathClassifier.classify(relativePath: "sessions/M31/2026-01-01/darks/a.fit").role == .dark)
    #expect(PathClassifier.classify(relativePath: "sessions/M31/2026-01-01/biases/a.fit").role == .bias)
}

@Test func roleFromCalibrationSubdirectories() {
    #expect(PathClassifier.classify(relativePath: "calibration_library/darks/60sec_-10deg/d.fit").role == .dark)
    #expect(PathClassifier.classify(relativePath: "calibration_library/flats/f.fit").role == .flat)
    #expect(PathClassifier.classify(relativePath: "calibration_library/biases/b.fit").role == .bias)
}

@Test func fileDirectlyUnderSessionDateWithNoRoleSubdirIsOther() {
    let info = PathClassifier.classify(relativePath: "sessions/M45_Pleiades/2026-01-10/README.txt")
    #expect(info.area == .sessions)
    #expect(info.role == .other)
}

@Test func rootLevelFileIsAreaOther() {
    let info = PathClassifier.classify(relativePath: "README.txt")
    #expect(info.area == .other)
    #expect(info.role == .other)
    #expect(info.target == nil)
    #expect(info.dateRaw == nil)
}

@Test func unknownTopLevelDirectoryIsAreaOther() {
    let info = PathClassifier.classify(relativePath: "randomdir/foo.txt")
    #expect(info.area == .other)
    #expect(info.role == .other)
}

@Test func dateRawKeepsNonCanonicalDirNameVerbatim() {
    #expect(PathClassifier.classify(relativePath: "sessions/M45_Pleiades/2026-04-06-2/lights/a.fit").dateRaw == "2026-04-06-2")
    #expect(PathClassifier.classify(relativePath: "sessions/M45_Pleiades/2026-02-25_2026-03-15/lights/a.fit").dateRaw == "2026-02-25_2026-03-15")
    #expect(PathClassifier.classify(relativePath: "sessions/M45_Pleiades/2026-03-15-OSC/lights/a.fit").dateRaw == "2026-03-15-OSC")
    #expect(PathClassifier.classify(relativePath: "sessions/M45_Pleiades/2026-03-15_hibas/lights/a.fit").dateRaw == "2026-03-15_hibas")
}

@Test func orphanSingularBiasCalibDirIsNotRecognizedAsBiasRole() {
    let info = PathClassifier.classify(relativePath: "calibration_library/bias/stray.fit")
    #expect(info.area == .calibration)
    #expect(info.role == .other)
}

// MARK: - Shallow real-library paths (file directly under an area/target dir)

@Test func fileDirectlyUnderSessionsHasNoTargetOrDate() {
    let info = PathClassifier.classify(relativePath: "sessions/.DS_Store")
    #expect(info.area == .sessions)
    #expect(info.target == nil)
    #expect(info.dateRaw == nil)
    #expect(info.role == .other)
}

@Test func fileDirectlyUnderSessionTargetDirHasTargetButNoDate() {
    let info = PathClassifier.classify(relativePath: "sessions/IC1805-1848_Heart-and-Soul_Nebula/.DS_Store")
    #expect(info.area == .sessions)
    #expect(info.target == "IC1805-1848_Heart-and-Soul_Nebula")
    #expect(info.dateRaw == nil)
    #expect(info.role == .other)
}

@Test func fileDirectlyUnderStacksHasNoTargetOrDate() {
    let info = PathClassifier.classify(relativePath: "stacks/.DS_Store")
    #expect(info.area == .stacks)
    #expect(info.target == nil)
    #expect(info.dateRaw == nil)
}

@Test func fileDirectlyUnderStackTargetDirHasTargetButNoDate() {
    let info = PathClassifier.classify(relativePath: "stacks/M42_Orion/.DS_Store")
    #expect(info.area == .stacks)
    #expect(info.target == "M42_Orion")
    #expect(info.dateRaw == nil)
}

@Test func fileDirectlyUnderProcessedHasNoTargetOrDate() {
    let info = PathClassifier.classify(relativePath: "processed/.DS_Store")
    #expect(info.area == .processed)
    #expect(info.target == nil)
    #expect(info.dateRaw == nil)
}

@Test func fileDirectlyUnderProcessedTargetDirHasTargetButNoDate() {
    let info = PathClassifier.classify(relativePath: "processed/M45_Pleiades/.DS_Store")
    #expect(info.area == .processed)
    #expect(info.target == "M45_Pleiades")
    #expect(info.dateRaw == nil)
}

// MARK: - Singular session role dirs

@Test func roleFromSingularSessionSubdirectories() {
    #expect(PathClassifier.classify(relativePath: "sessions/T/2025-12-31/light/a.fit").role == .light)
    #expect(PathClassifier.classify(relativePath: "sessions/T/2025-12-31/flat/a.fit").role == .flat)
    #expect(PathClassifier.classify(relativePath: "sessions/T/2025-12-31/dark/a.fit").role == .dark)
    #expect(PathClassifier.classify(relativePath: "sessions/T/2025-12-31/bias/x.fit").role == .bias)
}

@Test func roleFromSingularSessionSubdirectoriesIsCaseInsensitive() {
    #expect(PathClassifier.classify(relativePath: "sessions/T/2025-12-31/BIAS/x.fit").role == .bias)
    #expect(PathClassifier.classify(relativePath: "sessions/T/2025-12-31/Light/x.fit").role == .light)
}
