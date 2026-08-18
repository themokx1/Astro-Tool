import AstroCore
import Foundation

/// W7-F item 2 (2026-08-18 expert audit, workflow #5): one mosaic panel's
/// integration deficit against this project's own best (largest-integration)
/// panel -- the ledger behind the Overview tab's "Panelek" deficit column
/// and the `.balanceMosaicPanels` next-action case. `Equatable`/`Sendable`
/// like every other `ProjectReportQuery` model, not `Codable` -- nothing
/// persists this, it is derived fresh from `PanelReport.panels` on every
/// report load (same-engine rule: the panel CLUSTERING already lives in
/// `FieldGeometry.panels`; this only compares integrations across panels
/// that grouping already produced).
public struct PanelDeficit: Sendable, Equatable, Identifiable {
    public let panel: Panel
    /// Seconds this panel trails the project's best panel by -- exactly `0`
    /// for the best panel itself (and for any panel tied with it), never
    /// negative for any panel.
    public let deficitSeconds: Double
    public var id: String { panel.label }

    public init(panel: Panel, deficitSeconds: Double) {
        self.panel = panel
        self.deficitSeconds = deficitSeconds
    }
}

/// W7-F item 2: derives `PanelDeficit`s from a `PanelReport`'s already-
/// clustered panels, and gates whether the worst one is significant enough
/// to become the project's own "next action". Deliberately its own
/// `AstroApplication`-only type rather than new fields on `PanelReport`
/// itself (`AstroCore`'s `FieldGeometry.swift`): `PanelReport.isUnbalanced`
/// already answers "is this mosaic unbalanced AT ALL" (a ratio-based
/// warning banner, `AstroCore`'s own long-standing R6-3 rule); this answers
/// a different question -- "is one panel behind by enough that catching it
/// up is tonight's actual next step" -- with its own, deliberately stricter
/// bar, for a next-action mechanism `AstroCore` has no notion of at all.
public enum MosaicBalance {
    /// The "worth acting on" bar is whichever of these two is LARGER,
    /// because either bald number misfires alone at an extreme:
    ///
    /// - A flat 20%-of-best floor would flag a 6-minute panel trailing a
    ///   30-minute best panel as "the project's dominant problem" --
    ///   technically 20%, actually the length of a single sub, i.e. noise.
    /// - A flat 30-minute floor would let a real, large-project imbalance
    ///   hide underneath it: a 2-hour panel trailing a 10-hour best panel by
    ///   only 25 minutes is still a genuinely lopsided mosaic (12.5% of a
    ///   large project is a lot of missing integration), even though 25
    ///   minutes alone reads as small.
    ///
    /// Requiring the LARGER of the two bars means a short project needs a
    /// real half hour of absolute gap before this fires, AND a long project
    /// needs the gap to be a real fifth of its best panel -- not just an
    /// incidentally-large number of minutes on an otherwise well-balanced
    /// mosaic.
    static let relativeThresholdFraction = 0.20
    static let absoluteThresholdSeconds = 30.0 * 60

    /// One `PanelDeficit` per panel in `panels`, each measured against
    /// whichever panel has the largest `integrationSeconds` -- `0` for that
    /// panel itself (and for any other panel tied with it). `[]` for fewer
    /// than two panels: a single field has no "other panel" to be behind.
    public static func deficits(panels: [Panel]) -> [PanelDeficit] {
        guard panels.count >= 2, let best = panels.map(\.integrationSeconds).max() else { return [] }
        return panels.map { PanelDeficit(panel: $0, deficitSeconds: max(0, best - $0.integrationSeconds)) }
    }

