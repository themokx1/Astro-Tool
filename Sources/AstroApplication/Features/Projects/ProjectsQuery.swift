import AstroCore
import Foundation

public struct ProjectCatalogMatch: Equatable, Sendable, Identifiable {
    public let catalogID: String
    public let displayName: String
    public let englishName: String?
    public let canonicalFolderName: String
    public let existingProjectID: UUID?
    public var id: String { catalogID }
}

public struct ProjectNextAction: Equatable, Sendable {
    public let kind: ProjectNextActionKind
    public let title: String
    public let explanation: String
}

/// `ProjectNextAction.title`/`.explanation` are English sentences meant for
/// non-UI consumers (exports, tests) that want the plain text as-is. The UI
/// localizes this instead by switching on `kind` -- the same finite,
/// enumerable case this file's own `nextAction(for:seriesCount:)` already
/// switches on -- and mapping each case to a `LocalizedStringKey` at the
/// view layer (`AstroUI`'s `ProjectsStore.swift`). No Hungarian text lives
/// here; this enum only names the cases.
public enum ProjectNextActionKind: Equatable, Sendable {
    case planFirstNight
    case startCollecting
    case keepCollecting
    case keepProcessing
    case writeFinalReport
    case archived
}

public struct ProjectSeriesSnapshot: Equatable, Sendable, Identifiable {
    public let series: SeriesRecord
    public let totalFrames: Int
    public let usableFrames: Int
    public let excludedFrames: Int
    /// Frames whose `FrameVerdict` is still `.undecided` -- same distinction
    /// `NightSnapshot.undecidedFrames`'s own doc comment makes: rejecting a
    /// frame is a completed decision, an unreviewed one is not. Added
    /// (2026-08-17 owner-feedback wave 3, Task 5) so the project workspace's
    /// own Nights tab (`ProjectNightsSummary`) can show the same triage
    /// signal the top-level Nights table already does, rather than telling
    /// the reader frame counts with no sense of which nights still need
    /// attention.
    public let undecidedFrames: Int
    public let integrationSeconds: Double
    public var id: UUID { series.id }
    public var filterName: String? { series.filterName }
    /// `KeyPathComparator` needs a non-optional `Comparable` value --
    /// unfiltered series (`filterName == nil`) sort first (as the empty
    /// string) rather than crashing the column's sort.
    public var filterSortKey: String { filterName ?? "" }
}

public struct ProjectNightSnapshot: Equatable, Sendable, Identifiable {
    public let night: NightRecord
    public let series: [ProjectSeriesSnapshot]
    public var id: UUID { night.id }
    public var totalFrames: Int { series.reduce(0) { $0 + $1.totalFrames } }
    public var usableFrames: Int { series.reduce(0) { $0 + $1.usableFrames } }
    /// Rolled up the same way `usableFrames`/`totalFrames` already are --
    /// see `ProjectSeriesSnapshot.undecidedFrames`'s own doc comment for why
    /// this exists.
    public var undecidedFrames: Int { series.reduce(0) { $0 + $1.undecidedFrames } }
    public var integrationSeconds: Double { series.reduce(0) { $0 + $1.integrationSeconds } }
}

