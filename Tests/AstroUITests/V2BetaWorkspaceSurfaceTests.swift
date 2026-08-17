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
}
