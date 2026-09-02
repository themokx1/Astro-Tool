import Foundation
import Testing
@testable import AstroCore

@Test func defaultConfigHasExpectedValues() {
    let config = AstroConfig()

    #expect(config.rootPath.isEmpty)
    #expect(config.excludedDirNames == ["tools"])
    #expect(config.excludedPaths == [])
    #expect(config.residuePatterns == [
        "*.seq", "*.lst", "*_conv*", "*_bkg*", "*_pp_*", "r_*", "bkg_*", ".DS_Store",
        "veralux_*", "*stack_work*", "*_synt*", "fixstars*", "*star recomposition result*",
    ])
    #expect(config.sessionResiduePatterns == [
        "starless*", "starmask*", "*graxpert*", "result_*",
    ])
    #expect(config.residueDirNames == ["process"])
    #expect(config.toolOutputDirNames == ["Stack", "Review", "Reject", "light_frame_rating_report_assets", "masters"])
    #expect(config.intentional == IntentionalPatterns())

    #expect(config.wideField.extensions == ["cr3", "tif"])
    #expect(config.wideField.maxFocalLengthMM == 135)
    #expect(config.wideField.nameMarkers == ["wide"])
    #expect(config.wideField.overrides == [:])

    #expect(config.calib.tempToleranceC == 1.0)
    #expect(config.calib.exposureToleranceS == 0.0)
    #expect(config.calib.darkMaxAgeMonths == 12)
    #expect(config.calib.matchGain == true)
    #expect(config.calib.matchOffset == true)
    #expect(config.calib.matchBinning == true)
    #expect(config.calib.matchCamera == true)
    #expect(config.calib.gainTolerance == 0)
    #expect(config.calib.exposureToleranceFraction == 0.02)
    #expect(config.calib.flatMaxAgeDays == 30)
    #expect(config.calib.rotatorToleranceDeg == 2.0)
    #expect(config.calib.coolerToleranceC == 1.0)
    #expect(config.calib.autoMasterBuildEnabled == false)

    #expect(config.rating.workers == 4)
    #expect(config.rating.outlierZScore == 2.0)
    #expect(config.rating.sirilPath == "/Applications/Siril.app/Contents/MacOS/siril-cli")
    #expect(config.rating.weights == ["fwhm": 0.4, "roundness": 0.2, "starCount": 0.2, "background": 0.2])

    #expect(config.stats.excludeLabels == ["hibas", "bad", "reject", "rejected", "schlecht"])
    #expect(config.stats.gapThresholdSeconds == 0)
    #expect(config.stats.collectingThresholdSeconds == 7200)

    #expect(config.site.latitudeDeg == nil)
    #expect(config.site.longitudeDeg == nil)

    #expect(config.weather.enabled == false)
    #expect(config.notification.enabled == false)

    #expect(config.integrationReference == IntegrationReferenceRule())
}

