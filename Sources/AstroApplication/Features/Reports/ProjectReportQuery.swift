import AstroCore
import Foundation

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
            plan: plan,
            projectState: projectState,
            filterRows: filterRows
        )
    }
}
