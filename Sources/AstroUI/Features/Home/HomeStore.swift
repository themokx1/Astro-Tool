import Foundation
import Observation
import AstroApplication
import AstroCore

public struct HomeTonightRecommendation: Equatable, Sendable, Identifiable {
    public var id: String { target }
    public let projectID: UUID?
    public let target: String
    public let displayName: String
    public let visibleWindow: String?
    public let culmination: String?
    public let maxAltitude: Double?
    public let moonSeparation: Double?
    public let verdict: String
    public let score: Double
}

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
    public let tonightRecommendations: [HomeTonightRecommendation]

    public init(
        libraryName: String?,
        nightContext: NightContext,
        projectCount: Int = 0,
        nightCount: Int = 0,
        nextProject: ProjectRecord? = nil,
        nextProjectIntegrationSeconds: Double = 0,
        tonightRecommendations: [HomeTonightRecommendation] = []
    ) {
        self.libraryName = libraryName
        self.nightContext = nightContext
        self.projectCount = projectCount
        self.nightCount = nightCount
        self.nextProject = nextProject
        self.nextProjectIntegrationSeconds = nextProjectIntegrationSeconds
        self.tonightRecommendations = tonightRecommendations
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
    public typealias TonightProvider = @Sendable (URL) async throws -> [TargetPlan]
    public typealias CalibCoverageProvider = @Sendable (URL) async throws -> [CalibNeed]
    public private(set) var snapshot: HomeSnapshot
    /// The full plan `tonightRecommendations` was sliced from (`prefix(8)`,
    /// display-only) -- kept around so the "Export Plan" menu
    /// (`v2.home.plan-export`) can hand `ExportService.planCSV`/
    /// `planClipboardText` every planned target, not just the ones shown on
    /// screen.
    public private(set) var tonightPlans: [TargetPlan] = []
    /// Tonight's calibration shopping list (`CalibShoppingList.build`), for
    /// the same export menu's "Copy Shopping List" item -- same actionable +
    /// relevant-tonight filtering V1's "Kalibrációs teendők ma estére" card
    /// already applies.
    public private(set) var calibShoppingItems: [CalibShoppingList.Item] = []
    private let tonightProvider: TonightProvider
    private let calibCoverageProvider: CalibCoverageProvider

    public init(
        snapshot: HomeSnapshot = .unconfigured,
        tonightProvider: @escaping TonightProvider = HomeStore.productionTonight,
        calibCoverageProvider: @escaping CalibCoverageProvider = HomeStore.productionCalibCoverage
    ) {
        self.snapshot = snapshot
        self.tonightProvider = tonightProvider
        self.calibCoverageProvider = calibCoverageProvider
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
        rootURL: URL? = nil,
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
        let plans: [TargetPlan] = if let rootURL {
            (try? await tonightProvider(rootURL)) ?? []
        } else {
            []
        }
        tonightPlans = plans
        let coverage: [CalibNeed] = if let rootURL {
            (try? await calibCoverageProvider(rootURL)) ?? []
        } else {
            []
        }
        calibShoppingItems = CalibShoppingList.build(coverage: coverage, plans: plans)
        let recommendations = plans.prefix(8).map { plan in
            HomeTonightRecommendation(
                projectID: Self.projectID(for: plan, projects: projectsStore.projects),
                target: plan.target,
                displayName: plan.displayName,
                visibleWindow: plan.visibleWindowLocal,
                culmination: plan.culminationLocal,
                maxAltitude: plan.maxAltitudeDeg,
                moonSeparation: plan.moonSeparationDeg,
                verdict: plan.verdict,
                score: plan.score
            )
        }
        snapshot = HomeSnapshot(
            libraryName: libraryName,
            nightContext: snapshot.nightContext,
            projectCount: projectsStore.projects.count,
            nightCount: nightCount,
            nextProject: next?.0,
            nextProjectIntegrationSeconds: next?.1 ?? 0,
            tonightRecommendations: recommendations
        )
    }

    public static func productionTonight(rootURL: URL) async throws -> [TargetPlan] {
        try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            return try Planner.plan(db: database, config: config)
        }.value
    }

    /// Darks + flats concatenated into one list -- same "one merged coverage
    /// list" convention V1's `AppState.loadCalibBundle` already documents for
    /// itself, needed here only as `CalibShoppingList.build`'s own `coverage`
    /// input.
    public static func productionCalibCoverage(rootURL: URL) async throws -> [CalibNeed] {
        let query = try CalibrationQuery.production(rootURL: rootURL)
        return try await Task.detached(priority: .utility) {
            try query.coverage() + query.flatCoverage()
        }.value
    }

    private static func projectID(for plan: TargetPlan, projects: [ProjectRecord]) -> UUID? {
        let keys = [plan.target, plan.displayName].map(normalized)
        return projects.first {
            keys.contains(normalized($0.catalogID)) || keys.contains(normalized($0.displayName))
        }?.id
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            .map(String.init).joined().lowercased()
    }
}
