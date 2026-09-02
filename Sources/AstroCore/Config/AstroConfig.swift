import Foundation

/// Rule for classifying frames as wide-field vs. narrow-field/deep-sky,
/// plus per-target manual overrides.
public struct WideFieldRule: Codable, Equatable, Sendable {
    /// Extensions (matched case-insensitively, see `WideFieldHeuristic`)
    /// that count as a wide-field DSLR/mirrorless frame. Before this
    /// default only covered `cr3`/`tif` -- every other camera RAW format
    /// `LibraryScanner.rawExtensions` already recognizes as a frame at all
    /// (CR2, NEF, ARW, DNG, RAF, ORF, RW2, PEF, SRW) silently never
    /// qualified as wide-field regardless of focal length, so e.g. a Nikon
    /// or Sony wide-field rig's stats always fell through to the narrow-
    /// field bucket. Sourced from `LibraryScanner.rawExtensions` itself
    /// (sorted, for a deterministic default) plus `tiff` alongside the
    /// existing `tif`, rather than a second hand-picked list that could
    /// silently drift from what the scanner actually indexes.
    public var extensions: [String]
    public var maxFocalLengthMM: Double
    public var nameMarkers: [String]
    /// Target name -> manual classification (true == wide-field), overriding
    /// the heuristic above.
    public var overrides: [String: Bool]

    public init(
        extensions: [String] = LibraryScanner.rawExtensions.sorted() + ["tif", "tiff"],
        maxFocalLengthMM: Double = 135,
        nameMarkers: [String] = ["wide"],
        overrides: [String: Bool] = [:]
    ) {
        self.extensions = extensions
        self.maxFocalLengthMM = maxFocalLengthMM
        self.nameMarkers = nameMarkers
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey {
        case extensions, maxFocalLengthMM, nameMarkers, overrides
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WideFieldRule()
        self.extensions = try container.decodeIfPresent([String].self, forKey: .extensions) ?? defaults.extensions
        self.maxFocalLengthMM = try container.decodeIfPresent(Double.self, forKey: .maxFocalLengthMM) ?? defaults.maxFocalLengthMM
        self.nameMarkers = try container.decodeIfPresent([String].self, forKey: .nameMarkers) ?? defaults.nameMarkers
        self.overrides = try container.decodeIfPresent([String: Bool].self, forKey: .overrides) ?? defaults.overrides
    }
}

/// Tolerances used when matching calibration frames (darks/flats/bias) to
/// lights.
///
/// R4-3 note on the two changed defaults: a cooled CMOS camera's set-point
/// wobbles roughly ±0.1-0.2 °C and dark current only doubles every ~5-6 °C,
/// so the old `tempToleranceC` of 0.5 was needlessly strict -- 1.0 is safe.
/// `darkMaxAgeMonths` of 6 was too aggressive for a cooled CMOS dark library
/// (the noise profile is stable far longer than that); 12 is right, and age
/// is meant as a warning, never the primary invalidator -- the electronic
/// key (gain/offset/binning/camera) below is.
public struct CalibRule: Codable, Equatable, Sendable {
    public var tempToleranceC: Double
    public var exposureToleranceS: Double
    public var darkMaxAgeMonths: Int
    /// Reject a candidate master whose FITS `GAIN` differs from the light's
    /// (beyond `gainTolerance`) -- a gain-0 dark applied to gain-100 lights
    /// actively harms the result on the ASI2600 (and any other cooled CMOS
    /// camera with per-gain read-noise/dark-current curves), so this is on
    /// by default.
    public var matchGain: Bool
    /// Reject a candidate master whose FITS `OFFSET` differs from the
    /// light's -- only enforced when BOTH sides have a value (older
    /// headers/DSLR frames without one never fail this check).
    public var matchOffset: Bool
    /// Reject a candidate master whose `XBINNING` differs from the light's
    /// -- same "only when both sides have a value" rule as `matchOffset`.
    /// Binning is parsed from calibration masters' `header_json` only (a few
    /// hundred files); it is not captured per scanned light frame (there can
    /// be thousands), so today this dimension only ever compares against a
    /// deliberately absent light-side value and never actually rejects a
    /// match -- it's wired through the config now so a future per-light
    /// binning capture slots in without another config migration.
    public var matchBinning: Bool
    /// Reject a candidate master whose `INSTRUME` differs from the light's
    /// -- same "only when both sides have a value" rule as `matchOffset`.
    /// This is what keeps a DSLR session (ISO stored in the `gain` column)
    /// from ever matching an ASI-camera master even if gain/exposure/temp
    /// all happen to line up.
    public var matchCamera: Bool
    /// Allowed absolute difference in `GAIN` before `matchGain` rejects a
    /// candidate. `0` (the default) requires an exact match.
    public var gainTolerance: Double
    /// Extra exposure-time tolerance as a fraction of the light's own
    /// exposure, applied IN ADDITION to `exposureToleranceS` -- a candidate
    /// matches if it's within either tolerance. `0.02` (2%) absorbs a
    /// camera's own exposure-timing jitter (e.g. a `30s`-requested light
    /// landing at `29.9s`) without a fixed absolute tolerance that would be
    /// too loose for short exposures or too tight for long ones.
    public var exposureToleranceFraction: Double
    /// R6-1 (`CalibHealth`'s flat discipline check): a session's own flat is
    /// rejected as "too old" once it's more than this many days away from
    /// the session's lights (both sides' `DATE-OBS`) -- dust on the sensor
    /// moves over time, so an old flat no longer describes the current
    /// vignetting/dust pattern even if it's otherwise electronically
    /// identical. Default 30 days.
    public var flatMaxAgeDays: Int
    /// R6-1: a session's own flat is rejected when its `ROTATOR` FITS header
    /// angle (read from `header_json`, same convention as `XBINNING`)
    /// differs from the lights' by more than this many degrees -- a flat
    /// only corrects vignetting/dust at the optical-train orientation it was
    /// taken at, so a rotated imaging train needs its own flat. Only
    /// compared when BOTH sides have a `ROTATOR` value (same "nothing to
    /// compare" rule as `matchOffset`/`matchCamera`). Default 2.0°.
    public var rotatorToleranceDeg: Double
    /// R6-2 (`NightHealth`'s cooler-health verdict + the
    /// `cooler-not-reaching-setpoint` audit rule): a frame's cooler is
    /// considered "out of band" once `|CCD-TEMP - SET-TEMP|` exceeds this
    /// many degrees C -- a cooled CMOS camera's own set-point wobble is
    /// small (see this struct's top-level doc comment), so 1.0°C safely
    /// separates normal jitter from an actual failure to hold temperature
    /// (e.g. a hot summer night the ASI2600's cooler can't keep up with).
    /// Only ever compared when BOTH sides have a value (same "nothing to
    /// compare" rule as `matchOffset`/`matchCamera` -- a DSLR frame with no
    /// `SET-TEMP` header never contributes to this check at all). Default
    /// 1.0°C.
    public var coolerToleranceC: Double
    /// Wave 0 seam (V3 pre-stack program, `docs/superpowers/specs/
    /// 2026-08-20-v3-prestack-program.md` section 5.2, Kalibrációs automata):
    /// off by default -- until that feature lands, nothing reads this field
    /// at all. It exists now so 5.2's own `CalibrationMasterBuildCommand` can
    /// gate its Siril-backed master build on this flag (in addition to
    /// `LibraryAccessMode.mutationEnabled`) without a second config.json
    /// migration.
    public var autoMasterBuildEnabled: Bool

