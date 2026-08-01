import Foundation
import Testing
@testable import AstroCore

@Test func defaultConfigHasExpectedValues() {
    let config = AstroConfig()

    #expect(config.rootPath == "/Volumes/images/Astro")
    #expect(config.excludedDirNames == ["tools"])
    #expect(config.excludedPaths == [])
    #expect(config.residuePatterns == ["*.seq", "*.lst", "*_conv*", "*_bkg*", "*_pp_*", "r_*", "bkg_*", ".DS_Store"])
    #expect(config.residueDirNames == ["process"])
    #expect(config.intentional == IntentionalPatterns())

    #expect(config.wideField.extensions == ["cr3", "tif"])
    #expect(config.wideField.maxFocalLengthMM == 135)
    #expect(config.wideField.nameMarkers == ["wide"])
    #expect(config.wideField.overrides == [:])

    #expect(config.calib.tempToleranceC == 0.5)
    #expect(config.calib.exposureToleranceS == 0.0)
    #expect(config.calib.darkMaxAgeMonths == 6)

    #expect(config.rating.workers == 4)
    #expect(config.rating.outlierZScore == 2.0)
    #expect(config.rating.sirilPath == "/Applications/Siril.app/Contents/MacOS/siril-cli")
    #expect(config.rating.weights == ["fwhm": 0.4, "roundness": 0.2, "starCount": 0.2, "background": 0.2])
}

@Test func defaultWideFieldRuleHasExpectedValues() {
    let rule = WideFieldRule()
    #expect(rule.extensions == ["cr3", "tif"])
    #expect(rule.maxFocalLengthMM == 135)
    #expect(rule.nameMarkers == ["wide"])
    #expect(rule.overrides == [:])
}

@Test func defaultCalibRuleHasExpectedValues() {
    let rule = CalibRule()
    #expect(rule.tempToleranceC == 0.5)
    #expect(rule.exposureToleranceS == 0.0)
    #expect(rule.darkMaxAgeMonths == 6)
}

@Test func defaultRatingRuleHasExpectedValues() {
    let rule = RatingRule()
    #expect(rule.workers == 4)
    #expect(rule.outlierZScore == 2.0)
    #expect(rule.sirilPath == "/Applications/Siril.app/Contents/MacOS/siril-cli")
    #expect(rule.weights == ["fwhm": 0.4, "roundness": 0.2, "starCount": 0.2, "background": 0.2])
}

@Test func encodesAndDecodesRoundTrip() throws {
    var config = AstroConfig()
    config.rootPath = "/Volumes/images/Custom"
    config.excludedDirNames = ["tools", "junk"]
    config.wideField.overrides = ["M31": true]
    config.rating.weights["fwhm"] = 0.6

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(decoded == config)
}

@Test func decodingPartialJSONFillsMissingKeysWithDefaults() throws {
    let json = """
    {
      "rootPath": "/Volumes/images/Only",
      "rating": { "workers": 8 }
    }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.rootPath == "/Volumes/images/Only")
    #expect(config.excludedDirNames == ["tools"])
    #expect(config.excludedPaths == [])
    #expect(config.residuePatterns == AstroConfig().residuePatterns)
    #expect(config.residueDirNames == ["process"])
    #expect(config.intentional == IntentionalPatterns())
    #expect(config.wideField == WideFieldRule())
    #expect(config.calib == CalibRule())

    #expect(config.rating.workers == 8)
    #expect(config.rating.outlierZScore == 2.0)
    #expect(config.rating.sirilPath == "/Applications/Siril.app/Contents/MacOS/siril-cli")
    #expect(config.rating.weights == RatingRule().weights)
}

@Test func decodingEmptyJSONObjectYieldsAllDefaults() throws {
    let data = Data("{}".utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)
    #expect(config == AstroConfig())
}

@Test func decodingUnknownKeysIsNotAnError() throws {
    let json = """
    {
      "rootPath": "/Volumes/images/Astro",
      "someFutureField": "ignored",
      "wideField": { "extensions": ["cr3"], "somethingNew": 42 }
    }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)
    #expect(config.wideField.extensions == ["cr3"])
    #expect(config.wideField.maxFocalLengthMM == 135)
}

@Test func loadReadsConfigFromDisk() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("config.json")
    let json = """
    { "rootPath": "/Volumes/images/FromDisk" }
    """
    try json.write(to: url, atomically: true, encoding: .utf8)

    let config = try AstroConfig.load(from: url)
    #expect(config.rootPath == "/Volumes/images/FromDisk")
    #expect(config.excludedDirNames == ["tools"])
}

@Test func loadThrowsWhenFileMissing() {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-config-tests-missing-\(UUID().uuidString).json")
    #expect(throws: (any Error).self) {
        try AstroConfig.load(from: url)
    }
}

@Test func loadThrowsOnMalformedJSON() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("config.json")
    try "{ not valid json".write(to: url, atomically: true, encoding: .utf8)

    #expect(throws: (any Error).self) {
        try AstroConfig.load(from: url)
    }
}
