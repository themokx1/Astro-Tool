import AstroUI
import Observation
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// `withObservationTracking`'s `onChange` closure is `@Sendable` -- this
/// tiny reference-type counter is what these tests mutate from inside it
/// instead of a plain captured `var` (which the compiler correctly refuses,
/// since nothing here guarantees the closure runs on the calling thread).
/// Every test that uses it stays on the main actor end to end, so the
/// `@unchecked` is safe in practice; it exists only to satisfy the
/// closure's own `Sendable` requirement.
private final class NotificationCounter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Wave 4 Task 2 / Wave 4 (post-20014 invalidation-storm) fix: type-level
/// coverage for `WorkspaceActionItem`/`WorkspaceActions` and the
/// `WorkspaceActionCenter` that now owns publishing them -- the shell's
/// stable toolbar renders whatever the current route's workspace last
/// PUBLISHED here instead of that workspace drawing its own in-body action
/// row or (as of dev build 20014, since fixed) republishing a fresh value
/// through `.focusedSceneValue` on every single `body` evaluation. No
/// SwiftUI rendering involved (this repo has no ViewInspector-style
/// harness); everything here is plain struct/closure/`@Observable` behavior,
/// exercised directly.
@Suite("Workspace toolbar actions")
struct WorkspaceActionsTests {
    @Test("A button action carries its identity/help/icon and can be performed")
    func buttonActionCarriesIdentityAndPerforms() {
        var performCount = 0
        let action = WorkspaceAction(
            id: "v2.test.action",
            title: "Do Thing",
            systemImage: "bolt",
            help: "Does the thing",
            action: { performCount += 1 }
        )

        #expect(action.id == "v2.test.action")
        #expect(action.title == "Do Thing")
        #expect(action.systemImage == "bolt")
        #expect(action.help == "Does the thing")
        #expect(!action.isDisabled)

        action()
        action()
        #expect(performCount == 2)
    }

    @Test("A button action defaults to enabled with no tooltip")
    func buttonActionDefaults() {
        let action = WorkspaceAction(id: "v2.test.default", title: "Go", systemImage: "arrow.right") {}
        #expect(!action.isDisabled)
        #expect(action.help == nil)
    }

    @Test("isDisabled is carried through untouched, exactly as the workspace computed it")
    func disabledStateIsRespected() {
        let enabled = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle", isDisabled: false) {}
        let disabled = WorkspaceAction(id: "b", title: "B", systemImage: "b.circle", isDisabled: true) {}

        #expect(!enabled.isDisabled)
        #expect(disabled.isDisabled)
    }

    @Test("Two button actions with identical id/title/icon/help/isDisabled compare equal even with different closures")
    func buttonActionsWithEqualDescriptorsAreEqual() {
        var firstCallCount = 0
        var secondCallCount = 0
        let first = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle") { firstCallCount += 1 }
        let second = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle") { secondCallCount += 1 }

        #expect(first == second)

        // The closures themselves are genuinely distinct -- `==` deliberately
        // never looks at them, which is exactly what lets a freshly
        // reconstructed (but content-identical) action compare equal to the
        // one already published.
        first()
        #expect(firstCallCount == 1)
        #expect(secondCallCount == 0)
    }

    @Test("A button action with a different title does not compare equal")
    func buttonActionsWithDifferentTitlesAreNotEqual() {
        let first = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle") {}
        let second = WorkspaceAction(id: "a", title: "B", systemImage: "a.circle") {}
        #expect(first != second)
    }

    @Test("WorkspaceActionItem.id reads through to the wrapped button's own id")
    func buttonItemIDReadsThroughTheAction() {
        let action = WorkspaceAction(id: "v2.test.wrapped", title: "Wrapped", systemImage: "square") {}
        let item = WorkspaceActionItem.button(action)
        #expect(item.id == "v2.test.wrapped")
    }

