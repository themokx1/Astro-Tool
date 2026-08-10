import Foundation

/// One session date-dir, browsable across EVERY target at once -- the
/// cross-target counterpart to `SessionStatsQueries.sessions(target:...)`,
/// which only ever answers "show me one target's nights". Built by joining
/// that type's own `SessionDetail` with `SessionQuality`'s per-session
/// summary and `SessionTimeline`'s duty cycle, keyed on `(target, date)` --
/// no frame-level computation of its own, no filesystem access, no re-read
/// of pixel data (every quantity here already lives in `Database`).
///
/// This is a BROWSING surface, not a stats roll-up: an excluded (e.g.
/// `_hibas`-labeled) session still gets its own row here, flagged via
/// `isExcludedFromTotals`, exactly the way `SessionDetail` itself already
/// carries that flag for its target's own roll-up.
public struct NightRow: Codable, Sendable, Equatable {
    public var target: String
    /// The best available display name for `target` -- same resolution
    /// (`TargetNameResolver` plus a `name:<text>` tag override) `StatsQueries`
    /// already applies for its own `TargetStats.displayName`.
    public var displayName: String
    /// Raw session-date dir name, verbatim as it appears on disk under
    /// `sessions/<target>/` -- same convention as `SessionDetail.dateRaw`.
    public var date: String
    public var usableLightCount: Int
    public var integrationSeconds: Double
    /// `"120s×42, 300s×8"` -- ascending by the exposure-length key text, an
    /// unknown-exptime bucket (if any) prints as `"?×N"`. Same convention as
    /// `AcquisitionExport`'s own per-session exposure text; `"-"` for a
    /// session with no usable lights at all (e.g. a calibration-only or
    /// README-only date-dir).
    public var exposureSummary: String
    public var cameras: [String]
    public var filters: [String]
    /// From `SessionQualitySummary.medianFWHMArcsec` -- `nil` whenever the
    /// session has no rated frame with a derivable arcsec value (including
    /// "never rated at all").
    public var medianFWHMArcsec: Double?
    /// From `SessionQualitySummary.medianFWHMPixels` (R10 review) -- the
    /// pixel-only fallback for a rated session that has NO derivable
    /// `medianFWHMArcsec` (missing `xpixsz`/`focallen` pixel-scale metadata,
    /// not "never rated": a rated frame with neither still leaves this
    /// `nil` too). `NightsPage.fwhmText` falls back to this, suffixed
    /// " px", the same "arcsec when possible, else pixels" convention
    /// `SessionsSegment.fwhmText` already establishes for the per-target
    /// session table.
    public var medianFWHMPixels: Double?
    /// From `SessionQualitySummary.backgroundEPerSecPerArcsec2` -- `nil`
    /// under the same "n/a, never a guessed number" rule that type documents
    /// (missing sensor profile, missing exposure/pixel-scale metadata, or no
    /// rated frame at all).
    public var backgroundEPerSecPerArcsec2: Double?
    /// From `SessionTimeline.dutyCycle`, scaled to 0...100 (the "Percent"
    /// naming convention `Planner`'s `moonIlluminationPercent` already
    /// uses) -- `nil` when no usable light has a parseable `DATE-OBS`.
    public var dutyCyclePercent: Double?
    /// `true` when this session has any note on record -- either parsed
    /// from its `README.txt` (`Database.sessionNotes`) or typed into the
    /// note editor (`SessionNoteStore`); see `SessionDetail.notes`, which
    /// already merges both sources (the README wins a key collision).
    public var hasNotes: Bool
    /// R11-T13/F20: mirrors `SessionDetail.hasConflict` -- `true` when this
    /// session has at least one key where the app-store note
    /// (`SessionNoteStore`) and the README-parsed note disagree
    /// (`NoteConflicts.detect`). Backs `NightsPage`'s Jegyzet column
    /// (a yellow ⚠️ in place of the plain ✓ `hasNotes` already draws).
    public var hasConflict: Bool
    /// Mirrors `SessionDetail.isExcludedFromTotals` -- this session is still
    /// listed here with its own real numbers (this is a browsing surface,
    /// not a stats roll-up), just flagged as excluded from its TARGET's own
    /// usable totals (e.g. the user's own `_hibas` "bad night" marker).
    public var isExcludedFromTotals: Bool
    /// Mirrors `SessionDetail.tags` -- this session's own tags (the `tags`
    /// table, `session_date == date`), never the target-level set. R11-T2:
    /// backs `NightsPage`'s "Címke eltávolítása" submenu, the one piece of
    /// the shared `SessionActionMenu` action set this row didn't carry yet.
    public var tags: [String]
    /// R11-T5/F1: this ONE session's own per-filter usable-integration
    /// breakdown (`FilterBreakdownQueries.breakdown(db:config:target:date:)`,
    /// scoped to `date` -- so, like `filters`/`usableLightCount` above, this
    /// still reports an excluded (`_hibas`) night's own real numbers rather
    /// than an empty array). `filters` (the plain distinct-names list) is
    /// left untouched for whatever else already reads it; this is what
    /// `NightsPage`'s "Szűrők" column needs for its hour-bucketed
    /// ("Ha 1,5h · OIII 0,8h") cell text and frame-count tooltip. Never
    /// carries goal/missing data (`FilterIntegration.goalSeconds` stays
    /// `nil` here) -- a single NIGHT has no goal of its own, only the whole
    /// TARGET does (`TargetPlan.filterGoals`).
    public var filterBreakdown: [FilterIntegration]
    /// R11-T15/F16: this session's resolved `SiteProfile.name`, via
    /// `SiteResolver.resolve` (an explicit `site:<name>` tag on the session
    /// wins outright; otherwise the nearest configured site to the
    /// session's own median `SITELAT`/`SITELONG`, within 50 km). `nil`
    /// whenever `config.sites` is empty (no multi-site config at all -- the
    /// pre-T15 default, same "FITS-median automatika" stance the rest of
    /// this feature takes), the session has no resolvable coordinate AND no
    /// tag override, or nothing configured is close enough. Additive --
    /// absent in JSON produced before this field existed, decodes to `nil`
    /// there via the ordinary `Optional` decode-if-present the synthesized
    /// `Codable` conformance already gives every other `nil`-by-default
    /// field on this type. `NightsPage`'s optional "Helyszín" column (shown
    /// only once more than one site is configured) is this field's only
    /// consumer today.
    public var site: String?

