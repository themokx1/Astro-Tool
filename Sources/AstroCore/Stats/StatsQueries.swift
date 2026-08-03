import Foundation

/// Per-target roll-up: integration time, exposure/camera/filter breakdown,
/// session coverage, and the wide-field classification. Integration time and
/// the exposure/camera/filter breakdowns only ever count RAW session lights
/// (`area == .sessions && role == .light`) -- stacks/processed frames must
/// never inflate these numbers, since they're re-derived from the same
/// underlying lights.
public struct TargetStats: Codable, Sendable, Equatable {
    public var target: String
    public var isWideField: Bool
    /// Now EQUALS `usableIntegrationSeconds` -- the headline number must be
    /// the TRUE one (deduped, non-rejected, non-excluded-session), not the
    /// naive sum over every file `PathClassifier` calls a light. Kept as its
    /// own field (rather than just renaming it) since it's the one CLI/app
    /// callers have always displayed.
    public var totalIntegrationSeconds: Double
    /// Raw date-dir names (as they appear on disk under
    /// `sessions/<target>/`), sorted ascending. Covers every session-area
    /// file for the target, not just lights.
    public var sessionDates: [String]
    /// Light-frame count per exposure length, keyed by the exposure's
    /// `Double.description` (e.g. `"300.0"`); frames with no exptime (no
    /// `fits_meta` row, or a row with a nil `exptime`) are counted under the
    /// `"unknown"` key instead and contribute 0 seconds. Computed from the
    /// USABLE bucket only (see `usableIntegrationSeconds`).
    public var exposureBreakdown: [String: Int]
    /// The latest canonical start date (`YYYY-MM-DD`) among the target's
    /// `sessionDates` that parse as a real date; `nil` if none do.
    public var lastSessionDate: String?
    /// Distinct, sorted `instrume` values across the target's USABLE session
    /// lights.
    public var cameras: [String]
    /// Distinct, sorted `filter` values across the target's USABLE session
    /// lights -- excludes values that only ever appeared on non-frame/
    /// derivative files (e.g. a Siril `starless_*.fit`'s `FILTER` header).
    public var filters: [String]
    /// This target's target-level tags (from the `tags` table), sorted.
    /// `[]` for a target with none -- always present so older callers that
    /// never set it still get a valid, empty list.
    public var tags: [String]
    /// Sum of exptime over deduped, non-rejected, non-excluded-session light
    /// frames -- the "true" integration time. Identical to
    /// `totalIntegrationSeconds`.
    public var usableIntegrationSeconds: Double
    /// Sum of exptime over EVERY session light-role file, exactly as this
    /// tool computed `totalIntegrationSeconds` before R4-1 -- no dedup, no
    /// non-frame filtering, no excluded-session filtering. Kept so the app/
    /// CLI can show "you have X, but only Y is real" side by side.
    public var grossIntegrationSeconds: Double
    /// Count of deduped, non-rejected, non-excluded-session light frames --
    /// the frame-count counterpart of `usableIntegrationSeconds`.
    public var usableFrameCount: Int
    /// Extra hardlinked/derivative copies of the same physical frame that
    /// were dropped during dedup (see `FrameSet.lightBuckets`).
    public var duplicateLinkCount: Int
    /// Deduped frames living under a `Reject/` triage subdirectory -- the
    /// user explicitly threw these out.
    public var rejectedFrameCount: Int
    /// Files under `lights/` that were never real frames (wrong extension,
    /// or a processed-derivative name).
    public var nonFrameFileCount: Int
    /// Raw date-dir names, among `sessionDates`, whose `SessionDateKind` is
    /// `.labeled` with a label in `config.stats.excludeLabels` (e.g. the
    /// user's own `_hibas` "bad night" marker) -- excluded from every
    /// USABLE total above, even though they're still counted in
    /// `sessionDates` and have their own `SessionDetail`.
    public var excludedSessionDates: [String]

