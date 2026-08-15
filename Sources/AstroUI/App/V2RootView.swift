import AppKit
import AstroApplication
import Foundation
import SwiftUI

public struct AppUILaunchSelection: Equatable, Sendable {
    public let usesV2: Bool
    /// V2 UI/UX audit task 4: `-UITestInitialSection <home|projects|nights|
    /// planning|library|insights>` opens the app straight into that section
    /// with an empty path -- mainly so a runtime freeze/performance check
    /// (e.g. Planning) doesn't need a scripted click-through of the sidebar
    /// first. An unknown value or the argument's absence both resolve to
    /// `nil`, which leaves today's behavior (start on Home, or on whatever
    /// window restoration already resolved) completely unchanged.
    public let initialSection: PrimarySection?

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
        initialSection = Self.parsedInitialSection(arguments: arguments)
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

    /// A pure parse over `arguments` -- no filesystem/process-environment
    /// access beyond the array itself, so it is trivially unit-testable
    /// without a running app. `PrimarySection`'s raw values already ARE the
    /// exact lowercase section names the argument's contract documents, so
    /// this is a direct `rawValue` lookup: absent argument, argument with no
    /// following value, or a value that matches no case all resolve to
    /// `nil` alike.
    private static func parsedInitialSection(arguments: [String]) -> PrimarySection? {
        guard let index = arguments.firstIndex(of: "-UITestInitialSection") else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return PrimarySection(rawValue: arguments[valueIndex])
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
    /// Wave 4 (post-20014) fix: owned here (once per window, same lifetime
    /// as `operationHost`) and handed down through the environment -- see
    /// `WorkspaceActionCenter`'s own doc comment for why this replaced the
    /// old `FocusedValues.workspaceActions` mechanism.
    @State private var workspaceActionCenter = WorkspaceActionCenter()
    @SceneStorage("v2.windowRestoration") private var encodedWindowState = ""
    /// Gates the automatic restore-and-scan of the last bookmarked library
    /// at launch (see the first `.task` below) -- default `true` preserves
    /// today's behavior exactly. It does not gate `openAndScan` itself: the
    /// first read-only scan of a library the user just picked is mandatory,
    /// not a preference.
    @AppStorage("v2.library.scanOnOpen") private var scanOnOpen = true

    public init(
        appModel: AppModel,
        uiTestFixture: V2UITestFixture? = nil,
        initialSection: PrimarySection? = nil
    ) {
        self.appModel = appModel
        self.uiTestFixture = uiTestFixture
        let router = appModel.makeRouter()
        if let initialSection {
            router.navigate(to: initialSection)
        }
        _router = State(initialValue: router)
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
            libraryPreparationError: $libraryPreparationError,
            retryLibraryPreparation: retryLibraryPreparation
        )
            .overlay(alignment: .topTrailing) {
                ToastOverlay()
                    .accessibilityIdentifier("v2.toast-layer")
            }
            .environment(operationHost)
            .environment(workspaceActionCenter)
            .onAppear {
                restoreWindowStateOnce()
            }
            .onChange(of: router.restorationState) { _, state in
                persist(state)
            }
            .task(id: uiTestFixture?.libraryRoot) {
                // Restoring the last library at launch used to call
                // `restoreSavedLibrary()` directly -- a raw, unrouted scan
                // nobody outside the (never-presented-in-production)
                // onboarding sheet could see: no toolbar progress, no Cancel,
                // and a failure set `phase = .accessProblem` invisibly (V2
                // UI/UX audit section 2.2). Routing it through
                // `operationHost` is what makes launch scanning show up in
                // the toolbar's status control exactly like a manual rescan
                // already does. The UI-test-fixture branch is left calling
                // the raw, awaited `openAndScan(_:)` -- scripted UI tests
                // rely on this task not returning until that fixture scan has
                // actually finished.
                guard onboardingStore.phase == .chooseLibrary else { return }
                if let uiTestFixture {
                    try? await onboardingStore.openAndScan(uiTestFixture.libraryRoot)
                } else if scanOnOpen {
                    await onboardingStore.restoreSavedLibrary(through: operationHost)
                }
            }
            .task(id: onboardingStore.phase.summary?.libraryID.id) {
                guard let root = onboardingStore.selectedRoot,
                      onboardingStore.phase.summary != nil
                else { return }
                await prepareLibrary(root: root)
            }
            .onChange(of: appModel.pendingLibrarySwitchURL) { _, url in
                guard let url else { return }
                Task {
                    _ = try? await onboardingStore.openAndScan(url)
                    appModel.clearPendingLibrarySwitch()
                }
            }
    }

