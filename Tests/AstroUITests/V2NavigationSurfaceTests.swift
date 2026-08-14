import Foundation
import Testing

/// Wave 4 Task 1's own gate: the detail column is a real `NavigationStack`
/// with `navigationDestination` push targets and a native Back chevron, not
/// the old flat `switch router.contentRoute` plus window-covering
/// `.overlay`s the navigation-rework plan diagnosed. Follows this repo's
/// established "surface" suite convention (`V2ShellSurfaceTests`,
/// `V2WorkspaceParitySurfaceTests`): literal source-text assertions, since
/// these are wiring/architecture contracts, not layout contracts.
@Suite("V2 navigation rework (Wave 4 Task 1)")
struct V2NavigationSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("The detail column hosts a real NavigationStack with a native-editor toolbar role")
    func detailColumnIsARealNavigationStack() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(root.contains("NavigationStack(path:"))
        #expect(root.contains(".toolbarRole(.editor)"))
        #expect(root.contains(".navigationDestination(for: ContentRoute.self)"))
    }

    @Test("Every pushed workspace resets its own @State per route via .id(route)")
    func pushedDestinationsCarryRouteIdentity() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(root.contains(".id(route)"))
    }

    @Test("Review, Results, and Conversion are no longer window-covering overlays")
    func reviewResultsConversionAreNotOverlays() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        // `V2RootView` itself still legitimately uses `.overlay` for the
        // always-on-top `ToastOverlay` -- that is unrelated to this gate.
        // What must be gone is an `.overlay` that PRESENTS one of the former
        // window-covering workspaces.
        #expect(!root.contains("reviewDestination"), "ReviewWorkspace should no longer be driven by local overlay state")
        #expect(!root.contains("resultsDestination"), "ResultsView should no longer be driven by local overlay state")
        #expect(!root.contains("conversionRoot"), "ConversionWorkspace should no longer be driven by local overlay state")
        #expect(root.contains("case .review(let projectID):"))
        #expect(root.contains("case .resultsWorkspace(let projectID):"))
        #expect(root.contains("case .conversion:"))
    }

    @Test("Cleanup Preview and Sensor Profiles are routes, not nested inside Health's own overlay")
    func cleanupAndSensorProfilesAreRoutesNotNestedOverlays() throws {
        let health = try contents("Sources/AstroUI/Features/Library/HealthView.swift")
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(!health.contains("showsCleanup"), "HealthView still nests Cleanup Preview behind its own local overlay state")
        #expect(!health.contains("showsSensors"), "HealthView still nests Sensor Profiles behind its own local overlay state")
        #expect(health.contains("openCleanup: () -> Void"))
        #expect(health.contains("openSensorProfiles: () -> Void"))
        #expect(root.contains("case .cleanup:"))
        #expect(root.contains("case .sensorProfiles:"))
    }

    @Test("Every declared ContentRoute case is handled by name in the navigation destination switch")
    func everyContentRouteCaseIsHandledByName() throws {
        let route = try contents("Sources/AstroUI/App/AppRoute.swift")
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")

        // New Wave 4 Task 1 routes actually declared on ContentRoute.
        #expect(route.contains("case review(projectID: UUID)"))
        #expect(route.contains("case resultsWorkspace(projectID: UUID)"))
        #expect(route.contains("case conversion"))
        #expect(route.contains("case cleanup"))
        #expect(route.contains("case sensorProfiles"))

        // The two routes the old flat switch's `default:` silently dropped
        // to an empty view now have their OWN named case in DetailHost's
        // destination switch -- no bare `default:` swallowing them.
        #expect(root.contains("case .result(let rawID):"))
        #expect(root.contains("case .reviewFrame:"))

        let destinationStart = try #require(root.range(of: "private func destination(for route: ContentRoute)"))
        let destinationEnd = try #require(root.range(of: "\n    private func noLibraryPlaceholder"))
        let destinationSwitch = String(root[destinationStart.lowerBound..<destinationEnd.lowerBound])
        #expect(
            !destinationSwitch.contains("default:"),
            "DetailHost's destination switch should be exhaustive, not fall through a default"
        )
    }

    @Test("The Done/Close exit buttons of the former overlays are gone; native Back replaces them")
    func formerOverlayDismissButtonsAreGone() throws {
        let review = try contents("Sources/AstroUI/Features/Review/ReviewWorkspace.swift")
        let results = try contents("Sources/AstroUI/Features/Results/ResultsView.swift")
        let conversion = try contents("Sources/AstroUI/Features/Library/ConversionWorkspace.swift")
        let cleanup = try contents("Sources/AstroUI/Features/Library/CleanupPreviewView.swift")
        let sensorProfiles = try contents("Sources/AstroUI/Features/Library/SensorProfilesView.swift")

        // `ReviewWorkspace`/`SensorProfilesView` each still legitimately
        // declare a `dismiss: () -> Void` on an UNRELATED nested sheet type
        // (`ArchivePreviewSheet`, `SensorMeasureConfirmSheet`) -- only the
        // "Done"/"Close" exit BUTTON that used to close the whole
        // workspace-as-overlay is gone.
        #expect(!review.contains("\"Done\""))
        #expect(!results.contains("\"Close\""))
        #expect(!results.contains("dismiss: () -> Void"))
        #expect(!conversion.contains("Button(\"Done\", action: dismiss)"))
        #expect(!conversion.contains("Button(\"Close\", action: dismiss)"))
        #expect(!cleanup.contains("\"Close\""))
        #expect(!cleanup.contains("dismiss: () -> Void"))
        #expect(!sensorProfiles.contains("Button(\"Close\", action: dismiss)"))
    }

    @Test("Hand-rolled back-chevron buttons are gone from the pushed project/night/series workspaces")
    func handRolledBackChevronsAreGone() throws {
        let project = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        let night = try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        let series = try contents("Sources/AstroUI/Features/Projects/SeriesWorkspaceView.swift")

        #expect(!project.contains("systemImage: \"chevron.left\""))
        #expect(!night.contains("systemImage: \"chevron.left\""))
        #expect(!series.contains("systemImage: \"chevron.left\""))
        // The breadcrumb-style eyebrow text itself is untouched (Task 2
        // turns it into a clickable breadcrumb) -- only the manual button
        // wrapping it is gone.
        #expect(project.contains("Project ›"))
        #expect(night.contains("Night ›"))
        #expect(series.contains("Project ›"))
    }

    @Test("AppRouter exposes a push/pop stack API and a computed contentRoute")
    func appRouterExposesTheStackAPI() throws {
        let model = try contents("Sources/AstroUI/App/AppModel.swift")
        #expect(model.contains("func push(_ route: ContentRoute)"))
        #expect(model.contains("func pop()"))
        #expect(model.contains("func popToRoot()"))
        #expect(model.contains("var contentRoute: ContentRoute {"))
        #expect(model.contains("var currentSectionPath: [ContentRoute]"))
    }

    @Test("ProjectsStore.selectProject assigns snapshot and annotation together, with no await between the writes")
    func selectProjectAssignsSnapshotAndAnnotationAtomically() throws {
        let source = try contents("Sources/AstroUI/Features/Projects/ProjectsStore.swift")
        let range = try #require(source.range(of: "public func selectProject"))
        let body = String(source[range.lowerBound...])
        let closingBrace = try #require(body.range(of: "\n    }"))
        let functionBody = String(body[body.startIndex..<closingBrace.lowerBound])

        // Both queries are awaited into locals BEFORE either published
        // property is assigned -- no `await` keyword appears in between the
        // first `selectedProject`/`selectedProjectID` assignment and the
        // last one in the success path.
        #expect(functionBody.contains("let snapshot = try await"))
        #expect(functionBody.contains("let annotation = try await"))
        let assignmentsRange = try #require(functionBody.range(of: "selectedProjectID = id\n            selectedProject = snapshot\n            selectedProjectAnnotation = annotation"))
        #expect(!functionBody[assignmentsRange].contains("await"))
    }
}
