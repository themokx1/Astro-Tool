import AppKit
import AstroApplication
import Foundation
import SwiftUI

public struct AppUILaunchSelection: Equatable, Sendable {
    public let usesV2: Bool

    public init(
        arguments: [String],
        environment: [String: String],
        isDevelopmentBuild: Bool
    ) {
        if arguments.contains("-UseV1UI") {
            usesV2 = false
        } else if arguments.contains("-UseV2UI") {
            usesV2 = true
        } else if let environmentValue = Self.boolean(
            from: environment["ASTROTOOL_V2_UI"]
        ) {
            usesV2 = environmentValue
        } else {
            usesV2 = true
        }
    }

    public static var current: AppUILaunchSelection {
        AppUILaunchSelection(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment,
            isDevelopmentBuild: _isDebugAssertConfiguration()
        )
    }

    private static func boolean(from value: String?) -> Bool? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: nil
        }
    }
}

@MainActor
public struct V2RootView: View {
    private let appModel: AppModel
    private let uiTestFixture: V2UITestFixture?
    @State private var router: AppRouter
    @State private var homeStore: HomeStore
    @State private var onboardingStore: OnboardingStore
    @State private var projectsStore: ProjectsStore
    @State private var nightsStore: NightsStore
    @State private var reviewStore: ReviewStore
    @State private var libraryHealthStore = LibraryHealthStore()
    @State private var isOnboardingPresented: Bool
    @State private var libraryPreparationError: String?
    @State private var didRestoreWindowState = false
    @State private var operationHost = OperationHost(center: OperationCenter())
    @SceneStorage("v2.windowRestoration") private var encodedWindowState = ""
    /// Gates the automatic restore-and-scan of the last bookmarked library
    /// at launch (see the first `.task` below) -- default `true` preserves
    /// today's behavior exactly. It does not gate `openAndScan` itself: the
    /// first read-only scan of a library the user just picked is mandatory,
    /// not a preference.
    @AppStorage("v2.library.scanOnOpen") private var scanOnOpen = true

    public init(
        appModel: AppModel,
        uiTestFixture: V2UITestFixture? = nil
    ) {
        self.appModel = appModel
        self.uiTestFixture = uiTestFixture
        _router = State(initialValue: appModel.makeRouter())
        _homeStore = State(initialValue: HomeStore())
        _onboardingStore = State(
            initialValue: uiTestFixture?.makeOnboardingStore() ?? OnboardingStore()
        )
        let metadataFactory: ProjectsStore.MetadataFactory = if let uiTestFixture {
            { _ in try uiTestFixture.makeMetadataStore() }
        } else {
            ProjectsStore.productionMetadata
        }
        _projectsStore = State(initialValue: ProjectsStore(metadataFactory: metadataFactory))
        _nightsStore = State(initialValue: NightsStore(metadataFactory: metadataFactory))
        _reviewStore = State(initialValue: ReviewStore(metadataFactory: metadataFactory))
        _isOnboardingPresented = State(initialValue: uiTestFixture != nil)
        _libraryPreparationError = State(initialValue: nil)
    }

    public var body: some View {
        V2Shell(
            router: router,
            homeStore: homeStore,
            onboardingStore: onboardingStore,
            projectsStore: projectsStore,
            nightsStore: nightsStore,
            reviewStore: reviewStore,
            libraryHealthStore: libraryHealthStore,
            libraryRootFallback: uiTestFixture?.libraryRoot,
            isOnboardingPresented: $isOnboardingPresented,
            libraryPreparationError: $libraryPreparationError
        )
            .overlay(alignment: .topTrailing) {
                ToastOverlay()
                    .accessibilityIdentifier("v2.toast-layer")
            }
            .environment(operationHost)
            .onAppear {
                restoreWindowStateOnce()
            }
            .onChange(of: router.restorationState) { _, state in
                persist(state)
            }
            .task(id: uiTestFixture?.libraryRoot) {
                guard onboardingStore.phase == .chooseLibrary else { return }
                if let uiTestFixture {
                    try? await onboardingStore.openAndScan(uiTestFixture.libraryRoot)
                } else if scanOnOpen {
                    _ = try? await onboardingStore.restoreSavedLibrary()
                }
            }
            .task(id: onboardingStore.phase.summary?.libraryID.id) {
                guard let root = onboardingStore.selectedRoot,
                      onboardingStore.phase.summary != nil
                else { return }
                do {
                    if let uiTestFixture {
                        try await uiTestFixture.seedReviewMetadata()
                    } else {
                        _ = try await Task.detached(priority: .utility) {
                            try await ScanWorkflowMaterializer.materializeProductionLibrary(rootURL: root)
                        }.value
                    }
                    try await projectsStore.open(rootURL: root)
                    try await nightsStore.open(rootURL: root)
                    await homeStore.configure(
                        libraryName: root.lastPathComponent,
                        rootURL: root,
                        projectsStore: projectsStore,
                        nightCount: nightsStore.nights.count
                    )
                    appModel.libraryDidOpen(rootURL: root, metadataStore: projectsStore.metadataStore)
                    libraryPreparationError = nil
                } catch {
                    libraryPreparationError = error.localizedDescription
                }
            }
            .onChange(of: appModel.pendingLibrarySwitchURL) { _, url in
                guard let url else { return }
                Task {
                    _ = try? await onboardingStore.openAndScan(url)
                    appModel.clearPendingLibrarySwitch()
                }
            }
    }