    public init(
        tempToleranceC: Double = 1.0,
        exposureToleranceS: Double = 0.0,
        darkMaxAgeMonths: Int = 12,
        matchGain: Bool = true,
        matchOffset: Bool = true,
        matchBinning: Bool = true,
        matchCamera: Bool = true,
        gainTolerance: Double = 0,
        exposureToleranceFraction: Double = 0.02,
        flatMaxAgeDays: Int = 30,
        rotatorToleranceDeg: Double = 2.0,
        coolerToleranceC: Double = 1.0,
        autoMasterBuildEnabled: Bool = false
    ) {
        self.tempToleranceC = tempToleranceC
        self.exposureToleranceS = exposureToleranceS
        self.darkMaxAgeMonths = darkMaxAgeMonths
        self.matchGain = matchGain
        self.matchOffset = matchOffset
        self.matchBinning = matchBinning
        self.matchCamera = matchCamera
        self.gainTolerance = gainTolerance
        self.exposureToleranceFraction = exposureToleranceFraction
        self.flatMaxAgeDays = flatMaxAgeDays
        self.rotatorToleranceDeg = rotatorToleranceDeg
        self.coolerToleranceC = coolerToleranceC
        self.autoMasterBuildEnabled = autoMasterBuildEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case tempToleranceC, exposureToleranceS, darkMaxAgeMonths
        case matchGain, matchOffset, matchBinning, matchCamera
        case gainTolerance, exposureToleranceFraction
        case flatMaxAgeDays, rotatorToleranceDeg, coolerToleranceC
        case autoMasterBuildEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CalibRule()
        self.tempToleranceC = try container.decodeIfPresent(Double.self, forKey: .tempToleranceC) ?? defaults.tempToleranceC
        self.exposureToleranceS = try container.decodeIfPresent(Double.self, forKey: .exposureToleranceS) ?? defaults.exposureToleranceS
        self.darkMaxAgeMonths = try container.decodeIfPresent(Int.self, forKey: .darkMaxAgeMonths) ?? defaults.darkMaxAgeMonths
        self.matchGain = try container.decodeIfPresent(Bool.self, forKey: .matchGain) ?? defaults.matchGain
        self.matchOffset = try container.decodeIfPresent(Bool.self, forKey: .matchOffset) ?? defaults.matchOffset
        self.matchBinning = try container.decodeIfPresent(Bool.self, forKey: .matchBinning) ?? defaults.matchBinning
        self.matchCamera = try container.decodeIfPresent(Bool.self, forKey: .matchCamera) ?? defaults.matchCamera
        self.gainTolerance = try container.decodeIfPresent(Double.self, forKey: .gainTolerance) ?? defaults.gainTolerance
        self.exposureToleranceFraction = try container.decodeIfPresent(Double.self, forKey: .exposureToleranceFraction) ?? defaults.exposureToleranceFraction
        self.flatMaxAgeDays = try container.decodeIfPresent(Int.self, forKey: .flatMaxAgeDays) ?? defaults.flatMaxAgeDays
        self.rotatorToleranceDeg = try container.decodeIfPresent(Double.self, forKey: .rotatorToleranceDeg) ?? defaults.rotatorToleranceDeg
        self.coolerToleranceC = try container.decodeIfPresent(Double.self, forKey: .coolerToleranceC) ?? defaults.coolerToleranceC
        self.autoMasterBuildEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoMasterBuildEnabled) ?? defaults.autoMasterBuildEnabled
    }
}