    public init(
        target: String,
        displayName: String,
        date: String,
        usableLightCount: Int,
        integrationSeconds: Double,
        exposureSummary: String,
        cameras: [String],
        filters: [String],
        medianFWHMArcsec: Double? = nil,
        medianFWHMPixels: Double? = nil,
        backgroundEPerSecPerArcsec2: Double? = nil,
        dutyCyclePercent: Double? = nil,
        hasNotes: Bool = false,
        hasConflict: Bool = false,
        isExcludedFromTotals: Bool = false,
        tags: [String] = [],
        filterBreakdown: [FilterIntegration] = [],
        site: String? = nil
    ) {
        self.target = target
        self.displayName = displayName
        self.date = date
        self.usableLightCount = usableLightCount
        self.integrationSeconds = integrationSeconds
        self.exposureSummary = exposureSummary
        self.cameras = cameras
        self.filters = filters
        self.medianFWHMArcsec = medianFWHMArcsec
        self.medianFWHMPixels = medianFWHMPixels
        self.backgroundEPerSecPerArcsec2 = backgroundEPerSecPerArcsec2
        self.dutyCyclePercent = dutyCyclePercent
        self.hasNotes = hasNotes
        self.hasConflict = hasConflict
        self.isExcludedFromTotals = isExcludedFromTotals
        self.tags = tags
        self.filterBreakdown = filterBreakdown
        self.site = site
    }
}