    /// Runs the post-scan "prepare this library" pipeline (materialize
    /// planned-project/night records, open `projectsStore`/`nightsStore`,
    /// configure `homeStore`) through `operationHost` -- so it shows up as a
    /// named, cancellable-looking operation in the toolbar, exactly like
    /// `ScanWorkflowMaterializer.materializeProductionLibrary` running inside
    /// it should (V2 UI/UX audit section 2.2). Unlike a plain rescan/audit,
    /// this pipeline's OUTCOME still has to drive local state
    /// (`appModel.libraryDidOpen`, `libraryPreparationError`) rather than
    /// just a toast, so it awaits `operationHost.outcome(of:)` instead of
    /// firing and forgetting.
    private func prepareLibrary(root: URL) async {
        let kind = OperationKind.loadHome(library: root.lastPathComponent)
        guard !operationHost.activeOperations.contains(where: { $0.kind == kind }) else { return }
        let projectsStore = self.projectsStore
        let nightsStore = self.nightsStore
        let homeStore = self.homeStore
        let uiTestFixture = self.uiTestFixture
        let id = await operationHost.run(
            kind: kind,
            title: "Preparing \(root.lastPathComponent)",
            cancellation: .unavailable
        ) {
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
        }
        let phase = await operationHost.outcome(of: id)
        // The library that finished preparing might not be the one still
        // selected any more (a `Choose Another Library…`/library switch
        // raced this pipeline) -- only apply the outcome if it is.
        guard onboardingStore.selectedRoot == root else { return }
        switch phase {
        case .succeeded:
            appModel.libraryDidOpen(rootURL: root, metadataStore: projectsStore.metadataStore)
            libraryPreparationError = nil
        case .failed:
            libraryPreparationError = await operationHost.errorMessage(for: id)
                ?? "AstroTool could not prepare Projects and Nights for this library."
        case .cancelled, .running:
            break
        }
    }