/// Configuration for the frame-rating engine (native + Siril worker pool).
public struct RatingRule: Codable, Equatable, Sendable {
    public var workers: Int
    public var outlierZScore: Double
    public var sirilPath: String
    public var weights: [String: Double]

    public init(
        workers: Int = 4,
        outlierZScore: Double = 2.0,
        sirilPath: String = "/Applications/Siril.app/Contents/MacOS/siril-cli",
        weights: [String: Double] = ["fwhm": 0.4, "roundness": 0.2, "starCount": 0.2, "background": 0.2]
    ) {
        self.workers = workers
        self.outlierZScore = outlierZScore
        self.sirilPath = sirilPath
        self.weights = weights
    }

    private enum CodingKeys: String, CodingKey {
        case workers, outlierZScore, sirilPath, weights
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RatingRule()
        self.workers = try container.decodeIfPresent(Int.self, forKey: .workers) ?? defaults.workers
        self.outlierZScore = try container.decodeIfPresent(Double.self, forKey: .outlierZScore) ?? defaults.outlierZScore
        self.sirilPath = try container.decodeIfPresent(String.self, forKey: .sirilPath) ?? defaults.sirilPath
        self.weights = try container.decodeIfPresent([String: Double].self, forKey: .weights) ?? defaults.weights
    }
}

/// Rules governing how "true" (usable) statistics are derived from the raw
/// scanned library -- see `Sources/AstroCore/Stats/FrameSet.swift` for where
/// most of this actually gets applied.
public struct StatsRule: Codable, Equatable, Sendable {
    /// Session date-dir labels (`SessionDateKind.labeled`'s `label`,
    /// case-insensitive) whose entire night is excluded from a target's
    /// usable integration/frame totals -- the user's own "this night was
    /// bad" marker. Defaults cover both Hungarian (`_hibas` = "faulty") and
    /// English/German markers so the folder-name convention isn't
    /// Hungarian-only. The session still shows up in per-session details,
    /// just flagged `isExcludedFromTotals`.
    public var excludeLabels: [String]
    /// Reserved for R4-2 (gap-based sub-session splitting): the minimum
    /// silent gap, in seconds, between two consecutive lights before they're
    /// considered separate sub-sessions. `0` means "auto-detect" -- not yet
    /// implemented, just plumbed through so config files written today keep
    /// decoding once R4-2 lands.
    public var gapThresholdSeconds: Double
    /// R5-2 (`ProjectStatusQueries`): a target with no stack anywhere and
    /// less than this much usable integration is considered still
    /// "gyűjtés" (collecting) rather than "stackelhető" (ready to stack) --
    /// a couple of test lights don't mean the night's data collection is
    /// done. Default 2 hours.
    public var collectingThresholdSeconds: Double

    public init(
        excludeLabels: [String] = ["hibas", "bad", "reject", "rejected", "schlecht"],
        gapThresholdSeconds: Double = 0,
        collectingThresholdSeconds: Double = 7200
    ) {
        self.excludeLabels = excludeLabels
        self.gapThresholdSeconds = gapThresholdSeconds
        self.collectingThresholdSeconds = collectingThresholdSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case excludeLabels, gapThresholdSeconds, collectingThresholdSeconds
    }

    /// What the DECODER falls back to when a config file that already exists
    /// has no `excludeLabels` key -- deliberately the legacy single label,
    /// NOT `init()`'s wider default. That config was written when only
    /// `_hibas` excluded a night, and every total the user has seen since
    /// counted their `_bad`/`_reject`/`_schlecht` nights IN; adopting the
    /// wide list behind their back on the next launch would silently drop
    /// those nights from integration totals they never asked to exclude.
    /// A brand-new library (no config file, so a plain `StatsRule()`) gets
    /// the wide default instead -- there is no history to change there.
    static let legacyDecodedExcludeLabels = ["hibas"]

    /// The whole rule as an EXISTING config file with no `stats` block at
    /// all should decode -- same reasoning as
    /// `legacyDecodedExcludeLabels`, which it carries.
    static var legacyDecoded: StatsRule {
        StatsRule(excludeLabels: legacyDecodedExcludeLabels)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StatsRule()
        self.excludeLabels = try container.decodeIfPresent([String].self, forKey: .excludeLabels)
            ?? Self.legacyDecodedExcludeLabels
        self.gapThresholdSeconds = try container.decodeIfPresent(Double.self, forKey: .gapThresholdSeconds) ?? defaults.gapThresholdSeconds
        self.collectingThresholdSeconds = try container.decodeIfPresent(Double.self, forKey: .collectingThresholdSeconds) ?? defaults.collectingThresholdSeconds
    }
}