@Test func decodingConfigWithoutSessionResiduePatternsFallsBackToDefaults() throws {
    // Every pre-existing on-disk config.json predates this key -- decoding
    // one must yield the same defaults a fresh `AstroConfig()` has, and an
    // explicit empty list must survive a round-trip (an owner deliberately
    // disabling the session layer), not get "repaired" back to defaults.
    let withoutKey = try JSONDecoder().decode(AstroConfig.self, from: Data("{}".utf8))
    #expect(withoutKey.sessionResiduePatterns == AstroConfig().sessionResiduePatterns)

    let explicitlyEmpty = try JSONDecoder().decode(
        AstroConfig.self, from: Data(#"{"sessionResiduePatterns": []}"#.utf8))
    #expect(explicitlyEmpty.sessionResiduePatterns == [])

    var config = AstroConfig()
    config.sessionResiduePatterns = ["custom_*"]
    let decoded = try JSONDecoder().decode(AstroConfig.self, from: JSONEncoder().encode(config))
    #expect(decoded.sessionResiduePatterns == ["custom_*"])
}

@Test func defaultSiteRuleHasNilCoordinates() {
    let rule = SiteRule()
    #expect(rule.latitudeDeg == nil)
    #expect(rule.longitudeDeg == nil)
}

// MARK: - SiteProfile / config.sites (R11-T15/F16)

@Test func defaultConfigHasEmptySites() {
    #expect(AstroConfig().sites == [])
}

// MARK: - Imaging setups

@Test func defaultConfigHasNoManualImagingSetups() {
    #expect(AstroConfig().imagingSetups == [])
}

@Test func decodingLegacyConfigWithoutImagingSetupsKeepsAutomaticFOVMode() throws {
    let config = try JSONDecoder().decode(AstroConfig.self, from: Data("{}".utf8))
    #expect(config.imagingSetups == [])
}

@Test func imagingSetupsRoundTripThroughAstroConfig() throws {
    var config = AstroConfig()
    config.imagingSetups = [
        ImagingSetupProfile(
            id: "apsc", name: "APS-C astro 100–400", cameraName: "Astro kamera",
            cameraKind: .dedicatedAstro, sensorWidthMM: 23.5, sensorHeightMM: 15.7,
            focalLengthMinMM: 100, focalLengthMaxMM: 400,
            defaultFocalLengthMM: 200, isDefault: true
        ),
        ImagingSetupProfile(
            id: "r8-16", name: "Canon R8 · 16 mm", cameraName: "Canon R8",
            cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
            focalLengthMinMM: 16, focalLengthMaxMM: 16,
            defaultFocalLengthMM: 16
        ),
        ImagingSetupProfile(
            id: "r8-zoom", name: "Canon R8 · 28–70 mm", cameraName: "Canon R8",
            cameraKind: .unmodifiedColor, sensorWidthMM: 36, sensorHeightMM: 24,
            focalLengthMinMM: 28, focalLengthMaxMM: 70,
            defaultFocalLengthMM: 50
        ),
    ]

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AstroConfig.self, from: data)
    #expect(decoded.imagingSetups == config.imagingSetups)
    #expect(decoded == config)
}

@Test func siteProfileDefaultsIsDefaultToFalse() {
    let profile = SiteProfile(name: "Kert", latitudeDeg: 47.5, longitudeDeg: 19.0)
    #expect(profile.isDefault == false)
    #expect(profile.id == "Kert")
}

@Test func siteProfileDecodingMissingIsDefaultFillsFalse() throws {
    let json = """
    { "name": "Kert", "latitudeDeg": 47.5, "longitudeDeg": 19.0 }
    """
    let profile = try JSONDecoder().decode(SiteProfile.self, from: Data(json.utf8))
    #expect(profile.isDefault == false)
}

@Test func defaultSiteInPicksTheFlaggedEntry() {
    let sites = [
        SiteProfile(name: "A", latitudeDeg: 1, longitudeDeg: 1),
        SiteProfile(name: "B", latitudeDeg: 2, longitudeDeg: 2, isDefault: true),
        SiteProfile(name: "C", latitudeDeg: 3, longitudeDeg: 3),
    ]
    #expect(SiteProfile.defaultSite(in: sites)?.name == "B")
}

@Test func defaultSiteInFallsBackToFirstWhenNoneFlagged() {
    let sites = [
        SiteProfile(name: "A", latitudeDeg: 1, longitudeDeg: 1),
        SiteProfile(name: "B", latitudeDeg: 2, longitudeDeg: 2),
    ]
    #expect(SiteProfile.defaultSite(in: sites)?.name == "A")
}

@Test func defaultSiteInReturnsNilForEmptyList() {
    #expect(SiteProfile.defaultSite(in: []) == nil)
}

/// Decode combo 1/4: only the OLD `site` key present (a config.json written
/// before this task) -- `sites` synthesizes a one-element "Alapértelmezett"
/// list from it in memory, WITHOUT rewriting the underlying `site` field.
@Test func decodingOnlyLegacySiteSynthesizesOneElementSitesList() throws {
    let json = """
    { "site": { "latitudeDeg": 47.5, "longitudeDeg": 19.0 } }
    """
    let config = try JSONDecoder().decode(AstroConfig.self, from: Data(json.utf8))

    #expect(config.site.latitudeDeg == 47.5)
    #expect(config.site.longitudeDeg == 19.0)
    #expect(config.sites.count == 1)
    #expect(config.sites[0].name == "Alapértelmezett")
    #expect(config.sites[0].latitudeDeg == 47.5)
    #expect(config.sites[0].longitudeDeg == 19.0)
    #expect(config.sites[0].isDefault == true)
}

/// Decode combo 2/4: only the NEW `sites` key present, no `site` at all --
/// decodes straight through, `site` stays at its own empty default.
@Test func decodingOnlyNewSitesListDecodesDirectly() throws {
    let json = """
    { "sites": [{ "name": "Kert", "latitudeDeg": 47.4, "longitudeDeg": 19.1, "isDefault": true }] }
    """
    let config = try JSONDecoder().decode(AstroConfig.self, from: Data(json.utf8))

    #expect(config.sites == [SiteProfile(name: "Kert", latitudeDeg: 47.4, longitudeDeg: 19.1, isDefault: true)])
    #expect(config.site == SiteRule())
}

/// Decode combo 3/4: BOTH keys present -- the explicit `sites` list wins
/// outright (never merged with/overridden by the legacy `site` pair).
@Test func decodingBothSiteAndSitesPrefersTheExplicitSitesList() throws {
    let json = """
    {
      "site": { "latitudeDeg": 10.0, "longitudeDeg": 20.0 },
      "sites": [
        { "name": "Otthon", "latitudeDeg": 47.5, "longitudeDeg": 19.0, "isDefault": true },
        { "name": "Hegy", "latitudeDeg": 46.0, "longitudeDeg": 18.0 }
      ]
    }
    """
    let config = try JSONDecoder().decode(AstroConfig.self, from: Data(json.utf8))

    #expect(config.sites.count == 2)
    #expect(config.sites.map(\.name) == ["Otthon", "Hegy"])
    // The legacy `site` pair is decoded verbatim too (still readable by an
    // older CLI build) -- just not used to DERIVE `sites` when the explicit
    // list is already there.
    #expect(config.site.latitudeDeg == 10.0)
    #expect(config.site.longitudeDeg == 20.0)
}

/// Decode combo 4/4: NEITHER key present -- `sites` stays empty, the
/// pre-T15 FITS-median automatika keeps working unchanged.
@Test func decodingNeitherSiteNorSitesLeavesSitesEmpty() throws {
    let config = try JSONDecoder().decode(AstroConfig.self, from: Data("{}".utf8))
    #expect(config.sites == [])
    #expect(config.site == SiteRule())
}

/// A `site` with only ONE coordinate filled in (the other still `nil`,
/// `SiteRule`'s own partial-decode case) never synthesizes a `sites` entry
/// -- `TargetCoordinates.resolveSite`'s own "both must be present" contract
/// for a usable site pair.
@Test func decodingPartialLegacySiteDoesNotSynthesizeSitesList() throws {
    let json = """
    { "site": { "latitudeDeg": 47.5 } }
    """
    let config = try JSONDecoder().decode(AstroConfig.self, from: Data(json.utf8))
    #expect(config.sites == [])
}

@Test func sitesRoundTripsThroughEncodeDecode() throws {
    var config = AstroConfig()
    config.sites = [
        SiteProfile(name: "Otthon", latitudeDeg: 47.5, longitudeDeg: 19.0, isDefault: true),
        SiteProfile(name: "Hegy", latitudeDeg: 46.0, longitudeDeg: 18.0),
    ]

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AstroConfig.self, from: data)
    #expect(decoded == config)
}