    private func restoreWindowStateOnce() {
        guard !didRestoreWindowState else { return }
        didRestoreWindowState = true

        guard let state = WindowRestorationStateCodec.decode(encodedWindowState) else {
            persist(router.restorationState)
            return
        }
        router = appModel.makeRouter(restoring: state)
        persist(router.restorationState)
    }

    private func persist(_ state: WindowRestorationState) {
        guard let encoded = try? WindowRestorationStateCodec.encode(state) else { return }
        encodedWindowState = encoded
    }
}

@MainActor
private struct V2Shell: View {
    @Bindable var router: AppRouter
    let homeStore: HomeStore
    let onboardingStore: OnboardingStore
    let projectsStore: ProjectsStore
    let nightsStore: NightsStore
    let reviewStore: ReviewStore
    let libraryHealthStore: LibraryHealthStore
    let libraryRootFallback: URL?
    @Binding var isOnboardingPresented: Bool
    @Binding var libraryPreparationError: String?
    @State private var reviewDestination: ReviewDestination?
    @State private var conversionRoot: URL?
    @State private var resultsDestination: ResultsDestination?
    @State private var showsSearch = false
    @State private var globalSearch = GlobalSearchStore()
    @State private var newProjectInitialQuery = ""
    @State private var pendingMutationPlan: LibraryMutationPlan?
    @State private var pendingMutationRootURL: URL?
    @State private var pendingMutationAccessMode: LibraryAccessMode = .readOnly
    @State private var sidebarBadges = SidebarBadgeStore()
    @AppStorage("v2.library.enableWriteOperations") private var enableWriteOperations = false
    @Environment(\.openSettings) private var openSettings
    @Environment(OperationHost.self) private var operationHost

    private var libraryAccessMode: LibraryAccessMode {
        enableWriteOperations ? .mutationEnabled : .readOnly
    }

