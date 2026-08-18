import Foundation
import Testing

struct V2BetaWorkspaceSurfaceTests {
    @Test("Beta shell routes every primary workspace to real content")
    func betaRoutesHaveConcreteViews() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        // Task 10: the `.library` section now routes to `ArchiveView`, not
        // the deleted `LibraryView`.
        for view in ["ProjectsView", "NightsView", "PlanningView", "ArchiveView", "InsightsView"] {
            #expect(shell.contains("\(view)("))
        }
        #expect(!shell.contains("Available after library workflows arrive"))
    }

    @Test("Every beta workspace exposes a stable accessibility root")
    func workspacesExposeAccessibilityRoots() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = try FileManager.default.subpathsOfDirectory(
            atPath: root.appendingPathComponent("Sources/AstroUI/Features").path
        ).filter { $0.hasSuffix("View.swift") }
        let source = try files.map {
            try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/\($0)"), encoding: .utf8)
        }.joined(separator: "\n")
        for id in ["v2.detail.projects", "v2.detail.nights", "v2.detail.planning", "v2.detail.library", "v2.detail.insights"] {
            #expect(source.contains(id))
        }
    }

    @Test("Project metadata opens only after a library scan has produced an identity")
    func projectStoreFollowsCompletedSnapshot() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(
            contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"),
            encoding: .utf8
        )
        #expect(shell.contains(".task(id: onboardingStore.phase.summary?.libraryID.id)"))
        #expect(!shell.contains(".task(id: onboardingStore.selectedRoot)"))
        #expect(shell.contains("Library preparation needs attention"))
        #expect(!shell.contains("_ = try? await Task.detached"))
    }

    @Test("Projects workspace exposes a single understandable acquisition detail")
    func projectsExposeAcquisitionDetail() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("v2.projects.detail"))
        #expect(source.contains("v2.projects.night"))
        #expect(source.contains("Usable integration"))
        #expect(source.contains("Excluded"))
        #expect(source.contains("selectProject"))
    }

    @Test("Home recommendation opens the selected project instead of a generic page")
    func homeRecommendationHasDirectProjectAction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Home/HomeView.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        #expect(home.contains("Open Project"))
        #expect(home.contains("openProject(project)"))
        #expect(shell.contains("projectsStore.selectProject(project.id)"))
    }

    @Test("Planning carries the recommended catalog target into project creation")
    func planningPrefillsNewProjectFromRecommendation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let planning = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Planning/PlanningView.swift"), encoding: .utf8)
        let projects = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        #expect(planning.contains("createProject(row.target.designation)"))
        #expect(projects.contains("initialQuery"))
        #expect(shell.contains("newProjectInitialQuery = designation"))
    }

    @Test("Creating a project opens its acquisition workspace immediately")
    func newProjectOpensCreatedProject() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let projects = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        #expect(projects.contains("didCreate(project)"))
        #expect(shell.contains("openCreatedProject"))
        #expect(shell.contains("projectsStore.selectProject(project.id)"))
    }

    // MARK: - W5-2 finding 4 (owner pixel review, real 13-project library)

    @Test("The Goal column is gated by the store's own precomputed hasAnyGoal, not re-scanned in body")
    func goalColumnIsGatedByStoreComputedFlag() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let projects = try String(
            contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift"),
            encoding: .utf8
        )
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsStore.swift"),
            encoding: .utf8
        )
        #expect(projects.contains("if store.hasAnyGoal {"), "the \"Goal\" TableColumn must be conditional on the store's own hasAnyGoal")
        #expect(store.contains("public private(set) var hasAnyGoal"))
        // Computed alongside `workspaceRows` at load time, not from a
        // computed `var` re-scanning it on every access.
        #expect(store.contains("private func updateHasAnyGoal()"))
        #expect(!store.contains("var hasAnyGoal: Bool {"), "hasAnyGoal must be a stored value updated once, not a re-scanning computed property")
    }

    @Test("The projects search placeholder is short enough to fit the field without truncating")
    func projectsSearchPlaceholderFitsTheField() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let strings = try String(
            contentsOf: root.appendingPathComponent("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let pattern = try NSRegularExpression(pattern: #""Search projects, catalog, filter, setup, or status"\s*=\s*"([^"]*)""#)
        let nsRange = NSRange(strings.startIndex..<strings.endIndex, in: strings)
        let match = try #require(pattern.firstMatch(in: strings, range: nsRange))
        let range = try #require(Range(match.range(at: 1), in: strings))
        let translation = String(strings[range])
        // The pre-fix translation was 70 characters and visibly truncated
        // ("…összeállítás vagy álla…") inside `TextField(...).frame(maxWidth:
        // 360)`; the corrected prompt must stay well under that.
        #expect(translation.count <= 46, "Hungarian search placeholder (\(translation.count) chars) is likely to truncate again in the 360pt-wide field: \"\(translation)\"")
    }

    @Test("Nights groups morning triage into actionable states")
    func nightsExposeMorningTriage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let nights = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightsView.swift"), encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightsStore.swift"), encoding: .utf8)
        // W4-3b: the standalone "Morning triage" `MetricCard` (a number
        // duplicating the sidebar's own `.badge()` count) is gone -- morning
        // triage is now an actual triage FILTER (Mind / Áttekintésre vár /
        // Kész) plus a one-line summary once every visible night already
        // agrees, not an inert stat. See `NightTriageFilter` and
        // `NightsStore.uniformVisibleTriageState`.
        // "Needs review" itself is now a `NightTriageFilter`/`TriageState`
        // rawValue in the store (reused verbatim by both, per
        // `NightTriageFilter`'s own doc comment), not a literal string in
        // the view -- `NightsView` only ever renders it through
        // `.displayLabel`.
        #expect(nights.contains("v2.nights.triage-filter"))
        #expect(nights.contains("store.uniformVisibleTriageState"))
        #expect(store.contains("case needsReview = \"Needs review\""))
        #expect(store.contains("excludedFrames"))
        #expect(store.contains("triageState"))
        #expect(store.contains("public enum NightTriageFilter"))
        #expect(store.contains("public var uniformVisibleTriageState"))
    }

    @Test("Global search returns capture series and opens their project")
    func globalSearchIncludesSeries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let search = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Search/GlobalSearchStore.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        #expect(search.contains("case series"))
        // Task 5c (2026-08-17): the category word used to be a literal
        // "Series · " prefix baked into `subtitle` itself (never
        // localized); it now lives on `GlobalSearchResultKind.searchLabel`
        // instead, a `LocalizedStringKey` the view renders as its own
        // `Text`, independent of `GlobalSearchResult.detail`'s raw data.
        #expect(search.contains("case .series: \"Series\""))
        #expect(search.contains("series.filterName"))
        #expect(shell.contains("case .series"))
        #expect(shell.contains("guard let objectID = result.objectID"))
        #expect(shell.contains("selectProject(series.projectID)"))
    }

    @Test("Insights shows usable capture efficiency")
    func insightsShowsCaptureEfficiency() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Insights/InsightsView.swift"), encoding: .utf8)
        #expect(view.contains("Capture efficiency"))
        #expect(view.contains("rejectedFrameCount"))
        #expect(view.contains("v2.insights.quality"))
    }

    @Test("Home shows real astronomical tonight recommendations")
    func homeShowsTonightRecommendations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Home/HomeStore.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Home/HomeView.swift"), encoding: .utf8)
        #expect(store.contains("Planner.plan"))
        #expect(store.contains("visibleWindowLocal"))
        #expect(store.contains("moonSeparationDeg"))
        #expect(view.contains("Best targets tonight"))
        #expect(view.contains("v2.home.tonight-recommendations"))
    }

    @Test("Nights exposes the next thirty astronomical nights")
    func nightsShowsPlanningCalendar() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightsStore.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightsView.swift"), encoding: .utf8)
        #expect(store.contains("Planner.month(nights: 30"))
        #expect(view.contains("Next 30 nights"))
        #expect(view.contains("Astronomical planning calendar"))
        #expect(view.contains("v2.nights.planning-calendar"))
    }

    @Test("Insights exposes session quality setup and efficiency trends")
    func insightsShowsQualityTrendSeries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Insights/InsightsView.swift"), encoding: .utf8)
        #expect(view.contains("Session quality trends"))
        #expect(view.contains("fwhmValue"))
        #expect(view.contains("backgroundEPerSecPerArcsec2"))
        #expect(view.contains("efficiencyPercent"))
        #expect(view.contains("selectedSetup"))
        #expect(view.contains("v2.insights.recent-quality-table"))
    }

    // MARK: - W5-2 finding 5 (owner pixel review): cold-start Home honesty

    @Test("Home distinguishes a loading library from a genuinely unconfigured one")
    func homeShowsALoadingStateNotTheEmptyStateWhileOpening() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Home/HomeView.swift"), encoding: .utf8)
        #expect(view.contains("let isLibraryLoading: Bool"))
        #expect(view.contains("if isLibraryLoading {\n                        openingLibrary\n                    } else {\n                        emptyLibrary\n                    }"),
                "the no-library branch must choose between openingLibrary and emptyLibrary based on isLibraryLoading")
        #expect(view.contains("private var openingLibrary: some View"))
        #expect(view.contains("ProgressView(\"Opening the library…\")"))
        #expect(view.contains("v2.home.opening-library"))
        // NightContextRail must receive the same signal, not decide on its
        // own -- one source of truth for "is the library still opening".
        #expect(view.contains("isLoading: isLibraryLoading"))
        #expect(view.contains("let isLoading: Bool"))
    }

    @Test("The night-context card shows a quiet loading line, not \"Site not set\", while the library is opening")
    func nightContextRailShowsAQuietLoadingLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Home/HomeView.swift"), encoding: .utf8)
        // The rail's header trailing text and its main body both branch on
        // `isLoading` BEFORE falling through to the genuine "no site" copy.
        #expect(view.contains("if isLoading {\n                    Text(\"Opening the library…\")"))
        #expect(view.contains("} else if isLoading {\n                HStack(spacing: 6) {\n                    ProgressView().controlSize(.small)"))
        #expect(view.contains("Tonight's site will appear once the library finishes opening."))
    }

    @Test("Home's loading signal is a pure, independently-testable predicate, not inline body logic")
    func homeLibraryLoadingIsAPurePredicate() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        #expect(shell.contains("enum HomeLibraryLoading {"))
        #expect(shell.contains("static func isLoading(selectedRoot: URL?, homeLibraryName: String?, hasAccessProblem: Bool) -> Bool"))
        #expect(shell.contains("HomeLibraryLoading.isLoading("), "DetailHost.isLibraryLoading must delegate to the pure predicate")
        #expect(shell.contains("isLibraryLoading: isLibraryLoading"), "the .home destination must pass the computed signal into HomeView")
    }

    // MARK: - W5-2 finding 6 (owner click-through): Home's "Open Project"
    // button on the "Continue where it matters" card used to navigate to the
    // PROJECTS LIST with the row selected instead of opening the project
    // workspace itself -- a button labeled "open project" must open the
    // project page, the same navigation the row's own "More -> Open Project"
    // menu performs.

    @Test("Home's \"Open Project\" button pushes the project workspace directly, not the Projects list")
    func homeOpenProjectPushesTheProjectWorkspace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"), encoding: .utf8)
        // `case .home:` also appears in `breadcrumbLabel`'s unrelated switch
        // earlier in the file -- anchor on `destination(for:)` itself first,
        // then find `.home` only within that function's body.
        guard let destinationFuncRange = shell.range(of: "private func destination(for route: ContentRoute) -> some View {"),
              let homeCaseRange = shell.range(of: "case .home:", range: destinationFuncRange.upperBound..<shell.endIndex),
              let projectsCaseRange = shell.range(of: "case .projects:", range: homeCaseRange.upperBound..<shell.endIndex)
        else {
            Issue.record("Could not find the .home destination's own source block to inspect")
            return
        }
        let homeDestinationSource = shell[homeCaseRange.upperBound..<projectsCaseRange.lowerBound]
        #expect(
            homeDestinationSource.contains("openProject: { project in\n                    router.push(.project(project.id.uuidString))\n                }"),
            "HomeView's openProject callback must push .project(id) directly, matching openProjectID and ProjectsView's own openProject"
        )
        #expect(
            !homeDestinationSource.contains("router.navigate(to: .projects)"),
            "the .home destination must never route \"Open Project\" to the Projects list"
        )
    }

    @Test("Two hu.lproj entries back the new cold-start loading copy")
    func coldStartLoadingCopyIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let strings = try String(
            contentsOf: root.appendingPathComponent("Sources/AstroToolApp/Resources/hu.lproj/Localizable.strings"),
            encoding: .utf8
        )
        #expect(strings.contains("\"Opening the library…\" = \"Könyvtár megnyitása…\";"))
        #expect(strings.contains("\"Tonight's site will appear once the library finishes opening.\""))
    }
}
