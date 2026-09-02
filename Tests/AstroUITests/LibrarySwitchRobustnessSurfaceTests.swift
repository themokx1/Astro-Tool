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

    // MARK: - Item 2: a library switch resets navigation and per-project state.

    @Test("A change of open library resets the router and the per-project stores")
    func libraryRootChangeResetsNavigationAndStores() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains(".onChange(of: onboardingStore.selectedRoot) { previous, current in"))
        #expect(source.contains("router.resetForLibraryChange()"))
        #expect(source.contains("reviewStore.reset()"))
        #expect(source.contains("libraryHealthStore.reset()"))
    }

    @Test("The first open of a library does not wipe the restored window state")
    func theInitialOpenIsNotTreatedAsASwitch() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        // `nil -> root` is the FIRST open (and the one `restoreWindowStateOnce`
        // has just restored a route for), not a switch away from anything.
        #expect(source.contains("guard let previous, previous != current else { return }"))
    }

    @Test("The health store is re-loaded for the new root rather than left empty")
    func healthStoreReloadsForTheNewRoot() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("await libraryHealthStore.load(rootURL: current, accessMode: libraryAccessMode)"))
    }

    @Test("A project route the current library cannot answer gets its own state, not the no-library one")
    func staleProjectRouteHasItsOwnPlaceholder() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("private func projectIsMissingFromCurrentLibrary(_ projectID: UUID) -> Bool"))
        #expect(source.contains("v2.detail.not-in-current-library"))
        #expect(source.contains("Back to Projects"))
        // ... and it must not be reachable while the rows are merely still
        // loading, which would flash the wrong message on every open.
        #expect(source.contains("guard !projectsStore.isLoading, projectsStore.rootURL != nil else { return false }"))
    }

    @Test("Review, Results and the findings detail each route to that state instead of \"Choose an image library first\"")
    func allThreeRoutesUseTheStalePlaceholder() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        let occurrences = source.components(separatedBy: "notInThisLibraryPlaceholder(").count - 1
        // Three call sites plus the helper's own declaration.
        #expect(occurrences == 4)
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
