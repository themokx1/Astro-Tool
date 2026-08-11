import AstroUI
import Foundation
import Testing

@MainActor
@Suite("Window-scoped app routing")
struct AppRouterTests {
    @Test("Every primary section has one stable root route", arguments: [
        (PrimarySection.home, ContentRoute.home),
        (.projects, .projects),
        (.nights, .nights),
        (.planning, .planning),
        (.library, .library),
        (.insights, .insights),
    ])
    func primarySectionMapsToRootRoute(section: PrimarySection, route: ContentRoute) {
        let router = AppRouter()

        router.navigate(to: section)

        #expect(router.primarySection == section)
        #expect(router.contentRoute == route)
    }

    @Test("Selection drives detail and inspector in its window")
    func selectionDrivesDetailAndInspectorPerWindow() {
        let router = AppRouter()
        router.navigate(to: .projects)

        router.select(.series("series-1"))

        #expect(router.contentRoute == .projectSeries("series-1"))
        #expect(router.inspectorSelection == .series("series-1"))
        #expect(router.isInspectorPresented)
    }

    @Test("Routers keep window navigation independent")
    func independentWindowRouters() {
        let firstWindow = AppRouter()
        let secondWindow = AppRouter()

        firstWindow.select(.project("m31"))
        secondWindow.select(.night("2026-08-10"))

        #expect(firstWindow.primarySection == .projects)
        #expect(firstWindow.contentRoute == .project("m31"))
        #expect(secondWindow.primarySection == .nights)
        #expect(secondWindow.contentRoute == .night("2026-08-10"))
        #expect(firstWindow.inspectorSelection != secondWindow.inspectorSelection)
    }

    @Test("App model returns one router per window identity")
    func appModelScopesRoutersByWindow() {
        let model = AppModel()
        let firstWindowID = UUID()
        let secondWindowID = UUID()

        let firstWindow = model.router(for: firstWindowID)
        let sameWindow = model.router(for: firstWindowID)
        let secondWindow = model.router(for: secondWindowID)

        #expect(firstWindow === sameWindow)
        #expect(firstWindow !== secondWindow)
    }

    @Test("Restoration keeps stable routes and never restores a presentation")
    func restoredStateNeverRestoresConfirmation() {
        let state = WindowRestorationState(
            primarySection: .library,
            contentRoute: .health,
            selection: nil,
            isInspectorPresented: true
        )

        let router = AppRouter(restoring: state)

        #expect(router.primarySection == .library)
        #expect(router.contentRoute == .health)
        #expect(router.presentation == nil)
        #expect(!router.isInspectorPresented)
    }

    @Test("Deleted restored selections fall back to the section root")
    func deletedRestoredSelectionFallsBackSafely() {
        let state = WindowRestorationState(
            primarySection: .projects,
            contentRoute: .project("deleted"),
            selection: .project("deleted")
        )

        let router = AppRouter(restoring: state) { _ in false }

        #expect(router.primarySection == .projects)
        #expect(router.contentRoute == .projects)
        #expect(router.inspectorSelection == nil)
        #expect(!router.isInspectorPresented)
    }

    @Test("Clearing selection returns to the current section root")
    func selectionClearing() {
        let router = AppRouter()
        router.select(.result("stack-1"))

        router.clearSelection()

        #expect(router.primarySection == .projects)
        #expect(router.contentRoute == .projects)
        #expect(router.inspectorSelection == nil)
        #expect(!router.isInspectorPresented)
    }

    @Test("Inspector toggle changes only presentation visibility")
    func inspectorToggle() {
        let router = AppRouter()
        router.select(.frame(42))
        let route = router.contentRoute

        router.toggleInspector()

        #expect(!router.isInspectorPresented)
        #expect(router.inspectorSelection == .frame(42))
        #expect(router.contentRoute == route)
    }

    @Test("Typed deep links reject foreign and malformed URLs")
    func typedDeepLinkParsing() throws {
        let projectURL = try #require(URL(string: "astrotool://projects/m31"))
        let malformedURL = try #require(URL(string: "astrotool://frames/not-a-number"))
        let foreignURL = try #require(URL(string: "https://example.com/projects/m31"))

        #expect(AppRoute(deepLink: projectURL) == .content(.project("m31")))
        #expect(AppRoute(deepLink: malformedURL) == nil)
        #expect(AppRoute(deepLink: foreignURL) == nil)
    }

    @Test("Focused commands act on the active window only")
    func focusedCommandsResolveActiveWindow() {
        let firstWindow = AppRouter()
        let activeWindow = AppRouter()
        let commands = FocusedAppCommands(router: activeWindow)

        commands.toggleInspector()
        commands.navigate(to: .insights)

        #expect(firstWindow.primarySection == .home)
        #expect(firstWindow.isInspectorPresented)
        #expect(activeWindow.primarySection == .insights)
        #expect(!activeWindow.isInspectorPresented)
    }
}
