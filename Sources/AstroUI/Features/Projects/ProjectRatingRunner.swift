import AstroApplication
import Foundation

/// Task 4 (2026-08-17 owner-feedback wave 3): the owner asked to rate an
/// entire project ("az egészet tudjam értékelni, az összes session összes
/// capture") and to run that same rating across every project in the
/// library ("minden projektre ráengedni"). `FrameRatingCommand` itself stays
/// exactly as `ReviewStore.rateSelectedSeries`/`NightActionMenu.rateFrames`
/// already use it -- this only adds the BATCHING those two don't need: one
/// `FrameRatingCommand.run` call per night (its own anchor resolution rates a
/// single target/date session, so frames from two different nights can never
/// share one call -- see `NightActionMenu.rateFrames`'s own doc comment),
/// looped across every night of a project, or across every project.
enum ProjectRatingScope: Equatable {
    case project(id: UUID, displayName: String)
    case allProjects(libraryName: String)
}

/// Thread-safe box mirroring `ReviewStore`'s own private `FrameRatingProgressBox`,
/// just carrying an already-cumulative `(done, total)` pair across MULTIPLE
/// sequential `FrameRatingCommand.run` calls (one per night) rather than a
/// single one.
private final class ProjectRatingProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _done: Int64 = 0
    private var _total: Int64 = 0
    func update(done: Int, total: Int) {
        lock.lock(); _done = Int64(done); _total = Int64(total); lock.unlock()
    }
    var current: (done: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }
        return (_done, _total)
    }
}

@MainActor
enum ProjectRatingRunner {
    /// The `OperationHost` key one `run(scope:...)` call registers under --
    /// factored out so a caller that only needs to know whether a scope's
    /// run is CURRENTLY ACTIVE (W7-E: the Home dashboard's rating-gate card,
    /// checking `operationHost.activeOperations` to show progress instead of
    /// its own "Rate" button) can compute the same key without duplicating
    /// this switch, or launching a second `.rate` operation for the same
    /// scope by constructing a slightly different string by hand.
    static func kind(for scope: ProjectRatingScope) -> OperationKind {
        switch scope {
        case .project(let id, _):
            return .rate(series: "project-\(id.uuidString)")
        case .allProjects(let libraryName):
            return .rate(series: "all-projects-\(libraryName)")
        }
    }


    /// Groups `seriesList`'s frame paths by night, using `decisionsBySeriesID`
    /// (already-fetched `FrameDecisionRecord.relativePath`s, keyed by series
    /// id) -- a pure, synchronous step split out from `run(scope:...)` below
    /// purely so it is unit-testable without a database. Must be called with
    /// ONE project's own `seriesList` at a time: grouping by `nightID` alone
    /// across MULTIPLE projects would silently merge two different targets'
    /// frames that happen to share a night into one `FrameRatingCommand.run`
    /// call, which anchors on (and therefore only measures) whichever
    /// project's frame happens to resolve first -- the same hazard
    /// `NightActionMenu.rateFrames`'s own doc comment already calls out for a
    /// night spanning more than one project, just from the opposite
    /// direction. `run(scope:...)` avoids it by calling this once per
    /// project and flattening the per-project results, never once across
    /// all of them combined.
    static func groupRelativePathsByNight(
        seriesList: [SeriesRecord],
        decisionsBySeriesID: [UUID: [String]]
    ) -> [[String]] {
        var byNight: [UUID: [String]] = [:]
        for series in seriesList {
            guard let paths = decisionsBySeriesID[series.id], !paths.isEmpty else { continue }
            byNight[series.nightID, default: []].append(contentsOf: paths)
        }
        return Array(byNight.values)
    }

