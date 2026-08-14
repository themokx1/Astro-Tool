import AstroUI
import SwiftUI
import Testing

/// Wave 4 Task 2: type-level coverage for the `WorkspaceActions` focused
/// value -- the shell's stable toolbar renders whatever the current route's
/// workspace publishes here instead of that workspace drawing its own
/// in-body action row. No SwiftUI rendering involved (this repo has no
/// ViewInspector-style harness); everything here is plain struct/closure
/// behavior, exercised directly.
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

    @Test("WorkspaceActionItem.id reads through to the wrapped button's own id")
    func buttonItemIDReadsThroughTheAction() {
        let action = WorkspaceAction(id: "v2.test.wrapped", title: "Wrapped", systemImage: "square") {}
        let item = WorkspaceActionItem.button(action)
        #expect(item.id == "v2.test.wrapped")
    }

    @Test("A custom item carries its own explicit id, independent of any inner view")
    func customItemCarriesItsOwnID() {
        let item = WorkspaceActionItem.custom(id: "v2.test.custom") { EmptyView() }
        #expect(item.id == "v2.test.custom")
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
}