/// Configuration for `astrotool expose` (R7-B3, `ExposureAdvisor`): the
/// sub-exposure-length optimizer built on `SensorProfile`'s measured read
/// noise/bias/EGAIN and `ratings`' per-Bayer background medians.
public struct ExposeRule: Codable, Equatable, Sendable {
    /// Hard ceiling on a RECOMMENDED sub length, in seconds -- guiding
    /// accuracy and satellite-trail risk both grow with exposure length
    /// regardless of what the pure read-noise-vs-shot-noise trade-off says
    /// is "optimal", so a theoretical optimum beyond this is reported
    /// honestly (`capReason == "maxSubSeconds"`) rather than recommended
    /// outright. Default 300s (5 minutes).
    public var maxSubSeconds: Double
    /// How much extra per-sub noise read noise is allowed to add over pure
    /// sky shot noise before a sub is considered "long enough":
    /// `t = R² / (B × ((1+C)² − 1))`. Default `0.05` (5%) is equivalent to
    /// Glover's "sky background ≥ 10×R²" rule of thumb, since
    /// `1 / ((1.05)² − 1) ≈ 9.76`.
    public var noiseContributionC: Double

    public init(maxSubSeconds: Double = 300, noiseContributionC: Double = 0.05) {
        self.maxSubSeconds = maxSubSeconds
        self.noiseContributionC = noiseContributionC
    }

    private enum CodingKeys: String, CodingKey {
        case maxSubSeconds, noiseContributionC
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExposeRule()
        self.maxSubSeconds = try container.decodeIfPresent(Double.self, forKey: .maxSubSeconds) ?? defaults.maxSubSeconds
        self.noiseContributionC = try container.decodeIfPresent(Double.self, forKey: .noiseContributionC) ?? defaults.noiseContributionC
    }
}

/// The observer's site, for the planner (`Sources/AstroCore/Sky/Planner.swift`):
/// culmination/altitude/twilight all need a latitude and longitude. Both
/// default to `nil` -- when unset, `Planner` derives them from the median
/// `SITELAT`/`SITELONG` FITS header values across the scanned library
/// instead (see `TargetCoordinates.resolveSite`), and callers may cache that
/// derived value back into their in-memory `AstroConfig` without ever
/// writing it to disk.
public struct SiteRule: Codable, Equatable, Sendable {
    public var latitudeDeg: Double?
    public var longitudeDeg: Double?

    public init(latitudeDeg: Double? = nil, longitudeDeg: Double? = nil) {
        self.latitudeDeg = latitudeDeg
        self.longitudeDeg = longitudeDeg
    }

    private enum CodingKeys: String, CodingKey {
        case latitudeDeg, longitudeDeg
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.latitudeDeg = try container.decodeIfPresent(Double.self, forKey: .latitudeDeg)
        self.longitudeDeg = try container.decodeIfPresent(Double.self, forKey: .longitudeDeg)
    }
}

/// R10-B6: opt-in Open-Meteo cloud-cover forecast (Tonight page tile +
/// calendar "Felhő" column). This struct is only the on/off switch and its
/// persistence -- the actual HTTP fetch lives entirely in the app layer
/// (`Sources/AstroToolApp/WeatherService.swift`); AstroCore itself never
/// makes a network call (`WelcomeView`'s "minden lokálisan fut" promise).
/// Off by default: enabling it is what makes the configured site's
/// coordinates leave the machine at all, so silence-by-default matters here
/// more than for any other rule in this file.
public struct WeatherRule: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WeatherRule()
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
    }
}

/// Wave 0 seam (V3 pre-stack program, `docs/superpowers/specs/
/// 2026-08-20-v3-prestack-program.md` section 5.5, Derült-trigger): the
/// future opt-in "tell me when it clears tonight" notification switch,
/// following `WeatherRule`'s own pattern exactly -- a single `enabled` flag,
/// off by default, because enabling it is what will let that feature request
/// `UNUserNotificationCenter` permission and read `WeatherService`, so
/// silence-by-default matters here the same way it does for `WeatherRule`.
/// 5.5's own commit (V3 pre-stack program section 5.5, Derült-trigger): adds
/// `checkHourLocal` -- the local hour of day (0-23) the afternoon "has it
/// cleared up?" check is allowed to actually fire a notification at, per the
/// spec's own "délutáni ablak (pl. 14:00-16:00)" -- additive, same
/// `decodeIfPresent(...) ?? default` pattern every other field in this file
/// uses, so a config.json written before this field existed still decodes
/// cleanly at the honest `14` default rather than throwing.
public struct NotificationRule: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var checkHourLocal: Int

    public init(enabled: Bool = false, checkHourLocal: Int = 14) {
        self.enabled = enabled
        self.checkHourLocal = checkHourLocal
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, checkHourLocal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NotificationRule()
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        self.checkHourLocal = try container.decodeIfPresent(Int.self, forKey: .checkHourLocal) ?? defaults.checkHourLocal
    }
}

