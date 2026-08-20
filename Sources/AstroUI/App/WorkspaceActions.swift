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
///
/// `Equatable` by hand (excluding `action`): `WorkspaceActionCenter.publish`
/// compares the incoming `WorkspaceActions` against what it already holds so
/// a redundant publish -- same ids/titles/icons/help/enabled state, just a
/// freshly-allocated closure -- never mutates its `@Observable` storage and
/// therefore never notifies the shell toolbar. Closures are never
/// comparable in any useful sense, so they are deliberately left out of
/// `==` rather than made to always report "changed".
public struct WorkspaceAction: Identifiable {
    public let id: String
    public let title: LocalizedStringKey
    public let systemImage: String
    public let help: LocalizedStringKey?
    public let isDisabled: Bool
    private let action: () -> Void

    public init(
        id: String,
        title: LocalizedStringKey,
        systemImage: String,
        help: LocalizedStringKey? = nil,
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

extension WorkspaceAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.systemImage == rhs.systemImage
            && lhs.help == rhs.help
            && lhs.isDisabled == rhs.isDisabled
    }
}

/// One entry inside a `WorkspaceActionMenu`'s dropdown -- a plain titled
/// button, no icon required (none of today's two menu-shaped actions --
/// Health's "Run Audit"/Review's "Rate Frames…" -- give their sub-items
/// icons). Same hand-written `Equatable` reasoning as `WorkspaceAction`:
/// compares everything except `action`.
public struct WorkspaceMenuItem: Identifiable {
    public let id: String
    public let title: LocalizedStringKey
    public let systemImage: String?
    public let isDisabled: Bool
    private let action: () -> Void

    public init(
        id: String,
        title: LocalizedStringKey,
        systemImage: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isDisabled = isDisabled
        self.action = action
    }

    public func callAsFunction() {
        action()
    }
}

extension WorkspaceMenuItem: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.systemImage == rhs.systemImage
            && lhs.isDisabled == rhs.isDisabled
    }
}

/// A data-driven dropdown-menu action -- the split-button shape Health's
/// "Run Audit" (a full-audit primary action plus a "Fast" alternative) and
/// Review's "Rate Frames…" (native-only primary action plus a full
/// re-measure alternative) both need. The shell toolbar builds the actual
/// SwiftUI `Menu` from this data; nothing here is a view, so it is
/// comparable like every other `WorkspaceActionItem` payload.
public struct WorkspaceActionMenu: Identifiable {
    public let id: String
    public let title: LocalizedStringKey
    public let systemImage: String?
    public let help: LocalizedStringKey?
    public let isDisabled: Bool
    public let items: [WorkspaceMenuItem]
    private let primaryAction: (() -> Void)?

    public init(
        id: String,
        title: LocalizedStringKey,
        systemImage: String? = nil,
        help: LocalizedStringKey? = nil,
        isDisabled: Bool = false,
        items: [WorkspaceMenuItem],
        primaryAction: (() -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.isDisabled = isDisabled
        self.items = items
        self.primaryAction = primaryAction
    }

    public func performPrimaryAction() {
        primaryAction?()
    }

    var hasPrimaryAction: Bool { primaryAction != nil }
}

extension WorkspaceActionMenu: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.systemImage == rhs.systemImage
            && lhs.help == rhs.help
            && lhs.isDisabled == rhs.isDisabled
            && lhs.items == rhs.items
            && lhs.hasPrimaryAction == rhs.hasPrimaryAction
    }
}

/// The "Export" menu, data-driven for the shell toolbar -- wraps the exact
/// same `ExportMenuItem` list the reusable `ExportMenu` view already renders
/// (Project/Night/Results each build their own), so publishing this costs
/// nothing beyond what those views already computed. `ExportMenuItem`'s own
/// `Equatable` conformance (added alongside this type) compares by its
/// stable `id` only, ignoring the `make` closure -- exactly the
/// "ids/titles ... closures excluded" rule every payload here follows.
public struct WorkspaceActionExportMenu: Identifiable {
    public let id: String
    public let items: [ExportMenuItem]
    public let accessibilityID: String

