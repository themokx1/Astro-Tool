import Foundation

/// Per-session detail roll-up for one target's session date-dir: frame
/// counts by role, integration time and exposure breakdown from the raw
/// session LIGHT frames only (same convention as `TargetStats`), plus the
/// distinct equipment signals (camera, focal length, gain/ISO, sensor temp,
/// filter) those lights were shot with, and whether the session folder has
/// its `README.txt`.
public struct SessionDetail: Codable, Sendable, Equatable {
    public var target: String
    /// Raw date-dir name, verbatim as it appears on disk under
    /// `sessions/<target>/`.
    public var dateRaw: String
    /// Raw count of role-`.light` files on record for this session --
    /// UNDEDUPED (see `usableLightCount` for the true count).
    public var lightCount: Int
    public var flatCount: Int
    public var darkCount: Int
    public var biasCount: Int
    /// Sum of exptime over this session's USABLE light frames (deduped,
    /// non-rejected, non-derivative) -- lights with no exptime contribute 0,
    /// same as `TargetStats.totalIntegrationSeconds`.
    public var integrationSeconds: Double
    /// Light-frame count per exposure length, keyed by the exposure's
    /// `Double.description`; frames with no exptime land under `"unknown"`.
    /// Computed from the USABLE bucket, same as `integrationSeconds`.
    public var exposureBreakdown: [String: Int]
    /// Distinct, sorted `instrume` values across the session's USABLE lights.
    public var cameras: [String]
    /// Distinct `focallen` values across the session's USABLE lights,
    /// rounded to the nearest 1 mm, sorted ascending.
    public var focalLengthsMM: [Double]
    /// Distinct `gain` (ISO for DSLR frames) values across the session's
    /// USABLE lights, sorted ascending.
    public var gains: [Double]
    /// Distinct `setTemp` values across the session's USABLE lights, rounded
    /// to the nearest 0.5°C, sorted ascending.
    public var sensorTempsC: [Double]
    /// Distinct, sorted `filter` values across the session's USABLE lights.
    public var filters: [String]
    /// Whether the session's date-dir has a `README.txt` on record (a
    /// `kind == "text"` file whose last path component is `README.txt`).
    public var hasReadme: Bool
    /// This session's tags (from the `tags` table, `session_date == dateRaw`),
    /// sorted. `[]` for a session with none.
    public var tags: [String]
    /// Deduped, non-rejected real light-frame count for this session -- the
    /// TRUE frame count `integrationSeconds`/`exposureBreakdown` above are
    /// derived from.
    public var usableLightCount: Int
    /// Deduped real frames under this session's `Reject/` triage
    /// subdirectory.
    public var rejectedCount: Int
    /// Extra hardlinked/derivative copies of the same physical frame
    /// dropped during dedup (see `FrameSet.lightBuckets`).
    public var duplicateLinkCount: Int
    /// Whether this session date's `SessionDateKind` is `.labeled` with a
    /// label in `config.stats.excludeLabels` (e.g. the user's own `_hibas`
    /// marker) -- the session is still listed here with its own real
    /// numbers, but excluded from its target's `TargetStats` usable totals.
    public var isExcludedFromTotals: Bool
    /// This session's dominant `SetupFingerprint.descriptor` (R6-3) across
    /// its usable lights -- `nil` when no usable light has a derivable
    /// fingerprint at all (e.g. an entirely bare-header DSLR session).
    public var setupDescriptor: String?
    /// This session's `README.txt` notes (R6-4), keyed exactly as
    /// `ReadmeNotesParser` extracted them (e.g. `"Camera"`, `"Location/
    /// Bortle"`, or any custom key the user typed) -- `[:]` when the
    /// session has no README.txt on record, or one with no parseable lines.
    public var notes: [String: String]
    /// Count of this session's LIGHT frames the user marked CHECKED (kept)
    /// in a DeepSkyStacker `.dssfilelist`, per `DSSIngest`/`Database.
    /// acceptedCounts(target:date:)` -- schema v8/R7-B2. `nil` together with
    /// `dssRejectedCount` when the session has no recorded verdicts at all
    /// (never DSS-ingested, or ingested but this session had no
    /// `.dssfilelist` covering it).
    public var dssAcceptedCount: Int?
    /// Count of this session's LIGHT frames the user marked unchecked
    /// (rejected) in a `.dssfilelist` -- see `dssAcceptedCount`.
    public var dssRejectedCount: Int?
    /// R11-T13/F20: `true` when at least one key exists in BOTH the
    /// README-parsed notes AND the note-editor store
    /// (`NoteConflicts.detect`) with a differing (trimmed) value -- the
    /// disagreement the README-wins `notes` merge above silently papers
    /// over. Computed once, here, since `computeSessionDetail` is the one
    /// place that already has both RAW sources on hand before merging them;
    /// every other reader (`NightsQueries.allNights`, the app's
    /// `NotesSegment`/`SessionNoteSheet`, the CLI's `note show`) either reads
    /// this straight off or reruns the same detection with its own pair of
    /// raw dictionaries.
    public var hasConflict: Bool
    /// Operational sub-collections inside this date session. Empty only
    /// when decoding data produced before capture summaries existed.
    public var captureGroups: [CaptureGroupSummary]

