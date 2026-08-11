import SwiftUI

private struct AppRouterFocusedValueKey: FocusedValueKey {
    typealias Value = AppRouter
}

public extension FocusedValues {
    var appRouter: AppRouter? {
        get { self[AppRouterFocusedValueKey.self] }
        set { self[AppRouterFocusedValueKey.self] = newValue }
    }
}

@MainActor
public struct FocusedAppCommands {
    private let router: AppRouter?

    public init(router: AppRouter?) {
        self.router = router
    }

    public func navigate(to section: PrimarySection) {
        router?.navigate(to: section)
    }

    public func toggleInspector() {
        router?.toggleInspector()
    }

    public func present(_ route: PresentationRoute) {
        router?.present(route)
    }
}