    /// Backs the "Retry" action on the "Library preparation needs attention"
    /// alert -- re-runs `prepareLibrary` against whatever library is still
    /// selected (the same one that just failed).
    private func retryLibraryPreparation() {
        guard let root = onboardingStore.selectedRoot else { return }
        Task { await prepareLibrary(root: root) }
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
    let retryLibraryPreparation: () -> Void
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
    /// Wave 4 Task 2: whatever the CURRENT route's workspace published as its
    /// own primary actions (Export, Review Frames, Run Audit, ...) -- read
    /// here so the shell's own fixed toolbar can render them in one stable
    /// place, rather than each workspace drawing its own in-body action row.
    /// Wave 4 (post-20014) fix: this used to be `@FocusedValue(\.workspaceActions)`
    /// -- see `WorkspaceActionCenter`'s own doc comment for why that caused
    /// an invalidation storm and why an `@Observable` environment object,
    /// updated only on discrete workspace lifecycle/state-change events,
    /// replaced it.
    @Environment(WorkspaceActionCenter.self) private var workspaceActionCenter

    private var libraryAccessMode: LibraryAccessMode {
        enableWriteOperations ? .mutationEnabled : .readOnly
    }

    var body: some View {
        NavigationSplitView {
            V2Sidebar(router: router, badges: sidebarBadges)
        } detail: {
            DetailHost(
                router: router,
                homeStore: homeStore,
                onboardingStore: onboardingStore,
                projectsStore: projectsStore,
                nightsStore: nightsStore,
                reviewStore: reviewStore,
                libraryHealthStore: libraryHealthStore,
                libraryRootFallback: libraryRootFallback,
                chooseLibrary: presentOnboarding,
                createPlannedProject: { designation in
                    newProjectInitialQuery = designation
                    router.present(.newProject)
                },
                rescan: performRescan,
                accessMode: libraryAccessMode,
                presentQuarantineApply: { plan, rootURL, accessMode in
                    pendingMutationPlan = plan
                    pendingMutationRootURL = rootURL
                    pendingMutationAccessMode = accessMode
                    router.present(.mutationConfirmation(plan.id))
                },
                libraryFindingsChanged: refreshSidebarBadges
            )
        }
        .navigationSplitViewStyle(.balanced)
        .overlay {
            // V2 UI/UX audit section 2.2: `phase.accessProblemMessage` used
            // to be set by `OnboardingStore.openAndScan` and read by nobody
            // -- the onboarding sheet that WOULD render it
            // (`LibraryWelcomeView.accessProblem(_:)`) is never presented in
            // production (`isOnboardingPresented` only starts `true` under a
            // UI-test fixture), so a restore failure (unmounted volume,
            // stale bookmark) just left the shell looking broken with no
            // explanation and no way back in. This renders that same honest
            // state directly in the main window, with the same two recovery
            // actions the sheet's own version offers.
            if let message = onboardingStore.phase.accessProblemMessage {
                LibraryAccessProblemBanner(
                    message: message,
                    retry: retryLibraryAccess,
                    chooseAnotherLibrary: presentOnboarding
                )
            }
        }
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
            // Wave 4 Task 2: the current route's own workspace actions --
            // rendered FIRST, before the shell's own permanent Search/New
            // Project/Inspector controls, so a workspace's context actions
            // read left-to-right as "what THIS screen can do" followed by
            // "what the whole app can always do".
            ToolbarItemGroup {
                workspaceActionsToolbarContent
            }
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
                .accessibilityIdentifier("v2.toolbar.new-project")

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
            case .scan, .audit, .verify: refreshSidebarBadges()
            default: break
            }
        }
        .frame(minWidth: 820, minHeight: 600)
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
                    },
                    onLibraryFindingsChanged: refreshSidebarBadges
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
            // V2 UI/UX audit section 2.2: this alert used to leave only
            // "OK" -- dismissing it left the library half-open (scanned, but
            // Projects/Nights never populated) with no way back in short of
            // quitting and relaunching. "Retry" re-runs the exact same
            // preparation pipeline; "Choose Another Library…" is the same
            // escape hatch the access-problem banner offers.
            Button("Retry") {
                libraryPreparationError = nil
                retryLibraryPreparation()
            }
            Button("Choose Another Library…") {
                libraryPreparationError = nil
                presentOnboarding()
            }
            Button("Cancel", role: .cancel) { libraryPreparationError = nil }
        } message: {
            Text(libraryPreparationError ?? "AstroTool could not prepare Projects and Nights for this library.")
        }
        .onOpenURL { url in
            guard let route = AppRoute(deepLink: url) else { return }
            router.open(route)
        }
        .onAppear {
            refreshSidebarBadges()
            // Wave 3 follow-up fix: `LibraryHealthStore.acknowledge`/
            // `revokeAcknowledgement` previously never touched the sidebar
            // badge at all -- wiring this callback keeps it in sync with
            // those actions the same way `MutationConfirmationSheet`/
            // `CalibrationView` above are wired for quarantine apply/
            // rollback and calibration link apply.
            libraryHealthStore.onLibraryFindingsChanged = refreshSidebarBadges
        }
        .onChange(of: nightsStore.nights) { _, _ in refreshSidebarBadges() }
    }

    private func presentOnboarding() {
        onboardingStore.returnToLibraryChoice()
        isOnboardingPresented = true
    }

    /// Backs the access-problem banner's "Retry" action -- re-attempts the
    /// exact same scan against `selectedRoot` (still set even though the
    /// scan failed), routed through `operationHost` so it shows up in the
    /// toolbar exactly like the original attempt did.
    private func retryLibraryAccess() {
        guard let root = onboardingStore.selectedRoot else { return }
        Task { await onboardingStore.openAndScan(root, through: operationHost) }
    }

    /// Wave 4 Task 2: renders whatever the current route's workspace
    /// published to the shared `WorkspaceActionCenter` -- empty (Home,
    /// Insights, Planning, a section root with nothing pushed) simply
    /// renders nothing, so the toolbar quietly shrinks back to just its
    /// permanent controls. The wrapping `HStack` carries the container
    /// accessibility identifier automation looks for; each item then carries
    /// its OWN identifier, exactly like every other toolbar control here.
    @ViewBuilder
    private var workspaceActionsToolbarContent: some View {
        let items = workspaceActionCenter.actions.items
        if !items.isEmpty {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    switch item {
                    case .button(let action):
                        Button(action: action.callAsFunction) {
                            Label(action.title, systemImage: action.systemImage)
                        }
                        .disabled(action.isDisabled)
                        .help(action.help ?? "")
                        .accessibilityIdentifier(action.id)
                    case .menu(let menu):
                        workspaceMenu(menu)
                    case .exportMenu(let export):
                        ExportMenu(items: export.items, accessibilityID: export.accessibilityID)
                    case .nightActionsMenu(let night):
                        Menu {
                            NightActionMenu(
                                target: night.target,
                                date: night.date,
                                setupDescriptor: night.setupDescriptor,
                                nightID: night.nightID,
                                rootURL: night.rootURL,
                                editNotes: night.editNotes,
                                openCalibration: night.openCalibration,
                                openInsights: night.openInsights
                            )
                        } label: {
                            Label("Night Actions", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier(night.id)
                    }
                }
            }
            .accessibilityIdentifier("v2.toolbar.workspace-actions")
        }
    }

    /// Builds the actual SwiftUI split-button `Menu` for a data-driven
    /// `WorkspaceActionMenu` (Health's "Run Audit", Review's
    /// "Rate Frames…") -- two near-identical branches only because `Menu`'s
    /// `primaryAction:`-carrying initializer is a distinct overload from the
    /// plain one, not because the two menus differ in shape otherwise.
    @ViewBuilder
    private func workspaceMenu(_ menu: WorkspaceActionMenu) -> some View {
        Group {
            if menu.hasPrimaryAction {
                Menu {
                    menuItems(menu)
                } label: {
                    workspaceMenuLabel(menu)
                } primaryAction: {
                    menu.performPrimaryAction()
                }
            } else {
                Menu {
                    menuItems(menu)
                } label: {
                    workspaceMenuLabel(menu)
                }
            }
        }
        .disabled(menu.isDisabled)
        .help(menu.help ?? "")
        .accessibilityIdentifier(menu.id)
    }

    @ViewBuilder
    private func menuItems(_ menu: WorkspaceActionMenu) -> some View {
        ForEach(menu.items) { item in
            Button(action: item.callAsFunction) {
                if let systemImage = item.systemImage {
                    Label(item.title, systemImage: systemImage)
                } else {
                    Text(item.title)
                }
            }
            .disabled(item.isDisabled)
        }
    }

    @ViewBuilder
    private func workspaceMenuLabel(_ menu: WorkspaceActionMenu) -> some View {
        if let systemImage = menu.systemImage {
            Label(menu.title, systemImage: systemImage)
        } else {
            Text(menu.title)
        }
    }

    /// Wave 3 Task 7: the sidebar's `.badge()` counts (Nights
    /// needing-review, Library findings-needing-attention). Recomputed on
    /// appear, whenever `nightsStore.nights` changes (which is exactly what
    /// happens right after a library finishes opening), after a
    /// rescan/audit/verify operation succeeds (the `.onChange(of:
    /// operationHost.recentOutcomes)` above), and after ack/revoke,
    /// quarantine apply/rollback, or a calibration link apply (via each
    /// store's own `onLibraryFindingsChanged` callback, wired below) --
    /// kept intentionally simple, per the plan: no incremental diffing, just
    /// re-read the current state.
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

