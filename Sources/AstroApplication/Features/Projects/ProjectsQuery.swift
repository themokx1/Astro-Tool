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

public struct ProjectSnapshot: Equatable, Sendable, Identifiable {
    public let project: ProjectRecord
    public let canonicalFolderName: String
    public let series: [SeriesRecord]
    public let nextAction: ProjectNextAction
    public var id: UUID { project.id }
}

public struct ProjectsQuery: Sendable {
    private let metadata: MetadataStore

    public init(metadata: MetadataStore) {
        self.metadata = metadata
    }

    public func searchCatalog(_ term: String, limit: Int = 20) async throws -> [ProjectCatalogMatch] {
        let existing = try await metadata.projects()
        let byCatalogID = Dictionary(uniqueKeysWithValues: existing.map { ($0.catalogID, $0.id) })
        return TargetCatalog.search(term, limit: limit).map { target in
            ProjectCatalogMatch(
                catalogID: target.designation,
                displayName: target.commonNameHU.map { "\(target.designation) · \($0)" }
                    ?? target.designation,
                englishName: TargetCatalog.englishName(for: target),
                canonicalFolderName: TargetCatalog.canonicalFolderName(for: target),
                existingProjectID: byCatalogID[target.designation]
            )
        }
    }

    public func project(id: UUID) async throws -> ProjectSnapshot? {
        guard let project = try await metadata.project(id: id) else { return nil }
        let series = try await metadata.series(projectID: id)
        let canonicalFolder: String
        if let catalog = TargetCatalog.search(project.catalogID, limit: 1)
            .first(where: { $0.designation == project.catalogID }) {
            canonicalFolder = TargetCatalog.canonicalFolderName(for: catalog)
        } else {
            canonicalFolder = Sanitizer.sanitize(project.catalogID)
        }
        return ProjectSnapshot(
            project: project,
            canonicalFolderName: canonicalFolder,
            series: series,
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