    public init(
        target: String,
        dateRaw: String,
        lightCount: Int,
        flatCount: Int,
        darkCount: Int,
        biasCount: Int,
        integrationSeconds: Double,
        exposureBreakdown: [String: Int],
        cameras: [String],
        focalLengthsMM: [Double],
        gains: [Double],
        sensorTempsC: [Double],
        filters: [String],
        hasReadme: Bool,
        tags: [String] = [],
        usableLightCount: Int? = nil,
        rejectedCount: Int = 0,
        duplicateLinkCount: Int = 0,
        isExcludedFromTotals: Bool = false,
        setupDescriptor: String? = nil,
        notes: [String: String] = [:],
        dssAcceptedCount: Int? = nil,
        dssRejectedCount: Int? = nil,
        hasConflict: Bool = false,
        captureGroups: [CaptureGroupSummary] = []
    ) {
        self.target = target
        self.dateRaw = dateRaw
        self.lightCount = lightCount
        self.flatCount = flatCount
        self.darkCount = darkCount
        self.biasCount = biasCount
        self.integrationSeconds = integrationSeconds
        self.exposureBreakdown = exposureBreakdown
        self.cameras = cameras
        self.focalLengthsMM = focalLengthsMM
        self.gains = gains
        self.sensorTempsC = sensorTempsC
        self.filters = filters
        self.hasReadme = hasReadme
        self.tags = tags
        self.usableLightCount = usableLightCount ?? lightCount
        self.rejectedCount = rejectedCount
        self.duplicateLinkCount = duplicateLinkCount
        self.isExcludedFromTotals = isExcludedFromTotals
        self.setupDescriptor = setupDescriptor
        self.notes = notes
        self.dssAcceptedCount = dssAcceptedCount
        self.dssRejectedCount = dssRejectedCount
        self.hasConflict = hasConflict
        self.captureGroups = captureGroups
    }