@MainActor
private struct V2Sidebar: View {
    @Bindable var router: AppRouter
    let badges: SidebarBadgeStore
    /// Wave 4 Task 2: Library's own sub-pages (Health, Calibration) used to
    /// be a separate middle-column list -- now that the shell is a plain
    /// two-column split (sidebar + detail), they are nested rows
    /// under the Library row instead, the same "disclosure group under its
    /// parent section" shape a Finder-style sidebar uses. Expanded by
    /// default so the child rows -- and their accessibility identifiers --
    /// are always reachable without an extra disclosure click first.
    @State private var isLibraryExpanded = true

    /// Routes every sidebar click through `router.navigate(to:)` rather than
    /// binding straight to the (now `private(set)`) `primarySection` --
    /// this is what gives a re-click on the already-active section its
    /// "pop to root" behavior (see `AppRouter.navigate(to:)`'s own doc
    /// comment), which a raw property binding could not express.
    private var sectionSelection: Binding<PrimarySection?> {
        Binding(
            get: { router.primarySection },
            set: { section in
                guard let section else { return }
                router.navigate(to: section)
            }
        )
    }

    var body: some View {
        List(selection: sectionSelection) {
            ForEach(PrimarySection.allCases, id: \.self) { section in
                if section == .library {
                    DisclosureGroup(isExpanded: $isLibraryExpanded) {
                        libraryChildRow(
                            title: "Health",
                            systemImage: "checkmark.shield",
                            route: .health,
                            accessibilityID: "v2.sidebar.library.health"
                        )
                        libraryChildRow(
                            title: "Calibration",
                            systemImage: "thermometer.snowflake",
                            route: .calibration,
                            accessibilityID: "v2.sidebar.library.calibration"
                        )
                    } label: {
                        sectionRow(section)
                    }
                } else {
                    sectionRow(section)
                }
            }
        }
        .navigationTitle("AstroTool")
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        .listStyle(.sidebar)
    }

    private func sectionRow(_ section: PrimarySection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .tag(section)
            .accessibilityLabel(section.title)
            .accessibilityIdentifier("v2.sidebar.\(section.rawValue)")
            .badge(badgeCount(for: section))
            .help(badgeHelp(for: section) ?? "")
            // Wave 3 Task 7: `.badge()` itself accepts no accessibility
            // identifier, so a zero-size marker carries `v2.sidebar.badge.*`
            // for automation -- present only while the count it describes
            // is non-zero, so its mere existence already answers "is there
            // a badge showing right now".
            .overlay(alignment: .trailing) {
                if badgeCount(for: section) > 0 {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityIdentifier(badgeAccessibilityIdentifier(for: section))
                }
            }
    }

