import AstroApplication
import Foundation
import Observation

public struct RouteRestorationValidator: Sendable {
    private let selectionAvailability: @Sendable (LibrarySelection) -> Bool
    private let contentRouteAvailability: @Sendable (ContentRoute) -> Bool

    public init(
        selectionIsAvailable: @escaping @Sendable (LibrarySelection) -> Bool,
        contentRouteIsAvailable: @escaping @Sendable (ContentRoute) -> Bool
    ) {
        selectionAvailability = selectionIsAvailable
        contentRouteAvailability = contentRouteIsAvailable
    }

    public func isAvailable(_ selection: LibrarySelection) -> Bool {
        selectionAvailability(selection)
    }

    public func isAvailable(_ route: ContentRoute) -> Bool {
        contentRouteAvailability(route)
    }

    public static let allowingAll = RouteRestorationValidator(
        selectionIsAvailable: { _ in true },
        contentRouteIsAvailable: { _ in true }
    )
}

@MainActor
@Observable
public final class AppRouter {
    public var primarySection: PrimarySection {
        didSet {
            guard primarySection != oldValue else { return }
            contentRoute = primarySection.rootRoute
            inspectorSelection = nil
            isInspectorPresented = false
        }
    }
    public private(set) var contentRoute: ContentRoute
    public private(set) var inspectorSelection: LibrarySelection?
    public var isInspectorPresented: Bool
    public var presentation: PresentationRoute?

    public init() {
        primarySection = .home
        contentRoute = .home
        inspectorSelection = nil
        isInspectorPresented = true
        presentation = nil
    }

    public init(
        restoring state: WindowRestorationState,
        validator: RouteRestorationValidator
    ) {
        presentation = nil

        let routeIsConsistent = state.contentRoute.primarySection == state.primarySection
        let routeIsAvailable = state.contentRoute.selection == nil
            || validator.isAvailable(state.contentRoute)

        if let selection = state.selection,
           routeIsConsistent,
           routeIsAvailable,
           validator.isAvailable(selection),
           selection.primarySection == state.primarySection,
           selection.contentRoute == state.contentRoute {
            primarySection = selection.primarySection
            contentRoute = selection.contentRoute
            inspectorSelection = selection
            isInspectorPresented = state.isInspectorPresented
        } else if state.selection == nil, routeIsConsistent, routeIsAvailable {
            primarySection = state.primarySection
            contentRoute = state.contentRoute
            inspectorSelection = nil
            isInspectorPresented = state.isInspectorPresented
        } else {
            primarySection = state.primarySection
            contentRoute = state.primarySection.rootRoute
            inspectorSelection = nil
            isInspectorPresented = false
        }
    }

    public var restorationState: WindowRestorationState {
        WindowRestorationState(
            primarySection: primarySection,
            contentRoute: contentRoute,
            selection: inspectorSelection,
            isInspectorPresented: isInspectorPresented
        )
    }

    public func navigate(to section: PrimarySection) {
        primarySection = section
        contentRoute = section.rootRoute
        inspectorSelection = nil
        isInspectorPresented = false
    }

    public func navigate(toContent route: ContentRoute) {
        primarySection = route.primarySection
        contentRoute = route
        inspectorSelection = route.selection
        isInspectorPresented = inspectorSelection != nil
    }

    public func open(_ route: AppRoute) {
        switch route {
        case .content(let route): navigate(toContent: route)
        case .selection(let selection): select(selection)
        case .presentation(let route): present(route)
        }
    }

    public func select(_ selection: LibrarySelection) {
        primarySection = selection.primarySection
        contentRoute = selection.contentRoute
        inspectorSelection = selection
        isInspectorPresented = true
    }

    public func clearSelection() {
        inspectorSelection = nil
        contentRoute = primarySection.rootRoute
        isInspectorPresented = false
    }