    private enum CodingKeys: String, CodingKey {
        case target, dateRaw, lightCount, flatCount, darkCount, biasCount, integrationSeconds,
             exposureBreakdown, cameras, focalLengthsMM, gains, sensorTempsC, filters, hasReadme, tags,
             usableLightCount, rejectedCount, duplicateLinkCount, isExcludedFromTotals, setupDescriptor, notes,
             dssAcceptedCount, dssRejectedCount, hasConflict, captureGroups
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        dateRaw = try c.decode(String.self, forKey: .dateRaw)
        lightCount = try c.decode(Int.self, forKey: .lightCount)
        flatCount = try c.decode(Int.self, forKey: .flatCount)
        darkCount = try c.decode(Int.self, forKey: .darkCount)
        biasCount = try c.decode(Int.self, forKey: .biasCount)
        integrationSeconds = try c.decode(Double.self, forKey: .integrationSeconds)
        exposureBreakdown = try c.decode([String: Int].self, forKey: .exposureBreakdown)
        cameras = try c.decode([String].self, forKey: .cameras)
        focalLengthsMM = try c.decode([Double].self, forKey: .focalLengthsMM)
        gains = try c.decode([Double].self, forKey: .gains)
        sensorTempsC = try c.decode([Double].self, forKey: .sensorTempsC)
        filters = try c.decode([String].self, forKey: .filters)
        hasReadme = try c.decode(Bool.self, forKey: .hasReadme)
        // Absent in JSON produced before this field existed -- decode
        // leniently so older cached/serialized session details stay loadable.
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        // Additive R4-1 fields: absent in pre-R4-1 JSON, fall back to values
        // consistent with the old (undeduped) semantics.
        usableLightCount = try c.decodeIfPresent(Int.self, forKey: .usableLightCount) ?? lightCount
        rejectedCount = try c.decodeIfPresent(Int.self, forKey: .rejectedCount) ?? 0
        duplicateLinkCount = try c.decodeIfPresent(Int.self, forKey: .duplicateLinkCount) ?? 0
        isExcludedFromTotals = try c.decodeIfPresent(Bool.self, forKey: .isExcludedFromTotals) ?? false
        // Additive R6-3 field: absent in pre-R6-3 JSON, falls back to nil.
        setupDescriptor = try c.decodeIfPresent(String.self, forKey: .setupDescriptor)
        // Additive R6-4 field: absent in pre-R6-4 JSON, falls back to [:].
        notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
        // Additive R7-B2 fields: absent in pre-R7-B2 JSON, fall back to nil.
        dssAcceptedCount = try c.decodeIfPresent(Int.self, forKey: .dssAcceptedCount)
        dssRejectedCount = try c.decodeIfPresent(Int.self, forKey: .dssRejectedCount)
        // Additive R11-T13/F20 field: absent in pre-F20 JSON, falls back to
        // false (no conflict on record).
        hasConflict = try c.decodeIfPresent(Bool.self, forKey: .hasConflict) ?? false
        captureGroups = try c.decodeIfPresent([CaptureGroupSummary].self, forKey: .captureGroups) ?? []
    }
}

/// Builds `SessionDetail` rows for one target, one per session date-dir.
/// Reads only from `Database` -- never touches the filesystem.
public enum SessionStatsQueries {
    /// Every session date-dir on record for `target`, sorted by `dateRaw`
    /// ascending. `[]` if the target has no `area == .sessions` files at
    /// all (including an unknown target name).
    public static func sessions(target: String, db: Database, config: AstroConfig) throws -> [SessionDetail] {
        let files = try db.allFiles(includeMissing: false)
        let sessionFiles = files.filter { $0.target == target && $0.area == .sessions }
        guard !sessionFiles.isEmpty else { return [] }

        let dates = Set(sessionFiles.compactMap(\.sessionDate)).sorted()
        let targetFiles = files.filter {
            $0.target == target && ($0.area == .sessions || $0.area == .stacks || $0.area == .processed)
        }
        let metaByFileID = try db.fitsMetaBatch(fileIDs: targetFiles.compactMap(\.id))
        let resolver = try CaptureResolver.load(db: db)
        return try dates.map { date in
            try computeSessionDetail(
                target: target,
                date: date,
                files: targetFiles,
                metaByFileID: metaByFileID,
                resolver: resolver,
                captureGroups: db.captureGroups(target: target, date: date),
                db: db,
                config: config
            )
        }
    }