    /// A Library child row (Health/Calibration) -- a sidebar jump, so it
    /// goes through `navigate(toContent:)` rather than a raw `push(_:)`:
    /// clicking it always resets Library's stack and lands the user
    /// directly on that page, whether Library was already active (with some
    /// other page pushed) or not (with some OLD Library stack from an
    /// earlier visit still sitting underneath) -- either way the child row's
    /// own page is what ends up on screen, never a stale sibling underneath
    /// it.
    private func libraryChildRow(
        title: String,
        systemImage: String,
        route: ContentRoute,
        accessibilityID: String
    ) -> some View {
        Button {
            router.navigate(toContent: route)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrentLibraryChild(route) ? AstroTokens.Color.spectralBlue : .primary)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityID)
    }

    private func isCurrentLibraryChild(_ route: ContentRoute) -> Bool {
        router.primarySection == .library && router.currentSectionPath.last == route
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
private struct DetailHost: View {
    @Bindable var router: AppRouter
    let homeStore: HomeStore
    let onboardingStore: OnboardingStore
    let projectsStore: ProjectsStore
    let nightsStore: NightsStore
    let reviewStore: ReviewStore
    let libraryHealthStore: LibraryHealthStore
    let libraryRootFallback: URL?
    let chooseLibrary: () -> Void
    let createPlannedProject: (String) -> Void
    let rescan: () -> Void
    let accessMode: LibraryAccessMode
    let presentQuarantineApply: (LibraryMutationPlan, URL, LibraryAccessMode) -> Void
    let libraryFindingsChanged: () -> Void

    /// Wave 4 Task 1: the detail column is a real `NavigationStack` bound to
    /// the active section's own push stack (`AppRouter.currentSectionPath`)
    /// -- the section's root view (`destination(for:)` applied to that
    /// section's own root route) is the stack's root content, and every
    /// other `ContentRoute` (drill-downs AND what used to be
    /// window-covering `.overlay`s: Review/Results/Conversion/Cleanup/
    /// Sensor Profiles) is a `navigationDestination`, reachable with the
    /// native Back chevron. This replaces the old flat `switch
    /// router.contentRoute` that swapped the ENTIRE detail view on every
    /// route change with no history at all.
    var body: some View {
        NavigationStack(path: pathBinding) {
            destination(for: router.primarySection.rootRoute)
                .navigationDestination(for: ContentRoute.self) { route in
                    // `.id(route)` resets any pushed workspace's own
                    // `@State` per route -- without it, SwiftUI reuses the
                    // same view identity across e.g. `.project(A)` ->
                    // `.project(B)`, and V1-era `@State` (a selected tab, an
                    // unsaved edit) leaked between projects (the
                    // navigation-rework plan's diagnosis).
                    destination(for: route).id(route)
                }
        }
        // Wave 4 Task 2: the breadcrumb sits ABOVE the pushed content, in a
        // `.safeAreaInset` rather than inside `destination(for:)` itself --
        // that keeps it OUTSIDE the region that swaps/re-identifies per
        // route, so it stays visually stable (no flash/re-layout) while the
        // stack underneath it pushes and pops.
        .safeAreaInset(edge: .top) {
            BreadcrumbBar(
                sectionTitle: router.primarySection.title,
                path: router.currentSectionPath,
                label: breadcrumbLabel,
                select: { crumbID in BreadcrumbModel.select(crumbID, on: router) }
            )
        }
        .toolbarRole(.editor)
    }

    private var pathBinding: Binding<[ContentRoute]> {
        Binding(
            get: { router.currentSectionPath },
            set: { router.currentSectionPath = $0 }
        )
    }

    /// Resolves one pushed `ContentRoute` to the human-readable label its
    /// breadcrumb crumb shows -- lives here (not in `BreadcrumbBar` itself)
    /// because this is where `projectsStore`/`nightsStore` already are; the
    /// bar itself stays a dumb renderer of whatever label this returns. A
    /// project/night/series id that can't be resolved yet (e.g. mid-load,
    /// same moment `destination(for:)` below shows its own "Loading…" state)
    /// falls back to a generic noun rather than showing a raw identifier.
    private func breadcrumbLabel(for route: ContentRoute) -> String {
        switch route {
        case .home: "Home"
        case .projects: "Projects"
        case .project(let rawID):
            projectDisplayName(for: rawID) ?? "Project"
        case .projectSeries(let rawID):
            seriesLabel(for: rawID) ?? "Series"
        case .nights: "Nights"
        case .night(let rawID):
            nightLabel(for: rawID) ?? "Night"
        case .planning: "Planning"
        case .savedTargets: "Saved Targets"
        case .library: "Library"
        case .health: "Health"
        case .calibration: "Calibration"
        case .insights: "Insights"
        case .reviewFrame: "Frame Review"
        case .result: "Result"
        case .review: "Review"
        case .resultsWorkspace: "Results"
        case .conversion: "Organize Session"
        case .cleanup: "Cleanup"
        case .sensorProfiles: "Sensor Profiles"
        }
    }

    private func projectDisplayName(for rawID: String) -> String? {
        guard let id = UUID(uuidString: rawID) else { return nil }
        if let selected = projectsStore.selectedProject, selected.id == id {
            return selected.project.displayName
        }
        return projectsStore.projects.first { $0.id == id }?.displayName
    }

    private func nightLabel(for rawID: String) -> String? {
        guard let id = UUID(uuidString: rawID) else { return nil }
        return nightsStore.nights.first { $0.id == id }?.date
    }

    private func seriesLabel(for rawID: String) -> String? {
        guard let id = UUID(uuidString: rawID),
              let projectSnapshot = projectsStore.selectedProject,
              let night = projectSnapshot.nights.first(where: { $0.series.contains { $0.id == id } }),
              let item = night.series.first(where: { $0.id == id })
        else { return nil }
        let exposure = "\(item.series.exposureSeconds.formatted(.number.precision(.fractionLength(0...1))))s"
        return [item.series.filterName, exposure].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func destination(for route: ContentRoute) -> some View {
        switch route {
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
                    // Wave 4 navigation-rework code-review fix: no proactive
                    // `selectProject` here anymore -- the pushed `.project`
                    // destination's own recovery `.task` below is the single
                    // loader now, so this push site racing its own call
                    // against that task's (the "triple concurrent
                    // selectProject per project open" finding) is gone.
                    router.push(.project(projectID.uuidString))
                }
            )
        case .projects:
            ProjectsView(
                snapshot: onboardingStore.phase.summary,
                store: projectsStore,
                createProject: { router.present(.newProject) },
                chooseLibrary: chooseLibrary,
                reviewProject: { project in router.push(.review(projectID: project.id)) },
                showResults: { project in router.push(.resultsWorkspace(projectID: project.id)) },
                openProject: { project in
                    // Wave 4 navigation-rework code-review fix: same single-
                    // loader change as `openProjectID` above -- the pushed
                    // `.project` destination's own recovery task handles
                    // loading; this site (and the `ProjectsView` selection
                    // binding's own single-click load, which drives the
                    // inline detail panel on THIS page) no longer race it.
                    router.push(.project(project.id.uuidString))
                }
            )
        case .project(let rawID):
            if let id = UUID(uuidString: rawID), let snapshot = projectsStore.selectedProject, snapshot.id == id {
                ProjectWorkspaceView(
                    snapshot: snapshot,
                    rootURL: onboardingStore.selectedRoot,
                    accessMode: accessMode,
                    annotation: projectsStore.selectedProjectAnnotation,
                    router: router,
                    review: { router.push(.review(projectID: snapshot.project.id)) },
                    results: { router.push(.resultsWorkspace(projectID: snapshot.project.id)) },
                    openNight: { id in
                        nightsStore.selectNight(id)
                        router.push(.night(id.uuidString))
                    },
                    openSeries: { id in
                        router.push(.projectSeries(id.uuidString))
                    },
                    openCalibration: { router.push(.calibration) },
                    openInsights: { setup in router.navigateToInsights(presetSetupFilter: setup) },
                    saveAnnotation: { goal, notes in
                        try await projectsStore.saveSelectedProjectAnnotation(goalHours: goal, notes: notes)
                    }
                )
            } else {
                RoutePendingLoadView(
                    loadingMessage: "Loading project…",
                    failureTitle: "Couldn't Load Project",
                    errorMessage: projectsStore.errorMessage,
                    load: {
                        if let id = UUID(uuidString: rawID) {
                            try? await projectsStore.selectProject(id)
                        }
                    }
                )
            }
        case .night(let rawID):
            if let id = UUID(uuidString: rawID), let row = nightsStore.nights.first(where: { $0.id == id }) {
                NightWorkspaceView(
                    row: row,
                    rootURL: onboardingStore.selectedRoot,
                    accessMode: accessMode,
                    router: router,
                    openProject: { project in
                        // Wave 4 navigation-rework code-review fix: same
                        // single-loader change as the Home/Projects push
                        // sites above.
                        router.push(.project(project.id.uuidString))
                    },
                    reviewProject: { project in router.push(.review(projectID: project.id)) },
                    openCalibration: { router.push(.calibration) },
                    openInsights: { setup in router.navigateToInsights(presetSetupFilter: setup) }
                )
            } else {
                // V2 UI/UX audit, section 5 ("Végtelen töltő"): this branch
                // used to have no recovery `.task` at all -- if the nights
                // list failed to load (or simply had not loaded yet) when a
                // route landed straight on `.night(rawID)`, this spun
                // forever with no error and no retry.
                RoutePendingLoadView(
                    loadingMessage: "Loading night…",
                    failureTitle: "Couldn't Load Night",
                    errorMessage: nightsStore.errorMessage,
                    load: {
                        guard nightsStore.nights.first(where: { $0.id == UUID(uuidString: rawID) }) == nil,
                              let rootURL = onboardingStore.selectedRoot ?? libraryRootFallback
                        else { return }
                        try? await nightsStore.open(rootURL: rootURL)
                    }
                )
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
                    review: { router.push(.review(projectID: projectSnapshot.project.id)) }
                )
            } else {
                // Wave 4 navigation-rework code-review fix: unlike `.project`
                // just above, this branch used to have no recovery `.task`
                // at all -- restoring a window straight into a pushed series
                // route (nothing selected yet) left this spinner showing
                // forever. Resolves the series' OWN owning project via the
                // already-open metadata store (a series route only carries
                // its own id, not its project's), then selects it so the
                // `if` branch above can render on the next observation.
                RoutePendingLoadView(
                    loadingMessage: "Loading series…",
                    failureTitle: "Couldn't Load Series",
                    errorMessage: projectsStore.errorMessage,
                    load: {
                        guard let id = UUID(uuidString: rawID),
                              let metadataStore = projectsStore.metadataStore else { return }
                        if let record = try? await metadataStore.series(id: id) {
                            try? await projectsStore.selectProject(record.projectID)
                        }
                    }
                )
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
                    router.push(.night(id.uuidString))
                },
                openCalibration: { router.push(.calibration) },
                openInsights: { setup in router.navigateToInsights(presetSetupFilter: setup) }
            )
        case .planning:
            PlanningView(
                rootURL: onboardingStore.selectedRoot,
                createProject: createPlannedProject,
                openSavedTargets: { router.push(.savedTargets) }
            )
        case .savedTargets:
            SavedTargetsView(rootURL: onboardingStore.selectedRoot, chooseLibrary: chooseLibrary)
        case .library:
            LibraryView(
                snapshot: onboardingStore.phase.summary,
                rootURL: onboardingStore.selectedRoot,
                chooseLibrary: chooseLibrary,
                convertSession: { router.push(.conversion) },
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
                openCalibration: { router.push(.calibration) },
                accessMode: accessMode,
                openCleanup: { router.push(.cleanup) },
                openSensorProfiles: { router.push(.sensorProfiles) },
                store: libraryHealthStore
            )
        case .calibration:
            CalibrationView(
                rootURL: onboardingStore.selectedRoot, accessMode: accessMode,
                chooseLibrary: chooseLibrary,
                onLibraryFindingsChanged: libraryFindingsChanged
            )
        case .reviewFrame:
            // Wave 4 Task 1: no production call site constructs
            // `.reviewFrame(_:)` today -- its `Int64` payload cannot be
            // resolved back to an owning project/series without a
            // frame -> project lookup this router does not have (see
            // `LibrarySelection.frame`'s own doc comment and
            // `InspectorView.framePanel()`'s matching placeholder). Rather
            // than the old flat switch's silent `default` -> empty view,
            // this is an honest placeholder that also offers a real way
            // back to where frame review IS reachable from.
            V2EmptyDetail(
                title: "Frame Review",
                message: "Frame review opens from a project's own \"Review Frames\" action -- a bare frame identifier alone can't be resolved back to its project.",
                systemImage: "photo",
                actionTitle: "Go to Projects",
                action: { router.navigate(to: .projects) },
                accessibilityIdentifier: "v2.detail.review-frame"
            )
        case .result(let rawID):
            ResultInspectorPanel(
                resultIDString: rawID,
                metadataStore: projectsStore.metadataStore,
                projectID: projectsStore.selectedProjectID
            )
            .navigationTitle("Result")
        case .review(let projectID):
            if let rootURL = onboardingStore.selectedRoot ?? libraryRootFallback {
                ReviewWorkspace(store: reviewStore, rootURL: rootURL, projectID: projectID)
            } else {
                noLibraryPlaceholder(title: "Review", systemImage: "checkmark.rectangle.stack")
            }
        case .resultsWorkspace(let projectID):
            if let rootURL = onboardingStore.selectedRoot ?? libraryRootFallback,
               let project = projectsStore.projects.first(where: { $0.id == projectID }) {
                ResultsView(rootURL: rootURL, project: project)
            } else {
                noLibraryPlaceholder(title: "Results", systemImage: "square.stack.3d.up")
            }
        case .conversion:
            if let rootURL = onboardingStore.selectedRoot ?? libraryRootFallback {
                ConversionDestinationView(rootURL: rootURL, accessMode: accessMode)
            } else {
                noLibraryPlaceholder(title: "Organize Session", systemImage: "square.split.2x1")
            }
        case .cleanup:
            if let rootURL = onboardingStore.selectedRoot ?? libraryRootFallback {
                CleanupPreviewView(
                    rootURL: rootURL,
                    accessMode: accessMode,
                    presentQuarantineApply: { plan in presentQuarantineApply(plan, rootURL, accessMode) }
                )
            } else {
                noLibraryPlaceholder(title: "Cleanup Preview", systemImage: "archivebox")
            }
        case .sensorProfiles:
            if let rootURL = onboardingStore.selectedRoot ?? libraryRootFallback {
                SensorProfilesView(rootURL: rootURL)
            } else {
                noLibraryPlaceholder(title: "Sensor Profiles", systemImage: "sensor")
            }
        }
    }

    private func noLibraryPlaceholder(title: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("Choose an image library first.")
        } actions: {
            Button("Choose Image Library…", action: chooseLibrary)
                .buttonStyle(.borderedProminent)
        }
    }
}