@Test func defaultWeatherRuleIsDisabled() {
    let rule = WeatherRule()
    #expect(rule.enabled == false)
}

@Test func decodingPartialWeatherRuleFillsMissingKeyWithDefault() throws {
    let json = """
    { "weather": { "enabled": true } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.weather.enabled == true)
}

@Test func decodingConfigWithoutWeatherKeyStillDecodes() throws {
    // R10-B6: an old config.json written before this task landed has no
    // "weather" key at all -- must still decode cleanly, defaulting to
    // disabled (never silently opt a pre-existing config INTO a network
    // call it never asked for).
    let json = """
    { "rootPath": "/Volumes/images/OldConfig", "site": { "latitudeDeg": 47.5, "longitudeDeg": 19.0 } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.weather == WeatherRule())
    #expect(config.weather.enabled == false)
    #expect(config.rootPath == "/Volumes/images/OldConfig")
}

// MARK: - Wave 0 seam (V3 pre-stack program, section 5.5, Derült-trigger)

@Test func defaultNotificationRuleIsDisabled() {
    let rule = NotificationRule()
    #expect(rule.enabled == false)
}

@Test func defaultConfigHasDisabledNotificationRule() {
    #expect(AstroConfig().notification == NotificationRule())
}

@Test func decodingPartialNotificationRuleFillsMissingKeyWithDefault() throws {
    let json = """
    { "notification": { "enabled": true } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.notification.enabled == true)
}

@Test func decodingConfigWithoutNotificationKeyStillDecodes() throws {
    // Wave 0 lands this key for the first time -- every pre-existing
    // config.json has no "notification" key at all and must still decode
    // cleanly, defaulting to disabled (never silently opting a pre-existing
    // config INTO a system notification permission prompt it never asked
    // for -- the same rule `WeatherRule`'s own equivalent test enforces).
    let json = """
    { "rootPath": "/Volumes/images/OldConfig", "site": { "latitudeDeg": 47.5, "longitudeDeg": 19.0 } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.notification == NotificationRule())
    #expect(config.notification.enabled == false)
    #expect(config.rootPath == "/Volumes/images/OldConfig")
}

