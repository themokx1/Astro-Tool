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
        .onReceive(NotificationCenter.default.publisher(for: .showFolderStructureHelp)) { _ in
            showFolderStructureHelp = true
        }
    }
}
