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

    @Test("Selection and content routes round-trip without losing their type", arguments: [
        (LibrarySelection.project("project-1"), ContentRoute.project("project-1"), PrimarySection.projects),
        (.night("night-1"), .night("night-1"), .nights),
        (.series("series-1"), .projectSeries("series-1"), .projects),
        (.frame(42), .reviewFrame(42), .nights),
        (.result("result-1"), .result("result-1"), .projects),
    ])
    func selectionRouteRoundTrip(
        selection: LibrarySelection,
        route: ContentRoute,
        section: PrimarySection
    ) {
        let router = AppRouter()

        router.select(selection)
        #expect(router.contentRoute == route)
        #expect(router.primarySection == section)

        router.navigate(toContent: route)
        #expect(router.inspectorSelection == selection)
        #expect(router.primarySection == section)
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
        let model = AppModel(restorationValidator: .allowingAll)
        let firstWindowID = UUID()
        let secondWindowID = UUID()

        let firstWindow = model.router(for: firstWindowID)
        let sameWindow = model.router(for: firstWindowID)
        let secondWindow = model.router(for: secondWindowID)

        #expect(firstWindow === sameWindow)
        #expect(firstWindow !== secondWindow)
    }

    @Test("Full lightweight restoration state round-trips as validated storage")
    func restorationStateCodecRoundTripsHealthAndSelectionRoutes() throws {
        let health = WindowRestorationState(
            primarySection: .library,
            contentRoute: .health,
            selection: nil,
            isInspectorPresented: true
        )
        let selection = WindowRestorationState(
            primarySection: .projects,
            contentRoute: .projectSeries("m31-lrgb"),
            selection: .series("m31-lrgb"),
            isInspectorPresented: true
        )

        let encodedHealth = try WindowRestorationStateCodec.encode(health)
        let encodedSelection = try WindowRestorationStateCodec.encode(selection)

        #expect(WindowRestorationStateCodec.decode(encodedHealth) == health)
        #expect(WindowRestorationStateCodec.decode(encodedSelection) == selection)
        #expect(WindowRestorationStateCodec.decode("not-json") == nil)
    }

    @Test("Transient shell recreation restores route and selection without retaining presentation")
    func transientShellRecreationRestoresStateWithoutLeakingRouter() throws {
        let model = AppModel(restorationValidator: .allowingAll)
        var firstRouter: AppRouter? = model.makeRouter()
        firstRouter?.select(.series("m31-lrgb"))
        firstRouter?.present(.mutationConfirmation(UUID()))
        let encoded = try WindowRestorationStateCodec.encode(
            try #require(firstRouter).restorationState
        )
        weak let releasedRouter = firstRouter

        firstRouter = nil

        #expect(releasedRouter == nil)
        let state = try #require(WindowRestorationStateCodec.decode(encoded))
        let restoredRouter = model.makeRouter(restoring: state)
        #expect(restoredRouter.primarySection == .projects)
        #expect(restoredRouter.contentRoute == .projectSeries("m31-lrgb"))
        #expect(restoredRouter.inspectorSelection == .series("m31-lrgb"))
        #expect(restoredRouter.isInspectorPresented)
        #expect(restoredRouter.presentation == nil)
    }

    @Test("App model rejects deleted selections and stale ID routes during restoration")
    func appModelValidatesEveryRestoredIdentifier() {
        let validator = RouteRestorationValidator(
            selectionIsAvailable: { $0 != .frame(404) },
            contentRouteIsAvailable: {
                $0 != .reviewFrame(404) && $0 != .project("deleted")
            }
        )
        let model = AppModel(restorationValidator: validator)
        let staleSelectionState = WindowRestorationState(
            primarySection: .nights,
            contentRoute: .reviewFrame(404),
            selection: .frame(404),
            isInspectorPresented: true
        )
        let staleRouteState = WindowRestorationState(
            primarySection: .projects,
            contentRoute: .project("deleted"),
            selection: nil
        )

        let staleSelectionRouter = model.router(for: UUID(), restoring: staleSelectionState)
        let staleRouteRouter = model.router(for: UUID(), restoring: staleRouteState)

        #expect(staleSelectionRouter.contentRoute == .nights)
        #expect(staleSelectionRouter.inspectorSelection == nil)
        #expect(!staleSelectionRouter.isInspectorPresented)
        #expect(staleSelectionRouter.presentation == nil)
        #expect(staleRouteRouter.contentRoute == .projects)
        #expect(staleRouteRouter.inspectorSelection == nil)
        #expect(staleRouteRouter.presentation == nil)
    }

    @Test("Restoration keeps stable routes and never restores a presentation")
    func restoredStateNeverRestoresConfirmation() {
        let state = WindowRestorationState(
            primarySection: .library,
            contentRoute: .health,
            selection: nil,
            isInspectorPresented: true
        )

        let router = AppRouter(restoring: state, validator: .allowingAll)

        #expect(router.primarySection == .library)
        #expect(router.contentRoute == .health)
        #expect(router.presentation == nil)
        #expect(router.isInspectorPresented)
    }

    @Test("Deleted restored selections fall back to the section root")
    func deletedRestoredSelectionFallsBackSafely() {
        let state = WindowRestorationState(
            primarySection: .projects,
            contentRoute: .project("deleted"),
            selection: .project("deleted")
        )

        let router = AppRouter(
            restoring: state,
            validator: RouteRestorationValidator(
                selectionIsAvailable: { _ in false },
                contentRouteIsAvailable: { _ in false }
            )
        )

        #expect(router.primarySection == .projects)
        #expect(router.contentRoute == .projects)
        #expect(router.inspectorSelection == nil)
        #expect(!router.isInspectorPresented)
    }

    @Test("Clearing selection returns to the current section root without touching the inspector")
    func selectionClearing() {
        let router = AppRouter()
        router.select(.result("stack-1"))
        #expect(router.isInspectorPresented)

        router.clearSelection()

        #expect(router.primarySection == .projects)
        #expect(router.contentRoute == .projects)
        #expect(router.inspectorSelection == nil)
        // Wave 4 Task 1: navigation is decoupled from inspector visibility --
        // clearing a selection no longer forces the inspector closed, unlike
        // the old coupled behavior.
        #expect(router.isInspectorPresented)
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
        let invalidEncodingURL = try #require(URL(string: "astrotool://projects/%FF"))
        let emptyIDURL = try #require(URL(string: "astrotool://projects/%20"))
        let controlIDURL = try #require(URL(string: "astrotool://projects/m31%0A"))
        let encodedSlashURL = try #require(URL(string: "astrotool://projects/m31%2Fnight"))
        let extraComponentURL = try #require(URL(string: "astrotool://projects/m31/extra"))

        #expect(AppRoute(deepLink: projectURL) == .content(.project("m31")))
        #expect(AppRoute(deepLink: malformedURL) == nil)
        #expect(AppRoute(deepLink: foreignURL) == nil)
        #expect(AppRoute(deepLink: invalidEncodingURL) == nil)
        #expect(AppRoute(deepLink: emptyIDURL) == nil)
        #expect(AppRoute(deepLink: controlIDURL) == nil)
        #expect(AppRoute(deepLink: encodedSlashURL) == nil)
        #expect(AppRoute(deepLink: extraComponentURL) == nil)
    }

    // MARK: Wave 4 Task 1 -- router stack

    @Test("Push appends onto the active section's own stack; contentRoute reads its top")
    func pushAppendsOntoTheActiveSectionStack() {
        let router = AppRouter()
        router.navigate(to: .projects)

        router.push(.project("m31"))
        #expect(router.contentRoute == .project("m31"))
        #expect(router.currentSectionPath == [.project("m31")])

        router.push(.projectSeries("m31-lrgb"))
        #expect(router.contentRoute == .projectSeries("m31-lrgb"))
        #expect(router.currentSectionPath == [.project("m31"), .projectSeries("m31-lrgb")])
    }

    @Test("Pop removes the top of the active section's stack; a no-op at the root")
    func popRemovesTheTopOfTheStack() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))
        router.push(.projectSeries("m31-lrgb"))

        router.pop()
        #expect(router.contentRoute == .project("m31"))

        router.pop()
        #expect(router.contentRoute == .projects)

        router.pop()
        #expect(router.contentRoute == .projects)
    }

    @Test("popToRoot clears the active section's whole stack in one step")
    func popToRootClearsTheWholeStack() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))
        router.push(.projectSeries("m31-lrgb"))

        router.popToRoot()

        #expect(router.contentRoute == .projects)
        #expect(router.currentSectionPath.isEmpty)
    }

    // MARK: Wave 4 navigation-rework code-review fix -- cross-section push
    // no longer hijacks primarySection

    @Test("Pushing a foreign-section route mid-journey keeps the CURRENT section active and appends to ITS own stack")
    func pushingAForeignSectionRouteStaysInTheActiveSection() {
        let router = AppRouter()
        router.navigate(to: .nights)
        router.push(.night("2026-08-10"))

        // `.calibration`'s OWN nominal section is `.library` (see
        // `ContentRoute.primarySection`), but this is a mid-journey
        // drill-down from a night's own "Open Calibration" action -- it must
        // land on top of the CURRENT (nights) stack, not hijack the window
        // over to Library.
        router.push(.calibration)

        #expect(router.primarySection == .nights, "A mid-journey push must not hijack the active section")
        #expect(router.currentSectionPath == [.night("2026-08-10"), .calibration])
        #expect(router.contentRoute == .calibration)

        router.pop()
        #expect(router.contentRoute == .night("2026-08-10"), "Back must return to the night, not some unrelated Library stack")
        #expect(router.primarySection == .nights)
    }

    @Test("navigate(toContent:) still switches to the route's own section and resets it to just that route -- the deep-link/global-search jump semantics")
    func navigateToContentStillSwitchesSection() {
        let router = AppRouter()
        router.navigate(to: .nights)
        router.push(.night("2026-08-10"))

        router.navigate(toContent: .projectSeries("m31-lrgb"))

        #expect(router.primarySection == .projects)
        #expect(router.currentSectionPath == [.projectSeries("m31-lrgb")])
        #expect(router.contentRoute == .projectSeries("m31-lrgb"))

        // The nights stack this jump left behind is untouched.
        router.navigate(to: .nights)
        #expect(router.contentRoute == .night("2026-08-10"))
    }

    @Test("navigate(toContent:) resets the destination section's own stack even when it is already the active section")
    func navigateToContentResetsEvenTheAlreadyActiveSection() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))

        router.navigate(toContent: .projectSeries("ngc-1"))

        #expect(router.primarySection == .projects)
        #expect(
            router.currentSectionPath == [.projectSeries("ngc-1")],
            "The old project stack must not linger underneath a fresh deep-linked jump"
        )
    }

    @Test("Switching sections preserves each section's own stack independently")
    func switchingSectionsPreservesEachStack() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))

        router.navigate(to: .insights)
        #expect(router.contentRoute == .insights)

        router.navigate(to: .nights)
        router.push(.night("2026-08-10"))
        #expect(router.contentRoute == .night("2026-08-10"))

        router.navigate(to: .projects)
        #expect(router.contentRoute == .project("m31"), "Projects' own stack survived visiting other sections")

        router.navigate(to: .nights)
        #expect(router.contentRoute == .night("2026-08-10"), "Nights' own stack survived too")
    }

    @Test("Re-selecting the already-active section from the sidebar pops it to root")
    func sameSectionReclickPopsToRoot() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))
        router.push(.projectSeries("m31-lrgb"))

        router.navigate(to: .projects)

        #expect(router.contentRoute == .projects)
        #expect(router.currentSectionPath.isEmpty)
    }

    @Test("Navigating never forces the inspector open or closed")
    func navigationNeverTogglesTheInspector() {
        let openRouter = AppRouter()
        openRouter.isInspectorPresented = true
        openRouter.navigate(to: .projects)
        openRouter.push(.project("m31"))
        openRouter.navigate(to: .nights)
        openRouter.navigate(to: .projects)
        #expect(openRouter.isInspectorPresented)

        let closedRouter = AppRouter()
        closedRouter.isInspectorPresented = false
        closedRouter.navigate(to: .projects)
        closedRouter.push(.project("m31"))
        closedRouter.navigate(to: .nights)
        closedRouter.navigate(to: .projects)
        #expect(!closedRouter.isInspectorPresented)
    }

    @Test("A restored route rebuilds a one-entry stack the native Back chevron can pop")
    func restorationRebuildsAPoppableStack() {
        let state = WindowRestorationState(
            primarySection: .projects,
            contentRoute: .project("m31"),
            selection: .project("m31"),
            isInspectorPresented: true
        )

        let router = AppRouter(restoring: state, validator: .allowingAll)

        #expect(router.contentRoute == .project("m31"))
        #expect(router.currentSectionPath == [.project("m31")])

        router.pop()
        #expect(router.contentRoute == .projects)
    }

    @Test("Restoring a section's own root route leaves an empty stack, not a one-entry loop")
    func restorationOfARootRouteLeavesAnEmptyStack() {
        let state = WindowRestorationState(
            primarySection: .projects,
            contentRoute: .projects,
            selection: nil
        )

        let router = AppRouter(restoring: state, validator: .allowingAll)

        #expect(router.contentRoute == .projects)
        #expect(router.currentSectionPath.isEmpty)
    }

    // MARK: Wave 4 Task 3 -- router-backed workspace tabs

    @Test("A router is born with both workspace tabs on their overview default")
    func routerDefaultsBothWorkspaceTabsToOverview() {
        let router = AppRouter()

        #expect(router.projectTab == .overview)
        #expect(router.nightTab == .overview)
    }

    @Test("The project workspace tab survives pushing into a night and popping back")
    func projectTabSurvivesPushingIntoANightAndPoppingBack() {
        let router = AppRouter()
        router.navigate(to: .projects)
        router.push(.project("m31"))

        router.projectTab = .series

        router.push(.night("2026-08-10"))
        #expect(router.projectTab == .series, "Pushing a DIFFERENT section's route must not reset the project tab")

        router.pop()
        #expect(router.projectTab == .series)
    }

    @Test("The night workspace tab survives navigating away to another section and back")
    func nightTabSurvivesNavigatingAwayAndBack() {
        let router = AppRouter()
        router.navigate(to: .nights)
        router.push(.night("2026-08-10"))

        router.nightTab = .frames

        router.navigate(to: .insights)
        router.navigate(to: .nights)

        #expect(router.nightTab == .frames)
    }

    @Test("Workspace tabs round-trip through window restoration; a legacy blob with neither key restores the overview default")
    func workspaceTabsRoundTripThroughRestoration() throws {
        let state = WindowRestorationState(
            primarySection: .projects,
            contentRoute: .project("m31"),
            selection: .project("m31"),
            isInspectorPresented: true,
            projectTab: .notes,
            nightTab: .frames
        )

        let restored = AppRouter(restoring: state, validator: .allowingAll)
        #expect(restored.projectTab == .notes)
        #expect(restored.nightTab == .frames)

        let legacyState = WindowRestorationState(
            primarySection: .projects,
            contentRoute: .project("m31"),
            selection: .project("m31"),
            isInspectorPresented: true
        )
        #expect(legacyState.projectTab == nil)
        #expect(legacyState.nightTab == nil)

        let restoredLegacy = AppRouter(restoring: legacyState, validator: .allowingAll)
        #expect(restoredLegacy.projectTab == .overview)
        #expect(restoredLegacy.nightTab == .overview)
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