/// Builds `NightRow`s across EVERY target on record -- the answer to "show
/// me all my imaging nights, best seeing first" or "what did I shoot in
/// March?", which no existing query can give since `SessionStatsQueries`/
/// `SessionQuality`/`SessionTimeline` are all scoped to one target at a
/// time. Reuses those three untouched (one pass per target each, the same
/// shape `StatsQueries.perTarget` already loops with for its own per-target
/// roll-up), so this type owns no frame-level computation of its own --
/// purely a join plus a sort. Read-only against `db`; never touches the
/// filesystem.
public enum NightsQueries {
    /// Every session across every target, newest date first (ties on the
    /// same calendar date broken by target name, then by the raw date-dir
    /// text, both ascending, purely for a deterministic order). `year`/
    /// `month` optionally filter on the session's parsed CANONICAL start
    /// date (`SessionDateParser`'s own `YYYY-MM-DD` prefix, so a run-suffix
    /// or `_hibas`-labeled date-dir still matches on its underlying
    /// calendar date) -- a session whose date-dir name doesn't parse as a
    /// date at all is excluded whenever a `year` filter is active (there is
    /// no calendar date left to compare against), but still listed when
    /// browsing without any filter. `month` without `year` is ignored here;
    /// enforcing "month requires year" is the CLI layer's job (see
    /// `astrotool nights --help`), not this query's.
    public static func allNights(
        db: Database, config: AstroConfig, year: Int? = nil, month: Int? = nil
    ) throws -> [NightRow] {
        let targets = Set(try db.allSessionPairs().map { $0.target }).sorted()

        // One reusable library snapshot backs every per-session filter and
        // site calculation below. This removes the former
        // O(session-count × library-file-count) filter-breakdown scan.
        let libraryFiles = try db.allFiles(includeMissing: false)
        let allSessionFiles = libraryFiles.filter { $0.area == .sessions }
        let snapshotMeta = try db.fitsMetaBatch(fileIDs: allSessionFiles.compactMap(\.id))
        let captureResolver = try CaptureResolver.load(db: db)
        let filesBySession = Dictionary(grouping: allSessionFiles) { file in
            SiteSessionKey(target: file.target ?? "", date: file.sessionDate ?? "")
        }

        // R11-T15/F16: `NightRow.site` -- only ever computed when at least
        // one site is configured (an empty `config.sites` leaves every row's
        // `site` `nil`, same "FITS-median automatika, nincs site-lista"
        // stance the rest of this feature takes). One upfront pass over
        // every usable session light in the whole library, grouped by
        // (target, date), rather than a per-session `db.allFiles` query --
        // `SessionStatsQueries.sessions`/`SessionQuality.summaries` already
        // establish that "one full-library pass beats N per-session ones"
        // shape for this same loop.
        var rows: [(row: NightRow, sortDate: String)] = []
        for target in targets {
            let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
            guard !sessions.isEmpty else { continue }

            // Both keyed on the exact same date set as `sessions` above --
            // `SessionQuality.summaries`/`SessionStatsQueries.sessions` (and
            // `SessionTimeline.timeline`, called per-date below) all derive
            // their dates from the identical `area == .sessions` filter, so
            // this lookup is never expected to miss.
            let qualityByDate = Dictionary(
                uniqueKeysWithValues: try SessionQuality.summaries(target: target, db: db, config: config)
                    .map { ($0.date, $0) }
            )

            let tags = try db.tags(target: target, sessionDate: nil)
            let displayName = NameTag.apply(to: TargetNameResolver.resolve(folderName: target), tags: tags).displayName

            for session in sessions {
                let parsedStart = SessionDateParser.parse(session.dateRaw, patterns: config.intentional)?.start
                guard matchesFilter(parsedStart: parsedStart, year: year, month: month) else { continue }

                let quality = qualityByDate[session.dateRaw]
                let timeline = try SessionTimeline.timeline(target: target, date: session.dateRaw, db: db, config: config)
                let sessionKey = SiteSessionKey(target: target, date: session.dateRaw)
                let snapshotFiles = filesBySession[sessionKey] ?? []
                let filterBreakdown = FilterBreakdownQueries.compute(
                    target: target, date: session.dateRaw,
                    files: snapshotFiles, meta: snapshotMeta,
                    resolver: captureResolver, config: config
                )

                var resolvedSiteName: String?
                if !config.sites.isEmpty {
                    let sessionLights = snapshotFiles.filter { $0.role == .light }
                    let median = TargetCoordinates.medianSite(files: sessionLights, meta: snapshotMeta)
                    resolvedSiteName = SiteResolver.resolve(
                        sessionTags: session.tags,
                        medianLat: median.latitudeDeg,
                        medianLon: median.longitudeDeg,
                        sites: config.sites
                    )?.name
                }

                let row = NightRow(
                    target: target,
                    displayName: displayName,
                    date: session.dateRaw,
                    usableLightCount: session.usableLightCount,
                    integrationSeconds: session.integrationSeconds,
                    exposureSummary: exposureSummaryText(session.exposureBreakdown),
                    cameras: session.cameras,
                    filters: session.filters,
                    medianFWHMArcsec: quality?.medianFWHMArcsec,
                    medianFWHMPixels: quality?.medianFWHMPixels,
                    backgroundEPerSecPerArcsec2: quality?.backgroundEPerSecPerArcsec2,
                    dutyCyclePercent: timeline.dutyCycle.map { $0 * 100 },
                    hasNotes: !session.notes.isEmpty,
                    hasConflict: session.hasConflict,
                    isExcludedFromTotals: session.isExcludedFromTotals,
                    tags: session.tags,
                    filterBreakdown: filterBreakdown,
                    site: resolvedSiteName
                )
                // Falls back to the raw text itself when it doesn't parse as
                // a date at all, so the sort below still has SOME stable key
                // to compare with (rather than crashing or reordering
                // unpredictably) -- an edge case `matchesFilter` already
                // excludes whenever a real `year` filter is active.
                rows.append((row, parsedStart ?? session.dateRaw))
            }
        }

        rows.sort { lhs, rhs in
            if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
            if lhs.row.target != rhs.row.target { return lhs.row.target < rhs.row.target }
            return lhs.row.date < rhs.row.date
        }
        return rows.map(\.row)
    }