    private static func computeSessionDetail(
        target: String,
        date: String,
        files: [FileRecord],
        metaByFileID: [Int64: FITSMetaRecord],
        resolver: CaptureResolver,
        captureGroups: [CaptureGroupRecord],
        db: Database,
        config: AstroConfig
    ) throws -> SessionDetail {
        let dayFiles = files.filter { $0.sessionDate == date }
        let lights = dayFiles.filter { $0.role == .light }
        let flats = dayFiles.filter { $0.role == .flat }
        let darks = dayFiles.filter { $0.role == .dark }
        let biases = dayFiles.filter { $0.role == .bias }
        let hasReadme = dayFiles.contains {
            $0.kind == "text" && ($0.path as NSString).lastPathComponent == "README.txt"
        }

        let frameBuckets = FrameSet.lightBuckets(files: lights, meta: metaByFileID, config: config)
        let captureSummaries = CaptureQueries.summarize(
            files: dayFiles,
            meta: metaByFileID,
            resolver: resolver,
            groups: captureGroups,
            config: config
        )

        var totalSeconds: Double = 0
        var exposureBreakdown: [String: Int] = [:]
        var cameras = Set<String>()
        var focalLengths = Set<Double>()
        var gains = Set<Double>()
        var sensorTemps = Set<Double>()
        var filters = Set<String>()

        for file in frameBuckets.usable {
            let meta = file.id.flatMap { metaByFileID[$0] }
            if let exptime = meta?.exptime {
                totalSeconds += exptime
                exposureBreakdown[NominalExposure.nominal(exptime).description, default: 0] += 1
            } else {
                exposureBreakdown["unknown", default: 0] += 1
            }
            if let camera = meta?.instrume { cameras.insert(camera) }
            if let filter = meta?.filter { filters.insert(filter) }
            if let focallen = meta?.focallen { focalLengths.insert(focallen.rounded()) }
            if let gain = meta?.gain { gains.insert(gain) }
            if let setTemp = meta?.setTemp { sensorTemps.insert((setTemp * 2).rounded() / 2) }
        }

        let fingerprintCounts = EquipmentProfile.fingerprintCounts(usableLights: frameBuckets.usable, meta: metaByFileID)
        let setupDescriptor = EquipmentProfile.dominant(fingerprintCounts)?.descriptor

        let tags = try db.tags(target: target, sessionDate: date)
        // T6/B4: merge the README-parsed notes (`Database.sessionNotes`,
        // scanner-owned) with whatever the user typed into the note editor
        // (`SessionNoteStore`, `.astro_tool/notes/`) -- the README wins any
        // key collision (spec: "README nyer"), the store only ever fills in
        // a key the README doesn't already have. Done here, at query time,
        // rather than by writing the store's notes into the DB, so a
        // rescan (which unconditionally replaces `session_notes` from the
        // README) can never wipe out a note the store holds -- see
        // `SessionNoteStore`'s own doc comment.
        let readmeNotes = try db.sessionNotes(target: target, date: date)
        let storeNotes = SessionNoteStore.load(
            target: target, date: date, root: URL(fileURLWithPath: config.rootPath, isDirectory: true)
        )
        let notes = storeNotes.merging(readmeNotes) { _, readmeValue in readmeValue }
        // R11-T13/F20: computed off the same two RAW dictionaries, before
        // they got merged above -- once merged, a conflicting key's
        // app-store value is already gone (README won it), so this has to
        // happen here, not as a later derived property.
        let hasConflict = !NoteConflicts.detect(appNotes: storeNotes, readmeNotes: readmeNotes).isEmpty

        // `nil` together (not `0`) when the session has no recorded
        // verdicts at all, so a session never DSS-ingested doesn't show a
        // misleading "0✓/0✗" -- see `SessionDetail.dssAcceptedCount`'s doc
        // comment.
        let verdictCounts = try db.acceptedCounts(target: target, date: date)
        let dssAcceptedCount: Int?
        let dssRejectedCount: Int?
        if verdictCounts.accepted + verdictCounts.rejected > 0 {
            dssAcceptedCount = verdictCounts.accepted
            dssRejectedCount = verdictCounts.rejected
        } else {
            dssAcceptedCount = nil
            dssRejectedCount = nil
        }

        let excludedLabels = Set(config.stats.excludeLabels.map { $0.lowercased() })
        let isExcluded: Bool
        if let parsed = SessionDateParser.parse(date, patterns: config.intentional),
           parsed.kind == .labeled, let label = parsed.label {
            isExcluded = excludedLabels.contains(label.lowercased())
        } else {
            isExcluded = false
        }

        return SessionDetail(
            target: target,
            dateRaw: date,
            lightCount: lights.count,
            flatCount: flats.count,
            darkCount: darks.count,
            biasCount: biases.count,
            integrationSeconds: totalSeconds,
            exposureBreakdown: exposureBreakdown,
            cameras: cameras.sorted(),
            focalLengthsMM: focalLengths.sorted(),
            gains: gains.sorted(),
            sensorTempsC: sensorTemps.sorted(),
            filters: filters.sorted(),
            hasReadme: hasReadme,
            tags: tags,
            usableLightCount: frameBuckets.usable.count,
            rejectedCount: frameBuckets.rejected.count,
            duplicateLinkCount: frameBuckets.duplicateLinkCount,
            isExcludedFromTotals: isExcluded,
            setupDescriptor: setupDescriptor,
            notes: notes,
            dssAcceptedCount: dssAcceptedCount,
            dssRejectedCount: dssRejectedCount,
            hasConflict: hasConflict,
            captureGroups: captureSummaries
        )
    }
}