    var body: some View {
        NavigationSplitView {
            V2Sidebar(router: router, badges: sidebarBadges)
        } content: {
            ContentColumn(router: router)
        } detail: {
            DetailHost(
                router: router,
                homeStore: homeStore,
                onboardingStore: onboardingStore,
                projectsStore: projectsStore,
                nightsStore: nightsStore,
                libraryHealthStore: libraryHealthStore,
                chooseLibrary: presentOnboarding,
                createPlannedProject: { designation in
                    newProjectInitialQuery = designation
                    router.present(.newProject)
                },
                reviewProject: { project in
                    guard let rootURL = onboardingStore.selectedRoot ?? libraryRootFallback else { return }
                    if router.isInspectorPresented {
                        router.toggleInspector()
                    }
                    reviewDestination = ReviewDestination(id: project.id, rootURL: rootURL)
                },
                showResults: { project in
                    guard let rootURL = onboardingStore.selectedRoot ?? libraryRootFallback else { return }
                    resultsDestination = ResultsDestination(project: project, rootURL: rootURL)
                },
                convertSession: {
                    conversionRoot = onboardingStore.selectedRoot ?? libraryRootFallback
                },
                rescan: performRescan,
                accessMode: libraryAccessMode,
                presentQuarantineApply: { plan, rootURL, accessMode in
                    pendingMutationPlan = plan
                    pendingMutationRootURL = rootURL
                    pendingMutationAccessMode = accessMode
                    router.present(.mutationConfirmation(plan.id))
                }
            )
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $router.isInspectorPresented) {
            InspectorView(
                selection: router.inspectorSelection,
                rootURL: onboardingStore.selectedRoot ?? libraryRootFallback,
                projectsStore: projectsStore,
                nightsStore: nightsStore,
                reviewStore: reviewStore,
                hideInspector: router.toggleInspector
            )
        }
        .toolbar {
            ToolbarItemGroup {
                OperationStatusView()
                    .accessibilityIdentifier("v2.toolbar.operations")

                Button(action: { showsSearch.toggle() }) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search projects, nights, series, results, files, and notes")
                .accessibilityIdentifier("v2.toolbar.search")
                .popover(isPresented: $showsSearch, arrowEdge: .bottom) {
                    GlobalSearchPanel(
                        store: globalSearch,
                        projects: projectsStore,
                        nights: nightsStore,
                        rootURL: onboardingStore.selectedRoot ?? libraryRootFallback,
                        open: openSearchResult
                    )
                }

                Button(action: {
                    newProjectInitialQuery = ""
                    router.present(.newProject)
                }) {
                    Label("New Project", systemImage: "plus")
                }
                .help("Create a project from the astronomical catalog")
                .accessibilityLabel("New project")

                Button(action: router.toggleInspector) {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help(router.isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                .accessibilityLabel(
                    router.isInspectorPresented ? "Hide inspector" : "Show inspector"
                )
                .accessibilityIdentifier("v2.toolbar.inspector")
            }
        }
        .focusedSceneValue(\.appRouter, router)
        .focusedSceneValue(
            \.libraryRescan,
            LibraryRescanCommand(
                isAvailable: onboardingStore.selectedRoot != nil,
                action: performRescan
            )
        )
        .focusedSceneValue(
            \.libraryAudit,
            LibraryAuditCommand(
                isAvailable: onboardingStore.selectedRoot != nil,
                action: performAudit
            )
        )
        .focusedSceneValue(
            \.globalSearchFocus,
            GlobalSearchFocusCommand(isAvailable: true, action: { showsSearch = true })
        )
        .onChange(of: operationHost.recentOutcomes) { _, outcomes in
            guard let latest = outcomes.first, latest.phase == .succeeded else { return }
            switch latest.kind {
            case .scan, .audit: refreshSidebarBadges()
            default: break
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .overlay {
            if let destination = reviewDestination {
                ReviewWorkspace(
                    store: reviewStore,
                    rootURL: destination.rootURL,
                    projectID: destination.id,
                    dismiss: { reviewDestination = nil }
                )
                .background(.background)
            } else if let destination = resultsDestination {
                ResultsView(rootURL: destination.rootURL, project: destination.project) {
                    resultsDestination = nil
                }
            } else if let conversionRoot,
                      let useCase = try? ConversionUseCase.production(rootURL: conversionRoot) {
                ConversionWorkspace(
                    useCase: useCase,
                    rootURL: conversionRoot,
                    accessMode: libraryAccessMode,
                    dismiss: { self.conversionRoot = nil }
                )
            }
        }
        .sheet(item: $router.presentation) { presentation in
            if presentation == .newProject {
                NewProjectView(
                    store: projectsStore,
                    initialQuery: newProjectInitialQuery,
                    dismiss: {
                        router.dismissPresentation()
                        newProjectInitialQuery = ""
                    },
                    didCreate: openCreatedProject
                )
            } else if case .mutationConfirmation(let id) = presentation,
                      let plan = pendingMutationPlan, plan.id == id,
                      let rootURL = pendingMutationRootURL {
                MutationConfirmationSheet(
                    plan: plan,
                    rootURL: rootURL,
                    accessMode: pendingMutationAccessMode,
                    dismiss: {
                        router.dismissPresentation()
                        pendingMutationPlan = nil
                        pendingMutationRootURL = nil
                    }
                )
            } else if case .glossary(let anchor) = presentation {
                GlossaryView(anchor: anchor, dismiss: router.dismissPresentation)
            } else if presentation == .folderStructure {
                FolderStructureHelpView(dismiss: router.dismissPresentation)
            } else if presentation == .firstSteps {
                FirstStepsView(router: router, dismiss: router.dismissPresentation)
            } else {
                V2PresentationPlaceholder(route: presentation) {
                    router.dismissPresentation()
                }
            }
        }
        .sheet(isPresented: $isOnboardingPresented) {
            LibraryWelcomeView(
                store: onboardingStore,
                onContinue: {
                    isOnboardingPresented = false
                    router.navigate(to: .library)
                },
                onPersonalize: {
                    isOnboardingPresented = false
                    openSettings()
                }
            )
        }
        .alert(
            "Library preparation needs attention",
            isPresented: Binding(
                get: { libraryPreparationError != nil },
                set: { if !$0 { libraryPreparationError = nil } }
            )
        ) {
            Button("OK") { libraryPreparationError = nil }
        } message: {
            Text(libraryPreparationError ?? "AstroTool could not prepare Projects and Nights for this library.")
        }
        .onOpenURL { url in
            guard let route = AppRoute(deepLink: url) else { return }
            router.open(route)
        }
        .onAppear { refreshSidebarBadges() }
        .onChange(of: nightsStore.nights) { _, _ in refreshSidebarBadges() }
    }

    private func presentOnboarding() {
        onboardingStore.returnToLibraryChoice()
        isOnboardingPresented = true
    }

    /// Wave 3 Task 7: the sidebar's `.badge()` counts (Nights
    /// needing-review, Library findings-needing-attention). Recomputed on
    /// appear, whenever `nightsStore.nights` changes (which is exactly what
    /// happens right after a library finishes opening), and after a
    /// rescan/audit operation succeeds (the `.onChange(of:
    /// operationHost.recentOutcomes)` above) -- kept intentionally simple,
    /// per the plan: no incremental diffing, just re-read the current state.
    private func refreshSidebarBadges() {
        guard let rootURL = onboardingStore.selectedRoot ?? libraryRootFallback else { return }
        let nights = nightsStore.nights
        Task { await sidebarBadges.refresh(rootURL: rootURL, nights: nights) }
    }

    /// Backs both the ⌘R menu command (`V2AstroToolCommands`, via
    /// `FocusedValues.libraryRescan`) and the Library workspace's own
    /// "Rescan" button -- one action, reused rather than duplicated.
    private func performRescan() {
        Task { await onboardingStore.rescan(operationHost: operationHost) }
    }

    /// Backs both the ⌥⌘A menu command (`V2AstroToolCommands`, via
    /// `FocusedValues.libraryAudit`) and the Library Health workspace's own
    /// "Run Audit" split button -- one action, reused rather than
    /// duplicated, the same shape `performRescan` already uses.
    private func performAudit(mode: AuditRunMode) {
        Task {
            await libraryHealthStore.runAudit(
                mode: mode, rootURL: onboardingStore.selectedRoot, operationHost: operationHost
            )
        }
    }

    private func openSearchResult(_ result: GlobalSearchResult) {
        showsSearch = false
        switch result.kind {
        case .project:
            guard let objectID = result.objectID else { return }
            router.navigate(to: .projects)
            Task { try? await projectsStore.selectProject(objectID) }
        case .night:
            guard let objectID = result.objectID else { return }
            nightsStore.selectNight(objectID)
            router.navigate(to: .nights)
        case .series:
            guard let objectID = result.objectID else { return }
            guard let series = nightsStore.nights
                .flatMap(\.snapshot.series)
                .first(where: { $0.id == objectID }) else { return }
            Task { try? await projectsStore.selectProject(series.projectID) }
            router.navigate(toContent: .projectSeries(series.id.uuidString))
        case .file:
            guard let root = onboardingStore.selectedRoot ?? libraryRootFallback,
                  let path = result.locator else { return }
            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path)])
        case .note:
            guard let objectID = result.objectID else { return }
            router.navigate(to: .projects)
            Task { try? await projectsStore.selectProject(objectID) }
        case .result:
            guard let objectID = result.objectID,
                  let locator = result.locator,
                  let projectID = UUID(uuidString: locator) else { return }
            Task { try? await projectsStore.selectProject(projectID) }
            router.navigate(toContent: .result(objectID.uuidString))
        }
    }

    private func openCreatedProject(_ project: ProjectRecord) {
        router.navigate(to: .projects)
        Task {
            try? await projectsStore.selectProject(project.id)
        }
    }
}

@MainActor
private struct GlobalSearchPanel: View {
    @Bindable var store: GlobalSearchStore
    let projects: ProjectsStore
    let nights: NightsStore
    let rootURL: URL?
    let open: (GlobalSearchResult) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search projects, nights, series, results, files, and notes", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("v2.global-search.field")
                .onChange(of: query) { _, value in
                    Task {
                        await store.search(
                            value,
                            rootURL: rootURL,
                            projects: projects,
                            nights: nights
                        )
                    }
                }
            if query.isEmpty {
                Label("Try a target, date, filter, setup, or status.", systemImage: "sparkle.magnifyingglass")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 18)
            } else if store.results.isEmpty, !store.isSearching {
                ContentUnavailableView.search(text: query).frame(minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.results) { result in
                            Button { open(result) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: searchIcon(result.kind))
                                        .foregroundStyle(AstroTokens.Color.spectralBlue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title).font(.headline)
                                        Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.forward")
                                }
                                .contentShape(Rectangle()).padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 280)
            }
        }
        .padding(14)
        .frame(width: 430)
        .frame(minHeight: 100)
        .accessibilityIdentifier("v2.global-search")
    }

    private func searchIcon(_ kind: GlobalSearchResultKind) -> String {
        switch kind {
        case .project: "scope"
        case .night: "moon.stars"
        case .series: "square.stack.3d.up"
        case .file: "doc"
        case .note: "note.text"
        case .result: "square.stack.3d.up"
        }
    }
}

