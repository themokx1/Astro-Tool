import Foundation
import Observation

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
        selectionIsAvailable: (LibrarySelection) -> Bool = { _ in true }
    ) {
        presentation = nil

        if let selection = state.selection,
           selectionIsAvailable(selection),
           selection.primarySection == state.primarySection,
           selection.contentRoute == state.contentRoute {
            primarySection = selection.primarySection
            contentRoute = selection.contentRoute
            inspectorSelection = selection
            isInspectorPresented = state.isInspectorPresented
        } else {
            primarySection = state.primarySection
            contentRoute = state.contentRoute.primarySection == state.primarySection
                ? state.contentRoute
                : state.primarySection.rootRoute
            inspectorSelection = nil
            isInspectorPresented = false

            if state.selection != nil {
                contentRoute = state.primarySection.rootRoute
            }
        }
    }

    public var restorationState: WindowRestorationState {
        WindowRestorationState(
            primarySection: primarySection,
            contentRoute: contentRoute,
            selection: inspectorSelection,
            isInspectorPresented: inspectorSelection != nil && isInspectorPresented
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
        inspectorSelection = selection(for: route)
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

    private func selection(for route: ContentRoute) -> LibrarySelection? {
        switch route {
        case .project(let id): .project(id)
        case .projectSeries(let id): .series(id)
        case .night(let id): .night(id)
        case .review(let id): .result(id)
        default: nil
        }
    }
}

@MainActor
@Observable
public final class AppModel {
    private var windowRouters: [UUID: AppRouter]

    public init() {
        windowRouters = [:]
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
            router = AppRouter(restoring: state)
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