public struct ProjectSnapshot: Equatable, Sendable, Identifiable {
    public let project: ProjectRecord
    public let canonicalFolderName: String
    public let series: [SeriesRecord]
    public let nights: [ProjectNightSnapshot]
    /// W6-C (one count, one truth): series whose `nightID` does not resolve
    /// against `metadata.nights()` -- a night record can be deleted (or a
    /// series re-pointed) independently of the series that references it.
    /// `project(id:)` used to silently drop these when building `nights`
    /// (the `compactMap`'s `guard let night = nightByID[nightID] else {
    /// return nil }` discarded the whole group, series included), so the
    /// night-grouped view undercounted `series.count` with nothing telling
    /// the reader why -- the Projects list's "Series" column (fed by the
    /// night-grouped sum) could disagree with this same project's own
    /// header/MetricCard (fed by `series.count` directly). Kept here
    /// separately, not merged back into a fabricated `nights` entry, so
    /// `nights.count` still means "real observed nights" -- the UI layer
    /// (`ProjectWorkspaceView`) surfaces this bucket honestly instead of
    /// inventing a night that never happened.
    public let orphanedSeries: [ProjectSeriesSnapshot]
    public let nextAction: ProjectNextAction
    public var id: UUID { project.id }
    /// Includes `orphanedSeries` -- see its own doc comment. Before W6-C
    /// this was `nights.reduce(...)` alone, which silently dropped an
    /// orphaned series' frames from the project's own frame count, not just
    /// its series count.
    public var totalFrames: Int {
        nights.reduce(0) { $0 + $1.totalFrames } + orphanedSeries.reduce(0) { $0 + $1.totalFrames }
    }
    /// See `totalFrames`'s own doc comment.
    public var usableFrames: Int {
        nights.reduce(0) { $0 + $1.usableFrames } + orphanedSeries.reduce(0) { $0 + $1.usableFrames }
    }
    /// See `totalFrames`'s own doc comment -- an orphaned series' usable
    /// integration time used to vanish from the project's own total, not
    /// just its series count.
    public var integrationSeconds: Double {
        nights.reduce(0) { $0 + $1.integrationSeconds } + orphanedSeries.reduce(0) { $0 + $1.integrationSeconds }
    }
}

public struct ProjectsQuery: Sendable {
    private let metadata: MetadataStore

    public init(metadata: MetadataStore) {
        self.metadata = metadata
    }

    public static func searchCatalog(_ term: String, limit: Int = 20) -> [ProjectCatalogMatch] {
        TargetCatalog.search(term, limit: limit).map { target in
            ProjectCatalogMatch(
                catalogID: target.designation,
                displayName: target.commonNameHU.map { "\(target.designation) · \($0)" }
                    ?? target.designation,
                englishName: TargetCatalog.englishName(for: target),
                canonicalFolderName: TargetCatalog.canonicalFolderName(for: target),
                existingProjectID: nil
            )
        }
    }

    public func searchCatalog(_ term: String, limit: Int = 20) async throws -> [ProjectCatalogMatch] {
        let existing = try await metadata.projects()
        let byCatalogID = Dictionary(uniqueKeysWithValues: existing.map { ($0.catalogID, $0.id) })
        return Self.searchCatalog(term, limit: limit).map { match in
            ProjectCatalogMatch(
                catalogID: match.catalogID,
                displayName: match.displayName,
                englishName: match.englishName,
                canonicalFolderName: match.canonicalFolderName,
                existingProjectID: byCatalogID[match.catalogID]
            )
        }
    }

    /// `project.catalogID` resolved to its on-disk library folder name --
    /// `TargetCatalog.canonicalFolderName` when the catalog ID still
    /// resolves to a known catalog entry, else a plain `Sanitizer.sanitize`
    /// fallback (a project can outlive a catalog entry, e.g. a renamed or
    /// removed designation). Shared by `project(id:)` (`ProjectSnapshot.
    /// canonicalFolderName`) and any other caller that needs the raw
    /// library/folder key a `ProjectRecord` maps to -- e.g. V2's
    /// `ExportService` call sites, which need this same key rather than
    /// `catalogID` itself to address `AcquisitionExport`/`NightReport`/
    /// `TargetReport`/`StackList`.
    public static func canonicalFolderName(for project: ProjectRecord) -> String {
        if let catalog = TargetCatalog.search(project.catalogID, limit: 1)
            .first(where: { $0.designation == project.catalogID }) {
            return TargetCatalog.canonicalFolderName(for: catalog)
        }
        return Sanitizer.sanitize(project.catalogID)
    }