    @Test("A menu item carries its own id and reads through WorkspaceActionMenu")
    func menuItemIDReadsThroughTheMenu() {
        let menu = WorkspaceActionMenu(
            id: "v2.test.menu",
            title: "Menu",
            items: [WorkspaceMenuItem(id: "v2.test.menu.first", title: "First") {}]
        )
        let item = WorkspaceActionItem.menu(menu)
        #expect(item.id == "v2.test.menu")
    }

    @Test("Two menus with identical descriptors and sub-item ids/titles/isDisabled compare equal, ignoring their action closures")
    func menusWithEqualDescriptorsAreEqual() {
        let firstMenu = WorkspaceActionMenu(
            id: "v2.test.menu",
            title: "Menu",
            isDisabled: false,
            items: [WorkspaceMenuItem(id: "v2.test.menu.a", title: "A") {}],
            primaryAction: {}
        )
        let secondMenu = WorkspaceActionMenu(
            id: "v2.test.menu",
            title: "Menu",
            isDisabled: false,
            items: [WorkspaceMenuItem(id: "v2.test.menu.a", title: "A") {}],
            primaryAction: {}
        )
        #expect(firstMenu == secondMenu)
    }

    @Test("A menu whose isDisabled changed does not compare equal")
    func menusWithDifferentDisabledStateAreNotEqual() {
        let items = [WorkspaceMenuItem(id: "a", title: "A") {}]
        let enabled = WorkspaceActionMenu(id: "m", title: "M", isDisabled: false, items: items)
        let disabled = WorkspaceActionMenu(id: "m", title: "M", isDisabled: true, items: items)
        #expect(enabled != disabled)
    }

    @Test("An export-menu item carries its own id, independent of its ExportMenuItem list")
    func exportMenuItemCarriesItsOwnID() {
        let export = WorkspaceActionExportMenu(id: "v2.test.export", items: [], accessibilityID: "v2.test.export")
        let item = WorkspaceActionItem.exportMenu(export)
        #expect(item.id == "v2.test.export")
    }

    @Test("ExportMenuItem compares by its own stable id, ignoring its render closure")
    func exportMenuItemsCompareByID() {
        let first = ExportMenuItem.file(title: "Report", systemImage: "doc", contentType: .plainText) {
            ("first", "first.txt", [])
        }
        let second = ExportMenuItem.file(title: "Report", systemImage: "doc", contentType: .plainText) {
            ("second", "second.txt", [])
        }
        #expect(first == second)
    }

    @Test("A night-actions-menu item carries its own id and compares by its non-closure fields")
    func nightActionsMenuComparesByContent() {
        let nightID = UUID()
        let first = WorkspaceActionNightMenu(
            id: "v2.night.workspace.actions", target: "M31", date: "2026-08-14",
            setupDescriptor: "Setup", nightID: nightID, rootURL: nil,
            editNotes: {}, openCalibration: {}, openInsights: { _ in }
        )
        let second = WorkspaceActionNightMenu(
            id: "v2.night.workspace.actions", target: "M31", date: "2026-08-14",
            setupDescriptor: "Setup", nightID: nightID, rootURL: nil,
            editNotes: {}, openCalibration: {}, openInsights: { _ in }
        )
        #expect(first == second)
        #expect(WorkspaceActionItem.nightActionsMenu(first).id == "v2.night.workspace.actions")
    }

    @Test("WorkspaceActions publishes its items in the order given, preserving every id")
    func actionsArePublishableInOrder() {
        let first = WorkspaceAction(id: "v2.test.first", title: "First", systemImage: "1.circle") {}
        let second = WorkspaceAction(id: "v2.test.second", title: "Second", systemImage: "2.circle", isDisabled: true) {}
        let actions = WorkspaceActions([.button(first), .button(second)])

        #expect(actions.items.map(\.id) == ["v2.test.first", "v2.test.second"])
    }

    @Test("An empty WorkspaceActions publishes no items -- the shell renders nothing for it")
    func emptyActionsPublishesNothing() {
        let actions = WorkspaceActions([])
        #expect(actions.items.isEmpty)
    }