/// V2 UI/UX audit 3.3 -- `ConversionUseCase.production(rootURL:)` used to be
/// constructed directly inside `DetailHost.destination(for:)`'s body switch,
/// which runs `resolvingSymlinksInPath()` over several storage paths (dozens
/// of `stat`/`readlink` syscalls) on EVERY body evaluation for as long as the
/// `.conversion` route is on screen, not just once. This wrapper hoists that
/// construction into its own `.task(id: rootURL)`, which only (re-)runs when
/// `rootURL` actually changes -- mirroring how `CalibrationView`/`HealthView`
/// take an already-resolved value/injected factory rather than resolving
/// storage paths from their own body.
private struct ConversionDestinationView: View {
    let rootURL: URL
    let accessMode: LibraryAccessMode
    @State private var useCase: ConversionUseCase?
    @State private var failed = false

    var body: some View {
        Group {
            if let useCase {
                ConversionWorkspace(useCase: useCase, rootURL: rootURL, accessMode: accessMode)
            } else if failed {
                ContentUnavailableView {
                    Label("Organize Session", systemImage: "square.split.2x1")
                } description: {
                    Text("The session index for this library could not be opened.")
                } actions: {
                    Button("Retry") { failed = false }
                }
            } else {
                ProgressView("Preparing session index…")
            }
        }
        .task(id: "\(rootURL.path)-\(failed)") {
            guard !failed else { return }
            if let resolved = try? ConversionUseCase.production(rootURL: rootURL) {
                useCase = resolved
            } else {
                failed = true
            }
        }
    }
}