    /// `canonical` (typically `canonicalFolderName(for:)`'s own return),
    /// resolved against the library's real `sessions/` directories.
    ///
    /// One-letter-drift fix (2026-08-17): `canonicalFolderName` answers
    /// "what folder SHOULD this catalog identity live under" from the
    /// catalog's own English name alone -- it has no way to know that a
    /// real library's on-disk spelling has drifted from that, e.g. NGC
    /// 7000's canonical `NGC_7000_North_America_Nebula` vs. the 62 real
    /// files sitting under `NGC_7000_North_American_Nebula`. Every V2
    /// caller that turns a project into an actual filesystem path (the
    /// Finder-reveal actions in `InspectorView`/`NightActionMenu`) needs the
    /// folder that is really there, not the one the catalog would have
    /// chosen. This asks the exact same engine the Results page and
    /// `ExportService` already resolve exports through --
    /// `TargetCatalog.existingFolder(for:among:)` via `ResultsQuery.
    /// libraryFolder(matching:among:)` -- against a plain directory listing
    /// (`SessionCreator.onDiskSessionFolders`) rather than a scanned
    /// `Database`, since these call sites only ever have `rootURL`. Falls
    /// back to `canonical` unchanged when nothing on disk matches (a
    /// brand-new project with no session yet, or a project whose catalog
    /// entry no longer exists) -- never a fuzzy guess of its own.
    public static func resolvedFolderName(canonical: String, rootURL: URL) -> String {
        let diskFolders = SessionCreator.onDiskSessionFolders(root: rootURL)
        return ResultsQuery.libraryFolder(matching: canonical, among: diskFolders) ?? canonical
    }

    public func project(id: UUID) async throws -> ProjectSnapshot? {
        guard let project = try await metadata.project(id: id) else { return nil }
        let series = try await metadata.series(projectID: id)
        let nightByID = Dictionary(uniqueKeysWithValues: try await metadata.nights().map { ($0.id, $0) })
        var seriesByNight: [UUID: [ProjectSeriesSnapshot]] = [:]
        // W6-C: series are partitioned into a resolvable-night bucket or
        // `orphanedSeries` HERE, at the only place that actually knows which
        // of the two applies -- `nightByID[record.nightID]` -- rather than
        // discarding the unresolvable ones inside the `compactMap` below and
        // reconstructing "what got dropped" afterward from a diff.
        var orphanedSeries: [ProjectSeriesSnapshot] = []
        for record in series {
            let decisions = try await metadata.frameDecisions(seriesID: record.id)
            let usable = decisions.filter { !$0.logicallyExcluded && $0.verdict != .rejected }.count
            let undecided = decisions.filter { $0.verdict == .undecided }.count
            let snapshot = ProjectSeriesSnapshot(
                series: record,
                totalFrames: decisions.count,
                usableFrames: usable,
                excludedFrames: decisions.count - usable,
                undecidedFrames: undecided,
                integrationSeconds: Double(usable) * record.exposureSeconds
            )
            if nightByID[record.nightID] != nil {
                seriesByNight[record.nightID, default: []].append(snapshot)
            } else {
                orphanedSeries.append(snapshot)
            }
        }
        let nights = seriesByNight.compactMap { nightID, values -> ProjectNightSnapshot? in
            guard let night = nightByID[nightID] else { return nil }
            return ProjectNightSnapshot(
                night: night,
                series: values.sorted {
                    if $0.series.exposureSeconds != $1.series.exposureSeconds {
                        return $0.series.exposureSeconds < $1.series.exposureSeconds
                    }
                    return $0.series.id.uuidString < $1.series.id.uuidString
                }
            )
        }.sorted { $0.night.localDate > $1.night.localDate }
        return ProjectSnapshot(
            project: project,
            canonicalFolderName: Self.canonicalFolderName(for: project),
            series: series,
            nights: nights,
            orphanedSeries: orphanedSeries,
            nextAction: nextAction(for: project.phase, seriesCount: series.count)
        )
    }

    private func nextAction(
        for phase: ProjectWorkflowPhase,
        seriesCount: Int
    ) -> ProjectNextAction {
        switch phase {
        case .planned:
            return ProjectNextAction(
                kind: seriesCount == 0 ? .planFirstNight : .startCollecting,
                title: seriesCount == 0 ? "Plan the first night" : "Start collecting",
                explanation: "Choose a setup, a filter and an exposure series."
            )
        case .collecting:
            return ProjectNextAction(
                kind: .keepCollecting,
                title: "Keep collecting",
                explanation: "Add the missing series on the next good night."
            )
        case .processing:
            return ProjectNextAction(
                kind: .keepProcessing,
                title: "Keep processing",
                explanation: "Check the stacks and the results' lineage."
            )
        case .complete:
            return ProjectNextAction(
                kind: .writeFinalReport,
                title: "Write the final report",
                explanation: "The project is done; export the shareable summary."
            )
        case .archived:
            return ProjectNextAction(
                kind: .archived,
                title: "Project archived",
                explanation: "Nothing to do."
            )
        }
    }
}
