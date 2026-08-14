import SwiftUI

/// One simple toolbar action a workspace publishes as part of its
/// `WorkspaceActions` -- a plain button with a title/icon/tooltip and a
/// synchronous handler, e.g. "Review Frames" or "Results". `isDisabled`
/// mirrors whatever the workspace's own body already computed for its
/// (now-removed) in-body button, so the shell toolbar's rendering of it
/// stays enabled/disabled exactly the same as before. `callAsFunction()`
/// (not a public `perform` closure) matches the same shape every other
/// focused-value command in this file's sibling `FocusedAppValues.swift`
/// already uses (`LibraryRescanCommand`, `LibraryAuditCommand`, ...).
public struct WorkspaceAction: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let help: String?
    public let isDisabled: Bool
    private let action: () -> Void

    public init(
        id: String,
        title: String,
        systemImage: String,
        help: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.isDisabled = isDisabled
        self.action = action
    }

    public func callAsFunction() {
        action()
    }
}

/// One item the shell's stable toolbar renders for the CURRENT route's
/// workspace -- either a plain `WorkspaceAction` button, or a fully
/// self-rendering `custom` control for the handful of actions that are
/// themselves a menu of further choices rather than one single handler (the
/// "Export" menu, the "Night Actions" menu, "Run Audit"'s split button, ...).
/// `custom` type-erases to `AnyView` deliberately: those controls already
/// exist as reusable views (`ExportMenu`, `NightActionMenu`) with their own
/// accessibility identifiers and `.help(` tooltips baked in, so wrapping
/// rather than re-describing them keeps this one gate to keep in sync.
public enum WorkspaceActionItem: Identifiable {
    case button(WorkspaceAction)
    /// Backing storage for the public `custom(id:view:)` factory below --
    /// named differently from it so the two don't collide (a case and a
    /// static function of the same name on the same enum are ambiguous to
    /// call from inside the type itself).
    case renderedView(id: String, view: () -> AnyView)

    public var id: String {
        switch self {
        case .button(let action): action.id
        case .renderedView(let id, _): id
        }
    }

    public static func custom<Content: View>(
        id: String,
        @ViewBuilder view: @escaping () -> Content
    ) -> WorkspaceActionItem {
        .renderedView(id: id, view: { AnyView(view()) })
    }
}

/// The current route's workspace's own primary actions, published as a
/// focused SCENE value (see `FocusedValues.workspaceActions` below) the same
/// way `reviewRate`/`sensorMeasure` already are -- so the shell's own fixed
/// toolbar (`V2RootView`) can render them instead of each workspace drawing
/// its own in-body action row. This is what keeps the shell stable while
/// only its content swaps (the navigation-rework plan's UX principles #1 and
/// #4): a workspace publishes ITS actions, the shell decides WHERE they
/// render, and drilling further down the stack (a pushed series, a pushed
/// review) still shows that deeper workspace's own actions in the same
/// fixed place.
public struct WorkspaceActions {
    public let items: [WorkspaceActionItem]

    public init(_ items: [WorkspaceActionItem]) {
        self.items = items
    }
}

private struct WorkspaceActionsFocusedValueKey: FocusedValueKey {
    typealias Value = WorkspaceActions
}

public extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsFocusedValueKey.self] }
        set { self[WorkspaceActionsFocusedValueKey.self] = newValue }
    }
}