private struct ReviewDestination: Identifiable {
    let id: UUID
    let rootURL: URL
}

private struct ResultsDestination: Identifiable {
    var id: UUID { project.id }
    let project: ProjectRecord
    let rootURL: URL
}

@MainActor
private struct V2Sidebar: View {
    @Bindable var router: AppRouter
    let badges: SidebarBadgeStore

    var body: some View {
        List(selection: $router.primarySection) {
            ForEach(PrimarySection.allCases, id: \.self) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
                    .accessibilityLabel(section.title)
                    .accessibilityIdentifier("v2.sidebar.\(section.rawValue)")
                    .badge(badgeCount(for: section))
                    .help(badgeHelp(for: section) ?? "")
                    // Wave 3 Task 7: `.badge()` itself accepts no
                    // accessibility identifier, so a zero-size marker
                    // carries `v2.sidebar.badge.*` for automation --
                    // present only while the count it describes is
                    // non-zero, so its mere existence already answers
                    // "is there a badge showing right now".
                    .overlay(alignment: .trailing) {
                        if badgeCount(for: section) > 0 {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .accessibilityIdentifier(badgeAccessibilityIdentifier(for: section))
                        }
                    }
            }
        }
        .navigationTitle("AstroTool")
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        .listStyle(.sidebar)
    }

    private func badgeCount(for section: PrimarySection) -> Int {
        switch section {
        case .nights: badges.nightsNeedingAttention
        case .library: badges.libraryAttentionCount
        default: 0
        }
    }

    private func badgeHelp(for section: PrimarySection) -> String? {
        switch section {
        case .nights where badges.nightsNeedingAttention > 0:
            "\(badges.nightsNeedingAttention) night(s) need review"
        case .library where badges.libraryAttentionCount > 0:
            "\(badges.libraryAttentionCount) health finding(s) need attention, including calibration gaps"
        default: nil
        }
    }

    private func badgeAccessibilityIdentifier(for section: PrimarySection) -> String {
        switch section {
        case .nights: "v2.sidebar.badge.nights"
        case .library: "v2.sidebar.badge.library"
        default: ""
        }
    }
}