    public init(
        target: String,
        isWideField: Bool,
        totalIntegrationSeconds: Double,
        sessionDates: [String],
        exposureBreakdown: [String: Int],
        lastSessionDate: String?,
        cameras: [String],
        filters: [String],
        tags: [String] = [],
        usableIntegrationSeconds: Double? = nil,
        grossIntegrationSeconds: Double? = nil,
        usableFrameCount: Int = 0,
        duplicateLinkCount: Int = 0,
        rejectedFrameCount: Int = 0,
        nonFrameFileCount: Int = 0,
        excludedSessionDates: [String] = []
    ) {
        self.target = target
        self.isWideField = isWideField
        self.totalIntegrationSeconds = totalIntegrationSeconds
        self.sessionDates = sessionDates
        self.exposureBreakdown = exposureBreakdown
        self.lastSessionDate = lastSessionDate
        self.cameras = cameras
        self.filters = filters
        self.tags = tags
        self.usableIntegrationSeconds = usableIntegrationSeconds ?? totalIntegrationSeconds
        self.grossIntegrationSeconds = grossIntegrationSeconds ?? totalIntegrationSeconds
        self.usableFrameCount = usableFrameCount
        self.duplicateLinkCount = duplicateLinkCount
        self.rejectedFrameCount = rejectedFrameCount
        self.nonFrameFileCount = nonFrameFileCount
        self.excludedSessionDates = excludedSessionDates
    }

    private enum CodingKeys: String, CodingKey {
        case target, isWideField, totalIntegrationSeconds, sessionDates, exposureBreakdown,
             lastSessionDate, cameras, filters, tags, usableIntegrationSeconds, grossIntegrationSeconds,
             usableFrameCount, duplicateLinkCount, rejectedFrameCount, nonFrameFileCount, excludedSessionDates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        isWideField = try c.decode(Bool.self, forKey: .isWideField)
        totalIntegrationSeconds = try c.decode(Double.self, forKey: .totalIntegrationSeconds)
        sessionDates = try c.decode([String].self, forKey: .sessionDates)
        exposureBreakdown = try c.decode([String: Int].self, forKey: .exposureBreakdown)
        lastSessionDate = try c.decodeIfPresent(String.self, forKey: .lastSessionDate)
        cameras = try c.decode([String].self, forKey: .cameras)
        filters = try c.decode([String].self, forKey: .filters)
        // Absent in JSON produced before this field existed -- decode
        // leniently so older cached/serialized stats stay loadable.
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        // All additive R4-1 fields: absent in pre-R4-1 JSON, so fall back to
        // values consistent with the old (gross-only) semantics rather than
        // failing to decode.
        usableIntegrationSeconds = try c.decodeIfPresent(Double.self, forKey: .usableIntegrationSeconds) ?? totalIntegrationSeconds
        grossIntegrationSeconds = try c.decodeIfPresent(Double.self, forKey: .grossIntegrationSeconds) ?? totalIntegrationSeconds
        usableFrameCount = try c.decodeIfPresent(Int.self, forKey: .usableFrameCount) ?? 0
        duplicateLinkCount = try c.decodeIfPresent(Int.self, forKey: .duplicateLinkCount) ?? 0
        rejectedFrameCount = try c.decodeIfPresent(Int.self, forKey: .rejectedFrameCount) ?? 0
        nonFrameFileCount = try c.decodeIfPresent(Int.self, forKey: .nonFrameFileCount) ?? 0
        excludedSessionDates = try c.decodeIfPresent([String].self, forKey: .excludedSessionDates) ?? []
    }
}

/// Builds `TargetStats` from the scanned library. Reads only from
/// `Database` (`allFiles`/`fitsMeta`) -- never touches the filesystem.
public enum StatsQueries {
    /// One entry per distinct, non-nil `target` among session/stacks/processed
    /// files -- so a target with only stacks or only processed output (no
    /// session lights on record, e.g. calibration-only rescans or a purged
    /// sessions tree) still shows up, just with zeroed-out integration.
    /// Sorted by target name.
    public static func perTarget(db: Database, config: AstroConfig) throws -> [TargetStats] {
        let files = try db.allFiles(includeMissing: false)
        let targetNames = Set(files.compactMap { file -> String? in
            guard let target = file.target, isStatsRelevant(file.area) else { return nil }
            return target
        })

        return try targetNames.sorted().map { name in
            try computeStats(target: name, files: files, db: db, config: config)
        }
    }

