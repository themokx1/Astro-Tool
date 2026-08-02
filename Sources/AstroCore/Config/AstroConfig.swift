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
public struct CalibRule: Codable, Equatable, Sendable {
    public var tempToleranceC: Double
    public var exposureToleranceS: Double
    public var darkMaxAgeMonths: Int

    public init(
        tempToleranceC: Double = 0.5,
        exposureToleranceS: Double = 0.0,
        darkMaxAgeMonths: Int = 6
    ) {
        self.tempToleranceC = tempToleranceC
        self.exposureToleranceS = exposureToleranceS
        self.darkMaxAgeMonths = darkMaxAgeMonths
    }

    private enum CodingKeys: String, CodingKey {
        case tempToleranceC, exposureToleranceS, darkMaxAgeMonths
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CalibRule()
        self.tempToleranceC = try container.decodeIfPresent(Double.self, forKey: .tempToleranceC) ?? defaults.tempToleranceC
        self.exposureToleranceS = try container.decodeIfPresent(Double.self, forKey: .exposureToleranceS) ?? defaults.exposureToleranceS
        self.darkMaxAgeMonths = try container.decodeIfPresent(Int.self, forKey: .darkMaxAgeMonths) ?? defaults.darkMaxAgeMonths
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
    /// LightFrameRater.py`'s `Stack`/`Review`/`Reject` triage folders and its
    /// `light_frame_rating_report_assets` report bundle. The audit engine
    /// recognizes these instead of flagging them as suspicious.
    public var toolOutputDirNames: [String]
    public var intentional: IntentionalPatterns
    public var wideField: WideFieldRule
    public var calib: CalibRule
    public var rating: RatingRule

    public init(
        rootPath: String = "/Volumes/images/Astro",
        excludedDirNames: [String] = ["tools"],
        excludedPaths: [String] = [],
        residuePatterns: [String] = ["*.seq", "*.lst", "*_conv*", "*_bkg*", "*_pp_*", "r_*", "bkg_*", ".DS_Store"],
        residueDirNames: [String] = ["process"],
        toolOutputDirNames: [String] = ["Stack", "Review", "Reject", "light_frame_rating_report_assets"],
        intentional: IntentionalPatterns = IntentionalPatterns(),
        wideField: WideFieldRule = WideFieldRule(),
        calib: CalibRule = CalibRule(),
        rating: RatingRule = RatingRule()
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
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath, excludedDirNames, excludedPaths, residuePatterns, residueDirNames, toolOutputDirNames
        case intentional, wideField, calib, rating
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
