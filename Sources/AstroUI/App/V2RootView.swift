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
    @State private var isOnboardingPresented: Bool
    @State private var libraryPreparationError: String?
    @State private var didRestoreWindowState = false
    @SceneStorage("v2.windowRestoration") private var encodedWindowState = ""

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
            libraryRootFallback: uiTestFixture?.libraryRoot,
            isOnboardingPresented: $isOnboardingPresented,
            libraryPreparationError: $libraryPreparationError
        )
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
                } else {
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
                        projectsStore: projectsStore,
                        nightCount: nightsStore.nights.count
                    )
                    libraryPreparationError = nil
                } catch {
                    libraryPreparationError = error.localizedDescription
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
    let libraryRootFallback: URL?
    @Binding var isOnboardingPresented: Bool
    @Binding var libraryPreparationError: String?
    @State private var reviewDestination: ReviewDestination?
    @State private var conversionRoot: URL?
    @State private var resultsDestination: ResultsDestination?
    @State private var showsSearch = false
    @State private var globalSearch = GlobalSearchStore()
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            V2Sidebar(router: router)
        } content: {
            ContentColumn(router: router)
        } detail: {
            DetailHost(
                router: router,
                homeStore: homeStore,
                onboardingStore: onboardingStore,
                projectsStore: projectsStore,
                nightsStore: nightsStore,
                chooseLibrary: presentOnboarding,
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
                }
            )
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: $router.isInspectorPresented) {
            InspectorView(
                selection: router.inspectorSelection,
                hideInspector: router.toggleInspector
            )
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: { showsSearch.toggle() }) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .help("Search projects and observing nights")
                .accessibilityIdentifier("v2.toolbar.search")
                .popover(isPresented: $showsSearch, arrowEdge: .bottom) {
                    GlobalSearchPanel(
                        store: globalSearch,
                        projects: projectsStore,
                        nights: nightsStore,
                        open: openSearchResult
                    )
                }

                Button(action: { router.present(.newProject) }) {
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
                ConversionWorkspace(useCase: useCase, dismiss: { self.conversionRoot = nil })
            }
        }
        .sheet(item: $router.presentation) { presentation in
            if presentation == .newProject {
                NewProjectView(store: projectsStore) {
                    router.dismissPresentation()
                }
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
    }

    private func presentOnboarding() {
        onboardingStore.returnToLibraryChoice()
        isOnboardingPresented = true
    }

    private func openSearchResult(_ result: GlobalSearchResult) {
        showsSearch = false
        switch result.kind {
        case .project:
            router.navigate(to: .projects)
            Task { try? await projectsStore.selectProject(result.objectID) }
        case .night:
            nightsStore.selectNight(result.objectID)
            router.navigate(to: .nights)
        }
    }
}

@MainActor
private struct GlobalSearchPanel: View {
    @Bindable var store: GlobalSearchStore
    let projects: ProjectsStore
    let nights: NightsStore
    let open: (GlobalSearchResult) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search projects and nights", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("v2.global-search.field")
                .onChange(of: query) { _, value in
                    Task { await store.search(value, projects: projects, nights: nights) }
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
                                    Image(systemName: result.kind == .project ? "scope" : "moon.stars")
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

    var body: some View {
        List(selection: $router.primarySection) {
            ForEach(PrimarySection.allCases, id: \.self) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
                    .accessibilityLabel(section.title)
                    .accessibilityIdentifier("v2.sidebar.\(section.rawValue)")
            }
        }
        .navigationTitle("AstroTool")
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        .listStyle(.sidebar)
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
    let chooseLibrary: () -> Void
    let reviewProject: (ProjectRecord) -> Void
    let showResults: (ProjectRecord) -> Void
    let convertSession: () -> Void

    @ViewBuilder
    var body: some View {
        switch router.contentRoute {
        case .home:
            HomeView(store: homeStore, chooseLibrary: chooseLibrary)
        case .projects:
            ProjectsView(
                snapshot: onboardingStore.phase.summary,
                store: projectsStore,
                createProject: { router.present(.newProject) },
                chooseLibrary: chooseLibrary,
                reviewProject: reviewProject,
                showResults: showResults
            )
        case .nights:
            NightsView(
                snapshot: onboardingStore.phase.summary,
                store: nightsStore,
                chooseLibrary: chooseLibrary
            )
        case .planning:
            PlanningView(createProject: { router.present(.newProject) })
        case .library:
            LibraryView(
                snapshot: onboardingStore.phase.summary,
                rootURL: onboardingStore.selectedRoot,
                chooseLibrary: chooseLibrary,
                convertSession: convertSession
            )
        case .insights:
            InsightsView(
                snapshot: onboardingStore.phase.summary,
                rootURL: onboardingStore.selectedRoot,
                chooseLibrary: chooseLibrary
            )
        case .health:
            HealthView(rootURL: onboardingStore.selectedRoot, chooseLibrary: chooseLibrary)
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
        }
    }

    private var systemImage: String {
        switch route {
        case .newProject: "folder.badge.plus"
        case .newNight: "moon.stars"
        case .mutationConfirmation: "checkmark.shield"
        case .settingsDeepLink: "gearshape"
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