@Test func notificationRuleRoundTripsThroughEncodeDecode() throws {
    var config = AstroConfig()
    config.notification.enabled = true

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(decoded == config)
    #expect(decoded.notification.enabled == true)
}

// MARK: - 5.5 own commit: NotificationRule.checkHourLocal

@Test func defaultNotificationRuleChecksAtFourteenLocal() {
    #expect(NotificationRule().checkHourLocal == 14)
}

@Test func decodingPartialNotificationRuleFillsMissingCheckHourWithDefault() throws {
    // A config written after `enabled` existed but before `checkHourLocal`
    // did -- must still decode cleanly, defaulting the check hour rather
    // than throwing (the same additive-field contract this file's every
    // other `Rule` type already documents).
    let json = """
    { "notification": { "enabled": true } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.notification.enabled == true)
    #expect(config.notification.checkHourLocal == 14)
}

@Test func decodingExplicitCheckHourLocalRoundTrips() throws {
    let json = """
    { "notification": { "enabled": true, "checkHourLocal": 16 } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.notification.checkHourLocal == 16)

    let reencoded = try JSONEncoder().encode(config)
    let redecoded = try JSONDecoder().decode(AstroConfig.self, from: reencoded)
    #expect(redecoded.notification.checkHourLocal == 16)
}

// MARK: - Wave 0 seam (V3 pre-stack program, section 5.2, Kalibrációs automata)

@Test func defaultCalibRuleHasAutoMasterBuildDisabled() {
    #expect(CalibRule().autoMasterBuildEnabled == false)
}

@Test func decodingPartialCalibRuleWithAutoMasterBuildFillsOtherKeysWithDefaults() throws {
    let json = """
    { "calib": { "autoMasterBuildEnabled": true } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.calib.autoMasterBuildEnabled == true)
    #expect(config.calib.flatMaxAgeDays == 30)
    #expect(config.calib.tempToleranceC == 1.0)
}

@Test func decodingCalibRuleWithoutAutoMasterBuildKeyStillDecodes() throws {
    let json = """
    { "calib": { "flatMaxAgeDays": 45 } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.calib.autoMasterBuildEnabled == false)
}

@Test func calibRuleAutoMasterBuildRoundTripsThroughEncodeDecode() throws {
    var config = AstroConfig()
    config.calib.autoMasterBuildEnabled = true

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(decoded == config)
    #expect(decoded.calib.autoMasterBuildEnabled == true)
}

@Test func decodingPartialSiteRuleFillsMissingKeyWithDefault() throws {
    let json = """
    { "site": { "latitudeDeg": 47.5 } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.site.latitudeDeg == 47.5)
    #expect(config.site.longitudeDeg == nil)
}

// MARK: - R11-T16/F20: AstroBinRule

@Test func defaultAstroBinRuleHasEmptyFilterIds() {
    let rule = AstroBinRule()
    #expect(rule.filterIds == [:])
}

@Test func defaultConfigHasEmptyAstroBinFilterIds() {
    #expect(AstroConfig().astrobin.filterIds == [:])
}

@Test func decodingPartialAstroBinRuleFillsMissingKeyWithDefault() throws {
    let json = """
    { "astrobin": { "filterIds": { "Ha": 4663 } } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.astrobin.filterIds == ["Ha": 4663])
}

