import Foundation
import Observation
import AstroApplication

public struct HomeSnapshot: Equatable, Sendable {
    public struct NightContext: Equatable, Sendable {
        public let leadingLabel: String
        public let centerLabel: String
        public let trailingLabel: String

        public init(
            leadingLabel: String,
            centerLabel: String,
            trailingLabel: String
        ) {
            self.leadingLabel = leadingLabel
            self.centerLabel = centerLabel
            self.trailingLabel = trailingLabel
        }
    }

    public let libraryName: String?
    public let nightContext: NightContext
    public let projectCount: Int
    public let nightCount: Int
    public let nextProject: ProjectRecord?
    public let nextProjectIntegrationSeconds: Double

    public init(
        libraryName: String?,
        nightContext: NightContext,
        projectCount: Int = 0,
        nightCount: Int = 0,
        nextProject: ProjectRecord? = nil,
        nextProjectIntegrationSeconds: Double = 0
    ) {
        self.libraryName = libraryName
        self.nightContext = nightContext
        self.projectCount = projectCount
        self.nightCount = nightCount
        self.nextProject = nextProject
        self.nextProjectIntegrationSeconds = nextProjectIntegrationSeconds
    }

    /// Neutral preview content: it conveys the shape of the workspace without
    /// inventing a home location, equipment profile, or observation target.
    public static let unconfigured = HomeSnapshot(
        libraryName: nil,
        nightContext: NightContext(
            leadingLabel: "Dusk",
            centerLabel: "Observation window",
            trailingLabel: "Dawn"
        )
    )
}

@MainActor
@Observable
public final class HomeStore {
    public private(set) var snapshot: HomeSnapshot

    public init(snapshot: HomeSnapshot = .unconfigured) {
        self.snapshot = snapshot
    }

    public func replaceSnapshot(_ snapshot: HomeSnapshot) {
        self.snapshot = snapshot
    }

    public func configure(libraryName: String, projects: [ProjectRecord], nightCount: Int) {
        let nextProject = projects.first(where: { $0.phase == .collecting }) ?? projects.first
        snapshot = HomeSnapshot(
            libraryName: libraryName,
            nightContext: snapshot.nightContext,
            projectCount: projects.count,
            nightCount: nightCount,
            nextProject: nextProject
        )
    }

    public func configure(
        libraryName: String,
        projectsStore: ProjectsStore,
        nightCount: Int
    ) async {
        let active = projectsStore.projects.filter { $0.phase == .collecting || $0.phase == .planned }
        var ranked: [(ProjectRecord, Double)] = []
        for project in active {
            let integration = (try? await projectsStore.projectSnapshot(id: project.id)?.integrationSeconds) ?? 0
            ranked.append((project, integration))
        }
        let next = ranked.min {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.catalogID < $1.0.catalogID
        }
        snapshot = HomeSnapshot(
            libraryName: libraryName,
            nightContext: snapshot.nightContext,
            projectCount: projectsStore.projects.count,
            nightCount: nightCount,
            nextProject: next?.0,
            nextProjectIntegrationSeconds: next?.1 ?? 0
        )
    }
}
