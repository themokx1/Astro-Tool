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

    @Test("Hand-rolled back-chevron buttons and redundant eyebrow text are gone from the pushed project/night/series workspaces")
    func handRolledBackChevronsAreGone() throws {
        let project = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        let night = try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        let series = try contents("Sources/AstroUI/Features/Projects/SeriesWorkspaceView.swift")

        #expect(!project.contains("systemImage: \"chevron.left\""))
        #expect(!night.contains("systemImage: \"chevron.left\""))
        #expect(!series.contains("systemImage: \"chevron.left\""))
        // Wave 4 Task 3: the breadcrumb-style eyebrow text ("Project › …",
        // "Night › …", the series header's "Project › … › Series › …") is
        // now REDUNDANT with the global `BreadcrumbBar` Task 2 wired above
        // the detail stack, so it is gone entirely rather than kept as dead
        // decoration.
        #expect(!project.contains("Project ›"))
        #expect(!night.contains("Night ›"))
        #expect(!series.contains("Project ›"))
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

    // MARK: Wave 4 Task 2 -- two-column shell, stable toolbar actions, breadcrumb

    @Test("The shell is a plain two-column split -- the old ContentColumn middle list is gone")
    func contentColumnIsGone() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(!root.contains("ContentColumn"))
    }

    @Test("Library's own sub-pages are sidebar child rows, not a separate middle column")
    func librarySubPagesAreSidebarChildRows() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(root.contains("v2.sidebar.library.health"))
        #expect(root.contains("v2.sidebar.library.calibration"))
        #expect(root.contains("DisclosureGroup"))
    }

    @Test("The shell's stable toolbar renders the current route's own workspace actions from the shared WorkspaceActionCenter")
    func shellTogglesRenderTheWorkspaceActionsFocusedValue() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        // Wave 4 (post-20014) fix: this used to be
        // `@FocusedValue(\.workspaceActions)`, republished from every
        // workspace's `body` on every evaluation -- see
        // `WorkspaceActionCenter`'s own doc comment for the invalidation
        // storm that caused. The shell now reads a shared `@Observable`
        // environment object instead, updated only on discrete workspace
        // lifecycle/state-change events.
        #expect(root.contains("@Environment(WorkspaceActionCenter.self)"))
        #expect(root.contains("v2.toolbar.workspace-actions"))
    }

    @Test("A clickable breadcrumb sits above the pushed content in the detail column")
    func breadcrumbBarIsWiredIntoTheDetailColumn() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        let breadcrumb = try contents("Sources/AstroUI/App/BreadcrumbBar.swift")
        #expect(root.contains("BreadcrumbBar("))
        #expect(root.contains(".safeAreaInset(edge: .top)"))
        #expect(breadcrumb.contains("v2.breadcrumb"))
    }

    @Test("ProjectWorkspaceView's header carries only identity -- its old action buttons are gone")
    func projectWorkspaceHeaderHasNoActionButtons() throws {
        let project = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        // The old in-body buttons are gone by exact call shape...
        #expect(!project.contains("Button(\"Review Frames\", action: review)"))
        #expect(!project.contains("Button(\"Results\", action: results)"))
        // ...and each moved action is now published as a structured
        // `WorkspaceAction`/`WorkspaceActionItem` with its own stable id,
        // reachable through the shell's own toolbar instead.
        #expect(project.contains("v2.project.review"))
        #expect(project.contains("v2.project.results"))
        #expect(project.contains("workspaceActionCenter.publish(owner:"))
    }

    @Test("Every workspace publishing toolbar actions does so through WorkspaceActionCenter, not from body")
    func everyWorkspacePublishesWorkspaceActions() throws {
        for path in [
            "Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift",
            "Sources/AstroUI/Features/Nights/NightWorkspaceView.swift",
            "Sources/AstroUI/Features/Projects/SeriesWorkspaceView.swift",
            "Sources/AstroUI/Features/Library/HealthView.swift",
            "Sources/AstroUI/Features/Review/ReviewWorkspace.swift",
            "Sources/AstroUI/Features/Results/ResultsView.swift",
        ] {
            let source = try contents(path)
            // Wave 4 (post-20014) fix: no workspace may publish through
            // `.focusedSceneValue(\.workspaceActions, ...)` any more -- that
            // mechanism republished on every `body` evaluation with no
            // equality check of its own, which is what caused the 100% CPU
            // invalidation storm (see `WorkspaceActionCenter`'s own doc
            // comment). Every workspace instead publishes to the shared
            // `WorkspaceActionCenter` from `.onAppear`/`.onChange(of:)` and
            // clears its own contribution from `.onDisappear`.
            #expect(!source.contains(".focusedSceneValue(\\.workspaceActions,"), "\(path) still publishes through the old focused-value mechanism")
            #expect(source.contains("workspaceActionCenter.publish(owner:"), "\(path) does not publish to WorkspaceActionCenter")
            #expect(source.contains("workspaceActionCenter.clear(owner:"), "\(path) does not clear its own WorkspaceActionCenter contribution")
        }
    }

    // MARK: Wave 4 navigation-rework code-review fix -- ResultsView must not
    // publish WorkspaceActions when embedded

    @Test("ResultsView only publishes WorkspaceActions on its standalone route -- the embedded project-tab pane must not shadow ProjectWorkspaceView's own toolbar actions")
    func resultsViewGatesWorkspaceActionsPublishBehindShowsHeader() throws {
        let results = try contents("Sources/AstroUI/Features/Results/ResultsView.swift")

        // The publish must be reachable only through a branch keyed on
        // `showsHeader` -- when embedded (`showsHeader == false`, as
        // `ProjectResultsPane` renders it), NO view in this file may ever
        // call `workspaceActionCenter.publish`/`.clear`, or it would shadow
        // the parent `ProjectWorkspaceView`'s own Export/Review Frames/
        // Results actions in the shell's stable toolbar. (Wave 4
        // (post-20014) fix: this gate used to key off
        // `.focusedSceneValue(\.workspaceActions, ...)`; the mechanism
        // changed, but the embedding hazard -- and this test's intent -- did
        // not.)
        #expect(results.contains("if showsHeader {"))

        // Bound the scan to `ResultsView`'s OWN `body` (skipping past the
        // sibling `ProjectResultsPane.body` earlier in the file, which is
        // an unrelated one-liner), then up to the first blank line, which
        // separates it from the next member, so an UNRELATED `else` inside
        // some other property later in the file can't be mistaken for
        // this one.
        let structRange = try #require(results.range(of: "public struct ResultsView: View {"))
        let bodyRange = try #require(
            results.range(of: "public var body: some View {", range: structRange.upperBound..<results.endIndex)
        )
        let bodyTail = String(results[bodyRange.upperBound...])
        let bodyEnd = try #require(bodyTail.range(of: "\n\n"))
        let bodyText = String(bodyTail[bodyTail.startIndex..<bodyEnd.lowerBound])

        let elseRange = try #require(bodyText.range(of: "} else {"))
        let elseBranch = String(bodyText[elseRange.upperBound...])
        #expect(
            !elseBranch.contains("workspaceActionCenter"),
            "The embedded (showsHeader: false) branch must not touch WorkspaceActionCenter at all"
        )
    }

    // MARK: Wave 4 navigation-rework code-review fix -- .projectSeries needs
    // a recovery task, same as .project already has

    @Test("A restored .projectSeries route recovers via a task that resolves its owning project, like .project's own fallback already does")
    func projectSeriesDestinationHasARecoveryTask() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")

        // `.projectSeries` also appears (by name only, no body) in
        // `breadcrumbLabel(for:)` earlier in the file -- scope the search to
        // `destination(for:)`'s own switch so that unrelated match isn't
        // picked up instead.
        let destinationRange = try #require(root.range(of: "private func destination(for route: ContentRoute)"))
        let caseRange = try #require(
            root.range(of: "case .projectSeries(let rawID):", range: destinationRange.upperBound..<root.endIndex)
        )
        let nextCaseRange = try #require(
            root.range(of: "\n        case .nights:", range: caseRange.upperBound..<root.endIndex)
        )
        let caseBody = String(root[caseRange.upperBound..<nextCaseRange.lowerBound])

        #expect(caseBody.contains("loadingMessage: \"Loading series…\""))
        #expect(
            caseBody.contains("RoutePendingLoadView("),
            "The .projectSeries fallback must self-heal a cold restore through the shared retry-capable loading gate, like .project's own fallback already does"
        )
        #expect(caseBody.contains("metadataStore"), "The recovery must resolve the series via the already-open metadata store")
        #expect(caseBody.contains("selectProject"))
    }

    // MARK: Wave 4 navigation-rework code-review fix -- one selectProject
    // loader per project open, not three racing ones

    @Test("Pushing into a project no longer fires a redundant proactive selectProject at the push site -- the pushed .project destination's own recovery task is the single loader")
    func projectPushSitesDoNotDuplicateSelectProject() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")

        let redundantPattern = "Task { try? await projectsStore.selectProject("
        let occurrences = root.components(separatedBy: redundantPattern).count - 1
        // The legitimate survivors are all `openSearchResult` global-search
        // jumps (`.project`, `.series`, `.note`, `.result`) -- none of them
        // push `.project(id)` (they jump to the Projects section root, or to
        // `.projectSeries`/`.result` instead), so the `.project` destination's
        // own recovery task never runs for them and each needs its own
        // proactive select. The Home/Projects/Night sites that DO push
        // straight onto `.project(id)` must no longer duplicate that
        // destination's own fallback `.task`.
        #expect(
            occurrences == 4,
            "Expected only the four global-search jumps to still proactively select; found \(occurrences)"
        )

        // The `.project` destination's own single-loader fallback must still
        // be exactly there, untouched -- now driven through
        // `RoutePendingLoadView`'s `load` closure (V2 UI/UX audit, section 5)
        // rather than a bare `.task`, but still the one and only place this
        // exact recovery call lives.
        #expect(root.contains(
            "load: {\n                        if let id = UUID(uuidString: rawID) {\n                            try? await projectsStore.selectProject(id)\n                        }\n                    }"
        ))
    }

    // MARK: Wave 4 Task 3 -- router-backed tabs, a real Results tab

    @Test("ProjectWorkspaceView binds its segmented tab to the router, not local @State")
    func projectWorkspaceViewBindsTheRouterTab() throws {
        let project = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        #expect(!project.contains("@State private var section"))
        #expect(project.contains("selection: $router.projectTab"))
        #expect(project.contains("router: AppRouter"))
    }

    @Test("The project workspace's Results tab hosts real per-project results content, not a placeholder telling the reader to press a button elsewhere")
    func projectResultsTabHostsRealContent() throws {
        let project = try contents("Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift")
        let results = try contents("Sources/AstroUI/Features/Results/ResultsView.swift")
        #expect(!project.contains("Open Results workspace"))
        #expect(!project.contains("Use the Results button to inspect stack and processing lineage."))
        #expect(project.contains("ProjectResultsPane("))
        #expect(results.contains("public struct ProjectResultsPane: View"))
    }

    @Test("NightWorkspaceView and SeriesWorkspaceView each present a segmented Picker over their own tabs")
    func nightAndSeriesWorkspacesHaveSegmentedPickers() throws {
        let night = try contents("Sources/AstroUI/Features/Nights/NightWorkspaceView.swift")
        let series = try contents("Sources/AstroUI/Features/Projects/SeriesWorkspaceView.swift")

        #expect(night.contains(".pickerStyle(.segmented)"))
        #expect(night.contains("selection: $router.nightTab"))
        #expect(series.contains(".pickerStyle(.segmented)"))
    }

    @Test("AppRouter carries a project tab and a night tab, both defaulting to overview")
    func appRouterCarriesWorkspaceTabs() throws {
        let model = try contents("Sources/AstroUI/App/AppModel.swift")
        #expect(model.contains("var projectTab: ProjectWorkspaceTab"))
        #expect(model.contains("var nightTab: NightWorkspaceTab"))
    }

    // MARK: V2 UI/UX audit 3.3 -- no filesystem work in the body switch

    @Test("DetailHost's destination(for:) switch never constructs ConversionUseCase.production itself -- that resolves several stat/readlink syscalls per body pass")
    func destinationSwitchDoesNotConstructConversionUseCaseDirectly() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")

        let destinationStart = try #require(root.range(of: "private func destination(for route: ContentRoute)"))
        let destinationEnd = try #require(root.range(of: "\n    private func noLibraryPlaceholder"))
        let destinationSwitch = String(root[destinationStart.lowerBound..<destinationEnd.lowerBound])

        #expect(
            !destinationSwitch.contains("ConversionUseCase.production("),
            "ConversionUseCase.production(rootURL:) must be hoisted out of the per-body-pass destination switch into the destination view's own .task"
        )
        #expect(root.contains("ConversionUseCase.production("), "the construction must still happen somewhere, just not in the switch")
    }

    // MARK: V2 UI/UX audit 5 -- failed project/night/series loads must not
    // spin forever

    @Test("The project, night, and series recovery fallbacks each offer an honest failure state with a Retry action, not an unconditional spinner")
    func projectNightAndSeriesRecoveryFallbacksHaveARetryableFailureState() throws {
        let root = try contents("Sources/AstroUI/App/V2RootView.swift")

        let destinationStart = try #require(root.range(of: "private func destination(for route: ContentRoute)"))
        let destinationEnd = try #require(root.range(of: "\n    private func noLibraryPlaceholder"))
        let destinationSwitch = String(root[destinationStart.lowerBound..<destinationEnd.lowerBound])

        // Each of the three fallbacks must route through a shared gate that
        // renders a `ContentUnavailableView` + Retry once the recovery
        // attempt has actually finished, rather than the bare `ProgressView`
        // fallback with no failure branch the audit found.
        let projectCaseRange = try #require(destinationSwitch.range(of: "case .project(let rawID):"))
        let nightCaseRange = try #require(destinationSwitch.range(of: "case .night(let rawID):"))
        let seriesCaseRange = try #require(destinationSwitch.range(of: "case .projectSeries(let rawID):"))
        let nightsCaseRange = try #require(destinationSwitch.range(of: "\n        case .nights:"))

        let projectCaseBody = String(destinationSwitch[projectCaseRange.upperBound..<nightCaseRange.lowerBound])
        let nightCaseBody = String(destinationSwitch[nightCaseRange.upperBound..<seriesCaseRange.lowerBound])
        let seriesCaseBody = String(destinationSwitch[seriesCaseRange.upperBound..<nightsCaseRange.lowerBound])

        for (name, body) in [("project", projectCaseBody), ("night", nightCaseBody), ("series", seriesCaseBody)] {
            #expect(body.contains("RoutePendingLoadView("), "\(name)'s fallback must render through the shared retry-capable loading gate")
        }

        #expect(root.contains("struct RoutePendingLoadView"))
        #expect(root.contains("ContentUnavailableView"))
        #expect(root.contains("Button(\"Retry\")"))
    }
}