    public init(id: String, items: [ExportMenuItem], accessibilityID: String) {
        self.id = id
        self.items = items
        self.accessibilityID = accessibilityID
    }
}

extension WorkspaceActionExportMenu: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.accessibilityID == rhs.accessibilityID && lhs.items == rhs.items
    }
}

/// The Night workspace's "Night Actions" menu, data-driven for the shell
/// toolbar -- wraps the exact same parameters `NightActionMenu` (the
/// reusable component also used by the Nights table's and the project
/// workspace's own context menus) already takes, so the toolbar can build
/// `Menu { NightActionMenu(...) }` itself while `NightActionMenu` keeps
/// owning every one of its actions' real logic (reveal in Finder, export
/// the night report, rate frames, ...) untouched. `editNotes`/
/// `openCalibration`/`openInsights` stay out of `==` for the same
/// "closures excluded" reason every other payload here follows; every OTHER
/// field already uniquely identifies which night this menu is for, so
/// comparing them is enough to detect a genuine content change.
public struct WorkspaceActionNightMenu: Identifiable {
    public let id: String
    public let target: String
    public let date: String
    public let setupDescriptor: String?
    public let nightID: UUID
    public let rootURL: URL?
    let editNotes: () -> Void
    let openCalibration: () -> Void
    let openInsights: (String?) -> Void

    public init(
        id: String,
        target: String,
        date: String,
        setupDescriptor: String?,
        nightID: UUID,
        rootURL: URL?,
        editNotes: @escaping () -> Void,
        openCalibration: @escaping () -> Void,
        openInsights: @escaping (String?) -> Void
    ) {
        self.id = id
        self.target = target
        self.date = date
        self.setupDescriptor = setupDescriptor
        self.nightID = nightID
        self.rootURL = rootURL
        self.editNotes = editNotes
        self.openCalibration = openCalibration
        self.openInsights = openInsights
    }
}

extension WorkspaceActionNightMenu: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.target == rhs.target
            && lhs.date == rhs.date
            && lhs.setupDescriptor == rhs.setupDescriptor
            && lhs.nightID == rhs.nightID
            && lhs.rootURL == rhs.rootURL
    }
}

/// One item the shell's stable toolbar renders for the CURRENT route's
/// workspace -- a plain `WorkspaceAction` button, a data-driven dropdown
/// (`WorkspaceActionMenu`), or one of the two reusable rich menu components
/// (`ExportMenu`/`NightActionMenu`) wrapped in their own dedicated,
/// non-type-erased case. There used to be a fifth, fully generic
/// `custom(id:view:)` case that type-erased ANY view to `AnyView` -- that
/// was convenient, but an `AnyView` is inherently incomparable (no `==`,
/// reference-different every time the enclosing workspace's body ran), which
/// is exactly what turned this focused value into an infinite invalidation
/// storm the moment it was published every body pass instead of only on
/// real changes (see `WorkspaceActionCenter`'s own doc comment for the full
/// incident). Every case here is instead plain, comparable data; the shell
/// toolbar is the only place that ever turns it into actual SwiftUI views.
public enum WorkspaceActionItem: Identifiable {
    case button(WorkspaceAction)
    case menu(WorkspaceActionMenu)
    case exportMenu(WorkspaceActionExportMenu)
    case nightActionsMenu(WorkspaceActionNightMenu)

    public var id: String {
        switch self {
        case .button(let action): action.id
        case .menu(let menu): menu.id
        case .exportMenu(let export): export.id
        case .nightActionsMenu(let night): night.id
        }
    }
}

extension WorkspaceActionItem: Equatable {}

/// The current route's workspace's own primary actions, published to the
/// shared `WorkspaceActionCenter` (see that type's own doc comment) the same
/// way `reviewRate`/`sensorMeasure` still are as `FocusedValues` -- so the
/// shell's own fixed toolbar (`V2RootView`) can render them instead of each
/// workspace drawing its own in-body action row. This is what keeps the
/// shell stable while only its content swaps (the navigation-rework plan's
/// UX principles #1 and #4): a workspace publishes ITS actions, the shell
/// decides WHERE they render, and drilling further down the stack (a pushed
/// series, a pushed review) still shows that deeper workspace's own actions
/// in the same fixed place.
public struct WorkspaceActions: Identifiable {
    public let items: [WorkspaceActionItem]

