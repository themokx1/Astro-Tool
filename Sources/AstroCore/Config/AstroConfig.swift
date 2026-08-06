import Foundation

/// Rule for classifying frames as wide-field vs. narrow-field/deep-sky,
/// plus per-target manual overrides.
public struct WideFieldRule: Codable, Equatable, Sendable {
    public var extensions: [String]
    public var maxFocalLengthMM: Double
    public var nameMarkers: [String]
    /// Target name -> manual classification (true == wide-field), overriding
    /// the heuristic above.
    public var overrides: [String: Bool]

    public init(
        extensions: [String] = ["cr3", "tif"],
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
        coolerToleranceC: Double = 1.0
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
    }

    private enum CodingKeys: String, CodingKey {
        case tempToleranceC, exposureToleranceS, darkMaxAgeMonths
        case matchGain, matchOffset, matchBinning, matchCamera
        case gainTolerance, exposureToleranceFraction
        case flatMaxAgeDays, rotatorToleranceDeg, coolerToleranceC
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
    /// bad" marker (`_hibas` = "faulty" in Hungarian). The session still
    /// shows up in per-session details, just flagged
    /// `isExcludedFromTotals`.
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
        excludeLabels: [String] = ["hibas"],
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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StatsRule()
        self.excludeLabels = try container.decodeIfPresent([String].self, forKey: .excludeLabels) ?? defaults.excludeLabels
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

/// Top-level, user-editable configuration for Astro-Tool. Every field falls
/// back to a sensible default when missing from the on-disk JSON, so old
/// config files stay valid after new fields are added, and unknown keys in
/// the JSON are silently ignored rather than causing a decode error.
public struct AstroConfig: Codable, Equatable, Sendable {
    public var rootPath: String
    public var excludedDirNames: [String]
    /// Root-relative paths to exclude from scanning, beyond `excludedDirNames`.
    public var excludedPaths: [String]
    public var residuePatterns: [String]
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
    public var expose: ExposeRule
    public var weather: WeatherRule

    public init(
        rootPath: String = "/Volumes/images/Astro",
        excludedDirNames: [String] = ["tools"],
        excludedPaths: [String] = [],
        residuePatterns: [String] = ["*.seq", "*.lst", "*_conv*", "*_bkg*", "*_pp_*", "r_*", "bkg_*", ".DS_Store"],
        residueDirNames: [String] = ["process"],
        toolOutputDirNames: [String] = ["Stack", "Review", "Reject", "light_frame_rating_report_assets", "masters"],
        intentional: IntentionalPatterns = IntentionalPatterns(),
        wideField: WideFieldRule = WideFieldRule(),
        calib: CalibRule = CalibRule(),
        rating: RatingRule = RatingRule(),
        stats: StatsRule = StatsRule(),
        site: SiteRule = SiteRule(),
        expose: ExposeRule = ExposeRule(),
        weather: WeatherRule = WeatherRule()
    ) {
        self.rootPath = rootPath
        self.excludedDirNames = excludedDirNames
        self.excludedPaths = excludedPaths
        self.residuePatterns = residuePatterns
        self.residueDirNames = residueDirNames
        self.toolOutputDirNames = toolOutputDirNames
        self.intentional = intentional
        self.wideField = wideField
        self.calib = calib
        self.rating = rating
        self.stats = stats
        self.site = site
        self.expose = expose
        self.weather = weather
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath, excludedDirNames, excludedPaths, residuePatterns, residueDirNames, toolOutputDirNames
        case intentional, wideField, calib, rating, stats, site, expose, weather
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AstroConfig()
        self.rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath) ?? defaults.rootPath
        self.excludedDirNames = try container.decodeIfPresent([String].self, forKey: .excludedDirNames) ?? defaults.excludedDirNames
        self.excludedPaths = try container.decodeIfPresent([String].self, forKey: .excludedPaths) ?? defaults.excludedPaths
        self.residuePatterns = try container.decodeIfPresent([String].self, forKey: .residuePatterns) ?? defaults.residuePatterns
        self.residueDirNames = try container.decodeIfPresent([String].self, forKey: .residueDirNames) ?? defaults.residueDirNames
        self.toolOutputDirNames = try container.decodeIfPresent([String].self, forKey: .toolOutputDirNames) ?? defaults.toolOutputDirNames
        self.intentional = try container.decodeIfPresent(IntentionalPatterns.self, forKey: .intentional) ?? defaults.intentional
        self.wideField = try container.decodeIfPresent(WideFieldRule.self, forKey: .wideField) ?? defaults.wideField
        self.calib = try container.decodeIfPresent(CalibRule.self, forKey: .calib) ?? defaults.calib
        self.rating = try container.decodeIfPresent(RatingRule.self, forKey: .rating) ?? defaults.rating
        self.stats = try container.decodeIfPresent(StatsRule.self, forKey: .stats) ?? defaults.stats
        self.site = try container.decodeIfPresent(SiteRule.self, forKey: .site) ?? defaults.site
        self.expose = try container.decodeIfPresent(ExposeRule.self, forKey: .expose) ?? defaults.expose
        self.weather = try container.decodeIfPresent(WeatherRule.self, forKey: .weather) ?? defaults.weather
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
