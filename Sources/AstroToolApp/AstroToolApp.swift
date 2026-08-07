import SwiftUI

@main
struct AstroToolApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    appState.resolveRootOnLaunch()
                }
        }
        .commands {
            AstroToolCommands()
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
    @State private var showFolderStructureHelp = false
    /// R9-T6/B16(b): "Súgó ▸ Fogalomtár" -- same "the menu bar has no view
    /// state, so it posts a `Notification` this always-on-screen view
    /// observes" pattern `showFolderStructureHelp` already uses.
    @State private var showGlossary = false
    /// R11-T3/F11(c)/F20: "Súgó ▸ A Sirilről…" -- same notification pattern.
    @State private var showSirilHelp = false

    var body: some View {
        Group {
            switch appState.rootStatus {
            case .accessDenied, .notMounted:
                AccessDeniedView(status: appState.rootStatus) {
                    appState.retryRootAccess()
                }
            case .noRoot:
                WelcomeView()
            case .notScanned, .ok:
                if appState.lastScanDate == nil, !appState.didDismissFirstRun {
                    FirstScanView()
                } else {
                    MainShellView()
                }
            }
        }
        .sheet(isPresented: $showFolderStructureHelp) {
            FolderStructureHelpSheet()
        }
        .sheet(isPresented: $showGlossary) {
            GlossarySheet()
        }
        .sheet(isPresented: $showSirilHelp) {
            SirilHelpSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFolderStructureHelp)) { _ in
            showFolderStructureHelp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGlossary)) { _ in
            showGlossary = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSirilHelp)) { _ in
            showSirilHelp = true
        }
    }
}