    /// The single worst `PanelDeficit` -- but only once it clears the
    /// "worth acting on" bar (`relativeThresholdFraction`/
    /// `absoluteThresholdSeconds`'s own doc above). `nil` for a balanced
    /// mosaic (every panel within the bar of the best), a single-field
    /// report, or a best panel with no recorded integration at all (nothing
    /// to be a fraction of).
    public static func dominantGap(panels: [Panel]) -> PanelDeficit? {
        let allDeficits = deficits(panels: panels)
        guard let best = panels.map(\.integrationSeconds).max(), best > 0,
              let worst = allDeficits.max(by: { $0.deficitSeconds < $1.deficitSeconds }),
              worst.deficitSeconds > 0
        else { return nil }
        let threshold = max(relativeThresholdFraction * best, absoluteThresholdSeconds)
        return worst.deficitSeconds > threshold ? worst : nil
    }
}

/// One session paired with its own calibration match -- the row shape
/// `TargetReport.renderCalibration`'s per-session table iterates (`for
/// session in sessions { sessionCalibrations.append(SessionMatcher.match
/// (...)) }`), joined here by construction instead of by matching index.
public struct ProjectReportSessionRow: Sendable, Identifiable {
    public let session: SessionDetail
    public let calibration: SessionCalibration
    public var id: String { session.dateRaw }
}

/// W5-1: the target/project report's full data assembly, extracted out of
/// `TargetReport.render`'s HTML path into a `Sendable` model the project
/// workspace's Áttekintés (Overview) tab renders directly -- "a teljes
/// projekt áttekintése ... az áttekintő oldalra" (the owner's own words).
/// Every field is assembled by calling the EXACT SAME `AstroCore` queries
/// `TargetReport.render` itself calls -- `StatsQueries`, `SessionStatsQueries`,
/// `SessionQuality`, `ExposureAdvisor`, `StackDiscovery`, `SessionMatcher`,
/// `CalibHealth`, `FieldGeometry`, `Planner`, `ProjectStatusQueries`,
/// `FilterGoalQueries`, `TargetNameResolver` -- plus (for the target's
/// resolved coordinate + source label, the one computation unique to the
/// target report) `TargetReport.resolveCoordinateInfo`, promoted `public`
/// for exactly this reuse. `TargetReport`'s own HTML generator is NOT
/// deleted by this query -- it still backs V1's `AppState.exportTargetReport`
/// and the `astrotool target-report` CLI command, both outside this
/// ticket's scope.
public struct ProjectReportQuery: Sendable {
    public struct Result: Sendable {
        public let target: String
        public let stat: TargetStats
        public let resolved: ResolvedTargetName
        public let coordinateInfo: TargetReport.CoordinateInfo?
        public let setupDescriptors: [String]
        public let sessions: [ProjectReportSessionRow]
        public let qualitySummaries: [SessionQualitySummary]
        public let advice: ExposureAdvice
        public let stacks: [StackFile]
        /// W6-E item 5: the same variant-family grouping `ResultsQuery`
        /// already computes for the standalone Results workspace
        /// (`StackDiscovery.groupedStacks`, wrapped as `StackResultGroup`),
        /// reused here rather than re-derived so the Overview tab's stack
        /// summary and the Results tab's own table can never disagree about
        /// what a "family" is. `stacks` above stays -- `targetFlats`/
        /// `panelReport` and other sections still read individual files --
        /// this is purely an addition for the Overview summary block.
        public let stackGroups: [StackResultGroup]
        public let targetFlats: [FlatDiscipline]
        public let panelReport: PanelReport
        /// W7-F item 2: `MosaicBalance.deficits(panels:)` over `panelReport
        /// .panels` -- same-engine rule, no new panel detection, purely a
        /// per-panel comparison against the group `FieldGeometry.panels`
        /// already clustered.
        public let panelDeficits: [PanelDeficit]
        public let plan: TargetPlan?
        public let projectState: ProjectState?
        public let filterRows: [FilterIntegration]
    }

    private let db: Database
    private let config: AstroConfig

    public init(db: Database, config: AstroConfig) {
        self.db = db
        self.config = config
    }

    /// Opens the production index DB/config for `rootURL` -- same
    /// `.production(rootURL:)` shape `ExportService`/`NightReportQuery`
    /// already follow.
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

