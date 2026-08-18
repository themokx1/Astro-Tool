import AstroCore
import Foundation

/// One capture group's operational summary joined with its own quality
/// metrics (FWHM), when rated -- the exact join `NightReport.
/// renderCaptureGroups` performs (`Dictionary(uniqueKeysWithValues: (quality
/// ?.captureGroups ?? []).map { ($0.id, $0) })`), surfaced here as a
/// `Sendable` row instead of an HTML `<div>` so `NightWorkspaceView` can
/// render it natively.
public struct NightCaptureGroupRow: Sendable, Equatable, Identifiable {
    public let group: CaptureGroupSummary
    public let quality: CaptureQualitySummary?
    public var id: String { group.id }
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

    public func run(target: String, date: String) throws -> Result {
        let target = try resolvedTarget(target)
        let sessions = try SessionStatsQueries.sessions(target: target, db: db, config: config)
        guard let session = sessions.first(where: { $0.dateRaw == date }) else {
            throw AstroError.pathNotFound(path: "sessions/\(target)/\(date)")
        }

        let timeline = try SessionTimeline.timeline(target: target, date: date, db: db, config: config)
        let quality = try SessionQuality.summaries(target: target, db: db, config: config).first { $0.date == date }
        let health = try NightHealth.report(target: target, date: date, db: db, config: config)
        let calib = try SessionMatcher.match(target: target, date: date, db: db, config: config)
        let advice = try ExposureAdvisor.advise(target: target, db: db, config: config)
        let projectState = try ProjectStatusQueries.projects(db: db, config: config).first { $0.target == target }
        let projectTodos = projectState?.todos ?? []
        let displayName = projectState?.displayName ?? target.replacingOccurrences(of: "_", with: " ")
        let sky = try NightReport.computeSkySections(target: target, date: date, timeline: timeline, db: db, config: config)
        let filterRows = try FilterBreakdownQueries.breakdown(db: db, config: config, target: target, date: date)

        let qualityByID = Dictionary(uniqueKeysWithValues: (quality?.captureGroups ?? []).map { ($0.id, $0) })
        let captureGroups = session.captureGroups.map { group in
            NightCaptureGroupRow(group: group, quality: qualityByID[group.id])
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
            moon: sky.moon
        )
    }
}
