import AstroCore
import Foundation

/// One capture group's operational summary joined with its own quality
/// metrics (FWHM), when rated -- the exact join `NightReport.
/// renderCaptureGroups` performs (`Dictionary(uniqueKeysWithValues: (quality
/// ?.captureGroups ?? []).map { ($0.id, $0) })`), surfaced here as a
/// `Sendable` row instead of an HTML `<div>` so `NightWorkspaceView` can
/// render it natively.
///
/// W5-3 (owner pixel review, 2026-08-24 IC 4604 night): `sessionDate` is new
/// -- when a night's captures were split across more than one session
/// date-dir (`SessionConversionPlanner`'s mixed-exposure "-2" run-suffix
/// split, see `NightReportQuery.run`'s own doc comment), two sibling
/// sessions can each carry an "implicit" (no explicit `capture_groups` DB
/// row) `CaptureGroupSummary`, and `CaptureGroupSummary.id` collapses every
/// implicit group to the literal string `"implicit"` regardless of which
/// session it came from. Folding `id` alone into this row's own `id` would
/// silently collide two different sessions' rows into one SwiftUI identity;
/// namespacing by `sessionDate` keeps every merged row distinct without
/// having to touch `CaptureGroupSummary` itself (an `AstroCore` type shared
/// far beyond this one query).
public struct NightCaptureGroupRow: Sendable, Equatable, Identifiable {
    public let sessionDate: String
    public let group: CaptureGroupSummary
    public let quality: CaptureQualitySummary?
    public var id: String { "\(sessionDate)#\(group.id)" }
}

/// W5-1: the night report's full data assembly, extracted out of
/// `NightReport.render`'s HTML path into a `Sendable` model the in-app night
/// workspace (`NightWorkspaceView`'s Overview tab) renders directly --
/// "ezek a jelentések, amik html oldalt generálnak, kerüljenek át valami
/// áttekintő oldalra ... az éjszakák jelentése, az éjszakák egy elemének
/// dupla kattintására" (the owner's own words). Every field here is
/// assembled by calling the EXACT SAME `AstroCore` queries `NightReport.
/// render` itself calls -- `SessionStatsQueries`, `SessionTimeline`,
/// `SessionQuality`, `NightHealth`, `SessionMatcher`, `ExposureAdvisor`,
/// `ProjectStatusQueries`, `FilterBreakdownQueries`, and (for the altitude/
/// airmass track and achieved Moon geometry, the two computations unique to
/// the night report) `NightReport.computeSkySections` itself, promoted
/// `public` for exactly this reuse -- so the numbers this view shows and the
/// numbers `astrotool report`/V1's "Éjszaka-riport" HTML file would have
/// shown are, and stay, identical: one assembly, two renderers (native
/// SwiftUI here, HTML there), never two competing computations of the same
/// fact. `NightReport`'s own HTML generator is NOT deleted by this query --
/// it still backs V1's `AppState.exportNightReport` and the `astrotool
/// night-report` CLI command, both outside this ticket's scope.
public struct NightReportQuery: Sendable {
    public struct Result: Sendable {
        public let target: String
        public let displayName: String
        public let date: String
        public let session: SessionDetail
        public let captureGroups: [NightCaptureGroupRow]
        public let timeline: SessionTimeline
        public let quality: SessionQualitySummary?
        public let health: NightHealthReport
        public let calibration: SessionCalibration
        public let advice: ExposureAdvice
        public let projectTodos: [String]
        public let filterRows: [FilterIntegration]
        public let altitude: NightReport.AltitudeTrack?
        public let moon: NightReport.MoonGeometry?
        /// W5-3: sibling session date-dirs (same canonical calendar date as
        /// `date`, e.g. `"2026-05-24-2"` next to `"2026-05-24"`) whose
        /// `filterRows`/`captureGroups` are folded into this result's own --
        /// see `run`'s doc comment for why these exist and why the merge is
        /// necessary at all. `[]` for the overwhelmingly common case of a
        /// night that is exactly one session date-dir.
        public let mergedSessionDates: [String]
    }

