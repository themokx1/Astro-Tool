import Foundation
import Testing

/// v5 library-switch robustness fixes. The store-level halves of these are
/// covered by real, injectable tests (`LibraryHealthStoreTests`,
/// `ProjectRatingRunnerTests`, `AppRouterTests`); the halves below are pure
/// `V2RootView`/view wiring, which this repo has no rendering harness for
/// (see `V2HonestSurfacesTests`' own doc comment), so they follow the
/// established "surface" convention of literal source-text assertions.
@Suite("v5 library-switch robustness surfaces")
struct LibrarySwitchRobustnessSurfaceTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Item 3: one MetadataStore per library.

    @Test("V2RootView hands LibraryHealthStore the window's already-open metadata connection")
    func healthStoreGetsTheSharedMetadataProvider() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("libraryHealthStore.sharedMetadataProvider = projectsStore.sharedMetadataStore(for:)"))
    }

    @Test("The shared metadata store is only offered while it really is the asked-for library's")
    func sharedMetadataStoreIsRootChecked() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("guard self.rootURL == rootURL.standardizedFileURL else { return nil }"))
        #expect(source.contains("return projectsStore.sharedMetadataStore(for: root)"))
    }

    @Test("Every ProjectRatingRunner.run call site passes the shared metadata store rather than only a factory")
    func everyRatingCallSitePassesSharedMetadata() throws {
        for path in [
            "Sources/AstroUI/Features/Insights/InsightsView.swift",
            "Sources/AstroUI/Features/Home/HomeView.swift",
            "Sources/AstroUI/Features/Projects/ProjectWorkspaceView.swift",
            "Sources/AstroUI/Features/Projects/ProjectsView.swift",
        ] {
            let source = try contents(path)
            #expect(
                source.contains("sharedMetadata: sharedMetadataStore"),
                "\(path) must reuse the window's open connection"
            )
        }
    }

    @Test("V2RootView supplies that store to all four rating entry points")
    func detailHostSuppliesSharedMetadataToTheRatingViews() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        let occurrences = source.components(separatedBy: "sharedMetadataStore: sharedMetadataStore").count - 1
        #expect(occurrences == 4, "Home, Projects, Project workspace and Insights each need it")
    }
}
