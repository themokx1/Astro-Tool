import AstroUI
import SwiftUI

@main
struct AstroToolApp: App {
    @State private var appState = AppState()
    @State private var appModel = AppModel(
        restorationValidator: RouteRestorationValidator(
            selectionIsAvailable: { _ in false },
            contentRouteIsAvailable: { $0.selection == nil }
        )
    )
    private let launchSelection = AppUILaunchSelection.current

    var body: some Scene {
        WindowGroup {
            if launchSelection.usesV2 {
                V2RootView(appModel: appModel)
            } else {
                RootView()
                    .environment(appState)
                    .frame(minWidth: 1100, minHeight: 700)
                    .onAppear {
                        appState.resolveRootOnLaunch()
                    }
            }
        }
        .commands {
            if launchSelection.usesV2 {
                V2AstroToolCommands()
            } else {
                AstroToolCommands()
            }
        }

        Settings {
            SettingsWindow()
                .environment(appState)
        }
    }
}

/// Switches between the first-run flow (`WelcomeView`/`FirstScanView`), the
/// guidance screen (`AccessDeniedView`, for a TCC problem or an unmounted
/// volume), and the normal navigation shell (`MainShellView`), based on
/// `AppState.rootStatus` (R9-T1 -- replaces the old always-on six-tab
/// `TabView`).
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings
    @State private var showFolderStructureHelp = false
    /// R9-T6/B16(b): "Súgó ▸ Fogalomtár" -- same "the menu bar has no view
    /// state, so it posts a `Notification` this always-on-screen view
    /// observes" pattern `showFolderStructureHelp` already uses.
    @State private var showGlossary = false
    /// R11-T12/F11(a): the optional term name to scroll `GlossarySheet` to,
    /// read off `.showGlossary`'s notification `object` -- `nil` for every
    /// existing poster (open at the top), set whenever a per-field ⓘ
    /// popover's "Fogalomtár…" link posts with a specific term.
    @State private var glossaryAnchor: String?
    /// R11-T3/F11(c)/F20: "Súgó ▸ A Sirilről…" -- same notification pattern.
    @State private var showSirilHelp = false
    /// R11-T12/F12: "Súgó ▸ Első lépések…" -- same notification pattern.
    @State private var showFirstSteps = false
    @State private var showOnboarding = false

    var body: some View {
        rootContent
        .sheet(isPresented: $showFolderStructureHelp) {
            FolderStructureHelpSheet()
        }
        .sheet(isPresented: $showGlossary) {
            GlossarySheet(anchor: glossaryAnchor)
        }
        .sheet(isPresented: $showSirilHelp) {
            SirilHelpSheet()
        }
        .sheet(isPresented: $showFirstSteps) {
            FirstStepsSheet()
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingWizardView(
                onSkipAll: {
                    appState.completeOnboardingVersion()
                    showOnboarding = false
                },
                onFinished: { showOnboarding = false }
            )
        }
        .onChange(of: appState.onboardingPresentationNonce) { _, _ in
            if canPresentOnboarding { showOnboarding = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFolderStructureHelp)) { _ in
            showFolderStructureHelp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGlossary)) { note in
            glossaryAnchor = note.object as? String
            showGlossary = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSirilHelp)) { _ in
            showSirilHelp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFirstSteps)) { _ in
            showFirstSteps = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSupportDiagnostics)) { _ in
            appState.settingsTab = .support
            openSettings()
        }
    }

    private var canPresentOnboarding: Bool {
        appState.rootStatus == .ok || appState.rootStatus == .notScanned
    }

    @ViewBuilder
    private var rootContent: some View {
        if appState.legacyMigrationAvailable {
            LegacyMigrationView()
        } else {
            switch appState.rootStatus {
            case .accessDenied, .notMounted:
                AccessDeniedView(status: appState.rootStatus) {
                    appState.retryRootAccess()
                }
            case .noRoot:
                WelcomeView()
            case .notScanned, .ok:
                if appState.shouldShowFirstScanExperience {
                    FirstScanView()
                } else {
                    MainShellView()
                }
            }
        }
    }
}