    /// Rates every night of `scope` (one project, or every project in the
    /// open library) through `FrameRatingCommand`, reporting combined
    /// progress across every night through `operationHost` exactly like
    /// `ReviewStore.rateSelectedSeries`/`NightActionMenu.rateFrames` already
    /// do, and cooperatively cancellable between nights (and between frames
    /// within a night, via `FrameRatingCommand`'s own `isCancelled`).
    ///
    /// `mode` defaults to `.nativeOnly` -- every existing call site (Home's
    /// "Rate Everything" gate card, `ProjectsView`'s "Rate All Projects",
    /// `ProjectWorkspaceView`'s per-project button) keeps its original
    /// behavior unchanged: a run spanning a whole project (or every project)
    /// can be dozens of nights long, so its default never blocks on Siril or
    /// throws `FrameRatingCommandError.sirilUnavailable`, mirroring
    /// `NightActionMenu.rateFrames`'s own night-wide rate.
    ///
    /// OWNER BUG (2026-08-19, real-library audit): `.nativeOnly` was
    /// previously the ONLY mode this function could ever run -- it computes
    /// `NativeStats` background/score but never invokes a
    /// `StarMetricsProvider` (`FrameRatingCommand.run`'s `provider = nil` for
    /// `.nativeOnly`), so it can NEVER populate `ratings.fwhm`. The owner
    /// pressed "Minden projekt értékelése" (this function's `.allProjects`
    /// scope) and reported the Insights FWHM trend never changing -- his
    /// real `ratings` table confirmed it: 489 rows written by that exact
    /// run, all with `fwhm IS NULL`, `siril_version = ''`. Pressing the same
    /// nativeOnly-only button again could never have fixed that, no matter
    /// how many times. `mode` is now a real parameter so a caller that wants
    /// star metrics (`InsightsView`'s new "Start Measuring" action, wired to
    /// `.fullReMeasure`) can ask for them through this exact same batching
    /// layer, instead of duplicating it.
    ///
    /// `commandFactory` mirrors `metadataFactory`'s injection shape purely so
    /// tests can supply a fixture-backed `FrameRatingCommand(db:config:root:)`
    /// (real sqlite + real FITS bytes on disk, `RatingCommandFixture`'s own
    /// pattern in `FrameRatingCommandTests`) instead of `.production(rootURL:)`,
    /// which resolves a REAL `~/Library/Application Support/AstroTool/...`
    /// path from `rootURL`'s own identity hash.
    static func run(
        scope: ProjectRatingScope,
        rootURL: URL,
        metadataFactory: @escaping ProjectsStore.MetadataFactory,
        operationHost: OperationHost,
        mode: FrameRatingMode = .nativeOnly,
        commandFactory: @escaping (URL) throws -> FrameRatingCommand = { try FrameRatingCommand.production(rootURL: $0) }
    ) async {
        let kind = Self.kind(for: scope)
        let title: String
        switch scope {
        case .project(_, let displayName):
            title = "\(OperationHost.localized("Rating Frames")) — \(displayName)"
        case .allProjects:
            title = "\(OperationHost.localized("Rating Frames")) — \(OperationHost.localized("All Projects"))"
        }
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else {
            operationHost.notify(.info, message: OperationHost.localized("Frame rating is already running for this scope."))
            return
        }

        do {
            let metadata = try metadataFactory(rootURL)
            let projects: [ProjectRecord]
            switch scope {
            case .project(let id, _):
                guard let record = try await metadata.project(id: id) else {
                    operationHost.notify(.failure, message: OperationHost.localized("Project not found."))
                    return
                }
                projects = [record]
            case .allProjects:
                projects = try await metadata.projects()
            }

            var groups: [[String]] = []
            for project in projects {
                let seriesList = try await metadata.series(projectID: project.id)
                var decisionsBySeriesID: [UUID: [String]] = [:]
                for series in seriesList {
                    let decisions = try await metadata.frameDecisions(seriesID: series.id)
                    decisionsBySeriesID[series.id] = decisions.map(\.relativePath)
                }
                groups.append(contentsOf: groupRelativePathsByNight(seriesList: seriesList, decisionsBySeriesID: decisionsBySeriesID))
            }
            guard !groups.isEmpty else {
                operationHost.notify(.info, message: OperationHost.localized("No frames to rate."))
                return
            }
            // `let`-bound before entering the `@Sendable` work closure below --
            // a `var` cannot be captured by a `@Sendable` closure even
            // read-only, since the compiler cannot prove nothing else still
            // mutates it concurrently.
            let frozenGroups = groups
            let totalFrames = frozenGroups.reduce(0) { $0 + $1.count }
            let command = try commandFactory(rootURL)
            let box = ProjectRatingProgressBox()

            let id = await operationHost.run(kind: kind, title: title, cancellation: .cooperative) {
                var cumulative = 0
                for paths in frozenGroups {
                    try Task.checkCancellation()
                    let base = cumulative
                    _ = try command.run(
                        relativePaths: paths,
                        mode: mode,
                        progress: { done, _ in box.update(done: base + done, total: totalFrames) },
                        isCancelled: { Task.isCancelled }
                    )
                    cumulative += paths.count
                    box.update(done: cumulative, total: totalFrames)
                }
            }
            operationHost.relayProgress(id: id) {
                let progress = box.current
                return OperationProgress(completed: progress.done, total: progress.total > 0 ? progress.total : nil)
            }
        } catch {
            operationHost.notify(.failure, message: "\(OperationHost.localized("Frame rating failed:")) \(error.localizedDescription)")
        }
    }
}
