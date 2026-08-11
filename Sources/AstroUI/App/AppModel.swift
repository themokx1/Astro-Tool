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
            isInspectorPresented = false
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

@MainActor
@Observable
public final class AppModel {
    private var windowRouters: [UUID: AppRouter]
    private let restorationValidator: RouteRestorationValidator

    public init(restorationValidator: RouteRestorationValidator) {
        windowRouters = [:]
        self.restorationValidator = restorationValidator
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