    private let db: Database
    private let config: AstroConfig

    public init(db: Database, config: AstroConfig) {
        self.db = db
        self.config = config
    }

    /// Opens the production index DB/config for `rootURL` -- same
    /// `.production(rootURL:)` shape `ExportService`/`CalibrationQuery`/
    /// `FrameQualityQuery` already follow.
    public static func production(rootURL: URL) throws -> Self {
        let root = rootURL.standardizedFileURL
        let identity = LibraryIdentity(rootURL: root)
        let storage = try AppStoragePaths.production(libraryID: identity, libraryRoot: root)
        let database = try Database(path: storage.indexDatabase.path)
        let configURL = root.appendingPathComponent(".astro_tool/config.json")
        var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
        config.rootPath = root.path
        return Self(db: database, config: config)
    }

    /// Resolves `target` against the library's actually-scanned folders
    /// before running any query below -- the identical one-letter-drift fix
    /// `ExportService.resolvedTarget` applies (same doc comment, same
    /// `ResultsQuery.libraryFolder(matching:among:)` resolver), duplicated
    /// here rather than shared because `ExportService` is one query type
    /// among several with this exact shape (`CalibrationQuery`,
    /// `FrameQualityQuery`, ...), each owning its own tiny resolver rather
    /// than a cross-cutting dependency between them.
    private func resolvedTarget(_ target: String) throws -> String {
        let knownFolders = Array(Set(try db.allFiles(includeMissing: false).compactMap(\.target)))
        return ResultsQuery.libraryFolder(matching: target, among: knownFolders) ?? target
    }

    /// W5-3 (owner pixel review, 2026-08-24 IC 4604 night): the hero card
    /// (`NightSnapshot.usableFrames`, `NightsQuery`) sums usable frames
    /// across every `SeriesRecord` the V2 metadata layer files under one
    /// `night_id` per CALENDAR date -- it has no notion of session date-dir
    /// suffixes at all. `SessionStatsQueries.sessions`, which the Filters/
    /// Capture Groups tables below are built from, is a `AstroCore`/
    /// `Database` query keyed on the literal `session_date` text instead:
    /// `SessionConversionPlanner`'s mixed-exposure split
    /// (`1e20c25`, "fix: split mixed-exposure capture groups") files a
    /// second run into its own `<date>-2` folder precisely so each
    /// resulting session stays single-exposure, and `SessionDateParser`
    /// already models that suffix as a `.runSuffix` variation of the SAME
    /// calendar date (see its own doc comment). Reproduced against the real
    /// 2026-05-24 IC 4604 Rho Ophiuchi library index: the hero counted 221
    /// usable frames (`147+3+1` from the `2026-05-24` session's three
    /// series plus `70` from `2026-05-24-2`'s one series -- all four series
    /// share one `night_id`); asking `NightReportQuery.run(date:
    /// "2026-05-24")` for just that one exact `session_date` string only
    /// ever saw the 151-frame session, silently dropping the 70-frame
    /// sibling -- the exact 221-vs-151 mismatch the owner flagged. Rather
    /// than leave that gap unexplained, every sibling session sharing this
    /// date's canonical `YYYY-MM-DD` start is folded into `filterRows`/
    /// `captureGroups` below (`mergedSessionDates` records which ones), so
    /// the tables always sum to the same total the hero card shows.
    public func run(target: String, date: String) throws -> Result {
        let target = try resolvedTarget(target)
        let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
        guard let session = sessions.first(where: { $0.dateRaw == date }) else {
            throw AstroError.pathNotFound(path: "sessions/\(target)/\(date)")
        }

        let timeline = try SessionTimeline.timeline(target: target, date: date, db: db, config: config)
        let allQuality = try SessionQuality.summaries(target: target, db: db, config: config)
        let quality = allQuality.first { $0.date == date }
        let health = try NightHealth.report(target: target, date: date, db: db, config: config)
        let calib = try SessionMatcher.match(target: target, date: date, db: db, config: config)
        let advice = try ExposureAdvisor.advise(target: target, db: db, config: config)
        let projectState = try ProjectStatusQueries.projects(db: db, config: config).first { $0.target == target }
        let projectTodos = projectState?.todos ?? []
        let displayName = projectState?.displayName ?? target.replacingOccurrences(of: "_", with: " ")
        let sky = try NightReport.computeSkySections(target: target, date: date, timeline: timeline, db: db, config: config)

        // Every OTHER session date-dir on record for `target` that parses
        // to the same canonical calendar start as `date` -- e.g. `date` ==
        // "2026-05-24" also picks up "2026-05-24-2". A date-dir that fails
        // to parse at all (`SessionDateParser.parse` returns `nil`) can
        // never match here, same as `date` itself would if it were
        // unparseable (it never is: `session`'s own lookup above already
        // proved `date` is a real `session_date` on record).
        let canonicalStart = SessionDateParser.parse(date, patterns: config.intentional)?.start ?? date
        let siblingSessions = sessions
            .filter { $0.dateRaw != date }
            .filter { SessionDateParser.parse($0.dateRaw, patterns: config.intentional)?.start == canonicalStart }
            .sorted { $0.dateRaw < $1.dateRaw }

        var filterRows = try FilterBreakdownQueries.breakdown(db: db, config: config, target: target, date: date)
        var captureGroups = Self.captureGroupRows(session: session, quality: quality)
        for sibling in siblingSessions {
            let siblingFilters = try FilterBreakdownQueries.breakdown(db: db, config: config, target: target, date: sibling.dateRaw)
            filterRows = Self.mergeFilterRows(filterRows, siblingFilters)
            let siblingQuality = allQuality.first { $0.date == sibling.dateRaw }
            captureGroups += Self.captureGroupRows(session: sibling, quality: siblingQuality)
        }

        return Result(
            target: target,
            displayName: displayName,
            date: date,
            session: session,
            captureGroups: captureGroups,
            timeline: timeline,
            quality: quality,
            health: health,
            calibration: calib,
            advice: advice,
            projectTodos: projectTodos,
            filterRows: filterRows,
            altitude: sky.altitude,
            moon: sky.moon,
            mergedSessionDates: siblingSessions.map(\.dateRaw)
        )
    }

