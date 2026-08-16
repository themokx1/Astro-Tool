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
    /// V2 UI/UX audit (2026-08-14) section 4: this used to be three plain
    /// strings with no way to say "there is nothing real to show yet" --
    /// `HomeStore.configure` therefore always carried the very first
    /// (hardcoded) value forward unchanged, and `NightContextRail` drew a
    /// fixed-geometry dusk/observation-window/dawn plot that never reflected
    /// any actual site or time. `isConfigured` is the honest flag: `false`
    /// means no site could be resolved (no explicit `AstroConfig.site`, no
    /// FITS-median fallback) for this library, so the rail must say so
    /// instead of drawing a plot. `nowFraction` (0...1) is only meaningful
    /// when configured -- where "now" sits between dusk and dawn tonight --
    /// and `nil` whenever `now` falls outside that window (before dusk /
    /// after dawn) or the window can't be computed.
    public struct NightContext: Equatable, Sendable {
        public let isConfigured: Bool
        public let leadingLabel: String
        public let centerLabel: String
        public let trailingLabel: String
        public let nowFraction: Double?

        public init(
            isConfigured: Bool,
            leadingLabel: String,
            centerLabel: String,
            trailingLabel: String,
            nowFraction: Double? = nil
        ) {
            self.isConfigured = isConfigured
            self.leadingLabel = leadingLabel
            self.centerLabel = centerLabel
            self.trailingLabel = trailingLabel
            self.nowFraction = nowFraction
        }

        /// Neutral, honest default: no site has been resolved for the open
        /// library (or none is open yet), so there is nothing real to plot.
        public static let unconfigured = NightContext(
            isConfigured: false, leadingLabel: "Dusk", centerLabel: "Site not configured", trailingLabel: "Dawn"
        )
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
        nightContext: .unconfigured
    )
}

@MainActor
@Observable
public final class HomeStore {
    public typealias TonightProvider = @Sendable (URL) async throws -> [TargetPlan]
    public typealias CalibCoverageProvider = @Sendable (URL) async throws -> [CalibNeed]
    /// Resolves tonight's honest night context for an open library -- real
    /// dusk/dawn (from the site the planner itself would resolve: explicit
    /// config, else the FITS-median fallback) when a site is available,
    /// `.unconfigured` otherwise. Injectable for the same reason
    /// `tonightProvider`/`calibCoverageProvider` are: it lets tests supply a
    /// fixed result without needing a real FITS-backed library on disk.
    public typealias NightContextProvider = @Sendable (URL) async throws -> HomeSnapshot.NightContext
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
    private let nightContextProvider: NightContextProvider

    /// All three providers are `Optional`/`nil` rather than defaulted
    /// directly to the `production…` methods, and must stay that way: an
    /// `async` default argument is re-emitted as a `weak`/`linkonce_odr`
    /// async function pointer record in every module that uses it, with a
    /// different context size in the declaring module than in a client (80
    /// vs 64 for `tonightProvider`/`calibCoverageProvider`) -- a link that
    /// pairs the big body with the small record corrupts the task allocator.
    /// `nightContextProvider`'s two copies happen to agree today (144 both
    /// ways, a coincidence of its return type, not a guarantee); it gets the
    /// same shape because the hazard is the pattern, not the one symbol that
    /// currently diverges. `snapshot` is not `async`, emits no such record,
    /// and is deliberately left as an ordinary default.
    /// `AsyncContextSizeGateTests` gates this and carries the full account.
    public init(
        snapshot: HomeSnapshot = .unconfigured,
        tonightProvider: TonightProvider? = nil,
        calibCoverageProvider: CalibCoverageProvider? = nil,
        nightContextProvider: NightContextProvider? = nil
    ) {
        self.snapshot = snapshot
        self.tonightProvider = tonightProvider ?? HomeStore.productionTonight
        self.calibCoverageProvider = calibCoverageProvider ?? HomeStore.productionCalibCoverage
        self.nightContextProvider = nightContextProvider ?? HomeStore.productionNightContext
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
        // V2 UI/UX audit (2026-08-14) section 4: this used to carry
        // `snapshot.nightContext` forward completely unchanged, so the home
        // screen's night rail never reflected the library actually open --
        // it now asks `nightContextProvider` for the real answer (or the
        // honest `.unconfigured` state) every time a library opens.
        let nightContext: HomeSnapshot.NightContext = if let rootURL {
            (try? await nightContextProvider(rootURL)) ?? .unconfigured
        } else {
            .unconfigured
        }
        snapshot = HomeSnapshot(
            libraryName: libraryName,
            nightContext: nightContext,
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

    /// Resolves tonight's real dusk/dawn window from whatever site the
    /// planner itself would use -- `Planner.resolveSite` (explicit
    /// `AstroConfig.site`/`sites`, else the FITS-median fallback across the
    /// library's own scanned lights), so this never invents a location the
    /// rest of the app doesn't already treat as authoritative. Falls back to
    /// the honest `.unconfigured` state when no site resolves at all (a
    /// fresh library with no site set and no FITS coordinates yet), or when
    /// tonight's Sun never crosses twilight at this site (`astronomicalTwilight`
    /// returns `nil` dusk/dawn).
    public static func productionNightContext(rootURL: URL) async throws -> HomeSnapshot.NightContext {
        try await Task.detached(priority: .utility) {
            let identity = LibraryIdentity(rootURL: rootURL)
            let paths = try AppStoragePaths.production(libraryID: identity, libraryRoot: rootURL)
            let database = try Database(path: paths.indexDatabase.path)
            let configURL = rootURL.appendingPathComponent(".astro_tool/config.json")
            var config = (try? AstroConfig.load(from: configURL)) ?? AstroConfig()
            config.rootPath = rootURL.path
            let site = try Planner.resolveSite(db: database, config: config)
            guard let latitudeDeg = site.latitudeDeg, let longitudeDeg = site.longitudeDeg else {
                return .unconfigured
            }

            let now = Date()
            let timeZone = TimeZone.current
            let twilight = SunMoon.astronomicalTwilight(
                nightOf: now, latDeg: latitudeDeg, lonDeg: longitudeDeg, timeZone: timeZone
            )
            guard let duskUTC = twilight.duskUTC, let dawnUTC = twilight.dawnUTC else {
                return HomeSnapshot.NightContext(
                    isConfigured: true, leadingLabel: "Dusk", centerLabel: "No astronomical night tonight at this latitude",
                    trailingLabel: "Dawn"
                )
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            formatter.timeZone = timeZone
            let leadingLabel = "Dusk \(formatter.string(from: duskUTC))"
            let trailingLabel = "Dawn \(formatter.string(from: dawnUTC))"
            let windowSeconds = dawnUTC.timeIntervalSince(duskUTC)
            let nowFraction: Double? = windowSeconds > 0
                ? min(max(now.timeIntervalSince(duskUTC) / windowSeconds, 0), 1)
                : nil

            let centerLabel: String
            if now < duskUTC {
                centerLabel = "Before tonight's dusk"
            } else if now > dawnUTC {
                centerLabel = "After tonight's dawn"
            } else {
                let remainingMinutes = Int(dawnUTC.timeIntervalSince(now) / 60)
                centerLabel = "\(remainingMinutes / 60)h \(remainingMinutes % 60)m to dawn"
            }

            return HomeSnapshot.NightContext(
                isConfigured: true, leadingLabel: leadingLabel, centerLabel: centerLabel,
                trailingLabel: trailingLabel, nowFraction: nowFraction
            )
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