    /// Resolves `target` against the library's actually-scanned folders --
    /// same one-letter-drift fix as `ExportService.resolvedTarget`/
    /// `NightReportQuery.resolvedTarget` (see either's own doc comment for
    /// why this stays a small per-query-type helper rather than a shared
    /// cross-cutting dependency).
    private func resolvedTarget(_ target: String) throws -> String {
        let knownFolders = Array(Set(try db.allFiles(includeMissing: false).compactMap(\.target)))
        return ResultsQuery.libraryFolder(matching: target, among: knownFolders) ?? target
    }

    public func run(target: String) throws -> Result {
        let target = try resolvedTarget(target)
        guard let stat = try StatsQueries.target(target, db: db, config: config) else {
            throw AstroError.pathNotFound(path: "sessions/\(target)")
        }

        let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
        let qualitySummaries = try SessionQuality.summaries(target: target, db: db, config: config)
        let advice = try ExposureAdvisor.advise(target: target, db: db, config: config)
        let stacks = try StackDiscovery.stacks(target: target, db: db, config: config)
        let stackGroups = try StackDiscovery.groupedStacks(target: target, db: db, config: config).map(StackResultGroup.init)
        let projectState = try ProjectStatusQueries.projects(db: db, config: config).first { $0.target == target }
        let panelReport = try FieldGeometry.panels(target: target, db: db, config: config)
        let plan = try Planner.plan(db: db, config: config).first { $0.target == target }
        let calibHealth = try CalibHealth.report(db: db, config: config)
        let targetFlats = calibHealth.flats.filter { $0.target == target }
        let filterRows = FilterGoalQueries.merge(
            breakdown: try FilterBreakdownQueries.breakdown(db: db, config: config, target: target),
            tags: stat.tags
        )

        var sessionRows: [ProjectReportSessionRow] = []
        for session in sessions {
            let calibration = try SessionMatcher.match(target: target, date: session.dateRaw, db: db, config: config)
            sessionRows.append(ProjectReportSessionRow(session: session, calibration: calibration))
        }

        let coordinateInfo = try TargetReport.resolveCoordinateInfo(target: target, db: db)
        let resolved = TargetNameResolver.resolve(folderName: target)
        let setupDescriptors = Array(Set(sessions.compactMap(\.setupDescriptor))).sorted()

        return Result(
            target: target,
            stat: stat,
            resolved: resolved,
            coordinateInfo: coordinateInfo,
            setupDescriptors: setupDescriptors,
            sessions: sessionRows,
            qualitySummaries: qualitySummaries,
            advice: advice,
            stacks: stacks,
            stackGroups: stackGroups,
            targetFlats: targetFlats,
            panelReport: panelReport,
            panelDeficits: MosaicBalance.deficits(panels: panelReport.panels),
            plan: plan,
            projectState: projectState,
            filterRows: filterRows
        )
    }
}

extension ProjectReportQuery.Result {
    /// W7-F item 2: the mosaic-balance next action for THIS project's own
    /// report, or `nil` when its panel ledger has no dominant gap (including
    /// a non-mosaic report, which never has one -- `MosaicBalance
    /// .dominantGap` returns `nil` for `< 2` panels).
    /// `ProjectWorkspaceView`'s `ProjectNextActionResolution.resolve(base:
    /// report:)` overrides the phase-based `ProjectSnapshot.nextAction` with
    /// this once the report has loaded and the project hasn't been
    /// explicitly archived -- see that function's own doc for why archived
    /// is exempt.
    public var mosaicBalanceNextAction: ProjectNextAction? {
        guard let gap = MosaicBalance.dominantGap(panels: panelReport.panels) else { return nil }
        let deficitHours = gap.deficitSeconds / 3600
        let formattedHours = deficitHours.formatted(.number.precision(.fractionLength(1)))
        return ProjectNextAction(
            kind: .balanceMosaicPanels(worstPanelLabel: gap.panel.label, deficitHours: deficitHours),
            title: "Balance the panels: \(gap.panel.label) panel +\(formattedHours) h",
            explanation: "\(gap.panel.label) panel has the biggest integration gap in this mosaic -- capture more of it next."
        )
    }
}