@Test func decodingConfigWithoutAstroBinKeyStillDecodes() throws {
    let json = """
    { "rootPath": "/Volumes/images/OldConfig" }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.astrobin == AstroBinRule())
}

@Test func astroBinFilterIdsRoundTripsThroughEncodeDecode() throws {
    var config = AstroConfig()
    config.astrobin.filterIds = ["Ha": 4663, "OIII": 4664]

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(decoded == config)
    #expect(decoded.astrobin.filterIds == ["Ha": 4663, "OIII": 4664])
}

@Test func astroBinMappingLookupIsTrimmedAndCaseInsensitive() {
    let rule = AstroBinRule(filterIds: [" ha ": 4663])
    #expect(rule.filterID(for: "Ha") == 4663)
    #expect(rule.filterID(for: "  HA  ") == 4663)
}

@Test func astroBinDuplicateNormalizedKeysResolveDeterministically() throws {
    let json = #"{"filterIds":{" ha ":11,"Ha":22}}"#
    let rule = try JSONDecoder().decode(AstroBinRule.self, from: Data(json.utf8))
    #expect(rule.filterID(for: "HA") == 11)
    #expect(rule.filterID(for: "HA") == rule.filterID(for: " ha "))
}

@Test func astroBinSettingMappingReplacesNormalizedDuplicateAndKeepsDisplayName() {
    var rule = AstroBinRule(filterIds: [" ha ": 11, "Ha": 22, "OIII": 33])
    rule.setFilterID(44, for: "H-alpha")
    #expect(rule.filterIds["H-alpha"] == 44)
    rule.setFilterID(55, for: "HA")
    #expect(rule.filterID(for: "ha") == 55)
    #expect(rule.filterIds.keys.filter { AstroBinRule.normalizedFilterKey($0) == "ha" } == ["HA"])
}

@Test func defaultStatsRuleHasExpectedValues() {
    let rule = StatsRule()
    #expect(rule.excludeLabels == ["hibas", "bad", "reject", "rejected", "schlecht"])
    #expect(rule.gapThresholdSeconds == 0)
    #expect(rule.collectingThresholdSeconds == 7200)
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
    #expect(rule.tempToleranceC == 1.0)
    #expect(rule.exposureToleranceS == 0.0)
    #expect(rule.darkMaxAgeMonths == 12)
    #expect(rule.matchGain == true)
    #expect(rule.matchOffset == true)
    #expect(rule.matchBinning == true)
    #expect(rule.matchCamera == true)
    #expect(rule.gainTolerance == 0)
    #expect(rule.exposureToleranceFraction == 0.02)
    #expect(rule.flatMaxAgeDays == 30)
    #expect(rule.rotatorToleranceDeg == 2.0)
    #expect(rule.coolerToleranceC == 1.0)
    #expect(rule.autoMasterBuildEnabled == false)
}

@Test func decodingPartialCalibRuleFillsMissingKeysWithDefaults() throws {
    let json = """
    { "calib": { "flatMaxAgeDays": 45 } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.calib.flatMaxAgeDays == 45)
    #expect(config.calib.rotatorToleranceDeg == 2.0)
    #expect(config.calib.tempToleranceC == 1.0)
    #expect(config.calib.coolerToleranceC == 1.0)
    #expect(config.calib.autoMasterBuildEnabled == false)
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
    config.weather.enabled = true

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(decoded == config)
    #expect(decoded.weather.enabled == true)
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
    #expect(config.toolOutputDirNames == AstroConfig().toolOutputDirNames)
    #expect(config.intentional == IntentionalPatterns())
    #expect(config.wideField == WideFieldRule())
    #expect(config.calib == CalibRule())
    #expect(config.stats == StatsRule())
    #expect(config.site == SiteRule())
    #expect(config.weather == WeatherRule())
    #expect(config.notification == NotificationRule())
    #expect(config.astrobin == AstroBinRule())

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

@Test func decodingPartialStatsRuleFillsMissingKeyWithDefault() throws {
    let json = """
    { "stats": { "excludeLabels": ["hibas", "cloudy"] } }
    """
    let data = Data(json.utf8)
    let config = try JSONDecoder().decode(AstroConfig.self, from: data)

    #expect(config.stats.excludeLabels == ["hibas", "cloudy"])
    #expect(config.stats.gapThresholdSeconds == 0)
    #expect(config.stats.collectingThresholdSeconds == 7200)
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

@Test func saveThenLoadRoundTripsThroughWriteGuard() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("astro-config-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var config = AstroConfig()
    config.rootPath = "/Volumes/images/Saved"
    config.wideField.overrides = ["M42": true]

    let writeGuard = WriteGuard(root: root)
    try config.save(using: writeGuard)

    let configURL = root.appendingPathComponent(".astro_tool/config.json")
    let loaded = try AstroConfig.load(from: configURL)
    #expect(loaded == config)
}
