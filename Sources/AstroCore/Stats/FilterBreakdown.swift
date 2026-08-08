import Foundation

/// One filter's usable integration for a target (or one of its sessions) --
/// the mono-imager counterpart to `TargetStats`' single aggregate integration
/// number. Sorted seconds-descending by `FilterBreakdownQueries.breakdown`,
/// so "what have I got the most of" is always the first row.
public struct FilterIntegration: Codable, Sendable, Equatable {
    /// The raw FITS `FILTER` header value (e.g. `"Ha"`, `"L-eXtreme"`,
    /// `"OIII"`), or `FilterBreakdownQueries.noFilterSentinel` for frames
    /// with no filter recorded at all (no `fits_meta` row, or a row whose
    /// `filter` is `nil`/blank -- e.g. an unfiltered OSC/DSLR session). This
    /// sentinel is a stable, documented bucket key, never a guess at what
    /// the filter might have been -- "Őszinte n/a" (PLAN-R10 §2).
    public let filter: String
    public let usableFrameCount: Int
    public let integrationSeconds: Double
    /// This filter's `goal:<filter>=<hours>h` tag, in seconds -- `nil` when
    /// no such tag is set (the common case: most callers never populate
    /// this at all). Set only by `FilterGoalQueries.merge`, never by
    /// `FilterBreakdownQueries.breakdown` itself -- that query is a pure
    /// usable-integration MEASUREMENT with no notion of tags/goals; keeping
    /// goal data as optional, separately-attached fields here (rather than a
    /// parallel `FilterGoalStatus` type) lets every existing caller
    /// (`NightsQueries`, `stats --filters --json`'s date-scoped mode, ...)
    /// keep using plain `FilterIntegration` unchanged, while the few callers
    /// that DO have goal tags to merge in (`TargetDetailPage`'s "Szűrők"
    /// card, `TonightPage`'s "Hiányzik" popover, `stats --filters --json`'s
    /// whole-target mode, `goal list --json`) get it as additive fields on
    /// the exact same JSON shape.
    public var goalSeconds: Double?
    /// `max(0, goalSeconds - integrationSeconds)` -- `nil` iff `goalSeconds`
    /// is `nil`. Kept as a stored (not computed) property so it round-trips
    /// through `Codable` unchanged rather than needing callers to recompute
    /// it after decoding.
    public var missingSeconds: Double?

    public init(
        filter: String, usableFrameCount: Int, integrationSeconds: Double,
        goalSeconds: Double? = nil, missingSeconds: Double? = nil
    ) {
        self.filter = filter
        self.usableFrameCount = usableFrameCount
        self.integrationSeconds = integrationSeconds
        self.goalSeconds = goalSeconds
        self.missingSeconds = missingSeconds
    }

    /// Returns a copy with `goalSeconds` (and the derived `missingSeconds`)
    /// attached -- `FilterGoalQueries.merge`'s one mutation primitive, kept
    /// here (rather than duplicated at each call site) so `missingSeconds`
    /// can never drift from `max(0, goalSeconds - integrationSeconds)`.
    /// `seconds: nil` clears both back to absent.
    public func withGoal(seconds: Double?) -> FilterIntegration {
        FilterIntegration(
            filter: filter, usableFrameCount: usableFrameCount, integrationSeconds: integrationSeconds,
            goalSeconds: seconds, missingSeconds: seconds.map { max(0, $0 - integrationSeconds) }
        )
    }
}

/// Per-filter breakdown of a target's usable session-light integration --
/// "how many usable hours do I have per filter on this target" for mono
/// LRGB/SHO imagers, the one dimension `TargetStats`/`StatsQueries` collapse
/// into a single aggregate number. Shares `FrameSet`'s dedup/non-frame
/// filtering (never reimplemented here) and, for the whole-target overload,
/// `StatsQueries`' exact `_hibas`-style excluded-session convention -- see
/// `breakdown(db:config:target:)`'s own doc comment.
public enum FilterBreakdownQueries {
    /// The bucket every usable frame with no recorded `FILTER` header value
    /// falls into -- deliberately Hungarian and parenthesized so it reads as
    /// an explanatory placeholder, not a real filter name, wherever it's
    /// printed or JSON-encoded (same "explain instead of guessing" contract
    /// `NightHealth`'s `notAvailableReason` values already follow).
    public static let noFilterSentinel = "(nincs szűrő-adat)"