/// V2 UI/UX audit, section 5 ("Végtelen töltő") -- a uniform "loading ->
/// content or honest failure with Retry" gate for the pushed detail routes
/// (`.project`, `.night`, `.projectSeries`) whose real content depends on an
/// async recovery load that can fail. Each of those three used to render an
/// unconditional `ProgressView` as the `else` branch of their own `if let
/// ... {} else {}`, with no failure path at all -- a failed (or, for
/// `.night`, never-even-attempted) load spun forever with no error message
/// and no way to retry, even though the owning store's `errorMessage` was
/// already sitting there unrendered. Owns a single local `hasFinishedAttempt`
/// flag so "still loading" and "attempted and failed" are never confused: a
/// bare `nil`/missing row while `hasFinishedAttempt` is still `false` is a
/// spinner; once the recovery closure returns, this always flips to `true`,
/// so a still-missing row at that point is an honest, retryable failure, not
/// a permanent spinner. `.id(route)` on the destination view (see
/// `DetailHost`'s own doc comment) gives every distinct route push a fresh
/// `hasFinishedAttempt`, so navigating to a DIFFERENT project/night/series
/// always starts back at the spinner, never at a stale sibling's failure.
private struct RoutePendingLoadView: View {
    let loadingMessage: String
    let failureTitle: String
    let errorMessage: String?
    let load: () async -> Void