    // MARK: - Site assignment (R11-T15/F16)

    /// Groups a full-library light-frame pass by (target, raw session date)
    /// -- the key `sessionLightsByKey` above is bucketed under, so
    /// `NightRow.site`'s per-session median-coordinate lookup is a plain
    /// dictionary read instead of a per-session filesystem/DB round trip.
    private struct SiteSessionKey: Hashable {
        let target: String
        let date: String
    }

    // MARK: - Year/month filter

    /// `true` when `parsedStart` (the session's canonical `YYYY-MM-DD`, or
    /// `nil` if its date-dir name didn't parse as a date at all) satisfies
    /// the `year`/`month` filter -- no filter at all (`year == nil`) always
    /// matches, and an unparseable date never matches an active filter.
    private static func matchesFilter(parsedStart: String?, year: Int?, month: Int?) -> Bool {
        guard let year else { return true }
        guard let parsedStart else { return false }
        let parts = parsedStart.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]) else { return false }
        guard y == year else { return false }
        guard let month else { return true }
        guard let m = Int(parts[1]) else { return false }
        return m == month
    }

    // MARK: - Exposure summary text

    /// `"120s×42, 300s×8"` -- ascending by the (textual) exposure-length
    /// key, an unknown-exptime bucket prints as `"?×N"`. Same convention as
    /// `AcquisitionExport.exposureSummaryText`, duplicated rather than
    /// shared since that one stays `private` to its own file and this type
    /// needs a plain `String` (`NightRow.exposureSummary`), not the
    /// `[String: Int]` breakdown dict `SessionDetail` already exposes.
    private static func exposureSummaryText(_ breakdown: [String: Int]) -> String {
        guard !breakdown.isEmpty else { return "-" }
        return breakdown
            .sorted { $0.key < $1.key }
            .map { key, count -> String in
                if key == "unknown" { return "?×\(count)" }
                let label = Double(key).map(formatTrimmedSeconds) ?? key
                return "\(label)s×\(count)"
            }
            .joined(separator: ", ")
    }

    /// Whole numbers print without a decimal point (`"120"`, not
    /// `"120.0"`); everything else keeps one decimal digit (`"6.8"`) --
    /// matches `NominalExposure`'s own rounding granularity (whole seconds
    /// at/above 10s, 0.1s below).
    private static func formatTrimmedSeconds(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
