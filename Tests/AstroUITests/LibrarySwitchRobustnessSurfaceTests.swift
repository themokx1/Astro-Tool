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

    // MARK: - Item 1: only one library preparation in flight at a time.

    @Test("prepareLibrary gates on LibraryPreparationGate rather than its own library's key")
    func prepareLibraryUsesTheGate() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("LibraryPreparationGate.decision(preparing: kind, activeOperations: operationHost.activeOperations)"))
        // The old library-specific dedupe must be gone: it is what let a
        // second preparation start for a DIFFERENT library.
        #expect(!source.contains("guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else { return }"))
    }

    @Test("A superseded preparation publishes nothing after each of its awaits")
    func prepareLibraryIsGenerationAware() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("@State private var libraryPreparationGeneration = 0"))
        #expect(source.contains("let generation = libraryPreparationGeneration"))
        // One guard per suspension point that is followed by a write: the
        // gate's wait, `run`'s registration, `outcome`'s completion, and
        // (I9... I2) `adoptRunningPreparation`'s own await of the run it
        // adopts.
        let occurrences = source.components(separatedBy: "generation == libraryPreparationGeneration").count - 1
        #expect(occurrences == 4)
    }

    // MARK: - v5 flow review, I2: select A -> select B -> select A again
    // published nothing at all. A's runner was stale (B bumped the
    // generation), B's runner found A selected and bailed on its
    // `selectedRoot` guard, and the duplicate A request had simply returned.

    @Test("A duplicate request adopts the running preparation's outcome instead of dropping it")
    func aDuplicateRequestAdoptsTheRunningOutcome() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("private func adoptRunningPreparation(kind: OperationKind, root: URL, generation: Int) async"))
        // Both `.skipDuplicate` sites -- the pre-gate check and the one
        // inside the gate loop -- must adopt rather than return empty.
        let adoptCalls = source.components(separatedBy: "await adoptRunningPreparation(").count - 1
        #expect(adoptCalls == 2)
        // It awaits the run it adopts and applies it through the same one
        // place the normal path publishes through.
        #expect(source.contains("let phase = await operationHost.outcome(of: running.id)"))
        #expect(source.contains("await applyPreparationOutcome(phase, id: running.id, root: root)"))
        #expect(source.contains("private func applyPreparationOutcome(_ phase: OperationPhase, id: UUID, root: URL) async"))
    }

    @Test("The failure flag is cleared before the gate, not after it")
    func theFailureFlagIsClearedBeforeTheGate() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        let clearIndex = try #require(source.range(of: "libraryPreparationDidFail = false"))
        let gateIndex = try #require(source.range(of: "case .skipDuplicate = LibraryPreparationGate.decision"))
        #expect(clearIndex.lowerBound < gateIndex.lowerBound, "a stale failure alert must not survive the gate")
    }

    @Test("A wait winner whose library is no longer selected re-drives the selected one instead of going silent")
    func aStaleWaitWinnerRedrivesTheSelectedLibrary() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        let body = try #require(
            source.components(separatedBy: "private func prepareLibrary(root: URL) async {").dropFirst().first
        )
        #expect(body.contains("guard onboardingStore.selectedRoot == root else {"))
        #expect(body.contains("await prepareLibrary(root: selected)"))
        // The re-drive has to happen BEFORE the pipeline runs -- opening the
        // stores for an unselected library is the state divergence itself.
        let redriveIndex = try #require(body.range(of: "await prepareLibrary(root: selected)"))
        let runIndex = try #require(body.range(of: "let id = await operationHost.run("))
        #expect(redriveIndex.lowerBound < runIndex.lowerBound)
    }

    @Test("A duplicate request for the library already preparing does not invalidate the one in flight")
    func aDuplicateRequestDoesNotBumpTheGeneration() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        // The duplicate check runs BEFORE the generation is bumped -- a
        // `.task(id:)` re-fire for the same library must not make the
        // running preparation stale and stop it from publishing.
        let checkIndex = try #require(source.range(of: "case .skipDuplicate = LibraryPreparationGate.decision"))
        let bumpIndex = try #require(source.range(of: "libraryPreparationGeneration += 1"))
        #expect(checkIndex.lowerBound < bumpIndex.lowerBound)
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

    @Test("V2RootView supplies that store to every one of its entry points")
    func detailHostSuppliesSharedMetadataToTheRatingViews() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        let occurrences = source.components(separatedBy: "sharedMetadataStore: sharedMetadataStore").count - 1
        // Home, Projects, Project workspace, Insights (rating), plus this
        // follow-up's Night workspace, Nights, Planning, Saved Targets,
        // Results (each reusing the connection for its own single reader).
        #expect(occurrences == 9)
    }

    // MARK: - Item 3, follow-up: the remaining single-owner readers
    // (ArchiveStore, SavedTargetsStore, ResultsStore, NightActionMenu,
    // HomeStore.productionHighlights) each used to open their own confined
    // `MetadataStore` connection instead of reusing the window's.

    @Test("V2RootView hands ArchiveStore the window's already-open metadata connection")
    func archiveStoreGetsTheSharedMetadataProvider() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains("archiveStore.sharedMetadataProvider = projectsStore.sharedMetadataStore(for:)"))
    }

    @Test("A library switch resets ArchiveStore too, the same as ReviewStore/LibraryHealthStore")
    func libraryRootChangeResetsArchiveStore() throws {
        let source = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(source.contains(".onChange(of: onboardingStore.selectedRoot) { previous, current in"))
        #expect(source.contains("archiveStore.reset()"))
    }

    @Test("HomeStore.configure forwards its shared metadata store into productionHighlights")
    func homeStoreConfigureForwardsSharedMetadata() throws {
        let store = try contents("Sources/AstroUI/Features/Home/HomeStore.swift")
        #expect(store.contains("public func configure("))
        #expect(store.contains("sharedMetadata: MetadataStore?"))
        #expect(store.contains("(try? await highlightsProvider(rootURL, sharedMetadata)) ?? []"))

        let root = try contents("Sources/AstroUI/App/V2RootView.swift")
        #expect(root.contains("sharedMetadata: projectsStore.sharedMetadataStore(for: root)"))
    }

    @Test("Every NightActionMenu.rateFrames call site passes a shared metadata store rather than only a factory")
    func everyRateFramesCallSitePassesSharedMetadata() throws {
        for path in [
            "Sources/AstroUI/Features/Nights/NightWorkspaceView.swift",
            "Sources/AstroUI/Features/Nights/NightActionMenu.swift",
        ] {
            let source = try contents(path)
            #expect(source.contains("sharedMetadata:"), "\(path) must reuse the window's open connection")
        }
    }
}