    public init(_ items: [WorkspaceActionItem]) {
        self.items = items
    }

    /// A stable identity for `ForEach`/diffing purposes -- not otherwise
    /// meaningful; every real comparison goes through `==` below.
    public var id: [String] { items.map(\.id) }
}

extension WorkspaceActions: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items
    }
}

/// Wave 4 (post-20014) fix: the shared, `@Observable` home for the current
/// route's workspace actions -- replaces the `FocusedValues.workspaceActions`
/// mechanism (a `.focusedSceneValue(\.workspaceActions, workspaceActions)`
/// applied every time a workspace's `body` ran) that shipped in dev build
/// 20014 and caused a 100% CPU invalidation storm (occasionally an AutoLayout
/// crash) the moment the app restored into a route hosting one of these
/// workspaces.
///
/// The mechanism: `.focusedSceneValue` has no equality check of its own --
/// SwiftUI propagates whatever value the modifier carries up to the scene on
/// every application of the modifier, full stop. Publishing a FRESH
/// `WorkspaceActions` (new closures, and -- before this fix -- a `.custom`
/// case wrapping a brand new `AnyView`) from inside `body` therefore
/// invalidated the shell toolbar's `@FocusedValue(\.workspaceActions)` reader
/// on literally every body evaluation. The toolbar re-rendering dirtied the
/// window's layout; `layoutIfNeeded` re-ran the workspace's `body` to
/// re-resolve its content; which re-applied `.focusedSceneValue` with another
/// fresh value; which invalidated the toolbar again -- forever, pinning the
/// main thread at 100% CPU inside one never-ending
/// `NSDisplayCycleFlush -> layoutIfNeeded -> NSHostingView.layout` recursion.
///
/// The fix has two parts, both required:
/// 1. Publication moves OFF `body` entirely, onto discrete lifecycle/state-
///    change events (`.onAppear`, targeted `.onChange(of:)`) -- so nothing
///    republishes just because SOMETHING caused this view's body to
///    re-evaluate; it only republishes when whatever the actions actually
///    DEPEND ON changed.
/// 2. `publish(owner:_:)` below additionally guards on equality: even a
///    genuine `.onChange` firing for an unrelated reason (something that
///    changed but left the actions themselves identical) must not mutate
///    `actions`, because `@Observable` notifies its observers on every
///    mutation regardless of old/new equality -- an unguarded `self.actions
///    = newActions` would still poke the toolbar's observation every time,
///    even from a value that reads as "the same" by eye.
///
/// `owner` handles the one remaining race the plan calls out: during a route
/// transition, the OUTGOING workspace's `.onDisappear` can fire after the
/// INCOMING workspace's `.onAppear` already published -- see `clear(owner:)`.
@MainActor
@Observable
public final class WorkspaceActionCenter {
    public private(set) var actions = WorkspaceActions([])
    private var ownerID: String?

    public init() {}

    /// Publishes `newActions` on `owner`'s behalf. A no-op -- no mutation,
    /// therefore no `@Observable` notification to the toolbar -- unless
    /// `owner` is taking over from a different owner OR the content itself
    /// actually differs from what is already published.
    public func publish(owner: String, _ newActions: WorkspaceActions) {
        guard ownerID != owner || actions != newActions else { return }
        ownerID = owner
        actions = newActions
    }

    /// Clears `owner`'s own contribution -- a no-op if some OTHER owner has
    /// already taken over (the outgoing-view-disappears-after-incoming-view-
    /// appears race described above). Only ever wipes the toolbar back to
    /// empty when the caller asking is still the one who last published.
    public func clear(owner: String) {
        guard ownerID == owner else { return }
        ownerID = nil
        actions = WorkspaceActions([])
    }
}