@MainActor
private struct ContentColumn: View {
    @Bindable var router: AppRouter

    private var selection: Binding<ContentRoute?> {
        Binding(
            get: { router.contentRoute },
            set: { route in
                guard let route else { return }
                router.navigate(toContent: route)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section(router.primarySection.title) {
                Label("Overview", systemImage: "rectangle.grid.1x2")
                    .tag(router.primarySection.rootRoute)

                if router.primarySection == .library {
                    Label("Health", systemImage: "checkmark.shield")
                        .tag(ContentRoute.health)
                    Label("Calibration", systemImage: "thermometer.snowflake")
                        .tag(ContentRoute.calibration)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        .accessibilityLabel("\(router.primarySection.title) navigation")
    }
}

@MainActor
private struct DetailHost: View {
    @Bindable var router: AppRouter
    let homeStore: HomeStore
    let onboardingStore: OnboardingStore
    let projectsStore: ProjectsStore
    let nightsStore: NightsStore
    let libraryHealthStore: LibraryHealthStore
    let chooseLibrary: () -> Void
    let createPlannedProject: (String) -> Void
    let reviewProject: (ProjectRecord) -> Void
    let showResults: (ProjectRecord) -> Void
    let convertSession: () -> Void
    let rescan: () -> Void
    let accessMode: LibraryAccessMode
    let presentQuarantineApply: (LibraryMutationPlan, URL, LibraryAccessMode) -> Void

    @ViewBuilder
    var body: some View {
        switch router.contentRoute {
        case .home:
            HomeView(
                store: homeStore,
                rootURL: onboardingStore.selectedRoot,
                chooseLibrary: chooseLibrary,
                openProject: { project in
                    router.navigate(to: .projects)
                    Task {
                        try? await projectsStore.selectProject(project.id)
                    }
                },
                openProjectID: { projectID in
                    router.navigate(toContent: .project(projectID.uuidString))
                    Task { try? await projectsStore.selectProject(projectID) }
                }
            )
        case .projects:
            ProjectsView(
                snapshot: onboardingStore.phase.summary,
                store: projectsStore,
                createProject: { router.present(.newProject) },
                chooseLibrary: chooseLibrary,
                reviewProject: reviewProject,
                showResults: showResults,
                openProject: { project in
                    Task { try? await projectsStore.selectProject(project.id) }
                    router.navigate(toContent: .project(project.id.uuidString))
                }
            )
        case .project(let rawID):
            if let id = UUID(uuidString: rawID), let snapshot = projectsStore.selectedProject, snapshot.id == id {
                ProjectWorkspaceView(
                    snapshot: snapshot,
                    rootURL: onboardingStore.selectedRoot,
                    accessMode: accessMode,
                    annotation: projectsStore.selectedProjectAnnotation,
                    close: { router.navigate(to: .projects) },
                    review: { reviewProject(snapshot.project) },
                    results: { showResults(snapshot.project) },
                    openNight: { id in
                        nightsStore.selectNight(id)
                        router.navigate(toContent: .night(id.uuidString))
                    },
                    openSeries: { id in
                        router.navigate(toContent: .projectSeries(id.uuidString))
                    },
                    openCalibration: { router.navigate(toContent: .calibration) },
                    openInsights: { setup in router.navigateToInsights(presetSetupFilter: setup) },
                    saveAnnotation: { goal, notes in
                        try await projectsStore.saveSelectedProjectAnnotation(goalHours: goal, notes: notes)
                    }
                )
            } else {
                ProgressView("Loading project…")
                    .task { if let id = UUID(uuidString: rawID) { try? await projectsStore.selectProject(id) } }
            }
        case .night(let rawID):
            if let id = UUID(uuidString: rawID), let row = nightsStore.nights.first(where: { $0.id == id }) {
                NightWorkspaceView(
                    row: row,
                    rootURL: onboardingStore.selectedRoot,
                    accessMode: accessMode,
                    close: { router.navigate(to: .nights) },
                    openProject: { project in
                        Task { try? await projectsStore.selectProject(project.id) }
                        router.navigate(toContent: .project(project.id.uuidString))
                    },
                    reviewProject: reviewProject,
                    openCalibration: { router.navigate(toContent: .calibration) },
                    openInsights: { setup in router.navigateToInsights(presetSetupFilter: setup) }
                )
            } else {
                ProgressView("Loading night…")
            }
        case .projectSeries(let rawID):
            if let id = UUID(uuidString: rawID),
               let projectSnapshot = projectsStore.selectedProject,
               let night = projectSnapshot.nights.first(where: { $0.series.contains(where: { $0.id == id }) }),
               let item = night.series.first(where: { $0.id == id }) {
                SeriesWorkspaceView(
                    item: item,
                    project: projectSnapshot.project,
                    night: night.night,
                    close: { router.navigate(toContent: .project(projectSnapshot.id.uuidString)) },
                    review: { reviewProject(projectSnapshot.project) }
                )
            } else {
                ProgressView("Loading series…")
            }
        case .nights:
            NightsView(
                snapshot: onboardingStore.phase.summary,
                rootURL: onboardingStore.selectedRoot,
                store: nightsStore,
                accessMode: accessMode,
                chooseLibrary: chooseLibrary,
                openNight: { id in
                    nightsStore.selectNight(id)
                    router.navigate(toContent: .night(id.uuidString))
                },
                openCalibration: { router.navigate(toContent: .calibration) },
                openInsights: { setup in router.navigateToInsights(presetSetupFilter: setup) }
            )
        case .planning:
            PlanningView(createProject: createPlannedProject)
        case .library:
            LibraryView(
                snapshot: onboardingStore.phase.summary,
                rootURL: onboardingStore.selectedRoot,
                chooseLibrary: chooseLibrary,
                convertSession: convertSession,
                rescan: rescan
            )
        case .insights:
            InsightsView(
                snapshot: onboardingStore.phase.summary,
                rootURL: onboardingStore.selectedRoot,
                initialSetupFilter: router.pendingInsightsSetupFilter,
                chooseLibrary: chooseLibrary
            )
            .onAppear { router.pendingInsightsSetupFilter = nil }
        case .health:
            HealthView(
                rootURL: onboardingStore.selectedRoot, chooseLibrary: chooseLibrary,
                openCalibration: { router.navigate(toContent: .calibration) },
                accessMode: accessMode,
                presentQuarantineApply: presentQuarantineApply,
                store: libraryHealthStore
            )
        case .calibration:
            CalibrationView(
                rootURL: onboardingStore.selectedRoot, accessMode: accessMode,
                chooseLibrary: chooseLibrary
            )
        default:
            V2EmptyDetail(
                title: router.primarySection.emptyTitle,
                message: router.primarySection == .library
                    ? "Choose a folder to build a local, read-only index. Your image files stay untouched."
                    : router.primarySection.emptyMessage,
                systemImage: router.primarySection.systemImage,
                actionTitle: router.primarySection == .library
                    ? "Choose Image Library…"
                    : "Explore Library workspace",
                action: {
                    if router.primarySection == .library {
                        chooseLibrary()
                    } else {
                        router.navigate(to: .library)
                    }
                },
                accessibilityIdentifier: router.primarySection.detailAccessibilityIdentifier
            )
        }
    }
}

private struct V2EmptyDetail: View {
    let title: String
    let message: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void
    let accessibilityIdentifier: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle(title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AstroTokens.Color.graphite.opacity(0.36))
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct V2PresentationPlaceholder: View {
    let route: PresentationRoute
    let dismiss: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("This workflow will become available as V2 reaches feature parity.")
        } actions: {
            Button("Close", action: dismiss)
                .keyboardShortcut(.cancelAction)
        }
        .frame(minWidth: 420, minHeight: 260)
    }

    private var title: String {
        switch route {
        case .newProject: "New Project"
        case .newNight: "New Night"
        case .mutationConfirmation: "Confirm Change"
        case .settingsDeepLink: "Settings"
        case .glossary: "Glossary"
        case .folderStructure: "Folder Structure"
        case .firstSteps: "First Steps"
        }
    }

    private var systemImage: String {
        switch route {
        case .newProject: "folder.badge.plus"
        case .newNight: "moon.stars"
        case .mutationConfirmation: "checkmark.shield"
        case .settingsDeepLink: "gearshape"
        case .glossary: "character.book.closed"
        case .folderStructure: "folder"
        case .firstSteps: "checklist"
        }
    }
}

private extension PrimarySection {
    var title: String {
        switch self {
        case .home: "Home"
        case .projects: "Projects"
        case .nights: "Nights"
        case .planning: "Planning"
        case .library: "Library"
        case .insights: "Insights"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .projects: "folder"
        case .nights: "moon.stars"
        case .planning: "calendar"
        case .library: "photo.on.rectangle.angled"
        case .insights: "chart.xyaxis.line"
        }
    }

    var emptyTitle: String {
        switch self {
        case .home: "Home"
        case .projects: "No projects yet"
        case .nights: "No observing nights yet"
        case .planning: "No plan selected"
        case .library: "No library open"
        case .insights: "No insights yet"
        }
    }

    var emptyMessage: String {
        switch self {
        case .home: "Explore the Library workspace to begin."
        case .projects: "Explore the Library workspace before project workflows arrive."
        case .nights: "Explore the Library workspace before night workflows arrive."
        case .planning: "Explore the Library workspace before planning workflows arrive."
        case .library: "Return home while the library picker is being prepared."
        case .insights: "Explore the Library workspace before insights become available."
        }
    }

    var detailAccessibilityIdentifier: String {
        switch self {
        case .home: "v2.detail.home"
        case .projects: "v2.detail.projects"
        case .nights: "v2.detail.nights"
        case .planning: "v2.detail.planning"
        case .library: "v2.detail.library"
        case .insights: "v2.detail.insights"
        }
    }
}
