@testable import AstroUI
import AstroApplication
import Foundation
import Testing

@MainActor
@Suite("V2 Projects store")
struct ProjectsStoreTests {
    @Test("Project goal and notes save through the selected project workspace")
    func projectAnnotationEditing() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        try await metadata.save(project)
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        try await store.selectProject(project.id)

        try await store.saveSelectedProjectAnnotation(goalHours: 14, notes: "More dual-band data")

        #expect(store.selectedProjectAnnotation?.integrationGoalHours == 14)
        #expect(store.selectedProjectAnnotation?.notes == "More dual-band data")
        #expect(try await metadata.projectAnnotation(projectID: project.id) == store.selectedProjectAnnotation)
    }

    @Test("Opening a library loads projects and canonical creation refreshes the list")
    func createPersistsAndRefreshes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AstroTool-ProjectsStore-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = try MetadataStore.temporary()
        let store = ProjectsStore(metadataFactory: { _ in metadata })

        try await store.open(rootURL: root)
        let match = try #require(ProjectsQuery.searchCatalog("elefántormány").first)
        let created = try await store.createProject(from: match)

        #expect(created.catalogID == "IC 1396")
        #expect(store.projects == [created])
        #expect(try await metadata.project(id: created.id) == created)
    }

    @Test("Creating the same catalog target twice returns the existing project")
    func duplicateCatalogCreationIsIdempotent() async throws {
        let metadata = try MetadataStore.temporary()
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        try await store.open(rootURL: root)
        let match = try #require(ProjectsQuery.searchCatalog("IC 1396").first)

        let first = try await store.createProject(from: match)
        let second = try await store.createProject(from: match)

        #expect(first.id == second.id)
        #expect(store.projects.count == 1)
    }

    @Test("Selecting a project loads its complete acquisition detail")
    func selectionLoadsProjectDetail() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(
            id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting
        )
        try await metadata.save(project)
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        try await store.open(rootURL: root)

        try await store.selectProject(project.id)

        #expect(store.selectedProjectID == project.id)
        #expect(store.selectedProject?.project == project)
        #expect(store.errorMessage == nil)
    }

    @Test("Project workspace rows aggregate acquisition facts and survive reload selection")
    func workspaceRowsAndStableSelection() async throws {
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = SeriesRecord(
            id: UUID(), projectID: project.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC · 261 mm", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil, gain: 100, offset: 50, binning: "1x1"
        )
        let frames = (0..<3).map { index in
            FrameDecisionRecord(id: UUID(), seriesID: series.id, relativePath: "light/\(index).fit", verdict: index == 2 ? .rejected : .accepted, logicallyExcluded: index == 2)
        }
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series], frameDecisions: frames))
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        let root = URL(fileURLWithPath: NSTemporaryDirectory())

        try await store.open(rootURL: root)
        let row = try #require(store.workspaceRows.first)
        #expect(row.nightCount == 1)
        #expect(row.usableFrames == 2)
        #expect(row.excludedFrames == 1)
        #expect(row.integrationSeconds == 600)
        #expect(row.latestNight == "2026-08-08")
        try await store.selectProject(project.id)
        try await store.open(rootURL: root)
        #expect(store.selectedProjectID == project.id)
    }

    @Test("Projects defaults to most-recent-capture-first and re-sorts workspaceRows on demand")
    func sortsWorkspaceRowsByColumn() async throws {
        // Task 5 (2026-08-17 owner-feedback wave 3): the owner's own words --
        // "rossz a sorrend, az kell előre kerüljön, amiben az utolsó gyüjtés
        // van" (whichever project has the most recent capture belongs at
        // the top). `alpha` sorts first alphabetically but `zulu` has the
        // more recent night, so the default order must put `zulu` first.
        let metadata = try MetadataStore.temporary()
        let alpha = ProjectRecord(id: UUID(), catalogID: "NGC 7000", displayName: "Alpha Target", phase: .collecting)
        let zulu = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Zulu Target", phase: .collecting)
        let alphaNight = NightRecord(id: UUID(), localDate: "2026-08-01", timeZoneID: "Europe/Budapest")
        let zuluNight = NightRecord(id: UUID(), localDate: "2026-08-10", timeZoneID: "Europe/Budapest")
        let alphaSeries = SeriesRecord(
            id: UUID(), projectID: alpha.id, nightID: alphaNight.id, setupID: nil,
            setupDescriptor: "ASI2600MC · 261 mm", sensorMode: .osc, passband: .broadband,
            exposureSeconds: 60, filterName: nil, filterID: nil, gain: nil, offset: nil, binning: "1x1"
        )
        let zuluSeries = SeriesRecord(
            id: UUID(), projectID: zulu.id, nightID: zuluNight.id, setupID: nil,
            setupDescriptor: "ASI2600MC · 261 mm", sensorMode: .osc, passband: .broadband,
            exposureSeconds: 60, filterName: nil, filterID: nil, gain: nil, offset: nil, binning: "1x1"
        )
        try await metadata.save(MetadataWriteBatch(
            projects: [alpha, zulu], nights: [alphaNight, zuluNight], series: [alphaSeries, zuluSeries]
        ))
        let store = ProjectsStore(metadataFactory: { _ in metadata })

        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(store.workspaceRows.map(\.project.displayName) == ["Zulu Target", "Alpha Target"])

        store.setSortOrder([KeyPathComparator(\ProjectWorkspaceRow.project.displayName, order: .forward)])

        #expect(store.workspaceRows.map(\.project.displayName) == ["Alpha Target", "Zulu Target"])
    }

    @Test("Switching selection between projects never leaves the annotation mismatched with the selected snapshot")
    func selectingProjectsNeverObservesMismatchedAnnotation() async throws {
        // Wave 4 Task 1 data-bug fix: `selectProject` used to assign
        // `selectedProject` and `selectedProjectAnnotation` with an `await`
        // in between, so a view reading both `@Observable` properties could
        // catch the new project's snapshot paired with the PREVIOUS
        // project's (or no) annotation -- blanking out real notes. This
        // regression test selects a project WITH saved notes, then a
        // project WITHOUT any, then back to the first, and checks that at
        // every point `selectedProjectAnnotation` (when non-nil) actually
        // belongs to `selectedProject`.
        let metadata = try MetadataStore.temporary()
        let annotated = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let bare = ProjectRecord(id: UUID(), catalogID: "M 42", displayName: "Orion-köd", phase: .collecting)
        try await metadata.save(annotated)
        try await metadata.save(bare)
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))
        try await store.selectProject(annotated.id)
        try await store.saveSelectedProjectAnnotation(goalHours: 10, notes: "Needs more Ha data")

        try await store.selectProject(bare.id)
        #expect(store.selectedProject?.id == bare.id)
        if let annotation = store.selectedProjectAnnotation {
            #expect(annotation.projectID == bare.id, "Stale annotation from the previous project leaked through")
        }

        try await store.selectProject(annotated.id)
        #expect(store.selectedProject?.id == annotated.id)
        #expect(store.selectedProjectAnnotation?.projectID == annotated.id)
        #expect(store.selectedProjectAnnotation?.notes == "Needs more Ha data")
    }

    @Test("Resolving a series id back to its owning project (the .projectSeries restore-recovery path) lands selectProject on the right project")
    func seriesRecoveryResolvesToOwningProject() async throws {
        // Mirrors exactly what `.projectSeries`'s recovery `.task` in
        // `V2RootView.DetailHost` does when a window restores directly into
        // a pushed series route with nothing selected yet: resolve the
        // series' owning project via the already-open metadata store, then
        // select it.
        let metadata = try MetadataStore.temporary()
        let project = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let series = SeriesRecord(
            id: UUID(), projectID: project.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC · 261 mm", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil, gain: 100, offset: 50, binning: "1x1"
        )
        try await metadata.save(MetadataWriteBatch(projects: [project], nights: [night], series: [series]))
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        let record = try #require(try await store.metadataStore?.series(id: series.id))
        try await store.selectProject(record.projectID)

        #expect(store.selectedProjectID == project.id)
        #expect(store.selectedProject?.project == project)
    }

    @Test("A slower, earlier selectProject(A) does not clobber a faster, later selectProject(B) that finishes first")
    func selectProjectGuardsAgainstStaleOutOfOrderCompletion() async throws {
        // Wave 4 navigation-rework code-review fix: a project can be opened
        // through up to three concurrent `selectProject` calls today (the
        // pushed destination's own recovery task plus proactive calls at
        // the push sites) -- on a fast A -> B re-navigation, whichever call
        // happens to finish LAST used to win regardless of which one was
        // started last, so a slow completion for the FIRST project could
        // silently overwrite the correctly-selected second one. This drives
        // that exact shape directly against the store: start `selectProject`
        // for project A, hold it paused (via the test-only delay hook)
        // right before its metadata queries, let `selectProject(B)` run to
        // completion first, THEN release A -- the generation guard inside
        // `selectProject` must make sure A's now-stale completion does not
        // overwrite B's already-current selection.
        let metadata = try MetadataStore.temporary()
        let projectA = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "A", phase: .collecting)
        let projectB = ProjectRecord(id: UUID(), catalogID: "M 42", displayName: "B", phase: .collecting)
        try await metadata.save(MetadataWriteBatch(projects: [projectA, projectB]))
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        let race = SelectionRace()
        store.testOnlySelectionDelay = { id in
            if id == projectA.id { await race.enterAndWaitToProceed() }
        }

        let staleSelection = Task { try await store.selectProject(projectA.id) }
        await race.waitForEntry()
        try await store.selectProject(projectB.id)
        await race.proceed()
        try await staleSelection.value

        #expect(store.selectedProjectID == projectB.id, "The later call (B) must win regardless of which call's queries finished last")
        #expect(store.selectedProject?.project == projectB)
    }

    @Test("Project search matches catalog name, filter and setup metadata")
    func projectSearchUsesWorkflowMetadata() async throws {
        let metadata = try MetadataStore.temporary()
        let elephant = ProjectRecord(id: UUID(), catalogID: "IC 1396", displayName: "Elefántormány-köd", phase: .collecting)
        let orion = ProjectRecord(id: UUID(), catalogID: "M 42", displayName: "Orion-köd", phase: .processing)
        let night = NightRecord(id: UUID(), localDate: "2026-08-08", timeZoneID: "Europe/Budapest")
        let filtered = SeriesRecord(
            id: UUID(), projectID: elephant.id, nightID: night.id, setupID: nil,
            setupDescriptor: "ASI2600MC · 261 mm", sensorMode: .osc, passband: .dualBand,
            exposureSeconds: 300, filterName: "SV220", filterID: nil, gain: 100, offset: 50, binning: "1x1"
        )
        try await metadata.save(MetadataWriteBatch(projects: [elephant, orion], nights: [night], series: [filtered]))
        let store = ProjectsStore(metadataFactory: { _ in metadata })
        try await store.open(rootURL: URL(fileURLWithPath: NSTemporaryDirectory()))

        #expect(try await store.search("SV220").map(\.id) == [elephant.id])
        #expect(try await store.search("processing").map(\.id) == [orion.id])
        #expect(try await store.search("IC1396").map(\.id) == [elephant.id])
    }
}

/// A two-step rendezvous for `selectProjectGuardsAgainstStaleOutOfOrderCompletion`
/// above: lets the test deterministically pause `ProjectsStore`'s slow call
/// right before its metadata queries (`enterAndWaitToProceed`), confirm it has
/// actually reached that point (`waitForEntry`), run the fast call to
/// completion, and only THEN release the slow one (`proceed`) -- proving the
/// generation guard, not lucky scheduling, is what keeps the final state
/// correct. Same continuation-based gate shape as `OperationHostTests`' own
/// `AsyncGate`/`LibraryRescanTests`' own `RescanGate`, just with an added
/// "has it actually entered yet" signal neither of those needed.
private actor SelectionRace {
    private var hasEntered = false
    private var canProceed = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var proceedContinuation: CheckedContinuation<Void, Never>?

    func waitForEntry() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func enterAndWaitToProceed() async {
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if canProceed { return }
        await withCheckedContinuation { proceedContinuation = $0 }
    }

    func proceed() {
        canProceed = true
        proceedContinuation?.resume()
        proceedContinuation = nil
    }
}
