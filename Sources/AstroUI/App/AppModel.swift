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

@MainActor
@Observable
public final class AppModel {
    private var windowRouters: [UUID: AppRouter]
    private let restorationValidator: RouteRestorationValidator

    public init(restorationValidator: RouteRestorationValidator) {
        windowRouters = [:]
        self.restorationValidator = restorationValidator
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