    public func reconcileSelection(isAvailable: (LibrarySelection) -> Bool) {
        guard let inspectorSelection, !isAvailable(inspectorSelection) else { return }
        clearSelection()
    }

    public func toggleInspector() {
        isInspectorPresented.toggle()
    }

    public func present(_ route: PresentationRoute) {
        presentation = route
    }

    public func dismissPresentation() {
        presentation = nil
    }

}

/// One entry in the Libraries settings tab's "Recent Libraries" list --
/// `path`/`displayName` are the library folder's own path and name, which is
/// exactly the kind of thing `SupportDiagnostics` refuses to carry, so this
/// type stays local to `AppModel`/the Libraries settings surface and is
/// never threaded into a diagnostics payload.
public struct RecentLibraryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let displayName: String
    public let lastOpenedAt: Date

    public init(path: String, displayName: String, lastOpenedAt: Date) {
        self.path = path
        self.displayName = displayName
        self.lastOpenedAt = lastOpenedAt
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// Persists the Libraries settings tab's recent-library list, the same
/// closure-backed-`load`/`save` shape `LibraryWelcomeView`'s
/// `LibraryBookmarkStore` already established for the single bookmarked
/// root -- `.production` reads/writes a `UserDefaults` key, `.inactive` and
/// any test double just hold state in memory.
public struct RecentLibrariesStore: @unchecked Sendable {
    private let loadEntries: () -> [RecentLibraryEntry]
    private let saveEntries: ([RecentLibraryEntry]) -> Void

    public init(
        load: @escaping () -> [RecentLibraryEntry],
        save: @escaping ([RecentLibraryEntry]) -> Void
    ) {
        loadEntries = load
        saveEntries = save
    }

    public func load() -> [RecentLibraryEntry] { loadEntries() }
    public func save(_ entries: [RecentLibraryEntry]) { saveEntries(entries) }

    public static func production(defaults: UserDefaults = .standard) -> Self {
        let key = "v2.library.recentLibraries"
        return Self(
            load: {
                guard let data = defaults.data(forKey: key),
                      let entries = try? JSONDecoder().decode([RecentLibraryEntry].self, from: data)
                else { return [] }
                return entries
            },
            save: { entries in
                defaults.set(try? JSONEncoder().encode(entries), forKey: key)
            }
        )
    }

    public static let inactive = Self(load: { [] }, save: { _ in })
}

@MainActor
@Observable
public final class AppModel {
    /// Most-recent-first, capped here rather than left to grow unbounded --
    /// matches the plan's "recent, capped ~5" contract.
    private static let maximumRecentLibraries = 5

    private var windowRouters: [UUID: AppRouter]
    private let restorationValidator: RouteRestorationValidator
    private let recentLibrariesStore: RecentLibrariesStore

    public private(set) var recentLibraries: [RecentLibraryEntry]
    /// The library root currently open in (any of) this app's windows --
    /// `V2RootView` reports it here whenever `OnboardingStore` reaches
    /// `.summary`, so `V2SettingsView`'s Support tab (a separate `Settings`
    /// scene with no direct reference to any window's stores) can build a
    /// live diagnostics snapshot against it.
    public private(set) var currentLibraryRootURL: URL?
    /// The already-open metadata store for `currentLibraryRootURL`, handed
    /// over by `ProjectsStore.metadataStore` -- Support diagnostics query
    /// through this rather than opening a second confined connection to the
    /// same metadata database (that path is meant to have one owner at a
    /// time). `nil` whenever no library is open, or the window's own store
    /// has not finished opening yet.
    public private(set) var currentMetadataStore: MetadataStore?
    /// Set by the Libraries settings tab's "Switch" action on a recent
    /// entry; `V2RootView` observes this and routes the switch through its
    /// own `OnboardingStore.openAndScan` -- the very same path a fresh
    /// library pick uses -- then clears it. Settings has no direct
    /// reference to any window's `OnboardingStore`, so this is the
    /// hand-off point between the two scenes.
    public private(set) var pendingLibrarySwitchURL: URL?

    public init(
        restorationValidator: RouteRestorationValidator,
        recentLibrariesStore: RecentLibrariesStore = .production()
    ) {
        windowRouters = [:]
        self.restorationValidator = restorationValidator
        self.recentLibrariesStore = recentLibrariesStore
        recentLibraries = recentLibrariesStore.load()
        currentLibraryRootURL = nil
        pendingLibrarySwitchURL = nil
    }

    /// Records `rootURL` as the currently open library and moves it to the
    /// front of `recentLibraries`, deduplicating by path, capping the list,
    /// and persisting the result -- called once a library reaches its
    /// summary phase, regardless of whether it got there via a fresh pick,
    /// a restored bookmark, or a recent-library switch. `metadataStore` is
    /// the window's own already-open store (`ProjectsStore.metadataStore`)
    /// -- pass `nil` if it is not available yet; `currentMetadataStore`
    /// simply stays unset and Support diagnostics reports nothing connected
    /// rather than opening a competing connection.
    public func libraryDidOpen(rootURL: URL, metadataStore: MetadataStore?) {
        let standardized = rootURL.standardizedFileURL
        currentLibraryRootURL = standardized
        currentMetadataStore = metadataStore
        let entry = RecentLibraryEntry(
            path: standardized.path,
            displayName: standardized.lastPathComponent,
            lastOpenedAt: Date()
        )
        var updated = recentLibraries.filter { $0.path != entry.path }
        updated.insert(entry, at: 0)
        if updated.count > Self.maximumRecentLibraries {
            updated = Array(updated.prefix(Self.maximumRecentLibraries))
        }
        recentLibraries = updated
        recentLibrariesStore.save(updated)
    }

    /// Requests that the open window switch its library to `rootURL` --
    /// consumed by `V2RootView`'s own observation, which clears it via
    /// `clearPendingLibrarySwitch()` once the switch has been dispatched.
    public func requestLibrarySwitch(to rootURL: URL) {
        pendingLibrarySwitchURL = rootURL.standardizedFileURL
    }

    public func clearPendingLibrarySwitch() {
        pendingLibrarySwitchURL = nil
    }

    /// Creates a router owned by its window view. The app model deliberately
    /// does not retain it, so transient SwiftUI disappearance cannot erase its
    /// state and closing a window cannot leak its navigation graph.
    public func makeRouter(restoring state: WindowRestorationState? = nil) -> AppRouter {
        if let state {
            return AppRouter(restoring: state, validator: restorationValidator)
        }
        return AppRouter()
    }

    public func router(
        for windowID: UUID,
        restoring state: WindowRestorationState? = nil
    ) -> AppRouter {
        if let router = windowRouters[windowID] {
            return router
        }

        let router: AppRouter
        if let state {
            router = AppRouter(restoring: state, validator: restorationValidator)
        } else {
            router = AppRouter()
        }
        windowRouters[windowID] = router
        return router
    }

    public func closeWindow(_ windowID: UUID) {
        windowRouters[windowID] = nil
    }
}

public enum WindowRestorationStateCodec {
    private static let maximumEncodedBytes = 64 * 1024

    public static func encode(_ state: WindowRestorationState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                state,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Window restoration state is not UTF-8"
                )
            )
        }
        return encoded
    }

    public static func decode(_ encoded: String) -> WindowRestorationState? {
        guard let data = encoded.data(using: .utf8),
              !data.isEmpty,
              data.count <= maximumEncodedBytes,
              let state = try? JSONDecoder().decode(WindowRestorationState.self, from: data),
              state.contentRoute.primarySection == state.primarySection
        else { return nil }

        if let selection = state.selection {
            guard selection.primarySection == state.primarySection,
                  selection.contentRoute == state.contentRoute
            else { return nil }
        } else {
            guard state.contentRoute.selection == nil else { return nil }
        }

        return state
    }
}
