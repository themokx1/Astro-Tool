import Foundation

public enum PrimarySection: String, CaseIterable, Codable, Hashable, Sendable {
    case home
    case projects
    case nights
    case planning
    case library
    case insights

    public var rootRoute: ContentRoute {
        switch self {
        case .home: .home
        case .projects: .projects
        case .nights: .nights
        case .planning: .planning
        case .library: .library
        case .insights: .insights
        }
    }
}

public enum LibrarySelection: Hashable, Codable, Sendable {
    case project(String)
    case night(String)
    case series(String)
    case frame(Int64)
    case result(String)

    public var contentRoute: ContentRoute {
        switch self {
        case .project(let id): .project(id)
        case .night(let id): .night(id)
        case .series(let id): .projectSeries(id)
        case .frame(let id): .review(String(id))
        case .result(let id): .review(id)
        }
    }

    public var primarySection: PrimarySection {
        switch self {
        case .project, .series, .result: .projects
        case .night, .frame: .nights
        }
    }
}

public enum ContentRoute: Hashable, Codable, Sendable {
    case home
    case projects
    case project(String)
    case projectSeries(String)
    case nights
    case night(String)
    case planning
    case library
    case health
    case insights
    case review(String)

    public var primarySection: PrimarySection {
        switch self {
        case .home: .home
        case .projects, .project, .projectSeries, .review: .projects
        case .nights, .night: .nights
        case .planning: .planning
        case .library, .health: .library
        case .insights: .insights
        }
    }
}

public enum PresentationRoute: Hashable, Sendable, Identifiable {
    case newProject
    case newNight
    case mutationConfirmation(UUID)
    case settingsDeepLink(String)

    public enum ID: Hashable, Sendable {
        case newProject
        case newNight
        case mutationConfirmation(UUID)
        case settingsDeepLink(String)
    }

    public var id: ID {
        switch self {
        case .newProject: .newProject
        case .newNight: .newNight
        case .mutationConfirmation(let id): .mutationConfirmation(id)
        case .settingsDeepLink(let destination): .settingsDeepLink(destination)
        }
    }
}

public enum AppRoute: Hashable, Sendable {
    case content(ContentRoute)
    case selection(LibrarySelection)
    case presentation(PresentationRoute)

    public init?(deepLink url: URL) {
        guard url.scheme?.lowercased() == "astrotool",
              let destination = url.host?.lowercased()
        else { return nil }

        let components = url.pathComponents
            .filter { $0 != "/" }
            .compactMap { $0.removingPercentEncoding }

        switch (destination, components) {
        case ("home", []): self = .content(.home)
        case ("projects", []): self = .content(.projects)
        case ("projects", let parts) where parts.count == 1 && !parts[0].isEmpty:
            self = .content(.project(parts[0]))
        case ("series", let parts) where parts.count == 1 && !parts[0].isEmpty:
            self = .selection(.series(parts[0]))
        case ("nights", []): self = .content(.nights)
        case ("nights", let parts) where parts.count == 1 && !parts[0].isEmpty:
            self = .content(.night(parts[0]))
        case ("frames", let parts) where parts.count == 1:
            guard let id = Int64(parts[0]) else { return nil }
            self = .selection(.frame(id))
        case ("results", let parts) where parts.count == 1 && !parts[0].isEmpty:
            self = .selection(.result(parts[0]))
        case ("planning", []): self = .content(.planning)
        case ("library", []): self = .content(.library)
        case ("library", ["health"]): self = .content(.health)
        case ("insights", []): self = .content(.insights)
        case ("review", let parts) where parts.count == 1 && !parts[0].isEmpty:
            self = .content(.review(parts[0]))
        case ("settings", let parts) where parts.count == 1 && !parts[0].isEmpty:
            self = .presentation(.settingsDeepLink(parts[0]))
        default: return nil
        }
    }
}

public struct WindowRestorationState: Codable, Equatable, Sendable {
    public var primarySection: PrimarySection
    public var contentRoute: ContentRoute
    public var selection: LibrarySelection?
    public var isInspectorPresented: Bool

    public init(
        primarySection: PrimarySection,
        contentRoute: ContentRoute,
        selection: LibrarySelection?,
        isInspectorPresented: Bool = false
    ) {
        self.primarySection = primarySection
        self.contentRoute = contentRoute
        self.selection = selection
        self.isInspectorPresented = isInspectorPresented
    }
}
