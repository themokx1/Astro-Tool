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
    /// Wave 4 Task 1: navigation used to be a single scalar `contentRoute`
    /// that every route change replaced outright -- no back button, no
    /// per-section history, and forced inspector open/close on every
    /// navigation (see the navigation-rework plan's diagnosis). Each
    /// section now keeps its OWN push/pop stack here; switching sections
    /// preserves whatever stack that section already had, exactly like
    /// macOS `NavigationSplitView` + `NavigationStack` sidebar apps behave.
    /// `contentRoute` below is a computed read of "whichever section is
    /// active, its own current top-of-stack" so every existing call site
    /// that only ever read `contentRoute` keeps compiling and working.
    private var paths: [PrimarySection: [ContentRoute]] = [:]
    public private(set) var primarySection: PrimarySection
    public private(set) var inspectorSelection: LibrarySelection?
    public var isInspectorPresented: Bool
    public var presentation: PresentationRoute?
    /// A setup descriptor `InsightsView` should preset its own "Setup"
    /// filter to on next appearance -- set by `NightActionMenu`'s "Open in
    /// Insights" action right before navigating to `.insights`, and
    /// consumed (read once, then cleared) by `InsightsView` itself so it
    /// doesn't linger and re-apply on some LATER, unrelated visit to
    /// Insights. `nil` leaves Insights' own filter untouched (its default
    /// "All setups").
    public var pendingInsightsSetupFilter: String?

    /// Task 10 prerequisite: the Archive page's task cards know exactly
    /// which `CleanupPreviewGroup.category` values their own action covers
    /// (e.g. `["duplicate-content"]`) -- this is the hand-off that lets
    /// pushing `.cleanup` land on Cleanup Preview with those categories
    /// already checked, instead of the bare unfiltered open the page used to
    /// be limited to. Follows `pendingInsightsSetupFilter` exactly: a
    /// one-shot stash set right before navigating, read once and cleared by
    /// the consumer (`V2RootView`'s `.cleanup` destination) in its own
    /// `.onAppear`, so it never lingers and re-applies to some LATER,
    /// unrelated visit to Cleanup Preview. `nil` leaves
    /// `CleanupPreviewStore.selectedCategories` untouched (its own default,
    /// empty selection).
    public var pendingCleanupCategories: Set<String>?

    /// Wave 4 Task 3: the project/night workspace's own last-selected
    /// segmented tab, owned here (a plain router property) rather than as
    /// `@State` inside `ProjectWorkspaceView`/`NightWorkspaceView` -- those
    /// views are re-identified with `.id(route)` on every push (see
    /// `DetailHost`'s own doc comment), which resets `@State` per route, so
    /// a `@State` tab selection would silently reset to `.overview` every
    /// time the user drilled into a night/series and popped back. Router
    /// state survives that `.id()` reset because the router itself is not
    /// re-created; it is exactly the same reference `DetailHost` has always
    /// held. Not keyed per-project/per-night on purpose -- the plan calls
    /// for one persisted tab per session, not one per visited project.
    public var projectTab: ProjectWorkspaceTab
    public var nightTab: NightWorkspaceTab

    /// The active section's current top-of-stack, or that section's own
    /// stable root when nothing has been pushed onto it yet.
    public var contentRoute: ContentRoute {
        paths[primarySection]?.last ?? primarySection.rootRoute
    }

    /// The active section's full push stack -- what a `NavigationStack`
    /// hosted in the detail column binds its own `path:` to (see
    /// `V2RootView`'s `DetailHost`). Reading/writing this always operates
    /// on whichever section is currently active; SwiftUI's own pop
    /// gesture/native Back button writes a shorter array back through this
    /// exact accessor.
    public var currentSectionPath: [ContentRoute] {
        get { paths[primarySection] ?? [] }
        set { paths[primarySection] = newValue }
    }

    public init() {
        primarySection = .home
        inspectorSelection = nil
        isInspectorPresented = true
        presentation = nil
        pendingInsightsSetupFilter = nil
        pendingCleanupCategories = nil
        projectTab = .overview
        nightTab = .overview
    }

    public init(
        restoring state: WindowRestorationState,
        validator: RouteRestorationValidator
    ) {
        presentation = nil
        pendingInsightsSetupFilter = nil
        pendingCleanupCategories = nil
        paths = [:]

        let routeIsConsistent = state.contentRoute.primarySection == state.primarySection
        let routeIsAvailable = state.contentRoute.selection == nil
            || validator.isAvailable(state.contentRoute)

        // `WindowRestorationState` carries only the single last-visited
        // route per window, not a full per-section stack, so restoration
        // rebuilds a one-entry stack for the restored section (or an empty
        // stack when the restored route WAS that section's own root) --
        // "at least the last route", the lightweight half of the plan's
        // restoration contract. A future `WindowRestorationState` revision
        // could widen this to the full stack; that is a storage-schema
        // change out of this task's scope. Resolved into locals first (not
        // `self.primarySection`/`self.paths` reads) since Swift's two-phase
        // init forbids using `self` before every stored property has been
        // assigned once.
        let resolvedSection: PrimarySection
        let resolvedPath: [ContentRoute]
        let resolvedSelection: LibrarySelection?
        let resolvedInspectorPresented: Bool

        if let selection = state.selection,
           routeIsConsistent,
           routeIsAvailable,
           validator.isAvailable(selection),
           selection.primarySection == state.primarySection,
           selection.contentRoute == state.contentRoute {
            resolvedSection = selection.primarySection
            resolvedPath = state.contentRoute == state.primarySection.rootRoute ? [] : [state.contentRoute]
            resolvedSelection = selection
            resolvedInspectorPresented = state.isInspectorPresented
        } else if state.selection == nil, routeIsConsistent, routeIsAvailable {
            resolvedSection = state.primarySection
            resolvedPath = state.contentRoute == state.primarySection.rootRoute ? [] : [state.contentRoute]
            resolvedSelection = nil
            resolvedInspectorPresented = state.isInspectorPresented
        } else {
            resolvedSection = state.primarySection
            resolvedPath = []
            resolvedSelection = nil
            resolvedInspectorPresented = false
        }

        primarySection = resolvedSection
        inspectorSelection = resolvedSelection
        isInspectorPresented = resolvedInspectorPresented
        projectTab = state.projectTab ?? .overview
        nightTab = state.nightTab ?? .overview
        if !resolvedPath.isEmpty {
            paths[resolvedSection] = resolvedPath
        }
    }

    public var restorationState: WindowRestorationState {
        WindowRestorationState(
            primarySection: primarySection,
            contentRoute: contentRoute,
            selection: inspectorSelection,
            isInspectorPresented: isInspectorPresented,
            projectTab: projectTab,
            nightTab: nightTab
        )
    }

    /// Pushes `route` onto the CURRENTLY ACTIVE section's own stack --
    /// deliberately does NOT switch `primarySection`, even when `route`'s own
    /// nominal `primarySection` differs (e.g. a night's "Open Calibration"
    /// action pushes `.calibration`, whose own section is `.library`, while
    /// the user stays on the Nights journey). A mid-journey drill-down is
    /// owned by the journey the user is ON, not by the route's own nominal
    /// section -- switching sections here used to hijack the window over to
    /// a foreign section and land the native Back chevron on THAT section's
    /// own unrelated, possibly-stale stack (the navigation-rework code
    /// review's critical finding). `navigate(to:)` remains the only section
    /// switcher for a plain sidebar click; `navigate(toContent:)` below is
    /// the switching counterpart for deep links/global-search jumps, which
    /// (unlike this journey-preserving `push`) ARE meant to jump sections.
    /// Does NOT touch `isInspectorPresented` either way (Wave 4 Task 1:
    /// navigation is decoupled from inspector visibility -- see the plan's
    /// diagnosis of the old forced-open/forced-closed coupling);
    /// `inspectorSelection` is still kept in sync with the pushed route,
    /// same as before.
    public func push(_ route: ContentRoute) {
        var path = paths[primarySection] ?? []
        path.append(route)
        paths[primarySection] = path
        inspectorSelection = route.selection
    }

    /// Pops the active section's stack by one -- the programmatic
    /// equivalent of the native Back chevron/swipe-back gesture. A no-op at
    /// the section root.
    public func pop() {
        var path = paths[primarySection] ?? []
        guard !path.isEmpty else { return }
        path.removeLast()
        paths[primarySection] = path
    }

    /// Clears the active section's entire stack back to its root.
    public func popToRoot() {
        paths[primarySection] = []
    }

    /// v5 library-switch fixes (item 2): drops EVERY section's stack, not
    /// just the active one. Nothing reset navigation on a library switch,
    /// so a `.review(projectID:)`/`.resultsWorkspace(projectID:)`/
    /// `.archiveTaskDetail` route pushed under library A stayed on its
    /// section's stack under library B -- invisible until the user clicked
    /// that section in the sidebar and landed straight back on a project
    /// the open library does not even contain. `popToRoot()` alone is not
    /// enough for that: it only clears the section the user happens to be
    /// looking at.
    ///
    /// Deliberately NOT touched: `primarySection` (the section the user is
    /// on is not what a switch invalidates -- only its contents),
    /// `isInspectorPresented` (Wave 4 Task 1 decoupled navigation from
    /// inspector visibility, and a switch is navigation), and `presentation`
    /// (a modal is dismissed by whoever presented it; the library picker
    /// itself is one of them).
    public func resetForLibraryChange() {
        paths = [:]
        inspectorSelection = nil
        projectTab = .overview
        nightTab = .overview
        pendingInsightsSetupFilter = nil
        pendingCleanupCategories = nil
    }

    /// Switches to `section`. Re-selecting the ALREADY-active section (a
    /// sidebar re-click) pops that section back to its root -- the standard
    /// macOS sidebar pattern; switching to a genuinely different section
    /// leaves it exactly where its own stack last was.
    public func navigate(to section: PrimarySection) {
        if section == primarySection {
            popToRoot()
        } else {
            primarySection = section
        }
        inspectorSelection = nil
    }

    /// Switches to `route`'s own section and lands EXACTLY on `route` -- the
    /// deep-link/global-search-jump counterpart to journey-preserving
    /// `push(_:)` above. Always resets the destination section's stack to
    /// root first (even when that section is already active): an external
    /// jump has no relationship to whatever that section's stack last held,
    /// so leaving stale entries underneath the jumped-to route would make
    /// the native Back chevron pop into an unrelated stack (the same failure
    /// mode `push(_:)`'s own fix addresses, just from the opposite
    /// direction). This is what keeps Back "sane" after a deep link: one pop
    /// always lands on that section's own root.
    ///
    /// V2 UI/UX audit 3.1 -- this used to push UNCONDITIONALLY, even when
    /// `route` IS the destination section's own root route (every plain
    /// `astrotool://home|projects|nights|planning|library|insights` deep
    /// link, and `NightActionMenu`'s "Open in Insights"). That produced a
    /// one-entry stack sitting on top of the very route the section already
    /// starts on: a "Insights › Insights" breadcrumb, a Back chevron to a
    /// visually identical page, and the section's own `.task` load running
    /// twice. Landing on a root route now just resets the stack and switches
    /// sections -- exactly what `push(route)` would have produced anyway
    /// (`contentRoute` already falls back to `section.rootRoute` on an empty
    /// stack), just without the redundant entry.
    public func navigate(toContent route: ContentRoute) {
        let section = route.primarySection
        paths[section] = []
        primarySection = section
        guard route != section.rootRoute else {
            inspectorSelection = nil
            return
        }
        push(route)
    }

    /// `NightActionMenu`'s "Open in Insights" action: stashes `setupFilter`
    /// for `InsightsView` to pick up on this navigation, then navigates
    /// there -- see `pendingInsightsSetupFilter`'s own doc comment for why
    /// this is a one-shot handoff rather than persistent state.
    public func navigateToInsights(presetSetupFilter setupFilter: String?) {
        pendingInsightsSetupFilter = setupFilter
        navigate(toContent: .insights)
    }

    public func open(_ route: AppRoute) {
        switch route {
        case .content(let route): navigate(toContent: route)
        case .selection(let selection): select(selection)
        case .presentation(let route): present(route)
        }
    }

    public func select(_ selection: LibrarySelection) {
        // Deep-link selection (the `frames`/`series`/`results` URL schemes,
        // via `open(_:)` below) is an external jump exactly like
        // `navigate(toContent:)`, so it gets the same switch-and-reset
        // semantics rather than `push(_:)`'s journey-preserving one.
        navigate(toContent: selection.contentRoute)
        isInspectorPresented = true
    }

    public func clearSelection() {
        inspectorSelection = nil
        popToRoot()
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
