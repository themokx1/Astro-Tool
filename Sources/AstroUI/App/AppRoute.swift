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
        case .frame(let id): .reviewFrame(id)
        case .result(let id): .result(id)
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
    /// Wave 5 Task 4: the saved-targets list, pushed from Planning's own
    /// "Saved Targets" action (mirrors `.health`/`.calibration`'s own shape
    /// as a distinct route nested under a different section's
    /// `primarySection`).
    case savedTargets
    case library
    case health
    case calibration
    case insights
    case reviewFrame(Int64)
    case result(String)
    /// Wave 4 Task 1: the frame-review workspace as a route (was a
    /// window-covering `.overlay` in `V2Shell` -- see the navigation rework
    /// plan). Carries the project whose capture series are being reviewed;
    /// `ReviewWorkspace` resolves everything else itself from `rootURL` +
    /// `projectID`.
    case review(projectID: UUID)
    /// Wave 4 Task 1: the results/lineage workspace as a route (was the
    /// `.overlay`-presented `ResultsView`).
    case resultsWorkspace(projectID: UUID)
    /// Wave 4 Task 1: the session-conversion wizard as a route (was the
    /// `.overlay`-presented `ConversionWorkspace`).
    case conversion
    /// Wave 4 Task 1: the cleanup/quarantine preview as a route (was nested
    /// inside `HealthView`'s own `.overlay`).
    case cleanup
    /// Wave 4 Task 1: the sensor-profiles workspace as a route (was nested
    /// inside `HealthView`'s own `.overlay`).
    case sensorProfiles

    public var primarySection: PrimarySection {
        switch self {
        case .home: .home
        case .projects, .project, .projectSeries, .result, .review, .resultsWorkspace: .projects
        case .nights, .night, .reviewFrame: .nights
        case .planning, .savedTargets: .planning
        case .library, .health, .calibration, .conversion, .cleanup, .sensorProfiles: .library
        case .insights: .insights
        }
    }

    public var selection: LibrarySelection? {
        switch self {
        case .project(let id): .project(id)
        case .projectSeries(let id): .series(id)
        case .night(let id): .night(id)
        case .reviewFrame(let id): .frame(id)
        case .result(let id): .result(id)
        default: nil
        }
    }
}

public enum PresentationRoute: Hashable, Sendable, Identifiable {
    case newProject
    case newNight
    case mutationConfirmation(UUID)
    case settingsDeepLink(String)
    /// Wave 3 Task 7: Help ▸ Glossary -- `anchor`, when set, is the exact
    /// term name `GlossaryView` scrolls straight to (used by
    /// `MetricInfoButton`'s per-metric "In the Glossary" links); `nil` opens
    /// at the top, same as the plain Help-menu entry point.
    case glossary(String?)
    /// Wave 3 Task 7: Help ▸ Folder Structure.
    case folderStructure
    /// Wave 3 Task 7: Help ▸ First Steps.
    case firstSteps

    public enum ID: Hashable, Sendable {
        case newProject
        case newNight
        case mutationConfirmation(UUID)
        case settingsDeepLink(String)
        case glossary
        case folderStructure
        case firstSteps
    }

    public var id: ID {
        switch self {
        case .newProject: .newProject
        case .newNight: .newNight
        case .mutationConfirmation(let id): .mutationConfirmation(id)
        case .settingsDeepLink(let destination): .settingsDeepLink(destination)
        case .glossary: .glossary
        case .folderStructure: .folderStructure
        case .firstSteps: .firstSteps
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

        guard url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              let encodedPath = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              )?.percentEncodedPath,
              let components = Self.decodePathComponents(encodedPath)
        else { return nil }

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
        case ("planning", ["saved"]): self = .content(.savedTargets)
        case ("library", []): self = .content(.library)
        // Task 10: Health's findings now live on the Archive page itself
        // (it no longer has its own sidebar row), but `astrotool://library/
        // health` ships in already-published documentation -- redirecting it
        // to `.library` rather than dropping it keeps that link working
        // instead of resolving to nothing.
        case ("library", ["health"]): self = .content(.library)
        case ("library", ["calibration"]): self = .content(.calibration)
        case ("insights", []): self = .content(.insights)
        case ("settings", let parts) where parts.count == 1 && !parts[0].isEmpty:
            self = .presentation(.settingsDeepLink(parts[0]))
        default: return nil
        }
    }

    private static func decodePathComponents(_ path: String) -> [String]? {
        guard !path.isEmpty else { return [] }
        guard path.first == "/" else { return nil }

        let encodedComponents = path.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        var decodedComponents: [String] = []
        decodedComponents.reserveCapacity(encodedComponents.count)

        for encodedComponent in encodedComponents {
            guard !encodedComponent.isEmpty,
                  let decoded = String(encodedComponent).removingPercentEncoding,
                  isValidIdentifier(decoded)
            else { return nil }
            decodedComponents.append(decoded)
        }

        return decodedComponents
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains("/"),
              !value.contains("\\")
        else { return false }

        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }
}

public struct WindowRestorationState: Codable, Equatable, Sendable {
    public var primarySection: PrimarySection
    public var contentRoute: ContentRoute
    public var selection: LibrarySelection?
    public var isInspectorPresented: Bool
    /// Wave 4 Task 3: the project/night workspace's own last-selected tab.
    /// `Optional` (rather than a defaulted non-optional) so a state blob
    /// encoded before this task shipped -- which has no `projectTab`/
    /// `nightTab` key at all -- still decodes: synthesized `Decodable`
    /// treats a missing key on an `Optional` property as `nil`, no custom
    /// `init(from:)` required. `AppRouter`'s own restoring `init` maps `nil`
    /// back to `.overview`, its own default.
    public var projectTab: ProjectWorkspaceTab?
    public var nightTab: NightWorkspaceTab?

    public init(
        primarySection: PrimarySection,
        contentRoute: ContentRoute,
        selection: LibrarySelection?,
        isInspectorPresented: Bool = false,
        projectTab: ProjectWorkspaceTab? = nil,
        nightTab: NightWorkspaceTab? = nil
    ) {
        self.primarySection = primarySection
        self.contentRoute = contentRoute
        self.selection = selection
        self.isInspectorPresented = isInspectorPresented
        self.projectTab = projectTab
        self.nightTab = nightTab
    }
}

/// The `ProjectWorkspaceView` segmented picker's own tabs -- lives here
/// (rather than nested inside the view, its previous location as a private
/// `Section` enum) because `AppRouter` (this file's sibling `AppModel.swift`)
/// now owns the SELECTED tab as a plain router property, so a project
/// pushed, then navigated away from and back to, keeps whichever tab was
/// showing (Wave 4 Task 3 -- see the navigation-rework plan). `String`
/// raw values are the exact segmented-picker labels.
public enum ProjectWorkspaceTab: String, CaseIterable, Hashable, Codable, Sendable {
    case overview = "Overview"
    case nights = "Nights"
    case series = "Series"
    case results = "Results"
    case notes = "Notes"
}

/// `NightWorkspaceView`'s own segmented tabs, router-owned for the same
/// reason as `ProjectWorkspaceTab` above.
public enum NightWorkspaceTab: String, CaseIterable, Hashable, Codable, Sendable {
    case overview = "Overview"
    case series = "Series"
    case frames = "Frames"
    case notes = "Notes"
}
