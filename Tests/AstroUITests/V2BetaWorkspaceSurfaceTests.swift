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
}