    /// The stats for a single target, or `nil` if it isn't known to the
    /// library at all (no session/stacks/processed file references it).
    public static func target(_ name: String, db: Database, config: AstroConfig) throws -> TargetStats? {
        let files = try db.allFiles(includeMissing: false)
        let exists = files.contains { $0.target == name && isStatsRelevant($0.area) }
        guard exists else { return nil }
        return try computeStats(target: name, files: files, db: db, config: config)
    }

    private static func isStatsRelevant(_ area: LibraryArea) -> Bool {
        area == .sessions || area == .stacks || area == .processed
    }

    private static func computeStats(
        target: String,
        files: [FileRecord],
        db: Database,
        config: AstroConfig
    ) throws -> TargetStats {
        let sessionFiles = files.filter { $0.target == target && $0.area == .sessions }
        let sessionLights = sessionFiles.filter { $0.role == .light }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in sessionLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) {
                metaByFileID[id] = meta
            }
        }

        // Gross: the OLD (pre-R4-1) behavior, exactly -- every session
        // light-role file, no dedup, no exclusions. Kept so callers can show
        // "you have X raw, only Y is real".
        var grossSeconds: Double = 0
        for file in sessionLights {
            if let exptime = (file.id.flatMap { metaByFileID[$0] })?.exptime {
                grossSeconds += exptime
            }
        }

        let frameBuckets = FrameSet.lightBuckets(files: sessionLights, meta: metaByFileID, config: config)

        let excludedLabels = Set(config.stats.excludeLabels.map { $0.lowercased() })
        let excludedSessionDates = Set(sessionFiles.compactMap(\.sessionDate)).filter { date in
            guard let parsed = SessionDateParser.parse(date, patterns: config.intentional),
                  parsed.kind == .labeled, let label = parsed.label
            else { return false }
            return excludedLabels.contains(label.lowercased())
        }.sorted()
        let excludedSet = Set(excludedSessionDates)

        // Usable: deduped + non-rejected (from `frameBuckets`) AND not part
        // of an excluded (e.g. `_hibas`) session date -- the TRUE total.
        let usableForTotals = frameBuckets.usable.filter { file in
            guard let date = file.sessionDate else { return true }
            return !excludedSet.contains(date)
        }

        var usableSeconds: Double = 0
        var exposureBreakdown: [String: Int] = [:]
        var cameras = Set<String>()
        var filters = Set<String>()

        for file in usableForTotals {
            let meta = file.id.flatMap { metaByFileID[$0] }
            if let exptime = meta?.exptime {
                usableSeconds += exptime
                exposureBreakdown[NominalExposure.nominal(exptime).description, default: 0] += 1
            } else {
                exposureBreakdown["unknown", default: 0] += 1
            }
            if let camera = meta?.instrume { cameras.insert(camera) }
            if let filter = meta?.filter { filters.insert(filter) }
        }

        let sessionDates = Set(sessionFiles.compactMap(\.sessionDate)).sorted()
        let lastSessionDate = sessionDates
            .compactMap { SessionDateParser.parse($0, patterns: config.intentional) }
            .map(\.start)
            .max()

        let isWideField = WideFieldHeuristic.isWideField(
            target: target,
            files: usableForTotals,
            meta: metaByFileID,
            rule: config.wideField
        )

        let tags = try db.tags(target: target, sessionDate: nil)

        return TargetStats(
            target: target,
            isWideField: isWideField,
            totalIntegrationSeconds: usableSeconds,
            sessionDates: sessionDates,
            exposureBreakdown: exposureBreakdown,
            lastSessionDate: lastSessionDate,
            cameras: cameras.sorted(),
            filters: filters.sorted(),
            tags: tags,
            usableIntegrationSeconds: usableSeconds,
            grossIntegrationSeconds: grossSeconds,
            usableFrameCount: usableForTotals.count,
            duplicateLinkCount: frameBuckets.duplicateLinkCount,
            rejectedFrameCount: frameBuckets.rejected.count,
            nonFrameFileCount: frameBuckets.nonFrameFileCount,
            excludedSessionDates: excludedSessionDates
        )
    }
}
