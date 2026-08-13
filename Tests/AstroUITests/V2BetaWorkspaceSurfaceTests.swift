import Foundation
import Testing

struct V2BetaWorkspaceSurfaceTests {
    @Test("Beta shell routes every primary workspace to real content")
    func betaRoutesHaveConcreteViews() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        for view in ["ProjectsView", "NightsView", "PlanningView", "LibraryView", "InsightsView"] {
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
            try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/\($0)"))
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
            contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift")
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
            contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift")
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
        let home = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Home/HomeView.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        #expect(home.contains("Open Project"))
        #expect(home.contains("openProject(project)"))
        #expect(shell.contains("projectsStore.selectProject(project.id)"))
    }

    @Test("Planning carries the recommended catalog target into project creation")
    func planningPrefillsNewProjectFromRecommendation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let planning = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Planning/PlanningView.swift"))
        let projects = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        #expect(planning.contains("createProject(row.target.designation)"))
        #expect(projects.contains("initialQuery"))
        #expect(shell.contains("newProjectInitialQuery = designation"))
    }

    @Test("Creating a project opens its acquisition workspace immediately")
    func newProjectOpensCreatedProject() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let projects = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Projects/ProjectsView.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        #expect(projects.contains("didCreate(project)"))
        #expect(shell.contains("openCreatedProject"))
        #expect(shell.contains("projectsStore.selectProject(project.id)"))
    }

    @Test("Nights groups morning triage into actionable states")
    func nightsExposeMorningTriage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let nights = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightsView.swift"))
        let store = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Nights/NightsStore.swift"))
        #expect(nights.contains("Morning triage"))
        #expect(nights.contains("Needs review"))
        #expect(nights.contains("v2.nights.triage"))
        #expect(store.contains("excludedFrames"))
        #expect(store.contains("triageState"))
    }

    @Test("Global search returns capture series and opens their project")
    func globalSearchIncludesSeries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let search = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Search/GlobalSearchStore.swift"))
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/App/V2RootView.swift"))
        #expect(search.contains("case series"))
        #expect(search.contains("Series ·"))
        #expect(search.contains("series.filterName"))
        #expect(shell.contains("case .series"))
        #expect(shell.contains("selectProject(result.objectID)"))
    }

    @Test("Insights shows usable capture efficiency")
    func insightsShowsCaptureEfficiency() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AstroUI/Features/Insights/InsightsView.swift"))
        #expect(view.contains("Capture efficiency"))
        #expect(view.contains("rejectedFrameCount"))
        #expect(view.contains("v2.insights.quality"))
    }
}