    @State private var hasFinishedAttempt = false

    var body: some View {
        Group {
            if hasFinishedAttempt {
                ContentUnavailableView {
                    Label(failureTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage ?? "This could not be loaded.")
                } actions: {
                    Button("Retry") { hasFinishedAttempt = false }
                }
            } else {
                ProgressView(loadingMessage)
            }
        }
        .task(id: hasFinishedAttempt) {
            guard !hasFinishedAttempt else { return }
            await load()
            hasFinishedAttempt = true
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

/// V2 UI/UX audit section 2.2: the main-window rendering of
/// `OnboardingPhase.accessProblem(_:)` -- previously set by
/// `OnboardingStore.openAndScan` and displayed by nobody outside the
/// onboarding sheet (which production never presents). Mirrors
/// `LibraryWelcomeView.accessProblem(_:)`'s own two recovery actions, minus
/// its "Close" (there is no sheet here to dismiss).
private struct LibraryAccessProblemBanner: View {
    let message: String
    let retry: () -> Void
    let chooseAnotherLibrary: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Library access needs attention", systemImage: "folder.badge.questionmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("v2.shell.access-problem.retry")
            Button("Choose Another Library…", action: chooseAnotherLibrary)
                .accessibilityIdentifier("v2.shell.access-problem.choose-another-library")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityIdentifier("v2.shell.access-problem")
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
}