/// R11-T15/F16: one named observing site -- the "több helyszín" (multiple
/// sites) config unit. Unlike `SiteRule` (a single optional lat/lon pair,
/// still kept around unchanged for backward compatibility -- see
/// `AstroConfig.sites`'s own doc comment), every field here is required:
/// a site with no name or no coordinate isn't a usable entry at all, so
/// there's nothing sensible to default it to the way `SiteRule`'s `nil`
/// means "derive it from the library instead".
public struct SiteProfile: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var latitudeDeg: Double
    public var longitudeDeg: Double
    /// Exactly one entry across a whole `sites` list is expected to carry
    /// `true` (the Settings list-editor's radio button enforces this) --
    /// `defaultSite(in:)` is the single place that assumption gets consumed,
    /// with a defensive fallback for a hand-edited config.json that breaks it.
    public var isDefault: Bool

    /// `SiteProfile` has no separate database identity -- `name` doubles as
    /// `Identifiable`'s `id` (site names are the user-facing key everywhere
    /// else too: the `site:<name>` session tag, `plan --site <name>`), which
    /// is enough for `ForEach`/list-editor use in the app layer without a
    /// synthetic UUID nobody else would ever see.
    public var id: String { name }

    public init(name: String, latitudeDeg: Double, longitudeDeg: Double, isDefault: Bool = false) {
        self.name = name
        self.latitudeDeg = latitudeDeg
        self.longitudeDeg = longitudeDeg
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey {
        case name, latitudeDeg, longitudeDeg, isDefault
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.latitudeDeg = try container.decode(Double.self, forKey: .latitudeDeg)
        self.longitudeDeg = try container.decode(Double.self, forKey: .longitudeDeg)
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    /// The site to plan against absent an explicit `--site`/site-Picker
    /// choice: the entry flagged `isDefault`, falling back to the first
    /// entry when the list has exactly one (the ticket's own "isDefault
    /// site (vagy az egyetlen)" rule -- a single-site list trivially IS its
    /// own default even without the flag set) or, defensively, when a
    /// hand-edited config.json has several sites with NONE flagged default
    /// (the Settings list-editor's radio button always keeps exactly one
    /// `isDefault == true`, but `AstroConfig` is loaded from whatever's
    /// actually on disk, not just what the app itself ever wrote). `nil`
    /// only when `sites` itself is empty.
    public static func defaultSite(in sites: [SiteProfile]) -> SiteProfile? {
        sites.first(where: \.isDefault) ?? sites.first
    }
}

/// R11-T6/F3: Hold-tudatos szűrő-ajánlás config -- which FITS `FILTER`
/// values count as "narrowband" (Ha/OIII/SII/dual-/tri-band light-pollution
/// filters) vs. everything else ("broadband", including a plain OSC/DSLR
/// session shooting no filter at all) for `FilterAdvisor.advice`'s NB/BB
/// category split. Matched case-insensitively against real FITS `FILTER`
/// values (same convention `GoalTag.isFilterGoalTag` already uses for its
/// own filter-name comparisons). Config-only for now -- no dedicated
/// Settings field, same "plumbed through, editable via config.json" stance
/// `WeatherRule`/`ExposeRule` started with before their own UI landed.
public struct PlanRule: Codable, Equatable, Sendable {
    public var narrowbandFilters: [String]

    public init(narrowbandFilters: [String] = [
        "Ha", "OIII", "SII", "L-eXtreme", "L-Ultimate", "L-Enhance", "Dual-band",
    ]) {
        self.narrowbandFilters = narrowbandFilters
    }

    private enum CodingKeys: String, CodingKey {
        case narrowbandFilters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PlanRule()
        self.narrowbandFilters = try container.decodeIfPresent([String].self, forKey: .narrowbandFilters) ?? defaults.narrowbandFilters
    }
}

/// Library-wide default for targets without an explicit overall goal. The
/// factory baseline is deliberately concrete and visible: 10 hours on a
/// 23.5 × 15.6 mm APS-C sensor at f/5.
public struct IntegrationReferenceRule: Codable, Equatable, Sendable {
    public var baseHours: Double
    public var referenceSensorWidthMM: Double
    public var referenceSensorHeightMM: Double
    public var referenceFNumber: Double
    public var referenceEfficiency: Double
    /// The target difficulty tied to `baseHours`. Mean surface brightness is
    /// used rather than integrated magnitude, because a large nebula spreads
    /// the same total light over far more pixels than a compact object.
    public var referenceSurfaceBrightnessMagPerArcsec2: Double
    /// Planning guardrails: keep the heuristic useful and attainable instead
    /// of turning uncertain catalog photometry into hundreds of hours.
    public var minimumTargetFactor: Double
    public var maximumTargetFactor: Double

    public init(
        baseHours: Double = 10,
        referenceSensorWidthMM: Double = 23.5,
        referenceSensorHeightMM: Double = 15.6,
        referenceFNumber: Double = 5,
        referenceEfficiency: Double = 1,
        referenceSurfaceBrightnessMagPerArcsec2: Double = 22,
        minimumTargetFactor: Double = 0.5,
        maximumTargetFactor: Double = 3
    ) {
        self.baseHours = baseHours
        self.referenceSensorWidthMM = referenceSensorWidthMM
        self.referenceSensorHeightMM = referenceSensorHeightMM
        self.referenceFNumber = referenceFNumber
        self.referenceEfficiency = referenceEfficiency
        self.referenceSurfaceBrightnessMagPerArcsec2 = referenceSurfaceBrightnessMagPerArcsec2
        self.minimumTargetFactor = minimumTargetFactor
        self.maximumTargetFactor = maximumTargetFactor
    }

    private enum CodingKeys: String, CodingKey {
        case baseHours, referenceSensorWidthMM, referenceSensorHeightMM
        case referenceFNumber, referenceEfficiency
        case referenceSurfaceBrightnessMagPerArcsec2, minimumTargetFactor, maximumTargetFactor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IntegrationReferenceRule()
        baseHours = try container.decodeIfPresent(Double.self, forKey: .baseHours) ?? defaults.baseHours
        referenceSensorWidthMM = try container.decodeIfPresent(Double.self, forKey: .referenceSensorWidthMM) ?? defaults.referenceSensorWidthMM
        referenceSensorHeightMM = try container.decodeIfPresent(Double.self, forKey: .referenceSensorHeightMM) ?? defaults.referenceSensorHeightMM
        referenceFNumber = try container.decodeIfPresent(Double.self, forKey: .referenceFNumber) ?? defaults.referenceFNumber
        referenceEfficiency = try container.decodeIfPresent(Double.self, forKey: .referenceEfficiency) ?? defaults.referenceEfficiency
        referenceSurfaceBrightnessMagPerArcsec2 = try container.decodeIfPresent(
            Double.self, forKey: .referenceSurfaceBrightnessMagPerArcsec2
        ) ?? defaults.referenceSurfaceBrightnessMagPerArcsec2
        minimumTargetFactor = try container.decodeIfPresent(Double.self, forKey: .minimumTargetFactor) ?? defaults.minimumTargetFactor
        maximumTargetFactor = try container.decodeIfPresent(Double.self, forKey: .maximumTargetFactor) ?? defaults.maximumTargetFactor
    }
}

/// R11-T16/F20: AstroBin's own numeric equipment-database filter IDs, keyed
/// by the FITS `FILTER` name Astro-Tool already reads off scanned lights.
/// When present, `AcquisitionExport`'s AstroBin CSV writes the numeric ID
/// AstroBin's bulk importer expects for that filter's column instead of the
/// bare name -- looked up case-insensitively/trimmed at export time (same
/// convention `CalibAnalyzer`'s own filter matching uses), so `"Ha"` in the
/// mapping still matches a scanned `"HA"`/`" Ha "` header value. A filter
/// with no entry here still exports fine (the raw name goes out as-is, a
/// perfectly valid CSV cell) -- just not LINKED to AstroBin's equipment
/// database, which is what the export-time warning (CLI stderr / app toast)
/// surfaces.
public struct AstroBinRule: Codable, Equatable, Sendable {
    public var filterIds: [String: Int]

    public init(filterIds: [String: Int] = [:]) {
        self.filterIds = filterIds
    }

    public static func normalizedFilterKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Case/whitespace-insensitive lookup. If a legacy hand-edited config
    /// contains duplicate normalized keys, raw-key lexical order makes the
    /// selected value deterministic on every decode/platform.
    public func filterID(for rawFilter: String) -> Int? {
        let key = Self.normalizedFilterKey(rawFilter)
        guard !key.isEmpty else { return nil }
        guard let rawKey = filterIds.keys
            .filter({ Self.normalizedFilterKey($0) == key })
            .sorted()
            .first
        else { return nil }
        return filterIds[rawKey]
    }

    /// Save-boundary mutation: removes every case/spacing variant of the
    /// same key, then preserves the newly entered display spelling.
    public mutating func setFilterID(_ id: Int, for name: String) {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalizedFilterKey(displayName)
        guard !key.isEmpty else { return }
        for existing in Array(filterIds.keys) where Self.normalizedFilterKey(existing) == key {
            filterIds.removeValue(forKey: existing)
        }
        filterIds[displayName] = id
    }

    private enum CodingKeys: String, CodingKey {
        case filterIds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AstroBinRule()
        self.filterIds = try container.decodeIfPresent([String: Int].self, forKey: .filterIds) ?? defaults.filterIds
    }
}

/// Top-level, user-editable configuration for Astro-Tool. Every field falls
/// back to a sensible default when missing from the on-disk JSON, so old
/// config files stay valid after new fields are added, and unknown keys in
/// the JSON are silently ignored rather than causing a decode error.
public struct AstroConfig: Codable, Equatable, Sendable {
    public var rootPath: String
    /// Bare directory names (no `/`) excluded from scanning, matched
    /// case-insensitively, but ONLY at the library root -- a target,
    /// capture, or filter folder several levels down that happens to share
    /// the name (e.g. a target literally called "Tools") is never affected.
    /// An entry that itself contains `/` is instead matched against the
    /// full root-relative path at any depth, the same way `excludedPaths`
    /// works, for a user who wants to hide one specific deeper folder by
    /// name. See `ExclusionRules.isExcludedDir`.
    public var excludedDirNames: [String]
    /// Root-relative paths to exclude from scanning, beyond `excludedDirNames`.
    public var excludedPaths: [String]
    public var residuePatterns: [String]
    /// Residue filename globs that only count for files whose
    /// `PathClassifier` area is `.sessions` -- the vocabulary that is junk
    /// when loose in a session date dir but first-class, WANTED
    /// `StackVariantKind`/`looksLikeStackOutput` output in `stacks/`/
    /// `processed/` (`starless_*` variants, GraXpert intermediates, Siril
    /// `result*` integrations), which `residuePatterns`'s universal list
    /// therefore can never carry (see its doc comment for the reverted
    /// attempt). Consulted by `ResidueMatcher.category`/`isResidue` --
    /// i.e. it feeds both `CleanupReport`'s cleanup summary (category
    /// `residue-session`) and `LibraryScanner`'s IMAGETYP-promotion guard
    /// -- and deliberately NOT by `StackDiscovery`, whose stack-variant
    /// recognition keeps using only the universal list. Every default is
    /// verified against a copy of the owner's real library to match only
    /// confirmed stack byproducts in the sessions area, zero genuine subs
    /// (`ResidueMatcherRealLibraryTests`).
    public var sessionResiduePatterns: [String]
    public var residueDirNames: [String]
    /// Directory names (case-sensitive match on the path component) that are
    /// known outputs of coexisting tools -- currently `tools/rate/
    /// LightFrameRater.py`'s `Stack`/`Review`/`Reject` triage folders, its
    /// `light_frame_rating_report_assets` report bundle, and `masters` (a
    /// deliberate convention: stacked master files kept in a `masters/`
    /// subfolder right next to the raws that produced them, e.g.
    /// `sessions/<target>/<date>/darks/masters/`). The audit engine
    /// recognizes these instead of flagging them as suspicious.
    public var toolOutputDirNames: [String]
    public var intentional: IntentionalPatterns
    public var wideField: WideFieldRule
    public var calib: CalibRule
    public var rating: RatingRule
    public var stats: StatsRule
    public var site: SiteRule
    /// R11-T15/F16: named multi-site profiles -- when non-empty, this list
    /// (not `site`/the FITS-median fallback) is authoritative for the
    /// planner (`Planner.resolveSite`'s own doc comment covers the exact
    /// priority rule). `[]` (the default) leaves the pre-T15 single-site
    /// behavior completely untouched: `site`'s explicit coordinate, else the
    /// library-wide FITS `SITELAT`/`SITELONG` median.
    ///
    /// BACKWARD COMPATIBILITY (the ticket's own spec): an old config.json
    /// that only ever set `site.latitudeDeg`/`site.longitudeDeg` has no
    /// `"sites"` key at all -- `init(from:)` below synthesizes a one-element
    /// list from it ("Alapértelmezett", `isDefault: true`) SO THAT existing
    /// single-site configs immediately work with every `sites`-aware
    /// feature (the site-Picker, `--site`, `NightsPage`'s Site column). This
    /// happens ONLY in memory: the on-disk `config.json` is never rewritten
    /// by this decode step, and a plain Settings "Mentés" from a tab that
    /// never touches Helyszín leaves the file untouched -- only the Helyszín
    /// tab's own save (`LocationSettingsView`) writes `sites` explicitly,
    /// and it always mirrors the chosen default back into `site` too, so an
    /// older CLI build (which only ever reads `site`, not `sites`) keeps
    /// working unmodified against a config.json this app saved.
    public var sites: [SiteProfile]
    public var expose: ExposeRule
    public var weather: WeatherRule
    /// Wave 0 seam (V3 pre-stack program, section 5.5, Derült-trigger): see
    /// `NotificationRule`'s own doc comment. Off by default, read by nothing
    /// until 5.5 lands.
    public var notification: NotificationRule
    public var plan: PlanRule
    public var integrationReference: IntegrationReferenceRule
    /// User-defined camera + optic combinations for manual Discovery FOV
    /// planning. An empty list preserves the legacy automatic behavior that
    /// derives the dominant setup from scanned image/WCS metadata.
    public var imagingSetups: [ImagingSetupProfile]
    /// R11-T16/F20: AstroBin filter-ID mapping. Additive, empty by default --
    /// see `AstroBinRule`'s own doc comment.
    public var astrobin: AstroBinRule

    public init(
        rootPath: String = "",
        excludedDirNames: [String] = ["tools"],
        excludedPaths: [String] = [],
        residuePatterns: [String] = [
            "*.seq", "*.lst", "*_conv*", "*_bkg*", "*_pp_*", "r_*", "bkg_*", ".DS_Store",
            // Stack-PRODUCT names (not intermediate files) confirmed against
            // a real library as loose session-area residue that inherits
            // IMAGETYP='Light Frame' and gets wrongly promoted by
            // `LibraryScanner`'s IMAGETYP-based loose-frame refinement (see
            // `ResidueMatcherRealLibraryTests`). Deliberately EXCLUDES
            // `starless`/`starmask`/`graxpert_result` tokens despite those
            // accounting for most of the confirmed pollution: this same
            // vocabulary is first-class, WANTED `StackVariantKind`
            // (`.starless`/`.starmask`/`.edited`) output in the `stacks/`/
            // `processed/` areas (`Stats/StackDiscovery.swift`), which
            // hardcodes this exact default list to decide what to skip as
            // junk before variant-kind classification runs. Adding those
            // tokens here made `StackDiscovery` reject real stack variants
            // (6 test failures: `StackDiscoveryTests`, `ResultsQueryTests`,
            // `ResultsStoreTests`, `CLISmokeTests`) -- residue-ness for that
            // vocabulary is area-dependent (junk loose in `sessions/`, a
            // keeper in `stacks/`/`processed/`), which a single flat global
            // pattern list can't express: that vocabulary lives in
            // `sessionResiduePatterns` below instead, which only applies to
            // `.sessions`-area paths. Catches 10 of 53 confirmed
            // wrongly-promoted files with zero matches among ~4200 other
            // session light frames.
            "veralux_*", "*stack_work*", "*_synt*", "fixstars*", "*star recomposition result*",
        ],
        sessionResiduePatterns: [String] = [
            "starless*", "starmask*", "*graxpert*", "result_*",
        ],
        residueDirNames: [String] = ["process"],
        toolOutputDirNames: [String] = ["Stack", "Review", "Reject", "light_frame_rating_report_assets", "masters"],
        intentional: IntentionalPatterns = IntentionalPatterns(),
        wideField: WideFieldRule = WideFieldRule(),
        calib: CalibRule = CalibRule(),
        rating: RatingRule = RatingRule(),
        stats: StatsRule = StatsRule(),
        site: SiteRule = SiteRule(),
        sites: [SiteProfile] = [],
        expose: ExposeRule = ExposeRule(),
        weather: WeatherRule = WeatherRule(),
        notification: NotificationRule = NotificationRule(),
        plan: PlanRule = PlanRule(),
        integrationReference: IntegrationReferenceRule = IntegrationReferenceRule(),
        imagingSetups: [ImagingSetupProfile] = [],
        astrobin: AstroBinRule = AstroBinRule()
    ) {
        self.rootPath = rootPath
        self.excludedDirNames = excludedDirNames
        self.excludedPaths = excludedPaths
        self.residuePatterns = residuePatterns
        self.sessionResiduePatterns = sessionResiduePatterns
        self.residueDirNames = residueDirNames
        self.toolOutputDirNames = toolOutputDirNames
        self.intentional = intentional
        self.wideField = wideField
        self.calib = calib
        self.rating = rating
        self.stats = stats
        self.site = site
        self.sites = sites
        self.expose = expose
        self.weather = weather
        self.notification = notification
        self.plan = plan
        self.integrationReference = integrationReference
        self.imagingSetups = imagingSetups
        self.astrobin = astrobin
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath, excludedDirNames, excludedPaths, residuePatterns, sessionResiduePatterns, residueDirNames, toolOutputDirNames
        case intentional, wideField, calib, rating, stats, site, sites, expose, weather, notification, plan, integrationReference, imagingSetups, astrobin
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AstroConfig()
        self.rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath) ?? defaults.rootPath
        self.excludedDirNames = try container.decodeIfPresent([String].self, forKey: .excludedDirNames) ?? defaults.excludedDirNames
        self.excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? defaults.excludedPaths
        self.residuePatterns = try container.decodeIfPresent([String].self, forKey: .residuePatterns) ?? defaults.residuePatterns
        self.sessionResiduePatterns = try container.decodeIfPresent([String].self, forKey: .sessionResiduePatterns) ?? defaults.sessionResiduePatterns
        self.residueDirNames = try container.decodeIfPresent([String].self, forKey: .residueDirNames) ?? defaults.residueDirNames
        self.toolOutputDirNames = try container.decodeIfPresent([String].self, forKey: .toolOutputDirNames) ?? defaults.toolOutputDirNames
        self.intentional = try container.decodeIfPresent(IntentionalPatterns.self, forKey: .intentional) ?? defaults.intentional
        self.wideField = try container.decodeIfPresent(WideFieldRule.self, forKey: .wideField) ?? defaults.wideField
        self.calib = try container.decodeIfPresent(CalibRule.self, forKey: .calib) ?? defaults.calib
        self.rating = try container.decodeIfPresent(RatingRule.self, forKey: .rating) ?? defaults.rating
        // `StatsRule.legacyDecoded`, not `defaults.stats`: an existing
        // config file with no `stats` block must not silently adopt the
        // widened `excludeLabels` default -- see that property's own doc.
        self.stats = try container.decodeIfPresent(StatsRule.self, forKey: .stats) ?? StatsRule.legacyDecoded
        self.site = try container.decodeIfPresent(SiteRule.self, forKey: .site) ?? defaults.site
        // R11-T15/F16: see `sites`'s own doc comment for the full backward-
        // compatibility rationale -- an explicit `"sites"` key always wins
        // (covers "only new", "both old and new" -- the new list is treated
        // as authoritative rather than merged with `site`); missing
        // entirely, a filled-in legacy `site` synthesizes a one-element
        // default list; neither present leaves `sites` empty (the FITS-
        // median automatika keeps working exactly as before T15).
        if let decodedSites = try container.decodeIfPresent([SiteProfile].self, forKey: .sites) {
            self.sites = decodedSites
        } else if let lat = self.site.latitudeDeg, let lon = self.site.longitudeDeg {
            self.sites = [SiteProfile(name: "Alapértelmezett", latitudeDeg: lat, longitudeDeg: lon, isDefault: true)]
        } else {
            self.sites = []
        }
        self.expose = try container.decodeIfPresent(ExposeRule.self, forKey: .expose) ?? defaults.expose
        self.weather = try container.decodeIfPresent(WeatherRule.self, forKey: .weather) ?? defaults.weather
        self.notification = try container.decodeIfPresent(NotificationRule.self, forKey: .notification) ?? defaults.notification
        self.plan = try container.decodeIfPresent(PlanRule.self, forKey: .plan) ?? defaults.plan
        self.integrationReference = try container.decodeIfPresent(IntegrationReferenceRule.self, forKey: .integrationReference) ?? defaults.integrationReference
        self.imagingSetups = try container.decodeIfPresent([ImagingSetupProfile].self, forKey: .imagingSetups) ?? defaults.imagingSetups
        self.astrobin = try container.decodeIfPresent(AstroBinRule.self, forKey: .astrobin) ?? defaults.astrobin
    }

    /// Loads and decodes the config from `url`. Throws on I/O failure
    /// (missing/unreadable file) or malformed JSON; missing keys within
    /// otherwise-valid JSON fall back to defaults instead of throwing.
    public static func load(from url: URL) throws -> AstroConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AstroConfig.self, from: data)
    }

    /// Persists the config as pretty-printed, sorted-key JSON via
    /// `WriteGuard`, at `.astro_tool/config.json` under the guard's root.
    /// This is the only sanctioned way to save a config to disk — it never
    /// writes anywhere outside the tool's own directory.
    public func save(using writeGuard: WriteGuard) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try writeGuard.writeToolFile(relativePath: "config.json", data: data)
    }
}
