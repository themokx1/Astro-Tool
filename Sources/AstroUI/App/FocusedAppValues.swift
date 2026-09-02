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
    /// The series the action would rate -- the one thing about this command
    /// that can change while `isAvailable` stays `true`, so `==` (below)
    /// compares it. `nil` means "no particular series", which is what the
    /// menu item's disabled state already says.
    public let seriesID: UUID?
    private let action: () -> Void

    public init(isAvailable: Bool, seriesID: UUID? = nil, action: @escaping () -> Void) {
        self.isAvailable = isAvailable
        self.seriesID = seriesID
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

// MARK: - Equatable
//
// Every command above is constructed inline inside a `.focusedSceneValue`
// modifier, i.e. FRESHLY on every single `body` pass of the view that
// publishes it. Without `Equatable`, SwiftUI has no way to tell one pass's
// value from the next, so each pass counts as a change: it invalidates
// every view reading that focused value, which re-runs the body that
// publishes it. That is the exact invalidation storm this project already
// diagnosed once and fixed for the toolbar (see `WorkspaceActionCenter`'s
// own doc comment, and `WorkspaceAction`'s closure-excluding `==`).
//
// Equality deliberately never looks at the stored closures -- functions are
// not `Equatable`, and these ones capture only long-lived reference types
// (the stores, `OperationHost`) or `@State` setters, so an earlier pass's
// closure does exactly what a later pass's would. What is compared is the
// state the menu bar actually renders from: `isAvailable`, plus an explicit
// target identity wherever the action has one that can change
// independently (`ReviewRateCommand.seriesID`).

extension LibraryRescanCommand: Equatable {
    public static func == (lhs: LibraryRescanCommand, rhs: LibraryRescanCommand) -> Bool {
        lhs.isAvailable == rhs.isAvailable
    }
}

extension LibraryAuditCommand: Equatable {
    public static func == (lhs: LibraryAuditCommand, rhs: LibraryAuditCommand) -> Bool {
        lhs.isAvailable == rhs.isAvailable
    }
}

extension SensorMeasureCommand: Equatable {
    public static func == (lhs: SensorMeasureCommand, rhs: SensorMeasureCommand) -> Bool {
        lhs.isAvailable == rhs.isAvailable
    }
}

extension ReviewRateCommand: Equatable {
    public static func == (lhs: ReviewRateCommand, rhs: ReviewRateCommand) -> Bool {
        lhs.isAvailable == rhs.isAvailable && lhs.seriesID == rhs.seriesID
    }
}

extension GlobalSearchFocusCommand: Equatable {
    public static func == (lhs: GlobalSearchFocusCommand, rhs: GlobalSearchFocusCommand) -> Bool {
        lhs.isAvailable == rhs.isAvailable
    }
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
