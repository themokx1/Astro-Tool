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

/// Wave 3 Task 7: the Actions menu's "Measure Sensors" -- same shape as
/// `LibraryRescanCommand`/`LibraryAuditCommand`, published by
/// `SensorProfilesView` (via `Commands.swift`'s `V2AstroToolCommands`)
/// whenever that sheet is on screen so the menu item can run
/// `SensorProfilesStore.measure(operationHost:)` directly -- the same
/// "skip the confirm sheet, run it straight through `OperationHost`"
/// shortcut `libraryRescan`/`libraryAudit` already give the menu bar.
public struct SensorMeasureCommand {
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

private struct SensorMeasureFocusedValueKey: FocusedValueKey {
    typealias Value = SensorMeasureCommand
}

/// Wave 3 Task 7: the Actions menu's "Rate Frames in Review" -- published by
/// `ReviewWorkspace` only while it is on screen, `isAvailable` mirroring the
/// workspace's own "Rate Frames…" button (a capture series is selected, it
/// has frames, and no rating run is already in flight for it).
public struct ReviewRateCommand {
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

private struct ReviewRateFocusedValueKey: FocusedValueKey {
    typealias Value = ReviewRateCommand
}

/// Wave 3 Task 7: ⌘F -- opens/focuses the shell's own global search popover.
/// Published by `V2Shell` itself (always available once a window exists),
/// mirroring V1's "Kereső fókuszálása" (`Commands.swift`'s
/// `.focusSearchField` notification) but through a focused value rather than
/// `NotificationCenter`, matching every other V2 menu action.
public struct GlobalSearchFocusCommand {
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

private struct GlobalSearchFocusFocusedValueKey: FocusedValueKey {
    typealias Value = GlobalSearchFocusCommand
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

    var sensorMeasure: SensorMeasureCommand? {
        get { self[SensorMeasureFocusedValueKey.self] }
        set { self[SensorMeasureFocusedValueKey.self] = newValue }
    }

    var reviewRate: ReviewRateCommand? {
        get { self[ReviewRateFocusedValueKey.self] }
        set { self[ReviewRateFocusedValueKey.self] = newValue }
    }

    var globalSearchFocus: GlobalSearchFocusCommand? {
        get { self[GlobalSearchFocusFocusedValueKey.self] }
        set { self[GlobalSearchFocusFocusedValueKey.self] = newValue }
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
