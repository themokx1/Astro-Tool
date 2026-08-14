import AstroApplication
import SwiftUI

private struct AppRouterFocusedValueKey: FocusedValueKey {
    typealias Value = AppRouter
}

/// The menu bar's window onto the global rescan action (⌘R) -- `Commands`
/// runs outside the view hierarchy, so it cannot hold `OnboardingStore` or
/// `OperationHost` directly; the active window's `V2Shell` publishes this
/// instead, the same way it publishes `appRouter`.
public struct LibraryRescanCommand {
    public let isAvailable: Bool
    private let action: () -> Void

    public init(isAvailable: Bool, action: @escaping () -> Void) {
        self.isAvailable = isAvailable
        self.action = action
    }

    public func callAsFunction() {
        action()
    }
}

private struct LibraryRescanFocusedValueKey: FocusedValueKey {
    typealias Value = LibraryRescanCommand
}

/// The menu bar's window onto "Run Audit" (⌥⌘A) -- same shape as
/// `LibraryRescanCommand`, just parameterized by `AuditRunMode` so the same
/// command backs both the primary (full) menu item and the "fast" one.
public struct LibraryAuditCommand {
    public let isAvailable: Bool
    private let action: (AuditRunMode) -> Void

    public init(isAvailable: Bool, action: @escaping (AuditRunMode) -> Void) {
        self.isAvailable = isAvailable
        self.action = action
    }

    public func callAsFunction(_ mode: AuditRunMode) {
        action(mode)
    }
}

private struct LibraryAuditFocusedValueKey: FocusedValueKey {
    typealias Value = LibraryAuditCommand
}

public extension FocusedValues {
    var appRouter: AppRouter? {
        get { self[AppRouterFocusedValueKey.self] }
        set { self[AppRouterFocusedValueKey.self] = newValue }
    }

    var libraryRescan: LibraryRescanCommand? {
        get { self[LibraryRescanFocusedValueKey.self] }
        set { self[LibraryRescanFocusedValueKey.self] = newValue }
    }

    var libraryAudit: LibraryAuditCommand? {
        get { self[LibraryAuditFocusedValueKey.self] }
        set { self[LibraryAuditFocusedValueKey.self] = newValue }
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