    /// Per-filter usable (deduped, non-rejected, non-excluded-session)
    /// integration for one target across every session on record, sorted by
    /// `integrationSeconds` descending (ties broken by `filter` name for a
    /// stable order).
    ///
    /// Excluded sessions (a date-dir whose `SessionDateParser`-parsed label
    /// is in `config.stats.excludeLabels`, e.g. the user's own `_hibas`
    /// marker) are dropped from this roll-up entirely -- the exact same
    /// convention `StatsQueries.computeStats` applies to
    /// `TargetStats.usableIntegrationSeconds`, so this breakdown's rows
    /// always sum to that same headline number (modulo `stats --gross`,
    /// which this query has no equivalent of).
    public static func breakdown(db: Database, config: AstroConfig, target: String) throws -> [FilterIntegration] {
        try breakdown(db: db, config: config, target: target, date: nil)
    }

    /// Same as `breakdown(db:config:target:)`, scoped to one session date --
    /// e.g. "what filters did I actually shoot on 2026-03-15". Unlike the
    /// whole-target overload, this NEVER drops an excluded (`_hibas`-style)
    /// session's own frames: asking about one specific night should answer
    /// honestly for that night, the same way `stats --sessions`/
    /// `SessionDetail` still show a `_hibas` night's real numbers (just
    /// flagged `isExcludedFromTotals`) rather than hiding them.
    public static func breakdown(db: Database, config: AstroConfig, target: String, date: String) throws -> [FilterIntegration] {
        try breakdown(db: db, config: config, target: target, date: Optional(date))
    }

    private static func breakdown(
        db: Database, config: AstroConfig, target: String, date: String?
    ) throws -> [FilterIntegration] {
        let files = try db.allFiles(includeMissing: false)
        var sessionFiles = files.filter { $0.target == target && $0.area == .sessions }
        if let date {
            sessionFiles = sessionFiles.filter { $0.sessionDate == date }
        }
        let sessionLights = sessionFiles.filter { $0.role == .light }

        var metaByFileID: [Int64: FITSMetaRecord] = [:]
        for file in sessionLights {
            guard let id = file.id else { continue }
            if let meta = try db.fitsMeta(fileID: id) {
                metaByFileID[id] = meta
            }
        }

        let frameBuckets = FrameSet.lightBuckets(files: sessionLights, meta: metaByFileID, config: config)
        var usable = frameBuckets.usable

        if date == nil {
            // Whole-target roll-up only -- see this overload-pair's own doc
            // comments for why a per-date query skips this filter entirely.
            // Copied verbatim from `StatsQueries.computeStats`'s own
            // `excludedSessionDates`/`usableForTotals` derivation so the two
            // queries can never quietly disagree about which sessions count.
            let excludedLabels = Set(config.stats.excludeLabels.map { $0.lowercased() })
            let excludedDates = Set(sessionFiles.compactMap(\.sessionDate).filter { candidate in
                guard let parsed = SessionDateParser.parse(candidate, patterns: config.intentional),
                      parsed.kind == .labeled, let label = parsed.label
                else { return false }
                return excludedLabels.contains(label.lowercased())
            })
            usable = usable.filter { file in
                guard let sessionDate = file.sessionDate else { return true }
                return !excludedDates.contains(sessionDate)
            }
        }

        var frameCountByFilter: [String: Int] = [:]
        var secondsByFilter: [String: Double] = [:]
        for file in usable {
            let meta = file.id.flatMap { metaByFileID[$0] }
            let rawFilter = meta?.filter?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = (rawFilter?.isEmpty == false) ? rawFilter! : noFilterSentinel
            frameCountByFilter[key, default: 0] += 1
            secondsByFilter[key, default: 0] += meta?.exptime ?? 0
        }

        return frameCountByFilter.keys
            .map { key in
                FilterIntegration(
                    filter: key,
                    usableFrameCount: frameCountByFilter[key] ?? 0,
                    integrationSeconds: secondsByFilter[key] ?? 0
                )
            }
            .sorted { a, b in
                if a.integrationSeconds != b.integrationSeconds { return a.integrationSeconds > b.integrationSeconds }
                return a.filter < b.filter
            }
    }
}