    // MARK: WorkspaceActionCenter -- the post-20014 invalidation-storm fix

    @Test("WorkspaceActionCenter starts empty")
    @MainActor
    func centerStartsEmpty() {
        let center = WorkspaceActionCenter()
        #expect(center.actions.items.isEmpty)
    }

    @Test("Publishing genuinely new content updates the center's actions")
    @MainActor
    func publishUpdatesActions() {
        let center = WorkspaceActionCenter()
        let action = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle") {}
        center.publish(owner: "owner-1", WorkspaceActions([.button(action)]))
        #expect(center.actions.items.map(\.id) == ["a"])
    }

    @Test("A redundant publish from the SAME owner with an equal descriptor does not notify observers")
    @MainActor
    func redundantPublishFromSameOwnerDoesNotNotify() {
        let center = WorkspaceActionCenter()
        let firstAction = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle") {}
        let secondAction = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle") {}
        center.publish(owner: "owner-1", WorkspaceActions([.button(firstAction)]))

        let counter = NotificationCounter()
        withObservationTracking {
            _ = center.actions
        } onChange: {
            counter.increment()
        }

        // Same owner, content that compares EQUAL (different closure, same
        // descriptor) -- must be a complete no-op: no mutation, so no
        // observation notification. This is the guard that keeps a genuine
        // `.onChange` firing for an unrelated reason from re-poking every
        // observer of `actions` (see `WorkspaceActionCenter`'s own doc
        // comment for why an unconditional `self.actions = newActions`
        // would still notify even from equal-looking content).
        center.publish(owner: "owner-1", WorkspaceActions([.button(secondAction)]))
        #expect(counter.value == 0)
        #expect(center.actions.items.map(\.id) == ["a"])
    }

    @Test("Publishing genuinely different content from the same owner DOES notify observers")
    @MainActor
    func publishWithChangedContentNotifies() {
        let center = WorkspaceActionCenter()
        let firstAction = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle") {}
        let secondAction = WorkspaceAction(id: "b", title: "B", systemImage: "b.circle") {}
        center.publish(owner: "owner-1", WorkspaceActions([.button(firstAction)]))

        let counter = NotificationCounter()
        withObservationTracking {
            _ = center.actions
        } onChange: {
            counter.increment()
        }

        center.publish(owner: "owner-1", WorkspaceActions([.button(secondAction)]))
        #expect(counter.value == 1)
        #expect(center.actions.items.map(\.id) == ["b"])
    }

    @Test("clear(owner:) is a no-op when a DIFFERENT owner has already taken over")
    @MainActor
    func clearIsANoOpForAStaleOwner() {
        let center = WorkspaceActionCenter()
        let firstAction = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle") {}
        let secondAction = WorkspaceAction(id: "b", title: "B", systemImage: "b.circle") {}

        // Simulates a route transition: the incoming workspace's `.onAppear`
        // publishes under a NEW owner before the outgoing workspace's
        // `.onDisappear` gets a chance to clear its own (now-stale) owner.
        center.publish(owner: "owner-1", WorkspaceActions([.button(firstAction)]))
        center.publish(owner: "owner-2", WorkspaceActions([.button(secondAction)]))
        center.clear(owner: "owner-1")

        #expect(center.actions.items.map(\.id) == ["b"], "The stale owner's clear must not wipe the current owner's actions")
    }

    @Test("clear(owner:) empties the actions when it IS still the current owner")
    @MainActor
    func clearEmptiesActionsForTheCurrentOwner() {
        let center = WorkspaceActionCenter()
        let action = WorkspaceAction(id: "a", title: "A", systemImage: "a.circle") {}
        center.publish(owner: "owner-1", WorkspaceActions([.button(action)]))
        center.clear(owner: "owner-1")
        #expect(center.actions.items.isEmpty)
    }
}
