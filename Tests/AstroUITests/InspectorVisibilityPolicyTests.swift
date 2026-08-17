import Foundation
import Testing

@testable import AstroUI

/// W4-4 item 1 (owner review): "the inspector shows 'Nincs kijelölés' on
/// pages with nothing to select" -- Home, Planning, Insights, the Archive
/// map at minimum. `ContentRoute.hasInspectorContent` and
/// `InspectorVisibilityPolicy` are the pure decision behind `V2Shell`'s
/// `.inspector()` mount (`Sources/AstroUI/App/V2RootView.swift`); these
/// tests exercise both directly rather than through a rendered window.
@Suite("Inspector column visibility policy (W4-4 item 1)")
struct InspectorVisibilityPolicyTests {
    @Test("Routes with no selection concept report no inspector content", arguments: [
        ContentRoute.home,
        .projects,
        .nights,
        .planning,
        .savedTargets,
        .library,
        .health,
        .calibration,
        .insights,
        .review(projectID: UUID()),
        .resultsWorkspace(projectID: UUID()),
        .conversion,
        .cleanup,
        .sensorProfiles,
        .archiveTaskDetail("duplicate-content"),
    ])
    func noSelectionRoutesHaveNoInspectorContent(route: ContentRoute) {
        #expect(route.hasInspectorContent == false)
    }

    @Test("Routes with a real selection report inspector content", arguments: [
        ContentRoute.project("11111111-1111-1111-1111-111111111111"),
        .projectSeries("22222222-2222-2222-2222-222222222222"),
        .night("33333333-3333-3333-3333-333333333333"),
        .reviewFrame(7),
        .result("44444444-4444-4444-4444-444444444444"),
    ])
    func selectionRoutesHaveInspectorContent(route: ContentRoute) {
        #expect(route.hasInspectorContent)
    }

    @Test("On a content route, the persisted cross-route toggle alone decides visibility", arguments: [
        (isInspectorPresented: true, overrideVisible: false, expected: true),
        (isInspectorPresented: false, overrideVisible: true, expected: false),
        (isInspectorPresented: true, overrideVisible: true, expected: true),
        (isInspectorPresented: false, overrideVisible: false, expected: false),
    ])
    func contentRouteIgnoresOverride(isInspectorPresented: Bool, overrideVisible: Bool, expected: Bool) {
        let route = ContentRoute.project("11111111-1111-1111-1111-111111111111")
        #expect(
            InspectorVisibilityPolicy.isPresented(
                route: route, isInspectorPresented: isInspectorPresented, overrideVisible: overrideVisible
            ) == expected
        )
    }

    @Test("On a no-content route, only the per-route override decides visibility -- the persisted flag is ignored either way", arguments: [
        (isInspectorPresented: true, overrideVisible: false, expected: false),
        (isInspectorPresented: false, overrideVisible: true, expected: true),
        (isInspectorPresented: true, overrideVisible: true, expected: true),
        (isInspectorPresented: false, overrideVisible: false, expected: false),
    ])
    func noContentRouteFollowsOverrideOnly(isInspectorPresented: Bool, overrideVisible: Bool, expected: Bool) {
        #expect(
            InspectorVisibilityPolicy.isPresented(
                route: .home, isInspectorPresented: isInspectorPresented, overrideVisible: overrideVisible
            ) == expected
        )
    }

    /// The owner's own words: "the change is the default, not a lockout" --
    /// a no-content route must still be forceable open by the toggle
    /// (`overrideVisible: true` above already proves the read side; this
    /// pins that the persisted flag being `false` -- the default state for
    /// most sessions -- never by itself locks the override path out).
    @Test("A no-content route with the persisted flag OFF can still be forced open")
    func noContentRouteIsNeverLockedOut() {
        #expect(
            InspectorVisibilityPolicy.isPresented(route: .insights, isInspectorPresented: false, overrideVisible: true)
        )
    }
}
