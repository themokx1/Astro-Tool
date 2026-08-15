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
    public let title: String
    public let explanation: String
}

public struct ProjectSeriesSnapshot: Equatable, Sendable, Identifiable {
    public let series: SeriesRecord
    public let totalFrames: Int
    public let usableFrames: Int
    public let excludedFrames: Int
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
    public var integrationSeconds: Double { series.reduce(0) { $0 + $1.integrationSeconds } }
}

public struct ProjectSnapshot: Equatable, Sendable, Identifiable {
    public let project: ProjectRecord
    public let canonicalFolderName: String
    public let series: [SeriesRecord]
    public let nights: [ProjectNightSnapshot]
    public let nextAction: ProjectNextAction
    public var id: UUID { project.id }
    public var totalFrames: Int { nights.reduce(0) { $0 + $1.totalFrames } }
    public var usableFrames: Int { nights.reduce(0) { $0 + $1.usableFrames } }
    public var integrationSeconds: Double { nights.reduce(0) { $0 + $1.integrationSeconds } }
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

    public func project(id: UUID) async throws -> ProjectSnapshot? {
        guard let project = try await metadata.project(id: id) else { return nil }
        let series = try await metadata.series(projectID: id)
        let nightByID = Dictionary(uniqueKeysWithValues: try await metadata.nights().map { ($0.id, $0) })
        var seriesByNight: [UUID: [ProjectSeriesSnapshot]] = [:]
        for record in series {
            let decisions = try await metadata.frameDecisions(seriesID: record.id)
            let usable = decisions.filter { !$0.logicallyExcluded && $0.verdict != .rejected }.count
            seriesByNight[record.nightID, default: []].append(ProjectSeriesSnapshot(
                series: record,
                totalFrames: decisions.count,
                usableFrames: usable,
                excludedFrames: decisions.count - usable,
                integrationSeconds: Double(usable) * record.exposureSeconds
            ))
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
                title: seriesCount == 0 ? "Tervezd meg az első éjszakát" : "Kezdd el a gyűjtést",
                explanation: "Válassz setupot, szűrőt és expozíciós sorozatot."
            )
        case .collecting:
            return ProjectNextAction(
                title: "Folytasd a gyűjtést",
                explanation: "A következő jó éjszakán bővítsd a hiányzó sorozatokat."
            )
        case .processing:
            return ProjectNextAction(
                title: "Folytasd a feldolgozást",
                explanation: "Ellenőrizd a stackeket és az eredmények lineage-ét."
            )
        case .complete:
            return ProjectNextAction(
                title: "Készíts végső riportot",
                explanation: "A projekt kész; exportáld a megosztható összegzést."
            )
        case .archived:
            return ProjectNextAction(
                title: "Projekt archiválva",
                explanation: "Nincs szükséges teendő."
            )
        }
    }
}