    private static func captureGroupRows(session: SessionDetail, quality: SessionQualitySummary?) -> [NightCaptureGroupRow] {
        let qualityByID = Dictionary(uniqueKeysWithValues: (quality?.captureGroups ?? []).map { ($0.id, $0) })
        return session.captureGroups.map { group in
            NightCaptureGroupRow(sessionDate: session.dateRaw, group: group, quality: qualityByID[group.id])
        }
    }

    /// Sums `usableFrameCount`/`integrationSeconds` for the same filter name
    /// across two sessions' own breakdowns -- neither side ever carries a
    /// goal (`FilterBreakdownQueries.breakdown(db:config:target:date:)`
    /// never sets one; only `FilterGoalQueries.merge` does, for the
    /// whole-target overload nothing here calls), so the merged row's
    /// `goalSeconds`/`missingSeconds` stay `nil` too. Sorted the same way
    /// the source query itself sorts (`integrationSeconds` descending, ties
    /// broken by filter name) so a merged result reads exactly like a
    /// single `breakdown` call's own output would.
    private static func mergeFilterRows(_ lhs: [FilterIntegration], _ rhs: [FilterIntegration]) -> [FilterIntegration] {
        var byFilter = Dictionary(uniqueKeysWithValues: lhs.map { ($0.filter, $0) })
        for row in rhs {
            if let existing = byFilter[row.filter] {
                byFilter[row.filter] = FilterIntegration(
                    filter: row.filter,
                    usableFrameCount: existing.usableFrameCount + row.usableFrameCount,
                    integrationSeconds: existing.integrationSeconds + row.integrationSeconds
                )
            } else {
                byFilter[row.filter] = row
            }
        }
        return byFilter.values.sorted {
            $0.integrationSeconds == $1.integrationSeconds
                ? $0.filter < $1.filter
                : $0.integrationSeconds > $1.integrationSeconds
        }
    }
}
